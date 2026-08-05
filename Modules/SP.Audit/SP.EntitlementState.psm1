<#
.SYNOPSIS
    SP.EntitlementState -- persistent per-entitlement state tracking across campaigns.
.DESCRIPTION
    Maintains a JSONL key-value store that tracks honest decision state per cross-campaign
    ItemKey. The key is the REASSIGNMENT-STABLE key produced by Get-SPSeriesItemKey /
    Resolve-SPSeriesItemState (IdentityId | lowercased access NAME | SourceId-else-name --
    NEVER AccessId-first, because ISC regenerates AccessIds when a certification is
    reassigned). This module never recomputes the key; it trusts the resolved item.

    State codes:
      APPROVE   -- genuine reviewer approval
      REVOKE    -- genuine reviewer revocation
      PENDING   -- no decision yet (campaign still active, or item untouched)
      UNDECIDED -- campaign closed, item was auto-approved (never genuinely reviewed)

    CONTRACT (v1.1): the ORCHESTRATOR (SP.StateOrchestrator) owns processedInstances
    bookkeeping, scope detection, and retention pruning. Update-SPEntitlementState is a
    pure per-instance state machine: it may be called repeatedly for the SAME instance
    (e.g. an ACTIVE campaign re-captured daily until it completes) and converges rather
    than double-counting -- counters are DERIVED from the day-keyed stateLog, and dates
    come from the campaign InstanceDate, never the processing date.

    Functions:
      Read-SPEntitlementState        -- load JSONL into StateMap hashtable
      Update-SPEntitlementState      -- process resolved items through the state machine
      Invoke-SPEntitlementScopeSweep -- scope detection + retention pruning (orchestrator-called)
      Write-SPEntitlementState       -- atomic write (unique tmp + File.Replace under mutex)

    Version: 1.1.0
#>

Set-StrictMode -Version 1

#region Internal helpers

function ConvertFrom-PSOToHashtable {
    <#
    .SYNOPSIS
        Recursively converts PSCustomObject (from ConvertFrom-Json) to hashtable.
        Primitives, arrays, and $null pass through unchanged.
    #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [hashtable]) {
        $ht = @{}
        foreach ($k in $InputObject.Keys) { $ht[$k] = ConvertFrom-PSOToHashtable $InputObject[$k] }
        return $ht
    }
    if ($InputObject -is [PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $ht[$prop.Name] = ConvertFrom-PSOToHashtable $prop.Value
        }
        return $ht
    }
    if ($InputObject -is [System.Collections.IList]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) { $list.Add((ConvertFrom-PSOToHashtable $item)) }
        return @($list)
    }
    return $InputObject
}

function ConvertTo-SPStateDate {
    <#
    .SYNOPSIS
        Invariant-culture yyyy-MM-dd parse. Returns $null (never throws) on failure.
        All state-file dates are ISO strings; the ambient culture must never be involved.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParseExact($Value, 'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
        return $dt
    }
    # Tolerate full ISO timestamps (roundtrip) as a fallback.
    if ([datetime]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$dt)) {
        return $dt
    }
    return $null
}

function ConvertTo-SPEntitlementStateCode {
    <#
    .SYNOPSIS
        Maps HonestDecision + IsAutoApproved to a four-value state code.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$HonestDecision,
        [bool]$IsAutoApproved
    )
    switch ($HonestDecision) {
        'Approved'  { return 'APPROVE' }
        'Revoked'   { return 'REVOKE' }
        'Undecided' {
            if ($IsAutoApproved) { return 'UNDECIDED' }
            else                { return 'PENDING' }
        }
        default     { return 'PENDING' }
    }
}

function Update-StateLogEntry {
    <#
    .SYNOPSIS
        Adds or updates a stateLog entry for a given day. Returns the updated
        stateLog string and whether a change occurred (for idempotency).
    .DESCRIPTION
        stateLog format: {Code}:{yyyyMMdd}|{Code}:{yyyyMMdd} sorted ascending by day.
        Codes: A=APPROVE, R=REVOKE, P=PENDING, U=UNDECIDED.
        Day keys carry the YEAR: the earlier MMdd format silently overwrote the same
        calendar day from a prior year and sorted Dec/Jan transitions backwards.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$StateLog,
        [string]$DayKey,      # yyyyMMdd
        [string]$StateCode    # APPROVE, REVOKE, PENDING, UNDECIDED
    )

    $abbrev = switch ($StateCode) {
        'APPROVE'   { 'A' }
        'REVOKE'    { 'R' }
        'PENDING'   { 'P' }
        'UNDECIDED' { 'U' }
        default     { 'P' }
    }

    # Parse existing entries: dayKey -> abbreviation. Accepts only the yyyyMMdd form
    # (X:20260625, length 10); the state files shipped broken before v1.1, so there is
    # no legacy MMdd data to migrate.
    $entries = @{}
    if (-not [string]::IsNullOrWhiteSpace($StateLog)) {
        foreach ($part in $StateLog.Split('|')) {
            if ($part.Length -ge 10 -and $part[1] -eq ':') {
                $entries[$part.Substring(2)] = [string]$part[0]
            }
        }
    }

    $changed = $false
    if ($entries.ContainsKey($DayKey)) {
        if ([string]$entries[$DayKey] -ne $abbrev) {
            $entries[$DayKey] = $abbrev
            $changed = $true
        }
    }
    else {
        $entries[$DayKey] = $abbrev
        $changed = $true
    }

    # Rebuild sorted by day (lexical == chronological for yyyyMMdd). Cap the log at the
    # newest 400 entries (~18 months of workdays) so records never grow unboundedly.
    $sortedKeys = @($entries.Keys | Sort-Object)
    if ($sortedKeys.Count -gt 400) {
        $sortedKeys = @($sortedKeys | Select-Object -Last 400)
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $sortedKeys) {
        $parts.Add("$($entries[$k]):${k}")
    }

    return @{
        StateLog = $parts -join '|'
        Changed  = $changed
    }
}

function Get-SPTrailingUnreviewedCount {
    <#
    .SYNOPSIS
        Derives the consecutive-unreviewed counter from the stateLog: the length of the
        TRAILING run of P/U day entries. Derived (not incremented) so reprocessing the
        same instance -- normal for ACTIVE campaigns re-captured daily -- can never
        double-count, and a decision anywhere resets it naturally.
    #>
    param([string]$StateLog)
    if ([string]::IsNullOrWhiteSpace($StateLog)) { return 0 }
    $count = 0
    $parts = $StateLog.Split('|')
    for ($i = $parts.Count - 1; $i -ge 0; $i--) {
        $p = $parts[$i]
        if ($p.Length -lt 3) { continue }
        if ($p[0] -eq 'P' -or $p[0] -eq 'U') { $count++ } else { break }
    }
    return $count
}

#endregion

#region Public: Read

function Read-SPEntitlementState {
    <#
    .SYNOPSIS
        Reads entitlement-state.jsonl into a StateMap hashtable keyed by itemKey.
    .DESCRIPTION
        The first line with "_meta":true is metadata (processedInstances, lastRunDate).
        All other lines are data records keyed by their itemKey property.

        Corrupt lines are counted in SkippedLines (never silently discarded): callers
        must treat Exists + RecordCount 0 + SkippedLines > 0 as a CORRUPT file and
        refuse to overwrite it, otherwise months of history reset silently.
    .PARAMETER Path
        Full path to the entitlement-state.jsonl file.
    .OUTPUTS
        Hashtable: StateMap, ProcessedInstances, RecordCount, Exists, LastRunDate, SkippedLines.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stateMap = @{}
    $processedInstances = @{}
    $lastRunDate = ''
    $skipped = 0
    $exists = Test-Path $Path

    if ($exists) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        foreach ($ln in [System.IO.File]::ReadAllLines($Path, $utf8)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try {
                $pso = $ln | ConvertFrom-Json
                $rec = ConvertFrom-PSOToHashtable $pso
                if ($null -eq $rec -or $rec -isnot [hashtable]) { $skipped++; continue }
                # Check for metadata line
                if ($rec.ContainsKey('_meta') -and $rec['_meta'] -eq $true) {
                    if ($rec.ContainsKey('processedInstances') -and $null -ne $rec['processedInstances']) {
                        $pi = $rec['processedInstances']
                        if ($pi -is [hashtable]) { $processedInstances = $pi }
                    }
                    if ($rec.ContainsKey('lastRunDate')) {
                        $lastRunDate = [string]$rec['lastRunDate']
                    }
                    continue
                }
                # Data record -- key by itemKey
                $key = [string]$rec['itemKey']
                if (-not [string]::IsNullOrWhiteSpace($key)) {
                    $stateMap[$key] = $rec
                }
                else { $skipped++ }
            }
            catch { $skipped++ }
        }
        if ($skipped -gt 0) {
            Write-Warning "Read-SPEntitlementState: skipped $skipped unparseable line(s) in $Path"
        }
    }

    return @{
        StateMap            = $stateMap
        ProcessedInstances  = $processedInstances
        RecordCount         = $stateMap.Count
        Exists              = $exists
        LastRunDate         = $lastRunDate
        SkippedLines        = $skipped
    }
}

#endregion

#region Public: Update

function Update-SPEntitlementState {
    <#
    .SYNOPSIS
        Processes ONE campaign instance's resolved items through the entitlement state machine.
    .DESCRIPTION
        For each resolved item (from Resolve-SPSeriesItemState):
          1. Maps HonestDecision to state code (APPROVE/REVOKE/PENDING/UNDECIDED)
          2. Creates new records or updates existing ones with state change tracking
          3. Detects newly-decided items (an OBSERVED transition PENDING/UNDECIDED ->
             APPROVE/REVOKE; an item first seen already decided is NOT newly decided --
             the decision may be months old)
          4. Detects re-approvals (an OBSERVED transition REVOKE -> APPROVE): access
             that was genuinely revoked and later genuinely re-approved -- the primary
             re-grant governance signal, kept separate from NewlyDecided

        All dates written to records come from -InstanceDate (the campaign's own day),
        NEVER the processing date -- a bootstrap over months of cache must not stamp
        every historical decision with today.

        Re-processing the same instance converges (ACTIVE campaigns are re-captured
        daily until they complete): day-keyed stateLog entries update in place, and
        consecutiveUndecided is DERIVED from the log's trailing P/U run.

        UNDECIDED->PENDING regression guard: if an existing record is UNDECIDED and the
        new input would set it to PENDING, the update is skipped because UNDECIDED is a
        more specific classification (campaign closed with auto-approval).

        Out-of-order guard: an instance OLDER than the record's lastSeenDate only merges
        its stateLog day entry; it never regresses currentDecision/lastSeenDate.

        SCOPE + PRUNING ARE NOT DONE HERE (v1.1 contract): a single instance only sees
        its own series' items, so marking everything else out-of-scope here corrupted
        cross-series state. Invoke-SPEntitlementScopeSweep (orchestrator-called) owns it.
    .PARAMETER StateMap
        Hashtable of existing entitlement state records (from Read-SPEntitlementState).
        Modified in-place.
    .PARAMETER ResolvedItems
        Array of PSCustomObjects from Resolve-SPSeriesItemState.
    .PARAMETER ProcessedInstances
        ACCEPTED FOR BACK-COMPAT, IGNORED: the orchestrator owns instance bookkeeping.
    .PARAMETER InstanceId
        Campaign instance identifier (recorded on NewlyDecided entries only).
    .PARAMETER InstanceDate
        The campaign instance's own date (yyyy-MM-dd). Drives every date written.
    .PARAMETER SeriesName
        The campaign series stem; stored on records so the scope sweep can compare a
        record only against ITS OWN series' newest instance.
    .PARAMETER TodayLabel
        Fallback date when InstanceDate is blank. Defaults to current date.
    .OUTPUTS
        Hashtable: NewlyDecided, ReApproved, StateSummary, StateNew, StateChanged, PriorSnapshot.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$StateMap,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ResolvedItems,

        [Parameter()]
        [hashtable]$ProcessedInstances = @{},

        [Parameter()]
        [string]$InstanceId = '',

        [Parameter()]
        [string]$InstanceDate = '',

        [Parameter()]
        [string]$SeriesName = '',

        [Parameter()]
        [string]$TodayLabel = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    )

    $newlyDecided = [System.Collections.Generic.List[object]]::new()
    $reApproved   = [System.Collections.Generic.List[object]]::new()
    $stateNew     = 0
    $stateChanged = 0

    # Effective instance day: the campaign's own date, never the processing date.
    $effDate = $InstanceDate
    if ([string]::IsNullOrWhiteSpace($effDate)) { $effDate = $TodayLabel }
    $effDt = ConvertTo-SPStateDate $effDate
    if ($null -eq $effDt) {
        $effDate = $TodayLabel
        $effDt = ConvertTo-SPStateDate $effDate
    }
    $dayKey = if ($null -ne $effDt) { $effDt.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture) }
              else { (Get-Date).ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture) }

    # 1. Snapshot prior state for change detection
    $priorSnapshot = @{}
    foreach ($key in @($StateMap.Keys)) {
        $priorSnapshot[$key] = [string]$StateMap[$key]['currentDecision']
    }

    # 2. Process each resolved item
    foreach ($item in @($ResolvedItems)) {
        if ($null -eq $item) { continue }

        $itemKey = [string]$item.ItemKey
        if ([string]::IsNullOrWhiteSpace($itemKey)) { continue }

        $honestDecision = [string]$item.HonestDecision
        $isAutoApproved = [bool]$item.IsAutoApproved

        $stateCode = ConvertTo-SPEntitlementStateCode -HonestDecision $honestDecision -IsAutoApproved $isAutoApproved

        if (-not $StateMap.ContainsKey($itemKey)) {
            # --- NEW record ---
            $initialLog = Update-StateLogEntry -StateLog '' -DayKey $dayKey -StateCode $stateCode

            $StateMap[$itemKey] = @{
                itemKey              = $itemKey
                identityId           = [string]$item.IdentityId
                identityName         = [string]$item.IdentityName
                accessName           = [string]$item.AccessName
                accessType           = [string]$item.AccessType
                sourceId             = [string]$item.SourceId
                sourceName           = [string]$item.SourceName
                seriesName           = [string]$SeriesName
                currentDecision      = $stateCode
                priorDecision        = ''
                isPrivileged         = $false
                inCurrentScope       = $true
                reviewerName         = [string]$item.ReviewerName
                firstSeenDate        = $effDate
                lastStateChangeDate  = $effDate
                lastSeenDate         = $effDate
                consecutiveUndecided = (Get-SPTrailingUnreviewedCount -StateLog ([string]$initialLog.StateLog))
                stateLog             = [string]$initialLog.StateLog
            }
            $stateNew++
        }
        else {
            # --- EXISTING record ---
            $rec = $StateMap[$itemKey]
            $currentState = [string]$rec['currentDecision']

            # Keep the earliest firstSeenDate honest under out-of-order backfills.
            $recFirst = [string]$rec['firstSeenDate']
            if ([string]::IsNullOrWhiteSpace($recFirst) -or ($effDate -lt $recFirst)) {
                $rec['firstSeenDate'] = $effDate
            }
            if (-not [string]::IsNullOrWhiteSpace($SeriesName)) { $rec['seriesName'] = [string]$SeriesName }

            # Out-of-order guard: an instance OLDER than what this record has already
            # seen contributes only its stateLog day entry (historical backfill) and
            # must not regress the current state. ISO strings compare lexically.
            $recLastSeen = [string]$rec['lastSeenDate']
            if (-not [string]::IsNullOrWhiteSpace($recLastSeen) -and ($effDate -lt $recLastSeen)) {
                $logResult = Update-StateLogEntry -StateLog ([string]$rec['stateLog']) -DayKey $dayKey -StateCode $stateCode
                $rec['stateLog'] = [string]$logResult.StateLog
                $rec['consecutiveUndecided'] = Get-SPTrailingUnreviewedCount -StateLog ([string]$rec['stateLog'])
                continue
            }

            if ($currentState -ne $stateCode) {
                # UNDECIDED->PENDING regression guard: skip -- UNDECIDED is more specific
                if ($currentState -eq 'UNDECIDED' -and $stateCode -eq 'PENDING') {
                    $rec['lastSeenDate']   = $effDate
                    $rec['inCurrentScope'] = $true
                    if (-not [string]::IsNullOrWhiteSpace([string]$item.ReviewerName)) {
                        $rec['reviewerName'] = [string]$item.ReviewerName
                    }
                    continue
                }

                # State changed. Capture the prior change date BEFORE it is overwritten:
                # for a REVOKE -> APPROVE transition it is the day the item became REVOKE,
                # which the re-approval entry reports as the revocation day.
                $priorChangeDate = [string]$rec['lastStateChangeDate']
                $logResult = Update-StateLogEntry -StateLog ([string]$rec['stateLog']) -DayKey $dayKey -StateCode $stateCode
                $rec['priorDecision']       = $currentState
                $rec['currentDecision']     = $stateCode
                $rec['lastStateChangeDate'] = $effDate
                $rec['lastSeenDate']        = $effDate
                $rec['inCurrentScope']      = $true
                $rec['stateLog']            = [string]$logResult.StateLog
                $rec['consecutiveUndecided'] = Get-SPTrailingUnreviewedCount -StateLog ([string]$rec['stateLog'])

                if (-not [string]::IsNullOrWhiteSpace([string]$item.ReviewerName)) {
                    $rec['reviewerName'] = [string]$item.ReviewerName
                }

                # Detect newly decided: an OBSERVED transition from PENDING/UNDECIDED
                # to APPROVE/REVOKE. DecisionDate = the campaign's day, never today.
                if ($currentState -in @('PENDING', 'UNDECIDED') -and $stateCode -in @('APPROVE', 'REVOKE')) {
                    $newlyDecided.Add(@{
                        ItemKey       = $itemKey
                        IdentityName  = [string]$rec['identityName']
                        AccessName    = [string]$rec['accessName']
                        SourceName    = [string]$rec['sourceName']
                        PriorState    = $currentState
                        NewState      = $stateCode
                        ReviewerName  = [string]$rec['reviewerName']
                        DecisionDate  = $effDate
                        InstanceId    = [string]$InstanceId
                    })
                }

                # Detect re-approval: an OBSERVED REVOKE -> APPROVE transition. Access that
                # was genuinely revoked and later genuinely re-approved is the re-grant
                # governance signal ("revoked then re-approved later in the campaign
                # period"); routine first decisions never land here. ReviewerName is the
                # re-approver (already refreshed from the current item above).
                if ($currentState -eq 'REVOKE' -and $stateCode -eq 'APPROVE') {
                    $reApproved.Add(@{
                        ItemKey        = $itemKey
                        IdentityName   = [string]$rec['identityName']
                        AccessName     = [string]$rec['accessName']
                        SourceName     = [string]$rec['sourceName']
                        RevokedDate    = $priorChangeDate
                        ReApprovedDate = $effDate
                        ReviewerName   = [string]$rec['reviewerName']
                        InstanceId     = [string]$InstanceId
                    })
                }

                $stateChanged++
            }
            else {
                # Same state -- refresh metadata + day entry (idempotent re-processing).
                $logResult = Update-StateLogEntry -StateLog ([string]$rec['stateLog']) -DayKey $dayKey -StateCode $stateCode
                $rec['stateLog']       = [string]$logResult.StateLog
                $rec['lastSeenDate']   = $effDate
                $rec['inCurrentScope'] = $true
                $rec['consecutiveUndecided'] = Get-SPTrailingUnreviewedCount -StateLog ([string]$rec['stateLog'])
                if (-not [string]::IsNullOrWhiteSpace([string]$item.ReviewerName)) {
                    $rec['reviewerName'] = [string]$item.ReviewerName
                }
            }
        }
    }

    # 3. Compute StateSummary (count in-scope items by currentDecision)
    $stateSummary = @{ APPROVE = 0; REVOKE = 0; PENDING = 0; UNDECIDED = 0 }
    foreach ($key in @($StateMap.Keys)) {
        $rec = $StateMap[$key]
        $inScope = $true
        if ($rec.ContainsKey('inCurrentScope')) {
            $inScope = [bool]$rec['inCurrentScope']
        }
        if ($inScope) {
            $dec = [string]$rec['currentDecision']
            if ($stateSummary.ContainsKey($dec)) {
                $stateSummary[$dec] = [int]$stateSummary[$dec] + 1
            }
        }
    }

    return @{
        NewlyDecided       = $newlyDecided
        ReApproved         = $reApproved
        DroppedFromScope   = [System.Collections.Generic.List[object]]::new()   # v1.1: scope moved to Invoke-SPEntitlementScopeSweep
        StateSummary       = $stateSummary
        StateNew           = $stateNew
        StateChanged       = $stateChanged
        PriorSnapshot      = $priorSnapshot
        ProcessedInstances = $ProcessedInstances
    }
}

function Invoke-SPEntitlementScopeSweep {
    <#
    .SYNOPSIS
        Scope detection + retention pruning across the whole StateMap. Orchestrator-called
        ONCE per run, after all instances have been processed.
    .DESCRIPTION
        A record is OUT OF SCOPE when its own series has a processed instance NEWER than
        the record's lastSeenDate -- i.e. the grant was absent from its series' newest
        campaign (revoked upstream, or moved). Records whose series has no known newest
        date (or that carry no seriesName) are left untouched: absence of evidence is not
        evidence of absence. This makes the sweep IDEMPOTENT -- a same-day rerun that
        processed zero new instances changes nothing (the earlier implementation flipped
        EVERY record out of scope on rerun because it only trusted keys seen in that run).

        Retention: records that have been out of scope for more than RetentionDays
        (by lastSeenDate) are removed.
    .PARAMETER StateMap
        The state map. Modified in-place.
    .PARAMETER SeriesNewestDates
        Hashtable: seriesName -> newest processed instance date (yyyy-MM-dd) across ALL
        runs (derived from processedInstances metadata, not just this run).
    .PARAMETER TodayLabel
        Today's date (yyyy-MM-dd) for the retention cutoff.
    .PARAMETER RetentionDays
        Days to retain out-of-scope records. Default 90.
    .OUTPUTS
        Hashtable: DroppedFromScope (records newly true->false), PrunedCount.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$StateMap,

        [Parameter()]
        [hashtable]$SeriesNewestDates = @{},

        [Parameter()]
        [string]$TodayLabel = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture),

        [Parameter()]
        [int]$RetentionDays = 90
    )

    $dropped = [System.Collections.Generic.List[object]]::new()
    $cutoff = $null
    $todayDt = ConvertTo-SPStateDate $TodayLabel
    if ($null -ne $todayDt) { $cutoff = $todayDt.AddDays(-$RetentionDays) }

    $keysToRemove = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @($StateMap.Keys)) {
        $rec = $StateMap[$key]
        $series = ''
        if ($rec.ContainsKey('seriesName')) { $series = [string]$rec['seriesName'] }

        $newest = ''
        if (-not [string]::IsNullOrWhiteSpace($series) -and $SeriesNewestDates.ContainsKey($series)) {
            $newest = [string]$SeriesNewestDates[$series]
        }

        if (-not [string]::IsNullOrWhiteSpace($newest)) {
            $lastSeen = [string]$rec['lastSeenDate']
            # ISO strings compare lexically. Absent from the series' newest instance
            # => out of scope; present in it (lastSeen == newest) => in scope.
            if (-not [string]::IsNullOrWhiteSpace($lastSeen) -and ($lastSeen -lt $newest)) {
                $wasInScope = $true
                if ($rec.ContainsKey('inCurrentScope')) { $wasInScope = [bool]$rec['inCurrentScope'] }
                $rec['inCurrentScope'] = $false
                if ($wasInScope) {
                    $dropped.Add(@{
                        ItemKey      = $key
                        IdentityName = [string]$rec['identityName']
                        AccessName   = [string]$rec['accessName']
                        SourceName   = [string]$rec['sourceName']
                        LastState    = [string]$rec['currentDecision']
                        LastSeenDate = $lastSeen
                    })
                }
            }
            else {
                $rec['inCurrentScope'] = $true
            }
        }

        # Retention pruning: only ever removes records already out of scope.
        $inScopeNow = $true
        if ($rec.ContainsKey('inCurrentScope')) { $inScopeNow = [bool]$rec['inCurrentScope'] }
        if (-not $inScopeNow -and $null -ne $cutoff) {
            $lastSeenDt = ConvertTo-SPStateDate ([string]$rec['lastSeenDate'])
            if ($null -ne $lastSeenDt -and $lastSeenDt -lt $cutoff) {
                $keysToRemove.Add($key)
            }
        }
    }

    foreach ($key in $keysToRemove) {
        $StateMap.Remove($key)
    }

    return @{
        DroppedFromScope = $dropped
        PrunedCount      = $keysToRemove.Count
    }
}

#endregion

#region Public: Write

function Write-SPEntitlementState {
    <#
    .SYNOPSIS
        Atomically writes the entitlement state map to a JSONL file.
    .DESCRIPTION
        Writes a _meta line first (processedInstances, lastRunDate), then data records
        sorted by itemKey. Durable write discipline (mirrors SP.IdentityService):
          * a NAMED MUTEX serializes writers across processes (scheduled task + V8
            auto-refresh must not race);
          * content goes to a UNIQUE temp file (per-PID) then swaps in via
            [System.IO.File]::Replace (atomic on NTFS) -- there is never a moment
            without a state file, unlike the old delete-then-rename.
    .PARAMETER StateMap
        Hashtable of entitlement state records to write.
    .PARAMETER Path
        Full path to the entitlement-state.jsonl file.
    .PARAMETER ProcessedInstances
        Hashtable of processed campaign instance IDs and their metadata.
    .PARAMETER LastRunDate
        Date string for the last run. Defaults to current date.
    .OUTPUTS
        Hashtable with keys: Success (bool), RecordsWritten (int), Error (string).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$StateMap,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [hashtable]$ProcessedInstances = @{},

        [Parameter()]
        [string]$LastRunDate = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    )

    $mutex = $null
    $tmpFile = "${Path}.${PID}.tmp"
    try {
        $mutexName = 'Global\SPGovToolkit_State_' + (($Path -replace '[\\/:]', '_') -replace '[^A-Za-z0-9_.-]', '')
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        try { [void]$mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { }

        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $tmpFile  = [System.IO.Path]::GetFullPath($tmpFile)

        $parentDir = Split-Path $fullPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $lines = [System.Collections.Generic.List[string]]::new()

        # Meta line first
        $meta = @{
            _meta              = $true
            processedInstances = $ProcessedInstances
            lastRunDate        = $LastRunDate
        }
        $lines.Add(($meta | ConvertTo-Json -Depth 4 -Compress))

        # Data records sorted by itemKey
        foreach ($key in ($StateMap.Keys | Sort-Object)) {
            $lines.Add(($StateMap[$key] | ConvertTo-Json -Depth 4 -Compress))
        }

        [System.IO.File]::WriteAllLines($tmpFile, $lines.ToArray(), $utf8NoBom)

        if (Test-Path $fullPath) {
            # [NullString]::Value, not $null: PowerShell binds $null to a .NET string
            # parameter as '' and File.Replace rejects an empty backup path.
            [System.IO.File]::Replace($tmpFile, $fullPath, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($tmpFile, $fullPath)
        }

        return @{
            Success        = $true
            RecordsWritten = $StateMap.Count
            Error          = ''
        }
    }
    catch {
        try { if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue } } catch { }
        return @{
            Success        = $false
            RecordsWritten = 0
            Error          = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch { }
            $mutex.Dispose()
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Read-SPEntitlementState',
    'Update-SPEntitlementState',
    'Invoke-SPEntitlementScopeSweep',
    'Write-SPEntitlementState',
    'ConvertTo-SPEntitlementStateCode',
    'Update-StateLogEntry',
    'Get-SPTrailingUnreviewedCount'
)

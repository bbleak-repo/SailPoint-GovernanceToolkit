<#
.SYNOPSIS
    SP.EntitlementState -- persistent per-entitlement state tracking across campaigns.
.DESCRIPTION
    Maintains a JSONL key-value store that tracks honest decision state per
    IdentityId|AccessId|SourceId combination. Uses SP.CampaignSeries output
    (Resolve-SPSeriesItemState) as input. Supersedes the June 2026 stub.

    State codes:
      APPROVE   -- genuine reviewer approval
      REVOKE    -- genuine reviewer revocation
      PENDING   -- no decision yet (campaign still active, or item untouched)
      UNDECIDED -- campaign closed, item was auto-approved (never genuinely reviewed)

    Functions:
      Read-SPEntitlementState    -- load JSONL into StateMap hashtable
      Update-SPEntitlementState  -- process resolved items through state machine
      Write-SPEntitlementState   -- atomic write (tmp + rename)

    Version: 1.0.0
#>

#region Internal helpers

function ConvertFrom-PSOToHashtable {
    <#
    .SYNOPSIS
        Recursively converts PSCustomObject (from ConvertFrom-Json) to hashtable.
        Primitives and arrays pass through unchanged.
    #>
    param($InputObject)
    if ($null -eq $InputObject) { return @{} }
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
        Adds or updates a stateLog entry for a given MMDD. Returns the updated
        stateLog string and whether a change occurred (for idempotency).
    .DESCRIPTION
        stateLog format: {StateCode}:{MMDD}|{StateCode}:{MMDD}
        StateCode abbreviations: A=APPROVE, R=REVOKE, P=PENDING, U=UNDECIDED
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$StateLog,
        [string]$Mmdd,
        [string]$StateCode  # APPROVE, REVOKE, PENDING, UNDECIDED
    )

    # Map state code to single-char abbreviation
    $abbrev = switch ($StateCode) {
        'APPROVE'   { 'A' }
        'REVOKE'    { 'R' }
        'PENDING'   { 'P' }
        'UNDECIDED' { 'U' }
        default     { 'P' }
    }

    # Parse existing entries into hashtable: MMDD -> abbreviation
    $entries = @{}
    if (-not [string]::IsNullOrWhiteSpace($StateLog)) {
        foreach ($part in $StateLog.Split('|')) {
            if ($part.Length -ge 6 -and $part[1] -eq ':') {
                $entries[$part.Substring(2)] = [string]$part[0]
            }
        }
    }

    $changed = $false
    if ($entries.ContainsKey($Mmdd)) {
        if ([string]$entries[$Mmdd] -ne $abbrev) {
            $entries[$Mmdd] = $abbrev
            $changed = $true
        }
    }
    else {
        $entries[$Mmdd] = $abbrev
        $changed = $true
    }

    # Rebuild sorted by MMDD for chronological order
    $sortedKeys = @($entries.Keys | Sort-Object)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $sortedKeys) {
        $parts.Add("$($entries[$k]):${k}")
    }

    return @{
        StateLog = $parts -join '|'
        Changed  = $changed
    }
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
    .PARAMETER Path
        Full path to the entitlement-state.jsonl file.
    .OUTPUTS
        Hashtable with keys: StateMap, ProcessedInstances, RecordCount, Exists, LastRunDate.
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
    $exists = Test-Path $Path

    if ($exists) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        foreach ($ln in [System.IO.File]::ReadAllLines($Path, $utf8)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try {
                $pso = $ln | ConvertFrom-Json
                $rec = ConvertFrom-PSOToHashtable $pso
                # Check for metadata line
                if ($rec.ContainsKey('_meta') -and $rec['_meta'] -eq $true) {
                    if ($rec.ContainsKey('processedInstances') -and $null -ne $rec['processedInstances']) {
                        $processedInstances = $rec['processedInstances']
                        if ($processedInstances -isnot [hashtable]) {
                            $processedInstances = ConvertFrom-PSOToHashtable $processedInstances
                        }
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
            }
            catch { }
        }
    }

    return @{
        StateMap            = $stateMap
        ProcessedInstances  = $processedInstances
        RecordCount         = $stateMap.Count
        Exists              = $exists
        LastRunDate         = $lastRunDate
    }
}

#endregion

#region Public: Update

function Update-SPEntitlementState {
    <#
    .SYNOPSIS
        Processes resolved items through the entitlement state machine.
    .DESCRIPTION
        For each resolved item (from Resolve-SPSeriesItemState):
          1. Maps HonestDecision to state code (APPROVE/REVOKE/PENDING/UNDECIDED)
          2. Creates new records or updates existing ones with state change tracking
          3. Detects newly-decided items (PENDING/UNDECIDED -> APPROVE/REVOKE)
          4. Marks items no longer in scope and prunes old dropped records

        UNDECIDED->PENDING regression guard: if an existing record is UNDECIDED and
        the new input would set it to PENDING, the update is skipped because UNDECIDED
        is a more specific classification (campaign closed with auto-approval).
    .PARAMETER StateMap
        Hashtable of existing entitlement state records (from Read-SPEntitlementState).
        Modified in-place.
    .PARAMETER ResolvedItems
        Array of PSCustomObjects from Resolve-SPSeriesItemState.
    .PARAMETER ProcessedInstances
        Hashtable tracking which campaign instances have been processed. Modified in-place.
    .PARAMETER InstanceId
        Campaign instance identifier to mark as processed.
    .PARAMETER InstanceDate
        Date string for the campaign instance being processed.
    .PARAMETER TodayLabel
        Today's date as yyyy-MM-dd string. Defaults to current date.
    .PARAMETER RetentionDays
        How many days to retain out-of-scope records before pruning. Default 90.
    .OUTPUTS
        Hashtable with keys: NewlyDecided, DroppedFromScope, StateSummary,
        StateNew, StateChanged, PriorSnapshot, ProcessedInstances.
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
        [string]$TodayLabel = (Get-Date).ToString('yyyy-MM-dd'),

        [Parameter()]
        [int]$RetentionDays = 90
    )

    $newlyDecided     = [System.Collections.Generic.List[object]]::new()
    $droppedFromScope = [System.Collections.Generic.List[object]]::new()
    $stateNew     = 0
    $stateChanged = 0

    # 1. Snapshot prior state for change detection
    $priorSnapshot = @{}
    foreach ($key in @($StateMap.Keys)) {
        $priorSnapshot[$key] = [string]$StateMap[$key]['currentDecision']
    }

    # 2. Track seen keys for scope detection
    $seenKeys = @{}

    # Derive MMDD for stateLog from TodayLabel
    $logMmdd = ''
    try {
        $logMmdd = ([datetime]::Parse($TodayLabel)).ToString('MMdd')
    }
    catch {
        $logMmdd = (Get-Date).ToString('MMdd')
    }

    # 3. Process each resolved item
    foreach ($item in @($ResolvedItems)) {
        if ($null -eq $item) { continue }

        # Read properties from PSCustomObject
        $itemKey = [string]$item.ItemKey
        if ([string]::IsNullOrWhiteSpace($itemKey)) { continue }

        $honestDecision = [string]$item.HonestDecision
        $isAutoApproved = [bool]$item.IsAutoApproved
        $isGenuine      = [bool]$item.IsGenuineDecision

        # Map to state code
        $stateCode = ConvertTo-SPEntitlementStateCode -HonestDecision $honestDecision -IsAutoApproved $isAutoApproved

        $seenKeys[$itemKey] = $true

        if (-not $StateMap.ContainsKey($itemKey)) {
            # --- NEW record ---
            $initialLog = Update-StateLogEntry -StateLog '' -Mmdd $logMmdd -StateCode $stateCode

            $StateMap[$itemKey] = @{
                itemKey              = $itemKey
                identityId           = [string]$item.IdentityId
                identityName         = [string]$item.IdentityName
                accessName           = [string]$item.AccessName
                accessType           = [string]$item.AccessType
                sourceId             = [string]$item.SourceId
                sourceName           = [string]$item.SourceName
                currentDecision      = $stateCode
                priorDecision        = ''
                isPrivileged         = $false
                inCurrentScope       = $true
                reviewerName         = [string]$item.ReviewerName
                firstSeenDate        = $TodayLabel
                lastStateChangeDate  = $TodayLabel
                lastSeenDate         = $TodayLabel
                consecutiveUndecided = $(if ($stateCode -eq 'UNDECIDED') { 1 } else { 0 })
                stateLog             = [string]$initialLog.StateLog
            }
            $stateNew++
        }
        else {
            # --- EXISTING record ---
            $rec = $StateMap[$itemKey]
            $currentState = [string]$rec['currentDecision']

            if ($currentState -ne $stateCode) {
                # UNDECIDED->PENDING regression guard: skip -- UNDECIDED is more specific
                if ($currentState -eq 'UNDECIDED' -and $stateCode -eq 'PENDING') {
                    # Update metadata only (lastSeenDate, reviewer) without changing state
                    $rec['lastSeenDate']   = $TodayLabel
                    $rec['inCurrentScope'] = $true
                    if (-not [string]::IsNullOrWhiteSpace([string]$item.ReviewerName)) {
                        $rec['reviewerName'] = [string]$item.ReviewerName
                    }
                    # Still track consecutiveUndecided (not incrementing since we are skipping)
                    continue
                }

                # State changed
                $logResult = Update-StateLogEntry -StateLog ([string]$rec['stateLog']) -Mmdd $logMmdd -StateCode $stateCode
                $rec['priorDecision']       = $currentState
                $rec['currentDecision']     = $stateCode
                $rec['lastStateChangeDate'] = $TodayLabel
                $rec['lastSeenDate']        = $TodayLabel
                $rec['inCurrentScope']      = $true
                $rec['stateLog']            = [string]$logResult.StateLog

                if (-not [string]::IsNullOrWhiteSpace([string]$item.ReviewerName)) {
                    $rec['reviewerName'] = [string]$item.ReviewerName
                }

                # Track consecutiveUndecided
                if ($stateCode -eq 'UNDECIDED') {
                    $rec['consecutiveUndecided'] = [int]$rec['consecutiveUndecided'] + 1
                }
                else {
                    $rec['consecutiveUndecided'] = 0
                }

                # Detect newly decided: prior was PENDING/UNDECIDED, new is APPROVE/REVOKE
                if ($currentState -in @('PENDING', 'UNDECIDED') -and $stateCode -in @('APPROVE', 'REVOKE')) {
                    $newlyDecided.Add(@{
                        ItemKey       = $itemKey
                        IdentityName  = [string]$rec['identityName']
                        AccessName    = [string]$rec['accessName']
                        SourceName    = [string]$rec['sourceName']
                        PriorState    = $currentState
                        NewState      = $stateCode
                        ReviewerName  = [string]$rec['reviewerName']
                        DecisionDate  = $TodayLabel
                    })
                }

                $stateChanged++
            }
            else {
                # Same state -- update metadata only
                $rec['lastSeenDate']   = $TodayLabel
                $rec['inCurrentScope'] = $true
                if (-not [string]::IsNullOrWhiteSpace([string]$item.ReviewerName)) {
                    $rec['reviewerName'] = [string]$item.ReviewerName
                }

                # consecutiveUndecided: increment if still UNDECIDED, no change otherwise
                if ($stateCode -eq 'UNDECIDED') {
                    $rec['consecutiveUndecided'] = [int]$rec['consecutiveUndecided'] + 1
                }
            }
        }
    }

    # 4. Mark unseen keys as out of scope
    $cutoffDate = $null
    try {
        $cutoffDate = ([datetime]::Parse($TodayLabel)).AddDays(-$RetentionDays)
    }
    catch { }

    $keysToRemove = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @($StateMap.Keys)) {
        if (-not $seenKeys.ContainsKey($key)) {
            $rec = $StateMap[$key]
            $wasInScope = $true
            if ($rec.ContainsKey('inCurrentScope')) {
                $wasInScope = [bool]$rec['inCurrentScope']
            }

            $rec['inCurrentScope'] = $false

            # Newly dropped from scope (was in scope before this run)
            if ($wasInScope) {
                $droppedFromScope.Add(@{
                    ItemKey      = $key
                    IdentityName = [string]$rec['identityName']
                    AccessName   = [string]$rec['accessName']
                    SourceName   = [string]$rec['sourceName']
                    LastState    = [string]$rec['currentDecision']
                    LastSeenDate = [string]$rec['lastSeenDate']
                })
            }

            # 5. Prune dropped records older than RetentionDays
            if ($null -ne $cutoffDate -and $rec.ContainsKey('lastSeenDate')) {
                $lastSeen = $null
                try { $lastSeen = [datetime]::Parse([string]$rec['lastSeenDate']) } catch { }
                if ($null -ne $lastSeen -and $lastSeen -lt $cutoffDate) {
                    $keysToRemove.Add($key)
                }
            }
        }
    }

    foreach ($key in $keysToRemove) {
        $StateMap.Remove($key)
    }

    # 6. Mark InstanceId in ProcessedInstances
    if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
        $ProcessedInstances[$InstanceId] = @{
            processedDate = $TodayLabel
            instanceDate  = $InstanceDate
        }
    }

    # 7. Compute StateSummary (count in-scope items by currentDecision)
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
        DroppedFromScope   = $droppedFromScope
        StateSummary       = $stateSummary
        StateNew           = $stateNew
        StateChanged       = $stateChanged
        PriorSnapshot      = $priorSnapshot
        ProcessedInstances = $ProcessedInstances
    }
}

#endregion

#region Public: Write

function Write-SPEntitlementState {
    <#
    .SYNOPSIS
        Atomically writes the entitlement state map to a JSONL file.
    .DESCRIPTION
        Writes a _meta line first (processedInstances, lastRunDate), then data
        records sorted by itemKey. Uses atomic write: write to .tmp, then rename.
    .PARAMETER StateMap
        Hashtable of entitlement state records to write.
    .PARAMETER Path
        Full path to the entitlement-state.jsonl file.
    .PARAMETER ProcessedInstances
        Hashtable of processed campaign instance IDs and their dates.
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
        [string]$LastRunDate = (Get-Date).ToString('yyyy-MM-dd')
    )

    try {
        $tmpFile = "${Path}.tmp"
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

        if (Test-Path $Path) { Remove-Item $Path -Force }
        Rename-Item $tmpFile (Split-Path $Path -Leaf)

        return @{
            Success        = $true
            RecordsWritten = $StateMap.Count
            Error          = ''
        }
    }
    catch {
        return @{
            Success        = $false
            RecordsWritten = 0
            Error          = $_.Exception.Message
        }
    }
}

#endregion

<#
.SYNOPSIS
    SP.ReviewerState -- persistent per-reviewer engagement tracking across campaigns.

.DESCRIPTION
    Maintains a JSONL key-value store (reviewer-state.jsonl) that records reviewer
    engagement state per campaign series across daily/weekly/quarterly campaigns.
    Uses SP.CampaignSeries resolved items as input.

    Enables compliance accountability questions that daily-metrics.jsonl cannot answer:

      "Does this reviewer always miss Fridays?"
      "Did they miss 2+ days this week?"
      "Do they complete Daily Attestation but ignore SOX reviews?"
      "Are they trending better or worse?"

    Engagement states per campaign day:
      C = Completed  (all items decided)
      P = Partial    (some items decided, not all)
      M = Missed     (campaign existed, reviewer made 0 decisions)
      U = Undecided  (campaign force-closed, reviewer's items auto-approved)

    DOCTRINE: absence is not inaction -- a reviewer simply not present in an instance's
    resolved items gets NO day entry (nothing to attest). Phase/'SIGNED' is never read;
    states derive from the honest classifier's IsGenuineDecision / IsAutoApproved.

    CONTRACT (v2.1):
      * Records key on STABLE identity ('id:<ReviewerId>' else 'nm:<name>') -- a display
        name change (marriage, AD cleanup) must not fork a reviewer's history, and two
        reviewers sharing a name must not merge.
      * Day entries key on yyyyMMdd (year included) -- the earlier MMdd format silently
        overwrote the same calendar day from a prior year.
      * campaignsObserved / weeklyStats / streaks / engagement are DERIVED from the
        day-keyed dayLog on every update, so re-processing an instance -- normal for
        ACTIVE campaigns re-captured daily until they complete -- converges instead of
        double-counting, and a day that upgrades M->P->C settles at its final state.
      * The ORCHESTRATOR owns processedInstances; this module neither guards nor marks.

    Functions:
      Read-SPReviewerState     -- load JSONL into hashtable
      Update-SPReviewerState   -- process resolved items through state machine
      Write-SPReviewerState    -- atomic write (unique tmp + File.Replace under mutex)
      Get-SPCampaignSeriesName -- extract series from campaign name (backward compat)

    Version: 2.1.0
#>

Set-StrictMode -Version 1

#region Internal helpers

function Get-SPIsoWeekString {
    <#
    .SYNOPSIS
        True ISO-8601 week label (yyyy-Www) via the Thursday rule: a date belongs to the
        ISO week/year of its week's Thursday. The naive GetWeekOfYear + month fix-ups
        mislabeled late-December days of ISO week 1 (e.g. Mon 2029-12-31 is 2030-W01).
    #>
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Date)
    # Monday=0 .. Sunday=6
    $dowMon0 = ([int]$Date.DayOfWeek + 6) % 7
    $thursday = $Date.Date.AddDays(3 - $dowMon0)
    $week = [int][math]::Floor(($thursday.DayOfYear - 1) / 7) + 1
    return '{0}-W{1:D2}' -f $thursday.Year, $week
}

function Update-DayLogEntry {
    <#
    .SYNOPSIS
        Adds or updates a dayLog entry. Format: {State}:{yyyyMMdd}|... sorted ascending.
        Lexical sort == chronological for yyyyMMdd. Capped at the newest 400 entries.
    #>
    [CmdletBinding()][OutputType([hashtable])]
    param([string]$DayLog, [string]$DayKey, [string]$State)
    $entries = @{}
    if (-not [string]::IsNullOrWhiteSpace($DayLog)) {
        foreach ($part in $DayLog.Split('|')) {
            if ($part.Length -ge 10 -and $part[1] -eq ':') {
                $entries[$part.Substring(2)] = [string]$part[0]
            }
        }
    }
    $changed = $false
    if ($entries.ContainsKey($DayKey)) {
        if ([string]$entries[$DayKey] -ne $State) { $entries[$DayKey] = $State; $changed = $true }
    } else { $entries[$DayKey] = $State; $changed = $true }
    $sortedKeys = @($entries.Keys | Sort-Object)
    if ($sortedKeys.Count -gt 400) { $sortedKeys = @($sortedKeys | Select-Object -Last 400) }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $sortedKeys) { $parts.Add("$($entries[$k]):${k}") }
    return @{ DayLog = $parts -join '|'; Changed = $changed }
}

function ConvertFrom-PSOToHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [hashtable]) {
        $ht = @{}; foreach ($k in $InputObject.Keys) { $ht[$k] = ConvertFrom-PSOToHashtable $InputObject[$k] }; return $ht
    }
    if ($InputObject -is [PSCustomObject]) {
        $ht = @{}; foreach ($prop in $InputObject.PSObject.Properties) { $ht[$prop.Name] = ConvertFrom-PSOToHashtable $prop.Value }; return $ht
    }
    return $InputObject
}

function Get-SPReviewerStateKey {
    <#
    .SYNOPSIS
        Stable reviewer identity key: 'id:<ReviewerId>' when present, else 'nm:<name>'.
        Same ladder as the toolkit's other reviewer-distinct computations.
    #>
    [CmdletBinding()][OutputType([string])]
    param([string]$ReviewerId, [string]$ReviewerName)
    if (-not [string]::IsNullOrWhiteSpace($ReviewerId)) { return 'id:' + $ReviewerId.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($ReviewerName)) { return 'nm:' + $ReviewerName.Trim() }
    return ''
}

function Get-SPStateItemProp {
    # Shape-tolerant property read (hashtable or PSCustomObject); missing -> $Default.
    param([object]$Item, [string]$Name, $Default = '')
    if ($null -eq $Item) { return $Default }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name) -and $null -ne $Item[$Name]) { return $Item[$Name] }
        return $Default
    }
    $p = $Item.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Update-SPReviewerSeriesDerivedStats {
    <#
    .SYNOPSIS
        Recomputes a series record's campaignsObserved/Completed/Missed, weeklyStats,
        and streaks FROM its dayLog (the single source of truth). Idempotent by
        construction: replaying or upgrading a day converges instead of double-counting,
        and streaks are date-ordered regardless of processing order.

        weeklyStats keeps only the newest 26 ISO weeks (state-growth cap).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$SeriesData)

    $dayLog = [string]$SeriesData['dayLog']
    $observed = 0; $completed = 0; $missed = 0
    $weekly = @{}
    $curStreak = 0; $longStreak = 0; $curMiss = 0; $longMiss = 0

    if (-not [string]::IsNullOrWhiteSpace($dayLog)) {
        foreach ($part in $dayLog.Split('|')) {
            if ($part.Length -lt 10 -or $part[1] -ne ':') { continue }
            $state = [string]$part[0]
            $dk = $part.Substring(2)
            $dt = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($dk, 'yyyyMMdd',
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { continue }

            $observed++
            $isoWeek = Get-SPIsoWeekString -Date $dt
            if (-not $weekly.ContainsKey($isoWeek)) {
                $weekly[$isoWeek] = @{ expected = 0; completed = 0; missed = 0; partials = 0 }
            }
            $ws = $weekly[$isoWeek]
            $ws['expected'] = [int]$ws['expected'] + 1

            switch ($state) {
                'C' {
                    $completed++
                    $ws['completed'] = [int]$ws['completed'] + 1
                    $curStreak++; $curMiss = 0
                    if ($curStreak -gt $longStreak) { $longStreak = $curStreak }
                }
                'P' {
                    $ws['partials'] = [int]$ws['partials'] + 1
                    $curStreak = 0; $curMiss = 0
                }
                default {
                    # M or U
                    $missed++
                    $ws['missed'] = [int]$ws['missed'] + 1
                    $curMiss++; $curStreak = 0
                    if ($curMiss -gt $longMiss) { $longMiss = $curMiss }
                }
            }
        }
    }

    # Prune weeklyStats to the newest 26 ISO weeks (keys sort chronologically).
    $weekKeys = @($weekly.Keys | Sort-Object)
    if ($weekKeys.Count -gt 26) {
        foreach ($old in ($weekKeys | Select-Object -First ($weekKeys.Count - 26))) {
            $weekly.Remove($old)
        }
    }

    $SeriesData['campaignsObserved']  = $observed
    $SeriesData['campaignsCompleted'] = $completed
    $SeriesData['campaignsMissed']    = $missed
    $SeriesData['weeklyStats']        = $weekly
    $SeriesData['streaks'] = @{
        currentStreak     = $curStreak
        longestStreak     = $longStreak
        currentMissStreak = $curMiss
        longestMissStreak = $longMiss
    }
}

function Update-SPReviewerGlobalStats {
    <#
    .SYNOPSIS
        Recomputes a reviewer's global totals + engagementScore as the sum of the
        per-series derived stats. Idempotent (derived, never incremented).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Reviewer, [string]$TodayLabel = '')

    $obs = 0; $comp = 0; $miss = 0
    if ($Reviewer.ContainsKey('series') -and $null -ne $Reviewer['series']) {
        foreach ($sn in $Reviewer['series'].Keys) {
            $sd = $Reviewer['series'][$sn]
            $obs  += [int]$sd['campaignsObserved']
            $comp += [int]$sd['campaignsCompleted']
            $miss += [int]$sd['campaignsMissed']
        }
    }
    $score = 0
    if ($obs -gt 0) { $score = [int][math]::Round($comp / $obs * 100, 0) }
    if (-not $Reviewer.ContainsKey('global') -or $null -eq $Reviewer['global']) { $Reviewer['global'] = @{} }
    $g = $Reviewer['global']
    $g['totalCampaignsObserved']  = $obs
    $g['totalCampaignsCompleted'] = $comp
    $g['totalCampaignsMissed']    = $miss
    $g['engagementScore']         = $score
    if (-not [string]::IsNullOrWhiteSpace($TodayLabel)) { $g['lastRunDate'] = $TodayLabel }
}

#endregion

#region Public: Series Detection (backward compat)

function Get-SPCampaignSeriesName {
    <#
    .SYNOPSIS
        Extracts the campaign series name by stripping date suffixes.
    .DESCRIPTION
        Strips trailing date portions to produce a stable series name. Kept for
        backward compatibility; the orchestrator uses Get-SPCampaignSeriesKey from
        SP.CampaignSeries instead.
    .PARAMETER CampaignName
        The full campaign name from ISC.
    .OUTPUTS
        [string] The series name with date suffix removed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$CampaignName)

    $name = $CampaignName.Trim()
    $name = $name -replace '\s+(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),?\s+\w+\s+\d{1,2},?\s*\d{4}\s*$', ''
    $name = $name -replace '\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s*\d{4}\s*$', ''
    $name = $name -replace '\s+\d{4}-\d{2}-\d{2}\s*$', ''
    $name = $name -replace '\s+\d{1,2}/\d{1,2}/\d{4}\s*$', ''
    # Bare trailing 4-digit token: only strip plausible YEARS (19xx/20xx), not zone/site
    # numbers like "PCI Review Zone 1042".
    $name = $name -replace '\s+(19|20)\d{2}\s*$', ''
    return $name.Trim()
}

#endregion

#region Public: Read

function Read-SPReviewerState {
    <#
    .SYNOPSIS
        Reads reviewer-state.jsonl into a hashtable keyed by stable reviewer key.
    .DESCRIPTION
        The first line containing a _meta key is treated as file metadata (holds
        ProcessedInstances and LastRunDate). All other lines are reviewer records
        keyed by their reviewerKey field ('id:<ReviewerId>' else 'nm:<name>'); legacy
        records without reviewerKey fall back to 'nm:<reviewerName>'.

        Corrupt lines are counted in SkippedLines (never silently discarded): callers
        must treat Exists + RecordCount 0 + SkippedLines > 0 as a CORRUPT file and
        refuse to overwrite it.
    .PARAMETER Path
        Full path to the reviewer-state.jsonl file.
    .OUTPUTS
        Hashtable: ReviewerMap, ProcessedInstances, RecordCount, Exists, LastRunDate, SkippedLines.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $reviewerMap = @{}
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

                # Detect metadata line
                if ($rec.ContainsKey('_meta')) {
                    $meta = $rec['_meta']
                    if ($null -ne $meta -and $meta -is [hashtable]) {
                        if ($meta.ContainsKey('processedInstances') -and $null -ne $meta['processedInstances']) {
                            $pi = $meta['processedInstances']
                            if ($pi -is [hashtable]) { $processedInstances = $pi }
                        }
                        if ($meta.ContainsKey('lastRunDate')) {
                            $lastRunDate = [string]$meta['lastRunDate']
                        }
                    }
                    continue
                }

                # Data line: keyed by stable reviewerKey (legacy fallback: name).
                $key = ''
                if ($rec.ContainsKey('reviewerKey')) { $key = [string]$rec['reviewerKey'] }
                if ([string]::IsNullOrWhiteSpace($key) -and $rec.ContainsKey('reviewerName')) {
                    $key = Get-SPReviewerStateKey -ReviewerId '' -ReviewerName ([string]$rec['reviewerName'])
                    $rec['reviewerKey'] = $key
                }
                if (-not [string]::IsNullOrWhiteSpace($key)) {
                    $reviewerMap[$key] = $rec
                }
                else { $skipped++ }
            } catch { $skipped++ }
        }
        if ($skipped -gt 0) {
            Write-Warning "Read-SPReviewerState: skipped $skipped unparseable line(s) in $Path"
        }
    }

    return @{
        ReviewerMap        = $reviewerMap
        ProcessedInstances = $processedInstances
        RecordCount        = $reviewerMap.Count
        Exists             = $exists
        LastRunDate        = $lastRunDate
        SkippedLines       = $skipped
    }
}

#endregion

#region Public: Update

function Update-SPReviewerState {
    <#
    .SYNOPSIS
        Processes ONE campaign instance's resolved items through the reviewer
        engagement state machine.
    .DESCRIPTION
        Accepts resolved items from Resolve-SPSeriesItemState (the honest decision
        classifier in SP.CampaignSeries) and updates per-reviewer engagement records.
        The per-day state lands in the series dayLog (keyed yyyyMMdd by the campaign's
        own InstanceDate); campaignsObserved/weeklyStats/streaks/global totals are then
        RE-DERIVED from the dayLog, so re-processing an instance (ACTIVE campaigns are
        re-captured until they complete) converges instead of double-counting.

        Engagement classification per reviewer group:
          C: decided==total AND decided>0
          P: decided>0 AND decided<total
          M: decided==0 AND NOT all items are auto-approved
          U: decided==0 AND all items are auto-approved

        A reviewer absent from the instance's items is untouched (absence != inaction).
        The orchestrator owns processedInstances; this function neither guards nor marks.
    .PARAMETER ReviewerMap
        Hashtable of existing reviewer records keyed by stable reviewer key. Modified in-place.
    .PARAMETER ResolvedItems
        Array of resolved item objects from Resolve-SPSeriesItemState.
    .PARAMETER ProcessedInstances
        ACCEPTED FOR BACK-COMPAT, IGNORED: the orchestrator owns instance bookkeeping.
    .PARAMETER InstanceId
        The campaign instance ID (informational).
    .PARAMETER InstanceDate
        The campaign instance date as yyyy-MM-dd string. Drives the dayLog key.
    .PARAMETER SeriesName
        The campaign series name for grouping.
    .PARAMETER InstanceStatus
        The campaign status (e.g., ACTIVE, COMPLETED). Informational.
    .PARAMETER TodayLabel
        Today's date as yyyy-MM-dd string (metadata only). Defaults to current date.
    .OUTPUTS
        Hashtable with keys: ReviewersNew, ReviewersUpdated, ProcessedInstances.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ReviewerMap,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ResolvedItems,

        [Parameter()]
        [hashtable]$ProcessedInstances = @{},

        [string]$InstanceId = '',

        [string]$InstanceDate = '',

        [string]$SeriesName = '',

        [string]$InstanceStatus = '',

        [string]$TodayLabel = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    )

    $reviewersNew = 0
    $reviewersUpdated = 0

    # Resolve the campaign date (invariant culture; the ambient locale must never
    # re-interpret an ISO date).
    $campDate = $InstanceDate
    if ([string]::IsNullOrWhiteSpace($campDate)) { $campDate = $TodayLabel }
    $campDt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($campDate, 'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$campDt)) {
        if (-not [datetime]::TryParse($campDate, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$campDt)) {
            Write-Warning "Update-SPReviewerState: unparseable InstanceDate '$campDate' -- instance skipped (day attribution would be wrong)"
            return @{ ReviewersNew = 0; ReviewersUpdated = 0; ProcessedInstances = $ProcessedInstances }
        }
    }
    $dayKey = $campDt.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
    $campDateIso = $campDt.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)

    # Default series name
    $serName = $SeriesName
    if ([string]::IsNullOrWhiteSpace($serName)) { $serName = '(Unknown Series)' }

    # Group resolved items by STABLE reviewer key (id else name). An item with an id
    # but a blank display name still counts -- identity, not label, is the key.
    $reviewerGroups = @{}
    $reviewerLabels = @{}
    foreach ($item in @($ResolvedItems)) {
        if ($null -eq $item) { continue }
        $rvName = [string](Get-SPStateItemProp $item 'ReviewerName' '')
        $rvId   = [string](Get-SPStateItemProp $item 'ReviewerId' '')
        $key = Get-SPReviewerStateKey -ReviewerId $rvId -ReviewerName $rvName
        if ([string]::IsNullOrWhiteSpace($key)) { continue }

        if (-not $reviewerGroups.ContainsKey($key)) {
            $reviewerGroups[$key] = [System.Collections.Generic.List[object]]::new()
            $reviewerLabels[$key] = $rvName
        }
        if ([string]::IsNullOrWhiteSpace([string]$reviewerLabels[$key]) -and -not [string]::IsNullOrWhiteSpace($rvName)) {
            $reviewerLabels[$key] = $rvName
        }
        $reviewerGroups[$key].Add($item)
    }

    # Process each reviewer group
    foreach ($rvKey in $reviewerGroups.Keys) {
        $group = $reviewerGroups[$rvKey]
        $totalItems = $group.Count
        $rvName = [string]$reviewerLabels[$rvKey]

        # Count decided items (where IsGenuineDecision is true)
        $decidedCount = 0
        $allAutoApproved = $true
        $rvEmail = ''
        $rvId = ''

        foreach ($ri in $group) {
            $isGenuine = [bool](Get-SPStateItemProp $ri 'IsGenuineDecision' $false)
            $isAuto    = [bool](Get-SPStateItemProp $ri 'IsAutoApproved' $false)
            $riEmail   = [string](Get-SPStateItemProp $ri 'ReviewerEmail' '')
            $riId      = [string](Get-SPStateItemProp $ri 'ReviewerId' '')

            if ($isGenuine) { $decidedCount++ }
            if (-not $isAuto) { $allAutoApproved = $false }

            if ([string]::IsNullOrWhiteSpace($rvEmail) -and -not [string]::IsNullOrWhiteSpace($riEmail)) {
                $rvEmail = $riEmail
            }
            if ([string]::IsNullOrWhiteSpace($rvId) -and -not [string]::IsNullOrWhiteSpace($riId)) {
                $rvId = $riId
            }
        }

        # Determine engagement state: C/P/M/U
        $state = 'M'
        if ($decidedCount -eq $totalItems -and $decidedCount -gt 0) {
            $state = 'C'
        }
        elseif ($decidedCount -gt 0 -and $decidedCount -lt $totalItems) {
            $state = 'P'
        }
        elseif ($decidedCount -eq 0 -and $allAutoApproved) {
            $state = 'U'
        }
        # else: M (decided==0 and not all auto-approved)

        $compPct = 0
        if ($totalItems -gt 0) { $compPct = [math]::Round($decidedCount / $totalItems * 100, 1) }

        # Create the reviewer / series shells when missing
        $isNewReviewer = -not $ReviewerMap.ContainsKey($rvKey)
        if ($isNewReviewer) {
            $ReviewerMap[$rvKey] = @{
                reviewerKey   = $rvKey
                reviewerName  = $rvName
                reviewerEmail = $rvEmail
                reviewerId    = $rvId
                series        = @{}
                global        = @{
                    totalCampaignsObserved  = 0
                    totalCampaignsCompleted = 0
                    totalCampaignsMissed    = 0
                    lastRunDate             = $TodayLabel
                    engagementScore         = 0
                }
            }
            $reviewersNew++
        }

        $reviewer = $ReviewerMap[$rvKey]
        # Refresh display fields from the latest data (a rename updates the label,
        # never the identity).
        if (-not [string]::IsNullOrWhiteSpace($rvName))  { $reviewer['reviewerName'] = $rvName }
        if (-not [string]::IsNullOrWhiteSpace($rvEmail)) { $reviewer['reviewerEmail'] = $rvEmail }
        if (-not [string]::IsNullOrWhiteSpace($rvId))    { $reviewer['reviewerId'] = $rvId }

        if (-not $reviewer.ContainsKey('series') -or $null -eq $reviewer['series']) {
            $reviewer['series'] = @{}
        }
        if (-not $reviewer['series'].ContainsKey($serName)) {
            $reviewer['series'][$serName] = @{
                firstSeenDate      = $campDateIso
                lastActiveDate     = $campDateIso
                lastDecisionCount  = 0
                lastItemsTotal     = 0
                lastCompletionPct  = 0
                campaignsObserved  = 0
                campaignsCompleted = 0
                campaignsMissed    = 0
                dayLog             = ''
                weeklyStats        = @{}
                streaks            = @{
                    currentStreak     = 0
                    longestStreak     = 0
                    currentMissStreak = 0
                    longestMissStreak = 0
                }
            }
        }

        $sd = $reviewer['series'][$serName]

        # Keep firstSeenDate honest under out-of-order backfills.
        $sdFirst = [string]$sd['firstSeenDate']
        if ([string]::IsNullOrWhiteSpace($sdFirst) -or ($campDateIso -lt $sdFirst)) {
            $sd['firstSeenDate'] = $campDateIso
        }

        # Set/replace this day's entry, then re-derive every counter from the dayLog.
        $dlResult = Update-DayLogEntry -DayLog ([string]$sd['dayLog']) -DayKey $dayKey -State $state
        $sd['dayLog'] = $dlResult.DayLog

        # Latest-instance metadata: only advance when this instance is the newest the
        # series record has seen (ISO strings compare lexically).
        $sdLast = [string]$sd['lastActiveDate']
        if ([string]::IsNullOrWhiteSpace($sdLast) -or ($campDateIso -ge $sdLast)) {
            $sd['lastActiveDate']    = $campDateIso
            $sd['lastDecisionCount'] = $decidedCount
            $sd['lastItemsTotal']    = $totalItems
            $sd['lastCompletionPct'] = $compPct
        }

        Update-SPReviewerSeriesDerivedStats -SeriesData $sd
        Update-SPReviewerGlobalStats -Reviewer $reviewer -TodayLabel $TodayLabel

        if (-not $isNewReviewer) { $reviewersUpdated++ }
    }

    return @{
        ReviewersNew       = $reviewersNew
        ReviewersUpdated   = $reviewersUpdated
        ProcessedInstances = $ProcessedInstances
    }
}

#endregion

#region Public: Write

function Write-SPReviewerState {
    <#
    .SYNOPSIS
        Atomically writes the reviewer map to reviewer-state.jsonl.
    .DESCRIPTION
        Writes a _meta line first (with ProcessedInstances and LastRunDate), then data
        records sorted by reviewer key. Durable write discipline (mirrors
        SP.IdentityService): a NAMED MUTEX serializes writers across processes, content
        goes to a UNIQUE per-PID temp file, and the swap is [System.IO.File]::Replace
        (atomic on NTFS) -- there is never a moment without a state file.
        All output is UTF-8 no-BOM. ConvertTo-Json uses -Depth 6 for the nested
        series -> weeklyStats -> week data structure.
    .PARAMETER ReviewerMap
        Hashtable of reviewer records to write.
    .PARAMETER Path
        Full path to the reviewer-state.jsonl file.
    .PARAMETER ProcessedInstances
        Hashtable of processed instance IDs and their metadata.
    .PARAMETER LastRunDate
        The date to record as last run. Defaults to current date.
    .OUTPUTS
        Hashtable with keys: Success (bool), RecordsWritten (int), Error (string).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ReviewerMap,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [hashtable]$ProcessedInstances = @{},

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

        # Write _meta line first
        $meta = @{
            _meta = @{
                lastRunDate        = $LastRunDate
                processedInstances = $ProcessedInstances
                recordCount        = $ReviewerMap.Count
            }
        }
        $lines.Add(($meta | ConvertTo-Json -Depth 6 -Compress))

        # Write data records sorted by reviewer key
        foreach ($rvKey in ($ReviewerMap.Keys | Sort-Object)) {
            $lines.Add(($ReviewerMap[$rvKey] | ConvertTo-Json -Depth 6 -Compress))
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
            RecordsWritten = $ReviewerMap.Count
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
    'Read-SPReviewerState',
    'Update-SPReviewerState',
    'Write-SPReviewerState',
    'Get-SPCampaignSeriesName',
    'Get-SPReviewerStateKey',
    'Get-SPIsoWeekString',
    'Update-DayLogEntry'
)

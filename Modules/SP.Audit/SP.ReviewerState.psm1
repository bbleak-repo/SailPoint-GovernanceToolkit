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

    Functions:
      Read-SPReviewerState     -- load JSONL into hashtable
      Update-SPReviewerState   -- process resolved items through state machine
      Write-SPReviewerState    -- atomic write (tmp + rename)
      Get-SPCampaignSeriesName -- extract series from campaign name (backward compat)

    Version: 2.0.0
#>

#region Internal helpers

function Get-IsoWeekString {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Date)
    $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    $weekNum = $cal.GetWeekOfYear($Date, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [System.DayOfWeek]::Monday)
    $year = $Date.Year
    if ($weekNum -eq 1 -and $Date.Month -eq 12) { $year++ }
    if ($weekNum -ge 52 -and $Date.Month -eq 1) { $year-- }
    return '{0}-W{1:D2}' -f $year, $weekNum
}

function Update-DayLogEntry {
    [CmdletBinding()][OutputType([hashtable])]
    param([string]$DayLog, [string]$Mmdd, [string]$State)
    $entries = @{}
    if (-not [string]::IsNullOrWhiteSpace($DayLog)) {
        foreach ($part in $DayLog.Split('|')) {
            if ($part.Length -ge 6 -and $part[1] -eq ':') {
                $entries[$part.Substring(2)] = [string]$part[0]
            }
        }
    }
    $changed = $false
    if ($entries.ContainsKey($Mmdd)) {
        if ([string]$entries[$Mmdd] -ne $State) { $entries[$Mmdd] = $State; $changed = $true }
    } else { $entries[$Mmdd] = $State; $changed = $true }
    $sortedKeys = @($entries.Keys | Sort-Object)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $sortedKeys) { $parts.Add("$($entries[$k]):${k}") }
    return @{ DayLog = $parts -join '|'; Changed = $changed }
}

function ConvertFrom-PSOToHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [hashtable]) {
        $ht = @{}; foreach ($k in $InputObject.Keys) { $ht[$k] = ConvertFrom-PSOToHashtable $InputObject[$k] }; return $ht
    }
    if ($InputObject -is [PSCustomObject]) {
        $ht = @{}; foreach ($prop in $InputObject.PSObject.Properties) { $ht[$prop.Name] = ConvertFrom-PSOToHashtable $prop.Value }; return $ht
    }
    return $InputObject
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
    $name = $name -replace '\s+\d{4}\s*$', ''
    return $name.Trim()
}

#endregion

#region Public: Read

function Read-SPReviewerState {
    <#
    .SYNOPSIS
        Reads reviewer-state.jsonl into a hashtable keyed by reviewer name.
    .DESCRIPTION
        The first line containing a _meta key is treated as file metadata (holds
        ProcessedInstances and LastRunDate). All other lines are reviewer records
        keyed by reviewerName and converted to nested hashtables.
    .PARAMETER Path
        Full path to the reviewer-state.jsonl file.
    .OUTPUTS
        Hashtable with keys: ReviewerMap, ProcessedInstances, RecordCount, Exists, LastRunDate.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $reviewerMap = @{}
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

                # Detect metadata line
                if ($rec.ContainsKey('_meta')) {
                    $meta = $rec['_meta']
                    if ($null -ne $meta -and $meta -is [hashtable]) {
                        if ($meta.ContainsKey('processedInstances') -and $null -ne $meta['processedInstances']) {
                            $processedInstances = $meta['processedInstances']
                            if ($processedInstances -isnot [hashtable]) {
                                $processedInstances = ConvertFrom-PSOToHashtable $processedInstances
                            }
                        }
                        if ($meta.ContainsKey('lastRunDate')) {
                            $lastRunDate = [string]$meta['lastRunDate']
                        }
                    }
                    continue
                }

                # Data line: keyed by reviewerName
                if ($rec.ContainsKey('reviewerName') -and -not [string]::IsNullOrWhiteSpace([string]$rec['reviewerName'])) {
                    $reviewerMap[[string]$rec['reviewerName']] = $rec
                }
            } catch { }
        }
    }

    return @{
        ReviewerMap        = $reviewerMap
        ProcessedInstances = $processedInstances
        RecordCount        = $reviewerMap.Count
        Exists             = $exists
        LastRunDate        = $lastRunDate
    }
}

#endregion

#region Public: Update

function Update-SPReviewerState {
    <#
    .SYNOPSIS
        Processes resolved campaign items through the reviewer engagement state machine.
    .DESCRIPTION
        Accepts resolved items from Resolve-SPSeriesItemState (the honest decision
        classifier in SP.CampaignSeries) and updates per-reviewer engagement records
        with C/P/M/U state, dayLog, weeklyStats, streaks, and engagement score.

        Each resolved item carries: ReviewerName, HonestDecision (Approved/Revoked/Undecided),
        IsGenuineDecision (bool), IsAutoApproved (bool), ReviewerEmail, ReviewerId.

        Engagement classification per reviewer group:
          C: decided==total AND decided>0
          P: decided>0 AND decided<total
          M: decided==0 AND NOT all items are auto-approved
          U: decided==0 AND all items are auto-approved
    .PARAMETER ReviewerMap
        Hashtable of existing reviewer records (from Read-SPReviewerState). Modified in-place.
    .PARAMETER ResolvedItems
        Array of resolved item objects from Resolve-SPSeriesItemState.
    .PARAMETER ProcessedInstances
        Hashtable tracking which campaign instance IDs have already been processed.
    .PARAMETER InstanceId
        The campaign instance ID being processed.
    .PARAMETER InstanceDate
        The campaign instance date as yyyy-MM-dd string.
    .PARAMETER SeriesName
        The campaign series name for grouping.
    .PARAMETER InstanceStatus
        The campaign status (e.g., ACTIVE, COMPLETED).
    .PARAMETER TodayLabel
        Today's date as yyyy-MM-dd string. Defaults to current date.
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

        [string]$TodayLabel = (Get-Date).ToString('yyyy-MM-dd')
    )

    $reviewersNew = 0
    $reviewersUpdated = 0

    # Skip if this instance was already processed
    if (-not [string]::IsNullOrWhiteSpace($InstanceId) -and $ProcessedInstances.ContainsKey($InstanceId)) {
        return @{
            ReviewersNew       = 0
            ReviewersUpdated   = 0
            ProcessedInstances = $ProcessedInstances
        }
    }

    # Resolve the campaign date
    $campDate = $InstanceDate
    if ([string]::IsNullOrWhiteSpace($campDate)) { $campDate = $TodayLabel }
    $campMmdd = ''
    $campDt = $null
    try {
        $campDt = [datetime]::Parse($campDate)
        $campMmdd = $campDt.ToString('MMdd')
    } catch { }

    $isoWeek = ''
    if ($null -ne $campDt) {
        $isoWeek = Get-IsoWeekString -Date $campDt
    }

    # Default series name
    $serName = $SeriesName
    if ([string]::IsNullOrWhiteSpace($serName)) { $serName = '(Unknown Series)' }

    # Group resolved items by ReviewerName
    $reviewerGroups = @{}
    foreach ($item in @($ResolvedItems)) {
        if ($null -eq $item) { continue }
        $rvName = ''
        if ($item -is [hashtable]) {
            if ($item.ContainsKey('ReviewerName')) { $rvName = [string]$item['ReviewerName'] }
        } else {
            $rvName = [string]$item.ReviewerName
        }
        if ([string]::IsNullOrWhiteSpace($rvName)) { continue }

        if (-not $reviewerGroups.ContainsKey($rvName)) {
            $reviewerGroups[$rvName] = [System.Collections.Generic.List[object]]::new()
        }
        $reviewerGroups[$rvName].Add($item)
    }

    # Process each reviewer group
    foreach ($rvName in $reviewerGroups.Keys) {
        $group = $reviewerGroups[$rvName]
        $totalItems = $group.Count

        # Count decided items (where IsGenuineDecision is true)
        $decidedCount = 0
        $allAutoApproved = $true
        $rvEmail = ''
        $rvId = ''

        foreach ($ri in $group) {
            $isGenuine = $false
            $isAuto = $false
            $riEmail = ''
            $riId = ''

            if ($ri -is [hashtable]) {
                if ($ri.ContainsKey('IsGenuineDecision')) { $isGenuine = [bool]$ri['IsGenuineDecision'] }
                if ($ri.ContainsKey('IsAutoApproved')) { $isAuto = [bool]$ri['IsAutoApproved'] }
                if ($ri.ContainsKey('ReviewerEmail')) { $riEmail = [string]$ri['ReviewerEmail'] }
                if ($ri.ContainsKey('ReviewerId')) { $riId = [string]$ri['ReviewerId'] }
            } else {
                $isGenuine = [bool]$ri.IsGenuineDecision
                $isAuto = [bool]$ri.IsAutoApproved
                $riEmail = [string]$ri.ReviewerEmail
                $riId = [string]$ri.ReviewerId
            }

            if ($isGenuine) { $decidedCount++ }
            if (-not $isAuto) { $allAutoApproved = $false }

            # Extract email/id from first resolved item with non-empty values
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

        # Create or update reviewer record
        if (-not $ReviewerMap.ContainsKey($rvName)) {
            # NEW reviewer
            $newSeriesData = @{
                firstSeenDate      = $campDate
                lastActiveDate     = $campDate
                lastDecisionCount  = $decidedCount
                lastItemsTotal     = $totalItems
                lastCompletionPct  = $compPct
                campaignsObserved  = 1
                campaignsCompleted = 0
                campaignsMissed    = 0
                dayLog             = "${state}:${campMmdd}"
                weeklyStats        = @{}
                streaks            = @{
                    currentStreak     = 0
                    longestStreak     = 0
                    currentMissStreak = 0
                    longestMissStreak = 0
                }
            }

            if ($state -eq 'C') {
                $newSeriesData.campaignsCompleted = 1
                $newSeriesData.streaks.currentStreak = 1
                $newSeriesData.streaks.longestStreak = 1
            }
            if ($state -eq 'M' -or $state -eq 'U') {
                $newSeriesData.campaignsMissed = 1
                $newSeriesData.streaks.currentMissStreak = 1
                $newSeriesData.streaks.longestMissStreak = 1
            }

            # Initialize weekly stats
            if (-not [string]::IsNullOrWhiteSpace($isoWeek)) {
                $ws = @{ expected = 1; completed = 0; missed = 0; partials = 0 }
                if ($state -eq 'C') { $ws.completed = 1 }
                if ($state -eq 'M' -or $state -eq 'U') { $ws.missed = 1 }
                if ($state -eq 'P') { $ws.partials = 1 }
                $newSeriesData.weeklyStats[$isoWeek] = $ws
            }

            $globalCompleted = 0
            $globalMissed = 0
            if ($state -eq 'C') { $globalCompleted = 1 }
            if ($state -eq 'M' -or $state -eq 'U') { $globalMissed = 1 }
            $engScore = 0
            if ($globalCompleted -gt 0) { $engScore = [int][math]::Round($globalCompleted / 1 * 100, 0) }

            $ReviewerMap[$rvName] = @{
                reviewerName  = $rvName
                reviewerEmail = $rvEmail
                reviewerId    = $rvId
                series        = @{ $serName = $newSeriesData }
                global        = @{
                    totalCampaignsObserved  = 1
                    totalCampaignsCompleted = $globalCompleted
                    totalCampaignsMissed    = $globalMissed
                    lastRunDate             = $TodayLabel
                    engagementScore         = $engScore
                }
            }
            $reviewersNew++
        }
        else {
            # EXISTING reviewer -- update series data
            $reviewer = $ReviewerMap[$rvName]

            # Update email/id if available (might be empty on prior records)
            if (-not [string]::IsNullOrWhiteSpace($rvEmail)) { $reviewer['reviewerEmail'] = $rvEmail }
            if (-not [string]::IsNullOrWhiteSpace($rvId))    { $reviewer['reviewerId'] = $rvId }

            # Ensure series hashtable exists
            if (-not $reviewer.ContainsKey('series') -or $null -eq $reviewer['series']) {
                $reviewer['series'] = @{}
            }

            if (-not $reviewer['series'].ContainsKey($serName)) {
                # New series for existing reviewer
                $newSd = @{
                    firstSeenDate      = $campDate
                    lastActiveDate     = $campDate
                    lastDecisionCount  = $decidedCount
                    lastItemsTotal     = $totalItems
                    lastCompletionPct  = $compPct
                    campaignsObserved  = 1
                    campaignsCompleted = 0
                    campaignsMissed    = 0
                    dayLog             = "${state}:${campMmdd}"
                    weeklyStats        = @{}
                    streaks            = @{
                        currentStreak     = 0
                        longestStreak     = 0
                        currentMissStreak = 0
                        longestMissStreak = 0
                    }
                }

                if ($state -eq 'C') {
                    $newSd.campaignsCompleted = 1
                    $newSd.streaks.currentStreak = 1
                    $newSd.streaks.longestStreak = 1
                }
                if ($state -eq 'M' -or $state -eq 'U') {
                    $newSd.campaignsMissed = 1
                    $newSd.streaks.currentMissStreak = 1
                    $newSd.streaks.longestMissStreak = 1
                }

                if (-not [string]::IsNullOrWhiteSpace($isoWeek)) {
                    $ws = @{ expected = 1; completed = 0; missed = 0; partials = 0 }
                    if ($state -eq 'C') { $ws.completed = 1 }
                    if ($state -eq 'M' -or $state -eq 'U') { $ws.missed = 1 }
                    if ($state -eq 'P') { $ws.partials = 1 }
                    $newSd.weeklyStats[$isoWeek] = $ws
                }

                $reviewer['series'][$serName] = $newSd
            }
            else {
                # Existing series -- update with dayLog idempotency check
                $sd = $reviewer['series'][$serName]

                $dlResult = Update-DayLogEntry -DayLog ([string]$sd['dayLog']) -Mmdd $campMmdd -State $state
                if (-not $dlResult.Changed) {
                    # Already processed this date with same state -- skip updates
                    continue
                }
                $sd['dayLog'] = $dlResult.DayLog

                # Update series metadata
                $sd['lastActiveDate']    = $campDate
                $sd['lastDecisionCount'] = $decidedCount
                $sd['lastItemsTotal']    = $totalItems
                $sd['lastCompletionPct'] = $compPct
                $sd['campaignsObserved'] = [int]$sd['campaignsObserved'] + 1
                if ($state -eq 'C') { $sd['campaignsCompleted'] = [int]$sd['campaignsCompleted'] + 1 }
                if ($state -eq 'M' -or $state -eq 'U') { $sd['campaignsMissed'] = [int]$sd['campaignsMissed'] + 1 }

                # Update weekly stats
                if (-not [string]::IsNullOrWhiteSpace($isoWeek)) {
                    if (-not $sd.ContainsKey('weeklyStats') -or $null -eq $sd['weeklyStats']) {
                        $sd['weeklyStats'] = @{}
                    }
                    if (-not $sd['weeklyStats'].ContainsKey($isoWeek)) {
                        $sd['weeklyStats'][$isoWeek] = @{ expected = 0; completed = 0; missed = 0; partials = 0 }
                    }
                    $ws = $sd['weeklyStats'][$isoWeek]
                    $ws['expected'] = [int]$ws['expected'] + 1
                    if ($state -eq 'C') { $ws['completed'] = [int]$ws['completed'] + 1 }
                    if ($state -eq 'M' -or $state -eq 'U') { $ws['missed'] = [int]$ws['missed'] + 1 }
                    if ($state -eq 'P') { $ws['partials'] = [int]$ws['partials'] + 1 }
                }

                # Update streaks
                if (-not $sd.ContainsKey('streaks') -or $null -eq $sd['streaks']) {
                    $sd['streaks'] = @{ currentStreak = 0; longestStreak = 0; currentMissStreak = 0; longestMissStreak = 0 }
                }
                $streaks = $sd['streaks']
                switch ($state) {
                    'C' {
                        $streaks['currentStreak'] = [int]$streaks['currentStreak'] + 1
                        $streaks['currentMissStreak'] = 0
                        if ([int]$streaks['currentStreak'] -gt [int]$streaks['longestStreak']) {
                            $streaks['longestStreak'] = [int]$streaks['currentStreak']
                        }
                    }
                    'P' {
                        # Partial breaks both streaks
                        $streaks['currentStreak'] = 0
                        $streaks['currentMissStreak'] = 0
                    }
                    default {
                        # M or U
                        $streaks['currentMissStreak'] = [int]$streaks['currentMissStreak'] + 1
                        $streaks['currentStreak'] = 0
                        if ([int]$streaks['currentMissStreak'] -gt [int]$streaks['longestMissStreak']) {
                            $streaks['longestMissStreak'] = [int]$streaks['currentMissStreak']
                        }
                    }
                }
            }

            # Update global stats
            if (-not $reviewer.ContainsKey('global') -or $null -eq $reviewer['global']) {
                $reviewer['global'] = @{
                    totalCampaignsObserved = 0; totalCampaignsCompleted = 0
                    totalCampaignsMissed = 0; lastRunDate = $TodayLabel; engagementScore = 0
                }
            }
            $g = $reviewer['global']
            $g['totalCampaignsObserved']  = [int]$g['totalCampaignsObserved'] + 1
            if ($state -eq 'C') { $g['totalCampaignsCompleted'] = [int]$g['totalCampaignsCompleted'] + 1 }
            if ($state -eq 'M' -or $state -eq 'U') { $g['totalCampaignsMissed'] = [int]$g['totalCampaignsMissed'] + 1 }
            $g['lastRunDate'] = $TodayLabel
            if ([int]$g['totalCampaignsObserved'] -gt 0) {
                $g['engagementScore'] = [int][math]::Round([int]$g['totalCampaignsCompleted'] / [int]$g['totalCampaignsObserved'] * 100, 0)
            } else {
                $g['engagementScore'] = 0
            }

            $reviewersUpdated++
        }
    }

    # Mark instance as processed
    if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
        $ProcessedInstances[$InstanceId] = @{
            date   = $InstanceDate
            series = $serName
            status = $InstanceStatus
        }
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
        Writes a _meta line first (with ProcessedInstances and LastRunDate), then
        data records sorted by reviewerName. Uses atomic write-to-tmp + rename.
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

        [string]$LastRunDate = (Get-Date).ToString('yyyy-MM-dd')
    )

    try {
        $tmpFile = "${Path}.tmp"
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

        # Write data records sorted by reviewerName
        foreach ($rvName in ($ReviewerMap.Keys | Sort-Object)) {
            $lines.Add(($ReviewerMap[$rvName] | ConvertTo-Json -Depth 6 -Compress))
        }

        # Ensure parent directory exists
        $parentDir = Split-Path $Path -Parent
        if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        [System.IO.File]::WriteAllLines($tmpFile, $lines.ToArray(), $utf8NoBom)

        if (Test-Path $Path) { Remove-Item $Path -Force }
        Rename-Item $tmpFile (Split-Path $Path -Leaf)

        return @{
            Success        = $true
            RecordsWritten = $ReviewerMap.Count
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

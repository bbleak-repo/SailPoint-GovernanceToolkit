<#
.SYNOPSIS
    SP.StateOrchestrator -- single-call state tracking for any script.
.DESCRIPTION
    Thin orchestrator that reads the rich audit cache via Get-SPCachedCampaignSeries,
    runs the SP.CampaignSeries honest classifier on each item, and updates both
    entitlement-state.jsonl and reviewer-state.jsonl via SP.EntitlementState and
    SP.ReviewerState modules.

    Write-path scripts call:
      $tracking = Invoke-SPStateTracking -MetricsPath $metricsPath
    Read-only scripts call:
      $tracking = Read-SPStateFiles -MetricsPath $metricsDir

    Both return identical $tracking.Entitlement / $tracking.Reviewer structures.

    Delta optimization: processedInstances tracks which campaign IDs have already
    been processed. Daily runs skip all but the newest instance (~30 sec).
    Use -Force to reprocess everything (bootstrap/rebuild).

    Version: 2.0.0
#>

function Invoke-SPStateTracking {
    <#
    .SYNOPSIS
        Reads cache, classifies items, updates both state files in one call.
    .PARAMETER MetricsPath
        Resolved metrics directory (where state JSONL files live).
    .PARAMETER CampaignAudits
        Ignored (kept for V4c backward compatibility). The orchestrator reads from cache.
    .PARAMETER CachePath
        Override cache directory. Defaults to Get-SPAuditCacheDir.
    .PARAMETER TodayLabel
        Today's date as yyyy-MM-dd. Defaults to current date.
    .PARAMETER Force
        Ignore processedInstances -- reprocess all cached campaigns (bootstrap/rebuild).
    .PARAMETER MinInstances
        Minimum instance count per series for Get-SPCachedCampaignSeries. Default 1.
    .PARAMETER CorrelationID
        Optional correlation id for logging.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$MetricsPath,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$CampaignAudits,

        [Parameter()]
        [string]$CachePath,

        [Parameter()]
        [string]$TodayLabel = (Get-Date).ToString('yyyy-MM-dd'),

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [int]$MinInstances = 1,

        [Parameter()]
        [string]$CorrelationID
    )

    # Initialize empty result structure (returned even on failure)
    $emptyResult = @{
        Entitlement = @{
            StateMap = @{}; Total = 0; IsFirstRun = $true; FilePath = ''
            NewlyDecided = [System.Collections.Generic.List[object]]::new()
            DroppedFromScope = [System.Collections.Generic.List[object]]::new()
            StateSummary = @{ APPROVE = 0; REVOKE = 0; PENDING = 0; UNDECIDED = 0 }
            StateNew = 0; StateChanged = 0; PriorSnapshot = @{}
        }
        Reviewer = @{
            ReviewerMap = @{}; Total = 0; IsFirstRun = $true; FilePath = ''
            ReviewersNew = 0; ReviewersUpdated = 0; SeriesDetected = @{}
        }
    }

    # Verify required functions exist (SP.CampaignSeries + SP.AuditQueries)
    if (-not (Get-Command Get-SPCachedCampaignSeries -ErrorAction Ignore)) {
        Write-Warning 'Invoke-SPStateTracking: Get-SPCachedCampaignSeries not available. SP.Audit may not be fully loaded.'
        return $emptyResult
    }
    if (-not (Get-Command Resolve-SPSeriesItemState -ErrorAction Ignore)) {
        Write-Warning 'Invoke-SPStateTracking: Resolve-SPSeriesItemState not available. SP.CampaignSeries may not be loaded.'
        return $emptyResult
    }

    # --- Read existing state files ---
    $entPath = Join-Path $MetricsPath 'entitlement-state.jsonl'
    $rvPath  = Join-Path $MetricsPath 'reviewer-state.jsonl'

    $entRead = Read-SPEntitlementState -Path $entPath
    $rvRead  = Read-SPReviewerState -Path $rvPath

    $entStateMap       = $entRead.StateMap
    $rvReviewerMap     = $rvRead.ReviewerMap
    $entProcessed      = if ($Force) { @{} } else { $entRead.ProcessedInstances }
    $rvProcessed       = if ($Force) { @{} } else { $rvRead.ProcessedInstances }

    # Union processedInstances (they should match, but be defensive)
    $processedInstances = @{}
    foreach ($k in $entProcessed.Keys) { $processedInstances[$k] = $true }
    foreach ($k in $rvProcessed.Keys)  { $processedInstances[$k] = $true }

    # --- Load cached campaign series ---
    $seriesParams = @{ MinInstances = $MinInstances }
    if (-not [string]::IsNullOrWhiteSpace($CachePath)) { $seriesParams['CachePath'] = $CachePath }
    if (-not [string]::IsNullOrWhiteSpace($CorrelationID)) { $seriesParams['CorrelationID'] = $CorrelationID }

    $seriesResult = Get-SPCachedCampaignSeries @seriesParams
    if (-not $seriesResult.Success -or $null -eq $seriesResult.Data) {
        Write-Warning "Invoke-SPStateTracking: Cache read failed: $($seriesResult.Error)"
        return $emptyResult
    }

    $allSeries = @($seriesResult.Data.Series)
    $seriesDetected = @{}
    $allSeenItemKeys = @{}
    $totalEntNew = 0; $totalEntChanged = 0
    $totalRvNew = 0; $totalRvUpdated = 0
    $allNewlyDecided = [System.Collections.Generic.List[object]]::new()

    # --- Process each series, each instance ---
    foreach ($series in $allSeries) {
        $seriesStem = [string]$series.SeriesStem
        $normalizedStem = [string]$series.NormalizedStem
        if (-not $seriesDetected.ContainsKey($seriesStem)) { $seriesDetected[$seriesStem] = 0 }

        $instances = @($series.Instances)

        foreach ($inst in $instances) {
            $campId = [string]$inst.CampaignId
            if ([string]::IsNullOrWhiteSpace($campId)) { continue }

            # Skip already-processed instances
            if ($processedInstances.ContainsKey($campId)) { continue }

            $campName = [string]$inst.CampaignName
            $campStatus = [string]$inst.Status
            $isUnverified = $false
            if ($null -ne $inst.PSObject.Properties['Unverified']) { $isUnverified = [bool]$inst.Unverified }

            # Derive instance date from PeriodToken or CachedAt
            $instDate = $TodayLabel
            $periodToken = ''
            if ($null -ne $inst.PSObject.Properties['PeriodToken']) { $periodToken = [string]$inst.PeriodToken }
            if (-not [string]::IsNullOrWhiteSpace($periodToken)) {
                try { $instDate = ([datetime]::Parse($periodToken)).ToString('yyyy-MM-dd') } catch { }
            }
            if ($instDate -eq $TodayLabel -and $null -ne $inst.PSObject.Properties['CachedAt']) {
                $cachedAt = [string]$inst.CachedAt
                if (-not [string]::IsNullOrWhiteSpace($cachedAt)) {
                    try { $instDate = ([datetime]::Parse($cachedAt)).ToString('yyyy-MM-dd') } catch { }
                }
            }

            # Load items and roster
            $rawItems = @()
            $roster = @()
            try {
                if ($null -ne $inst.PSObject.Properties['LoadItems'] -and $null -ne $inst.LoadItems) {
                    $rawItems = @(& $inst.LoadItems)
                }
            } catch {
                Write-Warning "    Failed to load items for $campName : $($_.Exception.Message)"
                continue
            }
            try {
                if ($null -ne $inst.PSObject.Properties['LoadRoster'] -and $null -ne $inst.LoadRoster) {
                    $roster = @(& $inst.LoadRoster)
                }
            } catch { }

            if ($rawItems.Count -eq 0) { continue }

            # Resolve each item through SP.CampaignSeries honest classifier
            $resolvedItems = [System.Collections.Generic.List[object]]::new()
            foreach ($rawItem in $rawItems) {
                try {
                    $resolved = Resolve-SPSeriesItemState -Item $rawItem -Roster $roster `
                        -Unverified $isUnverified -Status $campStatus
                    if ($null -ne $resolved) {
                        $resolvedItems.Add($resolved)
                        # Track all seen item keys for scope detection
                        $ik = [string]$resolved.ItemKey
                        if (-not [string]::IsNullOrWhiteSpace($ik)) {
                            $allSeenItemKeys[$ik] = $true
                        }
                    }
                } catch { }
            }

            if ($resolvedItems.Count -eq 0) { continue }

            $seriesDetected[$seriesStem]++
            Write-Host "    [$seriesStem] $campName ($($resolvedItems.Count) items, $instDate)" -ForegroundColor DarkGray

            # Update entitlement state (DO NOT mark scope here -- done globally after all series)
            $entUpdate = Update-SPEntitlementState -StateMap $entStateMap `
                -ResolvedItems $resolvedItems.ToArray() `
                -ProcessedInstances $processedInstances `
                -InstanceId $campId -InstanceDate $instDate -TodayLabel $TodayLabel

            $totalEntNew += $entUpdate.StateNew
            $totalEntChanged += $entUpdate.StateChanged
            foreach ($nd in $entUpdate.NewlyDecided) { $allNewlyDecided.Add($nd) }

            # Update reviewer state
            $rvUpdate = Update-SPReviewerState -ReviewerMap $rvReviewerMap `
                -ResolvedItems $resolvedItems.ToArray() `
                -ProcessedInstances $processedInstances `
                -InstanceId $campId -InstanceDate $instDate `
                -SeriesName $seriesStem -InstanceStatus $campStatus `
                -TodayLabel $TodayLabel

            $totalRvNew += $rvUpdate.ReviewersNew
            $totalRvUpdated += $rvUpdate.ReviewersUpdated

            # Mark as processed
            $processedInstances[$campId] = $true
        }
    }

    # --- Global scope detection (across ALL series) ---
    $allDropped = [System.Collections.Generic.List[object]]::new()
    foreach ($ik in @($entStateMap.Keys)) {
        $rec = $entStateMap[$ik]
        if ($allSeenItemKeys.ContainsKey($ik)) {
            $rec.inCurrentScope = $true
        }
        else {
            if ([bool]$rec.inCurrentScope -eq $true) {
                $rec.inCurrentScope = $false
                $allDropped.Add($rec)
            }
        }
    }

    # --- Compute StateSummary from final state ---
    $stateSummary = @{ APPROVE = 0; REVOKE = 0; PENDING = 0; UNDECIDED = 0 }
    foreach ($ik in $entStateMap.Keys) {
        $rec = $entStateMap[$ik]
        if ([bool]$rec.inCurrentScope) {
            $dec = [string]$rec.currentDecision
            if ($stateSummary.ContainsKey($dec)) { $stateSummary[$dec]++ }
        }
    }

    # --- Write state files ---
    Write-SPEntitlementState -StateMap $entStateMap -Path $entPath `
        -ProcessedInstances $processedInstances -LastRunDate $TodayLabel | Out-Null
    Write-SPReviewerState -ReviewerMap $rvReviewerMap -Path $rvPath `
        -ProcessedInstances $processedInstances -LastRunDate $TodayLabel | Out-Null

    # --- Return results ---
    return @{
        Entitlement = @{
            StateMap         = $entStateMap
            Total            = $entStateMap.Count
            IsFirstRun       = -not $entRead.Exists
            FilePath         = $entPath
            NewlyDecided     = $allNewlyDecided
            DroppedFromScope = $allDropped
            StateSummary     = $stateSummary
            StateNew         = $totalEntNew
            StateChanged     = $totalEntChanged
            PriorSnapshot    = @{}
        }
        Reviewer = @{
            ReviewerMap      = $rvReviewerMap
            Total            = $rvReviewerMap.Count
            IsFirstRun       = -not $rvRead.Exists
            FilePath         = $rvPath
            ReviewersNew     = $totalRvNew
            ReviewersUpdated = $totalRvUpdated
            SeriesDetected   = $seriesDetected
        }
    }
}

function Read-SPStateFiles {
    <#
    .SYNOPSIS
        Reads both state files without writing. For read-only visualization scripts (V8).
    .PARAMETER MetricsPath
        Resolved metrics directory path.
    .OUTPUTS
        Hashtable with Entitlement and Reviewer sub-hashtables.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$MetricsPath
    )

    $result = @{
        Entitlement = @{
            StateMap = @{}; Total = 0; IsFirstRun = $true; FilePath = ''
            NewlyDecided = [System.Collections.Generic.List[object]]::new()
            DroppedFromScope = [System.Collections.Generic.List[object]]::new()
            StateSummary = @{ APPROVE = 0; REVOKE = 0; PENDING = 0; UNDECIDED = 0 }
            StateNew = 0; StateChanged = 0; PriorSnapshot = @{}; LastRunDate = ''
        }
        Reviewer = @{
            ReviewerMap = @{}; Total = 0; IsFirstRun = $true; FilePath = ''
            ReviewersNew = 0; ReviewersUpdated = 0; SeriesDetected = @{}; LastRunDate = ''
        }
    }

    $entPath = Join-Path $MetricsPath 'entitlement-state.jsonl'
    $result.Entitlement.FilePath = $entPath
    try {
        $entRead = Read-SPEntitlementState -Path $entPath
        $result.Entitlement.StateMap   = $entRead.StateMap
        $result.Entitlement.Total      = $entRead.RecordCount
        $result.Entitlement.IsFirstRun = -not $entRead.Exists
        $result.Entitlement.LastRunDate = $entRead.LastRunDate

        # Compute summary from current state
        foreach ($sk in $entRead.StateMap.Keys) {
            $rec = $entRead.StateMap[$sk]
            if ([bool]$rec.inCurrentScope) {
                $dec = [string]$rec.currentDecision
                if ($result.Entitlement.StateSummary.ContainsKey($dec)) {
                    $result.Entitlement.StateSummary[$dec]++
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to read entitlement state: $($_.Exception.Message)"
    }

    $rvPath = Join-Path $MetricsPath 'reviewer-state.jsonl'
    $result.Reviewer.FilePath = $rvPath
    try {
        $rvRead = Read-SPReviewerState -Path $rvPath
        $result.Reviewer.ReviewerMap = $rvRead.ReviewerMap
        $result.Reviewer.Total       = $rvRead.RecordCount
        $result.Reviewer.IsFirstRun  = -not $rvRead.Exists
        $result.Reviewer.LastRunDate  = $rvRead.LastRunDate
    }
    catch {
        Write-Warning "Failed to read reviewer state: $($_.Exception.Message)"
    }

    return $result
}

function Resolve-SPReportDateRange {
    <#
    .SYNOPSIS
        Resolves DaysBack / StartDate / EndDate into a concrete date range.
    .DESCRIPTION
        Every report script (V4, V4c, V4e, V7, V7c, V8) needs the same date-range
        resolution logic. This function centralizes it so scripts don't reimplement.

        Precedence: explicit StartDate/EndDate override DaysBack. Missing EndDate
        defaults to today. Missing StartDate defaults to today minus DaysBack.
    .PARAMETER DaysBack
        Lookback window in days. Default 7.
    .PARAMETER StartDate
        Explicit start date (yyyy-MM-dd). Overrides DaysBack.
    .PARAMETER EndDate
        Explicit end date (yyyy-MM-dd). Defaults to today.
    .OUTPUTS
        Hashtable with StartDate, EndDate (yyyy-MM-dd strings), DaysBack (int).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [int]$DaysBack = 7,
        [string]$StartDate,
        [string]$EndDate
    )

    $resolvedStart = ''
    $resolvedEnd   = ''

    if (-not [string]::IsNullOrWhiteSpace($StartDate)) {
        try { $resolvedStart = ([datetime]::Parse($StartDate)).ToString('yyyy-MM-dd') } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($EndDate)) {
        try { $resolvedEnd = ([datetime]::Parse($EndDate)).ToString('yyyy-MM-dd') } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedStart)) {
        $effectiveDays = if ($DaysBack -gt 0) { $DaysBack } else { 7 }
        $resolvedStart = (Get-Date).AddDays(-$effectiveDays).ToString('yyyy-MM-dd')
    }
    if ([string]::IsNullOrWhiteSpace($resolvedEnd)) {
        $resolvedEnd = (Get-Date).ToString('yyyy-MM-dd')
    }

    return @{
        StartDate = $resolvedStart
        EndDate   = $resolvedEnd
        DaysBack  = $DaysBack
    }
}

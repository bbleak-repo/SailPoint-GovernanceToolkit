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

    Both return identical $tracking.Entitlement / $tracking.Reviewer structures
    (Invoke-SPStateTracking additionally returns Success/Error).

    OWNERSHIP CONTRACT (v2.1): the orchestrator ALONE owns processedInstances (guard +
    marking), scope detection, and retention pruning. The Update-SP*State functions are
    pure per-instance state machines that may be safely re-invoked for the same instance.

      * An instance is marked processed ONLY once its status is terminal
        (COMPLETED/COMPLETING/...). ACTIVE/STAGED instances are re-processed on every
        run so a reviewer who finishes at 14:00 is not frozen at the 09:00 snapshot --
        the state modules converge because their counters derive from day-keyed logs.
      * Scope detection compares each record against ITS OWN series' newest processed
        instance date, so a same-day rerun that processed zero new instances is a no-op
        (the earlier implementation flipped every record out of scope on rerun).
      * A whole-run named mutex serializes concurrent updaters (scheduled
        Update-SPStateFiles.ps1 vs a V8 auto-refresh).
      * A corrupt state file (exists, zero parsed records, skipped lines) ABORTS the
        run instead of silently rebuilding from empty and destroying history.

    Delta optimization: processedInstances tracks terminal campaign IDs. Daily runs
    re-process only ACTIVE instances plus anything new. Use -Force to rebuild both
    state files from scratch (resets the maps AND the processed set).

    Version: 2.1.0
#>

Set-StrictMode -Version 1

function Invoke-SPStateTracking {
    <#
    .SYNOPSIS
        Reads cache, classifies items, updates both state files in one call.
    .PARAMETER MetricsPath
        Resolved metrics directory (where state JSONL files live).
    .PARAMETER CampaignAudits
        Ignored (kept for V4-lineage backward compatibility). The orchestrator reads from cache.
    .PARAMETER CachePath
        Override cache directory. Defaults to Get-SPAuditCacheDir.
    .PARAMETER TodayLabel
        Today's date as yyyy-MM-dd. Defaults to current date.
    .PARAMETER Force
        Rebuild from scratch: clears BOTH state maps and the processedInstances set,
        then reprocesses all cached campaigns.
    .PARAMETER MinInstances
        Minimum instance count per series for Get-SPCachedCampaignSeries. Default 1.
    .PARAMETER CorrelationID
        Optional correlation id for logging.
    .OUTPUTS
        Hashtable with Success (bool), Error (string), Entitlement, Reviewer.
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
        [string]$TodayLabel = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture),

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [int]$MinInstances = 1,

        [Parameter()]
        [string]$CorrelationID
    )

    # Initialize empty result structure (returned on failure, with Success=$false)
    $emptyResult = @{
        Success = $false
        Error   = ''
        Entitlement = @{
            StateMap = @{}; Total = 0; IsFirstRun = $true; FilePath = ''
            NewlyDecided = [System.Collections.Generic.List[object]]::new()
            ReApproved = [System.Collections.Generic.List[object]]::new()
            DroppedFromScope = [System.Collections.Generic.List[object]]::new()
            StateSummary = @{ APPROVE = 0; REVOKE = 0; PENDING = 0; UNDECIDED = 0 }
            StateNew = 0; StateChanged = 0; PriorSnapshot = @{}; LastRunDate = ''
        }
        Reviewer = @{
            ReviewerMap = @{}; Total = 0; IsFirstRun = $true; FilePath = ''
            ReviewersNew = 0; ReviewersUpdated = 0; SeriesDetected = @{}; LastRunDate = ''
        }
    }

    # Verify required functions exist (SP.CampaignSeries + SP.AuditQueries)
    if (-not (Get-Command Get-SPCachedCampaignSeries -ErrorAction Ignore)) {
        $emptyResult.Error = 'Get-SPCachedCampaignSeries not available. SP.Audit may not be fully loaded.'
        Write-Warning "Invoke-SPStateTracking: $($emptyResult.Error)"
        return $emptyResult
    }
    if (-not (Get-Command Resolve-SPSeriesItemState -ErrorAction Ignore)) {
        $emptyResult.Error = 'Resolve-SPSeriesItemState not available. SP.CampaignSeries may not be loaded.'
        Write-Warning "Invoke-SPStateTracking: $($emptyResult.Error)"
        return $emptyResult
    }

    # Whole-run mutex: two overlapping updaters (scheduled task + V8 auto-refresh) must
    # not interleave read-modify-write cycles -- last-writer-wins loses the other run's
    # processed instances.
    $runMutex = New-Object System.Threading.Mutex($false, 'Global\SPGovToolkit_StateTracking')
    try { [void]$runMutex.WaitOne(120000) } catch [System.Threading.AbandonedMutexException] { }
    try {

    # --- Read existing state files ---
    $entPath = Join-Path $MetricsPath 'entitlement-state.jsonl'
    $rvPath  = Join-Path $MetricsPath 'reviewer-state.jsonl'

    $entRead = Read-SPEntitlementState -Path $entPath
    $rvRead  = Read-SPReviewerState -Path $rvPath

    # CORRUPTION GUARD: an existing file that parsed to zero records with skipped lines
    # is damaged -- proceeding would rewrite it from scratch and silently destroy
    # months of history. Fail loudly instead ( -Force to rebuild deliberately).
    if (-not $Force) {
        if ($entRead.Exists -and $entRead.RecordCount -eq 0 -and $entRead.SkippedLines -gt 0) {
            $emptyResult.Error = "entitlement-state.jsonl exists but no records parsed ($($entRead.SkippedLines) corrupt line(s)). Refusing to overwrite -- inspect the file or rerun with -Force to rebuild."
            Write-Warning "Invoke-SPStateTracking: $($emptyResult.Error)"
            return $emptyResult
        }
        if ($rvRead.Exists -and $rvRead.RecordCount -eq 0 -and $rvRead.SkippedLines -gt 0) {
            $emptyResult.Error = "reviewer-state.jsonl exists but no records parsed ($($rvRead.SkippedLines) corrupt line(s)). Refusing to overwrite -- inspect the file or rerun with -Force to rebuild."
            Write-Warning "Invoke-SPStateTracking: $($emptyResult.Error)"
            return $emptyResult
        }
    }

    # -Force = rebuild from scratch: reset MAPS as well as the processed set, otherwise
    # re-observation of existing records corrupts derived counters and 'reprocess from
    # scratch' does not mean what it says.
    $entStateMap   = if ($Force) { @{} } else { $entRead.StateMap }
    $rvReviewerMap = if ($Force) { @{} } else { $rvRead.ReviewerMap }
    $entProcessed  = if ($Force) { @{} } else { $entRead.ProcessedInstances }
    $rvProcessed   = if ($Force) { @{} } else { $rvRead.ProcessedInstances }

    # Union processedInstances (they should match, but be defensive). Values carry
    # rich metadata (@{processedDate; instanceDate; series; status}) when written by
    # this version; tolerate bare $true from older files.
    $processedInstances = @{}
    foreach ($k in $entProcessed.Keys) { $processedInstances[$k] = $entProcessed[$k] }
    foreach ($k in $rvProcessed.Keys)  {
        if (-not $processedInstances.ContainsKey($k)) { $processedInstances[$k] = $rvProcessed[$k] }
    }

    # --- Load cached campaign series ---
    $seriesParams = @{ MinInstances = $MinInstances }
    if (-not [string]::IsNullOrWhiteSpace($CachePath)) { $seriesParams['CachePath'] = $CachePath }
    if (-not [string]::IsNullOrWhiteSpace($CorrelationID)) { $seriesParams['CorrelationID'] = $CorrelationID }

    $seriesResult = Get-SPCachedCampaignSeries @seriesParams
    if (-not $seriesResult.Success -or $null -eq $seriesResult.Data) {
        $emptyResult.Error = "Cache read failed: $($seriesResult.Error)"
        Write-Warning "Invoke-SPStateTracking: $($emptyResult.Error)"
        return $emptyResult
    }

    $allSeries = @($seriesResult.Data.Series)
    $seriesDetected = @{}
    $totalEntNew = 0; $totalEntChanged = 0
    $totalRvNew = 0; $totalRvUpdated = 0
    $allNewlyDecided = [System.Collections.Generic.List[object]]::new()
    $allReApproved   = [System.Collections.Generic.List[object]]::new()
    $instancesProcessed = 0
    $resolveFailures = 0
    $rosterFailures = 0
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    # --- Process each series, each instance ---
    foreach ($series in $allSeries) {
        $seriesStem = [string]$series.SeriesStem
        if (-not $seriesDetected.ContainsKey($seriesStem)) { $seriesDetected[$seriesStem] = 0 }

        $instances = @($series.Instances)

        foreach ($inst in $instances) {
            $campId = [string]$inst.CampaignId
            if ([string]::IsNullOrWhiteSpace($campId)) { continue }

            # Skip instances already processed in a TERMINAL state. ACTIVE instances are
            # never marked processed, so they re-process every run until they complete --
            # otherwise a mid-day snapshot freezes reviewers as 'missed' forever.
            if ($processedInstances.ContainsKey($campId)) { continue }

            $campName = [string]$inst.CampaignName
            $campStatus = [string]$inst.Status
            $isUnverified = $false
            if ($null -ne $inst.PSObject.Properties['Unverified']) { $isUnverified = [bool]$inst.Unverified }

            # Derive instance date: PeriodToken first, CachedAt second, TodayLabel last.
            # Invariant culture throughout; [datetime]::MinValue CachedAt is meaningless.
            $instDate = ''
            $periodToken = ''
            if ($null -ne $inst.PSObject.Properties['PeriodToken']) { $periodToken = [string]$inst.PeriodToken }
            if (-not [string]::IsNullOrWhiteSpace($periodToken)) {
                $pdt = [datetime]::MinValue
                if ([datetime]::TryParse($periodToken, $invariant, [System.Globalization.DateTimeStyles]::None, [ref]$pdt)) {
                    $instDate = $pdt.ToString('yyyy-MM-dd', $invariant)
                }
            }
            if ([string]::IsNullOrWhiteSpace($instDate) -and $null -ne $inst.PSObject.Properties['CachedAt']) {
                $cachedAtRaw = $inst.CachedAt
                $cdt = [datetime]::MinValue
                if ($cachedAtRaw -is [datetime]) { $cdt = $cachedAtRaw }
                else {
                    [void][datetime]::TryParse([string]$cachedAtRaw, $invariant, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$cdt)
                }
                if ($cdt -ne [datetime]::MinValue) {
                    $instDate = $cdt.ToString('yyyy-MM-dd', $invariant)
                }
            }
            if ([string]::IsNullOrWhiteSpace($instDate)) { $instDate = $TodayLabel }

            # Load items and roster. The reader's LoadItems returns `, $list.ToArray()`
            # (the array as ONE pipeline object), so @(& ...) yields a single element
            # that IS the item array -- without the flatten below, the whole array was
            # passed to Resolve-SPSeriesItemState as one "item", every fact came back
            # blank, and state records silently keyed to ''. Same defensive flatten as
            # Get-SPSeriesInstanceCompletion.
            $rawItems = @()
            $roster = @()
            try {
                if ($null -ne $inst.PSObject.Properties['LoadItems'] -and $null -ne $inst.LoadItems) {
                    $loaded = @(& $inst.LoadItems)
                    $flat = [System.Collections.Generic.List[object]]::new()
                    foreach ($el in $loaded) {
                        if ($null -eq $el) { continue }
                        if (($el -is [System.Collections.IEnumerable]) -and ($el -isnot [string]) -and ($el -isnot [System.Collections.IDictionary]) -and ($el -isnot [pscustomobject])) {
                            foreach ($sub in $el) { if ($null -ne $sub) { $flat.Add($sub) } }
                        }
                        else { $flat.Add($el) }
                    }
                    $rawItems = @($flat.ToArray())
                }
            } catch {
                Write-Warning "    Failed to load items for $campName : $($_.Exception.Message)"
                continue
            }
            try {
                if ($null -ne $inst.PSObject.Properties['LoadRoster'] -and $null -ne $inst.LoadRoster) {
                    $loadedR = @(& $inst.LoadRoster)
                    $flatR = [System.Collections.Generic.List[object]]::new()
                    foreach ($el in $loadedR) {
                        if ($null -eq $el) { continue }
                        if (($el -is [System.Collections.IEnumerable]) -and ($el -isnot [string]) -and ($el -isnot [System.Collections.IDictionary]) -and ($el -isnot [pscustomobject])) {
                            foreach ($sub in $el) { if ($null -ne $sub) { $flatR.Add($sub) } }
                        }
                        else { $flatR.Add($el) }
                    }
                    $roster = @($flatR.ToArray())
                }
            } catch {
                $rosterFailures++
                Write-Warning "    Failed to load roster for $campName : $($_.Exception.Message) -- reviewer attribution degrades to (Unassigned)"
            }

            if ($rawItems.Count -eq 0) { continue }

            # Resolve each item through SP.CampaignSeries honest classifier
            $resolvedItems = [System.Collections.Generic.List[object]]::new()
            foreach ($rawItem in $rawItems) {
                try {
                    $resolved = Resolve-SPSeriesItemState -Item $rawItem -Roster $roster `
                        -Unverified $isUnverified -Status $campStatus
                    if ($null -ne $resolved) {
                        $resolvedItems.Add($resolved)
                    }
                } catch {
                    $resolveFailures++
                }
            }

            if ($resolvedItems.Count -eq 0) { continue }

            $seriesDetected[$seriesStem]++
            Write-Host "    [$seriesStem] $campName ($($resolvedItems.Count) items, $instDate, $campStatus)" -ForegroundColor DarkGray

            # Update entitlement state (scope + pruning happen ONCE, globally, below)
            $entUpdate = Update-SPEntitlementState -StateMap $entStateMap `
                -ResolvedItems $resolvedItems.ToArray() `
                -InstanceId $campId -InstanceDate $instDate -SeriesName $seriesStem `
                -TodayLabel $TodayLabel

            $totalEntNew += $entUpdate.StateNew
            $totalEntChanged += $entUpdate.StateChanged
            foreach ($nd in $entUpdate.NewlyDecided) { $allNewlyDecided.Add($nd) }
            if ($entUpdate.ContainsKey('ReApproved')) {
                foreach ($ra in $entUpdate.ReApproved) { $allReApproved.Add($ra) }
            }

            # Update reviewer state
            $rvUpdate = Update-SPReviewerState -ReviewerMap $rvReviewerMap `
                -ResolvedItems $resolvedItems.ToArray() `
                -InstanceId $campId -InstanceDate $instDate `
                -SeriesName $seriesStem -InstanceStatus $campStatus `
                -TodayLabel $TodayLabel

            $totalRvNew += $rvUpdate.ReviewersNew
            $totalRvUpdated += $rvUpdate.ReviewersUpdated
            $instancesProcessed++

            # Mark processed ONLY for terminal statuses; ACTIVE/STAGED re-process until done.
            $statusUp = $campStatus.ToUpperInvariant()
            if ($statusUp -ne 'ACTIVE' -and $statusUp -ne 'STAGED') {
                $processedInstances[$campId] = @{
                    processedDate = $TodayLabel
                    instanceDate  = $instDate
                    series        = $seriesStem
                    status        = $campStatus
                }
            }
        }
    }

    if ($resolveFailures -gt 0) {
        Write-Warning "Invoke-SPStateTracking: $resolveFailures item(s) failed honest classification and were skipped -- state under-counts by that amount."
    }

    # --- Global scope detection (per-series newest instance, ALL-TIME) ---
    # Build seriesName -> newest instance date from the rich processedInstances values
    # PLUS the instances seen this run (covers still-ACTIVE ones not yet marked).
    $seriesNewestDates = @{}
    foreach ($k in $processedInstances.Keys) {
        $v = $processedInstances[$k]
        if ($v -is [hashtable] -and $v.ContainsKey('series') -and $v.ContainsKey('instanceDate')) {
            $s = [string]$v['series']; $d = [string]$v['instanceDate']
            if ([string]::IsNullOrWhiteSpace($s) -or [string]::IsNullOrWhiteSpace($d)) { continue }
            if (-not $seriesNewestDates.ContainsKey($s) -or ($d -gt [string]$seriesNewestDates[$s])) {
                $seriesNewestDates[$s] = $d
            }
        }
    }
    foreach ($series in $allSeries) {
        $seriesStem = [string]$series.SeriesStem
        foreach ($inst in @($series.Instances)) {
            $ptok = ''
            if ($null -ne $inst.PSObject.Properties['PeriodToken']) { $ptok = [string]$inst.PeriodToken }
            $pdt = [datetime]::MinValue
            if (-not [string]::IsNullOrWhiteSpace($ptok) -and
                [datetime]::TryParse($ptok, $invariant, [System.Globalization.DateTimeStyles]::None, [ref]$pdt)) {
                $d = $pdt.ToString('yyyy-MM-dd', $invariant)
                if (-not $seriesNewestDates.ContainsKey($seriesStem) -or ($d -gt [string]$seriesNewestDates[$seriesStem])) {
                    $seriesNewestDates[$seriesStem] = $d
                }
            }
        }
    }

    $sweep = Invoke-SPEntitlementScopeSweep -StateMap $entStateMap `
        -SeriesNewestDates $seriesNewestDates -TodayLabel $TodayLabel
    $allDropped = $sweep.DroppedFromScope

    # --- Compute StateSummary from final state ---
    $stateSummary = @{ APPROVE = 0; REVOKE = 0; PENDING = 0; UNDECIDED = 0 }
    foreach ($ik in $entStateMap.Keys) {
        $rec = $entStateMap[$ik]
        if ([bool]$rec.inCurrentScope) {
            $dec = [string]$rec.currentDecision
            if ($stateSummary.ContainsKey($dec)) { $stateSummary[$dec]++ }
        }
    }

    # --- Write state files (envelopes CHECKED -- a failed write must not report success) ---
    $entWrite = Write-SPEntitlementState -StateMap $entStateMap -Path $entPath `
        -ProcessedInstances $processedInstances -LastRunDate $TodayLabel
    $rvWrite = Write-SPReviewerState -ReviewerMap $rvReviewerMap -Path $rvPath `
        -ProcessedInstances $processedInstances -LastRunDate $TodayLabel

    $writeErrors = @()
    if (-not $entWrite.Success) { $writeErrors += "entitlement-state.jsonl write failed: $($entWrite.Error)" }
    if (-not $rvWrite.Success)  { $writeErrors += "reviewer-state.jsonl write failed: $($rvWrite.Error)" }
    if ($writeErrors.Count -gt 0) {
        foreach ($we in $writeErrors) { Write-Warning "Invoke-SPStateTracking: $we" }
    }

    # --- Return results ---
    return @{
        Success = ($writeErrors.Count -eq 0)
        Error   = ($writeErrors -join '; ')
        InstancesProcessed = $instancesProcessed
        Entitlement = @{
            StateMap         = $entStateMap
            Total            = $entStateMap.Count
            IsFirstRun       = -not $entRead.Exists
            FilePath         = $entPath
            NewlyDecided     = $allNewlyDecided
            ReApproved       = $allReApproved
            DroppedFromScope = $allDropped
            StateSummary     = $stateSummary
            StateNew         = $totalEntNew
            StateChanged     = $totalEntChanged
            PriorSnapshot    = @{}
            LastRunDate      = $TodayLabel
        }
        Reviewer = @{
            ReviewerMap      = $rvReviewerMap
            Total            = $rvReviewerMap.Count
            IsFirstRun       = -not $rvRead.Exists
            FilePath         = $rvPath
            ReviewersNew     = $totalRvNew
            ReviewersUpdated = $totalRvUpdated
            SeriesDetected   = $seriesDetected
            LastRunDate      = $TodayLabel
        }
    }

    }
    finally {
        try { $runMutex.ReleaseMutex() } catch { }
        $runMutex.Dispose()
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
            SkippedLines = 0
        }
        Reviewer = @{
            ReviewerMap = @{}; Total = 0; IsFirstRun = $true; FilePath = ''
            ReviewersNew = 0; ReviewersUpdated = 0; SeriesDetected = @{}; LastRunDate = ''
            SkippedLines = 0
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
        $result.Entitlement.SkippedLines = $entRead.SkippedLines

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
        $result.Reviewer.SkippedLines = $rvRead.SkippedLines
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
        Every report script (V4, V4e, V7, V7c, V8) needs the same date-range
        resolution logic. This function centralizes it so scripts don't reimplement.

        Precedence: explicit StartDate/EndDate override DaysBack. Missing EndDate
        defaults to today. Missing StartDate defaults to today minus DaysBack.

        An UNPARSEABLE explicit date sets Valid=$false and names the offender in
        Error -- callers must surface it (exit 2 per the report exit-code contract)
        instead of silently substituting the default window.
    .PARAMETER DaysBack
        Lookback window in days. Default 7.
    .PARAMETER StartDate
        Explicit start date (yyyy-MM-dd). Overrides DaysBack.
    .PARAMETER EndDate
        Explicit end date (yyyy-MM-dd). Defaults to today.
    .OUTPUTS
        Hashtable with StartDate, EndDate (yyyy-MM-dd strings), DaysBack (int),
        Valid (bool), Error (string).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [int]$DaysBack = 7,
        [string]$StartDate,
        [string]$EndDate
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $resolvedStart = ''
    $resolvedEnd   = ''
    $valid = $true
    $err = ''

    if (-not [string]::IsNullOrWhiteSpace($StartDate)) {
        $sdt = [datetime]::MinValue
        if ([datetime]::TryParse($StartDate, $invariant, [System.Globalization.DateTimeStyles]::None, [ref]$sdt)) {
            $resolvedStart = $sdt.ToString('yyyy-MM-dd', $invariant)
        }
        else { $valid = $false; $err = "Invalid StartDate '$StartDate' (expected yyyy-MM-dd)" }
    }
    if (-not [string]::IsNullOrWhiteSpace($EndDate)) {
        $edt = [datetime]::MinValue
        if ([datetime]::TryParse($EndDate, $invariant, [System.Globalization.DateTimeStyles]::None, [ref]$edt)) {
            $resolvedEnd = $edt.ToString('yyyy-MM-dd', $invariant)
        }
        else {
            $valid = $false
            $err = if ([string]::IsNullOrWhiteSpace($err)) { "Invalid EndDate '$EndDate' (expected yyyy-MM-dd)" } else { "$err; Invalid EndDate '$EndDate'" }
        }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedStart)) {
        $effectiveDays = if ($DaysBack -gt 0) { $DaysBack } else { 7 }
        $resolvedStart = (Get-Date).AddDays(-$effectiveDays).ToString('yyyy-MM-dd', $invariant)
    }
    if ([string]::IsNullOrWhiteSpace($resolvedEnd)) {
        $resolvedEnd = (Get-Date).ToString('yyyy-MM-dd', $invariant)
    }

    return @{
        StartDate = $resolvedStart
        EndDate   = $resolvedEnd
        DaysBack  = $DaysBack
        Valid     = $valid
        Error     = $err
    }
}

function Select-SPSeriesByCampaignName {
    <#
    .SYNOPSIS
        Filters a series list by campaign name substring or prefix match.
    .DESCRIPTION
        Every cache-based report script (V4c/V4d/V4e/V8) needs the same campaign
        name filtering on series instances. This function centralizes it so scripts
        call one line instead of duplicating the filter block.

        Instances whose CampaignName does not match are removed. Series that drop
        below MinInstances after filtering are removed entirely.
    .PARAMETER SeriesList
        Array of series hashtables from Get-SPCachedCampaignSeries.
    .PARAMETER CampaignNameContains
        Substring filter (case-insensitive). Instances whose CampaignName does not
        contain this string are removed.
    .PARAMETER CampaignNameStartsWith
        Prefix filter (case-insensitive).
    .PARAMETER CampaignName
        Exact match filter (case-insensitive).
    .PARAMETER MinInstances
        Minimum remaining instances for a series to survive filtering. Default 1.
    .OUTPUTS
        Filtered array of series hashtables.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$SeriesList,

        [string]$CampaignNameContains,
        [string]$CampaignNameStartsWith,
        [string]$CampaignName,
        [int]$MinInstances = 1
    )

    $hasFilter = (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) -or
                 (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) -or
                 (-not [string]::IsNullOrWhiteSpace($CampaignName))
    if (-not $hasFilter) { return $SeriesList }

    $filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $SeriesList) {
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($inst in @($s.Instances)) {
            $cn = [string]$inst.CampaignName
            $pass = $true
            if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains) -and
                $cn.IndexOf($CampaignNameContains, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                $pass = $false
            }
            if (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith) -and
                -not $cn.StartsWith($CampaignNameStartsWith, [System.StringComparison]::OrdinalIgnoreCase)) {
                $pass = $false
            }
            if (-not [string]::IsNullOrWhiteSpace($CampaignName) -and
                -not $cn.Equals($CampaignName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $pass = $false
            }
            if ($pass) { $kept.Add($inst) }
        }
        if ($kept.Count -ge $MinInstances) {
            $s.Instances = @($kept.ToArray())
            $s.InstanceCount = $kept.Count
            $filtered.Add($s)
        }
    }
    return @($filtered.ToArray())
}

Export-ModuleMember -Function @(
    'Invoke-SPStateTracking',
    'Read-SPStateFiles',
    'Resolve-SPReportDateRange',
    'Select-SPSeriesByCampaignName'
)

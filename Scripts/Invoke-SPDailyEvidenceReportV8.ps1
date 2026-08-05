#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the daily evidence report (v8) -- fast, state-powered HTML report
    that reads pre-computed entitlement and reviewer state files.
.DESCRIPTION
    V8 reads entitlement-state.jsonl and reviewer-state.jsonl (populated by
    Update-SPStateFiles.ps1) plus lightweight campaign metadata from
    daily-metrics.jsonl. V8 never calls the ISC API. Target execution: <30 seconds.

    NOT strictly read-only by default: when the state files are missing or stale,
    V8 AUTO-REFRESHES them from the cache (Invoke-SPStateTracking), which REWRITES
    both state files. Pass -NoRefresh for a guaranteed read-only run.

    Scope honesty: Sections 1-4 show CURRENT CUMULATIVE state as of the state
    files' last update; only Section 2 (Newly Decided) is filtered by the date
    window. When a campaign filter is supplied, Sections 1-4 are filtered to the
    matching campaign SERIES; Sections 5-7 always cover all reviewers.

    Data sources:
      {Metrics.Path}/entitlement-state.jsonl  (via Read-SPStateFiles)
      {Metrics.Path}/reviewer-state.jsonl     (via Read-SPStateFiles)
      {Metrics.Path}/daily-metrics.jsonl      (campaign summary, optional)

    Report sections (8):
      1  Entitlement State Summary (KPI tiles)
      2  Newly Decided (state transitions in the date window) + Re-Approved After
         Revoke sub-table (observed REVOKE -> APPROVE re-grants in the window)
      3  Chronically Unreviewed (consecutiveUndecided >= threshold)
      4  Dropped from Scope (inCurrentScope == false)
      5  Reviewer Engagement Summary (score table + KPI tiles)
      6  Reviewer Weekly Compliance (current ISO week misses)
      7  Reviewer Engagement Heatmap (14-day dayLog grid)
      8  Campaign Summary (last N days from daily-metrics.jsonl)

    Exit codes:
        0 = Normal
        2 = Parameter error
        4 = Configuration error
        5 = No state data (run Update-SPStateFiles.ps1 first)
.PARAMETER MetricsPath
    Override the metrics directory. Defaults to Metrics.Path from settings.json.
.PARAMETER OutputPath
    Directory for output files. Defaults to daily-evidence subdirectory.
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER ChronicThreshold
    Campaigns with PENDING/UNDECIDED before flagging as chronic. Default: 5.
.PARAMETER OutputMode
    Console: formatted summary to terminal.
    HTML: self-contained HTML report file.
    Both (default): console output and HTML file.
.PARAMETER Help
    Display detailed help.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV8.ps1
    # Generate state-powered daily evidence report.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV8.ps1 -ChronicThreshold 3
    # Lower the chronic-unreviewed threshold to 3 consecutive campaigns.
.NOTES
    Script:  Invoke-SPDailyEvidenceReportV8.ps1
    Version: 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter()]
    [int]$DaysBack = 7,

    [Parameter()]
    [string]$StartDate,

    [Parameter()]
    [string]$EndDate,

    [Parameter()]
    [string]$CampaignName,

    [Parameter()]
    [string]$CampaignNameStartsWith,

    [Parameter()]
    [string]$CampaignNameContains,

    [Parameter()]
    [ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')]
    [string[]]$Status,

    [Parameter()]
    [string]$MetricsPath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [int]$ChronicThreshold = 5,

    [Parameter()]
    [ValidateSet('Console', 'HTML', 'Both')]
    [string]$OutputMode = 'Both',

    [Parameter()]
    [switch]$NoRefresh,

    [Parameter()]
    [switch]$AutoFetch,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [Alias('?')]
    [switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

#region Module Load

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$toolkitRoot = Split-Path -Parent $scriptRoot

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1'; Name = 'SP.Shared'; Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';  Required = $true  }
)

foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) {
        Import-Module $mod.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        $moduleDir = Split-Path -Parent $mod.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
            }
        }
        elseif ($mod.Required) {
            Write-Host "ERROR: Required module '$($mod.Name)' not found at: $($mod.Path)" -ForegroundColor Red
            exit 4
        }
    }
}

#endregion

#region Helper Functions

function Get-V8Prop {
    param($Object, [string]$Name, $Default = '')
    return (Get-SPObjectProperty -Object $Object -Name $Name -Default $Default)
}

function Get-V8SafeInt {
    param($Object, [string]$Name, [int]$Default = 0)
    $v = Get-V8Prop -Object $Object -Name $Name -Default $Default
    if ($null -eq $v) { return $Default }
    try { return [int]$v } catch { return $Default }
}

function Get-V8PrimarySeries {
    <#
    .SYNOPSIS
        Returns the series name with the most campaignsObserved for a reviewer.
    #>
    param([hashtable]$ReviewerRec)
    $seriesMap = $null
    if ($ReviewerRec.ContainsKey('series')) { $seriesMap = $ReviewerRec['series'] }
    if ($null -eq $seriesMap -or $seriesMap.Count -eq 0) { return '(none)' }
    $best = ''; $bestCount = -1
    foreach ($sn in $seriesMap.Keys) {
        $sd = $seriesMap[$sn]
        $obs = 0
        if ($sd -is [hashtable] -and $sd.ContainsKey('campaignsObserved')) {
            $obs = [int]$sd['campaignsObserved']
        }
        if ($obs -gt $bestCount) { $bestCount = $obs; $best = $sn }
    }
    return $best
}

function Get-V8PrimarySeriesData {
    param([hashtable]$ReviewerRec)
    $primary = Get-V8PrimarySeries -ReviewerRec $ReviewerRec
    if ($primary -eq '(none)') { return $null }
    $seriesMap = $ReviewerRec['series']
    if ($seriesMap.ContainsKey($primary)) { return $seriesMap[$primary] }
    return $null
}

function Get-V8DayLogEntries {
    <#
    .SYNOPSIS
        Parses a dayLog string (e.g. "C:20260601|M:20260602") into an ordered list
        of [hashtable] with keys Date (yyyyMMdd) and State (C/P/M/U). Day keys carry
        the year (v2.1 state format) so January never sorts before last December.
    #>
    param([string]$DayLog)
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    if ([string]::IsNullOrWhiteSpace($DayLog)) { return $entries }
    foreach ($part in $DayLog.Split('|')) {
        if ($part.Length -ge 10 -and $part[1] -eq ':') {
            $entries.Add(@{ Date = $part.Substring(2); State = [string]$part[0] })
        }
    }
    return $entries
}

function Get-V8CurrentIsoWeek {
    # True ISO-8601 week (Thursday rule) via the shared SP.ReviewerState helper.
    return (Get-SPIsoWeekString -Date (Get-Date))
}

#endregion

#region Setup

$startTime = Get-Date
$correlationID = [guid]::NewGuid().ToString()
$todayLabel = $startTime.ToString('yyyy-MM-dd')

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Daily Evidence Report (v8) -- State-Powered Visualization' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

try { Initialize-SPLogging -ErrorAction SilentlyContinue } catch { }
try {
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV8 started: CorrelationID=$correlationID" `
        -Severity INFO -Component 'DailyEvidenceV8' -Action 'Start' -CorrelationID $correlationID
} catch { }

# Resolve config
$cfgPath = $ConfigPath
if ([string]::IsNullOrWhiteSpace($cfgPath)) {
    try { $cfgPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot } catch { }
    if ([string]::IsNullOrWhiteSpace($cfgPath)) {
        $defaultCfg = Join-Path $toolkitRoot 'settings.json'
        if (Test-Path $defaultCfg) { $cfgPath = $defaultCfg }
    }
}

$config = $null
if (-not [string]::IsNullOrWhiteSpace($cfgPath) -and (Test-Path $cfgPath)) {
    try { $config = Get-SPConfig -ConfigPath $cfgPath }
    catch { Write-Host "WARN: Failed to load configuration: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Resolve metrics path
$metricsDir = $MetricsPath
if ([string]::IsNullOrWhiteSpace($metricsDir) -and $null -ne $config) {
    try {
        if ($null -ne $config.PSObject.Properties['Metrics'] -and
            $null -ne $config.Metrics -and
            $null -ne $config.Metrics.PSObject.Properties['Path'] -and
            -not [string]::IsNullOrWhiteSpace($config.Metrics.Path)) {
            $metricsDir = [string]$config.Metrics.Path
        }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($metricsDir)) {
    $metricsDir = Join-Path $toolkitRoot (Join-Path 'Audit' 'metrics')
}
if (-not [System.IO.Path]::IsPathRooted($metricsDir)) {
    $metricsDir = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $metricsDir))
}

# Resolve output path
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $deOutputPath = $null
    if ($null -ne $config) {
        try {
            if ($null -ne $config.PSObject.Properties['DailyEvidence'] -and
                $null -ne $config.DailyEvidence -and
                $null -ne $config.DailyEvidence.PSObject.Properties['OutputPath'] -and
                -not [string]::IsNullOrWhiteSpace($config.DailyEvidence.OutputPath)) {
                $deOutputPath = [string]$config.DailyEvidence.OutputPath
            }
        } catch { }
    }
    if ($null -ne $deOutputPath) {
        $effectiveOutputPath = $deOutputPath
    }
    elseif ($null -ne $config -and $null -ne $config.PSObject.Properties['Audit'] -and
        $null -ne $config.Audit -and
        $null -ne $config.Audit.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
        $effectiveOutputPath = Join-Path ([string]$config.Audit.OutputPath) 'daily-evidence'
    }
    else {
        $effectiveOutputPath = Join-Path $toolkitRoot (Join-Path 'Audit' 'daily-evidence')
    }
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) {
    $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath
}
if (-not (Test-Path $effectiveOutputPath)) {
    New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null
}

# Resolve date range (shared helper from SP.StateOrchestrator). Invalid explicit
# dates are a PARAMETER ERROR (exit 2), never a silent fallback to the default window.
$dateRange = Resolve-SPReportDateRange -DaysBack $DaysBack -StartDate $StartDate -EndDate $EndDate
if (-not $dateRange.Valid) {
    Write-Host "  ERROR: $($dateRange.Error)" -ForegroundColor Red
    exit 2
}
$filterStartDate = $dateRange.StartDate
$filterEndDate   = $dateRange.EndDate
Write-Host "  Date range:    $filterStartDate to $filterEndDate" -ForegroundColor DarkGray

# Campaign name filter (for JSONL campaign summary + auto-refresh series filtering)
$campaignFilter = @{}
if (-not [string]::IsNullOrWhiteSpace($CampaignName))           { $campaignFilter['CampaignName'] = $CampaignName }
if (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) { $campaignFilter['CampaignNameStartsWith'] = $CampaignNameStartsWith }
if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains))   { $campaignFilter['CampaignNameContains'] = $CampaignNameContains }
$hasCampaignFilter = $campaignFilter.Count -gt 0
if ($hasCampaignFilter) {
    $filterDesc = ($campaignFilter.Keys | ForEach-Object { "$_='$($campaignFilter[$_])'" }) -join ', '
    Write-Host "  Campaign:      $filterDesc" -ForegroundColor DarkGray
}

#endregion

#region Step 0: Data Pipeline Check (opt-in via -AutoFetch)

if ($AutoFetch) {
    Write-Host '  Step 0: Data pipeline check (-AutoFetch)' -ForegroundColor Cyan

    # Initialize ISC session if -Token provided
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        try {
            Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes
            Write-Host '    ISC session initialized from -Token' -ForegroundColor DarkGray
        }
        catch {
            Write-Host "  ERROR: Failed to initialize ISC token: $($_.Exception.Message)" -ForegroundColor Red
            exit 4
        }
    }

    # Check if cache has items
    $v8CacheDir = $null
    try {
        $v8Cfg = Get-SPConfig
        if ($null -ne $v8Cfg.Audit -and $null -ne $v8Cfg.Audit.PSObject.Properties['CachePath'] -and
            -not [string]::IsNullOrWhiteSpace($v8Cfg.Audit.CachePath)) {
            $v8CacheDir = [string]$v8Cfg.Audit.CachePath
        }
        elseif ($null -ne $v8Cfg.Audit -and $null -ne $v8Cfg.Audit.PSObject.Properties['OutputPath'] -and
                -not [string]::IsNullOrWhiteSpace($v8Cfg.Audit.OutputPath)) {
            $v8CacheDir = Join-Path ([string]$v8Cfg.Audit.OutputPath) '.cache'
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($v8CacheDir)) { $v8CacheDir = Join-Path $toolkitRoot (Join-Path 'Audit' '.cache') }
    if (-not [System.IO.Path]::IsPathRooted($v8CacheDir)) { $v8CacheDir = Join-Path $toolkitRoot $v8CacheDir }

    $v8CacheFiles = @()
    if (Test-Path $v8CacheDir) {
        $v8CacheFiles = @(Get-ChildItem -Path $v8CacheDir -Filter 'items-*.jsonl' -File -ErrorAction SilentlyContinue)
    }

    if ($v8CacheFiles.Count -eq 0) {
        Write-Host '    Cache is empty -- populating from ISC...' -ForegroundColor Yellow

        $fetchParams = @{ DaysBack = $DaysBack; CorrelationID = $correlationID }
        if (-not [string]::IsNullOrWhiteSpace($CampaignName))           { $fetchParams['CampaignName']           = $CampaignName }
        if (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) { $fetchParams['CampaignNameStartsWith'] = $CampaignNameStartsWith }
        if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains))   { $fetchParams['CampaignNameContains']   = $CampaignNameContains }
        if ($null -ne $Status -and $Status.Count -gt 0)                 { $fetchParams['Status']                 = $Status }

        $fetchResult = Invoke-SPCachePopulate @fetchParams
        if ($fetchResult.Success) {
            Write-Host "    Cached $($fetchResult.ItemCount) items from $($fetchResult.CampaignCount) campaign(s), $($fetchResult.CertCount) cert(s)" -ForegroundColor Green
        }
        else {
            Write-Host "    ERROR: Cache population failed: $($fetchResult.Error)" -ForegroundColor Red
            Write-Host '    Cannot proceed without cached data.' -ForegroundColor Red
            exit 4
        }
    }
    else {
        Write-Host "    Cache has $($v8CacheFiles.Count) campaign(s) -- using existing data" -ForegroundColor DarkGray
    }

    Write-Host ''
}

#endregion

#region Step 1: Read State Files

Write-Host '  Step 1: Read state files' -ForegroundColor Cyan
Write-Host "    Metrics dir: $metricsDir" -ForegroundColor DarkGray

$tracking = Read-SPStateFiles -MetricsPath $metricsDir

# Auto-refresh: if EITHER state file is missing or stale (not updated today), rebuild
# from cache (delta mode -- ACTIVE instances re-process; terminal ones skip). Suppressed
# by -NoRefresh for a guaranteed read-only run. The orchestrator holds a global mutex,
# so an overlapping Update-SPStateFiles.ps1 cannot interleave.
$isStale = $tracking.Entitlement.IsFirstRun -or $tracking.Reviewer.IsFirstRun -or
           ([string]$tracking.Entitlement.LastRunDate -ne $todayLabel) -or
           ([string]$tracking.Reviewer.LastRunDate -ne $todayLabel)
if ($isStale -and -not $NoRefresh) {
    $staleReason = if ($tracking.Entitlement.IsFirstRun -or $tracking.Reviewer.IsFirstRun) { 'state file(s) missing' } else { "last updated $($tracking.Entitlement.LastRunDate)" }
    Write-Host "    Auto-refresh needed ($staleReason)" -ForegroundColor Yellow
    Write-Host '    Updating from cache...' -ForegroundColor Yellow
    try {
        $refresh = Invoke-SPStateTracking -MetricsPath $metricsDir -TodayLabel $todayLabel
        if ($refresh.Success) {
            $tracking = $refresh
            Write-Host "    Refreshed: $($tracking.Entitlement.Total) entitlements, $($tracking.Reviewer.Total) reviewers" -ForegroundColor Green
        }
        else {
            Write-Host "    WARN: Auto-refresh failed: $($refresh.Error)" -ForegroundColor Yellow
            Write-Host '    Continuing with existing state data (may be incomplete).' -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "    WARN: Auto-refresh failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '    Continuing with existing state data (may be incomplete).' -ForegroundColor Yellow
        $tracking = Read-SPStateFiles -MetricsPath $metricsDir
    }
}
elseif ($isStale) {
    Write-Host '    State is stale but -NoRefresh was passed -- rendering existing data as-is.' -ForegroundColor Yellow
}

# Surface corrupt-line counts (Read-SPStateFiles reports them; silence hides shrinkage).
foreach ($side in @('Entitlement', 'Reviewer')) {
    $sk2 = 0
    if ($tracking[$side].ContainsKey('SkippedLines')) { $sk2 = [int]$tracking[$side].SkippedLines }
    if ($sk2 -gt 0) {
        Write-Host "    WARN: $side state file had $sk2 unparseable line(s) -- records may be missing." -ForegroundColor Yellow
    }
}

# Campaign SERIES filter for the state sections: entitlement records carry seriesName,
# so a campaign filter can honestly narrow Sections 1-4 (previously the filter applied
# only to Section 8 while the state sections silently stayed tenant-wide).
$seriesFilterActive = $hasCampaignFilter
function Test-V8SeriesMatch {
    param([string]$SeriesName)
    if (-not $seriesFilterActive) { return $true }
    if ([string]::IsNullOrWhiteSpace($SeriesName)) { return $false }
    if ($campaignFilter.ContainsKey('CampaignNameContains')) {
        return ($SeriesName.IndexOf($campaignFilter['CampaignNameContains'], [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    if ($campaignFilter.ContainsKey('CampaignNameStartsWith')) {
        return $SeriesName.StartsWith($campaignFilter['CampaignNameStartsWith'], [System.StringComparison]::OrdinalIgnoreCase)
    }
    if ($campaignFilter.ContainsKey('CampaignName')) {
        # Exact campaign names carry date suffixes; compare series stems.
        $fStem = ''
        if (Get-Command Get-SPCampaignSeriesKey -ErrorAction Ignore) {
            $fk = Get-SPCampaignSeriesKey -Name ([string]$campaignFilter['CampaignName'])
            if ($fk.Success) { $fStem = [string]$fk.Data.SeriesStem }
        }
        if ([string]::IsNullOrWhiteSpace($fStem)) { $fStem = [string]$campaignFilter['CampaignName'] }
        return ($SeriesName -ieq $fStem)
    }
    return $true
}

$entStateMap  = $tracking.Entitlement.StateMap
if ($seriesFilterActive) {
    $filteredMap = @{}
    foreach ($sk in $entStateMap.Keys) {
        $rec = $entStateMap[$sk]
        $recSeries = ''
        if ($rec.ContainsKey('seriesName')) { $recSeries = [string]$rec['seriesName'] }
        if (Test-V8SeriesMatch -SeriesName $recSeries) { $filteredMap[$sk] = $rec }
    }
    Write-Host "    Series filter: $($filteredMap.Count) of $($entStateMap.Count) entitlement records match" -ForegroundColor DarkGray
    $entStateMap = $filteredMap
    # Recompute the summary over the filtered set
    $filteredSummary = @{ APPROVE = 0; REVOKE = 0; PENDING = 0; UNDECIDED = 0 }
    foreach ($sk in $entStateMap.Keys) {
        $rec = $entStateMap[$sk]
        $inS = $true
        if ($rec.ContainsKey('inCurrentScope')) { $inS = [bool]$rec['inCurrentScope'] }
        if ($inS) {
            $dec2 = [string]$rec['currentDecision']
            if ($filteredSummary.ContainsKey($dec2)) { $filteredSummary[$dec2]++ }
        }
    }
    $tracking.Entitlement.StateSummary = $filteredSummary
}
$entTotal     = $entStateMap.Count
$entSummary   = $tracking.Entitlement.StateSummary
$entLastRun   = $tracking.Entitlement.LastRunDate

$rvReviewerMap = $tracking.Reviewer.ReviewerMap
$rvTotal       = $tracking.Reviewer.Total
$rvLastRun     = $tracking.Reviewer.LastRunDate

$lastRunDate = $entLastRun
if ([string]::IsNullOrWhiteSpace($lastRunDate)) { $lastRunDate = $rvLastRun }
if ([string]::IsNullOrWhiteSpace($lastRunDate)) { $lastRunDate = '(unknown)' }

Write-Host "    Entitlement records: $entTotal" -ForegroundColor DarkGray
Write-Host "    Reviewer records:    $rvTotal" -ForegroundColor DarkGray
Write-Host "    Last updated:        $lastRunDate" -ForegroundColor DarkGray

# Count in-scope
$inScopeCount = 0
foreach ($sk in $entStateMap.Keys) {
    $rec = $entStateMap[$sk]
    $inScope = $true
    if ($rec.ContainsKey('inCurrentScope')) { $inScope = [bool]$rec['inCurrentScope'] }
    if ($inScope) { $inScopeCount++ }
}

Write-Host "    In-scope items:      $inScopeCount" -ForegroundColor DarkGray
Write-Host ''

#endregion

#region Step 2: Read daily-metrics.jsonl (campaign summary, optional)

Write-Host '  Step 2: Read campaign metrics (optional)' -ForegroundColor Cyan

$jsonlPath = Join-Path $metricsDir 'daily-metrics.jsonl'
$campaignRecords = [System.Collections.Generic.List[object]]::new()

if (Test-Path $jsonlPath) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $rawLines = [System.IO.File]::ReadAllLines($jsonlPath, $utf8)
    foreach ($ln in $rawLines) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        try {
            $rec = $ln | ConvertFrom-Json
            $capDate = [string]$rec.captureDate
            if ([string]::IsNullOrWhiteSpace($capDate)) { continue }
            # Date range filter
            if ($capDate -lt $filterStartDate -or $capDate -gt $filterEndDate) { continue }
            # Campaign name filters
            if ($hasCampaignFilter) {
                $campNameVal = [string]$rec.campaign.name
                if ($campaignFilter.ContainsKey('CampaignName') -and $campNameVal -ne $campaignFilter['CampaignName']) { continue }
                if ($campaignFilter.ContainsKey('CampaignNameStartsWith') -and -not $campNameVal.StartsWith($campaignFilter['CampaignNameStartsWith'], [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($campaignFilter.ContainsKey('CampaignNameContains') -and $campNameVal.IndexOf($campaignFilter['CampaignNameContains'], [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            }
            # Status filter
            if ($null -ne $Status -and $Status.Count -gt 0) {
                $recStatus = ([string]$rec.campaign.status).ToUpperInvariant()
                if ($recStatus -notin $Status) { continue }
            }
            $campaignRecords.Add($rec)
        } catch { }
    }
    Write-Host "    Campaign records ($filterStartDate to $filterEndDate): $($campaignRecords.Count)" -ForegroundColor DarkGray
}
else {
    Write-Host '    daily-metrics.jsonl not found (Section 8 will be empty)' -ForegroundColor Yellow
}
Write-Host ''

#endregion

#region Step 3: Derive report data

Write-Host '  Step 3: Derive report data' -ForegroundColor Cyan

# --- Section 2: Newly decided (items with state changes within the date range) ---
$newlyDecidedList = [System.Collections.Generic.List[hashtable]]::new()

foreach ($sk in $entStateMap.Keys) {
    $rec = $entStateMap[$sk]
    $decision = [string]$rec['currentDecision']
    if ($decision -ne 'APPROVE' -and $decision -ne 'REVOKE') { continue }

    # Check if lastStateChangeDate falls within the report date range
    $changeDate = ''
    if ($rec.ContainsKey('lastStateChangeDate')) { $changeDate = [string]$rec['lastStateChangeDate'] }
    if ([string]::IsNullOrWhiteSpace($changeDate)) { continue }
    if ($changeDate -lt $filterStartDate -or $changeDate -gt $filterEndDate) { continue }

    # Only show items with an OBSERVED transition from PENDING/UNDECIDED. A blank
    # priorDecision means the item was FIRST SEEN already decided (bootstrap over
    # historical cache) -- that is not a new decision and listing it fabricated
    # decision-activity evidence.
    $priorDecision = ''
    if ($rec.ContainsKey('priorDecision')) { $priorDecision = [string]$rec['priorDecision'] }
    if ($priorDecision -ne 'PENDING' -and $priorDecision -ne 'UNDECIDED') { continue }

    $newlyDecidedList.Add(@{
        IdentityName     = [string]$rec['identityName']
        AccessName       = [string]$rec['accessName']
        SourceName       = [string]$rec['sourceName']
        PriorState       = $priorDecision
        CurrentState     = $decision
        ReviewerName     = [string]$rec['reviewerName']
        StateChangedDate = $changeDate
    })
}

# Sort newly decided by date descending
$newlyDecidedSorted = @($newlyDecidedList | Sort-Object { $_['StateChangedDate'] } -Descending)
Write-Host "    Newly decided:      $($newlyDecidedSorted.Count)" -ForegroundColor DarkGray

# --- Section 2b: Re-approved after revoke (observed REVOKE -> APPROVE in range) ---
# The re-grant governance signal: access genuinely revoked in an earlier instance and
# genuinely re-approved later. Section 2's PENDING/UNDECIDED filter deliberately
# excludes these, so without this list they were invisible. A record keeps ONE
# prior/current pair, so this catches items whose LAST transition was the re-approval;
# the revocation day is mined from the record's stateLog (last R: entry).
$reApprovedList = [System.Collections.Generic.List[hashtable]]::new()
foreach ($sk in $entStateMap.Keys) {
    $rec = $entStateMap[$sk]
    if ([string]$rec['currentDecision'] -ne 'APPROVE') { continue }
    $priorDecision = ''
    if ($rec.ContainsKey('priorDecision')) { $priorDecision = [string]$rec['priorDecision'] }
    if ($priorDecision -ne 'REVOKE') { continue }
    $changeDate = ''
    if ($rec.ContainsKey('lastStateChangeDate')) { $changeDate = [string]$rec['lastStateChangeDate'] }
    if ([string]::IsNullOrWhiteSpace($changeDate)) { continue }
    if ($changeDate -lt $filterStartDate -or $changeDate -gt $filterEndDate) { continue }

    $revokedOn = ''
    if ($rec.ContainsKey('stateLog')) {
        $logEntries = ([string]$rec['stateLog']) -split '\|'
        for ($li = $logEntries.Count - 1; $li -ge 0; $li--) {
            if ($logEntries[$li] -like 'R:*') {
                $rd = $logEntries[$li].Substring(2)
                if ($rd.Length -eq 8) { $revokedOn = $rd.Substring(0, 4) + '-' + $rd.Substring(4, 2) + '-' + $rd.Substring(6, 2) }
                break
            }
        }
    }

    $reApprovedList.Add(@{
        IdentityName   = [string]$rec['identityName']
        AccessName     = [string]$rec['accessName']
        SourceName     = [string]$rec['sourceName']
        ReviewerName   = [string]$rec['reviewerName']
        RevokedOn      = $revokedOn
        ReApprovedDate = $changeDate
    })
}
$reApprovedSorted = @($reApprovedList | Sort-Object { $_['ReApprovedDate'] } -Descending)
Write-Host "    Re-approved:        $($reApprovedSorted.Count)" -ForegroundColor DarkGray

# --- Section 3: Chronically unreviewed ---
$chronicList = [System.Collections.Generic.List[hashtable]]::new()
foreach ($sk in $entStateMap.Keys) {
    $rec = $entStateMap[$sk]
    $inScope = $true
    if ($rec.ContainsKey('inCurrentScope')) { $inScope = [bool]$rec['inCurrentScope'] }
    if (-not $inScope) { continue }

    $decision = [string]$rec['currentDecision']
    if ($decision -ne 'PENDING' -and $decision -ne 'UNDECIDED') { continue }

    $consUndecided = 0
    if ($rec.ContainsKey('consecutiveUndecided')) { $consUndecided = [int]$rec['consecutiveUndecided'] }
    if ($consUndecided -lt $ChronicThreshold) { continue }

    $chronicList.Add(@{
        IdentityName         = [string]$rec['identityName']
        AccessName           = [string]$rec['accessName']
        SourceName           = [string]$rec['sourceName']
        Decision             = $decision
        ConsecutiveUndecided = $consUndecided
        FirstSeenDate        = [string]$rec['firstSeenDate']
        ReviewerName         = [string]$rec['reviewerName']
    })
}
$chronicSorted = @($chronicList | Sort-Object { $_['ConsecutiveUndecided'] } -Descending)
Write-Host "    Chronically unrev.: $($chronicSorted.Count) (threshold: $ChronicThreshold)" -ForegroundColor DarkGray

# --- Section 4: Dropped from scope ---
$droppedList = [System.Collections.Generic.List[hashtable]]::new()
foreach ($sk in $entStateMap.Keys) {
    $rec = $entStateMap[$sk]
    $inScope = $true
    if ($rec.ContainsKey('inCurrentScope')) { $inScope = [bool]$rec['inCurrentScope'] }
    if ($inScope) { continue }

    $droppedList.Add(@{
        IdentityName  = [string]$rec['identityName']
        AccessName    = [string]$rec['accessName']
        SourceName    = [string]$rec['sourceName']
        LastDecision  = [string]$rec['currentDecision']
        LastSeenDate  = [string]$rec['lastSeenDate']
        FirstSeenDate = [string]$rec['firstSeenDate']
    })
}
$droppedSorted = @($droppedList | Sort-Object { $_['LastSeenDate'] } -Descending)
Write-Host "    Dropped from scope: $($droppedSorted.Count)" -ForegroundColor DarkGray

# --- Section 5: Reviewer engagement ---
$reviewerRows = [System.Collections.Generic.List[hashtable]]::new()
$engLow = 0; $engMod = 0; $engHigh = 0

foreach ($rvName in $rvReviewerMap.Keys) {
    $rv = $rvReviewerMap[$rvName]
    $g = $null
    if ($rv.ContainsKey('global')) { $g = $rv['global'] }
    if ($null -eq $g) { continue }

    $score     = Get-V8SafeInt -Object $g -Name 'engagementScore' -Default 0
    $completed = Get-V8SafeInt -Object $g -Name 'totalCampaignsCompleted' -Default 0
    $missed    = Get-V8SafeInt -Object $g -Name 'totalCampaignsMissed' -Default 0
    $observed  = Get-V8SafeInt -Object $g -Name 'totalCampaignsObserved' -Default 0

    $primarySeries = Get-V8PrimarySeries -ReviewerRec $rv
    $psd = Get-V8PrimarySeriesData -ReviewerRec $rv
    $currentStreak = 0; $missStreak = 0
    if ($null -ne $psd -and $psd.ContainsKey('streaks')) {
        $streaks = $psd['streaks']
        if ($null -ne $streaks) {
            if ($streaks.ContainsKey('currentStreak'))     { $currentStreak = [int]$streaks['currentStreak'] }
            if ($streaks.ContainsKey('currentMissStreak')) { $missStreak    = [int]$streaks['currentMissStreak'] }
        }
    }

    if ($score -lt 50)       { $engLow++ }
    elseif ($score -lt 80)   { $engMod++ }
    else                     { $engHigh++ }

    $reviewerRows.Add(@{
        Name          = $rvName
        Score         = $score
        Completed     = $completed
        Missed        = $missed
        Observed      = $observed
        CurrentStreak = $currentStreak
        MissStreak    = $missStreak
        Series        = $primarySeries
    })
}
$reviewerSorted = @($reviewerRows | Sort-Object { $_['Score'] })
Write-Host "    Reviewers:          $($reviewerSorted.Count) (L:$engLow M:$engMod H:$engHigh)" -ForegroundColor DarkGray

# --- Section 6: Weekly compliance ---
$currentIsoWeek = Get-V8CurrentIsoWeek
$weeklyNonCompliant = [System.Collections.Generic.List[hashtable]]::new()

foreach ($rvName in $rvReviewerMap.Keys) {
    $rv = $rvReviewerMap[$rvName]
    $primarySeries = Get-V8PrimarySeries -ReviewerRec $rv
    $psd = Get-V8PrimarySeriesData -ReviewerRec $rv
    if ($null -eq $psd) { continue }

    $weeklyStats = $null
    if ($psd.ContainsKey('weeklyStats')) { $weeklyStats = $psd['weeklyStats'] }
    if ($null -eq $weeklyStats) { continue }

    $weekData = $null
    if ($weeklyStats.ContainsKey($currentIsoWeek)) { $weekData = $weeklyStats[$currentIsoWeek] }
    if ($null -eq $weekData) { continue }

    $wMissed = 0; $wExpected = 0; $wCompleted = 0; $wPartials = 0
    if ($weekData.ContainsKey('missed'))    { $wMissed    = [int]$weekData['missed'] }
    if ($weekData.ContainsKey('expected'))  { $wExpected  = [int]$weekData['expected'] }
    if ($weekData.ContainsKey('completed')) { $wCompleted = [int]$weekData['completed'] }
    if ($weekData.ContainsKey('partials'))  { $wPartials  = [int]$weekData['partials'] }

    if ($wMissed -lt 2) { continue }

    $gScore = 0
    $g = $null
    if ($rv.ContainsKey('global')) { $g = $rv['global'] }
    if ($null -ne $g -and $g.ContainsKey('engagementScore')) { $gScore = [int]$g['engagementScore'] }

    $weeklyNonCompliant.Add(@{
        Name      = $rvName
        Score     = $gScore
        Expected  = $wExpected
        Completed = $wCompleted
        Missed    = $wMissed
        Partials  = $wPartials
        Series    = $primarySeries
    })
}
$weeklyNCSorted = @($weeklyNonCompliant | Sort-Object { $_['Missed'] } -Descending)
Write-Host "    Weekly non-compliant: $($weeklyNCSorted.Count) ($currentIsoWeek)" -ForegroundColor DarkGray

# --- Section 7: Heatmap data (last 14 dayLog entries per reviewer) ---
# Collect all unique dates across all reviewers' primary series dayLogs
$heatmapData = [System.Collections.Generic.List[hashtable]]::new()
$allHeatDates = @{}

foreach ($rvName in $rvReviewerMap.Keys) {
    $rv = $rvReviewerMap[$rvName]
    $psd = Get-V8PrimarySeriesData -ReviewerRec $rv
    if ($null -eq $psd) { continue }

    $dayLog = ''
    if ($psd.ContainsKey('dayLog')) { $dayLog = [string]$psd['dayLog'] }
    # @() is load-bearing: PowerShell unrolls the returned List, so a single-entry
    # dayLog otherwise arrives as a bare hashtable and $entries[0] indexes to $null.
    $entries = @(Get-V8DayLogEntries -DayLog $dayLog)
    if ($entries.Count -eq 0) { continue }

    # Take last 14 entries
    $startIdx = 0
    if ($entries.Count -gt 14) { $startIdx = $entries.Count - 14 }
    $subset = @()
    for ($i = $startIdx; $i -lt $entries.Count; $i++) {
        $subset += $entries[$i]
        $allHeatDates[$entries[$i].Date] = $true
    }

    $gScore = 0
    $g = $null
    if ($rv.ContainsKey('global')) { $g = $rv['global'] }
    if ($null -ne $g -and $g.ContainsKey('engagementScore')) { $gScore = [int]$g['engagementScore'] }

    $heatmapData.Add(@{
        Name    = $rvName
        Score   = $gScore
        Entries = $subset
    })
}
$heatmapSorted = @($heatmapData | Sort-Object { $_['Score'] })
$sortedHeatDates = @($allHeatDates.Keys | Sort-Object)
# Limit to last 14 dates
if ($sortedHeatDates.Count -gt 14) {
    $sortedHeatDates = @($sortedHeatDates[($sortedHeatDates.Count - 14)..($sortedHeatDates.Count - 1)])
}

Write-Host "    Heatmap reviewers:  $($heatmapSorted.Count)" -ForegroundColor DarkGray
Write-Host ''

#endregion

#region Step 4: Compute KPI values (used by both HTML and Console)

$approveCount   = [int]$entSummary['APPROVE']
$revokeCount    = [int]$entSummary['REVOKE']
$pendingCount   = [int]$entSummary['PENDING']
$undecidedCount = [int]$entSummary['UNDECIDED']

$approvePct = 0; $revokePct = 0; $pendingPct = 0; $undecidedPct = 0
if ($inScopeCount -gt 0) {
    $approvePct   = [math]::Round($approveCount / $inScopeCount * 100, 1)
    $revokePct    = [math]::Round($revokeCount / $inScopeCount * 100, 1)
    $pendingPct   = [math]::Round($pendingCount / $inScopeCount * 100, 1)
    $undecidedPct = [math]::Round($undecidedCount / $inScopeCount * 100, 1)
}

# Privileged breakdown from entitlement state
$privApprove = 0; $privRevoke = 0; $privPending = 0; $privUndecided = 0; $privTotal = 0
$privBySource = @{}
foreach ($sk in $entStateMap.Keys) {
    $rec = $entStateMap[$sk]
    $inScope = $true
    if ($rec.ContainsKey('inCurrentScope')) { $inScope = [bool]$rec['inCurrentScope'] }
    if (-not $inScope) { continue }
    $isPriv = $false
    if ($rec.ContainsKey('isPrivileged')) { try { $isPriv = [bool]$rec['isPrivileged'] } catch { } }
    if (-not $isPriv) { continue }
    $privTotal++
    $state = ''
    if ($rec.ContainsKey('currentDecision')) { $state = [string]$rec['currentDecision'] }
    switch ($state.ToUpperInvariant()) {
        'APPROVE'   { $privApprove++ }
        'REVOKE'    { $privRevoke++ }
        'PENDING'   { $privPending++ }
        'UNDECIDED' { $privUndecided++ }
        default     { $privPending++ }
    }
    # Per-source breakdown for privileged
    $srcName = ''
    if ($rec.ContainsKey('sourceName')) { $srcName = [string]$rec['sourceName'] }
    if ([string]::IsNullOrWhiteSpace($srcName)) { $srcName = 'Unknown' }
    if (-not $privBySource.ContainsKey($srcName)) { $privBySource[$srcName] = @{ Approve = 0; Revoke = 0; Pending = 0; Undecided = 0; Total = 0 } }
    $privBySource[$srcName].Total++
    switch ($state.ToUpperInvariant()) {
        'APPROVE'   { $privBySource[$srcName].Approve++ }
        'REVOKE'    { $privBySource[$srcName].Revoke++ }
        'PENDING'   { $privBySource[$srcName].Pending++ }
        'UNDECIDED' { $privBySource[$srcName].Undecided++ }
        default     { $privBySource[$srcName].Pending++ }
    }
}
$privDecided = $privApprove + $privRevoke
$privDecidedPct = if ($privTotal -gt 0) { [math]::Round($privDecided / $privTotal * 100, 0) } else { 0 }
$privExposure = $privPending + $privUndecided

Write-Host "    Privileged items:    $privTotal (approved=$privApprove revoked=$privRevoke pending=$privPending undecided=$privUndecided)" -ForegroundColor DarkGray

#endregion

#region Step 5: Build HTML

if ($OutputMode -eq 'Console') {
    # Skip HTML generation
}
else {

Write-Host '  Step 5: Build HTML report' -ForegroundColor Cyan

$sb = [System.Text.StringBuilder]::new(65536)

# --- HTML Head ---
[void]$sb.Append('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
[void]$sb.Append('<meta name="viewport" content="width=device-width,initial-scale=1">')
[void]$sb.Append('<title>Daily Evidence V8 - State Tracking</title>')
[void]$sb.Append('<style>')
[void]$sb.Append('body{font-family:"Segoe UI",Arial,sans-serif;background:#f4f6f9;color:#333;margin:0;padding:20px}')
[void]$sb.Append('.container{max-width:1100px;margin:0 auto}')
[void]$sb.Append('.header{background:linear-gradient(135deg,#264d73,#336699);color:#fff;padding:24px 32px;border-radius:8px 8px 0 0}')
[void]$sb.Append('.header h1{margin:0 0 4px 0;font-size:20px;font-weight:600}')
[void]$sb.Append('.header .sub{font-size:12px;opacity:0.85;margin-top:4px}')
[void]$sb.Append('.section{background:#fff;border:1px solid #e0e0e0;border-top:none;padding:20px 32px}')
[void]$sb.Append('.section h2{font-size:15px;color:#264d73;margin:0 0 12px 0;padding-bottom:6px;border-bottom:2px solid #e8eef5}')
[void]$sb.Append('.section:last-of-type{border-radius:0 0 8px 8px}')
[void]$sb.Append('.kpi-row{display:flex;gap:16px;flex-wrap:wrap;margin:12px 0 16px 0}')
[void]$sb.Append('.kpi{flex:1;min-width:120px;background:#f8fafc;border:1px solid #e0e8f0;border-radius:6px;padding:14px 16px;text-align:center}')
[void]$sb.Append('.kpi .val{font-size:28px;font-weight:700;line-height:1.1}')
[void]$sb.Append('.kpi .lbl{font-size:11px;color:#667;text-transform:uppercase;margin-top:4px}')
[void]$sb.Append('.kpi .pct{font-size:12px;color:#888;margin-top:2px}')
[void]$sb.Append('table.report{border-collapse:collapse;width:100%;margin:12px 0;font-size:12px}')
[void]$sb.Append('table.report th{background:#e8eef5;padding:8px 10px;text-align:left;font-weight:600;font-size:11px;text-transform:uppercase}')
[void]$sb.Append('table.report td{padding:7px 10px;border-bottom:1px solid #eee}')
[void]$sb.Append('table.report tr:hover{background:#f8fafc}')
[void]$sb.Append('.s-green{color:#339933;font-weight:600}')
[void]$sb.Append('.s-amber{color:#9a6700;font-weight:600}')
[void]$sb.Append('.s-red{color:#CC3333;font-weight:600}')
[void]$sb.Append('.s-gray{color:#999999;font-weight:600}')
[void]$sb.Append('.row-red{background:#fff5f5}')
[void]$sb.Append('.row-amber{background:#fffbf0}')
[void]$sb.Append('.badge-priv{background:#ffcdd2;color:#b71c1c;display:inline-block;padding:2px 8px;border-radius:10px;font-size:10px}')
[void]$sb.Append('details{margin:8px 0}')
[void]$sb.Append('details summary{cursor:pointer;font-weight:600;color:#264d73;font-size:13px;padding:4px 0}')
[void]$sb.Append('.heat-cell{display:inline-block;width:24px;height:24px;line-height:24px;text-align:center;font-size:10px;font-weight:700;border-radius:3px;margin:1px}')
[void]$sb.Append('.hc-C{background:#339933;color:#fff}.hc-P{background:#FF8800;color:#fff}')
[void]$sb.Append('.hc-M{background:#CC3333;color:#fff}.hc-U{background:#999999;color:#fff}')
[void]$sb.Append('.footer{text-align:center;color:#999;font-size:11px;padding:16px;border-top:1px solid #eee;background:#fff;border-radius:0 0 8px 8px;border:1px solid #e0e0e0;border-top:none}')
[void]$sb.Append('.note{font-size:11px;color:#888;margin:6px 0;font-style:italic}')
[void]$sb.Append('</style></head><body><div class="container">')

# --- Header ---
$safeLastRun = ConvertTo-SPHtmlSafe $lastRunDate
[void]$sb.Append('<div class="header">')
[void]$sb.Append('<h1>Daily Evidence Report - State Tracking</h1>')
[void]$sb.Append("<div class='sub'>SailPoint ISC Governance Toolkit | Generated: $(ConvertTo-SPHtmlSafe $todayLabel) $((Get-Date).ToString('HH:mm'))</div>")
[void]$sb.Append("<div class='sub'>State files last updated: $safeLastRun | Entitlement: $entTotal records | Reviewer: $rvTotal reviewers</div>")
if ($seriesFilterActive) {
    [void]$sb.Append("<div class='sub'>Campaign filter active: Sections 1-4 are limited to matching series; Sections 5-7 cover ALL reviewers.</div>")
}
[void]$sb.Append("<div class='sub'>Sections 1, 3-7 show current cumulative state as of $safeLastRun; only Section 2 and Section 8 are filtered to $filterStartDate .. $filterEndDate.</div>")
if ($lastRunDate -ne '(unknown)' -and $lastRunDate -lt $filterEndDate) {
    [void]$sb.Append("<div class='sub' style='color:#ffd27f'>WARNING: state was last updated $safeLastRun, before the end of the requested window -- data may not cover the full range.</div>")
}
[void]$sb.Append('</div>')

# ======================== Section 1: Entitlement State Summary ========================
[void]$sb.Append('<div class="section"><h2>1. Entitlement State Summary</h2>')

[void]$sb.Append('<div class="kpi-row">')
[void]$sb.Append("<div class='kpi'><div class='val s-green'>$approveCount</div><div class='lbl'>Approved</div><div class='pct'>${approvePct}%</div></div>")
[void]$sb.Append("<div class='kpi'><div class='val s-red'>$revokeCount</div><div class='lbl'>Revoked</div><div class='pct'>${revokePct}%</div></div>")
[void]$sb.Append("<div class='kpi'><div class='val s-gray'>$pendingCount</div><div class='lbl'>Pending</div><div class='pct'>${pendingPct}%</div></div>")
[void]$sb.Append("<div class='kpi'><div class='val s-amber'>$undecidedCount</div><div class='lbl'>Undecided</div><div class='pct'>${undecidedPct}%</div></div>")
[void]$sb.Append('</div>')
[void]$sb.Append("<p class='note'>In-scope entitlements: $inScopeCount | Total tracked (incl. dropped): $entTotal</p>")
[void]$sb.Append('</div>')

# ======================== Section 1b: Privileged Access Summary ========================
if ($privTotal -gt 0) {
    [void]$sb.Append('<div class="section"><h2>1b. Privileged Access Summary</h2>')
    $privExposureColor = if ($privExposure -gt 0) { 's-red' } else { 's-green' }
    $privRevokeColor = if ($privRevoke -gt 0) { 's-red' } else { 's-gray' }
    [void]$sb.Append('<div class="kpi-row">')
    [void]$sb.Append("<div class='kpi'><div class='val s-blue'>$privTotal</div><div class='lbl'>Privileged Total</div></div>")
    [void]$sb.Append("<div class='kpi'><div class='val s-green'>$privApprove</div><div class='lbl'>Priv. Approved</div></div>")
    [void]$sb.Append("<div class='kpi'><div class='val $privRevokeColor'>$privRevoke</div><div class='lbl'>Priv. Revoked</div></div>")
    [void]$sb.Append("<div class='kpi'><div class='val $privExposureColor'>$privExposure</div><div class='lbl'>Priv. Exposure</div><div class='pct'>$privPending pending + $privUndecided undecided</div></div>")
    [void]$sb.Append("<div class='kpi'><div class='val'>${privDecidedPct}%</div><div class='lbl'>Priv. Decided</div></div>")
    [void]$sb.Append('</div>')

    # Per-source privileged breakdown table
    if ($privBySource.Count -gt 0) {
        [void]$sb.Append("<table class='report'><tr><th>Source</th><th style='text-align:right'>Total</th><th style='text-align:right'>Approved</th><th style='text-align:right'>Revoked</th><th style='text-align:right'>Pending</th><th style='text-align:right'>Undecided</th><th style='text-align:center'>Decided %</th></tr>")
        foreach ($srcName in ($privBySource.Keys | Sort-Object)) {
            $ps = $privBySource[$srcName]
            $psDecided = $ps.Approve + $ps.Revoke
            $psPct = if ($ps.Total -gt 0) { [math]::Round($psDecided / $ps.Total * 100, 0) } else { 0 }
            $psPctClass = if ($psPct -ge 80) { 's-green' } elseif ($psPct -ge 50) { 's-amber' } else { 's-red' }
            $psUndStyle = if (($ps.Pending + $ps.Undecided) -gt 0) { " style='color:#b00020;font-weight:600'" } else { '' }
            [void]$sb.Append("<tr><td style='font-weight:600'>$(ConvertTo-Safe $srcName)</td><td style='text-align:right'>$($ps.Total)</td><td style='text-align:right'>$($ps.Approve)</td><td style='text-align:right;color:#b00020'>$($ps.Revoke)</td><td style='text-align:right'$psUndStyle>$($ps.Pending)</td><td style='text-align:right'$psUndStyle>$($ps.Undecided)</td><td style='text-align:center' class='$psPctClass'>${psPct}%</td></tr>")
        }
        [void]$sb.Append('</table>')
    }

    [void]$sb.Append("<p class='note'>Privileged entitlements carry elevated risk. Exposure = items NOT genuinely reviewed (pending + undecided/auto-approved). Per-source breakdown shows which systems have the highest unreviewed privileged access.</p>")
    [void]$sb.Append('</div>')
}

# ======================== Section 2: Newly Decided ========================
[void]$sb.Append('<div class="section"><h2>2. Newly Decided</h2>')
if ($newlyDecidedSorted.Count -eq 0) {
    [void]$sb.Append("<p class='note'>No state changes detected. State files last updated: $safeLastRun.</p>")
}
else {
    [void]$sb.Append("<p class='note'>$($newlyDecidedSorted.Count) entitlement(s) with an observed PENDING/UNDECIDED -&gt; decision transition between $filterStartDate and $filterEndDate (dates are the campaign's own day).</p>")
    [void]$sb.Append('<table class="report"><tr><th>Identity</th><th>Access</th><th>Source</th><th>Prior State</th><th>Current State</th><th>Reviewer</th><th>Changed</th></tr>')
    foreach ($nd in $newlyDecidedSorted) {
        $stateClass = 's-green'
        if ($nd['CurrentState'] -eq 'REVOKE') { $stateClass = 's-red' }
        $priorClass = 's-gray'
        if ($nd['PriorState'] -eq 'UNDECIDED') { $priorClass = 's-amber' }
        elseif ($nd['PriorState'] -eq 'PENDING') { $priorClass = 's-gray' }

        [void]$sb.Append('<tr>')
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $nd['IdentityName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $nd['AccessName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $nd['SourceName'])</td>")
        [void]$sb.Append("<td class='$priorClass'>$(ConvertTo-SPHtmlSafe $nd['PriorState'])</td>")
        [void]$sb.Append("<td class='$stateClass'>$(ConvertTo-SPHtmlSafe $nd['CurrentState'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $nd['ReviewerName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $nd['StateChangedDate'])</td>")
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
}

# Section 2b: Re-Approved After Revoke (kept inside Section 2 so the numbered
# section list and the "only Section 2 is date-filtered" statement stay true).
[void]$sb.Append("<div style='font-weight:600;font-size:13px;margin:14px 0 4px;color:#9a6700'>Re-Approved After Revoke ($($reApprovedSorted.Count))</div>")
if ($reApprovedSorted.Count -eq 0) {
    [void]$sb.Append("<p class='note'>No revoked access was re-approved between $filterStartDate and $filterEndDate.</p>")
}
else {
    [void]$sb.Append("<p class='note'>Access genuinely REVOKED in an earlier campaign instance and genuinely RE-APPROVED within the window -- the re-grant governance signal. Revoked On is mined from each record's state log.</p>")
    [void]$sb.Append('<table class="report"><tr><th>Identity</th><th>Access</th><th>Source</th><th>Re-Approved By</th><th>Revoked On</th><th>Re-Approved On</th></tr>')
    foreach ($ra in $reApprovedSorted) {
        [void]$sb.Append('<tr>')
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $ra['IdentityName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $ra['AccessName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $ra['SourceName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $ra['ReviewerName'])</td>")
        [void]$sb.Append("<td class='s-red'>$(ConvertTo-SPHtmlSafe $ra['RevokedOn'])</td>")
        [void]$sb.Append("<td class='s-green'>$(ConvertTo-SPHtmlSafe $ra['ReApprovedDate'])</td>")
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
}
[void]$sb.Append('</div>')

# ======================== Section 3: Chronically Unreviewed ========================
[void]$sb.Append('<div class="section"><h2>3. Chronically Unreviewed</h2>')
if ($chronicSorted.Count -eq 0) {
    [void]$sb.Append("<p class='note'>No items exceed the chronic threshold ($ChronicThreshold consecutive campaigns).</p>")
}
else {
    [void]$sb.Append("<details><summary>$($chronicSorted.Count) item(s) with $ChronicThreshold+ consecutive unreviewed campaigns</summary>")
    [void]$sb.Append('<table class="report"><tr><th>Identity</th><th>Access</th><th>Source</th><th>Decision</th><th>Consecutive</th><th>First Seen</th><th>Reviewer</th></tr>')
    foreach ($ch in $chronicSorted) {
        $rowClass = ''
        if ([int]$ch['ConsecutiveUndecided'] -ge 10) { $rowClass = " class='row-red'" }
        $decClass = 's-amber'
        if ($ch['Decision'] -eq 'PENDING') { $decClass = 's-gray' }

        [void]$sb.Append("<tr$rowClass>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $ch['IdentityName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $ch['AccessName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $ch['SourceName'])</td>")
        [void]$sb.Append("<td class='$decClass'>$(ConvertTo-SPHtmlSafe $ch['Decision'])</td>")
        [void]$sb.Append("<td style='text-align:center;font-weight:700'>$($ch['ConsecutiveUndecided'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $ch['FirstSeenDate'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $ch['ReviewerName'])</td>")
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table></details>')
}
[void]$sb.Append('</div>')

# ======================== Section 4: Dropped from Scope ========================
[void]$sb.Append('<div class="section"><h2>4. Dropped from Scope</h2>')
if ($droppedSorted.Count -eq 0) {
    [void]$sb.Append("<p class='note'>No entitlements have dropped from scope.</p>")
}
else {
    [void]$sb.Append("<details><summary>$($droppedSorted.Count) entitlement(s) no longer in current certification scope</summary>")
    [void]$sb.Append('<table class="report"><tr><th>Identity</th><th>Access</th><th>Source</th><th>Last Decision</th><th>Last Seen</th><th>First Seen</th></tr>')
    foreach ($dp in $droppedSorted) {
        [void]$sb.Append('<tr>')
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $dp['IdentityName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $dp['AccessName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $dp['SourceName'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $dp['LastDecision'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $dp['LastSeenDate'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $dp['FirstSeenDate'])</td>")
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table></details>')
}
[void]$sb.Append('</div>')

# ======================== Section 5: Reviewer Engagement Summary ========================
[void]$sb.Append('<div class="section"><h2>5. Reviewer Engagement Summary</h2>')

[void]$sb.Append('<div class="kpi-row">')
$lowColor = 's-red'; $modColor = 's-amber'; $hiColor = 's-green'
[void]$sb.Append("<div class='kpi'><div class='val $lowColor'>$engLow</div><div class='lbl'>Low (&lt;50%)</div></div>")
[void]$sb.Append("<div class='kpi'><div class='val $modColor'>$engMod</div><div class='lbl'>Moderate (50-79%)</div></div>")
[void]$sb.Append("<div class='kpi'><div class='val $hiColor'>$engHigh</div><div class='lbl'>High (80%+)</div></div>")
[void]$sb.Append('</div>')

if ($reviewerSorted.Count -gt 0) {
    [void]$sb.Append("<p class='note'>Score/Completed/Missed/Observed are GLOBAL (all series); the streak columns come from the reviewer's primary series only.</p>")
    [void]$sb.Append('<table class="report"><tr><th>Reviewer</th><th>Score</th><th>Completed</th><th>Missed</th><th>Observed</th><th>Current Streak</th><th>Miss Streak</th><th>Series</th></tr>')
    foreach ($rv in $reviewerSorted) {
        $scoreVal = [int]$rv['Score']
        $scoreClass = 's-green'
        $rowClass = ''
        if ($scoreVal -lt 50) {
            $scoreClass = 's-red'
            $rowClass = " class='row-red'"
        }
        elseif ($scoreVal -lt 80) {
            $scoreClass = 's-amber'
            $rowClass = " class='row-amber'"
        }

        [void]$sb.Append("<tr$rowClass>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $rv['Name'])</td>")
        [void]$sb.Append("<td class='$scoreClass'>${scoreVal}%</td>")
        [void]$sb.Append("<td>$($rv['Completed'])</td>")
        [void]$sb.Append("<td>$($rv['Missed'])</td>")
        [void]$sb.Append("<td>$($rv['Observed'])</td>")
        [void]$sb.Append("<td>$($rv['CurrentStreak'])</td>")
        [void]$sb.Append("<td>$($rv['MissStreak'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $rv['Series'])</td>")
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
}
else {
    [void]$sb.Append("<p class='note'>No reviewer engagement data available.</p>")
}
[void]$sb.Append('</div>')

# ======================== Section 6: Reviewer Weekly Compliance ========================
[void]$sb.Append('<div class="section"><h2>6. Reviewer Weekly Compliance</h2>')
[void]$sb.Append("<p class='note'>Current ISO week: $(ConvertTo-SPHtmlSafe $currentIsoWeek) | Showing reviewers with 2+ missed days this week.</p>")

if ($weeklyNCSorted.Count -eq 0) {
    [void]$sb.Append("<p class='note'>All reviewers are compliant this week.</p>")
}
else {
    [void]$sb.Append("<details open><summary>$($weeklyNCSorted.Count) reviewer(s) with 2+ missed days this week</summary>")
    [void]$sb.Append('<table class="report"><tr><th>Reviewer</th><th>Score</th><th>Expected</th><th>Completed</th><th>Missed</th><th>Partials</th><th>Series</th></tr>')
    foreach ($wk in $weeklyNCSorted) {
        $wkScoreClass = 's-green'
        if ([int]$wk['Score'] -lt 50) { $wkScoreClass = 's-red' }
        elseif ([int]$wk['Score'] -lt 80) { $wkScoreClass = 's-amber' }

        [void]$sb.Append('<tr>')
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $wk['Name'])</td>")
        [void]$sb.Append("<td class='$wkScoreClass'>$($wk['Score'])%</td>")
        [void]$sb.Append("<td>$($wk['Expected'])</td>")
        [void]$sb.Append("<td>$($wk['Completed'])</td>")
        [void]$sb.Append("<td class='s-red'>$($wk['Missed'])</td>")
        [void]$sb.Append("<td>$($wk['Partials'])</td>")
        [void]$sb.Append("<td>$(ConvertTo-SPHtmlSafe $wk['Series'])</td>")
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table></details>')
}
[void]$sb.Append('</div>')

# ======================== Section 7: Reviewer Engagement Heatmap ========================
[void]$sb.Append('<div class="section"><h2>7. Reviewer Engagement Heatmap</h2>')
[void]$sb.Append("<p class='note'>Last 14 entries per reviewer. C=Completed (green), P=Partial (amber), M=Missed (red), U=Undecided (gray).</p>")

if ($heatmapSorted.Count -eq 0 -or $sortedHeatDates.Count -eq 0) {
    [void]$sb.Append("<p class='note'>No heatmap data available.</p>")
}
else {
    [void]$sb.Append('<table class="report"><tr><th>Reviewer</th>')
    foreach ($hd in $sortedHeatDates) {
        # Format yyyyMMdd as MM/DD
        $hdLabel = $hd
        if ($hd.Length -eq 8) { $hdLabel = $hd.Substring(4,2) + '/' + $hd.Substring(6,2) }
        [void]$sb.Append("<th style='text-align:center;font-size:10px;min-width:28px'>$(ConvertTo-SPHtmlSafe $hdLabel)</th>")
    }
    [void]$sb.Append('</tr>')

    foreach ($hm in $heatmapSorted) {
        [void]$sb.Append("<tr><td>$(ConvertTo-SPHtmlSafe $hm['Name'])</td>")

        # Build lookup of this reviewer's entries by date
        $entryLookup = @{}
        foreach ($e in $hm['Entries']) {
            $entryLookup[$e.Date] = $e.State
        }

        foreach ($hd in $sortedHeatDates) {
            if ($entryLookup.ContainsKey($hd)) {
                # Whitelist the state char: it comes from a data file and lands in an
                # attribute -- anything but C/P/M/U renders as '?' rather than raw.
                $st = [string]$entryLookup[$hd]
                if ($st -notmatch '^[CPMU]$') { $st = '?' }
                $stCls = if ($st -eq '?') { '' } else { " hc-$st" }
                [void]$sb.Append("<td style='text-align:center;padding:3px'><span class='heat-cell$stCls'>$(ConvertTo-SPHtmlSafe $st)</span></td>")
            }
            else {
                [void]$sb.Append("<td style='text-align:center;padding:3px'><span class='heat-cell' style='background:#eee;color:#ccc'>-</span></td>")
            }
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
}
[void]$sb.Append('</div>')

# ======================== Section 8: Campaign Summary ========================
[void]$sb.Append("<div class=""section""><h2>8. Campaign Summary ($filterStartDate to $filterEndDate)</h2>")

if ($campaignRecords.Count -eq 0) {
    [void]$sb.Append("<p class='note'>No campaign data available. daily-metrics.jsonl not found or empty.</p>")
}
else {
    # Dedupe by captureDate|campaignId, latest captureTimestamp wins (V7 convention --
    # multiple same-day captures of one campaign are normal and rendered as duplicate
    # rows without this).
    $dedup = @{}
    foreach ($cr in $campaignRecords) {
        $campIdV8 = ''
        try { $campIdV8 = [string]$cr.campaign.id } catch { }
        $dk = "$([string]$cr.captureDate)|$campIdV8"
        $ts = ''
        try { $ts = [string]$cr.captureTimestamp } catch { }
        if (-not $dedup.ContainsKey($dk)) { $dedup[$dk] = $cr }
        else {
            $existingTs = ''
            try { $existingTs = [string]$dedup[$dk].captureTimestamp } catch { }
            if ($ts -gt $existingTs) { $dedup[$dk] = $cr }
        }
    }
    $campSorted = @($dedup.Values | Sort-Object { [string]$_.captureDate }, { [string]$_.campaign.name } -Descending)
    if ($campSorted.Count -lt $campaignRecords.Count) {
        [void]$sb.Append("<p class='note'>$($campaignRecords.Count - $campSorted.Count) duplicate same-day capture(s) collapsed (latest capture wins).</p>")
    }

    [void]$sb.Append('<table class="report"><tr><th>Date</th><th>Campaign</th><th>Status</th><th>Total</th><th>Approved</th><th>Revoked</th><th>Undecided</th><th>Completion %</th></tr>')

    $maxCampRows = 50
    $campRowCount = 0
    $suspectRows = 0
    foreach ($cr in $campSorted) {
        if ($campRowCount -ge $maxCampRows) { break }
        $campRowCount++

        $crDate   = ConvertTo-SPHtmlSafe ([string]$cr.captureDate)
        $crName   = ''
        $crStatus = ''
        try {
            $crName   = ConvertTo-SPHtmlSafe ([string]$cr.campaign.name)
            $crStatus = ConvertTo-SPHtmlSafe ([string]$cr.campaign.status)
        } catch { }

        # V4b writes totalItems/pending (never total/undecided) -- the old field names
        # rendered the Total and Undecided columns as a permanent 0.
        $crTotal     = 0; $crApproved = 0; $crRevoked = 0; $crUndecided = 0; $crCompPct = 0; $crSchema = 0
        try {
            $sm = $cr.summary
            if ($null -ne $sm) {
                $crTotal     = [int](Get-V8Prop -Object $sm -Name 'totalItems' -Default 0)
                $crApproved  = [int](Get-V8Prop -Object $sm -Name 'approved' -Default 0)
                $crRevoked   = [int](Get-V8Prop -Object $sm -Name 'revoked' -Default 0)
                $crUndecided = [int](Get-V8Prop -Object $sm -Name 'pending' -Default 0)
                $crCompPct   = [double](Get-V8Prop -Object $sm -Name 'completionPct' -Default 0)
            }
            $crSchema = [int](Get-V8Prop -Object $cr -Name 'schemaVersion' -Default 0)
        } catch { }
        $compPctStr = [math]::Round($crCompPct, 1)
        $compClass = 's-green'
        if ($crCompPct -lt 50) { $compClass = 's-red' }
        elseif ($crCompPct -lt 80) { $compClass = 's-amber' }

        # Legacy suspect flag (V7 convention): a pre-schemaVersion-2 COMPLETED record at
        # ~100% with 0 pending has force-close auto-approvals counted as approved.
        # KEPT (never dropped) but badged so the row is not read as genuine completion.
        $suspectBadge = ''
        if ($crSchema -lt 2 -and $crStatus -eq 'COMPLETED' -and $crUndecided -eq 0 -and $crCompPct -ge 99.5) {
            $suspectBadge = " <span class='s-amber' style='font-size:10px'>(suspect: force-close inflated)</span>"
            $suspectRows++
        }

        [void]$sb.Append('<tr>')
        [void]$sb.Append("<td>$crDate</td>")
        [void]$sb.Append("<td>$crName$suspectBadge</td>")
        [void]$sb.Append("<td>$crStatus</td>")
        [void]$sb.Append("<td>$crTotal</td>")
        [void]$sb.Append("<td>$crApproved</td>")
        [void]$sb.Append("<td>$crRevoked</td>")
        [void]$sb.Append("<td>$crUndecided</td>")
        [void]$sb.Append("<td class='$compClass'>${compPctStr}%</td>")
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
    if ($campSorted.Count -gt $maxCampRows) {
        [void]$sb.Append("<p class='note'>Showing $maxCampRows of $($campSorted.Count) records.</p>")
    }
    if ($suspectRows -gt 0) {
        [void]$sb.Append("<p class='note'>$suspectRows record(s) predate canonical counts (schemaVersion &lt; 2); their approved/completion figures include force-close auto-approvals.</p>")
    }
}
[void]$sb.Append('</div>')

# --- Footer ---
[void]$sb.Append('<div class="footer">')
[void]$sb.Append("Daily Evidence V8 (State-Powered) | State: $entTotal ent, $rvTotal rev | Generated: $(ConvertTo-SPHtmlSafe $todayLabel) $((Get-Date).ToString('HH:mm')) | SailPoint ISC Governance Toolkit")
[void]$sb.Append('</div>')

[void]$sb.Append('</div></body></html>')

# --- Write HTML file ---
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$htmlFileName = "daily-evidence-v8-${timestamp}.html"
$htmlFilePath = Join-Path $effectiveOutputPath $htmlFileName

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($htmlFilePath, $sb.ToString(), $utf8NoBom)

Write-Host "    Output: $htmlFilePath" -ForegroundColor Green
Write-Host ''

} # end HTML block

#endregion

#region Step 6: Console Output

if ($OutputMode -eq 'HTML') {
    # Skip console output
}
else {

Write-Host ''
Write-Host '  === V8 State-Powered Summary ===' -ForegroundColor Cyan
Write-Host "  Entitlement:  $inScopeCount records (A:$approveCount R:$revokeCount P:$pendingCount U:$undecidedCount)" -ForegroundColor White
Write-Host "  Reviewer:     $rvTotal reviewers ($engLow low, $engMod moderate, $engHigh high engagement)" -ForegroundColor White
Write-Host "  State files:  last updated $lastRunDate" -ForegroundColor White

$totalDuration = (Get-Date) - $startTime
$durationStr = "$([math]::Round($totalDuration.TotalSeconds, 1))"
Write-Host "  Duration:     ${durationStr} seconds" -ForegroundColor White
Write-Host ''

} # end Console block

#endregion

#region Audit Trail

$totalDuration = (Get-Date) - $startTime
$durationStr = "$([math]::Round($totalDuration.TotalSeconds, 1))s"

try {
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV8 completed: Duration=$durationStr Entitlements=$entTotal Reviewers=$rvTotal" `
        -Severity INFO -Component 'DailyEvidenceV8' -Action 'Complete' -CorrelationID $correlationID
} catch { }

Write-Host "  Duration: $durationStr" -ForegroundColor DarkGray

#endregion

# Exit contract: 5 = no state data at all (documented; previously unreachable --
# an empty report exited 0 and schedulers never noticed).
if ($entTotal -eq 0 -and $rvTotal -eq 0) {
    Write-Host '' -ForegroundColor Red
    Write-Host '  ERROR: No state data available.' -ForegroundColor Red
    Write-Host '' -ForegroundColor Yellow
    Write-Host '  V8 needs cached items to build state files. To populate:' -ForegroundColor Yellow
    Write-Host '' -ForegroundColor Yellow
    Write-Host '    Option 1 -- Run V4b first:' -ForegroundColor Yellow
    Write-Host '      .\Invoke-SPDailyEvidenceReportV4b.ps1 -DaysBack 18 -OutputMode Both' -ForegroundColor White
    Write-Host '' -ForegroundColor Yellow
    Write-Host '    Option 2 -- Let V8 fetch automatically:' -ForegroundColor Yellow
    Write-Host '      .\Invoke-SPDailyEvidenceReportV8.ps1 -DaysBack 18 -AutoFetch -Token <token>' -ForegroundColor White
    Write-Host '' -ForegroundColor Yellow
    Write-Host '    Option 3 -- Use settings.json credentials:' -ForegroundColor Yellow
    Write-Host '      .\Invoke-SPDailyEvidenceReportV8.ps1 -DaysBack 18 -AutoFetch' -ForegroundColor White
    Write-Host '      (requires Authentication configured in settings.json)' -ForegroundColor DarkGray
    Write-Host '' -ForegroundColor Red
    exit 5
}
exit 0

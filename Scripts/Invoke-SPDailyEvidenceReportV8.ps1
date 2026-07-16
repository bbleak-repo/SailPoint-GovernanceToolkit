#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the daily evidence report (v8) -- fast, state-powered HTML report
    that reads pre-computed entitlement and reviewer state files.
.DESCRIPTION
    V8 is a read-only visualization script. It reads entitlement-state.jsonl and
    reviewer-state.jsonl (populated by Update-SPStateFiles.ps1) plus lightweight
    campaign metadata from daily-metrics.jsonl. V8 never calls the ISC API and
    never parses raw campaign cache. Target execution: <30 seconds.

    Data sources:
      {Metrics.Path}/entitlement-state.jsonl  (via Read-SPStateFiles)
      {Metrics.Path}/reviewer-state.jsonl     (via Read-SPStateFiles)
      {Metrics.Path}/daily-metrics.jsonl      (campaign summary, optional)

    Report sections (8):
      1  Entitlement State Summary (KPI tiles)
      2  Newly Decided (state transitions matching lastRunDate)
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
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [int]$ChronicThreshold = 5,

    [Parameter()]
    [ValidateSet('Console', 'HTML', 'Both')]
    [string]$OutputMode = 'Both',

    [Parameter()]
    [switch]$NoCache,

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
        Parses a dayLog string (e.g. "C:0601|M:0602|P:0603") into an ordered list
        of [hashtable] with keys Date (MMDD) and State (C/P/M/U).
    #>
    param([string]$DayLog)
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    if ([string]::IsNullOrWhiteSpace($DayLog)) { return $entries }
    foreach ($part in $DayLog.Split('|')) {
        if ($part.Length -ge 6 -and $part[1] -eq ':') {
            $entries.Add(@{ Date = $part.Substring(2); State = [string]$part[0] })
        }
    }
    return $entries
}

function Get-V8CurrentIsoWeek {
    $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    $now = Get-Date
    $weekNum = $cal.GetWeekOfYear($now, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [System.DayOfWeek]::Monday)
    $year = $now.Year
    if ($weekNum -eq 1 -and $now.Month -eq 12) { $year++ }
    if ($weekNum -ge 52 -and $now.Month -eq 1) { $year-- }
    return '{0}-W{1:D2}' -f $year, $weekNum
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

# Resolve date range (shared helper from SP.StateOrchestrator)
$dateRange = Resolve-SPReportDateRange -DaysBack $DaysBack -StartDate $StartDate -EndDate $EndDate
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

#region Step 1: Read State Files

Write-Host '  Step 1: Read state files' -ForegroundColor Cyan
Write-Host "    Metrics dir: $metricsDir" -ForegroundColor DarkGray

$tracking = Read-SPStateFiles -MetricsPath $metricsDir

# Auto-refresh: if state files are missing or stale (not updated today), rebuild from cache.
# Uses delta mode (processedInstances) so only new campaign instances are processed.
# First run (bootstrap) is slower; subsequent runs are fast (~30 sec).
$isStale = $tracking.Entitlement.IsFirstRun -or ([string]$tracking.Entitlement.LastRunDate -ne $todayLabel)
if ($isStale) {
    $staleReason = if ($tracking.Entitlement.IsFirstRun) { 'no state files found' } else { "last updated $($tracking.Entitlement.LastRunDate)" }
    Write-Host "    Auto-refresh needed ($staleReason)" -ForegroundColor Yellow
    Write-Host '    Updating from cache...' -ForegroundColor Yellow
    try {
        $tracking = Invoke-SPStateTracking -MetricsPath $metricsDir -TodayLabel $todayLabel
        Write-Host "    Refreshed: $($tracking.Entitlement.Total) entitlements, $($tracking.Reviewer.Total) reviewers" -ForegroundColor Green
    }
    catch {
        Write-Host "    WARN: Auto-refresh failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '    Continuing with existing state data (may be incomplete).' -ForegroundColor Yellow
        # Re-read whatever exists (might be partial from a prior run)
        $tracking = Read-SPStateFiles -MetricsPath $metricsDir
    }
}

$entStateMap  = $tracking.Entitlement.StateMap
$entTotal     = $tracking.Entitlement.Total
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

    # Only show items that transitioned from PENDING/UNDECIDED (genuine new decisions)
    $priorDecision = ''
    if ($rec.ContainsKey('priorDecision')) { $priorDecision = [string]$rec['priorDecision'] }
    if ($priorDecision -ne 'PENDING' -and $priorDecision -ne 'UNDECIDED' -and $priorDecision -ne '') { continue }

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
    $entries = Get-V8DayLogEntries -DayLog $dayLog
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

# ======================== Section 2: Newly Decided ========================
[void]$sb.Append('<div class="section"><h2>2. Newly Decided</h2>')
if ($newlyDecidedSorted.Count -eq 0) {
    [void]$sb.Append("<p class='note'>No state changes detected. State files last updated: $safeLastRun.</p>")
}
else {
    [void]$sb.Append("<p class='note'>$($newlyDecidedSorted.Count) entitlement(s) changed state on $safeLastRun.</p>")
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
        # Format MMDD as MM/DD
        $hdLabel = $hd
        if ($hd.Length -eq 4) { $hdLabel = $hd.Substring(0,2) + '/' + $hd.Substring(2,2) }
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
                $st = $entryLookup[$hd]
                [void]$sb.Append("<td style='text-align:center;padding:3px'><span class='heat-cell hc-$st'>$st</span></td>")
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
    # Sort by captureDate descending, then campaign name
    $campSorted = @($campaignRecords | Sort-Object { [string]$_.captureDate }, { [string]$_.campaign.name } -Descending)

    [void]$sb.Append('<table class="report"><tr><th>Date</th><th>Campaign</th><th>Status</th><th>Total</th><th>Approved</th><th>Revoked</th><th>Undecided</th><th>Completion %</th></tr>')

    $maxCampRows = 50
    $campRowCount = 0
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

        $crTotal     = 0; $crApproved = 0; $crRevoked = 0; $crUndecided = 0; $crCompPct = 0
        try {
            $sm = $cr.summary
            if ($null -ne $sm) {
                $crTotal     = [int](Get-V8Prop -Object $sm -Name 'total' -Default 0)
                $crApproved  = [int](Get-V8Prop -Object $sm -Name 'approved' -Default 0)
                $crRevoked   = [int](Get-V8Prop -Object $sm -Name 'revoked' -Default 0)
                $crUndecided = [int](Get-V8Prop -Object $sm -Name 'undecided' -Default 0)
                $crCompPct   = [double](Get-V8Prop -Object $sm -Name 'completionPct' -Default 0)
            }
        } catch { }
        $compPctStr = [math]::Round($crCompPct, 1)
        $compClass = 's-green'
        if ($crCompPct -lt 50) { $compClass = 's-red' }
        elseif ($crCompPct -lt 80) { $compClass = 's-amber' }

        [void]$sb.Append('<tr>')
        [void]$sb.Append("<td>$crDate</td>")
        [void]$sb.Append("<td>$crName</td>")
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

exit 0

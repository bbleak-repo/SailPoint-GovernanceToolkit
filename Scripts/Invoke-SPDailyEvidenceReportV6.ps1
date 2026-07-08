#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the daily certification evidence report (v6) -- pure visualization
    from daily-metrics.jsonl (output: daily-evidence-v6-*.html).
.DESCRIPTION
    V6 is a read-only visualization script. It reads daily-metrics.jsonl written
    by V4 and renders multi-day progression charts. V6 never calls the ISC API.

    Data source: {Metrics.Path}/daily-metrics.jsonl
    Each JSONL line contains one campaign capture with: captureDate, campaign info,
    summary metrics, per-reviewer detail, source breakdown, and diff data.

    Charts rendered (10 sections):
      1  KPI Banner + Executive Summary
      2  Metric Trends (day-by-day bar charts: Completion, Approved, Revoked, Pending)
      3  Per-Reviewer Accountability Table (with direction arrows and In Scope Since)
      4  Stacked Decision Distribution (day-by-day green/red/gray bars)
      5  Privileged Access Trend (KPI cards + bar chart)
      6  Completion Projection vs Deadline (line chart with dashed projection)
      7  Reviewer Activity Heatmap (decision intensity grid)
      8  Vertical Completion Progression (grouped blue+green bars)
      9  Cross-Campaign Risk Matrix (table with thermometers and risk scores)

    Exit codes:
        0 = Healthy (completion >= 80%, no stalled reviewers, on track)
        1 = Warning (completion 50-79%, some concerns)
        2 = Parameter error
        4 = Configuration error
        5 = Critical (completion < 50%, stalled, or insufficient data)
.PARAMETER DaysBack
    Lookback window in days. Default: 7.
.PARAMETER CampaignNameContains
    Campaign name contains this substring (case-insensitive).
.PARAMETER OutputPath
    Directory for output files. Defaults to daily-evidence subdirectory.
.PARAMETER OutputMode
    Console: formatted summary to terminal.
    HTML: self-contained HTML report file.
    Both (default): console output and HTML file.
.PARAMETER Help
    Display detailed help.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV6.ps1
    # Render last 7 days from daily-metrics.jsonl.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV6.ps1 -DaysBack 14 -CampaignNameContains 'Q2'
    # 14-day trend for campaigns matching 'Q2'.
.NOTES
    Script:  Invoke-SPDailyEvidenceReportV6.ps1
    Version: 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter()]
    [int]$DaysBack = 7,

    [Parameter()]
    [string]$CampaignNameContains,

    [Parameter()]
    [ValidateSet('ACTIVE', 'COMPLETED', 'COMPLETING', '')]
    [string]$Status,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateSet('Console', 'HTML', 'Both')]
    [string]$OutputMode = 'Both',

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

#region Setup

$startTime = Get-Date
$correlationID = [guid]::NewGuid().ToString()
$todayLabel = $startTime.ToString('yyyy-MM-dd')

$cfgPath = $null
try {
    $cfgPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
} catch {
    # Fallback: try default location
    $defaultCfg = Join-Path $toolkitRoot 'settings.json'
    if (Test-Path $defaultCfg) { $cfgPath = $defaultCfg }
}

$config = $null
if ($cfgPath) {
    try {
        $config = Get-SPConfig -ConfigPath $cfgPath
    }
    catch {
        Write-Host "WARN: Failed to load configuration: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$effectiveDaysBack = $DaysBack
if ($effectiveDaysBack -le 0) { $effectiveDaysBack = 7 }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Daily Evidence Report (v6) -- Metrics Visualization' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  Period:        Last $effectiveDaysBack day(s)" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

try {
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV6 started: CorrelationID=$correlationID DaysBack=$effectiveDaysBack" `
        -Severity INFO -Component 'DailyEvidenceV6' -Action 'Start' -CorrelationID $correlationID
} catch { }

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

#endregion

#region Helper: safe property access

function Get-V6Prop {
    param($Object, [string]$Name, $Default = '')
    return (Get-SPObjectProperty -Object $Object -Name $Name -Default $Default)
}

function Get-V6NumericProp {
    # Read a numeric property from a PSCustomObject or hashtable.
    # Returns a scalar value. If the value is an array, takes the first element.
    param([object]$Obj, [string]$Name, $Default = 0)
    if ($null -eq $Obj) { return $Default }
    try {
        $v = $null
        if ($Obj -is [System.Collections.IDictionary]) {
            if ($Obj.Contains($Name)) { $v = $Obj[$Name] }
        }
        else {
            $p = $Obj.PSObject.Properties[$Name]
            if ($null -ne $p) { $v = $p.Value }
        }
        if ($null -eq $v) { return $Default }
        if ($v -is [System.Array]) { $v = $v[0] }
        return $v
    } catch { }
    return $Default
}

#endregion

#region Step 1: Resolve metrics path and read daily-metrics.jsonl

Write-Host '  Step 1: Resolve metrics path and read daily-metrics.jsonl' -ForegroundColor Cyan

$metricsDir = $null
if ($null -ne $config) {
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

$jsonlPath = Join-Path $metricsDir 'daily-metrics.jsonl'
Write-Host "    Metrics file: $jsonlPath" -ForegroundColor DarkGray

if (-not (Test-Path $jsonlPath)) {
    Write-Host '' -ForegroundColor Red
    Write-Host '  ERROR: daily-metrics.jsonl not found.' -ForegroundColor Red
    Write-Host "  Expected at: $jsonlPath" -ForegroundColor Red
    Write-Host '' -ForegroundColor Yellow
    Write-Host '  Suggestions:' -ForegroundColor Yellow
    Write-Host '    - Run the daily orchestrator (V4) at least once to generate metrics' -ForegroundColor Yellow
    Write-Host '    - Verify Metrics.Path in settings.json' -ForegroundColor Yellow
    Write-Host '' -ForegroundColor Red
    exit 5
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$cutoffDate = (Get-Date).AddDays(-$effectiveDaysBack).ToString('yyyy-MM-dd')
$allRecords = [System.Collections.Generic.List[object]]::new()

$rawLines = [System.IO.File]::ReadAllLines($jsonlPath, $utf8)
foreach ($ln in $rawLines) {
    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
    try {
        $rec = $ln | ConvertFrom-Json
        $capDate = [string]$rec.captureDate
        if ([string]::IsNullOrWhiteSpace($capDate)) { continue }

        # Filter by DaysBack
        if ($capDate -lt $cutoffDate) { continue }

        # Filter by CampaignNameContains
        if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
            $campName = [string]$rec.campaign.name
            if ($campName.IndexOf($CampaignNameContains, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }
        }

        # Filter by Status
        if (-not [string]::IsNullOrWhiteSpace($Status)) {
            $recStatus = [string]$rec.campaign.status
            if ($recStatus.ToUpperInvariant() -ne $Status.ToUpperInvariant()) {
                continue
            }
        }

        $allRecords.Add($rec)
    } catch { }
}

Write-Host "    Loaded $($allRecords.Count) record(s) within ${effectiveDaysBack}-day window" -ForegroundColor DarkGray

if ($allRecords.Count -eq 0) {
    Write-Host '' -ForegroundColor Red
    Write-Host '  ERROR: No matching records found in daily-metrics.jsonl.' -ForegroundColor Red
    Write-Host '' -ForegroundColor Yellow
    Write-Host '  Suggestions:' -ForegroundColor Yellow
    Write-Host "    - Increase -DaysBack (current: $effectiveDaysBack)" -ForegroundColor Yellow
    Write-Host '    - Check your -CampaignNameContains filter' -ForegroundColor Yellow
    Write-Host "    - Verify data exists in: $jsonlPath" -ForegroundColor Yellow
    Write-Host '' -ForegroundColor Red
    exit 5
}

Write-Host ''

#endregion

#region Step 2: Deduplicate and sort records

Write-Host '  Step 2: Deduplicate and sort records' -ForegroundColor Cyan

# Deduplicate: one record per campaignId per captureDate. If V4 ran multiple
# times for the same campaign on the same day, keep the latest captureTimestamp.
# For daily campaigns, each day has a DIFFERENT campaignId, so each gets its own slot.
$dayMap = [ordered]@{}
foreach ($rec in $allRecords) {
    $dayKey = [string]$rec.captureDate
    $campId = ''
    try { $campId = [string]$rec.campaign.id } catch { }
    $dedupKey = "${dayKey}|${campId}"
    if ($dayMap.Contains($dedupKey)) {
        $existingTs = [string]$dayMap[$dedupKey].captureTimestamp
        $newTs = [string]$rec.captureTimestamp
        if ($newTs -gt $existingTs) {
            $dayMap[$dedupKey] = $rec
        }
    }
    else {
        $dayMap[$dedupKey] = $rec
    }
}

# Sort by captureDate ascending (compound key is "date|campaignId", sort works lexicographically)
$sortedKeys = @($dayMap.Keys | Sort-Object)

# Build $dailyData array
$dailyData = @()
foreach ($dayKey in $sortedKeys) {
    $rec = $dayMap[$dayKey]
    $dateStr = [string]$rec.captureDate
    $ts = [datetime]::Parse($dateStr)
    $sm = $rec.summary

    # Map per-reviewer data from the reviewers array
    $dayReviewers = @()
    $reviewerArray = $null
    try {
        if ($null -ne $rec.PSObject.Properties['reviewers'] -and $null -ne $rec.reviewers) {
            $reviewerArray = @($rec.reviewers)
        }
    } catch { }

    if ($null -ne $reviewerArray) {
        foreach ($rv in $reviewerArray) {
            if ($null -eq $rv) { continue }
            $rvName = [string](Get-V6Prop $rv 'name' '')
            if ([string]::IsNullOrWhiteSpace($rvName)) { continue }
            $dayReviewers += @{
                Name       = $rvName
                Total      = [int](Get-V6NumericProp $rv 'total' 0)
                Approved   = [int](Get-V6NumericProp $rv 'approved' 0)
                Revoked    = [int](Get-V6NumericProp $rv 'revoked' 0)
                Pending    = [int](Get-V6NumericProp $rv 'pending' 0)
                Completion = [double](Get-V6NumericProp $rv 'completionPct' 0)
                Signed     = $false
                Phase      = [string](Get-V6Prop $rv 'phase' '')
            }
            # Check signed
            try {
                $signedVal = Get-V6Prop $rv 'signed' $false
                if ($signedVal -eq $true -or $signedVal -eq 'True') {
                    $dayReviewers[$dayReviewers.Count - 1].Signed = $true
                }
            } catch { }
        }
    }

    $totalItems = [int](Get-V6NumericProp $sm 'totalItems' 0)
    $approvedItems = [int](Get-V6NumericProp $sm 'approved' 0)
    $revokedItems = [int](Get-V6NumericProp $sm 'revoked' 0)
    $pendingItems = [int](Get-V6NumericProp $sm 'pending' 0)

    $dailyData += @{
        Date            = $ts.ToString('yyyy-MM-dd')
        DayLabel        = $ts.ToString('MM/dd')
        Reviewers       = $dayReviewers
        Total           = $totalItems
        Approved        = $approvedItems
        Revoked         = $revokedItems
        Pending         = $pendingItems
        CompletionPct   = [double](Get-V6NumericProp $sm 'completionPct' 0)
        ReviewersTotal  = [int](Get-V6NumericProp $sm 'reviewersTotal' 0)
        ReviewersSigned = [int](Get-V6NumericProp $sm 'reviewersSigned' 0)
        PrivTotal       = [int](Get-V6NumericProp $sm 'privilegedTotal' 0)
        PrivApproved    = [int](Get-V6NumericProp $sm 'privilegedApproved' 0)
        PrivRevoked     = [int](Get-V6NumericProp $sm 'privilegedRevoked' 0)
        PrivPending     = [int](Get-V6NumericProp $sm 'privilegedPending' 0)
        ScopeAdded      = 0
        ScopeRemoved    = 0
        NewlyApproved   = 0
        NewlyDecided    = 0
        CampaignName    = [string]$rec.campaign.name
        CampaignId      = [string]$rec.campaign.id
        CampaignStatus  = [string]$rec.campaign.status
        CampaignDeadline = ''
        DiffData        = $null
    }
    # Populate deadline
    try {
        $dlVal = [string]$rec.campaign.deadline
        if (-not [string]::IsNullOrWhiteSpace($dlVal)) {
            $dailyData[$dailyData.Count - 1].CampaignDeadline = $dlVal
        }
    } catch { }
    # Populate diff data
    try {
        if ($null -ne $rec.PSObject.Properties['diff'] -and $null -ne $rec.diff) {
            $dailyData[$dailyData.Count - 1].DiffData = $rec.diff
            $dailyData[$dailyData.Count - 1].ScopeAdded = [int](Get-V6NumericProp $rec.diff 'scopeAdded' 0)
            $dailyData[$dailyData.Count - 1].ScopeRemoved = [int](Get-V6NumericProp $rec.diff 'scopeRemoved' 0)
            $dailyData[$dailyData.Count - 1].NewlyApproved = [int](Get-V6NumericProp $rec.diff 'newlyApprovedCount' 0)
            $dailyData[$dailyData.Count - 1].NewlyDecided = [int](Get-V6NumericProp $rec.diff 'newlyDecidedCount' 0)
        }
    } catch { }
}

$dayCount = $dailyData.Count
Write-Host "    Built $dayCount daily data point(s)" -ForegroundColor DarkGray

# Build reviewer list (distinct across all days, sorted alphabetically)
$reviewerNames = [ordered]@{}
foreach ($d in $dailyData) {
    foreach ($rv in $d.Reviewers) {
        $rn = $rv.Name
        if (-not [string]::IsNullOrWhiteSpace($rn) -and -not $reviewerNames.Contains($rn)) {
            $reviewerNames[$rn] = $true
        }
    }
}

# Build reviewer summary with behavior classification and first-seen tracking
$reviewerList = @()
foreach ($rn in ($reviewerNames.Keys | Sort-Object)) {
    [double]$firstComp = -1; [double]$lastComp = 0; $firstSeenIdx = -1
    [double]$yesterdayComp = 0
    for ($di = 0; $di -lt $dailyData.Count; $di++) {
        $rvDay = $null
        foreach ($r in $dailyData[$di].Reviewers) {
            if ($r.Name -eq $rn) { $rvDay = $r; break }
        }
        if ($null -ne $rvDay) {
            $compVal = [double]$rvDay.Completion
            if ($firstComp -lt 0) { $firstComp = $compVal; $firstSeenIdx = $di }
            if ($di -eq ($dailyData.Count - 2)) { $yesterdayComp = $compVal }
            $lastComp = $compVal
        }
    }
    if ($firstComp -lt 0) { $firstComp = 0 }

    [double]$delta = $lastComp - $firstComp
    $rvStyle = 'steady'
    if ($lastComp -ge 100) { $rvStyle = 'finishing' }
    elseif ($lastComp -ge 90) { $rvStyle = 'finishing' }
    elseif ($delta -lt 1 -and $lastComp -lt 95) { $rvStyle = 'stalled' }
    elseif ($delta -lt 5) { $rvStyle = 'slow' }

    $reviewerList += @{
        Name              = $rn
        StartCompletion   = $firstComp
        YesterdayCompletion = $yesterdayComp
        LastCompletion    = $lastComp
        Style             = $rvStyle
        FirstSeenIdx      = $firstSeenIdx
        FirstSeenDate     = if ($firstSeenIdx -ge 0) { $dailyData[$firstSeenIdx].DayLabel } else { 'N/A' }
    }
}

Write-Host "    Reviewers: $($reviewerList.Count)" -ForegroundColor DarkGray
Write-Host ''

# Resolve campaign metadata from the latest record
$campaignNameResolved = $dailyData[$dayCount - 1].CampaignName
$campaignIdResolved = $dailyData[$dayCount - 1].CampaignId
$campaignStatusResolved = $dailyData[$dayCount - 1].CampaignStatus
$campaignDeadlineResolved = $dailyData[$dayCount - 1].CampaignDeadline

# Check if this spans multiple campaigns
$distinctCampIds = [ordered]@{}
foreach ($d in $dailyData) {
    $cid = $d.CampaignId
    if (-not [string]::IsNullOrWhiteSpace($cid) -and -not $distinctCampIds.Contains($cid)) {
        $distinctCampIds[$cid] = $d.CampaignName
    }
}
if ($distinctCampIds.Count -gt 1) {
    # Try to find a common prefix
    $allNames = @($distinctCampIds.Values)
    $prefix = $allNames[0]
    foreach ($n in $allNames) {
        while ($prefix.Length -gt 0 -and -not $n.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $prefix = $prefix.Substring(0, $prefix.Length - 1)
        }
    }
    $prefix = $prefix.TrimEnd(' ', '-', '_')
    if ($prefix.Length -lt 5) { $prefix = $allNames[0] }
    $campaignNameResolved = "$prefix ($($distinctCampIds.Count) campaigns)"
}

Write-Host "    Campaign: $campaignNameResolved" -ForegroundColor DarkGray
Write-Host "    Status: $campaignStatusResolved" -ForegroundColor DarkGray
Write-Host ''

#endregion

#region Insufficient Data Guard

$insufficientData = ($dayCount -lt 2)

if ($insufficientData) {
    Write-Host '  NOTE: Less than 2 data points -- single-point report only.' -ForegroundColor Yellow
    Write-Host '        Multi-day charts require at least 2 captures on different days.' -ForegroundColor Yellow
    Write-Host ''
}

#endregion

#region Build HTML Report

Write-Host '  Step 3: Build HTML report' -ForegroundColor Cyan

$colors = Get-SPHtmlColorPalette
$genDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$safeCampId = $campaignIdResolved -replace '[^A-Za-z0-9_\-]', '_'
$htmlFile = Join-Path $effectiveOutputPath "daily-evidence-v6-${safeCampId}-${timestamp}.html"

$css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;background:#fff;max-width:1200px;}
h1{font-size:22px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;margin-bottom:4px;}
h2{font-size:17px;color:#1f3a5f;margin-top:30px;border-bottom:1px solid #d4dce6;padding-bottom:4px;}
h3{font-size:14px;color:#336699;margin-top:20px;}
.meta{color:#566;font-size:12px;margin-bottom:16px;line-height:1.6;}
table{border-collapse:collapse;width:100%;margin:8px 0 16px 0;font-size:12px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 8px;font-weight:600;}
td{border-bottom:1px solid #e3e9f0;padding:5px 8px;vertical-align:top;}
tr:nth-child(even) td{background:#f6f9fc;}
.kpi{display:inline-block;min-width:130px;margin:6px 10px 6px 0;padding:10px 14px;border:1px solid #d4dce6;border-radius:6px;background:#f6f9fc;text-align:center;}
.kpi .n{font-size:22px;font-weight:700;color:#1f3a5f;display:block;}
.kpi .l{font-size:11px;color:#566;text-transform:uppercase;letter-spacing:.04em;}
.note{font-size:11px;color:#777;margin-top:4px;}
.section{margin:24px 0;padding:16px 20px;border:1px solid #d4dce6;border-radius:8px;background:#fafbfd;}
.section-title{font-size:15px;color:#1f3a5f;font-weight:700;margin:0 0 12px 0;padding-bottom:6px;border-bottom:1px solid #d4dce6;}
.bar-track{background:#e3e9f0;border-radius:4px;height:18px;width:100%;position:relative;overflow:hidden;}
.bar-fill{height:18px;border-radius:4px;transition:width 0.3s;}
.bar-label{position:absolute;right:4px;top:1px;font-size:10px;font-weight:600;color:#1f3a5f;}
.stacked-bar{display:flex;height:22px;border-radius:4px;overflow:hidden;margin:2px 0;}
.stacked-seg{height:22px;display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:600;color:#fff;}
.up-arrow{display:inline-block;width:0;height:0;border-left:5px solid transparent;border-right:5px solid transparent;border-bottom:8px solid #0a7d2c;margin-right:3px;}
.down-arrow{display:inline-block;width:0;height:0;border-left:5px solid transparent;border-right:5px solid transparent;border-top:8px solid #b00020;margin-right:3px;}
.flat-line{display:inline-block;width:12px;height:3px;background:#9a6700;margin-right:3px;vertical-align:middle;}
.delta-up{color:#0a7d2c;font-weight:600;}
.delta-down{color:#b00020;font-weight:600;}
.delta-flat{color:#9a6700;}
.footer{margin-top:24px;padding-top:8px;border-top:1px solid #d4dce6;font-size:11px;color:#777;}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:9px;font-weight:700;color:#fff;margin-left:6px;vertical-align:middle;}
.badge-red{background:#b00020;}
.badge-amber{background:#9a6700;}
.badge-green{background:#0a7d2c;}
.risk-matrix td{padding:6px 8px;font-size:12px;border-bottom:1px solid #e3e9f0;vertical-align:middle;}
.risk-matrix th{padding:6px 8px;font-size:11px;}
.thermometer{display:inline-block;width:100px;height:14px;background:#e3e9f0;border-radius:7px;overflow:hidden;vertical-align:middle;}
.thermometer-fill{height:14px;border-radius:7px;}
'@

$sb = New-Object System.Text.StringBuilder 32768
[void]$sb.AppendLine("<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Daily Evidence V6 -- Metrics Visualization</title><style>$css</style></head><body>")

# Header
[void]$sb.AppendLine("<h1>Daily Certification Evidence Report (V6) -- Metrics Visualization</h1>")
[void]$sb.AppendLine("<p class='meta'>")
[void]$sb.AppendLine("Campaign: <strong>$(ConvertTo-SPHtmlSafe $campaignNameResolved)</strong><br>")
[void]$sb.AppendLine("Status: $(ConvertTo-SPHtmlSafe $campaignStatusResolved)<br>")
if ($dayCount -ge 2) {
    [void]$sb.AppendLine("Period: Last $dayCount captures ($($dailyData[0].Date) to $($dailyData[$dayCount - 1].Date))<br>")
} else {
    [void]$sb.AppendLine("Period: Single capture ($($dailyData[0].Date))<br>")
}
[void]$sb.AppendLine("Generated: $genDate</p>")

#endregion

#region Chart 1: KPI Banner + Executive Summary

$todayRec = $dailyData[$dayCount - 1]
$yesterdayRec = if ($dayCount -ge 2) { $dailyData[$dayCount - 2] } else { $todayRec }
$weekAgoRec = $dailyData[0]
$completionDelta = [math]::Round([double]$todayRec.CompletionPct - [double]$yesterdayRec.CompletionPct, 1)
$weekDelta = [math]::Round([double]$todayRec.CompletionPct - [double]$weekAgoRec.CompletionPct, 1)

# Resolve deadline days
$effectiveDeadlineDays = 5
$isOverdue = $false
if (-not [string]::IsNullOrWhiteSpace($campaignDeadlineResolved)) {
    try {
        $dueDt = [datetime]::Parse([string]$campaignDeadlineResolved, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $daysToDeadline = [int][math]::Floor(($dueDt - (Get-Date)).TotalDays)
        $effectiveDeadlineDays = $daysToDeadline
        if ($daysToDeadline -lt 0) { $isOverdue = $true }
    } catch { }
}

[void]$sb.AppendLine("<div style='margin:16px 0;'>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($todayRec.CompletionPct)%</span><span class='l'>Completion</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($todayRec.Approved)</span><span class='l'>Approved</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($todayRec.Revoked)</span><span class='l'>Revoked</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$($colors.Red);'>$($todayRec.Pending)</span><span class='l'>Pending</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($todayRec.ReviewersTotal)</span><span class='l'>Reviewers</span></span>")

if ($dayCount -ge 2) {
    $dSign = if ($weekDelta -gt 0) { '+' } else { '' }
    $dColor = if ($weekDelta -gt 5) { $colors.Green } elseif ($weekDelta -lt -2) { $colors.Red } else { $colors.Amber }
    $dLabel = "${dayCount}-Day Change"
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$dColor;'>${dSign}${weekDelta}%</span><span class='l'>$dLabel</span></span>")
}

# Deadline KPI
if ($isOverdue) {
    $overdueDays = [math]::Abs($effectiveDeadlineDays)
    [void]$sb.AppendLine("<span class='kpi' style='border-color:$($colors.Red);background:#fdecec;'><span class='n' style='color:$($colors.Red);'>OVERDUE</span><span class='l'>by $overdueDays day(s)</span></span>")
    $dlKpiColor = $colors.Red
} else {
    $dlKpiColor = if ($effectiveDeadlineDays -le 3) { $colors.Red } elseif ($effectiveDeadlineDays -le 7) { $colors.Amber } else { $colors.Green }
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$dlKpiColor;'>$effectiveDeadlineDays</span><span class='l'>Days to Deadline</span></span>")
}
[void]$sb.AppendLine("</div>")

# Executive summary paragraph
$stalledRvCount = 0
foreach ($rv in $reviewerList) { if ($rv.Style -eq 'stalled') { $stalledRvCount++ } }
$privPendCount = [int]$todayRec.PrivPending
$velocityPerDay = if ($dayCount -ge 2) { [math]::Round(([double]$todayRec.CompletionPct - [double]$weekAgoRec.CompletionPct) / [math]::Max(1, $dayCount - 1), 1) } else { 0 }

if ($isOverdue) {
    $summaryText = "Campaign is $($todayRec.CompletionPct)% complete and OVERDUE by $([math]::Abs($effectiveDeadlineDays)) day(s)."
} else {
    $projectedCompletion = [math]::Min(100, [double]$todayRec.CompletionPct + ($velocityPerDay * $effectiveDeadlineDays))
    $willComplete = if ($projectedCompletion -ge 99.5) { 'will' } else { 'will NOT' }
    $summaryText = "Campaign is $($todayRec.CompletionPct)% complete with $effectiveDeadlineDays business days until deadline."
}
if ($stalledRvCount -gt 0) {
    $summaryText += " $stalledRvCount reviewer(s) have made zero progress (stalled)."
}
if ($privPendCount -gt 0) {
    $summaryText += " $privPendCount privileged access items remain pending review."
}
if ($dayCount -ge 2 -and -not $isOverdue) {
    $summaryText += " Current velocity (${velocityPerDay}%/day) suggests the campaign $willComplete complete on time."
}
elseif ($dayCount -ge 2 -and $isOverdue) {
    $remaining = 100 - [double]$todayRec.CompletionPct
    $daysNeeded = if ($velocityPerDay -gt 0) { [int][math]::Ceiling($remaining / $velocityPerDay) } else { 999 }
    $summaryText += " Current velocity (${velocityPerDay}%/day). Estimated $daysNeeded more business day(s) needed to complete."
}
[void]$sb.AppendLine("<p style='font-size:13px;color:#1c2b3a;line-height:1.6;margin:12px 0 16px 0;padding:10px 14px;background:#f6f9fc;border-left:4px solid $dlKpiColor;border-radius:4px;'>$summaryText</p>")

# Insufficient data banner
if ($insufficientData) {
    [void]$sb.AppendLine("<div class='section' style='background:#fff7e6;border-color:#ffd97a;'>")
    [void]$sb.AppendLine("<div class='section-title' style='color:#7a5a00;'>Insufficient Trend Data</div>")
    [void]$sb.AppendLine("<p style='color:#7a5a00;font-size:13px;'>Only $dayCount data point(s) available. Multi-day progression charts require at least 2 captures on different days. Below shows today's snapshot data only. Run V4 daily to accumulate the series.</p>")
    [void]$sb.AppendLine("</div>")
}

#endregion

#region Chart 2: Metric Trends -- Day-by-Day Bar Charts

function Build-MetricBarChart {
    param([string]$Title, [double[]]$Values, [string[]]$Labels, [string]$Color, [string]$Unit = '',
          [int]$ChartW = 600, [int]$ChartH = 160, [bool]$HighIsGood = $true)
    $leftPad = 45; $topPad = 10; $bottomPad = 40
    $drawH = $ChartH - $topPad - $bottomPad
    $cnt = $Values.Count
    if ($cnt -eq 0) { return '' }
    $barW = [int][math]::Floor(($ChartW - $leftPad - 10) / $cnt * 0.65)
    $gapW = [int][math]::Floor(($ChartW - $leftPad - 10) / $cnt * 0.35)
    $maxVal = [math]::Max(1, ($Values | Measure-Object -Maximum).Maximum)

    $first = $Values[0]; $last = $Values[$cnt - 1]; $delta = [math]::Round($last - $first, 1)
    $dSignLocal = if ($delta -gt 0) { '+' } else { '' }
    $dColorLocal = if ($HighIsGood) { if ($delta -gt 0) { '#0a7d2c' } elseif ($delta -lt 0) { '#b00020' } else { '#9a6700' } } else { if ($delta -gt 0) { '#b00020' } elseif ($delta -lt 0) { '#0a7d2c' } else { '#9a6700' } }

    $svgH = $ChartH + 10
    $svg = "<div style='margin:8px 0;'>"
    $svg += "<div style='font-size:13px;font-weight:600;color:#1f3a5f;margin-bottom:4px;'>$Title <span style='font-size:12px;color:$dColorLocal;margin-left:8px;'>${dSignLocal}${delta}${Unit} vs first capture</span></div>"
    $svg += "<svg width='$ChartW' height='$svgH' style='font-family:Segoe UI,Arial,sans-serif;'>"

    for ($g = 0; $g -le 4; $g++) {
        $gVal = [math]::Round($maxVal * $g / 4, 0)
        $gy = $topPad + $drawH - [int]($drawH * $g / 4)
        $svg += "<line x1='$leftPad' y1='$gy' x2='$ChartW' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>"
        $svg += "<text x='$($leftPad - 4)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>${gVal}${Unit}</text>"
    }

    for ($i = 0; $i -lt $cnt; $i++) {
        $v = $Values[$i]
        $bH = [int][math]::Max(2, [math]::Round($v / $maxVal * $drawH))
        $bX = $leftPad + $i * ($barW + $gapW) + [int]($gapW / 2)
        $bY = $topPad + $drawH - $bH
        $opacity = [math]::Round(0.4 + (0.6 * $i / [math]::Max(1, $cnt - 1)), 2)
        $svg += "<rect x='$bX' y='$bY' width='$barW' height='$bH' fill='$Color' opacity='$opacity' rx='2'/>"
        $svg += "<text x='$($bX + [int]($barW/2))' y='$($bY - 3)' text-anchor='middle' font-size='10' font-weight='600' fill='$Color'>$([math]::Round($v,0))${Unit}</text>"
        $labelY = $topPad + $drawH + 14
        $svg += "<text x='$($bX + [int]($barW/2))' y='$labelY' text-anchor='middle' font-size='9' fill='#566'>$($Labels[$i])</text>"
    }

    $svg += "</svg></div>"
    return $svg
}

[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<div class='section-title'>Metric Trends -- Day-by-Day Detail</div>")
[void]$sb.AppendLine("<p class='note'>Individual bar charts for key metrics showing the exact value per capture day. Each bar represents one business day of data.</p>")

$dayLabels = @()
foreach ($d in $dailyData) { $dayLabels += $d.DayLabel }

$completionVals = @(); $approvedVals = @(); $revokedVals = @(); $pendingVals = @()
foreach ($d in $dailyData) {
    $completionVals += [double]$d.CompletionPct
    $approvedVals += [double]$d.Approved
    $revokedVals += [double]$d.Revoked
    $pendingVals += [double]$d.Pending
}

$chart1 = Build-MetricBarChart -Title 'Overall Completion' -Values $completionVals -Labels $dayLabels -Color '#336699' -Unit '%' -HighIsGood $true
$chart2 = Build-MetricBarChart -Title 'Approved Items' -Values $approvedVals -Labels $dayLabels -Color $colors.Green -Unit '' -HighIsGood $true
$chart3 = Build-MetricBarChart -Title 'Revoked Items' -Values $revokedVals -Labels $dayLabels -Color $colors.Red -Unit '' -HighIsGood $false
$chart4 = Build-MetricBarChart -Title 'Pending Items' -Values $pendingVals -Labels $dayLabels -Color $colors.Amber -Unit '' -HighIsGood $false

[void]$sb.AppendLine($chart1)
[void]$sb.AppendLine($chart2)
[void]$sb.AppendLine($chart3)
[void]$sb.AppendLine($chart4)

[void]$sb.AppendLine("</div>")

#endregion

#region Chart 3: Per-Reviewer Accountability Table

if ($reviewerList.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Per-Reviewer Accountability -- Numeric Comparison with Direction</div>")
    [void]$sb.AppendLine("<p class='note'>Shows each reviewer's completion today vs first capture, with direction arrows. Stalled reviewers (zero change) are highlighted.</p>")

    [void]$sb.AppendLine("<table><thead><tr><th>Reviewer</th><th style='text-align:right;'>First</th><th style='text-align:right;'>Yesterday</th><th style='text-align:right;'>Today</th><th style='text-align:center;'>Direction</th><th style='text-align:right;'>Change</th><th>Status</th><th style='font-size:10px;'>In Scope Since</th></tr></thead><tbody>")
    $rvIdx = 0
    foreach ($rv in $reviewerList) {
        # Get today's reviewer data
        $todayRvData = $null
        foreach ($r in $dailyData[$dayCount - 1].Reviewers) {
            if ($r.Name -eq $rv.Name) { $todayRvData = $r; break }
        }
        # Get yesterday's reviewer data
        $yestRvData = $null
        if ($dayCount -ge 2) {
            foreach ($r in $dailyData[$dayCount - 2].Reviewers) {
                if ($r.Name -eq $rv.Name) { $yestRvData = $r; break }
            }
        }
        # Get first-seen reviewer data
        $firstRvData = $null
        if ($rv.FirstSeenIdx -ge 0) {
            foreach ($r in $dailyData[$rv.FirstSeenIdx].Reviewers) {
                if ($r.Name -eq $rv.Name) { $firstRvData = $r; break }
            }
        }

        [double]$todayPct = if ($todayRvData) { [double]$todayRvData.Completion } else { 0 }
        [double]$yestPct  = if ($yestRvData) { [double]$yestRvData.Completion } else { 0 }
        [double]$firstPct = if ($firstRvData) { [double]$firstRvData.Completion } else { 0 }
        $todayPct = [math]::Max(0, [math]::Min(100, $todayPct))
        $yestPct  = [math]::Max(0, [math]::Min(100, $yestPct))
        $firstPct = [math]::Max(0, [math]::Min(100, $firstPct))

        [double]$delta7 = [math]::Round($todayPct - $firstPct, 1)
        $arrow = if ($delta7 -gt 2) { "<span class='up-arrow'></span>" } elseif ($delta7 -lt -2) { "<span class='down-arrow'></span>" } else { "<span class='flat-line'></span>" }
        $dClass = if ($delta7 -gt 2) { 'delta-up' } elseif ($delta7 -lt -2) { 'delta-down' } else { 'delta-flat' }
        $dSignRv = if ($delta7 -gt 0) { '+' } else { '' }

        $rvStatusHtml = ''
        if ($todayPct -ge 100) { $rvStatusHtml = "<span style='color:$($colors.Green);font-weight:600;'>Complete</span>" }
        elseif ($delta7 -lt 1 -and $todayPct -lt 95) { $rvStatusHtml = "<span style='color:$($colors.Red);font-weight:600;'>STALLED</span>" }
        elseif ($delta7 -lt 5) { $rvStatusHtml = "<span style='color:$($colors.Amber);'>Slow</span>" }
        else { $rvStatusHtml = "<span style='color:$($colors.Green);'>On Track</span>" }

        $scopeSince = if ($rv.FirstSeenIdx -eq 0) { 'Day 1' } elseif ($rv.FirstSeenIdx -gt 0) { $rv.FirstSeenDate } else { 'N/A' }
        $scopeStyle = if ($rv.FirstSeenIdx -gt 0) { "color:$($colors.Amber);font-weight:600;" } else { 'color:#888;' }

        $bg = if ($delta7 -lt 1 -and $todayPct -lt 95) { " style='background:#fdecec;'" } elseif ($rvIdx % 2 -eq 1) { " style='background:#f6f9fc;'" } else { '' }
        $rvNameSafe = ConvertTo-SPHtmlSafe $rv.Name
        [void]$sb.AppendLine("<tr$bg><td style='font-weight:600;'>$rvNameSafe</td><td style='text-align:right;color:#888;'>${firstPct}%</td><td style='text-align:right;'>${yestPct}%</td><td style='text-align:right;font-weight:600;'>${todayPct}%</td><td style='text-align:center;'>$arrow</td><td style='text-align:right;' class='$dClass'>${dSignRv}${delta7}%</td><td>$rvStatusHtml</td><td style='font-size:10px;$scopeStyle'>$scopeSince</td></tr>")
        $rvIdx++
    }
    [void]$sb.AppendLine("</tbody></table></div>")
}

#endregion

#region Chart 4: Stacked Decision Distribution

if ($dayCount -ge 2) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Decision Distribution -- Day-by-Day Stacked Bars</div>")
    [void]$sb.AppendLine("<p class='note'>Green=Approved, Red=Revoked, Gray=Pending. The width of each segment shows the proportion of total items.</p>")

    [void]$sb.AppendLine("<table><thead><tr><th style='width:100px;'>Day</th><th>Decision Distribution</th><th style='width:70px;text-align:right;'>Completion</th></tr></thead><tbody>")
    foreach ($d in $dailyData) {
        $totalForPct = [math]::Max(1, [int]$d.Total)
        $aPct = [math]::Round([int]$d.Approved / $totalForPct * 100, 0)
        $rPct = [math]::Round([int]$d.Revoked / $totalForPct * 100, 0)
        $pPct = 100 - $aPct - $rPct
        if ($pPct -lt 0) { $pPct = 0 }
        [void]$sb.AppendLine("<tr><td style='font-weight:600;'>$($d.DayLabel)</td>")
        [void]$sb.AppendLine("<td><div class='stacked-bar'>")
        if ($aPct -gt 0) {
            $aLabel = if ($aPct -ge 8) { "${aPct}%" } else { '' }
            [void]$sb.AppendLine("<div class='stacked-seg' style='width:${aPct}%;background:$($colors.Green);'>$aLabel</div>")
        }
        if ($rPct -gt 0) {
            $rLabel = if ($rPct -ge 8) { "${rPct}%" } else { '' }
            [void]$sb.AppendLine("<div class='stacked-seg' style='width:${rPct}%;background:$($colors.Red);'>$rLabel</div>")
        }
        if ($pPct -gt 0) {
            $pLabel = if ($pPct -ge 8) { "${pPct}%" } else { '' }
            [void]$sb.AppendLine("<div class='stacked-seg' style='width:${pPct}%;background:#ccc;color:#555;'>$pLabel</div>")
        }
        [void]$sb.AppendLine("</div></td>")
        [void]$sb.AppendLine("<td style='text-align:right;font-weight:600;'>$($d.CompletionPct)%</td></tr>")
    }
    [void]$sb.AppendLine("</tbody></table></div>")
}

#endregion

#region Chart 5: Privileged Access Trend

[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<div class='section-title'>Privileged Access -- Pending Review Trend</div>")

$todayPrivPending = [int]$todayRec.PrivPending
$todayPrivTotal   = [int]$todayRec.PrivTotal
$todayPrivApproved = [int]$todayRec.PrivApproved
$todayPrivRevoked  = [int]$todayRec.PrivRevoked
$privReviewedPct  = if ($todayPrivTotal -gt 0) { [math]::Round(($todayPrivTotal - $todayPrivPending) / $todayPrivTotal * 100, 1) } else { 0 }
$privStatusColor  = if ($todayPrivPending -eq 0) { $colors.Green } elseif ($todayPrivPending -le 3) { $colors.Amber } else { $colors.Red }

[void]$sb.AppendLine("<p class='note'>Tracks privileged entitlements still awaiting review. These items carry higher risk and should be prioritized.</p>")

# KPI row for privileged
[void]$sb.AppendLine("<div style='margin:8px 0 16px 0;'>")
$kpiS = "display:inline-block;min-width:120px;margin:4px 8px 4px 0;padding:8px 12px;border:1px solid $($colors.Border);border-radius:6px;background:$($colors.LightGrayBg);text-align:center;"
[void]$sb.AppendLine("<span style='$kpiS'><span style='font-size:20px;font-weight:700;color:$privStatusColor;display:block;'>$todayPrivPending</span><span style='font-size:10px;color:#566;text-transform:uppercase;'>Priv Pending</span></span>")
[void]$sb.AppendLine("<span style='$kpiS'><span style='font-size:20px;font-weight:700;color:$($colors.Dark);display:block;'>$todayPrivTotal</span><span style='font-size:10px;color:#566;text-transform:uppercase;'>Priv Total</span></span>")
[void]$sb.AppendLine("<span style='$kpiS'><span style='font-size:20px;font-weight:700;color:$($colors.Green);display:block;'>$todayPrivApproved</span><span style='font-size:10px;color:#566;text-transform:uppercase;'>Priv Approved</span></span>")
[void]$sb.AppendLine("<span style='$kpiS'><span style='font-size:20px;font-weight:700;color:$($colors.Red);display:block;'>$todayPrivRevoked</span><span style='font-size:10px;color:#566;text-transform:uppercase;'>Priv Revoked</span></span>")
[void]$sb.AppendLine("<span style='$kpiS'><span style='font-size:20px;font-weight:700;color:$($colors.Dark);display:block;'>${privReviewedPct}%</span><span style='font-size:10px;color:#566;text-transform:uppercase;'>Priv Reviewed</span></span>")
[void]$sb.AppendLine("</div>")

# Bar chart of privileged pending over time
$privPendingValues = @()
foreach ($d in $dailyData) { $privPendingValues += [double]$d.PrivPending }
$privChart = Build-MetricBarChart -Title 'Privileged Items Pending Review' -Values $privPendingValues -Labels $dayLabels -Color '#7b2d8e' -HighIsGood $false
[void]$sb.AppendLine($privChart)

[void]$sb.AppendLine("</div>")

#endregion

#region Chart 6: Completion Projection vs Deadline

if ($dayCount -ge 3) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Completion Projection vs Deadline</div>")
    [void]$sb.AppendLine("<p class='note'>Solid line = actual completion %. Dashed = linear projection from last 3 days velocity. Vertical red line = deadline. Green fill if on track, red if shortfall projected.</p>")

    $jW = 700; $jH = 220; $jPadL = 50; $jPadR = 60; $jPadT = 20; $jPadB = 40
    $jPlotW = $jW - $jPadL - $jPadR; $jPlotH = $jH - $jPadT - $jPadB

    # Velocity from last 3 data points
    $vel3 = ($completionVals[$dayCount - 1] - $completionVals[[math]::Max(0, $dayCount - 3)]) / [math]::Min(2, [math]::Max(1, $dayCount - 1))
    if ($vel3 -lt 0) { $vel3 = 0 }

    $deadlineDayIdx = $effectiveDeadlineDays
    $projectionDays = if ($effectiveDeadlineDays -ge 0) { [math]::Max(3, $effectiveDeadlineDays + 2) } else { 5 }
    $totalDays = $dayCount + $projectionDays

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$jW' height='$jH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($p = 0; $p -le 100; $p += 25) {
        $yy = [int]($jPadT + $jPlotH - ($p / 100 * $jPlotH))
        [void]$sb.AppendLine("<line x1='$jPadL' y1='$yy' x2='$($jW - $jPadR)' y2='$yy' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($jPadL - 5)' y='$($yy + 4)' text-anchor='end' font-size='9' fill='#888'>${p}%</text>")
    }

    $y100 = [int]($jPadT + $jPlotH - (100 / 100 * $jPlotH))
    [void]$sb.AppendLine("<line x1='$jPadL' y1='$y100' x2='$($jW - $jPadR)' y2='$y100' stroke='$($colors.Green)' stroke-width='1' stroke-dasharray='3,3' opacity='0.5'/>")

    $actPts = @()
    for ($i = 0; $i -lt $dayCount; $i++) {
        $ax = [int]($jPadL + ($i / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        $ay = [int]($jPadT + $jPlotH - ($completionVals[$i] / 100 * $jPlotH))
        $actPts += "$ax,$ay"
    }

    $actFill = "M $jPadL $($jPadT + $jPlotH)"
    foreach ($pt in $actPts) { $actFill += " L $($pt -replace ',',' ')" }
    $lastActParts = $actPts[$actPts.Count - 1] -split ','
    $actFill += " L $($lastActParts[0]) $($jPadT + $jPlotH) Z"
    [void]$sb.AppendLine("<path d='$actFill' fill='#336699' opacity='0.1'/>")
    [void]$sb.AppendLine("<polyline points='$($actPts -join ' ')' stroke='#336699' stroke-width='2.5' fill='none'/>")

    foreach ($pt in $actPts) {
        $parts = $pt -split ','
        [void]$sb.AppendLine("<circle cx='$($parts[0])' cy='$($parts[1])' r='3' fill='#336699'/>")
    }

    $projPts = @($actPts[$actPts.Count - 1])
    $lastPct = $completionVals[$dayCount - 1]
    for ($i = 1; $i -le $projectionDays; $i++) {
        $projPct = [math]::Min(100, $lastPct + ($vel3 * $i))
        $px = [int]($jPadL + (($dayCount - 1 + $i) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        $py = [int]($jPadT + $jPlotH - ($projPct / 100 * $jPlotH))
        $projPts += "$px,$py"
    }

    $projAtDeadline = [math]::Min(100, $lastPct + ($vel3 * $deadlineDayIdx))
    $hitsTarget = $projAtDeadline -ge 99.5
    $projFillColor = if ($hitsTarget) { $colors.Green } else { $colors.Red }

    $projFill = "M $($lastActParts[0]) $($jPadT + $jPlotH)"
    foreach ($pt in $projPts) { $projFill += " L $($pt -replace ',',' ')" }
    $lastProjParts = $projPts[$projPts.Count - 1] -split ','
    $projFill += " L $($lastProjParts[0]) $($jPadT + $jPlotH) Z"
    [void]$sb.AppendLine("<path d='$projFill' fill='$projFillColor' opacity='0.08'/>")
    [void]$sb.AppendLine("<polyline points='$($projPts -join ' ')' stroke='$projFillColor' stroke-width='2' fill='none' stroke-dasharray='6,4'/>")

    $deadlineX = [int]($jPadL + (($dayCount - 1 + $deadlineDayIdx) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
    [void]$sb.AppendLine("<line x1='$deadlineX' y1='$jPadT' x2='$deadlineX' y2='$($jPadT + $jPlotH)' stroke='$($colors.Red)' stroke-width='2' stroke-dasharray='4,3'/>")
    [void]$sb.AppendLine("<text x='$($deadlineX + 4)' y='$($jPadT + 14)' font-size='9' font-weight='600' fill='$($colors.Red)'>DEADLINE</text>")

    for ($i = 0; $i -lt $dayCount; $i++) {
        $lx = [int]($jPadL + ($i / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        [void]$sb.AppendLine("<text x='$lx' y='$($jH - 8)' text-anchor='middle' font-size='8' fill='#566'>$($dailyData[$i].DayLabel)</text>")
    }
    for ($i = 1; $i -le $projectionDays; $i++) {
        $lx = [int]($jPadL + (($dayCount - 1 + $i) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        [void]$sb.AppendLine("<text x='$lx' y='$($jH - 8)' text-anchor='middle' font-size='8' fill='#aaa'>+${i}d</text>")
    }

    $projRounded = [math]::Round($projAtDeadline, 1)
    $calloutText = if ($hitsTarget) { "ON TRACK: projected $($projRounded)% at deadline" } else { "AT RISK: projected only $($projRounded)% at deadline (velocity: $([math]::Round($vel3,1))%/day)" }
    $calloutColor = if ($hitsTarget) { $colors.Green } else { $colors.Red }
    [void]$sb.AppendLine("<text x='$($jW - $jPadR)' y='$($jPadT + 14)' text-anchor='end' font-size='10' font-weight='600' fill='$calloutColor'>$calloutText</text>")

    [void]$sb.AppendLine("<line x1='$($jPadL + 5)' y1='$($jPadT + 5)' x2='$($jPadL + 25)' y2='$($jPadT + 5)' stroke='#336699' stroke-width='2.5'/>")
    [void]$sb.AppendLine("<text x='$($jPadL + 29)' y='$($jPadT + 9)' font-size='9' fill='#1c2b3a'>Actual</text>")
    [void]$sb.AppendLine("<line x1='$($jPadL + 75)' y1='$($jPadT + 5)' x2='$($jPadL + 95)' y2='$($jPadT + 5)' stroke='$projFillColor' stroke-width='2' stroke-dasharray='6,4'/>")
    [void]$sb.AppendLine("<text x='$($jPadL + 99)' y='$($jPadT + 9)' font-size='9' fill='#1c2b3a'>Projection</text>")

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}

#endregion

#region Chart 7: Reviewer Activity Heatmap

if ($dayCount -ge 2 -and $reviewerList.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Reviewer Activity Heatmap -- ${dayCount}-Day Decision Intensity</div>")
    [void]$sb.AppendLine("<p class='note'>Rows = reviewers, Columns = days. Cell color intensity = decisions made that day (daily delta). Five-level blue scale. Inactive reviewers highlighted in light red.</p>")

    $hCellW = [math]::Min(70, [int](560 / [math]::Max(1, $dayCount)))
    $hCellH = 32; $hLabelW = 120
    $hTotalW = $hLabelW + ($dayCount * $hCellW) + 10
    $hTotalH = 30 + ($reviewerList.Count * $hCellH) + 5
    $heatColors = @('#f0f2f5', '#c6dbef', '#6baed6', '#2171b5', '#084594')

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;overflow-x:auto;'>")
    [void]$sb.AppendLine("<svg width='$hTotalW' height='$hTotalH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($i = 0; $i -lt $dayCount; $i++) {
        $hx = $hLabelW + ($i * $hCellW) + ($hCellW / 2)
        [void]$sb.AppendLine("<text x='$hx' y='16' text-anchor='middle' font-size='9' font-weight='600' fill='#566'>$($dailyData[$i].DayLabel)</text>")
    }

    $hmrvIdx = 0
    foreach ($rv in $reviewerList) {
        $hy = 24 + ($hmrvIdx * $hCellH)
        $rvNameSafe = ConvertTo-SPHtmlSafe $rv.Name
        $totalActivity = 0

        $deltas = @()
        for ($i = 0; $i -lt $dayCount; $i++) {
            $rvDay = $null
            foreach ($r in $dailyData[$i].Reviewers) {
                if ($r.Name -eq $rv.Name) { $rvDay = $r; break }
            }
            $todayDec = if ($rvDay) { [int]$rvDay.Approved + [int]$rvDay.Revoked } else { 0 }
            if ($i -gt 0) {
                $rvPrev = $null
                foreach ($r in $dailyData[$i - 1].Reviewers) {
                    if ($r.Name -eq $rv.Name) { $rvPrev = $r; break }
                }
                $prevDec = if ($rvPrev) { [int]$rvPrev.Approved + [int]$rvPrev.Revoked } else { 0 }
                $hmDelta = [math]::Max(0, $todayDec - $prevDec)
            } else {
                $hmDelta = $todayDec
            }
            $deltas += $hmDelta
            $totalActivity += $hmDelta
        }

        if ($totalActivity -eq 0) {
            [void]$sb.AppendLine("<rect x='0' y='$hy' width='$hTotalW' height='$hCellH' fill='#fdecec' opacity='0.5'/>")
        }

        [void]$sb.AppendLine("<text x='$($hLabelW - 8)' y='$($hy + $hCellH / 2 + 4)' text-anchor='end' font-size='11' font-weight='600' fill='#1c2b3a'>$rvNameSafe</text>")

        $maxDelta = 1
        foreach ($dv in $deltas) { if ($dv -gt $maxDelta) { $maxDelta = $dv } }
        for ($i = 0; $i -lt $deltas.Count; $i++) {
            $hcx = $hLabelW + ($i * $hCellW)
            $val = $deltas[$i]
            $level = [math]::Min(4, [int][math]::Floor($val / $maxDelta * 4.99))
            if ($val -eq 0) { $level = 0 }
            $cellColor = $heatColors[$level]
            [void]$sb.AppendLine("<rect x='$($hcx + 2)' y='$($hy + 2)' width='$($hCellW - 4)' height='$($hCellH - 4)' rx='3' fill='$cellColor' stroke='#e3e9f0' stroke-width='1'/>")
            if ($val -gt 0) {
                $textColor = if ($level -ge 3) { '#fff' } else { '#1c2b3a' }
                [void]$sb.AppendLine("<text x='$($hcx + $hCellW / 2)' y='$($hy + $hCellH / 2 + 4)' text-anchor='middle' font-size='10' font-weight='600' fill='$textColor'>$val</text>")
            }
        }
        $hmrvIdx++
    }

    $legY = $hTotalH - 2
    [void]$sb.AppendLine("<text x='$hLabelW' y='$($legY)' font-size='9' fill='#888'>Intensity:</text>")
    for ($lv = 0; $lv -lt 5; $lv++) {
        $lx = $hLabelW + 55 + ($lv * 22)
        [void]$sb.AppendLine("<rect x='$lx' y='$($legY - 10)' width='18' height='12' rx='2' fill='$($heatColors[$lv])' stroke='#d4dce6' stroke-width='0.5'/>")
    }

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}

#endregion

#region Chart 8: Vertical Completion Progression

if ($dayCount -ge 2) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Completion Progression -- Vertical Bar Chart (Items Reviewed % + Reviewer Completion %)</div>")
    [void]$sb.AppendLine("<p class='note'>Blue bars show the percentage of items reviewed (decided). Green bars show the percentage of reviewers who have fully completed. Height is proportional to 100%.</p>")

    $chartWidth = 700
    $chartHeight = 200
    $groupWidth = [int][math]::Floor(($chartWidth - 40) / $dayCount)
    $barWidth2 = [int][math]::Floor($groupWidth * 0.35)
    $gap = [int][math]::Floor($groupWidth * 0.08)
    $leftPad = 40

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$chartWidth' height='$($chartHeight + 60)' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($pct = 0; $pct -le 100; $pct += 25) {
        $y = [int]($chartHeight - ($pct / 100 * $chartHeight) + 10)
        [void]$sb.AppendLine("<line x1='$leftPad' y1='$y' x2='$chartWidth' y2='$y' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($leftPad - 5)' y='$($y + 4)' text-anchor='end' font-size='10' fill='#888'>${pct}%</text>")
    }

    for ($i = 0; $i -lt $dayCount; $i++) {
        $d = $dailyData[$i]
        $xBase = $leftPad + ($i * $groupWidth) + $gap

        $itemsPct = [math]::Max(0, [math]::Min(100, [double]$d.CompletionPct))
        $itemsH = [int][math]::Max(2, [math]::Round($itemsPct / 100 * $chartHeight))
        $itemsY = $chartHeight - $itemsH + 10
        $itemsOpacity = [math]::Round(0.5 + (0.5 * $i / [math]::Max(1, $dayCount - 1)), 2)
        [void]$sb.AppendLine("<rect x='$xBase' y='$itemsY' width='$barWidth2' height='$itemsH' fill='#336699' opacity='$itemsOpacity' rx='2'/>")
        if ($itemsH -gt 15) {
            [void]$sb.AppendLine("<text x='$($xBase + [int]($barWidth2/2))' y='$($itemsY - 3)' text-anchor='middle' font-size='9' font-weight='600' fill='#336699'>$($itemsPct)%</text>")
        }

        # Reviewer completion % (how many reviewers hit 100%)
        $rvCompleted = 0
        foreach ($r in $d.Reviewers) { if ([double]$r.Completion -ge 100) { $rvCompleted++ } }
        $rvTotalCount = $d.Reviewers.Count
        $rvPct = if ($rvTotalCount -gt 0) { [math]::Max(0, [math]::Min(100, [math]::Round($rvCompleted / $rvTotalCount * 100, 0))) } else { 0 }
        $rvH = [int][math]::Max(2, [math]::Round($rvPct / 100 * $chartHeight))
        $rvY = $chartHeight - $rvH + 10
        $rvX = $xBase + $barWidth2 + $gap
        [void]$sb.AppendLine("<rect x='$rvX' y='$rvY' width='$barWidth2' height='$rvH' fill='$($colors.Green)' opacity='$itemsOpacity' rx='2'/>")
        if ($rvH -gt 15) {
            [void]$sb.AppendLine("<text x='$($rvX + [int]($barWidth2/2))' y='$($rvY - 3)' text-anchor='middle' font-size='9' font-weight='600' fill='$($colors.Green)'>$($rvPct)%</text>")
        }

        $labelX = $xBase + $barWidth2 + [int]($gap / 2)
        $labelY = $chartHeight + 25
        [void]$sb.AppendLine("<text x='$labelX' y='$labelY' text-anchor='middle' font-size='10' fill='#566'>$($d.DayLabel)</text>")
    }

    $legendY = $chartHeight + 45
    [void]$sb.AppendLine("<rect x='$($leftPad + 20)' y='$legendY' width='12' height='12' fill='#336699' rx='2'/>")
    [void]$sb.AppendLine("<text x='$($leftPad + 37)' y='$($legendY + 10)' font-size='11' fill='#1c2b3a'>Items Reviewed %</text>")
    [void]$sb.AppendLine("<rect x='$($leftPad + 170)' y='$legendY' width='12' height='12' fill='$($colors.Green)' rx='2'/>")
    [void]$sb.AppendLine("<text x='$($leftPad + 187)' y='$($legendY + 10)' font-size='11' fill='#1c2b3a'>Reviewers Completed %</text>")

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}

#endregion

#region Chart 9: Cross-Campaign Risk Matrix

# Build risk matrix from ALL records in dailyData (each day is one campaign)
if ($dayCount -ge 1) {
    $campaigns = @()
    foreach ($d in $dailyData) {
        # Count stalled reviewers
        $stalledCountCamp = 0
        foreach ($r in $d.Reviewers) {
            if ([double]$r.Completion -lt 5) { $stalledCountCamp++ }
        }

        # Compute deadline days
        $dlDays = 999
        if (-not [string]::IsNullOrWhiteSpace($d.CampaignDeadline)) {
            try {
                $dueDtCamp = [datetime]::Parse([string]$d.CampaignDeadline, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                $dlDays = [int][math]::Floor(($dueDtCamp - (Get-Date)).TotalDays)
                if ($dlDays -lt 0) { $dlDays = 0 }
            } catch { }
        }

        $campaigns += @{
            Name             = "$($d.CampaignName) ($($d.DayLabel))"
            Date             = $d.Date
            Completion       = [double]$d.CompletionPct
            Deadline         = $dlDays
            Pending          = [int]$d.Pending
            PrivPending      = [int]$d.PrivPending
            StalledReviewers = $stalledCountCamp
            TotalReviewers   = [int]$d.ReviewersTotal
            Approved         = [int]$d.Approved
            Revoked          = [int]$d.Revoked
            Total            = [int]$d.Total
            RiskScore        = 0
        }
    }

    # Sort by date descending
    $campaigns = @($campaigns | Sort-Object { $_.Date } -Descending)

    # Compute risk scores
    foreach ($c in $campaigns) {
        $timeRisk = if ($c.Deadline -le 2) { 40 } elseif ($c.Deadline -le 5) { 25 } else { 10 }
        $completionRisk = [math]::Max(0, [int]((100 - $c.Completion) * 0.4))
        $privRisk = [math]::Min(25, [int]($c.PrivPending * 1.5))
        $stalledRisk = $c.StalledReviewers * 8
        $c.RiskScore = [math]::Min(100, $timeRisk + $completionRisk + $privRisk + $stalledRisk)
    }

    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Cross-Campaign Risk Matrix</div>")
    [void]$sb.AppendLine("<p class='note'>Multi-campaign view with composite risk scoring. Risk = f(deadline proximity, completion gap, privileged pending, stalled reviewers). Sorted by date descending.</p>")

    [void]$sb.AppendLine("<table class='risk-matrix'><thead><tr>")
    [void]$sb.AppendLine("<th>Campaign</th><th style='text-align:center;'>Completion</th><th style='text-align:center;'>Progress</th><th style='text-align:center;'>Deadline</th><th style='text-align:center;'>Priv. Pending</th><th style='text-align:center;'>Stalled</th><th style='text-align:center;'>Risk Score</th>")
    [void]$sb.AppendLine("</tr></thead><tbody>")

    foreach ($c in $campaigns) {
        $cName = ConvertTo-SPHtmlSafe $c.Name

        # Donut SVG
        $donutR = 14; $donutCx = 20; $donutCy = 20; $donutStroke = 6
        $circumference = [math]::Round(2 * [math]::PI * $donutR, 1)
        $dashLen = [math]::Round($circumference * $c.Completion / 100, 1)
        $gapLen = [math]::Round($circumference - $dashLen, 1)
        $donutColor = if ($c.Completion -ge 80) { $colors.Green } elseif ($c.Completion -ge 50) { $colors.Amber } else { $colors.Red }
        $donutSvg = "<svg width='40' height='40' style='vertical-align:middle;'>"
        $donutSvg += "<circle cx='$donutCx' cy='$donutCy' r='$donutR' fill='none' stroke='#e3e9f0' stroke-width='$donutStroke'/>"
        $donutSvg += "<circle cx='$donutCx' cy='$donutCy' r='$donutR' fill='none' stroke='$donutColor' stroke-width='$donutStroke' stroke-dasharray='$dashLen $gapLen' stroke-dashoffset='$([math]::Round($circumference * 0.25, 1))' stroke-linecap='round'/>"
        $donutSvg += "<text x='$donutCx' y='$($donutCy + 4)' text-anchor='middle' font-size='8' font-weight='700' fill='#1c2b3a'>$([math]::Round($c.Completion,0))%</text>"
        $donutSvg += "</svg>"

        # Thermometer bar
        $thermColor = if ($c.Completion -ge 80) { $colors.Green } elseif ($c.Completion -ge 50) { $colors.Amber } else { $colors.Red }
        $thermBar = "<span class='thermometer'><span class='thermometer-fill' style='width:$($c.Completion)%;background:$thermColor;display:inline-block;'></span></span>"

        # Deadline indicator
        $dlColor = if ($c.Deadline -le 2) { $colors.Red } elseif ($c.Deadline -le 5) { $colors.Amber } else { $colors.Green }
        $dlLabel = if ($c.Deadline -ge 999) { 'N/A' } else { "$($c.Deadline)d" }
        $dlSvg = "<svg width='16' height='16' style='vertical-align:middle;'><circle cx='8' cy='8' r='6' fill='$dlColor'/></svg>"
        $dlText = "$dlSvg <span style='font-weight:600;'>$dlLabel</span>"

        # Risk bar
        $riskColor = if ($c.RiskScore -ge 60) { $colors.Red } elseif ($c.RiskScore -ge 35) { $colors.Amber } else { $colors.Green }
        $riskW = $c.RiskScore
        $riskBar = "<div style='display:inline-block;width:100px;height:14px;background:#e3e9f0;border-radius:7px;overflow:hidden;vertical-align:middle;'>"
        $riskBar += "<div style='width:${riskW}%;height:14px;background:$riskColor;border-radius:7px;display:inline-block;'></div></div>"
        $riskBar += " <span style='font-size:11px;font-weight:600;color:$riskColor;'>$($c.RiskScore)</span>"

        $privColor = if ($c.PrivPending -gt 10) { $colors.Red } elseif ($c.PrivPending -gt 5) { $colors.Amber } else { '#1c2b3a' }
        $stalledColor = if ($c.StalledReviewers -gt 0) { $colors.Red } else { $colors.Green }

        [void]$sb.AppendLine("<tr>")
        [void]$sb.AppendLine("<td style='font-weight:600;'>$cName</td>")
        [void]$sb.AppendLine("<td style='text-align:center;'>$donutSvg</td>")
        [void]$sb.AppendLine("<td style='text-align:center;'>$thermBar</td>")
        [void]$sb.AppendLine("<td style='text-align:center;'>$dlText</td>")
        [void]$sb.AppendLine("<td style='text-align:center;font-weight:600;color:$privColor;'>$($c.PrivPending)</td>")
        [void]$sb.AppendLine("<td style='text-align:center;font-weight:600;color:$stalledColor;'>$($c.StalledReviewers) / $($c.TotalReviewers)</td>")
        [void]$sb.AppendLine("<td style='text-align:center;'>$riskBar</td>")
        [void]$sb.AppendLine("</tr>")
    }

    [void]$sb.AppendLine("</tbody></table></div>")
}

#endregion

#region Chart 10: Decision Activity Trending -- Day-by-Day Table

if ($dayCount -ge 2) {
    # Check if any day has diff data worth showing
    $hasAnyDiff = $false
    foreach ($d in $dailyData) {
        if ([int]$d.Revoked -gt 0 -or [int]$d.NewlyDecided -gt 0 -or [int]$d.NewlyApproved -gt 0 -or [int]$d.ScopeAdded -gt 0) {
            $hasAnyDiff = $true; break
        }
    }

    if ($hasAnyDiff) {
        [void]$sb.AppendLine("<div class='section'>")
        [void]$sb.AppendLine("<div class='section-title'>Decision Activity Trending -- Day-by-Day Table</div>")
        [void]$sb.AppendLine("<p class='note'>Option A: Tabular view. Each row is one day's delta vs the prior campaign. Cumulative row shows the full-window aggregate. Revoked = items with REVOKE decision. Newly Decided = was PENDING in prior campaign, now APPROVED. New Scope = items not in the prior campaign, approved.</p>")

        [void]$sb.AppendLine("<table><thead><tr><th>Day</th><th>Campaign</th><th style='text-align:right;'>Revoked</th><th style='text-align:right;'>Newly Decided</th><th style='text-align:right;'>New Scope</th><th style='text-align:right;'>Scope Added</th><th style='text-align:right;'>Scope Removed</th><th style='text-align:right;'>Completion</th></tr></thead><tbody>")

        # NewlyDecided/NewScope/ScopeAdded/ScopeRemoved are per-day DELTAS -- summing
        # them across the window is correct. Revoked is a SNAPSHOT total (a running
        # cumulative within a campaign), so its window aggregate must take the LATEST
        # snapshot per distinct campaign: summing daily snapshots counted a 3-day
        # campaign's revokes ~3x (5 -> 7 -> 8 rendered CUMULATIVE Revoked = 20, not 8).
        $latestRevByCampaign = [ordered]@{}
        $cumRevoked = 0; $cumDecided = 0; $cumNewScope = 0; $cumScopeAdd = 0; $cumScopeRem = 0
        foreach ($d in $dailyData) {
            $dayRev   = [int]$d.Revoked
            $dayND    = [int]$d.NewlyDecided
            $dayNS    = [int]$d.NewlyApproved
            $daySA    = [int]$d.ScopeAdded
            $daySR    = [int]$d.ScopeRemoved
            $revCid = [string]$d.CampaignId
            if ([string]::IsNullOrWhiteSpace($revCid)) { $revCid = [string]$d.CampaignName }
            $latestRevByCampaign[$revCid] = $dayRev   # dailyData is date-ascending; last write wins
            $cumDecided  += $dayND
            $cumNewScope += $dayNS
            $cumScopeAdd += $daySA
            $cumScopeRem += $daySR

            $campShort = ConvertTo-SPHtmlSafe $d.CampaignName
            if ($campShort.Length -gt 50) { $campShort = $campShort.Substring(0, 47) + '...' }
            $revStyle = if ($dayRev -gt 0) { " style='color:$($colors.Red);font-weight:600;'" } else { '' }
            $ndStyle  = if ($dayND -gt 0) { " style='color:$($colors.Green);font-weight:600;'" } else { '' }
            $nsStyle  = if ($dayNS -gt 0) { " style='color:$($colors.Blue);font-weight:600;'" } else { '' }

            [void]$sb.AppendLine("<tr><td style='font-weight:600;'>$($d.DayLabel)</td><td style='font-size:11px;color:#566;'>$campShort</td><td style='text-align:right;'$revStyle>$dayRev</td><td style='text-align:right;'$ndStyle>$dayND</td><td style='text-align:right;'$nsStyle>$dayNS</td><td style='text-align:right;'>$daySA</td><td style='text-align:right;'>$daySR</td><td style='text-align:right;font-weight:600;'>$($d.CompletionPct)%</td></tr>")
        }

        # Cumulative row: Revoked = latest snapshot per distinct campaign (see above)
        foreach ($rv in $latestRevByCampaign.Values) { $cumRevoked += [int]$rv }
        [void]$sb.AppendLine("<tr style='background:#edf2f7;font-weight:700;border-top:2px solid $($colors.Dark);'><td colspan='2'>CUMULATIVE ($dayCount days, $($latestRevByCampaign.Count) campaign(s))</td><td style='text-align:right;color:$($colors.Red);'>$cumRevoked</td><td style='text-align:right;color:$($colors.Green);'>$cumDecided</td><td style='text-align:right;color:$($colors.Blue);'>$cumNewScope</td><td style='text-align:right;'>$cumScopeAdd</td><td style='text-align:right;'>$cumScopeRem</td><td style='text-align:right;'>$($dailyData[$dayCount - 1].CompletionPct)%</td></tr>")

        [void]$sb.AppendLine("</tbody></table></div>")
    }
}

#endregion

#region Chart 11: Decision Activity Trending -- Stacked Bar Chart

if ($dayCount -ge 2) {
    $hasAnyDiff2 = $false
    foreach ($d in $dailyData) {
        if ([int]$d.Revoked -gt 0 -or [int]$d.NewlyDecided -gt 0 -or [int]$d.NewlyApproved -gt 0) {
            $hasAnyDiff2 = $true; break
        }
    }

    if ($hasAnyDiff2) {
        [void]$sb.AppendLine("<div class='section'>")
        [void]$sb.AppendLine("<div class='section-title'>Decision Activity Trending -- Stacked Bar Chart</div>")
        [void]$sb.AppendLine("<p class='note'>Option B: Visual view. Each day shows a stacked bar of Revoked (red) + Newly Decided (green) + New Scope (blue). Bar height proportional to total activity. Running cumulative line overlaid.</p>")

        $chartW = 700; $chartH = 200; $padL = 50; $padR = 20; $padT = 20; $padB = 50
        $plotW = $chartW - $padL - $padR; $plotH = $chartH - $padT - $padB

        # Find max daily total for scaling
        $maxDayTotal = 1
        foreach ($d in $dailyData) {
            $dayTotal = [int]$d.Revoked + [int]$d.NewlyDecided + [int]$d.NewlyApproved
            if ($dayTotal -gt $maxDayTotal) { $maxDayTotal = $dayTotal }
        }

        $barW = [int][math]::Floor($plotW / $dayCount * 0.7)
        $gapW = [int][math]::Floor($plotW / $dayCount * 0.3)

        [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
        [void]$sb.AppendLine("<svg width='$chartW' height='$($chartH + 10)' style='font-family:Segoe UI,Arial,sans-serif;'>")

        # Grid lines
        for ($g = 0; $g -le 4; $g++) {
            $gVal = [math]::Round($maxDayTotal * $g / 4, 0)
            $gy = $padT + $plotH - [int]($plotH * $g / 4)
            [void]$sb.AppendLine("<line x1='$padL' y1='$gy' x2='$($chartW - $padR)' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>")
            [void]$sb.AppendLine("<text x='$($padL - 4)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>$gVal</text>")
        }

        # Cumulative line points
        $cumPts = @()
        $cumTotal = 0

        for ($i = 0; $i -lt $dayCount; $i++) {
            $d = $dailyData[$i]
            $dRev = [int]$d.Revoked
            $dND  = [int]$d.NewlyDecided
            $dNS  = [int]$d.NewlyApproved
            $dayTotal = $dRev + $dND + $dNS
            $cumTotal += $dayTotal

            $bX = $padL + $i * ($barW + $gapW) + [int]($gapW / 2)
            $baseY = $padT + $plotH

            # Stack: Revoked (bottom, red), Newly Decided (middle, green), New Scope (top, blue)
            $rH = if ($maxDayTotal -gt 0) { [int][math]::Max(0, [math]::Round($dRev / $maxDayTotal * $plotH)) } else { 0 }
            $ndH = if ($maxDayTotal -gt 0) { [int][math]::Max(0, [math]::Round($dND / $maxDayTotal * $plotH)) } else { 0 }
            $nsH = if ($maxDayTotal -gt 0) { [int][math]::Max(0, [math]::Round($dNS / $maxDayTotal * $plotH)) } else { 0 }

            $curY = $baseY
            if ($rH -gt 0) {
                $curY -= $rH
                [void]$sb.AppendLine("<rect x='$bX' y='$curY' width='$barW' height='$rH' fill='$($colors.Red)' rx='2' opacity='0.85'/>")
                if ($rH -gt 12) { [void]$sb.AppendLine("<text x='$($bX + [int]($barW/2))' y='$($curY + [int]($rH/2) + 4)' text-anchor='middle' font-size='9' font-weight='600' fill='#fff'>$dRev</text>") }
            }
            if ($ndH -gt 0) {
                $curY -= $ndH
                [void]$sb.AppendLine("<rect x='$bX' y='$curY' width='$barW' height='$ndH' fill='$($colors.Green)' rx='2' opacity='0.85'/>")
                if ($ndH -gt 12) { [void]$sb.AppendLine("<text x='$($bX + [int]($barW/2))' y='$($curY + [int]($ndH/2) + 4)' text-anchor='middle' font-size='9' font-weight='600' fill='#fff'>$dND</text>") }
            }
            if ($nsH -gt 0) {
                $curY -= $nsH
                [void]$sb.AppendLine("<rect x='$bX' y='$curY' width='$barW' height='$nsH' fill='$($colors.Blue)' rx='2' opacity='0.85'/>")
                if ($nsH -gt 12) { [void]$sb.AppendLine("<text x='$($bX + [int]($barW/2))' y='$($curY + [int]($nsH/2) + 4)' text-anchor='middle' font-size='9' font-weight='600' fill='#fff'>$dNS</text>") }
            }

            # Day total label above bar
            if ($dayTotal -gt 0) {
                $topY = $baseY - $rH - $ndH - $nsH
                [void]$sb.AppendLine("<text x='$($bX + [int]($barW/2))' y='$($topY - 3)' text-anchor='middle' font-size='9' font-weight='600' fill='#1c2b3a'>$dayTotal</text>")
            }

            # Day label
            $labelY = $padT + $plotH + 16
            [void]$sb.AppendLine("<text x='$($bX + [int]($barW/2))' y='$labelY' text-anchor='middle' font-size='9' fill='#566'>$($d.DayLabel)</text>")

            # Cumulative line point
            $cumPts += "$($bX + [int]($barW/2)),$($padT + $plotH - 3)"
        }

        # Cumulative line (scaled to a secondary axis showing running total)
        if ($cumTotal -gt 0 -and $cumPts.Count -ge 2) {
            $cumRunning = 0; $cumLinePts = @()
            for ($i = 0; $i -lt $dayCount; $i++) {
                $d = $dailyData[$i]
                $cumRunning += [int]$d.Revoked + [int]$d.NewlyDecided + [int]$d.NewlyApproved
                $cx = $padL + $i * ($barW + $gapW) + [int]($gapW / 2) + [int]($barW / 2)
                $cy = [int]($padT + $plotH - ($cumRunning / [math]::Max(1, $cumTotal) * $plotH))
                $cumLinePts += "$cx,$cy"
            }
            [void]$sb.AppendLine("<polyline points='$($cumLinePts -join ' ')' stroke='#1f3a5f' stroke-width='2' fill='none' stroke-dasharray='4,3'/>")
            foreach ($pt in $cumLinePts) {
                $parts = $pt -split ','
                [void]$sb.AppendLine("<circle cx='$($parts[0])' cy='$($parts[1])' r='3' fill='#1f3a5f'/>")
            }
            # Label last point
            $lastParts = $cumLinePts[$cumLinePts.Count - 1] -split ','
            [void]$sb.AppendLine("<text x='$([int]$lastParts[0] + 8)' y='$([int]$lastParts[1] + 4)' font-size='10' font-weight='700' fill='#1f3a5f'>$cumTotal total</text>")
        }

        # Legend
        $legY = $chartH
        [void]$sb.AppendLine("<rect x='$($padL + 5)' y='$legY' width='10' height='10' fill='$($colors.Red)' rx='1'/>")
        [void]$sb.AppendLine("<text x='$($padL + 19)' y='$($legY + 9)' font-size='10' fill='#1c2b3a'>Revoked</text>")
        [void]$sb.AppendLine("<rect x='$($padL + 85)' y='$legY' width='10' height='10' fill='$($colors.Green)' rx='1'/>")
        [void]$sb.AppendLine("<text x='$($padL + 99)' y='$($legY + 9)' font-size='10' fill='#1c2b3a'>Newly Decided</text>")
        [void]$sb.AppendLine("<rect x='$($padL + 200)' y='$legY' width='10' height='10' fill='$($colors.Blue)' rx='1'/>")
        [void]$sb.AppendLine("<text x='$($padL + 214)' y='$($legY + 9)' font-size='10' fill='#1c2b3a'>New Scope</text>")
        [void]$sb.AppendLine("<line x1='$($padL + 290)' y1='$($legY + 5)' x2='$($padL + 310)' y2='$($legY + 5)' stroke='#1f3a5f' stroke-width='2' stroke-dasharray='4,3'/>")
        [void]$sb.AppendLine("<text x='$($padL + 314)' y='$($legY + 9)' font-size='10' fill='#1c2b3a'>Cumulative</text>")

        [void]$sb.AppendLine("</svg>")
        [void]$sb.AppendLine("</div></div>")
    }
}

#endregion

#region Footer

$envName = ''
if ($null -ne $config) {
    try {
        if ($null -ne $config.PSObject.Properties['Environment'] -and
            -not [string]::IsNullOrWhiteSpace($config.Environment)) {
            $envName = [string]$config.Environment
        }
    } catch { }
}
$envFooter = if (-not [string]::IsNullOrWhiteSpace($envName)) { " | Env: $envName" } else { '' }
[void]$sb.AppendLine("<p class='footer'>Daily Evidence V6 (Metrics Visualization) | Campaign: $(ConvertTo-SPHtmlSafe $campaignNameResolved)$envFooter | Generated: $genDate | SailPoint ISC Governance Toolkit</p>")
[void]$sb.AppendLine('</body></html>')

# Write HTML file
if ($OutputMode -eq 'HTML' -or $OutputMode -eq 'Both') {
    Write-SPHtmlFile -Path $htmlFile -Content $sb.ToString()
    Write-Host "    HTML: $htmlFile" -ForegroundColor Green
    Write-Host ''
}

#endregion

#region Console Output

if ($OutputMode -eq 'Console' -or $OutputMode -eq 'Both') {
    Write-Host '  === V6 Metrics Summary ===' -ForegroundColor Cyan
    Write-Host "  Campaign:     $campaignNameResolved" -ForegroundColor White
    Write-Host "  Status:       $campaignStatusResolved" -ForegroundColor White
    Write-Host "  Completion:   $($todayRec.CompletionPct)%" -ForegroundColor White
    Write-Host "  Approved:     $($todayRec.Approved)" -ForegroundColor White
    Write-Host "  Revoked:      $($todayRec.Revoked)" -ForegroundColor White
    Write-Host "  Pending:      $($todayRec.Pending)" -ForegroundColor White
    Write-Host "  Reviewers:    $($todayRec.ReviewersTotal)" -ForegroundColor White
    if ($dayCount -ge 2) {
        $trendDirection = if ($weekDelta -gt 0) { 'UP' } elseif ($weekDelta -lt 0) { 'DOWN' } else { 'FLAT' }
        $dSignConsole = if ($weekDelta -gt 0) { '+' } else { '' }
        Write-Host "  Trend:        ${trendDirection} (${dSignConsole}${weekDelta}% over $dayCount days)" -ForegroundColor White
    }
    Write-Host "  Priv Pending: $($todayRec.PrivPending) of $($todayRec.PrivTotal)" -ForegroundColor White

    # Stalled reviewers
    $stalledNames = @()
    foreach ($rv in $reviewerList) { if ($rv.Style -eq 'stalled') { $stalledNames += $rv.Name } }
    if ($stalledNames.Count -gt 0) {
        Write-Host "  STALLED:      $($stalledNames.Count) reviewer(s): $($stalledNames -join ', ')" -ForegroundColor Red
    }
    Write-Host ''
}

#endregion

#region Audit Trail

$totalDuration = (Get-Date) - $startTime
$durationStr = "$([math]::Round($totalDuration.TotalSeconds, 1))s"

Write-Host "  Duration: $durationStr" -ForegroundColor DarkGray

try {
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV6 completed: Duration=$durationStr DataPoints=$dayCount" `
        -Severity INFO -Component 'DailyEvidenceV6' -Action 'Complete' -CorrelationID $correlationID
} catch { }

#endregion

#region Exit Code

# 0: Healthy (completion >= 80%, no stalled, on track)
# 1: Warning (completion 50-79%, some concerns)
# 5: Critical (completion < 50%, stalled, insufficient data)

$exitCode = 0

if ($insufficientData) {
    $exitCode = 5
}
elseif ([double]$todayRec.CompletionPct -lt 50) {
    $exitCode = 5
}
elseif ([double]$todayRec.CompletionPct -lt 80 -or $stalledRvCount -gt 0) {
    $exitCode = 1
}

exit $exitCode

#endregion

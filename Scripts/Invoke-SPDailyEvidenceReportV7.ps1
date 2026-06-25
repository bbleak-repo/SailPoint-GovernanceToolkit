#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the daily certification evidence report (v7) -- calendar-day-oriented
    visualization from daily-metrics.jsonl (output: daily-evidence-v7-*.html).
.DESCRIPTION
    V7 is a read-only visualization script. It reads daily-metrics.jsonl written
    by V4 and renders multi-day progression charts. V7 never calls the ISC API.

    CRITICAL DIFFERENCE from V6: V7 resolves data to ONE record per calendar day.
    For daily certification campaigns, the JSONL contains one record per campaign
    and multiple campaigns can share the same calendar date. V7 deduplicates to
    exactly one data point per date, preferring ACTIVE over COMPLETED status and
    latest captureTimestamp as tiebreaker.

    Data source: {Metrics.Path}/daily-metrics.jsonl

    Charts rendered (9 sections):
      1  KPI Banner + Executive Summary
      2  Completion Progression Line Chart (one point per calendar day)
      3  Decision Distribution Stacked Bars (Approved/Revoked/Undecided per day)
      4  Per-Reviewer Accountability Table (with direction arrows and first-seen date)
      5  Reviewer Activity Heatmap (delta-based, consecutive calendar day diffs)
      6  Completion Projection vs Deadline (velocity from last 3 calendar days)
      7  Decision Activity Trending Table (one row per day + cumulative)
      8  Decision Activity Trending Stacked Bars (with cumulative line overlay)
      9  Cross-Campaign Risk Matrix (sorted by date descending, data quality badge)

    Exit codes:
        0 = Healthy (completion >= 80%)
        1 = Warning (completion 50-79%)
        2 = Parameter error
        4 = Configuration error
        5 = Critical (completion < 50% or insufficient data)
.PARAMETER DaysBack
    Lookback window in days. Default: 7.
.PARAMETER CampaignNameContains
    Campaign name contains this substring (case-insensitive).
.PARAMETER Status
    Filter to only ACTIVE, COMPLETED, or COMPLETING campaigns.
.PARAMETER OutputPath
    Directory for output files. Defaults to daily-evidence subdirectory.
.PARAMETER OutputMode
    Console: formatted summary to terminal.
    HTML: self-contained HTML report file.
    Both (default): console output and HTML file.
.PARAMETER IncludeSuspect
    Include suspect (pre-fix inflated) JSONL records that would otherwise be excluded.
.PARAMETER Help
    Display detailed help.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV7.ps1
    # Render last 7 days from daily-metrics.jsonl.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV7.ps1 -DaysBack 14 -CampaignNameContains 'Q2'
    # 14-day trend for campaigns matching 'Q2'.
.NOTES
    Script:  Invoke-SPDailyEvidenceReportV7.ps1
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
    [switch]$IncludeSuspect,

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

#region Helper Functions

function Get-V7Prop {
    param($Object, [string]$Name, $Default = '')
    return (Get-SPObjectProperty -Object $Object -Name $Name -Default $Default)
}

function Get-V7NumericProp {
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

function Build-V7BarChart {
    param([string]$Title, [double[]]$Values, [string[]]$Labels, [string]$Color, [string]$Unit = '',
          [int]$ChartW = 600, [int]$ChartH = 160, [bool]$HighIsGood = $true, [bool[]]$SuspectFlags = $null)
    $leftPad = 45; $topPad = 10; $bottomPad = 40
    $drawH = $ChartH - $topPad - $bottomPad
    $cnt = $Values.Count
    if ($cnt -eq 0) { return '' }
    $barW = [int][math]::Floor(($ChartW - $leftPad - 10) / $cnt * 0.65)
    $gapW = [int][math]::Floor(($ChartW - $leftPad - 10) / $cnt * 0.35)
    $maxVal = [math]::Max(1, ($Values | Measure-Object -Maximum).Maximum)

    $first = $Values[0]; $last = $Values[$cnt - 1]; $delta = [math]::Round($last - $first, 1)
    $dSignLocal = if ($delta -gt 0) { '+' } else { '' }
    if ($HighIsGood) {
        $dColorLocal = if ($delta -gt 0) { '#0a7d2c' } elseif ($delta -lt 0) { '#b00020' } else { '#9a6700' }
    } else {
        $dColorLocal = if ($delta -gt 0) { '#b00020' } elseif ($delta -lt 0) { '#0a7d2c' } else { '#9a6700' }
    }

    $svgH = $ChartH + 10
    $svg = "<div style='margin:8px 0;'>"
    $svg += "<div style='font-size:13px;font-weight:600;color:#1f3a5f;margin-bottom:4px;'>$Title <span style='font-size:12px;color:$dColorLocal;margin-left:8px;'>${dSignLocal}${delta}${Unit} vs first day</span></div>"
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
        $isSuspect = $false
        if ($null -ne $SuspectFlags -and $i -lt $SuspectFlags.Count) { $isSuspect = $SuspectFlags[$i] }
        $dashAttr = ''
        if ($isSuspect) { $dashAttr = " stroke='#9a6700' stroke-width='2' stroke-dasharray='4,2'" }
        $svg += "<rect x='$bX' y='$bY' width='$barW' height='$bH' fill='$Color' opacity='$opacity' rx='2'$dashAttr/>"
        $svg += "<text x='$($bX + [int]($barW/2))' y='$($bY - 3)' text-anchor='middle' font-size='10' font-weight='600' fill='$Color'>$([math]::Round($v,0))${Unit}</text>"
        $labelY = $topPad + $drawH + 14
        $svg += "<text x='$($bX + [int]($barW/2))' y='$labelY' text-anchor='middle' font-size='9' fill='#566'>$($Labels[$i])</text>"
    }

    $svg += "</svg></div>"
    return $svg
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
Write-Host '  Daily Evidence Report (v7) -- Calendar-Day Visualization' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
$periodLabel = if (-not [string]::IsNullOrWhiteSpace($StartDate) -or -not [string]::IsNullOrWhiteSpace($EndDate)) { "$StartDate to $EndDate" } else { "Last $effectiveDaysBack day(s)" }
Write-Host "  Period:        $periodLabel" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

try {
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV7 started: CorrelationID=$correlationID DaysBack=$effectiveDaysBack" `
        -Severity INFO -Component 'DailyEvidenceV7' -Action 'Start' -CorrelationID $correlationID
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

#region Step 1: Load and filter JSONL

Write-Host '  Step 1: Load and filter JSONL' -ForegroundColor Cyan

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

# Date range: -StartDate/-EndDate take precedence over -DaysBack
$filterStartDate = ''
$filterEndDate = ''
if (-not [string]::IsNullOrWhiteSpace($StartDate)) {
    try { $filterStartDate = ([datetime]::Parse($StartDate)).ToString('yyyy-MM-dd') }
    catch { Write-Host "  ERROR: Invalid -StartDate '$StartDate'. Use yyyy-MM-dd format." -ForegroundColor Red; exit 2 }
}
if (-not [string]::IsNullOrWhiteSpace($EndDate)) {
    try { $filterEndDate = ([datetime]::Parse($EndDate)).ToString('yyyy-MM-dd') }
    catch { Write-Host "  ERROR: Invalid -EndDate '$EndDate'. Use yyyy-MM-dd format." -ForegroundColor Red; exit 2 }
}
# If no explicit range, use DaysBack from today
if ([string]::IsNullOrWhiteSpace($filterStartDate)) {
    $filterStartDate = (Get-Date).AddDays(-$effectiveDaysBack).ToString('yyyy-MM-dd')
}
if ([string]::IsNullOrWhiteSpace($filterEndDate)) {
    $filterEndDate = (Get-Date).ToString('yyyy-MM-dd')
}
Write-Host "    Date range: $filterStartDate to $filterEndDate" -ForegroundColor DarkGray

$allRecords = [System.Collections.Generic.List[object]]::new()

$rawLines = [System.IO.File]::ReadAllLines($jsonlPath, $utf8)
foreach ($ln in $rawLines) {
    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
    try {
        $rec = $ln | ConvertFrom-Json
        $capDate = [string]$rec.captureDate
        if ([string]::IsNullOrWhiteSpace($capDate)) { continue }

        # Filter by date range
        if ($capDate -lt $filterStartDate) { continue }
        if ($capDate -gt $filterEndDate) { continue }

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

#region Step 2: Calendar-day resolution

Write-Host '  Step 2: Calendar-day resolution' -ForegroundColor Cyan

# Step 2a: Detect suspect records (pre-fix inflated data)
$suspectCount = 0
foreach ($rec in $allRecords) {
    $recIsSuspect = $false
    try {
        $campStatus = [string]$rec.campaign.status
        $sm = $rec.summary
        $pendingVal = [int](Get-V7NumericProp $sm 'pending' 0)
        $compPct = [double](Get-V7NumericProp $sm 'completionPct' 0)
        if ($campStatus -eq 'COMPLETED' -and $pendingVal -eq 0 -and $compPct -ge 99.5) {
            $recIsSuspect = $true
            $suspectCount++
        }
    } catch { }
    # Tag the record
    $rec | Add-Member -NotePropertyName '_isSuspect' -NotePropertyValue $recIsSuspect -Force
}

# Step 2b: Calendar-day grouping
# Group all records by calendar date (captureDate)
# Resolution: prefer ACTIVE over COMPLETED, then latest captureTimestamp
$dateGroups = [ordered]@{}
foreach ($rec in $allRecords) {
    $calDate = [string]$rec.captureDate
    if ([string]::IsNullOrWhiteSpace($calDate)) { continue }

    # Skip suspect records unless -IncludeSuspect is set
    $isSusp = $false
    try { $isSusp = [bool]$rec._isSuspect } catch { }
    if ($isSusp -and -not $IncludeSuspect) { continue }

    if (-not $dateGroups.Contains($calDate)) {
        $dateGroups[$calDate] = [System.Collections.Generic.List[object]]::new()
    }
    $dateGroups[$calDate].Add($rec)
}

# Step 2c: Resolve one record per calendar day
$calendarDays = [ordered]@{}
$statusPriority = @{ 'ACTIVE' = 3; 'COMPLETING' = 2; 'COMPLETED' = 1 }

foreach ($dateKey in $dateGroups.Keys) {
    $recs = $dateGroups[$dateKey]
    $best = $null
    foreach ($r in $recs) {
        if ($null -eq $best) {
            $best = $r
            continue
        }
        # Compare status priority
        $bestStatus = [string]$best.campaign.status
        $rStatus = [string]$r.campaign.status
        $bestPri = 0
        $rPri = 0
        if ($statusPriority.Contains($bestStatus)) { $bestPri = $statusPriority[$bestStatus] }
        if ($statusPriority.Contains($rStatus)) { $rPri = $statusPriority[$rStatus] }

        if ($rPri -gt $bestPri) {
            $best = $r
        }
        elseif ($rPri -eq $bestPri) {
            # Same status -- prefer latest captureTimestamp
            $bestTs = [string]$best.captureTimestamp
            $rTs = [string]$r.captureTimestamp
            if ($rTs -gt $bestTs) {
                $best = $r
            }
        }
    }

    if ($null -ne $best) {
        $ts = [datetime]::Parse($dateKey)
        $sm = $best.summary

        # Map per-reviewer data
        $dayReviewers = @()
        $reviewerArray = $null
        try {
            if ($null -ne $best.PSObject.Properties['reviewers'] -and $null -ne $best.reviewers) {
                $reviewerArray = @($best.reviewers)
            }
        } catch { }

        if ($null -ne $reviewerArray) {
            foreach ($rv in $reviewerArray) {
                if ($null -eq $rv) { continue }
                $rvName = [string](Get-V7Prop $rv 'name' '')
                if ([string]::IsNullOrWhiteSpace($rvName)) { continue }
                $dayReviewers += @{
                    Name       = $rvName
                    Total      = [int](Get-V7NumericProp $rv 'total' 0)
                    Approved   = [int](Get-V7NumericProp $rv 'approved' 0)
                    Revoked    = [int](Get-V7NumericProp $rv 'revoked' 0)
                    Pending    = [int](Get-V7NumericProp $rv 'pending' 0)
                    Completion = [double](Get-V7NumericProp $rv 'completionPct' 0)
                    Signed     = $false
                    Phase      = [string](Get-V7Prop $rv 'phase' '')
                }
                try {
                    $signedVal = Get-V7Prop $rv 'signed' $false
                    if ($signedVal -eq $true -or $signedVal -eq 'True') {
                        $dayReviewers[$dayReviewers.Count - 1].Signed = $true
                    }
                } catch { }
            }
        }

        $totalItems = [int](Get-V7NumericProp $sm 'totalItems' 0)
        $approvedItems = [int](Get-V7NumericProp $sm 'approved' 0)
        $revokedItems = [int](Get-V7NumericProp $sm 'revoked' 0)
        $pendingItems = [int](Get-V7NumericProp $sm 'pending' 0)

        $isSuspectFlag = $false
        try { $isSuspectFlag = [bool]$best._isSuspect } catch { }

        $entry = @{
            Date             = $ts.ToString('yyyy-MM-dd')
            DayLabel         = $ts.ToString('MM/dd')
            Reviewers        = $dayReviewers
            Total            = $totalItems
            Approved         = $approvedItems
            Revoked          = $revokedItems
            Pending          = $pendingItems
            CompletionPct    = [double](Get-V7NumericProp $sm 'completionPct' 0)
            ReviewersTotal   = [int](Get-V7NumericProp $sm 'reviewersTotal' 0)
            ReviewersSigned  = [int](Get-V7NumericProp $sm 'reviewersSigned' 0)
            PrivTotal        = [int](Get-V7NumericProp $sm 'privilegedTotal' 0)
            PrivApproved     = [int](Get-V7NumericProp $sm 'privilegedApproved' 0)
            PrivRevoked      = [int](Get-V7NumericProp $sm 'privilegedRevoked' 0)
            PrivPending      = [int](Get-V7NumericProp $sm 'privilegedPending' 0)
            ScopeAdded       = 0
            ScopeRemoved     = 0
            NewlyApproved    = 0
            NewlyDecided     = 0
            CampaignName     = [string]$best.campaign.name
            CampaignId       = [string]$best.campaign.id
            CampaignStatus   = [string]$best.campaign.status
            CampaignDeadline = ''
            DiffData         = $null
            IsSuspect        = $isSuspectFlag
            CompletionDelta  = [double]0
            ApprovedDelta    = [int]0
            RevokedDelta     = [int]0
            PendingDelta     = [int]0
        }
        # Populate deadline
        try {
            $dlVal = [string]$best.campaign.deadline
            if (-not [string]::IsNullOrWhiteSpace($dlVal)) {
                $entry.CampaignDeadline = $dlVal
            }
        } catch { }
        # Populate diff data
        try {
            if ($null -ne $best.PSObject.Properties['diff'] -and $null -ne $best.diff) {
                $entry.DiffData = $best.diff
                $entry.ScopeAdded = [int](Get-V7NumericProp $best.diff 'scopeAdded' 0)
                $entry.ScopeRemoved = [int](Get-V7NumericProp $best.diff 'scopeRemoved' 0)
                $entry.NewlyApproved = [int](Get-V7NumericProp $best.diff 'newlyApprovedCount' 0)
                $entry.NewlyDecided = [int](Get-V7NumericProp $best.diff 'newlyDecidedCount' 0)
            }
        } catch { }

        # Carry source data for the source-level completion chart
        try {
            if ($null -ne $best.PSObject.Properties['sources'] -and $null -ne $best.sources) {
                $entry.SourceData = @($best.sources)
            }
        } catch { }

        $calendarDays[$dateKey] = $entry
    }
}

# Sort by date ascending and rebuild ordered hashtable
$sortedDateKeys = @($calendarDays.Keys | Sort-Object)
$sortedCalendarDays = [ordered]@{}
foreach ($dk in $sortedDateKeys) {
    $sortedCalendarDays[$dk] = $calendarDays[$dk]
}
$calendarDays = $sortedCalendarDays

# Step 2d: Compute deltas between consecutive calendar days
$dayKeys = @($calendarDays.Keys)
$dayCount = $dayKeys.Count
for ($i = 1; $i -lt $dayCount; $i++) {
    $curr = $calendarDays[$dayKeys[$i]]
    $prev = $calendarDays[$dayKeys[$i - 1]]
    $curr.CompletionDelta = [math]::Round([double]$curr.CompletionPct - [double]$prev.CompletionPct, 1)
    $curr.ApprovedDelta = [int]$curr.Approved - [int]$prev.Approved
    $curr.RevokedDelta = [int]$curr.Revoked - [int]$prev.Revoked
    $curr.PendingDelta = [int]$curr.Pending - [int]$prev.Pending
    # Compute real daily deltas for trending table (instead of static per-campaign JSONL values)
    $dailyDecided = ([int]$curr.Approved + [int]$curr.Revoked) - ([int]$prev.Approved + [int]$prev.Revoked)
    $curr.NewlyDecided = [math]::Max(0, $dailyDecided)
    $dailyScopeChange = [int]$curr.Total - [int]$prev.Total
    $curr.NewlyApproved = [math]::Max(0, $dailyScopeChange)
}
# Day 0 has no prior day -- zero out its delta fields (they contain raw JSONL values, not deltas)
if ($dayCount -gt 0) {
    $day0 = $calendarDays[$dayKeys[0]]
    $day0.NewlyDecided = 0
    $day0.NewlyApproved = 0
    $day0.CompletionDelta = 0
    $day0.ApprovedDelta = 0
    $day0.RevokedDelta = 0
    $day0.PendingDelta = 0
}

$suspectIncluded = 0
foreach ($dk in $dayKeys) {
    if ($calendarDays[$dk].IsSuspect) { $suspectIncluded++ }
}

Write-Host "    $($allRecords.Count) records -> $dayCount calendar day(s), $suspectCount suspect flagged" -ForegroundColor DarkGray

if ($dayCount -eq 0) {
    Write-Host '' -ForegroundColor Red
    Write-Host '  ERROR: No calendar days resolved after deduplication.' -ForegroundColor Red
    Write-Host '  All records may have been filtered as suspect. Try -IncludeSuspect.' -ForegroundColor Red
    Write-Host '' -ForegroundColor Red
    exit 5
}

# Build dailyData array from calendarDays for indexed access
$dailyData = @()
foreach ($dk in $dayKeys) {
    $dailyData += $calendarDays[$dk]
}

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
    [double]$yesterdayComp = 0; $lastSeenIdx = -1; $latestSigned = $false
    [string]$firstSeenDate = 'N/A'
    for ($di = 0; $di -lt $dailyData.Count; $di++) {
        $rvDay = $null
        foreach ($r in $dailyData[$di].Reviewers) {
            if ($r.Name -eq $rn) { $rvDay = $r; break }
        }
        if ($null -ne $rvDay) {
            $compVal = [double]$rvDay.Completion
            if ($firstComp -lt 0) {
                $firstComp = $compVal
                $firstSeenIdx = $di
                $firstSeenDate = $dailyData[$di].DayLabel
            }
            if ($di -eq ($dailyData.Count - 2)) { $yesterdayComp = $compVal }
            $lastComp = $compVal
            $lastSeenIdx = $di
            # Track signed status from latest appearance
            $isSigned = $false
            try { $isSigned = [bool]$rvDay.Signed } catch { }
            if ($isSigned) { $latestSigned = $true }
        }
    }
    if ($firstComp -lt 0) { $firstComp = 0 }
    $daysInScope = if ($firstSeenIdx -ge 0 -and $lastSeenIdx -ge 0) { $lastSeenIdx - $firstSeenIdx + 1 } else { 1 }

    [double]$delta = $lastComp - $firstComp
    $rvStyle = 'steady'
    if ($latestSigned -or $lastComp -ge 95) { $rvStyle = 'finishing' }
    elseif ($lastComp -lt 5 -and $daysInScope -ge 3) { $rvStyle = 'stalled' }
    elseif ($delta -ge 10) { $rvStyle = 'steady' }
    elseif ($delta -lt 5 -and $lastComp -lt 90) { $rvStyle = 'slow' }

    $reviewerList += @{
        Name                = $rn
        StartCompletion     = $firstComp
        YesterdayCompletion = $yesterdayComp
        LastCompletion      = $lastComp
        Style               = $rvStyle
        FirstSeenIdx        = $firstSeenIdx
        FirstSeenDate       = $firstSeenDate
    }
}

Write-Host "    Reviewers: $($reviewerList.Count)" -ForegroundColor DarkGray

# Resolve campaign metadata from latest day
$latestDay = $dailyData[$dayCount - 1]
$campaignNameResolved = $latestDay.CampaignName
$campaignIdResolved = $latestDay.CampaignId
$campaignStatusResolved = $latestDay.CampaignStatus
$campaignDeadlineResolved = $latestDay.CampaignDeadline

# Check if this spans multiple campaigns (common in daily campaigns)
$distinctCampIds = [ordered]@{}
foreach ($d in $dailyData) {
    $cid = $d.CampaignId
    if (-not [string]::IsNullOrWhiteSpace($cid) -and -not $distinctCampIds.Contains($cid)) {
        $distinctCampIds[$cid] = $d.CampaignName
    }
}
if ($distinctCampIds.Count -gt 1) {
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
    Write-Host '  NOTE: Less than 2 calendar days -- single-point report only.' -ForegroundColor Yellow
    Write-Host '        Multi-day charts require at least 2 captures on different days.' -ForegroundColor Yellow
    Write-Host ''
}

#endregion

#region Step 3: Build HTML Report

Write-Host '  Step 3: Build HTML report' -ForegroundColor Cyan

$colors = Get-SPHtmlColorPalette
$genDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')

# Build safe campaign prefix for filename
$safeCampaignPrefix = $campaignNameResolved -replace '\s*\(\d+ campaigns\)', ''
$safeCampaignPrefix = $safeCampaignPrefix.Trim()
if ($safeCampaignPrefix.Length -gt 40) { $safeCampaignPrefix = $safeCampaignPrefix.Substring(0, 40) }
$safeCampaignPrefix = $safeCampaignPrefix -replace '[^A-Za-z0-9_\-]', '_'
$safeCampaignPrefix = $safeCampaignPrefix -replace '__+', '_'
$safeCampaignPrefix = $safeCampaignPrefix.Trim('_')
if ([string]::IsNullOrWhiteSpace($safeCampaignPrefix)) { $safeCampaignPrefix = 'report' }

$htmlFile = Join-Path $effectiveOutputPath "daily-evidence-v7-${safeCampaignPrefix}-${timestamp}.html"

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
.badge-suspect{background:#9a6700;color:#fff;font-size:9px;padding:2px 6px;border-radius:8px;margin-left:4px;}
.risk-matrix td{padding:6px 8px;font-size:12px;border-bottom:1px solid #e3e9f0;vertical-align:middle;}
.risk-matrix th{padding:6px 8px;font-size:11px;}
.thermometer{display:inline-block;width:100px;height:14px;background:#e3e9f0;border-radius:7px;overflow:hidden;vertical-align:middle;}
.thermometer-fill{height:14px;border-radius:7px;}
.suspect-border{border:2px dashed #9a6700 !important;}
'@

$sb = New-Object System.Text.StringBuilder 32768
[void]$sb.AppendLine("<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Daily Evidence V7 -- Calendar-Day Visualization</title><style>$css</style></head><body>")

# Header
[void]$sb.AppendLine("<h1>Daily Certification Evidence Report (V7) -- Calendar-Day Visualization</h1>")
[void]$sb.AppendLine("<p class='meta'>")
[void]$sb.AppendLine("Campaign: <strong>$(ConvertTo-SPHtmlSafe $campaignNameResolved)</strong><br>")
[void]$sb.AppendLine("Status: $(ConvertTo-SPHtmlSafe $campaignStatusResolved)<br>")
if ($dayCount -ge 2) {
    [void]$sb.AppendLine("Period: $dayCount calendar days ($($dailyData[0].Date) to $($dailyData[$dayCount - 1].Date))<br>")
} else {
    [void]$sb.AppendLine("Period: Single day ($($dailyData[0].Date))<br>")
}
if ($suspectIncluded -gt 0) {
    [void]$sb.AppendLine("Data Quality: <span class='badge-suspect'>$suspectIncluded suspect day(s) included</span><br>")
}
[void]$sb.AppendLine("Generated: $genDate</p>")

#endregion

#region Chart 1: KPI Banner + Executive Summary

$todayRec = $dailyData[$dayCount - 1]
$firstRec = $dailyData[0]
$yesterdayRec = if ($dayCount -ge 2) { $dailyData[$dayCount - 2] } else { $todayRec }
$dayOverDayDelta = [math]::Round([double]$todayRec.CompletionPct - [double]$yesterdayRec.CompletionPct, 1)
$windowDelta = [math]::Round([double]$todayRec.CompletionPct - [double]$firstRec.CompletionPct, 1)

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
[void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$($colors.Red);'>$($todayRec.Pending)</span><span class='l'>Undecided</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($todayRec.ReviewersTotal)</span><span class='l'>Reviewers</span></span>")

$privPendingKpi = [int]$todayRec.PrivPending
$privTotalKpi = [int]$todayRec.PrivTotal
$privColor = if ($privPendingKpi -eq 0) { $colors.Green } elseif ($privPendingKpi -le 3) { $colors.Amber } else { $colors.Red }
[void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$privColor;'>$privPendingKpi / $privTotalKpi</span><span class='l'>Priv. Pending</span></span>")

if ($dayCount -ge 2) {
    $dSign = if ($windowDelta -gt 0) { '+' } else { '' }
    $dColor = if ($windowDelta -gt 5) { $colors.Green } elseif ($windowDelta -lt -2) { $colors.Red } else { $colors.Amber }
    $dLabel = "${dayCount}-Day Change"
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$dColor;'>${dSign}${windowDelta}%</span><span class='l'>$dLabel</span></span>")
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
$velocityLong = if ($dayCount -ge 2) { [math]::Round(([double]$todayRec.CompletionPct - [double]$firstRec.CompletionPct) / [math]::Max(1, $dayCount - 1), 1) } else { 0 }
$velocityShort = 0
if ($dayCount -ge 3) {
    $shortStart = $dailyData[[math]::Max(0, $dayCount - 3)]
    $velocityShort = [math]::Round(([double]$todayRec.CompletionPct - [double]$shortStart.CompletionPct) / [math]::Min(2, [math]::Max(1, $dayCount - 1)), 1)
}
else { $velocityShort = $velocityLong }
$velocityPerDay = $velocityShort  # projection uses recent velocity

if ($isOverdue) {
    $summaryText = "Campaign is $($todayRec.CompletionPct)% complete and OVERDUE by $([math]::Abs($effectiveDeadlineDays)) day(s)."
} else {
    $projectedCompletion = [math]::Min(100, [double]$todayRec.CompletionPct + ($velocityPerDay * $effectiveDeadlineDays))
    $willComplete = if ($projectedCompletion -ge 99.5) { 'will' } else { 'will NOT' }
    $summaryText = "Campaign is $($todayRec.CompletionPct)% complete with $effectiveDeadlineDays day(s) until deadline."
}
if ($stalledRvCount -gt 0) {
    $summaryText += " $stalledRvCount reviewer(s) have made zero progress (stalled)."
}
if ($privPendCount -gt 0) {
    $summaryText += " $privPendCount privileged access items remain undecided."
}
if ($dayCount -ge 2 -and -not $isOverdue) {
    $summaryText += " Avg velocity: ${velocityLong}%/day (${dayCount}-day) | Recent: ${velocityShort}%/day (3-day). Projection suggests the campaign $willComplete complete on time."
}
elseif ($dayCount -ge 2 -and $isOverdue) {
    $remaining = 100 - [double]$todayRec.CompletionPct
    $daysNeeded = if ($velocityPerDay -gt 0) { [int][math]::Ceiling($remaining / $velocityPerDay) } else { 999 }
    $summaryText += " Avg velocity: ${velocityLong}%/day (${dayCount}-day) | Recent: ${velocityShort}%/day (3-day). Estimated $daysNeeded more day(s) needed."
}
[void]$sb.AppendLine("<p style='font-size:13px;color:#1c2b3a;line-height:1.6;margin:12px 0 16px 0;padding:10px 14px;background:#f6f9fc;border-left:4px solid $dlKpiColor;border-radius:4px;'>$summaryText</p>")

# Insufficient data banner
if ($insufficientData) {
    [void]$sb.AppendLine("<div class='section' style='background:#fff7e6;border-color:#ffd97a;'>")
    [void]$sb.AppendLine("<div class='section-title' style='color:#7a5a00;'>Insufficient Trend Data</div>")
    [void]$sb.AppendLine("<p style='color:#7a5a00;font-size:13px;'>Only $dayCount calendar day(s) available. Multi-day progression charts require at least 2 captures on different days. Below shows today's snapshot data only. Run V4 daily to accumulate the series.</p>")
    [void]$sb.AppendLine("</div>")
}

#endregion

#region Chart 2: Completion Progression Line Chart

if ($dayCount -ge 2) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Completion Progression -- Day-by-Day Line Chart</div>")
    [void]$sb.AppendLine("<p class='note'>One point per calendar day. Solid line = actual completion %. Suspect data points shown with dashed circle.</p>")

    $cW = 700; $cH = 220; $cPadL = 50; $cPadR = 20; $cPadT = 20; $cPadB = 40
    $cPlotW = $cW - $cPadL - $cPadR; $cPlotH = $cH - $cPadT - $cPadB

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$cW' height='$cH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    # Grid lines
    for ($p = 0; $p -le 100; $p += 25) {
        $yy = [int]($cPadT + $cPlotH - ($p / 100 * $cPlotH))
        [void]$sb.AppendLine("<line x1='$cPadL' y1='$yy' x2='$($cW - $cPadR)' y2='$yy' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($cPadL - 5)' y='$($yy + 4)' text-anchor='end' font-size='9' fill='#888'>${p}%</text>")
    }

    # 100% target line
    $y100 = [int]($cPadT + $cPlotH - (100 / 100 * $cPlotH))
    [void]$sb.AppendLine("<line x1='$cPadL' y1='$y100' x2='$($cW - $cPadR)' y2='$y100' stroke='$($colors.Green)' stroke-width='1' stroke-dasharray='3,3' opacity='0.4'/>")

    # Build polyline points and area fill
    $linePts = @()
    for ($i = 0; $i -lt $dayCount; $i++) {
        $px = [int]($cPadL + ($i / [math]::Max(1, $dayCount - 1)) * $cPlotW)
        $py = [int]($cPadT + $cPlotH - ([double]$dailyData[$i].CompletionPct / 100 * $cPlotH))
        $linePts += "$px,$py"
    }

    # Area fill under the line
    $areaPath = "M $cPadL $($cPadT + $cPlotH)"
    foreach ($pt in $linePts) { $areaPath += " L $($pt -replace ',',' ')" }
    $lastParts = $linePts[$linePts.Count - 1] -split ','
    $areaPath += " L $($lastParts[0]) $($cPadT + $cPlotH) Z"
    [void]$sb.AppendLine("<path d='$areaPath' fill='#336699' opacity='0.08'/>")

    # Polyline
    [void]$sb.AppendLine("<polyline points='$($linePts -join ' ')' stroke='#336699' stroke-width='2.5' fill='none'/>")

    # Data points
    for ($i = 0; $i -lt $dayCount; $i++) {
        $parts = $linePts[$i] -split ','
        $cx = $parts[0]; $cy = $parts[1]
        $isSusp = $dailyData[$i].IsSuspect
        if ($isSusp) {
            [void]$sb.AppendLine("<circle cx='$cx' cy='$cy' r='5' fill='none' stroke='#9a6700' stroke-width='2' stroke-dasharray='3,2'/>")
            [void]$sb.AppendLine("<circle cx='$cx' cy='$cy' r='2' fill='#9a6700'/>")
        } else {
            [void]$sb.AppendLine("<circle cx='$cx' cy='$cy' r='3.5' fill='#336699'/>")
        }

        # Value label
        [void]$sb.AppendLine("<text x='$cx' y='$([int]$cy - 8)' text-anchor='middle' font-size='9' font-weight='600' fill='#336699'>$([math]::Round([double]$dailyData[$i].CompletionPct, 1))%</text>")
    }

    # X-axis labels
    for ($i = 0; $i -lt $dayCount; $i++) {
        $lx = [int]($cPadL + ($i / [math]::Max(1, $dayCount - 1)) * $cPlotW)
        [void]$sb.AppendLine("<text x='$lx' y='$($cH - 8)' text-anchor='middle' font-size='9' fill='#566'>$($dailyData[$i].DayLabel)</text>")
    }

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}

#endregion

#region Chart 3: Decision Distribution Stacked Bars

if ($dayCount -ge 2) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Decision Distribution -- Day-by-Day Stacked Bars</div>")
    [void]$sb.AppendLine("<p class='note'>Green=Approved, Red=Revoked, Gray=Undecided. Each bar represents one calendar day. Width of each segment shows proportion of total items.</p>")

    [void]$sb.AppendLine("<table><thead><tr><th style='width:80px;'>Day</th><th>Decision Distribution</th><th style='width:70px;text-align:right;'>Completion</th></tr></thead><tbody>")
    foreach ($d in $dailyData) {
        $totalForPct = [math]::Max(1, [int]$d.Total)
        $aPct = [math]::Round([int]$d.Approved / $totalForPct * 100, 0)
        $rPct = [math]::Round([int]$d.Revoked / $totalForPct * 100, 0)
        $pPct = 100 - $aPct - $rPct
        if ($pPct -lt 0) { $pPct = 0 }

        $rowStyle = ''
        if ($d.IsSuspect) { $rowStyle = " class='suspect-border'" }

        [void]$sb.AppendLine("<tr$rowStyle><td style='font-weight:600;'>$($d.DayLabel)</td>")
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
        $suspBadge = ''
        if ($d.IsSuspect) { $suspBadge = " <span class='badge-suspect'>suspect</span>" }
        [void]$sb.AppendLine("<td style='text-align:right;font-weight:600;'>$($d.CompletionPct)%$suspBadge</td></tr>")
    }
    [void]$sb.AppendLine("</tbody></table></div>")
}

#endregion

#region Chart 4: Per-Reviewer Accountability Table

if ($reviewerList.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Per-Reviewer Accountability -- Numeric Comparison with Direction</div>")
    [void]$sb.AppendLine("<p class='note'>Shows each reviewer's completion across the calendar-day window with direction arrows. First-seen date is the calendar day the reviewer first appeared. Stalled reviewers (zero change) highlighted in red.</p>")

    [void]$sb.AppendLine("<table><thead><tr><th>Reviewer</th><th style='text-align:right;'>First</th><th style='text-align:right;'>Yesterday</th><th style='text-align:right;'>Today</th><th style='text-align:center;'>Direction</th><th style='text-align:right;'>Change</th><th>Status</th><th style='font-size:10px;'>First Seen</th></tr></thead><tbody>")
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

        [double]$todayPct = if ($null -ne $todayRvData) { [double]$todayRvData.Completion } else { 0 }
        [double]$yestPct  = if ($null -ne $yestRvData) { [double]$yestRvData.Completion } else { 0 }
        [double]$firstPct = if ($null -ne $firstRvData) { [double]$firstRvData.Completion } else { 0 }
        $todayPct = [math]::Max(0, [math]::Min(100, $todayPct))
        $yestPct  = [math]::Max(0, [math]::Min(100, $yestPct))
        $firstPct = [math]::Max(0, [math]::Min(100, $firstPct))

        [double]$deltaRv = [math]::Round($todayPct - $firstPct, 1)
        $arrow = if ($deltaRv -gt 2) { "<span class='up-arrow'></span>" } elseif ($deltaRv -lt -2) { "<span class='down-arrow'></span>" } else { "<span class='flat-line'></span>" }
        $dClass = if ($deltaRv -gt 2) { 'delta-up' } elseif ($deltaRv -lt -2) { 'delta-down' } else { 'delta-flat' }
        $dSignRv = if ($deltaRv -gt 0) { '+' } else { '' }

        $rvStatusHtml = ''
        if ($todayPct -ge 100) { $rvStatusHtml = "<span style='color:$($colors.Green);font-weight:600;'>Complete</span>" }
        elseif ($deltaRv -lt 1 -and $todayPct -lt 95) { $rvStatusHtml = "<span style='color:$($colors.Red);font-weight:600;'>STALLED</span>" }
        elseif ($deltaRv -lt 5) { $rvStatusHtml = "<span style='color:$($colors.Amber);'>Slow</span>" }
        else { $rvStatusHtml = "<span style='color:$($colors.Green);'>On Track</span>" }

        $firstSeenLabel = $rv.FirstSeenDate
        $scopeStyle = if ($rv.FirstSeenIdx -gt 0) { "color:$($colors.Amber);font-weight:600;" } else { 'color:#888;' }

        $bg = if ($deltaRv -lt 1 -and $todayPct -lt 95) { " style='background:#fdecec;'" } elseif ($rvIdx % 2 -eq 1) { " style='background:#f6f9fc;'" } else { '' }
        $rvNameSafe = ConvertTo-SPHtmlSafe $rv.Name
        [void]$sb.AppendLine("<tr$bg><td style='font-weight:600;'>$rvNameSafe</td><td style='text-align:right;color:#888;'>${firstPct}%</td><td style='text-align:right;'>${yestPct}%</td><td style='text-align:right;font-weight:600;'>${todayPct}%</td><td style='text-align:center;'>$arrow</td><td style='text-align:right;' class='$dClass'>${dSignRv}${deltaRv}%</td><td>$rvStatusHtml</td><td style='font-size:10px;$scopeStyle'>$firstSeenLabel</td></tr>")
        $rvIdx++
    }
    [void]$sb.AppendLine("</tbody></table></div>")
}

#endregion

#region Chart 5: Reviewer Activity Heatmap

if ($dayCount -ge 2 -and $reviewerList.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Reviewer Activity Heatmap -- ${dayCount}-Day Decision Intensity</div>")
    [void]$sb.AppendLine("<p class='note'>Rows = reviewers, Columns = calendar days. Cell value = decisions made on that day's campaign. Five-level blue scale. Inactive reviewers (zero decisions) highlighted in light red.</p>")

    $hCellW = [math]::Min(70, [int](560 / [math]::Max(1, $dayCount)))
    $hCellH = 32; $hLabelW = 120
    $hTotalW = $hLabelW + ($dayCount * $hCellW) + 10
    $hTotalH = 30 + ($reviewerList.Count * $hCellH) + 5
    $heatColors = @('#f0f2f5', '#c6dbef', '#6baed6', '#2171b5', '#084594')

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;overflow-x:auto;'>")
    [void]$sb.AppendLine("<svg width='$hTotalW' height='$hTotalH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    # Column headers (day labels)
    for ($i = 0; $i -lt $dayCount; $i++) {
        $hx = $hLabelW + ($i * $hCellW) + ($hCellW / 2)
        [void]$sb.AppendLine("<text x='$hx' y='16' text-anchor='middle' font-size='9' font-weight='600' fill='#566'>$($dailyData[$i].DayLabel)</text>")
    }

    $hmrvIdx = 0
    foreach ($rv in $reviewerList) {
        $hy = 24 + ($hmrvIdx * $hCellH)
        $rvNameSafe = ConvertTo-SPHtmlSafe $rv.Name
        $totalActivity = 0

        # For daily campaigns: show ABSOLUTE decisions per day (each day is a fresh campaign).
        # The reviewer's decided count on that day's campaign IS their daily work output.
        $deltas = @()
        for ($i = 0; $i -lt $dayCount; $i++) {
            $rvDay = $null
            foreach ($r in $dailyData[$i].Reviewers) {
                if ($r.Name -eq $rv.Name) { $rvDay = $r; break }
            }
            $dayDecided = if ($null -ne $rvDay) { [int]$rvDay.Approved + [int]$rvDay.Revoked } else { 0 }
            $deltas += $dayDecided
            $totalActivity += $dayDecided
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

    # Legend
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

#region Chart 6: Completion Projection vs Deadline

if ($dayCount -ge 3) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Completion Projection vs Deadline</div>")
    [void]$sb.AppendLine("<p class='note'>Solid line = actual completion %. Dashed = linear projection from last 3 calendar days velocity. Vertical red line = deadline. Green fill if on track, red if shortfall projected.</p>")

    $jW = 700; $jH = 220; $jPadL = 50; $jPadR = 60; $jPadT = 20; $jPadB = 40
    $jPlotW = $jW - $jPadL - $jPadR; $jPlotH = $jH - $jPadT - $jPadB

    $completionVals = @()
    foreach ($d in $dailyData) { $completionVals += [double]$d.CompletionPct }

    # Velocity from last 3 calendar days
    $vel3StartIdx = [math]::Max(0, $dayCount - 3)
    $vel3 = ($completionVals[$dayCount - 1] - $completionVals[$vel3StartIdx]) / [math]::Max(1, ($dayCount - 1) - $vel3StartIdx)
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

    # X-axis labels for actual days
    for ($i = 0; $i -lt $dayCount; $i++) {
        $lx = [int]($jPadL + ($i / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        [void]$sb.AppendLine("<text x='$lx' y='$($jH - 8)' text-anchor='middle' font-size='8' fill='#566'>$($dailyData[$i].DayLabel)</text>")
    }
    for ($i = 1; $i -le $projectionDays; $i++) {
        $lx = [int]($jPadL + (($dayCount - 1 + $i) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        [void]$sb.AppendLine("<text x='$lx' y='$($jH - 8)' text-anchor='middle' font-size='8' fill='#aaa'>+${i}d</text>")
    }

    $projRounded = [math]::Round($projAtDeadline, 1)
    $calloutText = if ($hitsTarget) { "ON TRACK: projected $($projRounded)% at deadline" } else { "AT RISK: projected only $($projRounded)% at deadline (3-day velocity: $([math]::Round($vel3,1))%/day)" }
    $calloutColor = if ($hitsTarget) { $colors.Green } else { $colors.Red }
    [void]$sb.AppendLine("<text x='$($jW - $jPadR)' y='$($jPadT + 14)' text-anchor='end' font-size='10' font-weight='600' fill='$calloutColor'>$calloutText</text>")

    # Legend
    [void]$sb.AppendLine("<line x1='$($jPadL + 5)' y1='$($jPadT + 5)' x2='$($jPadL + 25)' y2='$($jPadT + 5)' stroke='#336699' stroke-width='2.5'/>")
    [void]$sb.AppendLine("<text x='$($jPadL + 29)' y='$($jPadT + 9)' font-size='9' fill='#1c2b3a'>Actual</text>")
    [void]$sb.AppendLine("<line x1='$($jPadL + 75)' y1='$($jPadT + 5)' x2='$($jPadL + 95)' y2='$($jPadT + 5)' stroke='$projFillColor' stroke-width='2' stroke-dasharray='6,4'/>")
    [void]$sb.AppendLine("<text x='$($jPadL + 99)' y='$($jPadT + 9)' font-size='9' fill='#1c2b3a'>Projection</text>")

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}

#endregion

#region Chart 7: Decision Activity Trending -- Table

if ($dayCount -ge 2) {
    $hasAnyDiff = $false
    foreach ($d in $dailyData) {
        if ([int]$d.Revoked -gt 0 -or [int]$d.NewlyDecided -gt 0 -or [int]$d.NewlyApproved -gt 0 -or [int]$d.ScopeAdded -gt 0) {
            $hasAnyDiff = $true; break
        }
    }

    if ($hasAnyDiff) {
        [void]$sb.AppendLine("<div class='section'>")
        [void]$sb.AppendLine("<div class='section-title'>Campaign Completion Evidence -- Day-by-Day</div>")
        [void]$sb.AppendLine("<p class='note'>One row per calendar day combining campaign status, item counts, reviewer progress, and day-over-day deltas. Color-coded by completion threshold.</p>")

        [void]$sb.AppendLine("<table><thead><tr>")
        [void]$sb.AppendLine("<th>Day</th><th>Campaign</th><th>Status</th>")
        [void]$sb.AppendLine("<th style='text-align:right;'>Total</th><th style='text-align:right;'>Approved</th><th style='text-align:right;'>Revoked</th><th style='text-align:right;'>Undecided</th>")
        [void]$sb.AppendLine("<th style='text-align:center;'>Items %</th><th style='text-align:center;'>Reviewer %</th>")
        [void]$sb.AppendLine("<th style='text-align:right;'>Decided +/-</th><th style='text-align:right;'>Completion +/-</th>")
        [void]$sb.AppendLine("</tr></thead><tbody>")

        $cumAppr = 0; $cumRev = 0; $cumPend = 0; $cumTotal = 0
        foreach ($d in $dailyData) {
            $dAppr = [int]$d.Approved
            $dRev  = [int]$d.Revoked
            $dPend = [int]$d.Pending
            $dTotal = [int]$d.Total
            $dComp = [double]$d.CompletionPct
            $cumAppr += $dAppr; $cumRev += $dRev; $cumPend += $dPend; $cumTotal += $dTotal

            $campFull = ConvertTo-SPHtmlSafe $d.CampaignName
            $statusLabel = [string]$d.CampaignStatus
            $stColor = if ($statusLabel -eq 'COMPLETED') { "color:$($colors.Green);font-weight:600;" } else { "color:$($colors.Blue);" }

            # Items decided %
            $itemPct = [math]::Round($dComp, 0)
            $itemCls = if ($itemPct -ge 80) { "color:$($colors.Green);font-weight:600;" } elseif ($itemPct -ge 50) { "color:$($colors.Amber);font-weight:600;" } else { "color:$($colors.Red);font-weight:600;" }

            # Reviewer signed %
            $rvTotal = [int]$d.ReviewersTotal
            $rvSigned = [int]$d.ReviewersSigned
            $rvPct = if ($rvTotal -gt 0) { [math]::Round($rvSigned / $rvTotal * 100, 0) } else { 0 }
            $rvLabel = "$rvPct% ($rvSigned/$rvTotal)"
            $rvCls = if ($rvPct -ge 80) { "color:$($colors.Green);font-weight:600;" } elseif ($rvPct -ge 50) { "color:$($colors.Amber);" } else { "color:$($colors.Red);font-weight:600;" }

            # Day-over-day deltas
            $decidedDelta = [int]$d.NewlyDecided
            $compDelta = [double]$d.CompletionDelta
            $ddSign = if ($decidedDelta -gt 0) { '+' } else { '' }
            $cdSign = if ($compDelta -gt 0) { '+' } else { '' }
            $ddStyle = if ($decidedDelta -gt 0) { "color:$($colors.Green);font-weight:600;" } elseif ($decidedDelta -lt 0) { "color:$($colors.Red);" } else { 'color:#888;' }
            $cdStyle = if ($compDelta -gt 0) { "color:$($colors.Green);font-weight:600;" } elseif ($compDelta -lt 0) { "color:$($colors.Red);" } else { 'color:#888;' }

            $pendStyle = if ($dPend -gt 0) { "color:$($colors.Red);font-weight:600;" } else { '' }
            $suspTag = if ($d.IsSuspect) { " <span class='badge-suspect'>S</span>" } else { '' }

            [void]$sb.AppendLine("<tr>")
            [void]$sb.AppendLine("<td style='font-weight:600;white-space:nowrap;'>$($d.DayLabel)$suspTag</td>")
            [void]$sb.AppendLine("<td style='font-size:11px;'>$campFull</td>")
            [void]$sb.AppendLine("<td style='$stColor'>$statusLabel</td>")
            [void]$sb.AppendLine("<td style='text-align:right;'>$('{0:N0}' -f $dTotal)</td>")
            [void]$sb.AppendLine("<td style='text-align:right;'>$('{0:N0}' -f $dAppr)</td>")
            [void]$sb.AppendLine("<td style='text-align:right;color:$($colors.Red);'>$('{0:N0}' -f $dRev)</td>")
            [void]$sb.AppendLine("<td style='text-align:right;$pendStyle'>$('{0:N0}' -f $dPend)</td>")
            [void]$sb.AppendLine("<td style='text-align:center;$itemCls'>${itemPct}%</td>")
            [void]$sb.AppendLine("<td style='text-align:center;$rvCls'>$rvLabel</td>")
            [void]$sb.AppendLine("<td style='text-align:right;$ddStyle'>${ddSign}${decidedDelta}</td>")
            [void]$sb.AppendLine("<td style='text-align:right;$cdStyle'>${cdSign}${compDelta}%</td>")
            [void]$sb.AppendLine("</tr>")
        }

        # Totals row
        $cumDecPct = if ($cumTotal -gt 0) { [math]::Round(($cumAppr + $cumRev) / $cumTotal * 100, 0) } else { 0 }
        [void]$sb.AppendLine("<tr style='background:#edf2f7;font-weight:700;border-top:2px solid $($colors.Dark);'>")
        [void]$sb.AppendLine("<td colspan='3'>TOTALS ($dayCount days)</td>")
        [void]$sb.AppendLine("<td style='text-align:right;'>$('{0:N0}' -f $cumTotal)</td>")
        [void]$sb.AppendLine("<td style='text-align:right;'>$('{0:N0}' -f $cumAppr)</td>")
        [void]$sb.AppendLine("<td style='text-align:right;color:$($colors.Red);'>$('{0:N0}' -f $cumRev)</td>")
        [void]$sb.AppendLine("<td style='text-align:right;color:$($colors.Red);'>$('{0:N0}' -f $cumPend)</td>")
        [void]$sb.AppendLine("<td style='text-align:center;'>${cumDecPct}%</td>")
        [void]$sb.AppendLine("<td colspan='3'></td>")
        [void]$sb.AppendLine("</tr>")

        [void]$sb.AppendLine("</tbody></table></div>")
    }
}

#endregion

#region Chart 8: Decision Activity Trending -- Stacked Bar Chart

if ($dayCount -ge 2) {
    $hasAnyDiff2 = $false
    foreach ($d in $dailyData) {
        if ([int]$d.Revoked -gt 0 -or [int]$d.NewlyDecided -gt 0 -or [int]$d.NewlyApproved -gt 0) {
            $hasAnyDiff2 = $true; break
        }
    }

    if ($hasAnyDiff2) {
        [void]$sb.AppendLine("<div class='section'>")
        [void]$sb.AppendLine("<div class='section-title'>Decision Activity Trending -- Stacked Bar Chart with Cumulative Line</div>")
        [void]$sb.AppendLine("<p class='note'>Each calendar day shows stacked: Revoked (red) + Newly Decided (green) + New Scope (blue). Dashed line = running cumulative total.</p>")

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

        # Cumulative tracking
        $cumTotal = 0
        $cumLinePts = @()

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
            $cumLinePts += "$($bX + [int]($barW/2)),$($padT + $plotH - 3)"
        }

        # Cumulative line (scaled to secondary axis)
        if ($cumTotal -gt 0 -and $cumLinePts.Count -ge 2) {
            $cumRunning = 0; $scaledPts = @()
            for ($i = 0; $i -lt $dayCount; $i++) {
                $d = $dailyData[$i]
                $cumRunning += [int]$d.Revoked + [int]$d.NewlyDecided + [int]$d.NewlyApproved
                $cx = $padL + $i * ($barW + $gapW) + [int]($gapW / 2) + [int]($barW / 2)
                $cy = [int]($padT + $plotH - ($cumRunning / [math]::Max(1, $cumTotal) * $plotH))
                $scaledPts += "$cx,$cy"
            }

            [void]$sb.AppendLine("<polyline points='$($scaledPts -join ' ')' stroke='#1f3a5f' stroke-width='2' fill='none' stroke-dasharray='4,3'/>")
            foreach ($pt in $scaledPts) {
                $parts = $pt -split ','
                [void]$sb.AppendLine("<circle cx='$($parts[0])' cy='$($parts[1])' r='3' fill='#1f3a5f'/>")
            }
            # Label last point
            $lastParts = $scaledPts[$scaledPts.Count - 1] -split ','
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

#region Chart 9: Cross-Campaign Risk Matrix

# Only render the risk matrix if campaigns are genuinely different (mixed types/scopes).
# For daily recurring campaigns with the same scope and reviewers, the matrix produces
# identical scores and adds no value -- the Campaign Completion Evidence table is better.
$uniqueTotals = @{}; $uniqueReviewerCounts = @{}
foreach ($d in $dailyData) {
    $uniqueTotals[[string]$d.Total] = $true
    $uniqueReviewerCounts[[string]$d.ReviewersTotal] = $true
}
$isMixedCampaigns = ($uniqueTotals.Count -gt 1 -or $uniqueReviewerCounts.Count -gt 1)

if ($dayCount -ge 1 -and $isMixedCampaigns) {
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
            Name             = $d.CampaignName
            ShortName        = ''
            Date             = $d.Date
            DayLabel         = $d.DayLabel
            Completion       = [double]$d.CompletionPct
            Deadline         = $dlDays
            Pending          = [int]$d.Pending
            PrivPending      = [int]$d.PrivPending
            StalledReviewers = $stalledCountCamp
            TotalReviewers   = [int]$d.ReviewersTotal
            Approved         = [int]$d.Approved
            Revoked          = [int]$d.Revoked
            Total            = [int]$d.Total
            IsSuspect        = [bool]$d.IsSuspect
            RiskScore        = 0
        }
        # Short name for display
        $sn = $d.CampaignName
        if ($sn.Length -gt 40) { $sn = $sn.Substring(0, 37) + '...' }
        $campaigns[$campaigns.Count - 1].ShortName = $sn
    }

    # Sort by date descending (newest first)
    $campaigns = @($campaigns | Sort-Object { $_.Date } -Descending)

    # Compute risk scores
    foreach ($c in $campaigns) {
        $timeRisk = if ($c.Deadline -le 2) { 40 } elseif ($c.Deadline -le 5) { 25 } else { 10 }
        $completionRisk = [math]::Max(0, [int]((100 - $c.Completion) * 0.4))
        $privRisk = [math]::Min(25, [int]($c.PrivPending * 1.5))
        $stalledRisk = [math]::Min(30, [int]($c.StalledReviewers / [math]::Max(1, $c.TotalReviewers) * 40))
        $c.RiskScore = [math]::Min(100, $timeRisk + $completionRisk + $privRisk + $stalledRisk)
    }

    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Cross-Campaign Risk Matrix</div>")
    [void]$sb.AppendLine("<p class='note'>One row per calendar day, sorted by date descending. Risk = f(deadline proximity, completion gap, privileged pending, stalled reviewers). Suspect data marked with amber badge.</p>")

    [void]$sb.AppendLine("<table class='risk-matrix'><thead><tr>")
    [void]$sb.AppendLine("<th>Date</th><th>Campaign</th><th style='text-align:center;'>Completion</th><th style='text-align:center;'>Progress</th><th style='text-align:center;'>Deadline</th><th style='text-align:center;'>Priv. Pending</th><th style='text-align:center;'>Stalled</th><th style='text-align:center;'>Risk Score</th>")
    [void]$sb.AppendLine("</tr></thead><tbody>")

    foreach ($c in $campaigns) {
        $cName = ConvertTo-SPHtmlSafe $c.Name

        # Data quality badge
        $qualBadge = ''
        if ($c.IsSuspect) { $qualBadge = " <span class='badge-suspect'>suspect</span>" }

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

        $rowStyle = ''
        if ($c.IsSuspect) { $rowStyle = " style='border-left:3px dashed #9a6700;'" }

        [void]$sb.AppendLine("<tr$rowStyle>")
        [void]$sb.AppendLine("<td style='font-weight:600;white-space:nowrap;'>$($c.DayLabel)</td>")
        [void]$sb.AppendLine("<td style='font-size:11px;'>$cName$qualBadge</td>")
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

#region Chart 10: Reviewer Completion Progression (day-by-day bars)

if ($dayCount -ge 2) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Reviewer Completion Progression -- Day-by-Day</div>")
    [void]$sb.AppendLine("<p class='note'>Blue bars = % of items decided per day. Green bars = % of reviewers who signed off. Shows the gap between item completion and reviewer sign-off over time.</p>")

    $rcW = 700; $rcH = 220; $rcPadL = 50; $rcPadB = 45; $rcPadT = 15
    $rcPlotH = $rcH - $rcPadT - $rcPadB
    $rcGroupW = [int][math]::Floor(($rcW - $rcPadL - 10) / $dayCount)
    $rcBarW = [int][math]::Floor($rcGroupW * 0.38)
    $rcGap = [int][math]::Floor($rcGroupW * 0.08)

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$rcW' height='$($rcH + 10)' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($g = 0; $g -le 4; $g++) {
        $gVal = $g * 25
        $gy = $rcPadT + $rcPlotH - [int]($rcPlotH * $g / 4)
        [void]$sb.AppendLine("<line x1='$rcPadL' y1='$gy' x2='$rcW' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($rcPadL - 4)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>${gVal}%</text>")
    }

    for ($i = 0; $i -lt $dayCount; $i++) {
        $d = $dailyData[$i]
        $xBase = $rcPadL + ($i * $rcGroupW) + $rcGap
        $opacity = [math]::Round(0.4 + (0.6 * $i / [math]::Max(1, $dayCount - 1)), 2)

        # Items decided %
        $itemPct = [math]::Max(0, [math]::Min(100, [double]$d.CompletionPct))
        $itemH = [int][math]::Max(2, [math]::Round($itemPct / 100 * $rcPlotH))
        $itemY = $rcPadT + $rcPlotH - $itemH
        [void]$sb.AppendLine("<rect x='$xBase' y='$itemY' width='$rcBarW' height='$itemH' fill='#336699' opacity='$opacity' rx='2'/>")
        if ($itemH -gt 14) { [void]$sb.AppendLine("<text x='$($xBase + [int]($rcBarW/2))' y='$($itemY - 3)' text-anchor='middle' font-size='9' font-weight='600' fill='#336699'>$([math]::Round($itemPct,0))%</text>") }

        # Reviewer signed %
        $rvTotal = [int]$d.ReviewersTotal
        $rvSigned = [int]$d.ReviewersSigned
        $rvPct = if ($rvTotal -gt 0) { [math]::Round($rvSigned / $rvTotal * 100, 0) } else { 0 }
        $rvH = [int][math]::Max(2, [math]::Round($rvPct / 100 * $rcPlotH))
        $rvY = $rcPadT + $rcPlotH - $rvH
        $rvX = $xBase + $rcBarW + $rcGap
        [void]$sb.AppendLine("<rect x='$rvX' y='$rvY' width='$rcBarW' height='$rvH' fill='$($colors.Green)' opacity='$opacity' rx='2'/>")
        if ($rvH -gt 14) { [void]$sb.AppendLine("<text x='$($rvX + [int]($rcBarW/2))' y='$($rvY - 3)' text-anchor='middle' font-size='9' font-weight='600' fill='$($colors.Green)'>$rvPct%</text>") }

        # Day label
        [void]$sb.AppendLine("<text x='$($xBase + $rcBarW + [int]($rcGap/2))' y='$($rcPadT + $rcPlotH + 15)' text-anchor='middle' font-size='9' fill='#566'>$($d.DayLabel)</text>")
    }

    # Legend
    $legY = $rcH
    [void]$sb.AppendLine("<rect x='$($rcPadL + 20)' y='$legY' width='12' height='12' fill='#336699' rx='2'/>")
    [void]$sb.AppendLine("<text x='$($rcPadL + 37)' y='$($legY + 10)' font-size='10' fill='#1c2b3a'>Items Decided %</text>")
    [void]$sb.AppendLine("<rect x='$($rcPadL + 170)' y='$legY' width='12' height='12' fill='$($colors.Green)' rx='2'/>")
    [void]$sb.AppendLine("<text x='$($rcPadL + 187)' y='$($legY + 10)' font-size='10' fill='#1c2b3a'>Reviewers Signed Off %</text>")

    [void]$sb.AppendLine("</svg></div></div>")
}

#endregion

#region Chart 11: Source-Level Completion Breakdown

# Build source data from the latest calendar day's raw JSONL record
$latestRec = $null
$latestDayKey = @($calendarDays.Keys)[$dayCount - 1]
if ($null -ne $latestDayKey) { $latestRec = $calendarDays[$latestDayKey] }
# The source data is stored on the raw JSONL record, accessible via the calendar day's SourceData
if ($null -ne $latestRec -and $null -ne $latestRec.SourceData) {
    $sourceData = @($latestRec.SourceData)
    if ($sourceData.Count -gt 0) {
        [void]$sb.AppendLine("<div class='section'>")
        [void]$sb.AppendLine("<div class='section-title'>Source-Level Completion Breakdown</div>")
        [void]$sb.AppendLine("<p class='note'>Shows completion rate per source (application). Items reviewed = approved + revoked. Undecided items highlighted per source.</p>")

        [void]$sb.AppendLine("<table><thead><tr><th>Source</th><th style='text-align:right;'>Total</th><th style='text-align:right;'>Approved</th><th style='text-align:right;'>Revoked</th><th style='text-align:right;'>Undecided</th><th style='text-align:center;'>Completion</th><th>Progress</th></tr></thead><tbody>")
        foreach ($src in $sourceData) {
            $sName = ConvertTo-SPHtmlSafe ([string](Get-V7Prop $src 'name' 'Unknown'))
            $sTotal = [int](Get-V7NumericProp $src 'total' 0)
            $sAppr = [int](Get-V7NumericProp $src 'approved' 0)
            $sRev = [int](Get-V7NumericProp $src 'revoked' 0)
            $sPend = $sTotal - $sAppr - $sRev; if ($sPend -lt 0) { $sPend = 0 }
            $sPct = if ($sTotal -gt 0) { [math]::Round(($sAppr + $sRev) / $sTotal * 100, 0) } else { 0 }
            $sColor = if ($sPct -ge 80) { $colors.Green } elseif ($sPct -ge 50) { $colors.Amber } else { $colors.Red }
            $sPendColor = if ($sPend -gt 0) { "color:$($colors.Red);font-weight:600;" } else { '' }
            $thermBar = "<span class='thermometer'><span class='thermometer-fill' style='width:${sPct}%;background:$sColor;display:inline-block;'></span></span>"
            [void]$sb.AppendLine("<tr><td style='font-weight:600;'>$sName</td><td style='text-align:right;'>$sTotal</td><td style='text-align:right;'>$sAppr</td><td style='text-align:right;'>$sRev</td><td style='text-align:right;$sPendColor'>$sPend</td><td style='text-align:center;font-weight:600;color:$sColor;'>${sPct}%</td><td>$thermBar</td></tr>")
        }
        [void]$sb.AppendLine("</tbody></table></div>")
    }
}

#endregion

#region Chart 12: Scope Waterfall (day-over-day item count changes)

if ($dayCount -ge 3) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Decision Velocity -- Day-over-Day Changes</div>")
    [void]$sb.AppendLine("<p class='note'>Shows daily changes in approved (green up), revoked (red up), and undecided (amber down) counts. Positive = growth, negative = reduction. Tracks how quickly decisions are being made.</p>")

    $wfW = 700; $wfH = 180; $wfPadL = 50; $wfPadB = 40; $wfPadT = 15
    $wfPlotH = $wfH - $wfPadT - $wfPadB
    $wfBarW = [int][math]::Floor(($wfW - $wfPadL - 10) / ($dayCount - 1) * 0.7)
    $wfGapW = [int][math]::Floor(($wfW - $wfPadL - 10) / ($dayCount - 1) * 0.3)

    # Find max absolute delta for scaling
    $maxDelta = 1
    for ($i = 1; $i -lt $dayCount; $i++) {
        $d = $dailyData[$i]
        $aD = [math]::Abs([int]$d.ApprovedDelta)
        $rD = [math]::Abs([int]$d.RevokedDelta)
        $pD = [math]::Abs([int]$d.PendingDelta)
        if ($aD -gt $maxDelta) { $maxDelta = $aD }
        if ($rD -gt $maxDelta) { $maxDelta = $rD }
        if ($pD -gt $maxDelta) { $maxDelta = $pD }
    }

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$wfW' height='$($wfH + 10)' style='font-family:Segoe UI,Arial,sans-serif;'>")

    # Zero line
    $zeroY = $wfPadT + [int]($wfPlotH / 2)
    [void]$sb.AppendLine("<line x1='$wfPadL' y1='$zeroY' x2='$wfW' y2='$zeroY' stroke='#1f3a5f' stroke-width='1' opacity='0.3'/>")
    [void]$sb.AppendLine("<text x='$($wfPadL - 4)' y='$($zeroY + 4)' text-anchor='end' font-size='9' fill='#888'>0</text>")
    # Top/bottom labels
    [void]$sb.AppendLine("<text x='$($wfPadL - 4)' y='$($wfPadT + 10)' text-anchor='end' font-size='8' fill='#888'>+$maxDelta</text>")
    [void]$sb.AppendLine("<text x='$($wfPadL - 4)' y='$($wfPadT + $wfPlotH - 2)' text-anchor='end' font-size='8' fill='#888'>-$maxDelta</text>")

    for ($i = 1; $i -lt $dayCount; $i++) {
        $d = $dailyData[$i]
        $xBase = $wfPadL + (($i - 1) * ($wfBarW + $wfGapW)) + [int]($wfGapW / 2)
        $subBarW = [int]($wfBarW / 3)

        # Approved delta (green, positive = up from zero line)
        $aD = [int]$d.ApprovedDelta
        $aH = [int][math]::Max(1, [math]::Abs($aD) / $maxDelta * ($wfPlotH / 2))
        $aY = if ($aD -ge 0) { $zeroY - $aH } else { $zeroY }
        [void]$sb.AppendLine("<rect x='$xBase' y='$aY' width='$subBarW' height='$aH' fill='$($colors.Green)' rx='1' opacity='0.8'/>")

        # Revoked delta (red)
        $rD = [int]$d.RevokedDelta
        $rH = [int][math]::Max(1, [math]::Abs($rD) / $maxDelta * ($wfPlotH / 2))
        $rY = if ($rD -ge 0) { $zeroY - $rH } else { $zeroY }
        $rX = $xBase + $subBarW
        [void]$sb.AppendLine("<rect x='$rX' y='$rY' width='$subBarW' height='$rH' fill='$($colors.Red)' rx='1' opacity='0.8'/>")

        # Pending delta (amber, negative = good, going down)
        $pD = [int]$d.PendingDelta
        $pH = [int][math]::Max(1, [math]::Abs($pD) / $maxDelta * ($wfPlotH / 2))
        $pY = if ($pD -ge 0) { $zeroY - $pH } else { $zeroY }
        $pX = $xBase + $subBarW * 2
        [void]$sb.AppendLine("<rect x='$pX' y='$pY' width='$subBarW' height='$pH' fill='$($colors.Amber)' rx='1' opacity='0.8'/>")

        # Day label
        [void]$sb.AppendLine("<text x='$($xBase + [int]($wfBarW/2))' y='$($wfH - 5)' text-anchor='middle' font-size='9' fill='#566'>$($d.DayLabel)</text>")
    }

    # Legend
    $wfLegY = $wfH
    [void]$sb.AppendLine("<rect x='$($wfPadL + 5)' y='$wfLegY' width='10' height='10' fill='$($colors.Green)' rx='1'/>")
    [void]$sb.AppendLine("<text x='$($wfPadL + 19)' y='$($wfLegY + 9)' font-size='10' fill='#1c2b3a'>Approved +/-</text>")
    [void]$sb.AppendLine("<rect x='$($wfPadL + 110)' y='$wfLegY' width='10' height='10' fill='$($colors.Red)' rx='1'/>")
    [void]$sb.AppendLine("<text x='$($wfPadL + 124)' y='$($wfLegY + 9)' font-size='10' fill='#1c2b3a'>Revoked +/-</text>")
    [void]$sb.AppendLine("<rect x='$($wfPadL + 215)' y='$wfLegY' width='10' height='10' fill='$($colors.Amber)' rx='1'/>")
    [void]$sb.AppendLine("<text x='$($wfPadL + 229)' y='$($wfLegY + 9)' font-size='10' fill='#1c2b3a'>Undecided +/-</text>")

    [void]$sb.AppendLine("</svg></div></div>")
}

#endregion

#region Chart 13: Reviewer Compliance Accountability

if ($dayCount -ge 2 -and $reviewerList.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")
    [void]$sb.AppendLine("<div class='section-title'>Reviewer Compliance Accountability</div>")
    [void]$sb.AppendLine("<p class='note'>Categorizes reviewers by engagement pattern across the ${dayCount}-day window. 'Active' = made decisions on that day's campaign. Identifies chronic non-compliance, recent dropoff, and potential unreassigned absences.</p>")

    # Build per-reviewer activity timeline: which days they were active (decisions > 0)
    $rvCompliance = @()
    foreach ($rv in $reviewerList) {
        $rn = $rv.Name
        $activeDays = @()
        $totalDecisions = 0
        $lastActiveIdx = -1
        $firstActiveIdx = -1

        for ($di = 0; $di -lt $dayCount; $di++) {
            $rvDay = $null
            foreach ($r in $dailyData[$di].Reviewers) {
                if ($r.Name -eq $rn) { $rvDay = $r; break }
            }
            $dayDec = if ($null -ne $rvDay) { [int]$rvDay.Approved + [int]$rvDay.Revoked } else { 0 }
            $totalDecisions += $dayDec
            if ($dayDec -gt 0) {
                $activeDays += $di
                $lastActiveIdx = $di
                if ($firstActiveIdx -lt 0) { $firstActiveIdx = $di }
            }
        }

        $daysSinceActive = if ($lastActiveIdx -ge 0) { $dayCount - 1 - $lastActiveIdx } else { $dayCount }
        $activeDayCount = $activeDays.Count

        # Classify
        $compCategory = 'Unknown'
        $compSeverity = 'green'
        if ($totalDecisions -eq 0) {
            $compCategory = 'Never Complied'
            $compSeverity = 'red'
        }
        elseif ($daysSinceActive -eq 0) {
            $compCategory = 'Active Today'
            $compSeverity = 'green'
        }
        elseif ($daysSinceActive -le 2) {
            $compCategory = "Inactive $daysSinceActive day(s)"
            $compSeverity = 'green'
        }
        elseif ($daysSinceActive -le 4) {
            $compCategory = "Inactive $daysSinceActive days"
            $compSeverity = 'amber'
        }
        elseif ($daysSinceActive -le 7) {
            $compCategory = "Inactive $daysSinceActive days"
            $compSeverity = 'amber'
        }
        else {
            # Active in first half but not second half = potential vacation/absence
            $midpoint = [int]($dayCount / 2)
            $activeFirstHalf = @($activeDays | Where-Object { $_ -lt $midpoint }).Count
            $activeSecondHalf = @($activeDays | Where-Object { $_ -ge $midpoint }).Count
            if ($activeFirstHalf -gt 0 -and $activeSecondHalf -eq 0) {
                $compCategory = "Absent (active early, gone $daysSinceActive days)"
                $compSeverity = 'red'
            }
            else {
                $compCategory = "Inactive $daysSinceActive days"
                $compSeverity = 'red'
            }
        }

        $rvCompliance += @{
            Name           = $rn
            Category       = $compCategory
            Severity       = $compSeverity
            TotalDecisions = $totalDecisions
            ActiveDays     = $activeDayCount
            DaysSinceActive = $daysSinceActive
            LastActiveDate = if ($lastActiveIdx -ge 0) { $dailyData[$lastActiveIdx].DayLabel } else { 'Never' }
        }
    }

    # Group by severity for summary counts
    $redCount = @($rvCompliance | Where-Object { $_.Severity -eq 'red' }).Count
    $amberCount = @($rvCompliance | Where-Object { $_.Severity -eq 'amber' }).Count
    $greenCount = @($rvCompliance | Where-Object { $_.Severity -eq 'green' }).Count
    $neverCount = @($rvCompliance | Where-Object { $_.Category -eq 'Never Complied' }).Count
    $absentCount = @($rvCompliance | Where-Object { $_.Category -match 'Absent' }).Count

    # Summary KPIs
    [void]$sb.AppendLine("<div style='margin:8px 0 16px;'>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$($colors.Green);'>$greenCount</span><span class='l'>Compliant</span></span>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$($colors.Amber);'>$amberCount</span><span class='l'>At Risk (3-7 days)</span></span>")
    $ncColor = if ($neverCount -gt 0) { $colors.Red } else { $colors.Green }
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$ncColor;'>$neverCount</span><span class='l'>Never Complied</span></span>")
    $abColor = if ($absentCount -gt 0) { $colors.Red } else { $colors.Green }
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$abColor;'>$absentCount</span><span class='l'>Absent (needs reassignment?)</span></span>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$($colors.Red);'>$redCount</span><span class='l'>Non-Compliant Total</span></span>")
    [void]$sb.AppendLine("</div>")

    # Table: Non-compliant reviewers first (red, then amber), sorted by days since active descending
    $sorted = @($rvCompliance | Sort-Object @{ Expression = { switch ($_.Severity) { 'red' { 0 } 'amber' { 1 } default { 2 } } } }, @{ Expression = { $_.DaysSinceActive }; Descending = $true })

    # Never Complied section
    $neverList = @($sorted | Where-Object { $_.Category -eq 'Never Complied' })
    if ($neverList.Count -gt 0) {
        [void]$sb.AppendLine("<details open><summary style='font-weight:bold;font-size:13px;margin:8px 0 4px;color:$($colors.Red);'>Never Complied ($($neverList.Count) reviewers) -- Zero decisions across entire window</summary>")
        [void]$sb.AppendLine("<table class='report'><thead><tr><th>Reviewer</th><th style='text-align:right;'>Total Decisions</th><th style='text-align:right;'>Active Days</th><th>Last Active</th><th>Status</th></tr></thead><tbody>")
        foreach ($rv in $neverList) {
            [void]$sb.AppendLine("<tr style='background:#fdecec;'><td style='font-weight:600;color:$($colors.Red);'>$(ConvertTo-SPHtmlSafe $rv.Name)</td><td style='text-align:right;font-weight:600;'>0</td><td style='text-align:right;'>0 / $dayCount</td><td>Never</td><td class='s-red'>$($rv.Category)</td></tr>")
        }
        [void]$sb.AppendLine("</tbody></table></details>")
    }

    # Absent (active early, gone recently) section
    $absentList = @($sorted | Where-Object { $_.Category -match 'Absent' })
    if ($absentList.Count -gt 0) {
        [void]$sb.AppendLine("<details open><summary style='font-weight:bold;font-size:13px;margin:8px 0 4px;color:$($colors.Red);'>Potentially Absent / Unreassigned ($($absentList.Count) reviewers) -- Active early in window, inactive recently</summary>")
        [void]$sb.AppendLine("<p class='note'>These reviewers were active in the first half of the window but have made zero decisions recently. They may be on vacation, leave, or have left the organization without their certifications being reassigned.</p>")
        [void]$sb.AppendLine("<table class='report'><thead><tr><th>Reviewer</th><th style='text-align:right;'>Total Decisions</th><th style='text-align:right;'>Active Days</th><th>Last Active</th><th>Days Since</th><th>Status</th></tr></thead><tbody>")
        foreach ($rv in $absentList) {
            [void]$sb.AppendLine("<tr style='background:#fff7e6;'><td style='font-weight:600;'>$(ConvertTo-SPHtmlSafe $rv.Name)</td><td style='text-align:right;'>$($rv.TotalDecisions)</td><td style='text-align:right;'>$($rv.ActiveDays) / $dayCount</td><td>$($rv.LastActiveDate)</td><td style='text-align:right;font-weight:600;'>$($rv.DaysSinceActive)</td><td class='s-red'>$($rv.Category)</td></tr>")
        }
        [void]$sb.AppendLine("</tbody></table></details>")
    }

    # At-risk (3-7 days inactive) section
    $atRiskList = @($sorted | Where-Object { $_.Severity -eq 'amber' })
    if ($atRiskList.Count -gt 0) {
        [void]$sb.AppendLine("<details><summary style='font-weight:bold;font-size:13px;margin:8px 0 4px;color:$($colors.Amber);'>At Risk ($($atRiskList.Count) reviewers) -- Inactive 3-7 days</summary>")
        [void]$sb.AppendLine("<table class='report'><thead><tr><th>Reviewer</th><th style='text-align:right;'>Total Decisions</th><th style='text-align:right;'>Active Days</th><th>Last Active</th><th>Days Since</th><th>Status</th></tr></thead><tbody>")
        foreach ($rv in $atRiskList) {
            [void]$sb.AppendLine("<tr><td style='font-weight:600;'>$(ConvertTo-SPHtmlSafe $rv.Name)</td><td style='text-align:right;'>$($rv.TotalDecisions)</td><td style='text-align:right;'>$($rv.ActiveDays) / $dayCount</td><td>$($rv.LastActiveDate)</td><td style='text-align:right;'>$($rv.DaysSinceActive)</td><td class='s-amber'>$($rv.Category)</td></tr>")
        }
        [void]$sb.AppendLine("</tbody></table></details>")
    }

    # Compliant section (collapsed)
    $compliantList = @($sorted | Where-Object { $_.Severity -eq 'green' })
    if ($compliantList.Count -gt 0) {
        [void]$sb.AppendLine("<details><summary style='font-weight:bold;font-size:13px;margin:8px 0 4px;color:$($colors.Green);'>Compliant ($($compliantList.Count) reviewers) -- Active within last 2 days</summary>")
        [void]$sb.AppendLine("<table class='report'><thead><tr><th>Reviewer</th><th style='text-align:right;'>Total Decisions</th><th style='text-align:right;'>Active Days</th><th>Last Active</th><th>Status</th></tr></thead><tbody>")
        foreach ($rv in $compliantList) {
            [void]$sb.AppendLine("<tr><td>$(ConvertTo-SPHtmlSafe $rv.Name)</td><td style='text-align:right;'>$($rv.TotalDecisions)</td><td style='text-align:right;'>$($rv.ActiveDays) / $dayCount</td><td>$($rv.LastActiveDate)</td><td class='s-green'>$($rv.Category)</td></tr>")
        }
        [void]$sb.AppendLine("</tbody></table></details>")
    }

    [void]$sb.AppendLine("</div>")
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
[void]$sb.AppendLine("<p class='footer'>Daily Evidence V7 (Calendar-Day Visualization) | Campaign: $(ConvertTo-SPHtmlSafe $campaignNameResolved)$envFooter | Generated: $genDate | SailPoint ISC Governance Toolkit</p>")
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
    Write-Host '  === V7 Calendar-Day Summary ===' -ForegroundColor Cyan
    Write-Host "  Campaign:     $campaignNameResolved" -ForegroundColor White
    Write-Host "  Status:       $campaignStatusResolved" -ForegroundColor White
    Write-Host "  Days:         $dayCount calendar day(s)" -ForegroundColor White
    Write-Host "  Completion:   $($todayRec.CompletionPct)%" -ForegroundColor White
    Write-Host "  Approved:     $($todayRec.Approved)" -ForegroundColor White
    Write-Host "  Revoked:      $($todayRec.Revoked)" -ForegroundColor White
    Write-Host "  Undecided:    $($todayRec.Pending)" -ForegroundColor White
    Write-Host "  Reviewers:    $($todayRec.ReviewersTotal)" -ForegroundColor White
    if ($dayCount -ge 2) {
        $trendDirection = if ($windowDelta -gt 0) { 'UP' } elseif ($windowDelta -lt 0) { 'DOWN' } else { 'FLAT' }
        $dSignConsole = if ($windowDelta -gt 0) { '+' } else { '' }
        Write-Host "  Trend:        ${trendDirection} (${dSignConsole}${windowDelta}% over $dayCount days)" -ForegroundColor White
    }
    Write-Host "  Priv Pending: $($todayRec.PrivPending) of $($todayRec.PrivTotal)" -ForegroundColor White
    if ($suspectIncluded -gt 0) {
        Write-Host "  Suspect Days: $suspectIncluded" -ForegroundColor Yellow
    }

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
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV7 completed: Duration=$durationStr CalendarDays=$dayCount SuspectFlagged=$suspectCount" `
        -Severity INFO -Component 'DailyEvidenceV7' -Action 'Complete' -CorrelationID $correlationID
} catch { }

#endregion

#region Exit Code

# 0: Healthy (completion >= 80%)
# 1: Warning (completion 50-79%)
# 2: Parameter error
# 4: Configuration error
# 5: Critical (completion < 50% or insufficient data)

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

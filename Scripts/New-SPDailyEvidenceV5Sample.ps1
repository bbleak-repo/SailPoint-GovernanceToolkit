#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a V5 daily evidence report SAMPLE with multiple visualization styles.
.DESCRIPTION
    V5 is the trend-aware daily evidence report -- it reads per-campaign trend JSONL
    to show multi-day progression with visual charts. This sample script generates
    synthetic trend data and renders the report with FOUR different chart styles
    so you can evaluate which looks best:

    Style A: Horizontal bar charts (inline SVG) -- reviewer completion over 7 days
    Style B: Stacked progress bars (pure CSS) -- decision distribution day-by-day
    Style C: Sparkline mini-charts (inline SVG) -- compact metric trends
    Style D: Table with delta arrows -- numeric comparison with direction indicators

    No ISC tenant required. Produces daily-evidence-v5-sample-*.html.
.PARAMETER OutputPath
    Output directory. Default: .\Reports\sample-v5
.PARAMETER OpenInBrowser
    Open the generated HTML in the default browser.
#>
[CmdletBinding()]
param(
    [Parameter()] [string]$OutputPath,
    [Parameter()] [switch]$OpenInBrowser
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

Import-Module (Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1') -Force -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $toolkitRoot 'Reports\sample-v5' }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

Write-Host ''
Write-Host '  Daily Evidence V5 -- Multi-Style Sample Generator' -ForegroundColor Cyan
Write-Host '  ==================================================' -ForegroundColor Cyan
Write-Host ''

#region Generate 7 days of synthetic per-campaign trend data

$now = (Get-Date).ToUniversalTime()
$campaignName = 'Q2 Entitlement Review'

$reviewers = @(
    @{ Name = 'Alice Chen';    StartCompletion = 15;  DailyGain = 12; Style = 'steady' }
    @{ Name = 'Bob Martinez';  StartCompletion = 0;   DailyGain = 0;  Style = 'stalled' }
    @{ Name = 'Carol Davis';   StartCompletion = 40;  DailyGain = 8;  Style = 'steady' }
    @{ Name = 'Dave Wilson';   StartCompletion = 60;  DailyGain = 6;  Style = 'finishing' }
    @{ Name = 'Eve Thompson';  StartCompletion = 10;  DailyGain = 3;  Style = 'slow' }
)

# Build 7 days of data
$dailyData = @()
for ($day = 6; $day -ge 0; $day--) {
    $date = $now.AddDays(-$day)
    $dayIdx = 6 - $day  # 0=oldest, 6=today

    $dayReviewers = @()
    $totalItems = 0; $totalApproved = 0; $totalRevoked = 0; $totalPending = 0

    foreach ($rv in $reviewers) {
        $total = Get-Random -Minimum 20 -Maximum 35
        $completion = [math]::Max(0, [math]::Min(100, $rv.StartCompletion + ($rv.DailyGain * $dayIdx) + (Get-Random -Minimum -2 -Maximum 3)))
        $approved = [int][math]::Round($total * $completion / 100 * 0.8)
        $revoked  = [int][math]::Round($total * $completion / 100 * 0.15)
        $pending  = $total - $approved - $revoked
        if ($pending -lt 0) { $pending = 0 }

        $dayReviewers += @{
            Name       = $rv.Name
            Total      = $total
            Approved   = $approved
            Revoked    = $revoked
            Pending    = $pending
            Completion = [math]::Round($completion, 1)
            Style      = $rv.Style
        }

        $totalItems += $total
        $totalApproved += $approved
        $totalRevoked += $revoked
        $totalPending += $pending
    }

    # Scope changes
    $scopeAdded   = if ($dayIdx -gt 0) { Get-Random -Minimum 0 -Maximum 6 } else { 0 }
    $scopeRemoved = if ($dayIdx -gt 0) { Get-Random -Minimum 0 -Maximum 3 } else { 0 }

    # Privileged access data (derived ~15% of totals with jitter)
    $privPending = [math]::Max(0, [int]($totalPending * 0.15 + (Get-Random -Minimum -1 -Maximum 3)))
    $privTotal   = [math]::Max($privPending, [int]($totalItems * 0.15))

    $dailyData += @{
        Date       = $date.ToString('yyyy-MM-dd')
        DayLabel   = $date.ToString('ddd MM/dd')
        Reviewers  = $dayReviewers
        Total      = $totalItems
        Approved   = $totalApproved
        Revoked    = $totalRevoked
        Pending    = $totalPending
        CompletionPct = [math]::Round(($totalApproved + $totalRevoked) / [math]::Max(1, $totalItems) * 100, 1)
        ScopeAdded   = $scopeAdded
        ScopeRemoved = $scopeRemoved
        PrivPending  = $privPending
        PrivTotal    = $privTotal
    }
}

#endregion

#region Build HTML

$colors = Get-SPHtmlColorPalette
$genDate = $now.ToString('yyyy-MM-dd HH:mm UTC')
$timestamp = $now.ToString('yyyyMMdd-HHmmss')
$htmlFile = Join-Path $OutputPath "daily-evidence-v5-sample-${timestamp}.html"

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
.style-label{display:inline-block;padding:3px 10px;border-radius:12px;font-size:10px;font-weight:700;color:#fff;background:#336699;margin-bottom:8px;text-transform:uppercase;letter-spacing:.06em;}
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
.badge-gold{background:#c5960c;color:#fff;}
.badge-silver{background:#888;}
.badge-bronze{background:#8b5e3c;}
.risk-matrix td{padding:6px 8px;font-size:12px;border-bottom:1px solid #e3e9f0;vertical-align:middle;}
.risk-matrix th{padding:6px 8px;font-size:11px;}
.thermometer{display:inline-block;width:100px;height:14px;background:#e3e9f0;border-radius:7px;overflow:hidden;vertical-align:middle;}
.thermometer-fill{height:14px;border-radius:7px;}
'@

$sb = New-Object System.Text.StringBuilder 16384
[void]$sb.AppendLine("<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Daily Evidence V5 -- Trend Report (Sample)</title><style>$css</style></head><body>")

# Header
[void]$sb.AppendLine("<h1>Daily Certification Evidence Report (V5) -- Trend View</h1>")
[void]$sb.AppendLine("<p class='meta'>")
[void]$sb.AppendLine("Campaign: <strong>$(ConvertTo-SPHtmlSafe $campaignName)</strong><br>")
[void]$sb.AppendLine("Period: Last 7 days ($($dailyData[0].Date) to $($dailyData[6].Date))<br>")
[void]$sb.AppendLine("Generated: $genDate<br>")
[void]$sb.AppendLine("<em>This is a SAMPLE report with synthetic data demonstrating multiple visualization styles (A through N).</em></p>")

# Today's KPIs
$today = $dailyData[6]
$yesterday = $dailyData[5]
$weekAgo = $dailyData[0]
$completionDelta = [math]::Round($today.CompletionPct - $yesterday.CompletionPct, 1)
$weekDelta = [math]::Round($today.CompletionPct - $weekAgo.CompletionPct, 1)

[void]$sb.AppendLine("<div style='margin:16px 0;'>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($today.CompletionPct)%</span><span class='l'>Completion</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($today.Approved)</span><span class='l'>Approved</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($today.Revoked)</span><span class='l'>Revoked</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$($colors.Red);'>$($today.Pending)</span><span class='l'>Pending</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($reviewers.Count)</span><span class='l'>Reviewers</span></span>")
$dSign = if ($weekDelta -gt 0) { '+' } else { '' }
$dColor = if ($weekDelta -gt 5) { $colors.Green } elseif ($weekDelta -lt -2) { $colors.Red } else { $colors.Amber }
[void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$dColor;'>${dSign}${weekDelta}%</span><span class='l'>7-Day Change</span></span>")
# SLA Countdown KPI
$sampleDeadlineDays = 5
$dlKpiColor = if ($sampleDeadlineDays -le 3) { $colors.Red } elseif ($sampleDeadlineDays -le 7) { $colors.Amber } else { $colors.Green }
[void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$dlKpiColor;'>$sampleDeadlineDays</span><span class='l'>Days to Deadline</span></span>")
[void]$sb.AppendLine("</div>")

# Executive summary paragraph
$stalledRvCount = @($reviewers | Where-Object { $_.Style -eq 'stalled' }).Count
$privPendCount = $today.PrivPending
$velocityPerDay = [math]::Round(($today.CompletionPct - $weekAgo.CompletionPct) / 6, 1)
$projectedCompletion = [math]::Min(100, $today.CompletionPct + ($velocityPerDay * $sampleDeadlineDays))
$willComplete = if ($projectedCompletion -ge 99.5) { 'will' } else { 'will NOT' }
$summaryText = "Campaign is $($today.CompletionPct)% complete with $sampleDeadlineDays business days until deadline."
if ($stalledRvCount -gt 0) {
    $summaryText += " $stalledRvCount reviewer(s) have made zero progress (stalled)."
}
if ($privPendCount -gt 0) {
    $summaryText += " $privPendCount privileged access items remain pending review."
}
$summaryText += " Current velocity (${velocityPerDay}%/day) suggests the campaign $willComplete complete on time."
[void]$sb.AppendLine("<p style='font-size:13px;color:#1c2b3a;line-height:1.6;margin:12px 0 16px 0;padding:10px 14px;background:#f6f9fc;border-left:4px solid $dlKpiColor;border-radius:4px;'>$summaryText</p>")

# ===== STYLE A: Horizontal Bar Charts (SVG) =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style A</span>")
[void]$sb.AppendLine("<div class='section-title'>Reviewer Completion -- 7-Day Progression (Horizontal Bar Charts)</div>")
[void]$sb.AppendLine("<p class='note'>Each bar shows the reviewer's completion percentage. The rightmost bar is today; color indicates status (green=complete, blue=progressing, red=stalled).</p>")

[void]$sb.AppendLine("<table><thead><tr><th style='width:120px;'>Reviewer</th>")
foreach ($d in $dailyData) { [void]$sb.AppendLine("<th style='width:100px;text-align:center;font-size:10px;'>$($d.DayLabel)</th>") }
[void]$sb.AppendLine("</tr></thead><tbody>")

foreach ($rv in $reviewers) {
    [void]$sb.AppendLine("<tr><td style='font-weight:600;'>$(ConvertTo-SPHtmlSafe $rv.Name)</td>")
    foreach ($d in $dailyData) {
        $rvDay = $d.Reviewers | Where-Object { $_.Name -eq $rv.Name }
        $pct = if ($rvDay) { $rvDay.Completion } else { 0 }
        $pct = [math]::Max(0, [math]::Min(100, $pct))
        $barColor = if ($pct -ge 95) { $colors.Green } elseif ($rv.Style -eq 'stalled') { $colors.Red } else { '#336699' }
        [void]$sb.AppendLine("<td><div class='bar-track'><div class='bar-fill' style='width:${pct}%;background:$barColor;'></div><span class='bar-label'>${pct}%</span></div></td>")
    }
    [void]$sb.AppendLine("</tr>")
}
[void]$sb.AppendLine("</tbody></table></div>")

# ===== STYLE B: Stacked Progress Bars (CSS) =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style B</span>")
[void]$sb.AppendLine("<div class='section-title'>Decision Distribution -- Day-by-Day Stacked Bars</div>")
[void]$sb.AppendLine("<p class='note'>Green=Approved, Red=Revoked, Gray=Pending. The width of each segment shows the proportion of total items.</p>")

[void]$sb.AppendLine("<table><thead><tr><th style='width:100px;'>Day</th><th>Decision Distribution</th><th style='width:70px;text-align:right;'>Completion</th></tr></thead><tbody>")
foreach ($d in $dailyData) {
    $aPct = [math]::Round($d.Approved / [math]::Max(1, $d.Total) * 100, 0)
    $rPct = [math]::Round($d.Revoked / [math]::Max(1, $d.Total) * 100, 0)
    $pPct = 100 - $aPct - $rPct
    if ($pPct -lt 0) { $pPct = 0 }
    [void]$sb.AppendLine("<tr><td style='font-weight:600;'>$($d.DayLabel)</td>")
    [void]$sb.AppendLine("<td><div class='stacked-bar'>")
    if ($aPct -gt 0) { [void]$sb.AppendLine("<div class='stacked-seg' style='width:${aPct}%;background:$($colors.Green);'>$(if($aPct -ge 8){"${aPct}%"})</div>") }
    if ($rPct -gt 0) { [void]$sb.AppendLine("<div class='stacked-seg' style='width:${rPct}%;background:$($colors.Red);'>$(if($rPct -ge 8){"${rPct}%"})</div>") }
    if ($pPct -gt 0) { [void]$sb.AppendLine("<div class='stacked-seg' style='width:${pPct}%;background:#ccc;color:#555;'>$(if($pPct -ge 8){"${pPct}%"})</div>") }
    [void]$sb.AppendLine("</div></td>")
    [void]$sb.AppendLine("<td style='text-align:right;font-weight:600;'>$($d.CompletionPct)%</td></tr>")
}
[void]$sb.AppendLine("</tbody></table></div>")

# ===== STYLE B2: Vertical Bar Chart -- Items Reviewed % + Reviewer Completion % =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style B2</span>")
[void]$sb.AppendLine("<div class='section-title'>Completion Progression -- Vertical Bar Chart (Items Reviewed % + Reviewer Completion %)</div>")
[void]$sb.AppendLine("<p class='note'>Blue bars show the percentage of items reviewed (decided). Green bars show the percentage of reviewers who have fully completed. Height is proportional to 100%.</p>")

# Build the vertical bar chart as an SVG
$chartWidth = 700
$chartHeight = 200
$dayCount = $dailyData.Count
$groupWidth = [int][math]::Floor(($chartWidth - 40) / $dayCount)
$barWidth = [int][math]::Floor($groupWidth * 0.35)
$gap = [int][math]::Floor($groupWidth * 0.08)
$leftPad = 40

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
[void]$sb.AppendLine("<svg width='$chartWidth' height='$($chartHeight + 60)' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Y-axis labels and gridlines
for ($pct = 0; $pct -le 100; $pct += 25) {
    $y = [int]($chartHeight - ($pct / 100 * $chartHeight) + 10)
    [void]$sb.AppendLine("<line x1='$leftPad' y1='$y' x2='$chartWidth' y2='$y' stroke='#e3e9f0' stroke-width='1'/>")
    [void]$sb.AppendLine("<text x='$($leftPad - 5)' y='$($y + 4)' text-anchor='end' font-size='10' fill='#888'>${pct}%</text>")
}

for ($i = 0; $i -lt $dayCount; $i++) {
    $d = $dailyData[$i]
    $xBase = $leftPad + ($i * $groupWidth) + $gap

    # Items reviewed % (blue bar)
    $itemsPct = $d.CompletionPct
    $itemsH = [int][math]::Max(2, [math]::Round($itemsPct / 100 * $chartHeight))
    $itemsY = $chartHeight - $itemsH + 10
    $itemsOpacity = [math]::Round(0.5 + (0.5 * $i / [math]::Max(1, $dayCount - 1)), 2)
    [void]$sb.AppendLine("<rect x='$xBase' y='$itemsY' width='$barWidth' height='$itemsH' fill='#336699' opacity='$itemsOpacity' rx='2'/>")
    # Value label on top of bar
    if ($itemsH -gt 15) {
        [void]$sb.AppendLine("<text x='$($xBase + [int]($barWidth/2))' y='$($itemsY - 3)' text-anchor='middle' font-size='9' font-weight='600' fill='#336699'>$($itemsPct)%</text>")
    }

    # Reviewer completion % (green bar) -- compute from per-reviewer data
    $rvCompleted = @($d.Reviewers | Where-Object { $_.Completion -ge 100 }).Count
    $rvTotal = $d.Reviewers.Count
    $rvPct = if ($rvTotal -gt 0) { [math]::Round($rvCompleted / $rvTotal * 100, 0) } else { 0 }
    $rvH = [int][math]::Max(2, [math]::Round($rvPct / 100 * $chartHeight))
    $rvY = $chartHeight - $rvH + 10
    $rvX = $xBase + $barWidth + $gap
    [void]$sb.AppendLine("<rect x='$rvX' y='$rvY' width='$barWidth' height='$rvH' fill='$($colors.Green)' opacity='$itemsOpacity' rx='2'/>")
    if ($rvH -gt 15) {
        [void]$sb.AppendLine("<text x='$($rvX + [int]($barWidth/2))' y='$($rvY - 3)' text-anchor='middle' font-size='9' font-weight='600' fill='$($colors.Green)'>$($rvPct)%</text>")
    }

    # Day label below
    $labelX = $xBase + $barWidth + [int]($gap / 2)
    $labelY = $chartHeight + 25
    [void]$sb.AppendLine("<text x='$labelX' y='$labelY' text-anchor='middle' font-size='10' fill='#566'>$($d.DayLabel)</text>")
}

# Legend
$legendY = $chartHeight + 45
[void]$sb.AppendLine("<rect x='$($leftPad + 20)' y='$legendY' width='12' height='12' fill='#336699' rx='2'/>")
[void]$sb.AppendLine("<text x='$($leftPad + 37)' y='$($legendY + 10)' font-size='11' fill='#1c2b3a'>Items Reviewed %</text>")
[void]$sb.AppendLine("<rect x='$($leftPad + 170)' y='$legendY' width='12' height='12' fill='$($colors.Green)' rx='2'/>")
[void]$sb.AppendLine("<text x='$($leftPad + 187)' y='$($legendY + 10)' font-size='11' fill='#1c2b3a'>Reviewers Completed %</text>")

[void]$sb.AppendLine("</svg>")
[void]$sb.AppendLine("</div></div>")

# ===== STYLE C: Sparkline Mini-Charts (SVG) =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style C</span>")
[void]$sb.AppendLine("<div class='section-title'>Metric Trends -- Compact Sparklines</div>")
[void]$sb.AppendLine("<p class='note'>7-day sparklines for key metrics. Each bar represents one day; height is proportional to the value. The latest day is fully opaque.</p>")

# Build sparkline SVG helper
function Build-Sparkline {
    param([double[]]$Values, [string]$Color = '#1f3a5f', [int]$Width = 140, [int]$Height = 28)
    if ($Values.Count -eq 0) { return "<svg width='$Width' height='$Height'></svg>" }
    $max = ($Values | Measure-Object -Maximum).Maximum
    if ($max -eq 0) { $max = 1 }
    $barW = [int][math]::Floor(($Width - ($Values.Count - 1) * 2) / $Values.Count)
    $svgParts = "<svg width='$Width' height='$Height' style='vertical-align:middle;'>"
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $h = [math]::Max(2, [int][math]::Round($Values[$i] / $max * ($Height - 2)))
        $x = $i * ($barW + 2)
        $y = $Height - $h
        $opacity = [math]::Round(0.3 + (0.7 * $i / [math]::Max(1, $Values.Count - 1)), 2)
        $svgParts += "<rect x='$x' y='$y' width='$barW' height='$h' fill='$Color' opacity='$opacity'/>"
    }
    $svgParts += "</svg>"
    return $svgParts
}

$metrics = @(
    @{ Label = 'Overall Completion %'; Values = @($dailyData | ForEach-Object { $_.CompletionPct }); Color = '#336699'; HighIsGood = $true }
    @{ Label = 'Approved Items';       Values = @($dailyData | ForEach-Object { $_.Approved });      Color = $colors.Green; HighIsGood = $true }
    @{ Label = 'Revoked Items';        Values = @($dailyData | ForEach-Object { $_.Revoked });       Color = $colors.Red; HighIsGood = $false }
    @{ Label = 'Pending Items';        Values = @($dailyData | ForEach-Object { $_.Pending });       Color = $colors.Amber; HighIsGood = $false }
    @{ Label = 'Scope Added';          Values = @($dailyData | ForEach-Object { $_.ScopeAdded });    Color = '#336699'; HighIsGood = $false }
    @{ Label = 'Scope Removed';        Values = @($dailyData | ForEach-Object { $_.ScopeRemoved });  Color = $colors.Gray; HighIsGood = $true }
)

[void]$sb.AppendLine("<table><thead><tr><th style='width:180px;'>Metric</th><th style='width:160px;'>7-Day Trend</th><th style='width:80px;text-align:right;'>Current</th><th style='width:80px;text-align:right;'>7d Ago</th><th style='width:80px;text-align:right;'>Change</th></tr></thead><tbody>")
foreach ($m in $metrics) {
    $current = $m.Values[$m.Values.Count - 1]
    $prior   = $m.Values[0]
    $delta   = [math]::Round($current - $prior, 1)
    $dClass  = if ($m.HighIsGood) {
        if ($delta -gt 0) { 'delta-up' } elseif ($delta -lt 0) { 'delta-down' } else { 'delta-flat' }
    } else {
        if ($delta -gt 0) { 'delta-down' } elseif ($delta -lt 0) { 'delta-up' } else { 'delta-flat' }
    }
    $dSign   = if ($delta -gt 0) { '+' } else { '' }
    $spark   = Build-Sparkline -Values $m.Values -Color $m.Color
    [void]$sb.AppendLine("<tr><td style='font-weight:600;'>$(ConvertTo-SPHtmlSafe $m.Label)</td><td>$spark</td><td style='text-align:right;'>$current</td><td style='text-align:right;color:#888;'>$prior</td><td style='text-align:right;' class='$dClass'>${dSign}$delta</td></tr>")
}
[void]$sb.AppendLine("</tbody></table></div>")

# ===== STYLE D: Table with Delta Arrows =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style D</span>")
[void]$sb.AppendLine("<div class='section-title'>Per-Reviewer Accountability -- Numeric Comparison with Direction</div>")
[void]$sb.AppendLine("<p class='note'>Shows each reviewer's completion today vs 7 days ago, with direction arrows. Stalled reviewers (zero change) are highlighted.</p>")

[void]$sb.AppendLine("<table><thead><tr><th>Reviewer</th><th style='text-align:right;'>7d Ago</th><th style='text-align:right;'>Yesterday</th><th style='text-align:right;'>Today</th><th style='text-align:center;'>Direction</th><th style='text-align:right;'>7d Change</th><th>Status</th></tr></thead><tbody>")
$rvIdx = 0
foreach ($rv in $reviewers) {
    $todayRv = $dailyData[6].Reviewers | Where-Object { $_.Name -eq $rv.Name }
    $yestRv  = $dailyData[5].Reviewers | Where-Object { $_.Name -eq $rv.Name }
    $weekRv  = $dailyData[0].Reviewers | Where-Object { $_.Name -eq $rv.Name }

    $todayPct = if ($todayRv) { $todayRv.Completion } else { 0 }
    $yestPct  = if ($yestRv) { $yestRv.Completion } else { 0 }
    $weekPct  = if ($weekRv) { $weekRv.Completion } else { 0 }
    $todayPct = [math]::Max(0, [math]::Min(100, $todayPct))
    $yestPct  = [math]::Max(0, [math]::Min(100, $yestPct))
    $weekPct  = [math]::Max(0, [math]::Min(100, $weekPct))

    $delta7 = [math]::Round($todayPct - $weekPct, 1)
    $arrow = if ($delta7 -gt 2) { "<span class='up-arrow'></span>" } elseif ($delta7 -lt -2) { "<span class='down-arrow'></span>" } else { "<span class='flat-line'></span>" }
    $dClass = if ($delta7 -gt 2) { 'delta-up' } elseif ($delta7 -lt -2) { 'delta-down' } else { 'delta-flat' }
    $dSign = if ($delta7 -gt 0) { '+' } else { '' }

    $status = if ($todayPct -ge 100) { "<span style='color:$($colors.Green);font-weight:600;'>Complete</span>" }
              elseif ($delta7 -lt 1 -and $todayPct -lt 95) { "<span style='color:$($colors.Red);font-weight:600;'>STALLED</span>" }
              elseif ($delta7 -lt 5) { "<span style='color:$($colors.Amber);'>Slow</span>" }
              else { "<span style='color:$($colors.Green);'>On Track</span>" }

    $bg = if ($delta7 -lt 1 -and $todayPct -lt 95) { " style='background:#fdecec;'" } elseif ($rvIdx % 2 -eq 1) { " style='background:#f6f9fc;'" } else { '' }
    $rvName = ConvertTo-SPHtmlSafe $rv.Name
    [void]$sb.AppendLine("<tr$bg><td style='font-weight:600;'>$rvName</td><td style='text-align:right;color:#888;'>${weekPct}%</td><td style='text-align:right;'>${yestPct}%</td><td style='text-align:right;font-weight:600;'>${todayPct}%</td><td style='text-align:center;'>$arrow</td><td style='text-align:right;' class='$dClass'>${dSign}${delta7}%</td><td>$status</td></tr>")
    $rvIdx++
}
[void]$sb.AppendLine("</tbody></table></div>")

# ===== STYLE E: Privileged Access Exposure Gauge =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style E</span>")
[void]$sb.AppendLine("<div class='section-title'>Privileged Access Exposure Gauge</div>")
[void]$sb.AppendLine("<p class='note'>Semicircular gauge showing percentage of pending items that are privileged. Zones: 0-10% green, 10-25% amber, 25%+ red. Below: 7-day sparkline of privileged pending count.</p>")

$todayPrivPending = $today.PrivPending
$todayPending = [math]::Max(1, $today.Pending)
$privExposurePct = [math]::Round($todayPrivPending / $todayPending * 100, 1)
$gaugeColor = if ($privExposurePct -lt 10) { $colors.Green } elseif ($privExposurePct -lt 25) { $colors.Amber } else { $colors.Red }

# Semicircular gauge SVG
$gaugeW = 300; $gaugeH = 180; $cx = 150; $cy = 150; $r = 120
# Draw arc: sweep from 180deg (left) to 0deg (right) -- semicircle
# Angle for the value: 180 - (privExposurePct/100 * 180)
$angleRad = [math]::PI - ($privExposurePct / 100 * [math]::PI)
$needleX = [int]($cx + $r * [math]::Cos($angleRad))
$needleY = [int]($cy - $r * [math]::Abs([math]::Sin($angleRad)))

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
[void]$sb.AppendLine("<svg width='$gaugeW' height='$gaugeH' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Background arc zones -- draw as 3 colored arcs
# Green zone: 0-10% (angles 180 to 162 degrees)
# Amber zone: 10-25% (angles 162 to 135 degrees)
# Red zone: 25-100% (angles 135 to 0 degrees)
$zones = @(
    @{ StartPct = 0;  EndPct = 10;  Color = $colors.Green }
    @{ StartPct = 10; EndPct = 25;  Color = $colors.Amber }
    @{ StartPct = 25; EndPct = 100; Color = $colors.Red }
)
foreach ($z in $zones) {
    $a1 = [math]::PI - ($z.StartPct / 100 * [math]::PI)
    $a2 = [math]::PI - ($z.EndPct / 100 * [math]::PI)
    $x1 = [math]::Round($cx + $r * [math]::Cos($a1), 1)
    $y1 = [math]::Round($cy - [math]::Abs($r * [math]::Sin($a1)), 1)
    $x2 = [math]::Round($cx + $r * [math]::Cos($a2), 1)
    $y2 = [math]::Round($cy - [math]::Abs($r * [math]::Sin($a2)), 1)
    $largeArc = if (($z.EndPct - $z.StartPct) -gt 50) { 1 } else { 0 }
    [void]$sb.AppendLine("<path d='M $x1 $y1 A $r $r 0 $largeArc 1 $x2 $y2' stroke='$($z.Color)' stroke-width='24' fill='none' opacity='0.25'/>")
}

# Active arc from 0 to value
$valAngle = [math]::PI - ($privExposurePct / 100 * [math]::PI)
$vx = [math]::Round($cx + $r * [math]::Cos($valAngle), 1)
$vy = [math]::Round($cy - [math]::Abs($r * [math]::Sin($valAngle)), 1)
$startX = [math]::Round($cx - $r, 1); $startY = $cy
$valLargeArc = if ($privExposurePct -gt 50) { 1 } else { 0 }
[void]$sb.AppendLine("<path d='M $startX $startY A $r $r 0 $valLargeArc 1 $vx $vy' stroke='$gaugeColor' stroke-width='24' fill='none' stroke-linecap='round'/>")

# Needle line
[void]$sb.AppendLine("<line x1='$cx' y1='$cy' x2='$needleX' y2='$needleY' stroke='#1c2b3a' stroke-width='3' stroke-linecap='round'/>")
[void]$sb.AppendLine("<circle cx='$cx' cy='$cy' r='6' fill='#1c2b3a'/>")

# Center text
[void]$sb.AppendLine("<text x='$cx' y='$($cy - 30)' text-anchor='middle' font-size='28' font-weight='700' fill='$gaugeColor'>$todayPrivPending</text>")
[void]$sb.AppendLine("<text x='$cx' y='$($cy - 12)' text-anchor='middle' font-size='11' fill='#566'>privileged pending</text>")
[void]$sb.AppendLine("<text x='$cx' y='$($cy + 5)' text-anchor='middle' font-size='13' font-weight='600' fill='$gaugeColor'>${privExposurePct}% exposure</text>")

# Zone labels
[void]$sb.AppendLine("<text x='$($cx - $r - 5)' y='$($cy + 18)' text-anchor='middle' font-size='9' fill='$($colors.Green)'>0%</text>")
[void]$sb.AppendLine("<text x='$($cx + $r + 5)' y='$($cy + 18)' text-anchor='middle' font-size='9' fill='$($colors.Red)'>100%</text>")
[void]$sb.AppendLine("</svg>")

# 7-day sparkline of privileged pending
$privValues = @($dailyData | ForEach-Object { [double]$_.PrivPending })
$privSparkline = Build-Sparkline -Values $privValues -Color $gaugeColor -Width 200 -Height 30
[void]$sb.AppendLine("<div style='margin-top:8px;'>")
[void]$sb.AppendLine("<span style='font-size:11px;color:#566;margin-right:8px;'>7-Day Privileged Pending:</span>$privSparkline")
[void]$sb.AppendLine("</div>")
[void]$sb.AppendLine("</div></div>")


# ===== STYLE F: Scope Drift Monitor =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style F</span>")
[void]$sb.AppendLine("<div class='section-title'>Scope Drift Monitor -- Decisions vs Scope Growth</div>")
[void]$sb.AppendLine("<p class='note'>Overlays cumulative decisions made against cumulative scope growth. If scope grows faster than decisions, the gap is highlighted in red.</p>")

# Compute cumulative values
$cumDecisions = @(); $cumScope = @()
$runDecisions = 0; $runScope = 0
for ($i = 0; $i -lt $dailyData.Count; $i++) {
    $d = $dailyData[$i]
    if ($i -gt 0) {
        $prevD = $dailyData[$i - 1]
        $dailyDecided = ($d.Approved + $d.Revoked) - ($prevD.Approved + $prevD.Revoked)
        if ($dailyDecided -lt 0) { $dailyDecided = 0 }
        $runDecisions += $dailyDecided
        $runScope += ($d.ScopeAdded - $d.ScopeRemoved)
    }
    $cumDecisions += $runDecisions
    $cumScope += $runScope
}

$fW = 640; $fH = 200; $fPadL = 50; $fPadR = 20; $fPadT = 10; $fPadB = 40
$fPlotW = $fW - $fPadL - $fPadR; $fPlotH = $fH - $fPadT - $fPadB
$allVals = $cumDecisions + $cumScope
$fMax = [math]::Max(1, ($allVals | Measure-Object -Maximum).Maximum)

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
[void]$sb.AppendLine("<svg width='$fW' height='$fH' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Grid lines
for ($g = 0; $g -le 4; $g++) {
    $gVal = [int]($fMax * $g / 4)
    $gy = [int]($fPadT + $fPlotH - ($g / 4 * $fPlotH))
    [void]$sb.AppendLine("<line x1='$fPadL' y1='$gy' x2='$($fW - $fPadR)' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>")
    [void]$sb.AppendLine("<text x='$($fPadL - 5)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>$gVal</text>")
}

# Build path points
$decPts = @(); $scopePts = @()
for ($i = 0; $i -lt $dailyData.Count; $i++) {
    $px = [int]($fPadL + ($i / [math]::Max(1, $dailyData.Count - 1)) * $fPlotW)
    $decY = [int]($fPadT + $fPlotH - ($cumDecisions[$i] / $fMax * $fPlotH))
    $scopeY = [int]($fPadT + $fPlotH - ($cumScope[$i] / $fMax * $fPlotH))
    $decPts += "$px,$decY"
    $scopePts += "$px,$scopeY"
}

# Fill area between scope and decisions where scope > decisions (red gap)
$gapFill = "M $($scopePts[0] -replace ',',' ')"
for ($i = 1; $i -lt $scopePts.Count; $i++) { $gapFill += " L $($scopePts[$i] -replace ',',' ')" }
for ($i = $decPts.Count - 1; $i -ge 0; $i--) { $gapFill += " L $($decPts[$i] -replace ',',' ')" }
$gapFill += " Z"
[void]$sb.AppendLine("<path d='$gapFill' fill='$($colors.Red)' opacity='0.1'/>")

# Decision line (green area fill + line)
$decArea = "M $fPadL $($fPadT + $fPlotH)"
for ($i = 0; $i -lt $decPts.Count; $i++) { $decArea += " L $($decPts[$i] -replace ',',' ')" }
$decArea += " L $($fW - $fPadR) $($fPadT + $fPlotH) Z"
[void]$sb.AppendLine("<path d='$decArea' fill='$($colors.Green)' opacity='0.12'/>")
[void]$sb.AppendLine("<polyline points='$($decPts -join ' ')' stroke='$($colors.Green)' stroke-width='2.5' fill='none'/>")

# Scope line (amber)
$scopeArea = "M $fPadL $($fPadT + $fPlotH)"
for ($i = 0; $i -lt $scopePts.Count; $i++) { $scopeArea += " L $($scopePts[$i] -replace ',',' ')" }
$scopeArea += " L $($fW - $fPadR) $($fPadT + $fPlotH) Z"
[void]$sb.AppendLine("<path d='$scopeArea' fill='$($colors.Amber)' opacity='0.1'/>")
[void]$sb.AppendLine("<polyline points='$($scopePts -join ' ')' stroke='$($colors.Amber)' stroke-width='2.5' fill='none' stroke-dasharray='6,3'/>")

# Data point dots
for ($i = 0; $i -lt $dailyData.Count; $i++) {
    $parts = $decPts[$i] -split ','
    [void]$sb.AppendLine("<circle cx='$($parts[0])' cy='$($parts[1])' r='3' fill='$($colors.Green)'/>")
    $parts2 = $scopePts[$i] -split ','
    [void]$sb.AppendLine("<circle cx='$($parts2[0])' cy='$($parts2[1])' r='3' fill='$($colors.Amber)'/>")
}

# X-axis day labels
for ($i = 0; $i -lt $dailyData.Count; $i++) {
    $lx = [int]($fPadL + ($i / [math]::Max(1, $dailyData.Count - 1)) * $fPlotW)
    [void]$sb.AppendLine("<text x='$lx' y='$($fH - 5)' text-anchor='middle' font-size='9' fill='#566'>$($dailyData[$i].DayLabel)</text>")
}

# Legend
[void]$sb.AppendLine("<line x1='$($fPadL + 10)' y1='$($fPadT + 3)' x2='$($fPadL + 30)' y2='$($fPadT + 3)' stroke='$($colors.Green)' stroke-width='2.5'/>")
[void]$sb.AppendLine("<text x='$($fPadL + 34)' y='$($fPadT + 7)' font-size='10' fill='#1c2b3a'>Cumulative Decisions</text>")
[void]$sb.AppendLine("<line x1='$($fPadL + 180)' y1='$($fPadT + 3)' x2='$($fPadL + 200)' y2='$($fPadT + 3)' stroke='$($colors.Amber)' stroke-width='2.5' stroke-dasharray='6,3'/>")
[void]$sb.AppendLine("<text x='$($fPadL + 204)' y='$($fPadT + 7)' font-size='10' fill='#1c2b3a'>Cumulative Scope Drift</text>")

# Drift status callout
$finalDec = $cumDecisions[$cumDecisions.Count - 1]
$finalScope = $cumScope[$cumScope.Count - 1]
$driftStatus = if ($finalScope -gt $finalDec) { 'SCOPE OUTPACING DECISIONS' } else { 'Decisions keeping pace' }
$driftColor = if ($finalScope -gt $finalDec) { $colors.Red } else { $colors.Green }
[void]$sb.AppendLine("<text x='$($fW - $fPadR)' y='$($fPadT + 20)' text-anchor='end' font-size='10' font-weight='600' fill='$driftColor'>$driftStatus</text>")

[void]$sb.AppendLine("</svg>")
[void]$sb.AppendLine("</div></div>")


# ===== STYLE G: Rubber-Stamp Risk Detector =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style G</span>")
[void]$sb.AppendLine("<div class='section-title'>Rubber-Stamp Risk Detector -- Approval Ratio Analysis</div>")
[void]$sb.AppendLine("<p class='note'>Horizontal lollipop chart per reviewer. Dot position = approval ratio (Approved / Decided * 100). Circle size = items decided. Dashed threshold at 95%.</p>")

$gW = 700; $gH = 30 + ($reviewers.Count * 40); $gPadL = 120; $gPadR = 120; $gPlotW = $gW - $gPadL - $gPadR

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
[void]$sb.AppendLine("<svg width='$gW' height='$gH' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Header line
[void]$sb.AppendLine("<text x='$($gPadL + $gPlotW / 2)' y='14' text-anchor='middle' font-size='10' fill='#888'>Approval Ratio (%)</text>")

# Scale markers at 0, 25, 50, 75, 95, 100
$scaleVals = @(0, 25, 50, 75, 95, 100)
foreach ($sv in $scaleVals) {
    $sx = [int]($gPadL + ($sv / 100 * $gPlotW))
    [void]$sb.AppendLine("<line x1='$sx' y1='20' x2='$sx' y2='$($gH - 5)' stroke='#e3e9f0' stroke-width='1'/>")
    [void]$sb.AppendLine("<text x='$sx' y='28' text-anchor='middle' font-size='8' fill='#aaa'>${sv}%</text>")
}

# 95% threshold dashed line
$thresh95x = [int]($gPadL + (95 / 100 * $gPlotW))
[void]$sb.AppendLine("<line x1='$thresh95x' y1='20' x2='$thresh95x' y2='$($gH - 5)' stroke='$($colors.Red)' stroke-width='1.5' stroke-dasharray='5,3'/>")
[void]$sb.AppendLine("<text x='$($thresh95x + 3)' y='28' font-size='8' fill='$($colors.Red)'>95% threshold</text>")

$todayReviewers = $dailyData[6].Reviewers
$ri = 0
foreach ($rv in $todayReviewers) {
    $decided = $rv.Approved + $rv.Revoked
    $approvalRatio = if ($decided -gt 0) { [math]::Round($rv.Approved / $decided * 100, 1) } else { 0 }
    $yPos = 38 + ($ri * 40)
    $rvName = ConvertTo-SPHtmlSafe $rv.Name

    # Reviewer label
    [void]$sb.AppendLine("<text x='$($gPadL - 8)' y='$($yPos + 5)' text-anchor='end' font-size='11' font-weight='600' fill='#1c2b3a'>$rvName</text>")

    # Lollipop stick
    $dotX = [int]($gPadL + ($approvalRatio / 100 * $gPlotW))
    [void]$sb.AppendLine("<line x1='$gPadL' y1='$yPos' x2='$dotX' y2='$yPos' stroke='#ccc' stroke-width='2'/>")

    # Dot size proportional to decided items (min 6, max 16)
    $dotR = [math]::Max(6, [math]::Min(16, [int]($decided / 2)))
    $dotColor = if ($approvalRatio -ge 100) { $colors.Red } elseif ($approvalRatio -ge 95) { $colors.Amber } else { $colors.Green }
    [void]$sb.AppendLine("<circle cx='$dotX' cy='$yPos' r='$dotR' fill='$dotColor' opacity='0.85'/>")
    [void]$sb.AppendLine("<text x='$dotX' y='$($yPos + 4)' text-anchor='middle' font-size='8' font-weight='700' fill='#fff'>$decided</text>")

    # Badge
    $badgeX = $gW - $gPadR + 10
    if ($decided -eq 0) {
        [void]$sb.AppendLine("<text x='$badgeX' y='$($yPos + 4)' font-size='9' fill='#888'>NO DECISIONS</text>")
    } elseif ($approvalRatio -ge 100) {
        [void]$sb.AppendLine("<rect x='$badgeX' y='$($yPos - 8)' width='90' height='16' rx='8' fill='$($colors.Red)'/>")
        [void]$sb.AppendLine("<text x='$($badgeX + 45)' y='$($yPos + 4)' text-anchor='middle' font-size='8' font-weight='700' fill='#fff'>RUBBER STAMP</text>")
    } elseif ($approvalRatio -ge 95) {
        [void]$sb.AppendLine("<rect x='$badgeX' y='$($yPos - 8)' width='62' height='16' rx='8' fill='$($colors.Amber)'/>")
        [void]$sb.AppendLine("<text x='$($badgeX + 31)' y='$($yPos + 4)' text-anchor='middle' font-size='8' font-weight='700' fill='#fff'>WARNING</text>")
    } else {
        [void]$sb.AppendLine("<text x='$badgeX' y='$($yPos + 4)' font-size='9' fill='$($colors.Green)'>$($approvalRatio)%</text>")
    }
    $ri++
}

[void]$sb.AppendLine("</svg>")
[void]$sb.AppendLine("</div></div>")


# ===== STYLE H: Reviewer Activity Heatmap =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style H</span>")
[void]$sb.AppendLine("<div class='section-title'>Reviewer Activity Heatmap -- 7-Day Decision Intensity</div>")
[void]$sb.AppendLine("<p class='note'>Rows = reviewers, Columns = days. Cell color intensity = decisions made that day (daily delta). Five-level blue scale. Inactive reviewers highlighted in light red.</p>")

$hCellW = 70; $hCellH = 32; $hLabelW = 120
$hTotalW = $hLabelW + ($dailyData.Count * $hCellW) + 10
$hTotalH = 30 + ($reviewers.Count * $hCellH) + 5
$heatColors = @('#f0f2f5', '#c6dbef', '#6baed6', '#2171b5', '#084594')

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;overflow-x:auto;'>")
[void]$sb.AppendLine("<svg width='$hTotalW' height='$hTotalH' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Column headers (day labels)
for ($i = 0; $i -lt $dailyData.Count; $i++) {
    $hx = $hLabelW + ($i * $hCellW) + ($hCellW / 2)
    [void]$sb.AppendLine("<text x='$hx' y='16' text-anchor='middle' font-size='9' font-weight='600' fill='#566'>$($dailyData[$i].DayLabel)</text>")
}

# For each reviewer, compute daily deltas
$rvIdx = 0
foreach ($rv in $reviewers) {
    $hy = 24 + ($rvIdx * $hCellH)
    $rvName = ConvertTo-SPHtmlSafe $rv.Name
    $totalActivity = 0

    # Compute deltas for this reviewer across days
    $deltas = @()
    for ($i = 0; $i -lt $dailyData.Count; $i++) {
        $rvDay = $dailyData[$i].Reviewers | Where-Object { $_.Name -eq $rv.Name }
        $todayDec = if ($rvDay) { $rvDay.Approved + $rvDay.Revoked } else { 0 }
        if ($i -gt 0) {
            $rvPrev = $dailyData[$i - 1].Reviewers | Where-Object { $_.Name -eq $rv.Name }
            $prevDec = if ($rvPrev) { $rvPrev.Approved + $rvPrev.Revoked } else { 0 }
            $delta = [math]::Max(0, $todayDec - $prevDec)
        } else {
            $delta = $todayDec
        }
        $deltas += $delta
        $totalActivity += $delta
    }

    # Row background for inactive reviewers
    if ($totalActivity -eq 0) {
        [void]$sb.AppendLine("<rect x='0' y='$hy' width='$hTotalW' height='$hCellH' fill='#fdecec' opacity='0.5'/>")
    }

    # Reviewer label
    [void]$sb.AppendLine("<text x='$($hLabelW - 8)' y='$($hy + $hCellH / 2 + 4)' text-anchor='end' font-size='11' font-weight='600' fill='#1c2b3a'>$rvName</text>")

    # Heatmap cells
    $maxDelta = ($deltas | Measure-Object -Maximum).Maximum
    if ($maxDelta -eq 0) { $maxDelta = 1 }
    for ($i = 0; $i -lt $deltas.Count; $i++) {
        $cx = $hLabelW + ($i * $hCellW)
        $val = $deltas[$i]
        # Map to 0-4 level
        $level = [math]::Min(4, [int][math]::Floor($val / $maxDelta * 4.99))
        if ($val -eq 0) { $level = 0 }
        $cellColor = $heatColors[$level]
        [void]$sb.AppendLine("<rect x='$($cx + 2)' y='$($hy + 2)' width='$($hCellW - 4)' height='$($hCellH - 4)' rx='3' fill='$cellColor' stroke='#e3e9f0' stroke-width='1'/>")
        if ($val -gt 0) {
            $textColor = if ($level -ge 3) { '#fff' } else { '#1c2b3a' }
            [void]$sb.AppendLine("<text x='$($cx + $hCellW / 2)' y='$($hy + $hCellH / 2 + 4)' text-anchor='middle' font-size='10' font-weight='600' fill='$textColor'>$val</text>")
        }
    }
    $rvIdx++
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


# ===== STYLE I: Workload Distribution Treemap =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style I</span>")
[void]$sb.AppendLine("<div class='section-title'>Workload Distribution Treemap -- Reviewer Item Volume</div>")
[void]$sb.AppendLine("<p class='note'>Each rectangle = a reviewer, area proportional to their total items. Color by completion: green >=90%, amber 50-89%, red &lt;50%.</p>")

$iW = 700; $iH = 200
$todayRvs = $dailyData[6].Reviewers | Sort-Object { -$_.Total }
$totalAllItems = ($todayRvs | Measure-Object -Property Total -Sum).Sum
if ($totalAllItems -eq 0) { $totalAllItems = 1 }

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
[void]$sb.AppendLine("<svg width='$iW' height='$iH' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Simple strip treemap: lay out rectangles left to right, wrapping into rows
$xPos = 0; $yPos = 0; $rowH = $iH
foreach ($rv in $todayRvs) {
    $fraction = $rv.Total / $totalAllItems
    $rectW = [int][math]::Max(40, [math]::Round($fraction * $iW))
    # Ensure we don't overflow
    if ($xPos + $rectW -gt $iW) { $rectW = $iW - $xPos }
    if ($rectW -le 0) { continue }

    $rvCompClamped = [math]::Max(0, [math]::Min(100, $rv.Completion))
    $tmColor = if ($rvCompClamped -ge 90) { $colors.Green } elseif ($rvCompClamped -ge 50) { $colors.Amber } else { $colors.Red }
    $rvName = ConvertTo-SPHtmlSafe $rv.Name

    [void]$sb.AppendLine("<rect x='$xPos' y='$yPos' width='$rectW' height='$rowH' fill='$tmColor' opacity='0.2' stroke='#fff' stroke-width='2'/>")
    [void]$sb.AppendLine("<rect x='$xPos' y='$yPos' width='$rectW' height='$rowH' fill='$tmColor' opacity='0.65' stroke='#fff' stroke-width='2' rx='4'/>")

    # Label inside rectangle
    $labelFontSize = if ($rectW -gt 100) { 12 } else { 10 }
    $midX = $xPos + ($rectW / 2)
    $midY = $yPos + ($rowH / 2)
    [void]$sb.AppendLine("<text x='$midX' y='$($midY - 10)' text-anchor='middle' font-size='$labelFontSize' font-weight='700' fill='#fff'>$rvName</text>")
    [void]$sb.AppendLine("<text x='$midX' y='$($midY + 8)' text-anchor='middle' font-size='11' fill='#fff'>$($rv.Total) items</text>")
    [void]$sb.AppendLine("<text x='$midX' y='$($midY + 24)' text-anchor='middle' font-size='10' fill='#fff'>$($rvCompClamped)%</text>")

    $xPos += $rectW
}

[void]$sb.AppendLine("</svg>")
[void]$sb.AppendLine("</div></div>")


# ===== STYLE J: Completion Projection vs Deadline =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style J</span>")
[void]$sb.AppendLine("<div class='section-title'>Completion Projection vs Deadline</div>")
[void]$sb.AppendLine("<p class='note'>Solid line = actual completion % over 7 days. Dashed = linear projection from last 3 days velocity. Vertical red line = deadline. Green fill if on track, red if shortfall projected.</p>")

$jW = 700; $jH = 220; $jPadL = 50; $jPadR = 60; $jPadT = 20; $jPadB = 40
$jPlotW = $jW - $jPadL - $jPadR; $jPlotH = $jH - $jPadT - $jPadB
$completionVals = @($dailyData | ForEach-Object { $_.CompletionPct })

# Velocity from last 3 days
$vel3 = ($completionVals[6] - $completionVals[4]) / 2
if ($vel3 -lt 0) { $vel3 = 0 }

# Project forward 7 more days
$projectionDays = 7
$deadlineDayIdx = 5  # 5 days from today = day index 11 on the chart (6+5)
$totalDays = 7 + $projectionDays  # 14 total x-axis points

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
[void]$sb.AppendLine("<svg width='$jW' height='$jH' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Y-axis gridlines (0-100%)
for ($p = 0; $p -le 100; $p += 25) {
    $yy = [int]($jPadT + $jPlotH - ($p / 100 * $jPlotH))
    [void]$sb.AppendLine("<line x1='$jPadL' y1='$yy' x2='$($jW - $jPadR)' y2='$yy' stroke='#e3e9f0' stroke-width='1'/>")
    [void]$sb.AppendLine("<text x='$($jPadL - 5)' y='$($yy + 4)' text-anchor='end' font-size='9' fill='#888'>${p}%</text>")
}

# 100% target line
$y100 = [int]($jPadT + $jPlotH - (100 / 100 * $jPlotH))
[void]$sb.AppendLine("<line x1='$jPadL' y1='$y100' x2='$($jW - $jPadR)' y2='$y100' stroke='$($colors.Green)' stroke-width='1' stroke-dasharray='3,3' opacity='0.5'/>")

# Actual completion line
$actPts = @()
for ($i = 0; $i -lt 7; $i++) {
    $ax = [int]($jPadL + ($i / [math]::Max(1, $totalDays - 1)) * $jPlotW)
    $ay = [int]($jPadT + $jPlotH - ($completionVals[$i] / 100 * $jPlotH))
    $actPts += "$ax,$ay"
}

# Fill under actual line
$actFill = "M $jPadL $($jPadT + $jPlotH)"
foreach ($pt in $actPts) { $actFill += " L $($pt -replace ',',' ')" }
$lastActParts = $actPts[$actPts.Count - 1] -split ','
$actFill += " L $($lastActParts[0]) $($jPadT + $jPlotH) Z"
[void]$sb.AppendLine("<path d='$actFill' fill='#336699' opacity='0.1'/>")
[void]$sb.AppendLine("<polyline points='$($actPts -join ' ')' stroke='#336699' stroke-width='2.5' fill='none'/>")

# Data dots for actual
foreach ($pt in $actPts) {
    $parts = $pt -split ','
    [void]$sb.AppendLine("<circle cx='$($parts[0])' cy='$($parts[1])' r='3' fill='#336699'/>")
}

# Projection line (dashed)
$projPts = @($actPts[$actPts.Count - 1])
$lastPct = $completionVals[6]
for ($i = 1; $i -le $projectionDays; $i++) {
    $projPct = [math]::Min(100, $lastPct + ($vel3 * $i))
    $px = [int]($jPadL + ((6 + $i) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
    $py = [int]($jPadT + $jPlotH - ($projPct / 100 * $jPlotH))
    $projPts += "$px,$py"
}

# Determine if projection hits 100% before deadline
$projAtDeadline = [math]::Min(100, $lastPct + ($vel3 * $deadlineDayIdx))
$hitsTarget = $projAtDeadline -ge 99.5
$projFillColor = if ($hitsTarget) { $colors.Green } else { $colors.Red }

# Fill under projection
$projFill = "M $($lastActParts[0]) $($jPadT + $jPlotH)"
foreach ($pt in $projPts) { $projFill += " L $($pt -replace ',',' ')" }
$lastProjParts = $projPts[$projPts.Count - 1] -split ','
$projFill += " L $($lastProjParts[0]) $($jPadT + $jPlotH) Z"
[void]$sb.AppendLine("<path d='$projFill' fill='$projFillColor' opacity='0.08'/>")
[void]$sb.AppendLine("<polyline points='$($projPts -join ' ')' stroke='$projFillColor' stroke-width='2' fill='none' stroke-dasharray='6,4'/>")

# Deadline vertical line
$deadlineX = [int]($jPadL + ((6 + $deadlineDayIdx) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
[void]$sb.AppendLine("<line x1='$deadlineX' y1='$jPadT' x2='$deadlineX' y2='$($jPadT + $jPlotH)' stroke='$($colors.Red)' stroke-width='2' stroke-dasharray='4,3'/>")
[void]$sb.AppendLine("<text x='$($deadlineX + 4)' y='$($jPadT + 14)' font-size='9' font-weight='600' fill='$($colors.Red)'>DEADLINE</text>")

# X-axis labels: days 1-7 actual, then +1 to +7 projected
for ($i = 0; $i -lt 7; $i++) {
    $lx = [int]($jPadL + ($i / [math]::Max(1, $totalDays - 1)) * $jPlotW)
    [void]$sb.AppendLine("<text x='$lx' y='$($jH - 8)' text-anchor='middle' font-size='8' fill='#566'>$($dailyData[$i].DayLabel)</text>")
}
for ($i = 1; $i -le $projectionDays; $i++) {
    $lx = [int]($jPadL + ((6 + $i) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
    [void]$sb.AppendLine("<text x='$lx' y='$($jH - 8)' text-anchor='middle' font-size='8' fill='#aaa'>+${i}d</text>")
}

# Callout text
$projRounded = [math]::Round($projAtDeadline, 1)
$calloutText = if ($hitsTarget) { "ON TRACK: projected $($projRounded)% at deadline" } else { "AT RISK: projected only $($projRounded)% at deadline (velocity: $([math]::Round($vel3,1))%/day)" }
$calloutColor = if ($hitsTarget) { $colors.Green } else { $colors.Red }
# Place callout at top-right of chart to avoid overlap with projection labels
[void]$sb.AppendLine("<text x='$($jW - $jPadR)' y='$($jPadT + 14)' text-anchor='end' font-size='10' font-weight='600' fill='$calloutColor'>$calloutText</text>")

# Legend
[void]$sb.AppendLine("<line x1='$($jPadL + 5)' y1='$($jPadT + 5)' x2='$($jPadL + 25)' y2='$($jPadT + 5)' stroke='#336699' stroke-width='2.5'/>")
[void]$sb.AppendLine("<text x='$($jPadL + 29)' y='$($jPadT + 9)' font-size='9' fill='#1c2b3a'>Actual</text>")
[void]$sb.AppendLine("<line x1='$($jPadL + 75)' y1='$($jPadT + 5)' x2='$($jPadL + 95)' y2='$($jPadT + 5)' stroke='$projFillColor' stroke-width='2' stroke-dasharray='6,4'/>")
[void]$sb.AppendLine("<text x='$($jPadL + 99)' y='$($jPadT + 9)' font-size='9' fill='#1c2b3a'>Projection</text>")

[void]$sb.AppendLine("</svg>")
[void]$sb.AppendLine("</div></div>")


# ===== STYLE K: Decision Velocity Leaderboard =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style K</span>")
[void]$sb.AppendLine("<div class='section-title'>Decision Velocity Leaderboard</div>")
[void]$sb.AppendLine("<p class='note'>Horizontal bar per reviewer: average items decided per active day. Bars segmented green=approved, red=revoked. Rank badges for top 3. Dashed line = team average.</p>")

# Compute per-reviewer velocity across 7 days
$rvVelocities = @()
foreach ($rv in $reviewers) {
    $totalDecisions = 0; $totalAppr = 0; $totalRevk = 0; $activeDays = 0
    for ($i = 0; $i -lt $dailyData.Count; $i++) {
        $rvDay = $dailyData[$i].Reviewers | Where-Object { $_.Name -eq $rv.Name }
        $dayDec = if ($rvDay) { $rvDay.Approved + $rvDay.Revoked } else { 0 }
        if ($i -gt 0) {
            $rvPrev = $dailyData[$i - 1].Reviewers | Where-Object { $_.Name -eq $rv.Name }
            $prevDec = if ($rvPrev) { $rvPrev.Approved + $rvPrev.Revoked } else { 0 }
            $delta = [math]::Max(0, $dayDec - $prevDec)
        } else {
            $delta = $dayDec
        }
        if ($delta -gt 0) { $activeDays++ }
        $totalDecisions += $delta
    }

    # Compute approval ratio from cumulative data across ALL days
    $totalAppr = 0; $totalRevk = 0
    foreach ($day in $dailyData) {
        $rvDay2 = $day.Reviewers | Where-Object { $_.Name -eq $rv.Name }
        if ($rvDay2) { $totalAppr += $rvDay2.Approved; $totalRevk += $rvDay2.Revoked }
    }
    $totalDec2 = $totalAppr + $totalRevk
    $apprRatio = if ($totalDec2 -gt 0) { $totalAppr / $totalDec2 } else { 0.8 }
    $totalAppr = [int]($totalDecisions * $apprRatio)
    $totalRevk = $totalDecisions - $totalAppr

    $velocity = if ($activeDays -gt 0) { [math]::Round($totalDecisions / $activeDays, 1) } else { 0 }
    $rvVelocities += @{
        Name = $rv.Name
        TotalDecisions = $totalDecisions
        ApprovedTotal = $totalAppr
        RevokedTotal = $totalRevk
        ActiveDays = $activeDays
        Velocity = $velocity
    }
}

# Sort by velocity descending
$rvVelocities = @($rvVelocities | Sort-Object { -$_.Velocity })
$maxVel = [math]::Max(1, ($rvVelocities | Measure-Object -Property Velocity -Maximum).Maximum)
$teamAvg = [math]::Round(($rvVelocities | Measure-Object -Property Velocity -Average).Average, 1)

$kW = 700; $kBarH = 32; $kH = 40 + ($rvVelocities.Count * ($kBarH + 12)); $kPadL = 140; $kPadR = 80
$kPlotW = $kW - $kPadL - $kPadR

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
[void]$sb.AppendLine("<svg width='$kW' height='$kH' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Team average dashed line
$avgX = [int]($kPadL + ($teamAvg / $maxVel * $kPlotW))
[void]$sb.AppendLine("<line x1='$avgX' y1='10' x2='$avgX' y2='$($kH - 10)' stroke='#336699' stroke-width='1.5' stroke-dasharray='5,3'/>")
[void]$sb.AppendLine("<text x='$($avgX + 3)' y='18' font-size='8' fill='#336699'>Avg: $teamAvg/day</text>")

$rankColors = @('#c5960c', '#888888', '#8b5e3c')
$rankLabels = @('#1', '#2', '#3')

$ki = 0
foreach ($rvv in $rvVelocities) {
    $yPos = 30 + ($ki * ($kBarH + 12))
    $rvName = ConvertTo-SPHtmlSafe $rvv.Name

    # Rank badge for top 3
    if ($ki -lt 3 -and $rvv.Velocity -gt 0) {
        [void]$sb.AppendLine("<circle cx='15' cy='$($yPos + $kBarH / 2)' r='12' fill='$($rankColors[$ki])'/>")
        [void]$sb.AppendLine("<text x='15' y='$($yPos + $kBarH / 2 + 4)' text-anchor='middle' font-size='9' font-weight='700' fill='#fff'>$($rankLabels[$ki])</text>")
    }

    # Reviewer name
    [void]$sb.AppendLine("<text x='$($kPadL - 8)' y='$($yPos + $kBarH / 2 + 4)' text-anchor='end' font-size='11' font-weight='600' fill='#1c2b3a'>$rvName</text>")

    if ($rvv.Velocity -eq 0) {
        # NOT STARTED flag
        [void]$sb.AppendLine("<rect x='$kPadL' y='$yPos' width='$kPlotW' height='$kBarH' fill='#f0f2f5' rx='4'/>")
        [void]$sb.AppendLine("<text x='$($kPadL + 10)' y='$($yPos + $kBarH / 2 + 4)' font-size='10' font-weight='600' fill='$($colors.Red)'>NOT STARTED</text>")
    } else {
        # Segmented bar
        $totalW = [int]($rvv.Velocity / $maxVel * $kPlotW)
        $apprW = [int]($rvv.ApprovedTotal / [math]::Max(1, $rvv.TotalDecisions) * $totalW)
        $revkW = $totalW - $apprW

        # Background track
        [void]$sb.AppendLine("<rect x='$kPadL' y='$yPos' width='$kPlotW' height='$kBarH' fill='#f0f2f5' rx='4'/>")
        # Approved segment
        [void]$sb.AppendLine("<rect x='$kPadL' y='$yPos' width='$apprW' height='$kBarH' fill='$($colors.Green)' rx='4'/>")
        # Revoked segment
        if ($revkW -gt 0) {
            [void]$sb.AppendLine("<rect x='$($kPadL + $apprW)' y='$yPos' width='$revkW' height='$kBarH' fill='$($colors.Red)' rx='0'/>")
        }

        # Velocity label
        [void]$sb.AppendLine("<text x='$($kPadL + $totalW + 6)' y='$($yPos + $kBarH / 2 + 4)' font-size='10' font-weight='600' fill='#1c2b3a'>$($rvv.Velocity)/day</text>")
    }
    $ki++
}

# Legend
$legY = $kH - 5
[void]$sb.AppendLine("<rect x='$kPadL' y='$($legY - 10)' width='12' height='12' rx='2' fill='$($colors.Green)'/>")
[void]$sb.AppendLine("<text x='$($kPadL + 16)' y='$legY' font-size='9' fill='#1c2b3a'>Approved</text>")
[void]$sb.AppendLine("<rect x='$($kPadL + 80)' y='$($legY - 10)' width='12' height='12' rx='2' fill='$($colors.Red)'/>")
[void]$sb.AppendLine("<text x='$($kPadL + 96)' y='$legY' font-size='9' fill='#1c2b3a'>Revoked</text>")

[void]$sb.AppendLine("</svg>")
[void]$sb.AppendLine("</div></div>")


# ===== STYLE L: Scope Waterfall =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style L</span>")
[void]$sb.AppendLine("<div class='section-title'>Scope Waterfall -- Daily Changes to Pending Items</div>")
[void]$sb.AppendLine("<p class='note'>Waterfall chart: starting bar = Day 1 pending. Each subsequent day shows scope added (green up), scope removed (red down), and items decided (blue down). Final bar = today's pending.</p>")

$lW = 700; $lH = 260; $lPadL = 50; $lPadR = 20; $lPadT = 20; $lPadB = 50
$lPlotW = $lW - $lPadL - $lPadR; $lPlotH = $lH - $lPadT - $lPadB

# Compute waterfall segments
$wfSegments = @()
# Start bar = Day 0 pending
$wfSegments += @{ Label = $dailyData[0].DayLabel; Type = 'start'; Value = $dailyData[0].Pending; RunTotal = $dailyData[0].Pending }

$runTotal = $dailyData[0].Pending
for ($i = 1; $i -lt $dailyData.Count; $i++) {
    $d = $dailyData[$i]; $prev = $dailyData[$i - 1]
    $scopeAdd = $d.ScopeAdded
    $scopeRem = $d.ScopeRemoved
    $decided = [math]::Max(0, ($d.Approved + $d.Revoked) - ($prev.Approved + $prev.Revoked))

    if ($scopeAdd -gt 0) {
        $wfSegments += @{ Label = ''; Type = 'up'; Value = $scopeAdd; RunTotal = $runTotal; Day = $d.DayLabel; Desc = "+$scopeAdd scope" }
        $runTotal += $scopeAdd
    }
    if ($scopeRem -gt 0) {
        $wfSegments += @{ Label = ''; Type = 'scope-down'; Value = $scopeRem; RunTotal = $runTotal; Day = $d.DayLabel; Desc = "-$scopeRem scope" }
        $runTotal -= $scopeRem
    }
    if ($decided -gt 0) {
        $wfSegments += @{ Label = ''; Type = 'decided'; Value = $decided; RunTotal = $runTotal; Day = $d.DayLabel; Desc = "-$decided decided" }
        $runTotal -= $decided
    }
}
# End bar = today's pending
$wfSegments += @{ Label = 'Today'; Type = 'end'; Value = $today.Pending; RunTotal = $today.Pending }

$allRunTotals = @($wfSegments | ForEach-Object { $_.RunTotal }) + @($wfSegments | ForEach-Object { $_.RunTotal + $_.Value })
$lMaxVal = [math]::Max(1, ($allRunTotals | Measure-Object -Maximum).Maximum)
$segCount = $wfSegments.Count
$segW = [math]::Max(8, [int][math]::Floor($lPlotW / ($segCount + 1)))
$barW = [int]($segW * 0.7)

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
[void]$sb.AppendLine("<svg width='$lW' height='$lH' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Y-axis gridlines
for ($g = 0; $g -le 4; $g++) {
    $gVal = [int]($lMaxVal * $g / 4)
    $gy = [int]($lPadT + $lPlotH - ($g / 4 * $lPlotH))
    [void]$sb.AppendLine("<line x1='$lPadL' y1='$gy' x2='$($lW - $lPadR)' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>")
    [void]$sb.AppendLine("<text x='$($lPadL - 5)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>$gVal</text>")
}

$prevBarTop = 0; $prevBarX = 0
for ($si = 0; $si -lt $wfSegments.Count; $si++) {
    $seg = $wfSegments[$si]
    $sx = $lPadL + ($si * $segW) + [int](($segW - $barW) / 2)
    $baseline = [int]($lPadT + $lPlotH)

    if ($seg.Type -eq 'start' -or $seg.Type -eq 'end') {
        $bh = [int]($seg.Value / $lMaxVal * $lPlotH)
        $by = $baseline - $bh
        $bColor = if ($seg.Type -eq 'start') { '#336699' } else { '#1f3a5f' }
        [void]$sb.AppendLine("<rect x='$sx' y='$by' width='$barW' height='$bh' fill='$bColor' rx='2'/>")
        [void]$sb.AppendLine("<text x='$($sx + $barW / 2)' y='$($by - 4)' text-anchor='middle' font-size='9' font-weight='600' fill='$bColor'>$($seg.Value)</text>")
        $prevBarTop = $by
    }
    elseif ($seg.Type -eq 'up') {
        # Green bar going up from runTotal
        $baseY = [int]($baseline - ($seg.RunTotal / $lMaxVal * $lPlotH))
        $bh = [math]::Max(3, [int]($seg.Value / $lMaxVal * $lPlotH))
        $by = $baseY - $bh
        [void]$sb.AppendLine("<rect x='$sx' y='$by' width='$barW' height='$bh' fill='$($colors.Green)' opacity='0.75' rx='2'/>")
        [void]$sb.AppendLine("<text x='$($sx + $barW / 2)' y='$($by - 3)' text-anchor='middle' font-size='8' fill='$($colors.Green)'>+$($seg.Value)</text>")
        $prevBarTop = $by
    }
    elseif ($seg.Type -eq 'scope-down') {
        $topY = [int]($baseline - ($seg.RunTotal / $lMaxVal * $lPlotH))
        $bh = [math]::Max(3, [int]($seg.Value / $lMaxVal * $lPlotH))
        [void]$sb.AppendLine("<rect x='$sx' y='$topY' width='$barW' height='$bh' fill='$($colors.Red)' opacity='0.75' rx='2'/>")
        [void]$sb.AppendLine("<text x='$($sx + $barW / 2)' y='$($topY - 3)' text-anchor='middle' font-size='8' fill='$($colors.Red)'>-$($seg.Value)</text>")
        $prevBarTop = $topY
    }
    elseif ($seg.Type -eq 'decided') {
        $topY = [int]($baseline - ($seg.RunTotal / $lMaxVal * $lPlotH))
        $bh = [math]::Max(3, [int]($seg.Value / $lMaxVal * $lPlotH))
        [void]$sb.AppendLine("<rect x='$sx' y='$topY' width='$barW' height='$bh' fill='#336699' opacity='0.75' rx='2'/>")
        [void]$sb.AppendLine("<text x='$($sx + $barW / 2)' y='$($topY - 3)' text-anchor='middle' font-size='8' fill='#336699'>-$($seg.Value)</text>")
        $prevBarTop = $topY
    }

    # Connector line to next segment
    if ($si -lt $wfSegments.Count - 1 -and $seg.Type -ne 'start') {
        $connX1 = $sx + $barW
        $connX2 = $lPadL + (($si + 1) * $segW) + [int](($segW - $barW) / 2)
        [void]$sb.AppendLine("<line x1='$connX1' y1='$prevBarTop' x2='$connX2' y2='$prevBarTop' stroke='#aaa' stroke-width='1' stroke-dasharray='3,2'/>")
    }

    $prevBarX = $sx
}

# X-axis: label start and end, plus day markers for grouped segments
[void]$sb.AppendLine("<text x='$($lPadL + $barW / 2)' y='$($lH - 10)' text-anchor='middle' font-size='9' font-weight='600' fill='#566'>$($dailyData[0].DayLabel)</text>")
$endX = $lPadL + (($wfSegments.Count - 1) * $segW) + ($barW / 2)
[void]$sb.AppendLine("<text x='$endX' y='$($lH - 10)' text-anchor='middle' font-size='9' font-weight='600' fill='#566'>Today</text>")

# Legend
$legY = $lH - 25
[void]$sb.AppendLine("<rect x='$($lPadL + 60)' y='$($legY - 10)' width='10' height='10' rx='2' fill='$($colors.Green)' opacity='0.75'/>")
[void]$sb.AppendLine("<text x='$($lPadL + 74)' y='$legY' font-size='9' fill='#1c2b3a'>Scope Added</text>")
[void]$sb.AppendLine("<rect x='$($lPadL + 155)' y='$($legY - 10)' width='10' height='10' rx='2' fill='$($colors.Red)' opacity='0.75'/>")
[void]$sb.AppendLine("<text x='$($lPadL + 169)' y='$legY' font-size='9' fill='#1c2b3a'>Scope Removed</text>")
[void]$sb.AppendLine("<rect x='$($lPadL + 265)' y='$($legY - 10)' width='10' height='10' rx='2' fill='#336699' opacity='0.75'/>")
[void]$sb.AppendLine("<text x='$($lPadL + 279)' y='$legY' font-size='9' fill='#1c2b3a'>Decided</text>")

[void]$sb.AppendLine("</svg>")
[void]$sb.AppendLine("</div></div>")


# ===== STYLE M: Reviewer Engagement Timeline =====
[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style M</span>")
[void]$sb.AppendLine("<div class='section-title'>Reviewer Engagement Timeline -- Gantt-Style Activity Map</div>")
[void]$sb.AppendLine("<p class='note'>Per reviewer: gray baseline = 7-day window. Blue bar = first-to-last active day. Markers: circle=first decision, diamond=50% completion, star=100% completion.</p>")

$mW = 700; $mRowH = 40; $mPadL = 140; $mPadR = 100
$mH = 40 + ($reviewers.Count * $mRowH)
$mPlotW = $mW - $mPadL - $mPadR

[void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
[void]$sb.AppendLine("<svg width='$mW' height='$mH' style='font-family:Segoe UI,Arial,sans-serif;'>")

# Column day headers
for ($i = 0; $i -lt $dailyData.Count; $i++) {
    $dx = [int]($mPadL + ($i / [math]::Max(1, $dailyData.Count - 1)) * $mPlotW)
    [void]$sb.AppendLine("<line x1='$dx' y1='20' x2='$dx' y2='$($mH - 5)' stroke='#f0f2f5' stroke-width='1'/>")
    [void]$sb.AppendLine("<text x='$dx' y='14' text-anchor='middle' font-size='9' fill='#888'>$($dailyData[$i].DayLabel)</text>")
}

$ri = 0
foreach ($rv in $reviewers) {
    $yCenter = 35 + ($ri * $mRowH)
    $rvName = ConvertTo-SPHtmlSafe $rv.Name

    # Compute per-day activity for this reviewer
    $firstActive = -1; $lastActive = -1; $halfDay = -1; $doneDay = -1
    for ($i = 0; $i -lt $dailyData.Count; $i++) {
        $rvDay = $dailyData[$i].Reviewers | Where-Object { $_.Name -eq $rv.Name }
        $dayDec = if ($rvDay) { $rvDay.Approved + $rvDay.Revoked } else { 0 }
        $dayCompletion = if ($rvDay) { $rvDay.Completion } else { 0 }
        if ($i -gt 0) {
            $rvPrev = $dailyData[$i - 1].Reviewers | Where-Object { $_.Name -eq $rv.Name }
            $prevDec = if ($rvPrev) { $rvPrev.Approved + $rvPrev.Revoked } else { 0 }
            $delta = $dayDec - $prevDec
        } else {
            $delta = $dayDec
        }
        if ($delta -gt 0) {
            if ($firstActive -eq -1) { $firstActive = $i }
            $lastActive = $i
        }
        if ($dayCompletion -ge 50 -and $halfDay -eq -1) { $halfDay = $i }
        if ($dayCompletion -ge 100 -and $doneDay -eq -1) { $doneDay = $i }
    }

    # Reviewer label
    [void]$sb.AppendLine("<text x='$($mPadL - 8)' y='$($yCenter + 4)' text-anchor='end' font-size='11' font-weight='600' fill='#1c2b3a'>$rvName</text>")

    # Gray baseline (full 7-day span)
    $lineX1 = $mPadL; $lineX2 = $mPadL + $mPlotW
    [void]$sb.AppendLine("<line x1='$lineX1' y1='$yCenter' x2='$lineX2' y2='$yCenter' stroke='#e3e9f0' stroke-width='6' stroke-linecap='round'/>")

    # Blue active span
    if ($firstActive -ge 0 -and $lastActive -ge 0) {
        $actX1 = [int]($mPadL + ($firstActive / [math]::Max(1, $dailyData.Count - 1)) * $mPlotW)
        $actX2 = [int]($mPadL + ($lastActive / [math]::Max(1, $dailyData.Count - 1)) * $mPlotW)
        # Ensure minimum bar width when firstActive == lastActive
        if ($actX2 -le $actX1) { $actX2 = $actX1 + 6 }
        [void]$sb.AppendLine("<line x1='$actX1' y1='$yCenter' x2='$actX2' y2='$yCenter' stroke='#336699' stroke-width='8' stroke-linecap='round'/>")

        # Circle marker at first decision
        [void]$sb.AppendLine("<circle cx='$actX1' cy='$yCenter' r='6' fill='#336699' stroke='#fff' stroke-width='1.5'/>")
    }

    # Diamond at 50% completion day
    if ($halfDay -ge 0) {
        $hx = [int]($mPadL + ($halfDay / [math]::Max(1, $dailyData.Count - 1)) * $mPlotW)
        [void]$sb.AppendLine("<polygon points='$hx,$($yCenter - 7) $($hx + 6),$yCenter $hx,$($yCenter + 7) $($hx - 6),$yCenter' fill='$($colors.Amber)' stroke='#fff' stroke-width='1'/>")
    }

    # Star at 100% completion day
    if ($doneDay -ge 0) {
        $stx = [int]($mPadL + ($doneDay / [math]::Max(1, $dailyData.Count - 1)) * $mPlotW)
        # Simple 5-pointed star as polygon
        $sr = 7; $sir = 3
        $starPts = ''
        for ($s = 0; $s -lt 5; $s++) {
            $outerAngle = [math]::PI / 2 + ($s * 2 * [math]::PI / 5)
            $innerAngle = $outerAngle + [math]::PI / 5
            $ox = [math]::Round($stx + $sr * [math]::Cos($outerAngle), 1)
            $oy = [math]::Round($yCenter - $sr * [math]::Sin($outerAngle), 1)
            $ix = [math]::Round($stx + $sir * [math]::Cos($innerAngle), 1)
            $iy = [math]::Round($yCenter - $sir * [math]::Sin($innerAngle), 1)
            $starPts += "$ox,$oy $ix,$iy "
        }
        [void]$sb.AppendLine("<polygon points='$($starPts.Trim())' fill='$($colors.Green)' stroke='#fff' stroke-width='1'/>")
    }

    # Status annotation -- don't flag as stalled if completion >= 90%
    $lastCompletion = 0
    for ($ci = $dailyData.Count - 1; $ci -ge 0; $ci--) {
        $rvCheck = $dailyData[$ci].Reviewers | Where-Object { $_.Name -eq $rv.Name }
        if ($rvCheck) { $lastCompletion = $rvCheck.Completion; break }
    }
    $statusText = if ($firstActive -eq -1) { '(not started)' }
                  elseif ($lastCompletion -ge 90) { '(finishing)' }
                  elseif ($lastActive -lt 4 -and $doneDay -eq -1) { '(stalled)' }
                  else { '(steady)' }
    $statusColor = if ($statusText -eq '(not started)') { $colors.Red }
                   elseif ($statusText -eq '(stalled)') { $colors.Amber }
                   elseif ($statusText -eq '(finishing)') { $colors.Green }
                   else { '#888' }
    [void]$sb.AppendLine("<text x='$($mW - $mPadR + 10)' y='$($yCenter + 4)' font-size='9' fill='$statusColor'>$statusText</text>")

    $ri++
}

# Legend at bottom
$legY = $mH - 5
[void]$sb.AppendLine("<circle cx='$($mPadL + 5)' cy='$($legY - 4)' r='4' fill='#336699'/>")
[void]$sb.AppendLine("<text x='$($mPadL + 14)' y='$legY' font-size='9' fill='#1c2b3a'>First Decision</text>")
[void]$sb.AppendLine("<polygon points='$($mPadL + 100),$($legY - 8) $($mPadL + 105),$($legY - 4) $($mPadL + 100),$legY $($mPadL + 95),$($legY - 4)' fill='$($colors.Amber)'/>")
[void]$sb.AppendLine("<text x='$($mPadL + 112)' y='$legY' font-size='9' fill='#1c2b3a'>50% Complete</text>")
$ssx = $mPadL + 200; $ssy = $legY - 4
$starLegPts = ''
for ($s = 0; $s -lt 5; $s++) {
    $outerAngle = [math]::PI / 2 + ($s * 2 * [math]::PI / 5)
    $innerAngle = $outerAngle + [math]::PI / 5
    $ox = [math]::Round($ssx + 5 * [math]::Cos($outerAngle), 1)
    $oy = [math]::Round($ssy - 5 * [math]::Sin($outerAngle), 1)
    $ix = [math]::Round($ssx + 2 * [math]::Cos($innerAngle), 1)
    $iy = [math]::Round($ssy - 2 * [math]::Sin($innerAngle), 1)
    $starLegPts += "$ox,$oy $ix,$iy "
}
[void]$sb.AppendLine("<polygon points='$($starLegPts.Trim())' fill='$($colors.Green)'/>")
[void]$sb.AppendLine("<text x='$($mPadL + 210)' y='$legY' font-size='9' fill='#1c2b3a'>100% Complete</text>")

[void]$sb.AppendLine("</svg>")
[void]$sb.AppendLine("</div></div>")


# ===== STYLE N: Cross-Campaign Risk Matrix =====
# Synthesize 3-4 campaigns with different characteristics
$campaigns = @(
    @{ Name = 'Q2 Entitlement Review'; Completion = $today.CompletionPct; Deadline = 5; Pending = $today.Pending; PrivPending = $today.PrivPending; StalledReviewers = 1; TotalReviewers = 5; Approved = $today.Approved; Revoked = $today.Revoked; Total = $today.Total }
    @{ Name = 'SOX Access Recertification'; Completion = 35.2; Deadline = 3; Pending = 89; PrivPending = 14; StalledReviewers = 3; TotalReviewers = 8; Approved = 32; Revoked = 6; Total = 127 }
    @{ Name = 'Privileged Account Review'; Completion = 78.5; Deadline = 12; Pending = 18; PrivPending = 18; StalledReviewers = 0; TotalReviewers = 3; Approved = 52; Revoked = 14; Total = 84 }
    @{ Name = 'Quarterly Role Mining Cleanup'; Completion = 92.1; Deadline = 1; Pending = 7; PrivPending = 2; StalledReviewers = 0; TotalReviewers = 4; Approved = 71; Revoked = 11; Total = 89 }
)

# Compute risk scores
foreach ($c in $campaigns) {
    $timeRisk = if ($c.Deadline -le 2) { 40 } elseif ($c.Deadline -le 5) { 25 } else { 10 }
    $completionRisk = [math]::Max(0, [int]((100 - $c.Completion) * 0.4))
    $privRisk = [math]::Min(25, [int]($c.PrivPending * 1.5))
    $stalledRisk = $c.StalledReviewers * 8
    $c.RiskScore = [math]::Min(100, $timeRisk + $completionRisk + $privRisk + $stalledRisk)
}

[void]$sb.AppendLine("<div class='section'>")
[void]$sb.AppendLine("<span class='style-label'>Style N</span>")
[void]$sb.AppendLine("<div class='section-title'>Cross-Campaign Risk Matrix</div>")
[void]$sb.AppendLine("<p class='note'>Synthesized multi-campaign view with composite risk scoring. Risk = f(deadline proximity, completion gap, privileged pending, stalled reviewers).</p>")

[void]$sb.AppendLine("<table class='risk-matrix'><thead><tr>")
[void]$sb.AppendLine("<th>Campaign</th><th style='text-align:center;'>Completion</th><th style='text-align:center;'>Progress</th><th style='text-align:center;'>Deadline</th><th style='text-align:center;'>Priv. Pending</th><th style='text-align:center;'>Stalled</th><th style='text-align:center;'>Risk Score</th>")
[void]$sb.AppendLine("</tr></thead><tbody>")

foreach ($c in $campaigns) {
    $cName = ConvertTo-SPHtmlSafe $c.Name

    # Mini donut SVG (40x40)
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

    # Deadline dot
    $dlColor = if ($c.Deadline -le 2) { $colors.Red } elseif ($c.Deadline -le 5) { $colors.Amber } else { $colors.Green }
    $dlSvg = "<svg width='16' height='16' style='vertical-align:middle;'><circle cx='8' cy='8' r='6' fill='$dlColor'/></svg>"
    $dlText = "$dlSvg <span style='font-weight:600;'>$($c.Deadline)d</span>"

    # Risk score bar
    $riskColor = if ($c.RiskScore -ge 60) { $colors.Red } elseif ($c.RiskScore -ge 35) { $colors.Amber } else { $colors.Green }
    $riskW = $c.RiskScore
    $riskBar = "<div style='display:inline-block;width:100px;height:14px;background:#e3e9f0;border-radius:7px;overflow:hidden;vertical-align:middle;'>"
    $riskBar += "<div style='width:${riskW}%;height:14px;background:$riskColor;border-radius:7px;display:inline-block;'></div></div>"
    $riskBar += " <span style='font-size:11px;font-weight:600;color:$riskColor;'>$($c.RiskScore)</span>"

    # Privileged pending
    $privColor = if ($c.PrivPending -gt 10) { $colors.Red } elseif ($c.PrivPending -gt 5) { $colors.Amber } else { '#1c2b3a' }

    # Stalled count
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

# Footer
[void]$sb.AppendLine("<p class='footer'>Daily Evidence V5 (Trend View) -- SAMPLE DATA | Generated: $genDate | SailPoint ISC Governance Toolkit</p>")
[void]$sb.AppendLine('</body></html>')

Write-SPHtmlFile -Path $htmlFile -Content $sb.ToString()

#endregion

Write-Host "  Generated: $htmlFile" -ForegroundColor Green
Write-Host ''
Write-Host '  Visualization styles included:' -ForegroundColor White
Write-Host '    Style A:  Horizontal bar charts (reviewer completion over 7 days)' -ForegroundColor DarkGray
Write-Host '    Style B:  Stacked progress bars (decision distribution day-by-day)' -ForegroundColor DarkGray
Write-Host '    Style B2: Vertical bar chart (items reviewed % + reviewer completion %)' -ForegroundColor DarkGray
Write-Host '    Style C:  Sparkline mini-charts (compact metric trends with current/prior/delta)' -ForegroundColor DarkGray
Write-Host '    Style D:  Table with delta arrows (per-reviewer numeric comparison + status)' -ForegroundColor DarkGray
Write-Host '    Style E:  Privileged access exposure gauge (semicircular SVG gauge)' -ForegroundColor DarkGray
Write-Host '    Style F:  Scope drift monitor (cumulative decisions vs scope growth)' -ForegroundColor DarkGray
Write-Host '    Style G:  Rubber-stamp risk detector (approval ratio lollipop chart)' -ForegroundColor DarkGray
Write-Host '    Style H:  Reviewer activity heatmap (7-day decision intensity grid)' -ForegroundColor DarkGray
Write-Host '    Style I:  Workload distribution treemap (reviewer item volume)' -ForegroundColor DarkGray
Write-Host '    Style J:  Completion projection vs deadline (line chart with projection)' -ForegroundColor DarkGray
Write-Host '    Style K:  Decision velocity leaderboard (segmented bar chart + ranks)' -ForegroundColor DarkGray
Write-Host '    Style L:  Scope waterfall (daily pending item changes)' -ForegroundColor DarkGray
Write-Host '    Style M:  Reviewer engagement timeline (Gantt-style activity map)' -ForegroundColor DarkGray
Write-Host '    Style N:  Cross-campaign risk matrix (multi-campaign risk table)' -ForegroundColor DarkGray
Write-Host ''

if ($OpenInBrowser) {
    if ($IsMacOS -or $env:OS -notmatch 'Windows') { & open $htmlFile } else { Start-Process $htmlFile }
}

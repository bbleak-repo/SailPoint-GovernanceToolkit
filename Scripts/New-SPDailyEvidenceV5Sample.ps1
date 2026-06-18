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
        $completion = [math]::Min(100, $rv.StartCompletion + ($rv.DailyGain * $dayIdx) + (Get-Random -Minimum -2 -Maximum 3))
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
'@

$sb = New-Object System.Text.StringBuilder 16384
[void]$sb.AppendLine("<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Daily Evidence V5 -- Trend Report (Sample)</title><style>$css</style></head><body>")

# Header
[void]$sb.AppendLine("<h1>Daily Certification Evidence Report (V5) -- Trend View</h1>")
[void]$sb.AppendLine("<p class='meta'>")
[void]$sb.AppendLine("Campaign: <strong>$(ConvertTo-SPHtmlSafe $campaignName)</strong><br>")
[void]$sb.AppendLine("Period: Last 7 days ($($dailyData[0].Date) to $($dailyData[6].Date))<br>")
[void]$sb.AppendLine("Generated: $genDate<br>")
[void]$sb.AppendLine("<em>This is a SAMPLE report with synthetic data demonstrating four visualization styles.</em></p>")

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
[void]$sb.AppendLine("</div>")

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
    @{ Label = 'Overall Completion %'; Values = @($dailyData | ForEach-Object { $_.CompletionPct }); Color = '#336699' }
    @{ Label = 'Approved Items';       Values = @($dailyData | ForEach-Object { $_.Approved });      Color = $colors.Green }
    @{ Label = 'Revoked Items';        Values = @($dailyData | ForEach-Object { $_.Revoked });       Color = $colors.Red }
    @{ Label = 'Pending Items';        Values = @($dailyData | ForEach-Object { $_.Pending });       Color = $colors.Amber }
    @{ Label = 'Scope Added';          Values = @($dailyData | ForEach-Object { $_.ScopeAdded });    Color = '#336699' }
    @{ Label = 'Scope Removed';        Values = @($dailyData | ForEach-Object { $_.ScopeRemoved });  Color = $colors.Gray }
)

[void]$sb.AppendLine("<table><thead><tr><th style='width:180px;'>Metric</th><th style='width:160px;'>7-Day Trend</th><th style='width:80px;text-align:right;'>Current</th><th style='width:80px;text-align:right;'>7d Ago</th><th style='width:80px;text-align:right;'>Change</th></tr></thead><tbody>")
foreach ($m in $metrics) {
    $current = $m.Values[$m.Values.Count - 1]
    $prior   = $m.Values[0]
    $delta   = [math]::Round($current - $prior, 1)
    $dClass  = if ($delta -gt 0) { 'delta-up' } elseif ($delta -lt 0) { 'delta-down' } else { 'delta-flat' }
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

# Footer
[void]$sb.AppendLine("<p class='footer'>Daily Evidence V5 (Trend View) -- SAMPLE DATA | Generated: $genDate | SailPoint ISC Governance Toolkit</p>")
[void]$sb.AppendLine('</body></html>')

Write-SPHtmlFile -Path $htmlFile -Content $sb.ToString()

#endregion

Write-Host "  Generated: $htmlFile" -ForegroundColor Green
Write-Host ''
Write-Host '  Visualization styles included:' -ForegroundColor White
Write-Host '    Style A: Horizontal bar charts (reviewer completion over 7 days)' -ForegroundColor DarkGray
Write-Host '    Style B: Stacked progress bars (decision distribution day-by-day)' -ForegroundColor DarkGray
Write-Host '    Style C: Sparkline mini-charts (compact metric trends with current/prior/delta)' -ForegroundColor DarkGray
Write-Host '    Style D: Table with delta arrows (per-reviewer numeric comparison + status)' -ForegroundColor DarkGray
Write-Host ''

if ($OpenInBrowser) {
    if ($IsMacOS -or $env:OS -notmatch 'Windows') { & open $htmlFile } else { Start-Process $htmlFile }
}

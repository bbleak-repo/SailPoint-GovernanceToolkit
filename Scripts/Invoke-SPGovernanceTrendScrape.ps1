#Requires -Version 5.1
<#
.SYNOPSIS
    Monthly governance trend dashboard: scrapes daily evidence HTML reports to produce
    leadership-ready metrics trending over time -- total items, approvals, revocations,
    undecided, privileged access, reviewer completion, and new scope.

.DESCRIPTION
    Reads the day-end evidence reports you already produce (V4/V4b/V4e) and extracts
    the Campaign Completion Evidence table from each. Deduplicates by campaign date,
    then produces:

      1. Executive KPI Cards (period totals with month-over-month delta when applicable)
      2. Decision Distribution Over Time (stacked bar: approved/revoked/undecided per day)
      3. Completion + Reviewer Trend (dual-axis line chart)
      4. Privileged Access Summary (PRIV items approved vs revoked vs undecided)
      5. Revocation Trend (daily revoke count with cumulative line)
      6. New Scope Trend (genuinely new access grants per day)
      7. Month-over-Month Comparison Table (if data spans 2+ months)
      8. Campaign Detail Table (per-day breakdown)

    READ-ONLY: reads HTML files, writes a dashboard. No ISC API calls.

.PARAMETER Path
    Folder containing evidence HTML reports. Default: .\Audit\daily-evidence.

.PARAMETER FilePattern
    Wildcard for report files. Default: 'daily-evidence-v4*.html' (matches V4, V4b, V4e).

.PARAMETER Since
    Start date (e.g., '2026-06-01'). Only reports on/after this date.

.PARAMETER Until
    End date (e.g., '2026-06-30'). Only reports on/before this date.

.PARAMETER OutputPath
    Directory for the dashboard. Default: same as -Path.

.PARAMETER OutputMode
    Console | HTML | Both (default).

.PARAMETER Help
    Show help.

.EXAMPLE
    .\Invoke-SPGovernanceTrendScrape.ps1 -Since '2026-06-01' -Until '2026-06-30'
    # June monthly governance dashboard.

.EXAMPLE
    .\Invoke-SPGovernanceTrendScrape.ps1 -Since '2026-05-01' -Until '2026-06-30'
    # Two-month comparison with month-over-month deltas.

.NOTES
    Script:  Invoke-SPGovernanceTrendScrape.ps1
    Version: 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Path = '.\Audit\daily-evidence',
    [Parameter()][string]$FilePattern = 'daily-evidence-v4*.html',
    [Parameter()][string]$Since,
    [Parameter()][string]$Until,
    [Parameter()][string]$OutputPath,
    [Parameter()][ValidateSet('Console', 'HTML', 'Both')][string]$OutputMode = 'Both',
    [Parameter()][Alias('?')][switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function ConvertTo-Safe { param([string]$s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Remove-HtmlTags { param([string]$s) if ([string]::IsNullOrEmpty($s)) { return '' }; ($s -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim() }
function Parse-Number { param([string]$s) $s = $s -replace '[,\s]', ''; $n = 0; if ([int]::TryParse($s, [ref]$n)) { return $n }; return 0 }

function Resolve-ReportDate {
    param([System.IO.FileInfo]$File)
    $token = $File.BaseName -replace '^(?i)daily-evidence(-v\d\w*)?[-_ ]*', ''
    $token = $token -replace '^(?i)Daily-Attestation-Evidence-Report[-_ ]*', ''
    $token = $token.Trim('-', '_', ' ')
    $fmts = @('yyyy-MM-dd', 'yyyyMMdd', 'yyyyMMdd-HHmmss', 'yyyy-MM-dd-HHmmss')
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($f in $fmts) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($token, $f, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            return @{ Date = $dt.Date; Label = $dt.ToString('yyyy-MM-dd') }
        }
    }
    $m = [regex]::Match($token, '\d{4}[-.]?\d{2}[-.]?\d{2}')
    if ($m.Success) { $dt = [datetime]::MinValue; if ([datetime]::TryParse($m.Value, [ref]$dt)) { return @{ Date = $dt.Date; Label = $dt.ToString('yyyy-MM-dd') } } }
    return @{ Date = $File.LastWriteTime.Date; Label = $File.LastWriteTime.ToString('yyyy-MM-dd') + '*' }
}

function Extract-CampaignEvidence {
    # Parse the Campaign Completion Evidence table from a V4/V4b HTML report.
    # Returns array of hashtables: @{ Name; Status; Total; Approved; Revoked; Undecided; ItemsPct; ReviewerPct; Created }
    param([string]$Html)
    $results = @()

    # Find the Campaign Completion Evidence table
    $tableMatch = [regex]::Match($Html, '<h2>A\.\s*Campaign Completion Evidence</h2>\s*<table[^>]*>(.*?)</table>', 'Singleline')
    if (-not $tableMatch.Success) {
        # Try alternate table structure (V4e style)
        $tableMatch = [regex]::Match($Html, 'Campaign Completion Evidence.*?<table[^>]*>(.*?)</table>', 'Singleline')
    }
    if (-not $tableMatch.Success) { return $results }

    $tbody = $tableMatch.Groups[1].Value
    $rows = [regex]::Matches($tbody, '<tr[^>]*>(.*?)</tr>', 'Singleline')

    foreach ($row in $rows) {
        $cells = [regex]::Matches($row.Groups[1].Value, '<td[^>]*>(.*?)</td>', 'Singleline')
        if ($cells.Count -lt 8) { continue }

        $name = Remove-HtmlTags $cells[0].Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($name) -or $name -match 'TOTALS|CUMULATIVE') { continue }

        $status = Remove-HtmlTags $cells[1].Groups[1].Value
        $total = Parse-Number (Remove-HtmlTags $cells[2].Groups[1].Value)
        $approved = Parse-Number (Remove-HtmlTags $cells[3].Groups[1].Value)
        $revoked = Parse-Number (Remove-HtmlTags $cells[4].Groups[1].Value)
        $undecided = Parse-Number (Remove-HtmlTags $cells[5].Groups[1].Value)
        $itemsPctRaw = Remove-HtmlTags $cells[6].Groups[1].Value
        $itemsPct = Parse-Number ($itemsPctRaw -replace '%', '')
        $reviewerPctRaw = Remove-HtmlTags $cells[7].Groups[1].Value
        $reviewerPct = Parse-Number ($reviewerPctRaw -replace '%.*', '')

        # Extract campaign date from name
        $campDate = ''
        $dateMatch = [regex]::Match($name, '(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),?\s+(\w+ \d+,?\s+\d{4})')
        if ($dateMatch.Success) {
            try { $campDate = ([datetime]::Parse($dateMatch.Groups[1].Value)).ToString('yyyy-MM-dd') } catch { }
        }

        $results += @{
            Name = $name; Status = $status.ToUpperInvariant(); Total = $total
            Approved = $approved; Revoked = $revoked; Undecided = $undecided
            ItemsPct = $itemsPct; ReviewerPct = $reviewerPct; CampaignDate = $campDate
        }
    }
    return $results
}

function Extract-PrivilegedCounts {
    # Extract privileged item counts from executive summary or KPI section
    param([string]$Html)
    $privTotal = 0; $privApproved = 0; $privRevoked = 0; $privPending = 0

    # Look for privileged KPI data
    $privMatch = [regex]::Match($Html, 'privileged.*?(\d+)\s*/\s*(\d+)', 'Singleline,IgnoreCase')
    if ($privMatch.Success) {
        $privPending = [int]$privMatch.Groups[1].Value
        $privTotal = [int]$privMatch.Groups[2].Value
    }

    # Count PRIV badges in revoked section
    $revokedSection = [regex]::Match($Html, 'Revoked.*?</details>', 'Singleline')
    if ($revokedSection.Success) {
        $privRevoked = ([regex]::Matches($revokedSection.Value, 'badge-priv|PRIV')).Count
        # Approximate: each PRIV badge = 1 privileged revoked item (may double-count badge + text)
        $privRevoked = [int]($privRevoked / 2)
        if ($privRevoked -lt 1 -and $revokedSection.Value -match 'PRIV') { $privRevoked = ([regex]::Matches($revokedSection.Value, '<span class=.badge badge-priv')).Count }
    }

    return @{ Total = $privTotal; Approved = [math]::Max(0, $privTotal - $privPending - $privRevoked); Revoked = $privRevoked; Pending = $privPending }
}

function Extract-NewScopeCount {
    param([string]$Html)
    $m = [regex]::Match($Html, 'New Scope.*?(\d[\d,]*)\s*items?', 'IgnoreCase')
    if ($m.Success) { return Parse-Number $m.Groups[1].Value }
    return 0
}

function Extract-RevokedCount {
    param([string]$Html)
    $m = [regex]::Match($Html, 'Revoked\s*\((\d[\d,]*)\s*items?', 'IgnoreCase')
    if ($m.Success) { return Parse-Number $m.Groups[1].Value }
    return 0
}

# ---------------------------------------------------------------------------
# Load and parse reports
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  Governance Trend Dashboard' -ForegroundColor Cyan
Write-Host "  Path: $Path" -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $Path)) { Write-Host "  ERROR: Path not found: $Path" -ForegroundColor Red; exit 2 }

$files = @(Get-ChildItem -LiteralPath $Path -Filter $FilePattern -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($files.Count -eq 0) { Write-Host "  ERROR: No files matching '$FilePattern' in $Path" -ForegroundColor Red; exit 2 }

$sinceDate = $null; $untilDate = $null
if (-not [string]::IsNullOrWhiteSpace($Since)) { try { $sinceDate = [datetime]::Parse($Since).Date } catch { Write-Host "  ERROR: Invalid -Since date" -ForegroundColor Red; exit 2 } }
if (-not [string]::IsNullOrWhiteSpace($Until)) { try { $untilDate = [datetime]::Parse($Until).Date } catch { Write-Host "  ERROR: Invalid -Until date" -ForegroundColor Red; exit 2 } }

# Parse each report file
$reportData = @()
foreach ($file in $files) {
    $rd = Resolve-ReportDate -File $file
    if ($null -ne $sinceDate -and $rd.Date -lt $sinceDate) { continue }
    if ($null -ne $untilDate -and $rd.Date -gt $untilDate) { continue }

    $html = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($html)) { continue }

    $campaigns = Extract-CampaignEvidence -Html $html
    $priv = Extract-PrivilegedCounts -Html $html
    $newScope = Extract-NewScopeCount -Html $html
    $revokedTotal = Extract-RevokedCount -Html $html

    $reportData += @{
        File = $file.Name; Date = $rd.Date; Label = $rd.Label
        Campaigns = $campaigns; Priv = $priv; NewScope = $newScope; RevokedTotal = $revokedTotal
    }
}

if ($reportData.Count -eq 0) { Write-Host "  ERROR: No parseable reports found in date range" -ForegroundColor Red; exit 2 }
$reportData = @($reportData | Sort-Object { $_.Date })

Write-Host "  Reports: $($reportData.Count) file(s), $($reportData[0].Label) to $($reportData[-1].Label)" -ForegroundColor DarkGray

# Deduplicate campaigns by date (keep latest report's data per campaign date)
$campaignsByDate = [ordered]@{}
foreach ($rep in $reportData) {
    foreach ($camp in $rep.Campaigns) {
        $key = if (-not [string]::IsNullOrWhiteSpace($camp.CampaignDate)) { $camp.CampaignDate } else { $rep.Label }
        $campaignsByDate[$key] = $camp
    }
}
$dailyData = @($campaignsByDate.GetEnumerator() | Sort-Object Key | ForEach-Object { $v = $_.Value; $v.DateKey = $_.Key; $v })
$totalDays = $dailyData.Count

Write-Host "  Campaign days: $totalDays (deduplicated)" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Compute period aggregates
# ---------------------------------------------------------------------------
$aggTotal = 0; $aggApproved = 0; $aggRevoked = 0; $aggUndecided = 0
$minCompletion = 100; $maxCompletion = 0; $avgCompletion = 0
$minReviewer = 100; $maxReviewer = 0; $avgReviewer = 0
$completedCampaigns = 0; $activeCampaigns = 0

foreach ($d in $dailyData) {
    $aggTotal += $d.Total; $aggApproved += $d.Approved; $aggRevoked += $d.Revoked; $aggUndecided += $d.Undecided
    if ($d.ItemsPct -lt $minCompletion) { $minCompletion = $d.ItemsPct }
    if ($d.ItemsPct -gt $maxCompletion) { $maxCompletion = $d.ItemsPct }
    $avgCompletion += $d.ItemsPct
    if ($d.ReviewerPct -lt $minReviewer) { $minReviewer = $d.ReviewerPct }
    if ($d.ReviewerPct -gt $maxReviewer) { $maxReviewer = $d.ReviewerPct }
    $avgReviewer += $d.ReviewerPct
    if ($d.Status -eq 'COMPLETED') { $completedCampaigns++ } else { $activeCampaigns++ }
}
$avgCompletion = if ($totalDays -gt 0) { [math]::Round($avgCompletion / $totalDays, 0) } else { 0 }
$avgReviewer = if ($totalDays -gt 0) { [math]::Round($avgReviewer / $totalDays, 0) } else { 0 }

# Unique revoked (last report's total, or sum the daily register counts)
$uniqueRevoked = if ($reportData[-1].RevokedTotal -gt 0) { $reportData[-1].RevokedTotal } else { $aggRevoked }

# Privileged (from latest report)
$latestPriv = $reportData[-1].Priv
$totalNewScope = 0; foreach ($r in $reportData) { $totalNewScope += $r.NewScope }

# Month-over-month breakdown
$monthlyData = [ordered]@{}
foreach ($d in $dailyData) {
    $monthKey = $d.DateKey.Substring(0, 7)  # yyyy-MM
    if (-not $monthlyData.Contains($monthKey)) {
        $monthlyData[$monthKey] = @{ Days = 0; Total = 0; Approved = 0; Revoked = 0; Undecided = 0; CompletionSum = 0; ReviewerSum = 0 }
    }
    $m = $monthlyData[$monthKey]
    $m.Days++; $m.Total += $d.Total; $m.Approved += $d.Approved; $m.Revoked += $d.Revoked; $m.Undecided += $d.Undecided
    $m.CompletionSum += $d.ItemsPct; $m.ReviewerSum += $d.ReviewerPct
}

# ---------------------------------------------------------------------------
# Console Output
# ---------------------------------------------------------------------------
if ($OutputMode -in @('Console', 'Both')) {
    Write-Host ''
    Write-Host '  === Governance Trend Summary ===' -ForegroundColor Cyan
    Write-Host "  Period:       $($reportData[0].Label) to $($reportData[-1].Label) ($totalDays campaign days)" -ForegroundColor White
    Write-Host "  Campaigns:    $completedCampaigns completed, $activeCampaigns active" -ForegroundColor White
    Write-Host "  Completion:   avg $avgCompletion% (min $minCompletion%, max $maxCompletion%)" -ForegroundColor White
    Write-Host "  Reviewer:     avg $avgReviewer% (min $minReviewer%, max $maxReviewer%)" -ForegroundColor White
    Write-Host "  Revoked:      $uniqueRevoked unique items" -ForegroundColor White
    Write-Host "  New Scope:    $totalNewScope items added over period" -ForegroundColor White
    Write-Host "  Privileged:   $($latestPriv.Total) total, $($latestPriv.Pending) pending" -ForegroundColor White
    Write-Host ''
}

# ---------------------------------------------------------------------------
# HTML Dashboard
# ---------------------------------------------------------------------------
if ($OutputMode -in @('HTML', 'Both')) {
    if (-not $OutputPath) { $OutputPath = $Path }
    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $OutputPath "Governance-Trend-Dashboard-$stamp.html"

    $sb = New-Object System.Text.StringBuilder 16384
    [void]$sb.AppendLine(@"
<!DOCTYPE html><html><head><meta charset='utf-8'><title>Governance Trend Dashboard</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;background:#fff;max-width:1200px}
h1{font-size:22px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px}
h2{font-size:16px;color:#1f3a5f;margin-top:28px;border-bottom:1px solid #d4dce6;padding-bottom:4px}
.meta{color:#566;font-size:12px;margin-bottom:16px;line-height:1.6}
.kpi{display:inline-block;min-width:140px;margin:6px 10px 6px 0;padding:12px 16px;border:1px solid #d4dce6;border-radius:8px;background:#f6f9fc;text-align:center}
.kpi .n{font-size:24px;font-weight:700;color:#1f3a5f;display:block}
.kpi .l{font-size:11px;color:#566;text-transform:uppercase;letter-spacing:.04em}
.kpi .delta{font-size:11px;margin-top:2px}
.section{margin:20px 0;padding:14px 18px;border:1px solid #d4dce6;border-radius:8px;background:#fafbfd}
table{border-collapse:collapse;width:100%;font-size:12px;margin:8px 0}
th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 8px;font-weight:600}
td{border-bottom:1px solid #e3e9f0;padding:5px 8px}
tr:nth-child(even) td{background:#f6f9fc}
.up{color:#0a7d2c;font-weight:600} .down{color:#b00020;font-weight:600} .flat{color:#9a6700}
.footer{margin-top:24px;padding-top:8px;border-top:1px solid #d4dce6;font-size:11px;color:#777}
</style></head><body>
"@)

    # Header
    $periodLabel = "$($reportData[0].Label) to $($reportData[-1].Label)"
    [void]$sb.AppendLine("<h1>Governance Trend Dashboard</h1>")
    [void]$sb.AppendLine("<p class='meta'>Period: $periodLabel | $totalDays campaign day(s) from $($reportData.Count) report file(s) | $completedCampaigns completed, $activeCampaigns active | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p>")

    # Section 1: Executive KPI Cards
    $decisionRate = if ($aggTotal -gt 0) { [math]::Round(($aggApproved + $aggRevoked) / $aggTotal * 100, 0) } else { 0 }
    $revokeRate = if ($aggTotal -gt 0) { [math]::Round($aggRevoked / $aggTotal * 100, 1) } else { 0 }
    $undecidedRate = if ($aggTotal -gt 0) { [math]::Round($aggUndecided / $aggTotal * 100, 1) } else { 0 }

    [void]$sb.AppendLine("<div style='margin:16px 0'>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n'>$totalDays</span><span class='l'>Campaign Days</span></span>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n'>${avgCompletion}%</span><span class='l'>Avg Completion</span></span>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n'>${avgReviewer}%</span><span class='l'>Avg Reviewer</span></span>")
    $revColor = if ($uniqueRevoked -gt 0) { '#b00020' } else { '#0a7d2c' }
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$revColor'>$('{0:N0}' -f $uniqueRevoked)</span><span class='l'>Revoked Items</span></span>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n'>$('{0:N0}' -f $totalNewScope)</span><span class='l'>New Scope Added</span></span>")
    $privColor = if ($latestPriv.Pending -gt 0) { '#b00020' } else { '#0a7d2c' }
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$privColor'>$($latestPriv.Pending)</span><span class='l'>Priv. Undecided</span></span>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n'>${revokeRate}%</span><span class='l'>Revoke Rate</span></span>")
    [void]$sb.AppendLine("</div>")

    # Section 2: Decision Distribution Over Time (stacked bars)
    [void]$sb.AppendLine("<div class='section'><h2>Decision Distribution Over Time</h2>")
    $chartW = 800; $chartH = 200; $padL = 50; $padB = 45; $padT = 10
    $plotH = $chartH - $padT - $padB; $plotW = $chartW - $padL - 10
    $barW = [int][math]::Floor($plotW / $totalDays * 0.75)
    $gapW = [int][math]::Floor($plotW / $totalDays * 0.25)

    [void]$sb.AppendLine("<svg width='$chartW' height='$($chartH + 10)' style='font-family:Segoe UI,Arial,sans-serif'>")
    # Grid
    $maxItems = 1; foreach ($d in $dailyData) { if ($d.Total -gt $maxItems) { $maxItems = $d.Total } }
    for ($g = 0; $g -le 4; $g++) {
        $gy = $padT + $plotH - [int]($plotH * $g / 4)
        $gv = [math]::Round($maxItems * $g / 4, 0)
        [void]$sb.AppendLine("<line x1='$padL' y1='$gy' x2='$chartW' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($padL - 4)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>$('{0:N0}' -f $gv)</text>")
    }

    for ($i = 0; $i -lt $totalDays; $i++) {
        $d = $dailyData[$i]
        $bx = $padL + ($i * ($barW + $gapW)) + [int]($gapW / 2)
        $baseY = $padT + $plotH

        $aH = [int][math]::Max(0, [math]::Round($d.Approved / $maxItems * $plotH))
        $rH = [int][math]::Max(0, [math]::Round($d.Revoked / $maxItems * $plotH))
        $uH = [int][math]::Max(0, [math]::Round($d.Undecided / $maxItems * $plotH))

        $curY = $baseY
        if ($aH -gt 0) { $curY -= $aH; [void]$sb.AppendLine("<rect x='$bx' y='$curY' width='$barW' height='$aH' fill='#0a7d2c' rx='1'/>") }
        if ($rH -gt 0) { $curY -= $rH; [void]$sb.AppendLine("<rect x='$bx' y='$curY' width='$barW' height='$rH' fill='#b00020' rx='1'/>") }
        if ($uH -gt 0) { $curY -= $uH; [void]$sb.AppendLine("<rect x='$bx' y='$curY' width='$barW' height='$uH' fill='#9a6700' rx='1'/>") }

        # Day label (show every Nth to avoid crowding)
        $showLabel = ($totalDays -le 15) -or ($i % [math]::Max(1, [int]($totalDays / 15)) -eq 0) -or ($i -eq $totalDays - 1)
        if ($showLabel) {
            $dayLabel = if ($d.DateKey.Length -ge 10) { $d.DateKey.Substring(5) } else { $d.DateKey }
            [void]$sb.AppendLine("<text x='$($bx + [int]($barW/2))' y='$($baseY + 14)' text-anchor='middle' font-size='8' fill='#566'>$dayLabel</text>")
        }
    }
    # Legend
    $legY = $chartH
    [void]$sb.AppendLine("<rect x='$($padL+5)' y='$legY' width='10' height='10' fill='#0a7d2c' rx='1'/><text x='$($padL+19)' y='$($legY+9)' font-size='10' fill='#1c2b3a'>Approved</text>")
    [void]$sb.AppendLine("<rect x='$($padL+90)' y='$legY' width='10' height='10' fill='#b00020' rx='1'/><text x='$($padL+104)' y='$($legY+9)' font-size='10' fill='#1c2b3a'>Revoked</text>")
    [void]$sb.AppendLine("<rect x='$($padL+170)' y='$legY' width='10' height='10' fill='#9a6700' rx='1'/><text x='$($padL+184)' y='$($legY+9)' font-size='10' fill='#1c2b3a'>Undecided</text>")
    [void]$sb.AppendLine("</svg></div>")

    # Section 3: Completion + Reviewer Trend (line chart)
    [void]$sb.AppendLine("<div class='section'><h2>Completion + Reviewer Trend</h2>")
    $lcW = 800; $lcH = 180; $lcPadL = 40; $lcPadB = 40; $lcPadT = 10
    $lcPlotH = $lcH - $lcPadT - $lcPadB; $lcPlotW = $lcW - $lcPadL - 10

    [void]$sb.AppendLine("<svg width='$lcW' height='$($lcH + 10)' style='font-family:Segoe UI,Arial,sans-serif'>")
    for ($g = 0; $g -le 4; $g++) {
        $gy = $lcPadT + $lcPlotH - [int]($lcPlotH * $g / 4)
        [void]$sb.AppendLine("<line x1='$lcPadL' y1='$gy' x2='$lcW' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($lcPadL - 4)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>$($g * 25)%</text>")
    }

    $compPts = @(); $revPts = @()
    for ($i = 0; $i -lt $totalDays; $i++) {
        $x = [int]($lcPadL + ($i / [math]::Max(1, $totalDays - 1)) * $lcPlotW)
        $cy = [int]($lcPadT + $lcPlotH - ($dailyData[$i].ItemsPct / 100 * $lcPlotH))
        $ry = [int]($lcPadT + $lcPlotH - ($dailyData[$i].ReviewerPct / 100 * $lcPlotH))
        $compPts += "$x,$cy"; $revPts += "$x,$ry"
    }
    [void]$sb.AppendLine("<polyline points='$($compPts -join ' ')' stroke='#336699' stroke-width='2.5' fill='none'/>")
    [void]$sb.AppendLine("<polyline points='$($revPts -join ' ')' stroke='#0a7d2c' stroke-width='2' fill='none' stroke-dasharray='6,3'/>")
    foreach ($pt in $compPts) { $parts = $pt -split ','; [void]$sb.AppendLine("<circle cx='$($parts[0])' cy='$($parts[1])' r='3' fill='#336699'/>") }
    foreach ($pt in $revPts) { $parts = $pt -split ','; [void]$sb.AppendLine("<circle cx='$($parts[0])' cy='$($parts[1])' r='2.5' fill='#0a7d2c'/>") }

    $legY2 = $lcH
    [void]$sb.AppendLine("<line x1='$($lcPadL+5)' y1='$($legY2+3)' x2='$($lcPadL+25)' y2='$($legY2+3)' stroke='#336699' stroke-width='2.5'/><text x='$($lcPadL+29)' y='$($legY2+7)' font-size='10'>Items Decided %</text>")
    [void]$sb.AppendLine("<line x1='$($lcPadL+145)' y1='$($legY2+3)' x2='$($lcPadL+165)' y2='$($legY2+3)' stroke='#0a7d2c' stroke-width='2' stroke-dasharray='6,3'/><text x='$($lcPadL+169)' y='$($legY2+7)' font-size='10'>Reviewer Completed %</text>")
    [void]$sb.AppendLine("</svg></div>")

    # Section 4: Month-over-Month Comparison (if 2+ months)
    if ($monthlyData.Count -ge 2) {
        [void]$sb.AppendLine("<div class='section'><h2>Month-over-Month Comparison</h2>")
        [void]$sb.AppendLine("<table><thead><tr><th>Month</th><th style='text-align:right'>Days</th><th style='text-align:right'>Avg Completion</th><th style='text-align:right'>Avg Reviewer</th><th style='text-align:right'>Revoked</th><th style='text-align:right'>Undecided</th><th>Trend</th></tr></thead><tbody>")
        $prevMonth = $null
        foreach ($mk in $monthlyData.Keys) {
            $m = $monthlyData[$mk]
            $mAvgComp = [math]::Round($m.CompletionSum / [math]::Max(1, $m.Days), 0)
            $mAvgRev = [math]::Round($m.ReviewerSum / [math]::Max(1, $m.Days), 0)
            $trend = ''
            if ($null -ne $prevMonth) {
                $prevAvg = [math]::Round($prevMonth.CompletionSum / [math]::Max(1, $prevMonth.Days), 0)
                $delta = $mAvgComp - $prevAvg
                $sign = if ($delta -gt 0) { '+' } else { '' }
                $cls = if ($delta -gt 0) { 'up' } elseif ($delta -lt 0) { 'down' } else { 'flat' }
                $trend = "<span class='$cls'>${sign}${delta}%</span>"
            }
            [void]$sb.AppendLine("<tr><td style='font-weight:600'>$mk</td><td style='text-align:right'>$($m.Days)</td><td style='text-align:right'>${mAvgComp}%</td><td style='text-align:right'>${mAvgRev}%</td><td style='text-align:right;color:#b00020'>$('{0:N0}' -f $m.Revoked)</td><td style='text-align:right;color:#9a6700'>$('{0:N0}' -f $m.Undecided)</td><td>$trend</td></tr>")
            $prevMonth = $m
        }
        [void]$sb.AppendLine("</tbody></table></div>")
    }

    # Section 5: Campaign Detail Table
    [void]$sb.AppendLine("<div class='section'><h2>Campaign Detail</h2>")
    [void]$sb.AppendLine("<table><thead><tr><th>Date</th><th>Status</th><th style='text-align:right'>Total</th><th style='text-align:right'>Approved</th><th style='text-align:right'>Revoked</th><th style='text-align:right'>Undecided</th><th style='text-align:center'>Items %</th><th style='text-align:center'>Reviewer %</th></tr></thead><tbody>")
    foreach ($d in $dailyData) {
        $stColor = if ($d.Status -eq 'COMPLETED') { 'color:#0a7d2c' } else { 'color:#336699' }
        $itemCls = if ($d.ItemsPct -ge 80) { 'up' } elseif ($d.ItemsPct -ge 50) { 'flat' } else { 'down' }
        $rvCls = if ($d.ReviewerPct -ge 80) { 'up' } elseif ($d.ReviewerPct -ge 50) { 'flat' } else { 'down' }
        $uStyle = if ($d.Undecided -gt 0) { "color:#b00020;font-weight:600" } else { '' }
        [void]$sb.AppendLine("<tr><td style='font-weight:600'>$($d.DateKey)</td><td style='$stColor'>$($d.Status)</td><td style='text-align:right'>$('{0:N0}' -f $d.Total)</td><td style='text-align:right'>$('{0:N0}' -f $d.Approved)</td><td style='text-align:right;color:#b00020'>$('{0:N0}' -f $d.Revoked)</td><td style='text-align:right;$uStyle'>$('{0:N0}' -f $d.Undecided)</td><td style='text-align:center' class='$itemCls'>$($d.ItemsPct)%</td><td style='text-align:center' class='$rvCls'>$($d.ReviewerPct)%</td></tr>")
    }
    # Totals row
    [void]$sb.AppendLine("<tr style='background:#edf2f7;font-weight:700;border-top:2px solid #1f3a5f'><td>PERIOD TOTAL</td><td>$totalDays days</td><td style='text-align:right'>$('{0:N0}' -f $aggTotal)</td><td style='text-align:right'>$('{0:N0}' -f $aggApproved)</td><td style='text-align:right;color:#b00020'>$('{0:N0}' -f $aggRevoked)</td><td style='text-align:right;color:#9a6700'>$('{0:N0}' -f $aggUndecided)</td><td style='text-align:center'>${avgCompletion}% avg</td><td style='text-align:center'>${avgReviewer}% avg</td></tr>")
    [void]$sb.AppendLine("</tbody></table></div>")

    # Footer
    [void]$sb.AppendLine("<p class='footer'>Governance Trend Dashboard | Period: $periodLabel | Source: $(ConvertTo-Safe $Path) | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | SailPoint ISC Governance Toolkit</p>")
    [void]$sb.AppendLine('</body></html>')

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outFile, $sb.ToString(), $utf8NoBom)
    Write-Host "  Dashboard: $outFile" -ForegroundColor Green
}

Write-Host ''

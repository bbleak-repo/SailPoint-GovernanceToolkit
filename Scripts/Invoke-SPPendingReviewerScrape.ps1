#Requires -Version 5.1
<#
.SYNOPSIS
    Ad-hoc analyzer: scrape a folder of daily evidence HTML reports and chart which reviewers
    keep showing up as Pending / Undecided. A bridge while the cache-based trending matures.

.DESCRIPTION
    Reads the "final" daily evidence HTML reports you already produce -- by default named
    Daily-Attestation-Evidence-Report-<date>.html, where <date> is auto-parsed from the filename
    (falling back to the file's LastWriteTime). For each report it finds every collapsible whose
    <summary> mentions "Pending" or "Undecided" (the day-end ACTIVE-campaign accountability list)
    and pulls the reviewer name from each table row. A reviewer is counted once per report.

    It then renders a self-contained HTML dashboard (inline SVG, no JavaScript -- Word/email safe):
      1. Chronic-Pending bars  -- per reviewer: appeared pending in X of N reports (%).
      2. Reviewer x Date heatmap (V7-style) -- which reviewer was pending on which day.
      3. Daily distinct-pending trend bars -- how many reviewers were pending each day.

    READ-ONLY: it reads HTML and writes a report; it never calls ISC and never mutates anything.

.PARAMETER Path
    Folder containing the daily evidence HTML reports. Default: .\Audit\daily-evidence.

.PARAMETER FilePattern
    Wildcard for the report files. Default: 'Daily-Attestation-Evidence-Report-*.html'.

.PARAMETER Since
    Optional date string (e.g. '2026-06-01'). Only reports on/after this date are included.

.PARAMETER Until
    Optional date string. Only reports on/before this date are included.

.PARAMETER OutputPath
    Directory for the generated dashboard HTML. Default: the -Path folder.

.PARAMETER OutputMode
    Console | HTML | Both (default). Console prints the chronic-pending table; HTML writes the dashboard.

.PARAMETER Top
    Limit the bar chart + heatmap to the Top N most-pending reviewers (0 = all). Default 0.

.PARAMETER MinMisses
    Only include reviewers who appeared pending in at least N reports. Default 1 (include everyone);
    pass -MinMisses 2 to leave off folks who only missed a single day. Applies to every reviewer view
    (bars, missed-day streak flags, heatmap, detail table).

.EXAMPLE
    .\Invoke-SPPendingReviewerScrape.ps1 -Path 'C:\Reports\DailyEvidence' -Since '2026-06-01'

.EXAMPLE
    .\Invoke-SPPendingReviewerScrape.ps1 -Path .\Audit\daily-evidence -Top 25 -OutputMode Both
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Path = '.\Audit\daily-evidence',
    [Parameter()][string]$FilePattern = 'Daily-Attestation-Evidence-Report-*.html',
    [Parameter()][string]$Since,
    [Parameter()][string]$Until,
    [Parameter()][string]$OutputPath,
    [Parameter()][ValidateSet('Console', 'HTML', 'Both')][string]$OutputMode = 'Both',
    [Parameter()][int]$Top = 0,
    [Parameter()][int]$MinMisses = 1,
    [Parameter()][Alias('?')][switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function ConvertTo-Safe { param([string]$s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Remove-HtmlTags {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $t = [regex]::Replace($s, '<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    return ($t -replace '\s+', ' ').Trim()
}

function Resolve-ReportDate {
    # Extract a sortable date for a report file: parse the token after the prefix; fall back to
    # the file's LastWriteTime. Returns @{ Date=[datetime]; Label=[string] }.
    param([System.IO.FileInfo]$File)
    $token = $File.BaseName
    # strip a leading known prefix to isolate the date-looking tail
    $token = $token -replace '^(?i)Daily-Attestation-Evidence-Report[-_ ]*', ''
    $token = $token -replace '^(?i)daily-evidence(-v\d\w*)?[-_ ]*', ''
    $token = $token.Trim('-', '_', ' ')
    $fmts = @('yyyy-MM-dd', 'yyyyMMdd', 'yyyy-MM-dd-HHmmss', 'yyyyMMdd-HHmmss',
              'MM-dd-yyyy', 'M-d-yyyy', 'yyyy.MM.dd', 'dd-MM-yyyy', 'MMMM-d-yyyy', 'MMM-d-yyyy', 'MMMM d yyyy')
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($f in $fmts) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($token, $f, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            # .Date: the HHmmss formats carry a time-of-day, and the -Since/-Until
            # window compares against midnight-normalized bounds -- an un-normalized
            # 15:30 report silently fell OUTSIDE an inclusive -Until on its own day.
            return @{ Date = $dt.Date; Label = $dt.ToString('yyyy-MM-dd') }
        }
    }
    # Loose parse of the first date-looking chunk
    $m = [regex]::Match($token, '\d{4}[-.]?\d{2}[-.]?\d{2}')
    if ($m.Success) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse($m.Value, [ref]$dt)) { return @{ Date = $dt; Label = $dt.ToString('yyyy-MM-dd') } }
    }
    return @{ Date = $File.LastWriteTime.Date; Label = $File.LastWriteTime.ToString('yyyy-MM-dd') + '*' }
}

function Get-PendingReviewers {
    # Parse one report's HTML and return the DISTINCT reviewer names listed under any
    # Pending/Undecided <summary> table. Placeholder/empty/(Unassigned) rows are skipped.
    param([string]$Html)
    $names = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    # Each <details>...</details> block (the report's collapsibles). Fall back to whole doc.
    $blocks = [regex]::Matches($Html, '<details\b[^>]*>(.*?)</details>', 'Singleline')
    $scan = if ($blocks.Count -gt 0) { @($blocks | ForEach-Object { $_.Groups[1].Value }) } else { @($Html) }
    foreach ($block in $scan) {
        $sm = [regex]::Match($block, '<summary\b[^>]*>(.*?)</summary>', 'Singleline')
        $summaryText = if ($sm.Success) { Remove-HtmlTags $sm.Groups[1].Value } else { '' }
        # Only the Pending/Undecided reviewer tables; skip Completed/Reassigned/Approved/Revoked sections.
        if ($summaryText -notmatch '(?i)pending|undecided') { continue }
        if ($summaryText -match '(?i)\b(completed|reassigned|approved|revoked)\b') { continue }
        # ALL tables in the collapsible, not just the first -- per-reviewer subhead+table
        # layouts (V4d/V4e style) put each reviewer in a separate table, and Match (singular)
        # silently dropped everyone after the first table.
        $tbls = [regex]::Matches($block, '<table\b[^>]*>(.*?)</table>', 'Singleline')
        if ($tbls.Count -eq 0) { continue }
        foreach ($tbl in $tbls) {
        foreach ($row in [regex]::Matches($tbl.Groups[1].Value, '<tr\b[^>]*>(.*?)</tr>', 'Singleline')) {
            $cells = [regex]::Matches($row.Groups[1].Value, '<t[dh]\b[^>]*>(.*?)</t[dh]>', 'Singleline')
            if ($cells.Count -eq 0) { continue }
            if ($row.Groups[1].Value -match '<th\b') { continue }   # header row
            $name = Remove-HtmlTags $cells[0].Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -match '(?i)^\(?unassigned\)?$') { continue }
            if ($name -match '(?i)no (undecided|decisions|items)') { continue }   # placeholder row
            if ($name.Length -gt 120) { continue }                                # not a name (a colspan note)
            [void]$names.Add($name)
        }
        }
    }
    return @($names)
}

function Get-ReviewerStreak {
    # Longest run of CONSECUTIVE calendar days a reviewer was pending (a missing day's report OR a
    # not-pending day breaks the run). Also returns the total distinct days pending. DistinctDates is
    # sorted [datetime]; ByDate maps 'yyyy-MM-dd' -> HashSet of pending reviewer names.
    param([string]$Name, $DistinctDates, $ByDate)
    $max = 0; $cur = 0; $total = 0
    $prev = $null; $prevPending = $false; $curStart = $null; $maxStart = $null; $maxEnd = $null
    foreach ($dt in $DistinctDates) {
        $pending = $ByDate[$dt.ToString('yyyy-MM-dd')].Contains($Name)
        if ($pending) {
            $total++
            if ($prevPending -and $null -ne $prev -and ($dt - $prev).Days -eq 1) { $cur++ }
            else { $cur = 1; $curStart = $dt }
            if ($cur -gt $max) { $max = $cur; $maxStart = $curStart; $maxEnd = $dt }
        }
        else { $cur = 0 }
        $prev = $dt; $prevPending = $pending
    }
    return @{ Max = $max; Start = $maxStart; End = $maxEnd; Total = $total }
}

# ---------------------------------------------------------------------------
# Inline-SVG chart builders (no JS -- Word/email safe), V7-style palette.
# ---------------------------------------------------------------------------
function New-SvgChronicBars {
    param($Rows, [int]$Total)   # Rows: @(@{Name;Count}) sorted desc
    if ($Rows.Count -eq 0) { return '<p style="color:#777">No pending reviewers found.</p>' }
    $barH = 22; $gap = 6; $labelW = 230; $valW = 120; $maxBarW = 460
    $h = ($Rows.Count * ($barH + $gap)) + 10
    $w = $labelW + $maxBarW + $valW
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg width='$w' height='$h' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial,sans-serif' font-size='12'>")
    $y = 4
    foreach ($r in $Rows) {
        $pct = if ($Total -gt 0) { $r.Count / $Total } else { 0 }
        $bw = [int]($maxBarW * $pct); if ($bw -lt 2 -and $r.Count -gt 0) { $bw = 2 }
        $fill = if ($pct -ge 0.6) { '#c0392b' } elseif ($pct -ge 0.3) { '#e67e22' } else { '#27ae60' }
        $nm = ConvertTo-Safe $r.Name
        [void]$sb.Append("<text x='0' y='$($y+15)' fill='#222'>$nm</text>")
        [void]$sb.Append("<rect x='$labelW' y='$y' width='$bw' height='$barH' rx='3' fill='$fill'></rect>")
        [void]$sb.Append("<text x='$($labelW+$bw+6)' y='$($y+15)' fill='#444'>$($r.Count)/$Total ($([int]($pct*100))%)</text>")
        $y += $barH + $gap
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-SvgHeatmap {
    param($Reviewers, $Dates, $Grid)   # Reviewers: names sorted; Dates: labels sorted; Grid[name][dateLabel]=$true
    if ($Reviewers.Count -eq 0 -or $Dates.Count -eq 0) { return '<p style="color:#777">Not enough data for a heatmap.</p>' }
    $cell = 18; $rowLabelW = 200; $colLabelH = 70
    $w = $rowLabelW + ($Dates.Count * $cell) + 10
    $h = $colLabelH + ($Reviewers.Count * $cell) + 10
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg width='$w' height='$h' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial,sans-serif' font-size='10'>")
    # column (date) labels, rotated
    for ($c = 0; $c -lt $Dates.Count; $c++) {
        $x = $rowLabelW + ($c * $cell) + ($cell / 2)
        $lbl = ConvertTo-Safe $Dates[$c]
        [void]$sb.Append("<text x='$x' y='$($colLabelH-4)' transform='rotate(-60 $x,$($colLabelH-4))' fill='#555'>$lbl</text>")
    }
    for ($r = 0; $r -lt $Reviewers.Count; $r++) {
        $name = $Reviewers[$r]
        $ry = $colLabelH + ($r * $cell)
        [void]$sb.Append("<text x='0' y='$($ry+13)' fill='#222'>$(ConvertTo-Safe $name)</text>")
        for ($c = 0; $c -lt $Dates.Count; $c++) {
            $x = $rowLabelW + ($c * $cell)
            $on = $Grid[$name].Contains($Dates[$c])
            $fill = if ($on) { '#c0392b' } else { '#eef0f3' }
            [void]$sb.Append("<rect x='$x' y='$ry' width='$($cell-2)' height='$($cell-2)' rx='2' fill='$fill'><title>$(ConvertTo-Safe $name) - $(ConvertTo-Safe $Dates[$c]): $(if ($on) {'PENDING'} else {'-'})</title></rect>")
        }
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-SvgDailyTrend {
    param($Dates, $Counts)   # parallel arrays: date label -> distinct-pending count
    if ($Dates.Count -eq 0) { return '<p style="color:#777">No dates to trend.</p>' }
    $barW = 26; $gap = 8; $chartH = 160; $labelH = 60
    $max = ([int](@($Counts | Measure-Object -Maximum).Maximum)); if ($max -lt 1) { $max = 1 }
    $w = ($Dates.Count * ($barW + $gap)) + 40
    $h = $chartH + $labelH
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg width='$w' height='$h' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial,sans-serif' font-size='10'>")
    for ($i = 0; $i -lt $Dates.Count; $i++) {
        $x = 30 + ($i * ($barW + $gap))
        $bh = [int]($chartH * ($Counts[$i] / $max))
        $yTop = $chartH - $bh
        [void]$sb.Append("<rect x='$x' y='$yTop' width='$barW' height='$bh' rx='3' fill='#2c7fb8'></rect>")
        [void]$sb.Append("<text x='$($x+$barW/2)' y='$($yTop-3)' text-anchor='middle' fill='#222'>$($Counts[$i])</text>")
        $lx = $x + ($barW / 2)
        [void]$sb.Append("<text x='$lx' y='$($chartH+12)' transform='rotate(-60 $lx,$($chartH+12))' fill='#555'>$(ConvertTo-Safe $Dates[$i])</text>")
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "ERROR: Path not found: $Path" -ForegroundColor Red; exit 2 }
$files = @(Get-ChildItem -LiteralPath $Path -Filter $FilePattern -File | Sort-Object Name)
if ($files.Count -eq 0) { Write-Host "No files matching '$FilePattern' in $Path" -ForegroundColor Yellow; exit 0 }

$sinceDt = $null; $untilDt = $null
if ($Since) { $tmp = [datetime]::MinValue; if ([datetime]::TryParse($Since, [ref]$tmp)) { $sinceDt = $tmp.Date } }
if ($Until) { $tmp = [datetime]::MinValue; if ([datetime]::TryParse($Until, [ref]$tmp)) { $untilDt = $tmp.Date } }

# Parse every report -> per-date set of pending reviewers.
$reports = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $d = Resolve-ReportDate -File $f
    if ($null -ne $sinceDt -and $d.Date -lt $sinceDt) { continue }
    if ($null -ne $untilDt -and $d.Date -gt $untilDt) { continue }
    $html = Get-Content -LiteralPath $f.FullName -Raw
    $revs = Get-PendingReviewers -Html $html
    $reports.Add([pscustomobject]@{ File = $f.Name; Date = $d.Date; Label = $d.Label; Reviewers = $revs })
}
$reports = @($reports | Sort-Object Date, Label)
if ($reports.Count -eq 0) { Write-Host "No reports in the requested date window." -ForegroundColor Yellow; exit 0 }

# Count DAYS, not report files: a report regenerated twice on one day (both files
# kept) used to give a one-day miss Count=2 (surviving -MinMisses 2), deflate every
# reviewer's Pct via a doubled denominator, and emit duplicate heatmap columns.
$dateLabels = @($reports | ForEach-Object { $_.Label } | Sort-Object -Unique)
$total = $dateLabels.Count

# Aggregate per reviewer (grid = distinct day labels; Count derives from it).
$counts = @{}            # name -> int (distinct days pending)
$grid   = @{}            # name -> HashSet[dateLabel]
foreach ($rep in $reports) {
    foreach ($name in $rep.Reviewers) {
        if (-not $counts.ContainsKey($name)) { $counts[$name] = 0; $grid[$name] = New-Object System.Collections.Generic.HashSet[string] }
        [void]$grid[$name].Add($rep.Label)
    }
}
foreach ($name in @($counts.Keys)) { $counts[$name] = $grid[$name].Count }
$rows = @($counts.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Count = $_.Value; Pct = if ($total -gt 0) { [math]::Round($_.Value * 100.0 / $total, 0) } else { 0 } } } |
          Sort-Object -Property @{Expression='Count';Descending=$true}, @{Expression='Name';Descending=$false})
# -MinMisses: drop reviewers with fewer than N total pending appearances (e.g. -MinMisses 2 leaves off
# anyone who only missed a single day). Cascades to every reviewer view -- bars, streak flags, heatmap,
# and the detail table all derive from $rows below.
$reviewersBeforeMinMisses = $rows.Count
if ($MinMisses -gt 1) { $rows = @($rows | Where-Object { $_.Count -ge $MinMisses }) }
$excludedByMinMisses = $reviewersBeforeMinMisses - $rows.Count
$shown = if ($Top -gt 0) { @($rows | Select-Object -First $Top) } else { $rows }
# Per-DAY pending counts (union across same-day report files), aligned with $dateLabels.
$dayReviewerSets = @{}
foreach ($rep in $reports) {
    if (-not $dayReviewerSets.ContainsKey($rep.Label)) {
        $dayReviewerSets[$rep.Label] = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    }
    foreach ($n in $rep.Reviewers) { [void]$dayReviewerSets[$rep.Label].Add($n) }
}
$dailyCounts = @($dateLabels | ForEach-Object { $dayReviewerSets[$_].Count })

# ---- consecutive missed-review streaks (calendar-day adjacency) ----
# Collapse to distinct calendar dates: a reviewer is "pending that day" if pending in any report that day.
$byDate = [ordered]@{}
foreach ($rep in $reports) {
    $k = $rep.Date.ToString('yyyy-MM-dd')
    if (-not $byDate.Contains($k)) { $byDate[$k] = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase) }
    foreach ($n in $rep.Reviewers) { [void]$byDate[$k].Add($n) }
}
$distinctDates = @($byDate.Keys | ForEach-Object { [datetime]$_ } | Sort-Object)
$distinctCount = $distinctDates.Count
# Rule: fewer than 3 report files -> flag at 2+ consecutive days; 3+ files -> flag at 3+ in a row.
$streakThreshold = if ($reports.Count -lt 3) { 2 } else { 3 }
$streakRows = @($rows | ForEach-Object {
    $s = Get-ReviewerStreak -Name $_.Name -DistinctDates $distinctDates -ByDate $byDate
    [pscustomobject]@{
        Name      = $_.Name
        Streak    = $s.Max
        Window    = if ($s.Max -ge 1 -and $null -ne $s.Start) { "$($s.Start.ToString('yyyy-MM-dd')) to $($s.End.ToString('yyyy-MM-dd'))" } else { '-' }
        TotalDays = $s.Total
        Flagged   = ($s.Max -ge $streakThreshold)
    }
} | Sort-Object -Property @{Expression='Flagged';Descending=$true}, @{Expression='Streak';Descending=$true}, @{Expression='TotalDays';Descending=$true}, @{Expression='Name'})
$flaggedCount = @($streakRows | Where-Object Flagged).Count

# ---- Console ----
if ($OutputMode -in @('Console', 'Both')) {
    Write-Host ''
    Write-Host "Pending-Reviewer scrape: $total day(s) from $($reports.Count) report file(s) [$($reports[0].Label) .. $($reports[-1].Label)], $($rows.Count) distinct reviewer(s)$(if ($MinMisses -gt 1) { " (>= $MinMisses missed days; $excludedByMinMisses single/low-miss reviewer(s) excluded)" })" -ForegroundColor Cyan
    $shown | Select-Object Name, Count, @{N='OutOf';E={$total}}, @{N='Pct';E={"$($_.Pct)%"}} | Format-Table -AutoSize | Out-String | Write-Host
    if ($flaggedCount -gt 0) {
        Write-Host "Missed-review streaks (>= $streakThreshold consecutive day(s)): $flaggedCount reviewer(s) flagged" -ForegroundColor Yellow
        $streakRows | Where-Object Flagged | Select-Object Name, Streak, Window, TotalDays | Format-Table -AutoSize | Out-String | Write-Host
    }
    else {
        Write-Host "Missed-review streaks: none reached the $streakThreshold-consecutive-day threshold." -ForegroundColor Green
    }
}

# ---- HTML ----
if ($OutputMode -in @('HTML', 'Both')) {
    if (-not $OutputPath) { $OutputPath = $Path }
    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $OutputPath "Pending-Reviewer-Tracker-$stamp.html"

    $reviewerOrder = @($shown | ForEach-Object { $_.Name })
    $barSvg  = New-SvgChronicBars -Rows $shown -Total $total
    $heatSvg = New-SvgHeatmap -Reviewers $reviewerOrder -Dates $dateLabels -Grid $grid
    $trendSvg = New-SvgDailyTrend -Dates $dateLabels -Counts $dailyCounts

    $thresholdDesc = if ($reports.Count -lt 3) { 'fewer than 3 reports &rarr; 2+ consecutive days' } else { '3+ consecutive days' }
    $streakTableRows = ($streakRows | ForEach-Object {
        $st = if ($_.Flagged) { "<strong style='color:#c0392b'>&#9888; Flagged</strong>" } else { 'ok' }
        $bg = if ($_.Flagged) { " style='background:#fdecea'" } else { '' }
        "<tr$bg><td>$(ConvertTo-Safe $_.Name)</td><td style='text-align:right'>$($_.Streak)</td><td>$(ConvertTo-Safe $_.Window)</td><td style='text-align:right'>$($_.TotalDays)</td><td>$st</td></tr>"
    }) -join "`n"

    $tableRows = ($shown | ForEach-Object {
        "<tr><td>$(ConvertTo-Safe $_.Name)</td><td style='text-align:right'>$($_.Count)</td><td style='text-align:right'>$total</td><td style='text-align:right'>$($_.Pct)%</td><td>$(ConvertTo-Safe (($grid[$_.Name] | Sort-Object) -join ', '))</td></tr>"
    }) -join "`n"

    $doc = @"
<!DOCTYPE html><html><head><meta charset='utf-8'><title>Pending Reviewer Tracker</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;color:#222;margin:18px;background:#fff}
h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:22px 0 8px;border-bottom:1px solid #e1e4e8;padding-bottom:4px}
.meta{color:#555;font-size:12px;margin-bottom:6px}
table.report{border-collapse:collapse;font-size:12px;margin-top:6px}
table.report th,table.report td{border:1px solid #e1e4e8;padding:4px 8px}
table.report th{background:#f6f8fa;text-align:left}
.note{color:#777;font-size:11px;margin-top:4px}
</style></head><body>
<h1>Pending / Undecided Reviewer Tracker</h1>
<div class='meta'>Source: $(ConvertTo-Safe $Path) &nbsp;|&nbsp; $total day(s) from $($reports.Count) report file(s), $($reports[0].Label) &rarr; $($reports[-1].Label) &nbsp;|&nbsp; $($rows.Count) distinct reviewer(s)$(if ($MinMisses -gt 1) { " &nbsp;|&nbsp; min $MinMisses missed days ($excludedByMinMisses excluded)" }) &nbsp;|&nbsp; generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
<div class='note'>Scraped from the day-end evidence reports' Pending/Undecided reviewer tables. A reviewer is counted once per report. (Bridge view until cache-based trending is fully wired.)</div>

<h2>1. Chronic Pending &mdash; days pending out of $total day(s)</h2>
$barSvg

<h2>2. Missed-Review Streak Flags &mdash; flagged at &ge; $streakThreshold consecutive day(s)</h2>
<div class='note'>Rule: $thresholdDesc. Data window: $distinctCount day(s) across $($reports.Count) report(s). Flagged: $flaggedCount reviewer(s). A missing report day or a not-pending day breaks a streak. (High non-consecutive totals already show in section 1 and the heatmap.)</div>
<table class='report'><thead><tr><th>Reviewer</th><th>Longest Streak (days in a row)</th><th>Streak Window</th><th>Total Days Pending (of $distinctCount)</th><th>Status</th></tr></thead>
<tbody>
$streakTableRows
</tbody></table>

<h2>3. Reviewer &times; Date Heatmap &mdash; pending (red) by day</h2>
<div style='overflow-x:auto'>$heatSvg</div>

<h2>4. Daily Distinct-Pending Trend</h2>
<div style='overflow-x:auto'>$trendSvg</div>

<h2>Detail</h2>
<table class='report'><thead><tr><th>Reviewer</th><th>Pending In</th><th>Of</th><th>%</th><th>Dates</th></tr></thead>
<tbody>
$tableRows
</tbody></table>
</body></html>
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outFile, $doc, $utf8NoBom)
    Write-Host "Wrote dashboard: $outFile" -ForegroundColor Green
    if ($OutputMode -eq 'HTML') { Write-Output $outFile }
}

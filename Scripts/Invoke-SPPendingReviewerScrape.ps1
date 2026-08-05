#Requires -Version 5.1
<#
.SYNOPSIS
    Ad-hoc analyzer: scrape a folder of daily evidence HTML reports and chart which reviewers
    keep showing up as Pending / Undecided. A bridge while the cache-based trending matures.

.DESCRIPTION
    Reads the "final" daily evidence HTML reports you already produce -- by default matching the
    production V4b output name daily-evidence-v4b-<stamp>.html plus the legacy/mock name
    Daily-Attestation-Evidence-Report-<date>.html, with the report date auto-parsed from the
    filename (falling back to the file's LastWriteTime). For each report it finds every collapsible whose
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
    One or more wildcards for the report files. Default matches the production V4b output
    ('daily-evidence-v4b-*.html') plus the legacy/mock name ('Daily-Attestation-Evidence-Report-*.html').

.PARAMETER DaysBack
    Number of report DAYS to include (not calendar days). If the folder has reports for
    Mon/Tue/Wed/Thu/Fri and you pass -DaysBack 3, it takes the 3 most recent report days
    (Wed/Thu/Fri). Overrides -Since when set. Default 0 = disabled (use Since/Until).

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
    Only include reviewers who appeared pending in at least N report days. Default -1 = auto:
    1 (include everyone) when the window has 5 or fewer report days, else 3 to filter noise.
    Applies to every reviewer view (bars, missed-day streak flags, heatmap, detail table).

.EXAMPLE
    .\Invoke-SPPendingReviewerScrape.ps1 -Path 'C:\Reports\DailyEvidence' -Since '2026-06-01'

.EXAMPLE
    .\Invoke-SPPendingReviewerScrape.ps1 -Path .\Audit\daily-evidence -Top 25 -OutputMode Both
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Path = '.\Audit\daily-evidence',
    [Parameter()][string[]]$FilePattern = @('daily-evidence-v4b-*.html', 'Daily-Attestation-Evidence-Report-*.html'),
    [Parameter()][int]$DaysBack = 0,
    [Parameter()][string]$Since,
    [Parameter()][string]$Until,
    [Parameter()][string]$OutputPath,
    [Parameter()][ValidateSet('Console', 'HTML', 'Both')][string]$OutputMode = 'Both',
    [Parameter()][int]$Top = 0,
    [Parameter()][int]$MinMisses = -1,
    [Parameter()][switch]$ShowTrend,
    [Parameter()][switch]$Help
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
    # the file's LastWriteTime. Returns @{ Date=[datetime]; Label=[string]; Fallback=[bool] }.
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
            return @{ Date = $dt.Date; Label = $dt.ToString('yyyy-MM-dd'); Fallback = $false }
        }
    }
    # Loose parse of the first date-looking chunk
    $m = [regex]::Match($token, '\d{4}[-.]?\d{2}[-.]?\d{2}')
    if ($m.Success) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse($m.Value, [ref]$dt)) { return @{ Date = $dt.Date; Label = $dt.ToString('yyyy-MM-dd'); Fallback = $false } }
    }
    # Fallback: date the file by its LastWriteTime. The label stays the plain date -- a
    # starred label here split one calendar day into two aggregation keys whenever a
    # same-day file failed filename parsing, silently re-enabling the double-count the
    # day-dedup exists to prevent. Fallback provenance is surfaced in the meta line instead.
    return @{ Date = $File.LastWriteTime.Date; Label = $File.LastWriteTime.ToString('yyyy-MM-dd'); Fallback = $true }
}

function Test-ReviewerNameReal {
    # Shared row filter: drop blanks, unassigned markers, N/A stand-ins, empty-state
    # placeholder rows ("No undecided reviewers.", "No persistently-undecided items in
    # this window."), and colspan notes too long to be a name.
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 120) { return $false }
    if ($Name -match '(?i)^\(?unassigned\)?$') { return $false }
    if ($Name -match '(?i)^(n/?a|none|-+)$') { return $false }
    if ($Name -match '(?i)^no\b.*\b(undecided|decisions?|items?|reviewers?|approvals?)\b') { return $false }
    return $true
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
        # ALL tables in the collapsible, not just the first. Which column holds the reviewer
        # name is resolved from each table's header row: V4b/V4e put Reviewer first, but V4d
        # item tables (Identity|Access|Source|State) have NO Reviewer column at all -- their
        # reviewer lives in a subhead div above the table, and blindly reading column 0
        # counted end-user identities as reviewers. A table with headers but no Reviewer
        # column is skipped, and the block's subhead names are harvested instead.
        $tbls = [regex]::Matches($block, '<table\b[^>]*>(.*?)</table>', 'Singleline')
        if ($tbls.Count -eq 0) { continue }
        $needSubheadFallback = $false
        foreach ($tbl in $tbls) {
            $tblHtml = $tbl.Groups[1].Value
            $nameIdx = 0
            $ths = [regex]::Matches($tblHtml, '<th\b[^>]*>(.*?)</th>', 'Singleline')
            if ($ths.Count -gt 0) {
                $nameIdx = -1
                for ($i = 0; $i -lt $ths.Count; $i++) {
                    if ((Remove-HtmlTags $ths[$i].Groups[1].Value) -match '(?i)reviewer') { $nameIdx = $i; break }
                }
                if ($nameIdx -lt 0) { $needSubheadFallback = $true; continue }   # item table, not a reviewer table
            }
            foreach ($row in [regex]::Matches($tblHtml, '<tr\b[^>]*>(.*?)</tr>', 'Singleline')) {
                if ($row.Groups[1].Value -match '<th\b') { continue }   # header row
                $cells = [regex]::Matches($row.Groups[1].Value, '<t[dh]\b[^>]*>(.*?)</t[dh]>', 'Singleline')
                if ($cells.Count -le $nameIdx) { continue }
                $name = Remove-HtmlTags $cells[$nameIdx].Groups[1].Value
                if (Test-ReviewerNameReal $name) { [void]$names.Add($name) }
            }
        }
        # V4d layout: reviewer names live in <div class='subhead'>Name <span badge>N</span></div>
        # inside the collapsible; harvest them when the tables carried no Reviewer column.
        if ($needSubheadFallback) {
            foreach ($sh in [regex]::Matches($block, '<div\b[^>]*class=[''"][^''"]*subhead[^''"]*[''"][^>]*>(.*?)</div>', 'Singleline')) {
                $inner = [regex]::Replace($sh.Groups[1].Value, '<span\b[^>]*>.*?</span>', ' ')
                $name = Remove-HtmlTags $inner
                if (Test-ReviewerNameReal $name) { [void]$names.Add($name) }
            }
        }
    }
    return @($names)
}

function Get-ReviewerStreak {
    # Longest run of CONSECUTIVE REPORT DAYS a reviewer was pending. Adjacency is by report
    # day, not calendar day: reports only exist on business days, so calendar-day adjacency
    # made a Thu-Fri-Mon-Tue run read as two 2-day streaks -- a "3+ consecutive days" flag
    # could only ever fire within a single Mon-Fri week. A weekend/holiday with no report
    # does not break a run; a report day where the reviewer completed does. Also returns the
    # total distinct days pending. DistinctDates is sorted [datetime]; ByDate maps
    # 'yyyy-MM-dd' -> HashSet of pending reviewer names.
    param([string]$Name, $DistinctDates, $ByDate)
    $max = 0; $cur = 0; $total = 0
    $curStart = $null; $maxStart = $null; $maxEnd = $null
    foreach ($dt in $DistinctDates) {
        if ($ByDate[$dt.ToString('yyyy-MM-dd')].Contains($Name)) {
            $total++
            if ($cur -eq 0) { $curStart = $dt }
            $cur++
            if ($cur -gt $max) { $max = $cur; $maxStart = $curStart; $maxEnd = $dt }
        }
        else { $cur = 0 }
    }
    return @{ Max = $max; Start = $maxStart; End = $maxEnd; Total = $total }
}

function Get-ReviewerTrend {
    # Splits the report window into first-half and second-half by REPORT DAYS (not
    # calendar days). Compares the reviewer's outstanding rate in each half.
    #
    # 5-day example: first half = days 1-2, second half = days 3-5.
    #   Alice pending Mon,Tue,Wed but clear Thu,Fri -> first 2/2=100%, second 1/3=33% -> Improving
    #   Bob clear Mon,Tue but pending Wed,Thu,Fri   -> first 0/2=0%,   second 3/3=100% -> Lagging
    #   Carol pending all 5                          -> first 2/2=100%, second 3/3=100% -> Steady
    #
    # "Recently flagged": if the reviewer's total outstanding count equals the MinMisses
    # threshold, they just crossed the visibility line. Don't label them Lagging/Improving
    # -- they're new to the report and deserve a neutral indicator.
    #
    # Returns: @{ Direction = 'Improving'|'Lagging'|'Steady'|'New'|...; Color; Symbol }
    param([string]$Name, [string[]]$SortedDateLabels, $Grid, [int]$MinMissesThreshold = 0)

    $totalDays = $SortedDateLabels.Count
    if ($totalDays -lt 2) { return @{ Direction = 'New'; Color = '#3498db'; Symbol = '*' } }

    # Check if reviewer has enough data points
    $reviewerDates = $Grid[$Name]
    if ($null -eq $reviewerDates -or $reviewerDates.Count -lt 1) {
        return @{ Direction = 'New'; Color = '#3498db'; Symbol = '*' }
    }
    if ($reviewerDates.Count -eq 1) {
        # Single appearance -- check if it's in the recent half
        $midpoint = [int][math]::Floor($totalDays / 2)
        $theDate = @($reviewerDates)[0]
        $idx = [array]::IndexOf($SortedDateLabels, $theDate)
        if ($idx -ge $midpoint) {
            return @{ Direction = 'New this period'; Color = '#3498db'; Symbol = '*' }
        }
        else {
            return @{ Direction = 'Resolved'; Color = '#27ae60'; Symbol = 'v' }
        }
    }

    # "Recently flagged": reviewer just crossed the MinMisses threshold. They're new
    # to this report -- labeling them Lagging/Improving is premature. Give them a neutral
    # indicator that says "we see you, let's see how the next few days go."
    if ($MinMissesThreshold -gt 0 -and $reviewerDates.Count -eq $MinMissesThreshold) {
        return @{ Direction = 'Recently flagged'; Color = '#3498db'; Symbol = '*' }
    }

    # Split into halves
    $midpoint = [int][math]::Floor($totalDays / 2)
    $firstHalfDays  = @($SortedDateLabels[0..($midpoint - 1)])
    $secondHalfDays = @($SortedDateLabels[$midpoint..($totalDays - 1)])

    $firstCount  = 0; foreach ($d in $firstHalfDays)  { if ($reviewerDates.Contains($d)) { $firstCount++ } }
    $secondCount = 0; foreach ($d in $secondHalfDays) { if ($reviewerDates.Contains($d)) { $secondCount++ } }

    # Detect alternating pattern: count state transitions (pending->clear or clear->pending).
    # Mon-on/Tue-off/Wed-on/Thu-on/Fri-off = 3 transitions. If transitions >= half the days,
    # the reviewer is bouncing -- "Inconsistent" is a better label than Improving/Lagging.
    $transitions = 0
    $prevPending = $false
    $isFirst = $true
    foreach ($d in $SortedDateLabels) {
        $isPending = $reviewerDates.Contains($d)
        if (-not $isFirst -and $isPending -ne $prevPending) { $transitions++ }
        $prevPending = $isPending
        $isFirst = $false
    }
    $transitionThreshold = [int][math]::Floor($totalDays / 2)
    if ($transitions -ge $transitionThreshold -and $transitions -ge 2) {
        return @{ Direction = 'Inconsistent'; Color = '#e67e22'; Symbol = '~' }
    }

    $firstRate  = if ($firstHalfDays.Count -gt 0) { $firstCount / $firstHalfDays.Count } else { 0 }
    $secondRate = if ($secondHalfDays.Count -gt 0) { $secondCount / $secondHalfDays.Count } else { 0 }

    $delta = $secondRate - $firstRate
    if ($delta -lt -0.01) {
        return @{ Direction = 'Improving'; Color = '#27ae60'; Symbol = 'v' }
    }
    elseif ($delta -gt 0.01) {
        return @{ Direction = 'Lagging'; Color = '#c0392b'; Symbol = '^' }
    }
    else {
        return @{ Direction = 'Steady'; Color = '#888'; Symbol = '-' }
    }
}

# ---------------------------------------------------------------------------
# Inline-SVG chart builders (no JS -- Word/email safe), V7-style palette.
# ---------------------------------------------------------------------------
function New-SvgChronicBars {
    param($Rows, [int]$Total, $TrendData, [int]$ExcludedCount = 0, [int]$MinMisses = 1)
    if ($Rows.Count -eq 0) {
        # Distinguish "nobody was outstanding" from "everyone fell under -MinMisses" --
        # the all-clear message is factually wrong in the second case.
        if ($ExcludedCount -gt 0) { return "<p style='color:#777'>No reviewer reached the -MinMisses threshold of $MinMisses; $ExcludedCount reviewer(s) with fewer outstanding days were excluded. Rerun with -MinMisses 1 to see everyone.</p>" }
        return '<p style="color:#27ae60">All reviewers completed their attestations -- no outstanding reviews.</p>'
    }
    $hasTrend = ($null -ne $TrendData -and $TrendData.Count -gt 0)
    $barH = 18; $gap = 4; $labelW = 180; $maxBarW = 220
    $h = ($Rows.Count * ($barH + $gap)) + 6
    $w = if ($hasTrend) { 720 } else { 560 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg width='$w' height='$h' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial,sans-serif' font-size='11'>")
    $y = 2
    foreach ($r in $Rows) {
        $pct = if ($Total -gt 0) { $r.Count / $Total } else { 0 }
        $bw = [int]($maxBarW * $pct); if ($bw -lt 2 -and $r.Count -gt 0) { $bw = 2 }
        $fill = if ($pct -ge 0.6) { '#c0392b' } elseif ($pct -ge 0.3) { '#e67e22' } else { '#27ae60' }
        $nm = ConvertTo-Safe $r.Name
        [void]$sb.Append("<text x='0' y='$($y+13)' fill='#222' font-size='11'>$nm</text>")
        [void]$sb.Append("<rect x='$labelW' y='$y' width='$bw' height='$barH' rx='2' fill='$fill'/>")
        $valText = "$($r.Count)/$Total ($([int]($pct*100))%)"
        $valX = $labelW + $bw + 4
        [void]$sb.Append("<text x='$valX' y='$($y+13)' fill='#444' font-size='11'>$valText</text>")

        if ($hasTrend -and $TrendData.ContainsKey($r.Name)) {
            $tr = $TrendData[$r.Name]
            $tColor = [string]$tr.Color
            $tDir   = [string]$tr.Direction
            $tSym   = [string]$tr.Symbol
            # Fixed position column for trend (right-aligned area)
            $trendX = $labelW + $maxBarW + 110
            $triY = $y + 4
            if ($tSym -eq 'v') {
                [void]$sb.Append("<polygon points='$trendX,$triY $($trendX+7),$triY $($trendX+3),$($triY+6)' fill='$tColor'/>")
            }
            elseif ($tSym -eq '^') {
                [void]$sb.Append("<polygon points='$trendX,$($triY+6) $($trendX+7),$($triY+6) $($trendX+3),$triY' fill='$tColor'/>")
            }
            elseif ($tSym -eq '~') {
                # Wavy line for inconsistent
                [void]$sb.Append("<text x='$trendX' y='$($y+13)' fill='$tColor' font-size='13' font-weight='600'>~</text>")
            }
            else {
                [void]$sb.Append("<text x='$($trendX+1)' y='$($y+13)' fill='$tColor' font-size='12' font-weight='600'>$tSym</text>")
            }
            [void]$sb.Append("<text x='$($trendX+11)' y='$($y+13)' fill='$tColor' font-size='10'>$tDir</text>")
        }

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
    # Adaptive to the window length (15-90+ days): bar width shrinks as the day count
    # grows; date labels are thinned to ~30 and rotated BELOW the axis, anchored at
    # their top end so they slope down-left AWAY from the bars (the previous
    # start-anchored rotate(-60) sloped them up INTO the bars); per-bar value labels
    # render only when the bars are wide enough to hold them.
    if ($Dates.Count -eq 0) { return '<p style="color:#777">No dates to trend.</p>' }
    $n = $Dates.Count
    $barW = if ($n -le 20) { 26 } elseif ($n -le 45) { 14 } else { 9 }
    $gap  = if ($n -le 20) { 8 }  elseif ($n -le 45) { 5 }  else { 3 }
    $chartH = 160; $labelH = 64; $topPad = 14; $leftPad = 40
    $step = [int][math]::Ceiling($n / 30.0)
    $max = ([int](@($Counts | Measure-Object -Maximum).Maximum)); if ($max -lt 1) { $max = 1 }
    $w = $leftPad + ($n * ($barW + $gap)) + 20
    $h = $topPad + $chartH + $labelH
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg width='$w' height='$h' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial,sans-serif' font-size='10'>")
    for ($i = 0; $i -lt $n; $i++) {
        $x = $leftPad + ($i * ($barW + $gap))
        $bh = [int]($chartH * ($Counts[$i] / $max))
        $yTop = $topPad + $chartH - $bh
        [void]$sb.Append("<rect x='$x' y='$yTop' width='$barW' height='$bh' rx='3' fill='#2c7fb8'><title>$(ConvertTo-Safe $Dates[$i]): $($Counts[$i])</title></rect>")
        if ($barW -ge 14) {
            [void]$sb.Append("<text x='$($x+$barW/2)' y='$($yTop-3)' text-anchor='middle' fill='#222'>$($Counts[$i])</text>")
        }
        if (($i % $step) -eq 0 -or $i -eq ($n - 1)) {
            $lx = $x + ($barW / 2); $ly = $topPad + $chartH + 12
            [void]$sb.Append("<text x='$lx' y='$ly' text-anchor='end' transform='rotate(-60 $lx,$ly)' fill='#555'>$(ConvertTo-Safe $Dates[$i])</text>")
        }
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "ERROR: Path not found: $Path" -ForegroundColor Red; exit 2 }
$files = @(foreach ($pat in $FilePattern) { Get-ChildItem -LiteralPath $Path -Filter $pat -File }) |
    Sort-Object -Property FullName -Unique
$files = @($files | Sort-Object Name)
if ($files.Count -eq 0) { Write-Host "No files matching '$($FilePattern -join "', '")' in $Path" -ForegroundColor Yellow; exit 0 }

$sinceDt = $null; $untilDt = $null
if ($Since) { $tmp = [datetime]::MinValue; if ([datetime]::TryParse($Since, [ref]$tmp)) { $sinceDt = $tmp.Date } }
if ($Until) { $tmp = [datetime]::MinValue; if ([datetime]::TryParse($Until, [ref]$tmp)) { $untilDt = $tmp.Date } }

# -DaysBack N: resolve from the actual report file dates (not calendar days).
# Takes the N most recent unique report dates inside the -Until bound (it previously
# ignored -Until, so DaysBack+Until returned fewer days than asked) and moves the
# since-bound to the oldest of them. Overrides -Since when set.
if ($DaysBack -gt 0) {
    $allFileDates = [System.Collections.Generic.List[datetime]]::new()
    foreach ($f in $files) {
        $d = Resolve-ReportDate -File $f
        if ($null -ne $d -and $d.Date -ne [datetime]::MinValue) {
            if ($null -ne $untilDt -and $d.Date -gt $untilDt) { continue }
            if (-not $allFileDates.Contains($d.Date)) { $allFileDates.Add($d.Date) }
        }
    }
    $sortedDates = @($allFileDates | Sort-Object)
    if ($sortedDates.Count -gt $DaysBack) {
        $sinceDt = $sortedDates[$sortedDates.Count - $DaysBack]
        Write-Host "  -DaysBack $DaysBack -> using $DaysBack most recent report days (since $($sinceDt.ToString('yyyy-MM-dd')))" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  -DaysBack $DaysBack -> only $($sortedDates.Count) report day(s) available, using all" -ForegroundColor DarkGray
    }
}

# Parse every report -> per-date set of pending reviewers.
$reports = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $d = Resolve-ReportDate -File $f
    if ($null -ne $sinceDt -and $d.Date -lt $sinceDt) { continue }
    if ($null -ne $untilDt -and $d.Date -gt $untilDt) { continue }
    $html = Get-Content -LiteralPath $f.FullName -Raw
    $revs = Get-PendingReviewers -Html $html
    $reports.Add([pscustomobject]@{ File = $f.Name; Date = $d.Date; Label = $d.Label; Fallback = [bool]$d.Fallback; Reviewers = $revs })
}
$reports = @($reports | Sort-Object Date, Label)
if ($reports.Count -eq 0) { Write-Host "No reports in the requested date window." -ForegroundColor Yellow; exit 0 }

# Count DAYS, not report files: a report regenerated twice on one day (both files
# kept) used to give a one-day miss Count=2 (surviving -MinMisses 2), deflate every
# reviewer's Pct via a doubled denominator, and emit duplicate heatmap columns.
$dateLabels = @($reports | ForEach-Object { $_.Label } | Sort-Object -Unique)
$total = $dateLabels.Count
$fallbackFileCount = @($reports | Where-Object Fallback).Count

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
# Auto-MinMisses: if not explicitly set (-1), scale based on campaign-day count.
# <= 5 campaign days: show everyone (MinMisses=1). > 5: default to 3 to filter noise
# (same gate as the engagement pattern analysis).
if ($MinMisses -lt 0) {
    $MinMisses = if ($total -le 5) { 1 } else { 3 }
    Write-Host "  Auto-MinMisses: $MinMisses (based on $total campaign day(s))" -ForegroundColor DarkGray
}

# -MinMisses: drop reviewers with fewer than N total pending appearances.
$reviewersBeforeMinMisses = $rows.Count
if ($MinMisses -gt 1) { $rows = @($rows | Where-Object { $_.Count -ge $MinMisses }) }
$excludedByMinMisses = $reviewersBeforeMinMisses - $rows.Count

# ---------------------------------------------------------------------------
# Gaming / Pattern Detection (runs when > 5 campaigns)
# ---------------------------------------------------------------------------
# Detects reviewers who are strategically doing just enough to avoid flagging:
#   - Alternating: miss-complete-miss-complete (never accumulates streaks)
#   - Weekend-adjacent: always skips the same day of week (shift pattern)
#   - Declining: strong start, tapering off (engagement fatigue)
#   - Burst: long idle streak then one completion right before escalation
#   - Bare minimum: miss rate 30-59% (doing just enough to stay under radar)
# ---------------------------------------------------------------------------
function Get-ReviewerPattern {
    param([string]$Name, $DistinctDates, $ByDate, [int]$TotalDays, [int]$MissCount)
    $patterns = @()
    $missRate = if ($TotalDays -gt 0) { $MissCount / $TotalDays } else { 0 }

    if ($TotalDays -lt 6) { return @{ Patterns = @(); Score = 0; Label = 'Insufficient data' } }

    # Build per-day presence array: $true = pending (missed), $false = completed
    $dayStates = @()
    foreach ($dt in $DistinctDates) {
        $isPending = $ByDate[$dt.ToString('yyyy-MM-dd')].Contains($Name)
        $dayStates += @{ Date = $dt; DayOfWeek = $dt.DayOfWeek; Pending = $isPending }
    }

    # 1. Alternating pattern: miss-complete-miss-complete (strategic avoidance of streaks)
    $transitions = 0
    for ($i = 1; $i -lt $dayStates.Count; $i++) {
        if ($dayStates[$i].Pending -ne $dayStates[$i-1].Pending) { $transitions++ }
    }
    $transitionRate = $transitions / [math]::Max(1, $dayStates.Count - 1)
    if ($transitionRate -ge 0.7 -and $missRate -ge 0.3) {
        $patterns += 'Alternating (miss-complete-miss pattern)'
    }

    # 2. Day-of-week skipping: always misses the same day (shift worker or gaming)
    $dowMisses = @{}
    $dowTotal = @{}
    foreach ($ds in $dayStates) {
        $dow = [string]$ds.DayOfWeek
        if (-not $dowTotal.ContainsKey($dow)) { $dowTotal[$dow] = 0; $dowMisses[$dow] = 0 }
        $dowTotal[$dow]++
        if ($ds.Pending) { $dowMisses[$dow]++ }
    }
    $avgMissRate = $missRate
    foreach ($dow in $dowMisses.Keys) {
        if ($dowTotal[$dow] -lt 2) { continue }
        $dowRate = $dowMisses[$dow] / $dowTotal[$dow]
        if ($dowRate -ge 0.75 -and $dowRate -gt ($avgMissRate * 2)) {
            $patterns += "Day-of-week: misses $dow ($($dowMisses[$dow])/$($dowTotal[$dow]) = $([math]::Round($dowRate * 100))%)"
        }
    }

    # 3. Declining engagement: first half vs second half
    $mid = [int]($dayStates.Count / 2)
    $firstHalfMisses = @($dayStates[0..($mid-1)] | Where-Object { $_.Pending }).Count
    $secondHalfMisses = @($dayStates[$mid..($dayStates.Count-1)] | Where-Object { $_.Pending }).Count
    $firstHalfRate = $firstHalfMisses / [math]::Max(1, $mid)
    $secondHalfRate = $secondHalfMisses / [math]::Max(1, $dayStates.Count - $mid)
    if ($secondHalfRate -ge ($firstHalfRate * 2.5) -and $secondHalfMisses -ge 3 -and $firstHalfRate -lt 0.3) {
        $patterns += "Declining (first half: $([math]::Round($firstHalfRate*100))% miss, second half: $([math]::Round($secondHalfRate*100))% miss)"
    }

    # 4. Burst compliance: long miss streak then single completion then miss again
    $burstCount = 0
    for ($i = 2; $i -lt ($dayStates.Count - 1); $i++) {
        if (-not $dayStates[$i].Pending -and $dayStates[$i-1].Pending -and $dayStates[$i-2].Pending -and $dayStates[$i+1].Pending) {
            $burstCount++
        }
    }
    if ($burstCount -ge 2) {
        $patterns += "Burst compliance ($burstCount isolated completions surrounded by misses)"
    }

    # 5. Bare minimum: miss rate 30-59% -- doing just enough
    if ($missRate -ge 0.3 -and $missRate -lt 0.6 -and $patterns.Count -eq 0) {
        $patterns += "Bare minimum ($([math]::Round($missRate*100))% miss rate -- borderline compliance)"
    }

    # 6. Chronic: miss rate >= 60%
    if ($missRate -ge 0.6) {
        $patterns += "Escalation recommended ($([math]::Round($missRate*100))% outstanding rate)"
    }

    # Gaming score: 0-100
    $score = 0
    if ($missRate -ge 0.6) { $score += 40 }
    elseif ($missRate -ge 0.3) { $score += [int]($missRate * 50) }
    if ($transitionRate -ge 0.7 -and $missRate -ge 0.3) { $score += 25 }  # alternating
    if ($burstCount -ge 2) { $score += 20 }
    if ($secondHalfRate -ge ($firstHalfRate * 2.5) -and $secondHalfMisses -ge 3) { $score += 15 }
    foreach ($dow in $dowMisses.Keys) {
        if ($dowTotal[$dow] -ge 2 -and ($dowMisses[$dow] / $dowTotal[$dow]) -ge 0.75) { $score += 10; break }
    }
    $score = [math]::Min(100, $score)

    $label = if ($score -ge 60) { 'High Risk' } elseif ($score -ge 30) { 'Concerning' } elseif ($score -gt 0) { 'Monitor' } else { 'Normal' }
    return @{ Patterns = $patterns; Score = $score; Label = $label }
}

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

# Run pattern detection when > 5 campaigns (must run AFTER $byDate/$distinctDates are built)
$patternResults = @{}
if ($total -gt 5) {
    foreach ($r in $rows) {
        $patternResults[$r.Name] = Get-ReviewerPattern -Name $r.Name -DistinctDates $distinctDates -ByDate $byDate -TotalDays $distinctCount -MissCount $r.Count
    }
}

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
    Write-Host "Reviewer compliance scrape: $total day(s) from $($reports.Count) report file(s) [$($reports[0].Label) .. $($reports[-1].Label)], $($rows.Count) distinct reviewer(s)$(if ($MinMisses -gt 1) { " (>= $MinMisses outstanding days; $excludedByMinMisses low-count reviewer(s) excluded)" })" -ForegroundColor Cyan
    if ($fallbackFileCount -gt 0) { Write-Host "  NOTE: $fallbackFileCount file(s) dated by file-modified time (filename date not parseable)" -ForegroundColor Yellow }
    $shown | Select-Object Name, Count, @{N='OutOf';E={$total}}, @{N='Pct';E={"$($_.Pct)%"}} | Format-Table -AutoSize | Out-String | Write-Host
    if ($flaggedCount -gt 0) {
        Write-Host "Consecutive outstanding reviews (>= $streakThreshold day(s)): $flaggedCount reviewer(s) identified" -ForegroundColor Yellow
        $streakRows | Where-Object Flagged | Select-Object Name, Streak, Window, TotalDays | Format-Table -AutoSize | Out-String | Write-Host
    }
    else {
        Write-Host "Consecutive outstanding reviews: none reached the $streakThreshold-day threshold." -ForegroundColor Green
    }

    # Gaming / Pattern detection output
    if ($patternResults.Count -gt 0) {
        $flagged = @($patternResults.GetEnumerator() | Where-Object { $_.Value.Score -ge 30 } | Sort-Object { $_.Value.Score } -Descending)
        if ($flagged.Count -gt 0) {
            Write-Host ''
            Write-Host "Pattern Detection: $($flagged.Count) reviewer(s) with concerning engagement patterns" -ForegroundColor Yellow
            foreach ($f in $flagged) {
                $color = if ($f.Value.Score -ge 60) { 'Red' } else { 'Yellow' }
                Write-Host "  $($f.Key) [Score: $($f.Value.Score) - $($f.Value.Label)]" -ForegroundColor $color
                foreach ($p in $f.Value.Patterns) { Write-Host "    - $p" -ForegroundColor DarkGray }
            }
        }
        else {
            Write-Host "Pattern Detection: no concerning engagement patterns found." -ForegroundColor Green
        }
    }
}

# ---- HTML ----
if ($OutputMode -in @('HTML', 'Both')) {
    if (-not $OutputPath) { $OutputPath = $Path }
    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $OutputPath "Pending-Reviewer-Tracker-$stamp.html"

    $reviewerOrder = @($shown | ForEach-Object { $_.Name })

    # Trend analysis (opt-in via -ShowTrend): compare first-half vs second-half engagement
    $trendDataMap = $null
    if ($ShowTrend -and $dateLabels.Count -ge 2) {
        $trendDataMap = @{}
        # Computed over ALL rows above MinMisses (not just -Top) so the console tallies
        # below reflect the full population; the bar chart looks up only shown names.
        foreach ($r in $rows) {
            $trendDataMap[$r.Name] = Get-ReviewerTrend -Name $r.Name -SortedDateLabels $dateLabels -Grid $grid -MinMissesThreshold $MinMisses
        }
        $improving    = @($trendDataMap.Values | Where-Object { $_.Direction -eq 'Improving' }).Count
        $lagging      = @($trendDataMap.Values | Where-Object { $_.Direction -eq 'Lagging' }).Count
        $inconsistent = @($trendDataMap.Values | Where-Object { $_.Direction -eq 'Inconsistent' }).Count
        $steady       = @($trendDataMap.Values | Where-Object { $_.Direction -eq 'Steady' }).Count
        Write-Host "  Trend analysis: $improving improving, $lagging lagging, $inconsistent inconsistent, $steady steady" -ForegroundColor DarkGray
    }

    $barSvg  = New-SvgChronicBars -Rows $shown -Total $total -TrendData $trendDataMap -ExcludedCount $excludedByMinMisses -MinMisses $MinMisses
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
<!DOCTYPE html><html><head><meta charset='utf-8'><title>Reviewer Attestation Compliance Tracker</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;color:#222;margin:18px;background:#fff}
h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:22px 0 8px;border-bottom:1px solid #e1e4e8;padding-bottom:4px}
.meta{color:#555;font-size:12px;margin-bottom:6px}
table.report{border-collapse:collapse;font-size:12px;margin-top:6px}
table.report th,table.report td{border:1px solid #e1e4e8;padding:4px 8px}
table.report th{background:#f6f8fa;text-align:left}
.note{color:#777;font-size:11px;margin-top:4px}
</style></head><body>
<h1>Reviewer Attestation Compliance Tracker</h1>
<div class='meta'>Source: $(ConvertTo-Safe $Path) &nbsp;|&nbsp; $total day(s) from $($reports.Count) report file(s), $($reports[0].Label) &rarr; $($reports[-1].Label) &nbsp;|&nbsp; $($rows.Count) distinct reviewer(s)$(if ($MinMisses -gt 1) { " &nbsp;|&nbsp; min $MinMisses missed days ($excludedByMinMisses excluded)" })$(if ($fallbackFileCount -gt 0) { " &nbsp;|&nbsp; $fallbackFileCount file(s) dated by file-modified time" }) &nbsp;|&nbsp; generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
<div class='note'>Sourced from daily evidence reports. Identifies reviewers with outstanding attestation decisions. A reviewer is counted once per report day. Covers ACTIVE-campaign Pending/Undecided sections only -- completed-campaign "Reviewers who did not complete" listings are not included.</div>

<h2>1. Reviewer Escalations Pending &mdash; outstanding attestations across $total day(s)</h2>
$barSvg

<h2>2. Consecutive Outstanding Reviews &mdash; flagged at &ge; $streakThreshold consecutive day(s)</h2>
<div class='note'>Rule: $thresholdDesc. Data window: $distinctCount day(s) across $($reports.Count) report(s). Flagged: $flaggedCount reviewer(s). Streaks run over consecutive REPORT days: a completed day resets the count; weekends/holidays with no report do not.</div>
<table class='report'><thead><tr><th>Reviewer</th><th>Longest Consecutive Days</th><th>Window</th><th>Total Days Outstanding (of $distinctCount)</th><th>Status</th></tr></thead>
<tbody>
$streakTableRows
</tbody></table>

<h2>3. Reviewer &times; Date Heatmap &mdash; outstanding (red) by day</h2>
<div style='overflow-x:auto'>$heatSvg</div>

<h2>4. Daily Outstanding Reviewer Trend</h2>
<div style='overflow-x:auto'>$trendSvg</div>

$(if ($patternResults.Count -gt 0) {
    $patternFlagged = @($patternResults.GetEnumerator() | Where-Object { $_.Value.Score -gt 0 } | Sort-Object { $_.Value.Score } -Descending)
    if ($patternFlagged.Count -gt 0) {
        $ptRows = ($patternFlagged | ForEach-Object {
            $sc = $_.Value.Score
            $scColor = if ($sc -ge 60) { '#c0392b' } elseif ($sc -ge 30) { '#e67e22' } else { '#777' }
            $bg = if ($sc -ge 60) { " style='background:#fdecea'" } elseif ($sc -ge 30) { " style='background:#fef9e7'" } else { '' }
            $patList = if ($_.Value.Patterns.Count -gt 0) { ($_.Value.Patterns | ForEach-Object { "&#8226; $_" }) -join '<br>' } else { '-' }
            "<tr$bg><td>$(ConvertTo-Safe $_.Key)</td><td style='text-align:center;color:$scColor;font-weight:600'>$sc</td><td style='color:$scColor;font-weight:600'>$($_.Value.Label)</td><td style='font-size:11px'>$patList</td></tr>"
        }) -join "`n"
@"
<h2>5. Engagement Pattern Analysis</h2>
<div class='note'>Identifies reviewers with recurring engagement patterns that may require follow-up.
Score: 0-29 = Monitor, 30-59 = Needs Attention, 60+ = Escalation Recommended. Patterns: Alternating (inconsistent completion),
Day-of-week (regularly unavailable on a specific day), Declining (decreasing engagement over time), Burst (extended inactivity
followed by brief activity), Below threshold (30-59% completion rate). Only runs when &gt; 5 campaign days.</div>
<table class='report'><thead><tr><th>Reviewer</th><th style='text-align:center'>Score</th><th>Follow-Up Level</th><th>Patterns Identified</th></tr></thead>
<tbody>
$ptRows
</tbody></table>
"@
    } else { "<h2>5. Engagement Pattern Analysis</h2><p style='color:#27ae60'>No recurring patterns identified -- all reviewers within expected engagement norms.</p>" }
} else { '' })

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

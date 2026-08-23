#Requires -Version 5.1
<#
.SYNOPSIS
    Ad-hoc analyzer: scrape a folder of daily evidence HTML reports and summarize
    Revoked and Newly Approved (New Scope) access decisions across the reporting period.

.DESCRIPTION
    Reads the "final" daily evidence HTML reports you already produce -- by default matching
    the production V4b output name daily-evidence-v4b-<stamp>.html plus the legacy/mock name
    Daily-Attestation-Evidence-Report-<date>.html, with the report date auto-parsed from the
    filename (falling back to the file's LastWriteTime). For each report it finds every
    collapsible whose <summary> mentions "Revoked" (with class s-red) and "New Scope" or
    "Approved Access" (with class s-green), and extracts decision details from the tables.

    IMPORTANT SEMANTICS: the V4b registers are CUMULATIVE campaign snapshots -- every daily
    report re-lists all revocations/new-scope approvals made so far, and each row carries the
    item's own Decision Date. Items are therefore DE-DUPLICATED across the window (first
    sighting wins) and bucketed by their own Decision Date, falling back to the first report
    day that listed them. Without this, a 30-day window counted every item once per day it
    survived in and put decisions on the report-file date instead of the real decision date.

    The dedupe NEVER collapses distinct revoke events: the key includes the Decision Date, so
    a grant revoked on two different days counts twice and is surfaced in the Re-Revoked
    Grants register (revoked access that came back is a governance signal, not noise). A
    duplicate of the same key WITHIN one report file is flagged as a data-quality warning
    (possible upstream cache duplication) rather than silently collapsed.

    It then renders a self-contained HTML dashboard (inline SVG, no JavaScript -- Word/email safe):
      1. Decision Activity Summary -- KPI tiles (total revoked, new scope, approved campaign-to-date
         when the campaign summary table is present, net change, averages).
      2. Daily Decision Trend     -- combined paired red/green bars per DECISION day, plus
         revoked-only and new-scope-only charts and a raw per-day numbers table. Charts adapt
         bar width and date-label density to the window length (15-90+ days).
      3. Revoked Access Detail    -- full register of every revocation (collapsible).
      4. Top Revoked Entitlements -- which entitlements were revoked most often.
      5. Top Revoked Identities   -- which identities had the most revocations.
      6. New Scope Detail         -- full register of approved access (collapsible).
      7. Source Breakdown         -- revoked vs new scope by source system.

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
    Console | HTML | Both (default). Console prints the summary; HTML writes the dashboard.

.PARAMETER Top
    Limit detail tables and rankings to the Top N rows. Default 0 = built-in limits
    (500 rows per detail register, 15 rows per ranking table). A real report day can carry
    thousands of rows, and an unbounded register breaks the Word/email-safe output goal.

.PARAMETER Help
    Show detailed help.

.EXAMPLE
    .\Invoke-SPDecisionScrape.ps1 -Path 'C:\Reports\DailyEvidence' -Since '2026-06-01'

.EXAMPLE
    .\Invoke-SPDecisionScrape.ps1 -Path .\Audit\daily-evidence -DaysBack 15 -OutputMode Both
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
    param([System.IO.FileInfo]$File)
    $token = $File.BaseName
    $token = $token -replace '^(?i)Daily-Attestation-Evidence-Report[-_ ]*', ''
    $token = $token -replace '^(?i)daily-evidence(-v\d\w*)?[-_ ]*', ''
    $token = $token.Trim('-', '_', ' ')
    $fmts = @('yyyy-MM-dd', 'yyyyMMdd', 'yyyy-MM-dd-HHmmss', 'yyyyMMdd-HHmmss',
              'MM-dd-yyyy', 'M-d-yyyy', 'yyyy.MM.dd', 'dd-MM-yyyy', 'MMMM-d-yyyy', 'MMM-d-yyyy', 'MMMM d yyyy')
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($f in $fmts) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($token, $f, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            return @{ Date = $dt.Date; Label = $dt.ToString('yyyy-MM-dd'); Fallback = $false }
        }
    }
    $m = [regex]::Match($token, '\d{4}[-.]?\d{2}[-.]?\d{2}')
    if ($m.Success) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse($m.Value, [ref]$dt)) { return @{ Date = $dt.Date; Label = $dt.ToString('yyyy-MM-dd'); Fallback = $false } }
    }
    # Fallback: date the file by its LastWriteTime. The label stays the plain date -- a
    # starred label here split one calendar day into two aggregation keys whenever a
    # same-day file failed filename parsing. Fallback provenance goes in the meta line.
    return @{ Date = $File.LastWriteTime.Date; Label = $File.LastWriteTime.ToString('yyyy-MM-dd'); Fallback = $true }
}

function Get-RevokedItems {
    # Parse one report's HTML and return revoked access items.
    # Looks for <details> with <summary> containing "Revoked" and class s-red.
    param([string]$Html)
    $items = New-Object System.Collections.Generic.List[object]
    $blocks = [regex]::Matches($Html, '<details\b[^>]*>(.*?)</details>', 'Singleline')
    if ($blocks.Count -eq 0) { return ,$items.ToArray() }
    foreach ($block in $blocks) {
        $content = $block.Groups[1].Value
        $sm = [regex]::Match($content, '<summary\b[^>]*>(.*?)</summary>', 'Singleline')
        if (-not $sm.Success) { continue }
        $summaryTag  = $sm.Value                  # full <summary ...>...</summary> tag including attributes
        $summaryText = Remove-HtmlTags $sm.Groups[1].Value
        # Must contain "Revoked" and have class s-red OR contain "items"
        if ($summaryText -notmatch '(?i)\brevoked\b') { continue }
        if ($summaryTag -notmatch 's-red' -and $summaryText -notmatch '(?i)\bitems?\b') { continue }
        # Exclude summaries that say Completed or Approved
        if ($summaryText -match '(?i)\b(completed|approved)\b') { continue }
        # Parse tables
        $tbls = [regex]::Matches($content, '<table\b[^>]*>(.*?)</table>', 'Singleline')
        if ($tbls.Count -eq 0) { continue }
        foreach ($tbl in $tbls) {
            foreach ($row in [regex]::Matches($tbl.Groups[1].Value, '<tr\b[^>]*>(.*?)</tr>', 'Singleline')) {
                $cells = [regex]::Matches($row.Groups[1].Value, '<t[dh]\b[^>]*>(.*?)</t[dh]>', 'Singleline')
                if ($cells.Count -eq 0) { continue }
                if ($row.Groups[1].Value -match '<th\b') { continue }
                # V4b columns: 0=Identity, 1=Account, 2=AccessName, 3=Source, 4=Reviewer, 5=DecisionDate, 6=Justification
                if ($cells.Count -lt 5) { continue }
                $identity      = Remove-HtmlTags $cells[0].Groups[1].Value
                $accessName    = Remove-HtmlTags $cells[2].Groups[1].Value
                $source        = Remove-HtmlTags $cells[3].Groups[1].Value
                $reviewer      = Remove-HtmlTags $cells[4].Groups[1].Value
                $decisionDate  = if ($cells.Count -ge 6) { Remove-HtmlTags $cells[5].Groups[1].Value } else { '' }
                $justification = if ($cells.Count -ge 7) { Remove-HtmlTags $cells[6].Groups[1].Value } else { '' }
                if ([string]::IsNullOrWhiteSpace($identity)) { continue }
                $items.Add([pscustomobject]@{
                    Identity      = $identity
                    AccessName    = $accessName
                    Source        = $source
                    Reviewer      = $reviewer
                    DecisionDate  = $decisionDate
                    Justification = $justification
                })
            }
        }
    }
    return ,$items.ToArray()
}

function Get-NewScopeItems {
    # Parse one report's HTML and return newly approved access items.
    # Looks for <details> with <summary> containing "New Scope" or "Approved Access" and class s-green.
    param([string]$Html)
    $items = New-Object System.Collections.Generic.List[object]
    $blocks = [regex]::Matches($Html, '<details\b[^>]*>(.*?)</details>', 'Singleline')
    if ($blocks.Count -eq 0) { return ,$items.ToArray() }
    foreach ($block in $blocks) {
        $content = $block.Groups[1].Value
        $sm = [regex]::Match($content, '<summary\b[^>]*>(.*?)</summary>', 'Singleline')
        if (-not $sm.Success) { continue }
        $summaryTag  = $sm.Value                  # full <summary ...>...</summary> tag including attributes
        $summaryText = Remove-HtmlTags $sm.Groups[1].Value
        # Must contain "New Scope" or "Approved Access" and have class s-green
        if ($summaryText -notmatch '(?i)(new\s+scope|approved\s+access)') { continue }
        if ($summaryTag -notmatch 's-green') { continue }
        # Parse tables
        $tbls = [regex]::Matches($content, '<table\b[^>]*>(.*?)</table>', 'Singleline')
        if ($tbls.Count -eq 0) { continue }
        foreach ($tbl in $tbls) {
            foreach ($row in [regex]::Matches($tbl.Groups[1].Value, '<tr\b[^>]*>(.*?)</tr>', 'Singleline')) {
                $cells = [regex]::Matches($row.Groups[1].Value, '<t[dh]\b[^>]*>(.*?)</t[dh]>', 'Singleline')
                if ($cells.Count -eq 0) { continue }
                if ($row.Groups[1].Value -match '<th\b') { continue }
                # V4b columns: 0=Identity, 1=AccessName, 2=Source, 3=Reviewer, 4=DecisionDate
                if ($cells.Count -lt 4) { continue }
                $identity     = Remove-HtmlTags $cells[0].Groups[1].Value
                $accessName   = Remove-HtmlTags $cells[1].Groups[1].Value
                $source       = Remove-HtmlTags $cells[2].Groups[1].Value
                $reviewer     = Remove-HtmlTags $cells[3].Groups[1].Value
                $decisionDate = if ($cells.Count -ge 5) { Remove-HtmlTags $cells[4].Groups[1].Value } else { '' }
                if ([string]::IsNullOrWhiteSpace($identity)) { continue }
                $items.Add([pscustomobject]@{
                    Identity     = $identity
                    AccessName   = $accessName
                    Source       = $source
                    Reviewer     = $reviewer
                    DecisionDate = $decisionDate
                })
            }
        }
    }
    return ,$items.ToArray()
}

function Resolve-DecisionDay {
    # Prefer the register's own Decision Date cell (real decision timestamps, e.g.
    # '2026-06-24 13:00'); fall back to the report day for '-'/'N/A'/unparseable cells.
    param([string]$RawDecisionDate, [datetime]$ReportDate)
    if (-not [string]::IsNullOrWhiteSpace($RawDecisionDate)) {
        $tmp = [datetime]::MinValue
        if ([datetime]::TryParse($RawDecisionDate, [ref]$tmp)) { return $tmp.Date }
    }
    return $ReportDate.Date
}

function Get-ApprovedTotal {
    # Best-effort: sum the Approved column of the V4b campaign summary table
    # (Campaign | Status | Total Items | Approved | Revoked | Undecided | ...).
    # The value is a CAMPAIGN-TO-DATE level, not a daily increment. Returns -1 when the
    # table is absent (e.g. non-V4b input) so callers can hide the KPI gracefully.
    param([string]$Html)
    foreach ($tbl in [regex]::Matches($Html, '<table\b[^>]*>(.*?)</table>', 'Singleline')) {
        $t = $tbl.Groups[1].Value
        $ths = @([regex]::Matches($t, '<th\b[^>]*>(.*?)</th>', 'Singleline') | ForEach-Object { Remove-HtmlTags $_.Groups[1].Value })
        if ($ths.Count -eq 0) { continue }
        if (($ths -join '|') -notmatch '(?i)campaign') { continue }
        $apIdx = -1
        for ($i = 0; $i -lt $ths.Count; $i++) { if ($ths[$i] -match '(?i)^approved$') { $apIdx = $i; break } }
        if ($apIdx -lt 0) { continue }
        $sum = 0; $found = $false
        foreach ($row in [regex]::Matches($t, '<tr\b[^>]*>(.*?)</tr>', 'Singleline')) {
            if ($row.Groups[1].Value -match '<th\b') { continue }
            $cells = [regex]::Matches($row.Groups[1].Value, '<t[dh]\b[^>]*>(.*?)</t[dh]>', 'Singleline')
            if ($cells.Count -le $apIdx) { continue }
            $txt = (Remove-HtmlTags $cells[$apIdx].Groups[1].Value) -replace '[,\s]', ''
            $n = 0
            if ([int]::TryParse($txt, [ref]$n)) { $sum += $n; $found = $true }
        }
        if ($found) { return $sum }
    }
    return -1
}

# ---------------------------------------------------------------------------
# SVG chart builders (no JS -- Word/email safe).
# Shared adaptive rules so 15-90+ day windows stay readable:
#  - bar width shrinks as the day count grows
#  - date labels are thinned to ~30 and rotated BELOW the axis, anchored at their top
#    end so they slope down-left AWAY from the bars (the previous start-anchored
#    rotate(-60) sloped them up INTO the bars)
#  - per-bar value labels render only when bars are wide enough to hold them; the raw
#    daily numbers table carries the exact counts either way
# ---------------------------------------------------------------------------
function Get-SvgDateLabelStep {
    # At most ~30 date labels regardless of window length; the last bar always gets one.
    param([int]$Count)
    return [int][math]::Ceiling($Count / 30.0)
}

function New-SvgDailySeries {
    # Single-series daily bar chart (used for the revoked-only and new-scope-only views).
    param($Dates, $Counts, [string]$Fill = '#2c7fb8')
    if ($Dates.Count -eq 0) { return '<p style="color:#777">No dates to trend.</p>' }
    $n = $Dates.Count
    $barW = if ($n -le 20) { 26 } elseif ($n -le 45) { 14 } else { 9 }
    $gap  = if ($n -le 20) { 8 }  elseif ($n -le 45) { 5 }  else { 3 }
    $chartH = 160; $labelH = 64; $topPad = 14; $leftPad = 40
    $step = Get-SvgDateLabelStep -Count $n
    $max = ([int](@($Counts | Measure-Object -Maximum).Maximum)); if ($max -lt 1) { $max = 1 }
    $w = $leftPad + ($n * ($barW + $gap)) + 20
    $h = $topPad + $chartH + $labelH
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg width='$w' height='$h' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial,sans-serif' font-size='10'>")
    for ($i = 0; $i -lt $n; $i++) {
        $x = $leftPad + ($i * ($barW + $gap))
        $bh = [int]($chartH * ($Counts[$i] / $max))
        $yTop = $topPad + $chartH - $bh
        [void]$sb.Append("<rect x='$x' y='$yTop' width='$barW' height='$bh' rx='2' fill='$Fill'><title>$(ConvertTo-Safe $Dates[$i]): $($Counts[$i])</title></rect>")
        if ($barW -ge 14 -and $Counts[$i] -gt 0) {
            [void]$sb.Append("<text x='$($x + $barW/2)' y='$($yTop - 3)' text-anchor='middle' fill='#222'>$($Counts[$i])</text>")
        }
        if (($i % $step) -eq 0 -or $i -eq ($n - 1)) {
            $lx = $x + ($barW / 2); $ly = $topPad + $chartH + 12
            [void]$sb.Append("<text x='$lx' y='$ly' text-anchor='end' transform='rotate(-60 $lx,$ly)' fill='#555'>$(ConvertTo-Safe $Dates[$i])</text>")
        }
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-SvgDailyDecisionTrend {
    # Combined view: paired red (revoked) / green (new scope) bars per decision day.
    param($Dates, $RevokedCounts, $NewScopeCounts)
    if ($Dates.Count -eq 0) { return '<p style="color:#777">No dates to trend.</p>' }
    $n = $Dates.Count
    $barW = if ($n -le 20) { 12 } elseif ($n -le 45) { 8 } else { 5 }
    $pairGap  = if ($n -le 20) { 4 }  elseif ($n -le 45) { 3 } else { 2 }
    $groupGap = if ($n -le 20) { 10 } elseif ($n -le 45) { 6 } else { 4 }
    $chartH = 160; $labelH = 64; $topPad = 16; $leftPad = 40
    $step = Get-SvgDateLabelStep -Count $n
    $allCounts = @($RevokedCounts) + @($NewScopeCounts)
    $max = ([int](@($allCounts | Measure-Object -Maximum).Maximum)); if ($max -lt 1) { $max = 1 }
    $groupW = ($barW * 2) + $pairGap + $groupGap
    $w = $leftPad + ($n * $groupW) + 20
    $h = $topPad + $chartH + $labelH
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg width='$w' height='$h' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial,sans-serif' font-size='10'>")
    # Legend (top-left, inside the fixed padding so it never depends on chart width)
    [void]$sb.Append("<rect x='$leftPad' y='1' width='9' height='9' rx='1' fill='#c0392b'/><text x='$($leftPad+13)' y='9' fill='#555'>Revoked</text>")
    [void]$sb.Append("<rect x='$($leftPad+70)' y='1' width='9' height='9' rx='1' fill='#27ae60'/><text x='$($leftPad+84)' y='9' fill='#555'>New Scope</text>")
    for ($i = 0; $i -lt $n; $i++) {
        $gx = $leftPad + ($i * $groupW)
        # Revoked bar (red)
        $rh = [int]($chartH * ($RevokedCounts[$i] / $max))
        $ryTop = $topPad + $chartH - $rh
        [void]$sb.Append("<rect x='$gx' y='$ryTop' width='$barW' height='$rh' rx='2' fill='#c0392b'><title>$(ConvertTo-Safe $Dates[$i]) revoked: $($RevokedCounts[$i])</title></rect>")
        if ($barW -ge 12 -and $RevokedCounts[$i] -gt 0) {
            [void]$sb.Append("<text x='$($gx + $barW/2)' y='$($ryTop - 2)' text-anchor='middle' fill='#c0392b' font-size='9'>$($RevokedCounts[$i])</text>")
        }
        # New scope bar (green)
        $nx = $gx + $barW + $pairGap
        $nh = [int]($chartH * ($NewScopeCounts[$i] / $max))
        $nyTop = $topPad + $chartH - $nh
        [void]$sb.Append("<rect x='$nx' y='$nyTop' width='$barW' height='$nh' rx='2' fill='#27ae60'><title>$(ConvertTo-Safe $Dates[$i]) new scope: $($NewScopeCounts[$i])</title></rect>")
        if ($barW -ge 12 -and $NewScopeCounts[$i] -gt 0) {
            [void]$sb.Append("<text x='$($nx + $barW/2)' y='$($nyTop - 2)' text-anchor='middle' fill='#27ae60' font-size='9'>$($NewScopeCounts[$i])</text>")
        }
        # Date label (thinned, anchored at its top end below the axis)
        if (($i % $step) -eq 0 -or $i -eq ($n - 1)) {
            $lx = $gx + $barW + ($pairGap / 2); $ly = $topPad + $chartH + 12
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

# Parse every report -> collect revoked and new scope items per date.
$reports = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $d = Resolve-ReportDate -File $f
    if ($null -ne $sinceDt -and $d.Date -lt $sinceDt) { continue }
    if ($null -ne $untilDt -and $d.Date -gt $untilDt) { continue }
    $html = Get-Content -LiteralPath $f.FullName -Raw
    $revoked  = Get-RevokedItems  -Html $html
    $newScope = Get-NewScopeItems -Html $html
    $approved = Get-ApprovedTotal -Html $html
    $reports.Add([pscustomobject]@{
        File          = $f.Name
        Date          = $d.Date
        Label         = $d.Label
        Fallback      = [bool]$d.Fallback
        Revoked       = $revoked
        NewScope      = $newScope
        ApprovedTotal = $approved
    })
}
$reports = @($reports | Sort-Object Date, Label)
if ($reports.Count -eq 0) { Write-Host "No reports in the requested date window." -ForegroundColor Yellow; exit 0 }

# Distinct report days
$dateLabels = @($reports | ForEach-Object { $_.Label } | Sort-Object -Unique)
$totalDays = $dateLabels.Count
$fallbackFileCount = @($reports | Where-Object Fallback).Count

# ---------------------------------------------------------------------------
# Dedupe + date attribution.
# The V4b registers are CUMULATIVE campaign snapshots: every daily report re-lists all
# revocations/new-scope approvals made so far, and each row carries the item's own
# Decision Date. Summing rows across a multi-day window therefore counted every item
# once per report day it survived in, and stamping rows with the report file's date put
# decisions on the wrong day. Items are de-duplicated across reports (first sighting
# wins) and bucketed by their own Decision Date, falling back to the first report day
# that listed them.
# ---------------------------------------------------------------------------
$allRevoked  = New-Object System.Collections.Generic.List[object]
$allNewScope = New-Object System.Collections.Generic.List[object]
$seenRevoked  = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
$seenNewScope = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

# The dedupe key includes the item's own DecisionDate, so DISTINCT revoke/approve
# EVENTS (different decision dates) are NEVER collapsed -- a grant revoked twice in
# the window counts twice, on both days (and is surfaced in the Re-Revoked Grants
# register below). Only identical re-listings of the same event across the daily
# cumulative snapshots collapse. A duplicate of the same key WITHIN ONE report file
# is a different animal -- upstream cache/render duplication -- and is counted as a
# data-quality warning instead of being silently collapsed.
$intraReportDupes = 0
$intraReportDupeExamples = New-Object System.Collections.Generic.List[string]
foreach ($rep in $reports) {
    $seenThisReport = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $rep.Revoked) {
        $key = "$($item.Identity)|$($item.AccessName)|$($item.Source)|$($item.Reviewer)|$($item.DecisionDate)"
        if (-not $seenThisReport.Add("R|$key")) {
            $intraReportDupes++
            if ($intraReportDupeExamples.Count -lt 5) { $intraReportDupeExamples.Add("$($rep.File): REVOKED $($item.Identity) / $($item.AccessName)") }
        }
        if (-not $seenRevoked.Add($key)) { continue }
        $allRevoked.Add([pscustomobject]@{
            Date          = (Resolve-DecisionDay -RawDecisionDate $item.DecisionDate -ReportDate $rep.Date).ToString('yyyy-MM-dd')
            Identity      = $item.Identity
            AccessName    = $item.AccessName
            Source        = $item.Source
            Reviewer      = $item.Reviewer
            Justification = $item.Justification
        })
    }
    foreach ($item in $rep.NewScope) {
        $key = "$($item.Identity)|$($item.AccessName)|$($item.Source)|$($item.Reviewer)|$($item.DecisionDate)"
        if (-not $seenThisReport.Add("N|$key")) {
            $intraReportDupes++
            if ($intraReportDupeExamples.Count -lt 5) { $intraReportDupeExamples.Add("$($rep.File): NEW SCOPE $($item.Identity) / $($item.AccessName)") }
        }
        if (-not $seenNewScope.Add($key)) { continue }
        $allNewScope.Add([pscustomobject]@{
            Date       = (Resolve-DecisionDay -RawDecisionDate $item.DecisionDate -ReportDate $rep.Date).ToString('yyyy-MM-dd')
            Identity   = $item.Identity
            AccessName = $item.AccessName
            Source     = $item.Source
            Reviewer   = $item.Reviewer
        })
    }
}

# Daily activity buckets keyed by DECISION day (union across both series, sorted) so
# the three charts and the raw-numbers table share one aligned date axis.
$dailyRevoked  = @{}
$dailyNewScope = @{}
foreach ($it in $allRevoked)  { if (-not $dailyRevoked.ContainsKey($it.Date))  { $dailyRevoked[$it.Date]  = 0 }; $dailyRevoked[$it.Date]++ }
foreach ($it in $allNewScope) { if (-not $dailyNewScope.ContainsKey($it.Date)) { $dailyNewScope[$it.Date] = 0 }; $dailyNewScope[$it.Date]++ }
# Chart/table axis: every decision day PLUS every report day. A report day with no
# decision activity renders as a zero bar/row -- "the report ran and nothing was
# decided that day" is evidence, and its absence read as missing days. Weekend/
# holiday gaps with neither a report nor activity stay absent. $activityDays (the
# averages' denominator and the Decision Days KPI) still counts only days with
# actual activity, so quiet report days do not dilute the averages.
$decisionDayLabels = @(@($dailyRevoked.Keys) + @($dailyNewScope.Keys) | Sort-Object -Unique)
$activityDays = $decisionDayLabels.Count
$activityLabels = @(($decisionDayLabels + $dateLabels) | Sort-Object -Unique)

$totalRevoked  = $allRevoked.Count
$totalNewScope = $allNewScope.Count
$netChange     = $totalRevoked - $totalNewScope
$avgRevoked    = if ($activityDays -gt 0) { [math]::Round($totalRevoked / $activityDays, 1) } else { 0 }
$avgNewScope   = if ($activityDays -gt 0) { [math]::Round($totalNewScope / $activityDays, 1) } else { 0 }

# Approved totals: campaign-to-date levels scraped per report (when the campaign summary
# table is present). Latest snapshot + growth across the window; -1 = not available.
$approvedSnapshots = @($reports | Where-Object { $_.ApprovedTotal -ge 0 })
$approvedLatest = if ($approvedSnapshots.Count -gt 0) { [int]$approvedSnapshots[-1].ApprovedTotal } else { -1 }
$approvedDelta  = if ($approvedSnapshots.Count -ge 2) { [int]$approvedSnapshots[-1].ApprovedTotal - [int]$approvedSnapshots[0].ApprovedTotal } else { $null }

# Build daily count arrays for the charts (shared axis)
$revokedCounts  = @($activityLabels | ForEach-Object { if ($dailyRevoked.ContainsKey($_))  { $dailyRevoked[$_] }  else { 0 } })
$newScopeCounts = @($activityLabels | ForEach-Object { if ($dailyNewScope.ContainsKey($_)) { $dailyNewScope[$_] } else { 0 } })

# Top Revoked Entitlements (group by AccessName)
$entitlementGroups = @{}
foreach ($item in $allRevoked) {
    $key = $item.AccessName
    if (-not $entitlementGroups.ContainsKey($key)) {
        $entitlementGroups[$key] = @{
            Count     = 0
            Sources   = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
            Reviewers = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        }
    }
    $entitlementGroups[$key].Count++
    [void]$entitlementGroups[$key].Sources.Add($item.Source)
    [void]$entitlementGroups[$key].Reviewers.Add($item.Reviewer)
}
$topEntitlements = @($entitlementGroups.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{
        AccessName = $_.Key
        Count      = $_.Value.Count
        Sources    = ($_.Value.Sources | Sort-Object) -join ', '
        Reviewers  = ($_.Value.Reviewers | Sort-Object) -join ', '
    }
} | Sort-Object -Property @{Expression='Count';Descending=$true}, @{Expression='AccessName'})
$entitlementLimit = if ($Top -gt 0) { $Top } else { 15 }
$topEntitlementsShown = @($topEntitlements | Select-Object -First $entitlementLimit)

# Top Revoked Identities (group by Identity)
$identityGroups = @{}
foreach ($item in $allRevoked) {
    $key = $item.Identity
    if (-not $identityGroups.ContainsKey($key)) {
        $identityGroups[$key] = @{
            Count       = 0
            AccessNames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
            Reviewers   = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        }
    }
    $identityGroups[$key].Count++
    [void]$identityGroups[$key].AccessNames.Add($item.AccessName)
    [void]$identityGroups[$key].Reviewers.Add($item.Reviewer)
}
$topIdentities = @($identityGroups.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{
        Identity    = $_.Key
        Count       = $_.Value.Count
        AccessNames = ($_.Value.AccessNames | Sort-Object) -join ', '
        Reviewers   = ($_.Value.Reviewers | Sort-Object) -join ', '
    }
} | Sort-Object -Property @{Expression='Count';Descending=$true}, @{Expression='Identity'})
$identityLimit = if ($Top -gt 0) { $Top } else { 15 }
$topIdentitiesShown = @($topIdentities | Select-Object -First $identityLimit)

# Source Breakdown (group all decisions by Source)
$sourceGroups = @{}
foreach ($item in $allRevoked) {
    $key = $item.Source
    if (-not $sourceGroups.ContainsKey($key)) { $sourceGroups[$key] = @{ Revoked = 0; NewScope = 0 } }
    $sourceGroups[$key].Revoked++
}
foreach ($item in $allNewScope) {
    $key = $item.Source
    if (-not $sourceGroups.ContainsKey($key)) { $sourceGroups[$key] = @{ Revoked = 0; NewScope = 0 } }
    $sourceGroups[$key].NewScope++
}
$sourceRows = @($sourceGroups.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{
        Source    = $_.Key
        Revoked  = $_.Value.Revoked
        NewScope = $_.Value.NewScope
        Net      = $_.Value.Revoked - $_.Value.NewScope
    }
} | Sort-Object -Property @{Expression='Revoked';Descending=$true}, @{Expression='Source'})

# ---------------------------------------------------------------------------
# Re-approved flops: the same grant (identity|access|source, reviewer-agnostic)
# REVOKED earlier in the window and approved again later. The source registers are
# CURRENT-STATE snapshots, so on re-approval an item silently LEAVES the Revoked
# register (its count can shrink between two reports) and re-enters New Scope with a
# fresh decision date. Surfaced explicitly: a shrinking Revoked count is otherwise
# unexplainable, and re-grants of revoked access are the primary re-grant signal.
# Only flops whose revoke AND re-approval both fall inside the window are detectable.
# ---------------------------------------------------------------------------
$revokeDayByGrant = @{}
foreach ($it in $allRevoked) {
    $gk = "$($it.Identity)|$($it.AccessName)|$($it.Source)".ToLowerInvariant()
    if (-not $revokeDayByGrant.ContainsKey($gk) -or ([string]$it.Date) -lt ([string]$revokeDayByGrant[$gk])) { $revokeDayByGrant[$gk] = [string]$it.Date }
}
$reApprovedFlops = New-Object System.Collections.Generic.List[object]
foreach ($it in $allNewScope) {
    $gk = "$($it.Identity)|$($it.AccessName)|$($it.Source)".ToLowerInvariant()
    if ($revokeDayByGrant.ContainsKey($gk) -and (([string]$revokeDayByGrant[$gk]) -lt ([string]$it.Date))) {
        $reApprovedFlops.Add([pscustomobject]@{
            Identity      = $it.Identity
            AccessName    = $it.AccessName
            Source        = $it.Source
            Reviewer      = $it.Reviewer
            RevokedDay    = [string]$revokeDayByGrant[$gk]
            ReApprovedDay = [string]$it.Date
        })
    }
}
$reApprovedFlops = @($reApprovedFlops | Sort-Object -Property @{Expression='ReApprovedDay';Descending=$true}, @{Expression='Identity'})

# ---------------------------------------------------------------------------
# Re-revoked grants: the same grant (identity|access|source) revoked on MORE THAN
# ONE distinct decision day in the window. Revoke events are never de-duplicated
# across decision dates, so each event is already counted -- this register makes the
# pattern visible: revoked access that came back (failed remediation, re-provisioning,
# or a revoke -> approve -> revoke flip) and had to be revoked again.
# ---------------------------------------------------------------------------
$revokesByGrant = @{}
foreach ($it in $allRevoked) {
    $gk = "$($it.Identity)|$($it.AccessName)|$($it.Source)".ToLowerInvariant()
    if (-not $revokesByGrant.ContainsKey($gk)) { $revokesByGrant[$gk] = New-Object System.Collections.Generic.List[object] }
    $revokesByGrant[$gk].Add($it)
}
$reRevokedGrants = New-Object System.Collections.Generic.List[object]
foreach ($gk in $revokesByGrant.Keys) {
    $events = @($revokesByGrant[$gk] | Sort-Object Date)
    $distinctDays = @($events | ForEach-Object { [string]$_.Date } | Sort-Object -Unique)
    if ($distinctDays.Count -lt 2) { continue }
    $reRevokedGrants.Add([pscustomobject]@{
        Identity    = $events[0].Identity
        AccessName  = $events[0].AccessName
        Source      = $events[0].Source
        TimesRevoked = $distinctDays.Count
        RevokeDays  = ($distinctDays -join ', ')
        Reviewers   = (@($events | ForEach-Object { [string]$_.Reviewer } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
    })
}
$reRevokedGrants = @($reRevokedGrants | Sort-Object -Property @{Expression='TimesRevoked';Descending=$true}, @{Expression='Identity'})

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------
if ($OutputMode -in @('Console', 'Both')) {
    Write-Host ''
    Write-Host "Decision Activity Scrape: $totalDays day(s) from $($reports.Count) report(s) [$($reports[0].Label) .. $($reports[-1].Label)]" -ForegroundColor Cyan
    if ($fallbackFileCount -gt 0) { Write-Host "  NOTE: $fallbackFileCount file(s) dated by file-modified time (filename date not parseable)" -ForegroundColor Yellow }
    Write-Host "  Decision activity spans $activityDays decision day(s) (deduped across cumulative daily snapshots, dated by Decision Date)" -ForegroundColor DarkGray
    Write-Host "  Revoked:    $totalRevoked distinct items (avg ${avgRevoked}/decision day)" -ForegroundColor Red
    Write-Host "  New Scope:  $totalNewScope distinct items (avg ${avgNewScope}/decision day)" -ForegroundColor Green
    if (@($reApprovedFlops).Count -gt 0) { Write-Host "  Re-Approved After Revoke (flops): $(@($reApprovedFlops).Count) grant(s) revoked earlier in the window and approved again" -ForegroundColor Yellow }
    if (@($reRevokedGrants).Count -gt 0) { Write-Host "  Re-Revoked Grants: $(@($reRevokedGrants).Count) grant(s) revoked on more than one day -- access came back after a revoke" -ForegroundColor Yellow }
    if ($intraReportDupes -gt 0) { Write-Host "  DATA QUALITY: $intraReportDupes duplicate row(s) WITHIN single reports (same grant+reviewer+decision date twice in one file) -- possible upstream cache duplication" -ForegroundColor Yellow }
    if ($approvedLatest -ge 0) {
        $apDeltaTxt = if ($null -ne $approvedDelta) { " ($(if ($approvedDelta -ge 0) { "+$approvedDelta" } else { $approvedDelta }) across the window)" } else { '' }
        Write-Host "  Approved:   $('{0:N0}' -f $approvedLatest) campaign-to-date$apDeltaTxt" -ForegroundColor Cyan
    }
    $netLabel = if ($netChange -gt 0) { 'access reduced' } elseif ($netChange -lt 0) { 'access grew' } else { 'no net change' }
    $netSign = if ($netChange -gt 0) { "+$netChange" } else { "$netChange" }
    Write-Host "  Net Change: $netSign ($netLabel)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Top Revoked Entitlements:' -ForegroundColor White
    foreach ($ent in $topEntitlementsShown | Select-Object -First 10) {
        $padded = $ent.AccessName.PadRight(30)
        Write-Host "    $padded $($ent.Count) revocations" -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  Top Revoked Identities:' -ForegroundColor White
    foreach ($id in $topIdentitiesShown | Select-Object -First 10) {
        $padded = $id.Identity.PadRight(25)
        Write-Host "    $padded $($id.Count) revocations" -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# HTML dashboard
# ---------------------------------------------------------------------------
if ($OutputMode -in @('HTML', 'Both')) {
    if (-not $OutputPath) { $OutputPath = $Path }
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = [System.IO.Path]::GetFullPath((Join-Path $PWD $OutputPath))
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $OutputPath "Decision-Activity-Tracker-$stamp.html"

    $trendSvg        = New-SvgDailyDecisionTrend -Dates $activityLabels -RevokedCounts $revokedCounts -NewScopeCounts $newScopeCounts
    $revokedOnlySvg  = New-SvgDailySeries -Dates $activityLabels -Counts $revokedCounts  -Fill '#c0392b'
    $newScopeOnlySvg = New-SvgDailySeries -Dates $activityLabels -Counts $newScopeCounts -Fill '#27ae60'

    # Raw per-day numbers backing the charts (exact counts even when bars are too
    # narrow to carry value labels). Cumulative columns reconcile the daily
    # first-sightings back to register-style running totals: a source report showing
    # 35 new-scope items the day after one showing 28 is 7 first-sightings that day,
    # and the cumulative column reads 35.
    $dailyNumbersRows = if ($activityLabels.Count -gt 0) {
        $cumRev = 0; $cumNew = 0
        (0..($activityLabels.Count - 1) | ForEach-Object {
            $net = $revokedCounts[$_] - $newScopeCounts[$_]
            $cumRev += $revokedCounts[$_]; $cumNew += $newScopeCounts[$_]
            "<tr><td>$(ConvertTo-Safe $activityLabels[$_])</td><td style='text-align:right'>$($revokedCounts[$_])</td><td style='text-align:right'>$($newScopeCounts[$_])</td><td style='text-align:right'>$(if ($net -gt 0) { "+$net" } else { $net })</td><td style='text-align:right;color:#777'>$cumRev</td><td style='text-align:right;color:#777'>$cumNew</td></tr>"
        }) -join "`n"
    } else { "<tr><td colspan='6' style='color:#777;font-style:italic'>No decision activity found.</td></tr>" }

    # Re-approved flop table rows (Section 2 sub-table)
    $flopRows = if (@($reApprovedFlops).Count -gt 0) {
        (@($reApprovedFlops) | ForEach-Object {
            "<tr><td>$(ConvertTo-Safe $_.Identity)</td><td>$(ConvertTo-Safe $_.AccessName)</td><td>$(ConvertTo-Safe $_.Source)</td><td>$(ConvertTo-Safe $_.Reviewer)</td><td style='color:#c0392b'>$(ConvertTo-Safe $_.RevokedDay)</td><td style='color:#27ae60'>$(ConvertTo-Safe $_.ReApprovedDay)</td></tr>"
        }) -join "`n"
    } else { "<tr><td colspan='6' style='color:#777;font-style:italic'>None detected in this window.</td></tr>" }

    # Approved KPI tile (only when the campaign summary table was scrapeable)
    $approvedKpi = if ($approvedLatest -ge 0) {
        $apDeltaLbl = if ($null -ne $approvedDelta) { ", $(if ($approvedDelta -ge 0) { "+$approvedDelta" } else { $approvedDelta }) this window" } else { '' }
        "<div class='kpi'><div class='value' style='color:#2c7fb8'>$('{0:N0}' -f $approvedLatest)</div><div class='label'>Approved (campaign-to-date$apDeltaLbl)</div></div>"
    } else { '' }

    # Re-approved flop KPI tile (only when flops were detected)
    $flopKpi = if (@($reApprovedFlops).Count -gt 0) {
        "<div class='kpi'><div class='value' style='color:#e67e22'>$(@($reApprovedFlops).Count)</div><div class='label'>Re-Approved After Revoke</div></div>"
    } else { '' }

    # Re-revoked grants KPI tile (only when repeats were detected)
    $reRevokedKpi = if (@($reRevokedGrants).Count -gt 0) {
        "<div class='kpi'><div class='value' style='color:#c0392b'>$(@($reRevokedGrants).Count)</div><div class='label'>Re-Revoked Grants</div></div>"
    } else { '' }

    # Data-quality warning (intra-report duplicate rows -- possible cache duplication)
    $dupeWarning = if ($intraReportDupes -gt 0) {
        "<div class='note' style='color:#9a6700;border:1px solid #ffd97a;background:#fff7e6;padding:6px 10px'><strong>Data quality:</strong> $intraReportDupes duplicate row(s) found WITHIN single reports (the same identity + access + source + reviewer + decision date listed twice in one file). Cross-day repetition is normal for these cumulative registers; a duplicate inside ONE report is not, and may indicate upstream cache duplication. Examples: $(ConvertTo-Safe ($intraReportDupeExamples -join '; '))</div>"
    } else { '' }

    # Re-revoked table rows (Section 2 sub-table)
    $reRevokedRows = if (@($reRevokedGrants).Count -gt 0) {
        (@($reRevokedGrants) | ForEach-Object {
            "<tr><td>$(ConvertTo-Safe $_.Identity)</td><td>$(ConvertTo-Safe $_.AccessName)</td><td>$(ConvertTo-Safe $_.Source)</td><td style='text-align:right;color:#c0392b;font-weight:600'>$($_.TimesRevoked)</td><td>$(ConvertTo-Safe $_.RevokeDays)</td><td>$(ConvertTo-Safe $_.Reviewers)</td></tr>"
        }) -join "`n"
    } else { "<tr><td colspan='6' style='color:#777;font-style:italic'>None detected in this window -- no grant was revoked on more than one day.</td></tr>" }

    # Net change styling
    $netColor = if ($netChange -gt 0) { '#27ae60' } elseif ($netChange -lt 0) { '#c0392b' } else { '#888' }
    $netDisplay = if ($netChange -gt 0) { "+$netChange" } else { "$netChange" }
    $netNote = if ($netChange -gt 0) { 'access reduced' } elseif ($netChange -lt 0) { 'access grew' } else { 'no net change' }

    # Detail registers get a hard default cap: a single real report day can carry 17k+
    # new-scope rows, and an unbounded register made the "Word/email safe" HTML tens of
    # MB. -Top overrides; any truncation is disclosed in the section header.
    $detailLimit = if ($Top -gt 0) { $Top } else { 500 }

    # Section 3: Revoked detail table
    $revokedSorted = @($allRevoked | Sort-Object -Property @{Expression='Date';Descending=$true}, @{Expression='Identity'})
    $revokedShown = @($revokedSorted | Select-Object -First $detailLimit)
    $revokedDetailRows = ($revokedShown | ForEach-Object {
        "<tr><td>$(ConvertTo-Safe $_.Date)</td><td>$(ConvertTo-Safe $_.Identity)</td><td>$(ConvertTo-Safe $_.AccessName)</td><td>$(ConvertTo-Safe $_.Source)</td><td>$(ConvertTo-Safe $_.Reviewer)</td><td>$(ConvertTo-Safe $_.Justification)</td></tr>"
    }) -join "`n"

    # Section 4: Top entitlements table
    $entitlementTableRows = ($topEntitlementsShown | ForEach-Object {
        "<tr><td>$(ConvertTo-Safe $_.AccessName)</td><td style='text-align:right'>$($_.Count)</td><td>$(ConvertTo-Safe $_.Sources)</td><td>$(ConvertTo-Safe $_.Reviewers)</td></tr>"
    }) -join "`n"

    # Section 5: Top identities table
    $identityTableRows = ($topIdentitiesShown | ForEach-Object {
        "<tr><td>$(ConvertTo-Safe $_.Identity)</td><td style='text-align:right'>$($_.Count)</td><td>$(ConvertTo-Safe $_.AccessNames)</td><td>$(ConvertTo-Safe $_.Reviewers)</td></tr>"
    }) -join "`n"

    # Section 6: New scope detail table
    $newScopeSorted = @($allNewScope | Sort-Object -Property @{Expression='Date';Descending=$true}, @{Expression='Identity'})
    $newScopeShown = @($newScopeSorted | Select-Object -First $detailLimit)
    $newScopeDetailRows = ($newScopeShown | ForEach-Object {
        "<tr><td>$(ConvertTo-Safe $_.Date)</td><td>$(ConvertTo-Safe $_.Identity)</td><td>$(ConvertTo-Safe $_.AccessName)</td><td>$(ConvertTo-Safe $_.Source)</td><td>$(ConvertTo-Safe $_.Reviewer)</td></tr>"
    }) -join "`n"

    # Section 7: Source breakdown table
    $sourceTableRows = ($sourceRows | ForEach-Object {
        $nc = $_.Net
        $ncColor = if ($nc -gt 0) { '#27ae60' } elseif ($nc -lt 0) { '#c0392b' } else { '#888' }
        $ncDisplay = if ($nc -gt 0) { "+$nc" } else { "$nc" }
        "<tr><td>$(ConvertTo-Safe $_.Source)</td><td style='text-align:right'>$($_.Revoked)</td><td style='text-align:right'>$($_.NewScope)</td><td style='text-align:right;color:$ncColor;font-weight:600'>$ncDisplay</td></tr>"
    }) -join "`n"

    $revokedDetailNote = if ($allRevoked.Count -gt $detailLimit) { " (showing $detailLimit of $($allRevoked.Count) -- use -Top to adjust)" } else { '' }
    $newScopeDetailNote = if ($allNewScope.Count -gt $detailLimit) { " (showing $detailLimit of $($allNewScope.Count) -- use -Top to adjust)" } else { '' }

    $doc = @"
<!DOCTYPE html><html><head><meta charset='utf-8'><title>Decision Activity Tracker</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;color:#222;margin:18px;background:#fff}
h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:22px 0 8px;border-bottom:1px solid #e1e4e8;padding-bottom:4px}
h3{font-size:13px;margin:14px 0 4px;color:#444}
.meta{color:#555;font-size:12px;margin-bottom:6px}
table.report{border-collapse:collapse;font-size:12px;margin-top:6px}
table.report th,table.report td{border:1px solid #e1e4e8;padding:4px 8px}
table.report th{background:#f6f8fa;text-align:left}
.note{color:#777;font-size:11px;margin-top:4px}
.kpi-row{display:flex;flex-wrap:wrap;gap:14px;margin:12px 0}
.kpi{border:1px solid #e1e4e8;border-radius:6px;padding:12px 18px;min-width:120px;text-align:center}
.kpi .value{font-size:28px;font-weight:700;line-height:1.1}
.kpi .label{font-size:11px;color:#555;margin-top:4px}
summary{cursor:pointer;font-weight:600;padding:4px 0}
</style></head><body>
<h1>Decision Activity Tracker</h1>
<div class='meta'>Source: $(ConvertTo-Safe $Path) &nbsp;|&nbsp; $totalDays day(s) from $($reports.Count) report(s), $($reports[0].Label) &rarr; $($reports[-1].Label)$(if ($fallbackFileCount -gt 0) { " &nbsp;|&nbsp; $fallbackFileCount file(s) dated by file-modified time" }) &nbsp;|&nbsp; generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
<div class='note'>Sourced from daily evidence reports. Summarizes revoked and newly approved access decisions across the reporting period. "New Scope" counts truly new access only -- "Newly Decided" approvals of items that already existed in the prior campaign are intentionally excluded from these totals and from Net Change.</div>
$dupeWarning

<h2>1. Decision Activity Summary</h2>
<div class='kpi-row'>
<div class='kpi'><div class='value' style='color:#c0392b'>$totalRevoked</div><div class='label'>Total Revoked (distinct)</div></div>
<div class='kpi'><div class='value' style='color:#27ae60'>$totalNewScope</div><div class='label'>Total New Scope (distinct)</div></div>
$approvedKpi
$flopKpi
$reRevokedKpi
<div class='kpi'><div class='value' style='color:$netColor'>$netDisplay</div><div class='label'>Net Change ($netNote)</div></div>
<div class='kpi'><div class='value' style='color:#336699'>$totalDays</div><div class='label'>Report Days</div></div>
<div class='kpi'><div class='value' style='color:#336699'>$activityDays</div><div class='label'>Decision Days</div></div>
<div class='kpi'><div class='value' style='color:#c0392b'>$avgRevoked</div><div class='label'>Avg Revoked/Decision Day</div></div>
<div class='kpi'><div class='value' style='color:#27ae60'>$avgNewScope</div><div class='label'>Avg New Scope/Decision Day</div></div>
</div>

<h2>2. Daily Decision Trend</h2>
<div class='note'>Counts are bucketed by each item's own Decision Date (not the report file date) and de-duplicated
across the window's cumulative daily snapshots -- the same revocation listed in 20 consecutive reports counts once,
on the day it was decided. Red = revoked; green = newly approved (new scope).
<br><strong>Reading these against the source reports:</strong> the reports' section headers are campaign-cumulative
CURRENT-STATE counts, so a report showing 35 new-scope items the day after one showing 28 means 7 first-sightings
that day -- the bars show the 7, and the Cumulative columns in the raw table read 35. A Revoked count that SHRINKS
between two reports means a revoked item was re-approved (it leaves the register); those grants are listed in the
Re-Approved After Revoke table below. Every report day appears on the axis: a zero bar means the report ran and
nothing was decided that day. Days absent entirely had neither a report nor any decision activity (weekends/holidays).</div>
<h3>Combined &mdash; revoked vs new scope per day</h3>
<div style='overflow-x:auto'>$trendSvg</div>
<h3>Revoked only</h3>
<div style='overflow-x:auto'>$revokedOnlySvg</div>
<h3>New scope only</h3>
<div style='overflow-x:auto'>$newScopeOnlySvg</div>
<h3>Raw daily numbers</h3>
<table class='report'><thead><tr><th>Decision Day</th><th style='text-align:right'>Revoked</th><th style='text-align:right'>New Scope</th><th style='text-align:right'>Net (Rev - New)</th><th style='text-align:right'>Cumulative Revoked</th><th style='text-align:right'>Cumulative New Scope</th></tr></thead>
<tbody>
$dailyNumbersRows
</tbody></table>

<h3>Re-Approved After Revoke (flops)</h3>
<div class='note'>Grants revoked earlier in the window and approved again later (approve -&gt; revoke -&gt; approve).
Detected by matching identity + access + source across the deduped revoked and new-scope registers; the reviewer
shown is the re-approver. Only flops whose revoke AND re-approval both fall inside the scraped window are
detectable here -- the V4g/V8 state database tracks re-approvals across any time span.</div>
<table class='report'><thead><tr><th>Identity</th><th>Access Name</th><th>Source</th><th>Re-Approved By</th><th>Revoked On</th><th>Re-Approved On</th></tr></thead>
<tbody>
$flopRows
</tbody></table>

<h3>Re-Revoked Grants (repeat revocations)</h3>
<div class='note'>The same grant (identity + access + source) revoked on MORE THAN ONE decision day in the window --
revoked access that came back (failed remediation, re-provisioning, or a revoke -&gt; approve -&gt; revoke flip) and had
to be revoked again. Distinct revoke events are never de-duplicated: each one counts in the totals and charts on its
own day; this table makes the repeat pattern visible.</div>
<table class='report'><thead><tr><th>Identity</th><th>Access Name</th><th>Source</th><th style='text-align:right'>Times Revoked</th><th>Revoke Days</th><th>Reviewers</th></tr></thead>
<tbody>
$reRevokedRows
</tbody></table>

<h2>3. Revoked Access Detail</h2>
<details><summary>Revoked Access Register &mdash; $totalRevoked distinct items across $activityDays decision day(s)$revokedDetailNote</summary>
<table class='report'><thead><tr><th>Decision Day</th><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Justification</th></tr></thead>
<tbody>
$revokedDetailRows
</tbody></table>
</details>

<h2>4. Top Revoked Entitlements</h2>
<div class='note'>Entitlements most frequently revoked across the reporting period.</div>
<table class='report'><thead><tr><th>Access Name</th><th style='text-align:right'>Times Revoked</th><th>Sources</th><th>Reviewers</th></tr></thead>
<tbody>
$entitlementTableRows
</tbody></table>

<h2>5. Top Revoked Identities</h2>
<div class='note'>Identities with the most access revocations across the reporting period.</div>
<table class='report'><thead><tr><th>Identity</th><th style='text-align:right'>Times Revoked</th><th>Access Names</th><th>Reviewers</th></tr></thead>
<tbody>
$identityTableRows
</tbody></table>

<h2>6. New Scope &mdash; Approved Access</h2>
<details><summary>New Scope &mdash; Approved Access &mdash; $totalNewScope distinct items across $activityDays decision day(s)$newScopeDetailNote</summary>
<table class='report'><thead><tr><th>Decision Day</th><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th></tr></thead>
<tbody>
$newScopeDetailRows
</tbody></table>
</details>

<h2>7. Source Breakdown</h2>
<div class='note'>Decision totals by source system. Positive net change = access reduced; negative = access grew.</div>
<table class='report'><thead><tr><th>Source</th><th style='text-align:right'>Revoked</th><th style='text-align:right'>New Scope</th><th style='text-align:right'>Net Change</th></tr></thead>
<tbody>
$sourceTableRows
</tbody></table>

<div style='text-align:center;color:#999;font-size:11px;padding:16px;margin-top:24px;border-top:1px solid #eee'>
Decision Activity Tracker | $totalDays day(s) from $($reports.Count) report(s) | $($reports[0].Label) to $($reports[-1].Label) | SailPoint ISC Governance Toolkit
</div>
</body></html>
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outFile, $doc, $utf8NoBom)
    Write-Host "Wrote dashboard: $outFile" -ForegroundColor Green
    if ($OutputMode -eq 'HTML') { Write-Output $outFile }
}

#Requires -Version 5.1
<#
.SYNOPSIS
    Ad-hoc analyzer: scrape a folder of daily evidence HTML reports and summarize
    Revoked and Newly Approved (New Scope) access decisions across the reporting period.

.DESCRIPTION
    Reads the "final" daily evidence HTML reports you already produce -- by default named
    Daily-Attestation-Evidence-Report-<date>.html, where <date> is auto-parsed from the
    filename (falling back to the file's LastWriteTime). For each report it finds every
    collapsible whose <summary> mentions "Revoked" (with class s-red) and "New Scope" or
    "Approved Access" (with class s-green), and extracts decision details from the tables.

    It then renders a self-contained HTML dashboard (inline SVG, no JavaScript -- Word/email safe):
      1. Decision Activity Summary -- KPI tiles (total revoked, new scope, net change, averages).
      2. Daily Decision Trend     -- paired red/green bars per report day.
      3. Revoked Access Detail    -- full register of every revocation (collapsible).
      4. Top Revoked Entitlements -- which entitlements were revoked most often.
      5. Top Revoked Identities   -- which identities had the most revocations.
      6. New Scope Detail         -- full register of approved access (collapsible).
      7. Source Breakdown         -- revoked vs new scope by source system.

    READ-ONLY: it reads HTML and writes a report; it never calls ISC and never mutates anything.

.PARAMETER Path
    Folder containing the daily evidence HTML reports. Default: .\Audit\daily-evidence.

.PARAMETER FilePattern
    Wildcard for the report files. Default: 'Daily-Attestation-Evidence-Report-*.html'.

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
    Limit detail tables and rankings to the Top N rows (0 = default limits). Default 0.

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
    [Parameter()][string]$FilePattern = 'Daily-Attestation-Evidence-Report-*.html',
    [Parameter()][int]$DaysBack = 0,
    [Parameter()][string]$Since,
    [Parameter()][string]$Until,
    [Parameter()][string]$OutputPath,
    [Parameter()][ValidateSet('Console', 'HTML', 'Both')][string]$OutputMode = 'Both',
    [Parameter()][int]$Top = 0,
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
            return @{ Date = $dt.Date; Label = $dt.ToString('yyyy-MM-dd') }
        }
    }
    $m = [regex]::Match($token, '\d{4}[-.]?\d{2}[-.]?\d{2}')
    if ($m.Success) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse($m.Value, [ref]$dt)) { return @{ Date = $dt; Label = $dt.ToString('yyyy-MM-dd') } }
    }
    return @{ Date = $File.LastWriteTime.Date; Label = $File.LastWriteTime.ToString('yyyy-MM-dd') + '*' }
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
                $justification = if ($cells.Count -ge 7) { Remove-HtmlTags $cells[6].Groups[1].Value } else { '' }
                if ([string]::IsNullOrWhiteSpace($identity)) { continue }
                $items.Add([pscustomobject]@{
                    Identity      = $identity
                    AccessName    = $accessName
                    Source        = $source
                    Reviewer      = $reviewer
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
                $identity   = Remove-HtmlTags $cells[0].Groups[1].Value
                $accessName = Remove-HtmlTags $cells[1].Groups[1].Value
                $source     = Remove-HtmlTags $cells[2].Groups[1].Value
                $reviewer   = Remove-HtmlTags $cells[3].Groups[1].Value
                if ([string]::IsNullOrWhiteSpace($identity)) { continue }
                $items.Add([pscustomobject]@{
                    Identity   = $identity
                    AccessName = $accessName
                    Source     = $source
                    Reviewer   = $reviewer
                })
            }
        }
    }
    return ,$items.ToArray()
}

# ---------------------------------------------------------------------------
# SVG chart builders (no JS -- Word/email safe)
# ---------------------------------------------------------------------------
function New-SvgDailyDecisionTrend {
    param($Dates, $RevokedCounts, $NewScopeCounts)
    if ($Dates.Count -eq 0) { return '<p style="color:#777">No dates to trend.</p>' }
    $barW = 12; $pairGap = 4; $groupGap = 10; $chartH = 160; $labelH = 60
    $allCounts = @($RevokedCounts) + @($NewScopeCounts)
    $max = ([int](@($allCounts | Measure-Object -Maximum).Maximum)); if ($max -lt 1) { $max = 1 }
    $groupW = ($barW * 2) + $pairGap + $groupGap
    $w = ($Dates.Count * $groupW) + 40
    $h = $chartH + $labelH
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg width='$w' height='$h' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial,sans-serif' font-size='10'>")
    for ($i = 0; $i -lt $Dates.Count; $i++) {
        $gx = 30 + ($i * $groupW)
        # Revoked bar (red)
        $rh = [int]($chartH * ($RevokedCounts[$i] / $max))
        $ryTop = $chartH - $rh
        [void]$sb.Append("<rect x='$gx' y='$ryTop' width='$barW' height='$rh' rx='2' fill='#c0392b'/>")
        if ($RevokedCounts[$i] -gt 0) {
            [void]$sb.Append("<text x='$($gx + $barW/2)' y='$($ryTop - 2)' text-anchor='middle' fill='#c0392b' font-size='9'>$($RevokedCounts[$i])</text>")
        }
        # New scope bar (green)
        $nx = $gx + $barW + $pairGap
        $nh = [int]($chartH * ($NewScopeCounts[$i] / $max))
        $nyTop = $chartH - $nh
        [void]$sb.Append("<rect x='$nx' y='$nyTop' width='$barW' height='$nh' rx='2' fill='#27ae60'/>")
        if ($NewScopeCounts[$i] -gt 0) {
            [void]$sb.Append("<text x='$($nx + $barW/2)' y='$($nyTop - 2)' text-anchor='middle' fill='#27ae60' font-size='9'>$($NewScopeCounts[$i])</text>")
        }
        # Date label
        $lx = $gx + $barW + ($pairGap / 2)
        [void]$sb.Append("<text x='$lx' y='$($chartH + 12)' transform='rotate(-60 $lx,$($chartH + 12))' fill='#555'>$(ConvertTo-Safe $Dates[$i])</text>")
    }
    # Legend
    $legX = $w - 160
    [void]$sb.Append("<rect x='$legX' y='2' width='10' height='10' rx='1' fill='#c0392b'/><text x='$($legX+14)' y='11' fill='#555'>Revoked</text>")
    [void]$sb.Append("<rect x='$($legX+70)' y='2' width='10' height='10' rx='1' fill='#27ae60'/><text x='$($legX+84)' y='11' fill='#555'>New Scope</text>")
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "ERROR: Path not found: $Path" -ForegroundColor Red; exit 2 }
$files = @(Get-ChildItem -LiteralPath $Path -Filter $FilePattern -File | Sort-Object Name)
if ($files.Count -eq 0) { Write-Host "No files matching '$FilePattern' in $Path" -ForegroundColor Yellow; exit 0 }

# -DaysBack N: resolve from the actual report file dates (not calendar days).
if ($DaysBack -gt 0) {
    $allFileDates = [System.Collections.Generic.List[datetime]]::new()
    foreach ($f in $files) {
        $d = Resolve-ReportDate -File $f
        if ($null -ne $d -and $d.Date -ne [datetime]::MinValue) {
            if (-not $allFileDates.Contains($d.Date)) { $allFileDates.Add($d.Date) }
        }
    }
    $sortedDates = @($allFileDates | Sort-Object)
    if ($sortedDates.Count -gt $DaysBack) {
        $cutoffDate = $sortedDates[$sortedDates.Count - $DaysBack]
        $Since = $cutoffDate.ToString('yyyy-MM-dd')
        Write-Host "  -DaysBack $DaysBack -> using $DaysBack most recent report days (since $Since)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  -DaysBack $DaysBack -> only $($sortedDates.Count) report day(s) available, using all" -ForegroundColor DarkGray
    }
}

$sinceDt = $null; $untilDt = $null
if ($Since) { $tmp = [datetime]::MinValue; if ([datetime]::TryParse($Since, [ref]$tmp)) { $sinceDt = $tmp.Date } }
if ($Until) { $tmp = [datetime]::MinValue; if ([datetime]::TryParse($Until, [ref]$tmp)) { $untilDt = $tmp.Date } }

# Parse every report -> collect revoked and new scope items per date.
$reports = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $d = Resolve-ReportDate -File $f
    if ($null -ne $sinceDt -and $d.Date -lt $sinceDt) { continue }
    if ($null -ne $untilDt -and $d.Date -gt $untilDt) { continue }
    $html = Get-Content -LiteralPath $f.FullName -Raw
    $revoked  = Get-RevokedItems  -Html $html
    $newScope = Get-NewScopeItems -Html $html
    $reports.Add([pscustomobject]@{
        File      = $f.Name
        Date      = $d.Date
        Label     = $d.Label
        Revoked   = $revoked
        NewScope  = $newScope
    })
}
$reports = @($reports | Sort-Object Date, Label)
if ($reports.Count -eq 0) { Write-Host "No reports in the requested date window." -ForegroundColor Yellow; exit 0 }

# Distinct report days
$dateLabels = @($reports | ForEach-Object { $_.Label } | Sort-Object -Unique)
$totalDays = $dateLabels.Count

# Flatten all items with date labels
$allRevoked  = New-Object System.Collections.Generic.List[object]
$allNewScope = New-Object System.Collections.Generic.List[object]
$dailyRevoked  = @{}
$dailyNewScope = @{}
foreach ($dl in $dateLabels) { $dailyRevoked[$dl] = 0; $dailyNewScope[$dl] = 0 }

foreach ($rep in $reports) {
    foreach ($item in $rep.Revoked) {
        $allRevoked.Add([pscustomobject]@{
            Date          = $rep.Label
            Identity      = $item.Identity
            AccessName    = $item.AccessName
            Source        = $item.Source
            Reviewer      = $item.Reviewer
            Justification = $item.Justification
        })
        $dailyRevoked[$rep.Label] = $dailyRevoked[$rep.Label] + 1
    }
    foreach ($item in $rep.NewScope) {
        $allNewScope.Add([pscustomobject]@{
            Date       = $rep.Label
            Identity   = $item.Identity
            AccessName = $item.AccessName
            Source     = $item.Source
            Reviewer   = $item.Reviewer
        })
        $dailyNewScope[$rep.Label] = $dailyNewScope[$rep.Label] + 1
    }
}

$totalRevoked  = $allRevoked.Count
$totalNewScope = $allNewScope.Count
$netChange     = $totalRevoked - $totalNewScope
$avgRevoked    = if ($totalDays -gt 0) { [math]::Round($totalRevoked / $totalDays, 1) } else { 0 }
$avgNewScope   = if ($totalDays -gt 0) { [math]::Round($totalNewScope / $totalDays, 1) } else { 0 }

# Build daily count arrays for the chart
$revokedCounts  = @($dateLabels | ForEach-Object { $dailyRevoked[$_] })
$newScopeCounts = @($dateLabels | ForEach-Object { $dailyNewScope[$_] })

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
# Console output
# ---------------------------------------------------------------------------
if ($OutputMode -in @('Console', 'Both')) {
    Write-Host ''
    Write-Host "Decision Activity Scrape: $totalDays day(s) from $($reports.Count) report(s) [$($reports[0].Label) .. $($reports[-1].Label)]" -ForegroundColor Cyan
    Write-Host "  Revoked:    $totalRevoked items (avg ${avgRevoked}/day)" -ForegroundColor Red
    Write-Host "  New Scope:  $totalNewScope items (avg ${avgNewScope}/day)" -ForegroundColor Green
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
    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $OutputPath "Decision-Activity-Tracker-$stamp.html"

    $trendSvg = New-SvgDailyDecisionTrend -Dates $dateLabels -RevokedCounts $revokedCounts -NewScopeCounts $newScopeCounts

    # Net change styling
    $netColor = if ($netChange -gt 0) { '#27ae60' } elseif ($netChange -lt 0) { '#c0392b' } else { '#888' }
    $netDisplay = if ($netChange -gt 0) { "+$netChange" } else { "$netChange" }
    $netNote = if ($netChange -gt 0) { 'access reduced' } elseif ($netChange -lt 0) { 'access grew' } else { 'no net change' }

    # Section 3: Revoked detail table
    $revokedSorted = @($allRevoked | Sort-Object -Property @{Expression='Date';Descending=$true}, @{Expression='Identity'})
    if ($Top -gt 0) { $revokedSorted = @($revokedSorted | Select-Object -First $Top) }
    $revokedDetailRows = ($revokedSorted | ForEach-Object {
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
    if ($Top -gt 0) { $newScopeSorted = @($newScopeSorted | Select-Object -First $Top) }
    $newScopeDetailRows = ($newScopeSorted | ForEach-Object {
        "<tr><td>$(ConvertTo-Safe $_.Date)</td><td>$(ConvertTo-Safe $_.Identity)</td><td>$(ConvertTo-Safe $_.AccessName)</td><td>$(ConvertTo-Safe $_.Source)</td><td>$(ConvertTo-Safe $_.Reviewer)</td></tr>"
    }) -join "`n"

    # Section 7: Source breakdown table
    $sourceTableRows = ($sourceRows | ForEach-Object {
        $nc = $_.Net
        $ncColor = if ($nc -gt 0) { '#27ae60' } elseif ($nc -lt 0) { '#c0392b' } else { '#888' }
        $ncDisplay = if ($nc -gt 0) { "+$nc" } else { "$nc" }
        "<tr><td>$(ConvertTo-Safe $_.Source)</td><td style='text-align:right'>$($_.Revoked)</td><td style='text-align:right'>$($_.NewScope)</td><td style='text-align:right;color:$ncColor;font-weight:600'>$ncDisplay</td></tr>"
    }) -join "`n"

    $revokedDetailNote = if ($Top -gt 0) { " (showing top $Top)" } else { '' }
    $newScopeDetailNote = if ($Top -gt 0) { " (showing top $Top)" } else { '' }

    $doc = @"
<!DOCTYPE html><html><head><meta charset='utf-8'><title>Decision Activity Tracker</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;color:#222;margin:18px;background:#fff}
h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:22px 0 8px;border-bottom:1px solid #e1e4e8;padding-bottom:4px}
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
<div class='meta'>Source: $(ConvertTo-Safe $Path) &nbsp;|&nbsp; $totalDays day(s) from $($reports.Count) report(s), $($reports[0].Label) &rarr; $($reports[-1].Label) &nbsp;|&nbsp; generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
<div class='note'>Sourced from daily evidence reports. Summarizes revoked and newly approved access decisions across the reporting period.</div>

<h2>1. Decision Activity Summary</h2>
<div class='kpi-row'>
<div class='kpi'><div class='value' style='color:#c0392b'>$totalRevoked</div><div class='label'>Total Revoked</div></div>
<div class='kpi'><div class='value' style='color:#27ae60'>$totalNewScope</div><div class='label'>Total New Scope</div></div>
<div class='kpi'><div class='value' style='color:$netColor'>$netDisplay</div><div class='label'>Net Change ($netNote)</div></div>
<div class='kpi'><div class='value' style='color:#336699'>$totalDays</div><div class='label'>Report Days</div></div>
<div class='kpi'><div class='value' style='color:#c0392b'>$avgRevoked</div><div class='label'>Avg Revoked/Day</div></div>
<div class='kpi'><div class='value' style='color:#27ae60'>$avgNewScope</div><div class='label'>Avg New Scope/Day</div></div>
</div>

<h2>2. Daily Decision Trend</h2>
<div class='note'>Red bars = revoked items; green bars = newly approved (new scope) items per report day.</div>
<div style='overflow-x:auto'>$trendSvg</div>

<h2>3. Revoked Access Detail</h2>
<details><summary>Revoked Access Register &mdash; $totalRevoked items across $totalDays day(s)$revokedDetailNote</summary>
<table class='report'><thead><tr><th>Date</th><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Justification</th></tr></thead>
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
<details><summary>New Scope &mdash; Approved Access &mdash; $totalNewScope items across $totalDays day(s)$newScopeDetailNote</summary>
<table class='report'><thead><tr><th>Date</th><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th></tr></thead>
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

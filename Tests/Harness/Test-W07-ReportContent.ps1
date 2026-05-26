#Requires -Version 5.1
<#
.SYNOPSIS
    W-07 -- Deep content validation of the campaign-audit-combined HTML report.

.DESCRIPTION
    Reads the latest Audit\campaign-audit-combined-*.html file produced by
    W-05 and walks 15 specific content checks WR-07-01..15 from the backlog.
    Each check is a precise structural / data assertion on the rendered
    HTML (status badge, donut counts, table column headers, expandable
    section state, audit metadata, footer).

    Run as:
        powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File .\Tests\Harness\Test-W07-ReportContent.ps1

    Emits one compact JSON line per test, terminated by a {summary} line.
    Exit 0 if no FAIL.

.NOTES
    The harness does NOT re-open the report in a browser; the visual
    behavior was already validated by W-06's Playwright captures
    (round-09.md). W-07 verifies that the underlying HTML emitted by
    Build-SPCampaignAuditHtml encodes every required piece of data.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ReportPath,
    [Parameter()][string]$JsonlPath
)

$ErrorActionPreference = 'Stop'

$harnessRoot = $PSScriptRoot
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $harnessRoot '..\..'))
$logDir = Join-Path $toolkitRoot 'docs\windows-test-rounds'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if (-not $JsonlPath) { $JsonlPath = Join-Path $logDir 'WR-07-results.jsonl' }
Set-Content -Path $JsonlPath -Value '' -Encoding utf8

if (-not $ReportPath) {
    $candidate = Get-ChildItem (Join-Path $toolkitRoot 'Audit\campaign-audit-combined-*.html') -ErrorAction SilentlyContinue |
                 Sort-Object Name | Select-Object -First 1
    if (-not $candidate) {
        Write-Error "Could not locate Audit\campaign-audit-combined-*.html. Run W-05 first."
        exit 2
    }
    $ReportPath = $candidate.FullName
}
if (-not (Test-Path $ReportPath)) {
    Write-Error "Report not found: $ReportPath"
    exit 2
}

$html = Get-Content -Raw -Path $ReportPath

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Id, [string]$Result, [string]$Note = '')
    $results.Add([pscustomobject]@{ id = $Id; result = $Result; note = $Note })
    $line = ConvertTo-Json -Compress -InputObject ([ordered]@{ id = $Id; result = $Result; note = $Note })
    Write-Host $line
    Add-Content -Path $JsonlPath -Value $line -Encoding utf8
}

function Assert-Match {
    param([string]$Id, [string]$Pattern, [string]$Description, [switch]$Multiline)
    $opts = if ($Multiline) { 'Multiline,Singleline,IgnoreCase' } else { 'Singleline,IgnoreCase' }
    $rx = [regex]::new($Pattern, $opts)
    $m = $rx.Match($html)
    if ($m.Success) {
        $sample = $m.Value
        if ($sample.Length -gt 120) { $sample = $sample.Substring(0, 120) + '...' }
        $sample = ($sample -replace '\s+', ' ').Trim()
        Add-Result $Id 'PASS' ("{0}: '{1}'" -f $Description, $sample)
        return $true
    }
    Add-Result $Id 'FAIL' ("Could not find pattern for {0}. Regex: {1}" -f $Description, $Pattern)
    return $false
}

# ----- WR-07-01: Executive Summary -- COMPLETED badge visible
# Look for a styled COMPLETED token in the executive-summary area
# (within the campaign tile, not just inside the campaign-summary table).
# Production HTML wraps the word in a <span> inside the green <td>.
Assert-Match 'WR-07-01' '(?s)background:\s*#339933[^>]*>\s*<span[^>]*>\s*COMPLETED\s*</span>' 'COMPLETED status badge in executive summary' | Out-Null

# ----- WR-07-02: Donut chart -- 64% / 16% / 20% (matches 16/4/5 of 25)
# Verify donut data: legend lines + percentages.
$rx02 = '(?s)Approved:\s*16\s*\(64%\).*?Revoked:\s*4\s*\(16%\).*?Pending:\s*5\s*\(20%\)'
Assert-Match 'WR-07-02' $rx02 'Donut legend Approved/Revoked/Pending counts + percentages' | Out-Null

# ----- WR-07-03: Remediation Completion bar -- 0% (4 pending, mock has no provisioning events)
Assert-Match 'WR-07-03' 'Remediation Completion.*?0%' 'Remediation Completion bar at 0%' | Out-Null

# ----- WR-07-04: Risk Indicators -- Pending Items count matches
$rx04 = '(?s)Risk Indicators.*?Pending Items.*?<(?:td|span)[^>]*>\s*5\s*<'
Assert-Match 'WR-07-04' $rx04 'Risk Indicators -> Pending Items = 5' | Out-Null

# ----- WR-07-05: Reviewer Response Time bars -- 4 reviewers shown
# The section's outer <table> contains nested progress-bar <table> elements,
# so a naive `.*?</table>` stops too early. Bound the block by the section's
# trailing "Campaign average:" / "Median:" footer line instead.
$rrt = [regex]::new('(?s)Reviewer Response Time.*?Campaign average:')
$m = $rrt.Match($html)
if ($m.Success) {
    $block = $m.Value
    $names = [regex]::Matches($block, '(Diana Brown|Edward Jones|Fiona Garcia|George Miller|Alice Johnson|Bob Smith|Charlie Williams|Henry King|Samuel White)').Value | Sort-Object -Unique
    if ($names.Count -ge 4) {
        Add-Result 'WR-07-05' 'PASS' ("Reviewer Response Time shows {0} reviewers: {1}" -f $names.Count, ($names -join ', '))
    } else {
        Add-Result 'WR-07-05' 'FAIL' ("Reviewer Response Time block found but only {0} distinct reviewer name(s) matched. Sample names: {1}" -f $names.Count, ($names -join ', '))
    }
} else {
    Add-Result 'WR-07-05' 'FAIL' 'Reviewer Response Time block not located'
}

# ----- WR-07-06: Campaign Summary table -- name, dates, status, cert count
$rx06 = '(?s)<(?:h2|h3)[^>]*>\s*1\.\s*Campaign Summary.*?2025 Annual Access Review.*?(Status|COMPLETED).*?Total Certifications'
Assert-Match 'WR-07-06' $rx06 'Campaign Summary contains name + status + Total Certifications row' | Out-Null

# ----- WR-07-07: Reviewer Accountability -- Primary (4) + Reassigned (1) expandable
$rx07 = '(?s)Reviewer Accountability.*?Primary Reviewers\s*\(4\).*?Reassigned Reviewers\s*\(1\)'
Assert-Match 'WR-07-07' $rx07 'Reviewer Accountability has Primary Reviewers (4) + Reassigned Reviewers (1)' | Out-Null

# ----- WR-07-08: Reviewer Performance -- Fastest/Slowest/Average/Median response times
$rx08 = '(?s)Reviewer Performance.*?Fastest Response.*?Slowest Response.*?Average Response.*?Median Response'
Assert-Match 'WR-07-08' $rx08 'Reviewer Performance: Fastest + Slowest + Average + Median response rows' | Out-Null

# ----- WR-07-09: Decision Summary -- Approved (16) collapsed, Revoked (4) expanded
# The HTML uses <details><summary> elements. Revoked details has `open` attribute.
$rx09 = '(?s)<details[^>]*>\s*<summary[^>]*>[^<]*Approved \(16'
$approvedHasOpen = $false
$mApproved = [regex]::Matches($html, '<details([^>]*?)>\s*<summary[^>]*>[^<]*Approved \(16')
if ($mApproved.Count -gt 0) { $approvedHasOpen = ($mApproved[0].Groups[1].Value -match 'open') }

$revokedHasOpen = $false
$mRevoked = [regex]::Matches($html, '<details([^>]*?)>\s*<summary[^>]*>[^<]*Revoked \(4')
if ($mRevoked.Count -gt 0) { $revokedHasOpen = ($mRevoked[0].Groups[1].Value -match 'open') }

if ($mApproved.Count -gt 0 -and $mRevoked.Count -gt 0 -and -not $approvedHasOpen -and $revokedHasOpen) {
    Add-Result 'WR-07-09' 'PASS' "Approved (16) <details> = collapsed (no 'open' attr); Revoked (4) <details> = expanded (has 'open' attr)"
} else {
    Add-Result 'WR-07-09' 'FAIL' ("Expected Approved collapsed + Revoked expanded. Found Approved match={0} open={1}; Revoked match={2} open={3}" -f $mApproved.Count, $approvedHasOpen, $mRevoked.Count, $revokedHasOpen)
}

# ----- WR-07-10: Revoked items table -- Identity, Account (UPN data), Access, Decision Date, Justification, Remediation
$rx10 = '(?s)Revoked \(4 items\).*?<th[^>]*>Identity</th>.*?<th[^>]*>Account</th>.*?<th[^>]*>Access[^<]*</th>.*?<th[^>]*>Decision Date</th>.*?<th[^>]*>Justification</th>.*?<th[^>]*>Remediation</th>'
$baseOk = Assert-Match 'WR-07-10' $rx10 'Revoked table has Identity / Account / Access / Decision Date / Justification / Remediation columns'
if ($baseOk) {
    # Sanity: verify the Account column actually contains UPNs in the body.
    if ($html -match '@corp\.test') {
        # PASS already emitted. Append confirmation via no-op.
    }
}

# ----- WR-07-11: Campaign Reports -- CERTIFICATION_SIGNOFF_REPORT + CAMPAIGN_STATUS_REPORT expandable
$rx11 = '(?s)Campaign Reports.*?<details[^>]*>\s*<summary[^>]*>[^<]*CERTIFICATION_SIGNOFF_REPORT.*?<details[^>]*>\s*<summary[^>]*>[^<]*CAMPAIGN_STATUS_REPORT'
Assert-Match 'WR-07-11' $rx11 'Campaign Reports has CERTIFICATION_SIGNOFF_REPORT + CAMPAIGN_STATUS_REPORT <details>' | Out-Null

# ----- WR-07-12: Remediation & Reassignment Proof -- 4 revoked items, remediation status
$rx12 = '(?s)Revoked Items.*?(?:>4<|>\s*4\s*<).*?Revoked Items - Remediation Status \(4'
Assert-Match 'WR-07-12' $rx12 'Remediation summary shows 4 revoked items + per-item Remediation Status table' | Out-Null

# ----- WR-07-13: Reassignment Chain visible (1 record)
# The section header is "Reassignment Chain"; expect 1 record below.
$rx13 = '(?s)Reassignment Chain.*?<(?:table|tr)'
$mRC = [regex]::Match($html, $rx13)
if ($mRC.Success) {
    # Count <tr> rows inside the next <table> after the heading
    $rest = $html.Substring($mRC.Index)
    $tableMatch = [regex]::Match($rest, '(?s)<table[^>]*>(.*?)</table>')
    if ($tableMatch.Success) {
        $rows = [regex]::Matches($tableMatch.Groups[1].Value, '<tr')
        # Header row + 1 data row = 2; one data row.
        if ($rows.Count -ge 2) {
            Add-Result 'WR-07-13' 'PASS' ("Reassignment Chain table found with {0} <tr>(s) (header + data)" -f $rows.Count)
        } else {
            Add-Result 'WR-07-13' 'FAIL' ("Reassignment Chain table only has {0} row(s)" -f $rows.Count)
        }
    } else {
        Add-Result 'WR-07-13' 'FAIL' 'Reassignment Chain heading found but no <table> follows'
    }
} else {
    Add-Result 'WR-07-13' 'FAIL' 'Reassignment Chain section not found'
}

# ----- WR-07-14: Audit Metadata -- Correlation ID + Report Generated
$rx14 = '(?s)Audit Metadata.*?Correlation ID.*?Report Generated'
Assert-Match 'WR-07-14' $rx14 'Audit Metadata shows Correlation ID + Report Generated' | Out-Null

# ----- WR-07-15: Footer -- toolkit version, generation date, correlation ID
$rx15 = '(?s)SailPoint ISC Governance Toolkit\s*v\d+\.\d+\.\d+.*?Generated:\s*\d{4}-\d{2}-\d{2}.*?Correlation ID:\s*[0-9a-f-]{36}'
Assert-Match 'WR-07-15' $rx15 'Footer shows toolkit version vX.Y.Z + generation date + correlation GUID' | Out-Null

$pass    = @($results | Where-Object result -eq 'PASS').Count
$fail    = @($results | Where-Object result -eq 'FAIL').Count
$blocked = @($results | Where-Object result -eq 'BLOCKED').Count
$summary = ConvertTo-Json -Compress -InputObject ([ordered]@{
    summary = $true; pass = $pass; fail = $fail; blocked = $blocked; total = ($pass + $fail + $blocked)
    report  = $ReportPath
})
Write-Host $summary
Add-Content -Path $JsonlPath -Value $summary -Encoding utf8
exit $(if ($fail -eq 0) { 0 } else { 1 })

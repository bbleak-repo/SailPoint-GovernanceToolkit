#Requires -Version 5.1
<#
.SYNOPSIS
    Generates 15 realistic daily evidence HTML report files in V4b format for testing
    the Invoke-SPPendingReviewerScrape.ps1 scraper.
.DESCRIPTION
    Creates mock daily attestation evidence reports with:
      - 30 distinct reviewers across 6 behavior profiles
      - Realistic decision distributions (85-92% approved, 2-5% revoked)
      - Pending/Undecided reviewer sections parseable by the scraper
      - Revoked items with identity names, access names, sources, justifications
      - New scope approved items
    Uses a fixed random seed (42) for reproducible output.
.PARAMETER OutputPath
    Directory for the generated HTML files.
    Default: Audit\daily-evidence\mock-test (relative to toolkit root).
.NOTES
    Script:  New-SPMockDailyReports.ps1
    Version: 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter()][string]$OutputPath
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $toolkitRoot 'Audit\daily-evidence\mock-test'
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host ''
Write-Host '  Mock Daily Evidence Report Generator (V4b format)' -ForegroundColor Cyan
Write-Host '  ==================================================' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------------------
# Fixed-seed RNG for reproducibility
# ---------------------------------------------------------------------------
$rng = [System.Random]::new(42)

# ---------------------------------------------------------------------------
# Date range: 15 business days 2026-07-14 through 2026-08-01
# ---------------------------------------------------------------------------
$businessDays = @()
$cursor = [datetime]::new(2026, 7, 13)
$endDate = [datetime]::new(2026, 7, 31)
while ($cursor -le $endDate) {
    if ($cursor.DayOfWeek -ne 'Saturday' -and $cursor.DayOfWeek -ne 'Sunday') {
        $businessDays += $cursor
    }
    $cursor = $cursor.AddDays(1)
}
if ($businessDays.Count -ne 15) {
    Write-Warning "Expected 15 business days, got $($businessDays.Count). Proceeding with available days."
}

Write-Host "  Date range: $($businessDays[0].ToString('yyyy-MM-dd')) to $($businessDays[-1].ToString('yyyy-MM-dd')) ($($businessDays.Count) business days)" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 30 distinct reviewer names with behavior profiles
# ---------------------------------------------------------------------------
# Profile: AlwaysComplete (15), UsuallyComplete (5), Inconsistent (4),
#          UsuallyMiss (3), Chronic (2), Improving (1)

$reviewers = @(
    # Always complete (15) -- never pending
    @{ Name = 'Sarah Mitchell';    Email = 's.mitchell@contoso.com';    Profile = 'AlwaysComplete' }
    @{ Name = 'Robert Chen';       Email = 'r.chen@contoso.com';       Profile = 'AlwaysComplete' }
    @{ Name = 'Jennifer Park';     Email = 'j.park@contoso.com';       Profile = 'AlwaysComplete' }
    @{ Name = 'Michael Torres';    Email = 'm.torres@contoso.com';     Profile = 'AlwaysComplete' }
    @{ Name = 'Amanda Kowalski';   Email = 'a.kowalski@contoso.com';   Profile = 'AlwaysComplete' }
    @{ Name = 'David Nakamura';    Email = 'd.nakamura@contoso.com';   Profile = 'AlwaysComplete' }
    @{ Name = 'Lisa Fernandez';    Email = 'l.fernandez@contoso.com';  Profile = 'AlwaysComplete' }
    @{ Name = 'James Richardson';  Email = 'j.richardson@contoso.com'; Profile = 'AlwaysComplete' }
    @{ Name = 'Patricia Okafor';   Email = 'p.okafor@contoso.com';     Profile = 'AlwaysComplete' }
    @{ Name = 'Thomas Bergstrom';  Email = 't.bergstrom@contoso.com';  Profile = 'AlwaysComplete' }
    @{ Name = 'Rachel Kapoor';     Email = 'r.kapoor@contoso.com';     Profile = 'AlwaysComplete' }
    @{ Name = 'Christopher Lang';  Email = 'c.lang@contoso.com';       Profile = 'AlwaysComplete' }
    @{ Name = 'Maria Volkov';      Email = 'm.volkov@contoso.com';     Profile = 'AlwaysComplete' }
    @{ Name = 'Daniel Estrada';    Email = 'd.estrada@contoso.com';    Profile = 'AlwaysComplete' }
    @{ Name = 'Katherine Wu';      Email = 'k.wu@contoso.com';         Profile = 'AlwaysComplete' }

    # Usually complete (5) -- pending ~15% of days (~2 of 15)
    @{ Name = 'Brian Hoffmann';    Email = 'b.hoffmann@contoso.com';   Profile = 'UsuallyComplete' }
    @{ Name = 'Angela Petrov';     Email = 'a.petrov@contoso.com';     Profile = 'UsuallyComplete' }
    @{ Name = 'Steven Adeyemi';    Email = 's.adeyemi@contoso.com';    Profile = 'UsuallyComplete' }
    @{ Name = 'Laura Svensson';    Email = 'l.svensson@contoso.com';   Profile = 'UsuallyComplete' }
    @{ Name = 'Kevin Morales';     Email = 'k.morales@contoso.com';    Profile = 'UsuallyComplete' }

    # Inconsistent (4) -- pending ~50% of days (alternating)
    @{ Name = 'Nathan Gupta';      Email = 'n.gupta@contoso.com';      Profile = 'Inconsistent' }
    @{ Name = 'Diane Okonkwo';     Email = 'd.okonkwo@contoso.com';    Profile = 'Inconsistent' }
    @{ Name = 'Gregory Larsen';    Email = 'g.larsen@contoso.com';     Profile = 'Inconsistent' }
    @{ Name = 'Sandra Reeves';     Email = 's.reeves@contoso.com';     Profile = 'Inconsistent' }

    # Usually miss (3) -- pending ~75% of days
    @{ Name = 'Edward Mbeki';      Email = 'e.mbeki@contoso.com';      Profile = 'UsuallyMiss' }
    @{ Name = 'Monica Vasquez';    Email = 'm.vasquez@contoso.com';    Profile = 'UsuallyMiss' }
    @{ Name = 'Philip Johansson';  Email = 'p.johansson@contoso.com';  Profile = 'UsuallyMiss' }

    # Chronic (2) -- pending ~95% of days
    @{ Name = 'Howard Fitzgerald'; Email = 'h.fitzgerald@contoso.com'; Profile = 'Chronic' }
    @{ Name = 'Carmen Delgado';    Email = 'c.delgado@contoso.com';    Profile = 'Chronic' }

    # Improving (1) -- pending first 10 days, clear last 5
    @{ Name = 'Vincent Sharma';    Email = 'v.sharma@contoso.com';     Profile = 'Improving' }
)

# ---------------------------------------------------------------------------
# Identity names, access names, sources, justifications for revoked/new-scope
# ---------------------------------------------------------------------------
$identityNames = @(
    'James Wilson', 'Maria Santos', 'Oliver Brown', 'Fatima Al-Hassan', 'Liam Murphy',
    'Priya Patel', 'Alexander Nowak', 'Yuki Tanaka', 'Elena Popova', 'Marcus Johnson',
    'Sophie Dubois', 'Carlos Ramirez', 'Ingrid Andersen', 'Wei Zhang', 'Amara Osei',
    'Ryan O''Brien', 'Isabelle Laurent', 'Dmitri Ivanov', 'Chloe Kim', 'Hassan Ali',
    'Natalie Gruber', 'Samuel Ekwueme', 'Julia Schneider', 'Tariq Mahmoud', 'Emma Lindqvist',
    'Oscar Herrera', 'Aisha Diallo', 'Nikolai Petrov', 'Victoria Chang', 'Luke Patterson',
    'Zara Ahmed', 'Felix Bergmann', 'Camille Fontaine', 'Raj Krishnamurthy', 'Megan Stewart',
    'Youssef Benali', 'Astrid Holm', 'Gabriel Costa', 'Nadia Kowalczyk', 'Trevor Blackwell'
)

$accessNames = @(
    'AD_Domain_Admins', 'VPN_FullTunnel', 'SAP_Finance_Write', 'Azure_GlobalAdmin',
    'Exchange_FullAccess', 'CyberArk_SafeAdmin', 'SQL_DBA_Prod', 'AWS_PowerUser',
    'ServiceNow_ITIL_Admin', 'Salesforce_SysAdmin', 'AD_Schema_Admins', 'VPN_SplitTunnel',
    'SAP_HR_Read', 'SharePoint_SiteCollAdmin', 'AD_Enterprise_Admins', 'Citrix_Admin',
    'Oracle_DBA_Prod', 'SCCM_FullAdmin', 'AD_GPO_Admins', 'Exchange_OrgAdmin',
    'AWS_IAMAdmin', 'Azure_SubContributor', 'Jira_ProjectAdmin', 'AD_DNS_Admins',
    'NetApp_VolumeAdmin', 'PaloAlto_FW_Admin', 'Splunk_Admin', 'AD_DHCP_Admins',
    'Tableau_ServerAdmin', 'ServiceNow_SecurityAdmin'
)

$sourceNames = @(
    'Corporate Active Directory', 'Azure AD', 'SAP ERP', 'AWS IAM',
    'CyberArk Vault', 'ServiceNow ITSM', 'Salesforce Production',
    'Oracle EBS', 'Citrix NetScaler', 'Palo Alto Networks'
)

$justifications = @(
    'Role no longer required', 'Transfer to new department', 'Terminated',
    'Duplicate entitlement removed', 'Excessive privileges identified',
    'Contractor engagement ended', 'Project completed', 'Least privilege enforcement',
    'Security audit finding', 'Manager requested removal', 'Compliance remediation',
    'Access not used in 90+ days', 'Temporary access expired', 'Segregation of duties conflict',
    'Organizational restructuring'
)

$newScopeAccessNames = @(
    'AD_VPN_Users', 'SharePoint_DeptSite_Read', 'SAP_Logistics_Read', 'Azure_Reader',
    'ServiceNow_Fulfiller', 'Salesforce_StandardUser', 'Jira_Developer', 'Confluence_Space_Member',
    'Teams_ChannelOwner', 'AD_RemoteDesktop_Users', 'Citrix_AppAccess', 'AWS_S3ReadOnly',
    'Tableau_Viewer', 'Oracle_AppUser', 'AD_PrintOperators'
)

# ---------------------------------------------------------------------------
# Helper: determine if a reviewer is pending on a given day index (0-14)
# ---------------------------------------------------------------------------
function Test-ReviewerPending {
    param([hashtable]$Reviewer, [int]$DayIndex, [System.Random]$Rng)

    switch ($Reviewer.Profile) {
        'AlwaysComplete'  { return $false }
        'UsuallyComplete' { return ($Rng.NextDouble() -lt 0.15) }
        'Inconsistent'    { return ($Rng.NextDouble() -lt 0.50) }
        'UsuallyMiss'     { return ($Rng.NextDouble() -lt 0.75) }
        'Chronic'         { return ($Rng.NextDouble() -lt 0.95) }
        'Improving'       { return ($DayIndex -lt 10) }
        default           { return $false }
    }
}

# ---------------------------------------------------------------------------
# Generate reports
# ---------------------------------------------------------------------------
$totalRevokedAll = 0
$totalNewScopeAll = 0
$pendingTracker = [ordered]@{}  # reviewer -> list of date strings

foreach ($rev in $reviewers) {
    $pendingTracker[$rev.Name] = [System.Collections.Generic.List[string]]::new()
}

$generatedFiles = @()

for ($dayIdx = 0; $dayIdx -lt $businessDays.Count; $dayIdx++) {
    $reportDate = $businessDays[$dayIdx]
    $dateStr = $reportDate.ToString('yyyy-MM-dd')
    $dayOfWeek = $reportDate.ToString('dddd')

    # Determine pending reviewers for this day
    $pendingReviewers = @()
    foreach ($rev in $reviewers) {
        $isPending = Test-ReviewerPending -Reviewer $rev -DayIndex $dayIdx -Rng $rng
        if ($isPending) {
            $pendingReviewers += $rev
            $pendingTracker[$rev.Name].Add($dateStr)
        }
    }

    $pendingCount = $pendingReviewers.Count

    # Items per reviewer: ~200, total ~6000
    $itemsPerReviewer = 200
    $totalItems = $reviewers.Count * $itemsPerReviewer  # 6000

    # Pending items: from pending reviewers (each has ~200 items undecided)
    $pendingItems = $pendingCount * $itemsPerReviewer

    # Revoked: 12-30 items per day
    $revokedCount = $rng.Next(12, 31)
    $totalRevokedAll += $revokedCount

    # New scope approved: 5-15 items per day
    $newScopeCount = $rng.Next(5, 16)
    $totalNewScopeAll += $newScopeCount

    # Approved: remaining items minus pending and revoked
    $decidedItems = $totalItems - $pendingItems
    $approvedCount = $decidedItems - $revokedCount
    if ($approvedCount -lt 0) { $approvedCount = 0 }

    $totalIdentities = 180 + $rng.Next(0, 21)  # 180-200
    $completedReviewers = $reviewers.Count - $pendingCount

    # Approval rate
    $approvalPct = if ($totalItems -gt 0) { [math]::Round($approvedCount * 100.0 / $totalItems, 1) } else { 0 }
    $revokedPct = if ($totalItems -gt 0) { [math]::Round($revokedCount * 100.0 / $totalItems, 1) } else { 0 }
    $pendingPct = if ($totalItems -gt 0) { [math]::Round($pendingItems * 100.0 / $totalItems, 1) } else { 0 }

    # Build pending reviewer rows
    $pendingRowsSb = New-Object System.Text.StringBuilder
    foreach ($pr in $pendingReviewers) {
        $undecidedItems = $itemsPerReviewer + $rng.Next(-20, 21)  # 180-220
        [void]$pendingRowsSb.AppendLine("<tr><td>$($pr.Name)</td><td>$($pr.Email)</td><td style='text-align:right'>$undecidedItems</td><td style='text-align:right'>$itemsPerReviewer</td><td>Outstanding since campaign start</td></tr>")
    }
    $pendingRowsHtml = $pendingRowsSb.ToString()

    # Build revoked items rows
    $revokedRowsSb = New-Object System.Text.StringBuilder
    for ($ri = 0; $ri -lt $revokedCount; $ri++) {
        $idName = $identityNames[$rng.Next($identityNames.Count)]
        $accName = $accessNames[$rng.Next($accessNames.Count)]
        $srcName = $sourceNames[$rng.Next($sourceNames.Count)]
        # Reviewer from the "always complete" pool (first 15)
        $revName = $reviewers[$rng.Next(0, 15)].Name
        $justification = $justifications[$rng.Next($justifications.Count)]
        $accountName = ($idName.Split(' ')[0][0] + '.' + $idName.Split(' ')[-1]).ToLower()
        [void]$revokedRowsSb.AppendLine("<tr><td>$idName</td><td>$accountName</td><td>$accName</td><td>$srcName</td><td>$revName</td><td>$dateStr</td><td>$justification</td></tr>")
    }
    $revokedRowsHtml = $revokedRowsSb.ToString()

    # Build new scope approved rows
    $newScopeRowsSb = New-Object System.Text.StringBuilder
    for ($ni = 0; $ni -lt $newScopeCount; $ni++) {
        $idName = $identityNames[$rng.Next($identityNames.Count)]
        $accName = $newScopeAccessNames[$rng.Next($newScopeAccessNames.Count)]
        $srcName = $sourceNames[$rng.Next($sourceNames.Count)]
        $revName = $reviewers[$rng.Next(0, 15)].Name
        [void]$newScopeRowsSb.AppendLine("<tr><td>$idName</td><td>$accName</td><td>$srcName</td><td>$revName</td><td>$dateStr</td></tr>")
    }
    $newScopeRowsHtml = $newScopeRowsSb.ToString()

    # Build HTML document
    $html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>Daily Evidence Report - $dateStr</title>
<style>
*{box-sizing:border-box}
body{font-family:"Segoe UI",Arial,sans-serif;background:#f4f6f9;color:#333;margin:0;padding:20px}
.container{max-width:1100px;margin:0 auto}
.header{background:linear-gradient(135deg,#264d73,#336699);color:#fff;padding:24px 32px;border-radius:8px 8px 0 0}
.header h1{margin:0 0 6px;font-size:22px}
.header .meta{font-size:12px;opacity:.85}
.section{background:#fff;border:1px solid #e0e0e0;border-top:none;padding:20px 32px}
.section h2{color:#264d73;font-size:15px;border-bottom:2px solid #e8eef5;padding-bottom:6px;margin-top:0}
table.report{border-collapse:collapse;width:100%;margin:12px 0;font-size:12px}
table.report th{background:#e8eef5;padding:8px 10px;text-align:left;font-weight:600;font-size:11px;text-transform:uppercase;color:#555}
table.report td{padding:7px 10px;border-bottom:1px solid #eee}
.s-green{color:#339933;font-weight:600}
.s-red{color:#CC3333;font-weight:600}
.s-amber{color:#9a6700;font-weight:600}
.footer{text-align:center;color:#999;font-size:11px;padding:16px;border-top:1px solid #eee}
summary{cursor:pointer;font-weight:600}
</style></head><body><div class="container">

<!-- Header -->
<div class="header">
<h1>Daily Evidence Report</h1>
<div class="meta">SailPoint ISC Governance Toolkit | Report generated: $dateStr | Period: Last 1 day(s)</div>
</div>

<!-- Certification Scope -->
<div class="section"><h2>Certification Scope</h2>
<p>$totalIdentities distinct users reviewed | $totalItems entitlements tracked | 30 reviewers involved</p>
</div>

<!-- Section A: Campaign Summary (matches the V4b table the decision scraper reads Approved totals from) -->
<div class="section"><h2>A. Campaign Summary</h2>
<table class="report"><thead><tr><th>Campaign</th><th>Status</th><th>Total Items</th><th>Approved</th><th>Revoked</th><th>Undecided</th></tr></thead>
<tbody><tr><td>Q3 Quarterly Access Review</td><td>ACTIVE</td><td>$totalItems</td><td>$approvedCount</td><td class="s-red">$revokedCount</td><td>$pendingItems</td></tr></tbody></table>
</div>

<!-- Section B: Reviewer Accountability -->
<div class="section"><h2>B. Reviewer Accountability</h2>
<details><summary>Undecided ($pendingCount reviewers with undecided items)</summary>
<table class="report"><thead><tr><th>Reviewer</th><th>Email</th><th style="text-align:right">Undecided Items</th><th style="text-align:right">Total Items</th><th>Note</th></tr></thead>
<tbody>
$pendingRowsHtml
</tbody></table></details>
</div>

<!-- Decision Summary -->
<div class="section"><h2>Decision Summary</h2>

<details><summary class='s-red'>Revoked ($revokedCount items)</summary>
<table class="report"><thead><tr><th>Identity</th><th>Account</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Decision Date</th><th>Justification</th></tr></thead>
<tbody>
$revokedRowsHtml
</tbody></table></details>

<details><summary class='s-green'>New Scope -- Approved Access ($newScopeCount items)</summary>
<table class="report"><thead><tr><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Decision Date</th></tr></thead>
<tbody>
$newScopeRowsHtml
</tbody></table></details>

</div>

<div class="footer">SailPoint ISC Governance Toolkit | Daily Evidence Report v4b | Generated: $dateStr | 1 campaign(s)</div>
</div></body></html>
"@

    # Write file with UTF-8 no-BOM. Name matches the PRODUCTION V4b generator output
    # (daily-evidence-v4b-<yyyyMMdd-HHmmss>.html) so the scrapers' default -FilePattern
    # and filename date parsing are exercised exactly as in production; the previous
    # Daily-Attestation-Evidence-Report-* name matched only a legacy pattern the real
    # generator never writes. Fixed 170000 timestamp keeps fixed-seed output reproducible.
    $fileName = 'daily-evidence-v4b-{0}-170000.html' -f $reportDate.ToString('yyyyMMdd')
    $filePath = Join-Path $OutputPath $fileName
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($filePath, $html, $utf8NoBom)

    $fileInfo = Get-Item -LiteralPath $filePath
    $generatedFiles += [pscustomobject]@{
        Date     = $dateStr
        Day      = $dayOfWeek
        FileName = $fileName
        SizeKB   = [math]::Round($fileInfo.Length / 1024, 1)
        Pending  = $pendingCount
        Revoked  = $revokedCount
        NewScope = $newScopeCount
    }

    $statusColor = if ($pendingCount -eq 0) { 'Green' } elseif ($pendingCount -le 3) { 'Yellow' } else { 'Red' }
    Write-Host "  $dateStr ($($dayOfWeek.Substring(0,3))) -- $pendingCount pending, $revokedCount revoked, $newScopeCount new scope" -ForegroundColor $statusColor
}

# ---------------------------------------------------------------------------
# Summary output
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  Generation Complete' -ForegroundColor Cyan
Write-Host '  ====================' -ForegroundColor Cyan
Write-Host ''

Write-Host '  Files Generated:' -ForegroundColor White
Write-Host '  ----------------' -ForegroundColor DarkGray
$generatedFiles | ForEach-Object {
    Write-Host ("    {0}  {1,7} KB  (Pending: {2}, Revoked: {3}, NewScope: {4})" -f $_.Date, $_.SizeKB, $_.Pending, $_.Revoked, $_.NewScope)
}

Write-Host ''
Write-Host "  Total files: $($generatedFiles.Count)" -ForegroundColor White
Write-Host "  Total revoked items across all days: $totalRevokedAll" -ForegroundColor White
Write-Host "  Total new scope items across all days: $totalNewScopeAll" -ForegroundColor White
Write-Host "  Output directory: $OutputPath" -ForegroundColor White
Write-Host ''

# Pending reviewer summary
Write-Host '  Reviewer Pending Summary:' -ForegroundColor White
Write-Host '  -------------------------' -ForegroundColor DarkGray
foreach ($rev in $reviewers) {
    $pendingDays = $pendingTracker[$rev.Name]
    if ($pendingDays.Count -gt 0) {
        $dayList = ($pendingDays | ForEach-Object { $_ }) -join ', '
        Write-Host ("    {0,-25} [{1,-16}]  Pending {2,2}/{3} days: {4}" -f $rev.Name, $rev.Profile, $pendingDays.Count, $businessDays.Count, $dayList) -ForegroundColor Yellow
    }
    else {
        Write-Host ("    {0,-25} [{1,-16}]  Never pending (0/{2} days)" -f $rev.Name, $rev.Profile, $businessDays.Count) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Cyan

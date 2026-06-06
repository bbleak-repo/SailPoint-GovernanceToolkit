#Requires -Version 5.1
<#
.SYNOPSIS
    AR-07 -- adaptive-reports mock-parity / end-to-end adapter proof.

.DESCRIPTION
    Confirms Build-SPRCDataset produces non-empty GroupResults for BOTH anchors
    from REAL data served by the running mock, end-to-end through the toolkit's
    existing audit pipeline:

        Get-SPAuditCampaigns -> Get-SPAuditCertifications ->
        Get-SPAuditCertificationItems -> Group-SPAuditDecisions  (the .Decisions
        bag the adapter consumes) -> Build-SPRCDataset (Entitlement | Campaign) ->
        New-ComposableReport.

    Mock-parity finding it documents: the adapters route through the
    campaign/cert/access-review-item endpoints (mock-served; proven by W-03b/W-05),
    NOT /v3/entitlements -- so the mock's 405 on /v3/entitlements does NOT block the
    adaptive reports. A live entitlement *catalog* enrichment (Get-SPEntitlementInventory)
    is deferred until the mock serves /v3/entitlements.

.NOTES
    Run with the mock up at localhost:8080 and a mock-targeted config:
        powershell -NoProfile -File Tests\Harness\Test-AR07-AdapterMockParity.ps1 `
            -ConfigPath .\Config\settings-mock.json
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$MockBaseUrl = 'http://localhost:8080',
    [int]$DaysBack = 365
)

$ErrorActionPreference = 'Stop'
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $ConfigPath) { $ConfigPath = Join-Path $toolkitRoot 'Config\settings-mock.json' }

foreach ($m in 'SP.Core\SP.Core.psd1','SP.Api\SP.Api.psd1','SP.Audit\SP.Audit.psd1',
                'SP.ReportComponents\SP.ReportComponents.psd1','SP.AdaptiveReports\SP.AdaptiveReports.psd1') {
    Import-Module (Join-Path $toolkitRoot "Modules\$m") -Force -DisableNameChecking
}

$fail = $false
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

# --- mock health ---
try {
    if ((Invoke-RestMethod "$MockBaseUrl/health" -TimeoutSec 5).status -ne 'ok') { throw 'not ok' }
    Say "mock /health: OK" Green
} catch { Say "MOCK DOWN at $MockBaseUrl ($($_.Exception.Message)) -- start it -Fresh and retry." Red; exit 2 }

$null = Get-SPConfig -ConfigPath $ConfigPath
Initialize-SPLogging -ErrorAction SilentlyContinue

# --- build campaign audits via the existing pipeline ---
Say "Building campaign audits from the mock (DaysBack=$DaysBack)..." Cyan
$campaigns = @()
$cr = Get-SPAuditCampaigns -DaysBack $DaysBack
if ($cr.Success) { $campaigns = @($cr.Data) }
Say "  campaigns: $($campaigns.Count)"

$audits = New-Object System.Collections.Generic.List[hashtable]
foreach ($camp in $campaigns) {
    $wrapped = New-Object System.Collections.Generic.List[object]
    $certR = Get-SPAuditCertifications -CampaignId $camp.id
    foreach ($cert in @(if ($certR.Success) { $certR.Data } else { @() })) {
        $itemR = Get-SPAuditCertificationItems -CertificationId $cert.id
        foreach ($item in @(if ($itemR.Success) { $itemR.Data } else { @() })) {
            $wrapped.Add(@{ Item = $item; CertificationId = [string]$cert.id; CertificationName = [string]$cert.name; CampaignName = [string]$camp.name })
        }
    }
    $dg = Group-SPAuditDecisions -Items $wrapped.ToArray() -CampaignMetadata @{ StartDate = ''; DueDate = ''; CompletionDate = '' }
    $audits.Add(@{ CampaignName = [string]$camp.name; CampaignId = [string]$camp.id; Decisions = $dg })
}
$totalItems = ($audits | ForEach-Object { @($_.Decisions.Approved).Count + @($_.Decisions.Revoked).Count + @($_.Decisions.Pending).Count } | Measure-Object -Sum).Sum
Say "  built $($audits.Count) audit(s), $totalItems decision item(s)"

if ($audits.Count -eq 0 -or $totalItems -eq 0) {
    Say "FAIL: no campaign/decision data from the mock -- reload the mock -Fresh (needs campaign+cert+ARI seed)." Red
    exit 1
}

# --- adapter both anchors -> non-empty GroupResults -> render ---
foreach ($anchor in 'Entitlement','Campaign') {
    $ds = Build-SPRCDataset -CampaignAudits ($audits.ToArray()) -Anchor $anchor
    $groups = @($ds.Data.GroupResults)
    $members = ($groups | ForEach-Object { @($_.Data.Members).Count } | Measure-Object -Sum).Sum
    $ok = ($ds.Success -and $groups.Count -gt 0 -and $members -gt 0)
    if (-not $ok) { $fail = $true }
    Say ("  {0,-12} groups={1,-3} members={2,-4} success={3} {4}" -f $anchor, $groups.Count, $members, $ds.Success, $(if ($ok) { 'PASS' } else { 'FAIL' })) $(if ($ok) { 'Green' } else { 'Red' })
    if ($ok) {
        $ctx = New-RCContext -GroupResults $groups -StaleResults $ds.Data.StaleResults -Theme light
        $out = Join-Path $env:TEMP "ar07-$anchor.html"
        New-ComposableReport -Components @('kpi-cards','top-n','group-table') -Context $ctx -Title "AR-07 $anchor" -OutputPath $out | Out-Null
        $wf = ((Get-Content -Raw $out) -match '(?is)</html>')
        if (-not $wf) { $fail = $true }
        Say ("               rendered {0:N0}B wellformed={1}" -f (Get-Item $out).Length, $wf)
    }
}

Say ''
if ($fail) { Say "AR-07: FAIL" Red; exit 1 } else { Say "AR-07: PASS -- both anchors get real mock data + render; /v3/entitlements 405 is non-blocking (ARI-routed)." Green; exit 0 }

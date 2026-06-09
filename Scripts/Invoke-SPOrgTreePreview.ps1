#Requires -Version 5.1
<#
.SYNOPSIS
    Prints an ASCII org-tree preview for a campaign's certifiers, so you can review the
    management chain before generating leadership reports.

.DESCRIPTION
    Read-only. Resolves campaigns by name/status/date, collects each certification's
    certifier (reviewer) identity, builds the org tree (manager chain up to -OrgDepth via
    Get-SPDeltaIdentityDetail), optionally merges an org-chart supplement to fill ISC gaps,
    and renders the tree as ASCII art with Show-SPOrgTree.

    This surfaces Show-SPOrgTree / Build-SPOrgTree (SP.DeltaCert) as a one-command CLI --
    they previously had no entry-point script.

.PARAMETER CampaignName
    Exact (case-insensitive) campaign name.
.PARAMETER CampaignNameStartsWith
    Campaign name begins with this prefix.
.PARAMETER CampaignNameContains
    Campaign name contains this substring (case-insensitive, client-side).
.PARAMETER Status
    Campaign status filter. Default: COMPLETED, ACTIVE.
.PARAMETER DaysBack
    Only campaigns created in the last N days. Default 30.
.PARAMETER OrgDepth
    Levels to walk up the manager chain. Default 5.
.PARAMETER OrgSupplementPath
    Optional org-chart-supplement.csv to fill ISC manager-chain gaps.
.PARAMETER ShowBands
    Annotate each node with its A-E leadership band.
.PARAMETER MaxChildrenShown
    Truncate each node to the first N children (0 = show all). Default 0.
.PARAMETER RefreshIdentities
    Clear the persistent identity cache first so the chain is re-resolved from ISC
    (use to validate org movement after a reorg).
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved (honoring settings.local.json) if omitted.
.PARAMETER Token
    Browser bearer token for sessions without a stored PAT.
.PARAMETER TokenExpiryMinutes
    Browser-token lifetime. Default 10.
.EXAMPLE
    .\Invoke-SPOrgTreePreview.ps1 -CampaignNameContains 'Tuesday' -ShowBands
.EXAMPLE
    .\Invoke-SPOrgTreePreview.ps1 -Status COMPLETED -DaysBack 7 -OrgSupplementPath .\Config\org-chart-supplement.csv
#>
[CmdletBinding()]
param(
    [Parameter()] [string]$ConfigPath,
    [Parameter()] [string]$CampaignName,
    [Parameter()] [string]$CampaignNameStartsWith,
    [Parameter()] [string]$CampaignNameContains,
    [Parameter()] [ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')] [string[]]$Status = @('COMPLETED', 'ACTIVE'),
    [Parameter()] [int]$DaysBack = 30,
    [Parameter()] [ValidateRange(1, 10)] [int]$OrgDepth = 5,
    [Parameter()] [string]$OrgSupplementPath,
    [Parameter()] [switch]$ShowBands,
    [Parameter()] [int]$MaxChildrenShown = 0,
    [Parameter()] [switch]$RefreshIdentities,
    [Parameter()] [string]$Token,
    [Parameter()] [int]$TokenExpiryMinutes = 10,
    [Parameter()] [Alias('?')] [switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

#region Module Load
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot
foreach ($mod in @('SP.Core\SP.Core.psd1', 'SP.Api\SP.Api.psd1', 'SP.Audit\SP.Audit.psd1', 'SP.DeltaCert\SP.DeltaCert.psd1')) {
    $p = Join-Path $toolkitRoot (Join-Path 'Modules' $mod)
    if (Test-Path $p) { Import-Module $p -Force -ErrorAction Stop -DisableNameChecking }
    else { Write-Host "ERROR: Required module not found at: $p" -ForegroundColor Red; exit 4 }
}
#endregion

#region Setup
$correlationID = [guid]::NewGuid().ToString()
if (-not $ConfigPath) { $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Org-Tree Preview' -ForegroundColor Cyan
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

$config = $null
try { $config = Get-SPConfig -ConfigPath $ConfigPath }
catch { Write-Host "ERROR: Failed to load configuration: $($_.Exception.Message)" -ForegroundColor Red; exit 4 }
if (Test-SPConfigFirstRun -Config $config) {
    Write-Host "INFO: First-run configuration detected. Update settings.json and run again." -ForegroundColor Yellow; exit 4
}
try { Initialize-SPLogging -Force -ErrorAction SilentlyContinue } catch { }

if ($Token) {
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes -CorrelationID $correlationID
    if (-not $tokenResult.Success) { Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red; exit 3 }
    Write-Host "  Auth: Browser token active" -ForegroundColor Green
}
#endregion

# Step 1: campaigns
$campaignParams = @{ Status = $Status; DaysBack = $DaysBack; CorrelationID = $correlationID }
if ($CampaignName)           { $campaignParams['CampaignName']           = $CampaignName }
if ($CampaignNameStartsWith) { $campaignParams['CampaignNameStartsWith'] = $CampaignNameStartsWith }
if ($CampaignNameContains)   { $campaignParams['CampaignNameContains']   = $CampaignNameContains }
Write-Host "  Fetching campaigns (status: $($Status -join '/'), last $DaysBack days)..." -ForegroundColor Cyan
$campResult = Get-SPAuditCampaigns @campaignParams
if (-not $campResult.Success) { Write-Host "ERROR: Campaign query failed: $($campResult.Error)" -ForegroundColor Red; exit 5 }
$campaigns = @($campResult.Data)
Write-Host "  Found $($campaigns.Count) campaign(s)" -ForegroundColor DarkGray
if ($campaigns.Count -eq 0) { Write-Host '  No campaigns matched the filter.' -ForegroundColor Yellow; exit 1 }

# Step 2: certifier identity IDs (reviewer/certifier on each certification)
$certifierIds = @{}
foreach ($camp in $campaigns) {
    $certsResult = Get-SPAuditCertifications -CampaignId $camp.id -CorrelationID $correlationID
    if (-not $certsResult.Success) { continue }
    foreach ($cert in @($certsResult.Data)) {
        foreach ($prop in @('certifier', 'reviewer')) {
            if ($null -ne $cert.PSObject.Properties[$prop] -and $null -ne $cert.$prop -and
                $null -ne $cert.$prop.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace($cert.$prop.id)) {
                $certifierIds[[string]$cert.$prop.id] = $true
                break
            }
        }
    }
}
$uniqueCertifierIds = @($certifierIds.Keys)
Write-Host "  Unique certifiers: $($uniqueCertifierIds.Count)" -ForegroundColor DarkGray
if ($uniqueCertifierIds.Count -eq 0) {
    Write-Host '  No certifier/reviewer identity IDs found on the certifications.' -ForegroundColor Yellow; exit 1
}

# Step 3: build the org tree (optionally refreshing the identity cache first)
if ($RefreshIdentities -and (Get-Command Clear-SPIdentityCache -ErrorAction SilentlyContinue)) {
    Write-Host "  Refreshing identity cache (forcing fresh resolution)..." -ForegroundColor DarkGray
    Clear-SPIdentityCache | Out-Null
}
Write-Host "  Building org tree (depth=$OrgDepth)..." -ForegroundColor Cyan
$orgTreeResult = Build-SPOrgTree -IdentityIds $uniqueCertifierIds -MaxDepth $OrgDepth -CorrelationID $correlationID
if (-not $orgTreeResult.Success) { Write-Host "ERROR: Org tree build failed: $($orgTreeResult.Error)" -ForegroundColor Red; exit 5 }
$orgTree = $orgTreeResult.Data

# Step 4: optional supplement merge (fill ISC chain gaps)
if ($OrgSupplementPath -and (Test-Path -LiteralPath $OrgSupplementPath)) {
    $supResult = Import-SPOrgChartSupplement -FilePath $OrgSupplementPath -CorrelationID $correlationID
    if ($supResult.Success) {
        $emailMap = @{}
        foreach ($nid in $orgTree.Nodes.Keys) {
            $n = $orgTree.Nodes[$nid]
            if ($null -ne $n.Identity -and -not [string]::IsNullOrWhiteSpace([string]$n.Identity.Email)) { $emailMap[$nid] = $n.Identity.Email }
        }
        $orgTree = Merge-SPOrgTreeWithSupplement -OrgTree $orgTree -Supplement $supResult.Data.Entries -IdentityEmailMap $emailMap -CorrelationID $correlationID
        Write-Host "  Supplement merged." -ForegroundColor DarkGray
    }
    else { Write-Host "  WARN: Could not load supplement: $($supResult.Error)" -ForegroundColor Yellow }
}

# Step 5: render ASCII
Write-Host ''
$showParams = @{ OrgTree = $orgTree }
if ($ShowBands)              { $showParams['ShowBands'] = $true }
if ($MaxChildrenShown -gt 0) { $showParams['MaxChildrenShown'] = $MaxChildrenShown }
Show-SPOrgTree @showParams | ForEach-Object { Write-Host $_ }
Write-Host ''
exit 0

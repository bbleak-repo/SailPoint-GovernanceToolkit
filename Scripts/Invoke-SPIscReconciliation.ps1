#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the ISC-side reconciliation export -- the SailPoint operand for the cross-project
    AD <-> ISC <-> HR reconciliation contract. READ-ONLY (never reassigns / escalates / mutates).

.DESCRIPTION
    Fetches ISC identities (with the configurable employeeID join key) + governed access
    (entitlement membership) from ISC, builds the employeeID-keyed reconciliation model, and writes
    a versioned UTF-8 no-BOM JSON export + CSV twin + SHA-256 sidecar that a future merge joins
    against the AD + HR exports. See docs/AD-Reconciliation-Contract-from-GroupEnumerator.md.

    The raw fetched operands are persisted to a NON-EXPIRING cache (separate from the toolkit's
    24h identity-detail cache). On the next run the baseline is served from that cache unless
    -RefreshCache is given -- so you can generate a baseline, change the source data, and
    regenerate to see drift, without the cache silently expiring underneath you.

.PARAMETER ConfigPath
    Path to settings.json (default: resolved from the toolkit root).
.PARAMETER Token
    Optional pre-acquired ISC browser JWT (otherwise the configured client-credentials flow runs).
.PARAMETER TokenExpiryMinutes
    Browser-token validity window (default 10).
.PARAMETER JoinKeyAttribute
    The identity attributes.* field holding the SuccessFactors join key (default 'employeeNumber').
.PARAMETER RefreshCache
    Force a fresh ISC fetch and overwrite the non-expiring cache (default: serve from cache if present).
.PARAMETER CachePath
    Override the non-expiring cache directory.
.PARAMETER OutputPath
    Override the export directory (default: {Audit.OutputPath}\Reconciliation).
.PARAMETER OutputMode
    Console | JSON | Both | CSV. Files are always written; this controls console output.
.PARAMETER Help
    Show detailed help.

.NOTES
    Exit codes: 0 success; 1 no data; 2 parameter error; 3 auth/fetch error; 4 config/module error.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,

    [Parameter()][string]$JoinKeyAttribute = 'employeeNumber',
    [Parameter()][switch]$RefreshCache,
    [Parameter()][string]$CachePath,

    [Parameter()][string]$OutputPath,
    [Parameter()][ValidateSet('Console', 'JSON', 'Both', 'CSV')][string]$OutputMode = 'Console',
    [Parameter()][Alias('?')][switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

#region Module load
$scriptRoot  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot
foreach ($mod in @('SP.Core\SP.Core.psd1', 'SP.Api\SP.Api.psd1', 'SP.Reconciliation\SP.Reconciliation.psd1')) {
    $p = Join-Path $toolkitRoot "Modules\$mod"
    if (Test-Path $p) { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop }
    else { Write-Host "ERROR: required module not found: $p" -ForegroundColor Red; exit 4 }
}
#endregion

$correlationID = [guid]::NewGuid().ToString()

# --- Config + logging + auth ------------------------------------------------
try {
    if (-not $ConfigPath) { $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot }
    $config = Get-SPConfig -ConfigPath $ConfigPath
    Initialize-SPLogging -ErrorAction SilentlyContinue
}
catch { Write-Host "ERROR: configuration load failed: $($_.Exception.Message)" -ForegroundColor Red; exit 4 }

if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $null = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes -ErrorAction SilentlyContinue
}

# --- Resolve export path ----------------------------------------------------
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $auditBase = if ($config.PSObject.Properties.Name -contains 'Audit' -and $config.Audit.PSObject.Properties.Name -contains 'OutputPath') { [string]$config.Audit.OutputPath } else { 'Audit' }
    $effectiveOutputPath = Join-Path $auditBase 'Reconciliation'
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) { $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath }
if (-not (Test-Path $effectiveOutputPath)) { New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null }

$tenantUrl = if ($config.PSObject.Properties.Name -contains 'Api' -and $config.Api.PSObject.Properties.Name -contains 'BaseUrl') { [string]$config.Api.BaseUrl } else { '' }

Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  ISC Reconciliation Export (read-only -- AD<->ISC<->HR operand)'
Write-Host "  CorrelationID: $correlationID"
Write-Host ''

# --- Acquire data: non-expiring cache, else fetch ---------------------------
$data = $null
if (-not $RefreshCache) {
    try {
        $c = Get-SPIscReconCache -CacheDir $CachePath
        if ($c.Success) {
            $data = $c.Data
            Write-Host "  Loaded NON-EXPIRING recon cache: $($c.Path)" -ForegroundColor DarkGray
            Write-Host "    fetched-as-of $($data.FetchedAtUtc); identities=$(@($data.Identities).Count) grants=$(@($data.AccessGrants).Count)" -ForegroundColor DarkGray
            Write-Host "    (pass -RefreshCache to re-fetch from ISC)" -ForegroundColor DarkGray
        }
    } catch { }
}
if ($null -eq $data) {
    Write-Host '  Fetching identities + governed access from ISC...' -ForegroundColor DarkGray
    try {
        $f = Get-SPIscReconciliationData -JoinKeyAttribute $JoinKeyAttribute -CorrelationID $correlationID
    }
    catch {
        if ($_.Exception.Message -match 'token|auth|401|403') { Write-Host "ERROR: authentication failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
        Write-Host "ERROR: ISC fetch failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3
    }
    if (-not $f.Success) { Write-Host "ERROR: ISC fetch failed: $($f.Error)" -ForegroundColor Red; exit 3 }
    $data = $f.Data
    Write-Host "    fetched identities=$($data.SourceCounts.Identities) entitlements=$($data.SourceCounts.Entitlements) grants=$($data.SourceCounts.Grants)" -ForegroundColor DarkGray
    $sv = Save-SPIscReconCache -Data $data -CacheDir $CachePath
    if ($sv.Success) { Write-Host "    wrote NON-EXPIRING recon cache: $($sv.Data)" -ForegroundColor DarkGray }
    else { Write-Host "    WARN: cache write failed: $($sv.Error)" -ForegroundColor Yellow }
}

if (@($data.Identities).Count -eq 0) { Write-Host '  No identities -- nothing to reconcile.' -ForegroundColor Yellow; exit 1 }

# --- Build the model + write the export -------------------------------------
$toolVersion = if ($config.PSObject.Properties.Name -contains 'Version') { [string]$config.Version } else { '1.0.0' }
$environment = if ($config.PSObject.Properties.Name -contains 'Environment') { [string]$config.Environment } else { '' }
$prov = @{
    SnapshotAsOfUtc = [string]$data.FetchedAtUtc
    GeneratedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    ExtractMethod   = 'isc-search+entitlement-members'
    ToolVersion     = $toolVersion
    TenantUrl       = $tenantUrl
    Environment     = $environment
    ConfigHash      = ''
}
$model = Build-SPIscReconciliationModel -Identities @($data.Identities) -AccessGrants @($data.AccessGrants) -Provenance $prov -JoinKeyAttribute $JoinKeyAttribute
$saved = Save-SPIscReconciliationExport -Model $model -OutputDir $effectiveOutputPath
if (-not $saved.Success) { Write-Host "ERROR: export write failed: $($saved.Error)" -ForegroundColor Red; exit 3 }

$s = $model.Summary
Write-Host ''
Write-Host '  --- ISC reconciliation summary ---' -ForegroundColor Cyan
Write-Host ("    identities ............ {0}" -f $s.IdentityCount)
Write-Host ("    active ................ {0}" -f $s.ActiveCount)
Write-Host ("    join-key coverage ..... {0}% ({1}/{2} resolved; {3} low-confidence)" -f $s.JoinKeyCoveragePct, $s.JoinKeyResolvedCount, $s.IdentityCount, $s.LowConfidenceJoinCount)
Write-Host ("    manager resolved ...... {0}" -f $s.ManagerResolvedCount)
Write-Host ("    governed entitlements . {0} ({1} privileged grants)" -f $s.GovernedEntitlementCount, $s.PrivilegedGrantCount)
Write-Host ("    findings: JOINKEY_MISSING={0}  MAIL_NE_UPN={1}" -f $s.FindingCounts.JOINKEY_MISSING, $s.FindingCounts.MAIL_NE_UPN)
Write-Host ("    contentHash ........... {0}" -f $model.Generated.ContentHash)
Write-Host ''
Write-Host "  Export: $($saved.Data)" -ForegroundColor Green
Write-Host "  CSV   : $($saved.Csv)" -ForegroundColor Green
Write-Host "  SHA256: $($saved.Sha256)" -ForegroundColor DarkGray

switch ($OutputMode) {
    'JSON' { Write-Host ''; Get-Content $saved.Data -Raw }
    'Both' { Write-Host ''; Get-Content $saved.Data -Raw }
    'CSV'  { Write-Host ''; Get-Content $saved.Csv -Raw }
    default { }
}

exit 0

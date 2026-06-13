#Requires -Version 5.1
<#
.SYNOPSIS
    Orchestrates the full disconnected app certification workflow: validate, snapshot,
    delta, resolve, campaign, report.
.DESCRIPTION
    Entry point CLI script for the Disconnected App Onboarding Kit. Application teams
    deliver daily CSV exports (accounts + entitlements) for applications that lack a
    native SailPoint ISC connector. This script:

    1. Validates the account CSV (and entitlement CSV if provided)
    2. Saves today's file as a date-stamped snapshot
    3. Retrieves the most recent previous snapshot for comparison
    4. Runs delta detection (added/removed/changed accounts and entitlements)
    5. Resolves changed accounts to ISC identities via email/username correlation
    6. Creates targeted SEARCH campaigns per manager group (adds + grants only)
    7. Generates an HTML delta summary report
    8. Logs the run to a JSONL audit trail

    If no changes are detected between today's file and the previous snapshot, the
    script exits with code 1 (expected on quiet days -- not an error).

    SCOPE REQUIREMENT:
        Identity resolution requires sp:search:read.
        Campaign creation requires idn:campaign:read + idn:campaign:manage.
        Use -Token with a JWT from the ISC admin console if OAuth PAT is unavailable.

.PARAMETER AppName
    Application name. Used for directory paths, campaign naming, and report titles.
    Example: 'PEP-Plus', 'DebtNext', 'IPAY'
.PARAMETER AccountFilePath
    Path to today's account CSV file (full export from the app team).
.PARAMETER EntitlementFilePath
    Optional path to today's entitlement CSV file. When provided, cross-reference
    validation is performed to verify all group references in accounts exist in
    the entitlement file.
.PARAMETER CampaignNamePrefix
    Prefix for campaign names. Defaults to the DisconnectedApps.DefaultCampaignNamePrefix
    value in settings.json (fallback: 'Disconnected App Cert').
    Full name: "{Prefix} {YYYY-MM-DD} - {ManagerName}"
.PARAMETER DeadlineDays
    Days from today until the campaign deadline. Default: 2.
.PARAMETER FallbackReviewerIdentityId
    Identity ID used as reviewer for identities who have no manager in ISC.
    If omitted, manager-less identities are skipped and logged as warnings.
.PARAMETER MaxCampaignsPerRun
    Abort before creating any campaigns if the number of manager groups exceeds this.
    Default: 20.
.PARAMETER SnapshotDir
    Root directory for date-stamped file snapshots.
    Default: .\DisconnectedApps\Snapshots
.PARAMETER OutputPath
    Root directory for HTML reports and JSONL audit trail.
    Default: .\DisconnectedApps\Reports
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to this script.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials entirely. The "Bearer " prefix is stripped
    automatically if present.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER OutputMode
    Console (default): formatted summary to terminal.
    JSON: machine-parseable result object.
    Both: console output followed by the JSON object.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPDisconnectedAppCert.ps1 -AppName 'PEP-Plus' -AccountFilePath '.\Imports\PEP-Plus\accounts.csv'
    # Daily run: validate, snapshot, detect changes, create campaigns for new/changed access.
.EXAMPLE
    .\Invoke-SPDisconnectedAppCert.ps1 -AppName 'PEP-Plus' -AccountFilePath '.\Imports\PEP-Plus\accounts.csv' -WhatIf
    # Dry-run: full workflow validation without any write API calls.
.EXAMPLE
    .\Invoke-SPDisconnectedAppCert.ps1 -AppName 'DebtNext' `
        -AccountFilePath '.\Imports\DebtNext\accounts.csv' `
        -EntitlementFilePath '.\Imports\DebtNext\entitlements.csv' `
        -Token 'eyJhbGciOiJSUzI1...'
    # With entitlement cross-reference validation and browser token auth.
.EXAMPLE
    .\Invoke-SPDisconnectedAppCert.ps1 -AppName 'IPAY' `
        -AccountFilePath '.\Imports\IPAY\accounts.csv' `
        -FallbackReviewerIdentityId 'mgr-fallback-id' -DeadlineDays 3
    # Include manager-less identities via fallback reviewer with a 3-day deadline.
.NOTES
    Script:  Invoke-SPDisconnectedAppCert.ps1
    Version: 1.0.0
    Exit codes:
        0 = Success -- campaigns created (or WhatIf completed)
        1 = No changes -- no deltas detected between snapshots
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Validation failure (CSV structure/data errors)
        6 = Campaign creation error
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AppName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AccountFilePath,

    [Parameter()]
    [string]$EntitlementFilePath,

    [Parameter()]
    [string]$CampaignNamePrefix,

    [Parameter()]
    [int]$DeadlineDays = 2,

    [Parameter()]
    [string]$FallbackReviewerIdentityId,

    [Parameter()]
    [int]$MaxCampaignsPerRun = 0,

    [Parameter()]
    [string]$SnapshotDir,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [Alias('?')]
    [switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

#region Module Load

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$toolkitRoot = Split-Path -Parent $scriptRoot

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1';                   Name = 'SP.Shared';            Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';                       Name = 'SP.Core';              Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';                         Name = 'SP.Api';               Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1';             Name = 'SP.DeltaCert';         Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DisconnectedApps\SP.DisconnectedApps.psd1'; Name = 'SP.DisconnectedApps'; Required = $true  }
)

foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) {
        Import-Module $mod.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        $moduleDir = Split-Path -Parent $mod.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
            }
        }
        elseif ($mod.Required) {
            Write-Host "ERROR: Required module '$($mod.Name)' not found at: $($mod.Path)" -ForegroundColor Red
            exit 4
        }
    }
}

#endregion

#region Setup

$correlationID = [guid]::NewGuid().ToString()

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Disconnected App Certification' -ForegroundColor Cyan
Write-Host "  Application:     $AppName" -ForegroundColor Cyan
Write-Host "  CorrelationID:   $correlationID" -ForegroundColor DarkGray
Write-Host ''

$config = $null
try {
    $config = Get-SPConfig -ConfigPath $ConfigPath
}
catch {
    Write-Host "ERROR: Failed to load configuration from '$ConfigPath': $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}

if (Test-SPConfigFirstRun -Config $config) {
    Write-Host "INFO: First-run configuration detected. Update settings.json and run again." -ForegroundColor Yellow
    exit 4
}

if (-not (Test-SPConfig -Config $config)) {
    Write-Host "ERROR: Configuration validation failed. Check settings.json for required values." -ForegroundColor Red
    exit 4
}

try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
} catch { }

# Browser token injection
if ($Token) {
    Write-Host '  Auth: Injecting browser token...' -ForegroundColor Gray
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes `
        -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

# Apply config defaults for parameters not explicitly provided
$daConfig = $null
if ($null -ne $config.PSObject.Properties['DisconnectedApps'] -and $null -ne $config.DisconnectedApps) {
    $daConfig = $config.DisconnectedApps
}

$effectivePrefix = $CampaignNamePrefix
if ([string]::IsNullOrWhiteSpace($effectivePrefix)) {
    if ($null -ne $daConfig -and
        $null -ne $daConfig.PSObject.Properties['DefaultCampaignNamePrefix'] -and
        -not [string]::IsNullOrWhiteSpace($daConfig.DefaultCampaignNamePrefix)) {
        $effectivePrefix = [string]$daConfig.DefaultCampaignNamePrefix
    }
    else {
        $effectivePrefix = 'Disconnected App Cert'
    }
}

$effectiveMaxCampaigns = $MaxCampaignsPerRun
if ($effectiveMaxCampaigns -le 0) {
    if ($null -ne $daConfig -and
        $null -ne $daConfig.PSObject.Properties['MaxCampaignsPerRun'] -and
        [int]$daConfig.MaxCampaignsPerRun -gt 0) {
        $effectiveMaxCampaigns = [int]$daConfig.MaxCampaignsPerRun
    }
    else {
        $effectiveMaxCampaigns = 20
    }
}

$effectiveDeadline = $DeadlineDays
if ($effectiveDeadline -le 0) {
    if ($null -ne $daConfig -and
        $null -ne $daConfig.PSObject.Properties['DefaultDeadlineDays'] -and
        [int]$daConfig.DefaultDeadlineDays -gt 0) {
        $effectiveDeadline = [int]$daConfig.DefaultDeadlineDays
    }
    else {
        $effectiveDeadline = 2
    }
}

$effectiveFallback = $FallbackReviewerIdentityId
if ([string]::IsNullOrWhiteSpace($effectiveFallback)) {
    if ($null -ne $daConfig -and
        $null -ne $daConfig.PSObject.Properties['FallbackReviewerIdentityId']) {
        $effectiveFallback = [string]$daConfig.FallbackReviewerIdentityId
    }
}

$effectiveSnapshotDir = $SnapshotDir
if ([string]::IsNullOrWhiteSpace($effectiveSnapshotDir)) {
    if ($null -ne $daConfig -and
        $null -ne $daConfig.PSObject.Properties['SnapshotPath'] -and
        -not [string]::IsNullOrWhiteSpace($daConfig.SnapshotPath)) {
        $effectiveSnapshotDir = [string]$daConfig.SnapshotPath
    }
    else {
        $effectiveSnapshotDir = '.\DisconnectedApps\Snapshots'
    }
}

$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    if ($null -ne $daConfig -and
        $null -ne $daConfig.PSObject.Properties['ReportPath'] -and
        -not [string]::IsNullOrWhiteSpace($daConfig.ReportPath)) {
        $effectiveOutputPath = [string]$daConfig.ReportPath
    }
    else {
        $effectiveOutputPath = '.\DisconnectedApps\Reports'
    }
}

$effectiveCorrelation = 'e-mail'
if ($null -ne $daConfig -and
    $null -ne $daConfig.PSObject.Properties['CorrelationAttribute'] -and
    -not [string]::IsNullOrWhiteSpace($daConfig.CorrelationAttribute)) {
    $effectiveCorrelation = [string]$daConfig.CorrelationAttribute
}

Write-SPLog -Message "Invoke-SPDisconnectedAppCert started: AppName='$AppName' AccountFile='$AccountFilePath'" `
    -Severity INFO -Component 'Invoke-SPDisconnectedAppCert' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Validation

Write-Host '  Step 1: Validating CSV files...' -ForegroundColor Cyan

# Validate account file exists before passing to validator
if (-not (Test-Path -Path $AccountFilePath -PathType Leaf)) {
    Write-Host "ERROR: Account file not found: $AccountFilePath" -ForegroundColor Red
    exit 2
}

$acctValidation = Test-SPDisconnectedAppAccountFile -FilePath $AccountFilePath

if (-not $acctValidation.Success) {
    Write-Host "ERROR: Account file validation failed: $($acctValidation.Error)" -ForegroundColor Red
    if ($null -ne $acctValidation.Data -and $null -ne $acctValidation.Data.Errors) {
        foreach ($valErr in $acctValidation.Data.Errors) {
            Write-Host "    $valErr" -ForegroundColor Yellow
        }
    }
    Write-SPLog -Message "Account CSV validation failed: $($acctValidation.Error)" `
        -Severity ERROR -Component 'Invoke-SPDisconnectedAppCert' -Action 'Validate' -CorrelationID $correlationID
    exit 5
}

$acctData = $acctValidation.Data
Write-Host "    Account file: $($acctData.RowCount) rows ($($acctData.ValidRows) valid, $($acctData.InvalidRows) invalid)" -ForegroundColor DarkGray

if ($acctData.Warnings.Count -gt 0) {
    foreach ($warn in $acctData.Warnings) {
        Write-Host "    Warning: $warn" -ForegroundColor Yellow
    }
}

if ($acctData.InvalidRows -gt 0) {
    Write-Host "ERROR: Account file has $($acctData.InvalidRows) invalid row(s). Fix and retry." -ForegroundColor Red
    foreach ($valErr in $acctData.Errors) {
        Write-Host "    $valErr" -ForegroundColor Yellow
    }
    exit 5
}

# Validate entitlement file (optional)
$hasEntitlementFile = $false
if (-not [string]::IsNullOrWhiteSpace($EntitlementFilePath)) {
    if (-not (Test-Path -Path $EntitlementFilePath -PathType Leaf)) {
        Write-Host "ERROR: Entitlement file not found: $EntitlementFilePath" -ForegroundColor Red
        exit 2
    }

    $entValidation = Test-SPDisconnectedAppEntitlementFile -FilePath $EntitlementFilePath

    if (-not $entValidation.Success) {
        Write-Host "ERROR: Entitlement file validation failed: $($entValidation.Error)" -ForegroundColor Red
        if ($null -ne $entValidation.Data -and $null -ne $entValidation.Data.Errors) {
            foreach ($valErr in $entValidation.Data.Errors) {
                Write-Host "    $valErr" -ForegroundColor Yellow
            }
        }
        exit 5
    }

    $entData = $entValidation.Data
    Write-Host "    Entitlement file: $($entData.RowCount) rows ($($entData.ValidRows) valid)" -ForegroundColor DarkGray
    $hasEntitlementFile = $true

    # Cross-reference validation
    $crossRef = Test-SPDisconnectedAppCrossReference -AccountFilePath $AccountFilePath `
        -EntitlementFilePath $EntitlementFilePath

    if (-not $crossRef.Success) {
        Write-Host "ERROR: Cross-reference validation failed: $($crossRef.Error)" -ForegroundColor Red
        exit 5
    }

    if ($crossRef.Data.UnmatchedGroups.Count -gt 0) {
        Write-Host "ERROR: $($crossRef.Data.UnmatchedGroups.Count) group reference(s) in accounts not found in entitlements:" -ForegroundColor Red
        foreach ($ug in $crossRef.Data.UnmatchedGroups) {
            Write-Host "    $ug" -ForegroundColor Yellow
        }
        exit 5
    }

    if ($crossRef.Data.OrphanedEntitlements.Count -gt 0) {
        Write-Host "    Warning: $($crossRef.Data.OrphanedEntitlements.Count) orphaned entitlement(s) (not referenced by any account)" -ForegroundColor Yellow
    }
}

Write-Host '    Validation passed.' -ForegroundColor Green

#endregion

#region Snapshot

Write-Host '  Step 2: Saving snapshot...' -ForegroundColor Cyan

$snapshotResult = Save-SPDisconnectedAppSnapshot -FilePath $AccountFilePath `
    -AppName $AppName -FileType 'accounts' -SnapshotDir $effectiveSnapshotDir

if (-not $snapshotResult.Success) {
    Write-Host "ERROR: Snapshot save failed: $($snapshotResult.Error)" -ForegroundColor Red
    exit 4
}
Write-Host "    Snapshot saved: $($snapshotResult.Data)" -ForegroundColor DarkGray

if ($hasEntitlementFile) {
    $entSnapshotResult = Save-SPDisconnectedAppSnapshot -FilePath $EntitlementFilePath `
        -AppName $AppName -FileType 'entitlements' -SnapshotDir $effectiveSnapshotDir

    if (-not $entSnapshotResult.Success) {
        Write-Host "    Warning: Entitlement snapshot failed: $($entSnapshotResult.Error)" -ForegroundColor Yellow
    }
    else {
        Write-Host "    Entitlement snapshot saved: $($entSnapshotResult.Data)" -ForegroundColor DarkGray
    }
}

#endregion

#region Delta Detection

Write-Host '  Step 3: Detecting changes...' -ForegroundColor Cyan

$prevResult = Get-SPDisconnectedAppPreviousSnapshot -AppName $AppName `
    -FileType 'accounts' -SnapshotDir $effectiveSnapshotDir

if (-not $prevResult.Success) {
    Write-Host "ERROR: Failed to find previous snapshot: $($prevResult.Error)" -ForegroundColor Red
    exit 4
}

$previousFilePath = $prevResult.Data

if ([string]::IsNullOrWhiteSpace($previousFilePath)) {
    Write-Host '    First run detected (no previous snapshot). All accounts will be treated as new.' -ForegroundColor Yellow
}
else {
    Write-Host "    Previous snapshot: $previousFilePath" -ForegroundColor DarkGray
}

$deltaResult = Compare-SPDisconnectedAppFiles -CurrentFilePath $AccountFilePath `
    -PreviousFilePath $previousFilePath

if (-not $deltaResult.Success) {
    Write-Host "ERROR: Delta detection failed: $($deltaResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Delta detection failed: $($deltaResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPDisconnectedAppCert' -Action 'Delta' -CorrelationID $correlationID
    exit 4
}

$delta = $deltaResult.Data
$deltaSummary = $delta['Summary']

# Display delta summary
$addedCount   = if ($null -ne $deltaSummary['Added']) { $deltaSummary['Added'] } else { 0 }
$removedCount = if ($null -ne $deltaSummary['Removed']) { $deltaSummary['Removed'] } else { 0 }
$disabledCount = if ($null -ne $deltaSummary['Disabled']) { $deltaSummary['Disabled'] } else { 0 }
$enabledCount  = if ($null -ne $deltaSummary['Enabled']) { $deltaSummary['Enabled'] } else { 0 }
$grantedCount  = if ($null -ne $deltaSummary['EntitlementsGranted']) { $deltaSummary['EntitlementsGranted'] } else { 0 }
$revokedCount  = if ($null -ne $deltaSummary['EntitlementsRevoked']) { $deltaSummary['EntitlementsRevoked'] } else { 0 }
$attrChgCount  = if ($null -ne $deltaSummary['AttributeChanges']) { $deltaSummary['AttributeChanges'] } else { 0 }
$unchangedCount = if ($null -ne $delta['Unchanged']) { $delta['Unchanged'] } else { 0 }

Write-Host "    Added=$addedCount Removed=$removedCount Disabled=$disabledCount Enabled=$enabledCount" -ForegroundColor DarkGray
Write-Host "    Granted=$grantedCount Revoked=$revokedCount AttrChanges=$attrChgCount Unchanged=$unchangedCount" -ForegroundColor DarkGray

# --- Account deletion threshold check (DA-13) ---
$effectiveThresholdPct = 20
if ($null -ne $daConfig -and
    $null -ne $daConfig.PSObject.Properties['AccountDeletionThresholdPct']) {
    $effectiveThresholdPct = [int]$daConfig.AccountDeletionThresholdPct
}

$thresholdResult = Test-SPDisconnectedAppDeletionThreshold -DeltaSummary $deltaSummary `
    -ThresholdPct $effectiveThresholdPct

if (-not $thresholdResult.Allowed) {
    Write-Host ''
    Write-Host "  THRESHOLD EXCEEDED: $($thresholdResult.RemovedPct)% accounts removed (threshold: $($thresholdResult.ThresholdPct)%). Aborting." -ForegroundColor Red
    Write-Host "    Removed: $($thresholdResult.RemovedCount) of $($thresholdResult.TotalPrevious) accounts" -ForegroundColor Red
    Write-Host '    This may indicate a bad file (empty, partial export, or wrong app data).' -ForegroundColor Yellow
    Write-Host '    If this is intentional, increase AccountDeletionThresholdPct in settings.json.' -ForegroundColor Yellow
    Write-SPLog -Message "Deletion threshold exceeded for '$AppName': $($thresholdResult.RemovedPct)% removed (threshold=$($thresholdResult.ThresholdPct)%)" `
        -Severity ERROR -Component 'Invoke-SPDisconnectedAppCert' -Action 'ThresholdCheck' -CorrelationID $correlationID
    Write-Host "  CorrelationID:   $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    exit 5
}

if ($thresholdResult.Reason -eq 'FirstRun') {
    Write-Host '    Threshold check: skipped (first run)' -ForegroundColor DarkGray
}
elseif ($thresholdResult.Reason -eq 'TooFewAccounts') {
    Write-Host '    Threshold check: skipped (< 5 previous accounts)' -ForegroundColor DarkGray
}
elseif ($removedCount -gt 0) {
    Write-Host "    Threshold check: passed ($($thresholdResult.RemovedPct)% removed, limit $($effectiveThresholdPct)%)" -ForegroundColor DarkGray
}

# Check for campaign-triggering changes (adds + grants + enables)
$campaignTriggers = $addedCount + $grantedCount + $enabledCount

if ($campaignTriggers -eq 0) {
    Write-Host ''
    Write-Host '  No campaign-triggering changes detected.' -ForegroundColor Yellow

    # Still generate the HTML report for audit purposes
    Write-Host '  Step 7: Generating delta report...' -ForegroundColor Cyan
    $reportResult = Export-SPDisconnectedAppDeltaHtml -DeltaResult $delta `
        -AppName $AppName -OutputPath $effectiveOutputPath
    if ($reportResult.Success) {
        Write-Host "    Report saved: $($reportResult.Data.FilePath)" -ForegroundColor DarkGray
    }

    Write-SPLog -Message "No campaign-triggering changes for '$AppName'. Added=$addedCount Granted=$grantedCount Enabled=$enabledCount" `
        -Severity INFO -Component 'Invoke-SPDisconnectedAppCert' -Action 'Delta' -CorrelationID $correlationID
    Write-Host "  CorrelationID:   $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

Write-Host "    $campaignTriggers campaign-triggering change(s) found." -ForegroundColor Green

#endregion

#region WhatIf Short-Circuit Display

$runStart = Get-Date

if (($WhatIfPreference -eq $true)) {
    Write-Host ''
    Write-Host '  [WhatIf] Dry-run mode. No write API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Would run disconnected app certification with:' -ForegroundColor Cyan
    Write-Host "    AppName:          $AppName"
    Write-Host "    AccountFile:      $AccountFilePath"
    Write-Host "    DeadlineDays:     $effectiveDeadline"
    Write-Host "    NamePrefix:       $effectivePrefix"
    Write-Host "    MaxCampaigns:     $effectiveMaxCampaigns"
    Write-Host "    Correlation:      $effectiveCorrelation"
    if (-not [string]::IsNullOrWhiteSpace($effectiveFallback)) {
        Write-Host "    FallbackMgr:      $effectiveFallback"
    }
    Write-Host ''
}

#endregion

#region Identity Resolution

Write-Host '  Step 5: Resolving identities in ISC...' -ForegroundColor Cyan

$resolveResult = Resolve-SPDisconnectedAppIdentities -DeltaResult $delta `
    -CorrelationAttribute $effectiveCorrelation -CorrelationID $correlationID

if (-not $resolveResult.Success) {
    Write-Host "ERROR: Identity resolution failed: $($resolveResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Identity resolution failed: $($resolveResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPDisconnectedAppCert' -Action 'Resolve' -CorrelationID $correlationID
    exit 6
}

$resolved = $resolveResult.Data
Write-Host "    Resolved: $($resolved.Summary.Resolved)  Unresolved: $($resolved.Summary.Unresolved)" -ForegroundColor DarkGray

# Real-bug fix (T-03): $resolved.Unresolved is the ARRAY of unresolved entries
# (iterated below), not a count. Comparing the array `-gt 0` throws under
# StrictMode when entries are hashtables ("not IComparable"). Guard on the count.
if (@($resolved.Unresolved).Count -gt 0) {
    foreach ($unr in $resolved.Unresolved) {
        Write-Host "    Unresolved: $($unr.AccountId) ($($unr.Email)) -- $($unr.Reason)" -ForegroundColor Yellow
    }
}

if ($resolved.Summary.Resolved -eq 0) {
    Write-Host '  No identities could be resolved to ISC. No campaigns created.' -ForegroundColor Yellow
    Write-SPLog -Message "No identities resolved for '$AppName'" `
        -Severity WARN -Component 'Invoke-SPDisconnectedAppCert' -Action 'Resolve' -CorrelationID $correlationID
    Write-Host "  CorrelationID:   $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

#endregion

#region Campaign Creation

Write-Host '  Step 6: Creating campaigns...' -ForegroundColor Cyan

$certParams = @{
    AppName              = $AppName
    DeltaResult          = $delta
    ResolvedIdentities   = $resolved
    CampaignNamePrefix   = $effectivePrefix
    DeadlineDays         = $effectiveDeadline
    MaxCampaignsPerRun   = $effectiveMaxCampaigns
    OutputPath           = $effectiveOutputPath
    CorrelationID        = $correlationID
}
if (-not [string]::IsNullOrWhiteSpace($effectiveFallback)) {
    $certParams['FallbackManagerId'] = $effectiveFallback
}
if ($WhatIfPreference -eq $true) {
    $certParams['WhatIf'] = $true
}

$certResult = Invoke-SPDisconnectedAppCertRun @certParams

if (-not $certResult.Success) {
    Write-Host "ERROR: Campaign creation failed: $($certResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Campaign creation failed: $($certResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPDisconnectedAppCert' -Action 'Campaign' -CorrelationID $correlationID
    exit 6
}

$certData = $certResult.Data
$reason   = $certData.Reason

#endregion

#region HTML Report

Write-Host '  Step 7: Generating delta report...' -ForegroundColor Cyan

$reportResult = Export-SPDisconnectedAppDeltaHtml -DeltaResult $delta `
    -AppName $AppName -OutputPath $effectiveOutputPath

if ($reportResult.Success) {
    Write-Host "    Report saved: $($reportResult.Data.FilePath)" -ForegroundColor DarkGray
}
else {
    Write-Host "    Warning: Report generation failed: $($reportResult.Error)" -ForegroundColor Yellow
}

#endregion

#region Output

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

$summary = [PSCustomObject]@{
    CorrelationID        = $correlationID
    AppName              = $AppName
    StartedAt            = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt          = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds      = [math]::Round($runDuration, 2)
    Reason               = $reason
    CampaignsCreated     = $certData.CampaignsCreated
    CampaignIds          = $certData.CampaignIds
    IdentityCount        = $certData.IdentityCount
    ManagerGroups        = $certData.ManagerGroups
    UnresolvedCount      = $certData.UnresolvedCount
    DeltaSummary         = @{
        Added   = $addedCount
        Removed = $removedCount
        Granted = $grantedCount
        Revoked = $revokedCount
        Enabled = $enabledCount
        Disabled = $disabledCount
    }
    ReportPath           = if ($reportResult.Success) { $reportResult.Data.FilePath } else { $null }
    Environment          = $config.Global.EnvironmentName
}

switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 10
    }
    default {
        Write-Host ''
        if ($reason -eq 'NoCampaignTriggers' -or $reason -eq 'NoManagerGroups') {
            Write-Host '  No Campaigns Created' -ForegroundColor Yellow
            Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
            Write-Host "  Reason:          $reason" -ForegroundColor Yellow
            Write-Host "  Resolved:        $($resolved.Summary.Resolved)" -ForegroundColor DarkGray
            Write-Host "  Unresolved:      $($resolved.Summary.Unresolved)" -ForegroundColor DarkGray
        }
        elseif ($reason -eq 'DuplicatesExist') {
            Write-Host '  Duplicate Campaigns Detected' -ForegroundColor Yellow
            Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
            Write-Host "  Today's campaigns already exist for '$AppName'. Use -Force to bypass." -ForegroundColor Yellow
        }
        elseif ($reason -eq 'WhatIf') {
            Write-Host '  WhatIf Summary' -ForegroundColor Cyan
            Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
            Write-Host "  Would create:    $($certData.ManagerGroups) campaign(s)" -ForegroundColor Green
            Write-Host "  Identities:      $($certData.IdentityCount)" -ForegroundColor DarkGray
            Write-Host "  Unresolved:      $($certData.UnresolvedCount)" -ForegroundColor DarkGray
            if ($null -ne $certData.WhatIfGroups) {
                Write-Host ''
                foreach ($mgr in $certData.WhatIfGroups.Keys) {
                    $grp = $certData.WhatIfGroups[$mgr]
                    Write-Host "    Manager: $($grp.ManagerName) ($mgr)" -ForegroundColor DarkCyan
                    Write-Host "      Campaign: $($grp.CampaignName)" -ForegroundColor DarkGray
                    Write-Host "      Deadline: $($grp.Deadline)" -ForegroundColor DarkGray
                    Write-Host "      Identities ($($grp.IdentityCount)): $($grp.IdentityIds -join ', ')" -ForegroundColor DarkGray
                }
            }
        }
        else {
            Write-Host '  Disconnected App Certification Complete' -ForegroundColor Cyan
            Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
            Write-Host "  Campaigns created: $($certData.CampaignsCreated)" -ForegroundColor Green
            Write-Host "  Identities:        $($certData.IdentityCount)" -ForegroundColor DarkGray
            Write-Host "  Manager groups:    $($certData.ManagerGroups)" -ForegroundColor DarkGray
            Write-Host "  Unresolved:        $($certData.UnresolvedCount)" -ForegroundColor DarkGray
            if ($certData.CampaignIds.Count -gt 0) {
                Write-Host "  Campaign IDs:      $($certData.CampaignIds -join ', ')" -ForegroundColor DarkGray
            }
            if ($null -ne $certData.Errors -and $certData.Errors.Count -gt 0) {
                Write-Host ''
                Write-Host "  Errors ($($certData.Errors.Count)):" -ForegroundColor Yellow
                foreach ($err in $certData.Errors) {
                    Write-Host "    $err" -ForegroundColor Yellow
                }
            }
        }

        if ($null -ne $summary.ReportPath) {
            Write-Host "  Report:          $($summary.ReportPath)" -ForegroundColor DarkGray
        }
        Write-Host "  Duration:        $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  Environment:     $($summary.Environment)" -ForegroundColor DarkGray
        Write-Host "  CorrelationID:   $correlationID" -ForegroundColor DarkGray
        Write-Host ''

        if ($OutputMode -eq 'Both') {
            Write-Host '  JSON Output:' -ForegroundColor Cyan
            $summary | ConvertTo-Json -Depth 10
        }
    }
}

Write-SPLog -Message "Invoke-SPDisconnectedAppCert completed: AppName='$AppName' Reason='$reason' Campaigns=$($certData.CampaignsCreated) Identities=$($certData.IdentityCount)" `
    -Severity INFO -Component 'Invoke-SPDisconnectedAppCert' -Action 'Complete' -CorrelationID $correlationID

# Exit code: 1 for no-changes/no-triggers, 0 otherwise
if ($reason -eq 'NoCampaignTriggers' -or $reason -eq 'NoManagerGroups' -or $reason -eq 'DuplicatesExist') {
    exit 1
}

exit 0

#endregion

#Requires -Version 5.1
<#
.SYNOPSIS
    Creates AD certification campaigns for managers of users who received new AD access
    (daily DELTA mode) or for all managers with staff on monitored AD sources (quarterly
    FULL mode via -FullCert).
.DESCRIPTION
    DELTA mode (default):
        Queries SailPoint ISC account activities for GRANT_ACCESS events on specified AD
        sources within a configurable time window. For each affected active identity,
        resolves their manager and groups them. Creates one SEARCH-type certification
        campaign per manager group, scoped to only those managers' direct reports who
        received new access in the window.

        If no AD grant events are found in the time window the script exits with code 1
        (no-op -- this is the expected daily result on quiet days).

    FULL mode (-FullCert switch):
        Bypasses account-activity detection entirely. Queries all active identities who
        have accounts on the monitored source IDs, resolves their unique managers, and
        creates one MANAGER-type campaign per manager. The MANAGER campaign type in ISC
        automatically scopes to ALL direct reports of the certifier identity, presenting
        their complete entitlement set. Use for quarterly baseline reviews before starting
        the daily DELTA cron.

        Full-cert campaigns use a separate name prefix (DeltaCert.FullCert.CampaignNamePrefix,
        default: 'AD Full Cert') to avoid colliding with same-day DELTA campaigns.

    FIRST-RUN ADVISORY:
        If the deltacert-audit.jsonl baseline file does not exist and -FullCert is not
        specified, the script emits a WARNING recommending a -FullCert run first.

    SCOPE REQUIREMENT (DELTA mode):
        GET /v3/account-activities requires sp:scopes:all or a browser token.
        Use -Token with a JWT from the ISC admin console, or configure a PAT with
        sp:scopes:all in settings.json / the vault.

    ISC API LIMITATION:
        The /v3/campaigns SEARCH type accepts filter.query.query as a Lucene IDENTITY
        filter (id:"..." OR id:"..."). There is no entitlement-level filter parameter
        in the campaign creation body. DELTA mode scopes campaigns to only the identities
        who received new access (narrowing the reviewer's queue), but the reviewer will
        see ALL entitlements for those identities, not just the newly-granted AD group.

.PARAMETER SourceId
    One or more SailPoint ISC source IDs to monitor for AD group add operations.
    Obtain from: ISC Admin > Sources > select source > URL contains the source ID.
    Example: -SourceId 'abc123def456', @('src-1','src-2')
.PARAMETER HoursBack
    Look-back window in hours. Default: 24 (one full day).
    Increase to 48+ for catch-up after a missed run.
    Ignored in -FullCert mode.
.PARAMETER DeadlineDays
    Days from today until the campaign deadline. Default: 2 for DELTA mode.
    In -FullCert mode, reads DeltaCert.FullCert.DeadlineDays from settings.json
    (default: 14 days to accommodate quarterly review cadence).
.PARAMETER FullCert
    When set, runs the quarterly full-certification workflow (Invoke-SPDeltaCertFullRun)
    instead of the daily delta workflow. Creates one MANAGER-type campaign per manager
    who has staff on the monitored sources. Does NOT query account-activities.

    Run this once before starting the daily DELTA cron to establish a baseline, then
    schedule quarterly or as needed for periodic comprehensive reviews.
.PARAMETER FallbackReviewerIdentityId
    Identity ID of the reviewer to assign for identities who have no manager in ISC.
    If omitted, manager-less identities are skipped and logged as warnings.
.PARAMETER CampaignNamePrefix
    Prefix for DELTA campaign names. Defaults to the DeltaCert.CampaignNamePrefix value
    in settings.json (fallback: 'AD Delta Cert').
    Full name: "{Prefix} {YYYY-MM-DD} - {ManagerName}"
    Full-cert campaigns use DeltaCert.FullCert.CampaignNamePrefix instead.
.PARAMETER MaxCampaignsPerRun
    Abort before creating any campaigns if the number of manager groups exceeds this.
    Defaults to DeltaCert.MaxCampaignsPerRun in settings.json (fallback: 50).
.PARAMETER ReviewerMode
    Determines who reviews the delta cert campaigns.
    Manager (default): One SEARCH campaign per manager group. Each manager
        reviews only their direct reports who received new AD access.
    SourceOwner: One SOURCE_OWNER campaign per source ID. ISC automatically
        routes certification items to whoever owns each source.
    Defaults to DeltaCert.DefaultReviewerMode in settings.json (fallback: Manager).
    In -FullCert mode, this parameter is ignored (MANAGER type is always used).
.PARAMETER RunCleanup
    When set, runs Invoke-SPDeltaCertCleanup before creating new campaigns.
    Completes past-due delta cert campaigns that have exceeded their deadline
    or are older than DeltaCert.CleanupDaysStale (default: 3 days).
    Requires Safety.AllowCompleteCampaign = true in settings.json.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to this script.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials entirely. Obtain via:
    F12 > Network tab > any ISC API call > Authorization header value.
    The "Bearer " prefix is stripped automatically if present.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
    ISC browser tokens are typically valid for ~12 minutes.
.PARAMETER OutputMode
    Console (default): formatted summary to terminal.
    JSON: machine-parseable result object.
    Both: console output followed by the JSON object.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123'
    # Daily DELTA run: campaigns for managers of identities who got new AD access in the last 24 hours.
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -FullCert
    # Quarterly FULL run: one MANAGER campaign per manager with staff on the source (baseline mode).
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -WhatIf
    # Dry-run: show what campaigns would be created without making any write API calls.
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -FullCert -WhatIf
    # Dry-run full-cert: show which managers would receive MANAGER campaigns.
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId @('src-abc','src-def') -HoursBack 48 -DeadlineDays 3
    # Catch-up DELTA run across two AD sources with 48-hour window and 3-day deadline.
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -Token 'eyJhbGciOiJSUzI1...'
    # Use a browser token instead of OAuth credentials (required for sp:scopes:all).
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -FallbackReviewerIdentityId 'mgr-fallback-id'
    # Include manager-less identities, routing them to a designated fallback reviewer.
.NOTES
    Script:  Invoke-SPADDeltaCert.ps1
    Version: 1.1.0
    Exit codes:
        0 = Success -- campaigns created (or WhatIf completed)
        1 = No changes -- no events found, no campaigns created (DELTA no-op days)
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Campaign creation/activation error (partial or full failure)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourceId,

    [Parameter()]
    [int]$HoursBack = 24,

    [Parameter()]
    [int]$DeadlineDays = 2,

    [Parameter()]
    # When set, runs the quarterly full-certification workflow instead of the daily
    # delta workflow. Creates one MANAGER-type campaign per manager who has staff on
    # the monitored sources. Does NOT query account-activities. Use before starting
    # the daily DELTA cron to establish a full baseline, then schedule quarterly.
    [switch]$FullCert,

    [Parameter()]
    [string]$FallbackReviewerIdentityId,

    [Parameter()]
    [string]$CampaignNamePrefix,

    [Parameter()]
    [int]$MaxCampaignsPerRun = 0,

    [Parameter()]
    [ValidateSet('Manager', 'SourceOwner')]
    [string]$ReviewerMode,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [switch]$RunCleanup,

    # When set, only creates campaigns for identities who received a GRANT_ACCESS event
    # where the specific AD entitlement is marked privileged:true in ISC.
    # Falls back to Audit.RiskIndicators.PrivilegedPatterns for entitlements not yet
    # tagged in ISC (unmanaged groups, recently aggregated sources).
    # Default: read from DeltaCert.PrivilegedOnly in settings.json (false if not set).
    # ISC scope required: idn:entitlement:read or sp:scopes:all
    [Parameter()]
    [switch]$PrivilegedOnly,

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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';         Name = 'SP.Core';         Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';           Name = 'SP.Api';           Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'; Name = 'SP.DeltaCert'; Required = $true  }
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
if ($FullCert) {
    Write-Host '  AD Full Certification (Quarterly Baseline Mode)' -ForegroundColor Cyan
}
else {
    Write-Host '  AD Delta Certification' -ForegroundColor Cyan
}
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
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
$effectivePrefix = $CampaignNamePrefix
if ([string]::IsNullOrWhiteSpace($effectivePrefix)) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['CampaignNamePrefix'] -and
        -not [string]::IsNullOrWhiteSpace($config.DeltaCert.CampaignNamePrefix)) {
        $effectivePrefix = [string]$config.DeltaCert.CampaignNamePrefix
    }
    else {
        $effectivePrefix = 'AD Delta Cert'
    }
}

$effectiveMaxCampaigns = $MaxCampaignsPerRun
if ($effectiveMaxCampaigns -le 0) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['MaxCampaignsPerRun'] -and
        [int]$config.DeltaCert.MaxCampaignsPerRun -gt 0) {
        $effectiveMaxCampaigns = [int]$config.DeltaCert.MaxCampaignsPerRun
    }
    else {
        $effectiveMaxCampaigns = 50
    }
}

$effectiveFallback = $FallbackReviewerIdentityId
if ([string]::IsNullOrWhiteSpace($effectiveFallback)) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['FallbackReviewerIdentityId']) {
        $effectiveFallback = [string]$config.DeltaCert.FallbackReviewerIdentityId
    }
}

$effectiveReviewerMode = $ReviewerMode
if ([string]::IsNullOrWhiteSpace($effectiveReviewerMode)) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['DefaultReviewerMode'] -and
        -not [string]::IsNullOrWhiteSpace($config.DeltaCert.DefaultReviewerMode)) {
        $effectiveReviewerMode = [string]$config.DeltaCert.DefaultReviewerMode
    }
    else {
        $effectiveReviewerMode = 'Manager'
    }
}

# Apply config defaults for FullCert-specific parameters
$effectiveFullCertPrefix = 'AD Full Cert'
if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
    $null -ne $config.DeltaCert -and
    $null -ne $config.DeltaCert.PSObject.Properties['FullCert'] -and
    $null -ne $config.DeltaCert.FullCert -and
    $null -ne $config.DeltaCert.FullCert.PSObject.Properties['CampaignNamePrefix'] -and
    -not [string]::IsNullOrWhiteSpace($config.DeltaCert.FullCert.CampaignNamePrefix)) {
    $effectiveFullCertPrefix = [string]$config.DeltaCert.FullCert.CampaignNamePrefix
}

$effectiveFullCertDeadline = 14
if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
    $null -ne $config.DeltaCert -and
    $null -ne $config.DeltaCert.PSObject.Properties['FullCert'] -and
    $null -ne $config.DeltaCert.FullCert -and
    $null -ne $config.DeltaCert.FullCert.PSObject.Properties['DeadlineDays'] -and
    [int]$config.DeltaCert.FullCert.DeadlineDays -gt 0) {
    $effectiveFullCertDeadline = [int]$config.DeltaCert.FullCert.DeadlineDays
}

# Apply PrivilegedOnly default from config when the switch was not explicitly passed
$effectivePrivilegedOnly = $PrivilegedOnly.IsPresent
if (-not $effectivePrivilegedOnly) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['PrivilegedOnly'] -and
        [bool]$config.DeltaCert.PrivilegedOnly -eq $true) {
        $effectivePrivilegedOnly = $true
    }
}

# First-run advisory: if no audit baseline exists and -FullCert is not set, warn the operator.
# The audit JSONL file is written on every successful run. Its absence means this is either
# a brand-new deployment or the output directory was reset. In DELTA mode without a prior
# FULL baseline, managers will only see entitlements granted in the current window -- any
# access granted before this run started will not be reviewed until the next full cycle.
if (-not $FullCert) {
    $baselineExists = Test-SPDeltaCertBaselineExists
    if (-not $baselineExists) {
        $advisoryMsg = 'No prior run detected (deltacert-audit.jsonl not found). ' +
            "DELTA mode will only certify entitlements granted in the last $HoursBack hours. " +
            'To establish a full baseline first, re-run with -FullCert. ' +
            'Continuing in DELTA mode...'
        Write-Host "  WARNING: $advisoryMsg" -ForegroundColor Yellow
        Write-SPLog -Message $advisoryMsg `
            -Severity WARN -Component 'Invoke-SPADDeltaCert' -Action 'FirstRunCheck' `
            -CorrelationID $correlationID
    }
}

Write-SPLog -Message "Invoke-SPADDeltaCert started: SourceIds='$($SourceId -join ',')' HoursBack=$HoursBack DeadlineDays=$DeadlineDays FullCert=$($FullCert.IsPresent) PrivilegedOnly=$effectivePrivilegedOnly" `
    -Severity INFO -Component 'Invoke-SPADDeltaCert' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Cleanup

if ($RunCleanup) {
    Write-Host '  Running campaign cleanup...' -ForegroundColor Cyan

    $effectiveCleanupDays = 3
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['CleanupDaysStale'] -and
        [int]$config.DeltaCert.CleanupDaysStale -gt 0) {
        $effectiveCleanupDays = [int]$config.DeltaCert.CleanupDaysStale
    }

    $cleanupParams = @{
        CampaignNamePrefix = $effectivePrefix
        DaysStale          = $effectiveCleanupDays
        CorrelationID      = $correlationID
    }

    $cleanupResult = Invoke-SPDeltaCertCleanup @cleanupParams

    if ($cleanupResult.Success) {
        $cData = $cleanupResult.Data
        Write-Host "  Cleanup: Completed=$($cData.Completed.Count) StillActive=$($cData.StillActive.Count) Errors=$($cData.Errors.Count)" -ForegroundColor Green
        if ($cData.Errors.Count -gt 0) {
            foreach ($cErr in $cData.Errors) {
                Write-Host "    $cErr" -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host "  Cleanup warning: $($cleanupResult.Error)" -ForegroundColor Yellow
    }
    Write-Host ''
}

#endregion

#region Dispatch

$runStart = Get-Date

# WhatIf short-circuit: validate config and describe what would run
if (($WhatIfPreference -eq $true)) {
    Write-Host '  [WhatIf] Dry-run mode. No write API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    if ($FullCert) {
        Write-Host '  Would run full certification with:' -ForegroundColor Cyan
        Write-Host "    SourceIds:      $($SourceId -join ', ')"
        Write-Host "    NamePrefix:     $effectiveFullCertPrefix"
        Write-Host "    DeadlineDays:   $effectiveFullCertDeadline"
        Write-Host "    MaxCampaigns:   $effectiveMaxCampaigns"
        Write-Host "    Mode:           MANAGER (quarterly full-cert)"
    }
    else {
        Write-Host '  Would run delta certification with:' -ForegroundColor Cyan
        Write-Host "    SourceIds:      $($SourceId -join ', ')"
        Write-Host "    HoursBack:      $HoursBack"
        Write-Host "    DeadlineDays:   $DeadlineDays"
        Write-Host "    NamePrefix:     $effectivePrefix"
        Write-Host "    MaxCampaigns:   $effectiveMaxCampaigns"
        Write-Host "    ReviewerMode:   $effectiveReviewerMode"
        Write-Host "    PrivilegedOnly: $effectivePrivilegedOnly"
        if (-not [string]::IsNullOrWhiteSpace($effectiveFallback)) {
            Write-Host "    FallbackMgr:    $effectiveFallback"
        }
    }
    Write-Host ''
}

$runResult = $null

if ($FullCert) {
    # FullCert mode: quarterly MANAGER campaigns for all managers with staff on monitored sources.
    # Note: -ReviewerMode is ignored in FULL mode; MANAGER type is always used.
    if (-not [string]::IsNullOrWhiteSpace($effectiveReviewerMode) -and
        $effectiveReviewerMode -ne 'Manager') {
        Write-SPLog -Message "FullCert mode: -ReviewerMode '$effectiveReviewerMode' is ignored. MANAGER campaign type is always used for full-cert runs." `
            -Severity INFO -Component 'Invoke-SPADDeltaCert' -Action 'Dispatch' `
            -CorrelationID $correlationID
        Write-Host "  Note: -ReviewerMode is ignored in -FullCert mode (always uses MANAGER type)." -ForegroundColor DarkGray
    }

    Write-Host "  Resolving managers for full certification..." -ForegroundColor Cyan

    $fullRunParams = @{
        SourceIds          = $SourceId
        DeadlineDays       = $effectiveFullCertDeadline
        CampaignNamePrefix = $effectiveFullCertPrefix
        MaxCampaignsPerRun = $effectiveMaxCampaigns
        CorrelationID      = $correlationID
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveFallback)) {
        $fullRunParams['FallbackManagerId'] = $effectiveFallback
    }
    if ($WhatIfPreference -eq $true) {
        $fullRunParams['WhatIf'] = $true
    }

    $runResult = Invoke-SPDeltaCertFullRun @fullRunParams
}
else {
    # DELTA mode (default): daily SEARCH campaigns per manager group.
    Write-Host "  Querying AD grant events (last $HoursBack hours)..." -ForegroundColor Cyan

    $runParams = @{
        SourceIds            = $SourceId
        HoursBack            = $HoursBack
        DeadlineDays         = $DeadlineDays
        CampaignNamePrefix   = $effectivePrefix
        MaxCampaignsPerRun   = $effectiveMaxCampaigns
        ReviewerMode         = $effectiveReviewerMode
        CorrelationID        = $correlationID
        PrivilegedOnly       = $effectivePrivilegedOnly
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveFallback)) {
        $runParams['FallbackManagerId'] = $effectiveFallback
    }
    if ($WhatIfPreference -eq $true) {
        $runParams['WhatIf'] = $true
    }

    $runResult = Invoke-SPDeltaCertRun @runParams
}

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

if (-not $runResult.Success) {
    Write-Host "ERROR: Delta cert run failed: $($runResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Invoke-SPADDeltaCert failed: $($runResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPADDeltaCert' -Action 'Run' -CorrelationID $correlationID
    exit 5
}

$data   = $runResult.Data
$reason = $data.Reason

#endregion

#region Output

$summary = [PSCustomObject]@{
    CorrelationID    = $correlationID
    RunMode          = if ($FullCert) { 'Full' } else { 'Delta' }
    StartedAt        = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt      = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds  = [math]::Round($runDuration, 2)
    Reason           = $reason
    CampaignsCreated = $data.CampaignsCreated
    CampaignIds      = $data.CampaignIds
    IdentityCount    = $data.IdentityCount
    ManagerGroups    = $data.ManagerGroups
    Sources          = $SourceId
    Environment      = $config.Global.EnvironmentName
}

switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 10
    }
    default {
        Write-Host ''
        if ($reason -eq 'NoChanges') {
            Write-Host '  No Changes' -ForegroundColor Yellow
            Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
            Write-Host '  No AD grant events found in the time window.' -ForegroundColor Yellow
            Write-Host "  Sources:       $($SourceId -join ', ')" -ForegroundColor DarkGray
            Write-Host "  Window:        last $HoursBack hours" -ForegroundColor DarkGray
        }
        elseif ($reason -eq 'NoPrivilegedGrants') {
            Write-Host '  No Privileged Grants' -ForegroundColor Yellow
            Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
            Write-Host '  AD grant events were found but none involved privileged entitlements.' -ForegroundColor Yellow
            Write-Host "  Sources:       $($SourceId -join ', ')" -ForegroundColor DarkGray
            Write-Host "  Window:        last $HoursBack hours" -ForegroundColor DarkGray
            Write-Host '  To certify all grants regardless of privilege flag, omit -PrivilegedOnly.' -ForegroundColor DarkGray
        }
        elseif ($reason -eq 'WhatIf') {
            Write-Host '  WhatIf Summary' -ForegroundColor Cyan
            Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
            Write-Host "  Would create:  $($data.ManagerGroups) campaign(s)" -ForegroundColor Green
            Write-Host "  Identities:    $($data.IdentityCount)" -ForegroundColor DarkGray
            if ($null -ne $data.WhatIfGroups) {
                Write-Host ''
                foreach ($mgr in $data.WhatIfGroups.Keys) {
                    $grp = $data.WhatIfGroups[$mgr]
                    Write-Host "    Manager: $($grp.ManagerName) ($mgr)" -ForegroundColor DarkCyan
                    Write-Host "      Campaign: $($grp.CampaignName)" -ForegroundColor DarkGray
                    Write-Host "      Deadline: $($grp.Deadline)" -ForegroundColor DarkGray
                    Write-Host "      Identities ($($grp.IdentityCount)): $($grp.IdentityIds -join ', ')" -ForegroundColor DarkGray
                }
            }
        }
        else {
            $completeLabel = if ($FullCert) { 'Full Certification Complete' } else { 'Delta Certification Complete' }
            Write-Host "  $completeLabel" -ForegroundColor Cyan
            Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
            Write-Host "  Campaigns created: $($data.CampaignsCreated)" -ForegroundColor Green
            if ($data.IdentityCount -gt 0) {
                Write-Host "  Identities:        $($data.IdentityCount)" -ForegroundColor DarkGray
            }
            Write-Host "  Manager groups:    $($data.ManagerGroups)" -ForegroundColor DarkGray
            if ($data.CampaignIds.Count -gt 0) {
                Write-Host "  Campaign IDs:      $($data.CampaignIds -join ', ')" -ForegroundColor DarkGray
            }
            if ($null -ne $data.Errors -and $data.Errors.Count -gt 0) {
                Write-Host ''
                Write-Host "  Errors ($($data.Errors.Count)):" -ForegroundColor Yellow
                foreach ($err in $data.Errors) {
                    Write-Host "    $err" -ForegroundColor Yellow
                }
            }
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

Write-SPLog -Message "Invoke-SPADDeltaCert completed: Reason='$reason' Campaigns=$($data.CampaignsCreated) Identities=$($data.IdentityCount)" `
    -Severity INFO -Component 'Invoke-SPADDeltaCert' -Action 'Complete' -CorrelationID $correlationID

# Exit code: 1 for no-changes (expected on quiet DELTA days, or no managers found in FULL mode)
if ($reason -eq 'NoChanges' -or $reason -eq 'NoPrivilegedGrants' -or
    $reason -eq 'NoActiveIdentities' -or $reason -eq 'NoManagerGroups' -or
    $reason -eq 'NoManagers') {
    exit 1
}

exit 0

#endregion

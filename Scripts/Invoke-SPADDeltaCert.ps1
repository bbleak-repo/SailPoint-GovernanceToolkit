#Requires -Version 5.1
<#
.SYNOPSIS
    Creates daily AD delta certification campaigns for managers of users who received new AD access.
.DESCRIPTION
    Queries SailPoint ISC account activities for GRANT_ACCESS events on specified AD sources
    within a configurable time window. For each affected active identity, resolves their
    manager and groups them accordingly. Creates one SEARCH-type certification campaign per
    manager group, scoped to only those manager's direct reports who received new access.

    If no AD grant events are found in the time window the script exits with code 1
    (no-op -- this is the expected daily result on quiet days).

    SCOPE REQUIREMENT:
        GET /v3/account-activities requires sp:scopes:all or a browser token.
        Use -Token with a JWT from the ISC admin console, or configure a PAT with
        sp:scopes:all in settings.json / the vault.

.PARAMETER SourceId
    One or more SailPoint ISC source IDs to monitor for AD group add operations.
    Obtain from: ISC Admin > Sources > select source > URL contains the source ID.
    Example: -SourceId 'abc123def456', @('src-1','src-2')
.PARAMETER HoursBack
    Look-back window in hours. Default: 24 (one full day).
    Increase to 48+ for catch-up after a missed run.
.PARAMETER DeadlineDays
    Days from today until the campaign deadline. Default: 2.
    Managers receive the campaign today and have this many days to review.
.PARAMETER FallbackReviewerIdentityId
    Identity ID of the reviewer to assign for identities who have no manager in ISC.
    If omitted, manager-less identities are skipped and logged as warnings.
.PARAMETER CampaignNamePrefix
    Prefix for campaign names. Defaults to the DeltaCert.CampaignNamePrefix value
    in settings.json (fallback: 'AD Delta Cert').
    Full name: "{Prefix} {YYYY-MM-DD} - {ManagerName}"
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
    # Daily run: create campaigns for managers of identities who got new AD access in the last 24 hours.
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -WhatIf
    # Dry-run: show what campaigns would be created without making any write API calls.
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId @('src-abc','src-def') -HoursBack 48 -DeadlineDays 3
    # Catch-up run across two AD sources with 48-hour window and 3-day deadline.
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -Token 'eyJhbGciOiJSUzI1...'
    # Use a browser token instead of OAuth credentials (required for sp:scopes:all).
.EXAMPLE
    .\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -FallbackReviewerIdentityId 'mgr-fallback-id'
    # Include manager-less identities, routing them to a designated fallback reviewer.
.NOTES
    Script:  Invoke-SPADDeltaCert.ps1
    Version: 1.0.0
    Exit codes:
        0 = Success -- campaigns created (or WhatIf completed)
        1 = No changes -- no AD grant events found, no campaigns created
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
        Import-Module $mod.Path -Force -ErrorAction Stop
    }
    else {
        $moduleDir = Split-Path -Parent $mod.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue
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
Write-Host '  AD Delta Certification' -ForegroundColor Cyan
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

Write-SPLog -Message "Invoke-SPADDeltaCert started: SourceIds='$($SourceId -join ',')' HoursBack=$HoursBack DeadlineDays=$DeadlineDays" `
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
    Write-Host '  Would run delta certification with:' -ForegroundColor Cyan
    Write-Host "    SourceIds:      $($SourceId -join ', ')"
    Write-Host "    HoursBack:      $HoursBack"
    Write-Host "    DeadlineDays:   $DeadlineDays"
    Write-Host "    NamePrefix:     $effectivePrefix"
    Write-Host "    MaxCampaigns:   $effectiveMaxCampaigns"
    Write-Host "    ReviewerMode:   $effectiveReviewerMode"
    if (-not [string]::IsNullOrWhiteSpace($effectiveFallback)) {
        Write-Host "    FallbackMgr:    $effectiveFallback"
    }
    Write-Host ''
}

Write-Host "  Querying AD grant events (last $HoursBack hours)..." -ForegroundColor Cyan

$runParams = @{
    SourceIds            = $SourceId
    HoursBack            = $HoursBack
    DeadlineDays         = $DeadlineDays
    CampaignNamePrefix   = $effectivePrefix
    MaxCampaignsPerRun   = $effectiveMaxCampaigns
    ReviewerMode         = $effectiveReviewerMode
    CorrelationID        = $correlationID
}
if (-not [string]::IsNullOrWhiteSpace($effectiveFallback)) {
    $runParams['FallbackManagerId'] = $effectiveFallback
}

$runResult = Invoke-SPDeltaCertRun @runParams

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
            Write-Host '  Delta Certification Complete' -ForegroundColor Cyan
            Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
            Write-Host "  Campaigns created: $($data.CampaignsCreated)" -ForegroundColor Green
            Write-Host "  Identities:        $($data.IdentityCount)" -ForegroundColor DarkGray
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

# Exit code: 1 for no-changes (expected on quiet days), 0 otherwise
if ($reason -eq 'NoChanges' -or $reason -eq 'NoActiveIdentities' -or $reason -eq 'NoManagerGroups') {
    exit 1
}

exit 0

#endregion

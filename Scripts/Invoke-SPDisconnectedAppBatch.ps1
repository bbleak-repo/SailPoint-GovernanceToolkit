#Requires -Version 5.1
<#
.SYNOPSIS
    Batch orchestrator for disconnected app certifications across all registered apps.
.DESCRIPTION
    Processes all (or specified) registered disconnected apps in sequence, running the
    full certification pipeline for each: validate, snapshot, delta, threshold check,
    resolve, campaign, report. Errors are isolated per-app so one failure does not
    stop the batch.

    Pipeline per app:
    1. Validate account CSV (Test-SPDisconnectedAppAccountFile)
    2. Save today's snapshot (Save-SPDisconnectedAppSnapshot)
    3. Find previous snapshot (Get-SPDisconnectedAppPreviousSnapshot)
    4. Detect delta (Compare-SPDisconnectedAppFiles)
    5. Check deletion threshold (Test-SPDisconnectedAppDeletionThreshold)
    6. Resolve identities in ISC (Resolve-SPDisconnectedAppIdentities)
    7. Create campaigns (Invoke-SPDisconnectedAppCertRun)
    8. Generate HTML delta report (Export-SPDisconnectedAppDeltaHtml)

    Each app's result is classified as: Success, NoChanges, ThresholdBlocked, Error.

    SCOPE REQUIREMENT:
        Identity resolution requires sp:search:read.
        Campaign creation requires idn:campaign:read + idn:campaign:manage.
        Use -Token with a JWT from the ISC admin console if OAuth PAT is unavailable.

.PARAMETER AppNames
    Optional filter: only process these app names. If omitted, all enabled registered
    apps are processed.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to this script.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials entirely.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER FallbackReviewerIdentityId
    Identity ID used as reviewer for identities who have no manager in ISC.
    If omitted, manager-less identities are skipped.
.PARAMETER Force
    Bypass the duplicate campaign guard on all apps.
.PARAMETER OutputMode
    Console (default): formatted summary to terminal.
    JSON: machine-parseable result object.
    Both: console output followed by the JSON object.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPDisconnectedAppBatch.ps1
    # Process all enabled registered apps.
.EXAMPLE
    .\Invoke-SPDisconnectedAppBatch.ps1 -AppNames @('PEP-Plus','DebtNext')
    # Process only PEP-Plus and DebtNext.
.EXAMPLE
    .\Invoke-SPDisconnectedAppBatch.ps1 -WhatIf
    # Dry-run: validate and detect changes without creating campaigns.
.EXAMPLE
    .\Invoke-SPDisconnectedAppBatch.ps1 -Token 'eyJhbGciOiJSUzI1...' -OutputMode JSON
    # Process all apps with browser token auth, JSON output.
.NOTES
    Script:  Invoke-SPDisconnectedAppBatch.ps1
    Version: 1.0.0
    Exit codes:
        0 = All apps succeeded (or NoChanges)
        1 = Partial -- some apps failed or were blocked
        2 = All apps failed
        3 = Authentication error
        4 = Configuration error
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string[]]$AppNames,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [string]$FallbackReviewerIdentityId,

    [Parameter()]
    [switch]$Force,

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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';                       Name = 'SP.Core';             Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';                         Name = 'SP.Api';               Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1';             Name = 'SP.DeltaCert';         Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DisconnectedApps\SP.DisconnectedApps.psd1'; Name = 'SP.DisconnectedApps'; Required = $true  }
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

$batchCorrelationID = [guid]::NewGuid().ToString()
$batchStartTime     = Get-Date

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Disconnected App Batch Orchestrator' -ForegroundColor Cyan
Write-Host "  CorrelationID:   $batchCorrelationID" -ForegroundColor DarkGray
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
    Write-Host 'INFO: First-run configuration detected. Update settings.json and run again.' -ForegroundColor Yellow
    exit 4
}

if (-not (Test-SPConfig -Config $config)) {
    Write-Host 'ERROR: Configuration validation failed. Check settings.json for required values.' -ForegroundColor Red
    exit 4
}

try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
} catch { }

# Browser token injection
if ($Token) {
    Write-Host '  Auth: Injecting browser token...' -ForegroundColor Gray
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes `
        -CorrelationID $batchCorrelationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

# Load DisconnectedApps config defaults
$daConfig = $null
if ($null -ne $config.PSObject.Properties['DisconnectedApps'] -and $null -ne $config.DisconnectedApps) {
    $daConfig = $config.DisconnectedApps
}

if ($null -eq $daConfig) {
    Write-Host 'ERROR: DisconnectedApps section not found in settings.json.' -ForegroundColor Red
    exit 4
}

# Resolve config defaults
$effectiveSnapshotDir = '.\DisconnectedApps\Snapshots'
if ($null -ne $daConfig.PSObject.Properties['SnapshotPath'] -and
    -not [string]::IsNullOrWhiteSpace($daConfig.SnapshotPath)) {
    $effectiveSnapshotDir = [string]$daConfig.SnapshotPath
}

$effectiveOutputPath = '.\DisconnectedApps\Reports'
if ($null -ne $daConfig.PSObject.Properties['ReportPath'] -and
    -not [string]::IsNullOrWhiteSpace($daConfig.ReportPath)) {
    $effectiveOutputPath = [string]$daConfig.ReportPath
}

$effectiveFallback = $FallbackReviewerIdentityId
if ([string]::IsNullOrWhiteSpace($effectiveFallback)) {
    if ($null -ne $daConfig.PSObject.Properties['FallbackReviewerIdentityId']) {
        $effectiveFallback = [string]$daConfig.FallbackReviewerIdentityId
    }
}

Write-SPLog -Message "Invoke-SPDisconnectedAppBatch started: CorrelationID=$batchCorrelationID" `
    -Severity INFO -Component 'Invoke-SPDisconnectedAppBatch' -Action 'Start' -CorrelationID $batchCorrelationID

#endregion

#region Load and Filter Apps

Write-Host '  Step 1: Loading registered apps...' -ForegroundColor Cyan

$appsResult = Get-SPRegisteredApps -ConfigPath $ConfigPath
if (-not $appsResult.Success) {
    Write-Host "ERROR: Failed to load registered apps: $($appsResult.Error)" -ForegroundColor Red
    exit 4
}

$apps = @($appsResult.Data)

if ($apps.Count -eq 0) {
    Write-Host '  No enabled registered apps found.' -ForegroundColor Yellow
    exit 4
}

# Filter by -AppNames if specified
if ($AppNames -and $AppNames.Count -gt 0) {
    $filteredApps = @($apps | Where-Object { $_.Name -in $AppNames })

    # Warn about unrecognized names
    foreach ($requestedName in $AppNames) {
        $match = $apps | Where-Object { $_.Name -eq $requestedName }
        if ($null -eq $match) {
            Write-Host "  Warning: App '$requestedName' is not registered or not enabled. Skipping." -ForegroundColor Yellow
        }
    }

    $apps = $filteredApps

    if ($apps.Count -eq 0) {
        Write-Host '  No matching enabled apps found for the specified names.' -ForegroundColor Yellow
        exit 4
    }
}

Write-Host "    $($apps.Count) app(s) to process." -ForegroundColor DarkGray
Write-Host ''

#endregion

#region WhatIf Banner

if (($WhatIfPreference -eq $true)) {
    Write-Host '  [WhatIf] Dry-run mode. No write API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
}

#endregion

#region Batch Processing

$batchResults = [System.Collections.Generic.List[hashtable]]::new()
$appIndex     = 0

foreach ($app in $apps) {
    $appIndex++
    $appName = $app.Name
    $appCorrelationID = [guid]::NewGuid().ToString()
    $appStartTime     = Get-Date

    Write-Host "  [$appIndex/$($apps.Count)] Processing: $appName" -ForegroundColor Cyan
    Write-Host "    CorrelationID: $appCorrelationID" -ForegroundColor DarkGray

    $appResult = @{
        App             = $appName
        Status          = 'Error'
        CorrelationID   = $appCorrelationID
        StartedAt       = $appStartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        CompletedAt     = $null
        DurationSeconds = 0
        CampaignsCreated = 0
        CampaignIds     = @()
        IdentityCount   = 0
        DeltaSummary    = @{}
        ReportPath      = $null
        Error           = $null
        Reason          = $null
    }

    try {
        # --- Resolve per-app config values ---
        $appAccountPath    = $app.AccountFilePath
        $appCorrelation    = $app.CorrelationAttribute
        $appPrefix         = $app.CampaignNamePrefix
        $appDeadline       = $app.DeadlineDays
        $appThresholdPct   = $app.AccountDeletionThresholdPct

        $appMaxCampaigns = 20
        if ($null -ne $daConfig.PSObject.Properties['MaxCampaignsPerRun'] -and
            [int]$daConfig.MaxCampaignsPerRun -gt 0) {
            $appMaxCampaigns = [int]$daConfig.MaxCampaignsPerRun
        }

        # --- Step A: Validate account file ---
        Write-Host '    a. Validating CSV...' -ForegroundColor DarkCyan

        if ([string]::IsNullOrWhiteSpace($appAccountPath)) {
            throw "AccountFilePath is empty for app '$appName'."
        }

        if (-not (Test-Path -Path $appAccountPath -PathType Leaf)) {
            throw "Account file not found: $appAccountPath"
        }

        $acctValidation = Test-SPDisconnectedAppAccountFile -FilePath $appAccountPath

        if (-not $acctValidation.Success) {
            throw "Account CSV validation failed: $($acctValidation.Error)"
        }

        Write-Host "       $($acctValidation.Data.RowCount) rows ($($acctValidation.Data.ValidRows) valid)" -ForegroundColor DarkGray

        # --- Step B: Save snapshot ---
        Write-Host '    b. Saving snapshot...' -ForegroundColor DarkCyan

        $snapshotResult = Save-SPDisconnectedAppSnapshot -FilePath $appAccountPath `
            -AppName $appName -FileType 'accounts' -SnapshotDir $effectiveSnapshotDir

        if (-not $snapshotResult.Success) {
            throw "Snapshot save failed: $($snapshotResult.Error)"
        }

        # Save entitlement snapshot if configured
        $appEntitlementPath = $app.EntitlementFilePath
        if (-not [string]::IsNullOrWhiteSpace($appEntitlementPath) -and
            (Test-Path -Path $appEntitlementPath -PathType Leaf)) {
            Save-SPDisconnectedAppSnapshot -FilePath $appEntitlementPath `
                -AppName $appName -FileType 'entitlements' -SnapshotDir $effectiveSnapshotDir | Out-Null
        }

        # --- Step C: Find previous snapshot ---
        $prevResult = Get-SPDisconnectedAppPreviousSnapshot -AppName $appName `
            -FileType 'accounts' -SnapshotDir $effectiveSnapshotDir

        if (-not $prevResult.Success) {
            throw "Failed to find previous snapshot: $($prevResult.Error)"
        }

        $previousFilePath = $prevResult.Data

        # --- Step D: Delta detection ---
        Write-Host '    c. Detecting changes...' -ForegroundColor DarkCyan

        $deltaResult = Compare-SPDisconnectedAppFiles -CurrentFilePath $appAccountPath `
            -PreviousFilePath $previousFilePath

        if (-not $deltaResult.Success) {
            throw "Delta detection failed: $($deltaResult.Error)"
        }

        $delta        = $deltaResult.Data
        $deltaSummary = $delta['Summary']

        $addedCount   = if ($null -ne $deltaSummary['Added']) { $deltaSummary['Added'] } else { 0 }
        $removedCount = if ($null -ne $deltaSummary['Removed']) { $deltaSummary['Removed'] } else { 0 }
        $enabledCount = if ($null -ne $deltaSummary['Enabled']) { $deltaSummary['Enabled'] } else { 0 }
        $grantedCount = if ($null -ne $deltaSummary['EntitlementsGranted']) { $deltaSummary['EntitlementsGranted'] } else { 0 }

        $appResult.DeltaSummary = @{
            Added   = $addedCount
            Removed = $removedCount
            Enabled = $enabledCount
            Granted = $grantedCount
        }

        # --- Step E: Deletion threshold check ---
        Write-Host '    d. Checking deletion threshold...' -ForegroundColor DarkCyan

        $thresholdResult = Test-SPDisconnectedAppDeletionThreshold -DeltaSummary $deltaSummary `
            -ThresholdPct $appThresholdPct

        if (-not $thresholdResult.Allowed) {
            $appResult.Status = 'ThresholdBlocked'
            $appResult.Reason = "Threshold exceeded: $($thresholdResult.RemovedPct)% accounts removed (threshold: $($thresholdResult.ThresholdPct)%)"
            $appResult.Error  = $appResult.Reason
            Write-Host "       BLOCKED: $($appResult.Reason)" -ForegroundColor Red

            Write-SPLog -Message "App '$appName' blocked by deletion threshold: $($thresholdResult.RemovedPct)% removed (threshold=$appThresholdPct%)" `
                -Severity ERROR -Component 'Invoke-SPDisconnectedAppBatch' -Action 'ThresholdCheck' `
                -CorrelationID $appCorrelationID

            # Still generate report for blocked apps
            $reportResult = Export-SPDisconnectedAppDeltaHtml -DeltaResult $delta `
                -AppName $appName -OutputPath $effectiveOutputPath
            if ($reportResult.Success) {
                $appResult.ReportPath = $reportResult.Data.FilePath
            }

            $appEndTime = Get-Date
            $appResult.CompletedAt     = $appEndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $appResult.DurationSeconds = [math]::Round(($appEndTime - $appStartTime).TotalSeconds, 2)
            $batchResults.Add($appResult)
            Write-Host ''
            continue
        }

        # --- Check for campaign triggers ---
        $campaignTriggers = $addedCount + $grantedCount + $enabledCount

        if ($campaignTriggers -eq 0) {
            $appResult.Status = 'NoChanges'
            $appResult.Reason = 'NoCampaignTriggers'
            Write-Host '       No campaign-triggering changes.' -ForegroundColor DarkGray

            # Generate report for audit
            $reportResult = Export-SPDisconnectedAppDeltaHtml -DeltaResult $delta `
                -AppName $appName -OutputPath $effectiveOutputPath
            if ($reportResult.Success) {
                $appResult.ReportPath = $reportResult.Data.FilePath
            }

            $appEndTime = Get-Date
            $appResult.CompletedAt     = $appEndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $appResult.DurationSeconds = [math]::Round(($appEndTime - $appStartTime).TotalSeconds, 2)
            $batchResults.Add($appResult)
            Write-Host ''
            continue
        }

        Write-Host "       $campaignTriggers campaign-triggering change(s)." -ForegroundColor Green

        # --- Step F: Identity resolution ---
        Write-Host '    e. Resolving identities...' -ForegroundColor DarkCyan

        $resolveResult = Resolve-SPDisconnectedAppIdentities -DeltaResult $delta `
            -CorrelationAttribute $appCorrelation -CorrelationID $appCorrelationID

        if (-not $resolveResult.Success) {
            throw "Identity resolution failed: $($resolveResult.Error)"
        }

        $resolved = $resolveResult.Data
        Write-Host "       Resolved: $($resolved.Summary.Resolved)  Unresolved: $($resolved.Summary.Unresolved)" -ForegroundColor DarkGray

        if ($resolved.Summary.Resolved -eq 0) {
            $appResult.Status = 'NoChanges'
            $appResult.Reason = 'NoResolvedIdentities'
            Write-Host '       No identities resolved. Skipping campaigns.' -ForegroundColor Yellow

            $reportResult = Export-SPDisconnectedAppDeltaHtml -DeltaResult $delta `
                -AppName $appName -OutputPath $effectiveOutputPath
            if ($reportResult.Success) {
                $appResult.ReportPath = $reportResult.Data.FilePath
            }

            $appEndTime = Get-Date
            $appResult.CompletedAt     = $appEndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $appResult.DurationSeconds = [math]::Round(($appEndTime - $appStartTime).TotalSeconds, 2)
            $batchResults.Add($appResult)
            Write-Host ''
            continue
        }

        # --- Step G: Campaign creation ---
        Write-Host '    f. Creating campaigns...' -ForegroundColor DarkCyan

        $certParams = @{
            AppName            = $appName
            DeltaResult        = $delta
            ResolvedIdentities = $resolved
            CampaignNamePrefix = $appPrefix
            DeadlineDays       = $appDeadline
            MaxCampaignsPerRun = $appMaxCampaigns
            OutputPath         = $effectiveOutputPath
            CorrelationID      = $appCorrelationID
        }
        if (-not [string]::IsNullOrWhiteSpace($effectiveFallback)) {
            $certParams['FallbackManagerId'] = $effectiveFallback
        }
        if ($Force) {
            $certParams['Force'] = $true
        }
        if ($WhatIfPreference -eq $true) {
            $certParams['WhatIf'] = $true
        }

        $certResult = Invoke-SPDisconnectedAppCertRun @certParams

        if (-not $certResult.Success) {
            throw "Campaign creation failed: $($certResult.Error)"
        }

        $certData = $certResult.Data

        $appResult.CampaignsCreated = $certData.CampaignsCreated
        $appResult.CampaignIds      = $certData.CampaignIds
        $appResult.IdentityCount    = $certData.IdentityCount
        $appResult.Reason           = $certData.Reason

        if ($certData.Reason -eq 'WhatIf') {
            $appResult.Status = 'Success'
        }
        elseif ($certData.Reason -eq 'DuplicatesExist') {
            $appResult.Status = 'NoChanges'
        }
        else {
            $appResult.Status = 'Success'
        }

        # --- Step H: HTML report ---
        Write-Host '    g. Generating report...' -ForegroundColor DarkCyan

        $reportResult = Export-SPDisconnectedAppDeltaHtml -DeltaResult $delta `
            -AppName $appName -OutputPath $effectiveOutputPath

        if ($reportResult.Success) {
            $appResult.ReportPath = $reportResult.Data.FilePath
            Write-Host "       $($reportResult.Data.FilePath)" -ForegroundColor DarkGray
        }

        # Mark success
        $statusColor = 'Green'
        $statusLabel = 'SUCCESS'
        if ($certData.Reason -eq 'WhatIf') {
            $statusLabel = 'WHATIF'
            $statusColor = 'Yellow'
        }
        elseif ($certData.Reason -eq 'DuplicatesExist') {
            $statusLabel = 'DUPLICATES'
            $statusColor = 'Yellow'
        }

        Write-Host "    [$statusLabel] $appName -- $($certData.CampaignsCreated) campaign(s), $($certData.IdentityCount) identit(ies)" -ForegroundColor $statusColor
    }
    catch {
        $appResult.Status = 'Error'
        $appResult.Error  = $_.Exception.Message
        $appResult.Reason = 'Error'

        Write-Host "    [ERROR] $appName -- $($_.Exception.Message)" -ForegroundColor Red

        Write-SPLog -Message "App '$appName' failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'Invoke-SPDisconnectedAppBatch' -Action 'ProcessApp' `
            -CorrelationID $appCorrelationID
    }

    $appEndTime = Get-Date
    $appResult.CompletedAt     = $appEndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $appResult.DurationSeconds = [math]::Round(($appEndTime - $appStartTime).TotalSeconds, 2)
    $batchResults.Add($appResult)
    Write-Host ''
}

#endregion

#region Batch Summary

$batchEndTime    = Get-Date
$batchDuration   = [math]::Round(($batchEndTime - $batchStartTime).TotalSeconds, 2)

$successCount    = @($batchResults | Where-Object { $_.Status -eq 'Success' }).Count
$noChangesCount  = @($batchResults | Where-Object { $_.Status -eq 'NoChanges' }).Count
$blockedCount    = @($batchResults | Where-Object { $_.Status -eq 'ThresholdBlocked' }).Count
$errorCount      = @($batchResults | Where-Object { $_.Status -eq 'Error' }).Count
$totalCampaigns  = ($batchResults | ForEach-Object { $_.CampaignsCreated } | Measure-Object -Sum).Sum
$totalIdentities = ($batchResults | ForEach-Object { $_.IdentityCount } | Measure-Object -Sum).Sum

# --- JSONL Batch Audit Trail ---
try {
    $batchAuditPath = Join-Path -Path $effectiveOutputPath -ChildPath 'batch-audit.jsonl'
    if (-not (Test-Path -Path (Split-Path $batchAuditPath -Parent) -PathType Container)) {
        New-Item -Path (Split-Path $batchAuditPath -Parent) -ItemType Directory -Force | Out-Null
    }

    $batchEvent = [ordered]@{
        Timestamp        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        CorrelationID    = $batchCorrelationID
        Action           = 'DisconnectedAppBatchRun'
        AppsProcessed    = $batchResults.Count
        Success          = $successCount
        NoChanges        = $noChangesCount
        ThresholdBlocked = $blockedCount
        Errors           = $errorCount
        TotalCampaigns   = $totalCampaigns
        TotalIdentities  = $totalIdentities
        DurationSeconds  = $batchDuration
        WhatIf           = ($WhatIfPreference -eq $true)
        AppResults       = @($batchResults | ForEach-Object {
            [ordered]@{
                App    = $_.App
                Status = $_.Status
                Reason = $_.Reason
                Error  = $_.Error
            }
        })
    }

    $jsonLine = $batchEvent | ConvertTo-Json -Depth 5 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($batchAuditPath, "$jsonLine`n", $utf8NoBom)

    Write-SPLog -Message "Batch audit event written to $batchAuditPath" `
        -Severity INFO -Component 'Invoke-SPDisconnectedAppBatch' -Action 'BatchAudit' `
        -CorrelationID $batchCorrelationID
}
catch {
    Write-SPLog -Message "Failed to write batch audit event: $($_.Exception.Message)" `
        -Severity WARN -Component 'Invoke-SPDisconnectedAppBatch' -Action 'BatchAudit' `
        -CorrelationID $batchCorrelationID
}

# --- Build summary object ---
$batchSummary = [PSCustomObject]@{
    CorrelationID    = $batchCorrelationID
    StartedAt        = $batchStartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt      = $batchEndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds  = $batchDuration
    AppsProcessed    = $batchResults.Count
    Success          = $successCount
    NoChanges        = $noChangesCount
    ThresholdBlocked = $blockedCount
    Errors           = $errorCount
    TotalCampaigns   = $totalCampaigns
    TotalIdentities  = $totalIdentities
    WhatIf           = ($WhatIfPreference -eq $true)
    AppResults       = @($batchResults | ForEach-Object {
        [PSCustomObject]@{
            App              = $_.App
            Status           = $_.Status
            Reason           = $_.Reason
            CampaignsCreated = $_.CampaignsCreated
            IdentityCount    = $_.IdentityCount
            DurationSeconds  = $_.DurationSeconds
            ReportPath       = $_.ReportPath
            Error            = $_.Error
        }
    })
    Environment      = $config.Global.EnvironmentName
}

# --- Console Output ---
switch ($OutputMode) {
    'JSON' {
        $batchSummary | ConvertTo-Json -Depth 10
    }
    default {
        Write-Host '  Batch Summary' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        Write-Host ''

        # Per-app status table
        foreach ($r in $batchResults) {
            $statusColor = switch ($r.Status) {
                'Success'           { 'Green' }
                'NoChanges'         { 'DarkGray' }
                'ThresholdBlocked'  { 'Yellow' }
                'Error'             { 'Red' }
                default             { 'Gray' }
            }

            $statusPad = $r.Status.PadRight(18)
            $campaignInfo = "campaigns=$($r.CampaignsCreated)"
            $line = "    $($r.App.PadRight(20)) $statusPad $campaignInfo"

            if ($r.Status -eq 'Error' -and $null -ne $r.Error) {
                $line += "  err=$($r.Error.Substring(0, [Math]::Min(60, $r.Error.Length)))"
            }

            Write-Host $line -ForegroundColor $statusColor
        }

        Write-Host ''
        Write-Host "  Total:             $($batchResults.Count) app(s)" -ForegroundColor DarkGray
        Write-Host "  Succeeded:         $successCount" -ForegroundColor Green
        Write-Host "  No Changes:        $noChangesCount" -ForegroundColor DarkGray
        Write-Host "  Threshold Blocked: $blockedCount" -ForegroundColor $(if ($blockedCount -gt 0) { 'Yellow' } else { 'DarkGray' })
        Write-Host "  Errors:            $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'DarkGray' })
        Write-Host "  Campaigns Created: $totalCampaigns" -ForegroundColor DarkGray
        Write-Host "  Identities:        $totalIdentities" -ForegroundColor DarkGray
        Write-Host "  Duration:          $batchDuration seconds" -ForegroundColor DarkGray
        Write-Host "  CorrelationID:     $batchCorrelationID" -ForegroundColor DarkGray
        Write-Host ''

        if ($OutputMode -eq 'Both') {
            Write-Host '  JSON Output:' -ForegroundColor Cyan
            $batchSummary | ConvertTo-Json -Depth 10
        }
    }
}

Write-SPLog -Message "Invoke-SPDisconnectedAppBatch completed: $($batchResults.Count) app(s), $successCount success, $errorCount error(s), $totalCampaigns campaign(s)" `
    -Severity INFO -Component 'Invoke-SPDisconnectedAppBatch' -Action 'Complete' -CorrelationID $batchCorrelationID

#endregion

#region Exit Code

# 0=all success, 1=partial, 2=all failed, 3=auth error (handled earlier)
$nonErrorCount = $successCount + $noChangesCount

if ($errorCount -eq 0 -and $blockedCount -eq 0) {
    exit 0
}
elseif ($nonErrorCount -gt 0) {
    exit 1
}
else {
    exit 2
}

#endregion

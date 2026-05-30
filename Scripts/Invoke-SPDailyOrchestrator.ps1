#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the full daily governance workflow as a single coordinated operation.
.DESCRIPTION
    Consolidates the daily governance workflow into one invocation with
    dependency-aware execution and a consolidated daily summary. Designed
    for scheduled task / cron execution with comprehensive error handling.

    Execution steps (in order):
      1. Configuration Validation  (Test-SPConfiguration)
      2. Campaign Cleanup          (Invoke-SPDeltaCertCleanup)
      3. Delta Cert Run            (Invoke-SPDeltaCertRun)
      4. Delta Report              (Get-SPDeltaReportData + Export-SPDeltaReportHtml)
      5. Escalation                (Invoke-SPDeltaCertEscalate)
      6. Health Check              (Get-SPCampaignHealth)
      7. Disconnected App Batch    (Invoke-SPDisconnectedAppBatch)
      8. Decision Collection       (Get-SPDisconnectedAppCampaignDecisions)
      9. Remediation Check         (Update-SPRemediationStatus)
     10. Daily Summary             (consolidated output + JSONL audit trail)

    Each step is isolated -- a failure in one step does not prevent subsequent
    steps from executing. The exit code reflects the worst outcome.

    SCOPE REQUIREMENT:
        Steps 2-5 require sp:scopes:all or a browser token.
        Use -Token with a JWT from the ISC admin console, or configure a PAT
        with sp:scopes:all in settings.json / the vault.

.PARAMETER SourceId
    One or more SailPoint ISC source IDs to monitor for AD group add operations.
    Obtain from: ISC Admin > Sources > select source > URL contains the source ID.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to this script.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials entirely.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER SkipValidation
    Skip Step 1: Configuration validation.
.PARAMETER SkipCleanup
    Skip Step 2: Campaign cleanup.
.PARAMETER SkipDeltaCert
    Skip Step 3: Delta cert campaign creation.
.PARAMETER SkipDeltaReport
    Skip Step 4: Delta report generation.
.PARAMETER SkipEscalation
    Skip Step 5: Escalation of stale certifications.
.PARAMETER SkipHealthCheck
    Skip Step 6: Campaign health check.
.PARAMETER SkipDisconnectedApps
    Skip Steps 7-9: Disconnected app batch, decision collection, and remediation check.
.PARAMETER HoursBack
    Override the look-back window in hours for delta cert run and report.
.PARAMETER DeadlineDays
    Override the deadline days for new delta cert campaigns.
.PARAMETER ReviewerMode
    Override the reviewer mode (Manager or SourceOwner).
.PARAMETER StaleHours
    Override the stale hours threshold for escalation.
.PARAMETER CampaignNamePrefix
    Override the campaign name prefix.
.PARAMETER OutputMode
    Console (default): formatted summary to terminal.
    JSON: machine-parseable result object.
    Both: console output followed by the JSON object.
.PARAMETER OutputPath
    Directory for output files. Defaults to DeltaCert output path from config.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -Token $token
    # Single daily command replacing 4 separate script invocations.
.EXAMPLE
    .\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -HoursBack 48 -StaleHours 12 -Token $token
    # With parameter overrides.
.EXAMPLE
    .\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -SkipEscalation -SkipHealthCheck -Token $token
    # Skip specific steps.
.EXAMPLE
    .\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -WhatIf
    # Dry run -- all sub-steps receive -WhatIf.
.NOTES
    Script:  Invoke-SPDailyOrchestrator.ps1
    Version: 1.0.0
    Exit codes:
        0 = All steps succeeded
        1 = One or more non-critical steps had warnings
        2 = Parameter error
        3 = Authentication error
        4 = Configuration validation failed
        5 = Critical step failed (delta cert creation or escalation error)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string[]]$SourceId,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    # Step toggles
    [Parameter()]
    [switch]$SkipValidation,

    [Parameter()]
    [switch]$SkipCleanup,

    [Parameter()]
    [switch]$SkipDeltaCert,

    [Parameter()]
    [switch]$SkipDeltaReport,

    [Parameter()]
    [switch]$SkipEscalation,

    [Parameter()]
    [switch]$SkipHealthCheck,

    [Parameter()]
    [switch]$SkipDisconnectedApps,

    # Overrides
    [Parameter()]
    [int]$HoursBack,

    [Parameter()]
    [int]$DeadlineDays,

    [Parameter()]
    [ValidateSet('Manager', 'SourceOwner')]
    [string]$ReviewerMode,

    [Parameter()]
    [int]$StaleHours,

    [Parameter()]
    [string]$CampaignNamePrefix,

    # Output
    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [Alias('?')]
    [switch]$Help,

    # Note: -WhatIf is provided automatically by SupportsShouldProcess
    # but we accept it explicitly so we can pass it through to sub-steps
    [Parameter()]
    [switch]$WhatIf
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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';           Name = 'SP.Core';       Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';             Name = 'SP.Api';         Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';         Name = 'SP.Audit';       Required = $false }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'; Name = 'SP.DeltaCert';   Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DisconnectedApps\SP.DisconnectedApps.psd1'; Name = 'SP.DisconnectedApps'; Required = $false }
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

$startTime = Get-Date
$correlationID = [guid]::NewGuid().ToString()
$todayLabel = $startTime.ToString('yyyy-MM-dd')

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Daily Governance Orchestrator' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
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

Write-SPLog -Message "Invoke-SPDailyOrchestrator started: CorrelationID=$correlationID" `
    -Severity INFO -Component 'DailyOrchestrator' -Action 'Start' -CorrelationID $correlationID

# Resolve effective parameter values from config defaults
$effectiveSourceIds = $SourceId
if (-not $effectiveSourceIds -or $effectiveSourceIds.Count -eq 0) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['SourceIds'] -and
        $config.DeltaCert.SourceIds.Count -gt 0) {
        $effectiveSourceIds = @($config.DeltaCert.SourceIds)
    }
}

$effectiveHoursBack = $HoursBack
if ($effectiveHoursBack -le 0) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['DefaultHoursBack'] -and
        [int]$config.DeltaCert.DefaultHoursBack -gt 0) {
        $effectiveHoursBack = [int]$config.DeltaCert.DefaultHoursBack
    }
    else {
        $effectiveHoursBack = 24
    }
}

$effectiveDeadlineDays = $DeadlineDays
if ($effectiveDeadlineDays -le 0) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['DefaultDeadlineDays'] -and
        [int]$config.DeltaCert.DefaultDeadlineDays -gt 0) {
        $effectiveDeadlineDays = [int]$config.DeltaCert.DefaultDeadlineDays
    }
    else {
        $effectiveDeadlineDays = 2
    }
}

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

$effectiveStaleHours = $StaleHours
if ($effectiveStaleHours -le 0) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['Escalation'] -and
        $null -ne $config.DeltaCert.Escalation -and
        $null -ne $config.DeltaCert.Escalation.PSObject.Properties['DefaultStaleHours'] -and
        [int]$config.DeltaCert.Escalation.DefaultStaleHours -gt 0) {
        $effectiveStaleHours = [int]$config.DeltaCert.Escalation.DefaultStaleHours
    }
    else {
        $effectiveStaleHours = 24
    }
}

$effectiveMaxEscalation = 2
if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
    $null -ne $config.DeltaCert -and
    $null -ne $config.DeltaCert.PSObject.Properties['Escalation'] -and
    $null -ne $config.DeltaCert.Escalation -and
    $null -ne $config.DeltaCert.Escalation.PSObject.Properties['MaxEscalationLevels'] -and
    [int]$config.DeltaCert.Escalation.MaxEscalationLevels -gt 0) {
    $effectiveMaxEscalation = [int]$config.DeltaCert.Escalation.MaxEscalationLevels
}

$effectiveFallback = ''
if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
    $null -ne $config.DeltaCert -and
    $null -ne $config.DeltaCert.PSObject.Properties['FallbackReviewerIdentityId']) {
    $effectiveFallback = [string]$config.DeltaCert.FallbackReviewerIdentityId
}

$effectiveMaxCampaigns = 50
if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
    $null -ne $config.DeltaCert -and
    $null -ne $config.DeltaCert.PSObject.Properties['MaxCampaignsPerRun'] -and
    [int]$config.DeltaCert.MaxCampaignsPerRun -gt 0) {
    $effectiveMaxCampaigns = [int]$config.DeltaCert.MaxCampaignsPerRun
}

# Resolve output path for delta report and audit trail
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
        $effectiveOutputPath = [string]$config.DeltaCert.OutputPath
    }
    else {
        $effectiveOutputPath = Join-Path $toolkitRoot 'DeltaCert'
    }
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) {
    $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath
}
if (-not (Test-Path $effectiveOutputPath)) {
    New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null
}

$effectiveCleanupDays = 3
if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
    $null -ne $config.DeltaCert -and
    $null -ne $config.DeltaCert.PSObject.Properties['CleanupDaysStale'] -and
    [int]$config.DeltaCert.CleanupDaysStale -gt 0) {
    $effectiveCleanupDays = [int]$config.DeltaCert.CleanupDaysStale
}

# WhatIf detection
$isWhatIf = ($WhatIfPreference -eq $true) -or $WhatIf

#endregion

#region Step Tracking

# Per-step result tracking
$stepResults = [ordered]@{
    Validation  = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    Cleanup     = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    DeltaCert   = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    DeltaReport = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    Escalation    = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    HealthCheck   = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    DABatch       = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    DADecisions   = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    DARemediation = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
}

# Track worst exit code
$worstExitCode = 0

function Set-StepResult {
    param(
        [string]$Step,
        [string]$Status,
        [string]$Detail,
        [double]$Duration
    )
    $stepResults[$Step] = @{ Status = $Status; Detail = $Detail; Duration = $Duration }
}

#endregion

#region Step 1: Configuration Validation

if (-not $SkipValidation) {
    Write-Host '  Step 1: Configuration Validation' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $validationResult = Test-SPConfiguration -ConfigPath $ConfigPath -CorrelationID $correlationID

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

        if (-not $validationResult.Valid) {
            $errorCount = $validationResult.Errors.Count
            $detail = "FAILED ($errorCount error(s))"
            foreach ($err in $validationResult.Errors) {
                Write-Host "    ERROR: $err" -ForegroundColor Red
            }
            Set-StepResult -Step 'Validation' -Status 'Failed' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 1: $detail" -ForegroundColor Red
            Write-SPLog -Message "Configuration validation failed: $($validationResult.Errors -join '; ')" `
                -Severity ERROR -Component 'DailyOrchestrator' -Action 'ValidationFailed' -CorrelationID $correlationID
            $worstExitCode = 4
            # Abort -- config errors are fatal
            Write-Host ''
            Write-Host '  Aborting: Configuration validation failed.' -ForegroundColor Red
            # Still write audit trail before exiting
            & {
                $endTime = Get-Date
                $totalDuration = ($endTime - $startTime).TotalSeconds
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                $auditEvent = [ordered]@{
                    Timestamp     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    Action        = 'DailyOrchestrator'
                    CorrelationID = $correlationID
                    Data          = [ordered]@{
                        Steps           = $stepResults
                        DurationSeconds = [math]::Round($totalDuration, 1)
                        ExitCode        = $worstExitCode
                        WhatIf          = $isWhatIf
                    }
                }
                $jsonLine = $auditEvent | ConvertTo-Json -Depth 10 -Compress
                $auditFile = Join-Path $effectiveOutputPath 'orchestrator-audit.jsonl'
                [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
            }
            exit $worstExitCode
        }

        $warnCount = $validationResult.Warnings.Count
        if ($warnCount -gt 0) {
            foreach ($warn in $validationResult.Warnings) {
                Write-Host "    WARN: $warn" -ForegroundColor Yellow
            }
            Set-StepResult -Step 'Validation' -Status 'Warning' -Detail "VALID ($warnCount warning(s))" -Duration $stepDuration
            Write-Host "  Step 1: VALID ($warnCount warning(s))" -ForegroundColor Yellow
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
        else {
            Set-StepResult -Step 'Validation' -Status 'Success' -Detail 'VALID' -Duration $stepDuration
            Write-Host '  Step 1: VALID' -ForegroundColor Green
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'Validation' -Status 'Error' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 1: ERROR - $($_.Exception.Message)" -ForegroundColor Red
        Write-SPLog -Message "Configuration validation exception: $($_.Exception.Message)" `
            -Severity ERROR -Component 'DailyOrchestrator' -Action 'ValidationError' -CorrelationID $correlationID
        $worstExitCode = 4
        # Abort on validation error
        & {
            $endTime = Get-Date
            $totalDuration = ($endTime - $startTime).TotalSeconds
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $auditEvent = [ordered]@{
                Timestamp     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                Action        = 'DailyOrchestrator'
                CorrelationID = $correlationID
                Data          = [ordered]@{
                    Steps           = $stepResults
                    DurationSeconds = [math]::Round($totalDuration, 1)
                    ExitCode        = $worstExitCode
                    WhatIf          = $isWhatIf
                }
            }
            $jsonLine = $auditEvent | ConvertTo-Json -Depth 10 -Compress
            $auditFile = Join-Path $effectiveOutputPath 'orchestrator-audit.jsonl'
            [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
        }
        exit $worstExitCode
    }
    Write-Host ''
}
else {
    Write-Host '  Step 1: Configuration Validation [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region WhatIf short-circuit notice

if ($isWhatIf) {
    Write-Host '  [WhatIf] Dry-run mode enabled -- write operations will be simulated.' -ForegroundColor Yellow
    Write-Host ''
}

#endregion

#region Step 2: Campaign Cleanup

if (-not $SkipCleanup) {
    Write-Host '  Step 2: Campaign Cleanup' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $cleanupParams = @{
            CampaignNamePrefix = $effectivePrefix
            DaysStale          = $effectiveCleanupDays
            CorrelationID      = $correlationID
        }
        if ($isWhatIf) { $cleanupParams['WhatIf'] = $true }

        $cleanupResult = Invoke-SPDeltaCertCleanup @cleanupParams
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

        if ($cleanupResult.Success) {
            $completed = 0
            if ($null -ne $cleanupResult.Data -and $null -ne $cleanupResult.Data.Completed) {
                $completed = @($cleanupResult.Data.Completed).Count
            }
            $detail = "Completed $completed stale campaign(s)"
            Set-StepResult -Step 'Cleanup' -Status 'Success' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 2: $detail" -ForegroundColor Green
        }
        else {
            $detail = "WARN - $($cleanupResult.Error)"
            Set-StepResult -Step 'Cleanup' -Status 'Warning' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 2: $detail" -ForegroundColor Yellow
            Write-SPLog -Message "Cleanup warning: $($cleanupResult.Error)" `
                -Severity WARN -Component 'DailyOrchestrator' -Action 'CleanupWarn' -CorrelationID $correlationID
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'Cleanup' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 2: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Cleanup exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DailyOrchestrator' -Action 'CleanupError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Step 2: Campaign Cleanup [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 3: Delta Cert Run

if (-not $SkipDeltaCert) {
    Write-Host '  Step 3: Delta Cert Run' -ForegroundColor Cyan
    $stepStart = Get-Date

    if (-not $effectiveSourceIds -or $effectiveSourceIds.Count -eq 0) {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'DeltaCert' -Status 'Warning' -Detail 'No SourceIds configured or provided' -Duration $stepDuration
        Write-Host '  Step 3: WARN - No SourceIds configured or provided' -ForegroundColor Yellow
        Write-SPLog -Message 'Delta cert skipped: no SourceIds' `
            -Severity WARN -Component 'DailyOrchestrator' -Action 'DeltaCertSkip' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    else {
        try {
            $deltaCertParams = @{
                SourceIds          = $effectiveSourceIds
                HoursBack          = $effectiveHoursBack
                DeadlineDays       = $effectiveDeadlineDays
                CampaignNamePrefix = $effectivePrefix
                ReviewerMode       = $effectiveReviewerMode
                MaxCampaignsPerRun = $effectiveMaxCampaigns
                CorrelationID      = $correlationID
            }
            if (-not [string]::IsNullOrWhiteSpace($effectiveFallback)) {
                $deltaCertParams['FallbackManagerId'] = $effectiveFallback
            }
            if ($isWhatIf) { $deltaCertParams['WhatIf'] = $true }

            $deltaCertResult = Invoke-SPDeltaCertRun @deltaCertParams
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

            if ($deltaCertResult.Success) {
                $reason = ''
                $campaignsCreated = 0
                $identityCount = 0
                if ($null -ne $deltaCertResult.Data) {
                    $reason = $deltaCertResult.Data.Reason
                    $campaignsCreated = $deltaCertResult.Data.CampaignsCreated
                    $identityCount = $deltaCertResult.Data.IdentityCount
                }

                switch ($reason) {
                    'NoChanges' {
                        $detail = 'No new AD access grants found'
                        Set-StepResult -Step 'DeltaCert' -Status 'Success' -Detail $detail -Duration $stepDuration
                        Write-Host "  Step 3: $detail" -ForegroundColor Green
                    }
                    'WhatIf' {
                        $detail = "[WhatIf] Would create $campaignsCreated campaign(s) for $identityCount identities"
                        Set-StepResult -Step 'DeltaCert' -Status 'Success' -Detail $detail -Duration $stepDuration
                        Write-Host "  Step 3: $detail" -ForegroundColor Yellow
                    }
                    default {
                        $detail = "Created $campaignsCreated campaign(s) for $identityCount identities"
                        Set-StepResult -Step 'DeltaCert' -Status 'Success' -Detail $detail -Duration $stepDuration
                        Write-Host "  Step 3: $detail" -ForegroundColor Green
                    }
                }
            }
            else {
                $detail = "ERROR - $($deltaCertResult.Error)"
                Set-StepResult -Step 'DeltaCert' -Status 'Failed' -Detail $detail -Duration $stepDuration
                Write-Host "  Step 3: $detail" -ForegroundColor Red
                Write-SPLog -Message "Delta cert failed: $($deltaCertResult.Error)" `
                    -Severity ERROR -Component 'DailyOrchestrator' -Action 'DeltaCertFailed' -CorrelationID $correlationID
                if ($worstExitCode -lt 5) { $worstExitCode = 5 }
            }
        }
        catch {
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'DeltaCert' -Status 'Failed' -Detail $_.Exception.Message -Duration $stepDuration
            Write-Host "  Step 3: ERROR - $($_.Exception.Message)" -ForegroundColor Red
            Write-SPLog -Message "Delta cert exception: $($_.Exception.Message)" `
                -Severity ERROR -Component 'DailyOrchestrator' -Action 'DeltaCertError' -CorrelationID $correlationID
            if ($worstExitCode -lt 5) { $worstExitCode = 5 }
        }
    }
    Write-Host ''
}
else {
    Write-Host '  Step 3: Delta Cert Run [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 4: Delta Report

if (-not $SkipDeltaReport) {
    Write-Host '  Step 4: Delta Report' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $reportDataParams = @{
            HoursBack          = $effectiveHoursBack
            CampaignNamePrefix = $effectivePrefix
            CorrelationID      = $correlationID
        }
        if ($effectiveSourceIds -and $effectiveSourceIds.Count -gt 0) {
            $reportDataParams['SourceIds'] = $effectiveSourceIds
        }

        $reportData = Get-SPDeltaReportData @reportDataParams

        if ($reportData.Success) {
            $newGrants   = 0
            $revocations = 0
            $reportPath  = ''

            if ($null -ne $reportData.Data) {
                if ($null -ne $reportData.Data.NewGrants)   { $newGrants   = @($reportData.Data.NewGrants).Count }
                if ($null -ne $reportData.Data.Revocations) { $revocations = @($reportData.Data.Revocations).Count }
            }

            # Generate HTML report
            $reportOutputDir = Join-Path $effectiveOutputPath 'reports'
            if (-not (Test-Path $reportOutputDir)) {
                New-Item -ItemType Directory -Path $reportOutputDir -Force | Out-Null
            }

            $exportResult = Export-SPDeltaReportHtml -ReportData $reportData.Data `
                -OutputPath $reportOutputDir -CorrelationID $correlationID

            if ($null -ne $exportResult -and $null -ne $exportResult.HtmlPath) {
                $reportPath = $exportResult.HtmlPath
            }

            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            $detail = "$newGrants new grant(s), $revocations revocation(s)"
            if (-not [string]::IsNullOrWhiteSpace($reportPath)) {
                $detail += " (report: $reportPath)"
            }
            Set-StepResult -Step 'DeltaReport' -Status 'Success' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 4: $detail" -ForegroundColor Green
        }
        else {
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            $detail = "WARN - $($reportData.Error)"
            Set-StepResult -Step 'DeltaReport' -Status 'Warning' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 4: $detail" -ForegroundColor Yellow
            Write-SPLog -Message "Delta report warning: $($reportData.Error)" `
                -Severity WARN -Component 'DailyOrchestrator' -Action 'DeltaReportWarn' -CorrelationID $correlationID
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'DeltaReport' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 4: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Delta report exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DailyOrchestrator' -Action 'DeltaReportError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Step 4: Delta Report [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 5: Escalation

if (-not $SkipEscalation) {
    Write-Host '  Step 5: Escalation' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        # Find stale certifications first
        $staleCerts = Get-SPDeltaCertStaleCertifications `
            -CampaignNamePrefix $effectivePrefix `
            -StaleHours $effectiveStaleHours `
            -CorrelationID $correlationID

        if ($null -ne $staleCerts -and $staleCerts.Success -and
            $null -ne $staleCerts.Data -and @($staleCerts.Data).Count -gt 0) {

            $escalateParams = @{
                StaleCertifications  = @($staleCerts.Data)
                MaxEscalationLevels  = $effectiveMaxEscalation
                CorrelationID        = $correlationID
            }
            if ($isWhatIf) { $escalateParams['WhatIf'] = $true }

            $escalateResult = Invoke-SPDeltaCertEscalate @escalateParams
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

            if ($escalateResult.Success) {
                $escalated = 0
                $skipped   = 0
                if ($null -ne $escalateResult.Data) {
                    if ($null -ne $escalateResult.Data.Escalated) { $escalated = @($escalateResult.Data.Escalated).Count }
                    if ($null -ne $escalateResult.Data.Skipped)   { $skipped   = @($escalateResult.Data.Skipped).Count }
                }
                $detail = "Escalated $escalated certification(s), skipped $skipped"
                Set-StepResult -Step 'Escalation' -Status 'Success' -Detail $detail -Duration $stepDuration
                Write-Host "  Step 5: $detail" -ForegroundColor Green
            }
            else {
                $detail = "WARN - $($escalateResult.Error)"
                Set-StepResult -Step 'Escalation' -Status 'Warning' -Detail $detail -Duration $stepDuration
                Write-Host "  Step 5: $detail" -ForegroundColor Yellow
                Write-SPLog -Message "Escalation warning: $($escalateResult.Error)" `
                    -Severity WARN -Component 'DailyOrchestrator' -Action 'EscalationWarn' -CorrelationID $correlationID
                if ($worstExitCode -lt 1) { $worstExitCode = 1 }
            }
        }
        else {
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'Escalation' -Status 'Success' -Detail 'No stale certifications found' -Duration $stepDuration
            Write-Host '  Step 5: No stale certifications found' -ForegroundColor Green
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'Escalation' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 5: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Escalation exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DailyOrchestrator' -Action 'EscalationError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Step 5: Escalation [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 6: Health Check

if (-not $SkipHealthCheck) {
    Write-Host '  Step 6: Health Check' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $healthParams = @{
            CorrelationID = $correlationID
        }
        if ($effectiveStaleHours -gt 0) {
            $healthParams['StaleReviewerHours'] = $effectiveStaleHours
        }

        $healthResult = Get-SPCampaignHealth @healthParams
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

        if ($healthResult.Success) {
            $red    = 0
            $yellow = 0
            $green  = 0
            $total  = 0
            if ($null -ne $healthResult.Data -and $null -ne $healthResult.Data.Summary) {
                $red    = $healthResult.Data.Summary.Red
                $yellow = $healthResult.Data.Summary.Yellow
                $green  = $healthResult.Data.Summary.Green
                $total  = $healthResult.Data.Summary.Total
            }

            $detail = "$total active campaign(s) ($green Green, $yellow Yellow, $red Red)"

            if ($red -gt 0) {
                Set-StepResult -Step 'HealthCheck' -Status 'Warning' -Detail $detail -Duration $stepDuration
                Write-Host "  Step 6: $detail" -ForegroundColor Yellow

                # Log red campaign names
                if ($null -ne $healthResult.Data -and $null -ne $healthResult.Data.Campaigns) {
                    foreach ($camp in $healthResult.Data.Campaigns) {
                        if ($camp.OverallHealth -eq 'Red') {
                            Write-Host "    RED: $($camp.CampaignName) - $($camp.DeadlineStatus)" -ForegroundColor Red
                        }
                    }
                }

                Write-SPLog -Message "Health check: $red Red campaign(s) found" `
                    -Severity WARN -Component 'DailyOrchestrator' -Action 'HealthCheckWarn' -CorrelationID $correlationID
                if ($worstExitCode -lt 1) { $worstExitCode = 1 }
            }
            else {
                Set-StepResult -Step 'HealthCheck' -Status 'Success' -Detail $detail -Duration $stepDuration
                Write-Host "  Step 6: $detail" -ForegroundColor Green
            }
        }
        else {
            $detail = "WARN - $($healthResult.Error)"
            Set-StepResult -Step 'HealthCheck' -Status 'Warning' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 6: $detail" -ForegroundColor Yellow
            Write-SPLog -Message "Health check warning: $($healthResult.Error)" `
                -Severity WARN -Component 'DailyOrchestrator' -Action 'HealthCheckWarn' -CorrelationID $correlationID
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'HealthCheck' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 6: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Health check exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DailyOrchestrator' -Action 'HealthCheckError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Step 6: Health Check [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Disconnected App Shared State (Steps 7-9)

$daRegisteredApps = @()
$daReportPath = ''
if (-not $SkipDisconnectedApps) {
    if ($null -ne $config.PSObject.Properties['DisconnectedApps'] -and $null -ne $config.DisconnectedApps) {
        if ($null -ne $config.DisconnectedApps.PSObject.Properties['ReportPath'] -and
            -not [string]::IsNullOrWhiteSpace($config.DisconnectedApps.ReportPath)) {
            $daReportPath = [string]$config.DisconnectedApps.ReportPath
        }
    }
    if ([string]::IsNullOrWhiteSpace($daReportPath)) {
        $daReportPath = Join-Path $toolkitRoot 'DisconnectedApps\Reports'
    }
    if (-not [System.IO.Path]::IsPathRooted($daReportPath)) {
        $daReportPath = Join-Path $toolkitRoot $daReportPath
    }
}

#endregion

#region Step 7: Disconnected App Batch

if (-not $SkipDisconnectedApps) {
    Write-Host '  Step 7: Disconnected App Batch' -ForegroundColor Cyan
    $stepStart = Get-Date

    $daModuleLoaded = $null -ne (Get-Module -Name 'SP.DisconnectedApps' -ErrorAction SilentlyContinue)

    if (-not $daModuleLoaded) {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'DABatch' -Status 'Skipped' -Detail 'SP.DisconnectedApps module not available' -Duration $stepDuration
        Write-Host '  Step 7: SP.DisconnectedApps module not available [SKIPPED]' -ForegroundColor DarkGray
    }
    else {
        try {
            $regParams = @{}
            if ($ConfigPath) { $regParams['ConfigPath'] = $ConfigPath }
            $regResult = Get-SPRegisteredApps @regParams

            if (-not $regResult.Success -or @($regResult.Data).Count -eq 0) {
                $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
                Set-StepResult -Step 'DABatch' -Status 'Success' -Detail 'No registered disconnected apps' -Duration $stepDuration
                Write-Host '  Step 7: No registered disconnected apps' -ForegroundColor Green
            }
            else {
                $daRegisteredApps = @($regResult.Data)
                Write-Host "    $($daRegisteredApps.Count) app(s) registered." -ForegroundColor DarkGray

                $batchScriptPath = Join-Path $scriptRoot 'Invoke-SPDisconnectedAppBatch.ps1'
                $batchParams = @{
                    ConfigPath = $ConfigPath
                    OutputMode = 'JSON'
                }
                if ($Token) {
                    $batchParams['Token'] = $Token
                    $batchParams['TokenExpiryMinutes'] = $TokenExpiryMinutes
                }
                if ($isWhatIf) {
                    $batchParams['WhatIf'] = $true
                }

                $batchJsonOutput = & $batchScriptPath @batchParams
                $batchExitCode = $LASTEXITCODE
                $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

                # Parse batch JSON output
                $batchData = $null
                if ($batchJsonOutput) {
                    try {
                        $jsonStr = ($batchJsonOutput | Out-String).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($jsonStr)) {
                            $batchData = $jsonStr | ConvertFrom-Json
                        }
                    }
                    catch {
                        Write-SPLog -Message "Failed to parse batch JSON output: $($_.Exception.Message)" `
                            -Severity WARN -Component 'DailyOrchestrator' -Action 'DABatchParse' -CorrelationID $correlationID
                    }
                }

                if ($batchExitCode -eq 0) {
                    $daBatchApps = if ($batchData) { $batchData.AppsProcessed } else { $daRegisteredApps.Count }
                    $daBatchCampaigns = if ($batchData) { $batchData.TotalCampaigns } else { 0 }
                    $detail = "$daBatchApps app(s) processed, $daBatchCampaigns campaign(s) created"
                    Set-StepResult -Step 'DABatch' -Status 'Success' -Detail $detail -Duration $stepDuration
                    Write-Host "  Step 7: $detail" -ForegroundColor Green
                }
                elseif ($batchExitCode -eq 1) {
                    $daBatchErrs = if ($batchData) { $batchData.Errors } else { 0 }
                    $daBatchBlocked = if ($batchData) { $batchData.ThresholdBlocked } else { 0 }
                    $detail = "Partial: $daBatchErrs error(s), $daBatchBlocked blocked"
                    Set-StepResult -Step 'DABatch' -Status 'Warning' -Detail $detail -Duration $stepDuration
                    Write-Host "  Step 7: WARN - $detail" -ForegroundColor Yellow
                    Write-SPLog -Message "DA batch partial: $detail" `
                        -Severity WARN -Component 'DailyOrchestrator' -Action 'DABatchWarn' -CorrelationID $correlationID
                    if ($worstExitCode -lt 1) { $worstExitCode = 1 }
                }
                else {
                    $detail = "Batch failed (exit code $batchExitCode)"
                    Set-StepResult -Step 'DABatch' -Status 'Failed' -Detail $detail -Duration $stepDuration
                    Write-Host "  Step 7: ERROR - $detail" -ForegroundColor Red
                    Write-SPLog -Message "DA batch failed: exit code $batchExitCode" `
                        -Severity ERROR -Component 'DailyOrchestrator' -Action 'DABatchFailed' -CorrelationID $correlationID
                    if ($worstExitCode -lt 5) { $worstExitCode = 5 }
                }
            }
        }
        catch {
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'DABatch' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
            Write-Host "  Step 7: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SPLog -Message "DA batch exception: $($_.Exception.Message)" `
                -Severity WARN -Component 'DailyOrchestrator' -Action 'DABatchError' -CorrelationID $correlationID
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
    }
    Write-Host ''
}
else {
    Write-Host '  Step 7: Disconnected App Batch [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 8: Decision Collection

if (-not $SkipDisconnectedApps -and $daRegisteredApps.Count -gt 0) {
    Write-Host '  Step 8: Decision Collection' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $totalChecked    = 0
        $totalCompleted  = 0
        $totalRevoked    = 0
        $decisionErrors  = 0

        foreach ($daApp in $daRegisteredApps) {
            try {
                $decResult = Get-SPDisconnectedAppCampaignDecisions `
                    -AppName $daApp.Name `
                    -OutputPath $daReportPath `
                    -CorrelationID $correlationID

                if ($decResult.Success -and $null -ne $decResult.Data) {
                    $totalChecked   += $decResult.Data.CampaignsChecked
                    $totalCompleted += $decResult.Data.Completed
                    if ($null -ne $decResult.Data.Decisions) {
                        $totalRevoked += $decResult.Data.Decisions.Revoked
                    }
                }
            }
            catch {
                $decisionErrors++
                Write-SPLog -Message "Decision collection failed for '$($daApp.Name)': $($_.Exception.Message)" `
                    -Severity WARN -Component 'DailyOrchestrator' -Action 'DecisionCollection' -CorrelationID $correlationID
            }
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        $detail = "$totalChecked campaign(s) checked, $totalCompleted completed, $totalRevoked revocation(s)"
        if ($decisionErrors -gt 0) {
            $detail += " ($decisionErrors error(s))"
            Set-StepResult -Step 'DADecisions' -Status 'Warning' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 8: WARN - $detail" -ForegroundColor Yellow
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
        else {
            Set-StepResult -Step 'DADecisions' -Status 'Success' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 8: $detail" -ForegroundColor Green
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'DADecisions' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 8: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Decision collection exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DailyOrchestrator' -Action 'DecisionCollectionError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
elseif (-not $SkipDisconnectedApps) {
    Write-Host '  Step 8: Decision Collection [SKIPPED - no registered apps]' -ForegroundColor DarkGray
    Write-Host ''
}
else {
    Write-Host '  Step 8: Decision Collection [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 9: Remediation Check

if (-not $SkipDisconnectedApps -and $daRegisteredApps.Count -gt 0) {
    Write-Host '  Step 9: Remediation Check' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $totalConfirmed = 0
        $totalOverdue   = 0
        $totalPending   = 0
        $remErrors      = 0

        foreach ($daApp in $daRegisteredApps) {
            try {
                # Skip if no account file path or file missing
                if ([string]::IsNullOrWhiteSpace($daApp.AccountFilePath) -or
                    -not (Test-Path -Path $daApp.AccountFilePath -PathType Leaf)) {
                    continue
                }

                $remResult = Update-SPRemediationStatus `
                    -AppName $daApp.Name `
                    -AccountFilePath $daApp.AccountFilePath `
                    -OutputPath $daReportPath `
                    -CorrelationID $correlationID

                if ($remResult.Success -and $null -ne $remResult.Data) {
                    $totalConfirmed += $remResult.Data.Confirmed
                    $totalOverdue   += $remResult.Data.Overdue
                    $totalPending   += $remResult.Data.Pending
                }
            }
            catch {
                $remErrors++
                Write-SPLog -Message "Remediation check failed for '$($daApp.Name)': $($_.Exception.Message)" `
                    -Severity WARN -Component 'DailyOrchestrator' -Action 'RemediationCheck' -CorrelationID $correlationID
            }
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        $detail = "$totalConfirmed confirmed, $totalOverdue overdue, $totalPending pending"

        if ($totalOverdue -gt 0 -or $remErrors -gt 0) {
            if ($remErrors -gt 0) { $detail += " ($remErrors error(s))" }
            Set-StepResult -Step 'DARemediation' -Status 'Warning' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 9: WARN - $detail" -ForegroundColor Yellow
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
        else {
            Set-StepResult -Step 'DARemediation' -Status 'Success' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 9: $detail" -ForegroundColor Green
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'DARemediation' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 9: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Remediation check exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DailyOrchestrator' -Action 'RemediationCheckError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
elseif (-not $SkipDisconnectedApps) {
    Write-Host '  Step 9: Remediation Check [SKIPPED - no registered apps]' -ForegroundColor DarkGray
    Write-Host ''
}
else {
    Write-Host '  Step 9: Remediation Check [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 10: Daily Summary

$endTime = Get-Date
$totalDuration = ($endTime - $startTime)
$durationStr = '{0}m {1:00}s' -f [int][math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

# Determine overall result label
$overallResult = 'SUCCESS'
if ($worstExitCode -eq 1) { $overallResult = 'SUCCESS (with warnings)' }
if ($worstExitCode -ge 2) { $overallResult = 'FAILED' }
if ($isWhatIf)            { $overallResult = 'WHATIF' }

# Console summary
if ($OutputMode -eq 'Console' -or $OutputMode -eq 'Both') {
    Write-Host '  === Daily Governance Orchestrator Summary ===' -ForegroundColor Cyan
    Write-Host "  Date:       $todayLabel"
    Write-Host "  Duration:   $durationStr"

    foreach ($stepName in $stepResults.Keys) {
        $step = $stepResults[$stepName]
        $statusColor = switch ($step.Status) {
            'Success'  { 'Green' }
            'Warning'  { 'Yellow' }
            'Failed'   { 'Red' }
            'Error'    { 'Red' }
            'Skipped'  { 'DarkGray' }
            default    { 'White' }
        }
        $label = ('{0,-15}' -f "${stepName}:")
        Write-Host "  $label $($step.Detail)" -ForegroundColor $statusColor
    }

    Write-Host "  Result:     $overallResult" -ForegroundColor $(
        if ($worstExitCode -eq 0) { 'Green' }
        elseif ($worstExitCode -eq 1) { 'Yellow' }
        else { 'Red' }
    )
    Write-Host ''
}

# JSON output
$summaryObject = [ordered]@{
    Date            = $todayLabel
    CorrelationID   = $correlationID
    DurationSeconds = [math]::Round($totalDuration.TotalSeconds, 1)
    Duration        = $durationStr
    WhatIf          = $isWhatIf
    Steps           = $stepResults
    Result          = $overallResult
    ExitCode        = $worstExitCode
}

if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
    $summaryObject | ConvertTo-Json -Depth 5
}

# JSONL audit trail event
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $auditEvent = [ordered]@{
        Timestamp     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Action        = 'DailyOrchestrator'
        CorrelationID = $correlationID
        Data          = [ordered]@{
            Steps           = $stepResults
            DurationSeconds = [math]::Round($totalDuration.TotalSeconds, 1)
            ExitCode        = $worstExitCode
            WhatIf          = $isWhatIf
        }
    }
    $jsonLine = $auditEvent | ConvertTo-Json -Depth 10 -Compress
    $auditFile = Join-Path $effectiveOutputPath 'orchestrator-audit.jsonl'
    [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
}
catch {
    Write-Host "  WARN: Failed to write audit trail: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Audit trail write failed: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyOrchestrator' -Action 'AuditTrailError' -CorrelationID $correlationID
}

Write-SPLog -Message "Invoke-SPDailyOrchestrator completed: ExitCode=$worstExitCode Duration=$durationStr" `
    -Severity INFO -Component 'DailyOrchestrator' -Action 'Complete' -CorrelationID $correlationID

#endregion

exit $worstExitCode

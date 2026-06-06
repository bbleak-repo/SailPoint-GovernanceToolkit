#Requires -Version 5.1
<#
.SYNOPSIS
    Drives a 30-day MANAGER certification simulation against the mock SailPoint
    ISC API by exercising the toolkit's EXISTING CLI/functions headlessly and
    capturing all outputs for downstream validation. ADDITIVE -- it orchestrates
    the existing scripts/functions and changes nothing.
.DESCRIPTION
    This simulation driver assumes a coherent 30-day dataset is already loaded
    into the non-elevated mock (one dated MANAGER campaign per day re-attesting
    the SAME fixed set of ~10 tracked PRIVILEGED roles, plus a membership
    changelog). It then:

      Step A -- Campaign WRITE round-trip (mutating; gated by ShouldProcess):
        Submits ~10 MANAGER certification campaigns (one per tracked privileged
        role, certifier = the responsible manager) via the existing module
        functions New-SPCampaign + Start-SPCampaign (+ Complete-SPCampaign for a
        subset when Safety.AllowCompleteCampaign), then CONFIRMS the round-trip
        with Get-SPCampaign and Search-SPCampaigns.

      Step B -- Daily cadence pass (days 1..N, default 7):
        For each simulated day runs the existing campaign audit
        (Invoke-SPCampaignAudit.ps1 -IncludeLeadershipRollup), the adaptive
        privileged-role report (Invoke-SPAdaptiveReport.ps1 -BaselineReport
        privileged), and the SMTP-WhatIf leadership-distribution preview
        (Invoke-SPAdaptiveReport.ps1 -DistributeToLeadership WITHOUT -SendReports
        => 'WOULD send' / Action='Logged', NO real email).

      Step C -- Windowed runs: a 7-day and a 30-day audit + adaptive pass so the
        wider window surfaces privileged-role membership churn and manager
        accountability across all the daily campaigns.

      Step D -- Capture artifacts: writes a top-level sim-summary.json and a
        per-step sim-audit.jsonl into the run output directory so the validation
        step (T-05) can collect every generated report path + exit code.

    Read-only against ISC except the gated Step A write round-trip; all report
    output and audit trails are written locally. NO real email is ever sent.

.PARAMETER ConfigPath
    Path to settings.json (defaults to ..\Config\settings.json, honoring
    settings.local.json). Use Config\settings.local.json to target the mock.
.PARAMETER Token
    Pre-obtained JWT bearer token (bypasses OAuth client_credentials).
.PARAMETER TokenExpiryMinutes
    Minutes until a browser token is treated as expired. Default 10.
.PARAMETER CadenceDays
    Number of simulated days for the Step B daily cadence loop. Default 7.
.PARAMETER SkipWrite
    Skip Step A (the New/Start/Complete campaign write round-trip).
.PARAMETER SkipReports
    Skip Steps B and C (the audit/adaptive cadence + windowed report passes).
.PARAMETER SendReports
    Passthrough to the SMTP-WhatIf gating. OFF by default so Send-SPReport logs
    ('WOULD send' / Action='Logged') instead of sending. Only set this if SMTP is
    actually configured and you intend to send.
.PARAMETER IncludeSdkPath
    Additionally exercise the SP.Sdk path (T-07): query the mock's
    /campaign-templates, /campaign-templates/{id}/schedule, /work-items and
    /work-items/summary via Get-SPSdkCampaignTemplates / Get-SPSdkTemplateSchedule
    / Get-SPSdkWorkItemsSummary / Get-SPSdkWorkItems, and write sdk-path.json into
    the capture dir. OFF by default so existing behaviour is unchanged. Treated as
    a WARN (not fatal) if the SDK collections are empty. Skipped under -WhatIf.
.PARAMETER OutputPath
    Run output directory (the T-05 capture dir). Defaults to
    Audit\sim-30day-<yyyyMMdd-HHmmss> under the toolkit root.
.PARAMETER DetailLevel
    Passthrough detail level for the adaptive leadership preview. Default Verbose.
.PARAMETER OutputMode
    Run-summary format: Console (default), JSON, or Both. The sim-summary.json
    file is always written regardless.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SP30DayManagerCertSim.ps1 -ConfigPath Config\settings.local.json -OutputMode Both
    # Full headless end-to-end run against the running non-elevated mock.
.EXAMPLE
    .\Invoke-SP30DayManagerCertSim.ps1 -ConfigPath Config\settings.local.json -WhatIf
    # Dry run -- the write round-trip is simulated; reports still run read-only.
.EXAMPLE
    .\Invoke-SP30DayManagerCertSim.ps1 -SkipWrite -CadenceDays 3
    # Skip the write round-trip; run only a 3-day cadence + windowed reports.
.NOTES
    Script:  Invoke-SP30DayManagerCertSim.ps1
    Version: 1.0.0
    Exit codes:
        0 = Simulation completed successfully
        1 = One or more non-critical steps had warnings
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Critical step failed (e.g. write round-trip failed)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [int]$CadenceDays = 7,

    [Parameter()]
    [switch]$SkipWrite,

    [Parameter()]
    [switch]$SkipReports,

    [Parameter()]
    [switch]$SendReports,

    [Parameter()]
    [switch]$IncludeSdkPath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateSet('Summary', 'Detailed', 'Verbose')]
    [string]$DetailLevel = 'Verbose',

    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [Alias('?')]
    [switch]$Help
)
# -WhatIf is provided automatically by [CmdletBinding(SupportsShouldProcess)];
# it sets $WhatIfPreference in this scope (read below). No explicit -WhatIf
# switch is declared (that would collide with SupportsShouldProcess).

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

# Same module chain Invoke-SPCampaignAudit.ps1 + Invoke-SPAdaptiveReport.ps1 need.
$moduleChain = @(
    'SP.Core\SP.Core.psd1'
    'SP.Api\SP.Api.psd1'
    'SP.Sdk\SP.Sdk.psd1'
    'SP.Audit\SP.Audit.psd1'
    'SP.DeltaCert\SP.DeltaCert.psd1'
    'SP.ReportComponents\SP.ReportComponents.psd1'
    'SP.AdaptiveReports\SP.AdaptiveReports.psd1'
)
foreach ($mod in $moduleChain) {
    $p = Join-Path $toolkitRoot (Join-Path 'Modules' $mod)
    if (Test-Path $p) {
        Import-Module $p -Force -DisableNameChecking -ErrorAction Stop
    }
    else {
        Write-Host "ERROR: required module not found: $p" -ForegroundColor Red
        exit 4
    }
}

#endregion

#region Setup

$startTime = Get-Date
$correlationID = [guid]::NewGuid().ToString()
$runStamp = $startTime.ToString('yyyyMMdd-HHmmss')

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  30-Day Manager Certification Simulation' -ForegroundColor Cyan
Write-Host "  Started:       $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkGray
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

# Browser token injection (optional)
if ($Token) {
    Write-Host '  Auth: Injecting browser token...' -ForegroundColor Gray
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

# Resolve mock base URL (best-effort, for the summary only)
$mockBaseUrl = ''
try {
    if ($null -ne $config.PSObject.Properties['Api'] -and
        $null -ne $config.Api -and
        $null -ne $config.Api.PSObject.Properties['BaseUrl']) {
        $mockBaseUrl = [string]$config.Api.BaseUrl
    }
} catch { }

# Safety: max campaigns per run (write round-trip ceiling)
$maxCampaigns = 10
if ($null -ne $config.PSObject.Properties['Safety'] -and
    $null -ne $config.Safety -and
    $null -ne $config.Safety.PSObject.Properties['MaxCampaignsPerRun'] -and
    [int]$config.Safety.MaxCampaignsPerRun -gt 0) {
    $maxCampaigns = [int]$config.Safety.MaxCampaignsPerRun
}

$allowComplete = $false
if ($null -ne $config.PSObject.Properties['Safety'] -and
    $null -ne $config.Safety -and
    $null -ne $config.Safety.PSObject.Properties['AllowCompleteCampaign']) {
    $allowComplete = [bool]$config.Safety.AllowCompleteCampaign
}

# Resolve output (capture) directory
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $toolkitRoot (Join-Path 'Audit' "sim-30day-$runStamp")
}
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $toolkitRoot $OutputPath
}
if (-not (Test-Path $OutputPath)) {
    # The capture dir is infrastructure, not a domain mutation -- always create it
    # (do not let -WhatIf suppress it, or downstream artifact writes would fail).
    New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null
}
Write-Host "  Capture dir:   $OutputPath" -ForegroundColor DarkGray
Write-Host ''

$isWhatIf = ($WhatIfPreference -eq $true)
if ($isWhatIf) {
    Write-Host '  [WhatIf] Dry-run mode -- the write round-trip will be simulated.' -ForegroundColor Yellow
    Write-Host ''
}

Write-SPLog -Message "Invoke-SP30DayManagerCertSim started: CorrelationID=$correlationID" `
    -Severity INFO -Component 'Sim30Day' -Action 'Start' -CorrelationID $correlationID

# FIXED tracked privileged roles (mirrors the T-03 dataset trackedPrivilegedRoles
# block; no dedicated mock endpoint exists to read them, per CLI design).
$trackedRoles = @(
    @{ Id = 'ent-003'; Name = 'AD-SG-Admins-3';        ManagerId = 'id-gen-001'; ManagerName = 'James Smith' }
    @{ Id = 'ent-017'; Name = 'AD-SG-Marketing-17';    ManagerId = 'id-gen-002'; ManagerName = 'Mary Johnson' }
    @{ Id = 'ent-038'; Name = 'AD-SG-CloudApps-38';    ManagerId = 'id-gen-003'; ManagerName = 'Robert Williams' }
    @{ Id = 'ent-055'; Name = 'AD-SG-Identity-55';     ManagerId = 'id-gen-004'; ManagerName = 'Patricia Brown' }
    @{ Id = 'ent-072'; Name = 'AD-SG-Security-72';     ManagerId = 'id-gen-005'; ManagerName = 'John Jones' }
    @{ Id = 'ent-096'; Name = 'AD-SG-ReadOnly-96';     ManagerId = 'id-gen-006'; ManagerName = 'Jennifer Garcia' }
    @{ Id = 'ent-119'; Name = 'AD-SG-Procurement-119'; ManagerId = 'id-gen-007'; ManagerName = 'Michael Miller' }
    @{ Id = 'ent-140'; Name = 'AD-SG-Ops-140';         ManagerId = 'id-gen-008'; ManagerName = 'Linda Smith' }
    @{ Id = 'ent-168'; Name = 'AD-SG-Legal-168';       ManagerId = 'id-gen-009'; ManagerName = 'David Johnson' }
    @{ Id = 'ent-191'; Name = 'AD-SG-Audit-191';       ManagerId = 'id-gen-010'; ManagerName = 'Elizabeth Williams' }
)

#endregion

#region Step tracking / helpers

$worstExitCode = 0
$auditFile = Join-Path $OutputPath 'sim-audit.jsonl'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-SimAudit {
    param(
        [string]$Step,
        [string]$Status,
        [object]$Detail
    )
    try {
        $event = [ordered]@{
            Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Action        = 'Sim30Day'
            CorrelationID = $correlationID
            Step          = $Step
            Status        = $Status
            Detail        = $Detail
        }
        $line = $event | ConvertTo-Json -Depth 8 -Compress
        [System.IO.File]::AppendAllText($auditFile, "$line`n", $utf8NoBom)
    }
    catch { }
}

# Resolve sibling script paths once.
$auditScript    = Join-Path $scriptRoot 'Invoke-SPCampaignAudit.ps1'
$adaptiveScript = Join-Path $scriptRoot 'Invoke-SPAdaptiveReport.ps1'

# Collect generated report paths for echo + summary.
$reportPaths = [System.Collections.Generic.List[string]]::new()

function Add-ReportFiles {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path $Dir)) { return }
    try {
        Get-ChildItem -Path $Dir -Recurse -File -Include '*.html', '*.json', '*.jsonl', '*.txt' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $reportPaths.Add($_.FullName)
                Write-Host "      report: $($_.FullName)" -ForegroundColor DarkGray
            }
    }
    catch { }
}

#endregion

#region Step A: Campaign WRITE round-trip

$writeResult = [ordered]@{
    Submitted = 0
    Activated = 0
    Completed = 0
    Confirmed = 0
    Ids       = [System.Collections.Generic.List[string]]::new()
    Names     = [System.Collections.Generic.List[string]]::new()
}

if (-not $SkipWrite) {
    Write-Host '  Step A: Campaign WRITE round-trip' -ForegroundColor Cyan
    $writeStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $namePrefix = 'Sim Manager Cert'
    $rolesToSubmit = @($trackedRoles | Select-Object -First $maxCampaigns)

    foreach ($role in $rolesToSubmit) {
        $campName = "$namePrefix $($role.Name) $writeStamp"
        try {
            if ($PSCmdlet.ShouldProcess($campName, 'New-SPCampaign (MANAGER)')) {
                $newResult = New-SPCampaign -Name $campName -Type MANAGER `
                    -CertifierIdentityId $role.ManagerId `
                    -Description "Daily privileged role attestation simulation for $($role.Name)" `
                    -CorrelationID $correlationID -CampaignTestId 'T-04'

                if ($null -ne $newResult -and $newResult.Success -and $null -ne $newResult.Data) {
                    $campId = [string]$newResult.Data.id
                    $writeResult.Submitted++
                    $writeResult.Ids.Add($campId)
                    $writeResult.Names.Add($campName)
                    Write-Host "    + Submitted: $campName (id=$campId)" -ForegroundColor Green

                    # Activate
                    if ($PSCmdlet.ShouldProcess($campId, 'Start-SPCampaign (activate)')) {
                        $startResult = Start-SPCampaign -CampaignId $campId -CorrelationID $correlationID -CampaignTestId 'T-04'
                        if ($null -ne $startResult -and $startResult.Success) {
                            $writeResult.Activated++
                        }
                        else {
                            $errTxt = if ($null -ne $startResult) { $startResult.Error } else { 'null result' }
                            Write-Host "      WARN: activate failed: $errTxt" -ForegroundColor Yellow
                            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
                        }
                    }

                    # Optionally complete a subset (first 3) when allowed by Safety.
                    if ($allowComplete -and $writeResult.Submitted -le 3) {
                        if ($PSCmdlet.ShouldProcess($campId, 'Complete-SPCampaign')) {
                            $compResult = Complete-SPCampaign -CampaignId $campId -CorrelationID $correlationID -CampaignTestId 'T-04'
                            if ($null -ne $compResult -and $compResult.Success) {
                                $writeResult.Completed++
                            }
                            else {
                                $errTxt = if ($null -ne $compResult) { $compResult.Error } else { 'null result' }
                                Write-Host "      INFO: complete not applied: $errTxt" -ForegroundColor DarkGray
                            }
                        }
                    }
                }
                else {
                    $errTxt = if ($null -ne $newResult) { $newResult.Error } else { 'null result' }
                    Write-Host "    ! Submit failed for $($role.Name): $errTxt" -ForegroundColor Red
                    if ($worstExitCode -lt 5) { $worstExitCode = 5 }
                }
            }
            else {
                # WhatIf path -- simulated, no API call.
                Write-Host "    [WhatIf] Would submit + activate: $campName" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "    ! Exception submitting $($role.Name): $($_.Exception.Message)" -ForegroundColor Red
            Write-SPLog -Message "Step A exception ($($role.Name)): $($_.Exception.Message)" `
                -Severity ERROR -Component 'Sim30Day' -Action 'WriteRoundTrip' -CorrelationID $correlationID
            if ($worstExitCode -lt 5) { $worstExitCode = 5 }
        }
    }

    # CONFIRM round-trip (skip in WhatIf -- nothing was actually created).
    if (-not $isWhatIf -and $writeResult.Submitted -gt 0) {
        try {
            $searchResult = Search-SPCampaigns -Keyword $namePrefix -CorrelationID $correlationID
            $foundNames = @()
            if ($null -ne $searchResult -and $searchResult.Success -and $null -ne $searchResult.Data) {
                $foundNames = @($searchResult.Data | ForEach-Object { $_.name })
            }
            foreach ($id in $writeResult.Ids) {
                $getResult = Get-SPCampaign -CampaignId $id -CorrelationID $correlationID -CampaignTestId 'T-04'
                if ($null -ne $getResult -and $getResult.Success -and $null -ne $getResult.Data) {
                    $writeResult.Confirmed++
                }
            }
            $matchedNames = @($writeResult.Names | Where-Object { $foundNames -contains $_ })
            Write-Host "    Round-trip confirmed: $($writeResult.Confirmed)/$($writeResult.Submitted) via Get-SPCampaign; $($matchedNames.Count) name(s) returned by Search-SPCampaigns" -ForegroundColor Green
            if ($writeResult.Confirmed -lt $writeResult.Submitted) {
                if ($worstExitCode -lt 1) { $worstExitCode = 1 }
            }
        }
        catch {
            Write-Host "    WARN: round-trip confirmation failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
    }

    # Capture submitted/confirmed ids to the capture dir.
    try {
        $writeCapture = [ordered]@{
            Submitted = $writeResult.Submitted
            Activated = $writeResult.Activated
            Completed = $writeResult.Completed
            Confirmed = $writeResult.Confirmed
            Ids       = @($writeResult.Ids)
            Names     = @($writeResult.Names)
            WhatIf    = $isWhatIf
        }
        $writeCaptureFile = Join-Path $OutputPath 'write-roundtrip.json'
        [System.IO.File]::WriteAllText($writeCaptureFile, ($writeCapture | ConvertTo-Json -Depth 6), $utf8NoBom)
        Write-Host "    capture: $writeCaptureFile" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "    WARN: failed to write write-roundtrip.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-SimAudit -Step 'A-Write' -Status 'Done' -Detail @{
        Submitted = $writeResult.Submitted; Activated = $writeResult.Activated
        Completed = $writeResult.Completed; Confirmed = $writeResult.Confirmed; WhatIf = $isWhatIf
    }
    Write-Host ''
}
else {
    Write-Host '  Step A: Campaign WRITE round-trip [SKIPPED]' -ForegroundColor DarkGray
    Write-SimAudit -Step 'A-Write' -Status 'Skipped' -Detail $null
    Write-Host ''
}

#endregion

#region Report-run helper (child-process invocation, exact sibling pattern)

$cadenceResults = [System.Collections.Generic.List[object]]::new()

function Invoke-SimChild {
    param(
        [string]$ScriptPath,
        [hashtable]$Params,
        [string]$Label
    )
    $rec = [ordered]@{ Label = $Label; Script = (Split-Path -Leaf $ScriptPath); ExitCode = $null; OutputDir = $Params['OutputPath'] }
    try {
        $stdout = & $ScriptPath @Params
        $rec.ExitCode = $LASTEXITCODE
        # exit 1 = "no campaigns in window" -> WARN, not fatal.
        if ($rec.ExitCode -eq 1) {
            Write-Host "    $Label : WARN (no campaigns/data in window, exit 1)" -ForegroundColor Yellow
            if ($script:worstExitCode -lt 1) { $script:worstExitCode = 1 }
        }
        elseif ($rec.ExitCode -ne 0) {
            Write-Host "    $Label : WARN (exit $($rec.ExitCode))" -ForegroundColor Yellow
            if ($script:worstExitCode -lt 1) { $script:worstExitCode = 1 }
        }
        else {
            Write-Host "    $Label : OK (exit 0)" -ForegroundColor Green
        }
        # Capture JSON stdout if any (best-effort).
        if ($stdout) {
            $jsonStr = ($stdout | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($jsonStr) -and $jsonStr.StartsWith('{')) {
                try {
                    $capFile = Join-Path $rec.OutputDir 'child-stdout.json'
                    if (-not (Test-Path $rec.OutputDir)) { New-Item -ItemType Directory -Path $rec.OutputDir -Force -WhatIf:$false | Out-Null }
                    [System.IO.File]::WriteAllText($capFile, $jsonStr, $utf8NoBom)
                } catch { }
            }
        }
        Add-ReportFiles -Dir $rec.OutputDir
    }
    catch {
        $rec.ExitCode = 99
        Write-Host "    $Label : WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "$Label child failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'Sim30Day' -Action 'ChildScript' -CorrelationID $correlationID
        if ($script:worstExitCode -lt 1) { $script:worstExitCode = 1 }
    }
    Write-SimAudit -Step $Label -Status "exit=$($rec.ExitCode)" -Detail @{ OutputDir = $rec.OutputDir }
    return $rec
}

#endregion

#region Step B: daily cadence loop (days 1..CadenceDays)

if (-not $SkipReports) {
    Write-Host "  Step B: Daily cadence pass (days 1..$CadenceDays)" -ForegroundColor Cyan
    for ($d = 1; $d -le $CadenceDays; $d++) {
        $dayLabel = 'day-{0:00}' -f $d
        Write-Host "    [$dayLabel] DaysBack=$d" -ForegroundColor Gray
        $dayRoot = Join-Path $OutputPath $dayLabel

        # Audit (campaign cert audit + leadership rollup)
        $auditOut = Join-Path $dayRoot 'audit'
        $auditParams = @{
            ConfigPath              = $ConfigPath
            Status                  = @('ACTIVE', 'COMPLETED')
            DaysBack                = $d
            IncludeLeadershipRollup = $true
            OutputMode              = 'JSON'
            OutputPath              = $auditOut
        }
        if ($Token) { $auditParams['Token'] = $Token; $auditParams['TokenExpiryMinutes'] = $TokenExpiryMinutes }
        $cadenceResults.Add((Invoke-SimChild -ScriptPath $auditScript -Params $auditParams -Label "$dayLabel/audit"))

        # Adaptive privileged-role report
        $adaptiveOut = Join-Path $dayRoot 'adaptive'
        $adaptiveParams = @{
            ConfigPath     = $ConfigPath
            Anchor         = 'Entitlement'
            BaselineReport = @('privileged')
            DaysBack       = $d
            OutputMode     = 'JSON'
            OutputPath     = $adaptiveOut
        }
        if ($Token) { $adaptiveParams['Token'] = $Token; $adaptiveParams['TokenExpiryMinutes'] = $TokenExpiryMinutes }
        $cadenceResults.Add((Invoke-SimChild -ScriptPath $adaptiveScript -Params $adaptiveParams -Label "$dayLabel/adaptive"))

        # SMTP-WhatIf leadership distribution preview (NO -SendReports unless driver -SendReports)
        $smtpOut = Join-Path $dayRoot 'smtp-whatif'
        $smtpParams = @{
            ConfigPath             = $ConfigPath
            Anchor                 = 'Entitlement'
            BaselineReport         = @('privileged')
            DaysBack               = $d
            DistributeToLeadership = $true
            DetailLevel            = $DetailLevel
            OutputMode             = 'JSON'
            OutputPath             = $smtpOut
        }
        if ($SendReports) { $smtpParams['SendReports'] = $true }
        if ($Token) { $smtpParams['Token'] = $Token; $smtpParams['TokenExpiryMinutes'] = $TokenExpiryMinutes }
        $cadenceResults.Add((Invoke-SimChild -ScriptPath $adaptiveScript -Params $smtpParams -Label "$dayLabel/smtp-whatif"))
    }
    Write-Host ''
}
else {
    Write-Host '  Step B: Daily cadence pass [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step C: windowed runs (7-day, 30-day)

$windowResults = [ordered]@{ SevenDay = $null; ThirtyDay = $null }

if (-not $SkipReports) {
    Write-Host '  Step C: Windowed runs (7-day, 30-day)' -ForegroundColor Cyan

    $windows = @(
        @{ Key = 'SevenDay';  Dir = '7d';  Days = 7  }
        @{ Key = 'ThirtyDay'; Dir = '30d'; Days = 30 }
    )
    foreach ($w in $windows) {
        Write-Host "    [$($w.Dir)] DaysBack=$($w.Days)" -ForegroundColor Gray
        $winRoot = Join-Path (Join-Path $OutputPath 'windows') $w.Dir
        $winRecs = [System.Collections.Generic.List[object]]::new()

        $wAuditOut = Join-Path $winRoot 'audit'
        $wAuditParams = @{
            ConfigPath              = $ConfigPath
            Status                  = @('ACTIVE', 'COMPLETED')
            DaysBack                = $w.Days
            IncludeLeadershipRollup = $true
            OutputMode              = 'JSON'
            OutputPath              = $wAuditOut
        }
        if ($Token) { $wAuditParams['Token'] = $Token; $wAuditParams['TokenExpiryMinutes'] = $TokenExpiryMinutes }
        $winRecs.Add((Invoke-SimChild -ScriptPath $auditScript -Params $wAuditParams -Label "$($w.Dir)/audit"))

        $wAdaptiveOut = Join-Path $winRoot 'adaptive'
        $wAdaptiveParams = @{
            ConfigPath     = $ConfigPath
            Anchor         = 'Entitlement'
            BaselineReport = @('privileged')
            DaysBack       = $w.Days
            OutputMode     = 'JSON'
            OutputPath     = $wAdaptiveOut
        }
        if ($Token) { $wAdaptiveParams['Token'] = $Token; $wAdaptiveParams['TokenExpiryMinutes'] = $TokenExpiryMinutes }
        $winRecs.Add((Invoke-SimChild -ScriptPath $adaptiveScript -Params $wAdaptiveParams -Label "$($w.Dir)/adaptive"))

        $windowResults[$w.Key] = @($winRecs)
    }
    Write-Host ''
}
else {
    Write-Host '  Step C: Windowed runs [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step E: Rolling 7/30-day trend HTML (T-06)

# Additive, best-effort rolling-trend view. Sources the daily privileged campaigns
# (with managerAttestation) and the membership changelog from the LIVE mock, then
# calls Export-SPRollingTrendHtml. Fully guarded: any failure downgrades to a WARN
# (worstExitCode -> max(1)) and writes a rolling-trend-skipped.json note -- it MUST
# NEVER make the whole sim FAIL. The authoritative verification of the function is
# the unit suite Tests/SP.RollingTrendHtml.Tests.ps1 (frozen-fixture based).

if (-not $SkipReports) {
    Write-Host '  Step E: Rolling 7/30-day trend HTML' -ForegroundColor Cyan
    $rtOut = Join-Path $OutputPath 'rolling-trend'
    try {
        if (-not (Test-Path $rtOut)) { New-Item -ItemType Directory -Path $rtOut -Force | Out-Null }

        # Acquire daily campaigns (camp-daily-priv-*) from the mock.
        $dailyCampaigns = @()
        try {
            $campsUri = "$($mockBaseUrl.TrimEnd('/'))/v3/campaigns?limit=250"
            $campResp = Invoke-RestMethod -Uri $campsUri -Method GET -TimeoutSec 30 -ErrorAction Stop
            $dailyCampaigns = @($campResp | Where-Object { $null -ne $_ -and ([string]$_.id) -like 'camp-daily-priv-*' })
        }
        catch {
            Write-Host "      WARN: could not fetch daily campaigns: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Acquire the membership changelog from the mock.
        $changelog = @()
        try {
            $clUri = "$($mockBaseUrl.TrimEnd('/'))/v3/membership-changelog?limit=10000"
            $clResp = Invoke-RestMethod -Uri $clUri -Method GET -TimeoutSec 60 -ErrorAction Stop
            $changelog = @($clResp | Where-Object { $null -ne $_ })
        }
        catch {
            Write-Host "      WARN: could not fetch membership changelog: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Tracked roles for changelog scoping (driver's fixed list -> { id; name }).
        $rtTracked = @($trackedRoles | ForEach-Object { @{ id = $_.Id; name = $_.Name } })

        $rtResult = Export-SPRollingTrendHtml -DailyCampaigns @($dailyCampaigns) `
            -Changelog @($changelog) -TrackedRoles @($rtTracked) `
            -OutputPath $rtOut -WindowDays @(7, 30) -CorrelationID $correlationID

        if ($null -ne $rtResult -and $rtResult.Success -and $null -ne $rtResult.Data) {
            $rtPath = [string]$rtResult.Data.Path
            $reportPaths.Add($rtPath)
            Write-Host "      report: $rtPath" -ForegroundColor DarkGray
            $rem30 = 0; $mis30 = 0
            if ($null -ne $rtResult.Data.Windows -and $rtResult.Data.Windows.Contains('30')) {
                $rem30 = [int]$rtResult.Data.Windows['30'].Removed
                $mis30 = [int]$rtResult.Data.Windows['30'].Missed
            }
            Write-Host "    Rolling trend: $($dailyCampaigns.Count) daily campaign(s), $($changelog.Count) changelog event(s); 30d priv-removes=$rem30, missed=$mis30" -ForegroundColor Green
            Write-SimAudit -Step 'E-RollingTrend' -Status 'Done' -Detail @{
                HtmlPath = $rtPath; DailyCampaigns = $dailyCampaigns.Count
                ChangelogEvents = $changelog.Count; Removed30d = $rem30; Missed30d = $mis30
            }
        }
        else {
            $errTxt = if ($null -ne $rtResult) { $rtResult.Error } else { 'null result' }
            Write-Host "    WARN: rolling trend not generated: $errTxt" -ForegroundColor Yellow
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
            $skipNote = Join-Path $rtOut 'rolling-trend-skipped.json'
            [System.IO.File]::WriteAllText($skipNote, (@{ Reason = $errTxt; CorrelationID = $correlationID } | ConvertTo-Json), $utf8NoBom)
            Write-SimAudit -Step 'E-RollingTrend' -Status 'Warn' -Detail @{ Reason = $errTxt }
        }
    }
    catch {
        Write-Host "    WARN: Step E exception (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        try {
            $skipNote = Join-Path $rtOut 'rolling-trend-skipped.json'
            [System.IO.File]::WriteAllText($skipNote, (@{ Reason = $_.Exception.Message; CorrelationID = $correlationID } | ConvertTo-Json), $utf8NoBom)
        }
        catch { }
        Write-SimAudit -Step 'E-RollingTrend' -Status 'Warn' -Detail @{ Reason = $_.Exception.Message }
    }
    Write-Host ''
}
else {
    Write-Host '  Step E: Rolling 7/30-day trend HTML [SKIPPED]' -ForegroundColor DarkGray
    Write-SimAudit -Step 'E-RollingTrend' -Status 'Skipped' -Detail $null
    Write-Host ''
}

#endregion

#region Step F: SP.Sdk path (T-07) -- campaign templates / schedules / work-items

# Additive, opt-in (-IncludeSdkPath), and best-effort: proves the SAME daily
# privileged-attestation business outcome (per-manager accountability + tracked
# privileged roles) is reachable through the PSSailpoint SDK surface, via the
# already-served /campaign-templates, /campaign-templates/{id}/schedule, and
# /work-items[/summary] endpoints. Empty collections downgrade to a WARN (never
# fatal), matching the $worstExitCode pattern. Skipped under -WhatIf.

if ($IncludeSdkPath -and -not $isWhatIf) {
    Write-Host '  Step F: SP.Sdk path (campaign templates / schedules / work-items)' -ForegroundColor Cyan
    $sdkOut = Join-Path $OutputPath 'sdk-path'
    try {
        if (-not (Test-Path $sdkOut)) { New-Item -ItemType Directory -Path $sdkOut -Force -WhatIf:$false | Out-Null }

        $sdkResult = [ordered]@{
            Templates           = @()
            SchedulesSampled    = @()
            WorkItemsSummary    = $null
            OpenWorkItems       = 0
            CompletedWorkItems  = 0
        }

        # (1) Campaign templates (daily privileged-role attestation templates).
        $tmplRes = Get-SPSdkCampaignTemplates -CorrelationID $correlationID
        $templates = @()
        if ($null -ne $tmplRes -and $tmplRes.Success) {
            $templates = @($tmplRes.Data)
        }
        $sdkResult.Templates = @($templates | ForEach-Object {
            $ownerId = $null; $ownerName = $null
            if ($null -ne $_.ownerRef) { $ownerId = $_.ownerRef.id; $ownerName = $_.ownerRef.name }
            [ordered]@{ id = [string]$_.id; name = [string]$_.name; type = [string]$_.type; ownerId = $ownerId; ownerName = $ownerName }
        })
        Write-Host "    Templates: $($templates.Count)" -ForegroundColor $(if ($templates.Count -gt 0) { 'Green' } else { 'Yellow' })

        # (2) Schedules (sample the first few templates -- proves DAILY cadence).
        $sampleN = [math]::Min(3, @($templates).Count)
        for ($s = 0; $s -lt $sampleN; $s++) {
            $tid = [string]$templates[$s].id
            $schRes = Get-SPSdkTemplateSchedule -TemplateId $tid -CorrelationID $correlationID
            if ($null -ne $schRes -and $schRes.Success -and $null -ne $schRes.Data) {
                $sdkResult.SchedulesSampled += [ordered]@{
                    templateId = $tid
                    type       = [string]$schRes.Data.type
                    timeZoneId = [string]$schRes.Data.timeZoneId
                }
            }
        }

        # (3) Work-items summary + open items (manager attestation tasks).
        $wiSumRes = Get-SPSdkWorkItemsSummary -CorrelationID $correlationID
        if ($null -ne $wiSumRes -and $wiSumRes.Success -and $null -ne $wiSumRes.Data) {
            $sdkResult.WorkItemsSummary = [ordered]@{
                open      = [int]$wiSumRes.Data.open
                completed = [int]$wiSumRes.Data.completed
                total     = [int]$wiSumRes.Data.total
            }
        }
        $wiOpenRes = Get-SPSdkWorkItems -CorrelationID $correlationID
        if ($null -ne $wiOpenRes -and $wiOpenRes.Success) {
            $sdkResult.OpenWorkItems = @($wiOpenRes.Data).Count
        }
        $wiDoneRes = Get-SPSdkCompletedWorkItems -CorrelationID $correlationID
        if ($null -ne $wiDoneRes -and $wiDoneRes.Success) {
            $sdkResult.CompletedWorkItems = @($wiDoneRes.Data).Count
        }
        Write-Host "    Work-items: open=$($sdkResult.OpenWorkItems) completed=$($sdkResult.CompletedWorkItems)" -ForegroundColor $(if ($sdkResult.OpenWorkItems -gt 0) { 'Green' } else { 'Yellow' })

        $sdkFile = Join-Path $sdkOut 'sdk-path.json'
        [System.IO.File]::WriteAllText($sdkFile, ($sdkResult | ConvertTo-Json -Depth 8), $utf8NoBom)
        $reportPaths.Add($sdkFile)
        Write-Host "    capture: $sdkFile" -ForegroundColor DarkGray

        # Empty SDK collections are a WARN, not fatal.
        if (@($templates).Count -eq 0 -or $sdkResult.OpenWorkItems -eq 0) {
            Write-Host '    WARN: SDK path returned empty templates or no open work-items.' -ForegroundColor Yellow
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
            Write-SimAudit -Step 'F-SdkPath' -Status 'Warn' -Detail @{ Templates = @($templates).Count; OpenWorkItems = $sdkResult.OpenWorkItems }
        }
        else {
            Write-SimAudit -Step 'F-SdkPath' -Status 'Done' -Detail @{
                Templates = @($templates).Count; SchedulesSampled = @($sdkResult.SchedulesSampled).Count
                OpenWorkItems = $sdkResult.OpenWorkItems; CompletedWorkItems = $sdkResult.CompletedWorkItems
            }
        }
    }
    catch {
        Write-Host "    WARN: Step F exception (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        Write-SimAudit -Step 'F-SdkPath' -Status 'Warn' -Detail @{ Reason = $_.Exception.Message }
    }
    Write-Host ''
}
elseif ($IncludeSdkPath -and $isWhatIf) {
    Write-Host '  Step F: SP.Sdk path [SKIPPED -- WhatIf]' -ForegroundColor DarkGray
    Write-SimAudit -Step 'F-SdkPath' -Status 'Skipped' -Detail @{ Reason = 'WhatIf' }
    Write-Host ''
}

#endregion

#region Step D: capture artifacts + summary

$endTime = Get-Date
$totalDuration = ($endTime - $startTime)
$durationStr = '{0}m {1:00}s' -f [int][math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

$summary = [ordered]@{
    CorrelationID  = $correlationID
    RunStartedAt   = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    RunCompletedAt = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    DurationSeconds = [math]::Round($totalDuration.TotalSeconds, 1)
    MockBaseUrl    = $mockBaseUrl
    WhatIf         = $isWhatIf
    SendReports    = [bool]$SendReports
    Write          = [ordered]@{
        Submitted = $writeResult.Submitted
        Activated = $writeResult.Activated
        Completed = $writeResult.Completed
        Confirmed = $writeResult.Confirmed
        Ids       = @($writeResult.Ids)
        Names     = @($writeResult.Names)
    }
    Cadence        = [ordered]@{
        Days   = $CadenceDays
        PerDay = @($cadenceResults)
    }
    Windows        = [ordered]@{
        SevenDay  = $windowResults['SevenDay']
        ThirtyDay = $windowResults['ThirtyDay']
    }
    ReportPaths    = @($reportPaths)
    ExitCode       = $worstExitCode
}

$summaryFile = Join-Path $OutputPath 'sim-summary.json'
try {
    [System.IO.File]::WriteAllText($summaryFile, ($summary | ConvertTo-Json -Depth 8), $utf8NoBom)
    Write-Host "  Summary written: $summaryFile" -ForegroundColor Green
}
catch {
    Write-Host "  WARN: failed to write sim-summary.json: $($_.Exception.Message)" -ForegroundColor Yellow
    if ($worstExitCode -lt 1) { $worstExitCode = 1 }
}
# Keep the summary's recorded exit code consistent with the final value.
$summary.ExitCode = $worstExitCode

Write-SimAudit -Step 'D-Summary' -Status "exit=$worstExitCode" -Detail @{ SummaryFile = $summaryFile; ReportCount = $reportPaths.Count }

#endregion

#region Final summary output

$overallResult = 'SUCCESS'
if ($worstExitCode -eq 1) { $overallResult = 'SUCCESS (with warnings)' }
if ($worstExitCode -ge 2) { $overallResult = 'FAILED' }
if ($isWhatIf)            { $overallResult = 'WHATIF' }

if ($OutputMode -eq 'Console' -or $OutputMode -eq 'Both') {
    Write-Host ''
    Write-Host '  === 30-Day Manager Cert Simulation Summary ===' -ForegroundColor Cyan
    Write-Host "  Duration:        $durationStr"
    Write-Host "  Mock:            $mockBaseUrl"
    Write-Host "  Write round-trip: Submitted=$($writeResult.Submitted) Activated=$($writeResult.Activated) Completed=$($writeResult.Completed) Confirmed=$($writeResult.Confirmed)"
    Write-Host "  Cadence days:    $CadenceDays  (steps: $($cadenceResults.Count))"
    Write-Host "  Windows:         7d + 30d"
    Write-Host "  Reports captured: $($reportPaths.Count)"
    Write-Host "  Capture dir:     $OutputPath"
    Write-Host "  Result:          $overallResult" -ForegroundColor $(
        if ($worstExitCode -eq 0) { 'Green' } elseif ($worstExitCode -eq 1) { 'Yellow' } else { 'Red' }
    )
    Write-Host ''
}

if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
    $summary | ConvertTo-Json -Depth 6
}

Write-SPLog -Message "Invoke-SP30DayManagerCertSim completed: ExitCode=$worstExitCode Duration=$durationStr" `
    -Severity INFO -Component 'Sim30Day' -Action 'Complete' -CorrelationID $correlationID

#endregion

exit $worstExitCode

#Requires -Version 5.1
<#
.SYNOPSIS
    Authored live-mock resilience probe (T-04). NOT the headless gate.
.DESCRIPTION
    Proves end-to-end that the toolkit's daily attestation cadence survives
    injected API failures (429 rate limit / 503 / slow) WITHOUT crashing, by:

      1. Applying a named error-injection preset to the mock via the mock repo's
         Scripts/Set-ErrorPreset.ps1 (e.g. 'rate-limiting' or 'sailpoint-slow').
      2. Running a short daily-cadence pass of the existing sim driver
         (Invoke-SP30DayManagerCertSim.ps1 -CadenceDays N -SkipWrite) and
         asserting it COMPLETED with exit 0 (green) or 1 (WARN) rather than
         crashing or throwing.
      3. In a finally block that ALWAYS runs, RESETTING error injection to the
         'none' preset (and, if a scenario was touched, the scenario back to
         normal) so the mock is left clean.

    IMPORTANT -- Set-ErrorPreset.ps1 only patches the mock's mock-settings.json;
    it does NOT hot-reload. For an applied preset to actually take effect the
    operator MUST restart the mock (Start-MockServer.ps1) AFTER the preset is
    applied. Because of that human step, this probe is AUTHORED for a human/
    operator to run -- it is intentionally NOT auto-run as the loop's headless
    gate. The headless gate is the mocked-transport Pester suite
    Tests/SP.ApiResilience.Tests.ps1.

    The reset in the finally block is the load-bearing guarantee of this script:
    no matter how the cadence pass exits (success, WARN, error, or thrown
    exception), the mock's error injection is reset to 'none' before the script
    returns, leaving the mock clean for the next run.

.PARAMETER ConfigPath
    Path to settings.json targeting the mock. Default Config\settings.local.json
    (relative to the toolkit root).
.PARAMETER PresetName
    Error-injection preset to apply for the probe. Default 'rate-limiting'.
    Other useful values: 'sailpoint-slow', 'intermittent-failures'.
.PARAMETER MockRepoRoot
    Filesystem root of the SEPARATE mock-api repo. Default
    'C:/temp/Coding/API-mockserver'.
.PARAMETER CadenceDays
    Number of simulated days for the cadence pass. Default 1 (a short pass).
.PARAMETER ResetPresetName
    Preset to reset to in the finally block. Default 'none' (error injection off).
.EXAMPLE
    .\Invoke-SPResilienceProbe.ps1 -PresetName rate-limiting -CadenceDays 1
    # Apply rate-limiting, run a 1-day cadence pass, then reset to 'none'.
.NOTES
    Run NON-ELEVATED. Requires the mock to be running on http://localhost:8080
    (start it with the mock repo's Start-MockServer.ps1). Remember: apply the
    preset, THEN restart the mock so it takes effect, THEN run this probe.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,

    [ValidateNotNullOrEmpty()]
    [string]$PresetName = 'rate-limiting',

    [ValidateNotNullOrEmpty()]
    [string]$MockRepoRoot = 'C:/temp/Coding/API-mockserver',

    [int]$CadenceDays = 1,

    [ValidateNotNullOrEmpty()]
    [string]$ResetPresetName = 'none'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$scriptDir   = $PSScriptRoot
$toolkitRoot = Split-Path -Parent $scriptDir

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $toolkitRoot 'Config\settings.local.json'
}

$setPresetScript   = Join-Path $MockRepoRoot 'Scripts/Set-ErrorPreset.ps1'
$setScenarioScript = Join-Path $MockRepoRoot 'Scripts/Set-TestScenario.ps1'
$simDriver         = Join-Path $scriptDir 'Invoke-SP30DayManagerCertSim.ps1'

Write-Host "=== T-04 Resilience Probe (live mock) ===" -ForegroundColor Cyan
Write-Host "  Preset to apply : $PresetName"
Write-Host "  Mock repo root  : $MockRepoRoot"
Write-Host "  Config path     : $ConfigPath"
Write-Host "  Cadence days    : $CadenceDays"
Write-Host "  Reset preset    : $ResetPresetName"

# Pre-flight: required scripts must exist.
foreach ($req in @($setPresetScript, $simDriver)) {
    if (-not (Test-Path -LiteralPath $req)) {
        Write-Host "ERROR: required script not found: $req" -ForegroundColor Red
        exit 2
    }
}

$probeStatus = 'UNKNOWN'

try {
    # -----------------------------------------------------------------------
    # 1. Apply the error-injection preset.
    # -----------------------------------------------------------------------
    Write-Host "`n[1/2] Applying error preset '$PresetName' ..." -ForegroundColor Yellow
    & $setPresetScript -PresetName $PresetName
    Write-Host "NOTE: Set-ErrorPreset only patches mock-settings.json -- it does NOT hot-reload." -ForegroundColor DarkYellow
    Write-Host "      For the preset to take effect you MUST restart the mock (Start-MockServer.ps1)" -ForegroundColor DarkYellow
    Write-Host "      AFTER applying the preset, then re-run this probe. If the running mock already" -ForegroundColor DarkYellow
    Write-Host "      had this preset applied + was restarted, the cadence pass below exercises it." -ForegroundColor DarkYellow

    # -----------------------------------------------------------------------
    # 2. Run a short daily-cadence pass and assert it COMPLETED (exit 0 or 1).
    # -----------------------------------------------------------------------
    Write-Host "`n[2/2] Running short cadence pass (CadenceDays=$CadenceDays, SkipWrite) ..." -ForegroundColor Yellow
    & $simDriver -ConfigPath $ConfigPath -CadenceDays $CadenceDays -SkipWrite
    $simExit = $LASTEXITCODE
    if ($null -eq $simExit) { $simExit = 0 }

    Write-Host "  Cadence pass exit code: $simExit"
    if ($simExit -eq 0 -or $simExit -eq 1) {
        # 0 = green, 1 = WARN: both mean the cadence pass COMPLETED gracefully
        # (degraded by injected errors but no crash / no unhandled exception).
        $probeStatus = if ($simExit -eq 0) { 'PASS (green)' } else { 'PASS (WARN -- degraded but graceful)' }
        Write-Host "  RESULT: $probeStatus" -ForegroundColor Green
    }
    else {
        $probeStatus = "FAIL (cadence pass exited $simExit -- not a graceful 0/1)"
        Write-Host "  RESULT: $probeStatus" -ForegroundColor Red
    }
}
catch {
    $probeStatus = "FAIL (unhandled exception: $($_.Exception.Message))"
    Write-Host "  RESULT: $probeStatus" -ForegroundColor Red
}
finally {
    # -----------------------------------------------------------------------
    # ALWAYS reset error injection so the mock is left clean. This is the
    # load-bearing guarantee of the probe.
    # -----------------------------------------------------------------------
    Write-Host "`n[reset] Resetting error injection to '$ResetPresetName' (ALWAYS runs) ..." -ForegroundColor Yellow
    $resetCmd = "& '$setPresetScript' -PresetName $ResetPresetName"
    Write-Host "  Reset command: $resetCmd"
    try {
        & $setPresetScript -PresetName $ResetPresetName
        Write-Host "  Error injection reset to '$ResetPresetName'." -ForegroundColor Green
        Write-Host "  REMINDER: restart the mock (Start-MockServer.ps1) so the clean state takes effect." -ForegroundColor DarkYellow
    }
    catch {
        Write-Host "  WARN: reset failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  MANUAL RESET REQUIRED: $resetCmd" -ForegroundColor Red
    }

    # If a scenario was applied during a richer probe run, reset it here too.
    # This probe does not apply a scenario by default; documented for completeness.
    if (Test-Path -LiteralPath $setScenarioScript) {
        Write-Host "  (Scenario reset available if needed: & '$setScenarioScript' -ScenarioName <normal>)" -ForegroundColor DarkGray
    }
}

Write-Host "`n=== Probe complete: $probeStatus ===" -ForegroundColor Cyan
if ($probeStatus -like 'PASS*') { exit 0 } else { exit 1 }

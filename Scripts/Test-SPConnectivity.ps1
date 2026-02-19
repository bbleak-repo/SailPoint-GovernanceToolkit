#Requires -Version 5.1
<#
.SYNOPSIS
    Quick smoke test to verify SailPoint ISC connectivity and authentication.
.DESCRIPTION
    Validates the full connectivity stack in sequence:
      Step 1 - Load and validate settings.json
      Step 2 - Acquire OAuth 2.0 bearer token
      Step 3 - Execute a minimal live API call (GET /v3/campaigns?limit=1)

    Each step reports success or failure with elapsed time. Designed to be run
    before executing the main test suite to confirm the environment is reachable.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to
    the Scripts directory.
.EXAMPLE
    .\Test-SPConnectivity.ps1
    # Test connectivity using default settings.json location
.EXAMPLE
    .\Test-SPConnectivity.ps1 -ConfigPath 'C:\Toolkit\Config\settings.json'
    # Test with an explicit config path
.NOTES
    Script:  Test-SPConnectivity.ps1
    Version: 1.0.0
    Exit codes:
        0 = All steps passed
        1 = One or more steps failed
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [Alias('?')]
    [switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

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

$coreModulePath = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
$apiModulePath  = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1'

foreach ($moduleDef in @(
    @{ Path = $coreModulePath; Name = 'SP.Core'; Required = $true },
    @{ Path = $apiModulePath;  Name = 'SP.Api';  Required = $true }
)) {
    if (Test-Path $moduleDef.Path) {
        Import-Module $moduleDef.Path -Force -ErrorAction SilentlyContinue
    }
    else {
        $moduleDir = Split-Path -Parent $moduleDef.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        elseif ($moduleDef.Required) {
            Write-Host "ERROR: Required module '$($moduleDef.Name)' not found at: $($moduleDef.Path)" -ForegroundColor Red
            exit 1
        }
    }
}

#endregion

#region Connectivity Test

$correlationID = [guid]::NewGuid().ToString()
$overallPass   = $true
$results       = @()

function Write-StepResult {
    param(
        [int]    $Step,
        [string] $Description,
        [bool]   $Passed,
        [double] $ElapsedMs,
        [string] $Detail
    )
    $statusLabel = if ($Passed) { 'PASS' } else { 'FAIL' }
    $color       = if ($Passed) { 'Green' } else { 'Red' }
    $elapsed     = [math]::Round($ElapsedMs, 0)
    Write-Host ("  [{0}] Step {1}: {2} ({3}ms)" -f $statusLabel, $Step, $Description, $elapsed) -ForegroundColor $color
    if ($Detail) {
        Write-Host "         $Detail" -ForegroundColor $(if ($Passed) { 'DarkGray' } else { 'Red' })
    }
}

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit - Connectivity Test' -ForegroundColor Cyan
Write-Host "  $('=' * 56)" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

# Resolve config path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $toolkitRoot 'Config\settings.json'
}

# Step 1: Load and validate configuration
$sw      = [System.Diagnostics.Stopwatch]::StartNew()
$config  = $null
$step1Ok = $false
$step1Msg = ''

try {
    $config = Get-SPConfig -ConfigPath $ConfigPath
    if (Test-SPConfigFirstRun -Config $config) {
        $step1Msg = 'First-run configuration detected. Populate settings.json before testing.'
    }
    elseif (Test-SPConfig -Config $config) {
        $step1Ok  = $true
        $step1Msg = "Environment: $($config.Global.EnvironmentName) | Mode: $($config.Authentication.Mode)"
    }
    else {
        $step1Msg = 'Configuration validation failed. Check required fields in settings.json.'
    }
}
catch {
    $step1Msg = "Exception loading configuration: $($_.Exception.Message)"
}

$sw.Stop()
Write-StepResult -Step 1 -Description 'Load and validate settings.json' `
    -Passed $step1Ok -ElapsedMs $sw.Elapsed.TotalMilliseconds -Detail $step1Msg

if (-not $step1Ok) {
    $overallPass = $false
}

# Step 2: Acquire OAuth token
$step2Ok  = $false
$step2Msg = ''

if ($step1Ok) {
    $sw.Restart()
    try {
        $tokenResult = Get-SPAuthToken -CorrelationID $correlationID -Force
        if ($tokenResult.Success) {
            $step2Ok  = $true
            $expiresAt = $tokenResult.Data.ExpiresAt
            $step2Msg = "Mode: $($tokenResult.Data.Mode) | Expires: $expiresAt"
        }
        else {
            $step2Msg = "Token acquisition failed: $($tokenResult.Error)"
        }
    }
    catch {
        $step2Msg = "Exception during token acquisition: $($_.Exception.Message)"
    }
    $sw.Stop()

    Write-StepResult -Step 2 -Description 'Acquire OAuth 2.0 bearer token' `
        -Passed $step2Ok -ElapsedMs $sw.Elapsed.TotalMilliseconds -Detail $step2Msg

    if (-not $step2Ok) {
        $overallPass = $false
    }
}
else {
    Write-Host "  [SKIP] Step 2: Acquire OAuth 2.0 bearer token (skipped due to Step 1 failure)" -ForegroundColor Yellow
}

# Step 3: Live API call - GET /v3/campaigns?limit=1
$step3Ok  = $false
$step3Msg = ''

if ($step2Ok) {
    $sw.Restart()
    try {
        $apiResult = Invoke-SPApiRequest `
            -Method       GET `
            -Endpoint     '/campaigns' `
            -QueryParams  @{ limit = '1' } `
            -CorrelationID $correlationID

        if ($apiResult.Success) {
            $step3Ok  = $true
            $itemCount = if ($apiResult.Data -is [array]) { $apiResult.Data.Count } else { 1 }
            $step3Msg  = "API responded successfully. Items returned: $itemCount"
        }
        else {
            $step3Msg = "API call failed (HTTP $($apiResult.StatusCode)): $($apiResult.Error)"
        }
    }
    catch {
        $step3Msg = "Exception during API call: $($_.Exception.Message)"
    }
    $sw.Stop()

    Write-StepResult -Step 3 -Description 'GET /v3/campaigns?limit=1 (live API call)' `
        -Passed $step3Ok -ElapsedMs $sw.Elapsed.TotalMilliseconds -Detail $step3Msg

    if (-not $step3Ok) {
        $overallPass = $false
    }
}
else {
    Write-Host "  [SKIP] Step 3: GET /v3/campaigns?limit=1 (skipped due to Step 2 failure)" -ForegroundColor Yellow
}

# Overall summary
Write-Host ''
Write-Host "  $('=' * 56)" -ForegroundColor DarkGray
if ($overallPass) {
    Write-Host '  RESULT: All connectivity checks passed.' -ForegroundColor Green
}
else {
    Write-Host '  RESULT: One or more connectivity checks failed.' -ForegroundColor Red
    Write-Host '  Review the errors above and check settings.json.' -ForegroundColor Red
}
Write-Host ''

if ($overallPass) { exit 0 } else { exit 1 }

#endregion

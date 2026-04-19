#Requires -Version 5.1
<#
.SYNOPSIS
    Runs SailPoint ISC certification campaign governance tests.
.DESCRIPTION
    Primary CLI entry point for the SailPoint ISC Governance Toolkit. Loads test
    definitions from CSV files, executes certification campaigns against the ISC
    API, and generates structured evidence. Supports tag-based filtering, single
    test execution, WhatIf safety mode, and multiple output formats.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to the
    Scripts directory.
.PARAMETER Tags
    Filter campaigns by one or more tag names (e.g., smoke, regression, full).
    Only campaigns whose Tags column contains at least one matching tag will run.
.PARAMETER TestId
    Run a single test by ID (e.g., TC-001). Mutually exclusive with Tags.
.PARAMETER OutputMode
    Output destination. Console (default), JSON, or Both.
.PARAMETER StopOnFirstFailure
    Stop suite execution after the first test failure.
.EXAMPLE
    .\Invoke-GovernanceTest.ps1 -Tags smoke
    # Run all smoke-tagged tests
.EXAMPLE
    .\Invoke-GovernanceTest.ps1 -TestId TC-003 -WhatIf
    # Dry-run a single test without making API calls
.EXAMPLE
    .\Invoke-GovernanceTest.ps1 -Tags regression -OutputMode Both -StopOnFirstFailure
    # Run regression suite, output to console and JSON, stop on first failure
.NOTES
    Script:  Invoke-GovernanceTest.ps1
    Version: 1.0.0
    Exit codes:
        0 = All tests passed
        1 = One or more tests failed
        2 = Execution aborted (safety guard / user cancel)
        3 = CSV load or validation error
        4 = Parameter or configuration error
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string[]]$Tags,

    [Parameter()]
    [string]$TestId,

    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [switch]$StopOnFirstFailure,

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

$coreModulePath    = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
$apiModulePath     = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1'
$testingModulePath = Join-Path $toolkitRoot 'Modules\SP.Testing\SP.Testing.psd1'

foreach ($moduleDef in @(
    @{ Path = $coreModulePath;    Name = 'SP.Core';    Required = $true },
    @{ Path = $apiModulePath;     Name = 'SP.Api';     Required = $true },
    @{ Path = $testingModulePath; Name = 'SP.Testing';  Required = $true }
)) {
    if (Test-Path $moduleDef.Path) {
        Import-Module $moduleDef.Path -Force -ErrorAction Stop
    }
    else {
        # Attempt to load nested modules directly if psd1 not yet created
        $moduleDir = Split-Path -Parent $moduleDef.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        elseif ($moduleDef.Required) {
            Write-Host "ERROR: Required module '$($moduleDef.Name)' not found at: $($moduleDef.Path)" -ForegroundColor Red
            exit 4
        }
    }
}

#endregion

#region Setup

$correlationID = [guid]::NewGuid().ToString()

# Validate mutually exclusive parameters
if ($Tags -and $TestId) {
    Write-Host "ERROR: -Tags and -TestId cannot be used together. Specify one or neither." -ForegroundColor Red
    exit 4
}

# Resolve config path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $toolkitRoot 'Config\settings.json'
}

# Initialize logging (best-effort -- logging may depend on config)
try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
}
catch {
    # Logging initialization failure is non-fatal at this stage
}

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Invoke-GovernanceTest' -ForegroundColor Cyan
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

# Load configuration
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

# Re-initialize logging with loaded config
try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
}
catch { }

Write-SPLog -Message "Invoke-GovernanceTest started" `
    -Severity INFO -Component 'Invoke-GovernanceTest' -Action 'Start' -CorrelationID $correlationID

#endregion

#region WhatIf Guard

$isProdEnvironment = $config.Safety.RequireWhatIfOnProd
$isWhatIf          = $WhatIfPreference.IsPresent

if ($isProdEnvironment -and -not $isWhatIf) {
    $envName = $config.Global.EnvironmentName
    $message = "You are about to run governance tests against environment '$envName' without -WhatIf. This will create and activate real certification campaigns."
    $target  = "Environment: $envName"

    # Already-answered cases first: -Confirm:$false explicitly bypasses, any
    # other ConfirmPreference=None (e.g. set in-session) is treated the same.
    $confirmBypass = ($PSBoundParameters.ContainsKey('Confirm') -and -not $PSBoundParameters['Confirm']) `
                     -or ($ConfirmPreference -eq 'None')

    if (-not $confirmBypass) {
        # ShouldProcess can throw NullReferenceException when invoked in a
        # non-interactive host (e.g. 'powershell.exe -Command ...' from CI,
        # a parent process, or an IDE runner) because the host's UI is
        # incomplete. We treat any throw here as 'operator did not confirm'
        # rather than crashing the whole script.
        $confirmed = $false
        try {
            $confirmed = $PSCmdlet.ShouldProcess($target, $message)
        }
        catch {
            Write-Host "Execution aborted: cannot prompt for confirmation in this host." -ForegroundColor Yellow
            Write-Host "  Reason: $($_.Exception.Message)" -ForegroundColor DarkGray
            Write-Host "  Re-run with -WhatIf to dry-run, or -Confirm:`$false to skip this prompt." -ForegroundColor DarkGray
            Write-SPLog -Message "Execution aborted at WhatIf guard: ShouldProcess threw in non-interactive host ($($_.Exception.Message))" `
                -Severity WARN -Component 'Invoke-GovernanceTest' -Action 'Abort' -CorrelationID $correlationID
            exit 2
        }

        if (-not $confirmed) {
            Write-Host "Execution aborted by user." -ForegroundColor Yellow
            Write-SPLog -Message "Execution aborted by user at WhatIf guard" `
                -Severity WARN -Component 'Invoke-GovernanceTest' -Action 'Abort' -CorrelationID $correlationID
            exit 2
        }
    }
}

if ($isWhatIf) {
    Write-Host "  [WhatIf] Dry-run mode enabled. No API calls will be made." -ForegroundColor Yellow
    Write-Host ''
}

#endregion

#region Dispatch

$runStart = Get-Date

# Resolve CSV paths
$identitiesCsvPath = $config.Testing.IdentitiesCsvPath
$campaignsCsvPath  = $config.Testing.CampaignsCsvPath

if (-not [System.IO.Path]::IsPathRooted($identitiesCsvPath)) {
    $identitiesCsvPath = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $identitiesCsvPath.TrimStart('.\').TrimStart('./')))
}
if (-not [System.IO.Path]::IsPathRooted($campaignsCsvPath)) {
    $campaignsCsvPath = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $campaignsCsvPath.TrimStart('.\').TrimStart('./')))
}

# Load identities
Write-Host "  Loading test identities from: $identitiesCsvPath" -ForegroundColor Cyan
$identResult = Import-SPTestIdentities -CsvPath $identitiesCsvPath
if (-not $identResult.Success) {
    Write-Host "ERROR: $($identResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Failed to load identities: $($identResult.Error)" `
        -Severity ERROR -Component 'Invoke-GovernanceTest' -Action 'LoadIdentities' -CorrelationID $correlationID
    exit 3
}
$identities = $identResult.Data
Write-Host "  Loaded $($identities.Count) identities." -ForegroundColor Green

# Load campaigns (with optional tag or TestId filter)
Write-Host "  Loading test campaigns from: $campaignsCsvPath" -ForegroundColor Cyan

$importParams = @{
    CsvPath    = $campaignsCsvPath
    Identities = $identities
}

if ($Tags) {
    $importParams['Tags'] = $Tags
    Write-Host "  Tag filter: $($Tags -join ', ')" -ForegroundColor Cyan
}

$campaignResult = Import-SPTestCampaigns @importParams
if (-not $campaignResult.Success) {
    Write-Host "ERROR: $($campaignResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Failed to load campaigns: $($campaignResult.Error)" `
        -Severity ERROR -Component 'Invoke-GovernanceTest' -Action 'LoadCampaigns' -CorrelationID $correlationID
    exit 3
}
$campaigns = $campaignResult.Data

# Filter by TestId if specified
if ($TestId) {
    $campaigns = @($campaigns | Where-Object { $_.TestId -eq $TestId })
    Write-Host "  TestId filter: $TestId" -ForegroundColor Cyan
    if ($campaigns.Count -eq 0) {
        Write-Host "ERROR: No campaign found with TestId '$TestId'." -ForegroundColor Red
        exit 4
    }
}

Write-Host "  Loaded $($campaigns.Count) test campaign(s)." -ForegroundColor Green

if ($campaigns.Count -eq 0) {
    Write-Host "  No campaigns matched the specified filter. Nothing to run." -ForegroundColor Yellow
    exit 0
}

# Validate test data
Write-Host "  Validating test data cross-references..." -ForegroundColor Cyan
$validateResult = Test-SPTestData -Campaigns $campaigns -Identities $identities
if ($validateResult.Warnings.Count -gt 0) {
    foreach ($warn in $validateResult.Warnings) {
        Write-Host "  WARN: $warn" -ForegroundColor Yellow
    }
}
if (-not $validateResult.Success) {
    foreach ($err in $validateResult.ValidationErrors) {
        Write-Host "  ERROR: $err" -ForegroundColor Red
    }
    Write-Host "ERROR: Test data validation failed. Correct CSV errors before running." -ForegroundColor Red
    Write-SPLog -Message "Test data validation failed with $($validateResult.ValidationErrors.Count) error(s)" `
        -Severity ERROR -Component 'Invoke-GovernanceTest' -Action 'ValidateData' -CorrelationID $correlationID
    exit 3
}
Write-Host "  Validation passed." -ForegroundColor Green
Write-Host ''

# Safety gate: MaxCampaignsPerRun
$maxRun = $config.Safety.MaxCampaignsPerRun
if ($campaigns.Count -gt $maxRun) {
    Write-Host "ERROR: $($campaigns.Count) campaigns selected but Safety.MaxCampaignsPerRun=$maxRun. Reduce your selection or increase the limit in settings.json." -ForegroundColor Red
    exit 2
}

# Run suite
Write-Host '  Running test suite...' -ForegroundColor Cyan
Write-Host "  $('=' * 60)" -ForegroundColor DarkGray

$suiteParams = @{
    Campaigns          = $campaigns
    Identities         = $identities
    CorrelationID      = $correlationID
    WhatIf             = $isWhatIf
    StopOnFirstFailure = $StopOnFirstFailure.IsPresent
}

$suiteResult = Invoke-SPTestSuite @suiteParams

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

# Build summary object
$summary = [PSCustomObject]@{
    CorrelationID   = $correlationID
    StartedAt       = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt     = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds = [math]::Round($runDuration, 2)
    TotalTests      = $campaigns.Count
    PassCount       = $suiteResult.PassCount
    FailCount       = $suiteResult.FailCount
    SkipCount       = $suiteResult.SkipCount
    Success         = $suiteResult.Success
    Results         = $suiteResult.Results
    WhatIf          = $isWhatIf
    Environment     = $config.Global.EnvironmentName
}

# Output results
switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 10
    }
    'Console' {
        Write-Host ''
        Write-Host '  Test Suite Results' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray

        foreach ($testResult in $suiteResult.Results) {
            $statusColor = switch ($true) {
                ($testResult.Pass -eq $true)               { 'Green' }
                ($testResult.Error -and -not $testResult.Pass) { 'Red' }
                default                                    { 'Yellow' }
            }
            $statusLabel = if ($testResult.Pass) { 'PASS' } elseif ($testResult.Error) { 'FAIL' } else { 'SKIP' }
            Write-Host "  [$statusLabel] $($testResult.TestId) - $($testResult.TestName)" -ForegroundColor $statusColor

            if (-not $testResult.Pass -and $testResult.Error) {
                Write-Host "         Error: $($testResult.Error)" -ForegroundColor Red
            }
        }

        Write-Host ''
        Write-Host "  Summary: $($summary.PassCount) PASS / $($summary.FailCount) FAIL / $($summary.SkipCount) SKIP" -ForegroundColor $(if ($suiteResult.Success) { 'Green' } else { 'Red' })
        Write-Host "  Duration: $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  Environment: $($summary.Environment)" -ForegroundColor DarkGray
        Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
        Write-Host ''
    }
    'Both' {
        Write-Host ''
        Write-Host '  Test Suite Results' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray

        foreach ($testResult in $suiteResult.Results) {
            $statusColor = switch ($true) {
                ($testResult.Pass -eq $true)               { 'Green' }
                ($testResult.Error -and -not $testResult.Pass) { 'Red' }
                default                                    { 'Yellow' }
            }
            $statusLabel = if ($testResult.Pass) { 'PASS' } elseif ($testResult.Error) { 'FAIL' } else { 'SKIP' }
            Write-Host "  [$statusLabel] $($testResult.TestId) - $($testResult.TestName)" -ForegroundColor $statusColor

            if (-not $testResult.Pass -and $testResult.Error) {
                Write-Host "         Error: $($testResult.Error)" -ForegroundColor Red
            }
        }

        Write-Host ''
        Write-Host "  Summary: $($summary.PassCount) PASS / $($summary.FailCount) FAIL / $($summary.SkipCount) SKIP" -ForegroundColor $(if ($suiteResult.Success) { 'Green' } else { 'Red' })
        Write-Host "  Duration: $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  JSON Output:' -ForegroundColor Cyan
        $summary | ConvertTo-Json -Depth 10
    }
}

Write-SPLog -Message "Invoke-GovernanceTest completed: $($summary.PassCount) pass, $($summary.FailCount) fail, $($summary.SkipCount) skip" `
    -Severity INFO -Component 'Invoke-GovernanceTest' -Action 'Complete' -CorrelationID $correlationID

# Exit with appropriate code
if ($suiteResult.Success) {
    exit 0
}
else {
    exit 1
}

#endregion

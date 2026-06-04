#Requires -Version 5.1
<#
.SYNOPSIS
    Manages disconnected app registrations in the toolkit configuration.
.DESCRIPTION
    CLI script for managing the Applications array in the DisconnectedApps
    config section of settings.json. Supports four actions:

    - Register:   Add a new app with file paths and optional overrides
    - Unregister: Remove an app from the config (preserves snapshots/reports)
    - List:       Show all registered apps with file status
    - Test:       Run CSV validation on a registered app's current files

.PARAMETER Action
    The operation to perform: Register, Unregister, List, or Test.
.PARAMETER AppName
    Application name. Required for Register, Unregister, and Test actions.
.PARAMETER AccountFilePath
    Path to the account CSV file. Required for Register.
.PARAMETER EntitlementFilePath
    Path to the entitlement CSV file. Optional for Register.
.PARAMETER ISCSourceId
    ISC source ID for the app. Optional for Register.
.PARAMETER CorrelationAttribute
    Correlation attribute override. Optional (defaults to global setting).
.PARAMETER CampaignNamePrefix
    Campaign name prefix override. Optional (defaults to global setting).
.PARAMETER DeadlineDays
    Campaign deadline override in days. Optional (defaults to global setting).
.PARAMETER SlaDays
    SLA days for file delivery monitoring. Optional.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to this script.
.PARAMETER OutputMode
    Console (default): formatted table output.
    JSON: machine-parseable result object.
    Both: console output followed by the JSON object.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPDisconnectedAppRegistry.ps1 -Action List
    # Show all registered apps with file status.
.EXAMPLE
    .\Invoke-SPDisconnectedAppRegistry.ps1 -Action Register -AppName 'IPAY' `
        -AccountFilePath '\\fileserver\imports\IPAY\accounts.csv'
    # Register a new disconnected app.
.EXAMPLE
    .\Invoke-SPDisconnectedAppRegistry.ps1 -Action Test -AppName 'PEP-Plus'
    # Validate the CSV files for PEP-Plus without creating campaigns.
.EXAMPLE
    .\Invoke-SPDisconnectedAppRegistry.ps1 -Action Unregister -AppName 'IPAY'
    # Remove IPAY from the registry (snapshots and reports are preserved).
.NOTES
    Script:  Invoke-SPDisconnectedAppRegistry.ps1
    Version: 1.0.0
    Exit codes:
        0 = Success
        1 = No registered apps found (List) or validation warnings (Test)
        2 = Parameter error
        4 = Configuration error
        5 = Validation failure
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Register', 'Unregister', 'List', 'Test')]
    [string]$Action,

    [Parameter()]
    [string]$AppName,

    [Parameter()]
    [string]$AccountFilePath,

    [Parameter()]
    [string]$EntitlementFilePath,

    [Parameter()]
    [string]$ISCSourceId,

    [Parameter()]
    [string]$CorrelationAttribute,

    [Parameter()]
    [string]$CampaignNamePrefix,

    [Parameter()]
    [int]$DeadlineDays = 0,

    [Parameter()]
    [int]$SlaDays = 0,

    [Parameter()]
    [string]$ConfigPath,

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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';                         Name = 'SP.Core';             Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DisconnectedApps\SP.DisconnectedApps.psd1';  Name = 'SP.DisconnectedApps'; Required = $true  }
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

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Disconnected App Registry' -ForegroundColor Cyan
Write-Host "  Action:  $Action" -ForegroundColor Cyan
Write-Host ''

# Validate AppName is provided for actions that require it
if ($Action -ne 'List' -and [string]::IsNullOrWhiteSpace($AppName)) {
    Write-Host "ERROR: -AppName is required for the '$Action' action." -ForegroundColor Red
    exit 2
}

# Validate AccountFilePath is provided for Register
if ($Action -eq 'Register' -and [string]::IsNullOrWhiteSpace($AccountFilePath)) {
    Write-Host 'ERROR: -AccountFilePath is required for the Register action.' -ForegroundColor Red
    exit 2
}

#endregion

#region Helper: Read/Write Config JSON

function Read-SettingsJson {
    param([string]$Path)
    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Settings file not found: $Path"
    }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Write-SettingsJson {
    param(
        [string]$Path,
        [object]$Config
    )
    $json = $Config | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

#endregion

#region Action: Register

if ($Action -eq 'Register') {
    Write-Host "  Registering app: $AppName" -ForegroundColor Cyan

    # Load raw config JSON
    $rawConfig = $null
    try {
        $rawConfig = Read-SettingsJson -Path $ConfigPath
    }
    catch {
        Write-Host "ERROR: Failed to load config: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }

    # Ensure DisconnectedApps.Applications exists
    if ($null -eq $rawConfig.DisconnectedApps) {
        Write-Host 'ERROR: DisconnectedApps section not found in settings.json.' -ForegroundColor Red
        exit 4
    }

    $daSection = $rawConfig.DisconnectedApps

    # Ensure Applications array exists
    $apps = @()
    if ($null -ne $daSection.PSObject.Properties['Applications'] -and $null -ne $daSection.Applications) {
        $apps = @($daSection.Applications)
    }

    # Duplicate check
    $existing = $apps | Where-Object { $null -ne $_ -and $_.Name -eq $AppName }
    if ($null -ne $existing) {
        Write-Host "ERROR: App '$AppName' is already registered. Use Unregister first to re-register." -ForegroundColor Red
        exit 2
    }

    # Build new app entry
    $newApp = [ordered]@{
        Name                 = $AppName
        AccountFilePath      = $AccountFilePath
        EntitlementFilePath  = if (-not [string]::IsNullOrWhiteSpace($EntitlementFilePath)) { $EntitlementFilePath } else { '' }
        ISCSourceId          = if (-not [string]::IsNullOrWhiteSpace($ISCSourceId)) { $ISCSourceId } else { '' }
        CorrelationAttribute = if (-not [string]::IsNullOrWhiteSpace($CorrelationAttribute)) { $CorrelationAttribute } else { 'e-mail' }
        CampaignNamePrefix   = if (-not [string]::IsNullOrWhiteSpace($CampaignNamePrefix)) { $CampaignNamePrefix } else { "$AppName Cert" }
        DeadlineDays         = if ($DeadlineDays -gt 0) { $DeadlineDays } else { 2 }
        SlaDays              = if ($SlaDays -gt 0) { $SlaDays } else { 1 }
        Enabled              = $true
    }

    # Add to array
    $updatedApps = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $apps) {
        if ($null -ne $a) { $updatedApps.Add($a) }
    }
    $updatedApps.Add([PSCustomObject]$newApp)

    # Update config and write back
    $daSection | Add-Member -NotePropertyName 'Applications' -NotePropertyValue $updatedApps.ToArray() -Force
    try {
        Write-SettingsJson -Path $ConfigPath -Config $rawConfig
    }
    catch {
        Write-Host "ERROR: Failed to write config: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }

    # Create directories for the new app
    $initResult = Initialize-SPDisconnectedAppDirectories -AppNames @($AppName) -ConfigPath $ConfigPath
    $dirsCreated = 0
    if ($initResult.Success -and $null -ne $initResult.Data) {
        $dirsCreated = @($initResult.Data.DirectoriesCreated).Count
    }

    Write-Host ''
    Write-Host "  App '$AppName' registered successfully." -ForegroundColor Green
    Write-Host "    AccountFilePath:  $AccountFilePath" -ForegroundColor DarkGray
    if (-not [string]::IsNullOrWhiteSpace($EntitlementFilePath)) {
        Write-Host "    EntitlementFile:  $EntitlementFilePath" -ForegroundColor DarkGray
    }
    Write-Host "    Directories:      $dirsCreated created" -ForegroundColor DarkGray
    Write-Host ''

    Write-SPLog -Message "Registered disconnected app '$AppName' (AccountFilePath=$AccountFilePath)" `
        -Severity INFO -Component 'Invoke-SPDisconnectedAppRegistry' -Action 'Register'

    if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
        $result = [PSCustomObject]@{
            Action    = 'Register'
            AppName   = $AppName
            Success   = $true
            AppConfig = $newApp
        }
        $result | ConvertTo-Json -Depth 5
    }

    exit 0
}

#endregion

#region Action: Unregister

if ($Action -eq 'Unregister') {
    Write-Host "  Unregistering app: $AppName" -ForegroundColor Cyan

    $rawConfig = $null
    try {
        $rawConfig = Read-SettingsJson -Path $ConfigPath
    }
    catch {
        Write-Host "ERROR: Failed to load config: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }

    if ($null -eq $rawConfig.DisconnectedApps) {
        Write-Host 'ERROR: DisconnectedApps section not found in settings.json.' -ForegroundColor Red
        exit 4
    }

    $daSection = $rawConfig.DisconnectedApps

    $apps = @()
    if ($null -ne $daSection.PSObject.Properties['Applications'] -and $null -ne $daSection.Applications) {
        $apps = @($daSection.Applications)
    }

    # Check app exists
    $existing = $apps | Where-Object { $null -ne $_ -and $_.Name -eq $AppName }
    if ($null -eq $existing) {
        Write-Host "ERROR: App '$AppName' is not registered." -ForegroundColor Red
        exit 2
    }

    # Remove from array
    $updatedApps = @($apps | Where-Object { $null -eq $_ -or $_.Name -ne $AppName })

    $daSection | Add-Member -NotePropertyName 'Applications' -NotePropertyValue $updatedApps -Force

    try {
        Write-SettingsJson -Path $ConfigPath -Config $rawConfig
    }
    catch {
        Write-Host "ERROR: Failed to write config: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }

    Write-Host ''
    Write-Host "  App '$AppName' unregistered." -ForegroundColor Green
    Write-Host '  Note: Snapshot and report files were NOT deleted.' -ForegroundColor Yellow
    Write-Host ''

    Write-SPLog -Message "Unregistered disconnected app '$AppName'" `
        -Severity INFO -Component 'Invoke-SPDisconnectedAppRegistry' -Action 'Unregister'

    if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
        $result = [PSCustomObject]@{
            Action  = 'Unregister'
            AppName = $AppName
            Success = $true
        }
        $result | ConvertTo-Json -Depth 5
    }

    exit 0
}

#endregion

#region Action: List

if ($Action -eq 'List') {
    Write-Host '  Registered Disconnected Apps' -ForegroundColor Cyan
    Write-Host ''

    $config = $null
    try {
        $config = Get-SPConfig -ConfigPath $ConfigPath
    }
    catch {
        Write-Host "ERROR: Failed to load config: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }

    $daConfig = $null
    if ($null -ne $config.PSObject.Properties['DisconnectedApps'] -and $null -ne $config.DisconnectedApps) {
        $daConfig = $config.DisconnectedApps
    }

    if ($null -eq $daConfig -or $null -eq $daConfig.PSObject.Properties['Applications']) {
        Write-Host '  No Applications array found in DisconnectedApps config.' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }

    $allApps = @($daConfig.Applications)
    if ($allApps.Count -eq 0) {
        Write-Host '  No apps registered.' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }

    $snapshotBase = '.\DisconnectedApps\Snapshots'
    if ($null -ne $daConfig.PSObject.Properties['SnapshotPath'] -and
        -not [string]::IsNullOrWhiteSpace($daConfig.SnapshotPath)) {
        $snapshotBase = [string]$daConfig.SnapshotPath
    }

    $listData = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($app in $allApps) {
        if ($null -eq $app) { continue }

        $name    = if ($null -ne $app.PSObject.Properties['Name']) { [string]$app.Name } else { '(unnamed)' }
        $enabled = $true
        if ($null -ne $app.PSObject.Properties['Enabled']) {
            $enabled = [bool]$app.Enabled
        }

        $acctPath   = if ($null -ne $app.PSObject.Properties['AccountFilePath']) { [string]$app.AccountFilePath } else { '' }
        $fileStatus = 'Unknown'

        if ([string]::IsNullOrWhiteSpace($acctPath)) {
            $fileStatus = 'No Path'
        }
        elseif (-not (Test-Path -Path $acctPath -PathType Leaf)) {
            $fileStatus = 'Missing'
        }
        else {
            try {
                $fileInfo = Get-Item -Path $acctPath -ErrorAction Stop
                if ($fileInfo.Length -eq 0) {
                    $fileStatus = 'Empty'
                }
                else {
                    $ageHours = ((Get-Date) - $fileInfo.LastWriteTime).TotalHours
                    if ($ageHours -le 24) {
                        $fileStatus = 'Current'
                    }
                    else {
                        $fileStatus = 'Stale'
                    }
                }
            }
            catch {
                $fileStatus = 'Error'
            }
        }

        # Find last processed date from snapshots
        $lastProcessed = '--'
        $appSnapshotDir = Join-Path -Path $snapshotBase -ChildPath $name
        if (Test-Path -Path $appSnapshotDir -PathType Container) {
            $snapshots = Get-ChildItem -Path $appSnapshotDir -Filter '*-accounts.csv' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                Select-Object -First 1
            if ($null -ne $snapshots) {
                # Extract date from filename pattern: YYYY-MM-DD-accounts.csv
                if ($snapshots.Name -match '^(\d{4}-\d{2}-\d{2})-accounts\.csv$') {
                    $lastProcessed = $Matches[1]
                }
            }
        }

        $listData.Add([PSCustomObject]@{
            Name          = $name
            Enabled       = if ($enabled) { 'Yes' } else { 'No' }
            AccountPath   = $acctPath
            FileStatus    = $fileStatus
            LastProcessed = $lastProcessed
        })
    }

    # Console output
    if ($OutputMode -ne 'JSON') {
        # Calculate column widths
        $nameWidth   = [Math]::Max(4, ($listData | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
        $nameWidth   = [Math]::Min($nameWidth, 25)
        $statusWidth = 10
        $enabledWidth = 7
        $lastWidth   = 12

        $headerFmt = "  {0,-$nameWidth}  {1,-$enabledWidth}  {2,-$statusWidth}  {3,-$lastWidth}  {4}"
        $header = $headerFmt -f 'Name', 'Enabled', 'FileStatus', 'LastRun', 'AccountPath'
        Write-Host $header -ForegroundColor White
        Write-Host "  $('-' * ($header.Length - 2))" -ForegroundColor DarkGray

        foreach ($item in $listData) {
            $statusColor = switch ($item.FileStatus) {
                'Current'  { 'Green' }
                'Stale'    { 'Yellow' }
                'Missing'  { 'Red' }
                'Empty'    { 'Red' }
                'Error'    { 'Red' }
                'No Path'  { 'DarkGray' }
                default    { 'DarkGray' }
            }

            $displayName = $item.Name
            if ($displayName.Length -gt $nameWidth) {
                $displayName = $displayName.Substring(0, $nameWidth - 2) + '..'
            }

            $line = $headerFmt -f $displayName, $item.Enabled, $item.FileStatus, $item.LastProcessed, $item.AccountPath
            Write-Host $line -ForegroundColor $statusColor
        }

        Write-Host ''
        Write-Host "  Total: $($listData.Count) app(s)" -ForegroundColor DarkGray
        Write-Host ''
    }

    if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
        $result = [PSCustomObject]@{
            Action = 'List'
            Apps   = $listData
            Total  = $listData.Count
        }
        $result | ConvertTo-Json -Depth 5
    }

    exit 0
}

#endregion

#region Action: Test

if ($Action -eq 'Test') {
    Write-Host "  Testing app: $AppName" -ForegroundColor Cyan
    Write-Host ''

    # Load config and find the app
    $config = $null
    try {
        $config = Get-SPConfig -ConfigPath $ConfigPath
    }
    catch {
        Write-Host "ERROR: Failed to load config: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }

    $appsResult = Get-SPRegisteredApps -ConfigPath $ConfigPath
    if (-not $appsResult.Success) {
        Write-Host "ERROR: Failed to load registered apps: $($appsResult.Error)" -ForegroundColor Red
        exit 4
    }

    $appConfig = $appsResult.Data | Where-Object { $_.Name -eq $AppName }
    if ($null -eq $appConfig) {
        # Check if it exists but is disabled
        $daConfig = $config.DisconnectedApps
        $allApps = @()
        if ($null -ne $daConfig.PSObject.Properties['Applications']) {
            $allApps = @($daConfig.Applications)
        }
        $disabledMatch = $allApps | Where-Object { $null -ne $_ -and $_.Name -eq $AppName }
        if ($null -ne $disabledMatch) {
            Write-Host "ERROR: App '$AppName' is registered but disabled." -ForegroundColor Red
        }
        else {
            Write-Host "ERROR: App '$AppName' is not registered. Use -Action Register first." -ForegroundColor Red
        }
        exit 2
    }

    $testErrors   = [System.Collections.Generic.List[string]]::new()
    $testWarnings = [System.Collections.Generic.List[string]]::new()
    $testResults  = [ordered]@{}

    # --- Test 1: Account file path ---
    Write-Host '  1. Checking account file path...' -ForegroundColor Cyan
    $acctPath = $appConfig.AccountFilePath
    if ([string]::IsNullOrWhiteSpace($acctPath)) {
        $testErrors.Add('AccountFilePath is empty in config.')
        $testResults['AccountFileExists'] = $false
        Write-Host '     FAIL: AccountFilePath is empty.' -ForegroundColor Red
    }
    elseif (-not (Test-Path -Path $acctPath -PathType Leaf)) {
        $testErrors.Add("Account file not found: $acctPath")
        $testResults['AccountFileExists'] = $false
        Write-Host "     FAIL: File not found: $acctPath" -ForegroundColor Red
    }
    else {
        $testResults['AccountFileExists'] = $true
        Write-Host "     OK:   $acctPath" -ForegroundColor Green
    }

    # --- Test 2: Account file validation ---
    if ($testResults['AccountFileExists'] -eq $true) {
        Write-Host '  2. Validating account CSV...' -ForegroundColor Cyan
        $acctValidation = Test-SPDisconnectedAppAccountFile -FilePath $acctPath
        $testResults['AccountValidation'] = $acctValidation.Success

        if ($acctValidation.Success) {
            $acctData = $acctValidation.Data
            Write-Host "     OK:   $($acctData.RowCount) rows ($($acctData.ValidRows) valid)" -ForegroundColor Green
            $testResults['AccountRowCount'] = $acctData.RowCount

            if ($acctData.Warnings.Count -gt 0) {
                foreach ($w in $acctData.Warnings) {
                    $testWarnings.Add("Account: $w")
                    Write-Host "     WARN: $w" -ForegroundColor Yellow
                }
            }
        }
        else {
            $testErrors.Add("Account validation failed: $($acctValidation.Error)")
            Write-Host "     FAIL: $($acctValidation.Error)" -ForegroundColor Red
            if ($null -ne $acctValidation.Data -and $null -ne $acctValidation.Data.Errors) {
                foreach ($e in $acctValidation.Data.Errors) {
                    Write-Host "           $e" -ForegroundColor Yellow
                }
            }
        }
    }
    else {
        Write-Host '  2. Skipping account validation (file not found).' -ForegroundColor DarkGray
        $testResults['AccountValidation'] = $false
    }

    # --- Test 3: Entitlement file path ---
    $entPath = $appConfig.EntitlementFilePath
    $hasEntitlementFile = (-not [string]::IsNullOrWhiteSpace($entPath))

    if ($hasEntitlementFile) {
        Write-Host '  3. Checking entitlement file path...' -ForegroundColor Cyan
        if (-not (Test-Path -Path $entPath -PathType Leaf)) {
            $testWarnings.Add("Entitlement file not found: $entPath")
            $testResults['EntitlementFileExists'] = $false
            Write-Host "     WARN: File not found: $entPath" -ForegroundColor Yellow
            $hasEntitlementFile = $false
        }
        else {
            $testResults['EntitlementFileExists'] = $true
            Write-Host "     OK:   $entPath" -ForegroundColor Green
        }
    }
    else {
        Write-Host '  3. No entitlement file configured (skipping).' -ForegroundColor DarkGray
        $testResults['EntitlementFileExists'] = $null
    }

    # --- Test 4: Entitlement file validation ---
    if ($hasEntitlementFile -and $testResults['EntitlementFileExists'] -eq $true) {
        Write-Host '  4. Validating entitlement CSV...' -ForegroundColor Cyan
        $entValidation = Test-SPDisconnectedAppEntitlementFile -FilePath $entPath
        $testResults['EntitlementValidation'] = $entValidation.Success

        if ($entValidation.Success) {
            $entData = $entValidation.Data
            Write-Host "     OK:   $($entData.RowCount) rows ($($entData.ValidRows) valid)" -ForegroundColor Green
            $testResults['EntitlementRowCount'] = $entData.RowCount
        }
        else {
            $testErrors.Add("Entitlement validation failed: $($entValidation.Error)")
            Write-Host "     FAIL: $($entValidation.Error)" -ForegroundColor Red
        }
    }
    else {
        Write-Host '  4. Skipping entitlement validation.' -ForegroundColor DarkGray
        $testResults['EntitlementValidation'] = $null
    }

    # --- Test 5: Cross-reference ---
    if ($testResults['AccountFileExists'] -eq $true -and
        $testResults['AccountValidation'] -eq $true -and
        $hasEntitlementFile -and
        $testResults['EntitlementFileExists'] -eq $true -and
        $testResults['EntitlementValidation'] -eq $true) {

        Write-Host '  5. Cross-referencing accounts vs entitlements...' -ForegroundColor Cyan
        $crossRef = Test-SPDisconnectedAppCrossReference -AccountFilePath $acctPath `
            -EntitlementFilePath $entPath
        $testResults['CrossReference'] = $crossRef.Success

        if ($crossRef.Success) {
            $orphanCount = @($crossRef.Data.OrphanedEntitlements).Count
            Write-Host "     OK:   All group references match entitlement definitions." -ForegroundColor Green
            if ($orphanCount -gt 0) {
                $testWarnings.Add("$orphanCount orphaned entitlement(s) not referenced by any account.")
                Write-Host "     WARN: $orphanCount orphaned entitlement(s)." -ForegroundColor Yellow
            }
        }
        else {
            $unmatchedCount = @($crossRef.Data.UnmatchedGroups).Count
            $testErrors.Add("$unmatchedCount unmatched group reference(s).")
            Write-Host "     FAIL: $unmatchedCount unmatched group reference(s)." -ForegroundColor Red
            foreach ($ug in $crossRef.Data.UnmatchedGroups) {
                Write-Host "           Account '$($ug.AccountId)' -> '$($ug.EntitlementId)'" -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host '  5. Skipping cross-reference (missing files or validation failures).' -ForegroundColor DarkGray
        $testResults['CrossReference'] = $null
    }

    # --- Summary ---
    Write-Host ''
    $overallPass = ($testErrors.Count -eq 0)

    if ($overallPass) {
        if ($testWarnings.Count -gt 0) {
            Write-Host "  Result: PASS with $($testWarnings.Count) warning(s)" -ForegroundColor Yellow
        }
        else {
            Write-Host '  Result: PASS' -ForegroundColor Green
        }
    }
    else {
        Write-Host "  Result: FAIL ($($testErrors.Count) error(s), $($testWarnings.Count) warning(s))" -ForegroundColor Red
    }
    Write-Host ''

    if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
        $result = [PSCustomObject]@{
            Action   = 'Test'
            AppName  = $AppName
            Success  = $overallPass
            Tests    = $testResults
            Errors   = $testErrors.ToArray()
            Warnings = $testWarnings.ToArray()
        }
        $result | ConvertTo-Json -Depth 5
    }

    if (-not $overallPass) {
        exit 5
    }
    elseif ($testWarnings.Count -gt 0) {
        exit 1
    }

    exit 0
}

#endregion

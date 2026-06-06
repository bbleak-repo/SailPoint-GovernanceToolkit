#Requires -Version 5.1
<#
.SYNOPSIS
    Launches the SailPoint ISC Governance Toolkit WPF dashboard.
.DESCRIPTION
    Loads the SP.Core and SP.Gui modules, then calls Show-SPDashboard to display
    the WPF interactive interface. The dashboard provides campaign management,
    evidence review, and settings configuration through a tabbed UI.

    Requirements:
      - Windows (WPF is Windows-only)
      - PowerShell 5.1 Desktop edition (not Core/7+; pwsh does not ship WPF)
      - .NET Framework 4.8 or later (pre-installed on Windows 10 1903+ and Windows 11)
      - Configured settings.json (run Invoke-GovernanceTest.ps1 once to generate)
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to the
    Scripts directory. Passed through to the GUI module.
.EXAMPLE
    .\Show-SPDashboard.ps1
    # Launch the GUI with default settings
.EXAMPLE
    .\Show-SPDashboard.ps1 -ConfigPath 'C:\Toolkit\Config\prod-settings.json'
    # Launch the GUI pointed at a specific configuration file
.NOTES
    Script:  Show-SPDashboard.ps1
    Version: 1.0.0
    Note:    WPF requires a Single-Threaded Apartment (STA) thread. This script
             detects the current apartment state and re-launches in STA if needed.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [Alias('?')]
    [switch]$Help,

    # Internal switch -- set automatically by the parent launcher when it
    # spawns the isolated child process. End-users should NOT pass this
    # manually. Advanced users debugging inside PowerShell ISE may pass it
    # to run in-process, but that re-introduces WPF's once-per-AppDomain
    # Application-singleton trap after the first window close.
    [Parameter()]
    [switch]$NoIsolation
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

#region Pre-flight checks (OS / PSEdition / .NET Framework)
# These run in the parent process on every launch so the user gets a clear,
# actionable message instead of a cryptic assembly-load failure deep in the stack.

# 1. Windows-only: WPF assemblies don't exist on macOS or Linux.
if ($env:OS -ne 'Windows_NT') {
    Write-Host ("ERROR: The dashboard requires Windows. " +
                "WPF is a Windows-only framework and is not available on this OS ($($PSVersionTable.OS)).") `
               -ForegroundColor Red
    exit 1
}

# 2. PowerShell Desktop edition: pwsh (Core/7+) does not ship WPF assemblies.
#    #Requires -Version 5.1 already enforces the minimum version number, but it
#    passes on pwsh 7.x which also satisfies ">= 5.1".
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Host ("ERROR: The dashboard requires Windows PowerShell 5.1 (Desktop edition). " +
                "You are running PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)). " +
                "Run 'powershell.exe' (not 'pwsh') to use the Desktop edition.") `
               -ForegroundColor Red
    exit 1
}

# 3. .NET Framework >= 4.8 (release key >= 528040).
#    All WPF APIs we use exist since .NET 3.0, so there is no hard API floor.
#    4.8 is chosen because it ships pre-installed on every Windows 10 1903+
#    (May 2019) and all Windows 11 machines -- the realistic enterprise target
#    for this toolkit. Requiring 4.8 means users never need to install anything
#    on a modern system; we surface a clear error on the rare older machine.
#    Release key reference: https://learn.microsoft.com/dotnet/framework/migration-guide/versions-and-dependencies
$netRegPath = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
$netRelease  = $null
try {
    $netRelease = (Get-ItemProperty -Path $netRegPath -Name Release -ErrorAction Stop).Release
} catch { }

if ($null -eq $netRelease) {
    Write-Host ("ERROR: .NET Framework 4.x was not found in the registry ($netRegPath). " +
                "Install .NET Framework 4.8 and try again.") `
               -ForegroundColor Red
    exit 1
}

if ($netRelease -lt 528040) {
    # Map release key to a human-readable version for the error message.
    $netVer = switch ($netRelease) {
        { $_ -ge 461808 } { '4.7.2' }
        { $_ -ge 461308 } { '4.7.1' }
        { $_ -ge 460798 } { '4.7' }
        { $_ -ge 394802 } { '4.6.2' }
        { $_ -ge 394254 } { '4.6.1' }
        default            { "unknown (release=$netRelease)" }
    }
    Write-Host ("ERROR: .NET Framework 4.8 is required for the dashboard. " +
                "Detected version: $netVer (release key $netRelease). " +
                "Download .NET Framework 4.8 from https://dotnet.microsoft.com/download/dotnet-framework") `
               -ForegroundColor Red
    exit 1
}

#endregion

#region Process Isolation

# WPF requires STA, AND [System.Windows.Application] is a once-per-AppDomain
# singleton for the entire life of the host process: once you close the
# dashboard window in a given PowerShell session, you cannot launch it
# again in that same session (the Application instance stays registered
# in a shutdown state and cannot be recreated).
#
# The robust fix is to always run the dashboard in a brand-new child
# powershell.exe so every launch starts from a clean AppDomain regardless
# of whether the caller's shell is MTA (regular powershell.exe), STA
# (PowerShell ISE, -STA-flagged terminal), or has previously launched the
# dashboard. The parent acts purely as a fire-and-forget wrapper that
# waits for the child to exit and forwards its exit code.
#
# The -NoIsolation switch is the recursion sentinel: parent invocations
# omit it; child invocations carry it (set automatically below) and skip
# this block to do the actual work.

if (-not $NoIsolation) {
    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        Write-Host "ERROR: Cannot determine script path for child-process launch." -ForegroundColor Red
        exit 1
    }

    Write-Host "  INFO: Launching dashboard in isolated STA child process..." -ForegroundColor Cyan

    $relaunchArgs = @(
        '-STA',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$scriptPath`"",
        '-NoIsolation'
    )
    if ($ConfigPath) {
        $relaunchArgs += @('-ConfigPath', "`"$ConfigPath`"")
    }

    Start-Process powershell.exe -ArgumentList $relaunchArgs -Wait -NoNewWindow
    exit $LASTEXITCODE
}

# Past this point we are the isolated child (or someone bypassed
# isolation manually). WPF still requires STA; verify and fail clearly
# if the caller passed -NoIsolation from a non-STA shell.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Host ("ERROR: Show-SPDashboard requires STA apartment state. " +
                "Remove the -NoIsolation switch (recommended -- the launcher " +
                "will spawn an STA child for you), or launch powershell.exe " +
                "with -STA before re-running.") -ForegroundColor Red
    exit 1
}

#endregion

#region Module Load

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$toolkitRoot = Split-Path -Parent $scriptRoot

$coreModulePath  = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
$apiModulePath   = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1'
$auditModulePath = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'
$sdkModulePath   = Join-Path $toolkitRoot 'Modules\SP.Sdk\SP.Sdk.psd1'
$guiModulePath   = Join-Path $toolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'
$deltaCertModulePath        = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'
$reportComponentsModulePath = Join-Path $toolkitRoot 'Modules\SP.ReportComponents\SP.ReportComponents.psd1'
$adaptiveReportsModulePath  = Join-Path $toolkitRoot 'Modules\SP.AdaptiveReports\SP.AdaptiveReports.psd1'

foreach ($moduleDef in @(
    @{ Path = $coreModulePath;  Name = 'SP.Core';  Required = $true },
    @{ Path = $apiModulePath;   Name = 'SP.Api';   Required = $true },
    @{ Path = $auditModulePath; Name = 'SP.Audit'; Required = $true },
    @{ Path = $deltaCertModulePath;        Name = 'SP.DeltaCert';        Required = $true },
    @{ Path = $reportComponentsModulePath; Name = 'SP.ReportComponents'; Required = $true },
    @{ Path = $adaptiveReportsModulePath;  Name = 'SP.AdaptiveReports';  Required = $true },
    @{ Path = $sdkModulePath;   Name = 'SP.Sdk';   Required = $true },
    @{ Path = $guiModulePath;   Name = 'SP.Gui';   Required = $true }
)) {
    if (Test-Path $moduleDef.Path) {
        Import-Module $moduleDef.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        $moduleDir = Split-Path -Parent $moduleDef.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
            }
        }
        elseif ($moduleDef.Required) {
            Write-Host "ERROR: Required module '$($moduleDef.Name)' not found at: $($moduleDef.Path)" -ForegroundColor Red
            exit 1
        }
    }
}

#endregion

#region Launch GUI

$dashboardParams = @{}
if ($ConfigPath) {
    $dashboardParams['ConfigPath'] = $ConfigPath
}

try {
    Show-SPDashboard @dashboardParams
}
catch {
    Write-Host ''
    Write-Host "ERROR: Dashboard failed to launch: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 1
}

#endregion

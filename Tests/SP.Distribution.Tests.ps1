#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    DIST-01..04 -- distributable zip smoke tests.
.DESCRIPTION
    Guards against the class of bug where a packaged zip cannot initialize from
    a clean extract (e.g. a flattened layout that breaks the launcher's
    toolkit-root path math). For each zip produced by build-dist.ps1 it:

      1. Builds the zip fresh into $TestDrive.
      2. Extracts it.
      3. Derives the toolkit root EXACTLY as Show-SPDashboard.ps1 does
         (parent of the launcher's \Scripts dir).
      4. In a clean child powershell.exe, imports SP.Core from that root and
         loads Config\settings.json via Get-SPConfig -- the real startup path.

    If a future change flattens the layout or moves modules/config, step 3/4
    fails and this test goes red.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:BuildScript = Join-Path $script:RepoRoot 'build-dist.ps1'
    $script:DistDir = Join-Path $TestDrive 'dist'
    New-Item -ItemType Directory -Path $script:DistDir -Force | Out-Null

    # Build both zips from the current working tree into the test sandbox.
    & $script:BuildScript -OutputDir $script:DistDir | Out-Null

    # Child-process startup probe: import SP.Core + load config the way the app does.
    $script:ProbePath = Join-Path $TestDrive 'probe.ps1'
    # Import every module the launcher (Show-SPDashboard.ps1) loads as Required,
    # not just SP.Core -- so a module that fails to parse/import (e.g. a bad
    # string interpolation) fails the packaged-zip test instead of slipping
    # through to the end user.
    Set-Content -Path $script:ProbePath -Encoding UTF8 -Value @'
param([Parameter(Mandatory)][string]$ToolkitRoot)
$ErrorActionPreference = 'Stop'
try {
    foreach ($m in 'SP.Core\SP.Core.psd1', 'SP.Api\SP.Api.psd1', 'SP.Audit\SP.Audit.psd1', 'SP.Gui\SP.Gui.psd1') {
        Import-Module (Join-Path $ToolkitRoot "Modules\$m") -Force
    }
    $cfg = Get-SPConfig -ConfigPath (Join-Path $ToolkitRoot 'Config\settings.json') -Force
    if ($null -eq $cfg) { exit 3 }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@

    function Expand-Dist {
        param([string]$ZipName)
        $dest = Join-Path $TestDrive ([IO.Path]::GetFileNameWithoutExtension($ZipName))
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Expand-Archive -Path (Join-Path $script:DistDir $ZipName) -DestinationPath $dest -Force
        return $dest
    }

    # Mirror Show-SPDashboard.ps1: $toolkitRoot = Split-Path -Parent (dir of the launcher).
    function Resolve-ToolkitRoot {
        param([string]$ExtractRoot)
        $launcher = Get-ChildItem -Path $ExtractRoot -Recurse -Filter 'Show-SPDashboard.ps1' | Select-Object -First 1
        if (-not $launcher) { return $null }
        return (Split-Path -Parent (Split-Path -Parent $launcher.FullName))
    }

    function Invoke-StartupProbe {
        param([string]$ToolkitRoot)
        $ps = (Get-Command powershell.exe).Source
        $p = Start-Process -FilePath $ps -PassThru -Wait -NoNewWindow `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script:ProbePath`"", '-ToolkitRoot', "`"$ToolkitRoot`"")
        return $p.ExitCode
    }
}

Describe "DIST: user-handoff zip initializes from a clean extract" {
    BeforeAll {
        $script:UserRoot = Expand-Dist 'SailPoint-GovernanceToolkit-UserHandoff.zip'
        $script:UserToolkitRoot = Resolve-ToolkitRoot $script:UserRoot
    }

    It "DIST-01: places the launcher so the toolkit root resolves to a real tree" {
        $script:UserToolkitRoot | Should -Not -BeNullOrEmpty
        (Join-Path $script:UserToolkitRoot 'Modules\SP.Core\SP.Core.psd1') | Should -Exist
        (Join-Path $script:UserToolkitRoot 'Config\settings.json')         | Should -Exist
        (Join-Path $script:UserToolkitRoot 'Gui\MainWindow.xaml')          | Should -Exist
    }

    It "DIST-02: imports all required modules and loads config in a clean session (exit 0)" {
        Invoke-StartupProbe -ToolkitRoot $script:UserToolkitRoot | Should -Be 0
    }

    It "DIST-03: ships user docs but excludes dev/test files" {
        (Join-Path $script:UserRoot 'USER-GUIDE.html') | Should -Exist
        (Join-Path $script:UserRoot 'Tests')           | Should -Not -Exist
        (Join-Path $script:UserRoot 'DEV.md')          | Should -Not -Exist
    }
}

Describe "DIST: portable zip initializes from a clean extract" {
    BeforeAll {
        $script:PortRoot = Expand-Dist 'SailPoint-GovernanceToolkit.zip'
        $script:PortToolkitRoot = Resolve-ToolkitRoot $script:PortRoot
    }

    It "DIST-04: launcher root resolves and a clean session initializes (exit 0)" {
        $script:PortToolkitRoot | Should -Not -BeNullOrEmpty
        (Join-Path $script:PortToolkitRoot 'Modules\SP.Core\SP.Core.psd1') | Should -Exist
        Invoke-StartupProbe -ToolkitRoot $script:PortToolkitRoot | Should -Be 0
    }

    It "DIST-05: includes the unit tests (portable/full bundle)" {
        (Join-Path $script:PortRoot 'Tests\Import-TestModules.ps1') | Should -Exist
    }
}

Describe "DIST: shipped settings.json template integrity" {
    BeforeAll {
        # Clean child session so the once-per-session unknown-key warning cache
        # cannot mask drift. Exit code = number of warnings (0 = clean).
        $script:CfgProbe = Join-Path $TestDrive 'cfgprobe.ps1'
        Set-Content -Path $script:CfgProbe -Encoding UTF8 -Value @'
param([Parameter(Mandatory)][string]$RepoRoot)
Import-Module (Join-Path $RepoRoot 'Modules\SP.Core\SP.Config.psm1') -Force -DisableNameChecking
$w = @()
$cfg = Get-SPConfig -ConfigPath (Join-Path $RepoRoot 'Config\settings.json') -Force -WarningVariable +w -WarningAction SilentlyContinue
if ($w.Count -ne 0) { [Console]::Error.WriteLine(($w -join ' | ')); exit $w.Count }
if (-not (Test-SPConfigFirstRun -Config $cfg)) { exit 250 }  # template must still read as first-run
exit 0
'@
    }

    It "DIST-06: template loads with zero unknown-key warnings and is still first-run" {
        $ps = (Get-Command powershell.exe).Source
        $p = Start-Process -FilePath $ps -PassThru -Wait -NoNewWindow `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script:CfgProbe`"", '-RepoRoot', "`"$script:RepoRoot`"")
        $p.ExitCode | Should -Be 0
    }
}

#Requires -Version 5.1
<#
.SYNOPSIS
    FlaUI-based WPF test harness for the SailPoint Governance Toolkit.

.DESCRIPTION
    Launches the dashboard as a real visible WPF window in a child STA
    PowerShell process and lets the caller drive it via UI Automation
    (find controls by AutomationId or Name, click them, read values,
    capture screenshots).

    Designed to be loaded once per round by the windows-gui-tests loop:
        Import-Module $PSScriptRoot\SP.UiTest.psm1 -Force

.EXAMPLE
    $ui = Start-SPDashboardForTest -ConfigPath C:\...\Config\test-settings.json
    try {
        $tab = Find-SPUiTab -Window $ui.Window -Header 'Settings'
        $tab.Click()
        Save-SPUiScreenshot -Window $ui.Window -Path C:\...\settings-tab.png
    }
    finally {
        Stop-SPDashboardForTest -UiContext $ui
    }
#>

$ErrorActionPreference = 'Stop'

# ---------- FlaUI assembly loading (idempotent) ----------

$script:UiTestRoot   = $PSScriptRoot
$script:ToolkitRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:FlaUIDir     = Join-Path $script:ToolkitRoot 'Tests\Tools\FlaUI'

function Initialize-SPUiAutomation {
    <#
    .SYNOPSIS
        Loads the vendored FlaUI DLLs into the current AppDomain.
        Safe to call multiple times.
    #>
    [CmdletBinding()]
    param()

    if ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'FlaUI.Core' }) {
        return
    }

    $dlls = @(
        'Interop.UIAutomationClient.dll',
        'FlaUI.Core.dll',
        'FlaUI.UIA3.dll'
    )
    foreach ($dll in $dlls) {
        $path = Join-Path $script:FlaUIDir $dll
        if (-not (Test-Path $path)) {
            throw "FlaUI vendor DLL not found: $path"
        }
        Add-Type -Path $path
    }
}

# ---------- Dashboard lifecycle ----------

function Start-SPDashboardForTest {
    <#
    .SYNOPSIS
        Launches Show-SPDashboard.ps1 as a child STA process and attaches
        FlaUI to it.

    .PARAMETER ConfigPath
        Optional settings.json path. Passed through to the dashboard so the
        test can point it at a mock config without disturbing the real one.

    .PARAMETER TimeoutSeconds
        How long to wait for the main window to appear. Default 30s.

    .OUTPUTS
        Hashtable with keys:
            Process     - System.Diagnostics.Process for the child powershell
            Automation  - FlaUI.UIA3.UIA3Automation (caller must NOT dispose;
                          Stop-SPDashboardForTest handles cleanup)
            Application - FlaUI.Core.Application
            Window      - FlaUI.Core.AutomationElements.Window (main window)
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ConfigPath,
        [Parameter()][int]$TimeoutSeconds = 30
    )

    Initialize-SPUiAutomation

    $launcher = Join-Path $script:ToolkitRoot 'Scripts\Show-SPDashboard.ps1'
    if (-not (Test-Path $launcher)) {
        throw "Dashboard launcher not found: $launcher"
    }

    # IMPORTANT: pass -NoIsolation. The launcher's default behaviour is to
    # spawn a fresh STA child process for the dashboard, but we are the
    # test harness: we already spawn a fresh STA child ourselves (below)
    # and we need FlaUI to attach to *that* child (the one hosting the
    # window). Without -NoIsolation we end up with a launcher process that
    # forks a grandchild for the WPF window; FlaUI attaches to the
    # launcher's empty PID and times out waiting for a window that never
    # appears in that process.
    $psArgs = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$launcher`"", '-NoIsolation')
    if ($ConfigPath) {
        $psArgs += @('-ConfigPath', "`"$ConfigPath`"")
    }

    # Launch detached so this caller can keep working. -Wait would block.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = (Get-Command powershell.exe).Source
    $psi.Arguments              = $psArgs -join ' '
    $psi.WorkingDirectory       = $script:ToolkitRoot
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $false   # We want the WPF window visible.
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError  = $false
    $proc = [System.Diagnostics.Process]::Start($psi)

    if (-not $proc) {
        throw "Failed to start dashboard launcher"
    }

    # Attach FlaUI and wait for the main window. The launcher does its own
    # STA self-relaunch check, but because we already passed -STA it should
    # proceed in-process and host the window in the PID we just started.
    $automation = New-Object FlaUI.UIA3.UIA3Automation
    try {
        $app = [FlaUI.Core.Application]::Attach($proc.Id)
        $timeout = [System.TimeSpan]::FromSeconds($TimeoutSeconds)
        $window  = $app.GetMainWindow($automation, $timeout)
        if (-not $window) {
            throw "Main window did not appear within ${TimeoutSeconds}s"
        }
    }
    catch {
        # Clean up partial state on failure so the caller doesn't leak a
        # background powershell process.
        $automation.Dispose()
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
        throw
    }

    return @{
        Process     = $proc
        Automation  = $automation
        Application = $app
        Window      = $window
    }
}

function Stop-SPDashboardForTest {
    <#
    .SYNOPSIS
        Closes the dashboard window and disposes FlaUI resources.
        Force-kills the process if it does not exit cleanly within
        GracefulTimeoutSeconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$UiContext,
        [Parameter()][int]$GracefulTimeoutSeconds = 5
    )

    $proc = $UiContext.Process
    try {
        if ($UiContext.Window -and -not $UiContext.Window.IsOffscreen) {
            try { $UiContext.Window.Close() } catch { }
        }
        if ($proc -and -not $proc.HasExited) {
            $proc.CloseMainWindow() | Out-Null
            $proc.WaitForExit($GracefulTimeoutSeconds * 1000) | Out-Null
        }
        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill() } catch { }
        }
    }
    finally {
        if ($UiContext.Automation) { try { $UiContext.Automation.Dispose() } catch { } }
    }
}

# ---------- Element finders ----------

function Find-SPUiElement {
    <#
    .SYNOPSIS
        Finds the first descendant matching the given condition, polling
        until found or until TimeoutMs elapses.

    .PARAMETER Root
        AutomationElement to start searching from (usually $ui.Window).

    .PARAMETER AutomationId
        Find by AutomationId. Mutually exclusive with -Name.

    .PARAMETER Name
        Find by AutomationProperty.Name (often the visible text /
        header / x:Name).

    .PARAMETER ControlType
        Optional additional filter, e.g. 'Button', 'TabItem', 'TextBox'.

    .PARAMETER TimeoutMs
        Total time to wait. Default 5000.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory)] $Root,
        [Parameter(Mandatory, ParameterSetName = 'ById')]   [string]$AutomationId,
        [Parameter(Mandatory, ParameterSetName = 'ByName')] [string]$Name,
        [Parameter()] [string]$ControlType,
        [Parameter()] [int]$TimeoutMs = 5000
    )

    Initialize-SPUiAutomation

    $cf = $Root.ConditionFactory
    switch ($PSCmdlet.ParameterSetName) {
        'ById'   { $cond = $cf.ByAutomationId($AutomationId) }
        'ByName' { $cond = $cf.ByName($Name) }
    }
    if ($ControlType) {
        $ct = [FlaUI.Core.Definitions.ControlType]::$ControlType
        $cond = $cond.And($cf.ByControlType($ct))
    }

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $el = $Root.FindFirstDescendant($cond)
        if ($el) { return $el }
        Start-Sleep -Milliseconds 100
    }
    $label = if ($AutomationId) { "AutomationId='$AutomationId'" } else { "Name='$Name'" }
    throw "UI element not found ($label$(if ($ControlType) { ", ControlType=$ControlType" })) within ${TimeoutMs}ms"
}

function Find-SPUiTab {
    <#
    .SYNOPSIS
        Finds a TabItem by its header text and returns it as a typed
        FlaUI.Core.AutomationElements.TabItem (so callers can use
        Select() / IsSelected / etc.).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)] [string]$Header,
        [Parameter()] [int]$TimeoutMs = 5000
    )
    $el = Find-SPUiElement -Root $Window -Name $Header -ControlType 'TabItem' -TimeoutMs $TimeoutMs
    # FlaUI 4 has no AsTabItem() extension; construct the typed wrapper directly.
    return [FlaUI.Core.AutomationElements.TabItem]::new($el.FrameworkAutomationElement)
}

# ---------- Diagnostics ----------

function Save-SPUiScreenshot {
    <#
    .SYNOPSIS
        Captures the bounds of the given element (or full screen if none)
        and writes them to a PNG file. Useful for visual review and for
        attaching evidence to a failed test.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] $Element,
        [Parameter(Mandatory)] [string]$Path
    )

    Initialize-SPUiAutomation

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($Element) {
        $bitmap = [FlaUI.Core.Capturing.Capture]::Element($Element).Bitmap
    }
    else {
        $bitmap = [FlaUI.Core.Capturing.Capture]::Screen().Bitmap
    }
    try {
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
    return (Get-Item $Path).FullName
}

Export-ModuleMember -Function Initialize-SPUiAutomation,
                              Start-SPDashboardForTest,
                              Stop-SPDashboardForTest,
                              Find-SPUiElement,
                              Find-SPUiTab,
                              Save-SPUiScreenshot

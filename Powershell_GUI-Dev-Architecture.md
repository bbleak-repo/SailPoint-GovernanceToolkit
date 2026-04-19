# PowerShell + WPF GUI Development — Architecture & Patterns

A reference for building (or auditing) PowerShell-hosted WPF desktop GUIs using **Windows PowerShell 5.1 Desktop** and **.NET Framework 4.5+**. Distilled from the SailPoint Governance Toolkit. Every pattern here earned its place by being the fix for a real bug.

Use this document two ways:
1. **Building new** — copy the skeleton at the end, then follow each pattern section.
2. **Auditing existing** — run the checklist in "Porting / Audit" against the target project.

---

## 1. Scope and Non-Goals

**In scope:**
- PowerShell 5.1 Desktop hosting a WPF window loaded from XAML files.
- Multi-module layout (foundation → API/domain → GUI).
- Single-threaded apartment (STA) launcher.
- Structured JSONL logging, dispatcher safety net, window fit-to-screen.
- File/folder picker integration.

**Out of scope (intentionally):**
- PowerShell 7 / Core hosting WPF. WPF runs on PS7/.NET Core but module-scope and Pester mock semantics differ; test every pattern.
- MVVM / full data binding — keep it imperative (`FindName` + event handlers). Adds complexity without a payoff at this size.
- WinUI / MAUI / Avalonia — different stacks.

---

## 2. Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Windows PowerShell | **5.1 Desktop** | Not PS7 / Core. PS7 has different module-scope + mock behavior. |
| Windows | 10 / 11 / Server 2019+ | WPF is Windows-only. |
| .NET Framework | 4.5+ | Pre-installed on Windows 10+. |
| Pester (for tests) | 5.x | Only if you ship unit tests. |

**Assemblies loaded at runtime** (inside the GUI module):
```powershell
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop   # Window, Controls
Add-Type -AssemblyName PresentationCore      -ErrorAction Stop   # Brushes, Media
Add-Type -AssemblyName WindowsBase           -ErrorAction Stop   # Dispatcher
Add-Type -AssemblyName System.Xml            -ErrorAction Stop   # XamlReader input
# Only if you use FolderBrowserDialog:
# Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
```

`Microsoft.Win32.OpenFileDialog` comes from `PresentationFramework` — no extra `Add-Type` needed.

---

## 3. Repository Layout

```
<ToolkitRoot>/
    Scripts/
        Show-Dashboard.ps1          # Thin STA launcher
        Other-CliEntryPoint.ps1     # Your CLI entry points (share modules)

    Modules/
        X.Core/                     # Foundation. No UI, no domain.
            X.Core.psd1
            X.Config.psm1
            X.Logging.psm1
            ...

        X.Api/                      # External APIs / domain calls.
            X.Api.psd1
            X.ApiClient.psm1
            ...

        X.Testing/ (optional)       # Test orchestration

        X.Gui/                      # GUI module (everything WPF).
            X.Gui.psd1
            X.GuiBridge.psm1        # Adapter: maps GUI requests → domain calls
            X.MainWindow.psm1       # WPF window host, event wiring

    Gui/
        MainWindow.xaml             # Single source of truth for the window

    Logs/                           # JSONL logs land here
    Config/                         # Runtime config (settings.json)
```

**Layering rule (strictly enforced):**
- `X.Core` depends on nothing else in the project.
- `X.Api` depends on `X.Core` only.
- `X.Gui` depends on `X.Core`, `X.Api`, and optionally `X.Testing`.
- `Scripts` are thin: load modules, parse args, dispatch.

**Why it matters:** when `X.MainWindow.psm1` calls `Write-SPLog` or `Get-SPConfig`, those commands are resolved through the module session chain. If the layering is wrong, the GUI will silently no-op because the logging function isn't reachable.

---

## 4. Entry-Point Script (STA Launcher)

WPF **requires** the thread apartment state to be STA. If the user invokes PowerShell in MTA, the dashboard will crash before showing. Detect and self-relaunch:

```powershell
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Help,
    [Alias('?')][switch]$ShortHelp
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

if ($Help -or $ShortHelp) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

# Relaunch in STA if needed
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
                '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $psArgs += "-$($kv.Key)"; $psArgs += "`"$($kv.Value)`""
    }
    Start-Process powershell.exe -ArgumentList $psArgs -Wait
    return
}

# Import modules (CALLER handles order — see Section 5)
$toolkitRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolkitRoot 'Modules\X.Core\X.Core.psd1') -Force
Import-Module (Join-Path $toolkitRoot 'Modules\X.Api\X.Api.psd1')   -Force
Import-Module (Join-Path $toolkitRoot 'Modules\X.Gui\X.Gui.psd1')   -Force

# Dispatch — Show-XDashboard is exported by X.Gui
Show-XDashboard -ConfigPath $ConfigPath
```

---

## 5. Module Loading Order

Modules use a `.psd1` manifest with **`NestedModules`** for their own `.psm1` files and **empty `RequiredModules`**. The caller (entry script) imports them in dependency order.

**Why empty `RequiredModules`:** it only resolves through `$env:PSModulePath`. Keeping it empty lets the module work from any deployment layout without machine-wide installation.

```powershell
# X.Gui.psd1
@{
    RootModule       = ''
    ModuleVersion    = '1.0.0'
    NestedModules    = @('X.GuiBridge.psm1', 'X.MainWindow.psm1')   # load order matters
    FunctionsToExport= @('Show-XDashboard', 'Invoke-XGuiAction', ...)
    RequiredModules  = @()   # caller handles order
}
```

---

## 6. State Management

**Three scopes, each with a specific job:**

| Scope | Use for | Example |
|---|---|---|
| `$script:*` (module) | Window handle, config path, toolkit root, loaded data that event handlers read. | `$script:MainWindow`, `$script:ConfigPath` |
| Function-local | Control references used only inside the `Initialize-*Tab` function. | `$btnRefresh`, `$tagFilter` |
| Parameters | When a function calls a helper. | `-TabContent $TabContent` |

**The trap:** event handler script blocks (`Add_Click`, `Add_SelectedItemChanged`, etc.) defined inside a function that reference **function-local variables** may not see them at fire-time when the handler runs in module scope under `Set-StrictMode`. See Section 10.

**Rule of thumb:**
- If a handler needs a control, **either** embed a closure over locals **or** re-find the control via `$script:MainWindow.FindName(...)` inside the handler.
- Don't rely on "it happens to work sometimes." It doesn't, consistently.

---

## 7. XAML Authoring Rules

### 7.1 Prefer single-file XAML for the window

Other projects often create `CampaignTab.xaml`, `SettingsTab.xaml` as *separate* files intending to inject them at runtime via `ContentControl.Content` — then forget to write the injection code. Result: orphan XAML files with controls no one ever sees, plus code that assumes those controls exist.

**Recommendation:** inline every tab directly into `MainWindow.xaml`. One file, one truth.

If you really need split XAML, wire the injection explicitly:
```powershell
$form = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlReader]::Create('Gui\FormTab.xaml'))
$host = $script:MainWindow.FindName('FormHost')
$host.Content = $form
```

### 7.2 Name every control you need to touch from code

```xml
<Button x:Name="BtnSave" Content="Save" />
<TextBox x:Name="TxtTenantUrl" />
<CheckBox x:Name="ChkRequireWhatIf" />
```

Unnamed controls are fine for decoration but can't be found by `FindName`.

### 7.3 Don't set properties that don't exist

Classic trap: **`ProgressBar` has no `CornerRadius`.** WPF `XamlReader.Load` throws immediately at parse time with a line/column number. When you see `'Cannot set unknown member 'System.Windows.Controls.X.Y''`, look up which control actually owns that property — often it's `Border`.

**Pre-commit sanity check:** parse the XAML offline before each GUI change:
```powershell
powershell.exe -NoProfile -STA -Command @"
Add-Type -AssemblyName PresentationFramework
try {
  [xml]`$x = Get-Content 'Gui\MainWindow.xaml' -Raw
  [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader `$x)) | Out-Null
  'PARSE OK'
} catch { 'PARSE FAIL: ' + `$_.Exception.Message }
"@
```

### 7.4 Styles: `x:Key` + `StaticResource`, or `TargetType` alone?

- **Keyed styles** (`x:Key="FieldBox" TargetType="TextBox"`) only apply where explicitly referenced. Use this for opt-in form fields.
- **Unkeyed styles** (`TargetType="Menu"`) apply globally to every control of that type. Use for blanket theming (menu bar, scroll bars).

Keep all styles in `Window.Resources` at the top of `MainWindow.xaml`. Deduplicate ruthlessly — a style redefined inside a `UserControl` won't be reachable if you ever inline that UserControl elsewhere.

### 7.5 Window defaults: size modestly

```xml
<Window
    Title="My App"
    Width="1100"
    Height="640"
    MinWidth="860"
    MinHeight="480"
    WindowStartupLocation="CenterScreen" />
```

**Do not** specify `Height="780"` or larger by default. Common laptop displays have ~720px work area. A too-tall window with `WindowStartupLocation="CenterScreen"` gets a negative `Top` — the title bar renders above pixel 0 and the window becomes uncloseable by anything except Alt+F4. See Section 14 for the runtime clamp.

---

## 8. Loading XAML at Runtime

One helper, with proper reader cleanup:

```powershell
function Import-XamlWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$XamlPath)

    if (-not (Test-Path $XamlPath)) { throw "XAML not found: $XamlPath" }

    $reader = [System.Xml.XmlReader]::Create($XamlPath)
    try   { return [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }   # or $reader.Close() on older runtimes
}
```

Wrap the caller in try/catch and rethrow with the path for debuggability:
```powershell
try { $window = Import-XamlWindow -XamlPath $path }
catch { throw "Failed to load XAML from '$path': $($_.Exception.Message)" }
```

---

## 9. Control Lookup

Thin wrapper around `FrameworkElement.FindName`:

```powershell
function Find-Control {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Parent,
          [Parameter(Mandatory)][string]$Name)
    return $Parent.FindName($Name)
}
```

**Use the window (module scope) as the parent inside event handlers**, not a function-local variable. `$script:MainWindow.FindName('BtnSave')` is reliable; `$TabContent.FindName('BtnSave')` inside a click handler is not (see Section 10).

---

## 10. Event Handlers & Closures — THE RULE

This is the #1 source of mysterious crashes in PowerShell + WPF + modules.

### The problem

```powershell
function Initialize-MyTab {
    param($TabContent)
    $btnSave = Find-Control -Parent $TabContent -Name 'BtnSave'
    $status  = Find-Control -Parent $TabContent -Name 'StatusLabel'

    $btnSave.Add_Click({
        $status.Text = 'Saving...'    #  <-- may THROW at click time under StrictMode
    })
}
```

When the user clicks later, the handler script block runs in the **module's session state**, not in `Initialize-MyTab`'s scope. `$status` may not be reachable. Under `Set-StrictMode -Version 1` (or stricter) this raises:

```
The variable '$status' cannot be retrieved because it has not been set.
```

The exception propagates up through `Dispatcher.Invoke` and **kills `ShowDialog()`** — the window dies.

### Fix A — `.GetNewClosure()` (mechanical, low-risk)

Embeds the caller's locals into the script block at declaration time.

```powershell
$btnSave.Add_Click({
    $status.Text = 'Saving...'
}.GetNewClosure())
```

Apply to every `Add_Click`, `Add_SelectedItemChanged`, `Add_MouseDoubleClick`, etc. that references function-local variables. Safe to apply even when not strictly necessary — it's a no-op then.

### Fix B — Re-find the control inside the handler (robust)

```powershell
$btnSave.Add_Click({
    $statusCtl = Find-Control -Parent $script:MainWindow -Name 'StatusLabel'
    if ($null -ne $statusCtl) { $statusCtl.Text = 'Saving...' }
})
```

Works without closures. Verbose but scope-proof. Use for handlers that only need one or two controls.

### Which fix when?

| Handler body | Use |
|---|---|
| References 3+ locals, lots of inline logic | **Fix A** (`.GetNewClosure()`) |
| References 1–2 controls, simple | **Fix B** (re-find) |
| References only `$script:*` / call module-scope functions | No fix needed |

### What not to do

Don't declare the handler body as a named function and pass it — you lose both the lexical capture *and* the module-scope resolution. Closure or re-find; don't invent a third path.

---

## 11. Dispatcher Safety Net + Logging Bootstrap

Even with the closure rule applied everywhere, Add_Click bodies can still throw (bad input, network failure, bug). One bad handler should **never** take down the whole dashboard. Install a dispatcher-level catch:

```powershell
# Inside Show-XDashboard, AFTER XAML loads and BEFORE ShowDialog()
$window.Dispatcher.add_UnhandledException({
    param($eventSender, $eventArgs)
    $ex = $eventArgs.Exception
    try {
        Write-XLog -Message "Unhandled GUI exception: $($ex.GetType().FullName): $($ex.Message)" `
            -Severity ERROR -Component 'X.Gui' -Action 'UnhandledException'
    } catch { }
    try { Set-StatusMessage -Message "Error (see log): $($ex.Message)" -IsError } catch { }
    $eventArgs.Handled = $true   # keep the dispatcher loop alive
})
```

**Pair this with logging initialization at dashboard startup.** A very common bug: CLI entry points call `Initialize-XLogging`, but the GUI launcher forgets — so `Write-XLog` in handler `catch` blocks silently no-ops. Add:

```powershell
try { Initialize-XLogging -Force -ErrorAction SilentlyContinue } catch { }
try {
    Write-XLog -Message "Dashboard launched (Config: $($script:ConfigPath))" `
        -Severity INFO -Component 'X.Gui' -Action 'Start'
} catch { }
```

---

## 12. Cross-Thread UI Updates

Background work (API calls, long tasks) runs on threads other than the UI thread. You cannot touch WPF controls from them directly — WPF will throw `InvalidOperationException`. Marshal through the dispatcher:

```powershell
function Invoke-OnDispatcher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Action)
    $dispatcher = [System.Windows.Application]::Current.Dispatcher
    if ($null -ne $dispatcher) {
        $dispatcher.Invoke([System.Action]$Action, [System.Windows.Threading.DispatcherPriority]::Normal)
    } else { & $Action }
}

function Set-StatusMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message, [switch]$IsError)
    Invoke-OnDispatcher -Action {
        $label = Find-Control -Parent $script:MainWindow -Name 'StatusBarText'
        if ($null -ne $label) {
            $label.Text = $Message
            $label.Foreground = if ($IsError) { [System.Windows.Media.Brushes]::Salmon }
                                else          { [System.Windows.Media.Brushes]::LightGray }
        }
    }
}
```

If you use runspaces (Powershell.BeginInvoke with a Runspace) for background work, the dispatcher wrap is mandatory.

---

## 13. Structured Logging Pattern

JSONL (one JSON object per line) — easy to tail, grep, ship to any log aggregator.

```powershell
# In X.Logging.psm1
function Write-XLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$Severity = 'INFO',
        [string]$Component = 'X.Core',
        [string]$Action,
        [string]$CorrelationID,
        [hashtable]$AdditionalFields
    )
    if (-not (Test-XSeverityLevel $Severity $script:MinSeverity)) { return }
    $entry = [ordered]@{
        Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Severity      = $Severity
        Component     = $Component
        Action        = $Action
        Message       = $Message
        CorrelationID = $CorrelationID
        User          = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Host          = [Environment]::MachineName
    }
    if ($AdditionalFields) { foreach ($k in $AdditionalFields.Keys) { $entry[$k] = $AdditionalFields[$k] } }
    $json = $entry | ConvertTo-Json -Compress -Depth 10
    [System.IO.File]::AppendAllText($script:LogPath, "$json`n", [System.Text.Encoding]::UTF8)
}
```

**Always wrap `Write-XLog` calls in handler catch-blocks with their own try/catch** — logging failure should never be the reason a handler crashes.

---

## 14. Window Fit-to-Screen

Even with sensible XAML defaults, some users will have exotic displays. Clamp to the primary screen's working area in the Loaded event:

```powershell
$window.add_Loaded({
    try {
        try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        if ($null -eq $screen) { return }
        $work = $screen.WorkingArea
        $margin = 8

        # Shrink if larger than work area
        $newW = [Math]::Min($this.Width,  [double]($work.Width  - 2 * $margin))
        $newH = [Math]::Min($this.Height, [double]($work.Height - 2 * $margin))
        if ($newW -ne $this.Width)  { $this.Width  = $newW }
        if ($newH -ne $this.Height) { $this.Height = $newH }

        # Re-center inside work area (accounts for taskbar + multi-monitor origin)
        $this.Left = [double]$work.X + [Math]::Max(0, ($work.Width  - $this.Width)  / 2)
        $this.Top  = [double]$work.Y + [Math]::Max(0, ($work.Height - $this.Height) / 2)
    } catch {
        try { Write-XLog -Message "Fit-to-screen failed: $($_.Exception.Message)" -Severity WARN -Component 'X.Gui' -Action 'FitToScreen' } catch { }
    }
})
```

**Also provide an obvious Close button** so users on dark themes can exit without hunting for the title-bar X:

```xml
<Button x:Name="BtnCloseApp" Content="✕  Close"
        Background="#8B2E2E" Foreground="#FFFFFF"
        BorderBrush="#C04040" BorderThickness="1"
        Padding="14,4" FontSize="12" FontWeight="SemiBold"
        Cursor="Hand" Margin="4,2,6,2" VerticalAlignment="Center"
        ToolTip="Close the dashboard (Alt+F4)"/>
```

Handler:
```powershell
$btnClose = Find-Control -Parent $script:MainWindow -Name 'BtnCloseApp'
if ($btnClose) { $btnClose.Add_Click({ $script:MainWindow.Close() }) }
```

---

## 15. File and Folder Pickers

**File (one dialog, no extra assemblies):**
```powershell
function Invoke-GuiFilePicker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetName,    # x:Name of target TextBox
        [string]$Title   = 'Select file',
        [string]$Filter  = 'All files (*.*)|*.*'
    )
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = $Title; $dlg.Filter = $Filter; $dlg.Multiselect = $false
    $target = Find-Control -Parent $script:MainWindow -Name $TargetName
    if ($null -ne $target -and $target.Text) {
        try {
            $seed = $target.Text
            $seedDir = if (Test-Path $seed -PathType Container) { $seed } else { Split-Path -Parent $seed }
            if ($seedDir -and (Test-Path $seedDir)) { $dlg.InitialDirectory = $seedDir }
        } catch { }
    }
    if ($dlg.ShowDialog() -eq $true -and $null -ne $target) { $target.Text = $dlg.FileName }
}
```

**Folder (requires WinForms):**
```powershell
function Invoke-GuiFolderPicker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetName, [string]$Description = 'Select folder')
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description; $dlg.ShowNewFolderButton = $true
    $target = Find-Control -Parent $script:MainWindow -Name $TargetName
    if ($null -ne $target -and $target.Text -and (Test-Path $target.Text)) {
        $dlg.SelectedPath = $target.Text
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $null -ne $target) {
        $target.SelectedPath = $dlg.SelectedPath   # wait — TextBox uses .Text, see below
        $target.Text = $dlg.SelectedPath
    }
}
```

Wire each Browse button with `.GetNewClosure()`:
```powershell
$btnBrowseEvid.Add_Click({
    Invoke-GuiFolderPicker -TargetName 'TxtEvidencePath' -Description 'Select Evidence output folder'
}.GetNewClosure())
```

---

## 16. Secret Handling (PasswordBox)

`PasswordBox` stores its value in `.Password`, not `.Text`. It is **not visible to WPF data binding by default** and is deliberately awkward.

**Load:** never populate a PasswordBox from disk automatically. Leave it blank.

**Save:** preserve the existing on-disk value if the user didn't type a new one. **Never** write a sentinel like `'VAULT_OR_ENV_ONLY'` unconditionally — it will silently erase real credentials on every save.

```powershell
# Inside Save-SettingsForm
$existingConfig = $null
try { $existingConfig = Get-XConfig -ConfigPath $configPath -Force } catch { }

$clientSecretToWrite = $null
$pbSecret = Find-Control -Parent $TabContent -Name 'PbClientSecret'
if ($null -ne $pbSecret -and $pbSecret.Password) {
    $clientSecretToWrite = $pbSecret.Password
}
elseif ($null -ne $existingConfig -and
        $existingConfig.PSObject.Properties.Name -contains 'Authentication' -and
        $existingConfig.Authentication.PSObject.Properties.Name -contains 'ConfigFile' -and
        $existingConfig.Authentication.ConfigFile.PSObject.Properties.Name -contains 'ClientSecret') {
    $clientSecretToWrite = $existingConfig.Authentication.ConfigFile.ClientSecret
}
else {
    $clientSecretToWrite = 'CHANGE_ME'
}
```

Better yet: store secrets in an encrypted vault (AES-256-CBC + PBKDF2, 600k iterations) and have the GUI only ever write a reference (`Mode = Vault`).

---

## 17. Common Pitfalls Catalog

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot set unknown member 'ProgressBar.CornerRadius'` | WPF `ProgressBar` has no `CornerRadius`. Only `Border` does. | Remove the attribute. For rounded corners, re-template via `ControlTemplate`. |
| `The variable '$X' cannot be retrieved...` in an event handler | Function-local captured by a module-scope script block, `Set-StrictMode -Version 1`. | `.GetNewClosure()` or re-find via `$script:MainWindow.FindName`. |
| Window title bar off the top of the screen | `Height` too large + `WindowStartupLocation="CenterScreen"` on a smaller display. | Reduce `Height` default; add Loaded fit-to-screen handler. |
| Dashboard crashes on first event | No `Dispatcher.UnhandledException` hook. | Add one before `ShowDialog()`. |
| `Write-XLog` calls do nothing from the GUI | `Initialize-XLogging` never called (other entry points called it; GUI forgot). | Call it once at dashboard startup. |
| Form controls empty / `Find-Control` returns null | `ContentControl` placeholder expected runtime injection, which was never written. | Inline the form XAML, or wire the injection. |
| PasswordBox secret overwritten with sentinel | Save path hardcoded a placeholder. | Preserve existing value unless user typed. |
| `Exception calling ShouldProcess with "2" arguments` | CLI script uses `SupportsShouldProcess` but is invoked via `-Command` in a non-interactive host. | Detect non-interactive (`[Environment]::UserInteractive`) and skip the prompt, or pass `-Confirm:$false`. |
| Controls unresponsive during API call | Calling API on the UI thread. | Dispatch to a runspace; marshal UI updates back via `Invoke-OnDispatcher`. |
| `Cannot set Property; object is frozen` | Modifying a `FrozenBrush` / static resource. | Clone the brush or declare a mutable instance per control. |

---

## 18. StrictMode — What Actually Happens

| Version | Effect relevant to WPF/closures |
|---|---|
| Off (no `Set-StrictMode`) | Unset variables evaluate to `$null`. Handlers "work" by accident. |
| **1** | Unset variables throw. This is what surfaces the closure bug. |
| 2 | + references to uninitialized properties throw, + calling functions with extra params throws. |
| 3 | + out-of-bounds array indexing throws. |

**Recommendation:** `Set-StrictMode -Version 1` at the top of every `.psm1`. It forces you to write closure-safe handlers without being pedantic about everything else.

---

## 19. Porting / Audit Checklist

Use this when bringing these patterns into a new project or reviewing an existing one.

### Structure
- [ ] Entry-point `Scripts\Show-*.ps1` exists, is thin, handles STA relaunch.
- [ ] Modules are layered: Core → Api → (Testing) → Gui.
- [ ] Each `.psd1` has empty `RequiredModules` + populated `NestedModules`.
- [ ] Caller imports modules in dependency order.

### XAML
- [ ] Single `MainWindow.xaml`; tab UIs inlined (no orphan `*Tab.xaml`).
- [ ] Every control the code touches has `x:Name`.
- [ ] No invalid property sets (`ProgressBar.CornerRadius`, etc.). Offline parse check passes.
- [ ] `Width` / `Height` defaults fit a 1366×768 display.
- [ ] Explicit, prominent Close button in addition to native X.
- [ ] Styles centralized in `Window.Resources`.

### Module
- [ ] `Set-StrictMode -Version 1` at top of GUI `.psm1`.
- [ ] Assemblies loaded at module top: `PresentationFramework`, `PresentationCore`, `WindowsBase`, `System.Xml`.
- [ ] `$script:MainWindow`, `$script:ConfigPath`, `$script:ToolkitRoot` set in `Show-*Dashboard`.
- [ ] `Find-Control` helper + consistent use.
- [ ] `Invoke-OnDispatcher` helper for any cross-thread work.

### Show-*Dashboard function
- [ ] Calls `Initialize-XLogging -Force` before anything that might log.
- [ ] Writes an INFO `Dashboard launched` log entry on startup.
- [ ] Installs `Dispatcher.add_UnhandledException` safety net **before** `ShowDialog()`.
- [ ] Installs `$window.add_Loaded` fit-to-screen handler.
- [ ] Wires `BtnCloseApp` (and `MenuExit` if present) to `$script:MainWindow.Close()`.

### Event handlers
- [ ] **Every** `Add_Click` / `Add_SelectedItemChanged` / `Add_MouseDoubleClick` either:
  - [ ] Has `.GetNewClosure()` appended, **or**
  - [ ] Re-finds controls via `$script:MainWindow.FindName` inside, **or**
  - [ ] References only `$script:*` / module-scope functions.
- [ ] Handlers that call potentially-failing code wrap the body in try/catch with `Write-XLog` + `Set-StatusMessage`.

### Settings / secrets
- [ ] PasswordBox value is NOT auto-populated on load.
- [ ] Save path preserves existing secret if PasswordBox is empty (never writes a sentinel that erases real data).
- [ ] Browse buttons wired to `Invoke-GuiFilePicker` / `Invoke-GuiFolderPicker`.

### Validation
- [ ] Offline XAML parse: `XamlReader.Load` succeeds.
- [ ] Launch check: `Get-Process` shows a window with non-empty `MainWindowTitle` and `Responding=True`.
- [ ] Win32 check: `GetWindowRect().top >= 0` (title bar on-screen).
- [ ] Clicking every button either does its job or fails softly (logged + status message); no dispatcher crashes.

---

## 20. Minimal Starter Skeleton

Enough to launch an empty dashboard with every pattern wired up.

### `Scripts\Show-Dashboard.ps1`
```powershell
#Requires -Version 5.1
[CmdletBinding()] param([string]$ConfigPath)
Set-StrictMode -Version 1

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',"`"$PSCommandPath`"")
    if ($ConfigPath) { $args += '-ConfigPath'; $args += "`"$ConfigPath`"" }
    Start-Process powershell.exe -ArgumentList $args -Wait
    return
}

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Modules\X.Core\X.Core.psd1') -Force
Import-Module (Join-Path $root 'Modules\X.Gui\X.Gui.psd1')  -Force
Show-XDashboard -ConfigPath $ConfigPath
```

### `Gui\MainWindow.xaml`
```xml
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="My Dashboard"
        Width="1000" Height="600" MinWidth="800" MinHeight="480"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E2E" Foreground="#E0E0E0" FontFamily="Segoe UI">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="28"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Background="#252538">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Menu Grid.Column="0" Background="#252538">
                <MenuItem Header="File"><MenuItem x:Name="MenuExit" Header="Exit"/></MenuItem>
            </Menu>
            <Button Grid.Column="1" x:Name="BtnCloseApp" Content="✕  Close"
                    Background="#8B2E2E" Foreground="#FFFFFF" BorderBrush="#C04040"
                    Padding="14,4" FontWeight="SemiBold" Cursor="Hand"
                    Margin="4,2,6,2" VerticalAlignment="Center"
                    ToolTip="Close (Alt+F4)"/>
        </Grid>
        <Grid Grid.Row="1" Margin="12,8">
            <Button x:Name="BtnHello" Content="Hello" Width="120" Height="32"
                    HorizontalAlignment="Left" VerticalAlignment="Top"/>
        </Grid>
        <Border Grid.Row="2" Background="#252538" Padding="8,2">
            <TextBlock x:Name="StatusBarText" Foreground="#AAAACC" Text="Ready"/>
        </Border>
    </Grid>
</Window>
```

### `Modules\X.Gui\X.MainWindow.psm1`
```powershell
#Requires -Version 5.1
Set-StrictMode -Version 1

Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore      -ErrorAction Stop
Add-Type -AssemblyName WindowsBase           -ErrorAction Stop
Add-Type -AssemblyName System.Xml            -ErrorAction Stop

$script:MainWindow  = $null
$script:ConfigPath  = $null
$script:ToolkitRoot = $null

function Find-Control { param($Parent, [string]$Name) return $Parent.FindName($Name) }

function Invoke-OnDispatcher {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $d = [System.Windows.Application]::Current.Dispatcher
    if ($null -ne $d) { $d.Invoke([System.Action]$Action, 'Normal') } else { & $Action }
}

function Set-StatusMessage {
    param([Parameter(Mandatory)][string]$Message, [switch]$IsError)
    Invoke-OnDispatcher -Action {
        $t = Find-Control -Parent $script:MainWindow -Name 'StatusBarText'
        if ($t) {
            $t.Text = $Message
            $t.Foreground = if ($IsError) { [System.Windows.Media.Brushes]::Salmon }
                            else          { [System.Windows.Media.Brushes]::LightGray }
        }
    }
}

function Show-XDashboard {
    [CmdletBinding()] param([string]$ConfigPath)

    $script:ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:ConfigPath  = if ($ConfigPath) { $ConfigPath } else { Join-Path $script:ToolkitRoot 'Config\settings.json' }

    if ($null -eq [System.Windows.Application]::Current) { [System.Windows.Application]::new() | Out-Null }

    $xamlPath = Join-Path $script:ToolkitRoot 'Gui\MainWindow.xaml'
    $reader   = [System.Xml.XmlReader]::Create($xamlPath)
    try   { $window = [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }

    $script:MainWindow = $window

    # Close handlers
    $menuExit = Find-Control -Parent $window -Name 'MenuExit'
    if ($menuExit) { $menuExit.Add_Click({ $script:MainWindow.Close() }) }
    $btnClose = Find-Control -Parent $window -Name 'BtnCloseApp'
    if ($btnClose) { $btnClose.Add_Click({ $script:MainWindow.Close() }) }

    # Example click handler with .GetNewClosure()
    $btnHello = Find-Control -Parent $window -Name 'BtnHello'
    if ($btnHello) {
        $localMsg = 'Hello from local scope'
        $btnHello.Add_Click({
            Set-StatusMessage -Message $localMsg
        }.GetNewClosure())
    }

    # Dispatcher safety net
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try { Write-XLog -Message "GUI exception: $($e.Exception.Message)" -Severity ERROR -Component 'X.Gui' -Action 'UnhandledException' } catch { }
        try { Set-StatusMessage -Message "Error: $($e.Exception.Message)" -IsError } catch { }
        $e.Handled = $true
    })

    # Fit-to-screen
    $window.add_Loaded({
        try {
            try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }
            $work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $m = 8
            $this.Width  = [Math]::Min($this.Width,  [double]($work.Width  - 2*$m))
            $this.Height = [Math]::Min($this.Height, [double]($work.Height - 2*$m))
            $this.Left   = [double]$work.X + [Math]::Max(0, ($work.Width  - $this.Width)  / 2)
            $this.Top    = [double]$work.Y + [Math]::Max(0, ($work.Height - $this.Height) / 2)
        } catch { }
    })

    Set-StatusMessage -Message "Ready | Root: $($script:ToolkitRoot)"
    try { Initialize-XLogging -Force -ErrorAction SilentlyContinue } catch { }
    try { Write-XLog -Message "Dashboard launched" -Severity INFO -Component 'X.Gui' -Action 'Start' } catch { }

    $window.ShowDialog() | Out-Null
}

Export-ModuleMember -Function Show-XDashboard
```

---

## 21. When to Break These Rules

- **Single-file XAML:** if your dashboard has 20+ distinct views, split becomes worthwhile — but commit to wiring the injection and delete the orphans on the same PR.
- **MVVM / data binding:** worth adopting once a tab has 10+ form fields that need to stay in sync with a view model. Hand-wiring `FindName` + imperative updates hits diminishing returns.
- **Single window only:** multiple top-level windows need their own `$script:SecondaryWindow` handles, separate dispatcher hooks, separate fit-to-screen handlers. The rules scale; the globals multiply.
- **Async / runspace pool for background work:** worth the complexity if any operation takes >500ms; otherwise the sync + Dispatcher pattern is simpler and good enough.

---

_Derived from the SailPoint Governance Toolkit on 2026-04-17. Each pattern here replaced a bug we actually hit. If you add a new pattern to this document, include the symptom that justified it._

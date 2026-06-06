# Round 10
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-10 -- Initialize-SdkTab region

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-10 entry, lines 213-228)
- `docs/planning/PHASE7_GUI_SDK_TAB.md` (SP.MainWindow.psm1 Changes + WPF notes 1-6)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Gui/SdkTab.xaml` (read-only x:Name + sub-tab header reference)
- `Modules/SP.Gui/SP.MainWindow.psm1`: #region Module-scoped State (32-61),
  Initialize-AuditTab handlers (1280-1369), Initialize-GovernanceTab (2941-3028),
  Set-StatusMessage (289+), Governance region close + #region Menu Handlers (3537-3539)

**Did:**
Added one new `#region SDK Features Tab` to `Modules/SP.Gui/SP.MainWindow.psm1`,
inserted between the Governance Tab region and `#region Menu Handlers` (plan note
"insert before #region Menu Handlers"). It contains the module-private,
non-exported `Initialize-SdkTab -TabContent` function which: captures
`$module = $script:ThisModule` once at the top; binds each of the 7 sub-tab grids
to its matching module-scoped ObservableCollection; locates all 38 controls via
`Find-Control -Parent $TabContent -Name`; and wires all 33 button/checkbox/radio/
combo/sub-tab handlers with the mandatory `& $module { param($tc) ... } $TabContent`
+ `.GetNewClosure()` idiom (WPF note 2). Each handler routes to a named
module-private helper. SDK-10 ships those helpers as THIN STUBS (refresh + each
action per sub-tab, plus `Set-SdkSubTabStatus`, `Invoke-SdkSubTabLoad`) that only
set the sub-tab `*StatusLabel` to a "deferred to SDK-11" message -- no bridge/API
call runs on the UI thread (WPF note 3). The sub-tab `SelectionChanged` handler
filters to the TabControl's own selection then lazy-routes to the selected
sub-tab's refresh helper. At the end of `Initialize-SdkTab` the six initial
status labels are set and the default sub-tab (Templates) refresh stub is invoked
(plan: "Call initial data load for the default sub-tab (Templates)").
The 7 ObservableCollections + `$script:IsSdkRunning = $false` were added to
`#region Module-scoped State` with the plan's exact names. Export list unchanged
(Initialize-* tab fns stay private); tab-init sequence and
`Scripts/Show-SPDashboard.ps1` untouched (SDK-13).

**Files:**
- Modified: `Modules/SP.Gui/SP.MainWindow.psm1`
- Created: `docs/phase7-sdk-gui-rounds/round-10.md`
- Modified: `docs/phase7-sdk-gui-backlog.md` (SDK-10 Status -> DONE)

**Verification:**
  - Parse: `[Parser]::ParseFile` on SP.MainWindow.psm1 -> ZERO errors ("PARSE OK").
  - Import: `Import-Module SP.Gui.psd1 -Force` succeeds; `Initialize-SdkTab` and
    the stub helpers resolve inside the nested SP.MainWindow module scope
    (`& $nested { Get-Command ... }` = True); NOT exported (correct -- only
    Show-SPDashboard family is in the export list).
  - Static (AST): Initialize-SdkTab has 33 `.Add_*` invocations; every one wraps
    its body in `& $module { ... }`; ZERO delegates contain `$script:`; ZERO
    `Get-SPGuiSdk*` / `Invoke-SPGuiSdk*` bridge tokens anywhere in the function.
  - x:Names: all 38 `Find-Control -Name` values exist in `Gui/SdkTab.xaml`
    (BtnSdk*, ChkSdk*, RbSdk*, CboSdk*, Sdk*Grid, Sdk*StatusLabel, SdkSubTabControl).
  - Pester: SP.SdkBridge.Tests.ps1 -> P=34 F=0 Skipped=0 Total=34.
  - XAML parse: n/a (SdkTab.xaml read-only, not modified this round).
  - Manifest: n/a (SP.Gui.psd1 not modified; import verified above).

**Review:** <PASS | FAIL: findings>

**Backlog update:** SDK-10 -> DONE

**Code/plan disagreements recorded (trust code):**
1. The tab-init call sequence and "initial data load" wiring live in the
   `Show-SPDashboard` FUNCTION in `Modules/SP.Gui/SP.MainWindow.psm1` (~3716-3754),
   NOT in `Scripts/Show-SPDashboard.ps1` (which only holds the module-LOAD chain).
   SDK-13 must add the `Initialize-SdkTab` call there (after Governance) AND add
   SP.Sdk to the .ps1 load chain. Out of SDK-10 scope; flagged for SDK-13.
2. Backlog/plan "call initial data load for the default sub-tab (Templates)" is
   reconciled with WPF note 3 / SDK-10 wiring-only mandate: SDK-10 wires the call
   to the (stub) Templates refresh helper; the real runspace load is SDK-11.

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

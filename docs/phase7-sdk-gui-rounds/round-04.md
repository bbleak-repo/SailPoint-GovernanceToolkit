# Round 4
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-04 -- SP.Gui.psd1 register SP.SdkBridge + exports

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-04 row + section, lines 33, 118-129)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round-file template)
- `Modules/SP.Gui/SP.Gui.psd1` (current manifest)
- `Modules/SP.Gui/SP.SdkBridge.psm1` (Export-ModuleMember block lines 1242-1257; confirmed `Test-SPGuiSdkSafetyGate` is defined but NOT exported)

**Did:** Manifest-only, additive edit to `Modules/SP.Gui/SP.Gui.psd1`. (1) Added
`'SP.SdkBridge.psm1'` as the FIRST entry in `NestedModules` (bridge-first per the
load-order comment at psd1:46 and WPF note 3 -- the bridge has no WPF deps).
(2) Appended the 14 public bridge functions (9 reads + 5 write dispatchers) to
`FunctionsToExport`, taking exactly the names from SP.SdkBridge.psm1's own
`Export-ModuleMember`; the private `Test-SPGuiSdkSafetyGate` was deliberately left
unexported so SDK-06 can `Mock -ModuleName` it. (3) Housekeeping: added
`'SP.SdkBridge.psm1'` to `FileList` and appended a v1.4.0 note to
`PrivateData.PSData.ReleaseNotes`. The pre-existing `SP.GuiBridge.psm1`
registration (a separate file) was left untouched.

**Files:** Modified `Modules/SP.Gui/SP.Gui.psd1`.

**Verification:** (clean `powershell.exe` PS 5.1 Desktop process)
  - Pester: P=34 F=0 (Total=34) on `Tests/SP.SdkBridge.Tests.ps1` via
    New-PesterConfiguration (the dedicated bridge test that exercises the exported
    functions through SP.Gui).
  - XAML parse: n/a (manifest-only item, no XAML touched).
  - Manifest/import: OK. `Test-ModuleManifest` -> MANIFEST_OK (v1.0.0).
    `Import-PowerShellDataFile` -> NestedModules[0] = SP.SdkBridge.psm1 (first, ahead
    of SP.GuiBridge.psm1 and SP.MainWindow.psm1); FileList includes SP.SdkBridge.psm1
    (True). Clean-process `Import-Module -Force` succeeded and
    `Get-Command -Module SP.Gui | Where Name -like '*Sdk*'` resolved all 14 SPGuiSdk*
    functions (SDK_COUNT=14), set-equal to the bridge's own Export-ModuleMember list;
    `Get-Command Test-SPGuiSdkSafetyGate -Module SP.Gui` returned nothing
    (GATE_PRIVATE_OK -- private gate stays private); pre-existing exports still present.

**Review:** PASS (self-verified end-state; defer to independent code-review gate)
**Backlog update:** SDK-04 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

**Plan/code note (resolved in code's favor):** The backlog/plan name the new file
`SP.SdkBridge.psm1`, which genuinely exists on disk and is a SEPARATE file from the
already-registered `SP.GuiBridge.psm1`. SDK-04 ADDS SP.SdkBridge.psm1; it does not
rename or remove SP.GuiBridge.psm1. `Test-ModuleManifest` passes today even without
validating nested function names, so the authoritative gate was the clean-process
`Import-Module` + `Get-Command -Module SP.Gui` check, which passed (14/14).

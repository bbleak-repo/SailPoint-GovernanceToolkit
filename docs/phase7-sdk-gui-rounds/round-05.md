# Round 5
**Started:** <START_TIMESTAMP>
**Item:** SDK-05 -- Import-TestModules.ps1 -- load bridge flat for tests

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-05 row + section, lines 34/133-144)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Tests/Import-TestModules.ps1` (Bug-1 flat-import rationale header lines 1-22, sibling import blocks 66-113)
- `Modules/SP.Gui/SP.SdkBridge.psm1` (exports: 9 Get-SPGuiSdk*, 5 Invoke-SPGuiSdk*Action = 14)
- existing test convention (`. (Join-Path $PSScriptRoot 'Import-TestModules.ps1')` + `Import-SPTestModules` inside `BeforeAll`)

**Did:** Added a dedicated `[switch]$SdkBridge` parameter to `Import-SPTestModules` and a
guarded `if ($SdkBridge)` block that imports `SP.Gui\SP.SdkBridge.psm1` flat
(`-Force -DisableNameChecking`), placed after the `if ($Sdk)` block, using the same
Join-Path/$modulesRoot convention as every sibling family. Added a `.PARAMETER SdkBridge`
help stanza documenting the flat-load and the -Core/-Api/-Sdk co-requirement. This makes
`Mock <SP.Sdk fn> -ModuleName SP.SdkBridge` reach the bridge call sites under WinPS 5.1 /
Pester 5.x (Bug-1 rule: import the .psm1 directly, never the SP.Gui.psd1 aggregator).

PLAN DISAGREEMENT (code over plan): the backlog mentions adding to "the existing `-Gui`
path" but no `-Gui` flag exists in this file -- resolved by adding the explicitly-permitted
`-SdkBridge` switch instead of fabricating a `-Gui` flag. Flagged forward to SDK-06: the
plan's note (PHASE7_GUI_SDK_TAB.md:516) "Mock Invoke-SPApiRequest at module level" is wrong
for this bridge -- it calls SP.Sdk cmdlets, not Invoke-SPApiRequest; SDK-06 must mock an
SP.Sdk function inside SP.SdkBridge scope (matching the SDK-05 Accept).

**Files:** `Tests/Import-TestModules.ps1` (modified)

**Verification:**
  - Parse: `[Parser]::ParseFile` ParseErrors=0
  - Import: dot-source + `Import-SPTestModules -Core -Api -Sdk -SdkBridge` -> `Get-Module SP.SdkBridge` non-null, ExportedFunctions.Count=14
  - Param: `(Get-Command Import-SPTestModules).Parameters` contains 'SdkBridge' = True
  - Help: `(Get-Help Import-SPTestModules).parameters.parameter` SdkBridge description non-empty = True
  - Pester (smoke, run only): P=2 F=0
    - flat-scope proof: `Mock Get-SPSdkCampaignTemplates -ModuleName SP.SdkBridge` -> `Get-SPGuiSdkCampaignTemplates` returns Success=$true, Data.Count=1, `Assert-MockCalled ... -Times 1` passes
    - regression: `Import-SPTestModules -Core -Api -Sdk` (no -SdkBridge) does NOT load SP.SdkBridge
  - XAML parse: n/a (no XAML touched)
  - Manifest/import: n/a (no manifest/production-module edits)

**Re-verification (this round, headless):**
  - Pester full affected suite `Tests/SP.SdkBridge.Tests.ps1` via `New-PesterConfiguration`: P=34 F=0 Total=34
  - Flat-import: `Import-SPTestModules -Core -Api -Sdk -SdkBridge` -> `(Get-Module SP.SdkBridge).NestedModules.Count` == 0; `Get-Command Get-SPGuiSdkCampaignTemplates` resolves == True
  - Smoke-mock (in-Pester): `Mock Get-SPSdkCampaignTemplates -ModuleName SP.SdkBridge { @{Success=$true;Data=@();Error=$null} }` -> empty-success envelope, backing invoked once, no live call: P=1 F=0

**Review:** PASS (re-verified headless this round; independent code-review gate runs in the loop)
**Backlog update:** SDK-05 -> DONE

**Completed:** <END_TIMESTAMP>
**Status:** SUCCESS

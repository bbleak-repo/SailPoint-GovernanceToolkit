# Round 13
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-13 -- Show-SPDashboard.ps1 add SP.Sdk + Initialize-SdkTab call

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-13 row + section, lines 42 / 265-276)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Scripts/Show-SPDashboard.ps1` (module-load chain, lines 120-147 -- actual chain
  is Core, Api, Audit, Gui; NO SP.DeltaCert entry, contradicting plan line 436)
- `Modules/SP.Gui/SP.MainWindow.psm1` (tab-init sequence ~5136-5174; `Initialize-SdkTab`
  definition at line 3553, signature `param($TabContent)`)
- `Gui/MainWindow.xaml` (confirmed `x:Name="SdkTabContent"` present)

**Did:**
Pure wiring across two coupled files. (1) In `Scripts/Show-SPDashboard.ps1` added a
`$sdkModulePath` var (after `$auditModulePath`) and inserted a hashtable entry
`@{ Path = $sdkModulePath; Name = 'SP.Sdk'; Required = $true }` in the foreach
load chain BETWEEN the SP.Audit and SP.Gui entries, so the parent session loads
SP.Sdk before SP.Gui (whose SDK runspace hard-imports SP.Sdk.psd1). (2) In
`Modules/SP.Gui/SP.MainWindow.psm1` added an `# SDK Features tab` block in
`Show-SPDashboard`'s tab-init sequence -- `Find-Control -Name 'SdkTabContent'`
guarded by `if ($null -ne $sdkTab)` then `Initialize-SdkTab -TabContent $sdkTab`
-- placed immediately before the Settings-tab block (honoring backlog/plan
"before Settings"). Mirrors the existing 6-tab init pattern exactly.

**Files:**
- MODIFIED `Scripts/Show-SPDashboard.ps1`
- MODIFIED `Modules/SP.Gui/SP.MainWindow.psm1`

**Verification:**
  - Pester: P=38 F=0 Total=38 (Tests/SP.SdkBridge.Tests.ps1 -- nearest affected
    test; launcher/tab-init have no dedicated test yet, SDK-15 adds structural tab tests)
  - AST parse: Show-SPDashboard.ps1 = 0 errors; SP.MainWindow.psm1 = 0 errors
  - Module chain: fresh PS 5.1 session imported Core->Api->Audit->SP.Sdk in
    launcher order; `(Get-Module SP.Sdk)` not null AND
    `Get-Command Get-SPSdkCampaignTemplates -Module SP.Sdk` resolves (SdkLoaded=True, CmdResolves=True)
  - Ordering: SP.Audit (L129) < SP.Sdk (L130) < SP.Gui (L131) = True
  - Call-site: exactly 1 `Initialize-SdkTab -TabContent` call site at L5154
    (outside the function def); placed before Settings tab block
  - Regression: all 6 existing Initialize-*Tab calls present (1 each)
  - Manifest: Test-ModuleManifest Modules/SP.Sdk/SP.Sdk.psd1 = OK (SP.Sdk v1.0.0)
  - XAML: x:Name="SdkTabContent" confirmed present in Gui/MainWindow.xaml

**Plan-vs-code disagreements noted:**
- Plan line 436 "after SP.DeltaCert" is stale -- no SP.DeltaCert entry exists in
  the actual load chain. Followed backlog "after SP.Audit" (correct).
- Plan snippet line 439 `Required = $false`; used `Required = $true` (deviation)
  because SP.Gui's SDK runspace hard-imports SP.Sdk.psd1 and a silent-missing
  SP.Sdk yields a broken-but-launching dashboard. $true fails fast and satisfies
  backlog Accept "module chain loads SP.Sdk". FLAGGED to outer loop as the single
  judgment call.
- Backlog Files list (Show-SPDashboard.ps1 only) is incomplete -- the named
  "Initialize-SdkTab call" physically lives in SP.MainWindow.psm1's tab sequence.
  Both files in scope.

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-13 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

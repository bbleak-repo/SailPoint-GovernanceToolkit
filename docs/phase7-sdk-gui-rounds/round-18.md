# Round 18
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-18 -- Cert Summaries sub-tab (SCOPE DECISION -- ship-vs-defer)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-18 table row line 47 + section lines 379-391)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Gui/SdkTab.xaml` (Cert Summaries TabItem, lines 152-274)
- `Modules/SP.Gui/SP.MainWindow.psm1` (Initialize-SdkTab wiring 3645-3684, initial status 3928, Invoke-SdkCertSummaryRefresh 4500)
- `Tests/Harness/Test-W08-SdkTabStructure.ps1` (WG-08-03 / WG-08-05 invariants)

**Did:**
DEFERRED the Cert Summaries sub-tab cleanly (FLAGGED FOR HUMAN RATIFICATION). Three
blockers make SHIP unverifiable in the headless loop: the campaign->certification
combo cascade has no backing (`Get-SPGuiSdkCertifications` does not exist; SP.Api
has no campaign-list), the mock has 0 ROLE/ACCESS_PROFILE access-summary fixtures
(round-14: 0/81), and the W-08b interactive test is unwritten/unrunnable headlessly.
In `SdkTab.xaml`: added `IsEnabled="False"` to `CboSdkCertCampaign`,
`CboSdkCertification`, `CboSdkAccessType`, and `BtnSdkRefreshSummaries`; set the
`SdkCertSummaryGrid` Border to `Visibility="Collapsed"` (grid kept in the tree so
the x:Name still resolves); added a native dark-theme overlay Border in `Grid.Row=2`
declared after the grid (renders on top) with `x:Name="SdkCertSummaryComingSoon"`
text "Coming in a future release." In `SP.MainWindow.psm1`: updated the no-op
`Invoke-SdkCertSummaryRefresh` status message and the `Initialize-SdkTab` initial
status to user-facing deferral text; left the Sub-tab 2 handler wiring untouched
(disabled controls never fire; minimizes diff; preserves the
`& $module { } + .GetNewClosure()` idiom). No combo-cascade population added; no
bridge/API/runspace call on a deferred tab. The four structural x:Names and the
`Cert Summaries` header are unchanged so WG-08-03/05 stay green; the button keeps a
non-empty ToolTip (WG-08-10).

**Files:**
- modified: `Gui/SdkTab.xaml`
- modified: `Modules/SP.Gui/SP.MainWindow.psm1`
- modified: `docs/phase7-sdk-gui-backlog.md` (SDK-18 -> DEFERRED, table + section + rationale)
- created: `docs/phase7-sdk-gui-rounds/round-18.md`

**Verification:**
  - Pester (affected: SP.SdkCertSummaries.Tests.ps1 + SP.SdkBridge.Tests.ps1): P=60 F=0
  - XAML parse (powershell -STA, XamlReader::Load over XmlNodeReader): PARSE OK;
    CboSdkCertCampaign/CboSdkCertification/CboSdkAccessType IsEnabled=False,
    BtnSdkRefreshSummaries IsEnabled=False, SdkCertSummaryGrid present,
    SdkCertSummaryComingSoon present (Text "Coming in a future release."),
    BtnSdkRefreshSummaries ToolTip non-empty.
  - W-08 structural test (Test-W08-SdkTabStructure.ps1, STA): pass=10 fail=0
    (WG-08-03 6 sub-tabs in order, WG-08-05 all 4 Cert Summaries controls present,
    WG-08-10 all 25 Btn*/Chk* have ToolTips).
  - Manifest/import: Import-Module -Force SP.Gui.psd1 -> IMPORT OK (no errors).

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-18 -> DEFERRED

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

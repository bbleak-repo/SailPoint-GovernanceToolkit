# Round 18
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-18 -- Cert Summaries sub-tab (SCOPE DECISION -- ship-vs-defer)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-18 table row line 47 + section lines 379-409)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Gui/MainWindow.xaml` (the RUNTIME SDK tab; Cert Summaries TabItem lines 1187-1272)
- `Gui/SdkTab.xaml` (dead design reference, lines 155-274 -- NOT loaded at runtime)
- `Modules/SP.Gui/SP.MainWindow.psm1` (Initialize-SdkTab wiring 3645-3684, initial status 3928, Invoke-SdkCertSummaryRefresh 4501)
- `Tests/Harness/Test-W08-SdkTabStructure.ps1` (header note: asserts against MainWindow.xaml; WG-08-03 / WG-08-05 invariants)

**Did:**
DEFERRED the Cert Summaries sub-tab cleanly (FLAGGED FOR HUMAN RATIFICATION). Three
blockers make SHIP unverifiable in the headless loop: the campaign->certification
combo cascade has no backing (`Get-SPGuiSdkCertifications` does not exist; SP.Api
has no campaign-list), the mock has 0 ROLE/ACCESS_PROFILE access-summary fixtures
(round-14: 0/81), and the W-08b interactive test is unwritten/unrunnable headlessly.

**RETRY CORRECTION (code-review BLOCKER fixed):** the prior attempt applied the
defer edits only to `Gui/SdkTab.xaml`, which is a dead design reference that is
never loaded -- the GUI loads `Gui/MainWindow.xaml` via
`Get-XamlPath -FileName 'MainWindow.xaml'` (SP.MainWindow.psm1:5131) where the SDK
tab is inlined. So the running GUI still showed an enabled, uncovered sub-tab. This
round applies the defer to the RUNTIME `Gui/MainWindow.xaml` (Cert Summaries TabItem):
added `IsEnabled="False"` to `CboSdkCertCampaign`, `CboSdkCertification`,
`CboSdkAccessType`, and `BtnSdkRefreshSummaries`; set the `SdkCertSummaryGrid` Border
to `Visibility="Collapsed"` (grid kept in the tree so the x:Name still resolves); and
added a native dark-theme overlay Border in `Grid.Row="1"` (same row as the collapsed
grid, declared after it so it fills the content area) with
`x:Name="SdkCertSummaryComingSoon"` text "Certification Summaries -- coming in a
future release." The four structural x:Names and the `Cert Summaries` header are
unchanged so WG-08-03/05 stay green; the button keeps a non-empty ToolTip (WG-08-10).

The PSM1 changes from the prior attempt were already correct (they operate on the
runtime tree by x:Name): the no-op `Invoke-SdkCertSummaryRefresh` and the
`Initialize-SdkTab` initial status both set user-facing deferral text; the Sub-tab 2
handler wiring is left untouched (disabled controls never fire; minimizes diff;
preserves the `& $module { } + .GetNewClosure()` idiom). No combo-cascade population
added; no bridge/API/runspace call on a deferred tab. Updated the PSM1 comment and
the backlog Files line to name the runtime file (the spec's `SdkTab.xaml` reference
was inaccurate about the live file -- flagged upstream).

**Files:**
- modified: `Gui/MainWindow.xaml` (runtime Cert Summaries TabItem -- defer applied here)
- modified: `Modules/SP.Gui/SP.MainWindow.psm1` (comment now names runtime file; no-op + initial status text unchanged from prior round)
- modified: `docs/phase7-sdk-gui-backlog.md` (SDK-18 -> DONE; Files line corrected to MainWindow.xaml; retry-correction rationale)
- modified: `docs/phase7-sdk-gui-rounds/round-18.md`

**Verification:**
  - Pester (affected: SP.SdkCertSummaries.Tests.ps1 + SP.SdkBridge.Tests.ps1): P=60 F=0
  - XAML parse of the RUNTIME `Gui/MainWindow.xaml` (powershell -STA, XamlReader::Load
    over XmlNodeReader): PARSE OK; after load FindName reports
    CboSdkCertCampaign/CboSdkCertification/CboSdkAccessType IsEnabled=False,
    BtnSdkRefreshSummaries IsEnabled=False, SdkCertSummaryGrid present,
    SdkCertSummaryComingSoon present (Text "Certification Summaries -- coming in a
    future release."), BtnSdkRefreshSummaries ToolTip non-empty.
  - W-08 structural test (Test-W08-SdkTabStructure.ps1, STA, against MainWindow.xaml):
    pass=10 fail=0 (WG-08-03 6 sub-tabs in order, WG-08-05 all 4 Cert Summaries
    controls present, WG-08-10 all 25 Btn*/Chk* have ToolTips).
  - Manifest/import: Import-Module -Force SP.Gui.psd1 -> IMPORT OK (no errors).

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-18 -> DONE (DEFER ratified; sub-tab cleanly disabled)

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

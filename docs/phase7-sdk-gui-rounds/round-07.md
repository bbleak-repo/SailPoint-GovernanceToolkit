# Round 7
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-07 -- SdkTab.xaml (nested 6 sub-tabs + controls + tooltips)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-07 row + section)
- `docs/planning/PHASE7_GUI_SDK_TAB.md` (sub-tab control tables, lines 78-277; Color/Style Notes, lines 549-556)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Gui/AuditTab.xaml` (template: root `<Grid x:Name="*TabContent">`, Grid.Resources ToolkitButton/SecondaryButton, DataGrid block, gray-italic status labels)
- `Gui/MainWindow.xaml:255-302` (production DataGrid + ColumnHeaderStyle markup mirrored)
- `Gui/GovernanceTab.xaml` (badge StackPanel/Border pattern for summary panels)

**Did:** Created `Gui/SdkTab.xaml` as a standalone DESIGN-REFERENCE XAML (not loaded
at runtime; SDK-08 will inline it into MainWindow.xaml). Root is
`<Grid x:Name="SdkTabContent" Background="#1E1E2E" Margin="12,8">` with a
`Grid.Resources` carrying local copies of `ToolkitButton`/`SecondaryButton`
(verbatim from AuditTab) plus a shared `SdkColumnHeaderStyle` so the file
self-parses under `XamlReader::Load` (WPF note 5). Single child is
`<TabControl x:Name="SdkSubTabControl">` with exactly 6 `<TabItem>`s in order
Templates, Cert Summaries, Approvals, Work Items, Workflows, Filters (WG-08-03).
Each sub-tab uses the toolkit row pattern (Auto toolbar / optional summary or
badge row / `*` DataGrid / Auto gray-italic status). Every mandated x:Name from
WG-08-04..09 is present (51 named controls). Every `Btn*`/`Chk*` (and the
`Rb*` radios) carry a non-empty inline `ToolTip` with the exact plan strings
(WG-08-10). Checkbox-flagged columns (Scheduled, Completed, Enabled,
System Filter) are `DataGridCheckBoxColumn`; all grids use
`AutoGenerateColumns="False"`, `AlternatingRowBackground="#252538"`, and an
explicit `DataGrid.Columns` block. Work Items/Approvals/Cert Summaries use the
Governance-tab badge `Border`/`StackPanel` pattern. No PowerShell, no event
wiring, no bridge calls, no live-DataContext bindings beyond simple
`{Binding <Prop>}` column bindings (which parse without a DataContext).

**Plan-vs-code disagreement (flagged, no escalation needed):** the plan prose and
`GovernanceTab.xaml` use a `<Window>` root, but the live design-reference files
(`AuditTab.xaml`, `CampaignTab.xaml`) and the inline target in `MainWindow.xaml`
use a `<Grid x:Name="*TabContent">` root. Trusted the code -> used
`<Grid x:Name="SdkTabContent">` so SDK-08 inlines cleanly.

**Scope note (DEFERRED-AS-DESIGNED):** Cert Summaries ship-vs-defer is SDK-18's
decision (depends on SDK-11). SDK-07 provides only the static structure +
x:Names WG-08-05 requires (CboSdkCertCampaign, CboSdkCertification,
CboSdkAccessType, SdkCertSummaryGrid, BtnSdkRefreshSummaries,
SdkCertSummaryStatusLabel, SdkDecisionSummaryPanel) -- no enable/disable or
"coming soon" affordance added now.

**Files:** `Gui/SdkTab.xaml` (new); `docs/phase7-sdk-gui-backlog.md` (status ->
DONE); `docs/phase7-sdk-gui-rounds/round-07.md` (this file).

**Verification:**
  - Pester: P=34 F=0 Total=34 on `Tests/SP.SdkBridge.Tests.ps1` (nearest affected
    suite; no Pester test targets the new XAML directly -- SDK-07 is additive and
    the SDK-15 W-08 structural test does not exist yet). SdkTab.xaml is not yet
    referenced by MainWindow.xaml, so no regression surface.
  - XAML parse: ok -- `[System.Windows.Markup.XamlReader]::Load` over an
    `XmlNodeReader` of `[xml](Get-Content)` succeeds in an STA PS 5.1 session
    (returns a `Grid`). All 51 required x:Names resolve via `FindName`; the 6
    sub-tab headers match the required order; all 25 `Button`/`CheckBox`
    elements (and the 2 `RadioButton`s) carry a non-empty `ToolTip`; checkbox
    columns are `DataGridCheckBoxColumn`. (Fixed an initial XML failure: comments
    may not contain `--`; reworded the header/comment text.)
  - Manifest/import: n/a (no module/manifest touched).

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-07 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

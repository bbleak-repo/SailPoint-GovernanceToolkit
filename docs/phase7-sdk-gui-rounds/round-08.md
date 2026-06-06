# Round 8
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-08 -- MainWindow.xaml: add SDK Features TabItem (before Settings)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-08 table row + per-item section)
- `docs/planning/PHASE7_GUI_SDK_TAB.md` (Tab Layout Design sub-tab tables WG-08-04..10,
  Safety & What-If Integration, Windows WPF Framework Notes 4/5/6, GUI Testing Methods)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Gui/MainWindow.xaml` (Campaign tab grid template lines 263-301, Governance badge
  pattern lines 896-924, Settings tab insertion point lines 1104-1116, Window header
  lines 1-14)

**Did:**
Inserted one additive `<TabItem Header="SDK Features" Style="{StaticResource ToolkitTabItem}">`
into MainTabControl between the Governance `</TabItem>` and the `<!-- Settings Tab -->`
comment, making it the 7th of 7 (index 5, immediately before Settings). Content root is
`<Grid x:Name="SdkTabContent" Background="#1E1E2E" Margin="12,8">` containing a nested
`<TabControl x:Name="SdkSubTabControl">` with 6 sub-tabs in the exact order Templates,
Cert Summaries, Approvals, Work Items, Workflows, Filters. Each sub-tab uses the
established 3-row (Workflows: 4-row) Grid layout: Auto toolbar / * DataGrid / Auto status,
with ToolkitButton (primary) and SecondaryButton (refresh/secondary) buttons, the dark
DataGrid template copied from CampaignGrid (#2D2D44 / #252538 alt rows,
AutoGenerateColumns=False, #252538/#5B9BD5 column-header style), Governance-style badge
borders for the Work Items Open/Completed/Total counts, and gray italic status TextBlocks.
Every x:Name from the plan's WG-08-04..10 tables is present verbatim (50 controls); every
Btn*/Chk* carries the plan's verbatim ToolTip text. RbSdkPending/RbSdkCompleted share
GroupName="SdkApprovalState" with RbSdkPending IsChecked=True. DataGrid columns declared
per the plan column lists with the specified Binding paths so SDK-11 binds without XAML
churn. NO new files (SdkTab.xaml not created -- live MainWindow.xaml inlines all tab
content; zero refs to SdkTab.xaml in any .ps1/.psm1/.psd1, confirmed). NO handler/runspace
wiring (SDK-10/11/12). No x:Class / code-behind; file remains XamlReader-loadable.

**Files:** modified `Gui/MainWindow.xaml`; updated `docs/phase7-sdk-gui-backlog.md`
(SDK-08 -> DONE, table + section); added this round file.

**Verification:**
  - Pester: n/a (SDK-08 is XAML-only; the structural test Test-W08-SdkTabStructure.ps1
    is SDK-15, not yet created; no SDK-08-specific Pester file exists)
  - XAML parse: ok -- `[System.Windows.Markup.XamlReader]::Load` over an `[xml]` of the
    file in `powershell -STA` (5.1 Desktop) succeeded (PARSE_OK). MainTabControl has
    exactly 7 items, headers in order Campaigns|Evidence|Audit|Delta Cert|Governance|
    SDK Features|Settings (SDK Features at idx 5). SdkSubTabControl has exactly 6 sub-tabs:
    Templates|Cert Summaries|Approvals|Work Items|Workflows|Filters. All 50 required
    x:Names resolved via FindName (MISSING_NAMES empty). Every Btn*/Chk* ToolTip non-empty
    (NO_TOOLTIP empty). RbSdkPending.IsChecked=True; both radios GroupName=SdkApprovalState.
    Window.Width=1100 / MinWidth=860 unchanged, both <= WorkArea.Width (1280) -- WPF note 4
    fit re-check passes; the nested sub-tab toolbar does not force MinWidth growth.
  - Manifest/import: n/a (no module/manifest touched)

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-08 -> DONE

**Notes / plan-vs-code:**
- Plan architecture list (line 38) names a standalone `Gui/SdkTab.xaml`; the live
  MainWindow.xaml inlines every tab's content and has no ContentControl injection
  (explicit Settings-tab comment confirms). Resolved in favor of code: content inlined
  in MainWindow.xaml, no SdkTab.xaml created.
- Scope decision (escalated, defaulted to INCLUDE): sub-tab 2 "Cert Summaries" is a
  phase-2 de-scope candidate per plan lines 108-117, but WG-08-03 (exactly 6 sub-tabs)
  and WG-08-05 (its 4 controls) require it; included as inert markup (no runtime/Safety
  risk until SDK-11/12 wire it). If the human/outer loop de-scopes to 5 sub-tabs,
  SDK-15's WG-08-03/WG-08-05 must be amended in lockstep.

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

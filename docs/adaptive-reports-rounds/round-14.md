# Round 14
**Started:** 2026-06-05 16:05:00
**Item:** AR-14 -- GUI Adaptive Reports tab (XAML)

**Read:**
- `docs/adaptive-reports-rounds/round-00-PROTOCOL.md` (loop rules, round template, headless toolbox).
- `docs/adaptive-reports-backlog.md` AR-14 spec + Phase Summary row.
- `Gui/MainWindow.xaml`: Window.Resources styles (ToolkitButton:31, SecondaryButton:65,
  ToolkitTabItem:72, FieldLabel:123, FieldBox:130, FieldCombo:151, SectionHeader:162,
  SectionBorder:169); SDK Features tab shell (1107-1116) as template; GovProgressBar block
  (1060-1064); CheckBox markup pattern (540-543); SDK status label (1181-1183); insertion
  point between SDK `</TabItem>` (1716) and Settings tab (1718-1719).

**Did:** Inserted exactly one additive `<TabItem Header="Adaptive Reports"
Style="{StaticResource ToolkitTabItem}">` after the SDK Features tab and before the
Settings tab. It hosts a single compact form (no nested TabControl): a 3-row Grid
(`AdaptiveReportsTabContent`, rows Auto/*/Auto) with a scrollable options form on row 0
and an action+progress+status block on row 2. The form provides an Anchor combo
(Entitlement default / Campaign), Theme combo (light default / dark), a Days Back textbox
(default "90"), 5 component checkboxes (KPI Cards/Top-N/Group Table checked by default,
Heatmap/Tree unchecked — mirrors CLI default `@('kpi-cards','top-n','group-table')`), and
7 baseline-report checkboxes (all unchecked — mirrors CLI default `@()`). Action row has
`BtnArGenerate` (ToolkitButton), `BtnArOpenFolder` and `BtnArOpenReport` (SecondaryButton),
`AdaptiveReportsProgressBar` (copied attrs from GovProgressBar, IsIndeterminate=False), and
`AdaptiveReportsStatusLabel` (italic muted, mirrors SdkTemplateStatusLabel). All x:Names are
namespaced `AdaptiveReports*`/`BtnAr*`/`ChkAr*`. Every `Btn*`/`Chk*` carries a non-empty
ToolTip naming its CLI token. Only existing Window.Resources styles were reused; no handler
wiring (AR-15), no x:Name added to MainTabControl or any other tab, no existing tab touched.

**Files:**
- `Gui/MainWindow.xaml` (EDIT — additive: one new `<TabItem>` inserted; nothing removed/rewired).
- `docs/adaptive-reports-backlog.md` (AR-14 → DONE in Phase Summary row + item header).
- `docs/adaptive-reports-rounds/round-14.md` (this file).

**Verification:**
  - XAML parse (XamlReader, no window): OK. headers=Campaigns|Evidence|Audit|Delta Cert|
    Governance|SDK Features|Adaptive Reports|Settings; AdaptiveReports present=True idx=6
    gov=4 settings=7 (order: gov < AR < settings); **ALL CONTROLS PRESENT** (20 named
    controls resolved via FindName).
  - ToolTip walk (LogicalTreeHelper over Adaptive subtree): Btn/Chk controls walked=15;
    **ALL TOOLTIPS PRESENT** (zero missing).
  - Pester: not run for AR-14 (XAML-only markup item; per spec only the two headless XAML
    probes are required; AR-17 will codify the W-09 structure test).
  - AST: n/a (no harness/script files touched).

**Review:** PASS (self-check pending independent code-review gate). Additive-only confirmed:
one TabItem added, existing tab list unchanged except the new entry; only pre-existing styles
referenced; no `$script:`/handlers/dispatcher in markup.

**Backlog update:** AR-14 -> DONE

**Completed:** 2026-06-05 16:12:00
**Status:** SUCCESS

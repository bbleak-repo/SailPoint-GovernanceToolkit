# Round 15
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-15 -- Test-W08-SdkTabStructure.ps1 (headless, WG-08-01..10)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-15 row + section, lines 44, 315-327)
- `docs/planning/PHASE7_GUI_SDK_TAB.md` (W-08 acceptance table, lines 476-491)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Tests/Harness/Test-W03-AuditTabStructure.ps1` (structural pattern copied verbatim: header/param/STA-gate/Add-Result/Load-Xaml/Get-NamedControl/summary-line/exit-code)
- `Gui/MainWindow.xaml` lines 1106-1671 (runtime inlined SDK content -- the load target; SdkTab.xaml NOT consulted as it is a non-runtime design reference)

**Did:** Created `Tests/Harness/Test-W08-SdkTabStructure.ps1`, a purely structural,
headless test. It loads `Gui/MainWindow.xaml` via `XamlReader::Load` (WPF note 5)
on an STA thread (WPF note 1, exit 2 gate), locates the `SDK Features` TabItem in
`MainTabControl`, takes its `.Content` (the `SdkTabContent` Grid), and asserts
WG-08-01..10: tab existence + that it precedes the Settings tab (WG-08-01); the
nested `SdkSubTabControl` TabControl (WG-08-02); exactly 6 sub-tabs in order
Templates/Cert Summaries/Approvals/Work Items/Workflows/Filters (WG-08-03);
per-sub-tab required controls (WG-08-04..09, DRY'd via a `Test-ControlsPresent`
helper returning missing names); and that every `Btn*`/`Chk*` FrameworkElement in
the subtree has a non-null, non-whitespace ToolTip (WG-08-10). It does NOT import
GUI modules, call `Initialize-SdkTab`, touch a mock, or `.Show()` the window.
Assertions target only names that exist in the runtime XAML (no `SdkCertBadge*`/
`SdkApprovalBadge*`, per the camelCase/dynamic-panel divergence). JSONL contract
matches W-03: one compressed JSON line per id + a `{summary}` tail; exit 1 on any
FAIL else 0.

**Files:** `Tests/Harness/Test-W08-SdkTabStructure.ps1` (new).

**Verification:**
  - AST parse: `[Parser]::ParseFile` -> ErrorCount=0.
  - Run: `powershell.exe -NoProfile -STA -File Tests/Harness/Test-W08-SdkTabStructure.ps1`
    exits 0 and prints 10 PASS rows + `{"summary":true,"pass":10,"fail":0,"blocked":0,"total":10}`.
    WG-08-10 confirms exactly 25 Btn*/Chk* controls, all with a non-empty ToolTip.
  - Pester: n/a (this item is a standalone harness script, not a Pester spec; verified by direct STA run).
  - XAML parse: MainWindow.xaml loads via XamlReader inside the test (implicitly green; WG-08-pre did not fire).
  - Manifest/import: n/a (no modules imported or changed).

**Disagreements flagged to outer loop (no code change needed):**
  1. SDK-08/backlog "tab is 7th of 7" is inaccurate: the live `MainTabControl`
     order is Campaigns, Evidence, Audit, Delta Cert, Governance, SDK Features,
     Settings -- so SDK Features is the 6th of 7 (index 5) and Settings remains
     last (consistent with WPF note 6 "insert before Settings"). WG-08-01
     therefore asserts existence + precedes-Settings, not literal 7th/last.
  2. Runtime `MainWindow.xaml` SDK content diverges from the `SdkTab.xaml` design
     reference: camelCase grid bindings, and the Cert-Summaries/Approvals static
     count badges (`SdkCertBadge*`, `SdkApprovalBadge*`) do not exist in the
     runtime (`SdkDecisionSummaryPanel`/`SdkApprovalSummaryPanel` are empty
     StackPanels filled dynamically). The test asserts against the runtime only.
  3. The spec's "24 Btn* + Chk*" split is off by one: the runtime has 23 `Btn*`
     + 2 `Chk*` = 25 total. WG-08-10 walks and asserts zero-missing against the
     actual count (reported as 25), rather than hardcoding the split.

**Review:** <pending -- handed to code-review gate; do not self-approve>
**Backlog update:** SDK-15 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

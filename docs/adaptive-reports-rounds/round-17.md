# Round 17
**Started:** 2026-06-05 00:00:00
**Item:** AR-17 -- Headless structure test (W-09)

**Read:** `docs/adaptive-reports-backlog.md` (AR-17 + Phase Summary);
`docs/adaptive-reports-rounds/round-00-PROTOCOL.md` (loop rules + round template);
`Tests/Harness/Test-W08-SdkTabStructure.ps1` (template to mirror);
`Gui/MainWindow.xaml` lines 1715-1874 (Adaptive Reports TabItem @1719 ->
`AdaptiveReportsTabContent` Grid @1720; Settings @1869 — verified all control
x:Names and ToolTips).

**Did:** Created `Tests/Harness/Test-W09-AdaptiveTabStructure.ps1` by copying the
W-08 harness wholesale and adapting it for the Adaptive Reports tab. Reused
verbatim: the `[CmdletBinding()] param([string]$ConfigPath)` signature,
`$ErrorActionPreference='Stop'`, the STA guard (exit 2), the `$results` list +
`Add-Result` JSONL emitter, the `$toolkitRoot`/`$mainXaml` path block, the
`Add-Type` assembly load, the four helpers (`Load-Xaml`, `Get-NamedControl`,
`Test-ControlsPresent`, `Get-FrameworkElements`), the MainWindow load + pre-FAIL
guard, and the summary block (`{summary}` + `exit 1/0`). Adapted the
SYNOPSIS/DESCRIPTION to the (flat, no-nested-TabControl) Adaptive tab, renamed IDs
to `WG-09-01..07` / `WG-09-pre`, and switched the tab-location loop to match
Header 'Adaptive Reports' vs 'Settings'. Dropped W-08's nested-TabControl tests
(WG-08-02/03). New tests: WG-09-01 (tab exists + precedes Settings), WG-09-02
(`AdaptiveReportsTabContent` Grid present), WG-09-03..06 (options /
component-checkboxes / baseline-checkboxes / actions+progress+status via the
`$controlSets` foreach pattern), WG-09-07 (every Btn*/Chk* in the subtree carries a
non-empty ToolTip). XAML-only — runs on any OS, no Show, no module import, no mock.

**Files:** `Tests/Harness/Test-W09-AdaptiveTabStructure.ps1` (CREATE — additive,
new file only); `docs/adaptive-reports-rounds/round-17.md` (this round doc);
`docs/adaptive-reports-backlog.md` (AR-17 status flip only). No existing test,
XAML, module, or validation harness touched.

**Verification:**
  - AST: `[Parser]::ParseFile` -> **AST OK** (0 errors).
  - Headless run (`powershell -NoProfile -STA -File ...`): exit **0**; all 7 emit
    `PASS`; summary `{"pass":7,"fail":0,"blocked":0,"total":7}`. Tab found at index
    6, precedes Settings at index 7 (of 8 tabs); 3 options + 5 component + 7
    baseline + 5 action controls present; all 15 Btn*/Chk* have non-empty ToolTips.
  - XAML parse: ok (window loaded via XamlReader). Manifest/import: n/a (harness
    does not import GUI modules).

**Review:** PENDING (independent code-review gate — inner does not self-approve).

**Backlog update:** AR-17 -> DONE

**Completed:** 2026-06-05 00:00:00
**Status:** SUCCESS

# Phase 7: SDK Features GUI Tab -- Backlog (SDK-01 to SDK-19)

**Created:** 2026-06-04
**Purpose:** Implement the SDK Features GUI tab end-to-end, headless-validated,
up to (but not including) the live-Windows interactive FlaUI run.
**Source:** `docs/planning/PHASE7_GUI_SDK_TAB.md` (Opus 4.8 reviewed/reconciled).
**Branch:** `feature/phase7-sdk-gui-tab`
**Execution:** 3-loop autonomous process -- see
`docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md`.

---

## How to Use This File

Agent loop order: `SDK-01 -> SDK-02 -> ... -> SDK-19`, respecting `Depends On`.
The outer orchestrator picks the lowest-numbered `TODO` whose dependencies are
all `DONE`. Each item is sized S/M/L. CRITICAL/HIGH first.

**GUI-testing boundary:** every item except **SDK-19** is headless-verifiable in
the loop (Pester + XAML parse + structural tree-walk). **SDK-19 (interactive
FlaUI) is DEFERRED to a live Windows GUI session** and is NOT run by the loop --
the loop only authors it.

---

## Phase Summary

| # | Priority | Feature | Size | Depends | Status |
|---|----------|---------|------|---------|--------|
| SDK-01 | CRITICAL | SP.SdkBridge.psm1 -- read functions (9) | M | none | DONE |
| SDK-02 | CRITICAL | SP.SdkBridge.psm1 -- write dispatchers (5) | M | SDK-01 | DONE |
| SDK-03 | CRITICAL | Safety/What-If integration in write dispatchers | M | SDK-02 | DONE |
| SDK-04 | HIGH | SP.Gui.psd1 -- register SP.SdkBridge + exports | S | SDK-01 | DONE |
| SDK-05 | HIGH | Import-TestModules.ps1 -- load bridge for tests | S | SDK-01 | DONE |
| SDK-06 | HIGH | Tests/SP.SdkBridge.Tests.ps1 (SDK-BR-001..007 + Safety) | M | SDK-02,03,05 | DONE |
| SDK-07 | HIGH | SdkTab.xaml -- nested 6 sub-tabs + controls + tooltips | L | none | DONE |
| SDK-08 | HIGH | MainWindow.xaml -- add SDK Features TabItem (before Settings) | M | SDK-07 | DONE |
| SDK-09 | HIGH | 3 modal dialog XAMLs (Schedule/Workflow/Approval) | M | none | DONE |
| SDK-10 | HIGH | Initialize-SdkTab region in SP.MainWindow.psm1 | L | SDK-08 | DONE |
| SDK-11 | HIGH | Wire 5 data-loading sub-tabs via bridge + runspace | L | SDK-10,01 | DONE |
| SDK-12 | HIGH | Wire write actions + confirm dialogs (uses SDK-09) | L | SDK-11,03,09 | DONE |
| SDK-13 | HIGH | Show-SPDashboard.ps1 -- add SP.Sdk + Initialize-SdkTab call | S | SDK-10 | DONE |
| SDK-14 | MEDIUM | Mock parity audit: every bridge read has seed/handler | M | SDK-01 | DONE |
| SDK-15 | MEDIUM | Test-W08-SdkTabStructure.ps1 (headless, WG-08-01..10) | M | SDK-08,09 | DONE |
| SDK-16 | MEDIUM | Invoke-FullGuiValidation.ps1 -- register W-08 + W-08b | S | SDK-15 | DONE |
| SDK-17 | MEDIUM | OutputMode/Both consistency: CampaignSearch (or relax test) | S | none | DONE |
| SDK-18 | LOW | Cert Summaries sub-tab (SCOPE DECISION -- may defer to phase 2) | M | SDK-11 | DEFERRED |
| SDK-19 | DEFERRED | Test-W08b-SdkTabInteractive.ps1 -- AUTHOR only; run live | L | SDK-15,16 | TODO |

Exit criteria for the loop: SDK-01..SDK-17 `DONE`, SDK-18 `DONE` or explicitly
`DEFERRED`, SDK-19 authored (`AUTHORED`, not run). Full Pester suite green
(954+ new bridge tests), W-08 headless green, no parse/XAML errors.

---

## SDK-01: SP.SdkBridge.psm1 -- read functions

- **Status:** `DONE`
- **Depends On:** none
- **Size:** M

**Goal:** New `Modules/SP.Gui/SP.SdkBridge.psm1`. Implement the 6 read bridge
functions, each returning `@{ Success; Data; Error }` and shaping rows for
DataGrid binding (add `IsSelected` for checkbox columns, keep `_Raw` for detail).

Functions + backing SP.Sdk calls (see mapping table in the plan):
`Get-SPGuiSdkCampaignTemplates`, `Get-SPGuiSdkCertSummaries`,
`Get-SPGuiSdkDecisionSummary`, `Get-SPGuiSdkApprovals`,
`Get-SPGuiSdkWorkItems`, `Get-SPGuiSdkWorkflows`,
`Get-SPGuiSdkWorkflowExecutions`, `Get-SPGuiSdkCampaignFilters`,
`Get-SPGuiSdkCertCampaigns`.

**Files:** `Modules/SP.Gui/SP.SdkBridge.psm1` (new).
**Accept:** module imports clean; each function returns the documented shape when
the underlying SP.Sdk call is mocked.

---

## SDK-02: SP.SdkBridge.psm1 -- write dispatchers

- **Status:** `DONE`
- **Depends On:** SDK-01
- **Size:** M

**Goal:** Implement the 5 write dispatchers using the `-Action <Verb>` pattern:
`Invoke-SPGuiSdkTemplateAction` (Create|Update|Delete|SetSchedule|RemoveSchedule),
`Invoke-SPGuiSdkApprovalAction` (Approve|Deny|Forward),
`Invoke-SPGuiSdkWorkItemAction` (Complete|Forward|BulkApprove|BulkReject),
`Invoke-SPGuiSdkWorkflowAction` (Toggle|Test|CreateOOO),
`Invoke-SPGuiSdkFilterAction` (Create|Update|Delete). Map each verb to the
verified SP.Sdk function in the plan's mapping table.

**Files:** `Modules/SP.Gui/SP.SdkBridge.psm1`.
**Accept:** each verb routes to the correct SP.Sdk call (verified via mock);
unknown verb returns `Success=$false` with a clear error.

---

## SDK-03: Safety / What-If integration

- **Status:** `DONE`
- **Depends On:** SDK-02
- **Size:** M

**Goal:** Every destructive verb honors the `Safety` config (see plan's "Safety &
What-If Integration" section). Honor `RequireWhatIfOnProd` (confirm before
executing on non-mock), `AllowCompleteCampaign`-style terminal gates, and bulk
caps; return `@{Success=$false; Error='blocked by Safety...'}` when a gate
refuses (no thrown exception). Mirror `Invoke-GuiTestRun`'s MessageBox pattern
(`SP.MainWindow.psm1:~468`) for confirmations.

**Files:** `Modules/SP.Gui/SP.SdkBridge.psm1`.
**Accept:** Pester proves a destructive verb is blocked when its Safety gate is
off and proceeds when on.

---

## SDK-04: Register SP.SdkBridge in SP.Gui.psd1

- **Status:** `DONE`
- **Depends On:** SDK-01
- **Size:** S

**Goal:** Add `SP.SdkBridge.psm1` to `NestedModules` and the bridge function
names to `FunctionsToExport` in `Modules/SP.Gui/SP.Gui.psd1`.

**Files:** `Modules/SP.Gui/SP.Gui.psd1`.
**Accept:** `Import-Module SP.Gui.psd1` exposes the bridge functions;
`Test-ModuleManifest` passes.

---

## SDK-05: Import-TestModules.ps1 -- bridge loadable in tests

- **Status:** `DONE`
- **Depends On:** SDK-01
- **Size:** S

**Goal:** Import `SP.SdkBridge.psm1` flat (top-level, not via psd1) so
`Mock -ModuleName SP.SdkBridge` reaches the call sites under PS 5.1 -- add it to
the existing `-Gui` path (or a `-SdkBridge` flag) in `Tests/Import-TestModules.ps1`.

**Files:** `Tests/Import-TestModules.ps1`.
**Accept:** a smoke test can mock an SP.Sdk function inside SP.SdkBridge scope.

---

## SDK-06: Bridge Pester tests

- **Status:** `DONE`
- **Depends On:** SDK-02, SDK-03, SDK-05
- **Size:** M

**Goal:** `Tests/SP.SdkBridge.Tests.ps1` covering SDK-BR-001..007 (grid-bindable
shape, IsSelected, pending/completed columns, items+summary, workflow enabled/
trigger, action routing) PLUS Safety-gate cases from SDK-03. Mock the SP.Sdk
functions at module level.

**Files:** `Tests/SP.SdkBridge.Tests.ps1` (new).
**Accept:** all new tests pass; included in the full-suite run.

---

## SDK-07: SdkTab.xaml

- **Status:** `DONE`
- **Depends On:** none
- **Size:** L

**Goal:** Build `Gui/SdkTab.xaml`: a nested `TabControl` with 6 sub-tabs
(Templates, Cert Summaries, Approvals, Work Items, Workflows, Filters), each with
the controls/x:Names/columns in the plan. Every Btn*/Chk* gets a non-empty
ToolTip. Use `ToolkitTabItem`, dark button styles, alternating DataGrid rows,
gray-italic status labels (match existing tabs).

**Files:** `Gui/SdkTab.xaml` (new).
**Accept:** XAML parses via `XamlReader`; all required x:Names present (checked by
SDK-15). Cert Summaries sub-tab respects SDK-18 scope decision.

---

## SDK-08: MainWindow.xaml -- add SDK Features TabItem

- **Status:** `DONE`
- **Depends On:** SDK-07
- **Size:** M

**Goal:** Insert the `SDK Features` TabItem between Governance and Settings,
hosting SdkTab content. Re-verify the window still fits the work area after the
wider toolbar (WPF note 4 / FlaUI (0,0) risk).

**Files:** `Gui/MainWindow.xaml`.
**Accept:** XAML parses; tab is 7th of 7; structural test (SDK-15) finds it.

---

## SDK-09: Modal dialog XAMLs

- **Status:** `DONE`
- **Depends On:** none
- **Size:** M

**Goal:** `Gui/SdkTemplateScheduleDialog.xaml`, `Gui/SdkWorkflowDialog.xaml`,
`Gui/SdkApprovalActionDialog.xaml` -- each a `Window` with `BtnOK`/`BtnCancel`
and the fields in the plan, designed to be driven by `Show-SPGuiDialog` (no
code-behind).

**Files:** 3 new XAML files under `Gui/`.
**Accept:** each parses; x:Names match the `-ControlNames` the handlers will pass.

---

## SDK-10: Initialize-SdkTab region

- **Status:** `DONE`
- **Depends On:** SDK-08
- **Size:** L

**Goal:** Add `#region SDK Features Tab` to `SP.MainWindow.psm1`:
`Initialize-SdkTab` that captures `$module = $script:ThisModule`, finds controls
via `Find-Control`, declares the 7 `ObservableCollection`s, and wires every
handler with `& $module { } + .GetNewClosure()` (WPF note 2). Wire the sub-tab
`SelectionChanged` and checkbox/radio events. Do NOT make API calls on the UI
thread (use the runspace pattern in SDK-11).

**Files:** `Modules/SP.Gui/SP.MainWindow.psm1`.
**Accept:** function parses; no `$script:` access inside raw delegates.

---

## SDK-11: Wire data-loading sub-tabs (runspace)

- **Status:** `DONE`
- **Depends On:** SDK-10, SDK-01
- **Size:** L

**Goal:** Refresh handlers for Templates, Approvals, Work Items, Workflows,
Filters run on a background STA runspace (WPF note 3): import SP.Core/SP.Api/
SP.Sdk/SP.Gui in the runspace, call the bridge read function, marshal rows back
via `$MainWindow.Dispatcher` into the ObservableCollection. Populate summary
badges/labels.

**Files:** `Modules/SP.Gui/SP.MainWindow.psm1`.
**Accept:** against the mock, each grid populates with the verified seed counts.

---

## SDK-12: Wire write actions + confirms

- **Status:** `DONE`
- **Depends On:** SDK-11, SDK-03, SDK-09
- **Size:** L

**Goal:** Action buttons call the write dispatchers through the runspace, show
`Show-SPGuiDialog` modals where needed (schedule/test/forward/deny), confirm
destructive actions with affected-count, surface Safety blocks in the status
label, and refresh the affected grid on success.

**Files:** `Modules/SP.Gui/SP.MainWindow.psm1`.
**Accept:** headless logic paths covered where possible; full interactive proof
deferred to SDK-19.

---

## SDK-13: Show-SPDashboard.ps1 wiring

- **Status:** `DONE`
- **Depends On:** SDK-10
- **Size:** S

**Goal:** Add `SP.Sdk\SP.Sdk.psd1` to the module-load chain (after SP.Audit) and
call `Initialize-SdkTab` in the tab-init sequence (before Settings).

**Files:** `Scripts/Show-SPDashboard.ps1`, `Modules/SP.Gui/SP.MainWindow.psm1`
(the named `Initialize-SdkTab` call lives in the latter's tab-init sequence; the
backlog Files list was incomplete).
**Accept:** launcher parses; module chain loads SP.Sdk.

**Done:** SP.Sdk added to load chain between SP.Audit and SP.Gui with
`Required = $true` (deviates from plan snippet's `$false`; SP.Gui's SDK runspace
hard-imports SP.Sdk.psd1 so fail-fast is correct -- flagged to outer loop).
`Initialize-SdkTab -TabContent $sdkTab` invoked before the Settings tab block.
Verified: AST clean both files; fresh-session chain loads SP.Sdk and resolves
`Get-SPSdkCampaignTemplates`; Test-ModuleManifest OK; SP.SdkBridge tests P=38 F=0.

---

## SDK-14: Mock parity audit

- **Status:** `DONE`
- **Depends On:** SDK-01
- **Size:** M

> **Round 14 (DONE, documentation-only):** Audited all 11 read paths (5 non-cert
> bridges + `Get-SPGuiSdkCertCampaigns` + the 3 cert-summary handlers, incl. the
> ENTITLEMENT / ROLE / ACCESS_PROFILE access-summary splits) -- full coverage
> table in `docs/phase7-sdk-gui-rounds/round-14.md`. Every read is COVERED except
> one parity hole: `access-summaries/{ROLE,ACCESS_PROFILE}` has 0 fixtures (all 81
> seed ARIs are `access.type=ENTITLEMENT`; 0/81 carry `access.id`). Filling it is
> GATED by the SDK-18 ship-vs-defer decision (escalated to outer loop), so it is
> FLAGGED as an SDK-18 sub-task with NO mock edit this round. Default path
> (-AccessType ENTITLEMENT), identity-summaries, and decision-summary are all
> covered via dynamically-derived `accessReviewItems`.

**Goal:** Confirm `API-MockServer/Profiles/SailPoint-ISC` (seed + SdkHandlers)
serves every endpoint the bridge reads call -- especially the **cert-summary**
fixtures (the one unverified area, ties to SDK-18). Log any missing fixtures as
a sub-task; add them to the mock if trivial.

**Files:** (mock repo) `Profiles/SailPoint-ISC/*` as needed; note-only otherwise.
**Accept:** documented coverage list; gaps either filled or flagged for SDK-18.

---

## SDK-15: Test-W08-SdkTabStructure.ps1 (headless)

- **Status:** `DONE`
- **Depends On:** SDK-08, SDK-09
- **Size:** M

**Goal:** Headless structural test (WG-08-01..10): load MainWindow.xaml without
showing, assert the SDK tab, nested TabControl, all 6 sub-tab headers, each
sub-tab's required controls, and that every Btn*/Chk* has a ToolTip. Runs on any
OS. Pattern: `Test-W03-AuditTabStructure.ps1`.

**Files:** `Tests/Harness/Test-W08-SdkTabStructure.ps1` (new).
**Accept:** green headless on Windows (and macOS).

---

## SDK-16: Register W-08 with the orchestrator

- **Status:** `DONE`
- **Depends On:** SDK-15
- **Size:** S

**Goal:** Add W-08 (headless) and a W-08b stub invocation to
`Tests/Harness/Invoke-FullGuiValidation.ps1`.

**Files:** `Tests/Harness/Invoke-FullGuiValidation.ps1`.
**Accept:** full GUI validation lists W-08; W-08b shows as deferred/skipped until
run live.

---

## SDK-17: OutputMode/Both consistency

- **Status:** `DONE`
- **Depends On:** none
- **Size:** S

**Problem:** `Invoke-SPCampaignSearch.ps1` `OutputMode` ValidateSet is
`Console/JSON/CSV/HTML` -- missing `Both`, which every other script declares. The
CLI-004 consistency test (`SP.CliScripts.Tests.ps1`) now fails on it (the test
was previously masked by a discovery bug, fixed 2026-06-04).

**Fix (decide in the middle loop):** EITHER add `Both` to CampaignSearch and
implement the Console+JSON branch, OR relax CLI-004 to allow richer taxonomies
(require only Console+JSON universally). Record the decision in the round file.

**Files:** `Scripts/Invoke-SPCampaignSearch.ps1` or `Tests/SP.CliScripts.Tests.ps1`.
**Accept:** CLI-004 green; rationale documented.

**Decision (round-17):** CHOSEN -- added `Both` to CampaignSearch's ValidateSet
(`Console/JSON/CSV/HTML/Both`, preserving the richer CSV/HTML taxonomy) AND fixed
the output gates rather than relaxing CLI-004. Console gate retargeted from
`Console || JSON` to `-in @('Console','Both')`; JSON gate from `eq 'JSON'` to
`-in @('JSON','Both')`. This keeps the universal Console/JSON/Both invariant
enforced across all 20+ OutputMode scripts and incidentally fixes a latent bug
where `JSON` mode also dumped the full tabular console view (now JSON is pure
JSON, `Both` = console + JSON). Comment-based help updated to mention `Both`.
Verified: CLI-004 `All scripts with OutputMode use ValidateSet Console/JSON/Both`
now PASSES; `Invoke-Pester` on `SP.CliScripts.Tests.ps1` => P=71 F=0; AST parse
clean. SDK-17 is CLI-only -- no XAML/WPF/bridge code touched, so the WPF Framework
Notes and GUI Testing Methods do not apply.

---

## SDK-18: Cert Summaries sub-tab (SCOPE DECISION)

- **Status:** `DEFERRED`
- **Depends On:** SDK-11
- **Size:** M

**Decision:** ship now or defer to phase 2 (see plan's SCOPE DECISION callout).
If shipping: requires SDK-14 cert-summary mock fixtures + the campaign->cert
combo cascade + a W-08b test. If deferring: mark the sub-tab disabled/hidden with
a "coming soon" note and set Status `DEFERRED`.

**Files:** `Gui/SdkTab.xaml`, `Modules/SP.Gui/SP.MainWindow.psm1`.
**Accept:** either functional + tested, or cleanly disabled and documented.

**Decision (round-18, FLAGGED FOR HUMAN RATIFICATION): DEFER.** Three blockers
make SHIP unverifiable in the headless loop: (1) the campaign->certification combo
cascade has no real backing -- `Get-SPGuiSdkCertifications` does not exist anywhere
and SP.Api has no campaign-list function; (2) the mock has 0 ROLE/ACCESS_PROFILE
access-summary fixtures (round-14 verified 0/81 seed ARIs carry `access.id`); (3)
the W-08b interactive test for this sub-tab is unwritten and is outside the headless
loop boundary. Cleanly disabled instead: the `Cert Summaries` TabItem header and all
four structural x:Names (`CboSdkCertCampaign`, `CboSdkCertification`,
`CboSdkAccessType`, `SdkCertSummaryGrid`) are preserved so WG-08-03/05 stay green;
the three ComboBoxes and `BtnSdkRefreshSummaries` are `IsEnabled="False"`; the
DataGrid is `Visibility="Collapsed"` (kept in the tree) under a visible
`SdkCertSummaryComingSoon` overlay ("Coming in a future release.");
`Invoke-SdkCertSummaryRefresh` stays a documented no-op that only sets the deferred
status label (no bridge/API/runspace call). The SP.Sdk-layer tests
(`Tests/SP.SdkCertSummaries.Tests.ps1` SDK-CERT-001..006) and the bridge functions
remain untouched and passing. No W-08b authored for this sub-tab (SDK-19 should omit
the Cert Summaries interactive steps).

---

## SDK-19: Test-W08b-SdkTabInteractive.ps1 (AUTHOR ONLY -- DEFERRED RUN)

- **Status:** `TODO`
- **Depends On:** SDK-15, SDK-16
- **Size:** L

**Goal:** Author the interactive FlaUI test (WG-08-11..22) using
`SP.UiTest.psm1`: navigate to the tab, Refresh each grid and assert the verified
seed counts, toggle pending/completed, check badges, screenshots. Budget 5000ms
for any step that triggers a bridge/runspace call.

**DO NOT RUN in the loop** -- it needs a live Windows GUI + mock at :8080. The
loop marks this `AUTHORED`. A human runs it in the Windows GUI session as the
final acceptance gate.

**Files:** `Tests/Harness/Test-W08b-SdkTabInteractive.ps1` (new).
**Accept:** file parses, structurally sound; execution deferred.

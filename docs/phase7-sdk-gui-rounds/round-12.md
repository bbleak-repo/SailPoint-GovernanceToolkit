# Round 12
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-12 -- Wire write actions + confirm dialogs (Show-SPGuiDialog)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-12 table row + per-item section)
- `docs/planning/PHASE7_GUI_SDK_TAB.md` (bridge mapping table; "Safety & What-If
  Integration"; "Windows WPF Framework Notes" 1-6; "GUI Testing Methods")
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- Code: `Modules/SP.Gui/SP.MainWindow.psm1` -- SDK-11 read engine
  `Invoke-SdkGridRefresh` (:3965), `Invoke-GuiTestRun` Safety guard (:464-490),
  `Show-SPGuiDialog` (:161), `Initialize-SdkTab` + the 13 action stubs, the 5
  refresh helpers, `Set-SdkSubTabStatus`.
- Code: `Modules/SP.Gui/SP.SdkBridge.psm1` -- the 5 write dispatchers
  (`Invoke-SPGuiSdk{Template,Approval,WorkItem,Workflow,Filter}Action`) +
  `Get-SPGuiSdkWorkflowExecutions`; their ValidateSet/-Action contracts and the
  SDK-03 `Test-SPGuiSdkSafetyGate` calls.
- XAML: `Gui/SdkTemplateScheduleDialog.xaml`, `Gui/SdkApprovalActionDialog.xaml`,
  `Gui/SdkWorkflowDialog.xaml` (x:Name inventory).
- Tests: `Tests/SP.SdkBridge.Tests.ps1` (baseline P=34; SDK-03 gate cases).

**Did:**
Replaced the 13 deferred SDK action stubs in the `#region SDK Features Tab`
helpers with real handlers and added a private DRY write engine. Added
`Invoke-SdkActionRun` (modeled exactly on the SDK-11 read engine
`Invoke-SdkGridRefresh`: background STA runspace re-importing
SP.Core/SP.Api/**SP.Sdk\SP.Sdk.psd1**/**SP.Gui\SP.Gui.psd1**, 500ms
DispatcherTimer, `& $module {...}.GetNewClosure()` Tick re-entry, shared
`$script:IsSdkRunning` guard) -- the runspace ONLY runs the dispatcher and
touches no UI; on Success it runs the affected sub-tab's `*Refresh` via the
`OnSuccess` scriptblock in module scope, on `@{Success=$false}` it surfaces
`Error` verbatim via `Set-SdkSubTabStatus` + `Set-StatusMessage -IsError` and
never throws. Added `Test-SdkRequireWhatIfConfirm` (mirrors
`Invoke-GuiTestRun:464-490`: `Get-SPConfig -ConfigPath $script:ConfigPath` +
the defensive `PSObject.Properties.Name -contains` idiom for
`Safety.RequireWhatIfOnProd` / `Global.EnvironmentName`; YesNo MessageBox; cancel
=> caller aborts with a `cancelled by user (Safety.RequireWhatIfOnProd)` status)
and `Get-SdkSelectedRow` (UI-thread `.SelectedItem` read).

Each wired handler: reads the selected grid row on the UI thread -> (where an
SDK-09 modal exists) gathers input via `Show-SPGuiDialog` -> shows an
affected-count YesNo confirm for destructive/bulk verbs -> runs the
RequireWhatIfOnProd gate -> dispatches via `Invoke-SdkActionRun`. Mapping used:
Edit Schedule->SetSchedule, Remove Schedule->RemoveSchedule, Delete->Delete
(Template); Approve/Deny/Forward->ApprovalAction (shared
`Invoke-SdkApprovalAction` driver, Deny/Forward get the confirm); Complete /
BulkApprove->WorkItemAction; Enable/Disable->Toggle (confirm only on disable);
Test->Test (UI-thread JSON parse + error surfacing); Delete Filter->FilterAction
Delete (string[]). `ViewExecutions` is a READ: it calls `Invoke-SdkGridRefresh`
against `Get-SPGuiSdkWorkflowExecutions` into `$script:SdkExecutionDataSource`,
NOT a write dispatcher.

**Scope decision (escalated in the work spec; recorded here per protocol):**
SDK-09 shipped only 3 input dialogs (SdkTemplateScheduleDialog,
SdkApprovalActionDialog, SdkWorkflowDialog). Five write verbs have NO input
modal: Template New, Filter New, Filter Edit, Workflow Create OOO
(PrimaryReviewerId + FallbackReviewerId), Work Item Forward (TargetOwnerId +
Comment). Authoring new XAML is an SDK-09-class deliverable and is OUTSIDE
SDK-12's stated Files line (`Modules/SP.Gui/SP.MainWindow.psm1` only).
DECISION (recommended path taken): SDK-12 fully wires every verb that has an
existing dialog or a safe confirm-only path -- Edit Schedule, Remove Schedule,
Delete Template, Approve, Deny, Forward (approval), Complete, Bulk Approve,
Enable/Disable, Test, View Executions, Delete Filter -- and leaves the five
dialog-less verbs with an explicit `requires <Dialog> (SDK-09 follow-up /
phase 2)` status message rather than guessing UI or expanding SDK-09 scope.

**Files:**
- MODIFIED `Modules/SP.Gui/SP.MainWindow.psm1` -- added `Test-SdkRequireWhatIfConfirm`,
  `Invoke-SdkActionRun`, `Get-SdkSelectedRow`, `Invoke-SdkApprovalAction`;
  replaced the 13 stub bodies with real handlers (5 deferred-with-status).
- MODIFIED `Tests/SP.SdkBridge.Tests.ps1` -- added the SDK-12 context
  "destructive-verb Safety block reaches the UI verbatim" (4 cases:
  Template RemoveSchedule + WorkItem BulkApprove, blocked + proceeds each).
- CREATED `docs/phase7-sdk-gui-rounds/round-12.md` (this file).

**Verification:**
  - Parse: `[Parser]::ParseFile` on SP.MainWindow.psm1 -> 0 errors (PS 5.1 Desktop).
  - Import: `Import-Module Modules/SP.Gui/SP.Gui.psd1 -Force` -> OK; Show-SPDashboard exported.
  - AST static: 10 AddScript runspace blocks -> 0 contain MessageBox/ShowDialog/
    Show-SPGuiDialog; the write-engine runspace import list includes
    SP.Sdk\SP.Sdk.psd1 AND SP.Gui\SP.Gui.psd1. No `$script:` token in any raw
    SDK Add_Click/Add_Tick delegate body (the only 4 raw-`$script:` hits are the
    pre-existing Wire-MenuHandlers handlers, unchanged by SDK-12).
  - Pester (SP.SdkBridge.Tests.ps1, New-PesterConfiguration): **P=38 F=0**
    Skipped=0 Total=38 (baseline 34 + 4 SDK-12 cases; no regressions).
  - XAML parse (powershell -STA, XamlReader over [xml]): all 3 SDK-09 dialogs
    load and every referenced x:Name is present
    (CboScheduleType/TxtScheduleHours/TxtScheduleDays/CboScheduleTimeZone/
    TxtScheduleExpiration; TxtComment/TxtForwardTo; TxtTestInput; BtnOK/BtnCancel).
  - Interactive proof (real window populate/click/confirm) is DEFERRED to
    SDK-19 W-08b -- the (0,0) mouse-jump / DPI-fit interaction and live modal
    flow only manifest with a visible STA window (testing note 6).

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-12 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

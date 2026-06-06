# Round 11
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-11 -- Wire 5 data-loading sub-tabs via bridge + STA runspace

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-11 Problem/Fix/Files/Accept; dependency map)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template)
- `Modules/SP.Gui/SP.MainWindow.psm1`: data-source declarations (:54-61), the
  `Invoke-GuiAuditRun` runspace skeleton (:1625-1757), the in-place
  `.Clear()/.Add()` pattern (:1467-1471), and the SDK-10 refresh stubs
  (Set-SdkSubTabStatus, Invoke-SdkSubTabLoad, the 5 *Refresh stubs).
- `Modules/SP.Gui/SP.SdkBridge.psm1`: shapes of Get-SPGuiSdkCampaignTemplates,
  Get-SPGuiSdkApprovals (Pending/Completed column sets), Get-SPGuiSdkWorkItems
  (Data + Summary), Get-SPGuiSdkWorkflows, Get-SPGuiSdkCampaignFilters.
- `Gui/SdkTab.xaml`: control names (RbSdkPending/RbSdkCompleted,
  ChkSdkShowCompleted, ChkSdkIncludeSystem, SdkApprovalBadgePending/Approved/
  Rejected, SdkWiBadgeOpen/Completed/Total, the WorkItem State column).

**Did:**
Added a single private DRY engine `Invoke-SdkGridRefresh` that mirrors the
`Invoke-GuiAuditRun` runspace skeleton: opens a background STA runspace, sets
inputs (ToolkitRoot, MainWindow, BridgeFunction, BridgeArgs, DataSource) via
SessionStateProxy, AddScript re-imports the empty runspace's modules
(SP.Core, SP.Api, SP.Sdk\SP.Sdk.psd1, SP.Gui\SP.Gui.psd1 -- SP.Gui carries
SP.SdkBridge as a nested module), calls `& $BridgeFunction @BridgeArgs`, and
marshals rows back via `$MainWindow.Dispatcher.Invoke([System.Action]{...})`
using in-place `.Clear()/.Add()` on the bound ObservableCollection. A 500ms
DispatcherTimer polls `InvocationStateInfo.State`; its Tick body is wrapped in
`& $capturedModule {...}.GetNewClosure()`, sets the status label, runs the
optional `-OnLoaded ($result,$TabContent)` hook (also in module scope), disposes
the runspace, and resets the `$script:IsSdkRunning` re-entrancy guard in a
`finally`. Rewrote the 5 data-loading refresh stubs to call this engine:
Templates and Workflows are plain loads; Approvals reads RbSdkPending/Completed
on the UI thread, passes `-State`, and rebuilds the Pending/Approved/Rejected
badges in OnLoaded; Work Items reads ChkSdkShowCompleted, sets the open/
completed/total badges from `$result.Summary`, and applies an open-only filter
from the full Data set in OnLoaded (no second API hit); Filters reads
ChkSdkIncludeSystem and forwards `-IncludeSystem`. Cert Summaries was left a
stub (message changed to "deferred to SDK-18"). No write/action helper was
touched. No control or collection is mutated off the Dispatcher; no `$script:*`
is read inside a raw delegate.

**Files:**
- MODIFIED `Modules/SP.Gui/SP.MainWindow.psm1` (added Invoke-SdkGridRefresh;
  replaced 5 *Refresh bodies; reworded Cert Summary stub).
- CREATED `docs/phase7-sdk-gui-rounds/round-11.md`.
- MODIFIED `docs/phase7-sdk-gui-backlog.md` (SDK-11 -> DONE in table + section).

**Verification:**
  - Parse: `[Parser]::ParseFile` on SP.MainWindow.psm1 -> PARSE OK (0 errors).
  - Import: `Import-Module SP.Gui.psd1 -Force` (PS 5.1 Desktop) -> ok, no errors.
    All 6 new/changed helpers present in the SP.MainWindow nested-module scope
    (Invoke-SdkGridRefresh + the 5 *Refresh) verified via
    `& $nestedModule { Get-Command ... }`.
  - Pester: `Tests/SP.SdkBridge.Tests.ps1` -> **P=34 F=0** Skipped=0 Total=34.
  - Static routing: each refresh passes one of Get-SPGuiSdkCampaignTemplates /
    Get-SPGuiSdkApprovals / Get-SPGuiSdkWorkItems / Get-SPGuiSdkWorkflows /
    Get-SPGuiSdkCampaignFilters (all in SP.Gui.psd1 FunctionsToExport).
  - Runspace import list (in AddScript) includes SP.Sdk\SP.Sdk.psd1 AND
    SP.Gui\SP.Gui.psd1 (string-verified).
  - Marshalling discipline: `.Clear()/.Add()` + all badge/label writes occur
    only inside `Dispatcher.Invoke([System.Action]{...})` or the
    `& $capturedModule` Tick block; verified no `$script:` token appears inside
    any raw delegate (only inside `& $capturedModule {...}` or the UI-thread
    function body).
  - XAML: n/a (no XAML touched).
  - Live grid populate (Templates=3, Approvals 4/3, WorkItems 4/2/6,
    Workflows=4, Filters=3): DEFERRED to SDK-19 W-08b (needs live window + mock
    at :8080); SDK-11 structurally supports it.

**Plan disagreements / decisions recorded (all in-item, no escalation):**
1. "5 grids" -> the tab has 6 sub-tabs + 7 collections. SDK-11 wires the 5
   verified-seed sub-tabs; Cert Summaries deferred to SDK-18; the Executions
   grid (SdkExecutionDataSource) is loaded by the Workflows "View Executions"
   action (SDK-12), so Workflows refresh only populates SdkWorkflowDataSource.
2. SP.Sdk is not yet in the dashboard module chain and Initialize-SdkTab is not
   yet called by the launcher (both SDK-13). The runspace therefore imports
   SP.Sdk itself -- correct, since a runspace starts empty (WPF note 3).
3. Single private `Invoke-SdkGridRefresh` engine drives all 5 refreshes (DRY)
   with an `-OnLoaded` post-marshal hook for badges/summary/filter, instead of
   5 near-identical ~70-line runspace blocks.
4. `ChkSdkIncludeSystem` is presently a no-op at the bridge layer
   (Get-SPGuiSdkCampaignFilters defaults to include-all, per SP.SdkBridge
   round-01); the checkbox is read and forwarded so real narrowing is a single
   bridge follow-up. Accepted for SDK-11, not blocked.
5. Approvals Pending/Completed column-set swap is a visual/SDK-12 concern; the
   grid uses fixed AutoGenerateColumns=False columns, so bound columns show the
   union. SDK-11 guarantees correct row counts + summary badges only.
   Additionally, the SdkApprovalSummaryPanel badge TextBlocks
   (SdkApprovalBadgePending/Approved/Rejected) already exist by x:Name in the
   XAML, so OnLoaded sets their `.Text` rather than rebuilding the StackPanel.

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-11 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

# Phase 7: SDK Features GUI Tab -- Windows Handoff Plan

## Context

The SP.Sdk module (66 functions across 8 .psm1 files) is complete and tested:
- 142 Pester tests passing
- 3 CLI scripts verified against mock API (localhost:8080)
- 50 mock API handlers with realistic seed data
- All validation warnings resolved

This plan adds a 7th GUI tab ("SDK Features") to the WPF dashboard with nested
sub-tabs for each SDK feature domain. The tab isolates vendor SDK-derived
functionality from the custom-built toolkit features.

---

## Architecture Overview

### New Files to Create

```
Gui/
  SdkTab.xaml                          -- SDK Features tab content (nested sub-tabs)
  SdkWorkflowDialog.xaml               -- Modal: workflow test execution
  SdkTemplateScheduleDialog.xaml       -- Modal: campaign template schedule config
  SdkApprovalActionDialog.xaml         -- Modal: approve/deny/forward approval

Modules/SP.Gui/
  SP.SdkBridge.psm1                    -- Bridge functions for SDK tab (new file)

Tests/Harness/
  Test-W08-SdkTabStructure.ps1         -- Headless structural test (XAML parse + control presence)
  Test-W08b-SdkTabInteractive.ps1      -- FlaUI interactive test (real window + mock API)
```

### Existing Files to Modify (additive only)

```
Gui/MainWindow.xaml                    -- Add 7th TabItem (SDK Features) before Settings
Modules/SP.Gui/SP.Gui.psd1            -- Add SP.SdkBridge.psm1 to NestedModules + exports
Modules/SP.Gui/SP.MainWindow.psm1     -- Add Initialize-SdkTab region + call in Show-SPDashboard
Scripts/Show-SPDashboard.ps1           -- Add SP.Sdk to module-load chain
Tests/Harness/Invoke-FullGuiValidation.ps1 -- Add W-08 test invocations
```

---

## Tab Layout Design

### Top-level: TabItem Header="SDK Features"

Position: Between "Governance" and "Settings" tabs (7th of 8).
Style: `{StaticResource ToolkitTabItem}` (matches existing tabs).

### Inner layout: Nested TabControl with 6 sub-tabs

The SDK Features tab contains a nested `<TabControl>` with sub-tabs. Each sub-tab
follows the existing toolkit pattern: status summary at top, action toolbar,
progress bar, DataGrid.

#### Sub-tab 1: "Templates" (Campaign Templates + Scheduling)

**Controls:**
| x:Name | Type | Purpose | ToolTip |
|--------|------|---------|---------|
| SdkTemplateGrid | DataGrid | Campaign template list | "Campaign templates define reusable certification campaign configurations" |
| BtnSdkRefreshTemplates | Button | Refresh template list | "Reload campaign templates from ISC" |
| BtnSdkNewTemplate | Button | Create new template | "Create a new campaign template (POST /campaign-templates)" |
| BtnSdkEditSchedule | Button | Set/edit schedule | "Set a recurring schedule for the selected template (MONTHLY, WEEKLY, ANNUALLY)" |
| BtnSdkRemoveSchedule | Button | Remove schedule | "Remove the schedule from the selected template" |
| BtnSdkDeleteTemplate | Button | Delete template | "Permanently delete the selected campaign template" |
| SdkTemplateStatusLabel | TextBlock | "3 templates loaded" | -- |

**DataGrid Columns:**
- Name (binding: name)
- ID (binding: id)
- Deadline (binding: deadlineDuration)
- Scheduled (binding: scheduled, checkbox icon)
- Modified (binding: modified)
- Owner (binding: ownerRef.name)

**Actions:**
- Refresh: `Get-SPGuiSdkCampaignTemplates` -> populate grid
- New: Show modal dialog -> `Invoke-SPGuiSdkCreateTemplate`
- Edit Schedule: Show `SdkTemplateScheduleDialog.xaml` -> `Invoke-SPGuiSdkSetSchedule`
- Remove Schedule: Confirm -> `Invoke-SPGuiSdkRemoveSchedule`
- Delete: Confirm -> `Invoke-SPGuiSdkDeleteTemplate`

#### Sub-tab 2: "Cert Summaries" (Certification Summaries)

**Controls:**
| x:Name | Type | Purpose | ToolTip |
|--------|------|---------|---------|
| CboSdkCertCampaign | ComboBox | Campaign selector | "Select a campaign to view certification summaries" |
| CboSdkCertification | ComboBox | Certification selector | "Select a certification reviewer to view identity summaries" |
| SdkCertSummaryGrid | DataGrid | Identity/access summaries | "Pre-aggregated certification statistics from ISC" |
| CboSdkAccessType | ComboBox | Access type filter | "Filter by access type: Role, Access Profile, or Entitlement" |
| BtnSdkRefreshSummaries | Button | Refresh | "Reload summaries for the selected certification" |
| SdkCertSummaryStatusLabel | TextBlock | Status | -- |
| SdkDecisionSummaryPanel | StackPanel | Decision counts | "Approve/Revoke/No Decision counts" |

**DataGrid Columns (Identity Summaries):**
- Identity Name
- Completed (checkbox)
- Total Items
- Approved
- Revoked
- No Decision

**DataGrid Columns (Access Summaries, toggled by CboSdkAccessType):**
- Access Name
- Source Name
- Completed
- Decision

**Flow:**
1. On tab load: populate CboSdkCertCampaign from existing campaign cache
2. On campaign select: call `Get-SPGuiSdkCertifications` to populate CboSdkCertification
3. On certification select: call `Get-SPGuiSdkIdentitySummaries` to populate grid
4. On access type change: call `Get-SPGuiSdkAccessSummaries` filtered by type
5. Decision summary panel always shows aggregate counts

#### Sub-tab 3: "Approvals" (Access Request Approvals)

**Controls:**
| x:Name | Type | Purpose | ToolTip |
|--------|------|---------|---------|
| SdkApprovalGrid | DataGrid | Approval list | "Pending and completed access request approvals" |
| RbSdkPending | RadioButton | Show pending | "Show pending approvals awaiting action" |
| RbSdkCompleted | RadioButton | Show completed | "Show historical completed approvals" |
| BtnSdkRefreshApprovals | Button | Refresh | "Reload approvals from ISC" |
| BtnSdkApprove | Button | Approve selected | "Approve the selected access request" |
| BtnSdkDeny | Button | Deny selected | "Deny the selected access request (comment required)" |
| BtnSdkForward | Button | Forward selected | "Forward the selected approval to another reviewer" |
| SdkApprovalSummaryPanel | StackPanel | Summary badges | "Pending / Approved / Rejected counts" |
| SdkApprovalStatusLabel | TextBlock | Status | -- |

**DataGrid Columns (Pending):**
- Name
- Requester
- Requested For
- Request Type (GRANT_ACCESS / REVOKE_ACCESS)
- Created
- Owner

**DataGrid Columns (Completed):**
- Name
- Requester
- Requested For
- State (APPROVED / REJECTED)
- Reviewed By
- Modified

**Actions:**
- Toggle Pending/Completed: switches data source + column layout
- Approve: calls `Invoke-SPGuiSdkApprovalAction -Action Approve`
- Deny: shows comment dialog (required) -> `Invoke-SPGuiSdkApprovalAction -Action Deny`
- Forward: shows `SdkApprovalActionDialog.xaml` -> `Invoke-SPGuiSdkApprovalAction -Action Forward`

#### Sub-tab 4: "Work Items" (Work Item Operations)

**Controls:**
| x:Name | Type | Purpose | ToolTip |
|--------|------|---------|---------|
| SdkWorkItemGrid | DataGrid | Work item list | "Pending work items assigned to reviewers" |
| BtnSdkRefreshWorkItems | Button | Refresh | "Reload work items from ISC" |
| BtnSdkCompleteWorkItem | Button | Complete | "Mark the selected work item as complete" |
| BtnSdkForwardWorkItem | Button | Forward | "Forward the selected work item to another reviewer" |
| BtnSdkBulkApprove | Button | Bulk Approve | "Approve all approval items within the selected work item" |
| ChkSdkShowCompleted | CheckBox | Show completed | "Include completed work items in the list" |
| SdkWorkItemSummaryPanel | StackPanel | Summary badges | -- |
| SdkWiBadgeOpen | TextBlock | Open count | "Number of open work items" |
| SdkWiBadgeCompleted | TextBlock | Completed count | "Number of completed work items" |
| SdkWiBadgeTotal | TextBlock | Total count | "Total work items across all states" |
| SdkWorkItemStatusLabel | TextBlock | Status | -- |

**DataGrid Columns:**
- Type (Certification, Approval, Remediation, ManualAction, etc.)
- Description
- Owner
- State (Pending, Finished, Rejected, Expired)
- Created
- Num Items

**Actions:**
- Refresh: calls `Get-SPGuiSdkWorkItems` + `Get-SPGuiSdkWorkItemsSummary`
- Complete: calls `Invoke-SPGuiSdkWorkItemAction -Action Complete`
- Forward: shows dialog -> `Invoke-SPGuiSdkWorkItemAction -Action Forward`
- Bulk Approve: confirm -> `Invoke-SPGuiSdkWorkItemAction -Action BulkApprove`
- Show Completed toggle: switches between open-only and all items

#### Sub-tab 5: "Workflows" (Workflow Management)

**Controls:**
| x:Name | Type | Purpose | ToolTip |
|--------|------|---------|---------|
| SdkWorkflowGrid | DataGrid | Workflow list | "ISC workflow definitions for automation" |
| BtnSdkRefreshWorkflows | Button | Refresh | "Reload workflows from ISC" |
| BtnSdkEnableWorkflow | Button | Enable/Disable | "Toggle the enabled state of the selected workflow" |
| BtnSdkTestWorkflow | Button | Test | "Test the selected workflow with sample input (workflow must be disabled)" |
| BtnSdkViewExecutions | Button | Executions | "View execution history for the selected workflow" |
| BtnSdkCreateOOO | Button | Create OOO | "Create an OOO fallback reviewer workflow" |
| SdkExecutionGrid | DataGrid | Execution list (below workflow grid) | "Recent workflow execution results" |
| SdkWorkflowStatusLabel | TextBlock | Status | -- |

**Workflow DataGrid Columns:**
- Name
- ID
- Enabled (checkbox)
- Trigger Type (EVENT, SCHEDULED, EXTERNAL)
- Execution Count
- Failure Count
- Modified

**Execution DataGrid Columns:**
- Execution ID
- Status (Completed, Failed, Running, Queued, Canceled)
- Start Time
- Close Time
- Workflow ID

**Actions:**
- Refresh: calls `Get-SPGuiSdkWorkflows`
- Enable/Disable: calls `Invoke-SPGuiSdkWorkflowAction -Action Toggle`
- Test: shows `SdkWorkflowDialog.xaml` for test input -> `Invoke-SPGuiSdkWorkflowAction -Action Test`
- Executions: calls `Get-SPGuiSdkWorkflowExecutions` for selected workflow
- Create OOO: shows dialog for primary/fallback reviewer IDs + days -> `Invoke-SPGuiSdkOOOSetup`

#### Sub-tab 6: "Filters" (Campaign Filters)

**Controls:**
| x:Name | Type | Purpose | ToolTip |
|--------|------|---------|---------|
| SdkFilterGrid | DataGrid | Campaign filter list | "Reusable campaign filters for include/exclude rules" |
| BtnSdkRefreshFilters | Button | Refresh | "Reload campaign filters from ISC" |
| BtnSdkNewFilter | Button | New | "Create a new campaign filter" |
| BtnSdkEditFilter | Button | Edit | "Edit the selected campaign filter (full replacement)" |
| BtnSdkDeleteFilter | Button | Delete | "Delete the selected campaign filter(s)" |
| ChkSdkIncludeSystem | CheckBox | Include System | "Show system-created filters alongside custom filters" |
| SdkFilterStatusLabel | TextBlock | Status | -- |

**DataGrid Columns:**
- Name
- ID
- Mode (INCLUSION / EXCLUSION)
- Description
- System Filter (checkbox)
- Modified

---

## Bridge Functions (SP.SdkBridge.psm1)

New file: `Modules/SP.Gui/SP.SdkBridge.psm1`
All functions return `@{ Success; Data; Error }` matching existing bridge pattern.

### Templates Bridge (3 functions)
```
Get-SPGuiSdkCampaignTemplates       -- loads templates + schedule status for grid
Invoke-SPGuiSdkTemplateAction       -- create / delete / set-schedule / remove-schedule
```

### Cert Summaries Bridge (2 functions)
```
Get-SPGuiSdkCertSummaries           -- loads identity or access summaries for selected cert
Get-SPGuiSdkDecisionSummary         -- loads decision aggregate for summary panel
```

### Approvals Bridge (2 functions)
```
Get-SPGuiSdkApprovals               -- loads pending or completed approvals
Invoke-SPGuiSdkApprovalAction       -- approve / deny / forward selected approval
```

### Work Items Bridge (2 functions)
```
Get-SPGuiSdkWorkItems               -- loads work items + summary
Invoke-SPGuiSdkWorkItemAction       -- complete / forward / bulk-approve
```

### Workflows Bridge (3 functions)
```
Get-SPGuiSdkWorkflows               -- loads workflow list
Get-SPGuiSdkWorkflowExecutions      -- loads executions for selected workflow
Invoke-SPGuiSdkWorkflowAction       -- enable/disable / test / create-ooo
```

**Total: 12 bridge functions**

---

## SP.MainWindow.psm1 Changes

Add a new `#region SDK Features Tab` section (insert before `#region Menu Handlers`).

### Initialize-SdkTab function
- Wire all button click handlers via `& $module { ... }` pattern (PS 5.1 module scope fix)
- Wire sub-tab SelectionChanged event
- Initialize ObservableCollections for each grid
- Wire CheckBox/RadioButton change events
- Call initial data load for the default sub-tab (Templates)

### Background runspace pattern
All API calls run in background runspaces (same pattern as Audit tab):
1. Spawn STA runspace
2. Import SP.Core + SP.Api + SP.Sdk + SP.Gui modules
3. Call bridge function
4. Marshal results back via Dispatcher
5. Timer polls for completion

### State variables
```powershell
$script:SdkTemplateDataSource     = [ObservableCollection[PSObject]]::new()
$script:SdkCertSummaryDataSource  = [ObservableCollection[PSObject]]::new()
$script:SdkApprovalDataSource     = [ObservableCollection[PSObject]]::new()
$script:SdkWorkItemDataSource     = [ObservableCollection[PSObject]]::new()
$script:SdkWorkflowDataSource     = [ObservableCollection[PSObject]]::new()
$script:SdkExecutionDataSource    = [ObservableCollection[PSObject]]::new()
$script:SdkFilterDataSource       = [ObservableCollection[PSObject]]::new()
```

---

## Show-SPDashboard.ps1 Changes

Add SP.Sdk to the module-load chain (1 line, after SP.DeltaCert):

```powershell
@{ Path = Join-Path $toolkitRoot 'Modules\SP.Sdk\SP.Sdk.psd1'; Name = 'SP.Sdk'; Required = $false }
```

Add `Initialize-SdkTab` call in the tab initialization sequence (after Governance, before Settings):

```powershell
Initialize-SdkTab
```

---

## Modal Dialogs

### SdkTemplateScheduleDialog.xaml
- Type dropdown: MONTHLY, WEEKLY, ANNUALLY, CALENDAR
- Hours field: TextBox (e.g., "9")
- Days field: TextBox (e.g., "1,15" for 1st and 15th)
- TimeZone dropdown: Common US/EU timezones
- Expiration date: DatePicker (optional)
- OK / Cancel buttons

### SdkWorkflowDialog.xaml
- Workflow name label (read-only)
- Test input: TextBox (JSON, multiline)
- Run Test / Cancel buttons
- Status label for result

### SdkApprovalActionDialog.xaml
- Action label: "Approve" / "Deny" / "Forward"
- Comment: TextBox (multiline, required for Deny)
- Forward To (identity ID): TextBox (visible only for Forward)
- OK / Cancel buttons

---

## Test Plan

### W-08: Headless Structural Tests (Test-W08-SdkTabStructure.ps1)

Runs on macOS or Windows. Loads MainWindow.xaml without showing, walks visual tree.

| Test ID | Description | Assertion |
|---------|-------------|-----------|
| WG-08-01 | SDK Features tab exists | TabItem with Header="SDK Features" found |
| WG-08-02 | Nested TabControl exists | TabControl inside SDK Features tab |
| WG-08-03 | All 6 sub-tabs present | Headers: Templates, Cert Summaries, Approvals, Work Items, Workflows, Filters |
| WG-08-04 | Templates controls exist | SdkTemplateGrid, BtnSdkRefreshTemplates, BtnSdkNewTemplate, BtnSdkEditSchedule, BtnSdkRemoveSchedule, BtnSdkDeleteTemplate |
| WG-08-05 | Cert Summaries controls exist | CboSdkCertCampaign, CboSdkCertification, SdkCertSummaryGrid, CboSdkAccessType |
| WG-08-06 | Approvals controls exist | SdkApprovalGrid, RbSdkPending, RbSdkCompleted, BtnSdkApprove, BtnSdkDeny, BtnSdkForward |
| WG-08-07 | Work Items controls exist | SdkWorkItemGrid, BtnSdkRefreshWorkItems, BtnSdkCompleteWorkItem, BtnSdkForwardWorkItem, SdkWiBadgeOpen |
| WG-08-08 | Workflows controls exist | SdkWorkflowGrid, SdkExecutionGrid, BtnSdkTestWorkflow, BtnSdkCreateOOO |
| WG-08-09 | Filters controls exist | SdkFilterGrid, BtnSdkRefreshFilters, BtnSdkNewFilter, BtnSdkDeleteFilter, ChkSdkIncludeSystem |
| WG-08-10 | All buttons have ToolTip | Every Btn* and Chk* control has non-empty ToolTip attribute |

### W-08b: Interactive FlaUI Tests (Test-W08b-SdkTabInteractive.ps1)

Runs on Windows only. Requires mock API at localhost:8080 (or -MockBaseUrl).
Uses SP.UiTest.psm1 FlaUI harness.

| Test ID | Description | Steps |
|---------|-------------|-------|
| WG-08-11 | Navigate to SDK Features tab | Click "SDK Features" tab header, verify nested TabControl visible |
| WG-08-12 | Templates: Refresh loads data | Click BtnSdkRefreshTemplates, wait for grid rows > 0, verify 3 templates from seed data |
| WG-08-13 | Templates: View schedule | Select tmpl-001 row, click BtnSdkEditSchedule, verify dialog shows MONTHLY schedule |
| WG-08-14 | Approvals: Pending/Completed toggle | Click RbSdkPending, verify 4 rows. Click RbSdkCompleted, verify 3 rows. |
| WG-08-15 | Approvals: Summary badges | Verify SdkApprovalSummaryPanel shows pending=4, approved=2, rejected=1 |
| WG-08-16 | Work Items: Summary + list | Click BtnSdkRefreshWorkItems, verify badges (open=4, completed=2, total=6), grid shows 4 pending items |
| WG-08-17 | Work Items: Show completed | Check ChkSdkShowCompleted, verify grid shows 6 items (includes finished) |
| WG-08-18 | Workflows: List + executions | Click BtnSdkRefreshWorkflows, verify 4 workflows. Select wf-001, click Executions, verify execution grid populated |
| WG-08-19 | Workflows: Enabled column | Verify wf-004 shows enabled=False, others True |
| WG-08-20 | Filters: List with system filter toggle | Click BtnSdkRefreshFilters, verify 3 filters. Uncheck ChkSdkIncludeSystem, re-refresh, verify only non-system filters |
| WG-08-21 | Tooltips visible on hover | Hover BtnSdkRefreshTemplates, verify ToolTip popup appears |
| WG-08-22 | Screenshot round | Capture screenshot of each sub-tab for visual baseline |

### Pester Tests for Bridge Functions

File: `Tests/SP.SdkBridge.Tests.ps1`
Pattern: Mock Invoke-SPApiRequest at the module level, verify bridge functions
return correctly shaped data for grid binding (IsSelected property for checkboxes,
_Raw reference for detail views, etc.).

| Test ID | Description |
|---------|-------------|
| SDK-BR-001 | Get-SPGuiSdkCampaignTemplates returns grid-bindable array with schedule status |
| SDK-BR-002 | Get-SPGuiSdkApprovals returns pending approvals with IsSelected property |
| SDK-BR-003 | Get-SPGuiSdkApprovals returns completed approvals with correct column shape |
| SDK-BR-004 | Get-SPGuiSdkWorkItems returns items + summary in single call |
| SDK-BR-005 | Get-SPGuiSdkWorkflows returns workflows with enabled/trigger info |
| SDK-BR-006 | Invoke-SPGuiSdkApprovalAction correctly handles approve/deny/forward |
| SDK-BR-007 | Invoke-SPGuiSdkWorkflowAction correctly handles test/toggle/create-ooo |

---

## Implementation Order

1. Create `SP.SdkBridge.psm1` (12 bridge functions)
2. Create `SdkTab.xaml` (design reference, ~300 lines)
3. Add SDK Features TabItem to `MainWindow.xaml` (~200 lines)
4. Create 3 modal dialog XAMLs (~80 lines each)
5. Add `Initialize-SdkTab` region to `SP.MainWindow.psm1` (~300 lines)
6. Update `SP.Gui.psd1` (add bridge module + exports)
7. Update `Scripts/Show-SPDashboard.ps1` (add SP.Sdk to module chain)
8. Create `Tests/SP.SdkBridge.Tests.ps1` (Pester)
9. Create `Tests/Harness/Test-W08-SdkTabStructure.ps1` (headless)
10. Create `Tests/Harness/Test-W08b-SdkTabInteractive.ps1` (FlaUI)
11. Update `Tests/Harness/Invoke-FullGuiValidation.ps1` (add W-08)
12. Visual smoke test: launch dashboard, navigate all sub-tabs

---

## Color/Style Notes

- Sub-tab headers: Use same `ToolkitTabItem` style as main tabs
- Summary badges: Use same badge pattern as Governance tab (colored rectangles with count text)
- Action buttons: Same dark theme button style as existing tabs
- DataGrids: Same alternating row style as Campaign/Audit grids
- Status labels: Same gray italic style as existing status labels
- ToolTips: Plain text, no markdown, describe what the button does and optionally the API endpoint

---

## Dependencies for Windows Session

- Mock API server running at localhost:8080 (or network-accessible host)
- FlaUI 4.0 DLLs in Tests/Tools/FlaUI/
- PowerShell 5.1 Desktop (STA mode for WPF)
- Pode module (for mock server if running locally)
- SP.Sdk module files (already on master after commit)

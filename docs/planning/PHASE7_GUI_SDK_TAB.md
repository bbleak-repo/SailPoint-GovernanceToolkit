# Phase 7: SDK Features GUI Tab -- Windows Handoff Plan

> **Plan status (Opus 4.8 review, 2026-06-04, Windows box):** Foundation
> verified against live code + mock. Reconciliation edits applied to the bridge
> inventory, action naming, and safety integration. New sections added for the
> Windows-only WPF framework conventions and the FlaUI GUI test harness (context
> the authoring macOS session did not have). See **"Reviewer Notes"** at the
> bottom for what was verified and what remains a scope decision.

## Context

The SP.Sdk module (8 .psm1 files + SP.Sdk.psd1) is implemented and tested:
- ~53 exported functions (the earlier "66" count included internal helpers)
- Pester tests for each SDK domain (SP.Sdk*.Tests.ps1) -- re-confirm the live
  pass count on Windows via `Invoke-Pester .\Tests\`; do not trust the historical
  "142 passing" figure until the Windows run reports it
- 3 CLI scripts verified against mock API (localhost:8080)
- 50 mock API handlers; **seed-data counts verified to match the W-08b test
  assertions exactly** (3 templates, 4 pending / 3 completed approvals,
  6 work items [4 Pending + 2 Finished], 4 workflows with wf-004 disabled,
  3 campaign filters) -- see `API-MockServer\Profiles\SailPoint-ISC`
- All validation warnings resolved

This plan adds an **SDK Features** GUI tab to the WPF dashboard with nested
sub-tabs for each SDK feature domain. The tab isolates vendor SDK-derived
functionality from the custom-built toolkit features. With the 6 current
top-level tabs (Campaigns, Evidence, Audit, Delta Cert, Governance, Settings),
this becomes the **7th of 7**, inserted before Settings.

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

Position: Between "Governance" and "Settings" tabs (7th of 7 -- the 6 current
top-level tabs are Campaigns, Evidence, Audit, Delta Cert, Governance, Settings;
verified in `Gui/MainWindow.xaml`).
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

> **SCOPE DECISION (Opus 4.8 review).** This is the least-baked sub-tab and a
> **phase-2 candidate**. The backing SDK functions exist
> (`Get-SPSdkIdentitySummaries`, `Get-SPSdkAccessSummaries`,
> `Get-SPSdkDecisionSummary`), BUT: (a) the mock SailPoint-ISC seed data was NOT
> verified to contain certification-summary fixtures (unlike templates/approvals/
> work-items/workflows/filters, which were verified exact), and (b) the original
> W-08b interactive test plan has **no test** for this sub-tab. Recommend either
> de-scoping it to a follow-up phase, or, if kept, adding mock fixtures + a
> W-08b interactive test as an explicit prerequisite. The other five sub-tabs
> have no such gap.

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
All functions return `@{ Success; Data; Error }` matching the existing
`SP.GuiBridge.psm1` pattern (verified: that shape is used throughout the
current bridge).

> **NAMING CONVENTION (canonical -- supersedes the inline "Actions:" bullets in
> the sub-tab specs above).** Each domain gets exactly one read function
> (`Get-SPGuiSdk<Domain>`) and one dispatcher for writes
> (`Invoke-SPGuiSdk<Domain>Action -Action <Verb>`). The granular names that
> appear in the per-sub-tab "Actions" lists (e.g. `Invoke-SPGuiSdkCreateTemplate`,
> `Invoke-SPGuiSdkSetSchedule`, `Invoke-SPGuiSdkOOOSetup`) are **logical
> operations**, not separate functions -- they are `-Action` verbs on the
> dispatcher below. When implementing, follow this table, not the inline bullets.

### Templates Bridge (2 functions)
```
Get-SPGuiSdkCampaignTemplates   -- loads templates + schedule status for grid
Invoke-SPGuiSdkTemplateAction   -- -Action Create | Update | Delete | SetSchedule | RemoveSchedule
```

### Cert Summaries Bridge (3 functions)  [see SCOPE NOTE on sub-tab 2]
```
Get-SPGuiSdkCertCampaigns       -- populates CboSdkCertCampaign + CboSdkCertification
                                   (uses existing SP.Api/SP.Certifications, NOT SP.Sdk)
Get-SPGuiSdkCertSummaries       -- -SummaryType Identity | Access for selected cert
Get-SPGuiSdkDecisionSummary     -- decision aggregate for the summary panel
```

### Approvals Bridge (2 functions)
```
Get-SPGuiSdkApprovals           -- -State Pending | Completed
Invoke-SPGuiSdkApprovalAction   -- -Action Approve | Deny | Forward
```

### Work Items Bridge (2 functions)
```
Get-SPGuiSdkWorkItems           -- loads work items + summary in one call
Invoke-SPGuiSdkWorkItemAction   -- -Action Complete | Forward | BulkApprove | BulkReject
```

### Workflows Bridge (3 functions)
```
Get-SPGuiSdkWorkflows           -- loads workflow list
Get-SPGuiSdkWorkflowExecutions  -- loads executions for selected workflow
Invoke-SPGuiSdkWorkflowAction   -- -Action Toggle | Test | CreateOOO
```

### Filters Bridge (2 functions)  [WAS MISSING in the original plan -- gap fixed]
```
Get-SPGuiSdkCampaignFilters     -- -IncludeSystem switch
Invoke-SPGuiSdkFilterAction     -- -Action Create | Update | Delete
```

**Total: 14 bridge functions** (was incorrectly stated as 12; the original also
omitted the Filters bridge entirely despite sub-tab 6 needing it).

### Canonical mapping: bridge function -> real SP.Sdk function(s)

Verified against the live module exports (2026-06-04). Use these exact names.

| Bridge function | `-Action` | Backed by SP.Sdk function |
|---|---|---|
| Get-SPGuiSdkCampaignTemplates | -- | `Get-SPSdkCampaignTemplates` + `Get-SPSdkTemplateSchedule` |
| Invoke-SPGuiSdkTemplateAction | Create | `New-SPSdkCampaignTemplate` |
| | Update | `Update-SPSdkCampaignTemplate` |
| | Delete | `Remove-SPSdkCampaignTemplate` |
| | SetSchedule | `Set-SPSdkTemplateSchedule` |
| | RemoveSchedule | `Remove-SPSdkTemplateSchedule` |
| Get-SPGuiSdkCertSummaries | (Identity) | `Get-SPSdkIdentitySummaries` |
| | (Access) | `Get-SPSdkAccessSummaries` |
| Get-SPGuiSdkDecisionSummary | -- | `Get-SPSdkDecisionSummary` |
| Get-SPGuiSdkApprovals | (Pending) | `Get-SPSdkPendingApprovals` / `Get-SPSdkAllPendingApprovals` |
| | (Completed) | `Get-SPSdkCompletedApprovals` / `Get-SPSdkAllCompletedApprovals` |
| Invoke-SPGuiSdkApprovalAction | Approve | `Approve-SPSdkAccessRequest` |
| | Deny | `Deny-SPSdkAccessRequest` |
| | Forward | `Forward-SPSdkAccessRequest` |
| Get-SPGuiSdkWorkItems | -- | `Get-SPSdkWorkItems` (+ `Get-SPSdkWorkItemsSummary`) |
| Invoke-SPGuiSdkWorkItemAction | Complete | `Complete-SPSdkWorkItem` |
| | Forward | `Forward-SPSdkWorkItem` |
| | BulkApprove | `Invoke-SPSdkBulkApproveWorkItem` |
| | BulkReject | `Invoke-SPSdkBulkRejectWorkItem` |
| Get-SPGuiSdkWorkflows | -- | `Get-SPSdkWorkflows` / `Get-SPSdkAllWorkflows` |
| Get-SPGuiSdkWorkflowExecutions | -- | `Get-SPSdkWorkflowExecutions` |
| Invoke-SPGuiSdkWorkflowAction | Toggle | `Set-SPSdkWorkflow` (enabled flag) |
| | Test | `Test-SPSdkWorkflow` |
| | CreateOOO | `Set-SPSdkOOOFallbackWorkflow` |
| Get-SPGuiSdkCampaignFilters | -- | `Get-SPSdkCampaignFilters` / `Get-SPSdkAllCampaignFilters` |
| Invoke-SPGuiSdkFilterAction | Create | `New-SPSdkCampaignFilter` |
| | Update | `Update-SPSdkCampaignFilter` |
| | Delete | `Remove-SPSdkCampaignFilter` |

---

## Safety & What-If Integration (REQUIRED -- gap fixed)

**Every write/destructive bridge action must honor the toolkit `Safety` config**,
exactly as the CLI does. Without this, the GUI SDK tab becomes a way to bypass
the guardrails the CLI enforces. This was absent from the original plan.

Destructive operations on this tab: Delete Template, RemoveSchedule, Delete
Filter, Deny/Forward approval, Complete/BulkApprove/BulkReject work items,
Toggle (disable) workflow, Test workflow, CreateOOO.

Requirements for `Invoke-SPGuiSdk*Action`:
1. **Honor `Safety.RequireWhatIfOnProd`.** When set and the environment is not a
   mock/sandbox, show a confirmation MessageBox before executing -- mirror the
   existing pattern in `SP.MainWindow.psm1` (`Invoke-GuiTestRun`, ~line 468:
   `MessageBox.Show(... YesNo, Warning)`, cancel -> status "cancelled by user
   (Safety.RequireWhatIfOnProd)").
2. **Honor `Safety.AllowCompleteCampaign` / equivalent gates** for any terminal
   action; refuse with a clear status message when disabled.
3. **Confirm dialog on every delete/bulk action**, even in mock, with the count
   of affected items (e.g. "Delete 3 filters?").
4. **Never silently truncate.** If `Safety.MaxCampaignsPerRun` (or an analogous
   cap) bounds a bulk action, surface what was/was not done in the status label.
5. Bridge write functions return `@{ Success=$false; Error='blocked by Safety...' }`
   when a gate refuses, so the UI can show it without a thrown exception.

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

---

## Windows WPF Framework Notes (context the macOS authoring session lacked)

WPF is Windows-only -- none of the patterns below can be exercised on the
MacBook. They are the load-bearing conventions of the existing dashboard
(`SP.MainWindow.psm1`, `Show-SPDashboard.ps1`); the SDK tab MUST follow them or
it will fail in ways that only reproduce on Windows. Each is verified against the
current code with a file:line reference.

### 1. STA + process isolation (the WPF Application singleton trap)
`[System.Windows.Application]` is a **once-per-AppDomain singleton**. Once a
dashboard window is closed in a given PowerShell process, a second
`Show-SPDashboard` in that same session throws *"Cannot set Visibility ... after
a Window has closed."* `Show-SPDashboard.ps1` solves this by **always
re-launching the GUI in a fresh STA child `powershell.exe`** (the `-NoIsolation`
switch is the recursion sentinel: parent omits it, child carries it). WPF also
requires STA apartment state; the child is spawned with `-STA`.
**SDK-tab impact:** none directly, but any new "open a second window" behavior
(e.g. a non-modal SDK detail window) must respect this -- prefer **modal**
dialogs (`ShowDialog`) which the existing `Show-SPGuiDialog` helper already
handles. See `Show-SPDashboard.ps1:55-107`, `SP.MainWindow.psm1:3814-3841`.

### 2. Module-scope event handlers: `& $module { } + .GetNewClosure()`
This is the single most important and least obvious idiom. When you attach a WPF
event handler (`$btn.Add_Click({...})`), the script block is converted to a
delegate and **loses access to module-scope (`$script:*`) functions and
variables**. The toolkit's fix, used by every existing tab:

```powershell
$module = $script:ThisModule          # captured once at top of Initialize-*Tab
...
$btn.Add_Click({
    & $module {
        param($a, $b)
        # inside here, module-private functions (Set-StatusMessage, bridge
        # calls, $script:* state) resolve correctly
        Some-ModulePrivateFunction -X $a -Y $b
    } $localA $localB
}.GetNewClosure())                     # GetNewClosure() preserves the locals
```

Two rules, both mandatory:
- Wrap the handler body in `& $module { ... }` so it runs in **module scope**.
- End the handler with `.GetNewClosure()` so the `$module` ref and any captured
  locals survive the delegate conversion.

`Initialize-SdkTab` must use this for **every** button/checkbox/radio/sub-tab
handler. Reference implementation: `SP.MainWindow.psm1:319, 337-374` (Campaign
tab) and the Audit tab at `:1271+`.

### 3. Background runspace pattern (keep the UI responsive)
All API/bridge calls run on a **background STA runspace**, never on the UI
thread, or the window freezes during the (potentially multi-second) ISC call.
The established pattern (`Invoke-GuiTestRun`, `SP.MainWindow.psm1:495-535`):
1. `RunspaceFactory::CreateRunspace()`, set `.ApartmentState = 'STA'`, `.Open()`.
2. Pass state in via `$runspace.SessionStateProxy.SetVariable(...)` (campaigns,
   ToolkitRoot, the progress controls, and `$script:MainWindow`).
3. Inside the runspace scriptblock, **re-import the modules** (SP.Core, SP.Api,
   **SP.Sdk**, SP.Gui) -- a runspace starts empty.
4. Marshal results back to the UI thread via `$MainWindow.Dispatcher` (the UI
   thread owns the controls; you cannot touch them from the runspace directly).
5. A `DispatcherTimer` (or the dispatcher invoke) updates the grid/labels.

**SDK-tab impact:** each of the 7 grids refreshes through this pattern; the
runspace's module-import list must include `SP.Sdk\SP.Sdk.psd1`. Performance
note: importing 8 SDK `.psm1` files cold on every refresh adds latency -- if it's
noticeable, consider an `InitialSessionState` with the modules pre-imported, or a
shared/pooled runspace. The existing tabs accept the cold-import cost, so match
that first and optimize only if measured.

### 4. DPI / fit-to-screen: use DIPs, never physical pixels
WPF coordinates (`Window.Width/Left/Top`) are **device-independent units
(DIPs)**. `System.Windows.Forms.Screen.WorkingArea` reports **physical pixels**.
Mixing them put the window (and its right-edge toolbar) partly off-screen on
125%/150% laptops. The fix uses `[System.Windows.SystemParameters]::WorkArea`
(DIPs, same units as the window) inside `add_Loaded`
(`SP.MainWindow.psm1:3786-3812`). **This is also why the FlaUI mouse jumped to
(0,0)** -- see GUI Testing note 6 below. The SDK tab adds width via the nested
sub-tab toolbar; re-verify the window still fits after the tab is added.

### 5. XAML loading + the modal dialog helper
XAML is loaded via `[System.Windows.Markup.XamlReader]::Load(XmlNodeReader)` from
an `[xml]` of the file (not `Window.LoadComponent`). Reuse the existing
**`Show-SPGuiDialog`** helper (`SP.MainWindow.psm1:149`) for the three SDK modal
dialogs -- do NOT hand-roll dialog plumbing. Its contract:
- Params: `-XamlPath`, `-ControlNames` (x:Names to read on OK), optional
  `-Defaults` (hashtable to pre-populate), `-OkButtonName`/`-CancelButtonName`
  (default `BtnOK`/`BtnCancel`).
- Sets `Owner = $script:MainWindow` (centers the dialog), wires OK/Cancel,
  pre-populates TextBox/ComboBox/CheckBox, returns a **hashtable of values on
  OK** or **`$null` on Cancel**.
- So the SDK dialogs (`SdkTemplateScheduleDialog`, `SdkWorkflowDialog`,
  `SdkApprovalActionDialog`) just need x:Names matching what you pass in
  `-ControlNames`, and `BtnOK`/`BtnCancel` buttons. No code-behind.

### 6. Tab wiring entry point
Tabs are initialized in `Show-SPDashboard`'s tab sequence
(`SP.MainWindow.psm1:3722-3752`): `Initialize-CampaignTab`, `-EvidenceTab`,
`-SettingsTab`, `-AuditTab`, `-DeltaCertTab`, `-GovernanceTab`. Add
`Initialize-SdkTab` here (before Settings). Each `Initialize-*Tab` takes the
`$TabContent` element and uses `Find-Control -Parent $TabContent -Name '...'` to
locate controls by x:Name.

---

## GUI Testing Methods -- the FlaUI Harness (true end-to-end GUI testing)

This is how the toolkit drives the **real, visible WPF window** under UI
Automation. It is **Windows-only** and was not runnable on the MacBook, so the
W-08b interactive plan could only be authored, not executed, there. The harness
is `Tests/Harness/SP.UiTest.psm1`; the orchestrator is
`Tests/Harness/Invoke-FullGuiValidation.ps1` (existing tests W-02..W-07).

### Two-layer test model (mirror it for W-08)
- **Headless / structural (W-08):** load `MainWindow.xaml` via `XamlReader`
  *without showing it*, walk the visual tree, assert TabItems/controls/x:Names
  and that every Btn*/Chk* has a non-empty ToolTip. **Runs on macOS or Windows,
  no display needed** -- so this is the part the loop can fully validate before
  the Windows GUI session. Pattern: `Test-W03-AuditTabStructure.ps1`.
- **Interactive / FlaUI (W-08b):** launch the real window, click, type, read grid
  rows, screenshot. **Windows-only, needs the mock at localhost:8080.** This is
  the deferral boundary -- author it in the loop, run it in the Windows GUI
  session. Pattern: `Test-W03b-AuditTabInteractive.ps1`.

### FlaUI harness API (from SP.UiTest.psm1)
- **DLLs are vendored** in `Tests\Tools\FlaUI\`:
  `Interop.UIAutomationClient.dll`, `FlaUI.Core.dll`, `FlaUI.UIA3.dll`
  (FlaUI 4.0, UIA3). `Initialize-SPUiAutomation` `Add-Type`s them idempotently.
- `Start-SPDashboardForTest -ConfigPath <mock-settings.json>` spawns the
  dashboard as a **child STA process** and attaches FlaUI via
  `Application::Attach($pid)` + `GetMainWindow(...)`. Returns a context hashtable
  (`Process`, `Automation`, `Application`, `Window`).
  **CRITICAL gotcha:** the launcher is passed **`-NoIsolation`** here. The
  harness already spawns the STA child; without `-NoIsolation` the launcher forks
  a *grandchild* for the window and FlaUI attaches to the wrong (empty) PID and
  times out. (`SP.UiTest.psm1:98-106`.)
- `Find-SPUiElement -Root $win -AutomationId <x:Name>` (or `-Name`) `-ControlType
  Button|TabItem|TextBox` `-TimeoutMs 5000` -- **polls** until found or timeout.
  **WPF `x:Name` surfaces as the UIA `AutomationId`**, so every control the test
  touches must have an `x:Name` in the XAML (the SDK control inventory already
  specifies these).
- `Find-SPUiTab -Window $win -Header 'SDK Features'` -- finds a TabItem by header;
  note FlaUI 4 has no `AsTabItem()` so it constructs the typed wrapper manually.
- `Save-SPUiScreenshot -Element $el -Path <png>` -- for the W-08-22 visual
  baseline round and for failure evidence.
- `Stop-SPDashboardForTest -UiContext $ui` -- graceful close then force-kill;
  always call in a `finally`.

### Timeout tuning (real lesson from this box)
Default finder timeout is 5000ms. Under load, actions that spawn a runspace +
hit the mock can exceed a 2s timeout: `Test-W03b`'s "Open Audit Folder" button
was bumped **2000 -> 5000ms** to stop a flaky failure. **Budget 5000ms for any
W-08b step that triggers a bridge/runspace call** (Refresh*, action buttons),
and use the polling finder rather than a fixed sleep.

### The (0,0) mouse jump -- why GUI fit matters for testing
FlaUI clicks an element's **clickable point**; if the control is **off-screen**
(the DPI bug in WPF note 4), the clickable point falls back to the top-left of
the screen and **the mouse jumps to (0,0)** and the click misfires. So the
WorkArea/DIP fit-to-screen fix is not just cosmetic -- it is a **prerequisite for
reliable FlaUI clicks**. After adding the SDK tab (which widens the toolbar),
confirm the window still fits the work area, or W-08b right-edge buttons will
flake. This is the exact symptom reported and fixed this cycle.

### Registering W-08 with the orchestrator
Add W-08 (headless) and W-08b (interactive) invocations to
`Tests/Harness/Invoke-FullGuiValidation.ps1` alongside W-02..W-07 so a single run
covers the new tab.

---

## Reviewer Notes (Opus 4.8, 2026-06-04, Windows box)

**Verified against live code/mock before edits:**
- SP.Sdk: 8 `.psm1` + manifest, ~53 exported functions (not 66).
- SDK GUI genuinely unbuilt (no `SdkBridge`/`SdkTab`/`Initialize-SdkTab` refs).
- Existing bridge return shape `@{Success;Data;Error}` confirmed.
- Real SP.Sdk function names captured into the canonical mapping table above.
- **Mock seed data matches W-08b assertions exactly** (3 templates; 4 pending /
  3 completed approvals; 6 work items = 4 Pending + 2 Finished; 4 workflows,
  wf-004 disabled; 3 filters) -- `API-MockServer\Profiles\SailPoint-ISC`.

**Gaps fixed in this doc:** bridge inventory was internally inconsistent
("12" but 11 listed) and **omitted the Filters bridge entirely** -> corrected to
14 with a verified mapping table; per-sub-tab action names reconciled to the
dispatcher convention; **Safety/What-If integration section added** (was absent
and is the main risk gap); Cert Summaries flagged as a phase-2 scope decision;
function-count and tab-position drift corrected.

**Adjacent finding (not part of this tab, logged for the backlog):** running the
full Windows Pester suite surfaced that `Tests/SP.CliScripts.Tests.ps1` had a
Pester-5 discovery-phase bug (`-ForEach` referenced `$script:` vars set only in
`BeforeAll`), which silently dropped its entire parametrized matrix. Fixed via a
`BeforeDiscovery` block. That in turn revealed a real latent inconsistency:
**`Invoke-SPCampaignSearch.ps1`'s `OutputMode` ValidateSet is
`Console/JSON/CSV/HTML` and omits `Both`**, which every other script includes
(the CLI-004 consistency test now fails on it). Decision needed: add `Both` to
CampaignSearch (and implement the Console+JSON branch) vs. relax the test for
scripts with richer output taxonomies. Tracked as a backlog item.

**Execution:** this plan is decomposed for the 3-loop autonomous process in
`docs/phase7-sdk-gui-backlog.md` (+ `docs/phase7-sdk-gui-rounds/`). The
GUI-testing boundary (W-08b interactive FlaUI) is the last, post-loop step that
requires a live Windows GUI session.

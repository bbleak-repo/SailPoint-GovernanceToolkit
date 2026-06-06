# SailPoint ISC Governance Toolkit — GUI Playbook

> **Source of truth.** Edit this Markdown, not the generated HTML. Read
> [Foundations](00-foundations.md) first (setup, authentication, the `settings.json`
> reference, the Safety model, output locations, glossary). Every CLI equivalent
> referenced below is documented in the [CLI Playbook](cli-playbook.md).

**Audience:** analysts and reviewers using the interactive dashboard.

## Launching
```powershell
.\Scripts\Show-SPDashboard.ps1                               # default config
.\Scripts\Show-SPDashboard.ps1 -ConfigPath .\Config\settings-mock.json
```
The dashboard opens as a WPF window with **8 tabs**: Campaigns · Evidence · Audit ·
Delta Cert · Governance · SDK Features · **Adaptive Reports** · Settings. A status line at the bottom
shows the result of the last action; long operations run in the background so the
window stays responsive.

**Universal conventions**
- **Refresh** buttons (re)load data from ISC into a grid.
- **Checkbox columns** select rows for an action.
- **Destructive actions** (delete, deny, complete, disable) pop a Yes/No confirm
  showing the affected count; on a production environment with
  `Safety.RequireWhatIfOnProd = true` they require confirmation, and actions gated
  by `Safety.AllowCompleteCampaign` are refused with a "blocked by Safety…" status
  rather than failing silently (see Foundations §7).

## Contents
1. [Campaigns](#1-campaigns-tab) · 2. [Evidence](#2-evidence-tab) · 3. [Audit](#3-audit-tab) ·
4. [Delta Cert](#4-delta-cert-tab) · 5. [Governance](#5-governance-tab) ·
6. [SDK Features](#6-sdk-features-tab) · 7. [Adaptive Reports](#7-adaptive-reports-tab) ·
8. [Settings](#8-settings-tab)

---

## 1. Campaigns tab
**Purpose:** load the test-campaign catalog and run certification test campaigns.
**When to use:** to exercise/validate governance flows interactively (the GUI equivalent
of `Invoke-GovernanceTest.ps1`).

| Control | What it does |
|---|---|
| Campaign grid + tag filter | Lists campaign test cases; the tag combo filters by tag (smoke/regression/full). Checkbox column selects rows. |
| **Refresh** (`BtnRefreshCampaigns`) | Reload the campaign catalog. |
| **Run Selected** (`BtnRunSelected`) | Run the checked campaigns. |
| **Run All** (`BtnRunAll`) | Run every loaded campaign. |
| **Run Smoke** (`BtnRunSmoke`) | Run only the smoke-tagged subset. |

**Workflow:** Refresh → (optionally filter by tag, tick rows) → Run Selected/All/Smoke →
watch the progress bar and result summary.
**Related CLI:** `Invoke-GovernanceTest.ps1`.

---

## 2. Evidence tab
**Purpose:** review and export the evidence bundles produced by campaign runs.
**When to use:** after running campaigns, to inspect or hand off evidence.

| Control | What it does |
|---|---|
| Evidence grid | Lists generated evidence artifacts. |
| **Refresh** (`BtnRefreshEvidence`) | Reload the evidence list. |
| **Open in Browser** (`BtnOpenInBrowser`) | Open the selected evidence/report in the default browser. |
| **Export All** (`BtnExportAll`) | Export/copy all evidence to a chosen location. |

**Related CLI:** evidence is produced by `Invoke-GovernanceTest.ps1` (under `Evidence\`).

---

## 3. Audit tab
**Purpose:** run post-campaign audits and browse the resulting reports.
**When to use:** after campaigns complete, for compliance reports and leadership rollups
(the GUI equivalent of `Invoke-SPCampaignAudit.ps1`).

| Control | What it does |
|---|---|
| **Configure Audit** (`BtnConfigureAudit`) | Opens a dialog to set the campaign filter, status, look-back window, and options (persisted for the session). |
| `ChkCampaignReports` / `ChkIdentityEvents` / `ChkLeadershipRollup` | Toggle inclusion of campaign reports, identity lifecycle events, and the leadership rollup. |
| **Query Campaigns** (`BtnQueryCampaigns`) | Search/list campaigns matching the configured filter. |
| **Run Audit** (`BtnRunAudit`) | Generate the audit reports (HTML/text/JSONL) for the selection. |
| **Open Audit Folder** (`BtnOpenAuditFolder`) | Open the `Audit\` output folder. |
| **Refresh Reports** (`BtnRefreshAuditReports`) | Reload the list of existing audit reports. |

**Workflow:** Configure Audit (set filters) → Query Campaigns → Run Audit → Open Audit
Folder / Refresh Reports to view output.
**Reading results:** reports include decision breakdowns (Approved/Revoked/Pending),
reviewer actions, and — with the rollup — per-leader summaries up the org tree.
**Related CLI:** `Invoke-SPCampaignAudit.ps1`, `Invoke-SPCampaignSearch.ps1`.

---

## 4. Delta Cert tab
**Purpose:** run targeted delta certifications (re-certify recently-changed access) and
manage the **disconnected-app** pipeline.
**When to use:** daily delta-cert operations and disconnected-app certification.

**Delta certification**
| Control | What it does |
|---|---|
| **Configure Delta Cert** (`BtnConfigureDeltaCert`) | Dialog for source IDs, look-back, deadline, reviewer mode, prefix (session-persisted). |
| **Run Delta Cert** (`BtnRunDeltaCert`) | Create delta-cert campaigns for newly-granted access. |
| **Cleanup** (`BtnCleanupDeltaCert`) | Complete past-due delta campaigns (gated by `Safety.AllowCompleteCampaign`). |
| **Escalate** (`BtnEscalateDeltaCert`) | Reassign stale certifications up the org tree. |
| **Generate Delta Report** (`BtnGenerateDeltaReport`) | Produce the lightweight daily change report (HTML+JSONL). |
| **Open Folder** / **Refresh History** | Open `DeltaCert\` / reload the run history list. |

**Disconnected apps** (panel within this tab)
| Control | What it does |
|---|---|
| **Run Disconnected Batch** (`BtnRunDisconnectedBatch`) | Run the certification pipeline for all registered disconnected apps. |
| **Check Delivery** (`BtnCheckDelivery`) | Verify expected CSV files arrived. |
| **View SLA** (`BtnViewSla`) | Show file-delivery SLA status per app. |
| **Refresh Status** (`BtnRefreshDcAppStatus`) | Reload disconnected-app status. |

**Related CLI:** `Invoke-SPADDeltaCert.ps1`, `Invoke-SPDeltaCertEscalate.ps1`,
`Invoke-SPDeltaReport.ps1`, `Invoke-SPDisconnectedAppBatch.ps1`.

---

## 5. Governance tab
**Purpose:** run governance health checks and generate governance reports/dashboards.
**When to use:** posture checks, audit prep, KPI/dashboard generation.

| Control | What it does |
|---|---|
| **Run Health Check** (`BtnRunHealthCheck`) | Run the six-dimension health check and show pass/fail/warn + grade. |
| **Generate Report** (`BtnGenerateGovReport`) | Build the full governance report package. |
| **Export Dashboard Data** (`BtnExportDashboardData`) | Export the dashboard data set. |
| **Open Folder** / **Refresh Reports** | Open the `Reports\` folder / reload the report list. |

**Related CLI:** `Invoke-SPGovernanceHealthCheck.ps1`, `Invoke-SPGovernanceReport.ps1`,
`Invoke-SPGovernanceMetrics.ps1`, `Invoke-SPDataQualityReport.ps1`.

---

## 6. SDK Features tab
**Purpose:** operate the vendor-SDK governance features. Contains six sub-tabs. Every grid
loads via **Refresh**; write actions honor the Safety model.
**When to use:** managing campaign templates/schedules, approvals, work items, workflows,
and campaign filters interactively.

> **All write actions are live.** Every button below — including New Template, New
> Filter, Edit Filter, Create OOO, and Forward Work Item — opens its input dialog,
> validates the entered values, applies the Safety gate (`RequireWhatIfOnProd`), and
> calls the SDK bridge. There are no placeholder/"coming soon" actions on this tab.

### 6.1 Templates
| Control | What it does |
|---|---|
| **Refresh** (`BtnSdkRefreshTemplates`) | Load campaign templates + their schedule status. |
| **New Template** (`BtnSdkNewTemplate`) | Create a campaign template (dialog: name, deadline duration, owner identity, reviewer type). |
| **Edit Schedule** (`BtnSdkEditSchedule`) | Set a recurring schedule on the selected template (dialog). |
| **Remove Schedule** (`BtnSdkRemoveSchedule`) | Remove the schedule (confirm). |
| **Delete Template** (`BtnSdkDeleteTemplate`) | Delete the selected template (confirm). |

### 6.2 Cert Summaries *(shipped)*
| Control | What it does |
|---|---|
| **Campaign** (`CboSdkCertCampaign`) | Pick a campaign; populates the certification list. |
| **Certification** (`CboSdkCertification`) | Pick a certification; loads its summaries. |
| **View** (`CboSdkAccessType`) | `Identity` (default) shows per-identity decision counts; `Entitlement`/`Role`/`Access Profile` show access summaries of that type. |
| **Refresh** (`BtnSdkRefreshSummaries`) | Reload summaries for the current selection. |

**Workflow:** pick Campaign → pick Certification → grid shows identity summaries
(Identity Name, Completed, Total/Approved/Revoked/No-Decision); switch **View** to see
access summaries by type.
> Against the **mock**, Identity and Decision summaries return data; ROLE/ACCESS_PROFILE
> access summaries are empty (no mock fixtures) but populate against a real tenant.
**Related CLI:** *(no direct CLI; SDK cert-summary reads are via the modules.)*

### 6.3 Approvals
| Control | What it does |
|---|---|
| **Pending / Completed** (`RbSdkPending` / `RbSdkCompleted`) | Toggle between pending and historical approvals (swaps the column set + counts). |
| **Refresh** (`BtnSdkRefreshApprovals`) | Reload approvals; updates the Pending/Approved/Rejected badges. |
| **Approve** (`BtnSdkApprove`) | Approve the selected access request. |
| **Deny** (`BtnSdkDeny`) | Deny the selected request (comment dialog; confirm). |
| **Forward** (`BtnSdkForward`) | Forward to another reviewer (dialog; confirm). |

**Related CLI:** *(approvals are operated via the GUI / SDK modules.)*

### 6.4 Work Items
| Control | What it does |
|---|---|
| **Refresh** (`BtnSdkRefreshWorkItems`) | Load work items + the Open/Completed/Total badges. |
| **Show Completed** (`ChkSdkShowCompleted`) | Include completed items in the list. |
| **Complete** (`BtnSdkCompleteWorkItem`) | Mark the selected work item complete (confirm). |
| **Bulk Approve** (`BtnSdkBulkApprove`) | Approve all approval items in the selected work item (confirm; Safety-gated). |
| **Forward** (`BtnSdkForwardWorkItem`) | Forward the work item to another owner (dialog: target identity ID + comment; confirm). |

**Related CLI:** `Invoke-SPSdkWorkItems.ps1` (read/list).

### 6.5 Workflows
| Control | What it does |
|---|---|
| **Refresh** (`BtnSdkRefreshWorkflows`) | Load the workflow list (Enabled, trigger type, execution/failure counts). |
| **Enable/Disable** (`BtnSdkEnableWorkflow`) | Toggle the selected workflow's enabled state (confirm on disable). |
| **Test** (`BtnSdkTestWorkflow`) | Test the selected workflow with sample input (dialog; workflow must be disabled). |
| **View Executions** (`BtnSdkViewExecutions`) | Load recent execution history into the executions grid. |
| **Create OOO** (`BtnSdkCreateOOO`) | Create an out-of-office fallback workflow (dialog: primary + fallback reviewer IDs, fallback days). |

**Related CLI:** `Invoke-SPSdkWorkflows.ps1` (read/list/executions).

### 6.6 Filters
| Control | What it does |
|---|---|
| **Refresh** (`BtnSdkRefreshFilters`) | Load campaign filters. |
| **Include System** (`ChkSdkIncludeSystem`) | Show system-created filters alongside custom ones. |
| **New Filter** (`BtnSdkNewFilter`) | Create a campaign filter (dialog: name, mode `INCLUSION`/`EXCLUSION`, description). |
| **Edit Filter** (`BtnSdkEditFilter`) | Edit the selected filter (dialog pre-populated with its current name/mode/description). |
| **Delete Filter** (`BtnSdkDeleteFilter`) | Delete the selected filter(s) (confirm). |

**Related CLI:** `Invoke-SPSdkCampaignTemplates.ps1` (templates/schedules).

---

## 7. Adaptive Reports tab
**Purpose:** generate **adaptive / composable HTML reports** plus a **baseline report
library** over your governance data — presentation-ready dashboards (KPI cards, heatmap,
drill-down tree, top-N bars, grouped tables) and a catalog of named baseline reports.
**When to use:** richer, presentation-ready governance views; ad-hoc analysis of
entitlement assignment or campaign coverage (the GUI equivalent of
`Invoke-SPAdaptiveReport.ps1`).

**Report Options**
| Control | What it does |
|---|---|
| **Anchor** (`AdaptiveReportsAnchorCombo`) | Pivot the report around an **Entitlement** (default — group = entitlement/role/access profile, members = the identities holding it) or a **Campaign** (group = a certification campaign, members = the identities under it). |
| **Theme** (`AdaptiveReportsThemeCombo`) | Visual theme for the generated HTML (`light` default / `dark`). |
| **Days Back** (`AdaptiveReportsDaysBackBox`) | Look-back window in days for audit/event data (default `90`). |

**Components** (composable report)
| Control | Component key | What it does |
|---|---|---|
| **KPI Cards** (`ChkArCompKpiCards`, default on) | `kpi-cards` | KPI summary-cards component. |
| **Heatmap** (`ChkArCompHeatmap`) | `heatmap` | Source × risk heatmap component. |
| **Tree** (`ChkArCompTree`) | `tree` | Hierarchical drill-down tree component. |
| **Top-N** (`ChkArCompTopN`, default on) | `top-n` | Top-N ranked-items bar component. |
| **Group Table** (`ChkArCompGroupTable`, default on) | `group-table` | Grouped detail-table component. |

**Baseline Reports** (named report library)
| Control | Baseline key | What it does |
|---|---|---|
| **Inventory** (`ChkArBaseInventory`) | `inventory` | Access inventory baseline report. |
| **Privileged** (`ChkArBasePrivileged`) | `privileged` | Privileged-access review baseline report. |
| **Orphaned** (`ChkArBaseOrphaned`) | `orphaned` | Orphaned / disabled-account access baseline report. |
| **Exec Summary** (`ChkArBaseExecSummary`) | `exec-summary` | Governance executive-summary baseline report. |
| **Roster** (`ChkArBaseRoster`) | `roster` | Certification roster baseline report. |
| **Access Cert** (`ChkArBaseAccessCert`) | `access-cert` | Access-certification attestation baseline report. |
| **SoD** (`ChkArBaseSod`) | `sod` | Separation-of-Duties toxic-combination baseline report. |

**Actions**
| Control | What it does |
|---|---|
| **Generate** (`BtnArGenerate`) | Generate the adaptive report(s) from the selected anchor, components and baselines. Runs in the background; the progress bar (`AdaptiveReportsProgressBar`) and status label (`AdaptiveReportsStatusLabel`) update while it runs. |
| **Open Folder** (`BtnArOpenFolder`) | Open the output folder containing the generated reports (default `Audit\adaptive`). |
| **Open Report** (`BtnArOpenReport`) | Open the most recently generated adaptive report in the browser. |

**Workflow:** pick **Anchor** → set **Theme** / **Days Back** → tick **Components** and/or
**Baseline Reports** → **Generate** (runs in the background; progress bar + status label
update) → **Open Report** / **Open Folder**. The default output folder is `Audit\adaptive`
(matches the CLI `-OutputPath` default).

> **Leadership distribution is CLI-only.** This tab generates reports; it does **not**
> distribute them. Tiered leadership distribution (org-tree bands + a WhatIf-SMTP preview
> by default) is run from the CLI via
> `Invoke-SPAdaptiveReport.ps1 -DistributeToLeadership`.

**Related CLI:** `Invoke-SPAdaptiveReport.ps1`.

---

## 8. Settings tab
**Purpose:** view/edit configuration, manage authentication, and run a connectivity test —
without hand-editing `settings.json`.
**When to use:** initial setup, switching environments, applying a browser token, toggling
Safety flags.

| Control | What it does |
|---|---|
| **Debug Mode** (`ChkDebugMode`) | Toggle `Global.DebugMode` (verbose diagnostics). |
| **Browse…** (`BtnBrowseIdentities`/`Campaigns`/`Evidence`/`Reports`) | Set the identities CSV, campaigns CSV, evidence path, and reports path. |
| **Require WhatIf on Prod** (`ChkRequireWhatIf`) | Toggle `Safety.RequireWhatIfOnProd`. |
| **Allow Complete Campaign** (`ChkAllowComplete`) | Toggle `Safety.AllowCompleteCampaign` (the terminal-action gate). |
| **Health Check on Startup** (`ChkGovHealthCheckOnStartup`) | Run a governance health check when the dashboard launches. |
| **Apply Token** / **Clear Token** (`BtnApplyToken` / `BtnClearToken`) | Paste a browser bearer token for the session / clear it. |
| **Test Connectivity** (`BtnTestConnectivity`) | Run the connectivity smoke test (auth + a live API call). |
| **Save Settings** (`BtnSaveSettings`) | Persist changes to the config file. |
| **Reset Defaults** (`BtnResetDefaults`) | Restore default settings. |

> The Settings tab also includes a Delta Cert configuration section (source IDs, hours
> back, deadline, reviewer mode, prefix, output path) that preserves non-GUI fields on save.
**Related CLI:** `Test-SPConnectivity.ps1`, `New-SPVault.ps1` (vault setup is CLI-only).

---

*See also the [CLI Playbook](cli-playbook.md) and [Foundations](00-foundations.md).
Screenshots of each tab will be embedded here after the live GUI validation pass.*

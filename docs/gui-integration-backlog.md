# GUI Integration -- Governance Dashboard + Enhancements (GU-01 to GU-09)

**Created:** 2026-05-31
**Purpose:** Surface high-value governance functions in the WPF GUI
**Strategy:** 1 new tab + 2 enhanced tabs, not 55 buttons

---

## Serial order: `GU-01 -> GU-02 -> GU-03 -> GU-04 -> GU-05 -> GU-06 -> GU-07 -> GU-08 -> GU-09`

**Agent model:** Sonnet 4.6 for GU-01 to GU-08 (implementation), Opus for GU-09 (validation)

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| GU-01 | Governance tab XAML layout | none | DONE |
| GU-02 | Governance bridge functions | GU-01 | DONE |
| GU-03 | Governance tab MainWindow wiring | GU-02 | DONE |
| GU-04 | GovernanceRunDialog.xaml | GU-01 | DONE |
| GU-05 | Enhanced AuditQueryDialog (type + dates) | none | PENDING |
| GU-06 | Enhanced Delta Cert tab (batch status) | none | PENDING |
| GU-07 | Settings tab governance section | none | PENDING |
| GU-08 | Syntax + XAML validation | GU-07 | PENDING |
| GU-09 | Opus visual review + verification | GU-08 | PENDING |

---

## Current GUI Context

- **5 tabs:** Campaigns, Evidence, Settings, Audit, Delta Cert
- **After this:** Campaigns, Evidence, Audit, Delta Cert, **Governance**, Settings
  (Settings stays last -- convention)
- **Pattern:** Each tab has: Initialize-*Tab function, bridge functions, async runspaces
- **Dialogs:** 3 exist (AuditQuery, DeltaCertRun, DeltaCertEscalate) -- adding 1 more
- **Dark theme:** sidebar=#1e2a3a, header=#2c3e50, primary=#336699, accent=#5B9BD5
- **All CSS inline** for Word compatibility in reports

---

## GU-01: Governance Tab XAML Layout

- **Status:** `DONE`
- **Depends On:** none

**Add a new "Governance" TabItem to MainWindow.xaml** between Delta Cert and Settings.
Also create `Gui/GovernanceTab.xaml` as design reference (not loaded at runtime).

**Layout (5 rows):**

```
Row 0: Health Check Status (6 badges in a horizontal stack)
  [Source Health: ?] [Data Quality: ?] [Policy: ?] [Config Drift: ?] [Orphans: ?] [Coverage: ?]
  Each badge: colored border (green=pass, red=fail, gray=unknown), label + status text

Row 1: Metric Cards (3 cards in a horizontal stack)
  [Maturity: --/5] [Policy Compliance: ---%] [Coverage Rate: ---%]
  Each card: large number + label below, colored by threshold

Row 2: Action Buttons
  [Run Health Check]  [Generate Governance Report]  [Export Dashboard Data]  [Open Reports Folder]

Row 3: Progress bar + status label (same pattern as Audit/DeltaCert tabs)

Row 4: Recent Governance Reports (ListBox, same pattern as Audit report list)
```

**Control names (x:Name):**
- Health badges: `GovBadgeSourceHealth`, `GovBadgeDataQuality`, `GovBadgePolicy`,
  `GovBadgeConfigDrift`, `GovBadgeOrphans`, `GovBadgeCoverage`
- Metric cards: `GovMetricMaturity`, `GovMetricPolicyPct`, `GovMetricCoveragePct`
- Buttons: `BtnRunHealthCheck`, `BtnGenerateGovReport`, `BtnExportDashboardData`, `BtnOpenGovFolder`
- Progress: `GovProgressBar`, `GovStatusLabel`
- Reports: `GovReportList`, `BtnRefreshGovReports`

**Files:** Gui/MainWindow.xaml, Gui/GovernanceTab.xaml (NEW design reference)

**Acceptance Criteria:**
- Tab appears between Delta Cert and Settings
- Dark theme matches existing tabs (#1E1E2E background, #2D2D44 surfaces)
- 6 health badges rendered as bordered cards
- 3 metric cards with large numbers
- XML well-formedness check passes

---

## GU-02: Governance Bridge Functions

- **Status:** `DONE`
- **Depends On:** GU-01

**Add 4 bridge functions to SP.GuiBridge.psm1:**

1. `Invoke-SPGuiHealthCheck` -- wraps Invoke-SPGovernanceHealthCheck logic
   - Returns: @{Success; Data=@{Checks=@({Name;Status;Details}); MetricCards=@({Label;Value;Color})}; Error}
   - Maps existing functions: Get-SPSourceAggregationHealth, Measure-SPIdentityDataQuality,
     Test-SPGovernancePolicy, Compare-SPConfigurationSnapshots, Get-SPOrphanAccounts, Get-SPCampaignCoverageGaps

2. `Invoke-SPGuiGovernanceReport` -- wraps Invoke-SPGovernanceReport logic
   - Triggers full governance report generation
   - Returns: @{Success; Data=@{OutputPath; FilesWritten; DurationSeconds}; Error}

3. `Export-SPGuiDashboardData` -- wraps Export-SPGovernanceDashboardData
   - Returns: @{Success; Data=@{CsvPath; RowCount}; Error}

4. `Get-SPGuiGovernanceReports` -- lists recent governance reports (same pattern as Get-SPGuiAuditReports)
   - Returns: @{Success; Data=@([PSCustomObject]@{FileName;FullPath;LastModified;SizeKB}); Error}

**Files:** Modules/SP.Gui/SP.GuiBridge.psm1, Modules/SP.Gui/SP.Gui.psd1

---

## GU-03: Governance Tab MainWindow Wiring

- **Status:** `DONE`
- **Depends On:** GU-02

**Add to SP.MainWindow.psm1:**

1. `Initialize-GovernanceTab` function
   - Find all controls by x:Name
   - Wire button click handlers
   - Load initial state (badges = gray/unknown, metrics = --)
   - Call Load-GovernanceReports for the report list

2. `Invoke-GuiHealthCheck` -- async handler for [Run Health Check]
   - Background runspace pattern (same as Invoke-GuiDeltaCertRun)
   - Calls Invoke-SPGuiHealthCheck on background thread
   - On completion: update 6 badge colors + 3 metric values via dispatcher
   - Progress bar visible during run

3. `Invoke-GuiGovernanceReport` -- async handler for [Generate Report]
   - Shows GovernanceRunDialog first (GU-04) to select what to include
   - Runs Invoke-SPGuiGovernanceReport on background thread
   - Updates status + refreshes report list

4. `Invoke-GuiExportDashboardData` -- handler for [Export Dashboard Data]
   - Calls Export-SPGuiDashboardData
   - Shows save-file dialog or uses default path

5. `Load-GovernanceReports` -- loads recent reports into GovReportList
   - Same pattern as Load-AuditReportList

6. Wire Initialize-GovernanceTab into Show-SPDashboard (after Initialize-DeltaCertTab)

**Files:** Modules/SP.Gui/SP.MainWindow.psm1

---

## GU-04: GovernanceRunDialog.xaml

- **Status:** `DONE`
- **Depends On:** GU-01

**New modal dialog for configuring governance report generation.**

```
<Window> (Title="Governance Report Options", SizeToContent, MinWidth=450)
  Dark theme (#1E1E2E)

  Checkboxes:
    [x] Include Campaign Audit (default checked)
    [x] Include Leadership Rollup (default checked)
    [x] Include Policy Compliance Check
    [x] Include Data Quality Analysis
    [ ] Include Dashboard Data Export (CSV)

  Date Range:
    Status: [COMPLETED v]  Days Back: [90]

  Buttons: [Cancel] [Generate Report] (BtnOK, IsDefault=True)
</Window>
```

**Uses Show-SPGuiDialog** (existing helper from G-01) for dialog management.

**Files:** Gui/GovernanceRunDialog.xaml (NEW)

---

## GU-05: Enhanced AuditQueryDialog

- **Status:** `PENDING`
- **Depends On:** none

**Add 2 controls to existing AuditQueryDialog.xaml:**

1. **Campaign Type dropdown** after Status:
   ```xaml
   <TextBlock>Campaign Type</TextBlock>
   <ComboBox x:Name="CboType">
     <ComboBoxItem Content="(All)" IsSelected="True"/>
     <ComboBoxItem Content="MANAGER"/>
     <ComboBoxItem Content="SOURCE_OWNER"/>
     <ComboBoxItem Content="SEARCH"/>
     <ComboBoxItem Content="ROLE_COMPOSITION"/>
   </ComboBox>
   ```

2. **Date range** after Timespan (replace or supplement):
   ```xaml
   <TextBlock>Created After</TextBlock>
   <TextBox x:Name="TxtCreatedAfter" Width="120" Text=""/>
   <TextBlock>Created Before</TextBlock>
   <TextBox x:Name="TxtCreatedBefore" Width="120" Text=""/>
   ```

**Wire in SP.MainWindow.psm1:** Pass new values through to Get-SPGuiAuditCampaigns.
Update Invoke-AuditCampaignQuery to include -CampaignType and -CreatedAfter/-CreatedBefore.

**Files:** Gui/AuditQueryDialog.xaml, Modules/SP.Gui/SP.MainWindow.psm1

---

## GU-06: Enhanced Delta Cert Tab (Batch Status)

- **Status:** `PENDING`
- **Depends On:** none

**Add a "Disconnected Apps" section to the Delta Cert tab** in Row 4 area
(below existing history, or as a collapsible section).

```
Disconnected Apps: [3 registered, 2 delivered today, 1 missing]
  [Run Batch]  [Check Delivery]  [View SLA]
```

**Minimal footprint:** One summary line + 3 small buttons. Uses existing bridge functions
if available, or calls Get-SPRegisteredApps + Get-SPDisconnectedAppDeliveryStatus directly.

**Files:** Gui/MainWindow.xaml (Delta Cert tab section), SP.MainWindow.psm1

---

## GU-07: Settings Tab Governance Section

- **Status:** `PENDING`
- **Depends On:** none

**Add a "Governance" section to Settings tab** (after Delta Cert section, before Quick Connect).

```
Governance
  Metrics Output Path:    [.\GovernanceMetrics]
  Health Check on Startup: [ ] (checkbox, default unchecked)
```

**Minimal:** Just 2 fields. The governance config is mostly operational (CLI-driven).
The GUI surfaces only the path and the startup-check toggle.

**Files:** Gui/MainWindow.xaml (Settings tab), Gui/SettingsTab.xaml (design ref),
SP.MainWindow.psm1 (Load/Save Settings)

---

## GU-08: Syntax + XAML Validation

- **Status:** `PENDING`
- **Depends On:** GU-07

**Run validation on all modified files:**
- PowerShell AST syntax: SP.MainWindow.psm1, SP.GuiBridge.psm1, SP.Gui.psd1
- XML well-formedness: MainWindow.xaml, GovernanceTab.xaml, GovernanceRunDialog.xaml,
  AuditQueryDialog.xaml, SettingsTab.xaml
- JSON: settings.json

**Fix any issues found.**

---

## GU-09: Opus Visual Review + Verification

- **Status:** `PENDING`
- **Depends On:** GU-08

**Opus agent reads the code and verifies:**
1. All x:Name controls in XAML have matching handlers in SP.MainWindow.psm1
2. All bridge functions are exported in SP.Gui.psd1
3. No orphaned controls (XAML references without code, or code without XAML)
4. Tab order is correct (Campaigns, Evidence, Audit, Delta Cert, Governance, Settings)
5. Dark theme colors consistent with existing tabs
6. Show-SPGuiDialog used for the new GovernanceRunDialog (not manual XAML loading)
7. Async runspace pattern matches existing Audit/DeltaCert implementations
8. If Playwright available: capture screenshot of Governance tab against mock

**Files:** All GUI files (read-only verification)

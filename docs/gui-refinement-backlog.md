# Phase 7: GUI Refinement & Full Stabilization

**Created:** 2026-05-22
**Prereqs:** All SP.DeltaCert features F-01 to F-10 (Phases 2-6) complete

---

## How to Use This File

Same loop workflow as deltacert-backlog.md:

1. Find the next feature with status `PENDING` (follow the serial order below)
2. Check **Depends On** -- all dependencies must be `DONE`
3. Implement using Description, Files, and Acceptance Criteria
4. Run the listed validations
5. Update status to `DONE`, add commit hash
6. Commit feature + this file, push
7. Loop

**Serial order (dependency-safe):**
```
G-01 -> G-05 -> G-06 -> G-02 -> G-04 -> G-03 -> G-07 -> G-08 -> G-09 -> G-10 -> G-11
```

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| G-01 | WPF Modal Dialog Helper | none | DONE |
| G-05 | History Display Upgrade | none | DONE |
| G-06 | DeltaCert Config in Settings Tab | none | DONE |
| G-02 | DeltaCert Run Parameters Dialog | G-01 | DONE |
| G-04 | Escalation Parameters Dialog | G-01 | DONE |
| G-03 | DeltaCert Tab Declutter | G-02 | PENDING |
| G-07 | Audit Tab Dialog Retrofit | G-01 | PENDING |
| G-08 | UI Consistency Pass | G-03, G-07 | PENDING |
| G-09 | Update toolkit-status.md | G-08 | PENDING |
| G-10 | README DeltaCert Section | G-08 | PENDING |
| G-11 | Portable Zip Rebuild | G-09, G-10 | PENDING |

---

## WPF Modal Dialog Pattern (Reference)

No modal dialogs exist in the toolkit yet (only `MessageBox.Show`). G-01 establishes
the reusable pattern. All subsequent dialog features (G-02, G-04, G-07) reuse it.

**PowerShell 5.1 + WPF Window.ShowDialog():**
```powershell
[xml]$xaml = [System.IO.File]::ReadAllText($XamlPath)
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$dialog = [System.Windows.Markup.XamlReader]::Load($reader)
$dialog.Owner = $script:MainWindow
# Wire OK: $dialog.FindName('BtnOK').Add_Click({ $dialog.DialogResult = $true })
# Wire Cancel: $dialog.FindName('BtnCancel').Add_Click({ $dialog.Close() })
if ($dialog.ShowDialog()) { <read control values> } else { <cancelled> }
```

**Dialog XAML conventions:**
- Root element: `<Window>` (not UserControl)
- `WindowStartupLocation="CenterOwner"`, `ResizeMode="NoResize"`
- Dark theme colors embedded inline (dialogs load standalone, can't reference MainWindow resources):
  - Background: `#1E1E2E`
  - Surface: `#2D2D44`
  - Primary/Accent: `#5B9BD5`
  - Text: `#E0E0E0`
  - Muted: `#AAAACC`
  - Border: `#3D3D5C`

---

## Existing Patterns to Reuse

| Pattern | Location | Used By |
|---------|----------|---------|
| XAML loading | SP.MainWindow.psm1 `Load-XamlWindow` | G-01 (extend) |
| Control finder | SP.MainWindow.psm1 `Find-Control` | All |
| Dispatcher cross-thread | SP.MainWindow.psm1 `Invoke-OnDispatcher` | G-02, G-03, G-07 |
| Background runspace + timer | SP.MainWindow.psm1 line ~304 | G-03, G-07 |
| `Invoke-SPGuiDeltaCertRun` | SP.GuiBridge.psm1 line 846 | G-02, G-03 |
| `Invoke-SPGuiDeltaCertEscalate` | SP.GuiBridge.psm1 line 990 | G-04 |
| `Get-SPGuiDeltaCertHistory` | SP.GuiBridge.psm1 line 1084 | G-05 |
| `Get-SPGuiAuditCampaigns` | SP.GuiBridge.psm1 line 422 | G-07 |
| Settings section styles | MainWindow.xaml `SectionHeader`, `SectionBorder` | G-06 |
| `Save-SettingsForm` | SP.MainWindow.psm1 line ~820 | G-06 |

---

## G-01: WPF Modal Dialog Helper

- **Status:** `DONE`
- **Commit:** c863462
- **Depends On:** none

**Description:**
Create `Show-SPGuiDialog` in SP.MainWindow.psm1 -- a reusable internal function that loads
a XAML Window from a file, shows it as a modal dialog, and returns control values as a
hashtable (or `$null` on cancel). Supports a `-Defaults` hashtable to pre-populate controls.

This is the foundation for G-02, G-04, and G-07.

**Files to Modify:**
- `Modules/SP.Gui/SP.MainWindow.psm1` -- add function in the internal XAML helpers region

**Function Signature:**
```powershell
function Show-SPGuiDialog {
    param(
        [Parameter(Mandatory)][string]$XamlPath,
        [Parameter(Mandatory)][string[]]$ControlNames,
        [Parameter()][hashtable]$Defaults,
        [Parameter()][string]$OkButtonName = 'BtnOK',
        [Parameter()][string]$CancelButtonName = 'BtnCancel'
    )
}
```

**Behavior:**
- Loads XAML, sets `Owner = $script:MainWindow`
- Wires OK button (`DialogResult = $true`) and Cancel button (`Close()`)
- If `-Defaults` provided: sets TextBox.Text, ComboBox.SelectedItem (by Content match), CheckBox.IsChecked
- On OK: reads each named control's value into a hashtable, returns it
- On Cancel/Close: returns `$null`
- On error: logs via Write-SPLog, returns `$null`
- NOT exported in SP.Gui.psd1 (internal helper)

**Acceptance Criteria:**
- Modal dialog appears centered over main window
- OK returns hashtable of control values
- Cancel returns `$null`
- Defaults pre-populate controls
- ComboBox default-setting matches item by Content string
- XAML-not-found produces logged error, not crash

**Validation:**
- PS AST syntax check on SP.MainWindow.psm1

---

## G-05: History Display Upgrade

- **Status:** `DONE`
- **Commit:** f4a9e60
- **Depends On:** none

**Description:**
Upgrade the DeltaCert history ListBox (`DeltaCertHistoryList`) to show color-coded entries:
- Green (`#339933`): Reason contains "Created" or CampaignsCreated > 0
- Gray (`#888899`): Reason is "NoChanges"
- Orange (`#FF9900`): Errors present

Update `Load-DeltaCertHistory` in SP.MainWindow.psm1 to create ListBoxItems with colored
Foreground. Apply the same color pattern to the Audit report list for consistency.

**Files to Modify:**
- `Modules/SP.Gui/SP.MainWindow.psm1` -- update `Load-DeltaCertHistory` (color logic) and Audit report list loader
- `Gui/MainWindow.xaml` -- optional: add `MaxHeight="150"` to history ListBox
- `Gui/DeltaCertTab.xaml` -- update design reference

**Acceptance Criteria:**
- Successful runs show in green
- No-change runs show in muted gray
- Error runs show in orange
- Each entry shows: timestamp, campaign count, reason on one line
- History section has bounded height (MaxHeight ~150px)

**Validation:**
- XML well-formedness check on MainWindow.xaml
- PS AST syntax check on SP.MainWindow.psm1

---

## G-06: DeltaCert Config in Settings Tab

- **Status:** `DONE`
- **Commit:** cb50b88
- **Depends On:** none

**Description:**
Add a "Delta Cert" section to the Settings tab with 6 persistent config fields: Source IDs,
Default Hours Back, Default Deadline Days, Default Reviewer Mode, Campaign Name Prefix,
Output Path. Uses existing `SectionHeader`, `SectionBorder`, `FieldLabel`, `FieldBox` styles.

Update `Load-SettingsForm` and `Save-SettingsForm` in SP.MainWindow.psm1. On save, preserve
DeltaCert config keys not exposed in the GUI (ExcludeLifecycleStates, ExcludeDisplayNamePatterns,
ExcludeIdentityIds, Escalation sub-object).

**Files to Modify:**
- `Gui/MainWindow.xaml` -- add "Delta Cert" section after Safety section
- `Gui/SettingsTab.xaml` -- update design reference
- `Modules/SP.Gui/SP.MainWindow.psm1` -- update Load-SettingsForm, Save-SettingsForm

**Key detail for Save:** Read existing DeltaCert config from current settings.json, overlay
only the GUI-exposed fields, preserve everything else. Comma-separated Source IDs text saves
as JSON array; empty string saves as `[]`.

**Acceptance Criteria:**
- Settings tab shows "Delta Cert" section with 6 fields
- Loading populates fields from config
- Saving writes fields to settings.json
- Non-GUI DeltaCert fields preserved on save
- Empty Source IDs saves as `[]` not `[""]`
- Comma-separated Source IDs round-trip correctly

**Validation:**
- XML well-formedness on MainWindow.xaml, SettingsTab.xaml
- PS AST syntax on SP.MainWindow.psm1
- Manual: save, reload, verify round-trip

---

## G-02: DeltaCert Run Parameters Dialog

- **Status:** `DONE`
- **Commit:** a17cda6
- **Depends On:** G-01

**Description:**
New XAML dialog `Gui/DeltaCertRunDialog.xaml` with 4 fields (Source IDs, Hours Back,
Deadline Days, Reviewer Mode) + OK/Cancel. Dark theme, `SizeToContent="WidthAndHeight"`,
`MinWidth="450"`.

Update `Invoke-GuiDeltaCertRun` in SP.MainWindow.psm1 to show this dialog before running.
Add `$script:LastDeltaCertParams` for session persistence (remembers last values between runs).

On first open, defaults come from the Settings tab config. On subsequent opens, defaults
come from the last-used values.

**Files to Create:**
- `Gui/DeltaCertRunDialog.xaml`

**Files to Modify:**
- `Modules/SP.Gui/SP.MainWindow.psm1` -- modify `Invoke-GuiDeltaCertRun`, add session state

**Dialog Controls:**
- `TxtSourceIds` (TextBox, full width)
- `TxtHoursBack` (TextBox, Width=80, default "24")
- `TxtDeadlineDays` (TextBox, Width=80, default "2")
- `CboReviewerMode` (ComboBox: Manager, SourceOwner)
- `BtnOK` (primary, IsDefault=True, Content="Run Delta Cert")
- `BtnCancel` (secondary)

**Acceptance Criteria:**
- Clicking "Run Delta Cert" on the tab opens this dialog
- Dialog pre-populates with last-used or config-default values
- OK starts the run with dialog values
- Cancel returns to tab without running
- Values persist across runs within the same GUI session

**Validation:**
- XML well-formedness on DeltaCertRunDialog.xaml
- PS AST syntax on SP.MainWindow.psm1

---

## G-04: Escalation Parameters Dialog

- **Status:** `DONE`
- **Commit:** df8c2c8
- **Depends On:** G-01

**Description:**
New XAML dialog `Gui/DeltaCertEscalateDialog.xaml` with 3 fields (Campaign Name Prefix,
Stale Hours, Max Escalation Levels) + OK/Cancel. Same dark theme pattern as G-02.

Update `Invoke-GuiDeltaCertEscalation` to show dialog before running. Add
`$script:LastEscalationParams` for session persistence.

**Files to Create:**
- `Gui/DeltaCertEscalateDialog.xaml`

**Files to Modify:**
- `Modules/SP.Gui/SP.MainWindow.psm1` -- modify `Invoke-GuiDeltaCertEscalation`, add session state

**Dialog Controls:**
- `TxtCampaignPrefix` (TextBox, default "AD Delta Cert")
- `TxtStaleHours` (TextBox, Width=80, default "24")
- `TxtMaxLevels` (TextBox, Width=80, default "2")
- `BtnOK` (primary, Content="Run Escalation")
- `BtnCancel` (secondary)

**Acceptance Criteria:**
- "Run Escalation" button on tab opens this dialog
- Defaults from config on first open, then from last-used values
- OK runs escalation, Cancel returns to tab

**Validation:**
- XML well-formedness on DeltaCertEscalateDialog.xaml
- PS AST syntax on SP.MainWindow.psm1

---

## G-03: DeltaCert Tab Declutter

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** G-02

**Description:**
Remove the 4 inline config inputs and their labels from DeltaCert tab Row 0 in
MainWindow.xaml. Replace with:

```
Row 0: [Summary label] .............. [Configure...] [Run Delta Cert]
Row 1: Results DataGrid (unchanged, now has more vertical space)
Row 2: [Run Cleanup] [Run Escalation]  ........... [Open Output Folder]
Row 3: Progress bar + status (unchanged)
Row 4: History (unchanged)
```

Summary label shows: `"Sources: src-ad-001 | 24h | 2d deadline | Manager"`
or `"Not configured. Click Configure to set parameters."` on first load.

Add `Update-DeltaCertSummaryLabel` helper and wire [Configure...] button to open the
DeltaCertRunDialog (same as Run, but doesn't execute -- just stores params and updates label).

**Control count reduction:** 21 -> ~14 controls.

**Files to Modify:**
- `Gui/MainWindow.xaml` -- replace DeltaCert Row 0 XAML
- `Gui/DeltaCertTab.xaml` -- update design reference
- `Modules/SP.Gui/SP.MainWindow.psm1` -- add Configure button handler, summary label updater

**Acceptance Criteria:**
- Row 0 shows summary + Configure + Run (3 elements instead of 8+)
- Configure opens dialog, updates summary, does NOT run
- Run opens dialog then runs on OK
- Summary label reflects current parameters
- DataGrid has more vertical space

**Validation:**
- XML well-formedness on MainWindow.xaml, DeltaCertTab.xaml
- PS AST syntax on SP.MainWindow.psm1

---

## G-07: Audit Tab Dialog Retrofit

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** G-01

**Description:**
Apply the same modal dialog pattern to the Audit tab. Move query filters (Campaign Name,
Status, Timespan) into `Gui/AuditQueryDialog.xaml`. Replace Audit Row 0 with summary +
[Configure...] + [Query Campaigns] matching the DeltaCert pattern.

The Row 2 checkboxes (Include Campaign Reports, Include Identity Events) stay inline --
they're action modifiers, not query filters.

**Files to Create:**
- `Gui/AuditQueryDialog.xaml`

**Files to Modify:**
- `Gui/MainWindow.xaml` -- replace Audit tab Row 0
- `Gui/AuditTab.xaml` -- update design reference
- `Modules/SP.Gui/SP.MainWindow.psm1` -- update Initialize-AuditTab, add dialog handlers, add `$script:LastAuditQueryParams`, add `Update-AuditSummaryLabel`

**Dialog Controls:**
- `TxtCampaignName` (TextBox, placeholder "Search by keyword...")
- `CboStatus` (ComboBox: (All), COMPLETED, ACTIVE, STAGED, COMPLETING)
- `CboTimespan` (ComboBox: 7 days, 14 days, 30 days, 60 days, 90 days)
- `BtnOK` (primary, Content="Query Campaigns")
- `BtnCancel` (secondary)

**Acceptance Criteria:**
- Audit Row 0: summary + Configure + Query (matches DeltaCert pattern)
- Query opens dialog then queries on OK
- Session persistence for filter values
- Audit DataGrid gets more vertical space
- Row 2 checkboxes + Run Audit button unchanged

**Validation:**
- XML well-formedness on all XAML files
- PS AST syntax on SP.MainWindow.psm1

---

## G-08: UI Consistency Pass

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** G-03, G-07

**Description:**
After dialog refactoring, sweep all 5 tabs + 3 dialogs for consistency:

1. **Button styles:** All primary = `ToolkitButton`, all secondary = `SecondaryButton`
2. **Button naming:** Primary = "verb + noun", Configure = "Configure..." (with ellipsis)
3. **Progress bars:** DeltaCert, Audit, Campaigns all use same structure
4. **Tab content margins:** All tab content grids use `Margin="12,8"`
5. **Dialog colors:** All 3 dialog XAMLs use identical color constants
6. **No orphaned controls:** Every x:Name in XAML has a handler in SP.MainWindow.psm1

**Files to Modify:** All XAML files + SP.MainWindow.psm1 (as needed)

**Acceptance Criteria:**
- All criteria above verified and corrected
- No visual inconsistencies between tabs

**Validation:**
- XML well-formedness on all XAML files
- PS AST syntax on SP.MainWindow.psm1

---

## G-09: Update toolkit-status.md

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** G-08

**Description:**
Refresh `docs/toolkit-status.md` with Phase 7 changes: modal dialog pattern, tab declutter,
3 new dialog XAML files, updated test counts (34 DeltaCert tests), architecture diagram
update, verification checklist for GUI features.

**Files to Modify:**
- `docs/toolkit-status.md`

**Acceptance Criteria:**
- Last Updated date reflects current date
- Architecture diagram shows dialog XAML files
- Module tracking table includes all new files
- Test counts accurate
- Phase 7 verification checklist added

---

## G-10: README DeltaCert Section

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** G-08

**Description:**
Add "Delta Cert (AD Access Change Detection)" section to README.md with CLI examples,
GUI tab description (post-declutter layout), and daily operations reference showing
recommended scheduled task setup.

**Files to Modify:**
- `README.md`

**Acceptance Criteria:**
- CLI examples for: basic run, with cleanup, SourceOwner mode, WhatIf, escalation
- GUI description matches post-G-03 layout (Configure + Run + summary)
- Daily operations section with cron/scheduled task examples

---

## G-11: Portable Zip Rebuild

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** G-09, G-10

**Description:**
Rebuild `SailPoint-GovernanceToolkit.zip` including all new dialog XAML files, updated
MainWindow.xaml, SP.MainWindow.psm1, SP.GuiBridge.psm1, README.md, toolkit-status.md.

**Include:** Config/, Gui/ (all XAML including 3 new dialogs), Modules/, Scripts/, Tests/,
README.md, QUICKSTART.md, docs/toolkit-status.md, docs/DEV.md, docs/SANDBOX-API-SETUP.md

**Exclude:** .git/, *.zip, Logs/, Evidence/, DeltaCert/, Audit/, Reports/, Data/, .DS_Store,
docs/deltacert-backlog.md, docs/deltacert-rounds/, docs/gui-refinement-backlog.md

**Acceptance Criteria:**
- Zip contains all 3 new dialog XAML files
- Zip contains updated GUI and script files
- No excluded files present
- Extract + `.\Scripts\Show-SPDashboard.ps1` launches successfully (Windows PS 5.1)

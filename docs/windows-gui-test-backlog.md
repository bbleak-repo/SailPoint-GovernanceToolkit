# Windows GUI + CLI Integration Test Backlog

**Created:** 2026-05-23
**Target:** Windows PowerShell 5.1 with WPF GUI
**Mock APIs:** Running on macOS at 10.0.0.143

---

## How to Use This File

Agent loop -- each round tackles one test phase:
1. Find next `PENDING` phase
2. Execute all tests in that phase
3. Log results (PASS/FAIL per item) in the round MD file
4. Fix any bugs found, re-test
5. Mark `DONE`, commit, push
6. Loop

**Serial order:** `W-01 -> W-02 -> W-03 -> W-04 -> W-05 -> W-06 -> W-07`

---

## Mock API Endpoints (macOS host)

| Service | URL | Purpose |
|---------|-----|---------|
| Pode MockServer | http://10.0.0.143:8080 | SailPoint ISC (80 identities, enterprise org) |
| Prism SailPoint | http://10.0.0.143:4010 | OpenAPI spec validation |
| Prism CyberArk | http://10.0.0.143:4020 | CyberArk PVWA mock |
| Prism Okta | http://10.0.0.143:4030 | Okta mock |

---

## Mock Config Setup (run once before W-01)

**CRITICAL: Save real config first:**
```powershell
Copy-Item Config\settings.json Config\settings-real.json
```

**Write mock config** (modify Config\settings.json):
```json
{
    "Global": { "EnvironmentName": "MOCK-SERVER" },
    "Authentication": {
        "ConfigFile": {
            "TenantUrl": "http://10.0.0.143:8080",
            "OAuthTokenUrl": "http://10.0.0.143:8080/oauth/token",
            "ClientId": "mock-client",
            "ClientSecret": "mock-secret"
        }
    },
    "Api": { "BaseUrl": "http://10.0.0.143:8080/v3" },
    "Safety": { "RequireWhatIfOnProd": false, "AllowCompleteCampaign": true },
    "Audit": { "DefaultDaysBack": 365 },
    "DeltaCert": {
        "SourceIds": ["src-ad-001"],
        "FallbackReviewerIdentityId": "id-orphan-1",
        "ExcludeDisplayNamePatterns": ["^SVC-"]
    }
}
```

Keep all other existing keys unchanged (Logging, Testing, Vault, etc.).

**Restore when done:**
```powershell
Copy-Item Config\settings-real.json Config\settings.json -Force
Remove-Item Config\settings-real.json
```

---

## FlaUI Interactive GUI Harness

All `GUI:` phases (W-02 onward) must drive a real visible WPF window via the
vendored FlaUI harness, not headless XAML parsing. Headless coverage was
shipped first as a sanity layer; W-02b and W-03b backfill it with interactive
tests, and W-04 builds on top of the same harness.

- Helper module:  `Tests\Harness\SP.UiTest.psm1`
- Vendored DLLs:  `Tests\Tools\FlaUI\` (FlaUI 4.0 net48, MIT)
- Smoke proof:    `Tests\Harness\Test-FlaUiSmoke.ps1` (9/9 PASS as of harness build)

Pattern each interactive harness must follow (run as `powershell.exe -STA -File ...`):

```powershell
Import-Module $PSScriptRoot\SP.UiTest.psm1 -Force
$ui = Start-SPDashboardForTest -ConfigPath C:\...\Config\settings.json
try {
    $tab = Find-SPUiTab -Window $ui.Window -Header 'Settings'
    $tab.Select()
    $btn = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnSave'
    $btn.Click()
    Save-SPUiScreenshot -Element $ui.Window -Path docs\windows-test-rounds\WG-02b-after-save.png
}
finally { Stop-SPDashboardForTest -UiContext $ui }
```

The window *will* be visible while the test runs; this is intentional.

---

## Phase Summary

| ID | Phase | Tests | Depends On | Status |
|----|-------|-------|------------|--------|
| W-01 | Prerequisites + Pester | 3 | none | DONE |
| W-02 | GUI (headless): Settings + Campaigns + Evidence tabs | 8 | W-01 | DONE |
| W-02b | GUI (interactive, FlaUI): backfill W-02 | 8 | W-02 | DONE |
| W-03 | GUI (headless): Audit tab | 12 | W-01 | DONE |
| W-03b | GUI (interactive, FlaUI): backfill W-03 | 12 | W-03 | DONE |
| W-04 | GUI (interactive, FlaUI): Delta Cert tab (all 5 buttons + dialogs) | 14 | W-02b | PENDING |
| W-05 | CLI: All scripts against remote mock | 8 | W-01 | PENDING |
| W-06 | Playwright: Screenshot + visual validation | 10 | W-03b, W-05 | PENDING |
| W-07 | Report content deep validation | 15 | W-06 | PENDING |

---

## W-01: Prerequisites + Pester

- **Status:** `DONE`
- **Commit:** (this round)
- **Depends On:** none
- **Results:** PASS -- mock connectivity OK, OAuth OK, Pester 402/411 pass (9 pre-existing test/mock failures documented in docs\windows-test-rounds\round-02.md, down from 55 on PS 7)

**Tests:**

```
WC-01-01: git pull origin master
  Verify: on commit 54b28c7 or later

WC-01-02: Mock connectivity
  Invoke-RestMethod -Uri http://10.0.0.143:8080/health
  Expected: HTTP 200

WC-01-03: Mock auth
  Invoke-RestMethod -Uri http://10.0.0.143:8080/oauth/token -Method POST `
      -Body "grant_type=client_credentials&client_id=mock&client_secret=mock"
  Expected: JSON with access_token

WC-01-04: Pester test suite
  Invoke-Pester -Path .\Tests\ -Output Detailed
  Log: total tests, pass count, fail count, failure details
  Note: 55 mock-scoping failures on PS7 are expected to PASS on PS 5.1
```

**Setup:** Save real config, write mock config per the setup section above.

---

## W-02: GUI -- Settings, Campaigns, Evidence Tabs

- **Status:** `DONE`
- **Commit:** (this round)
- **Depends On:** W-01
- **Results:** PASS 8/8 -- headless WPF harness `Tests\Harness\Test-W02-GuiStructure.ps1` (STA, no ShowDialog) verified XAML loads, 5 tabs in correct order, all 6 Settings section anchors, 6 Delta Cert fields, Quick Connect masked PasswordBox + buttons, Campaigns toolbar + DataGrid + ProgressBar, Evidence tree + detail grid, and a real settings.json round-trip (TxtDcHoursBack 24 -> 48 -> 24 verified via WriteAllText + re-read). See docs\windows-test-rounds\round-03.md.

**Launch GUI:** `.\Scripts\Show-SPDashboard.ps1`

**Tests:**

```
WG-02-01: GUI launches without errors
  Expected: MainWindow appears, 5 tabs visible

WG-02-02: Settings tab renders
  Expected: Environment, Authentication, API, Testing, Safety, Delta Cert sections visible

WG-02-03: Settings tab -- Delta Cert section has 6 fields
  Verify: Source IDs, Hours Back, Deadline Days, Reviewer Mode, Campaign Prefix, Output Path

WG-02-04: Settings tab -- Quick Connect section exists
  Verify: Browser Token masked input + Apply/Clear buttons

WG-02-05: Settings tab -- Save/Load round trip
  Change a value (e.g., Hours Back to 48), click Save
  Close and reopen GUI, verify the value persisted

WG-02-06: Campaigns tab renders
  Expected: toolbar with buttons, DataGrid, progress bar area

WG-02-07: Evidence tab renders
  Expected: tab content loads without errors

WG-02-08: All 5 tab headers visible and clickable
  Click each tab: Campaigns, Evidence, Settings, Audit, Delta Cert
  Expected: no crashes, content switches cleanly
```

---

## W-02b: GUI (interactive, FlaUI) -- backfill W-02

- **Status:** `DONE`
- **Commit:** (this round)
- **Depends On:** W-02 (headless baseline) + FlaUI harness
- **Results:** PASS 8/8 -- interactive harness `Tests\Harness\Test-W02b-GuiInteractive.ps1` drives the real visible WPF dashboard via SP.UiTest.psm1 (FlaUI 4.0 UIA3). Verified main window + 5 tabs, all 6 Settings section headers (Environment, Authentication, API Configuration, Testing, Safety Controls, Delta Cert), 6 Delta Cert AutomationIds, Quick Connect masked PasswordBox + Apply/Clear, end-to-end Save round trip on TxtDcHoursBack (24->48->24 with disk verification, "Saved" MessageBox dismissed via desktop-wide UIA sweep, StatusBarText='Settings saved successfully.'), Campaigns toolbar + CampaignGrid + progress area (SuiteProgressBar is Visibility=Collapsed pre-run by design), Evidence tree + detail grid + Refresh/Open/Export buttons, and all 5 tabs Select() in spec order Campaigns->Evidence->Settings->Audit->Delta Cert with per-tab screenshots. Mock at 10.0.0.143:8080 reachable this round; `Config\settings.local.json` had to be overlaid with the same mock config as `settings.json` because path-less Get-SPConfig calls in background runspaces prefer the .local file (see round-05.md bugs section). See docs\windows-test-rounds\round-05.md.

---

## W-03b: GUI (interactive, FlaUI) -- backfill W-03

- **Status:** `DONE`
- **Commit:** (this round)
- **Depends On:** W-03 (headless baseline) + FlaUI harness
- **Results:** PASS 12/12 -- interactive harness `Tests\Harness\Test-W03b-AuditTabInteractive.ps1` drives the real visible WPF dashboard via SP.UiTest.psm1 (FlaUI 4.0 UIA3). Verified the Audit tab Row 0 (summary + Configure + Query Campaigns), the AuditQueryDialog modal opening with TxtCampaignName/CboStatus/CboTimespan, the live mock query for `COMPLETED + 365 days` populating AuditCampaignGrid with "2025 Annual Access Review", the summary-label refresh, selecting the row checkbox + checking all three audit options (Reports/Events/Leadership), the live Run Audit run (AuditProgressBar visible, BtnRunAudit disabled, dispatcher-timer driven), audit completion in <30s (`Audit complete. 1 campaign(s), 10 file(s) written.`), generation of Audit\*.html + Audit\leadership\executive-summary.html + 3 per-leader HTML reports, AuditReportList populating with 5 items + a double-click delivery (evidence chain), and BtnOpenAuditFolder spawning Explorer. **Bug fix shipped this round:** the AuditReportList MouseDoubleClick handler hit the WPF+PS5.1 module-scope gotcha (`.GetNewClosure()` drops module SessionState, so `$auditReportList` resolved to `$null` and `Start-Process` was never reached); fixed in `Modules\SP.Gui\SP.MainWindow.psm1` by wrapping the handler body in `& $module { param($lb) ... } $auditReportList` plus an INFO `Write-SPLog "Opening audit report:"` observability line. See `docs\windows-test-rounds\round-06.md`.

- **Required artifact:** `Tests\Harness\Test-W03b-AuditTabInteractive.ps1`.

---

## W-03: GUI -- Audit Tab

- **Status:** `DONE`
- **Commit:** (this round)
- **Depends On:** W-01
- **Results:** PASS 10/10 testable, BLOCKED 2 (mock down) -- headless WPF harness `Tests\Harness\Test-W03-AuditTabStructure.ps1` (STA, no ShowDialog) verified Audit tab Row 0 layout, AuditQueryDialog 3 fields + new 365-day timespan option, Update-AuditSummaryLabel formatter ("Status: COMPLETED | Timespan: 365 days"), AuditCampaignGrid 6-column schema, checkbox defaults (Reports/Events checked, Leadership unchecked), BtnRunAudit disabled-at-startup, AuditReportList green-brush color coding via Load-AuditReportList, MouseDoubleClick handler wired on list, Click handler wired on Open Reports Folder + absolute path from Resolve-AuditOutputPath. WG-03-08 (full audit run via Invoke-SPCampaignAudit.ps1) + WG-03-09 (Audit\leadership\ HTMLs) BLOCKED -- mock Pode server at 10.0.0.143:8080 unreachable this round. Fix shipped: added "180 days" + "365 days" options to AuditQueryDialog timespan. See docs\windows-test-rounds\round-04.md.

**Tests:**

```
WG-03-01: Audit tab renders with decluttered layout
  Expected: Summary label + [Configure...] + [Query Campaigns] in Row 0

WG-03-02: Click [Configure...] -- AuditQueryDialog opens
  Expected: modal dialog centered on main window with 3 fields

WG-03-03: AuditQueryDialog -- set filters
  Set Campaign Name = (empty), Status = COMPLETED, Timespan = 365 days
  Click [Query Campaigns]
  Expected: dialog closes, DataGrid populates with campaigns from mock

WG-03-04: Summary label updates after query
  Expected: shows query parameters (e.g., "Status: COMPLETED | 365 days")

WG-03-05: Campaign DataGrid shows mock data
  Expected: "2025 Annual Access Review" appears with COMPLETED status

WG-03-06: Select campaign + check options
  Select the campaign checkbox
  Check "Include Campaign Reports"
  Check "Include Identity Events"
  Check "Include Leadership Rollup"

WG-03-07: Click [Run Audit]
  Expected: progress bar appears, status updates during run

WG-03-08: Audit completes successfully
  Expected: status shows "Audit Complete" or similar
  Verify: Audit\ directory created with HTML + TXT + JSONL

WG-03-09: Leadership reports generated
  Expected: Audit\leadership\ contains executive-summary.html + VP/director reports

WG-03-10: Recent reports list populates
  Expected: ListBox shows recently generated HTML files

WG-03-11: Double-click a report in the list
  Expected: opens in default browser

WG-03-12: [Open Reports Folder] button
  Expected: opens Audit\ directory in Explorer
```

---

## W-04: GUI -- Delta Cert Tab

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** W-01

**Tests:**

```
WG-04-01: Delta Cert tab renders with decluttered layout
  Expected: summary label + [Configure...] + [Run Delta Cert] in Row 0

WG-04-02: Click [Configure...] -- DeltaCertRunDialog opens
  Expected: modal dialog with 4 fields (Source IDs, Hours Back, Deadline Days, Reviewer Mode)

WG-04-03: DeltaCertRunDialog pre-populated with config defaults
  Expected: Source IDs = src-ad-001, Hours Back = 24, Deadline Days = 2, Mode = Manager

WG-04-04: Set parameters and click [Run Delta Cert]
  Set: Source IDs = src-ad-001, Hours Back = 48, Deadline Days = 2, Mode = Manager
  Expected: dialog closes, delta cert runs, progress shown

WG-04-05: Delta cert completes
  Expected: status shows campaigns created count
  Verify: DataGrid in Row 1 shows result row

WG-04-06: Session persistence -- click [Configure...] again
  Expected: dialog pre-populated with LAST USED values (src-ad-001, 48, 2, Manager)

WG-04-07: Summary label updated
  Expected: shows current parameters after configuration

WG-04-08: Click [Run Cleanup]
  Expected: cleanup runs (may complete 0 campaigns if none stale)
  Verify: status shows cleanup result

WG-04-09: Click [Run Escalation] -- DeltaCertEscalateDialog opens
  Expected: modal dialog with 3 fields (Campaign Prefix, Stale Hours, Max Levels)

WG-04-10: Set escalation parameters and run
  Set: Prefix = AD Delta Cert, Stale Hours = 1, Max Levels = 2
  Expected: escalation runs, finds stale certs from mock data

WG-04-11: Click [Open Output Folder]
  Expected: opens DeltaCert\ directory in Explorer

WG-04-12: Click [Generate Delta Report] (if button exists)
  Expected: delta report HTML generated in DeltaCert\reports\

WG-04-13: History section shows recent runs
  Expected: color-coded entries (green for created, gray for no changes)

WG-04-14: Click [Refresh] on history
  Expected: history list updates with latest run
```

---

## W-05: CLI -- All Scripts Against Remote Mock

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** W-01

**Tests:**

```
WC-05-01: Test-SPConnectivity.ps1
  .\Scripts\Test-SPConnectivity.ps1
  Expected: exit code 0, auth success

WC-05-02: Invoke-SPCampaignAudit.ps1 -- COMPLETED with leadership
  .\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 365 `
      -IncludeLeadershipRollup -LeadershipDepth 4 -DetailLevel Detailed
  Expected: 1 campaign, leadership reports in Audit\leadership\

WC-05-03: Invoke-SPCampaignAudit.ps1 -- ACTIVE campaigns
  .\Scripts\Invoke-SPCampaignAudit.ps1 -Status ACTIVE -DaysBack 365
  Expected: 1-2 campaigns (SOURCE_OWNER + delta cert)

WC-05-04: Invoke-SPADDeltaCert.ps1 -- Manager mode
  .\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-ad-001' -CampaignNamePrefix 'WinCLI-01'
  Expected: campaigns created, identity count > 0

WC-05-05: Invoke-SPADDeltaCert.ps1 -- SourceOwner mode
  .\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-ad-001' -ReviewerMode SourceOwner `
      -CampaignNamePrefix 'WinCLI-02'
  Expected: SOURCE_OWNER campaign created

WC-05-06: Invoke-SPDeltaReport.ps1 -- 48h window
  .\Scripts\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -HoursBack 48
  Expected: 8 grants, 2 revocations, delta report HTML

WC-05-07: Invoke-SPDeltaCertEscalate.ps1 -- WhatIf
  .\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 1 -WhatIf
  Expected: stale certs found, no actual reassignment

WC-05-08: Invoke-SPCampaignAudit.ps1 -- WhatIf
  .\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -WhatIf
  Expected: dry run output, no API writes, exit code 0
```

---

## W-06: Playwright -- Screenshot + Visual Validation

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** W-03, W-05

**Prerequisites:** Playwright installed (`pip install playwright && playwright install chromium`)

**Capture commands:**
```powershell
$py = "python"  # or path to python with playwright
$cap = "path\to\capture.py"  # copy from .claude-frameworks/playwright-capture/
$out = "docs\windows-screenshots"
mkdir $out -Force

# Campaign audit
& $py $cap Audit\campaign-audit-combined-*.html --full-page --output-dir $out --prefix win-audit

# Executive summary
& $py $cap Audit\leadership\executive-summary.html --full-page --output-dir $out --prefix win-exec

# VP report
& $py $cap Audit\leadership\director-AliceJohnson.html --full-page --output-dir $out --prefix win-vp

# Delta report
& $py $cap DeltaCert\reports\delta-*.html --full-page --output-dir $out --prefix win-delta

# Scroll captures
& $py $cap Audit\campaign-audit-combined-*.html --scroll-captures --scroll-step 800 --output-dir $out --prefix win-scroll
```

**Visual checks per screenshot (read each PNG):**

```
WV-06-01: Audit combined -- donut chart renders
WV-06-02: Audit combined -- tables aligned, no overflow
WV-06-03: Audit combined -- Revoked section auto-expanded with compliance fields
WV-06-04: Executive summary -- "Vice Presidents" label (not "Directors")
WV-06-05: Executive summary -- Richard Sterling in Executive Rollup
WV-06-06: VP report -- expandable <details> sections visible (triangle icons)
WV-06-07: VP report -- Manager Summary + Identity Decision Detail
WV-06-08: Delta report -- compact (1-2 page equivalent)
WV-06-09: Delta report -- dates populated, names resolved (not raw IDs)
WV-06-10: Color coding consistent: green=#339933, red=#CC3333, orange=#FF8800
```

---

## W-07: Report Content Deep Validation

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** W-06

**Open each HTML report in Edge/Chrome. Verify every section:**

**Campaign Audit (15 checks):**

```
WR-07-01: Executive Summary -- COMPLETED badge visible
WR-07-02: Donut chart -- 64% approved, 16% revoked, 20% pending (matches mock: 16/4/5 of 25)
WR-07-03: Remediation Completion bar -- 0% (4 pending, mock has no provisioning events)
WR-07-04: Risk Indicators -- Pending Items count matches
WR-07-05: Reviewer Response Time bars -- 4 reviewers shown
WR-07-06: Campaign Summary -- name, dates, status, cert count
WR-07-07: Reviewer Accountability -- Primary (4) + Reassigned (1) expandable
WR-07-08: Reviewer Performance -- Fastest/Slowest/Average/Median response times
WR-07-09: Decision Summary -- Approved (16) collapsed, Revoked (4) expanded
WR-07-10: Revoked items table -- Identity, Account (UPN), Access, Decision Date, Justification, Remediation
WR-07-11: Campaign Reports -- CERTIFICATION_SIGNOFF_REPORT + CAMPAIGN_STATUS_REPORT expandable
WR-07-12: Remediation & Reassignment Proof -- 4 revoked items, remediation status
WR-07-13: Reassignment Chain visible (1 record)
WR-07-14: Audit Metadata -- Correlation ID, Report Generated timestamp
WR-07-15: Footer -- toolkit version, generation date, correlation ID
```

---

## Cleanup (after all phases)

```powershell
# CRITICAL: Restore real config
Copy-Item Config\settings-real.json Config\settings.json -Force
Remove-Item Config\settings-real.json -ErrorAction SilentlyContinue

# Clean runtime outputs
Remove-Item -Recurse -Force Audit\, DeltaCert\ -ErrorAction SilentlyContinue

# Commit test report + screenshots
git add docs\windows-gui-test-report.md docs\windows-screenshots\
git commit -m "test: Windows GUI + CLI integration test report"
git push origin master
```

---

## Agent Loop Template

```
MAX=10
LOGDIR="docs\windows-test-rounds"
mkdir $LOGDIR -Force
$i = 0

while ($i -lt $MAX) {
    $i++
    $logFile = "$LOGDIR\round-$('{0:D2}' -f $i).md"
    "# Round $i`n**Started:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" | Out-File $logFile

    claude --model claude-opus-4-6 -p "
    You are testing the SailPoint Governance Toolkit GUI and CLI on Windows PS 5.1.

    BACKLOG: docs\windows-gui-test-backlog.md
    ROOT: (this directory)
    BRANCH: feature/windows-gui-tests

    Find the next PENDING phase (W-01 to W-07). Execute all tests in that phase.
    For GUI tests: launch Show-SPDashboard.ps1 and interact with the WPF controls.
    For CLI tests: run each script and capture exit codes + output.
    For Playwright: capture screenshots and read each PNG for visual review.

    Log every test result as PASS or FAIL with notes.
    Fix any bugs found in the same round.
    Update backlog to DONE, commit, push to feature/windows-gui-tests.
    Exit 0 if more phases remain. Exit non-zero when all DONE.

    Mock API is at http://10.0.0.143:8080 (already configured in settings.json).
    Do NOT use emoji. Always restore Config\settings.json from backup before committing.
    " *>> $logFile

    if ($LASTEXITCODE -ne 0) {
        "**Status:** FINISHED" | Out-File $logFile -Append
        Write-Host "--- Loop ended at round $i ---"
        break
    }

    "**Completed:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $logFile -Append
    "**Status:** SUCCESS" | Out-File $logFile -Append
    Write-Host "--- Round $i of $MAX complete ---"
    Start-Sleep -Seconds 5
}

Write-Host "Stopped after $i round(s)."
```

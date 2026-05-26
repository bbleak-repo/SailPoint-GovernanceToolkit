# Round 5 -- W-02b: Interactive FlaUI backfill of W-02 GUI tests

**Started:** 2026-05-23
**Branch:** feature/windows-gui-tests
**Phase:** W-02b (GUI -- Settings + Campaigns + Evidence tabs, REAL visible WPF window)
**Mock API:** http://10.0.0.143:8080 (UP this round -- HTTP 200 on /health)

## Setup

- Backed up `Config\settings.json`      -> `Config\settings-real.json`
- Backed up `Config\settings.local.json` -> `Config\settings-local-real.json`
- Wrote identical mock config to **both** `settings.json` and `settings.local.json`
  (TenantUrl/OAuth/API BaseUrl -> 10.0.0.143:8080, DeltaCert SourceIds populated,
  AllowCompleteCampaign=true, FallbackReviewerIdentityId=id-orphan-1).
- Probed mock health (`GET http://10.0.0.143:8080/health`): HTTP 200.

## Test Approach

Built `Tests\Harness\Test-W02b-GuiInteractive.ps1`, the first **interactive**
WPF harness in this branch. It uses `Tests\Harness\SP.UiTest.psm1` (FlaUI 4.0
UIA3, vendored at `Tests\Tools\FlaUI\`) to drive a real visible dashboard:

1. `Start-SPDashboardForTest` spawns a child `powershell.exe -STA -File
   Scripts\Show-SPDashboard.ps1 -ConfigPath ...` and attaches UIA3 to the
   child PID; `app.GetMainWindow($automation, 45s)` returns the main window.
2. Tab navigation uses the typed `TabItem.Select()` (SelectionItemPattern);
   button clicks use `Invoke` pattern explicitly so they don't depend on a
   mouse arriving at the right coordinates.
3. `TxtDcHoursBack` edits go through ValuePattern.SetValue with a 3s
   verify-loop on read-back -- cross-process UIA writes are async, and without
   the wait the subsequent `BtnSaveSettings.Invoke` raced past the TextProperty
   update on the first cut (observed in the working tree -- see Bugs section).
4. After `BtnSaveSettings.Invoke`, the Save handler shows
   `[System.Windows.MessageBox]::Show(..., 'Saved', ...)`. We dismiss it by
   first sweeping `Application.GetAllTopLevelWindows`, then falling back to a
   desktop-wide `UIA3Automation.GetDesktop().FindFirstDescendant(Window, Name='Saved')`
   -- the WPF MessageBox surfaces as a Win32 `#32770` dialog that
   `Application.GetAllTopLevelWindows` did not always enumerate.
5. Per-test screenshots are captured via `Save-SPUiScreenshot` to
   `docs\windows-test-rounds\WG-02b-*.png`.
6. JSONL emitted to `docs\windows-test-rounds\WG-02b-results.jsonl` (one
   compact line per test + a `summary` line). Exit 0 when no FAIL.

## Test Results

| ID        | Result | Notes |
|-----------|--------|-------|
| WG-02b-01 | PASS   | Window 'SailPoint ISC Governance Toolkit' attached (child PID per run); 5 tabs (Campaigns/Evidence/Settings/Audit/Delta Cert) discoverable via UIA |
| WG-02b-02 | PASS   | All 6 settings section headers visible after Settings tab Select: Environment, Authentication, API Configuration, Testing, Safety Controls, Delta Cert |
| WG-02b-03 | PASS   | 6/6 Delta Cert AutomationIds present in live tree: TxtDcSourceIds, TxtDcHoursBack, TxtDcDeadlineDays, CboDcReviewerMode, TxtDcCampaignPrefix, TxtDcOutputPath |
| WG-02b-04 | PASS   | Quick Connect: PbBrowserToken (IsPassword=True), BtnApplyToken, BtnClearToken, BrowserTokenStatus all present |
| WG-02b-05 | PASS   | Save round trip on TxtDcHoursBack: UI 24/disk 24 -> SetValue('48') verified ui=48 -> BtnSaveSettings.Invoke -> disk=48, status='Settings saved successfully.', 'Saved' MessageBox dismissed -> SetValue('24') verified ui=24 -> Invoke -> disk=24, status='Settings saved successfully.', dialog dismissed |
| WG-02b-06 | PASS   | Campaigns tab: BtnRunSelected + BtnRunAll + BtnRunSmoke + BtnRefreshCampaigns + CampaignGrid + CurrentTestLabel + ResultSummaryText all present. SuiteProgressBar is `Visibility=Collapsed` pre-run by design, so it is intentionally absent from the live UIA tree until a run begins; the spec's "progress bar area" is satisfied by CurrentTestLabel + ResultSummaryText |
| WG-02b-07 | PASS   | Evidence tab: EvidenceTree + EvidenceDetailGrid + BtnRefreshEvidence + BtnOpenInBrowser + BtnExportAll all present |
| WG-02b-08 | PASS   | All 5 tabs selectable in spec order Campaigns -> Evidence -> Settings -> Audit -> Delta Cert; IsSelected went True within 2s each; per-tab screenshot written |

**Totals: 8 PASS / 0 FAIL / 0 BLOCKED / 8 total. Exit 0.**

## Harness Command

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass `
    -File .\Tests\Harness\Test-W02b-GuiInteractive.ps1 `
    -JsonlPath docs\windows-test-rounds\WG-02b-results.jsonl `
    -ScreenshotDir docs\windows-test-rounds
```

## Artifacts (`docs\windows-test-rounds\`)

- `WG-02b-results.jsonl`              -- one line per test + summary
- `WG-02b-01-launched.png`            -- main window after attach
- `WG-02b-02-settings-tab.png`        -- Settings tab with all 6 section headers visible
- `WG-02b-05-after-save-roundtrip.png` -- after second Save (TxtDcHoursBack back to 24)
- `WG-02b-06-campaigns-tab.png`       -- Campaigns toolbar + DataGrid
- `WG-02b-07-evidence-tab.png`        -- Evidence tree + detail grid
- `WG-02b-08-tab-Campaigns.png` / -Evidence / -Settings / -Audit / -DeltaCert -- one per tab after .Select()

## Bugs Found + Fixes (development iterations -- captured here so the harness pattern is durable)

1. **`settings.local.json` overlay broke headless launches.**
   `Get-SPConfig` (SP.Config.psm1:467) calls `Resolve-SPConfigPath` when no
   `-ConfigPath` is supplied, and that helper prefers `Config\settings.local.json`
   over `Config\settings.json`. The dashboard's background runspaces call
   `Get-SPConfig` without a path, so they ignored the mock `settings.json` and
   loaded the gitignored `settings.local.json` (which pointed at
   `https://example.invalid` and was missing `Audit.LeadershipDepth`,
   `Audit.RiskIndicators`, `Audit.Smtp`, `Audit.IncludeLeadershipRollup`).
   That triggered tens of thousands of `WARNING: Configuration key
   'Audit.X' not found. Using default value.` lines on stderr and OAuth
   attempts against an invalid host -- the main window never finished
   initialising within the 45s `GetMainWindow` timeout. Fix this round: back
   up `Config\settings.local.json` to `Config\settings-local-real.json` and
   mirror the mock config into it for the duration of the test run.
   Cleanup restores the original. *No product change.*

2. **Cross-process UIA SetValue raced ahead of the Save click.**
   First cut called `$vp.SetValue('48')` then `$btnSave.Click()` immediately;
   the Save handler read `TxtDcHoursBack.Text == '24'` because the WPF
   TextProperty had not yet been updated when the click handler ran on the
   dispatcher. Hardened `Set-SPUiTextValue` with a 3s verify-loop that reads
   the value back through FlaUI and only returns once it matches. After the
   change, `uiAfterSet1=48` and `disk1=48` both confirm the write
   propagated before Save fired.

3. **WPF `MessageBox.Show` is a Win32 `#32770` dialog -- not always in
   `Application.GetAllTopLevelWindows`.** The first dismiss helper only
   walked the per-application enumeration and missed the modal even though
   it was visibly up. Extended `Dismiss-SPUiSavedDialog` to fall back to a
   desktop-wide search (`Automation.GetDesktop().FindFirstDescendant(
   Window, Name='Saved')`) and Invoke its OK button. Both Save dialogs
   were then dismissed within the polling window.

## Cleanup

- `Config\settings.json`       restored from `Config\settings-real.json` (then removed backup).
- `Config\settings.local.json` restored from `Config\settings-local-real.json` (then removed backup).
- Per-run runtime outputs untouched (`Audit\`, `DeltaCert\`).
- WPF child `powershell.exe` always terminated by `Stop-SPDashboardForTest`
  (including a final best-effort modal sweep so we don't leak a blocked PID
  if a test threw mid-Save).

## Files Added/Changed This Round

- `Tests\Harness\Test-W02b-GuiInteractive.ps1` (new) -- interactive W-02b harness driving real visible WPF.
- `docs\windows-gui-test-backlog.md` -- W-02b status -> DONE.
- `docs\windows-test-rounds\round-05.md` (this file).
- `docs\windows-test-rounds\WG-02b-*.png` and `WG-02b-results.jsonl` -- evidence.

**Remaining phases:** W-03b, W-04, W-05, W-06, W-07 -- exiting 0 so the loop continues.
**Status:** SUCCESS

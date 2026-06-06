# Round 19
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-19 -- Test-W08b-SdkTabInteractive.ps1 (AUTHOR ONLY -- DEFERRED RUN)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-19 @ line 425; Cert Summaries deferral @ 396-421)
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract, round template, GUI-testing boundary)
- `Tests/Harness/Test-W03b-AuditTabInteractive.ps1` (canonical W-xxb pattern mirrored verbatim: param block, STA guard, Add-Result JSONL sink, mock `/health` probe -> BLOCKED guard, try/finally Stop-SPDashboardForTest, summary line + exit code, Find-SPModalByTitle)
- `Tests/Harness/SP.UiTest.psm1` (FlaUI harness exports: Start/Stop-SPDashboardForTest, Find-SPUiElement, Find-SPUiTab, Save-SPUiScreenshot)
- `Gui/MainWindow.xaml` lines ~1107-1687 (runtime SDK tab; authoritative x:Names + camelCase grid bindings)
- `Gui/SdkTemplateScheduleDialog.xaml` (modal Title="Set Template Schedule", BtnCancel, CboScheduleType default MONTHLY)
- `Modules/SP.Gui/SP.MainWindow.psm1` (Invoke-SdkTemplateEditSchedule + Show-SPGuiDialog -- confirms dialog title preserved)

**Did:** Authored the deferred interactive FlaUI test `Tests/Harness/Test-W08b-SdkTabInteractive.ps1`
(WG-08-11..22) by mirroring the W-03b pattern exactly. The script: guards STA (exit 2);
resolves toolkitRoot/ConfigPath/ScreenshotDir/JsonlPath and truncates the JSONL up front;
imports `SP.UiTest.psm1 -Force`; probes `$MockBaseUrl/health` via Invoke-RestMethod and marks
all 12 live-dependent steps BLOCKED if the mock is down; launches the dashboard once via
`Start-SPDashboardForTest -TimeoutSeconds 45` and tears down with `Stop-SPDashboardForTest`
in a `finally`. Steps: navigate to "SDK Features" + assert SdkSubTabControl (11); Templates
Refresh -> 3 rows (12); Edit Schedule modal "Set Template Schedule" shows MONTHLY then Cancel (13);
Approvals RbSdkPending->4 / RbSdkCompleted->3 (14); SdkApprovalSummaryPanel renders counts,
best-effort (15); Work Items Refresh -> badges 4/2/6 + 4 pending rows (16); ChkSdkShowCompleted
ON -> 6 rows (17); Workflows Refresh -> 4 rows + Executions populate (18); enabled column one
disabled = wf-004 (19); Filters Include System ON -> 3, OFF -> fewer (20); tooltip hover soft-PASS
(21); 5-active-sub-tab screenshot round, Cert Summaries omitted (22). Every bridge/runspace step
uses the 5000ms polling finder (`Get-SPUiGridRows`), never a fixed sleep as the wait mechanism.
Default `$MockBaseUrl='http://localhost:8080'` (drift vs W-03b's hardcoded remote host, resolved
per backlog/plan; kept overridable). No Cert Summaries interactive step and no
destructive/Safety-gated action clicks, so no confirmation MessageBox can block the run.

**Files:**
- `Tests/Harness/Test-W08b-SdkTabInteractive.ps1` (new)
- `docs/phase7-sdk-gui-backlog.md` (SDK-19 status TODO -> AUTHORED; round-19 note)
- `docs/phase7-sdk-gui-rounds/round-19.md` (this file)

**Verification:**
  - Pester: n/a -- this is an interactive FlaUI harness script, not a `*.Tests.ps1` unit test; there is no Pester file for it. Required gate is ParseFile.
  - ParseFile: `[System.Management.Automation.Language.Parser]::ParseFile` -> **0 errors**.
  - x:Name cross-check: all 23 `-AutomationId` strings used against `$ui.Window` resolve in `Gui/MainWindow.xaml` (the only MISSING token is `BtnCancel`, which is correctly a control of the `SdkTemplateScheduleDialog.xaml` modal, not the main window). Cert Summaries x:Names (CboSdkCert*, BtnSdkRefreshSummaries, SdkCertSummaryGrid) and `Invoke-SdkCertSummaryRefresh` are all absent from the test (correct -- deferred).
  - XAML parse: n/a (no XAML modified).
  - Manifest/import: n/a (no module modified; SP.UiTest.psm1 reused unchanged).
  - Step coverage: WG-08-11..22 all present via Add-Result; terminating `{summary;pass;fail;blocked;total}` line + `exit 0`-on-no-FAIL / `1`-otherwise branch present.

**Review:** <PASS | FAIL: findings>  (filled by the code-review gate)
**Backlog update:** SDK-19 -> AUTHORED

**NOTE -- DEFERRED RUN:** Per the protocol GUI-testing boundary, the interactive run was
NOT executed in the loop. It requires a live Windows STA GUI session + the mock Pode
server at localhost:8080 and is the human's final acceptance gate. The loop only authored
the file and verified it statically (ParseFile clean + x:Name cross-check).

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

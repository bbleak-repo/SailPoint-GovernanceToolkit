# Round 19
**Started:** 2026-06-05 00:00:00
**Item:** AR-19 -- Interactive FlaUI W-09b (AUTHOR only)

**Read:**
- `docs/adaptive-reports-backlog.md` (AR-19 spec + Phase Summary).
- `docs/adaptive-reports-rounds/round-00-PROTOCOL.md` (loop rules, additive directive, round template).
- `Tests/Harness/Test-W08b-SdkTabInteractive.ps1` (the template mirrored: param block + STA guard + path defaults + Add-Result sink + Invoke-SPUiButton/Set-SPUiCheckTo helpers + /health BLOCKED guard + dashboard launch + status-label polling + screenshot/summary/exit).
- `Tests/Harness/Test-W09-AdaptiveTabStructure.ps1` (the W-09-verified AutomationId set the new harness depends on).
- `Tests/Harness/SP.UiTest.psm1` (Start/Stop-SPDashboardForTest, Find-SPUiTab/Find-SPUiElement, Save-SPUiScreenshot signatures).
- `Gui/MainWindow.xaml` lines 1718-1866 (the flat Adaptive Reports tab: AdaptiveReportsTabContent Grid, anchor/theme/days-back, Chk components/baselines, BtnArGenerate/OpenFolder/OpenReport, progress bar, AdaptiveReportsStatusLabel) + line 2249 (global StatusBarText).
- `Modules/SP.Gui/SP.MainWindow.psm1` lines 3028-3435 (Resolve-AdaptiveOutputPath output-dir derivation, Invoke-GuiAdaptiveReport success/fail status text 'Generated N report(s).'/'Adaptive report failed: ...' on AdaptiveReportsStatusLabel, file naming adaptive-<Anchor>-<stamp>.html + <key>-<stamp>.html, Invoke-GuiAdaptiveOpenReport 'No report generated yet.' on StatusBarText via Set-StatusMessage, $script:LastAdaptiveReportPath set on success).

**Did:** Authored `Tests/Harness/Test-W09b-AdaptiveTabInteractive.ps1` by mirroring W-08b almost line-for-line, retargeted to the FLAT Adaptive Reports tab (no nested TabControl / sub-tabs). It copies the W-08b param signature verbatim (-ConfigPath/-JsonlPath/-ScreenshotDir/-MockBaseUrl='http://localhost:8080'/-RefreshTimeoutMs=5000) -- the exact signature Invoke-FullGuiValidation.ps1 already wires (AR-18) -- the STA guard, the path defaults (Jsonl filename changed to WG-09b-results.jsonl), the Add-Result JSONL sink, and the Invoke-SPUiButton + Set-SPUiCheckTo helpers (plus a small Get-SPUiToggleState; Find-SPModalByTitle omitted -- no modal on this tab). The /health probe sets $mockUp; if the mock is down, $liveStepIds = WG-09-11..14 are all BLOCKED with the 'Generate will not produce a report.' note and live steps are skipped; the live block is wrapped in try/finally that always calls Stop-SPDashboardForTest. Live walk: WG-09-11 navigate + resolve AdaptiveReportsAnchorCombo (gate $tabReady); WG-09-12 assert anchor/theme/days-back resolve + make ChkArCompKpiCards explicitly On + opt-in ChkArBaseInventory (gate $configOk); WG-09-13 (core) snapshot $outDir *.html BEFORE clicking, click BtnArGenerate, poll AdaptiveReportsStatusLabel up to 90s for '^Generated \d+ report' or 'failed', then poll $outDir up to 10s for a NEW *.html, PASS only if BOTH the success text AND a new file appear; WG-09-14 click BtnArOpenReport and assert the global StatusBarText does NOT flip to 'No report generated yet.', plus a screenshot-only soft-note Open Folder invoke. $outDir is re-derived exactly as Resolve-AdaptiveOutputPath does (config .Audit.OutputPath fallback '.\Audit', resolve vs toolkit root, Join 'adaptive', GetFullPath). DID NOT execute the harness (it needs a live STA GUI session + mock; a human runs it).

**Files:** `Tests/Harness/Test-W09b-AdaptiveTabInteractive.ps1` (CREATE -- the only file). Additive: brand-new file, touches nothing existing. Invoke-FullGuiValidation.ps1 already references it (AR-18), so no edit there; SP.MainWindow.psm1 / MainWindow.xaml / SP.UiTest.psm1 / Test-W09 unchanged.

**Verification:**
  - AST: `[Parser]::ParseFile` -> **AST OK: 0 errors**.
  - x:Name cross-check: every `-AutomationId` literal in the harness (AdaptiveReportsAnchorCombo, AdaptiveReportsThemeCombo, AdaptiveReportsDaysBackBox, ChkArCompKpiCards, ChkArBaseInventory, BtnArGenerate, BtnArOpenReport, BtnArOpenFolder, AdaptiveReportsStatusLabel) is in the W-09-verified Adaptive-tab set; the one non-Adaptive id, StatusBarText, is the global main-window status bar (MainWindow.xaml line 2249, the Set-StatusMessage target for the Open-Report 'No report generated yet.' failure).
  - W-09 structure harness (proves every dependent id exists in the runtime XAML): **pass=7 fail=0 blocked=0** (WG-09-01..07 all PASS).
  - NOT executed: Test-W09b itself / Show-SPDashboard / FlaUI / Invoke-FullGuiValidation -Phase W-09b live -- deferred to the human acceptance run, per protocol.

**Review:** PASS (self-check vs spec: param block + preamble verbatim, Jsonl default WG-09b-results.jsonl, helpers limited to Invoke-SPUiButton/Set-SPUiCheckTo, /health BLOCKED guard with the 4 live ids, try/finally Stop, core WG-09-13 snapshot-before + dual status-and-file assertion, additive-only). Awaiting the independent code-review gate.

**Backlog update:** AR-19 -> AUTHORED

**Completed:** 2026-06-05 00:00:00
**Status:** SUCCESS

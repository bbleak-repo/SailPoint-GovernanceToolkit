# Round 15
**Started:** 2026-06-05 00:00:00
**Item:** AR-15 -- Initialize-SPAdaptiveTab handlers

**Read:**
- `docs/adaptive-reports-backlog.md` (AR-15 item + Phase Summary), `docs/adaptive-reports-rounds/round-00-PROTOCOL.md`.
- `Scripts/Invoke-SPAdaptiveReport.ps1` (the canonical report chain: Get-SPAuditCampaigns -> build audits -> Build-SPRCDataset -> New-RCContext/New-ComposableReport / baselineMap Export-* dispatch; output path `{Audit.OutputPath}\adaptive`).
- `Modules/SP.Gui/SP.MainWindow.psm1` -- the proven Delta Cert analog: `Initialize-DeltaCertTab` (1860), `Invoke-GuiDeltaReport` (2685), `Resolve-DeltaCertOutputPath` (2891), `Resolve-AuditOutputPath` (1821), `Wait-SPReportFileReady` (2633), `Set-StatusMessage`/`Invoke-OnDispatcher`, the audit progress idiom (1626), the state block (32-88), and the `Export-ModuleMember` at EOF (was `Show-SPDashboard` only).
- `Gui/MainWindow.xaml` (AR-14 tab `AdaptiveReportsTabContent` + all `AdaptiveReports*`/`ChkAr*`/`BtnAr*` x:Names; anchor/theme combos use ComboBoxItem `Content`; progress bar is `IsIndeterminate`-driven).
- `Modules/SP.Gui/SP.Gui.psd1` (explicit FunctionsToExport allowlist).

**Did:**
Added a `#region Adaptive Reports Tab` to `SP.MainWindow.psm1` with three functions mirroring the Delta Cert pattern: `Resolve-AdaptiveOutputPath` (Resolve-AuditOutputPath + `\adaptive`, matching the CLI's effectiveOutputPath), `Initialize-SPAdaptiveTab` (captures `$module=$script:ThisModule`, Find-Control lookups, wires BtnArGenerate/BtnArOpenFolder/BtnArOpenReport with `& $module { param(...) } $args` + `.GetNewClosure()`, sets an initial status, no auto-run/no API on init), and the internal helpers `Invoke-GuiAdaptiveReport` + `Invoke-GuiAdaptiveOpenReport`. Generate gathers all UI selections on the UI thread (anchor/theme/daysBack + the 5 component checks mapped to kpi-cards/heatmap/tree/top-n/group-table and the 7 baseline checks mapped to inventory/privileged/orphaned/exec-summary/roster/access-cert/sod; guard if both empty), then runs the SAME CLI chain on a background STA runspace that imports SP.Core/Api/Audit/DeltaCert/ReportComponents/AdaptiveReports (+SP.Gui for parity), returns a `@{Success;Data=@{Generated;Primary};Error}` envelope, marshals a status string back via `$MainWindow.Dispatcher.Invoke`, and a completion DispatcherTimer (copied from Invoke-GuiDeltaReport) EndInvokes, opens the primary HTML via `Wait-SPReportFileReady` + `Start-Process`, records `$script:LastAdaptiveReportPath`, re-enables the button, clears the indeterminate progress bar, and resets `$script:IsAdaptiveRunning` in `finally`. Added `$script:IsAdaptiveRunning`/`$script:LastAdaptiveReportPath` to the state block. Exported `Initialize-SPAdaptiveTab` (manifest FunctionsToExport + the SP.MainWindow `Export-ModuleMember`) and bumped the psd1 ReleaseNotes (v1.5.0).

**Files:**
- `Modules/SP.Gui/SP.MainWindow.psm1` (edit, additive): +2 `$script:` state vars; new `#region Adaptive Reports Tab` (3 new functions); +1 entry in the EOF `Export-ModuleMember`. No existing function/handler/tab touched. Show-SPDashboard tab-init sequence NOT edited (that is AR-16).
- `Modules/SP.Gui/SP.Gui.psd1` (edit, additive): +`Initialize-SPAdaptiveTab` in FunctionsToExport; ReleaseNotes bumped (v1.5.0).

> Note on the extra (beyond named-files) edit: the spec named only the two files above and the manifest export; during verification I confirmed that the manifest allowlist alone cannot surface a nested-module function that the nested module's own `Export-ModuleMember` does not export (`SP.MainWindow.psm1` exported only `Show-SPDashboard`). To satisfy the AR-15 Get-Command acceptance I added the function to that `Export-ModuleMember` array too -- a single additive entry, no existing export removed. `Invoke-GuiAdaptiveReport`/`Invoke-GuiAdaptiveOpenReport`/`Resolve-AdaptiveOutputPath` stay internal, matching Invoke-GuiDeltaReport/Resolve-AuditOutputPath.

**Verification:** (headless, fresh PowerShell 5.1 process, from toolkit root)
  - AST parse of `SP.MainWindow.psm1`: **0 errors** (AST OK).
  - `Test-ModuleManifest SP.Gui.psd1`: **OK** (SP.Gui 1.0.0).
  - Import + Get-Command: **Initialize-SPAdaptiveTab RESOLVES OK** (ExportedFunctions 34 -> 35).
  - Regression: **Show-SPDashboard still exports**; `Invoke-GuiAdaptiveReport` and `Resolve-AdaptiveOutputPath` correctly **unexported** (internal).
  - XAML sanity: `MainWindow.xaml` still parses via XamlReader (no window shown) -- unchanged.
  - FORBIDDEN (not run): real WPF dashboard, FlaUI/W-09b, full 10-min Pester suite. Live generate is AR-19.

**Review:** (self-pre-check vs round-00 gate) local `$module = $script:ThisModule` captured once; every delegate is `& $module { param(...) } $args` + `.GetNewClosure()`; no bare `$script:` in raw delegates (only inside re-entered `& $capturedModule {}` blocks, as Invoke-GuiDeltaReport does); all API/IO is inside the STA runspace; cross-thread UI via `$MainWindow.Dispatcher.Invoke` (runspace) + Set-StatusMessage/Invoke-OnDispatcher (UI thread); HTML opened only after Wait-SPReportFileReady; report logic reused from the CLI chain, not duplicated; additive only. -> handed to the independent review gate.

**Backlog update:** AR-15 -> DONE

**Completed:** 2026-06-05 00:00:00
**Status:** SUCCESS

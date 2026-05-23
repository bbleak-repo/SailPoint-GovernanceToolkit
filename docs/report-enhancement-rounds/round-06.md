# Round 6
**Started:** 2026-05-23 12:58:56

Warning: no stdin data received in 3s, proceeding without it. If piping from a slow command, redirect stdin explicitly: < /dev/null to skip, or wait longer.
---

**R-06: Delta Report CLI + GUI -- SUMMARY**

**Feature implemented:** R-06 Delta Report CLI + GUI

**Files created:**
- `Scripts/Invoke-SPDeltaReport.ps1` -- CLI script with `-SourceId`, `-HoursBack`, `-OutputPath`, `-Token`, `-TokenExpiryMinutes`, `-OutputMode`, `-ConfigPath` parameters. Follows the same module-loading, auth, and config patterns as `Invoke-SPADDeltaCert.ps1`. Generates HTML + JSONL output via `Get-SPDeltaReportData` and `Export-SPDeltaReportHtml`.

**Files modified:**
- `Gui/MainWindow.xaml` -- Added "Generate Delta Report" button to Delta Cert tab Row 2 (between "Run Escalation" and the spacer)
- `Modules/SP.Gui/SP.GuiBridge.psm1` -- Added `Invoke-SPGuiDeltaReport` bridge function + exported it in `Export-ModuleMember`
- `Modules/SP.Gui/SP.MainWindow.psm1` -- Added `BtnGenerateDeltaReport` control lookup in `Initialize-DeltaCertTab`, click handler wiring, and `Invoke-GuiDeltaReport` function (background runspace pattern matching existing cleanup/escalation handlers; opens HTML in browser on completion)
- `docs/report-enhancements-backlog.md` -- R-06 status updated to DONE

**Issues encountered:** None

**Commit hash:** `4b54b9d`

**Completed:** 2026-05-23 13:04:23
**Status:** SUCCESS - more features remain

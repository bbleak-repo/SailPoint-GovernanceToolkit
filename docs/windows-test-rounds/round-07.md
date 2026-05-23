# Round 7 -- W-04: GUI -- Delta Cert Tab (interactive, FlaUI)

**Started:** 2026-05-23
**Phase:** W-04
**Status:** SUCCESS -- 14/14 PASS
**Harness:** `Tests\Harness\Test-W04-DeltaCertInteractive.ps1`
**Mock:** http://10.0.0.143:8080 (reachable, `/health` returned `{status:'ok'}`)
**Run command:** `powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\Tests\Harness\Test-W04-DeltaCertInteractive.ps1`

## Summary

| Result   | Count |
|----------|-------|
| PASS     | 14    |
| FAIL     | 0     |
| BLOCKED  | 0     |
| **Total**| **14**|

Exit code: 0.

## Per-test results

| ID         | Result | Note |
|------------|--------|------|
| WG-04-01   | PASS   | Delta Cert tab Row 0 visible -- `DeltaCertSummaryLabel` (`Sources: src-ad-001 | 24h | 2d deadline | Manager`) + `BtnConfigureDeltaCert` + `BtnRunDeltaCert` |
| WG-04-02   | PASS   | `Delta Cert Run Parameters` modal opened with 4 fields (`TxtSourceIds`, `TxtHoursBack`, `TxtDeadlineDays`, `CboReviewerMode`) |
| WG-04-03   | PASS   | Pre-populated from `Config\settings.json`: SourceIds=`src-ad-001`, HoursBack=24, DeadlineDays=2, ReviewerMode=Manager |
| WG-04-04   | PASS   | Filled `src-ad-001 / 48h / 2d / Manager`, clicked `Run Delta Cert`; modal closed; status -> `Running delta cert...` |
| WG-04-05   | PASS   | Completed: `Delta cert complete. Campaigns: 0, Reason: DuplicatesExist`; `DeltaCertResultGrid` populated with 1 row (mock returned `DuplicatesExist` because pre-existing AD Delta Cert campaign exists in mock data; 0 campaigns created is expected). |
| WG-04-06   | PASS   | Re-opened Configure -- dialog pre-populated with LAST USED values (`src-ad-001` / 48 / 2 / Manager), confirming `$script:LastDeltaCertParams` is honored |
| WG-04-07   | PASS   | `DeltaCertSummaryLabel` text after run: `Sources: src-ad-001 | 48h | 2d deadline | Manager` |
| WG-04-08   | PASS   | `Cleanup complete: 0 completed, 1 still active, 0 error(s)` -- the 1 active campaign is below the 3-day stale threshold so cleanup correctly left it alone |
| WG-04-09   | PASS   | `Escalation Parameters` modal opened with 3 fields (`TxtCampaignPrefix`, `TxtStaleHours`, `TxtMaxLevels`) |
| WG-04-10   | PASS   | Filled prefix=`AD Delta Cert` / stale=1h / levels=2, clicked Run Escalation; result: `Escalation complete: 1 stale, 0 escalated, 1 skipped, 0 error(s)` -- skipped because the mock stale cert has no EffectiveReviewer set (fix below) |
| WG-04-11   | PASS   | `BtnOpenDeltaCertFolder` spawned a fresh `explorer.exe` for `DeltaCert\` and was cleaned up |
| WG-04-12   | PASS   | `Delta report generated: 8 grants, 2 revocations, 0 pending, 0 anomalies`; 1 HTML file written under `DeltaCert\reports\`; spawned browser process killed |
| WG-04-13   | PASS   | `DeltaCertHistoryList` populated from `DeltaCert\deltacert-audit.jsonl` with 1 entry: `2026-05-23T23:53:03.721Z | Campaigns: 0 | DuplicatesExist` |
| WG-04-14   | PASS   | `BtnRefreshDeltaCertHistory` click did not throw; history list still shows 1 item after refresh |

## Bugs found + fixed this round

### Bug 1: `Invoke-SPGuiDeltaReport` not exported from `SP.Gui`

WG-04-12 initially failed with `Delta report failed: ` (empty error). Root cause:
`Invoke-SPGuiDeltaReport` is defined in `Modules\SP.Gui\SP.GuiBridge.psm1` and is
listed in `Export-ModuleMember` at the bottom of that nested module, but it was
**missing** from `FunctionsToExport` in `Modules\SP.Gui\SP.Gui.psd1`. The
module-manifest filter strips functions not listed in the manifest even when
the nested module exports them, so the background runspace's
`Import-Module SP.Gui` did not expose `Invoke-SPGuiDeltaReport`.

When `Invoke-GuiDeltaReport`'s runspace scriptblock then called the function it
threw `CommandNotFoundException`, the scriptblock's return value (`$reportResult`)
remained unbound, and the dispatcher action wrote the empty
`"Delta report failed: $($capturedResult.Error)"` to the status label.

Fix: added `'Invoke-SPGuiDeltaReport'` to `FunctionsToExport` in
`Modules\SP.Gui\SP.Gui.psd1`. WG-04-12 now passes with status
`Delta report generated: 8 grants, 2 revocations, 0 pending, 0 anomalies`.

### Bug 2: `Invoke-SPDeltaCertEscalate` blows up on stale certs with no reviewer

WG-04-10 initially failed with
`Invoke-SPDeltaCertEscalate failed: Cannot validate argument on parameter 'IdentityId'.
The argument is null or empty.`

Root cause: `Get-SPDeltaCertStaleCertifications` returns
`ReviewerIdentityId = ''` when the underlying cert has no `EffectiveReviewer` (or
the reviewer object has no `id`) -- a real situation the mock exposed.
`Invoke-SPDeltaCertEscalate` then forwarded that empty string to
`Get-SPDeltaIdentityDetail`, whose parameter has `[ValidateNotNullOrEmpty()]`,
crashing the whole escalation run.

Fix: in `Modules\SP.DeltaCert\SP.DeltaCertRunner.psm1`, before calling
`Get-SPDeltaIdentityDetail -IdentityId $reviewerId`, guard with
`[string]::IsNullOrWhiteSpace($reviewerId)`; if empty, write a WARN log and
push the cert into `$skipped`. Matches the existing pattern used a few lines
below for empty `ManagerId`. WG-04-10 now passes with
`Escalation complete: 1 stale, 0 escalated, 1 skipped, 0 error(s)`.

## Artifacts

- Harness: `Tests\Harness\Test-W04-DeltaCertInteractive.ps1`
- Per-test JSONL: `docs\windows-test-rounds\WG-04-results.jsonl`
- stdout/stderr: `docs\windows-test-rounds\WG-04-stdout.txt`
- Screenshots (12 PNGs):
  - `WG-04-01-tab.png`            -- Delta Cert tab Row 0
  - `WG-04-02-config-dialog.png`  -- Configure modal (empty input)
  - `WG-04-04-run-filled.png`     -- Run modal filled with `src-ad-001 / 48 / 2 / Manager`
  - `WG-04-05-run-done.png`       -- After successful run; DataGrid populated
  - `WG-04-06-reopen.png`         -- Re-opened Configure shows LAST USED
  - `WG-04-08-cleanup.png`        -- Cleanup status
  - `WG-04-09-escalate-dialog.png`-- Escalation modal
  - `WG-04-10-escalation-done.png`-- Escalation status
  - `WG-04-11-open-folder.png`    -- Open Output Folder
  - `WG-04-12-delta-report.png`   -- After Generate Delta Report success
  - `WG-04-13-history.png`        -- History list populated from JSONL
  - `WG-04-14-refresh.png`        -- History after Refresh click

## Notes

- `Config\settings.json` was overlaid with the 10.0.0.143 mock configuration
  for the test run (matching `Config\settings.local.json`). `git restore` after
  to confirm no unintended change vs HEAD.
- `DeltaCert\` directory was cleaned before the run so we observe a fresh
  `deltacert-audit.jsonl` + `reports\` written by this round only.
- `Invoke-SPGuiDeltaReport` opens the generated HTML in the system default
  browser via `Start-Process`; the harness snapshots browser PIDs and kills
  any new ones after WG-04-12.
- Cross-process WPF input quirks documented in `feedback_flaui_mouse_doubleclick`
  did not apply to W-04: every button on the Delta Cert tab is invoked via the
  `Invoke` UIA pattern (single-click semantics), no MouseDoubleClick required.

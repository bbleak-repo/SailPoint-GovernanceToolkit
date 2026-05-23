# Round 4 -- W-03: GUI Audit Tab

**Started:** 2026-05-23
**Branch:** feature/windows-gui-tests
**Phase:** W-03 (GUI -- Audit tab: query + audit + leadership)
**Mock API:** http://10.0.0.143:8080 (DOWN this round -- live-mock items BLOCKED)

## Setup

- Backed up `Config\settings.json` -> `Config\settings-real.json`.
- Patched `Config\settings.json` with mock values (TenantUrl/OAuth/API BaseUrl -> 10.0.0.143:8080, DeltaCert SourceIds populated, AllowCompleteCampaign=true).
- Probed mock health (`GET http://10.0.0.143:8080/health`): `Unable to connect to the remote server` -- ICMP to 10.0.0.143 succeeds, TCP/8080 closed. Mock host (macOS) reachable but Pode service stopped.

## Test Approach

Built `Tests\Harness\Test-W03-AuditTabStructure.ps1` extending the W-02 pattern:

1. Child STA `powershell.exe` so WPF event handlers bind correctly.
2. Loads `Gui\MainWindow.xaml` via `XamlReader.Load`, walks the logical tree to the `Audit` `TabItem.Content`.
3. Loads `Gui\AuditQueryDialog.xaml` separately and verifies the 3 named fields + the new `365 days` timespan option (added this round -- see Bugs).
4. Imports `SP.Core` + `SP.GuiBridge` + `SP.MainWindow` directly, then back-fills `$script:ToolkitRoot`, `$script:ConfigPath`, `$script:ThisModule` (normally set by `Show-SPDashboard`) via `& $module { param(...) ... }`. This matches the documented PS 5.1 module-scope gotcha (`[[project_wpf_module_scope_gotcha]]`).
5. Calls `Update-AuditSummaryLabel`, `Initialize-AuditTab`, `Load-AuditReportList`, `Resolve-AuditOutputPath` directly to validate behaviour.
6. Uses `UIElement.EventHandlersStore` reflection to count handlers wired by `Initialize-AuditTab` (no Click/DoubleClick raising, which would otherwise spawn the background runspace).
7. For WG-03-08/09, probes mock first; if unreachable, marks BLOCKED rather than invoking `Invoke-SPCampaignAudit.ps1` against a dead endpoint.

## Test Results

| ID       | Result  | Notes |
|----------|---------|-------|
| WG-03-01 | PASS    | Row 0 has Summary + Configure + Query Campaigns; default text: "Status: (All) | Timespan: 30 days" |
| WG-03-02 | PASS    | AuditQueryDialog parses; TxtCampaignName + CboStatus + CboTimespan all present |
| WG-03-03 | PASS    | Dialog accepts COMPLETED + 365 days selections (365 days option added this round) |
| WG-03-04 | PASS    | Update-AuditSummaryLabel produced "Status: COMPLETED | Timespan: 365 days" from synthetic params |
| WG-03-05 | PASS    | AuditCampaignGrid has 6 columns in order: '', Campaign Name, Status, Created, Completed, Certs |
| WG-03-06 | PASS    | ChkCampaignReports=True, ChkIdentityEvents=True, ChkLeadershipRollup=False (matches spec defaults) |
| WG-03-07 | PASS    | BtnRunAudit present and disabled at startup (enabled after Invoke-AuditCampaignQuery populates results) |
| WG-03-08 | BLOCKED | Mock at http://10.0.0.143:8080 unreachable; skipping live audit run via Invoke-SPCampaignAudit.ps1 |
| WG-03-09 | BLOCKED | Mock unreachable; cannot generate Audit\leadership\ executive + per-leader HTMLs |
| WG-03-10 | PASS    | Load-AuditReportList populated ListBox with 2 items, both rendered with green `#FF339933` brush for HTML extension |
| WG-03-11 | PASS    | AuditReportList has 1 `MouseDoubleClick` handler attached after Initialize-AuditTab (verified via EventHandlersStore reflection) |
| WG-03-12 | PASS    | BtnOpenAuditFolder has 1 `Click` handler attached; Resolve-AuditOutputPath = C:\temp\Coding\SailPoint\SailPoint-GovernanceToolkit\Audit |

**Totals: 10 PASS / 0 FAIL / 2 BLOCKED (mock down) / 12 total. Exit 0.**

## Harness Command

```powershell
& powershell.exe -STA -NoProfile -ExecutionPolicy Bypass `
    -File .\Tests\Harness\Test-W03-AuditTabStructure.ps1
```

Emits one JSON line per test, terminated by a `{summary}` line. Exit 0 when no FAILs (BLOCKED does not fail).

## Bugs Found + Fixes

1. **WG-03-03 originally would have failed**: backlog asks for `Timespan = 365 days`, but `Gui\AuditQueryDialog.xaml` only listed `7 / 14 / 30 / 60 / 90 days`. Added `180 days` and `365 days` ComboBoxItems so the dialog supports the audit horizon required for annual COMPLETED campaign reviews. `Invoke-AuditCampaignQuery` already parses `"(\d+)"` from the selected text and forwards as `DaysBack`, so no module-side change was needed.

2. **Headless module init**: `Initialize-AuditTab`, `Resolve-AuditOutputPath`, and `Load-AuditReportList` depend on `$script:ToolkitRoot`/`$script:ConfigPath`/`$script:ThisModule` which are only set by `Show-SPDashboard`. Not a product bug, but the harness now mirrors that setup via `& $module { ... }` so future Audit-tab structural tests can call any module function safely.

## What Is Blocked vs Verified

- **Verified structurally + functionally**: tab layout, dialog structure + selectable filters, summary label formatter, datagrid schema, checkbox defaults, button enable state, listbox population + color coding, handler wiring (DoubleClick on report list, Click on Open Folder), audit output path resolution.
- **Blocked on mock**: actual `Invoke-AuditCampaignQuery` (would call `Get-SPGuiAuditCampaigns` -> `Get-SPCampaigns` -> `http://10.0.0.143:8080/v3/campaigns`) and end-to-end audit run producing `Audit\*.html` + `Audit\leadership\*.html`. These should be re-attempted as soon as the Pode mock on the macOS host is back up; the rest of the W-03 plan is exercised.

## Cleanup

- `Config\settings.json` restored from `Config\settings-real.json`.
- `Config\settings-real.json` removed.
- Temporary `Tests\Harness\W03-output.txt` deleted; no synthetic `Audit\w03-synthetic-*.html` left behind (harness removes its own seed files).
- `Audit\` and `DeltaCert\deltacert-audit.jsonl` untouched.

## Files Added/Changed This Round

- `Tests\Harness\Test-W03-AuditTabStructure.ps1` (new) -- headless W-03 audit-tab structural harness.
- `Gui\AuditQueryDialog.xaml` -- added `180 days` + `365 days` timespan options.
- `docs\windows-gui-test-backlog.md` -- W-03 status -> DONE (with mock-blocked note).
- `docs\windows-test-rounds\round-04.md` (this file).

**Remaining phases:** W-04, W-05, W-06, W-07 -- exiting 0 so the loop continues.
**Status:** SUCCESS

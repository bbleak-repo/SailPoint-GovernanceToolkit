# Round 2
**Started:** 2026-05-31 14:16:47

GU-02 complete. Here's what was delivered:

**4 new bridge functions in `SP.GuiBridge.psm1`:**

| Function | Purpose |
|---|---|
| `Invoke-SPGuiHealthCheck` | Runs all 6 health checks; returns `Checks[]` (badge key/status/color) + `MetricCards[]` (Maturity/5, PolicyCompliance%, CoverageRate%) for WPF dispatcher binding |
| `Invoke-SPGuiGovernanceReport` | Full report orchestration: fetches campaigns → `Invoke-SPGuiAudit` → optional policy/data-quality/dashboard; writes timestamped `GovernanceReport-*` package dir |
| `Export-SPGuiDashboardData` | Standalone CSV export: fetches campaigns, builds full certification/item/decision data, delegates to `Export-SPGovernanceDashboardData` |
| `Get-SPGuiGovernanceReports` | Scans `GovernanceReport-*/` packages + legacy `Reports/GovernanceRun_*.html` for the report list |

`SP.Gui.psd1` updated (FunctionsToExport + v1.3.0 ReleaseNotes). AST syntax clean. Pushed to `feature/gui-integration`.


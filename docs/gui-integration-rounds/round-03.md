# Round 3
**Started:** 2026-05-31 14:26:13

**GU-03 done.** Pushed `ea60c1a` to `feature/gui-integration`.

**What was added to `SP.MainWindow.psm1`** (609 lines, `#region Governance Tab`):

| Function | Role |
|---|---|
| `Initialize-GovernanceTab` | Wires 5 buttons, double-click report opener, initial status, calls `Load-GovernanceReports` |
| `Invoke-GuiHealthCheck` | Async runspace -> `Invoke-SPGuiHealthCheck`; dispatcher updates 6 badge `BorderBrush`/grade text + 3 metric card values |
| `Invoke-GuiGovernanceReport` | Shows `GovernanceRunDialog.xaml` when it exists (GU-04), falls back to defaults if not yet present; async runspace + DispatcherTimer |
| `Invoke-GuiExportDashboardData` | Synchronous wrapper around `Export-SPGuiDashboardData` |
| `Load-GovernanceReports` | Populates `GovReportList` (green=HTML, gray=other), same ListBoxItem/Tag pattern as Audit tab |
| `Resolve-GovernanceOutputPath` | Reads `Audit.OutputPath` from config, falls back to `.\Audit` |

Also added `$script:IsGovernanceRunning = $false` to module state and wired `Initialize-GovernanceTab` into `Show-SPDashboard` after `Initialize-DeltaCertTab`.

**Next up: GU-04** (`GovernanceRunDialog.xaml`) -- new modal dialog file.


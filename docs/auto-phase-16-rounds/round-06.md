# Round 6
**Started:** 2026-05-30 23:36:05
**P16-06 done.** Committed and pushed.

**What was implemented:**
- `Save-SPGovernanceMetrics` in `SP.AuditOperations.psm1` -- extracts KPIs from analytics outputs (identity risk, source governance, campaign metrics, reviewer reputation, stale access, governance maturity, orchestrator history), builds a timestamped JSONL record, appends atomically (write to .tmp then rename), and applies retention by removing records older than configured RetentionDays
- `Get-SPGovernanceMetrics` in `SP.AuditOperations.psm1` -- reads governance-metrics.jsonl, filters to DaysBack window, returns records sorted by timestamp ascending
- `Get-SPGovernanceMetricsTrend` in `SP.AuditOperations.psm1` -- groups metrics by Daily/Weekly/Monthly granularity, computes min/max/avg/latest per period, calculates period-over-period change and overall direction (Improving/Declining/Stable with 2% threshold)
- `Config/settings.json` -- added Metrics section with Path, RetentionDays, AutoCapture defaults
- `SP.Audit.psd1` updated with all three new exports

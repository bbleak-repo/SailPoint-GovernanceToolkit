# Round 12
**Started:** 2026-06-05 18:00:00
**Item:** AR-12 — CLI `Invoke-SPAdaptiveReport.ps1` (generation + date period)

**Read:** `Invoke-SPWeeklyDigest.ps1` (module-load + `Get-SPConfig -ConfigPath` +
`Initialize-SPLogging` + `Set-SPBrowserToken` bootstrap); `Invoke-SPGovernanceMetrics.ps1`
(campaign-audit build loop); the leadership-distribution API map (for AR-21 design).

**Did:** New additive `Scripts/Invoke-SPAdaptiveReport.ps1`. `[CmdletBinding()]`
(read-only -> **no** SupportsShouldProcess, CLI-005); standard
-ConfigPath/-Token/-TokenExpiryMinutes/-Help; `-OutputMode` ValidateSet
Console/JSON/HTML/Both. Report selection: `-Anchor` Entitlement|Campaign,
`-Components` (RC keys), `-BaselineReport` (friendly keys -> the 7 Export-*Report
fns, or 'all'), `-Theme`. **Date period:** `-Status` + `-DaysBack` (and
`-CreatedAfter`/`-CreatedBefore`, passed through to `Get-SPAuditCampaigns`). Pulls
campaigns for the window, rebuilds audits, `Build-SPRCDataset`, renders the
composable report + selected baseline reports to {Audit}\adaptive. Exit codes
0/1/2/3/4. Nothing existing touched.

**Files:** `Scripts/Invoke-SPAdaptiveReport.ps1` (new).

**Verification (live mock):**
  - AST parse OK.
  - Run (entitlement; kpi/heatmap/top-n/group-table + inventory/privileged/exec):
    3 campaigns -> 7 groups -> **4 reports** (composable 11.1 KB + inventory 5.4 KB
    + privileged 7.3 KB + exec 8.9 KB), Both summary (console + JSON), exit 0.
  - CLI convention tests: AR-13.

**Review:** PASS (self — additive read-only CLI; real-data run; date-window works).
**Backlog update:** AR-12 → DONE. (Leadership distribution = AR-21.)

**Completed:** 2026-06-05 18:12:00
**Status:** SUCCESS

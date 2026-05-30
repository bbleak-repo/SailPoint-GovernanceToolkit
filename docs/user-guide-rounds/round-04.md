# Round 4
**Started:** 2026-05-30 11:36:09

**UG-04 DONE.** Committed `c48b848` and pushed to `feature/user-guide`.

Created `docs/user-guide-sections/01-getting-started.html` (741 lines) with 9 sub-sections:

1. **What This Toolkit Does** -- summary with stat cards (14 scripts, 6 module layers, 5 GUI tabs, 3 auth modes)
2. **Prerequisites** -- PS 5.1, Windows, .NET 4.5+, ISC credentials, Pester (optional)
3. **PAT Scopes** -- all 6 read-only scopes in a param-table with callout about Delta Cert's `sp:scopes:all` requirement
4. **Installation** -- extract, navigate, verify; directory overview table
5. **Configuration** -- minimum 4-value config, then collapsible `<details>` sections for Global, Authentication, API, Safety, and Audit settings
6. **First Run** -- `Test-SPConnectivity.ps1` with expected 3-step PASS output
7. **Your First Audit** -- `Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 7` with output structure
8. **GUI Overview** -- 5 content-cards with numbered badges for each tab
9. **Safety Defaults** -- MaxCampaignsPerRun, RequireWhatIfOnProd, AllowCompleteCampaign + auth modes table
10. **Troubleshooting** -- 8-row common issues table + getting help commands

All CLI examples use correct parameter names from the actual scripts. Uses theme CSS classes: `stat-grid`, `stat-card`, `content-card`, `param-table`, `callout-info`, `callout-warning`, `callout-success`, `callout-danger`, `badge-*`, and `<details>/<summary>` collapsibles.

**Completed:** 2026-05-30 11:40:02
**Status:** SUCCESS

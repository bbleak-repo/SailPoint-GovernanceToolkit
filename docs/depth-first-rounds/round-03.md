# Round 3
**Started:** 2026-05-31 11:39:25

**DF-03 complete.** `Scripts/Invoke-SPGovernanceReport.ps1` (651 lines) -- the "run everything" governance report CLI.

**What it does:**
- **Step 1** -- Campaign Audit: fetches campaigns by filter, collects certifications/items/events, runs all analytics (decisions, reviewer metrics, rubber-stamp risk, remediation proof), generates per-campaign + combined HTML/text/JSONL
- **Step 2** -- Policy Compliance (optional): runs `Test-SPGovernancePolicy` and renders `Export-SPPolicyComplianceHtml`
- **Step 3** -- Data Quality (optional): runs aggregation health, orphan accounts, identity quality with individual HTML reports
- **Step 4** -- Dashboard Data Export: produces CSV+JSON flat files via `Export-SPGovernanceDashboardData`
- **Step 5** -- Leadership Rollup (optional): builds org tree, generates executive summary + per-level reports
- Writes a `manifest.json` with all step results, file counts, and metadata
- Packages everything into a timestamped `GovernanceReport-yyyyMMdd-HHmmss/` directory

**Patterns followed:** same module loading, config resolution, token injection, WhatIf, step tracking, OutputMode switch, exit codes, and JSONL audit trail as all existing CLI scripts.

**Completed:** 2026-05-31 11:48:22
**Status:** SUCCESS

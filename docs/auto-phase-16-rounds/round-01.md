# Round 1
**Started:** 2026-05-30 23:13:47
Warning: no stdin data received in 3s, proceeding without it. If piping from a slow command, redirect stdin explicitly: < /dev/null to skip, or wait longer.
**P16-01 Orphan Account Detector -- DONE.**

- `Get-SPOrphanAccounts` in SP.AuditQueries.psm1 -- paginated account scan across sources, classifies orphans as Uncorrelated (null identityId), TerminatedOwner (identity TERMINATED/INACTIVE), or DanglingReference (identity 404). Batched identity lookups, service account/disabled filtering, per-source orphan rate summaries.
- `Export-SPOrphanAccountHtml` in SP.AuditReportHtml.psm1 -- summary cards, per-source orphan rate table, detail table sorted by type, per-source grouped sections with badges, recommendations section.
- Exported in SP.Audit.psd1.
- All 3 files pass syntax checks. Committed and pushed.

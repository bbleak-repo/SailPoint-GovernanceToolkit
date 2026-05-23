# Round 3
**Started:** 2026-05-23 18:59:59

**P11-03 complete.** `Export-SPAuditCsv` added to `SP.AuditReport.psm1` with four CSV sheet types:

- **Decisions** -- one row per access review decision with all compliance fields, risk flags as semicolons
- **Reviewers** -- one row per reviewer per campaign with response metrics and rubber-stamp risk
- **Campaigns** -- one row per campaign with item counts, completion %, response time stats
- **Remediation** -- one row per revoked item with days-to-remediate calculation

Selective export via `-Sheets 'Decisions'` is supported. Empty datasets produce header-only CSVs. Committed as `ee26acc` and pushed.

**Completed:** 2026-05-23 19:02:58

# Round 7
**Started:** 2026-05-23 19:11:54

**P11-07 complete.** Committed `e4d64b7` and pushed.

**What was implemented:**

- **`Get-SPEntitlementInventory`** in `SP.AuditQueries.psm1` -- Queries ISC `/v3/entitlements` with pagination, groups by source, tracks privileged status, and optionally cross-references against recent campaign access review items to identify unreviewed entitlements.

- **`Export-SPEntitlementInventoryHtml`** in `SP.AuditReport.psm1` -- Generates a Word-compatible HTML report with summary card (totals + coverage %), per-source entitlement tables, privileged items highlighted red, unreviewed highlighted orange.

- **`SP.Audit.psd1`** updated to export both new functions.

**Completed:** 2026-05-23 19:15:44

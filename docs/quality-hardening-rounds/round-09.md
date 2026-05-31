# Round 9
**Started:** 2026-05-30 19:35:36

**QH-10: DONE** -- Consolidated duplicate SMTP config.

**What changed:**
- **`SP.AuditReport.psm1`** -- `Send-SPReport` now loads both `Audit.Smtp` and `Notification.Smtp`. When `Audit.Smtp` Server/From are empty, it inherits connection settings from `Notification.Smtp` and logs the fallback. `Audit.Smtp.Enabled` and `SubjectPrefix` remain exclusive to report delivery.
- **`Config/settings.json`** -- Added `_note` fields to both SMTP sections documenting the primary/fallback relationship.
- **`Invoke-SPReportDistribution.ps1`** -- Updated help text to document the fallback behavior.
- **Backlog** -- QH-10 marked DONE with resolution notes.

**Next PENDING:** QH-11 (MEDIUM) -- Fix SHA1 to SHA256 in logging mutex.

**Completed:** 2026-05-30 19:40:13
**Status:** SUCCESS

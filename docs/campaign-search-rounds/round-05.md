# Round 5
**Started:** 2026-05-23 17:28:35

**S-05 complete.** Implemented `Get-SPIdentityDecisionHistory` in `SP.AuditQueries.psm1`:

- Walks campaigns -> certifications -> access-review-items, filtering by `identitySummary.id`
- Returns decisions grouped by campaign, sorted newest-first
- Extracts access name, decision, reviewer name, and decision date per item
- All DateTime comparisons use `.ToUniversalTime()`
- Exported in both `Export-ModuleMember` and `SP.Audit.psd1`
- Syntax check passed, committed and pushed to `feature/campaign-search`

**Completed:** 2026-05-23 17:30:36
**Status:** SUCCESS

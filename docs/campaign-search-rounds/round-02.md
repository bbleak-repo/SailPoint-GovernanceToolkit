# Round 2
**Started:** 2026-05-23 17:21:05

**S-02 complete.** Added `-CreatedAfter` and `-CreatedBefore` `[DateTime]` parameters to `Get-SPAuditCampaigns`:

- Explicit date range takes precedence over `-DaysBack` (backwards compatible -- omitting both uses `DaysBack=30` as before)
- All DateTime comparisons use `.ToUniversalTime()` to prevent PS7 Kind=Utc vs Kind=Local mismatch
- Supports one-sided ranges (e.g., `-CreatedAfter '2026-01-01'` with no upper bound)
- No manifest changes needed (function was already exported)

**Completed:** 2026-05-23 17:23:06
**Status:** SUCCESS

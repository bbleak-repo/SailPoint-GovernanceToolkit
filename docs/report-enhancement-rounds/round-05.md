# Round 5
**Started:** 2026-05-23 12:53:38

Warning: no stdin data received in 3s, proceeding without it. If piping from a slow command, redirect stdin explicitly: < /dev/null to skip, or wait longer.
---

**R-05: Delta Report Mock Data -- COMPLETE**

**Feature:** R-05 Delta Report Mock Data
**Commit:** `0e7d792`

**Files modified:**
- `/Users/xand/Documents/Projects/API-MockServer/Profiles/SailPoint-ISC/seed-data.json` -- enriched with multi-day account activities and delta cert campaign data
- `docs/report-enhancements-backlog.md` -- status updated to DONE

**Changes made to seed-data.json:**
- Kept 5 GRANT_ACCESS activities at `__NOW_MINUS_HOURS_2__` (within 24h window)
- Changed 3 GRANT_ACCESS activities (006-008) to `__NOW_MINUS_HOURS_26__` (outside 24h, inside 48h)
- Removed 2 excess GRANT_ACCESS activities (old 009-010) and renumbered
- Added 2 REVOKE_ACCESS activities (009-010) at `__NOW_MINUS_HOURS_4__` with REMOVE operations
- Added 1 active delta cert campaign (`camp-delta-001`: "AD Delta Cert 2026-05-23")
- Added 3 pending certifications (`cert-delta-001` to `cert-delta-003`) with unsigned state

**Acceptance criteria verified:**
- `HoursBack 24`: 5 grants + 2 revocations
- `HoursBack 48`: 8 grants + 2 revocations
- Yesterday's activities excluded from 24h window

**Issues:** None. Seed-data.json is in a separate repo (API-MockServer), so it was committed there separately (`b92970d`).

**Completed:** 2026-05-23 12:58:51
**Status:** SUCCESS - more features remain

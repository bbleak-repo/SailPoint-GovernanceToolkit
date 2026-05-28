# Round 9
**Started:** 2026-05-28 15:32:13

**D-09 complete.** Committed `d8ff708` and pushed to `feature/disconnected-apps`.

**What was done:**
- Added `DisconnectedApps` config section to `Config/settings.json` with all 10 keys (paths, retention, campaign defaults, correlation, threshold, required columns)
- Added matching defaults in `Get-SPConfigDefaults` and `Get-SPConfigTemplate` in `SP.Config.psm1`
- Added section to `Tests/TestData/valid-settings.json`
- Created 4 mock test data files:
  - `disconnected-day1-accounts.csv` -- 5 accounts, 8 entitlement assignments
  - `disconnected-day2-accounts.csv` -- 5 accounts: +EMP10006 (added), -EMP10002 (removed), EMP10003 gains APP-REPORTS
  - `disconnected-entitlements.csv` -- 4 entitlements
  - `disconnected-invalid-accounts.csv` -- missing `e-mail` column, duplicate IDs, bad IIQDisabled value

**Verified:** Config loads with zero warnings, day1->day2 delta produces exactly 1 added/1 removed/1 granted, invalid file triggers all expected validation errors.

**Next PENDING:** D-10 (Pester Tests).

**Completed:** 2026-05-28 15:35:40
**Status:** SUCCESS

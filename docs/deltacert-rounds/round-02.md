# Round 2
**Started:** 2026-05-22 00:22:00

---

**F-03: Campaign Cleanup (Auto-Complete Stale Campaigns) -- COMPLETE**

**Feature:** F-03 -- `Invoke-SPDeltaCertCleanup` function

**Files modified:**
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1` -- new `Invoke-SPDeltaCertCleanup` function (~170 lines)
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` -- exported new function
- `Modules/SP.Core/SP.Config.psm1` -- added `CleanupDaysStale = 3` to DeltaCert defaults
- `Config/settings.json` -- added `DeltaCert.CleanupDaysStale: 3`
- `Scripts/Invoke-SPADDeltaCert.ps1` -- added `-RunCleanup` switch with cleanup dispatch before main run
- `Tests/SP.DeltaCert.Tests.ps1` -- added DC-019, DC-020, DC-021

**Tests added:**
- DC-019: Stale campaigns are completed (deadline passed + created old)
- DC-020: `AllowCompleteCampaign=false` blocks cleanup with clear error, no API calls made
- DC-021: Non-stale campaigns (future deadline, recent created) are not completed

**Issues:** None encountered.

**Commit:** `47d0db4` (pushed to origin/master)

**Completed:** 2026-05-22 00:27:31
**Status:** SUCCESS - more features remain

# Round 6
**Started:** 2026-05-29 23:23:03

**DA-26 complete.** Here's what was implemented:

**`Invoke-SPDisconnectedAppCleanup`** (new function in SP.DisconnectedAppRunner.psm1):
- Iterates all registered apps (or filtered by `-AppNames`)
- For each app, searches ACTIVE campaigns matching the app's `CampaignNamePrefix`
- Evaluates staleness via deadline (past due) or creation date (> `DaysStale` days old, default 3)
- Completes stale campaigns via `Complete-SPCampaign`
- Guarded by `Safety.AllowCompleteCampaign` -- blocks with clear message if false
- Supports `-WhatIf` for dry runs
- Returns per-app breakdown: completed, still-active, errors

**Batch orchestrator integration** (Invoke-SPDisconnectedAppBatch.ps1):
- Added as **Step 0** (pre-step) before the per-app processing loop
- Non-blocking: cleanup failures don't stop the batch
- Respects `-AppNames` filter and `-WhatIf` from the parent script

**Completed:** 2026-05-29 23:25:33
**Status:** SUCCESS

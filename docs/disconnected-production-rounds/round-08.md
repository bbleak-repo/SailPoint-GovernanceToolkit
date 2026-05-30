# Round 8
**Started:** 2026-05-29 23:31:02

**DA-28: Disconnected App Escalation -- DONE** (`ccb2677`)

Summary of changes:

1. **`SP.DisconnectedAppRunner.psm1`** -- New function `Invoke-SPDisconnectedAppEscalation`:
   - Iterates all registered apps, finds ACTIVE campaigns by each app's `CampaignNamePrefix`
   - Delegates stale cert detection to `Get-SPDeltaCertStaleCertifications` (reuses SP.DeltaCert)
   - Delegates reassignment to `Invoke-SPDeltaCertEscalate` (sync/async based on item count)
   - Per-app `EscalationStaleHours` and `MaxEscalationLevels` configurable (falls back to defaults: 24h, 2 levels)
   - Writes per-app JSONL audit events to `{ReportPath}/{AppName}/disconnected-app-escalation.jsonl`
   - Supports `-WhatIf` for dry runs
   - Added `EscalationTriggered` to `Send-SPDisconnectedAppAlert` ValidateSet
   - Added to `Export-ModuleMember`, module version bumped to 1.8.0

2. **`Invoke-SPDisconnectedAppBatch.ps1`** -- Wired as non-blocking post-step after alerts, before exit code. Respects `-AppNames` filter and `-WhatIf`.

**Completed:** 2026-05-29 23:37:06
**Status:** SUCCESS

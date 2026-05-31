# Round 17
**Started:** 2026-05-30 20:01:07

**QH-18 complete.** Committed `c013ab7` and pushed to `feature/quality-hardening`.

**Summary of changes (SP.Testing v1.0.0 -> v2.0.0):**

| File | Changes |
|---|---|
| `SP.Assertions.psm1` | +6 assertions: `Assert-SPDeltaGrantEventCount`, `Assert-SPDeltaManagerGrouping`, `Assert-SPDisconnectedAppFileValid`, `Assert-SPDisconnectedAppDeltaDetected`, `Assert-SPDeletionThresholdSafe`, `Assert-SPAggregationComplete` |
| `SP.BatchRunner.psm1` | +2 workflows: `Invoke-SPDeltaCertTest` (5-step: query/filter/group/create/assert) and `Invoke-SPDisconnectedAppTest` (7-step: validate/snapshot/delta/threshold/resolve/certify/push) |
| `SP.TestLoader.psm1` | +2 loaders: `Import-SPDeltaCertTestCases`, `Import-SPDisconnectedAppTestCases` |
| `SP.Testing.psd1` | FunctionsToExport 12 -> 22, version 2.0.0 |

**Remaining backlog:** QH-19 (PENDING, split AuditReport monolith), QH-20 (PENDING, split DisconnectedAppRunner monolith).

**Completed:** 2026-05-30 20:09:19
**Status:** SUCCESS

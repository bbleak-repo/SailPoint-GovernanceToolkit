# Round 8
**Started:** 2026-05-28 15:27:41

**D-08 DONE.** Created `Scripts/Invoke-SPDisconnectedAppCert.ps1` -- the entry-point CLI that orchestrates the full disconnected app workflow:

1. **Validate** account CSV (+ optional entitlement cross-reference)
2. **Snapshot** today's file with date stamp
3. **Delta detect** against previous snapshot
4. **Resolve** changed accounts to ISC identities via email/username
5. **Create** SEARCH campaigns per manager group (adds + grants + enables only)
6. **Generate** HTML delta summary report
7. **Audit** via JSONL trail

Key features:
- Follows the exact `Invoke-SPADDeltaCert.ps1` pattern (module chain loading, config defaults, token injection, WhatIf, OutputMode, exit codes)
- Config-driven defaults from `DisconnectedApps` section in settings.json
- Exit codes: 0=success, 1=no changes, 2=param error, 3=auth, 4=config, 5=validation, 6=campaign error
- Generates delta report even on no-change runs (audit evidence)

Next pending: **D-09** (Config Section + Mock Test Data).

**Completed:** 2026-05-28 15:32:10
**Status:** SUCCESS

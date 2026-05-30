# Round 7
**Started:** 2026-05-29 23:25:36

**DA-27 complete.** Two functions added to `SP.DisconnectedAppRunner.psm1`:

- **`Get-SPDisconnectedAppTrend`** -- Reads JSONL audit trails across all apps, aggregates `DisconnectedAppCertRun`, `DecisionHarvest`, and `RemediationStatusUpdate` events into per-app per-quarter metrics (cert runs, identities processed, campaigns created/completed, approval/revocation counts, remediation closure). Calculates derived rates (completion %, revocation %, remediation closure %).

- **`Export-SPDisconnectedAppCompliancePackage`** -- Bundles all evidence for a date range into a ZIP: per-app HTML reports, JSONL audit trails, remediation trackers, daily CSV snapshots, a trend summary JSON, a SHA256 manifest, and a cover page with scope/methodology. Ready for auditor handoff.

Committed as `39df876`, pushed to `feature/disconnected-production`.

**Completed:** 2026-05-29 23:30:59
**Status:** SUCCESS

# SailPoint ISC Governance Toolkit -- Production Runbook

> **Source of truth.** This runbook covers daily, weekly, and monthly operational
> procedures for teams running the toolkit in production. Read
> [Foundations](00-foundations.md) and the [CLI Playbook](cli-playbook.md) first.

**Audience:** operations engineers, SailPoint administrators, on-call staff.

---

## Morning Checklist

Run through this checklist every business morning (or on the first check after the
scheduled orchestrator run).

1. **Orchestrator log** -- Open `Logs\GovernanceToolkit-YYYY-MM-DD.log` (today's date).
   Search for `"Action":"DailyOrchestrator"` entries. Confirm the overall `ExitCode` is
   `0` (success) or `1` (success with warnings). Exit code 5 requires immediate investigation.
2. **Delta cert campaigns** -- Verify new delta-cert campaigns were created (or that exit
   code 1 means "no grants found" -- expected on quiet days). Check the delta report HTML
   in `DeltaCert\reports\` for anomalies.
3. **Disconnected app delivery** -- Confirm CSV files arrived for all registered apps.
   Check the orchestrator log for `StepName=DisconnectedApps` status. `NoChanges` is
   normal; `ThresholdBlocked` or `Error` requires investigation.
4. **Escalation activity** -- Check if any stale certifications were escalated. Look for
   `Action=Escalate` in the log. Repeated escalations for the same reviewer indicate
   the reviewer is unresponsive -- follow up manually.
5. **Error notifications** -- Check the configured notification channel (email inbox,
   Slack/Teams webhook) for any ERROR-severity alerts. The toolkit sends notifications
   for health check grade D/F, data quality issues, and orchestrator failures.

---

## Alert Response Matrix

| Notification Type | Severity | Immediate Action |
|---|---|---|
| Orchestrator ExitCode 5 | Critical | Check log for failed step. Re-run with `-Skip*` for succeeded steps. |
| Health check grade D or F | Critical | Run `Invoke-SPGovernanceHealthCheck.ps1 -OutputMode HTML` and review each failed dimension. |
| Data quality grade D or F | High | Run `Invoke-SPDataQualityReport.ps1 -OutputMode HTML`. Common causes: source aggregation stale, orphan account spike. |
| AccountDeletionThresholdPct exceeded | High | Verify the CSV is a full export. If legitimate, increase threshold temporarily. |
| Token acquisition failed (401) | Critical | PAT may be expired or revoked. Follow the Credential Rotation Procedure (Foundations section 5.3.2). |
| Rate limit (429) persistent | Medium | Check for concurrent toolkit runs. Reduce `RateLimitRequestsPerWindow` or stagger scheduled tasks. |
| Disconnected app batch all-failed | Critical | Check each app's CSV delivery status. Run `Invoke-SPDisconnectedAppRegistry.ps1 -Action Test -AppName <name>` per app. |
| Escalation max levels reached | Medium | A reviewer has been unresponsive through all escalation levels. Manual outreach required. |
| Retention archival failed | Low | Check disk space and write permissions on the `ArchivePath` directory. |
| Remediation SLA exceeded | High | App team has not processed revocations within `SlaDays`. Contact the app owner. |

---

## Where to Look

| What You Need | Where to Find It |
|---|---|
| Daily run log | `Logs\GovernanceToolkit-YYYY-MM-DD.log` (JSONL, one entry per line) |
| Orchestrator summary | Last entry in the daily log with `Action=DailyOrchestrator` and `Status=Complete` |
| Campaign audit reports | `Audit\` (HTML, text, JSONL per campaign) |
| Leadership rollups | `Audit\leadership\` (per-leader HTML) |
| Adaptive reports | `Audit\adaptive\` (composable HTML dashboards) |
| Delta cert output | `DeltaCert\` (campaign evidence, history) |
| Delta change reports | `DeltaCert\reports\` (daily HTML + JSONL) |
| Disconnected app snapshots | `DisconnectedApps\Snapshots\<AppName>\` (date-stamped CSVs) |
| Disconnected app reports | `DisconnectedApps\Reports\<AppName>\` (delta HTML + JSONL) |
| Governance metrics (time-series) | `Audit\metrics\` (JSONL KPI history) |
| Governance health/report output | `Reports\` (composite report packages) |
| Encrypted vault | `Data\sp-vault.enc` |
| Task Scheduler history | Windows Event Viewer > Applications and Services Logs > Microsoft > Windows > TaskScheduler |
| JSONL audit trail | `Audit\audit-YYYYMMDD-HHmmss.jsonl` (machine-parseable evidence) |
| Archived output | `Archive\` (monthly zip files from retention) |

---

## Operational Troubleshooting

### Rate Limiting

The toolkit enforces client-side rate limiting (default: 95 requests per 10-second
window) to stay within ISC's server-side limits. If you see `429 Too Many Requests`:

- Check for **concurrent toolkit runs** (e.g. two scheduled tasks overlapping).
- Reduce `Api.RateLimitRequestsPerWindow` to 80 or lower.
- Increase `Api.RetryDelaySeconds` to give more backoff time.
- The toolkit auto-retries with exponential backoff; transient 429s resolve automatically.

### Token Expiry

- **PAT tokens** refresh automatically via the `client_credentials` OAuth flow. If the
  PAT itself is expired or revoked in ISC, the toolkit logs `401 Unauthorized`. Follow
  the Credential Rotation Procedure.
- **Browser tokens** expire in 10-12 minutes. Do not use them for scheduled tasks or
  the daily orchestrator.

### Network Errors

- `The underlying connection was closed` -- TLS mismatch. The toolkit enforces TLS 1.2
  automatically, but a proxy or firewall may block it. Verify outbound HTTPS to
  `<tenant>.api.identitynow.com` is open.
- `The operation has timed out` -- increase `Api.TimeoutSeconds` (default 60). Check
  network latency to the ISC data center.
- If running behind a corporate proxy, ensure the proxy allows HTTPS to
  `*.api.identitynow.com` and `*.identitynow.com`.

### Disk Space

The toolkit writes logs, reports, snapshots, and evidence continuously. Without
retention, output accumulates indefinitely.

- Enable retention: `Retention.Enabled = true` in `settings.json`.
- Default: archive after 30 days, delete archives after 90 days.
- Monitor disk usage on the toolkit directory, especially `Logs\`, `Audit\`, and
  `DisconnectedApps\Snapshots\`.

### CSV Delivery Failures

When a disconnected app's CSV file is missing, stale, or invalid:

- The batch step logs `ThresholdBlocked` or `Error` for that app.
- Check the file share path in `DisconnectedApps.Applications[].AccountFilePath`.
- Verify the app team's export job ran (check their side).
- Run `Invoke-SPDisconnectedAppRegistry.ps1 -Action Test -AppName <name>` to validate
  the file if it exists.

### Vault Passphrase Prompt

If a scheduled task hangs, it may be waiting for the vault passphrase prompt (which
requires interactive input). Switch the scheduled task to `ConfigFile` mode with
`settings.local.json` (see Foundations section 5.3.1).

---

## Weekly Operations

Perform these checks weekly (suggested: Monday morning).

1. **Weekly digest review** -- Run `Invoke-SPWeeklyDigest.ps1 -OutputMode HTML` (or
   check if the orchestrator already generated it). Review campaign activity trends,
   reviewer performance, and remediation tracking.
2. **SLA compliance check** -- Review disconnected-app SLA status. Any app with
   `Remediation SLA exceeded` needs follow-up with the app owner.
3. **Credential rotation reminder** -- ISC PATs have configurable expiry (typically
   90 days). Check the PAT's expiry date in the ISC admin console and plan rotation
   at least 1 week before expiry.
4. **Review open escalations** -- Check if any delta-cert escalations have hit the
   maximum level without resolution. These require manual reviewer outreach.
5. **Disk usage check** -- Verify the toolkit directory is not filling up. If retention
   is disabled, consider enabling it or running `Invoke-SPRetention.ps1` manually.

---

## Monthly Operations

1. **Compliance evidence packaging** -- Run `Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 30 -IncludeLeadershipRollup -IncludeDataQuality -IncludePolicyCheck`
   to generate the monthly evidence package. Archive the output for auditor access.
2. **Trend review** -- Run `Invoke-SPGovernanceMetrics.ps1 -TrendDaysBack 90 -TrendGranularity Monthly -IncludeCompletionForecast -OutputMode HTML`
   to review KPI trends. Look for declining completion rates or increasing review times.
3. **Config drift check** -- Compare the current `settings.json` against the last
   known-good version. Pay attention to: `Safety` settings (should not be loosened
   without documentation), `DeltaCert.SourceIds` (should match current AD sources),
   and `DisconnectedApps.Applications` (should match current app inventory).
4. **Source coverage review** -- Run `Invoke-SPCampaignSearch.ps1 -SourceCoverage -OutputMode HTML`
   to verify all sources have been covered by recent campaigns. Gaps may indicate
   new sources that need delta-cert configuration.
5. **Disconnected app inventory reconciliation** -- Run
   `Invoke-SPDisconnectedAppRegistry.ps1 -Action List` and compare against the current
   list of applications that should be certified. Onboard new apps, decommission retired ones.

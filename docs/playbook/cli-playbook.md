# SailPoint ISC Governance Toolkit — CLI Playbook

> **Source of truth.** Edit this Markdown, not the generated HTML. Read
> [Foundations](00-foundations.md) first — it covers setup, authentication, the
> `settings.json` reference, the Safety model, output modes, and the glossary that
> every script below relies on.

**Audience:** operators, automation engineers, and anyone running the toolkit
headlessly (scheduled tasks, pipelines, ad-hoc admin).

**Conventions used in every entry below**
- **Required** parameters are marked *(required)*; everything else has a default
  (usually from `settings.json`).
- Most scripts accept `-ConfigPath`, `-Token` / `-TokenExpiryMinutes`, and
  `-OutputMode`; these shared parameters are described once here and not repeated:
  - `-ConfigPath <file>` — use a specific settings file (default `..\Config\settings.json`).
  - `-Token <jwt>` — a browser bearer token from the ISC admin console (F12 → Network →
    copy the `Authorization` value). Bypasses OAuth; the `Bearer ` prefix is stripped
    automatically. `-TokenExpiryMinutes` (default 10) sets when it's treated as expired.
  - `-OutputMode` — `Console` (default), `JSON`, `Both`, and where noted `CSV`/`HTML`.
- `-Help` on any script prints its full comment-based help.
- **Scope note:** scripts that read **account activities** (`/v3/account-activities`)
  require `sp:scopes:all` or a browser token — noted per script.

## Contents
1. [Setup & diagnostics](#1-setup--diagnostics) — `New-SPVault`, `Test-SPConnectivity`, `Show-SPDashboard`
2. [Campaign testing & audit](#2-campaign-testing--audit) — `Invoke-GovernanceTest`, `Invoke-SPCampaignAudit`, `Invoke-SPCampaignSearch`
3. [Delta certification](#3-delta-certification) — `Invoke-SPADDeltaCert`, `Invoke-SPDeltaCertEscalate`, `Invoke-SPDeltaReport`
4. [Disconnected applications](#4-disconnected-applications) — `Invoke-SPDisconnectedAppCert`, `Invoke-SPDisconnectedAppBatch`, `Invoke-SPDisconnectedAppRegistry`
5. [Governance & reporting](#5-governance--reporting) — health check, metrics, report, data quality, distribution, weekly digest, **adaptive reports**
6. [SDK features](#6-sdk-features) — `Invoke-SPSdkCampaignTemplates`, `Invoke-SPSdkWorkItems`, `Invoke-SPSdkWorkflows`
7. [Operations & scheduling](#7-operations--scheduling) — `Invoke-SPDailyOrchestrator`, `Invoke-SPScheduledCampaign`, `Invoke-SPRetention`

---

## 1. Setup & diagnostics

### `New-SPVault.ps1`
**Purpose:** one-time interactive setup of the encrypted credential vault
(AES-256-CBC + PBKDF2, 600k iterations). Stores the ISC OAuth client credentials so
the secret is never on disk in plain text.
**When to use:** once, before running anything with `Authentication.Mode = Vault`.
Re-run only to re-key or rotate credentials (it will warn before overwriting).

| Parameter | Description |
|---|---|
| `-VaultPath <file>` | Override the vault path from `settings.json` (default `.\Data\sp-vault.enc`). |
| `-ClientId <id>` | OAuth client ID. Prompted interactively if omitted. |
| `-ClientSecret <secret>` | OAuth client secret. Prompted as a SecureString if omitted. |

```powershell
.\Scripts\New-SPVault.ps1                      # fully interactive
.\Scripts\New-SPVault.ps1 -ClientId 'abc123'   # pre-supply id, prompt for the rest
```
> Store the passphrase in a password manager — it is never logged or recoverable.
**Related GUI:** Settings tab (auth configuration).

### `Test-SPConnectivity.ps1`
**Purpose:** quick smoke test of the whole connectivity stack — (1) load+validate
config, (2) acquire an OAuth token, (3) make a minimal live call (`GET /v3/campaigns?limit=1`).
Each step reports success/failure + elapsed time.
**When to use:** before any real run, after changing credentials/tenant, or to debug
auth/TLS issues.

| Parameter | Description |
|---|---|
| `-ConfigPath <file>` | Settings file to test against (e.g. point at `settings-mock.json` or `settings.local.json`). |

```powershell
.\Scripts\Test-SPConnectivity.ps1
.\Scripts\Test-SPConnectivity.ps1 -ConfigPath .\Config\settings.local.json
```
**Related GUI:** Settings tab → "Test Connection".

### `Show-SPDashboard.ps1`
**Purpose:** launches the WPF dashboard (the entire GUI — see the GUI Playbook).
**When to use:** for interactive analysis/review instead of the CLI.

| Parameter | Description |
|---|---|
| `-ConfigPath <file>` | Settings file the GUI uses. |
| `-NoIsolation` | **Internal** — the launcher re-spawns itself in an STA child process; end users never pass this. |

```powershell
.\Scripts\Show-SPDashboard.ps1
.\Scripts\Show-SPDashboard.ps1 -ConfigPath .\Config\settings-mock.json
```
> WPF requires STA; the script relaunches itself in a clean STA child automatically.

---

## 2. Campaign testing & audit

### `Invoke-GovernanceTest.ps1`
**Purpose:** the primary test entry point — loads campaign test definitions from CSV,
executes certification campaigns against ISC, and writes structured evidence.
**When to use:** to validate governance flows (smoke/regression suites), in CI, or to
exercise the toolkit against the mock.

| Parameter | Description |
|---|---|
| `-Tags <names>` | Run only campaigns whose `Tags` column matches one of these (e.g. `smoke`, `regression`, `full`). |
| `-TestId <id>` | Run a single test by ID (e.g. `TC-001`). Mutually exclusive with `-Tags`. |
| `-StopOnFirstFailure` | Halt the suite at the first failure. |
| `-OutputMode` | `Console` / `JSON` / `Both`. |
| `-WhatIf` | Preview without executing (honor on production). |

```powershell
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke
.\Scripts\Invoke-GovernanceTest.ps1 -TestId TC-001 -OutputMode JSON
```
**Related GUI:** Campaigns tab.

### `Invoke-SPCampaignAudit.ps1`
**Purpose:** generates post-campaign **audit reports** — pulls completed/active
campaigns, all certifications + review items, decisions and reviewer actions, identity
lifecycle events for revoked identities, and writes per-campaign HTML/text + a combined
summary + a JSONL audit trail.
**When to use:** after campaigns complete, for compliance evidence and leadership rollups.
**Requires at least one campaign filter** (`-CampaignName`, `-CampaignNameStartsWith`,
`-CampaignNameContains`, or `-Status`).

| Parameter | Description |
|---|---|
| `-CampaignName <name>` | Exact (case-insensitive) campaign name. |
| `-CampaignNameStartsWith <prefix>` | Name begins with prefix. |
| `-CampaignNameContains <kw>` | Name contains keyword (ISC `co` filter; best for fuzzy search). |
| `-Status <list>` | `STAGED`/`ACTIVE`/`COMPLETING`/`COMPLETED`. Defaults to `Audit.DefaultStatuses`. |
| `-DaysBack <n>` | Only campaigns created in the last *n* days (default 30 / `Audit.DefaultDaysBack`). |
| `-IdentityEventDays <n>` | Days before campaign end to search lifecycle events for revoked identities (default 2). |
| `-CampaignReportCsvPath <file>` | Read decisions from a locally-exported report CSV instead of live API calls. |
| `-OutputPath <dir>` | Override `Audit.OutputPath` (default `.\Audit`). |
| `-IncludeLeadershipRollup` | Also build per-leader rollup reports by walking the org tree (identity → manager → director → VP). |
| `-LeadershipDepth <n>` / `-LeadershipStartLevel <n>` | Control rollup depth / starting band. |
| `-DetailLevel <level>` | Verbosity of the report content. |

```powershell
# Everything completed in the last 7 days
.\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 7
# One campaign by name, with leadership rollups
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignName 'Q2 Manager Review' -IncludeLeadershipRollup
# Fuzzy search + JSON output
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignNameContains 'manager' -OutputMode JSON
```
**Related GUI:** Audit tab.

### `Invoke-SPCampaignSearch.ps1`
**Purpose:** unified campaign **search + analysis** — find campaigns and run analytics
without producing a full audit. At least one filter/analysis parameter is required (no
filter → exit code 2).
**When to use:** to locate campaigns, triage deadlines, compare campaigns, check reviewer
workload, or find source coverage gaps.

| Parameter | Description |
|---|---|
| `-Keyword <kw>` | Substring search on campaign name (ISC `co` filter). |
| `-Type <type>` | `MANAGER` / `SOURCE_OWNER` / `SEARCH` / `ROLE_COMPOSITION` (server-side filter). |
| `-Status <list>` | Default `COMPLETED, ACTIVE`. |
| `-CreatedAfter` / `-CreatedBefore <date>` | Creation-date bounds (take precedence over `-DaysBack`). |
| `-DaysBack <n>` | Look-back window (default 90). |
| `-ShowDeadlines` | Add deadline urgency (Overdue/Critical/Warning/OnTrack) per campaign. |
| `-ShowMetrics` | Add per-campaign KPIs (approval/completion rate, reviewer count, response times). |
| `-ReviewerIdentityId <id>` | Find all campaigns/certs for a reviewer with workload counts. |
| `-IdentityId <id>` | Show all decisions made about one identity across campaigns. |
| `-SourceCoverage` | Which sources have/haven't been audited by campaigns. |
| `-CompareIds <ids>` | Two+ campaign IDs for side-by-side metric comparison (standalone mode). |
| `-OutputMode` | `Console`/`JSON`/`Both`/**`CSV`**/**`HTML`**. |
| `-OutputPath <dir>` | Destination for CSV/HTML artifacts. |

```powershell
.\Scripts\Invoke-SPCampaignSearch.ps1 -Keyword 'access' -ShowDeadlines -ShowMetrics
.\Scripts\Invoke-SPCampaignSearch.ps1 -SourceCoverage -OutputMode HTML
.\Scripts\Invoke-SPCampaignSearch.ps1 -CompareIds 'camp-001','camp-002' -OutputMode CSV
```
**Related GUI:** Audit tab (campaign query dialog).

---

## 3. Delta certification

> **Scope:** all three read `/v3/account-activities`, which requires `sp:scopes:all`
> or a browser `-Token`.

### Finding Your Source ID

The `-SourceId` parameter on all delta-cert scripts is the ISC internal identifier for
the source (AD domain, Entra connector, etc.) you want to monitor. To find it:

1. Log into the **ISC Admin Console**.
2. Navigate to **Admin > Connections > Sources**.
3. Click the source you want to monitor.
4. The **Source ID** is visible in the browser URL bar: `https://<tenant>.identitynow.com/ui/admin#admin:sources:edit:<SOURCE_ID>`.
5. Copy the ID (it looks like `2c91808a7f3e8b01017f3e9abc123456`).

**Which sources to monitor:** Start with your AD sources -- these are where the most
frequent group-membership changes happen. Add other sources (Entra, LDAP) as your
delta-cert program matures. Each source ID is an independent monitor, so you can
add them incrementally.

### Testing Your Delta Cert Pipeline

Before scheduling delta certs for production, validate the end-to-end pipeline:

1. **Start the mock server** (or use a sandbox tenant) and configure `settings-mock.json`
   with `SourceIds: ["src-ad-001"]`.
2. **Preview** what would be created:
   ```powershell
   .\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-ad-001' -ConfigPath .\Config\settings-mock.json -WhatIf
   ```
   Expected: a summary of GRANT_ACCESS events found and the campaigns that would be
   created, without actually creating them.
3. **Run for real** against the mock:
   ```powershell
   .\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-ad-001' -ConfigPath .\Config\settings-mock.json
   ```
   Expected: exit code 0, campaigns created in the mock, JSONL evidence written to `DeltaCert\`.
4. **Generate the delta report:**
   ```powershell
   .\Scripts\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -ConfigPath .\Config\settings-mock.json
   ```
   Expected: HTML report in `DeltaCert\reports\` showing grants, revocations, and pending certs.
5. **Run escalation** to verify the stale-reviewer logic:
   ```powershell
   .\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 0 -ConfigPath .\Config\settings-mock.json
   ```
   Expected: escalation log entries (stale hours = 0 forces everything to escalate for testing).

> **What Can Go Wrong (Delta Cert)**
>
> - **No GRANT_ACCESS events found (exit code 1).** The look-back window
>   (`-HoursBack`) may be too narrow, or the source has no recent grants. Widen the
>   window to 48-72 hours to catch up. Verify the source ID is correct.
> - **Identity has no manager.** Identities without a manager in ISC are skipped
>   unless `-FallbackReviewerIdentityId` is set. Check the JSONL output for
>   `"skipped: no manager"` entries and either fix the manager attribute in the
>   authoritative source or set a fallback.
> - **`sp:scopes:all` required error.** The account-activities endpoint has no
>   granular scope. Either add `sp:scopes:all` to your PAT or use a browser `-Token`.

### `Invoke-SPADDeltaCert.ps1`
**Purpose:** creates **daily AD delta-cert campaigns** — finds `GRANT_ACCESS` events on
the specified AD sources in the look-back window, resolves each affected active identity's
manager, and creates one targeted campaign per manager (scoped to just their reports who
got new access).
**When to use:** scheduled daily, to re-certify *newly granted* AD access without a full campaign.
Exits with code 1 (nothing to do) if no grants are found.

| Parameter | Description |
|---|---|
| `-SourceId <ids>` *(required)* | ISC source ID(s) to monitor (ISC Admin → Sources → ID in URL). |
| `-HoursBack <n>` | Look-back window (default 24; raise to 48+ to catch up a missed run). |
| `-DeadlineDays <n>` | Days managers have to review (default 2). |
| `-FallbackReviewerIdentityId <id>` | Reviewer for identities with no manager (else skipped + logged). |
| `-CampaignNamePrefix <s>` | Name prefix (default `DeltaCert.CampaignNamePrefix` / `AD Delta Cert`). Full: `"{Prefix} {YYYY-MM-DD} - {Manager}"`. |
| `-MaxCampaignsPerRun <n>` | Abort before creating anything if manager groups exceed this (default 50). |
| `-ReviewerMode <mode>` | `Manager` (one SEARCH campaign per manager) or `SourceOwner` (one SOURCE_OWNER campaign per source). Default `Manager`. |
| `-RunCleanup` | First complete past-due delta campaigns (needs `Safety.AllowCompleteCampaign = true`). |
| `-WhatIf` | Preview the campaigns that would be created. |

```powershell
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-ad-001' -Token $jwt
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-ad-001' -HoursBack 48 -RunCleanup -WhatIf
```
**Related GUI:** Delta Cert tab → Run.

### `Invoke-SPDeltaCertEscalate.ps1`
**Purpose:** escalates **stale** delta-cert certifications — finds active delta certs with
no reviewer action past a threshold and reassigns each up the org tree to the reviewer's
manager (ISC emails the new reviewer automatically). Escalations are logged to JSONL for evidence.
**When to use:** on a separate schedule from the main delta-cert job (e.g. every few hours)
to keep reviews moving.

| Parameter | Description |
|---|---|
| `-CampaignNamePrefix <s>` | Prefix used to find delta-cert campaigns (default `DeltaCert.Escalation.CampaignNamePrefix`). |
| `-StaleHours <n>` | Hours of inactivity before a cert is "stale" (default 24). |
| `-MaxEscalationLevels <n>` | Max hops up the org tree from the original reviewer (default 2). |

```powershell
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -Token $jwt
```
**Related GUI:** Delta Cert tab → Escalate.

### `Invoke-SPDeltaReport.ps1`
**Purpose:** a lightweight **daily change report** (1–2 page HTML + JSONL for SIEM) — grants,
revocations, recently-created delta campaigns, pending certs, and anomalies in the window.
Not a full audit — just "what changed today."
**When to use:** quick daily operations review / SIEM feed.

| Parameter | Description |
|---|---|
| `-SourceId <ids>` *(required)* | Source ID(s) to monitor. |
| `-HoursBack <n>` | Look-back window (default 24). |
| `-OutputPath <dir>` | Output dir for HTML+JSONL (default `DeltaCert\reports\`). |

```powershell
.\Scripts\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -Token $jwt
```
**Related GUI:** Delta Cert tab (history/reports).

---

## 4. Disconnected applications

> For apps with no native ISC connector. Teams deliver daily CSV exports; the toolkit
> snapshots, diffs, correlates to identities, and certifies the *changes*.
> **Scope:** identity resolution needs `sp:search:read`; campaign creation needs
> `idn:campaign:read` + `idn:campaign:manage` (or a browser `-Token`).

### `Invoke-SPDisconnectedAppRegistry.ps1`
**Purpose:** manage the `DisconnectedApps.Applications` registry in `settings.json`.
**When to use:** to onboard/offboard an app or validate its setup before batch runs.

| Parameter | Description |
|---|---|
| `-Action <op>` *(required)* | `Register`, `Unregister`, `List`, or `Test`. |
| `-AppName <name>` | App name (required for Register/Unregister/Test). |
| `-AccountFilePath <file>` | Account CSV (required for Register). |
| `-EntitlementFilePath <file>` | Entitlement CSV (optional). |
| `-ISCSourceId`, `-CorrelationAttribute`, `-CampaignNamePrefix`, `-DeadlineDays`, `-SlaDays` | Per-app overrides of the global defaults. |

```powershell
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action List
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Register -AppName 'PEP-Plus' -AccountFilePath .\imports\pep.csv
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Test -AppName 'PEP-Plus'
```
*Exit codes:* 0 success · 1 none found / warnings · 2 parameter · 4 config · 5 validation.

### `Invoke-SPDisconnectedAppCert.ps1`
**Purpose:** the full single-app pipeline — validate CSV → snapshot → diff vs. previous →
resolve changed accounts to identities → create one SEARCH campaign per manager (adds/grants
only) → HTML delta report + JSONL audit.
**When to use:** to certify one app's newly-changed access. Exits code 1 (not an error) if
nothing changed since the last snapshot.

| Parameter | Description |
|---|---|
| `-AppName <name>` *(required)* | App name (paths, campaign naming, titles). |
| `-AccountFilePath <file>` *(required)* | Today's account CSV. |
| `-EntitlementFilePath <file>` | Entitlement CSV; enables cross-reference validation. |
| `-CampaignNamePrefix <s>` | Default `DisconnectedApps.DefaultCampaignNamePrefix`. |
| `-DeadlineDays <n>` | Reviewer deadline (default 2). |
| `-FallbackReviewerIdentityId <id>` | Reviewer for manager-less identities (else skipped). |
| `-MaxCampaignsPerRun <n>` | Abort if manager groups exceed this (default 20). |
| `-SnapshotDir` / `-OutputPath <dir>` | Snapshot and report/JSONL locations. |

```powershell
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 -AppName 'PEP-Plus' -AccountFilePath .\imports\pep-2026-06-05.csv -Token $jwt
```
**Related GUI:** *(CLI-only pipeline)*.

### `Invoke-SPDisconnectedAppBatch.ps1`
**Purpose:** runs the per-app pipeline for **all (or named) registered apps** in sequence,
isolating errors so one bad app doesn't stop the batch. Each app → `Success`, `NoChanges`,
`ThresholdBlocked`, or `Error`.
**When to use:** the daily disconnected-app run (often via the orchestrator).

| Parameter | Description |
|---|---|
| `-AppNames <list>` | Only process these apps (default: all enabled). |
| `-Force` | Bypass the duplicate-campaign guard on every app. |

```powershell
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -Token $jwt
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -AppNames 'PEP-Plus','IPAY' -OutputMode Both
```
*Exit codes:* 0 all ok/no-changes · 1 partial · 2 all failed.

> **What Can Go Wrong (Disconnected Apps)**
>
> - **AccountDeletionThresholdPct exceeded.** The CSV has too many missing accounts
>   compared to the previous snapshot. This safety guard prevents accidental mass
>   removal. Verify the CSV is a **full export** (not a delta/changes-only file).
>   If the removal is legitimate (e.g. org restructure), temporarily increase
>   `DisconnectedApps.AccountDeletionThresholdPct`.
> - **Identity correlation failures.** The `e-mail` in the CSV does not match any
>   ISC identity. Common causes: wrong email format, the identity is in a non-active
>   lifecycle state (`ExcludeLifecycleStates`), or the `CorrelationAttribute` is
>   misconfigured. Run `Invoke-SPDisconnectedAppRegistry.ps1 -Action Test` to validate.
> - **Duplicate campaign guard.** If a campaign with the same name prefix already
>   exists for today, the pipeline skips creation (exit code 1). Use `-Force` to
>   bypass, or wait until the existing campaign is completed/cleaned up.

### Remediation Tracking

When disconnected-app campaigns complete, the toolkit tracks remediation status for
revoked access. This means: after a reviewer marks an entitlement as `REVOKE`, the
toolkit monitors whether the revocation was actually carried out in subsequent CSV
deliveries.

- **Remediation data collection:** the orchestrator step 9 (`Update-SPRemediationStatus`)
  compares the current CSV snapshot against the previous day's revocation decisions. If a
  revoked account or entitlement still appears in the next delivery, it is flagged as
  "pending remediation."
- **Investigating stuck remediations:** check the weekly digest's remediation tracking
  section, or query the JSONL audit trail for `Action=RemediationCheck` entries with
  `Status=Pending`. Common causes: the app team did not process the revocation, or the
  CSV was not refreshed after the change.
- **SLA enforcement:** each registered app has a `SlaDays` setting. Remediations
  exceeding the SLA are escalated in the daily summary and (if configured) via
  notification.

---

## 5. Governance & reporting

### `Invoke-SPGovernanceHealthCheck.ps1`
**Purpose:** one consolidated health report across six dimensions — source aggregation,
data quality, policy compliance, config drift, orphan accounts, campaign coverage gaps —
with a pass/fail/warn per check and an overall grade.
**When to use:** routine governance posture checks; before audits.

| Parameter | Description |
|---|---|
| `-SourceId <ids>` | Sources to assess (default: configured/all enabled). |
| `-MaxStalenessHours <n>` | Source-stale threshold (default 48). |
| `-IdentityLimit <n>` | Cap for data-quality scoring (default 500). |
| `-SnapshotPath <dir>` | Config snapshots for drift comparison. |
| `-DaysBack <n>` | Coverage-gap look-back (default 90). |
| `-Skip*` switches | Skip any individual check (`-SkipDataQuality`, `-SkipConfigDrift`, …). |
| `-OutputMode` | `Console`/`HTML`/`JSON`/`Both`. |

```powershell
.\Scripts\Invoke-SPGovernanceHealthCheck.ps1 -OutputMode HTML
```
**Related GUI:** Governance tab → Health Check.

### `Invoke-SPGovernanceMetrics.ps1`
**Purpose:** captures governance **KPIs to a JSONL time-series store**, generates trend
reports, and optionally forecasts active-campaign completion. Preserves long-term trends
even after raw audit data is archived.
**When to use:** scheduled (after the daily orchestrator) to build history.

| Parameter | Description |
|---|---|
| `-CaptureOnly` / `-TrendOnly` | Capture without reporting / report without recomputing. |
| `-IncludeCompletionForecast` | Add per-campaign completion forecasts. |
| `-TrendDaysBack <n>` | History window for trends (default 180). |
| `-TrendGranularity <p>` | `Daily`/`Weekly`/`Monthly` (default Weekly). |
| `-AlertOnDecline` / `-AlertRecipients <emails>` | Notify when KPIs decline >5% over 4 periods. |
| `-OutputMode` | `Console`/`HTML`/`JSON`/`Both`. |

```powershell
.\Scripts\Invoke-SPGovernanceMetrics.ps1 -IncludeCompletionForecast -OutputMode Both
```
**Related GUI:** Governance tab → Metrics.

### `Invoke-SPGovernanceReport.ps1`
**Purpose:** the "one report to rule them all" — assembles audit, leadership rollup, policy
compliance, and data quality into one output directory with a manifest. What an auditor/
governance lead runs for a complete posture snapshot.

| Parameter | Description |
|---|---|
| `-Status`, `-DaysBack`, `-CampaignName*` | Campaign selection (same semantics as audit). |
| `-IncludeLeadershipRollup` / `-LeadershipDepth <n>` | Add per-leader rollups (depth default 3). |
| `-IncludePolicyCheck` / `-IncludeDataQuality` | Add those dimensions. |
| `-IdentityLimit`, `-MaxStalenessHours` | Data-quality tuning. |
| `-SkipDashboardExport` | Skip the dashboard data export. |
| `-DetailLevel <l>` | `Summary`/`Detailed`/`Verbose` (default Verbose). |

```powershell
.\Scripts\Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 90 -IncludeLeadershipRollup -IncludeDataQuality
```
**Related GUI:** Governance tab → Report.

### `Invoke-SPDataQualityReport.ps1`
**Purpose:** focused **data-quality** assessment — orphan accounts + identity-attribute
quality + source-aggregation health → a composite weighted score and grade.
**When to use:** scheduled or on-demand data hygiene checks.

| Parameter | Description |
|---|---|
| `-SkipOrphanAccounts` / `-SkipIdentityQuality` / `-SkipAggregationHealth` | Drop a section. |
| `-IdentityLimit <n>` (500) / `-MaxStalenessHours <n>` (48) | Tuning. |
| `-SendNotification` / `-NotifyRecipients` | Notify when grade is D/F. |
| `-OutputMode` | `Console`/`HTML`/`JSON`/`Both`. |

```powershell
.\Scripts\Invoke-SPDataQualityReport.ps1 -OutputMode HTML
```
*Exit codes:* 0 grade A/B · 1 grade C · 5 grade D/F (critical) · 2/3/4 param/auth/config.
**Related GUI:** Governance tab → Data Quality.

### `Invoke-SPReportDistribution.ps1`
**Purpose:** generates **per-leader / per-band leadership reports** and (optionally) emails
each to the right leader via SMTP. Builds the org tree (optionally merging a supplement CSV),
resolves bands, groups decisions by level. Generate-only by default.
**When to use:** distributing campaign results up the management chain.

| Parameter | Description |
|---|---|
| `-Status <list>` *(required)* | Campaign statuses to include. |
| `-DaysBack <n>` | Look-back (default 30). |
| `-LeadershipDepth <n>` | Org-tree levels above reviewed identities (default 4). |
| `-TargetBands <letters>` | Limit to specific bands (e.g. `@('B','C')`). |
| `-SendReports` | Actually email each report (needs `Audit.Smtp.Enabled = true`). |
| `-PreviewOnly` | Show who-gets-what without generating or sending. |
| `-OrgSupplementPath <csv>` | Org-chart supplement overriding/filling ISC manager gaps. |
| `-DetailLevel <l>` | `Summary`/`Detailed`/`Verbose`. |

```powershell
.\Scripts\Invoke-SPReportDistribution.ps1 -Status COMPLETED -PreviewOnly
.\Scripts\Invoke-SPReportDistribution.ps1 -Status COMPLETED -SendReports -TargetBands B,C
```
**Related GUI:** Governance tab (report generation).

### Band Classification Guide

The leadership report system classifies identities into **bands** based on their
position in the org tree. Bands determine who receives which reports and at what level
of detail.

| Band | Role Level | Org-Tree Depth | Report Content |
|---|---|---|---|
| **A** | President / CEO | Depth 4+ above reviewed identity | Executive summary only |
| **B** | VP / SVP | Depth 3 above reviewed identity | Aggregated division rollup |
| **C** | Director | Depth 2 above reviewed identity | Department-level detail |
| **D** | Manager | Depth 1 above reviewed identity | Direct-report detail (individual decisions) |
| **E** | Individual Contributor | Depth 0 (the reviewed identity) | Not a report recipient |

The band mapping is configured in `Leadership.DefaultBandMapping` in `settings.json`.
The default maps org-tree depth to band letter (`0=E, 1=D, 2=C, 3=B, 4=A`). If your
organization uses a different hierarchy, adjust the mapping.

**Org supplement CSV:** When ISC's manager attribute has gaps (missing managers, incorrect
reporting chains), supply a supplement CSV via `-OrgSupplementPath`:

```csv
identityId,managerId,band
2c918..abc,2c918..def,C
2c918..ghi,,B
```

The supplement overrides ISC's org tree for the specified identities. Place it at
`Config\org-chart-supplement.csv` or pass the path explicitly.

**Leadership report workflow:** (1) run the audit first (`Invoke-SPCampaignAudit.ps1`),
then (2) distribute with `Invoke-SPReportDistribution.ps1 -PreviewOnly` to verify
who-gets-what, then (3) send with `-SendReports`.

### Compliance Evidence Guide

The toolkit's reports map to common compliance frameworks. Use this guide when
packaging evidence for auditors.

| Framework | Control Area | Toolkit Report | What It Proves |
|---|---|---|---|
| **SOX** | Access review (ITGC) | Campaign Audit, Leadership Rollup | Access was reviewed and decisions were made by authorized reviewers |
| **SOX** | Segregation of duties | Adaptive SoD Baseline | Toxic combinations identified and reviewed |
| **SOC 2** | CC6.1 -- Logical access | Campaign Audit, Data Quality | Access is periodically reviewed; orphan accounts identified |
| **SOC 2** | CC6.2 -- Prior to access | Delta Report | New access grants are certified promptly |
| **SOC 2** | CC6.3 -- Access removal | Remediation Tracking (Weekly Digest) | Revoked access is actually removed |
| **ISO 27001** | A.9.2.5 -- Review of access rights | Governance Report | Comprehensive governance posture snapshot |
| **ISO 27001** | A.9.2.6 -- Removal of access | Delta Report, Remediation Tracking | Timely revocation and follow-through |

**Packaging evidence for auditors:**
1. Run `Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 90 -IncludeLeadershipRollup -IncludeDataQuality` to generate the full evidence package.
2. Collect the output directory (`Reports\`) -- it includes a manifest listing all artifacts.
3. Include the JSONL audit trail (`Audit\*.jsonl`) for machine-verifiable provenance.
4. For SOX, add the leadership rollup reports to show reviewer accountability.

### `Invoke-SPWeeklyDigest.ps1`
**Purpose:** a consolidated **weekly digest** — campaign activity, campaign health, identity
risk, reviewer performance, remediation tracking, and orchestrator reliability in one report.
**When to use:** weekly distribution to governance leadership.

| Parameter | Description |
|---|---|
| `-DaysBack <n>` | Window (default 7). |
| `-Skip*` switches | Drop any section (`-SkipIdentityRisk`, `-SkipReviewerAnalysis`, …). |
| `-SendNotification` / `-NotifyRecipients` | Deliver via configured backends. |
| `-OutputMode` | `Console`/`HTML`/`JSON`/`Both`. |

```powershell
.\Scripts\Invoke-SPWeeklyDigest.ps1 -OutputMode HTML
```
**Related GUI:** Governance tab.

### `Invoke-SPAdaptiveReport.ps1`
**Purpose:** generate **adaptive, composable HTML reports** over your governance data —
a reusable component engine (KPI cards, heatmap, top-N bars, drill-down tree, group
table) plus a **baseline report library** (entitlement inventory, privileged review,
orphaned/disabled access, separation-of-duties, certification roster, access-cert
attestation, governance executive summary). **Additive** — it sits alongside the
existing reports; nothing is replaced.
**When to use:** richer, presentation-ready governance views; ad-hoc analysis of
entitlement assignment or campaign coverage; as the source for tiered leadership
distribution (see `Invoke-SPReportDistribution`).

**Anchor — what becomes a "group" and its "members":**
- `Entitlement` (default) — group = an entitlement / access profile / role; members =
  the identities holding it. Drives inventory, top-N most-assigned, privileged-
  entitlement review, disabled-still-has-access, and SoD toxic combinations.
- `Campaign` — group = a certification campaign; members = the identities under it.

Both anchors pivot the same campaign access-review data, so they need only the
campaign/certification endpoints (no extra scopes).

| Parameter | Description |
|---|---|
| `-Anchor <a>` | `Entitlement` (default) or `Campaign`. |
| `-Components <keys>` | Composable component list: `kpi-cards`, `heatmap`, `tree`, `top-n`, `group-table` (append `:half` for side-by-side). Default `kpi-cards,top-n,group-table`; pass `@()` to skip the composable report. |
| `-BaselineReport <names>` | One or more of `inventory`, `privileged`, `orphaned`, `exec-summary`, `roster`, `access-cert`, `sod`, or `all`. |
| `-Theme <t>` | `light` (default) or `dark`. |
| `-Status <list>` | Campaign status filter (default `COMPLETED, ACTIVE`). |
| `-DaysBack <n>` | Campaign window in days (default 90). |
| `-CreatedAfter` / `-CreatedBefore <date>` | Explicit creation-date bounds (take precedence over `-DaysBack`). |
| `-OutputPath <dir>` | Destination (default `Audit\adaptive`). |
| `-OutputMode` | `Console` (default) / `JSON` / `HTML` / `Both` — controls the run summary; the HTML report files are always written. |

```powershell
# Entitlement view: composable dashboard + three baseline reports, last 180 days
.\Scripts\Invoke-SPAdaptiveReport.ps1 -Anchor Entitlement -Components kpi-cards,heatmap,top-n,group-table -BaselineReport inventory,privileged,exec-summary -DaysBack 180
# Campaign view, dark theme, an explicit window
.\Scripts\Invoke-SPAdaptiveReport.ps1 -Anchor Campaign -BaselineReport all -Theme dark -CreatedAfter 2026-01-01 -CreatedBefore 2026-03-31
```
*Exit codes:* 0 ok · 1 no campaigns/data · 2 parameter · 3 auth · 4 config.
**Related GUI:** Adaptive Reports tab (see the GUI Playbook).

---

## 6. SDK features

> Thin CLI wrappers over the vendor SDK functions (module chain SP.Core → SP.Api → SP.Sdk).
> These are **read/inspect** CLIs; the full create/edit/schedule/act surface lives in the
> **SDK Features GUI tab**. Common exit codes: 0 ok · 1 no results · 2 param · 3 auth · 4 config.

### `Invoke-SPSdkCampaignTemplates.ps1`
**Purpose:** list/inspect campaign templates and their schedules.

| Parameter | Description |
|---|---|
| `-Action <op>` | `List` (default), `Get`, `Schedule`. |
| `-TemplateId <id>` | Required for `Get`/`Schedule`. |
| `-Filters <expr>` | ISC filter for `List` (e.g. `name co "quarterly"`). |
| `-Sorters <expr>` | Sort by `name`/`created`/`modified`. |

```powershell
.\Scripts\Invoke-SPSdkCampaignTemplates.ps1 -Action List -Filters 'name co "quarterly"'
.\Scripts\Invoke-SPSdkCampaignTemplates.ps1 -Action Schedule -TemplateId tmpl-001
```

### `Invoke-SPSdkWorkItems.ps1`
**Purpose:** list work items with a summary; open by default.

| Parameter | Description |
|---|---|
| `-OwnerId <id>` | Filter by owner identity (default: all visible). |
| `-ShowCompleted` | Show completed instead of open items. |

```powershell
.\Scripts\Invoke-SPSdkWorkItems.ps1
.\Scripts\Invoke-SPSdkWorkItems.ps1 -ShowCompleted -OutputMode JSON
```

### `Invoke-SPSdkWorkflows.ps1`
**Purpose:** list/inspect workflows and their execution history.

| Parameter | Description |
|---|---|
| `-Action <op>` | `List` (default), `Get`, `Executions`. |
| `-WorkflowId <id>` | Required for `Get`/`Executions`. |
| `-Filters <expr>` | `List`: `enabled`, `connectorInstanceId`, `triggerId`; `Executions`: `start_time`, `status`. |

```powershell
.\Scripts\Invoke-SPSdkWorkflows.ps1 -Action List -Filters 'enabled eq true'
.\Scripts\Invoke-SPSdkWorkflows.ps1 -Action Executions -WorkflowId wf-001
```
**Related GUI:** SDK Features tab (full read/write surface).

---

## 7. Operations & scheduling

### `Invoke-SPDailyOrchestrator.ps1`
**Purpose:** the **single daily run** — chains 11 steps (config validate → cleanup → delta
cert → delta report → escalation → health check → disconnected-app batch → decision collect →
remediation check → log retention → daily summary + JSONL). Each step is isolated; the exit
code reflects the worst outcome.
**When to use:** the primary scheduled task (Task Scheduler/cron), once daily.
**Scope:** steps 2–5 need `sp:scopes:all` or a browser `-Token`.

| Parameter | Description |
|---|---|
| `-SourceId <ids>` | Sources for the delta-cert steps. |
| `-Skip*` switches | Skip any step (`-SkipValidation`, `-SkipCleanup`, `-SkipDeltaCert`, `-SkipDeltaReport`, `-SkipEscalation`, `-SkipHealthCheck`, …). |

```powershell
.\Scripts\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -Token $jwt
```
**Related GUI:** *(operational — typically scheduled, not interactive)*.

### `Invoke-SPScheduledCampaign.ps1`
**Purpose:** runs campaigns from **saved JSON templates** on a cadence — loads templates from
`Config/campaign-templates/`, checks last-run state (`.schedule-state.json`), and creates
campaigns for those that are due.
**When to use:** scheduled, alongside the orchestrator, for recurring (e.g. quarterly) campaigns.

| Parameter | Description |
|---|---|
| `-TemplateName <name>` | Run one template (else all, filtered by cadence). |
| `-Cadence <c>` | Cadence filter (default `Quarterly`). |
| `-MinDaysSinceLastRun <n>` | Due threshold (default 80). |
| `-ExcludeExceptions` | Exclude identities with active governance exceptions. |
| `-WhatIf` | Show which templates are due without creating campaigns. |

```powershell
.\Scripts\Invoke-SPScheduledCampaign.ps1 -Cadence Quarterly -WhatIf
```
*Exit codes:* 0 ok/none due · 1 warnings · 2 parameter.

### `Invoke-SPRetention.ps1`
**Purpose:** archive + delete old toolkit output — zips files older than `ArchiveDays` into
monthly archives, then deletes archive zips older than `DeleteDays`. Only touches known
toolkit file types.
**When to use:** scheduled housekeeping (also runs as orchestrator step 10).

| Parameter | Description |
|---|---|
| `-ArchiveDays <n>` | Archive files older than this (min 7; overrides `Retention.ArchiveDays`). |
| `-DeleteDays <n>` | Delete archives older than this (min 30, > ArchiveDays). |
| `-ArchivePath <dir>` | Where archives go. |
| `-Paths <dirs>` | Directories to process (default `Audit`, `DeltaCert`, `Logs`). |
| `-WhatIf` | Preview without changing anything. |

```powershell
.\Scripts\Invoke-SPRetention.ps1 -WhatIf
.\Scripts\Invoke-SPRetention.ps1 -ArchiveDays 30 -DeleteDays 90
```
*Exit codes:* 0 success · 1 retention disabled (no action) · 2 param · 4 config.
> Requires `Retention.Enabled = true` **or** explicit `-ArchiveDays`/`-DeleteDays`.

### Orchestrator Troubleshooting

The daily orchestrator is the most common entry point for scheduled automation. When
it fails or produces warnings, use this reference.

**Exit code table:**

| Exit Code | Meaning | Action |
|---|---|---|
| 0 | All steps succeeded | No action needed |
| 1 | Success with warnings | Check the JSONL summary for skipped steps or non-critical issues |
| 2 | Parameter error | Review script invocation; a required parameter is missing or invalid |
| 3 | Authentication failure | Token expired or PAT credentials invalid; re-authenticate |
| 4 | Configuration error | `settings.json` / `settings.local.json` has invalid values or missing required keys |
| 5 | Critical failure | One or more steps failed (e.g. disconnected-app batch all-failed, health check grade D/F) |

**Log file location:** `Logs\GovernanceToolkit-YYYY-MM-DD.log` (JSONL format). The
orchestrator also writes a dedicated summary to its output path.

**JSONL summary fields:**

| Field | Description |
|---|---|
| `RunId` | Unique UUID for this orchestrator run |
| `StepName` | Step name (e.g. `DeltaCert`, `HealthCheck`, `DisconnectedApps`) |
| `StepNumber` | Step sequence (1-11) |
| `Status` | `Success`, `Warning`, `Error`, `Skipped` |
| `Duration` | Elapsed time for the step |
| `Detail` | Human-readable summary of what happened |
| `ExitCode` | Worst exit code at the time this step completed |

**Re-run guidance for partial failures:**

If only specific steps failed, re-run the orchestrator with `-Skip*` flags to skip the
steps that already succeeded:

```powershell
# Example: steps 1-6 succeeded, step 7 (disconnected apps) failed
.\Scripts\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' `
    -SkipValidation -SkipCleanup -SkipDeltaCert -SkipDeltaReport -SkipEscalation -SkipHealthCheck
```

> **What Can Go Wrong (Operations)**
>
> - **Token expires mid-run.** Browser tokens last only 10-12 minutes. The 11-step
>   orchestrator can exceed this. Use a PAT (which auto-refreshes) for scheduled runs,
>   not a browser token.
> - **Scheduled task runs but produces no output.** The service account may lack write
>   permissions to the toolkit directory, or the execution policy blocks the script.
>   Check Task Scheduler history and the Windows event log.
> - **Retention deletes reports needed for compliance.** Review `Retention.ArchiveDays`
>   and `Retention.DeleteDays` against your retention policy. Archive zips are kept
>   for `DeleteDays` after archival, so effective retention is `ArchiveDays + DeleteDays`.

---

*See also the [GUI Playbook](gui-playbook.md) for the interactive equivalents, and
[Foundations](00-foundations.md) for setup, auth, config, and the Safety model.*

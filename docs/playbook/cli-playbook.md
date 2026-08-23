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
2. [Campaign testing & audit](#2-campaign-testing--audit) — **creating/activating campaigns**, `Invoke-GovernanceTest`, `Invoke-SPCampaignAudit`, `Invoke-SPCampaignSearch`, **`Invoke-SPCampaignClose`**
3. [Delta certification](#3-delta-certification) — `Invoke-SPADDeltaCert`, `Invoke-SPDeltaCertEscalate`, **`Invoke-SPEscalationMailer`**, `Invoke-SPDeltaReport`
4. [Disconnected applications](#4-disconnected-applications) — `Invoke-SPDisconnectedAppCert`, `Invoke-SPDisconnectedAppBatch`, `Invoke-SPDisconnectedAppRegistry`
5. [Governance & reporting](#5-governance--reporting) — health check, metrics, report, data quality, distribution, **campaign diff (day-over-day + cross-campaign decision dates)**, **cache/snapshot validator**, **per-entitlement decision history**, **campaign KPI trend / program trend**, **executive cert tracker + attestation evidence**, **daily evidence report (audit/IAG; + lean v2)**, weekly digest, **AD-ISC-HR reconciliation export (non-expiring change-detection cache)**, **state tracking (V8 fast report + Update-SPStateFiles)**, ~~adaptive reports~~ (deprecated)
6. [SDK features](#6-sdk-features) — `Invoke-SPSdkCampaignTemplates`, `Invoke-SPSdkWorkItems`, `Invoke-SPSdkWorkflows`
7. [Operations & scheduling](#7-operations--scheduling) — `Invoke-SPDailyOrchestrator`, `Invoke-SPScheduledCampaign`, `Invoke-SPRetention`
8. [B2B guest governance](#8-b2b-guest-governance) — `Invoke-SPB2BSetup`, `Invoke-SPB2BHealthCheck`

---

## Script Quick Reference (all 66 scripts)

> Ctrl+F on the script name to jump to its detailed section below.
> **Category:** EXPORT = calls ISC API | REPORT = generates output from local data |
> TRANSFORM = derives local data from local data | UTILITY = setup/config/diagnostic |
> SAMPLE = generates synthetic test data

| Script | Cat. | Purpose | ISC? | Output |
|--------|------|---------|------|--------|
| `Invoke-GovernanceTest.ps1` | EXPORT | Runs certification campaign governance tests | YES | Console/JSON |
| `Invoke-SP30DayManagerCertSim.ps1` | UTIL | 30-day MANAGER cert simulation against mock API | YES | JSONL |
| `Invoke-SPAdaptiveReport.ps1` | REPORT | ~~DEPRECATED~~ -- replaced by CertTracker/TrendReport/Diff | YES | HTML/JSONL |
| `Invoke-SPADDeltaCert.ps1` | EXPORT | Creates AD delta/full cert campaigns per manager group | YES | Console/JSONL |
| `Invoke-SPB2BHealthCheck.ps1` | EXPORT | 11-check B2B guest governance layer verification | YES | HTML/JSONL |
| `Invoke-SPB2BSetup.ps1` | EXPORT | 8-step idempotent B2B partner onboarding (ISC-side) | YES | Console/JSONL |
| `Invoke-SPCacheDiagnostic.ps1` | UTIL | Comprehensive cache integrity scanner (all cache types) | NO | Console/Log |
| `Invoke-SPCacheValidate.ps1` | UTIL | Validates snapshot/items-cache JSON for completeness | NO | Console/JSON |
| `Invoke-SPCampaignAudit.ps1` | EXPORT | Post-campaign audit reports (HTML, text, JSONL) | YES | HTML/JSONL |
| `Invoke-SPCampaignClose.ps1` | EXPORT | Finds campaigns; optionally force-completes (-SetCompleted) | OPT | Console/JSONL |
| `Invoke-SPCampaignDiff.ps1` | EXPORT | Day-over-day snapshot diff (completion + scope changes) | YES | HTML/CSV |
| `Invoke-SPCampaignSearch.ps1` | EXPORT | Unified campaign search (keywords, metrics, reviewer, source) | YES | Console/HTML/CSV |
| `Invoke-SPCampaignTrendReport.ps1` | REPORT | KPI trend report for recurring campaigns from trend JSONL | NO | HTML |
| `Invoke-SPCertTracker.ps1` | EXPORT | Executive cert progress tracker (pipeline board) | YES | HTML |
| `Invoke-SPDailyEvidenceReport.ps1` | EXPORT | Daily evidence v1: KPI dashboard + domino tracker | YES | HTML |
| `Invoke-SPDailyEvidenceReportV2.ps1` | EXPORT | Daily evidence v2: lean leadership-grade attestation | YES | HTML |
| `Invoke-SPDailyEvidenceReportV3.ps1` | EXPORT | Daily evidence v3: day-over-day delta with scope-diff | YES | HTML |
| `Invoke-SPDailyEvidenceReportV4.ps1` | EXPORT | Daily evidence v4: accountability + delta-aware evidence | YES | HTML |
| `Invoke-SPDailyEvidenceReportV4b.ps1` | EXPORT | V4 fork: metrics JSONL for downstream viz (V7/V7c) | YES | HTML/JSONL |
| `Invoke-SPDailyEvidenceReportV4c.ps1` | REPORT | Series attestation delta (read-only from rich cache) | NO | HTML |
| `Invoke-SPDailyEvidenceReportV4d.ps1` | REPORT | ~~DEPRECATED~~ -- prefer V4e | NO | HTML |
| `Invoke-SPDailyEvidenceReportV4e.ps1` | REPORT | Unified series attestation delta (V4b chrome) | NO | HTML |
| `Invoke-SPDailyEvidenceReportV4f.ps1` | REPORT | V4e + first-approval timeline across series window | NO | HTML/JSON |
| `Invoke-SPDailyEvidenceReportV4g.ps1` | EXPORT | V4 + persistent entitlement state DB (honest NewlyDecided) | YES | HTML/JSONL |
| `Invoke-SPDailyEvidenceReportV5.ps1` | REPORT | Trend-aware with 14 multi-day chart styles | NO | HTML |
| `Invoke-SPDailyEvidenceReportV6.ps1` | REPORT | Pure visualizer from daily-metrics.jsonl (10 sections) | NO | HTML |
| `Invoke-SPDailyEvidenceReportV7.ps1` | REPORT | Calendar-day visualizer (13 charts) | NO | HTML |
| `Invoke-SPDailyEvidenceReportV7c.ps1` | REPORT | V7 + engagement heatmap + entitlement state (15 charts) | NO | HTML |
| `Invoke-SPDailyEvidenceReportV8.ps1` | REPORT | State-powered report (-AutoFetch), <30s render, 8 sections | NO | HTML |
| `Invoke-SPDailyOrchestrator.ps1` | EXPORT | Full daily governance workflow (12-step coordinator) | YES | Console/JSONL |
| `Invoke-SPDataQualityReport.ps1` | EXPORT | Data quality: orphans, identity attributes, source health | YES | HTML |
| `Invoke-SPDecisionScrape.ps1` | XFORM | Scrapes evidence HTMLs for revoked/new-scope decisions | NO | HTML |
| `Invoke-SPDeltaCertEscalate.ps1` | EXPORT | Escalates stale certs by reassigning up org tree | YES | HTML/JSONL |
| `Invoke-SPDeltaReport.ps1` | EXPORT | Daily delta cert report: grants/revocations in time window | YES | HTML/JSONL |
| `Invoke-SPDisconnectedAppBatch.ps1` | EXPORT | Batch orchestrator for disconnected app certs | YES | HTML/JSONL |
| `Invoke-SPDisconnectedAppCert.ps1` | EXPORT | Full disconnected app cert pipeline (validate/snapshot/delta) | YES | HTML/JSONL |
| `Invoke-SPDisconnectedAppRegistry.ps1` | UTIL | Manages disconnected app registrations in settings.json | NO | Console/JSON |
| `Invoke-SPEntitlementHistory.ps1` | REPORT | Per-entitlement decision timeline across N snapshots | NO | HTML/CSV |
| `Invoke-SPEscalationMailer.ps1` | UTIL | Sends personalized escalation emails via SMTP | NO | CSV |
| `Invoke-SPGovernanceHealthCheck.ps1` | EXPORT | 6-dimension health check with pass/fail grades | YES | HTML |
| `Invoke-SPGovernanceHeartbeat.ps1` | EXPORT | Lightweight high-frequency campaign KPI capture | YES | JSONL/HTML |
| `Invoke-SPGovernanceMetrics.ps1` | EXPORT | Captures governance KPIs to time-series store | YES | JSONL/HTML |
| `Invoke-SPGovernanceReport.ps1` | EXPORT | Full governance report package (audit/policy/quality) | YES | HTML/CSV/JSON |
| `Invoke-SPGovernanceTrendScrape.ps1` | XFORM | Scrapes evidence HTMLs for monthly governance trend | NO | HTML |
| `Invoke-SPHierarchicalReport.ps1` | EXPORT | Hierarchical leadership cert rollup (per-leader HTML) | YES | HTML |
| `Invoke-SPIscReconciliation.ps1` | EXPORT | ISC identity+entitlement export for AD/HR reconciliation | YES | JSON/CSV |
| `Invoke-SPOrgTreePreview.ps1` | EXPORT | ASCII org-tree preview for a campaign's certifiers | YES | Console |
| `Invoke-SPPendingReviewerScrape.ps1` | XFORM | Scrapes evidence HTMLs for chronic-pending reviewer trends | NO | HTML |
| `Invoke-SPReportDistribution.ps1` | EXPORT | Generates and distributes leadership reports via SMTP | YES | HTML/JSONL |
| `Invoke-SPResilienceProbe.ps1` | UTIL | Resilience probe: verifies toolkit survives API failures | YES | Console |
| `Invoke-SPRetention.ps1` | UTIL | Log and report retention cleanup (archive + delete) | NO | Console/JSON |
| `Invoke-SPScheduledCampaign.ps1` | EXPORT | Runs campaigns from saved templates on cadence | YES | Console/JSON |
| `Invoke-SPSdkCampaignTemplates.ps1` | EXPORT | Lists/inspects ISC campaign templates and schedules | YES | Console/JSON |
| `Invoke-SPSdkWorkflows.ps1` | EXPORT | Lists/inspects ISC workflows and execution history | YES | Console/JSON |
| `Invoke-SPSdkWorkItems.ps1` | EXPORT | Lists ISC work items (open/completed counts) | YES | Console/JSON |
| `Invoke-SPTrendBackfill.ps1` | XFORM | Backfills campaign trend JSONL from existing snapshots | NO | JSONL |
| `Invoke-SPWeeklyDigest.ps1` | EXPORT | Weekly governance digest (campaigns, health, risk, reviewers) | YES | HTML/JSON |
| `New-SPDailyEvidenceV5Sample.ps1` | SAMPLE | Generates V5 sample report with four viz styles | NO | HTML |
| `New-SPDisconnectedAppSnapshotData.ps1` | SAMPLE | Generates deterministic disconnected-app CSV test data | NO | CSV |
| `New-SPMockDailyReports.ps1` | SAMPLE | Generates 15 realistic daily evidence HTMLs for testing | NO | HTML |
| `New-SPSampleDashboard.ps1` | SAMPLE | Generates governance trend dashboard with synthetic data | NO | HTML |
| `New-SPSampleEscalation.ps1` | SAMPLE | Generates sample escalation reports across 5 tiers | NO | HTML |
| `New-SPVault.ps1` | UTIL | One-time encrypted credential vault setup | NO | Console |
| `Show-SPDashboard.ps1` | UTIL | Launches WPF interactive governance dashboard (Windows) | NO | GUI |
| `Test-SPConnectivity.ps1` | UTIL | Quick smoke test for ISC connectivity and OAuth | YES | Console |
| `Update-SPStateFiles.ps1` | XFORM | Updates entitlement/reviewer state JSONL from rich cache | NO | JSONL |

**Totals:** 35 EXPORT (call ISC) | 12 REPORT (local data to HTML) | 5 TRANSFORM (local to local) | 9 UTILITY | 5 SAMPLE

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

### Creating & activating a campaign (the write path)
**Purpose:** the toolkit doesn't just *audit* campaigns — it can **create, activate,
and complete** them. The lifecycle building blocks live in `SP.Api\SP.Campaigns.psm1`
and follow the ISC state machine `STAGED → ACTIVATING → ACTIVE → COMPLETING → COMPLETED`:

| Function | What it does |
|---|---|
| `New-SPCampaign` | POSTs `/campaigns` and returns the **STAGED** campaign. `-Type` is one of `MANAGER`, `SOURCE_OWNER`, `SEARCH`, `ROLE_COMPOSITION`; supply only the fields that type needs (`-CertifierIdentityId` for MANAGER/SEARCH/ROLE_COMPOSITION, `-SourceId` for SOURCE_OWNER, `-SearchFilter` for SEARCH, `-RoleId` for ROLE_COMPOSITION). Optional `-Description`, `-Deadline` (ISO 8601). |
| `Start-SPCampaign` | POSTs `/campaigns/{id}/activate` — transitions **STAGED → ACTIVATING → ACTIVE** (a campaign does nothing until activated). |
| `Get-SPCampaignStatus` | Blocking poller — waits until the campaign reaches `-TargetStatus` (default `ACTIVE`) so a script can create → activate → confirm in one flow. |
| `Complete-SPCampaign` | POSTs `/campaigns/{id}/complete` to close a **past-due** campaign. Gated by `Safety.AllowCompleteCampaign` (returns an error, makes no API call, when false). |

These are module functions (not standalone scripts), so run them after importing the
module chain. The minimal **create → activate** flow for a **MANAGER** campaign:

```powershell
Import-Module .\Modules\SP.Api\SP.Api.psd1   # pulls SP.Core -> SP.Api
$c = New-SPCampaign -Name 'Q3 Manager Review' -Type MANAGER `
        -CertifierIdentityId 'idn-mgr-001' -Deadline '2026-09-30T23:59:59Z'
if ($c.Success) { Start-SPCampaign -CampaignId $c.Data.id }
```

For the **driven** (no-hand-rolling) paths that create *and* activate campaigns for you:
- **`Invoke-SPDeltaCertRun`** (in `SP.DeltaCert\SP.DeltaCertRunner.psm1`) — finds newly-granted
  access, groups affected identities by manager, then **creates and activates one campaign
  per manager** in a single call (`ReviewerMode Manager` → one SEARCH campaign per manager;
  `SourceOwner` → one SOURCE_OWNER campaign per source). It is the engine behind the
  `Invoke-SPADDeltaCert.ps1` script (§3) and `Invoke-SPScheduledCampaign.ps1` (§7). Honors
  `-WhatIf` and the `MaxCampaignsPerRun` ceiling.
- **`Invoke-SPADDeltaCert.ps1`** (§3) and **`Invoke-SPScheduledCampaign.ps1`** (§7) — the
  scheduled, script-level wrappers that call the runner.

> **Scope:** creating/activating/completing campaigns needs the **Full-toolkit** PAT scope
> set (`idn:campaign:manage`, …) — see [Foundations §5.1](00-foundations.md#51-the-isc-credential-a-personal-access-token-pat).
**Related GUI:** the SDK Features → Templates sub-tab (New Template / Edit Schedule) creates
*scheduled* campaign templates; ad-hoc create/activate is a CLI/module operation.

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
| `-CampaignNameContains <kw>` | Name contains keyword (case-insensitive, filtered client-side; best for fuzzy search). |
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

### `Invoke-SPCampaignClose.ps1`
**Purpose:** find and optionally **complete** certification campaigns from the command line.
Safe by default -- without `-SetCompleted` it is purely a read-only listing. Designed for
closing out daily attestation campaigns that have run their course.

**When to use:** end-of-day or next-morning cleanup of completed daily campaigns. Also useful
for closing stale campaigns that reviewers have finished but ISC hasn't auto-completed.

| Parameter | Description |
|---|---|
| `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Campaign name filters (same precedence as all toolkit scripts). |
| `-Status <list>` | Filter by status (default: all statuses). Example: `-Status ACTIVE`. |
| `-DaysBack <n>` | Look-back window (default 1). |
| `-SetCompleted` | Actually complete the matching campaigns. Without this, the script only lists them. |
| `-Force` | Skip the confirmation prompt when completing more than 5 campaigns. |

**Safety:**
- Without `-SetCompleted`: read-only listing -- no API writes
- With `-WhatIf -SetCompleted`: shows what would be completed without doing it
- More than 5 matches: requires typing "YES" to confirm (or `-Force`)
- Requires `Safety.AllowCompleteCampaign = true` in `settings.json`
- Pending (undecided) items maintain current access when a campaign is completed

```powershell
# List active daily campaigns from the last day (read-only)
.\Scripts\Invoke-SPCampaignClose.ps1 -CampaignNameContains 'Daily Attestation' -Status ACTIVE -DaysBack 1 -Token $token

# Dry run -- see what would be completed
.\Scripts\Invoke-SPCampaignClose.ps1 -CampaignNameContains 'Daily Attestation Monday' -Status ACTIVE -DaysBack 1 -SetCompleted -WhatIf -Token $token

# Complete a specific day's campaign
.\Scripts\Invoke-SPCampaignClose.ps1 -CampaignNameContains 'Daily Attestation Monday' -Status ACTIVE -DaysBack 1 -SetCompleted -Token $token

# Close all daily campaigns from the last 7 days (skip confirmation)
.\Scripts\Invoke-SPCampaignClose.ps1 -CampaignNameContains 'Daily' -Status ACTIVE -DaysBack 7 -SetCompleted -Force -Token $token
```

> **WARNING:** Completing a campaign makes all undecided items maintain current access.
> Always run without `-SetCompleted` first to review what will be closed and how many
> items are still pending. The script shows pending item counts in both listing and
> WhatIf modes.

*Exit codes:* 0 success | 1 no matches | 2 parameter | 3 auth | 4 config | 5 completion failed.

> **Least-privilege PAT scopes:**
> - **Read-only listing** (without `-SetCompleted`): `idn:campaign:read` + `idn:campaign-report:read`
> - **Complete campaigns** (with `-SetCompleted`): `idn:campaign:manage` (includes read)
> - **Browser token** (`-Token`): works for both -- browser tokens carry full admin scope.
> - The PAT user must have **ORG_ADMIN** or **CERT_ADMIN** user level. A standard user
>   will receive 403 even with the correct scopes.

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
| `-CampaignNamePrefix <s>` | Prefix (starts-with) used to find delta-cert campaigns (default `DeltaCert.Escalation.CampaignNamePrefix`). |
| `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Same name-resolution options as `Invoke-SPCampaignDiff`. **`-CampaignNameContains 'Wednesday'`** matches a token mid-name (e.g. the weekday in `Daily Attestation Manager Wednesday`); `-CampaignName` is an exact match. Precedence: exact > contains > startsWith > prefix. |
| `-StaleHours <n>` | Hours of inactivity before a cert is "stale" (default 24). |
| `-MaxEscalationLevels <n>` | Max hops up the org tree from the original reviewer (default 2). |
| `-DaysBack <n>` *(+ `-WhatIf`)* | **Org-chart audit mode:** check every cert in campaigns from the last N days and resolve each reviewer→skip-level chain — validates ISC manager chains without writing. |
| `-Csv` / `-CsvPath <p>` | Write the full reviewer→skip-level chain to a CSV (read-only; produced even under `-WhatIf`). |
| `-EmailList` / `-EmailListPath <p>` | Write a copy-paste **email-queue** text file with: (1) global `;`-separated email lines (managers behind + skip-level path), and (2) **per-skip-level-manager breakdown tables** showing which reviewers under each manager still need to act. Produced even under `-WhatIf`. |
| `-EmailHtml` / `-EmailHtmlPath <p>` | Write a **self-contained HTML escalation report** grouping late reviewers by skip-level manager with clean tables (reviewer, email, campaign, hours open, reason, status). Includes an "Email Quick-Copy" footer with the `;`-separated lines. Professional styling, suitable for email attachment or SharePoint. |
| `-EmailHtmlManagers` / `-EmailHtmlManagersPath <dir>` | Generate **individual HTML email templates per skip-level manager** -- one personalized file per manager ("Hi Jane, you have direct reports who have not completed...") with a clean table (Reviewer, Campaign, Pending Items). Output: `escalation-managers\{name}.html` + `_manifest.json` for future SMTP automation. |

```powershell
# Live escalation
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -Token $jwt

# Dry-run + the copy-paste email queue (managers behind + skip-level breakdown)
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf -EmailList

# Dry-run + HTML escalation report (grouped by skip-level manager)
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf -EmailHtml

# Full package: CSV chain + text email queue + HTML report
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf -Csv -EmailList -EmailHtml

# Scope to Wednesday campaigns only
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -CampaignNameContains 'Wednesday' -DaysBack 1 -WhatIf -Csv -EmailList -EmailHtml

# Full org-chart audit: the chain spreadsheet AND the email lines
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf -Csv -EmailList

# Generate individual per-manager email templates (for SMTP automation)
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -CampaignNameContains 'Thursday' -DaysBack 1 -WhatIf -EmailHtmlManagers

# Everything: CSV + text queue + consolidated HTML + per-manager templates
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -CampaignNameContains 'Daily Attestation' -DaysBack 1 -WhatIf -Csv -EmailList -EmailHtml -EmailHtmlManagers
```

> **`-EmailList` — the email queue + skip-level breakdown.** Writes `escalation-emails-*.txt` to
> `DeltaCert.OutputPath`: labelled header, two global `;`-separated email lines (managers behind +
> escalation path), then a **per-skip-level-manager section** with text tables showing each
> manager's outstanding reviewers, their campaigns, hours open, and escalation reason.
>
> **`-EmailHtml` — the HTML alternative.** Writes `escalation-report-*.html` to `DeltaCert.OutputPath`:
> a clean, self-contained HTML report grouping late reviewers by skip-level manager. Each group
> shows the manager's name/email, count of outstanding reviewers, and a color-coded table. Includes
> an "Email Quick-Copy" footer with the `;`-separated lines for To/CC. Both artifacts are read-only
> (no ISC writes) and safe under `-WhatIf`.
>
> **`-EmailHtmlManagers` -- per-manager SMTP templates.** Writes one HTML file per skip-level
> manager to `escalation-managers\` with a personalized greeting, their outstanding reviewers
> table (Reviewer, Campaign, Pending Items), and totals. Plus `_manifest.json` listing every
> generated file with recipient email, identity ID, and counts -- the SMTP automation hook.
> A future send script reads the manifest and delivers each file to its recipient without
> reassigning in ISC. Read-only, safe under `-WhatIf`.

**Related GUI:** Delta Cert tab → Escalate.

### `Invoke-SPEscalationMailer.ps1`
**Purpose:** sends the personalized escalation HTML emails generated by `Invoke-SPDeltaCertEscalate.ps1`
via SMTP. Reads the `_email-routing.csv` from the most recent escalation run and delivers each
manager's HTML file to their email address. Designed as the second half of a two-step pipeline.

**When to use:** after running `Invoke-SPDeltaCertEscalate.ps1 -EmailHtmlManagers` to generate
the per-manager HTML files. Run with `-WhatIf` first to preview recipients.

| Parameter | Description |
|---|---|
| `-RoutingCsvPath <path>` | Explicit path to `_email-routing.csv`. If omitted, auto-discovers from the latest escalation run. |
| `-EscalationDir <dir>` | Base directory to search for the latest timestamped run folder. |
| `-SmtpServer <host>` | SMTP server (overrides `Notification.Smtp.Server` in settings.json). |
| `-SmtpPort <n>` | SMTP port (default 587). |
| `-From <email>` | Sender address (overrides `Notification.Smtp.From`). |
| `-UseSsl` | Enable TLS. |
| `-Credential <PSCredential>` | SMTP authentication credentials. |
| `-Subject <text>` | Email subject line (default: "Action Required: Pending Attestation Review"). |
| `-SubjectPrefix <text>` | Prepend to subject (e.g., `[IAM]` or `[GOVERNANCE]`). |
| `-Levels 2,3` | Only send to specific org levels (default: all rows). |
| `-SkipAllOutstanding` | Don't send the `all-outstanding.html` blast email. |

```powershell
# Full pipeline: generate + preview + send
# Step 1: Generate escalation HTML
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -CampaignNameContains 'Daily' -DaysBack 1 -Status ACTIVE -WhatIf -EmailHtmlManagers -MaxEscalationLevels 3 -Token $token

# Step 2: Preview what would be sent (dry run -- no emails)
.\Scripts\Invoke-SPEscalationMailer.ps1 -WhatIf

# Step 3: Send only level 2 managers (direct managers)
.\Scripts\Invoke-SPEscalationMailer.ps1 -Levels 2

# Step 4: Send all levels with explicit SMTP
.\Scripts\Invoke-SPEscalationMailer.ps1 -SmtpServer smtp.company.com -From governance@company.com -UseSsl -SubjectPrefix '[IAM]'

# Step 5: Send level 3 (directors) only, skip the all-outstanding blast
.\Scripts\Invoke-SPEscalationMailer.ps1 -Levels 3 -SkipAllOutstanding
```

> **SMTP configuration:** The mailer reads SMTP settings from `Notification.Smtp` in `settings.json`
> (Server, Port, From, UseSsl). Override any of these with explicit parameters. If no SMTP config
> exists and no parameters are provided, the script errors with exit code 4.
>
> **Send log:** Each run appends to `_send-log.csv` in the escalation run folder with:
> Timestamp, Level, ManagerEmail, ManagerName, HtmlFile, Status (Sent/Failed), Error.

> **Least-privilege PAT scopes:** None required -- this script only reads local files and sends
> email via SMTP. No ISC API calls are made. Only needs network access to the SMTP server.

*Exit codes:* 0 all sent | 1 some failed | 2 parameter | 4 config/SMTP | 5 no routing CSV found.

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

### Campaign filtering & the item cache (read this first)

The seven report scripts below — `Invoke-SPCampaignAudit`, `Invoke-SPGovernanceReport`,
`Invoke-SPGovernanceMetrics`, `Invoke-SPDailyEvidenceReport`, `Invoke-SPWeeklyDigest`,
`Invoke-SPAdaptiveReport`, `Invoke-SPReportDistribution` — share two behaviours worth
understanding before you run them.

**Campaign name filters.** Every one accepts the same three optional filters (on top of
`-Status` / `-DaysBack` / date windows):

| Filter | Match | Use when |
|---|---|---|
| `-CampaignName <name>` | Exact, case-insensitive | You know the full name. |
| `-CampaignNameStartsWith <prefix>` | Name begins with the prefix | A stable prefix identifies a family (e.g. `Daily Attestation Manager Campaign - Tuesday`). |
| `-CampaignNameContains <kw>` | Substring, case-insensitive (client-side) | Fuzzy / keyword search. |

Precedence is **exact → starts-with → contains** (pass more than one and the most specific
wins). Filters combine with the window, so `-CampaignNameContains 'Tuesday' -DaysBack 30`
returns **every** Tuesday campaign in the last 30 days — narrow it (e.g.
`-CampaignNameContains 'Tuesday, June 09'`) to target a single day. Omitting all three keeps
the previous behaviour: every campaign in the status/date window.

**The campaign item cache.** Pulling a campaign's review items from ISC is the slow part —
one API call per certification, minutes for a large campaign. Each script fetches a campaign's
items **once** and reuses them on every later run:

- First run for a campaign logs `... [from ISC]` and writes `Audit\.cache\items-<id>.jsonl`.
- Later runs — the *same* report or a *different* one — log `... [from cache]` and return in seconds.
- **COMPLETED** campaigns are cached **permanently** (their data is sealed); **ACTIVE**
  campaigns use a TTL (`Audit.CacheActiveTtlMinutes`, **default 180 = 3h**) so in-progress
  reviewer decisions aren't served stale indefinitely; `STAGED` / `ERROR` are never cached.

The cache is keyed by campaign ID and shared across all six scripts, so the practical pattern
is **pull once, report many**:

```powershell
# 1) First report pulls Tuesday's items from ISC and caches them (slow, once).
.\Scripts\Invoke-SPCampaignAudit.ps1    -CampaignNameContains 'Tuesday, June 09' -OutputMode Both   # [from ISC]
# 2) Every other report on the same campaign now reads the cache (fast).
.\Scripts\Invoke-SPGovernanceReport.ps1 -CampaignNameContains 'Tuesday, June 09'                     # [from cache]
.\Scripts\Invoke-SPWeeklyDigest.ps1     -CampaignNameContains 'Tuesday, June 09'                     # [from cache]
```

Across a week of **completed** daily campaigns (Mon–Sat), each is pulled once and every
subsequent report for the rest of the week is a cache hit.

**Force a fresh pull** (e.g. a campaign just completed and you want to re-cache it):

```powershell
Import-Module .\Modules\SP.Audit\SP.Audit.psd1 -Force -DisableNameChecking
Clear-SPAuditItemCache                       # all campaigns
Clear-SPAuditItemCache -CampaignId '<id>'    # just one
```

Cache location and the active-campaign TTL are configurable via `Audit.CachePath` and
`Audit.CacheActiveTtlMinutes` in `settings.json`. A relative `CachePath` is anchored to the
**toolkit root**, so the cache lands in the same place no matter which directory you launch
the script from (running from `Scripts\` no longer scatters it to `Scripts\Audit\.cache`).

> **Cache vs. source of truth.** The item cache is a **disposable mirror of ISC** — deleting it
> only forces a re-fetch; it is *not* a system of record. The immutable **snapshots** written by
> `Invoke-SPCampaignDiff.ps1` (`Audit\snapshots\<id>\<stamp>.json`, append-only, SHA-256-sealed)
> are the historical **source of truth** for diffs and trends. For campaigns that stay ACTIVE for
> a long time (laggards finishing days later), capture **one snapshot per active campaign on a
> schedule** so each builds its own timeline — then day-over-day (same campaign) and cross-campaign
> diffs both work. Validate either with `Invoke-SPCacheValidate.ps1`.

**Three things that make long runs survivable.** A big campaign (thousands of items /
identities) can take many minutes, so the report scripts now:

- **Show progress during the quiet phases.** Account resolution and the revoked-identity
  event lookups print a periodic heartbeat (`...1200 / 3500 (34%) [cache: 800, fetched: 400]`)
  so you can see it is still working, not hung. If the heartbeat slows, you are being
  rate-limited by ISC (the log shows the `Rate limit … Waiting` waits) — it will still finish.
- **Cache identity→account resolution to disk.** Resolving each identity's
  sAMAccountName / UPN / email is a per-identity API call and was the slow, silent phase that
  re-ran on *every* report. It is now cached to `Audit\.cache\accounts.jsonl` with a TTL
  (`Audit.AccountCacheTtlMinutes`, default 1440 = 24h), so the **second report onward reuses
  it**. Force a refresh with `Clear-SPAuditAccountCache` (`-CampaignId` not needed — accounts
  are campaign-independent).
- **Resume an interrupted item fetch.** The item cache is now written *per certification as it
  is fetched*. If a long first-time pull is killed mid-way, the next run **resumes from the
  last completed certification** instead of restarting (`[Cache] Resuming partial fetch: …`).

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
| `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Filter captured campaigns by name (see *Campaign filtering & the item cache*). |
| `-OutputMode` | `Console`/`HTML`/`JSON`/`Both`. |
| `-IncludeDashboard` | Generate a governance trend dashboard HTML (KPI cards, SVG sparklines, direction arrows, alerts). |
| `-DashboardPeriod` | `Last7Days`/`Last30Days`/`Last90Days`/`AllTime` (default Last30Days). |

```powershell
# Capture + trend + completion forecast
.\Scripts\Invoke-SPGovernanceMetrics.ps1 -IncludeCompletionForecast -OutputMode Both

# Capture + governance trend dashboard
.\Scripts\Invoke-SPGovernanceMetrics.ps1 -IncludeDashboard -DashboardPeriod Last90Days
```
**Related GUI:** Governance tab → Metrics.

### `Invoke-SPGovernanceHeartbeat.ps1`
**Purpose:** lightweight governance pulse check -- captures only campaign-level KPIs
(active/completed/overdue counts, average completion %) via a single API call. No item-
level fetching, so it runs in seconds. Designed for high-frequency scheduling (every 4
hours) to produce finer-grained sparkline data.

| Parameter | Description |
|---|---|
| `-OutputPath` | Override output directory. |
| `-IncludeDashboard` | Also generate the trend dashboard HTML. |
| `-DashboardPeriod` | `Last7Days`/`Last30Days`/`Last90Days` (default Last7Days). |
| `-DaysBack` | Campaign lookback window (default 90). |

```powershell
# Quick heartbeat capture
.\Scripts\Invoke-SPGovernanceHeartbeat.ps1

# Heartbeat + mini dashboard
.\Scripts\Invoke-SPGovernanceHeartbeat.ps1 -IncludeDashboard -DashboardPeriod Last7Days
```

### Cache Management Commands

### Stalled Reviewer Detection

Detect reviewers who have made zero progress across campaigns for 3+ consecutive days:

```powershell
# Detect stalled reviewers
$stalled = Get-SPStalledReviewers -ConsecutiveDays 3
$stalled.Data.StalledReviewers | Format-Table Reviewer, CampaignCount, StalledDays, Severity

# Generate accountability HTML report
Export-SPStalledReviewerHtml -StalledData $stalled.Data -OutputPath '.\Reports\'
```

Multi-campaign stalls (RED severity) typically indicate a reviewer who is OOO, has departed,
or whose campaigns need reassignment. The daily orchestrator runs this automatically as Step 11.

### Cache Management Commands

The toolkit caches identity details, account data, and campaign items to reduce API calls.
All caches support inspection and clearing via `SP.Shared` functions:

```powershell
# Inspect a specific cache store
Get-SPCacheStoreInfo -Store 'SPIdentity'

# View all cache stores
Get-SPCacheStoreSummary

# Validate JSONL integrity
Test-SPCacheStoreIntegrity -Store 'SPIdentity'

# Clear identity cache (for SOX-critical evidence runs)
Clear-SPIdentityCache

# Clear campaign item cache
Clear-SPAuditItemCache -CampaignId 'campaign-id-here'
```

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
| `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Filter campaigns by name (see *Campaign filtering & the item cache*). |
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

### `Invoke-SPHierarchicalReport.ps1`
**Purpose:** generates **hierarchical leadership drill-down HTML reports** — one self-contained
file per leader at (or above) the specified org level. Each report shows the full certification
rollup for that leader's subtree as collapsible sections: VP expands to Directors, Directors
to Managers, Managers to certified identities, identities to entitlement-level decisions.
All decision counts bubble upward so each level always shows its subtree totals.
**When to use:** after a certification period closes, to give each executive/director a
single file showing everything that happened under them — approved, revoked, and pending.
Also useful as a spot-check at any point during an active campaign window.

| Parameter | Description |
|---|---|
| `-DaysBack <n>` | Campaign look-back window (default 30). |
| `-CampaignNameContains <str>` | Filter campaigns by name substring (e.g. `'Daily Attestation'`). |
| `-MinReportLevel <0-5>` | Minimum org level to generate a file for. `0`=all certifiers, `1`=directors+ (default), `2`=VPs+. |
| `-OrgDepth <n>` | Levels to walk up the manager chain (default 5). |
| `-OutputPath <dir>` | Output root (default `.\Audit\HierarchicalReports`). |
| `-ReportTitle <str>` | Title shown in every report header. |
| `-OutputMode` | `Console`/`JSON`/`Both` — controls the run summary; the HTML files are always written. |
| `-OrgSupplementPath <csv>` | Merge `Config\org-chart-supplement.csv` to fill ISC manager-chain gaps where the chain dead-ends short of the top. |
| `-RefreshIdentities` | Clear the identity cache first so the manager chain is re-resolved from ISC — use to validate org movement after a reorg. |
| `-IncludeMasterRollup` / `-MasterScope <s>` | Also generate the **executive master rollup**: one consolidated doc with an org-wide KPI banner, whole-org drill-down, leadership scorecard, the revocations ("what was done"), and a coverage/exceptions footer. Scope `CompanyWide` / `PerTopLeader` / `Both` (default `Both`). |
| `-WhatIf` | Preview: shows campaign/cert count without generating files. |

```powershell
# Preview first — see how many campaigns and certs will be included
.\Scripts\Invoke-SPHierarchicalReport.ps1 -DaysBack 30 -WhatIf

# Generate director-and-above reports for last 30 days (default)
.\Scripts\Invoke-SPHierarchicalReport.ps1

# Scope to a specific campaign type, generate VP-and-above only
.\Scripts\Invoke-SPHierarchicalReport.ps1 -CampaignNameContains 'Daily Attestation' -MinReportLevel 2

# Per-leader files PLUS the executive master rollup, filling chain gaps from the supplement
.\Scripts\Invoke-SPHierarchicalReport.ps1 -CampaignNameContains 'Tuesday' -IncludeMasterRollup -OrgSupplementPath .\Config\org-chart-supplement.csv

# After a reorg: force fresh identity resolution
.\Scripts\Invoke-SPHierarchicalReport.ps1 -CampaignNameContains 'Tuesday' -RefreshIdentities
```

The master rollup lands beside the per-leader files in a `master-<stamp>\` subdirectory
(`master-rollup-company.html` and one `master-rollup-<Leader>.html` per top leader).

**Output structure:** each run creates a timestamped subdirectory so multiple runs never
overwrite each other:
```
Audit\HierarchicalReports\
  run-20260609-041423\
    hierarchy-report-James_Smith.html    ← VP-level: full org subtree (699 KB)
    hierarchy-report-Mary_Johnson.html
    hierarchy-report-John_Jones.html
    ...
```

**HTML report controls** (all in the report header bar):

| Button | Behaviour |
|---|---|
| **Expand All** | Open every collapsible section |
| **Collapse All** | Collapse everything to root-level summaries |
| **Hide Empty** (turns yellow) | Hide any node whose subtree has zero decisions in this window — removes org-chart noise |
| **Hide Identities** (turns blue) | Hide individual identity rows; manager-level counts (approved/revoked/pending) stay visible — executive summary view |

Combining **Hide Empty + Hide Identities** gives a clean count-only view of the org
hierarchy with inactive managers suppressed — ideal for sharing upward.

**Required scope:** `sp:search:read` (identity resolution for org tree walks).
The `reviewer.id` field on certification objects must be populated — this is standard
for all ISC certifications.

**Related GUI:** Governance tab → Hierarchical Drill-Down Reports.

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

| Control Area | Toolkit Report | What It Proves |
|---|---|---|
| Periodic access review / certification | Campaign Audit, Leadership Rollup | Access was reviewed and decisions were made by authorized reviewers |
| Segregation of duties | Adaptive SoD Baseline | Toxic combinations identified and reviewed |
| Logical access controls | Campaign Audit, Data Quality | Access is periodically reviewed; orphan accounts identified |
| Access reviewed prior to provisioning | Delta Report | New access grants are certified promptly |
| Timely access removal | Remediation Tracking (Weekly Digest) | Revoked access is actually removed |
| Review of access rights | Governance Report | Comprehensive governance posture snapshot |
| Removal of access | Delta Report, Remediation Tracking | Timely revocation and follow-through |

**Packaging evidence for auditors:**
1. Run `Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 90 -IncludeLeadershipRollup -IncludeDataQuality` to generate the full evidence package.
2. Collect the output directory (`Reports\`) -- it includes a manifest listing all artifacts.
3. Include the JSONL audit trail (`Audit\*.jsonl`) for machine-verifiable provenance.
4. For compliance evidence, add the leadership rollup reports to show reviewer accountability.

### `Invoke-SPOrgTreePreview.ps1`
**Purpose:** prints the **org tree as ASCII art** for a campaign's certifiers, so you can
eyeball the management chain (and band assignments) before generating leadership reports.
Read-only; surfaces `Build-SPOrgTree` / `Show-SPOrgTree` as a one-command tool.
**When to use:** sanity-check the org structure, spot where ISC manager data dead-ends, or
validate an `org-chart-supplement.csv` before a big report run.

| Parameter | Description |
|---|---|
| `-CampaignName*` | Campaign name filters (exact / starts-with / contains). |
| `-Status <list>` / `-DaysBack <n>` | Campaign window (default `COMPLETED, ACTIVE` / 30). |
| `-OrgDepth <1-10>` | Levels to walk up the manager chain (default 5). |
| `-OrgSupplementPath <csv>` | Merge the supplement to fill ISC chain gaps. |
| `-ShowBands` | Annotate each node with its A–E leadership band. |
| `-MaxChildrenShown <n>` | Truncate each node to the first *n* children (0 = all). |
| `-RefreshIdentities` | Re-resolve the chain from ISC (validate movement after a reorg). |

```powershell
.\Scripts\Invoke-SPOrgTreePreview.ps1 -CampaignNameContains 'Tuesday' -ShowBands
.\Scripts\Invoke-SPOrgTreePreview.ps1 -Status COMPLETED -DaysBack 7 -OrgSupplementPath .\Config\org-chart-supplement.csv
```

### `Invoke-SPCampaignDiff.ps1`
**Purpose:** **day-over-day (or intra-day / weekly / monthly) diff reporting** for a
recurring attestation campaign. Each run captures an immutable, datetime-stamped *snapshot*
of the campaign and compares it against the prior snapshot, producing **two read-only
reports**:

- **Completion diff** — *who is doing their attestations.* Per reviewer: decisions
  **Decided** since the last capture (the count of items the reviewer has acted on — what was
  previously labelled "made"), **Approved** and **Revoked** sub-counts, completion %, **newly
  completed**, **stalled** (no progress between captures), and **not started**. Reviewers with
  no items show `—` rather than a misleading `0 / 0 = 0%`.
- **Scope diff** — *what changed in the campaign.* Grants added to scope are split into
  **Newly approved access**, **Newly revoked access**, and **Newly added, not yet decided** (so
  fresh approvals aren't bundled in with revokes); grants **removed**; and **decision changes**
  — a real **APPROVE↔REVOKE** flip on the same grant (access removed or re-granted), *not* a
  reviewer who simply hasn't re-reviewed yet. Every scope list carries the **Reviewer (manager)**
  who owns the item. Plus a **compliance summary**: newly-added privileged access,
  stalled/not-started reviewers, overdue undecided items, and a *privileged-approved* advisory.

**When to use:** run it on the campaign's cadence (e.g. each morning) so leadership can
see who is keeping up and what new (especially privileged) access appeared — **without**
touching the delta-escalation chain. **Read-only: it never reassigns, escalates, or
completes anything in ISC.** The snapshot is the single source of truth, so "yesterday vs
today", "before noon vs now", and "this week vs last" all reduce to *which two snapshots*.

> **Cadence = comparison granularity.** The diff compares the current snapshot to the most
> recent *prior* one. Capture daily for a day-over-day view; capture twice a day for an
> intra-day "before noon vs now" view. No prior snapshot (first run) ⇒ a baseline report.

| Parameter | Description |
|---|---|
| `-CampaignId <id>` | Resolve the recurring campaign by its **stable id** (most precise). |
| `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Resolve by name (contains is client-side; ISC rejects bare `name co`). |
| `-Status <list>` / `-DaysBack <n>` | Resolution window (default `ACTIVE` / 30). |
| `-NoCapture` | Don't call ISC — diff the **two most recent existing snapshots** (re-render offline). |
| `-CompareBefore <iso>` | Pick the "previous" snapshot as the most recent one strictly before this time. |
| `-Cadence` | Which prior snapshot to diff against: `Adjacent` (immediately prior, default), `IntraDay` (earlier today), `Daily` (~24h ago), `Weekly` (~168h ago), `Monthly` (~730h ago). This is what makes a *week-over-week* report compare this week's capture to **last week's**, not to yesterday's. |
| `-IncludeCsv` | Also write flat completion + scope **CSVs** (Excel / leadership). |
| `-VelocityAdvisory` | **Opt-in.** Also emit the review-velocity advisory (see caveat below). |
| `-PerDirector` / `-OrgDepth <n>` | **Opt-in.** Also write **one HTML report per director** (their team's attestation progress + the access added/removed/changed for their reviewers) + an `index.html`, under `…\per-director\per-director-<stamp>\` — each self-contained and suitable to **send to that director individually**. A director = a reviewer's manager (one level up the org tree, `-OrgDepth` default 3); reviewers with no manager fall into one `Unassigned` report. |
| `-CrossCampaign` | **For "new campaign per day" setups.** Compare two DIFFERENT campaigns instead of two captures of the same one. When the name filter matches several (e.g. `Daily Attestation Manager Monday` / `…Tuesday`), it diffs the **two most-recently-created** against each other. The **scope diff (access added/removed)** is the meaningful day-over-day view; completion shows each campaign's own state (progress-deltas are suppressed — they're separate review cycles). Needs ≥2 matches and a live capture (not `-NoCapture`). Pairs well with `-PerDirector`. |
| `-PruneOldSnapshots` | Run the lifecycle-aware retention sweep (never deletes a signed/COMPLETED evidence capture). |
| `-OutputPath <dir>` | Output root (default `.\Audit\diff`). |
| `-OutputMode` | `Console`/`JSON`/`HTML`/`Both`/`CSV` — controls the run summary; the two HTML diffs are always written. |

```powershell
# Morning run: capture today's snapshot and diff vs yesterday's, with CSVs
.\Scripts\Invoke-SPCampaignDiff.ps1 -CampaignNameContains 'Daily Attestation' -IncludeCsv

# Pin to a stable campaign id (recommended for a recurring campaign)
.\Scripts\Invoke-SPCampaignDiff.ps1 -CampaignId 'camp-7f3a...' -IncludeCsv

# Day-over-day diff PLUS one HTML per director to send out individually
.\Scripts\Invoke-SPCampaignDiff.ps1 -CampaignNameContains 'Daily Attestation' -PerDirector -IncludeCsv

# Separate per-day campaigns: diff today's against yesterday's (the two newest matches),
# with per-director reports of what access changed for each director's team
.\Scripts\Invoke-SPCampaignDiff.ps1 -CampaignNameContains 'Daily Attestation Manager' -CrossCampaign -PerDirector

# Week-over-week: compare this week's capture to last week's
.\Scripts\Invoke-SPCampaignDiff.ps1 -CampaignId 'camp-7f3a...' -Cadence Weekly

# Re-render this morning's vs yesterday's capture WITHOUT calling ISC
.\Scripts\Invoke-SPCampaignDiff.ps1 -CampaignId 'camp-7f3a...' -NoCapture
```

> **What counts as a "decision change".** Only a real flip between *decided* states —
> **APPROVE↔REVOKE** (access removed or re-granted). Transitions involving PENDING are
> **excluded**: APPROVE→PENDING just means "not re-reviewed yet" (the escalation chain handles
> that, it isn't an access change), and PENDING→decided is a first action, not a change from a
> prior decision. So the table picks up only users who **acted in the prior campaign** and whose
> access decision then changed. (New grants and removals are in the *added* / *removed* lists.)
>
> **Decision dates across campaigns.** The scope diff records *when* each decision was made
> (the ISC decision timestamp). A **decision change** row shows both sides —
> e.g. *John Doe · admin_xyz · APPROVE (2026-06-10) → REVOKE (2026-06-11)* — and a **first-time**
> grant shows the date it was decided. The same `Prev date` / `Curr date` / `Transition`
> (`APPROVE->REVOKE`) columns are in the scope **CSV**. In `-CrossCampaign` mode the report header
> labels each side by **campaign name + start date** (both snapshots are captured *now*, so the
> capture time is not a useful per-campaign date).
>
> **Freshness for long-lived ACTIVE campaigns.** The capture reuses the item cache (default 3 h
> TTL for ACTIVE campaigns). When laggards keep completing a campaign that stays open for days and
> you want an *authoritative* capture, force a fresh pull first
> (`Clear-SPAuditItemCache -CampaignId '<id>'`) or lower `Audit.CacheActiveTtlMinutes`. Then
> **validate the capture** with `Invoke-SPCacheValidate.ps1` (below) before trusting the diff.

> **`-VelocityAdvisory` — read before using.** This emits a separate, HTML-only
> `velocity-advisory-*.html` measuring per-reviewer decision *pace* (time-to-start, active
> span, decisions/minute, approval ratio) — the classic rubber-stamp shape is a fast,
> all-approve burst across many items. It is **opt-in**, **never written to CSV**, and every
> figure carries a mandatory caveat: **review pace is gameable and a fast pace is not proof
> of an improper review.** Use it only as a prompt for a *respectful conversation* about
> review quality — never as evidence of misconduct or an individual performance score. It
> needs ISC decision timestamps (usually present only on **signed/completed** campaigns); it
> degrades to "insufficient-timing-data" rather than guessing.

> **On the *privileged-approved* signal:** approving privileged access is often entirely
> legitimate. The count is a *conversation starter* for review quality — reviewed
> respectfully alongside review-velocity context — **never** an automatic finding. Snapshots
> live under `Audit.SnapshotPath` (toolkit-root anchored) and feed the KPI trend separately.

**Related:** `Invoke-SPCampaignTrendReport.ps1` (the rate trend over time),
`Invoke-SPWeeklyDigest.ps1` (week-over-week roll-up), the item cache (*Campaign filtering &
the item cache*), `Invoke-SPCacheValidate.ps1` (validate a capture before trusting the diff).

### `Invoke-SPCacheValidate.ps1`
**Purpose:** a fast, **HTML-free, read-only data-quality check** over a campaign **snapshot**
JSON (the diff/trend source of truth) or a raw **items cache** (`items-<id>.jsonl`). Use it to
answer *"did this run capture good data?"* before trusting a diff or report — it catches the
bad/partial runs that otherwise quietly feed a misleading report.

It auto-detects the file kind and flags, with **Error / Warn / Info** severity:
- blank **Decision / Source / Identity / Access** fields (the "approve with no date / blank
  source" class of bug), with the % populated;
- **decided-with-no-date** items (an APPROVE/REVOKE carrying no decision timestamp);
- **KPI vs item-count** mismatches and a `Meta.ItemCount` that disagrees with the items;
- **blank or duplicate** join keys (`identity|access|source`);
- an **empty capture** (0 items — an API hiccup / partial auth);
- a **partial item cache** (an `items-*.jsonl` with no `.meta.json` sidecar = an interrupted fetch).

| Parameter | Description |
|---|---|
| `-Path <file\|dir>` | A snapshot `.json`, an `items-*.jsonl`, or a **directory** (every snapshot + items cache beneath it is checked). Defaults to `Audit\snapshots`. |
| `-FieldCoverageWarnPct <n>` | Warn when a key field is populated on fewer than this % of items (default 90). |
| `-OutputMode` | `Console` (default) / `JSON` / `Both`. |

```powershell
# Validate one snapshot
.\Scripts\Invoke-SPCacheValidate.ps1 -Path '.\Audit\snapshots\camp-7f3a...\20260611-080000.json'

# Sweep every snapshot + items cache under a directory and flag any bad runs
.\Scripts\Invoke-SPCacheValidate.ps1 -Path '.\Audit\snapshots'

# Machine-readable, for a scheduled health gate (exit 1 if any ERROR-severity finding)
.\Scripts\Invoke-SPCacheValidate.ps1 -Path '.\Audit\snapshots' -OutputMode JSON
```

> **Exit codes:** `0` all files OK (warnings are still reported), `1` one or more files have an
> ERROR-severity finding, `2` path/parameter error. Read-only (CLI-005) — never writes or mutates.

**Related:** `Invoke-SPCampaignDiff.ps1` (produces the snapshots), the item cache (*Campaign
filtering & the item cache*), `Invoke-SPCacheDiagnostic.ps1` (broader scan across all cache types).

### `Invoke-SPCacheDiagnostic.ps1`
**Purpose:** comprehensive **cache integrity scanner** across all cache types -- item caches,
identity/account caches, campaign snapshots, trend JSONL, and governance metrics (output:
timestamped diagnostic log in `Reports\diagnostics\`).

- Scans every cache file in the toolkit: `items-*.jsonl` + `.meta.json` sidecars, `identities.jsonl`,
  `accounts.jsonl`, campaign snapshots, campaign-trend JSONL, governance metrics
- Detects: partial/interrupted caches (missing meta sidecar), stale caches past TTL, corrupt or
  unparseable JSON/JSONL lines, duplicate keys, PS 5.1 datetime auto-conversion artifacts,
  AccessId instability, baseline captures masquerading as scope additions, orphaned files,
  cross-snapshot key drift, and trend JSONL gaps
- Categorizes findings as ERROR, WARN, or INFO
- Read-only: never modifies any cache file

| Parameter | Description |
|---|---|
| `-OutputPath` | Directory for the diagnostic log (default `.\Reports\diagnostics`). |
| `-Verbose` | Show all findings in console (not just errors/warnings). |

```powershell
# Full diagnostic scan (log file only)
.\Scripts\Invoke-SPCacheDiagnostic.ps1

# Full scan with verbose console output
.\Scripts\Invoke-SPCacheDiagnostic.ps1 -Verbose
```

**Output:** timestamped log file in the diagnostics directory.
**Related:** `Invoke-SPCacheValidate.ps1` (focused snapshot/item validation with exit codes),
`Clear-SPAuditItemCache` / `Clear-SPIdentityCache` (remediation after diagnosis).

### `Invoke-SPTrendBackfill.ps1`
**Purpose:** one-time **trend JSONL hydration** from existing campaign snapshots -- populates
the campaign-trend JSONL files that V5 and the Campaign Trend Report use for multi-day
progression charts.

- Reads all snapshots in `Audit\Snapshots\` and generates trend points via `Save-SPCampaignTrendPoint`
- Safe to run multiple times (atomic append, deduplicates by timestamp)
- Intended for bootstrapping: after the initial backfill, daily V3/V4/V5 runs write trend
  points automatically

| Parameter | Description |
|---|---|
| `-SnapshotDir` | Override snapshot directory (default from config). |
| `-DaysBack <n>` | Only backfill snapshots from the last N days (default 90). |

```powershell
# Backfill from all snapshots within 90 days
.\Scripts\Invoke-SPTrendBackfill.ps1

# Backfill only the last 30 days
.\Scripts\Invoke-SPTrendBackfill.ps1 -DaysBack 30
```

**Output:** writes to `Audit\metrics\campaign-trend\{campaignId}.jsonl` (one file per campaign).
**Related:** `Invoke-SPCampaignTrendReport.ps1` (renders trend charts from the JSONL this script hydrates),
`Invoke-SPCampaignDiff.ps1` (produces the snapshots that this script reads).

### `Invoke-SPEntitlementHistory.ps1`
**Purpose:** the **decision timeline** for each identity+entitlement across **many** snapshots —
the multi-campaign generalization of the diff (which compares two). Answers *"how did
admin_xyz / John Doe move over time?"* (`APPROVE 6/8 → APPROVE 6/9 → REVOKE 6/11`) and *"who got
admin_xyz for the first time?"*. **Read-only, no API** — it walks the immutable snapshots already
on disk.

Two timeline modes:
- **default (cross-campaign):** one point per campaign whose snapshots match the name filter — the
  "separate daily campaigns" view.
- **`-WithinCampaign`:** every capture of **one** long-lived campaign (how it evolved as laggards
  and reviewers acted). Requires the filter to resolve to a single campaign.

By default it shows only timelines that **changed** (a decision flip, a first-time grant, or a drop
from scope); `-IncludeUnchanged` shows all. Output is one self-contained HTML report (grouped **by
entitlement** and/or **by identity** — chips coloured by decision, a red arrow marks each change)
plus an optional per-observation CSV.

| Parameter | Description |
|---|---|
| `-CampaignId` / `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Which campaigns' snapshots to walk (same precedence as elsewhere). |
| `-WithinCampaign` | Walk every capture of ONE campaign instead of one-per-campaign. |
| `-AccessName` / `-AccessId` / `-IdentityName` / `-IdentityId` | Focus on one entitlement and/or identity (name = substring, id = exact). |
| `-GroupBy` | `Entitlement` / `Identity` / `Both` (default `Both`). |
| `-IncludeUnchanged` | Also show timelines whose decision never changed. |
| `-MaxTimelines <n>` | Cap the output (most-changed first); prints how many were omitted. `0` = no cap. |
| `-SnapshotDir` / `-OutputPath` | Snapshot root (default `Audit\snapshots`) / output dir (default `Audit\history`). |
| `-IncludeCsv` | Also write the flat per-observation CSV. |
| `-OutputMode` | `Console` / `JSON` / `Both`. |

```powershell
# admin_xyz's decision timeline across every matching daily campaign, with a CSV
.\Scripts\Invoke-SPEntitlementHistory.ps1 -CampaignNameContains 'Daily Attestation Manager' -AccessName 'admin_xyz' -IncludeCsv

# Everything that changed for one person across the daily campaigns
.\Scripts\Invoke-SPEntitlementHistory.ps1 -CampaignNameContains 'Daily Attestation Manager' -IdentityName 'John Doe'

# How one long-lived campaign's decisions evolved across its own captures
.\Scripts\Invoke-SPEntitlementHistory.ps1 -CampaignId 'camp-7f3a...' -WithinCampaign
```

> Needs **&ge; 2 snapshots** to show change — capture one per active campaign on a schedule (via
> `Invoke-SPCampaignDiff.ps1`) so each builds a timeline. The join is the same stable
> `identity|access|source` key the diff uses (benefits from populated `AccessId`/`SourceId`).
> Read-only (CLI-005), no API. Exit `0` report written, `2` no matching snapshots, `5` error.

**Related:** `Invoke-SPCampaignDiff.ps1` (two-campaign diff + produces the snapshots),
`Invoke-SPCacheValidate.ps1` (validate the snapshots first).

### `Invoke-SPCampaignTrendReport.ps1`
**Purpose:** the **KPI trend report** for a recurring campaign — how its *rates* move over
**days / weeks / months**, answering *"is privileged access trending in a direction?"* Each
`Invoke-SPCampaignDiff` run appends one rate row to a per-campaign series; this script rolls
that series up and renders it.
**When to use:** after a few days/weeks of diff runs, to show leadership the direction of
travel (charts/tables) for privileged-approval rate, revoke rate, privileged share of scope,
and completion velocity.

> **Why rates, not counts.** Raw "privileged approved" counts rise just because scope grows
> as entitlements/sources onboard. The trend tracks **privileged approval rate**
> = approved ÷ (approved + revoked) *among privileged* — robust to scope growth. A rising
> rate is a **discussion prompt, not a finding** (direction-neutral ▲/▼). The trend is a
> *management/maturity view*, **not** certification evidence (the immutable snapshots are).

| Parameter | Description |
|---|---|
| `-CampaignId <id>` | The stable campaign id the diff runs used (required). |
| `-Granularity` | `Daily` / `Weekly` (default) / `Monthly` rollup. |
| `-DaysBack <n>` | Window in days (default 365). |
| `-Environment <name>` | Environment the series was captured under (defaults to `Global.EnvironmentName`). |
| `-OutputPath <dir>` | Output root (default `.\Audit\trend`). |
| `-OutputMode` | `Console`/`JSON`/`HTML`/`Both` — the HTML is always written. |

```powershell
.\Scripts\Invoke-SPCampaignTrendReport.ps1 -CampaignId 'camp-7f3a...' -Granularity Weekly
.\Scripts\Invoke-SPCampaignTrendReport.ps1 -CampaignId 'camp-7f3a...' -Granularity Monthly -DaysBack 730
```

> **Storage & retention.** The trend lives in a small per-campaign JSONL under
> `Metrics.CampaignTrendPath` (default `.\Audit\metrics\campaign-trend\{env}\{campaignId}.jsonl`),
> retained `Metrics.CampaignTrendRetentionDays` (default **1825** / 5 years) — the long-term
> record. Full snapshots are pruned at `Audit.SnapshotRetentionDays` (90 days), but the prune
> is **lifecycle-aware**: it never deletes a *signed / COMPLETED* (evidence) capture.
> Snapshots carry a `.sha256` sidecar and can be chained with
> `New-SPAuditEvidenceChain -IncludeSnapshots` for tamper-evidence.

> **Cross-campaign program trend.** `Invoke-SPCampaignTrendReport.ps1 -Program` aggregates
> *all* campaigns' series into a leadership "are we trending the right way as a whole" view:
> campaigns closing per period, privileged-approval direction, and completion movement across
> the program. It accumulates as diff/tracker runs append rows; closures show up as COMPLETED
> captures.

### `Invoke-SPCertTracker.ps1`
**Purpose:** the **executive Certification Progress Tracker** — a Domino's-style pipeline board
showing where every active campaign stands. Because campaigns are *almost always active and
incomplete*, it is **pace-centric**: the story is whether each campaign is *moving toward its
deadline*, not whether it hit 100%. Useful from **hour 8 to day 30**.
**When to use:** the daily/weekly leadership view of "what's moving, what's stuck, what's at risk."

Each campaign card shows: a 6-stage rail (Launched → In Review → Decisions Done → Signed Off →
Remediation → Closed) as context; **both** completion framings (reviewers-complete *and*
decisions-complete — leadership picks); **projected close vs deadline** (On track / At risk /
Behind) from decision velocity; momentum vs the prior capture; a burndown bar; and a pace line
(day N, velocity/day, items remaining, reviewers-not-started, privileged-pending, revocations-to-
remediate). Plus a program pipeline board (campaign count per stage) and RAG worst-first ordering.

| Parameter | Description |
|---|---|
| `-CampaignName*` / `-Status` / `-DaysBack` | Which campaigns to track (default ACTIVE+COMPLETING, 60 days). |
| `-Cadence` | Movement window: `Adjacent` (default) / `IntraDay` / `Daily` / `Weekly` / `Monthly`. |
| `-NoCapture` | Build the board from existing snapshots (don't call ISC). |
| `-EvidencePack` | **Also** emit the per-campaign **Attestation Evidence Pack** (below). |
| `-MaxCampaigns <n>` | Safety cap (default `Safety.MaxCampaignsPerRun` or 25). |
| `-OutputPath` / `-OutputMode` | Output root (default `.\Audit\tracker`) / run-summary format. |

```powershell
# The executive board for all active campaigns
.\Scripts\Invoke-SPCertTracker.ps1

# Board + the per-campaign attestation evidence packs (compliance/audit)
.\Scripts\Invoke-SPCertTracker.ps1 -EvidencePack -Cadence Daily
```

> **Attestation Evidence Pack (`-EvidencePack`).** The compliance/audit artifact the AD-port
> "access certification" report only *pretended* to be: it renders the **actual recorded**
> decisions — Identity · Access · Source · Privileged · **Decision** · **Reviewer** ·
> **Date** · **Justification** · **Remediation status** — per campaign, plus a revocation→closure
> section ("we said revoke; here's what was actually removed"). Works on partial/active campaigns
> (pending items are normal, not errors). Read-only.

### `Invoke-SPWeeklyDigest.ps1`
**Purpose:** a consolidated **weekly digest** — campaign activity, campaign health, identity
risk, reviewer performance, remediation tracking, and orchestrator reliability in one report.
**When to use:** weekly distribution to governance leadership.

| Parameter | Description |
|---|---|
| `-DaysBack <n>` | Window (default 7). |
| `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Filter campaigns by name — applied to **both** the current and prior period so the week-over-week comparison stays apples-to-apples (see *Campaign filtering & the item cache*). |
| `-Skip*` switches | Drop any section (`-SkipIdentityRisk`, `-SkipReviewerAnalysis`, …). |
| `-SendNotification` / `-NotifyRecipients` | Deliver via configured backends. |
| `-OutputMode` | `Console`/`HTML`/`JSON`/`Both`. |

```powershell
.\Scripts\Invoke-SPWeeklyDigest.ps1 -OutputMode HTML
```
**Related GUI:** Governance tab.

### `Invoke-SPDailyEvidenceReport.ps1`

> **Complementary versions** -- all coexist, produce separate output files, and can run
> in any combination. They are NOT sequential replacements.
>
> | Version | Script | Best for | Key feature |
> |---|---|---|---|
> | **V1** | `Invoke-SPDailyEvidenceReport.ps1` | Standalone daily compliance dashboard | 6-KPI tiles, Domino Tracker, Governance Confidence Score, evidence registers. Works for any campaign on any schedule. |
> | **V2** | `Invoke-SPDailyEvidenceReportV2.ps1` | Lean per-campaign audit evidence | Donut chart, source-aware remediation (Deprovisioned/Queued/Pending), decision register with justification. No KPI dashboard. |
> | **V3** | `Invoke-SPDailyEvidenceReportV3.ps1` | Day-over-day delta tracking | Everything V2 has + KPI dashboard + access change tracking (added/removed/changed) + reviewer timeliness aging. Requires recurring daily campaign model. |
> | **V4 / V4b** | `Invoke-SPDailyEvidenceReportV4.ps1` / `...V4b.ps1` | Cache-honest evidence engine + `daily-metrics.jsonl` | Undecided detection (`idNowAutoApproved`); reviewer accountability that stays honest across ACTIVE -> COMPLETED via a cert-to-reviewer roster sealed at ACTIVE state; writes the JSONL that V7 trends. |
> | **V7** | `Invoke-SPDailyEvidenceReportV7.ps1` | Calendar-day trending visualizer | Reads `daily-metrics.jsonl` (no API calls): completion progression, reviewer heatmap, velocity, compliance accountability. |
>
> **Quick decision:** Use V1 for "what is governance posture today?" Use V3 for "what
> changed since yesterday?" Use V2 for a clean audit artifact without KPI overhead. Use
> **V4/V4b + V7** for daily privileged-attestation programs that need reviewer-completion
> tracking that stays correct *after* a campaign closes (see the V4/V4b/V7 section below).

**Purpose:** a daily executive governance dashboard with six KPIs, a Governance Confidence
Score, a cascading-risk "Domino Tracker", and audit/IAG evidence registers. Designed to satisfy
**Step 6: Evidence and Reporting** of the IAM governance program -- a single report that
answers whether campaigns are completing, attestations are on time, revocations are being
enforced, remediation is timely, high-risk access is being reviewed, and reviewers are
performing responsibly.

**When to use:** daily, scheduled after the daily orchestrator. Also useful on-demand with
`-DaysBack 7` for a weekly evidence summary or `-CampaignNameContains 'Tuesday'` to scope to
a specific campaign day.

**KPI dashboard (above the fold -- one screen):**

| KPI | What It Measures | Green | Yellow | Red |
|---|---|---|---|---|
| Campaign Completion | % of review items decided | 95%+ | 80-94% | <80% |
| Past-Due Reviews | overdue + at-risk campaigns | 0 | 1-2 | 3+ |
| Revocations Executed | % provisioned within SLA | 95%+ | 80-94% | <80% or Failed |
| Remediation Timeliness | SLA compliance + aging buckets | 95%+, none >5d | 80-94% or 5-10d | <80% or >10d |
| High-Risk Exposure | high-risk identities with pending reviews | 0 | 1-3 | 4+ |
| Reviewer Health | % of reviewers in good standing | 0 at-risk | 1-2 at-risk | 3+ at-risk |

**Domino Tracker:** the six KPIs are shown as a causal chain
(Reviewer -> Completion -> Overdue -> Revocations -> Remediation -> Risk). When any KPI
degrades, downstream indicators are highlighted with a one-sentence narrative explaining
the cascading impact.

**Evidence sections (below the fold -- for compliance/auditors):**

| Section | Content |
|---|---|
| A. Campaign Completion | Per-campaign status, completion %, deadline status |
| B. Certifier Decisions | Decision register (identity, access, decision, reviewer, date) |
| C. Remediation Register | Revocation status, aging bucket chart, per-item SLA tracking |
| D. Past-Due Campaigns | Overdue/at-risk campaigns with bottleneck reviewers |
| E. High-Risk Pending | High-risk identities with unreviewed access items |
| F. Reviewer Performance | Reputation scores, tiers, rubber-stamp flags |

| Parameter | Description |
|---|---|
| `-DaysBack <n>` | Lookback window (default 1 for daily). Use 7 for weekly catch-up. |
| `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Campaign name filters (see *Campaign filtering & the item cache*). Example: `-CampaignNameContains 'Wednesday'` for all Wednesday campaigns. |
| `-SlaHours <n>` | Remediation SLA threshold in hours (default 48). |
| `-HighRiskThreshold <n>` | Identity risk score for "High" classification (default 70). |
| `-OutputMode` | `Console`/`HTML`/`JSON`/`Both`. |

```powershell
# Daily compliance dashboard (default 1-day window, console + HTML)
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -Token $token -OutputMode Both

# Scope to a specific day's campaigns
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -CampaignNameContains 'Tuesday' -DaysBack 7 -Token $token

# Full campaign name match with custom thresholds
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -CampaignName 'Daily Attestation Manager Campaign - Wednesday, June 11 2026' -SlaHours 24 -HighRiskThreshold 80 -Token $token -OutputMode Both

# Weekly evidence catch-up (last 7 days, all campaigns)
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -DaysBack 7 -Token $token -OutputMode HTML

# Prefix match for a campaign series
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -CampaignNameStartsWith 'Daily Attestation' -Token $token -OutputMode Both

# Dry run -- see what steps would execute without API calls
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -WhatIf

# JSON output for pipeline/automation consumption
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -CampaignNameContains 'Wednesday' -Token $token -OutputMode JSON
```

**Thresholds** are configurable in `settings.json` under the `DailyEvidence.Thresholds` section.
The script uses sensible defaults if the section is missing. See
[Foundations](00-foundations.md) for the settings reference.

**Output files:**
- `Audit\daily-evidence\daily-evidence-{timestamp}.html` -- self-contained HTML dashboard + evidence
- `Audit\daily-evidence\daily-evidence-audit.jsonl` -- append-only JSONL evidence trail (every run)

*Exit codes:* 0 all KPIs green + confidence A/B | 1 any KPI yellow or confidence C | 5 any KPI red, confidence D/F, or critical failure | 2/3/4 parameter/auth/config.

**Also available via GUI:** Governance tab > "Daily Evidence" button.

### `Invoke-SPDailyEvidenceReportV2.ps1`
**Purpose:** the **v2** daily certification evidence report — a leaner, leadership-grade rewrite of
the report above. It **drops** the six-KPI dashboard, the Governance Confidence Score, the Domino
Tracker, and the Past-Due / High-Risk / Reviewer-Performance registers, and presents only the
evidence that holds up in an audit. The original `Invoke-SPDailyEvidenceReport.ps1` is unchanged —
**run either**. Output: `daily-evidence-v2-*.html` (+ `daily-evidence-v2-audit.jsonl`), so it never
clobbers the v1 output.

**Layout (top to bottom):**

| Section | Content |
|---|---|
| Header | Report-generated date, period, aggregate decisions made. **No due date.** |
| Certification Scope | distinct users reviewed, entitlements tracked, privileged-access users, managers involved, sources evaluated |
| Executive Summary (per campaign) | status badge, reviewers signed-off, items decided, a decision-distribution **donut**, **Revoked Access — Removal Status** (Deprovisioned / Queued / Pending), and Key Indicators |
| A. Campaign Completion Evidence | cross-campaign table incl. Approved / Revoked / Pending |
| B. Reviewer Accountability | collapsible **Completed / Pending / Reassigned** per campaign (+ Reassigned From, Proof of Action) |
| Decision Summary | collapsible **Approved / Revoked (open) / Pending** — Identity, Account, Access (PRIV), **Source**, **Reviewer (manager)**, Decision Date, **Justification**, Remediation (**Deprovisioned** / **Queued for removal** / **Pending removal**) |

> **Source-aware removal wording (applies to every report that reports removals).** A finalised
> revoke means the *decision* is recorded, **not** that the access was always pulled at the source.
> The toolkit only counts a completed revoke as **Deprovisioned** when it is on a **connected
> Active Directory** source (where ISC actually performs the removal). A completed revoke on any
> other source (disconnected apps, manual / other connectors) is **Queued for removal** — recorded
> but fulfilled downstream and **not confirmed here**; an undecided revoke is **Pending removal**.
> The classification lives in one place (`Get-SPRevocationDisposition`) and drives the daily-evidence
> reports (v1 + v2), the campaign-audit executive summary, and the attestation evidence pack. The
> AD-vs-other split is keyed off the ISC item's `sourceType` (e.g. `Active Directory - Direct`).

Day-over-day / scope-change deltas are intentionally **not** here — they live in the campaign-diff
report (`Invoke-SPCampaignDiff.ps1`).

**Parameters:** same as `Invoke-SPDailyEvidenceReport.ps1` (`-DaysBack`, the `-CampaignName*`
filters, `-Token`, `-OutputMode`). Threshold/KPI params have no effect on the v2 HTML.

```powershell
# v2 daily evidence (default 1-day window)
.\Scripts\Invoke-SPDailyEvidenceReportV2.ps1 -Token $token -OutputMode HTML

# Scope to one campaign day
.\Scripts\Invoke-SPDailyEvidenceReportV2.ps1 -CampaignNameContains 'Thursday' -Token $token -OutputMode Both
```

> The Decision Summary's **Source / Reviewer / Justification** come straight from the ISC item:
> `sourceName` (incl. disconnected-app sources), the certification's reviewer (= the manager), and
> the item's `comments`. The `PRIV` badge is driven by the entitlement's privileged attribute, so it
> stays **adaptive** for quarterly mixed campaigns. Note: internally v2 still runs the legacy
> data-gathering steps, so `-OutputMode JSON`/console still emit the old KPI structure — a
> leaner-runtime trim is a planned follow-up.

**Output files:**
- `daily-evidence-{timestamp}.html` -- self-contained HTML executive dashboard + evidence
- `daily-evidence-audit.jsonl` -- append-only JSONL evidence trail (written every run for audit immutability)

*Exit codes:* 0 all KPIs green + confidence A/B | 1 any KPI yellow or confidence C |
5 any KPI red, confidence D/F, or critical failure | 2/3/4 parameter/auth/config.

**Related GUI:** Governance tab. **Related:** `Invoke-SPGovernanceMetrics` (time-series capture),
`Invoke-SPWeeklyDigest` (weekly narrative), `Invoke-SPGovernanceReport` (full audit package).

### `Invoke-SPDailyEvidenceReportV3.ps1`
**Purpose:** a **day-over-day DELTA** evidence report — v2's executive layout, but the body answers
*"what changed since the previous day's campaign?"*. It captures today's campaign snapshot and diffs
it **cross-campaign** against the most-recent **different** campaign in the same series (the
new-campaign-per-day model), reusing the same engine as `Invoke-SPCampaignDiff.ps1`.

Use it for recurring daily attestations where **each day is its own campaign**. Run it with a
`-CampaignName*` filter that matches the series (e.g. `-CampaignNameContains 'Daily Attestation'`) so
the prior campaign resolves to yesterday's, not an unrelated one. It captures a snapshot each run
(`-NoCapture` to re-render offline from existing snapshots).

| Section | Content |
|---|---|
| Header | report-generated date + "vs `<prior campaign>`"; baseline banner on first run |
| Certification Scope + Executive Summary | *as v2* (today's full context: donut, Removal-Status card, Key Indicators) |
| A. Campaign Completion Evidence | *as v2* |
| **Access Changes Since Last Campaign** | **Newly added access** (net-new to SailPoint — the identity was NOT in the entitlement before, approved or pending); **Removed entirely** (disappeared without a formal revoke); **Revoked but still present** (the revoke isn't getting fulfilled — split **Removal failed / connected AD** vs **Queued / disconnected** per the source-aware policy) |
| B. Reviewer Accountability | **net-new items only**, grouped by reviewer: Completed (decided) / Pending / Reassigned |
| Decision Summary | **net-new items only** — Approved / Revoked / Pending — plus a **Changed** register (APPROVE↔REVOKE flips on *existing* access) |
| Footnote | entitlements **persistently PENDING across ≥2 campaigns** (separate cycles, not just captures) |

> **Net-new** means the stable key `identity\|access\|source` was **absent in the prior campaign's
> snapshot**. The "Revoked but still present" tracker reuses `Get-SPRevocationDisposition`'s source
> policy: a still-present revoke on connected **AD** is a *removal failure* (red — should be gone),
> while a disconnected/other source is *queued* (amber — downstream/manual, not confirmed here). The
> new delta the report adds to the diff engine is `Scope.PersistedRevokes` (revoked-before,
> still-present), alongside the existing Added / Removed / Changed.

```powershell
# Day-over-day delta for a recurring daily series (captures today's snapshot, diffs vs yesterday's)
.\Scripts\Invoke-SPDailyEvidenceReportV3.ps1 -CampaignNameContains 'Daily Attestation' -Token $token -OutputMode HTML

# Re-render offline from snapshots already on disk (no capture, no API mutation)
.\Scripts\Invoke-SPDailyEvidenceReportV3.ps1 -CampaignNameContains 'Daily Attestation' -NoCapture -Token $token
```

**Output:** `daily-evidence-v3-{timestamp}.html` (+ `daily-evidence-v3-audit.jsonl`). **Related:**
`Invoke-SPCampaignDiff.ps1` (the scope-diff this hybridizes), `Invoke-SPDailyEvidenceReportV2.ps1`
(the current-state sibling — both remain available).

### `Invoke-SPDailyEvidenceReportV4.ps1` / `V4b.ps1` / `V7.ps1`
**Purpose:** the **cache-honest daily-evidence pipeline** for daily (or long-running)
privileged-attestation programs that need reviewer-completion tracking which stays correct **after a
campaign closes**. **V4 / V4b** are the data engine — they fetch from ISC, render per-campaign HTML
evidence, and write `Audit\metrics\daily-metrics.jsonl`. **V7** is the trending visualizer — it reads
that JSONL (no API calls) and renders calendar-day charts. V4b is a bug-fixed fork of V4 (donut
chart, N/A-reviewer warning, item-level reviewer %); both take the same parameters and write the same
JSONL. Run one of V4/V4b, then V7.

```
ISC API  -->  V4 / V4b  -->  items cache + snapshots + daily-metrics.jsonl  -->  V7 (calendar-day charts)
                       \-->  per-campaign HTML evidence report
```

> **Known limitation -- "Newly Decided" and reassignments (fixed in V4g/V8, not here).**
> V4/V4b compute "Newly Decided -- Approved Since Prior Campaign" from a two-campaign
> snapshot diff gated by a recurrence heuristic that reads a SINGLE-campaign run as
> "not recurring" -- exactly the daily-attestation case -- so routine catch-up approvals
> of items that sat pending yesterday get flagged as newly decided. The persistent
> entitlement state DB in **V4g/V8** is the authoritative source: it only reports
> OBSERVED PENDING/UNDECIDED -> decided transitions, never first-seen-already-decided
> items, which also makes it reassignment-safe (an item the original reviewer already
> approved enters the DB as APPROVE, so a delegate's later re-approval is invisible).
> Prefer V4g (or V8) for daily newly-decided evidence; treat the V4/V4b section as
> legacy.

**Why this pipeline exists — honest completion tracking across ACTIVE and COMPLETED.** After a
campaign is force-completed, ISC's API *inflates* the data: it auto-approves leftover items (marking
them `idNowAutoApproved`), reports `decisionsMade = decisionsTotal`, and sets every certification to
`phase: SIGNED` — so a naive read claims *everyone* finished. The pipeline refuses that story:

- **Item-level truth, not cert sign-off.** "Who didn't complete" is derived from the items that were
  genuinely **Undecided** when the campaign was last captured ACTIVE — never from cert `phase`.
- **Sealed cert-to-reviewer roster.** The assigned-reviewer roster is captured and **sealed at ACTIVE
  state**, and undecided items are attributed to the **cert-assigned reviewer** (keyed on ISC
  identity ID). A COMPLETED campaign therefore names the *actual accountable reviewer* instead of
  collapsing every undecided item into a single `(Unassigned)` row.
- **Seal-on-transition.** When a campaign that was cached ACTIVE flips to COMPLETED, its cache is
  sealed permanent — the honest ACTIVE-state data is preserved and never overwritten by ISC's
  post-completion inflation.
- **Unverified-provenance banner (warning).** If a campaign is **first seen *after* it already
  COMPLETED** (no ACTIVE-state capture ever ran), the report renders a red "no active-state capture —
  completion unverified" banner rather than silently trusting ISC's post-close numbers.
  **Operational rule:** schedule V4/V4b to run **while campaigns are ACTIVE** (after the daily
  orchestrator) so every campaign gets an honest pre-close capture.
- **Every non-completed reviewer is named -- with the reason.** The COMPLETED accountability lists not
  just reviewers who left items **Undecided**, but also those who **decided everything yet never signed
  off** (finished-but-unsigned / auto-closed) -- each row states which -- so a reviewer who did all the
  work but never finalized no longer disappears from the report.
- **A force-close is not a sign-off.** An ISC *administrative* force-signature (`signedBy` is a system
  identity, not the reviewer) is **excluded** from the genuine reviewer-completion count, so a
  force-closed campaign shows the honest "0 of N reviewers signed off", never a green "N of N".
- **The COMPLETED badge tells the truth.** When a campaign closed with work outstanding, the status
  carries a "Closed with incomplete work -- N of M reviewers signed off, X items never manually
  decided" qualifier, so a green COMPLETED never reads as a clean pass. Reviewer-% is rendered the same
  across the exec summary, Section A, and the KPI card, and decision dates never show the campaign's
  created timestamp in place of a real decision time.

| Parameter (V4 / V4b) | Description |
|---|---|
| `-DaysBack <n>` | Lookback window (default 1). |
| `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Campaign name filters. |
| `-Status` | Restrict to campaign states: STAGED / ACTIVE / COMPLETING / COMPLETED. |
| `-NoCache` | Fetch fresh from ISC but **do not** read or overwrite the cache (compare fresh vs cached). |
| `-RefreshCache` | Fetch fresh **and** overwrite the cache (after reviewers sign off; real-time numbers + updated cache). |
| `-PerRunDay` | **Opt-in** time axis. Default `captureDate` = the campaign's own *created* date (campaign-to-campaign axis — correct for recurring daily campaigns). `-PerRunDay` uses the *run* date, giving true per-day ACTIVE progression for a **single long-running** campaign. |
| `-NoCapture` | Re-render from existing snapshots without capturing a new one. |
| `-OutputMode` | `Console`/`HTML`/`JSON`/`Both`. |

| Parameter (V7) | Description |
|---|---|
| `-DaysBack <n>` | Trend window in days. |
| `-StartDate` / `-EndDate` | Exact `yyyy-MM-dd` range (takes precedence over `-DaysBack`). |
| `-OutputMode` | `Console`/`HTML`/`Both`. |

```powershell
# Daily: V4b generates evidence + JSONL (honest reviewer accountability; uses cache if valid)
.\Scripts\Invoke-SPDailyEvidenceReportV4b.ps1 -CampaignNameContains 'Daily Attestation' -OutputMode Both -Token $token

# After reviewers signed off mid-day -- refresh the cache with live numbers
.\Scripts\Invoke-SPDailyEvidenceReportV4b.ps1 -CampaignNameContains 'Daily Attestation' -RefreshCache -Token $token

# A single long-running quarterly campaign captured daily -- true per-day progression
.\Scripts\Invoke-SPDailyEvidenceReportV4.ps1 -CampaignName 'Q3 Privileged Review' -PerRunDay -Token $token

# Trend the last 18 days from the JSONL (no API calls)
.\Scripts\Invoke-SPDailyEvidenceReportV7.ps1 -DaysBack 18 -OutputMode Both

# Trend an exact date range
.\Scripts\Invoke-SPDailyEvidenceReportV7.ps1 -StartDate '2026-06-15' -EndDate '2026-06-19' -OutputMode Both
```

> **Optional — near-deadline cache freshness.** By default the ACTIVE-campaign item cache uses a
> fixed TTL (`Audit.CacheActiveTtlMinutes`, default 180 min). To capture a fresher final picture as a
> deadline nears, enable `Audit.NearDeadlineCapture` in `settings.json`: `Enabled` (default `false`),
> `WindowMinutes` (default 1440 = 24 h before deadline), and `TtlMinutes` (default 15 — the shrunk
> TTL inside the window; it only ever *shortens* the effective TTL, never lengthens it).

**Output:** `daily-evidence-v4{,b}-{timestamp}.html` (plus a `_fresh.html` variant under `-NoCache`),
`daily-evidence-v7-{prefix}-{timestamp}.html`, and `Audit\metrics\daily-metrics.jsonl`. For the
exhaustive per-section tables and the full ISC-behaviour handling matrix, see
[Reporting & Analytics](07-reporting-analytics.md).

### `Invoke-SPDailyEvidenceReportV7c.ps1`
**Purpose:** extends V7 with two visualization features -- the **Reviewer Engagement Heatmap**
(C/P/M/U daily grid) and the **Entitlement State Summary** (honest decision distribution via
SP.CampaignSeries). Output: `daily-evidence-v7c-{prefix}-{timestamp}.html`.

- **15 chart sections** (V7 has 13) -- all V7 charts plus:
  - Chart 14: Reviewer Engagement Heatmap -- daily C/P/M/U status per reviewer, sorted by
    engagement score, with category labels (Always Complete through Chronic Non-Compliance)
  - Chart 15: Entitlement State Summary -- stacked bar of genuinely Approved / Revoked /
    Undecided (auto-approved) items, using SP.CampaignSeries honest classifier
- **Prerequisite guard** -- clear "run V4b first" message when daily-metrics.jsonl is missing
- **Data coverage warning** -- alerts when actual date span is less than half the requested window
- Read-only: reads daily-metrics.jsonl + optional rich cache; never calls ISC API

> **Pipeline:** `Invoke-SPDailyEvidenceReportV4b.ps1` (export from ISC, writes JSONL) -->
> `Invoke-SPDailyEvidenceReportV7c.ps1` (visualize from JSONL). Run V4b daily while campaigns
> are ACTIVE to accumulate multi-day data points.

| Parameter | Description |
|---|---|
| `-DaysBack <n>` | Lookback window in days (default 7). |
| `-StartDate` / `-EndDate` | Exact date range (yyyy-MM-dd), takes precedence over -DaysBack. |
| `-CampaignNameContains` | Substring filter on campaign name (case-insensitive). |
| `-Status` | ACTIVE, COMPLETED, or COMPLETING filter. |
| `-OutputPath` | Output directory for HTML file. |
| `-OutputMode` | Console / HTML / Both (default Both). |
| `-IncludeSuspect` | Include suspect (pre-fix inflated) JSONL records. |
| `-ShowPrerequisites` | Display the data pipeline prerequisites and exit. |

```powershell
# Last 14 days, all campaigns
.\Scripts\Invoke-SPDailyEvidenceReportV7c.ps1 -DaysBack 14

# 30-day trend for Q2 campaigns
.\Scripts\Invoke-SPDailyEvidenceReportV7c.ps1 -DaysBack 30 -CampaignNameContains 'Q2'

# Show what scripts to run before V7c can generate a report
.\Scripts\Invoke-SPDailyEvidenceReportV7c.ps1 -ShowPrerequisites
```

**Output:** `daily-evidence-v7c-{prefix}-{timestamp}.html`.
**Related:** `Invoke-SPDailyEvidenceReportV7.ps1` (base, 13 charts),
`Invoke-SPDailyEvidenceReportV4b.ps1` (upstream data source).

### `Invoke-SPDailyEvidenceReportV4c.ps1`
**Purpose:** the **series-aware, honest "newly attested" decision-transition** report over the rich
audit cache (output `daily-evidence-v4c-{timestamp}.html`). Where V4/V4b answer *"who hasn't finished
THIS campaign?"*, V4c answers *"across a recurring campaign FAMILY, who got genuinely attested for the
FIRST time this period, who is still never decided, and what changed?"* — by walking N chronological
instances of a recurring series, not an arbitrary two-snapshot prior. It is **read-only**: it reads
ONLY the rich cache (`items-<id>.jsonl` + `items-<id>.meta.json` + `roster-<id>.json`) and never calls
ISC, never starts the live mock, never opens a GUI.

**Auto-derivation (the series grouping).** V4c derives recurring series automatically: it strips the
variable temporal token from each campaign name — daily date (`2026-06-30`), quarter (`1Q2026` /
`Q1 2026` / `Q1-2026` / `2026 Q1`), month-year (`Jun 2026`), or trailing year — and groups by a
**normalized stem** that is robust to human spacing / separator / case variances. So
`Daily Attestation Manager Campaign - 2026-06-30` and `Daily Attestation Manager Campaign -2026-06-29`
(and en-dash / double-spaced hand-typed variants) all collapse to **one** series. Derivation is
deterministic and explainable (it is audit evidence), so it honors two **override guards** when a
particular family of names would mis-split, plus an **opt-in fuzzy near-match**:

- `-SeriesName` (alias `-SeriesStem`) — force an explicit stem instead of auto-derivation.
- `-SeriesPattern` — supply your own temporal regex instead of the built-in ladder.
- `-SimilarityThreshold` — **opt-in** Levenshtein near-match; **default `0` = OFF** (exact-match
  grouping only). When `> 0`, near-identical stems are consolidated and the merge is **logged as
  audit evidence**.

**Honesty doctrine (the same shared classifier as V4/V4b).** V4c reuses the single shared honest
classifier, so the headline cannot be gamed:

- A genuine reviewer Approve/Revoke stays Approved/Revoked, but **pending OR auto-approved-at-close
  (`idNowAutoApproved`) is demoted to Undecided** — NEVER counted as a genuine approval. A prior
  COMPLETED instance's auto-approve therefore does **not** mask a later genuine first-time approval.
- **"Newly attested" = the FIRST genuine approval** of each identity+entitlement in the window; items
  already genuinely approved in an earlier instance are **AlreadyAttestedEarlier** and **excluded from
  the headline**.
- COMPLETED instances are attributed to the **cert-ASSIGNED reviewer** off the **sealed roster** (never
  `item.reviewedBy` when null), so a closed campaign names the accountable reviewer.
- **Unverified provenance** (a campaign first seen only after it COMPLETED) is propagated and, by
  default, **EXCLUDED from the headline**; pass `-IncludeUnverified` to surface those items with a badge.

| Parameter | Description |
|---|---|
| `-SeriesName` (alias `-SeriesStem`) | Override guard: force an explicit series stem instead of auto-derivation. |
| `-SeriesPattern` | Override guard: a user-supplied temporal regex used instead of the built-in ladder. |
| `-SimilarityThreshold <0..1>` | Opt-in fuzzy near-match. Default `0` = OFF (exact match only); the merge is logged as audit evidence. |
| `-MinInstances <n>` | Minimum instances for a family to count as a "series" (default `2`). |
| `-IncludeUnverified` | Include Unverified-provenance items in the headline (rendered with a badge) instead of excluding them. |
| `-CachePath` (alias `-Path`) | Override the rich-cache directory (defaults to the configured Audit cache). |
| `-OutputPath` | Output directory (defaults to the daily-evidence subdir). |
| `-OutputMode` | `Console`/`JSON`/`HTML`/`Both` (default `Both`). |

```powershell
# Auto-derive every recurring series from the cache and render the delta (read-only)
.\Scripts\Invoke-SPDailyEvidenceReportV4c.ps1

# Force a single series stem and write only the HTML report
.\Scripts\Invoke-SPDailyEvidenceReportV4c.ps1 -SeriesName 'Daily Attestation Manager Campaign' -OutputMode HTML

# Opt-in fuzzy stem merge for genuine typos; include Unverified items with a badge
.\Scripts\Invoke-SPDailyEvidenceReportV4c.ps1 -SimilarityThreshold 0.15 -IncludeUnverified
```

> **V4c REPLACES the cross-campaign snapshot scope-diff for RECURRING series — and why.** The snapshot
> scope-diff (`Invoke-SPCampaignDiff.ps1` / the V3 hybrid) compares exactly **two** campaign snapshots
> picked as "current" and an **arbitrary prior**. For a recurring daily/quarterly family that framing
> distorts the truth two ways: it depends on *which* prior you happen to pick, and it trusts the raw
> snapshot — so a COMPLETED instance's `idNowAutoApproved` auto-approve inflation reads as a real
> approval. V4c is **series-aware** (it walks every chronological instance of the family, not a single
> 2-snapshot prior) and **honest** (it reads the rich cache through the shared classifier, so the
> arbitrary-prior pick and the COMPLETED auto-approve inflation cannot distort the "newly attested"
> headline). This is **ADDITIVE**: the snapshot scope-diff stays intact for genuinely **different**
> campaigns — V4c is the recurring-series analysis alongside it, not a removal of it.

**Output:** `daily-evidence-v4c-{timestamp}.html` (plus a `.json` sidecar under `-OutputMode Both`).
**Related:** `Invoke-SPDailyEvidenceReportV4b.ps1` (single-campaign honest completion — the data engine
whose cache V4c reads), `Invoke-SPCampaignDiff.ps1` (the snapshot scope-diff V4c supersedes for
recurring series, retained for different-campaign diffs).

### `Invoke-SPDailyEvidenceReportV4e.ps1`
**Purpose:** **THE unified daily-evidence report for recurring campaign series** (output
`daily-evidence-v4e-{timestamp}.html`). It fuses two views in one honest report off the rich audit cache,
**superseding V4b's snapshot scope-diff for recurring series**:

- **Single-day per-campaign completion (NEWEST instance, honest).** A V4b-faithful `.execbox` panel for the
  newest instance in the series: status, **Items Decided X/Y**, **Reviewers Signed Off X/Y** (genuine
  sign-off — admin force-close is NOT a sign-off), a newest-instance **decision-distribution donut**
  (Approved / Revoked / Undecided), **Revoked Access — Removal Status** (source-aware:
  Deprovisioned / Queued / Pending), and **Key Indicators**.
- **Multi-day series attestation.** **Section A** is a per-instance completion breakdown table — one row per
  instance (Total Items, Approved, Revoked, Undecided, Items Decided %, Reviewer %, Created, Completed) —
  and **Section B** the reviewer accountability rollups (newly-attested / persistently-undecided by
  reviewer), with the **Decision Summary** detail and Key Indicators carrying the cross-instance deltas.

Every surface counts from the SAME honest/gated set (exec box, donut, Section A, Section B, Key Indicators,
JSON, console) so the numbers reconcile; the newest Section A row's Items Decided / Total matches the exec
box byte-for-byte. V4e runs the SAME series engine as V4c/V4d (`Get-SPCachedCampaignSeries` for
variance-tolerant auto-derivation + `Get-SPSeriesAttestationDelta` for the honest cross-instance
classification) and honors the SAME **honesty doctrine** — rendered in **byte-faithful V4b chrome** (the
gradient header, the **Certification Scope** block, the `.execbox` Executive Summary, the **Section A**
`table.report`, the **Section B** tables, the **Decision Summary** detail, and the `.footer`). It is
**read-only** (no `SupportsShouldProcess`, CLI-005): it reads ONLY the rich cache and never calls ISC,
never starts the live mock, never opens a GUI.

V4e **DROPS the V4b per-campaign machinery** that is meaningless for a recurring-series attestation view:
the 6 KPIs (Completion / Overdue / Revocations / Remediation / High-Risk / Reviewer Health), the
Governance Confidence score, the Domino Chain, the cross-campaign scope-diff snapshot, and the
`daily-metrics.jsonl` write. Only the series-attestation data is rebound onto the V4b section chrome.

> **Skin lineage.** `V4c = analytics look`, `V4d = interim skin`, `V4e = V4b-faithful chrome`. All three
> render the SAME honest series-attestation data off the SAME engine; they differ ONLY in visual chrome.
> V4e is **ADDITIVE** — V4c and V4d stay intact.

Parameters are identical to V4c:

| Parameter | Description |
|---|---|
| `-SeriesName` (alias `-SeriesStem`) | Override guard: force an explicit series stem instead of auto-derivation. |
| `-SeriesPattern` | Override guard: a user-supplied temporal regex used instead of the built-in ladder. |
| `-SimilarityThreshold <0..1>` | Opt-in fuzzy near-match. Default `0` = OFF (exact match only); the merge is logged as audit evidence. |
| `-MinInstances <n>` | Minimum instances for a family to count as a "series" (default `2`). |
| `-Window <n>` (alias `-DaysBack`) | Narrow each series to the newest `n` instances. Default `0` = full window (all instances); `-Window 2` = today vs yesterday. The newest instance is ALWAYS retained. |
| `-IncludeUnverified` | Include Unverified-provenance items in the headline (rendered with a badge) instead of excluding them. |
| `-CachePath` (alias `-Path`) | Override the rich-cache directory (defaults to the configured Audit cache). |
| `-OutputPath` | Output directory (defaults to the daily-evidence subdir). |
| `-OutputMode` | `Console`/`JSON`/`HTML`/`Both` (default `Both`). |

```powershell
# Auto-derive every recurring series and render the unified daily-evidence report (read-only)
.\Scripts\Invoke-SPDailyEvidenceReportV4e.ps1

# Force a single series stem and write only the HTML report
.\Scripts\Invoke-SPDailyEvidenceReportV4e.ps1 -SeriesName 'Daily Attestation Manager Campaign' -OutputMode HTML

# Narrow each series to today vs yesterday (newest two instances; newest always retained)
.\Scripts\Invoke-SPDailyEvidenceReportV4e.ps1 -Window 2

# Opt-in fuzzy stem merge for genuine typos; include Unverified items with a badge
.\Scripts\Invoke-SPDailyEvidenceReportV4e.ps1 -SimilarityThreshold 0.15 -IncludeUnverified
```

**Output:** `daily-evidence-v4e-{timestamp}.html` (plus a `.json` sidecar under `-OutputMode Both`).
**Related:** `Invoke-SPDailyEvidenceReportV4c.ps1` (the analytics-look sibling -- same engine/data),
`Invoke-SPDailyEvidenceReportV4b.ps1` (the chrome source V4e reproduces AND the data engine whose rich
cache it reads).

### `Invoke-SPDailyEvidenceReportV4f.ps1`
**Purpose:** V4e plus the **Approved Items First-Approval Timeline** -- tracks WHEN each
currently-approved grant was first genuinely approved across the series window, and WHICH
grants became "newly approved" mid-window (output `daily-evidence-v4f-{timestamp}.html`).

- Same series-attestation engine as V4c/V4e (read-only, no ISC API calls)
- Adds per-item first-genuine-approval tracking: which instance first approved each grant
- Shows mid-window "newly approved" grants that transitioned from Undecided to Approved
- V4b visual family chrome (consistent look with V4/V4b reports)

| Parameter | Description |
|---|---|
| `-SeriesName` | Override series stem for grouping (alias `-SeriesStem`). |
| `-SeriesPattern` | Override temporal regex for series key extraction. |
| `-CampaignName` | Exact campaign name filter. |
| `-CampaignNameStartsWith` | Campaign name prefix filter. |
| `-CampaignNameContains` | Campaign name substring filter (case-insensitive). |
| `-SimilarityThreshold` | 0..1 string distance threshold (default 0 = OFF). |
| `-MinInstances <n>` | Minimum instances for a series (default 2). |
| `-Window <n>` | Lookback window (alias `-DaysBack`; default 0 = full). |
| `-IncludeUnverified` | Include instances captured while COMPLETED (unverified provenance). |
| `-CachePath` | Override cache directory (alias `-Path`). |
| `-OutputPath` | Output directory. |
| `-OutputMode` | Console / JSON / HTML / Both (default Both). |

```powershell
# First-approval timeline for all series with 3+ instances
.\Scripts\Invoke-SPDailyEvidenceReportV4f.ps1 -MinInstances 3

# Filter to a specific recurring campaign
.\Scripts\Invoke-SPDailyEvidenceReportV4f.ps1 -CampaignNameContains 'AD Daily'
```

**Output:** `daily-evidence-v4f-{timestamp}.html` (plus `.json` sidecar under `-OutputMode Both`).
**Related:** `Invoke-SPDailyEvidenceReportV4e.ps1` (base engine without first-approval timeline),
`Invoke-SPDailyEvidenceReportV4b.ps1` (upstream cache writer).

### `Invoke-SPDailyEvidenceReportV4g.ps1`
**Purpose:** **V4 with the persistent entitlement state database** -- the authoritative engine for
"Newly Decided" and re-approval evidence (output `daily-evidence-v4g-{timestamp}.html`). Same
fetch/render pipeline and parameters as V4/V4b, plus per-entitlement state tracked across campaign
instances in `entitlement-state.jsonl` with four honest states: `APPROVE`, `REVOKE`, `PENDING`
(ISC decision null), `UNDECIDED` (auto-closed `idNowAutoApproved` -- the reviewer never acted).

> **Naming note:** this script briefly shipped as "V4c" on 2026-07-16, overwriting the original
> read-only series-attestation V4c; both now exist under their own names.

**Why the state DB matters (vs the V4/V4b snapshot diff):**
- **Newly Decided = observed transitions only.** An item is newly decided only when the DB actually
  SAW it PENDING/UNDECIDED and then saw it decided. First-seen-already-decided items are excluded --
  the decision may be months old.
- **Baseline-safe.** The first run over a fresh cache reports nothing as newly decided; it just
  seeds the DB.
- **Reassignment-safe.** Items are keyed identity + access NAME + source (ISC regenerates AccessIds
  on reassignment), and an item the original reviewer already approved enters the DB as APPROVE --
  a delegate's later re-approval of it is not "newly approved".
- **Re-Approved After Revoke register.** Observed REVOKE -> APPROVE transitions render as their own
  collapsible (identity, access, source, re-approving reviewer, revoked-on and re-approved-on days,
  both instance-dated) -- the re-grant governance signal, kept separate from Newly Decided.
- **All dates are the campaign instance's own day**, never the processing day -- a bootstrap over
  months of cache does not stamp historical decisions with today.
- The legacy diff-based Newly Decided is NOT collected in V4g (its `newlyDecidedCount` in
  daily-metrics.jsonl is always 0); prior-snapshot selection only considers campaigns that started
  BEFORE the current one, so a run containing both today's and yesterday's instances can never diff
  backwards.
- **Crash-safe on long runs.** State tracking checkpoints both state files every 10 instances
  (with a `[checkpoint]` heartbeat showing count + elapsed minutes); a killed multi-hour
  month-scale run loses at most the last batch, and the restart skips already-processed terminal
  instances. Applies to every state-tracking caller (V4g, V8 auto-refresh, Update-SPStateFiles).

**Cross-check:** `Invoke-SPDailyEvidenceReportV4f.ps1` computes first-genuine-approval timelines from
the cache through an independent engine -- run both over the same window and the "newly
approved/attested" sets should agree; disagreement localizes a bug. NOTE: V4f is series-engine
based, so it takes the common campaign filters (`-CampaignName` / `-CampaignNameStartsWith` /
`-CampaignNameContains`, added for parity) plus `-DaysBack` as an alias of `-Window` (newest N
INSTANCES per series, not calendar days). Its `-SeriesName` is NOT a filter -- it is an override
guard that forces a stem onto every cached campaign.

```powershell
.\Scripts\Invoke-SPDailyEvidenceReportV4f.ps1 -CampaignNameStartsWith 'daily attestation' -DaysBack 18
```

```powershell
# Daily run (API capture + state DB update + HTML)
.\Scripts\Invoke-SPDailyEvidenceReportV4g.ps1 -CampaignNameStartsWith 'daily attestation'

# Re-render from existing snapshots/cache without calling ISC (state DB still updates, idempotently)
.\Scripts\Invoke-SPDailyEvidenceReportV4g.ps1 -CampaignNameStartsWith 'daily attestation' -NoCapture
```

**Related:** `Invoke-SPDailyEvidenceReportV8.ps1` (fast renderer over the same state files),
`Tests\SP.EntitlementState.Tests.ps1` (ES-001..ES-022 state-machine contract, incl. re-approval).

### `Update-SPStateFiles.ps1`
**Purpose:** updates (or bootstraps) the persistent entitlement and reviewer state JSONL
files from the rich audit cache. Uses `SP.CampaignSeries` (the same honest classifier as
V4e) to classify every cached item, then persists the results to
`{Metrics.Path}/entitlement-state.jsonl` and `{Metrics.Path}/reviewer-state.jsonl`.

**Delta mode** (default): skips campaign instances already recorded in the state files'
`processedInstances` set. Daily runs complete in ~30 seconds.
**Bootstrap mode** (`-Force`): reprocesses ALL cached campaigns from scratch. Use on first
run or to rebuild after cache changes. Takes 2-5 minutes depending on cache size.

> **V8 auto-refreshes** -- you do not need to run this script manually before V8.
> V8 detects stale/missing state files and calls the same update logic internally.
> This script exists for explicit control: forced rebuilds, CI/CD pipelines, or
> pre-warming state before running V8.

| Parameter | Description |
|---|---|
| `-Force` | Ignore processedInstances and reprocess ALL cached campaigns (bootstrap/rebuild). |
| `-CachePath <dir>` | Override the rich-cache directory (defaults to the configured Audit cache). |
| `-MetricsPath <dir>` | Override the metrics directory (defaults to `Metrics.Path` from settings.json). |
| `-ConfigPath <file>` | Override settings.json path. |

```powershell
# Delta update (default -- process only new campaign instances)
.\Scripts\Update-SPStateFiles.ps1

# Bootstrap from scratch (first run or rebuild)
.\Scripts\Update-SPStateFiles.ps1 -Force

# Custom cache location
.\Scripts\Update-SPStateFiles.ps1 -Force -CachePath C:\AuditExport\cache
```

**Output:** updates two JSONL files in the metrics directory:
- `entitlement-state.jsonl` -- one line per IdentityId|AccessId|SourceId pair (~500KB-1.5MB)
- `reviewer-state.jsonl` -- one line per reviewer (~50-200KB)

**Related:** `Invoke-SPDailyEvidenceReportV8.ps1` (the fast report that reads these files),
`Invoke-SPDailyEvidenceReportV4g.ps1` (the API-driven KPI report that also feeds the
state database -- briefly shipped under the V4c name; the original read-only series
V4c is unchanged and documented above).

### `Invoke-SPDailyEvidenceReportV8.ps1`
**Purpose:** fast evidence report powered by the persistent state files
(output `daily-evidence-v8-{timestamp}.html`). Runs in under 30 seconds because it
reads pre-computed state instead of reprocessing the raw cache.

**Self-contained:** V8 auto-detects stale or missing state files and refreshes them
from the cache before rendering (this REWRITES the two state files -- pass
`-NoRefresh` for a guaranteed read-only run). No manual `Update-SPStateFiles.ps1`
step required.

**Scope semantics (honesty):** Sections 1, 3-7 show the CURRENT CUMULATIVE state as
of the state files' last update; only Section 2 (Newly Decided) and Section 8
(Campaign Summary) are filtered to the `-DaysBack`/`-StartDate`/`-EndDate` window.
With a campaign filter, Sections 1-4 narrow to the matching campaign SERIES;
Sections 5-7 always cover all reviewers. The header states all of this and warns
when the state predates the end of the requested window.

**Report sections:**
1. **Entitlement State Summary** -- honest decision distribution (APPROVE / REVOKE / PENDING / UNDECIDED tiles)
2. **Newly Decided** -- items that transitioned from PENDING/UNDECIDED to APPROVE/REVOKE within the date range. Includes the **Re-Approved After Revoke** sub-table: observed REVOKE -> APPROVE re-grants within the window (the re-grant governance signal), with the revocation day mined from each record's state log. First-seen-already-decided items appear in neither list
3. **Chronically Unreviewed** -- items stuck in PENDING/UNDECIDED for N+ consecutive campaigns
4. **Dropped from Scope** -- items that disappeared from all campaigns
5. **Reviewer Engagement Summary** -- engagement scores with streaks, sorted worst-first
6. **Reviewer Weekly Compliance** -- reviewers who missed 2+ days this ISO week
7. **Reviewer Engagement Heatmap** -- C/P/M/U daily grid per reviewer
8. **Campaign Summary** -- completion data from daily-metrics.jsonl for the date range

| Parameter | Description |
|---|---|
| `-DaysBack <n>` | Lookback window in days (default `7`). Controls campaign summary and newly-decided date range. |
| `-StartDate <yyyy-MM-dd>` | Explicit start date (overrides DaysBack). |
| `-EndDate <yyyy-MM-dd>` | Explicit end date (defaults to today). |
| `-CampaignName <name>` | Exact campaign name filter for campaign summary. |
| `-CampaignNameStartsWith <prefix>` | Campaign name prefix filter. |
| `-CampaignNameContains <substring>` | Campaign name substring filter. |
| `-Status <status[]>` | Filter campaign summary by status (`ACTIVE`, `COMPLETED`, etc.). |
| `-ChronicThreshold <n>` | Consecutive PENDING/UNDECIDED campaigns before an item is "chronic" (default `5`). |
| `-OutputMode` | `Console`/`HTML`/`Both` (default `Both`). |
| `-NoRefresh` | Never rewrite the state files -- render whatever exists (true read-only run). |
| `-MetricsPath <dir>` | Override the metrics directory. |
| `-OutputPath <dir>` | Override the output directory. |

**Exit codes:** `0` normal, `2` invalid `-StartDate`/`-EndDate`, `5` no state data.

```powershell
# Default: last 7 days, all campaigns
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1

# 14-day window
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -DaysBack 14

# Explicit date range
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -StartDate 2026-07-01 -EndDate 2026-07-15

# Filter to Daily Attestation campaigns
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -CampaignNameContains 'Daily' -DaysBack 30

# Only COMPLETED campaigns, stricter chronic threshold
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -Status COMPLETED -ChronicThreshold 3

# Console-only summary (no HTML file)
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -OutputMode Console
```

**Output:** `daily-evidence-v8-{timestamp}.html`.
**Data sources:** `entitlement-state.jsonl` + `reviewer-state.jsonl` (pre-computed) +
`daily-metrics.jsonl` (campaign metadata). No ISC API calls, no cache parsing.
**Related:** `Update-SPStateFiles.ps1` (explicit state rebuild),
`Invoke-SPDailyEvidenceReportV4e.ps1` (the cache-based series report V8 complements).
**Testing:** see `docs/testing/state-tracking-integration-test.md` for the integration
test guide.

### `Invoke-SPPendingReviewerScrape.ps1`
**Purpose:** an **ad-hoc, dependency-free** scraper that answers "who keeps not attesting?" straight from
the **daily evidence HTML files you already have** -- no ISC API, no cache, no metrics store, no V7.
Point it at a folder of reports (defaults match the production `daily-evidence-v4b-*.html` name plus
the legacy `Daily-Attestation-Evidence-Report-*.html`) and it pulls every reviewer listed in each
report's Pending / Undecided table, then charts who shows up repeatedly. Handy as a bridge while the
cache-based trending is adopted, or as an independent cross-check when V7 looks off. Because it reads
finished HTML rather than the API or cache, it is unaffected by cache or metrics-store state.

**Parsing hardening:** the reviewer column is resolved from each table's header row (V4d-style item
tables, whose first column is an identity, fall back to their subhead reviewer names); placeholder
rows (`N/A`, `(Unassigned)`, "No undecided reviewers.", V4e empty-state rows) are filtered; files
whose names fail date parsing are dated by file-modified time WITHOUT splitting the day into two
aggregation keys (provenance is noted in the report header instead).

It renders a self-contained inline-SVG dashboard (no JavaScript -- Word/email safe):
1. **Chronic-Pending bars** -- per reviewer, appeared pending in X of N report days (percentage),
   with optional `-ShowTrend` indicators (Improving / Lagging / Chronic / Inconsistent / Steady /
   Recently flagged). An ACTIVE trailing streak (still pending on the window's last day, 2+ days
   running) always reads Lagging -- 4 outstanding days becoming 5 is deterioration, even when a
   saturated window's half-vs-half rates are flat -- and pending EVERY window day reads Chronic.
2. **Reviewer-by-Date heatmap** -- a red cell wherever a reviewer was pending that day.
3. **Missed-Review Streak flags** -- reviewers pending N **consecutive REPORT days** (threshold 2 when
   fewer than 3 reports are in scope, otherwise 3). Weekends/holidays with no report do NOT reset a
   run; a completed report day does.
4. **Daily distinct-pending trend** bars (adaptive width + thinned rotated labels for 15-90+ day windows).
5. **Engagement pattern analysis** (runs when more than 5 report days are in scope).

| Parameter | Description |
|---|---|
| `-Path <folder>` | Folder of report HTML files. Default `.\Audit\daily-evidence`. |
| `-FilePattern` | One or more wildcards. Default `daily-evidence-v4b-*.html` + `Daily-Attestation-Evidence-Report-*.html`. |
| `-DaysBack <n>` | The N most recent REPORT days (not calendar days); respects `-Until`; overrides `-Since`. |
| `-Since` / `-Until` | Optional inclusive date bounds; the date is auto-parsed from each filename. |
| `-MinMisses <n>` | Minimum pending days to appear. Default `-1` = auto: 1 when 5 or fewer report days, else 3. |
| `-Top <n>` | Limit the bars/heatmap to the N most-pending reviewers (0 for all). |
| `-ShowTrend` | Opt-in first-half vs second-half trend indicators on the bar chart. |
| `-OutputMode` | `Console`/`HTML`/`Both`. |

```powershell
# Point at a folder of your final attestation reports; last 3 report days
.\Scripts\Invoke-SPPendingReviewerScrape.ps1 -Path 'C:\Reports\DailyEvidence' -DaysBack 3 -OutputMode Both
```

**Read-only** (no `SupportsShouldProcess`). **Output:** `Pending-Reviewer-Tracker-<timestamp>.html` in the
output folder.

### `Invoke-SPDecisionScrape.ps1`
**Purpose:** the companion **decision-activity scraper** -- revoked and newly approved access across
the reporting period, from the same daily evidence HTML folder. Read-only, no ISC API, no cache.

**Critical semantics:** the V4b registers are **cumulative campaign snapshots** (every daily report
re-lists all decisions made so far, each row carrying the item's own Decision Date). The scraper
**de-duplicates** items across the window (identity + access + source + reviewer + decision date,
first sighting wins) and **buckets by each item's own Decision Date**, never the report file's date.
Without this, a 30-day window over-counted every item once per day it survived in, and put decisions
on the wrong day. The decision-day axis can therefore start before the first report file -- that is
the truthful timeline. The approved campaign-to-date total is scraped from the campaign summary
table when present.

Dashboard: KPI tiles (distinct revoked / distinct new scope / approved campaign-to-date /
re-approved flops / net change / report days / decision days / averages), three adaptive charts on
one aligned date axis (combined paired red-green, revoked-only, new-scope-only) plus a raw per-day
numbers table with CUMULATIVE columns that reconcile daily first-sightings back to the source
reports' register counts (a report showing 35 the day after 28 = 7 first-sightings that day). Every
report day appears on the chart axis -- a zero bar means the report ran and nothing was decided;
only days with neither a report nor decision activity are absent. Also includes a
**Re-Approved After Revoke (flops)** table (grants revoked earlier in the window and approved again
later -- also the explanation when a Revoked register count SHRINKS between two reports), a
**Re-Revoked Grants** table (the same grant revoked on more than one decision day -- distinct revoke
events are never de-duplicated, and repeats signal access that came back after a revoke), an
intra-report duplicate-row data-quality warning (the same key twice in ONE file suggests upstream
cache duplication; cross-day repetition is normal), the
revoked register (default cap 500 rows, `-Top` overrides, truncation disclosed), top revoked
entitlements/identities, new-scope register, and a per-source breakdown. "Newly Decided" approvals of
pre-existing items are intentionally excluded from New Scope and Net Change -- that signal belongs to
the V4g/V8 state pipeline.

| Parameter | Description |
|---|---|
| `-Path` / `-FilePattern` | Same defaults and semantics as the pending scraper. |
| `-DaysBack` / `-Since` / `-Until` | Same report-day window semantics as the pending scraper. |
| `-Top <n>` | Row limit for detail registers and rankings. Default 0 = 500 detail / 15 ranking rows. |
| `-OutputMode` | `Console`/`HTML`/`Both`. |

```powershell
# Last 30 report days with default caps
.\Scripts\Invoke-SPDecisionScrape.ps1 -Path .\Audit\daily-evidence -DaysBack 30
```

**Read-only.** **Output:** `Decision-Activity-Tracker-<timestamp>.html` in the output folder.

### `Invoke-SPAdaptiveReport.ps1` ---- DEPRECATED
> **Deprecated — do not use for new work.** These reports were ported *verbatim* from an
> EntraID group-enumerator and render an AD "group → members" view (`SamAccountName`, `Enabled`,
> nested groups) that **drops the ISC certification substance** — the decision, the reviewer, the
> dates, the remediation status. An IGA review panel found them either strictly-worse clones
> of native ISC reports or authoritative-looking dashboards built on the wrong fields. Use the
> ISC-native replacements: **`Invoke-SPCertTracker.ps1`** (executive tracker + `-EvidencePack`
> attestation evidence), **`Invoke-SPCampaignTrendReport.ps1`** (KPI trend; `-Program` for
> cross-campaign), **`Invoke-SPCampaignDiff.ps1`** (day-over-day diff). Kept temporarily for
> back-compat; will be removed.

> **Deprecation timeline:** Deprecated as of June 2026. Will be removed in a future release.
> **Migration:** Use `Invoke-SPCertTracker.ps1` (executive tracker), `Invoke-SPCampaignTrendReport.ps1`
> (KPI trend), or `Invoke-SPCampaignDiff.ps1` (day-over-day diff) instead.

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
| `-Components <keys>` | Composable component list: `kpi-cards`, `heatmap`, `tree`, `top-n`, `group-table`, **`diff`** (append `:half` for side-by-side). Default `kpi-cards,top-n,group-table`; pass `@()` to skip the composable report. The **`diff`** component renders the per-group **Added/Removed** membership changelog (RC04) — see *Delta / removal detection* below. |
| `-BaselineReport <names>` | One or more of `inventory`, `privileged`, `orphaned`, `exec-summary`, `roster`, `access-cert`, `sod`, or `all`. |
| `-Theme <t>` | `light` (default) or `dark`. |
| `-Status <list>` | Campaign status filter (default `COMPLETED, ACTIVE`). |
| `-DaysBack <n>` | Campaign window in days (default 90). |
| `-CreatedAfter` / `-CreatedBefore <date>` | Explicit creation-date bounds (take precedence over `-DaysBack`). |
| `-CampaignName` / `-CampaignNameStartsWith` / `-CampaignNameContains` | Filter campaigns by name (see *Campaign filtering & the item cache*). |
| `-OutputPath <dir>` | Destination (default `Audit\adaptive`). |
| `-OutputMode` | `Console` (default) / `JSON` / `HTML` / `Both` — controls the run summary; the HTML report files are always written. |

**Leadership distribution** *(additive; off by default)* — `-DistributeToLeadership`
turns the same run into tiered, per-leader reports and (optionally) sends them. It reuses
the org-tree / band machinery from `Invoke-SPReportDistribution` (`SP.DeltaCert`): it builds
the org tree, resolves each identity's **band A–E**, generates an upper-leadership executive
HTML rollup plus **per-band leader reports** (via `Export-SPLeadershipExecutiveHtml` /
`Export-SPLeadershipBandHtml`), then distributes them.

| Parameter | Description |
|---|---|
| `-DistributeToLeadership` | Enable the leadership pass (per-band reports + distribution). |
| `-TargetBands <letters>` | Limit to specific bands (e.g. `B,C`). Default: all bands present. |
| `-LeadershipDepth <n>` | Org-tree levels above reviewed identities (default 4). |
| `-OrgSupplementPath <csv>` | Org-chart supplement overriding/filling ISC manager gaps. |
| `-PreviewOnly` | Show who-gets-what without generating or sending. |
| `-SendReports` | Actually email each report. |

> **SMTP-off = "would-send" simulation.** Distribution **simulates by default** (WhatIf):
> for each band leader it logs `WOULD send -> email (name) : file` and **sends nothing**.
> Email is only attempted when you pass `-SendReports`, and even then `Send-SPReport` only
> truly sends when `Audit.Smtp.Enabled = true` — otherwise it falls back to a logged
> "would-send" entry. The run summary reports `Leaders / Sent / Simulated / Skipped` counts.

**Delta / removal detection (`diff` component).** Add `diff` to `-Components` to render
the **Added/Removed membership changelog** (RC04) — a per-group `+adds / -removes` delta
over the window, so *removed-from-entitlement* changes are surfaced alongside grants. It
reads the membership changelog (JSONL of `Added`/`Removed` events); component options
`Days` (last-N-days window) and `MaxGroups` (busiest first) tune the view. This complements
`Invoke-SPADDeltaCert` / `Invoke-SPDeltaCertRun` (§3), which re-certify *newly granted*
access; the `diff` component is the read-side view of *both* directions of change.

```powershell
# Entitlement view: composable dashboard + three baseline reports, last 180 days
.\Scripts\Invoke-SPAdaptiveReport.ps1 -Anchor Entitlement -Components kpi-cards,heatmap,top-n,group-table -BaselineReport inventory,privileged,exec-summary -DaysBack 180
# Add the Added/Removed change diff alongside the dashboard
.\Scripts\Invoke-SPAdaptiveReport.ps1 -Anchor Entitlement -Components kpi-cards,top-n,diff -DaysBack 30
# Campaign view, dark theme, an explicit window
.\Scripts\Invoke-SPAdaptiveReport.ps1 -Anchor Campaign -BaselineReport all -Theme dark -CreatedAfter 2026-01-01 -CreatedBefore 2026-03-31
# Generate + distribute to leadership, bands B & C, simulate only (no email)
.\Scripts\Invoke-SPAdaptiveReport.ps1 -Anchor Campaign -BaselineReport exec-summary -DistributeToLeadership -TargetBands B,C
# Same, but actually email (requires Audit.Smtp.Enabled = true)
.\Scripts\Invoke-SPAdaptiveReport.ps1 -Anchor Campaign -BaselineReport exec-summary -DistributeToLeadership -SendReports
```
*Exit codes:* 0 ok · 1 no campaigns/data · 2 parameter · 3 auth · 4 config.
**Related GUI:** Adaptive Reports tab (see the GUI Playbook). The GUI generates reports
only; leadership distribution is CLI-only (`-DistributeToLeadership`).

### `Invoke-SPIscReconciliation.ps1`
**Purpose:** generate the **ISC-side operand** for the cross-project **AD ↔ ISC ↔ HR
reconciliation**. It reads identities + governed access (entitlement membership) from ISC,
resolves the `employeeID` join key and each identity's cert-reviewer (manager) `employeeID`,
and writes a versioned, self-describing **employeeID-keyed export** — UTF-8 no-BOM JSON + a
CSV twin + a SHA-256 sidecar — that a future merge joins against the **AD export** (the Group
Enumerator) and an **HR export** (SuccessFactors) to surface drift (`MGR_MISMATCH`,
`STATUS_MISMATCH`, `ACCESS_NOT_GOVERNED`, …). **Read-only: it never reassigns, escalates, or
mutates ISC.** The shared interface both sides coordinate to is
`docs/AD-Reconciliation-Contract-from-GroupEnumerator.md`.

**When to use:** whenever you need the current ISC picture as a merge-ready operand — a
governance baseline of *who exists, who is active, who reviews whom, and what access each
identity holds* — keyed so it can be reconciled against AD and HR.

> **The non-expiring cache (change detection).** The raw fetched operands (identities +
> grants) are written to a **cache that never expires** — deliberately separate from the
> toolkit's 24 h identity-detail cache (`Audit.IdentityCacheTtlMinutes`), with **no TTL and no
> age check**. So a generated baseline survives indefinitely: run once to capture a baseline,
> change the source (a termination, a manager change, a revoked entitlement, a blanked join
> key…), then re-run with `-RefreshCache` to see the change reflected. The export's
> `contentHash` changes **only when the data does** — without `-RefreshCache` the baseline is
> served from cache and reproduces a **byte-identical** export.

| Parameter | Description |
|---|---|
| `-JoinKeyAttribute <attr>` | ISC `attributes.*` field holding the SuccessFactors join key (default `employeeNumber`). Coverage % is computed from whether the key is **populated**, not from the attribute name, so a custom join key can't collapse coverage to 0%. |
| `-RefreshCache` | Re-fetch from ISC and overwrite the non-expiring cache (default: serve the cached baseline if present). |
| `-CachePath <dir>` | Override the non-expiring cache directory. |
| `-Token` / `-TokenExpiryMinutes` | Optional pre-acquired ISC browser JWT (else the configured client-credentials flow runs). |
| `-OutputPath <dir>` | Export root (default `.\Audit\Reconciliation`). |
| `-OutputMode` | `Console`/`JSON`/`Both`/`CSV` — controls console output; the JSON + CSV + sha256 are always written. |

```powershell
# Baseline: fetch from ISC, write the non-expiring cache + the export
.\Scripts\Invoke-SPIscReconciliation.ps1 -RefreshCache

# Re-run WITHOUT a refetch — serve the cached baseline (identical contentHash)
.\Scripts\Invoke-SPIscReconciliation.ps1

# After the source data changes, regenerate to detect the drift
.\Scripts\Invoke-SPIscReconciliation.ps1 -RefreshCache

# Custom join key (e.g. an extension attribute), into a scratch location
.\Scripts\Invoke-SPIscReconciliation.ps1 -RefreshCache -JoinKeyAttribute extensionAttribute7 -OutputPath .\Audit\Reconciliation
```

> **What the export carries (per identity, keyed by `employeeID`):** the resolved join key +
> confidence (`employeeID` > `mail` > `upn`; a `mail`/`upn` fallback is flagged
> `JoinConfidence=Low`), lifecycle/`active`, the manager/reviewer `employeeID` (the cert
> routing target), and the governed entitlements (name / source / privileged) for AD-group
> matching. The ISC side **pre-stages only the findings it can determine alone** —
> `JOINKEY_MISSING` and `MAIL_NE_UPN`; every *cross-source* finding (`MGR_MISMATCH`,
> `STATUS_MISMATCH`, `ACCESS_NOT_GOVERNED`, …) is computed at **merge** time, not invented
> here. Keep the shared finding-code vocabulary and join-key ladder identical on both sides.

*Exit codes:* 0 ok · 1 no identities · 2 parameter · 3 auth/fetch · 4 config.
**Related:** `docs/AD-Reconciliation-Contract-from-GroupEnumerator.md` (the shared contract);
`Invoke-SPCampaignDiff.ps1` (change detection *within* an ISC campaign).

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
| `-Skip*` switches | Skip any step (`-SkipValidation`, `-SkipCleanup`, `-SkipDeltaCert`, `-SkipDeltaReport`, `-SkipEscalation`, `-SkipHealthCheck`, ...). |
| `-IncludeDashboard` | Generate a governance trend dashboard as Step 11 (after log retention, before daily summary). |
| `-DashboardPeriod` | `Last7Days`/`Last30Days`/`Last90Days`/`AllTime` (default Last30Days). |

```powershell
# Standard daily run
.\Scripts\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -Token $jwt

# Daily run with governance dashboard
.\Scripts\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -Token $jwt -IncludeDashboard
```
**Related GUI:** *(operational -- typically scheduled, not interactive)*.

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

## 8. B2B guest governance

Scripts for onboarding and monitoring B2B partner access via ISC. These create the
governance layer (access profiles, roles, transforms, campaigns) without touching the
Entra/Graph API -- ISC-side only.

### `Invoke-SPB2BSetup.ps1`
**Purpose:** **8-step idempotent B2B partner onboarding** -- builds the full ISC governance
layer for a B2B partner domain: discovers entitlements, creates access profiles (standard +
optional Tier-2 elevated), criteria-based roles, optional lookup transform, and optional
certification campaign.

- Idempotent: re-running skips already-created resources (matched by naming convention)
- Certifier logic: never falls back to manager review (B2B guests have no manager identity)
- Supports `-WhatIf` for dry-run validation before creating any ISC resources
- Requires **admin-level** PAT permissions (not read-only audit scopes)

| Parameter | Description |
|---|---|
| `-PartnerName` | Partner identifier (used in naming convention). **Required.** |
| `-PartnerDomain` | Partner email domain (e.g. `contoso.com`). **Required.** |
| `-SourceId` / `-SourceName` | ISC source for partner identities (one required). |
| `-OwnerIdentityId` | IAM admin identity ID (owns created resources). **Required.** |
| `-Tier2Apps` | Optional elevated app group names for Tier-2 access profile. |
| `-GroupPrefix` | Entra group prefix (default `CLD-B2B`). |
| `-IncludeTransform` | Deploy partner-domain lookup transform. |
| `-CreateCampaign` | Create a certification campaign for the partner. |
| `-CertifierIdentityId` | Certifier for the campaign (required with `-CreateCampaign`). |
| `-CampaignDeadline` | Campaign deadline in days (default 14). |
| `-TriggerAggregation` | Trigger entitlement aggregation if missing. |
| `-Token` | Browser JWT or PAT override. |
| `-OutputMode` | Console / HTML / Both (default Both). |
| `-WhatIf` | Dry-run: show what would be created without making changes. |

```powershell
# Dry-run: preview what would be created for Contoso
.\Scripts\Invoke-SPB2BSetup.ps1 -PartnerName 'Contoso' -PartnerDomain 'contoso.com' `
    -SourceName 'Entra ID [source]' -OwnerIdentityId 'abc123' -WhatIf

# Full setup with Tier-2 apps and a campaign
.\Scripts\Invoke-SPB2BSetup.ps1 -PartnerName 'Contoso' -PartnerDomain 'contoso.com' `
    -SourceName 'Entra ID [source]' -OwnerIdentityId 'abc123' `
    -Tier2Apps 'SG-Salesforce-Admin','SG-ServiceNow-Admin' `
    -IncludeTransform -CreateCampaign -CertifierIdentityId 'def456'
```

**Exit codes:** 0 = success, 1 = entitlements not found, 2 = parameter error, 3 = API error,
4 = config error, 5 = partial (some steps failed).
**Output:** HTML setup report + JSONL audit trail.

### `Invoke-SPB2BHealthCheck.ps1`
**Purpose:** **11-check ongoing verification** of the B2B governance layer -- validates source
health, aggregation freshness, access profile completeness, role criteria, transform coverage,
provisioning policies, naming convention compliance, and unassigned guests.

- Read-only: PAT sufficient (no admin permissions needed)
- Exit codes map to operational severity: 0 = all pass, 1 = warnings, 2 = failures
- Designed for weekly scheduled runs to catch drift

| Parameter | Description |
|---|---|
| `-SourceId` / `-SourceName` | ISC source for partner identities (one required). |
| `-GroupPrefix` | Entra group prefix to validate (default `CLD-B2B`). |
| `-RolePrefix` | Role naming prefix to validate (default `B2B-`). |
| `-TransformName` | Expected transform name (default `B2B Partner Group Resolver`). |
| `-AccountStalenessHours` | Account aggregation freshness threshold (default 24). |
| `-EntitlementStalenessHours` | Entitlement aggregation freshness threshold (default 48). |
| `-GuestSampleLimit` | Max guests to sample for zero-role check (default 250). |
| `-Token` | Browser JWT or PAT override. |
| `-Quiet` | Suppress console output (exit code only). |

```powershell
# Full health check for the Entra ID source
.\Scripts\Invoke-SPB2BHealthCheck.ps1 -SourceName 'Entra ID [source]'

# Scheduled weekly check with custom staleness thresholds
.\Scripts\Invoke-SPB2BHealthCheck.ps1 -SourceId 'src-entra-001' `
    -AccountStalenessHours 48 -EntitlementStalenessHours 72 -Quiet
```

**Exit codes:** 0 = all checks pass, 1 = warnings present, 2 = failures detected.
**Output:** HTML health check report + JSONL evidence.
**Related:** `Invoke-SPB2BSetup.ps1` (creates the resources this script validates),
`docs/plans/B2B-SETUP-PLAN.md` (implementation plan).

---

*See also the [GUI Playbook](gui-playbook.md) for the interactive equivalents, and
[Foundations](00-foundations.md) for setup, auth, config, and the Safety model.*

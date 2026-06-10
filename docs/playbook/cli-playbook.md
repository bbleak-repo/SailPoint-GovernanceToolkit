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
2. [Campaign testing & audit](#2-campaign-testing--audit) — **creating/activating campaigns**, `Invoke-GovernanceTest`, `Invoke-SPCampaignAudit`, `Invoke-SPCampaignSearch`
3. [Delta certification](#3-delta-certification) — `Invoke-SPADDeltaCert`, `Invoke-SPDeltaCertEscalate`, `Invoke-SPDeltaReport`
4. [Disconnected applications](#4-disconnected-applications) — `Invoke-SPDisconnectedAppCert`, `Invoke-SPDisconnectedAppBatch`, `Invoke-SPDisconnectedAppRegistry`
5. [Governance & reporting](#5-governance--reporting) — health check, metrics, report, data quality, distribution, **campaign diff (day-over-day)**, **campaign KPI trend / program trend**, **executive cert tracker + attestation evidence**, **daily evidence report (SOX/IAG)**, weekly digest, **AD↔ISC↔HR reconciliation export (non-expiring change-detection cache)**, ~~adaptive reports~~ (deprecated)
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
| `-DaysBack <n>` *(+ `-WhatIf`)* | **Org-chart audit mode:** check every cert in campaigns from the last N days and resolve each reviewer→skip-level chain — validates ISC manager chains without writing. |
| `-Csv` / `-CsvPath <p>` | Write the full reviewer→skip-level chain to a CSV (read-only; produced even under `-WhatIf`). |
| `-EmailList` / `-EmailListPath <p>` | Write a copy-paste **email-queue** text file for nudging people *outside the tool*: two `;`-separated lines — (1) the **managers behind** on their attestation, (2) the **skip-level / escalation path** (each manager's manager). De-duplicated, resolvable emails only; produced even under `-WhatIf`. |

```powershell
# Live escalation
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -Token $jwt

# Dry-run + the copy-paste email queue (managers behind + escalation path)
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf -EmailList

# Full org-chart audit: the chain spreadsheet AND the email lines
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf -Csv -EmailList
```

> **`-EmailList` — the email queue.** Writes `escalation-emails-*.txt` to `DeltaCert.OutputPath`:
> a labelled header plus **two ready-to-paste lines** — the managers behind on their attestation,
> and the skip-level/escalation path — each a `;`-separated list for pasting into an email client's
> To/CC. Pair with `-Csv` for the full per-cert chain. Both are read-only reporting artifacts (no
> ISC writes), so they're safe to generate under `-WhatIf`.

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

- **Completion diff** — *who is doing their attestations.* Per reviewer: decisions made
  since the last capture, completion %, **newly completed**, **stalled** (no progress
  between captures), and **not started**.
- **Scope diff** — *what changed in the campaign.* Grants **added** to scope (the same
  campaign grows as entitlement groups and sources onboard), grants **removed**, and
  **decision changes** — plus a **compliance summary**: newly-added privileged access,
  stalled/not-started reviewers, overdue undecided items, and a *privileged-approved*
  advisory.

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

# Week-over-week: compare this week's capture to last week's
.\Scripts\Invoke-SPCampaignDiff.ps1 -CampaignId 'camp-7f3a...' -Cadence Weekly

# Re-render this morning's vs yesterday's capture WITHOUT calling ISC
.\Scripts\Invoke-SPCampaignDiff.ps1 -CampaignId 'camp-7f3a...' -NoCapture
```

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
the item cache*).

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
**Purpose:** a daily executive governance dashboard with six KPIs, a Governance Confidence
Score, a cascading-risk "Domino Tracker", and SOX/IAG evidence registers. Designed to satisfy
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
# Daily evidence report (default 1-day window)
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -Token $token -OutputMode Both

# Scope to a specific day's campaigns
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -CampaignNameContains 'Tuesday' -DaysBack 7 -Token $token

# Dry run -- see what steps would execute
.\Scripts\Invoke-SPDailyEvidenceReport.ps1 -WhatIf
```

**Thresholds** are configurable in `settings.json` under the `DailyEvidence.Thresholds` section.
The script uses sensible defaults if the section is missing. See
[Foundations](00-foundations.md) for the settings reference.

**Output files:**
- `daily-evidence-{timestamp}.html` -- self-contained HTML executive dashboard + evidence
- `daily-evidence-audit.jsonl` -- append-only JSONL evidence trail (written every run for SOX immutability)

*Exit codes:* 0 all KPIs green + confidence A/B | 1 any KPI yellow or confidence C |
5 any KPI red, confidence D/F, or critical failure | 2/3/4 parameter/auth/config.

**Related GUI:** Governance tab. **Related:** `Invoke-SPGovernanceMetrics` (time-series capture),
`Invoke-SPWeeklyDigest` (weekly narrative), `Invoke-SPGovernanceReport` (full audit package).

### `Invoke-SPAdaptiveReport.ps1` ---- DEPRECATED
> **Deprecated — do not use for new work.** These reports were ported *verbatim* from an
> EntraID group-enumerator and render an AD "group → members" view (`SamAccountName`, `Enabled`,
> nested groups) that **drops the ISC certification substance** — the decision, the reviewer, the
> dates, the remediation status. A SOX/IGA review panel found them either strictly-worse clones
> of native ISC reports or authoritative-looking dashboards built on the wrong fields. Use the
> ISC-native replacements: **`Invoke-SPCertTracker.ps1`** (executive tracker + `-EvidencePack`
> attestation evidence), **`Invoke-SPCampaignTrendReport.ps1`** (KPI trend; `-Program` for
> cross-campaign), **`Invoke-SPCampaignDiff.ps1`** (day-over-day diff). Kept temporarily for
> back-compat; will be removed.

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

# SailPoint ISC Governance Toolkit — Foundations

> **Source of truth.** This Markdown file is the canonical reference. The HTML user
> guides are generated from it; edit the Markdown, never the HTML. This document is
> shared by both the **CLI Playbook** and the **GUI Playbook** — every concept
> here (setup, authentication, configuration, safety, outputs, glossary) is written
> once and referenced by both.

**Audience:** anyone setting up or operating the toolkit. Read this first; then go
to the CLI Playbook (operators / automation) or the GUI Playbook (interactive
analysts / reviewers).

---

## 1. What the toolkit is

The SailPoint ISC Governance Toolkit is a PowerShell 5.1 toolkit for operating
identity governance against a SailPoint Identity Security Cloud (ISC) tenant. It
covers:

- **Campaign certification** — create, run, monitor, and audit access-review campaigns.
- **Delta certification** — targeted re-certification of recently-changed access (e.g. new AD grants).
- **Disconnected applications** — certify access for apps that don't integrate directly with ISC.
- **Governance reporting** — health checks, KPI metrics, leadership rollups, data-quality scoring.
- **Adaptive reports** — composable, themeable HTML reports (KPI cards, heatmaps, top-N bars, drill-down trees) plus a baseline report library (entitlement inventory, privileged review, orphaned/disabled access, separation-of-duties, certification roster, access-certification attestation, governance executive summary), rendered over an **entitlement-** or **campaign-centric** view of your campaign data (`Invoke-SPAdaptiveReport`). Additive — alongside the existing reports.
- **Vendor SDK features** — campaign templates/scheduling, approvals, work items, workflows, campaign filters (the **SDK Features** GUI tab and the `Invoke-SPSdk*` scripts).
- **Operations** — report distribution, retention/archival, scheduling, connectivity checks.

Everything is available two ways: a **CLI** (headless, automatable) and a **WPF GUI
dashboard** (interactive). They share the same modules, configuration, and safety
rules.

---

## 2. Prerequisites

| Requirement | Detail |
|---|---|
| **OS** | Windows 10/11 or Windows Server. |
| **PowerShell** | **Windows PowerShell 5.1 (Desktop edition).** Not PowerShell 7/Core — the modules rely on 5.1 behavior and the GUI requires .NET Framework WPF. |
| **.NET Framework** | **4.8+** (only for the GUI dashboard / WPF). Pre-installed on Windows 10 1903+ and all Windows 11 machines — no action needed on modern Windows. `Show-SPDashboard.ps1` checks this at launch and exits with a clear error and download link if needed. |
| **Network / TLS** | Outbound HTTPS to your ISC tenant. The toolkit forces **TLS 1.2 (and 1.3 where available)** automatically. |
| **ISC credentials** | An ISC **Personal Access Token (PAT)** — a `client_credentials` OAuth client that yields a `ClientId` + `ClientSecret` pair — or a short-lived **bearer token** copied from the browser. The PAT must be created by an identity with the **`CERT_ADMIN`** or **`ORG_ADMIN`** role and granted the scopes for what you intend to do (read-only audit vs. campaign creation vs. delta cert). See §5 for the scope matrix and `docs/SANDBOX-API-SETUP.md` for the click-by-click setup. |
| **Pester** (optional) | 5.x — only needed to run the test suite. |
| **Execution policy** | PowerShell execution policy must allow running unsigned scripts. Set `RemoteSigned` for the toolkit user (`Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`), or pass `-ExecutionPolicy Bypass` when invoking scripts from Task Scheduler. |

---

## 3. Installation

1. Extract the toolkit zip (or clone the repo) to a local directory, e.g. `C:\Toolkit\`.
2. Confirm the structure:
   - `Modules\` — the PowerShell modules (don't edit).
   - `Scripts\` — the CLI entry points (what you run).
   - `Gui\` — the WPF dashboard XAML.
   - `Config\` — your configuration files (you edit these).
   - `Tests\` — Pester + GUI test harness (dev only).
   - Runtime output folders (`Logs\`, `Audit\`, `Reports\`, etc.) are created on demand.
3. From the toolkit root, every script supports `-Help`:
   ```powershell
   .\Scripts\Invoke-SPCampaignAudit.ps1 -Help
   ```

---

## 3.1 Architecture at a Glance

The toolkit is a **modular monolith** -- a set of PowerShell modules that compose into
scripts and the GUI. Every script and the dashboard share the same module chain.

| Module | Purpose | Used by | Notes |
|---|---|---|---|
| **SP.Shared** | Shared utilities: HTML encoding/dates/properties/file writing (SP.HtmlHelpers), generic TTL-aware cache with JSONL persistence (SP.CacheService), identity resolution and caching (SP.IdentityService) | Everything | Infrastructure -- loaded first, before SP.Core. 26 exported functions across 3 sub-modules. |
| **SP.Core** | Configuration, logging, authentication, vault, TLS enforcement | Everything | Infrastructure -- you never call this directly. |
| **SP.Api** | HTTP client, campaign/certification/decision API wrappers, rate limiting, pagination | All scripts that talk to ISC | Infrastructure -- you never call this directly. |
| **SP.Testing** | Test-case loader, batch runner, assertions, evidence writer | `Invoke-GovernanceTest.ps1`, the Campaigns GUI tab | Infrastructure for the test harness. |
| **SP.Audit** | Audit queries, analytics, identity-account resolution, HTML/text report generation, governance trend queries, governance dashboard | `Invoke-SPCampaignAudit.ps1`, `Invoke-SPCampaignSearch.ps1`, `Invoke-SPGovernanceMetrics.ps1`, governance reports, the Audit GUI tab | The core reporting engine. Includes SP.GovernanceTrendQuery for dashboard data + alerts. |
| **SP.DeltaCert** | Delta-cert queries (account activities, identity resolution, band classification), campaign runner, escalation, delta report | `Invoke-SPADDeltaCert.ps1`, `Invoke-SPDeltaCertEscalate.ps1`, `Invoke-SPDeltaReport.ps1`, the Delta Cert GUI tab | |
| **SP.DisconnectedApps** | CSV validation, snapshot/diff, identity correlation, campaign creation, batch orchestration, analytics, reports | `Invoke-SPDisconnectedAppCert.ps1`, `Invoke-SPDisconnectedAppBatch.ps1`, `Invoke-SPDisconnectedAppRegistry.ps1`, the Delta Cert GUI tab | |
| **SP.Sdk** | Vendor SDK wrappers -- campaign templates, cert summaries, approvals, work items, workflows, campaign filters, OOO fallback | `Invoke-SPSdkCampaignTemplates.ps1`, `Invoke-SPSdkWorkItems.ps1`, `Invoke-SPSdkWorkflows.ps1`, the SDK Features GUI tab | |
| **SP.AdaptiveReports** | Composable adaptive report engine, baseline report library, dataset builder | `Invoke-SPAdaptiveReport.ps1`, the Adaptive Reports GUI tab | |
| **SP.ReportComponents** | Individual HTML report components -- KPI cards, heatmap, tree, diff, top-N, group table, framework CSS | SP.AdaptiveReports (indirectly) | Infrastructure -- you never call this directly. Component files: `RC00-Framework.ps1` through `RC06-GroupTable.ps1`. |
| **SP.Reconciliation** | ISC-side reconciliation operand builder/exporter | `Invoke-SPIscReconciliation.ps1` | Pure builder -- no ISC API dependency for the builder itself. |
| **SP.Gui** | WPF window construction, GUI bridge (translates button clicks to module calls), SDK bridge | `Show-SPDashboard.ps1` | Infrastructure for the GUI. |

**Module dependency chain:**
`SP.Shared` (HTML helpers, cache service, identity service -- no dependencies) -->
`SP.Core` (config, auth, logging) --> `SP.Api` (HTTP + ISC endpoints) --> domain modules
(`SP.Audit`, `SP.DeltaCert`, `SP.DisconnectedApps`, `SP.Sdk`, `SP.Testing`) -->
`SP.AdaptiveReports` + `SP.ReportComponents` (report rendering) --> `SP.Gui` (presentation).

---

## 3.2 Day 1 Deployment Checklist

Use this checklist to verify everything is ready before the first real run.

- [ ] **PowerShell version** -- Windows PowerShell 5.1 Desktop edition (`$PSVersionTable.PSVersion` shows 5.1.x)
- [ ] **.NET Framework** -- 4.8+ installed (required for the GUI; pre-installed on Windows 10 1903+ and all Windows 11)
- [ ] **Extraction** -- Toolkit zip extracted to a local directory (e.g. `C:\Toolkit\`); folder structure matches section 3
- [ ] **Execution policy** -- Set to `RemoteSigned` for the toolkit user, or plan to pass `-ExecutionPolicy Bypass` when invoking from Task Scheduler
- [ ] **Config created** -- `Config\settings.local.json` exists with real tenant values (copy from `settings.json`, replace all `CHANGE_ME` placeholders)
- [ ] **PAT created** -- ISC Personal Access Token created with the required scopes for your use case (see section 5.1)
- [ ] **Vault set up** -- `New-SPVault.ps1` run and passphrase stored in a password manager (or ConfigFile mode chosen for scheduled tasks)
- [ ] **Connectivity test** -- `Test-SPConnectivity.ps1` returns success against your tenant
- [ ] **Smoke test** -- `Invoke-GovernanceTest.ps1 -Tags smoke` runs clean (against mock or tenant)
- [ ] **Safety settings reviewed** -- `Safety.RequireWhatIfOnProd` is `true`, `Safety.AllowCompleteCampaign` is `false` (until you explicitly need it)
- [ ] **Output directories** -- `Logs\`, `Audit\`, `DeltaCert\`, `Reports\` will be auto-created on first run; confirm the toolkit user has write permission to the toolkit root
- [ ] **Network** -- Outbound HTTPS to `<tenant>.api.identitynow.com` is open; TLS 1.2 is enforced automatically
- [ ] **Notification** -- SMTP server or webhook URL configured if you want email/webhook alerts (section 11)
- [ ] **Disconnected apps** -- If applicable, apps registered via `Invoke-SPDisconnectedAppRegistry.ps1 -Action Register` and CSV delivery path confirmed
- [ ] **Scheduled task** -- Task Scheduler job created for `Invoke-SPDailyOrchestrator.ps1` (see CLI Playbook section 7)

---

## 4. Configuration

### 4.1 How config files work

Configuration is JSON. Resolution order (highest precedence last):

1. **`Config\settings.json`** — the base config (committed/shared; safe defaults with `CHANGE_ME` placeholders).
2. **`Config\settings.local.json`** — your machine-local overrides (gitignored; **put real credentials here**, never in `settings.json`).
3. **`-ConfigPath <file>`** — an explicit file passed to any script/the GUI (wins over the above).

> **Never commit real credentials.** `settings.local.json` and any `*-real.local.json`
> are gitignored on purpose, as is the encrypted vault (`*.enc`) and all runtime
> output (`Logs/`, `Audit/`, `Reports/`, `Data/`).

### 4.2 Generating a config

- First run of `Invoke-GovernanceTest.ps1` (or any script) with no config creates a
  template `settings.json` full of `CHANGE_ME` placeholders and prints first-run guidance.
- Replace every `CHANGE_ME` with your tenant values (or supply them via the vault — §5).
- A `CHANGE_ME` value is treated as "first run not complete" and the toolkit will refuse
  to run against a real tenant until it's replaced.

### 4.3 `settings.json` reference

Top-level sections and the keys that matter most:

| Section | Key | Purpose |
|---|---|---|
| **Global** | `EnvironmentName` | A label for this environment (shown in logs, used by Safety). |
| | `DebugMode` | Verbose diagnostics when `true`. |
| **Authentication** | `Mode` | `ConfigFile`, `Vault`, `DpapiCredential`, `ScheduledVault`, or `Token` — see §5. |
| | `ConfigFile.TenantUrl` / `OAuthTokenUrl` | Your ISC tenant base + OAuth token endpoint. |
| | `ConfigFile.ClientId` / `ClientSecret` | OAuth client credentials (use the vault for real secrets). |
| | `Vault.VaultPath` | Encrypted vault location (`.\Data\sp-vault.enc`). |
| | `Vault.Pbkdf2Iterations` | Key-derivation iterations (default 600000). |
| **Api** | `BaseUrl` | `https://<tenant>.api.identitynow.com/v3`. |
| | `TimeoutSeconds`, `RetryCount`, `RetryDelaySeconds`, `MaxRetryDelaySeconds` | HTTP timeout + exponential-backoff retry tuning. |
| | `RateLimitRequestsPerWindow`, `RateLimitWindowSeconds` | Client-side rate limiting to respect ISC limits. |
| | `MaxPaginationPages` | Safety ceiling on auto-pagination (prevents runaway loops). |
| **Logging** | `Path`, `FilePrefix`, `MinimumSeverity` | Log folder, file prefix, and minimum level (`DEBUG`/`INFO`/`WARN`/`ERROR`). |
| **Safety** | `MaxCampaignsPerRun` | Hard cap on campaigns created/processed per run. |
| | `RequireWhatIfOnProd` | When `true`, mutating actions on a non-mock environment require confirmation / WhatIf. |
| | `AllowCompleteCampaign` | Gate for the terminal "complete campaign" action (default `false`). |
| **Audit** | `OutputPath`, `DefaultDaysBack`, `DefaultStatuses` | Where audit reports go; default look-back window and campaign statuses. |
| | `IncludeCampaignReports`, `IncludeIdentityEvents`, `IncludeLeadershipRollup`, `LeadershipDepth` | Which sections to include in an audit. |
| | `RiskIndicators.*` | Stale-access threshold, privileged/service-account name patterns. |
| | `Smtp.*` | Email delivery for audit reports (disabled by default). |
| **DeltaCert** | `SourceIds`, `DefaultHoursBack`, `DefaultDeadlineDays` | Sources to watch, look-back, and reviewer deadline. |
| | `CampaignNamePrefix`, `DefaultReviewerMode`, `ExcludeLifecycleStates` | Naming, reviewer assignment, and exclusions. |
| | `Escalation.*` | Stale-reviewer escalation thresholds. |
| **DisconnectedApps** | `ImportBasePath`, `SnapshotPath`, `ReportPath` | File locations for the disconnected-app pipeline. |
| | `CorrelationAttribute`, `AccountDeletionThresholdPct`, `RequiredAccountColumns` | Correlation key, delete-safety threshold, CSV schema. |
| | `ISC.UploadMethod`, `Applications` | How accounts reach ISC; per-app definitions. |
| **Sdk** | `OutputPath`, `CampaignTemplates.*`, `Approvals.*`, `WorkItems.*`, `Workflows.*` | Defaults for the SDK Features (templates, approvals, work items, workflows incl. OOO fallback). |
| **DailyEvidence** | `OutputPath` | Daily evidence report output directory (default `.\Audit\daily-evidence`). |
| | `DefaultDaysBack` | Campaign look-back window in days (default `1`). |
| | `DefaultSlaHours` | Remediation SLA threshold in hours (default `48`). |
| | `HighRiskThreshold` | Risk score at or above which an identity is flagged high-risk (default `70`). |
| | `EvidenceDetailLimit` | Max rows shown per evidence register table in the HTML report (default `50`). |
| | `Thresholds.CompletionRate` | `{ "Green": 95, "Yellow": 80 }` -- campaign completion percentage. |
| | `Thresholds.OverdueAttestations` | `{ "Green": 0, "Yellow": 2 }` -- count of overdue attestations. |
| | `Thresholds.RevocationExecution` | `{ "Green": 95, "Yellow": 80 }` -- revocation execution percentage. |
| | `Thresholds.RemediationSla` | `{ "Green": 95, "Yellow": 80 }` -- remediation within SLA percentage. |
| | `Thresholds.HighRiskPending` | `{ "Green": 0, "Yellow": 3 }` -- count of high-risk items still pending. |
| | `Thresholds.ReviewerHealth` | `{ "GreenMaxAtRisk": 0, "YellowMaxAtRisk": 2 }` -- reviewers flagged at-risk. |
| | `ConfidenceScoreGrade` | Score-to-grade mapping: `{ "A": 90, "B": 80, "C": 70, "D": 60 }`. Scores below D threshold receive an F. |
| **GovernancePolicy** | `Enabled` | Master switch for policy evaluation (`true`/`false`). |
| | `Policies` | Array of policy objects. Each policy has `Id`, `Name`, `Description`, `Type`, `Scope` (where applicable), `Severity` (`Critical`/`Warning`), and type-specific thresholds. |
| | `Policies[]: POL-001` | **Privileged Access Review Frequency** -- all privileged entitlements reviewed within `MaxDaysSinceReview` days (default 90). Severity: Critical. |
| | `Policies[]: POL-002` | **Source Coverage Minimum** -- every source has at least `MinCoveragePercent`% entitlement review coverage (default 75). Severity: Warning. |
| | `Policies[]: POL-003` | **Identity Risk Ceiling** -- no identity remains at high risk (above `MaxRiskScore`, default 70) for more than 30 days. Severity: Critical. |
| | `Policies[]: POL-004` | **Stale Access Limit** -- no more than `MaxStalePercent`% of entitlements classified as stale (default 10). Severity: Warning. |
| | `Policies[]: POL-005` | **Reviewer Performance Floor** -- no reviewer has a reputation score below `MinReputationScore` (default 40). Severity: Warning. |
| **Metrics** | `Path` | KPI time-series storage directory (default `.\Audit\metrics`). |
| | `RetentionDays` | How long metric snapshots are retained (default `365`). |
| | `AutoCapture` | When `true`, scripts that produce KPIs automatically persist them to the metrics store. |
| | `CampaignTrendPath` | Storage directory for campaign-trend data (default `.\Audit\metrics\campaign-trend`). |
| | `CampaignTrendRetentionDays` | Retention for campaign-trend data (default `1825` -- 5 years). |
| **Governance / Leadership** | various | Governance report depth, leadership band mapping. |
| **Retention** | `Enabled`, `ArchiveDays`, `DeleteDays`, `ArchivePath`, `Paths` | Log/report archival + deletion windows. |
| **Notification** | `Backends`, `Smtp`, `Webhook` | Where notifications go (log, email, webhook). |

> For the exact defaults of every key, see `Get-SPConfigDefaults` in
> `Modules\SP.Core\SP.Config.psm1` (the runtime source of truth).

---

## 5. Authentication

The toolkit authenticates to ISC five ways, selected by `Authentication.Mode`:
**`ConfigFile`**, **`Vault`**, **`DpapiCredential`**, and **`ScheduledVault`** all use
an OAuth **Personal Access Token (PAT)**; **`Token`** uses a short-lived browser bearer
token. Read §5.1 first to create the credential, then pick a storage mode (§5.2–§5.6).

### 5.1 The ISC credential: a Personal Access Token (PAT)

For anything beyond a quick browser-token run, the toolkit uses the OAuth 2.0
**`client_credentials`** grant. In the ISC admin console this is created as a
**Personal Access Token** — despite the name, it issues a **`ClientId` + `ClientSecret`**
pair and is the standard non-interactive service credential. Create it under
**Admin → Preferences → Personal Access Tokens** (or **Security Settings → API
Management** with `ORG_ADMIN`).

A PAT **inherits the permissions of the identity that creates it**, then the selected
**scopes** further restrict it. Create it as a **`CERT_ADMIN`** (campaigns +
certifications — all the toolkit needs) or **`ORG_ADMIN`**, and grant the scopes that
match your intended use:

| Use case | Scopes to grant | Covers |
|---|---|---|
| **Read-only audit** (query + audit existing campaigns, reports) | `idn:campaign:read`, `idn:campaign-report:read`, `sp:report:read`, `sp:search:read`, `idn:sources:read`, `idn:accounts:read` | Audit, search, governance/data-quality reporting, leadership rollups. |
| **Full toolkit** (also create/activate/decide campaigns) | `idn:campaign:manage`, `idn:campaign-report:manage`, `sp:report:manage`, `sp:search:read`, `idn:sources:read`, `idn:accounts:read` | Everything above **plus** campaign creation, delta-cert/disconnected-app campaign creation, decisions, sign-off. `…:manage` is a superset of `…:read`. |
| **Delta cert / orchestrator** (account-activities) | the Full-toolkit set **plus** `sp:scopes:all` *(or a browser token)* | `GET /v3/account-activities` has **no** granular scope — it requires `sp:scopes:all`. Affects `Invoke-SPADDeltaCert`, `Invoke-SPDeltaReport`, and the daily orchestrator steps 2–5. |

> **Why `sp:search:read` for a "read-only" PAT?** Delta cert and disconnected-app
> correlation resolve identities (and their managers) via `GET /v3/search/identities/{id}`
> and `POST /v3/search`. The plain `idn:campaign:read` set is **not** sufficient for those.
> For the full endpoint-to-scope mapping and a click-by-click walkthrough, see
> **`docs/SANDBOX-API-SETUP.md`** (sandbox-framed but the steps apply to any tenant).

### 5.2 ConfigFile
`ClientId` + `ClientSecret` are read directly from config. Simplest, but the secret
sits in a file in plain text — only use with `settings.local.json` (gitignored) or the
mock, never in the committed `settings.json`.

### 5.3 Vault (recommended for real tenants)

Credentials live in an **encrypted vault file** unlocked by a passphrase — the secret
is never stored in plain text on disk, and the passphrase is never written to disk at
all. Set up once:

```powershell
.\Scripts\New-SPVault.ps1            # interactive: prompts for passphrase + ClientId/Secret
.\Scripts\New-SPVault.ps1 -ClientId 'abc123'   # pre-supply the id, prompt for the rest
.\Scripts\New-SPVault.ps1 -VaultPath 'D:\Secure\team.enc'   # custom location
```

Then set `Authentication.Mode = "Vault"`. The vault is created at
`Authentication.Vault.VaultPath` (default `.\Data\sp-vault.enc`); at runtime the
toolkit prompts for (or is given) the passphrase to unlock it.

**How the encryption works.** The vault is authenticated encryption — **AES-256-CBC for
confidentiality plus HMAC-SHA256 for integrity** (encrypt-then-MAC, so tampering is
detected before decryption). The passphrase is stretched with **PBKDF2 (`Rfc2898DeriveBytes`,
600,000 iterations** — tunable via `Vault.Pbkdf2Iterations`) into a 64-byte key that is
split into a separate 32-byte AES key and 32-byte HMAC key. Each save uses a fresh random
32-byte salt and 16-byte IV, so the on-disk blob is
`[salt][IV][HMAC][ciphertext]`. **What it supports:** storing the ISC `ClientId` +
`ClientSecret` under a named key (`Vault.CredentialKey`, default `sailpoint-isc`),
rotation/re-keying by re-running `New-SPVault.ps1` (it warns before overwriting), and a
custom vault path for shared/team locations. The `*.enc` file is gitignored.

> **Store the passphrase in a password manager.** It is never logged and cannot be
> recovered — lose it and you must recreate the vault (and rotate the PAT secret).

### 5.4 DpapiCredential (automation option A -- Windows DPAPI)

Uses Windows DPAPI via PowerShell's `Export-CliXml` to store the PAT credential
encrypted to the **current Windows user + machine**. No passphrase needed at runtime --
fully unattended. Set up once as the service account:

```powershell
.\Scripts\New-SPVault.ps1 -Mode DpapiCredential    # prompts for ClientId + Secret, saves encrypted
```

Then set `Authentication.Mode = "DpapiCredential"`. The credential file is created at
`Authentication.DpapiCredential.Path` (default `.\Data\sp-dpapi-credential.xml`).

**Security properties:**
- Encrypted to the Windows user account + machine via DPAPI
- If the file is copied to another machine or user, decryption fails
- No passphrase needed at runtime -- suitable for Task Scheduler
- **Risk:** Mimikatz and similar credential dumping tools can extract DPAPI master keys
  from process memory. Some EDR/endpoint protection systems flag DPAPI operations in
  non-interactive sessions. Discuss with your SOC/EDR team before deploying.

> **When to use:** when your EDR team approves DPAPI-based credential storage, or in
> environments without aggressive endpoint monitoring. Simplest automation setup.

### 5.5 ScheduledVault (automation option B -- machine-bound key, DPAPI optional)

Stores the vault passphrase encrypted with a **machine-derived key** using the toolkit's own
AES-256-CBC crypto (same as the vault). The key mixes in a **per-install random secret** so it is
**not derivable** from public machine, user, and domain values. Requires the regular vault (§5.3) first.

> **Important (this was a security gap):** earlier versions derived the key purely from a SHA-256 of
> machine, user, domain, and a salt shipped in the repo -- all *public* values. Anyone who copied the
> key file and the vault file could recompute the key and **decrypt offline on any machine**. The
> per-install secret closes that hole.

```powershell
# Step 1: Set up the regular vault first (if not already done)
.\Scripts\New-SPVault.ps1 -Mode Vault

# Step 2: Create the scheduled key (recommended: DPAPI-protected secret -- the default)
.\Scripts\New-SPVault.ps1 -Mode ScheduledVault

#   ...or EDR-quiet (no DPAPI):
.\Scripts\New-SPVault.ps1 -Mode ScheduledVault -KeyProtection AclFile
```

Then set `Authentication.Mode = "ScheduledVault"`. The key is at
`Authentication.ScheduledVault.KeyPath` (default `.\Data\sp-scheduled-key.enc`); the per-install
secret is at `.\Data\.sv-secret` (gitignored -- never commit it).

**How it works:**
1. Your vault passphrase is encrypted with AES-256-CBC + PBKDF2 (same as the vault)
2. The encryption key is a SHA-256 over machine, user, domain, a static salt, AND the per-install secret
3. At runtime the key is reconstructed, the passphrase is decrypted, and the vault opens -- no human input
4. Copying the files to another machine or user fails to decrypt (different identity; and in Dpapi mode the secret itself will not unprotect off-box)

**Key-protection modes** (`-KeyProtection`, or `Authentication.ScheduledVault.KeyProtection`):

| Mode | How the per-install secret is stored | Off-box decryption if every file is exfiltrated? | EDR / SOC |
|---|---|---|---|
| **`Dpapi`** (default, recommended) | DPAPI-protected (CurrentUser) | No -- DPAPI will not unprotect off the box or user | ProtectedData calls may be flagged |
| **`AclFile`** (EDR-quiet) | Raw random blob in an NTFS-ACL-locked file (no DPAPI) | Possible -- if the attacker can also read the ACL-locked secret file | No DPAPI, so no endpoint alerts |

Both are far stronger than the old public-only key. **Prefer `Dpapi`** unless your SOC/EDR team
prohibits DPAPI; in that case `AclFile` still removes the "derivable from the repo" weakness while
staying endpoint-quiet -- just keep the secret file's ACLs sound.

> **Note:** `DpapiCredential` (§5.4) remains the simplest genuinely-secure unattended mode. Use
> ScheduledVault when you specifically want the AES-vault plus machine-binding model.

### 5.3.1 Choosing an automation mode

| Mode | Setup | Passphrase at runtime? | DPAPI? | EDR risk | Best for |
|---|---|---|---|---|---|
| **ConfigFile** | Edit JSON | No | No | None | Dev/mock only (secret in plain text) |
| **Vault** | `New-SPVault.ps1` | YES (interactive) | No | None | Interactive use, demos |
| **DpapiCredential** | `New-SPVault.ps1 -Mode DpapiCredential` | No | YES | Mimikatz-flaggable | Automation with EDR approval |
| **ScheduledVault** | `New-SPVault.ps1 -Mode ScheduledVault [-KeyProtection Dpapi/AclFile]` | No | Optional | Dpapi: flaggable / AclFile: none | Automation; machine-bound AES vault |
| **BrowserToken** | F12 copy-paste | No (expires in ~12 min) | No | None | Quick one-off queries |

For **scheduled tasks** (Task Scheduler, cron), use `DpapiCredential` or `ScheduledVault`.
Both are fully unattended. Your SOC/EDR team decides which is acceptable.

**Task Scheduler setup** (same for both modes):
```powershell
# 1. Log in as the service account and run the one-time setup
.\Scripts\New-SPVault.ps1 -Mode DpapiCredential   # or -Mode ScheduledVault

# 2. Create the scheduled task (as admin)
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\GovernanceToolkit\Scripts\Run-DailyGovernance.ps1' `
    -WorkingDirectory 'C:\GovernanceToolkit'

$triggers = @(
    New-ScheduledTaskTrigger -Daily -At '08:00'
    New-ScheduledTaskTrigger -Daily -At '12:00'
    New-ScheduledTaskTrigger -Daily -At '17:00'
)

Register-ScheduledTask -TaskName 'SailPoint-GovernanceToolkit' `
    -Action $action -Trigger $triggers `
    -User 'DOMAIN\svc-sailpoint' -RunLevel Highest
```

### 5.3.2 Credential Rotation Procedure

When your ISC PAT expires or is compromised, follow this procedure:

1. **Create a new PAT** in the ISC admin console (Admin > Preferences > Personal Access
   Tokens) with the same scopes as the old one.
2. **Update the credential store.** If using the vault, re-run `New-SPVault.ps1` (it
   warns before overwriting). If using ConfigFile, update `ClientId` and `ClientSecret`
   in `settings.local.json`.
3. **Test connectivity** with `Test-SPConnectivity.ps1` to confirm the new credential
   works.
4. **Verify scheduled tasks** still run successfully -- trigger the orchestrator manually
   once (`Invoke-SPDailyOrchestrator.ps1 -SkipCleanup -SkipDeltaCert ...`) and confirm
   exit code 0.
5. **Delete the old PAT** in the ISC admin console once the new one is confirmed working.

### 5.4 Token
Paste a short-lived **bearer token** (copied from an active ISC web session: F12 →
Network → copy the `Authorization` value) via the `-Token` parameter on most scripts,
or the GUI's Settings-tab token field. No PAT or scopes setup needed — it carries your
browser session's full permissions — but it expires in ~10–12 minutes, so it's for
quick ad-hoc/`account-activities` runs, not automation.

> **TLS:** the toolkit enforces TLS 1.2 (and 1.3 if the OS supports it) on every HTTPS
> call automatically — no configuration needed. This is the #1 fix for "connection
> closed" errors against ISC.

---

## 6. Environments: mock vs. real

- **Mock** — point the toolkit at the local **API-MockServer** (`http://localhost:8080`)
  using `Config\settings-mock.json`. Safe for testing, demos, and the GUI test harness;
  no real tenant calls. The mock serves the SailPoint-ISC profile with realistic seed data.
- **Real** — your ISC tenant via `settings.local.json` with real credentials (vault recommended).

`Global.EnvironmentName` feeds the **Safety** model: a non-mock environment with
`RequireWhatIfOnProd = true` will demand confirmation before mutating actions.

### 6.1 Mock Server Setup

The mock server is a **Pode**-based HTTP server that emulates the SailPoint ISC v3 API.
It lives in the separate `API-MockServer` repository with a `SailPoint-ISC` profile.

**Installing and starting the mock server:**

```powershell
# 1. Install Pode (one-time)
Install-Module -Name Pode -Scope CurrentUser -Force

# 2. Start the mock server (from the API-MockServer directory)
cd <path-to-API-MockServer>
pwsh -NoProfile -File Start-MockServer.ps1
# Server listens on http://localhost:8080 by default
```

**Seed data inventory:**

| Entity | Count | Details |
|---|---|---|
| Identities | 82 | 1 President, 3 VPs, 12 Directors, 60 ICs, 2 orphans (no manager), 2 service accounts |
| Campaigns | 4 | 1 ACTIVE (SOURCE_OWNER), 1 COMPLETED (MANAGER), 1 STAGED (SEARCH), 1 ACTIVE delta cert |
| Certifications | 18 | 4 signed-off, 14 unsigned |
| Account activities | multiple | GRANT_ACCESS and REVOKE_ACCESS events with relative timestamps |

**Which scripts work against the mock:**

All CLI scripts and the full GUI work against the mock. Scripts that create campaigns
will create them in the mock's in-memory state; restarting the mock server resets all
state to the seed data.

**Switching between mock and real:**

```powershell
# Run against mock
.\Scripts\Invoke-SPCampaignAudit.ps1 -ConfigPath .\Config\settings-mock.json -Status COMPLETED

# Run against real tenant
.\Scripts\Invoke-SPCampaignAudit.ps1 -ConfigPath .\Config\settings.local.json -Status COMPLETED
```

The key difference in `settings-mock.json` is that all URLs point to `http://localhost:8080`
instead of `https://<tenant>.api.identitynow.com`, and `Safety.RequireWhatIfOnProd` is
`false` since the mock is safe to mutate.

---

## 7. The Safety model (read before mutating anything)

Mutating operations (creating/completing campaigns, deleting templates/filters,
deciding work items, etc.) are governed by `Safety`:

| Control | Effect |
|---|---|
| `RequireWhatIfOnProd` | On a real environment, mutating actions require explicit confirmation (CLI `-WhatIf` preview, GUI Yes/No prompt) before they execute. |
| `MaxCampaignsPerRun` | Hard cap — a run that would exceed it is refused (no partial silent truncation; you're told the count vs. the cap). |
| `AllowCompleteCampaign` | The terminal "complete campaign" / bulk-approve style actions are **blocked unless this is explicitly `true`.** |

- **CLI:** mutating scripts support `-WhatIf` (preview without executing). Honor it on
  production until you've reviewed the plan.
- **GUI:** destructive buttons show a confirmation dialog with the affected count; the
  SDK Features tab routes write actions through the same Safety gates and surfaces a
  "blocked by Safety…" status rather than failing silently.

---

## 8. Output, reports, and logs

| Location | Contents |
|---|---|
| `Logs\` | Structured run logs (`<FilePrefix>-*.log`), severity-filtered. |
| `Audit\` | Campaign audit reports (HTML / text / JSONL); **adaptive reports** under `Audit\adaptive\`, leadership reports under `Audit\leadership\`. |
| `DeltaCert\` | Delta-certification run output + history. |
| `Reports\` | Governance reports, metrics, health checks. |
| `Evidence\` | Test/campaign evidence bundles. |
| `DisconnectedApps\` | Imports, snapshots, and disconnected-app reports. |
| `Data\` | The encrypted vault (`sp-vault.enc`). |

> **Paths are anchored to the toolkit root.** The relative paths in `settings.json`
> (`Audit.OutputPath = .\Audit`, `Logging.Path = .\Logs`, `Audit.CachePath`,
> `DeltaCert.OutputPath`, etc.) are resolved to **`<toolkit-root>\…`** at load time, so output,
> cache, and logs land in the **same place no matter which directory you launch a script from**
> — running from `Scripts\` no longer scatters them to `Scripts\Audit\…` or your home folder.
> To pin output elsewhere, set an **absolute** path in `settings.json` (absolute values are used
> as-is) or pass `-OutputPath` to a script.

### Output modes (CLI)
Most reporting scripts take `-OutputMode`:

| Mode | Meaning |
|---|---|
| `Console` | Human-readable to the terminal. |
| `JSON` | Machine-readable JSON to stdout (for piping/automation). |
| `Both` | Console **and** a JSON file. |
| `CSV` / `HTML` | Where supported (search, data-quality, governance, weekly digest), a CSV or HTML artifact. |

---

## 9. Glossary (ISC terms)

| Term | Meaning |
|---|---|
| **Campaign** | A certification campaign — a scheduled review of access. Types: `MANAGER`, `SOURCE_OWNER`, `SEARCH`, `ROLE_COMPOSITION`. |
| **Certification** | One reviewer's slice of a campaign (their queue of items to decide). |
| **Access Review Item (ARI)** | A single access (entitlement/role/access-profile) on one identity awaiting a decision. |
| **Decision** | The reviewer's verdict: `APPROVE` (keep) or `REVOKE` (remove); undecided = pending. |
| **Sign-off** | A reviewer finalizing their certification once all items are decided. |
| **Reassign** | Moving review items from one reviewer to another (sync ≤50, async ≤500). |
| **Entitlement / Access Profile / Role** | Units of access, increasing in aggregation (entitlement → access profile → role). |
| **Source** | A connected system (AD, Okta, etc.) that ISC aggregates accounts/entitlements from. |
| **Identity** | A person/account in ISC, with attributes and a lifecycle state. |
| **Lifecycle state** | `active`, `inactive`, `terminated`, `leaver`, `prehire`, etc. |
| **Delta certification** | Re-certifying only recently-*changed* access (e.g. new grants in the last 24h) rather than everything. |
| **Disconnected application** | An app not directly integrated with ISC; access is imported via CSV and certified through a generated campaign. |
| **Campaign template** | A reusable campaign definition (SDK feature) that can be scheduled. |
| **Campaign filter** | A reusable include/exclude rule set for campaigns (SDK feature). |
| **Work item** | A task assigned to a user (certification, approval, remediation, manual action). |
| **Workflow** | An ISC automation definition (event/scheduled/external trigger). |
| **OOO fallback** | An out-of-office fallback-reviewer workflow (SDK feature). |
| **Adaptive report** | A composable HTML report assembled from independent components (KPI cards, heatmap, top-N, drill-down tree, group table) over a generic "groups containing members" view of governance data, plus a baseline report library (inventory, privileged review, orphaned/disabled, SoD, roster, access-cert, exec summary). See `Invoke-SPAdaptiveReport`. |
| **Anchor (adaptive reports)** | How SailPoint data maps into the adaptive report engine: **entitlement-centric** (entitlement → group, identity → member) or **campaign-centric** (campaign → group). |

---

## 10. Getting help & exit codes

- **Per-command help:** `.\Scripts\<Script>.ps1 -Help` prints full usage for any CLI script.
- **Exit codes:** CLI scripts return `0` on success and non-zero on failure (the
  specific codes are documented per script in the CLI Playbook). Automation should
  check the exit code, not just stdout.
- **Connectivity:** `Test-SPConnectivity.ps1` verifies auth + tenant reachability before
  a real run.

---

## 11. Notification Setup

The toolkit can send notifications via email (SMTP) and/or webhook. Notifications are
triggered by scripts that support `-SendNotification` (data quality, weekly digest,
governance metrics) and by the daily orchestrator summary.

### 11.1 SMTP configuration

Add your SMTP server details to the `Notification.Smtp` section of `settings.local.json`:

```json
{
    "Notification": {
        "Backends": ["Log", "Email"],
        "Smtp": {
            "Server": "smtp.corp.com",
            "Port": 587,
            "From": "sailpoint-toolkit@corp.com",
            "UseSsl": true
        }
    }
}
```

> The `Audit.Smtp` section can override these for audit-specific report delivery. When
> `Audit.Smtp.Server` is empty, audit report delivery falls back to `Notification.Smtp`.

### 11.2 Webhook configuration

For Slack, Teams, or any HTTP endpoint, configure `Notification.Webhook`:

```json
{
    "Notification": {
        "Backends": ["Log", "Webhook"],
        "Webhook": {
            "Url": "https://hooks.slack.com/services/T00/B00/xxx",
            "Method": "POST",
            "Headers": { "Content-Type": "application/json" },
            "IncludePayload": true
        }
    }
}
```

### 11.3 Testing notifications

```powershell
# Test SMTP delivery via a data quality report (low-impact read-only operation)
.\Scripts\Invoke-SPDataQualityReport.ps1 -SendNotification -NotifyRecipients 'you@corp.com'

# Test webhook delivery via the weekly digest
.\Scripts\Invoke-SPWeeklyDigest.ps1 -SendNotification
```

Successful delivery logs a `Severity=INFO` entry with `Action=SendNotification` in the
daily log. Failed delivery logs a `Severity=ERROR` with the SMTP/HTTP error details.

---

## 12. Report Catalog

The toolkit generates many report types. Use this catalog to find the right report for
your audience and frequency.

| Report Name | Script | Audience | Frequency | Contents |
|---|---|---|---|---|
| Campaign Audit | `Invoke-SPCampaignAudit.ps1` | Compliance, auditors | After campaigns complete | Per-campaign HTML/text + combined summary + JSONL audit trail |
| Leadership Rollup | `Invoke-SPCampaignAudit.ps1 -IncludeLeadershipRollup` | VP/Director leadership | After campaigns complete | Per-leader decision summaries rolled up the org tree |
| Delta Report | `Invoke-SPDeltaReport.ps1` | Daily operations | Daily | Grants, revocations, pending certs, anomalies (HTML + JSONL) |
| Governance Health Check | `Invoke-SPGovernanceHealthCheck.ps1` | Governance leads | Weekly/before audits | Six-dimension health report with pass/fail/warn + overall grade |
| Governance Report | `Invoke-SPGovernanceReport.ps1` | Auditors, governance leads | Quarterly/on-demand | Combined audit + leadership + policy + data quality package |
| Data Quality Report | `Invoke-SPDataQualityReport.ps1` | IAM operations | Weekly/on-demand | Orphan accounts, identity-attribute quality, source-aggregation health |
| Governance Metrics | `Invoke-SPGovernanceMetrics.ps1` | KPI dashboards | Daily (automated) | KPI time-series capture + trend reports + completion forecasts |
| Weekly Digest | `Invoke-SPWeeklyDigest.ps1` | Governance leadership | Weekly | Campaign activity, health, identity risk, reviewer performance, remediation |
| Leadership Distribution | `Invoke-SPReportDistribution.ps1` | Per-leader delivery | After campaigns | Band-filtered per-leader reports, optionally emailed |
| Adaptive Report (composable) | `Invoke-SPAdaptiveReport.ps1` | Presentation, analysis | On-demand | KPI cards, heatmap, top-N, drill-down tree, group table |
| Adaptive Baseline: Inventory | `Invoke-SPAdaptiveReport.ps1 -BaselineReport inventory` | Access review | On-demand | Full entitlement/access-profile/role inventory |
| Adaptive Baseline: Privileged | `Invoke-SPAdaptiveReport.ps1 -BaselineReport privileged` | Security | Quarterly | Privileged-access review |
| Adaptive Baseline: Orphaned | `Invoke-SPAdaptiveReport.ps1 -BaselineReport orphaned` | IAM operations | Monthly | Orphaned/disabled-account access |
| Adaptive Baseline: SoD | `Invoke-SPAdaptiveReport.ps1 -BaselineReport sod` | Compliance | Quarterly | Separation-of-duties toxic-combination analysis |
| Adaptive Baseline: Roster | `Invoke-SPAdaptiveReport.ps1 -BaselineReport roster` | Certification admin | On-demand | Certification roster |
| Adaptive Baseline: Access Cert | `Invoke-SPAdaptiveReport.ps1 -BaselineReport access-cert` | Compliance | After campaigns | Access-certification attestation |
| Adaptive Baseline: Exec Summary | `Invoke-SPAdaptiveReport.ps1 -BaselineReport exec-summary` | Executives | Quarterly | Governance executive summary |
| Orchestrator Daily Summary | `Invoke-SPDailyOrchestrator.ps1` | Operations | Daily (automated) | Consolidated 11-step status + JSONL audit trail |

---

## 13. Error Reference

### 13.1 Log file format

Logs are **structured JSONL** (one JSON object per line) written to daily rotating files
in the `Logs\` directory. File naming: `<FilePrefix>-YYYY-MM-DD.log` (e.g.
`GovernanceToolkit-2026-06-05.log`).

Each log entry contains:

| Field | Description |
|---|---|
| `Timestamp` | UTC ISO 8601 with milliseconds (`2026-06-05T14:30:00.123Z`) |
| `Severity` | `DEBUG`, `INFO`, `WARN`, or `ERROR` |
| `Component` | Source module (e.g. `SP.Auth`, `SP.Campaigns`, `SP.DeltaCertRunner`) |
| `Action` | Operation being performed (e.g. `GetToken`, `CreateCampaign`) |
| `Message` | Human-readable description |
| `CorrelationID` | UUID linking related entries across a single operation |
| `User` | Windows identity running the script |
| `Environment` | `Global.EnvironmentName` value |
| `Host` | Machine name |

**Severity levels:**
- `DEBUG` -- Verbose diagnostics (only logged when `DebugMode = true` or `MinimumSeverity = DEBUG`)
- `INFO` -- Normal operations (token acquired, campaign created, report generated)
- `WARN` -- Non-fatal issues (skipped identity, rate limit approached, fallback used)
- `ERROR` -- Failures requiring attention (auth failure, API error, campaign creation failed)

### 13.2 Enabling debug mode

Set `Global.DebugMode` to `true` in `settings.local.json` (or toggle it in the GUI
Settings tab). This sets the logging minimum severity to `DEBUG` and enables verbose
output from all modules.

```json
{
    "Global": {
        "DebugMode": true
    },
    "Logging": {
        "MinimumSeverity": "DEBUG"
    }
}
```

### 13.3 Common errors and resolutions

| Error Message | Cause | Resolution |
|---|---|---|
| `CHANGE_ME value detected` | Config still has placeholder values | Replace all `CHANGE_ME` in `settings.local.json` with real tenant values |
| `Token acquisition failed` / `401 Unauthorized` | Invalid or expired PAT credentials | Verify `ClientId`/`ClientSecret`; check PAT not expired in ISC admin console; confirm scopes |
| `The underlying connection was closed` | TLS mismatch or network block | Toolkit auto-enforces TLS 1.2; check firewall allows HTTPS to `*.api.identitynow.com` |
| `429 Too Many Requests` | ISC rate limit exceeded (95 req/10s) | The toolkit auto-retries with exponential backoff; if persistent, increase `Api.RetryDelaySeconds` |
| `MaxPaginationPages exceeded` | More pages than the safety ceiling | Increase `Api.MaxPaginationPages` or narrow your query (add filters, reduce `DaysBack`) |
| `MaxCampaignsPerRun exceeded` | Too many campaigns would be created | Increase `Safety.MaxCampaignsPerRun` after reviewing the plan, or narrow the scope |
| `AllowCompleteCampaign is false` | Tried to complete/bulk-approve a campaign | Set `Safety.AllowCompleteCampaign = true` in config if you intend to allow terminal actions |
| `No campaigns found matching filter` | Campaign name/status filter returned empty | Verify the campaign name, status, and `DaysBack` window; use `-CampaignNameContains` for fuzzy search |
| `Vault decryption failed` | Wrong passphrase or corrupted vault file | Re-enter passphrase; if lost, recreate vault with `New-SPVault.ps1` and rotate the PAT |
| `AccountDeletionThresholdPct exceeded` | Disconnected app CSV has too many removals vs. previous snapshot | Verify the CSV is a full export (not a delta); if legitimate mass removal, temporarily increase `AccountDeletionThresholdPct` |
| `Identity not found for correlation` | Disconnected app email does not match any ISC identity | Verify the `e-mail` in the CSV matches the ISC identity's email; check `CorrelationAttribute` setting |
| `sp:scopes:all required` | Script needs account-activities endpoint | Add `sp:scopes:all` to the PAT scopes, or use a browser `-Token` instead |
| `Invoke-RestMethod: The operation has timed out` | API call exceeded `TimeoutSeconds` | Increase `Api.TimeoutSeconds` (default 60); check network latency to ISC |
| `Execution policy violation` | Script blocked by PowerShell execution policy | Set `RemoteSigned` for the current user or pass `-ExecutionPolicy Bypass` |
| `WPF STA thread required` | GUI launched from a non-STA PowerShell session | Use `Show-SPDashboard.ps1` (it auto-relaunches in STA); do not run the GUI from PowerShell ISE |

---

*Next: the [CLI Playbook](cli-playbook.md) (operators / automation) and the
[GUI Playbook](gui-playbook.md) (interactive analysts / reviewers).*

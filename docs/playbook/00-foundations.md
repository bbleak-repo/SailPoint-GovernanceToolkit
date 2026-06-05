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
| **.NET Framework** | **4.7.2+** (only for the GUI dashboard / WPF). `Show-SPDashboard.ps1` checks this at launch and exits with a clear error and download link if the requirement isn't met. |
| **Network / TLS** | Outbound HTTPS to your ISC tenant. The toolkit forces **TLS 1.2 (and 1.3 where available)** automatically. |
| **ISC credentials** | An ISC **OAuth client** (client_credentials grant) with `ClientId` + `ClientSecret`, or a personal **bearer token** from the browser for short-lived use. |
| **Pester** (optional) | 5.x — only needed to run the test suite. |

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
| **Authentication** | `Mode` | `ConfigFile`, `Vault`, or `Token` — see §5. |
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
| **Metrics / Governance / Leadership** | various | KPI persistence, governance report depth, leadership band mapping. |
| **Retention** | `Enabled`, `ArchiveDays`, `DeleteDays`, `ArchivePath`, `Paths` | Log/report archival + deletion windows. |
| **Notification** | `Backends`, `Smtp`, `Webhook` | Where notifications go (log, email, webhook). |

> For the exact defaults of every key, see `Get-SPConfigDefaults` in
> `Modules\SP.Core\SP.Config.psm1` (the runtime source of truth).

---

## 5. Authentication

Set `Authentication.Mode` to one of:

### ConfigFile
`ClientId` + `ClientSecret` are read directly from config. Simplest, but the secret
sits in a file — only use with `settings.local.json` (gitignored) or for the mock.

### Vault (recommended for real tenants)
Credentials live in an **encrypted vault** (`AES-256-CBC` with `PBKDF2`,
600,000 iterations) unlocked by a passphrase — the secret is never stored in plain
text on disk. Set up once:

```powershell
.\Scripts\New-SPVault.ps1            # interactive: prompts for passphrase + ClientId/Secret
.\Scripts\New-SPVault.ps1 -ClientId 'abc123'   # pre-supply the id, prompt for the rest
```

The vault is created at `Authentication.Vault.VaultPath` (default `.\Data\sp-vault.enc`).
At runtime the toolkit prompts for (or is given) the passphrase to unlock it.

### Token
Paste a short-lived **bearer token** (e.g. copied from the ISC web session) via the
`-Token` parameter on most scripts, or the GUI's token field. Good for quick ad-hoc
runs; expires quickly.

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
| `Audit\` | Campaign audit reports (HTML / text / JSONL). |
| `DeltaCert\` | Delta-certification run output + history. |
| `Reports\` | Governance reports, metrics, health checks. |
| `Evidence\` | Test/campaign evidence bundles. |
| `DisconnectedApps\` | Imports, snapshots, and disconnected-app reports. |
| `Data\` | The encrypted vault (`sp-vault.enc`). |

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

---

## 10. Getting help & exit codes

- **Per-command help:** `.\Scripts\<Script>.ps1 -Help` prints full usage for any CLI script.
- **Exit codes:** CLI scripts return `0` on success and non-zero on failure (the
  specific codes are documented per script in the CLI Playbook). Automation should
  check the exit code, not just stdout.
- **Connectivity:** `Test-SPConnectivity.ps1` verifies auth + tenant reachability before
  a real run.

---

*Next: the [CLI Playbook](cli-playbook.md) (operators / automation) and the
[GUI Playbook](gui-playbook.md) (interactive analysts / reviewers).*

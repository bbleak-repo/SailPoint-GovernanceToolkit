# SailPoint ISC Governance Toolkit

A PowerShell 5.1 toolkit for automated testing of SailPoint IdentityNow (ISC) certification campaign workflows. The toolkit creates, activates, and validates certification campaigns against the ISC REST API v3, producing structured JSONL evidence and HTML reports for UAT sign-off.

For a 15-minute setup walkthrough, see [QUICKSTART.md](QUICKSTART.md).
For the comprehensive interactive guide, open [USER-GUIDE.html](USER-GUIDE.html) in your browser.

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| PowerShell  | 5.1 Desktop | Windows PowerShell only. PS Core / PS 7 not supported. |
| Windows     | 10 / 11 / Server 2019+ | WPF requires Windows. CLI works on any edition. |
| .NET Framework | 4.5+ | Required for WPF dashboard. Included in Windows 10+. |
| Pester      | 5.x | Required only for running unit tests in Tests/. |
| SailPoint ISC API credentials | - | OAuth 2.0 PAT or browser token. Read-only audit needs 6 scopes (see `docs/SANDBOX-API-SETUP.md`). |

---

## Quick Start

**Step 1: Clone or extract the toolkit**

```powershell
# No build step required - pure PowerShell modules
cd C:\Path\To\SailPoint-GovernanceToolkit
```

**Step 2: Configure settings.json**

On first run, the toolkit auto-generates `Config\settings.json` from a template. Open the file and replace all `CHANGE_ME` values:

```powershell
.\Scripts\Test-SPConnectivity.ps1
# First run will create Config\settings.json and exit with guidance
```

Key values to update:
- `Global.EnvironmentName` - label for this environment (e.g., Sandbox)
- `Authentication.ConfigFile.TenantUrl` - `https://<tenant>.api.identitynow.com`
- `Authentication.ConfigFile.OAuthTokenUrl` - `https://<tenant>.api.identitynow.com/oauth/token`
- `Authentication.ConfigFile.ClientId` / `ClientSecret`
- `Api.BaseUrl` - `https://<tenant>.api.identitynow.com/v3`

**Step 3: Test connectivity**

```powershell
.\Scripts\Test-SPConnectivity.ps1
```

Expected output: three PASS steps (config load, token acquisition, live API call).

**Step 4: Run smoke tests**

```powershell
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke -WhatIf
# Dry-run first to validate without making API calls

.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke
# Execute against ISC
```

**Step 5: View reports**

Evidence JSONL files are written to `Evidence\<TestId>\`. HTML reports go to `Reports\`. Open reports in a browser or use the GUI dashboard.

---

## Configuration

The toolkit uses a single `Config\settings.json` file. A complete annotated structure:

```json
{
  "Global": {
    "EnvironmentName": "Sandbox",
    "DebugMode": false,
    "ToolkitVersion": "1.0.0"
  },
  "Authentication": {
    "Mode": "ConfigFile",
    "ConfigFile": {
      "TenantUrl": "https://tenant.api.identitynow.com",
      "OAuthTokenUrl": "https://tenant.api.identitynow.com/oauth/token",
      "ClientId": "...",
      "ClientSecret": "..."
    },
    "Vault": {
      "VaultPath": ".\\Data\\sp-vault.enc",
      "Pbkdf2Iterations": 600000,
      "CredentialKey": "sailpoint-isc"
    }
  },
  "Api": {
    "BaseUrl": "https://tenant.api.identitynow.com/v3",
    "TimeoutSeconds": 60,
    "RetryCount": 3,
    "RateLimitRequestsPerWindow": 95,
    "RateLimitWindowSeconds": 10
  },
  "Testing": {
    "IdentitiesCsvPath": ".\\Config\\test-identities.csv",
    "CampaignsCsvPath": ".\\Config\\test-campaigns.csv",
    "EvidencePath": ".\\Evidence",
    "ReportsPath": ".\\Reports"
  },
  "Safety": {
    "MaxCampaignsPerRun": 10,
    "RequireWhatIfOnProd": true,
    "AllowCompleteCampaign": false
  },
  "Audit": {
    "OutputPath": ".\\Audit",
    "DefaultDaysBack": 365,
    "DefaultIdentityEventDays": 2,
    "DefaultStatuses": ["COMPLETED", "ACTIVE"],
    "IncludeCampaignReports": true,
    "IncludeIdentityEvents": true
  }
}
```

For production environments, set `Authentication.Mode` to `Vault` and store credentials using `New-SPVault.ps1` (see Vault section below).

For the complete list of all configuration keys including Logging, Notification, Retention, and advanced API settings, see `Config/settings.json`.

### Local Configuration Override (settings.local.json)

The toolkit supports a `settings.local.json` override file for per-developer or per-machine configuration. When `Config\settings.local.json` exists alongside `Config\settings.json`, the toolkit automatically uses the local file instead of the tracked template.

**How it works:**

1. Every CLI script and the GUI call `Resolve-SPConfigPath` to locate the config file.
2. `Resolve-SPConfigPath` checks for `Config\settings.local.json` first.
3. If it exists, that file is used. Otherwise, `Config\settings.json` is used.

**Why use it:**

- Keep the tracked `settings.json` as a clean `CHANGE_ME` template that documents the expected structure.
- Store your real tenant credentials, paths, and environment-specific overrides in `settings.local.json` without risk of committing them.
- Each team member can maintain their own local file targeting different tenants or modes.

**Setup:**

```powershell
# Copy the template to create your local override
Copy-Item Config\settings.json Config\settings.local.json

# Edit the local copy with your real values
notepad Config\settings.local.json
```

The file is already gitignored (`Config/*.local.json` is in `.gitignore`). No additional configuration is needed -- the toolkit detects and uses it automatically.

**Precedence:** If a `-ConfigPath` parameter is passed to any script, that explicit path takes priority over both `settings.local.json` and `settings.json`.

---

## Authentication Modes

The toolkit supports three authentication modes, configured via `Authentication.Mode` in settings.json. Two of them (`ConfigFile`, `Vault`) use an OAuth PAT; the third uses a browser token.

### Creating the API client (Personal Access Token)

The non-interactive credential is an ISC **Personal Access Token (PAT)** — the OAuth 2.0 `client_credentials` grant, which yields a `ClientId` + `ClientSecret` pair. Create it under **Admin → Preferences → Personal Access Tokens** as a `CERT_ADMIN` (or `ORG_ADMIN`) identity. A PAT inherits the creating identity's permissions, narrowed by the scopes you grant:

| Use case | Scopes |
|----------|--------|
| Read-only audit (query/audit existing campaigns + reports) | `idn:campaign:read`, `idn:campaign-report:read`, `sp:report:read`, `sp:search:read`, `idn:sources:read`, `idn:accounts:read` |
| Full toolkit (also create/activate/decide campaigns) | `idn:campaign:manage`, `idn:campaign-report:manage`, `sp:report:manage`, `sp:search:read`, `idn:sources:read`, `idn:accounts:read` |
| Delta cert / orchestrator (`/v3/account-activities`) | the above **plus** `sp:scopes:all` (no granular scope exists) or a browser token |

`sp:search:read` is required even for read-only use because delta cert and disconnected-app correlation resolve identities via `/v3/search`. For the full endpoint-to-scope mapping and a click-by-click walkthrough, see [`docs/SANDBOX-API-SETUP.md`](docs/SANDBOX-API-SETUP.md).

### ConfigFile

Reads `ClientId` and `ClientSecret` directly from settings.json. The client secret is stored in plain text.

Use only in isolated development environments where the config file is not shared or committed to version control.

### Vault

Credentials are stored in an authenticated-encryption vault file (`Data\sp-vault.enc` by default): **AES-256-CBC for confidentiality + HMAC-SHA256 for integrity** (encrypt-then-MAC), with the passphrase stretched via PBKDF2 (600,000 iterations) into separate encryption and authentication keys. The passphrase is never written to disk. Re-running `New-SPVault.ps1` rotates/re-keys the vault (it warns before overwriting).

```powershell
# One-time setup
.\Scripts\New-SPVault.ps1

# Switch mode in settings.json
"Authentication": { "Mode": "Vault" }
```

Use this mode for any shared, CI/CD, or production-adjacent environment.

### Browser Token

Bypasses OAuth entirely. Pass a JWT bearer token copied from an active browser session directly to the audit script via `-Token`.

```powershell
.\Scripts\Invoke-SPCampaignAudit.ps1 -Token 'eyJhbGciOiJSUzI1NiIs...' -Status COMPLETED -DaysBack 7
```

To obtain the token: open ISC admin console in a browser, open developer tools (F12), go to the Network tab, and copy the `Authorization: Bearer eyJ...` value from any API request. Tokens are typically valid for approximately 12 minutes.

This mode is intended for ad-hoc audits where configuring OAuth credentials is not practical. It is not suitable for automated or scheduled runs.

You can also set the token in the GUI Settings tab without modifying settings.json.

---

## Usage

### CLI: Invoke-GovernanceTest.ps1

Primary entry point for running certification campaign tests.

```powershell
# Run all smoke-tagged tests (dry-run)
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke -WhatIf

# Run smoke tests against ISC
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke

# Run regression suite, stop on first failure
.\Scripts\Invoke-GovernanceTest.ps1 -Tags regression -StopOnFirstFailure

# Run a single test by ID
.\Scripts\Invoke-GovernanceTest.ps1 -TestId TC-003

# Run all tests and output JSON results
.\Scripts\Invoke-GovernanceTest.ps1 -OutputMode JSON

# Run with custom config path
.\Scripts\Invoke-GovernanceTest.ps1 -ConfigPath 'D:\Configs\prod-settings.json' -Tags smoke -WhatIf
```

OutputMode options:
- `Console` (default) - colored pass/fail output to terminal
- `JSON` - machine-parseable result object
- `Both` - console output followed by JSON

### Audit: Invoke-SPCampaignAudit.ps1

Post-campaign audit reporting for certification campaigns. Queries completed or active
campaigns, collects all certifications and review item decisions, fetches identity lifecycle
events for revoked identities, and produces per-campaign HTML and text reports plus a
combined summary and a JSONL audit trail.

**Requirements:** At least one campaign filter must be specified (`-CampaignName`,
`-CampaignNameStartsWith`, `-CampaignNameContains`, or `-Status`). Without a filter the
script exits with code 2.

```powershell
# Audit all campaigns completed in the last 7 days
.\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 7

# Audit a specific campaign by exact name
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignName 'Q1 2026 Access Review'

# Audit all campaigns whose name begins with a prefix
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignNameStartsWith 'Q1'

# Audit campaigns whose name contains a keyword (substring match via ISC 'co' filter)
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignNameContains 'entitlement' -DaysBack 90

# Audit active and completed campaigns, write JSON result
.\Scripts\Invoke-SPCampaignAudit.ps1 -Status ACTIVE, COMPLETED -DaysBack 30 -OutputMode JSON

# Use a browser token instead of configured OAuth credentials
.\Scripts\Invoke-SPCampaignAudit.ps1 -Token 'eyJhbGciOiJSUzI1NiIs...' -Status COMPLETED -DaysBack 7

# Use a locally exported campaign report CSV instead of the API
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignName 'Annual Review' -CampaignReportCsvPath 'C:\Reports\annual.csv'

# Write output to a custom directory
.\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -OutputPath 'D:\AuditReports'
```

**Output structure (default: .\Audit\):**

```
Audit\
    <CampaignName>\
        <CampaignName>_audit.html     # Per-campaign HTML report
        <CampaignName>_summary.txt    # Per-campaign text summary
    CampaignAudit_<CorrelationID>.html  # Combined HTML report (all campaigns)
    CampaignAudit_<CorrelationID>.jsonl # JSONL audit trail
```

**Per-campaign HTML report sections:**

Each HTML report opens with an Executive Summary Dashboard: a status badge, decision
breakdown donut, remediation completion bar, risk scorecard, and reviewer response time
summary. The detailed sections follow:

1. Campaign Summary (name, status, dates, duration, certification count)
2. Reviewer Accountability (primary certifiers and reassignments with sign-off proof)
3. Reviewer Performance (time-to-decision metrics per reviewer, color-coded by response time)
4. Decision Summary (approved, revoked, and pending items with identity and entitlement detail)
5. Campaign Reports (Campaign Status Report and Certification Signoff Report from ISC)
6. Remediation and Reassignment Proof (item-level completion status and reassignment chain)
7. Audit Metadata (correlation ID, generation timestamp, filters applied)

**JSONL audit trail format (one JSON object per line):**

```json
{"CorrelationID":"...","CampaignId":"camp-abc","CampaignName":"Q1 Review","AuditedAt":"...","ApproveCount":45,"RevokeCount":12,"PendingCount":0}
```

**Configuration (settings.json Audit section):**

```json
"Audit": {
    "OutputPath": ".\\Audit",
    "DefaultDaysBack": 365,
    "DefaultIdentityEventDays": 2,
    "DefaultStatuses": ["COMPLETED", "ACTIVE"],
    "IncludeCampaignReports": true,
    "IncludeIdentityEvents": true
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Audit completed successfully |
| 1 | No campaigns matched the filter criteria |
| 2 | Parameter error (no campaign filter specified) |
| 3 | Authentication or API error |
| 4 | Configuration error (settings.json missing or invalid) |

#### Sample Output (Audit-Mock Directory)

The `Audit-Mock/` directory contains pre-generated audit reports from three representative campaign types: an annual access review, a source owner review, and an AD delta cert. These files serve as an offline reference so you can see the exact HTML, TXT, and JSONL output the toolkit produces without connecting to an ISC tenant.

Use the samples to:

- **Train reviewers** on the report format before running a live audit.
- **Validate report rendering** in your environment (browser, PDF printer, mail client).
- **Feed the GUI dashboard** -- point the Audit tab at `Audit-Mock\` to explore the dashboard without live data.

The directory structure mirrors the live `Audit\` output documented above.

### Delta Cert: Invoke-SPADDeltaCert.ps1

Daily AD access change detection. Queries SailPoint ISC for `GRANT_ACCESS` events on specified AD sources within a configurable time window, groups affected identities by manager, and creates one SEARCH-type certification campaign per manager group. On quiet days with no new access grants, the script exits with code 1 (expected no-op).

**Scope requirement:** `GET /v3/account-activities` requires `sp:scopes:all` or a browser token. The standard read-only PAT scopes are not sufficient for this endpoint.

```powershell
# Basic daily run -- create campaigns for managers of identities who got new AD access
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123'

# Dry-run -- show what campaigns would be created without making write API calls
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -WhatIf

# Multiple AD sources with extended look-back window and 3-day deadline
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId @('src-abc','src-def') -HoursBack 48 -DeadlineDays 3

# SourceOwner mode -- ISC routes certification items to each source's owner
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -ReviewerMode SourceOwner

# Run cleanup of stale campaigns before creating new ones
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -RunCleanup

# Use a browser token instead of OAuth credentials
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -Token 'eyJhbGciOiJSUzI1...'

# Include manager-less identities, routing them to a fallback reviewer
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -FallbackReviewerIdentityId 'mgr-fallback-id'
```

**Reviewer modes:**

| Mode | Behavior |
|------|----------|
| `Manager` (default) | One SEARCH campaign per manager. Each manager reviews only their direct reports who received new AD access. |
| `SourceOwner` | One SOURCE_OWNER campaign per source ID. ISC routes items to whoever owns each source. |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Campaigns created (or WhatIf completed) |
| 1 | No AD grant events found in the time window |
| 2 | Parameter error |
| 3 | Authentication error |
| 4 | Configuration error |
| 5 | Campaign creation/activation error |

### Delta Cert Escalation: Invoke-SPDeltaCertEscalate.ps1

Escalates stale delta cert certifications by reassigning them up the org tree. Finds active delta cert certifications with no reviewer action past a configurable threshold and reassigns each to the current reviewer's manager. ISC sends its own notification email to the new reviewer on reassignment.

```powershell
# Dry-run -- show which stale certifications would be escalated
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf

# Escalate stale certifications using a browser token
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -Token 'eyJhbGciOiJSUzI1...'

# Aggressive escalation -- 12-hour threshold, max 1 hop
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 12 -MaxEscalationLevels 1
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Escalation completed (or WhatIf) |
| 1 | No stale certifications found |
| 3 | Authentication error |
| 4 | Configuration error |
| 5 | Escalation error |

**Configuration (settings.json DeltaCert section):**

```json
"DeltaCert": {
    "SourceIds": ["src-abc123"],
    "DefaultHoursBack": 24,
    "DefaultDeadlineDays": 2,
    "FallbackReviewerIdentityId": "",
    "CampaignNamePrefix": "AD Delta Cert",
    "MaxCampaignsPerRun": 50,
    "CleanupDaysStale": 3,
    "OutputPath": ".\\DeltaCert",
    "DefaultReviewerMode": "Manager",
    "ExcludeLifecycleStates": ["terminated", "inactive", "leaver", "prehire"],
    "ExcludeDisplayNamePatterns": [],
    "ExcludeIdentityIds": [],
    "Escalation": {
        "DefaultStaleHours": 24,
        "MaxEscalationLevels": 2,
        "CampaignNamePrefix": "AD Delta Cert"
    }
}
```

### Campaign Search: Invoke-SPCampaignSearch.ps1

Unified campaign search and analysis tool. Combines keyword, type, status, and date filtering with deadline urgency classification, reviewer workload analysis, identity decision history, source coverage analysis, and side-by-side campaign comparison into a single CLI.

At least one filter or analysis parameter is required. Without any filter the script exits with code 2.

```powershell
# Find all MANAGER campaigns from Q1
.\Scripts\Invoke-SPCampaignSearch.ps1 -Type MANAGER -CreatedAfter '2026-01-01' -CreatedBefore '2026-03-31'

# Show deadline urgency for all active campaigns
.\Scripts\Invoke-SPCampaignSearch.ps1 -Status ACTIVE -ShowDeadlines

# Find all decisions about a specific identity in the last year
.\Scripts\Invoke-SPCampaignSearch.ps1 -IdentityId 'id-001' -Status COMPLETED -DaysBack 365

# Side-by-side campaign comparison as HTML
.\Scripts\Invoke-SPCampaignSearch.ps1 -CompareIds 'camp-001','camp-002' -OutputMode HTML

# Reviewer workload analysis
.\Scripts\Invoke-SPCampaignSearch.ps1 -ReviewerIdentityId 'id-reviewer-001' -DaysBack 90

# Source coverage analysis -- which sources have been audited
.\Scripts\Invoke-SPCampaignSearch.ps1 -SourceCoverage -DaysBack 180
```

**Key parameters:**

| Parameter | Description |
|-----------|-------------|
| `-Keyword` | Substring search against campaign names (ISC `co` filter) |
| `-Type` | Campaign type: MANAGER, SOURCE_OWNER, SEARCH, ROLE_COMPOSITION |
| `-Status` | One or more statuses. Default: COMPLETED, ACTIVE |
| `-CreatedAfter` / `-CreatedBefore` | Date range filter (ISO 8601) |
| `-DaysBack` | Look-back window in days. Default: 90 |
| `-ShowDeadlines` | Include deadline urgency classification |
| `-ShowMetrics` | Include per-campaign KPIs |
| `-ReviewerIdentityId` | Workload analysis for a specific reviewer |
| `-IdentityId` | Decision history for a specific identity |
| `-SourceCoverage` | Source coverage gap analysis |
| `-CompareIds` | Side-by-side comparison of two or more campaigns |
| `-OutputMode` | Console (default), JSON, CSV, HTML |

### Daily Orchestrator: Invoke-SPDailyOrchestrator.ps1

Runs the full daily governance workflow as a single coordinated operation, replacing four separate script invocations. Designed for scheduled task or cron execution.

**Execution steps (in order):**

1. Configuration validation
2. Campaign cleanup (completes stale campaigns)
3. Delta cert run (creates campaigns for new AD access)
4. Delta report (generates daily change report)
5. Escalation (reassigns unactioned certifications)
6. Health check (campaign health status)
7. Daily summary (consolidated output + JSONL audit trail)

Each step is isolated -- a failure in one step does not prevent subsequent steps from executing. Individual steps can be skipped with `-Skip*` parameters.

**Scope requirement:** Steps 2-5 require `sp:scopes:all` or a browser token.

```powershell
# Single daily command replacing 4 separate script invocations
.\Scripts\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -Token $token

# With parameter overrides
.\Scripts\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -HoursBack 48 -StaleHours 12 -Token $token

# Skip specific steps
.\Scripts\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -SkipEscalation -SkipHealthCheck -Token $token

# Dry run -- all sub-steps receive -WhatIf
.\Scripts\Invoke-SPDailyOrchestrator.ps1 -SourceId 'src-ad-001' -WhatIf
```

**Key parameters:**

| Parameter | Description |
|-----------|-------------|
| `-SourceId` | One or more ISC source IDs to monitor (required) |
| `-HoursBack` | Override look-back window for delta cert and report |
| `-DeadlineDays` | Override deadline for new delta cert campaigns |
| `-StaleHours` | Override stale threshold for escalation |
| `-ReviewerMode` | Manager (default) or SourceOwner |
| `-SkipValidation` / `-SkipCleanup` / `-SkipDeltaCert` / `-SkipDeltaReport` / `-SkipEscalation` / `-SkipHealthCheck` | Skip individual steps |

### Delta Report: Invoke-SPDeltaReport.ps1

Generates a daily delta certification report showing new grants, revocations, pending certifications, and anomalies within a configurable time window. Produces a lightweight 1-2 page HTML report and a JSONL audit trail for SIEM ingestion. This is not a full campaign audit -- it shows only changes in the time window for quick daily operations review.

**Scope requirement:** `GET /v3/account-activities` requires `sp:scopes:all` or a browser token.

```powershell
# Daily delta report for the last 24 hours
.\Scripts\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -HoursBack 24

# Catch-up report for the last 48 hours, output to a custom directory
.\Scripts\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -HoursBack 48 -OutputPath 'C:\Reports'

# Use a browser token instead of OAuth credentials
.\Scripts\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -Token 'eyJhbGciOiJSUzI1...'
```

**Key parameters:**

| Parameter | Description |
|-----------|-------------|
| `-SourceId` | One or more ISC source IDs to monitor (required) |
| `-HoursBack` | Look-back window in hours. Default: 24 |
| `-OutputPath` | Directory for HTML + JSONL output files |
| `-Token` | Browser JWT token (bypasses OAuth) |
| `-OutputMode` | Console (default), JSON, or Both |

### Weekly Digest: Invoke-SPWeeklyDigest.ps1

Generates a comprehensive weekly governance digest combining campaign activity, health status, identity risk, reviewer performance, remediation tracking, and orchestrator reliability into one report. Designed for weekly distribution to governance leadership.

**Report sections:**

1. Campaign Activity Summary
2. Current Campaign Health
3. Identity Risk Highlights
4. Reviewer Performance
5. Remediation Tracking
6. Orchestrator Health

Each section can be individually skipped with `-Skip*` parameters.

```powershell
# Weekly digest with default 7-day window
.\Scripts\Invoke-SPWeeklyDigest.ps1 -Token $token

# Console + HTML output with notification dispatch
.\Scripts\Invoke-SPWeeklyDigest.ps1 -Token $token -OutputMode Both -SendNotification

# Two-week digest, skip identity risk section
.\Scripts\Invoke-SPWeeklyDigest.ps1 -DaysBack 14 -SkipIdentityRisk -Token $token

# Dry run -- shows what sections would be generated
.\Scripts\Invoke-SPWeeklyDigest.ps1 -WhatIf
```

**Key parameters:**

| Parameter | Description |
|-----------|-------------|
| `-DaysBack` | Number of days to include. Default: 7 |
| `-Token` | Browser JWT token (bypasses OAuth) |
| `-SourceId` | One or more ISC source IDs for context |
| `-SkipCampaignSummary` / `-SkipIdentityRisk` / `-SkipReviewerAnalysis` / `-SkipRemediationTracking` / `-SkipOrchestratorHealth` | Skip individual sections |
| `-OutputMode` | Console (default), HTML, JSON, or Both |
| `-SendNotification` | Dispatch digest via configured notification backends |

### Delta Cert GUI Tab

The Delta Cert tab in the WPF dashboard provides a streamlined interface for running and monitoring delta certifications. The tab layout after the Phase 7 declutter:

- **Row 0 -- Summary + Actions:** A summary label shows current parameters (e.g., `Sources: src-ad-001 | 24h | 2d deadline | Manager`). Two buttons: **Configure...** opens a parameters dialog without running, **Run Delta Cert** opens the same dialog then executes on OK.
- **Row 1 -- Results DataGrid:** Displays campaign results from the most recent run.
- **Row 2 -- Secondary Actions:** Run Cleanup (completes stale campaigns), Run Escalation (reassigns unactioned certifications), Open Output Folder.
- **Row 3 -- Progress:** Progress bar and status label during async operations.
- **Row 4 -- History:** Color-coded list of recent runs (green = campaigns created, gray = no changes, orange = errors).

Delta Cert parameters are configured in the Settings tab and persist to `settings.json`. Session overrides via the dialog are remembered for the duration of the GUI session.

### Delta Cert Daily Operations

Recommended setup for automated daily delta certification with escalation follow-up.

**Windows Task Scheduler (production):**

```powershell
# Daily at 06:00 -- create delta cert campaigns for overnight AD changes
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Toolkit\Scripts\Invoke-SPADDeltaCert.ps1" -SourceId "src-abc123" -RunCleanup'
$trigger = New-ScheduledTaskTrigger -Daily -At '06:00'
Register-ScheduledTask -TaskName 'SailPoint-DeltaCert-Daily' -Action $action -Trigger $trigger `
    -Description 'Daily AD delta certification' -RunLevel Highest

# Every 4 hours during business hours -- escalate stale certifications
$action2 = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Toolkit\Scripts\Invoke-SPDeltaCertEscalate.ps1" -StaleHours 24'
$trigger2 = New-ScheduledTaskTrigger -Daily -At '10:00'
# Add repetition for 4-hour intervals during business day
$trigger2.Repetition.Interval = 'PT4H'
$trigger2.Repetition.Duration = 'PT12H'
Register-ScheduledTask -TaskName 'SailPoint-DeltaCert-Escalate' -Action $action2 -Trigger $trigger2 `
    -Description 'Escalate stale delta cert certifications' -RunLevel Highest
```

**Linux/macOS cron (development/testing):**

```bash
# Daily at 06:00
0 6 * * * pwsh -NoProfile -File /opt/toolkit/Scripts/Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -RunCleanup >> /var/log/deltacert.log 2>&1

# Every 4 hours from 10:00-22:00
0 10,14,18,22 * * * pwsh -NoProfile -File /opt/toolkit/Scripts/Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 >> /var/log/deltacert-escalate.log 2>&1
```

**Recommended daily workflow:**

1. **06:00** -- `Invoke-SPADDeltaCert.ps1 -RunCleanup` creates campaigns and cleans up stale ones from prior days.
2. **10:00, 14:00, 18:00, 22:00** -- `Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24` escalates unactioned certifications.
3. **Ad-hoc** -- Use the GUI Delta Cert tab or `Invoke-SPCampaignAudit.ps1 -CampaignNameContains 'AD Delta Cert'` to audit completed delta cert campaigns.

### Disconnected App Onboarding: Invoke-SPDisconnectedAppCert.ps1

Flat file integration for applications that lack a native SailPoint ISC connector. Application teams deliver daily CSV exports (accounts + entitlements) to a local directory. The toolkit validates the files, takes a date-stamped snapshot, compares against the previous day's snapshot to detect deltas, resolves changed accounts to ISC identities via email/username correlation, and creates targeted SEARCH-type certification campaigns per manager group for new or changed access.

**Scope requirement:** Identity resolution requires `sp:search:read` (POST /v3/search). Campaign creation requires `idn:campaign:manage`. Use `-Token` with a browser JWT if OAuth PAT is unavailable.

**CSV Templates:**

Two CSV template files are provided in `Config\Templates\`:

**Account file** (`disconnected-app-accounts.csv`):

| Column | Required | Description |
|--------|----------|-------------|
| `id` | Yes | Unique account identifier (max 128 characters) |
| `name` | Yes | Username or login name |
| `givenName` | Yes | First name |
| `familyName` | Yes | Last name |
| `e-mail` | Yes | Corporate email address (used to correlate to ISC identity) |
| `department` | Recommended | Department name |
| `groups` | Yes | Comma-separated entitlement IDs assigned to this account |
| `IIQDisabled` | Yes | Account status: `true` = disabled, `false` = active |

**Entitlement file** (`disconnected-app-entitlements.csv`):

| Column | Required | Description |
|--------|----------|-------------|
| `id` | Yes | Unique entitlement identifier (must match values in accounts `groups` column) |
| `name` | Yes | Technical name |
| `displayName` | Yes | Human-readable name shown to reviewers during certification |
| `description` | Yes | Description shown to reviewers (max 2000 characters) |

See `Config\Templates\v2\ONBOARDING-GUIDE.md` for detailed instructions to hand off to application teams.

**CLI usage:**

```powershell
# Basic daily run -- validate, snapshot, detect changes, create campaigns
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 -AppName 'PEP-Plus' -AccountFilePath '.\Imports\PEP-Plus\accounts.csv'

# Dry-run -- full workflow validation without any write API calls
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 -AppName 'PEP-Plus' -AccountFilePath '.\Imports\PEP-Plus\accounts.csv' -WhatIf

# With entitlement cross-reference validation and browser token auth
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 -AppName 'DebtNext' `
    -AccountFilePath '.\Imports\DebtNext\accounts.csv' `
    -EntitlementFilePath '.\Imports\DebtNext\entitlements.csv' `
    -Token 'eyJhbGciOiJSUzI1...'

# Include manager-less identities via fallback reviewer with a 3-day deadline
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 -AppName 'IPAY' `
    -AccountFilePath '.\Imports\IPAY\accounts.csv' `
    -FallbackReviewerIdentityId 'mgr-fallback-id' -DeadlineDays 3

# Custom campaign name prefix, snapshot directory, and output path
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 -AppName 'PEP-Plus' `
    -AccountFilePath '.\Imports\PEP-Plus\accounts.csv' `
    -CampaignNamePrefix 'PEP Access Review' `
    -SnapshotDir 'D:\Snapshots' `
    -OutputPath 'D:\Reports'

# JSON output mode with custom config path
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 -AppName 'PEP-Plus' `
    -AccountFilePath '.\Imports\PEP-Plus\accounts.csv' `
    -ConfigPath 'D:\Config\settings.json' -OutputMode JSON
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-AppName` | Yes | Application name (used for directory paths, campaign naming, report titles) |
| `-AccountFilePath` | Yes | Path to today's account CSV file |
| `-EntitlementFilePath` | No | Path to entitlement CSV file (enables cross-reference validation) |
| `-CampaignNamePrefix` | No | Campaign name prefix (default: `Disconnected App Cert`) |
| `-DeadlineDays` | No | Days until campaign deadline (default: 2) |
| `-FallbackReviewerIdentityId` | No | Identity ID for reviewing manager-less identities |
| `-MaxCampaignsPerRun` | No | Abort if manager group count exceeds this (default: 20) |
| `-SnapshotDir` | No | Root directory for date-stamped snapshots (default: `.\DisconnectedApps\Snapshots`) |
| `-OutputPath` | No | Root directory for reports and JSONL audit trail (default: `.\DisconnectedApps\Reports`) |
| `-ConfigPath` | No | Path to settings.json (default: `Config\settings.json`) |
| `-Token` | No | Pre-obtained JWT bearer token from ISC browser session |
| `-TokenExpiryMinutes` | No | Minutes until browser token expiry (default: 10) |
| `-OutputMode` | No | `Console` (default), `JSON`, or `Both` |
| `-WhatIf` | No | Dry-run mode -- no write API calls |
| `-Help` | No | Display built-in help and exit |

The `CorrelationAttribute` setting (which field to use for ISC identity matching -- defaults to `e-mail`) is configured in `settings.json` under `DisconnectedApps.CorrelationAttribute`, not as a CLI parameter.

**Daily workflow:**

1. Application team drops `accounts.csv` (and optionally `entitlements.csv`) into a local import directory by 04:00 UTC.
2. The toolkit **validates** the CSV structure (required columns, data types, encoding, duplicate IDs).
3. A **date-stamped snapshot** is saved (e.g., `2026-05-21-accounts.csv`) for historical comparison.
4. **Delta detection** compares today's file against the previous snapshot. Seven change types are detected: added accounts, removed accounts, disabled, enabled, entitlements granted, entitlements revoked, and attribute changes.
5. Changed accounts (adds, enables, grants) are **resolved** to ISC identities via `POST /v3/search` using email (primary) or username (fallback) correlation.
6. Resolved identities are grouped by manager. One SEARCH-type **certification campaign** is created per manager group.
7. An **HTML delta report** is generated with color-coded sections for all change types.
8. A **JSONL audit event** is appended to the per-app audit trail.

On quiet days with no changes between snapshots, the script exits with code 1 (expected no-op).

**File delivery pattern:**

Application teams place their CSV exports in a local directory (e.g., a network share, SFTP drop, or scheduled export target). The toolkit reads from wherever the files land -- it does not pull files from remote systems. File names should always be `accounts.csv` and `entitlements.csv` (no date suffixes). The toolkit handles date-stamped archival via the snapshot system.

**Delta detection:**

Each day's file is compared against the most recent previous snapshot (excluding today). The comparison is done by building hashtables keyed by account `id` for O(1) lookup, then checking each account for seven change types. Only campaign-triggering changes (added accounts, enabled accounts, entitlement grants) result in certification campaigns. Removals, revocations, disables, and attribute changes are logged in the HTML report but do not trigger campaigns.

On first run (no previous snapshot exists), all accounts in the file are treated as added.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Campaigns created (or WhatIf completed) |
| 1 | No changes detected between snapshots |
| 2 | Parameter error |
| 3 | Authentication error |
| 4 | Configuration error |
| 5 | Validation failure (CSV structure or data errors) |
| 6 | Campaign creation error |

#### Multi-App Enterprise Operations

When multiple disconnected applications need governance, the toolkit provides config-driven batch orchestration. Instead of running `Invoke-SPDisconnectedAppCert.ps1` per app, register each app in `settings.json` and process them all in a single batch run.

**App Registry: settings.json Applications array**

The `DisconnectedApps.Applications` array in `settings.json` holds the registration for each app. Each entry stores the app's file paths, correlation settings, and per-app overrides:

```json
"DisconnectedApps": {
    "CorrelationAttribute": "e-mail",
    "AccountDeletionThresholdPct": 20,
    "Applications": [
        {
            "Name": "PEP-Plus",
            "AccountFilePath": "\\\\fileserver\\imports\\PEP-Plus\\accounts.csv",
            "EntitlementFilePath": "\\\\fileserver\\imports\\PEP-Plus\\entitlements.csv",
            "ISCSourceId": "src-pep-001",
            "CorrelationAttribute": "e-mail",
            "CampaignNamePrefix": "PEP Access Review",
            "DeadlineDays": 2,
            "SlaDays": 1,
            "Enabled": true
        }
    ]
}
```

**Registry CLI: Invoke-SPDisconnectedAppRegistry.ps1**

Manages the `Applications` array without hand-editing JSON.

```powershell
# Register a new app
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Register `
    -AppName 'IPAY' `
    -AccountFilePath '\\fileserver\imports\IPAY\accounts.csv' `
    -EntitlementFilePath '\\fileserver\imports\IPAY\entitlements.csv' `
    -ISCSourceId 'src-ipay-001' `
    -CorrelationAttribute 'e-mail' `
    -CampaignNamePrefix 'IPAY Access Review' `
    -DeadlineDays 3 -SlaDays 1

# List all registered apps with file delivery status
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action List

# Test CSV validation for a registered app (no campaigns created)
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Test -AppName 'IPAY'

# Unregister an app (preserves snapshots and reports on disk)
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Unregister -AppName 'IPAY'
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Action` | Yes | `Register`, `Unregister`, `List`, or `Test` |
| `-AppName` | Yes (except List) | Application name |
| `-AccountFilePath` | Yes (Register) | Path to the account CSV file |
| `-EntitlementFilePath` | No | Path to the entitlement CSV file |
| `-ISCSourceId` | No | ISC source ID for the app |
| `-CorrelationAttribute` | No | Identity correlation field override (default: `e-mail`) |
| `-CampaignNamePrefix` | No | Campaign name prefix override (default: `{AppName} Cert`) |
| `-DeadlineDays` | No | Campaign deadline in days (default: 2) |
| `-SlaDays` | No | SLA days for file delivery monitoring (default: 1) |
| `-ConfigPath` | No | Path to settings.json |
| `-OutputMode` | No | `Console` (default), `JSON`, or `Both` |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | No registered apps found (List) or validation warnings (Test) |
| 2 | Parameter error |
| 4 | Configuration error |
| 5 | Validation failure |

**Batch Orchestrator: Invoke-SPDisconnectedAppBatch.ps1**

Processes all (or specified) registered apps in sequence. Each app runs the full pipeline: validate, snapshot, delta, threshold check, resolve, campaign, report. Errors are isolated per-app so one failure does not stop the batch.

```powershell
# Process all enabled registered apps
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1

# Process specific apps only
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -AppNames @('PEP-Plus','DebtNext')

# Dry-run: validate and detect changes without creating campaigns
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -WhatIf

# Process all apps with browser token auth, JSON output
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -Token 'eyJhbGciOiJSUzI1...' -OutputMode JSON
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-AppNames` | No | Filter to specific app names. If omitted, all enabled apps run. |
| `-ConfigPath` | No | Path to settings.json |
| `-Token` | No | Pre-obtained JWT bearer token from ISC browser session |
| `-TokenExpiryMinutes` | No | Minutes until browser token expiry (default: 10) |
| `-WhatIf` | No | Dry-run mode -- no write API calls |
| `-OutputMode` | No | `Console` (default), `JSON`, or `Both` |

Each app result is classified as: `Success`, `NoChanges`, `ThresholdBlocked`, or `Error`.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | All apps succeeded (or NoChanges) |
| 1 | Partial -- some apps failed or were blocked |
| 2 | All apps failed |
| 3 | Authentication error |
| 4 | Configuration error |

**Account Deletion Threshold Protection**

The `AccountDeletionThresholdPct` setting (default: 20) guards against bad data by blocking processing when the percentage of removed accounts exceeds the threshold. If a CSV file suddenly drops from 100 accounts to 10, the 90% deletion rate exceeds the 20% threshold and the app is blocked with `ThresholdBlocked` status. The block is logged, and a delta report is still generated for review. First-run scenarios (no previous snapshot) and files with fewer than 5 accounts always pass the threshold check.

**File Delivery Monitoring**

Check whether registered apps have received their daily CSV file delivery:

```powershell
# Check delivery status (uses Get-SPDisconnectedAppDeliveryStatus internally)
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action List
```

The `List` action shows each app's file status: `Current` (delivered within 24 hours), `Stale` (older than 24 hours), `Missing` (file not found), `Empty`, or `No Path`. The last processed date is extracted from the most recent snapshot filename.

**Cross-App Identity Risk Analysis**

Identifies identities who appear across multiple disconnected applications -- a separation-of-duties concern:

The `Get-SPDisconnectedAppIdentityRisk` function scans the latest account snapshots across all registered apps, correlates identities by email, and classifies risk:

| App Count | Risk Level |
|-----------|------------|
| 3+ apps | High |
| 2 apps | Elevated |
| 1 app | Normal |

Results are sorted by app count descending with summary counts for each risk tier.

**Unified Entitlement Catalog**

The `Get-SPDisconnectedAppEntitlementCatalog` function aggregates entitlements from all registered apps into a single catalog view. For each entitlement it reports the source app, display name, description, and the count of accounts currently assigned that entitlement (computed from the latest account snapshots).

**SLA Tracking and Delivery History**

The `Get-SPDisconnectedAppSlaStatus` function analyzes snapshot filenames over a configurable window (default 30 days) to compute per-app delivery rates:

- **DeliveryRate**: percentage of days with a snapshot file present
- **SlaCompliant**: `true` if delivery rate meets the threshold (based on per-app `SlaDays` setting)
- **LongestGapDays**: longest consecutive run of missing deliveries
- **DaysMissing**: list of specific dates with no delivery

### Vault: New-SPVault.ps1

One-time setup to store OAuth credentials in an encrypted vault (recommended for non-development environments).

```powershell
# Fully interactive setup
.\Scripts\New-SPVault.ps1

# Pre-supply ClientId (ClientSecret prompted)
.\Scripts\New-SPVault.ps1 -ClientId 'abc123def456'

# Custom vault path
.\Scripts\New-SPVault.ps1 -VaultPath 'D:\Secure\myteam.enc'
```

After vault setup, set `Authentication.Mode = Vault` in settings.json and confirm `Authentication.Vault.VaultPath` matches the vault file location.

### GUI: Show-SPDashboard.ps1

Launches the WPF interactive dashboard (Windows only, requires .NET Framework 4.5+).

```powershell
# Launch with default settings
.\Scripts\Show-SPDashboard.ps1

# Launch with specific config
.\Scripts\Show-SPDashboard.ps1 -ConfigPath 'C:\Toolkit\Config\settings.json'
```

The dashboard provides five tabs:
- **Campaigns** - load CSV data, select and run tests, view progress and results
- **Evidence** - browse Evidence/ folder, view JSONL events in a grid
- **Settings** - edit all settings.json fields with form validation, test connectivity, paste a browser token for quick authentication, and configure Delta Cert parameters
- **Audit** - query campaigns by keyword or substring search, select for audit, generate HTML compliance reports with reviewer performance metrics
- **Delta Cert** - configure and run daily AD delta certifications, run cleanup and escalation, view color-coded run history

---

## CSV Format Reference

### test-identities.csv

```csv
IdentityId,DisplayName,Email,Role,CertifierFor,IsReassignTarget
id-alice-001,Alice Johnson,alice@example.com,Certifier,id-bob-001,false
id-bob-001,Bob Smith,bob@example.com,Reviewer,,false
id-carol-001,Carol Davis,carol@example.com,Reassign Target,,true
```

Required columns: `IdentityId`, `DisplayName`, `Email`, `Role`, `CertifierFor`, `IsReassignTarget`

### test-campaigns.csv

```csv
TestId,TestName,CampaignType,CampaignName,CertifierIdentityId,ReassignTargetIdentityId,SourceId,SearchFilter,RoleId,DecisionToMake,ReassignBeforeDecide,ValidateRemediation,ExpectCampaignStatus,Priority,Tags
TC-001,Manager Campaign Approve,MANAGER,TC-001 Manager Test,id-alice-001,,,,,,false,false,ACTIVE,1,smoke
TC-002,Certifier Reassign Then Approve,SEARCH,TC-002 Reassign Test,id-alice-001,id-carol-001,,employee=true,,APPROVE,true,true,ACTIVE,2,regression
```

Required columns: `TestId`, `TestName`, `CampaignType`, `CampaignName`, `CertifierIdentityId`, `ReassignTargetIdentityId`, `SourceId`, `SearchFilter`, `RoleId`, `DecisionToMake`, `ReassignBeforeDecide`, `ValidateRemediation`, `ExpectCampaignStatus`, `Priority`, `Tags`

Tags are comma-separated within the cell (e.g., `smoke,regression`). Use `Tags` to filter runs with `-Tags smoke`.

---

## Evidence Output Structure

```
Evidence/
    TC-001/
        TC-001_<CorrelationID>.jsonl      # Structured event log (one JSON object per line)
        TC-001_summary.json               # Final test result summary
    TC-002/
        TC-002_<CorrelationID>.jsonl
        TC-002_summary.json

Reports/
    TC-001_report.html                    # Human-readable HTML report
    run_<CorrelationID>_summary.html      # Full suite run report
```

JSONL format (one event per line):

```json
{"Timestamp":"2026-02-18T14:30:00Z","CorrelationID":"...","TestId":"TC-001","Step":"CreateCampaign","Status":"SUCCESS","CampaignId":"campaign-abc123","DurationMs":1240}
```

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |
| 2 | Execution aborted (safety guard or user cancelled confirmation) |
| 3 | CSV load or validation error (check test-identities.csv / test-campaigns.csv) |
| 4 | Parameter or configuration error (check settings.json and command arguments) |

---

## Module Architecture

```
SailPoint-GovernanceToolkit/
    USER-GUIDE.html                      # Interactive tabbed user guide (open in browser)
    Scripts/                             # Thin-wrapper CLI entry points
        Invoke-GovernanceTest.ps1        # Primary test runner
        Invoke-SPCampaignAudit.ps1       # Post-campaign audit reporting
        Invoke-SPCampaignSearch.ps1      # Unified campaign search and analysis
        Invoke-SPADDeltaCert.ps1         # Daily AD delta certification
        Invoke-SPDeltaCertEscalate.ps1   # Stale certification escalation
        Invoke-SPDeltaReport.ps1         # Daily delta certification report
        Invoke-SPDailyOrchestrator.ps1   # Full daily governance workflow
        Invoke-SPWeeklyDigest.ps1        # Weekly governance digest report
        Invoke-SPDisconnectedAppCert.ps1 # Disconnected app flat file certification (single app)
        Invoke-SPDisconnectedAppRegistry.ps1  # App registry management (Register/Unregister/List/Test)
        Invoke-SPDisconnectedAppBatch.ps1     # Batch orchestrator for all registered apps
        Test-SPConnectivity.ps1          # Quick smoke test (config -> token -> API)
        New-SPVault.ps1                  # One-time vault setup
        Show-SPDashboard.ps1             # WPF GUI launcher

    Modules/
        SP.Core/                         # Foundation layer (no business logic)
            SP.Config.psm1               # settings.json load/validate/cache
            SP.Logging.psm1              # JSONL structured logging
            SP.Auth.psm1                 # OAuth 2.0 token acquisition + caching; browser token pass-through (Set-SPBrowserToken)
            SP.Vault.psm1                # AES-256-CBC credential vault

        SP.Api/                          # ISC API adapter layer
            SP.ApiClient.psm1            # Rate-limited, retry-capable REST client
            SP.Campaigns.psm1            # Campaign lifecycle (create/activate/poll/decide); Search-SPCampaigns (name co filter)
            SP.Certifications.psm1       # Certification and access review item queries (Get-SPCertifications, Get-SPAllCertifications, Get-SPAccessReviewItems)
            SP.Decisions.psm1            # Bulk decide, reassignment, and sign-off operations

        SP.Testing/                      # Test orchestration layer
            SP.Testing.psd1              # Module manifest
            SP.TestLoader.psm1           # CSV ingestion and cross-validation
            SP.Assertions.psm1           # Test assertion helpers
            SP.BatchRunner.psm1          # Test suite execution engine
            SP.Evidence.psm1             # Evidence collection and formatting

        SP.Audit/                        # Post-campaign audit reporting layer
            SP.AuditQueries.psm1         # Campaign/cert/item/event API queries
            SP.AuditReport.psm1          # Decision grouping, HTML/text/JSONL export

        SP.DeltaCert/                    # AD delta certification layer
            SP.DeltaCert.psd1            # Module manifest
            SP.DeltaCertQueries.psm1     # Grant event query + identity grouping
            SP.DeltaCertRunner.psm1      # Campaign creation + activation + cleanup
            SP.DeltaCertReport.psm1      # Delta report generation + HTML export

        SP.DisconnectedApps/             # Flat file disconnected app integration
            SP.DisconnectedAppValidator.psm1  # CSV structure + data validation
            SP.DisconnectedAppSnapshot.psm1   # Date-stamped file snapshot management
            SP.DisconnectedAppDelta.psm1      # Day-over-day delta detection engine
            SP.DisconnectedAppRunner.psm1     # Identity resolution + campaign creation + HTML reports

        SP.Gui/                          # WPF presentation layer
            SP.GuiBridge.psm1            # GUI-to-module bridge adapter
            SP.MainWindow.psm1           # WPF window host + event wiring

    Gui/                                 # XAML UI definitions
        MainWindow.xaml
        CampaignTab.xaml
        EvidenceTab.xaml
        SettingsTab.xaml
        AuditTab.xaml
        DeltaCertTab.xaml
        DeltaCertRunDialog.xaml          # Modal: delta cert run parameters
        DeltaCertEscalateDialog.xaml     # Modal: escalation parameters
        AuditQueryDialog.xaml            # Modal: audit query filters

    Config/
        settings.json                    # Runtime configuration
        test-identities.csv              # Test identity definitions
        test-campaigns.csv               # Campaign test cases
        Templates/                       # Disconnected app onboarding templates
            v1/                                 # Original template (8 account + 4 entitlement columns)
            v2/                                 # Current template (adds accountType, created, lastLogin, owner, type, riskLevel)
            VERSION-HISTORY.md                  # Template version changelog
            disconnected-app-accounts.csv       # Account CSV template with sample data
            disconnected-app-entitlements.csv   # Entitlement CSV template with sample data
            ONBOARDING-GUIDE.md                 # Instructions for application teams

    Evidence/                            # JSONL evidence output (per test run)
    Reports/                             # HTML report output
    Logs/                                # Toolkit operational logs
    Tests/                               # Pester unit tests
```

**Layering rules (strictly enforced):**
- `SP.Core` has no dependencies on other toolkit modules
- `SP.Api` depends on `SP.Core` only
- `SP.Testing` depends on `SP.Core` and `SP.Api`
- `SP.Audit` depends on `SP.Core` and `SP.Api` only (same level as SP.Testing)
- `SP.DeltaCert` depends on `SP.Core` and `SP.Api` only (same level as SP.Testing and SP.Audit)
- `SP.DisconnectedApps` depends on `SP.Core`, `SP.Api`, and `SP.DeltaCert` (reuses identity resolution and manager grouping from DeltaCert)
- `SP.Gui` depends on SP.Core, SP.Api, SP.Testing, SP.Audit, and SP.DeltaCert
- Scripts are thin wrappers: module load -> config -> WhatIf guard -> dispatch

---

## Security Considerations

**Credential storage:**
- `ConfigFile` mode stores the `ClientSecret` in plain text in settings.json. Acceptable only in isolated development environments.
- `Vault` mode uses authenticated encryption: AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC), keyed by PBKDF2 (600,000 iterations by default) which derives separate 32-byte encryption and authentication keys from the passphrase. On-disk layout is `[salt][IV][HMAC][ciphertext]`. Use this for any shared or production-adjacent environment.
- The vault passphrase is never written to disk. Store it in a password manager.

**WhatIf safety:**
- Set `Safety.RequireWhatIfOnProd = true` in settings.json for any environment where running live campaigns carries risk.
- When this flag is set, `Invoke-GovernanceTest.ps1` requires the operator to confirm via `ShouldProcess` before proceeding without `-WhatIf`.
- All scripts support `-WhatIf`. Pass `-WhatIf` during initial validation to confirm CSV data and configuration without making any API calls.

**API rate limiting:**
- The `SP.ApiClient` module enforces the ISC rate limit of 95 requests per 10-second window using a sliding-window queue.
- Bulk decision calls are capped at 250 items per request (ISC constraint).
- Reassign sync calls are capped at 50 items; async at 500.

**Campaign lifecycle:**
- `AllowCompleteCampaign = false` (default) prevents tests from calling `POST /campaigns/{id}/complete`. This API only works on past-due campaigns and has irreversible effects.
- Test campaigns are created with unique names including the test run `CorrelationID` to avoid collisions between concurrent runs.

---

## Extending the Toolkit

**Adding a new governance domain (e.g., role mining tests):**

1. Add a new test case row in `Config\test-campaigns.csv` with appropriate `CampaignType` and tags.
2. If the new domain requires custom API calls not covered by `SP.Campaigns.psm1`, add functions to a new module (e.g., `Modules\SP.Api\SP.RoleMining.psm1`) following the `@{Success; Data; StatusCode; Error}` return pattern.
3. Update `Modules\SP.Api\SP.Api.psd1` to include the new module in `NestedModules` and `FunctionsToExport`.
4. Add a corresponding Pester test file in `Tests\SP.Api\`.

**Adding custom evidence fields:**
- The `Write-SPLog` function (from `SP.Core`) accepts named parameters passed through to the JSONL event. Additional fields appear automatically in the evidence grid in the GUI.

**Building a standalone executable:**
- The toolkit is designed for PowerShell 5.1 and does not require a build step for standard use.
- If distribution as a `.exe` is needed, add a PyInstaller or Velopack pipeline following the patterns in the `.claude-frameworks/launcher-framework/` templates.

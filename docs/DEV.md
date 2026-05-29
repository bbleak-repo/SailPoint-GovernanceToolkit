# Developer Guide

Technical reference for maintaining and extending the SailPoint ISC Governance Toolkit.

---

## Module Loading Order

Modules must be imported in dependency order. All scripts follow this pattern:

```powershell
$modulesRoot = Join-Path $PSScriptRoot '..\Modules'

# 1. Foundation
Import-Module (Join-Path $modulesRoot 'SP.Core\SP.Core.psd1') -Force

# 2. API adapter
Import-Module (Join-Path $modulesRoot 'SP.Api\SP.Api.psd1') -Force

# 3. Business logic (choose as needed)
Import-Module (Join-Path $modulesRoot 'SP.Testing\SP.Testing.psd1') -Force
Import-Module (Join-Path $modulesRoot 'SP.Audit\SP.Audit.psd1') -Force
Import-Module (Join-Path $modulesRoot 'SP.DeltaCert\SP.DeltaCert.psd1') -Force
Import-Module (Join-Path $modulesRoot 'SP.DisconnectedApps\SP.DisconnectedApps.psd1') -Force  # requires SP.DeltaCert

# 4. GUI (optional, Windows only)
Import-Module (Join-Path $modulesRoot 'SP.Gui\SP.Gui.psd1') -Force
```

Each `.psd1` manifest uses `NestedModules` to load its `.psm1` files. `RequiredModules` is intentionally empty in all manifests to avoid `$env:PSModulePath` resolution failures in non-standard deployment layouts. The caller handles import order.

---

## Return Envelope Pattern

All public functions in SP.Api and SP.Audit return a standardized hashtable:

```powershell
@{
    Success = $true          # [bool] whether the operation succeeded
    Data    = $responseObj   # [object] the result payload (null on failure)
    Error   = $null          # [string] error message (null on success)
}
```

SP.ApiClient adds a `StatusCode` field:

```powershell
@{
    Success    = $true
    Data       = $responseObj
    StatusCode = 200
    Error      = $null
}
```

Callers always check `$result.Success` before accessing `$result.Data`. This avoids exception-based control flow and makes error handling explicit.

---

## Correlation IDs

Every operation generates a `CorrelationID` (GUID) that flows through all API calls, log entries, and evidence events within that operation:

```powershell
$CorrelationID = [guid]::NewGuid().ToString()
```

Functions accept an optional `-CorrelationID` parameter. When omitted, they generate their own. Scripts pass a single CorrelationID through all calls to enable end-to-end tracing.

---

## SP.Core Module Internals

### SP.Config.psm1

Configuration loading with validation and caching:

| Function | Purpose |
|----------|---------|
| `Get-SPConfig` | Load and cache settings.json. Returns PSCustomObject. |
| `Test-SPConfig` | Validate required fields (Api.BaseUrl, Authentication, etc.) |
| `Test-SPConfigFirstRun` | Detect CHANGE_ME placeholders |
| `New-SPConfigFile` | Generate template settings.json with defaults |
| `Get-SPConfigDefaults` | Return default values for all config sections |

The config system merges loaded JSON with defaults using `Merge-SPConfigWithDefaults`. Unknown keys produce warnings but are preserved in the result (forward compatibility).

### SP.Logging.psm1

Structured logging to file:

| Function | Purpose |
|----------|---------|
| `Write-SPLog` | Append structured log entry. Parameters: Message, Severity, Component, Action, CorrelationID |
| `Initialize-SPLogging` | Set log directory, configure minimum severity |
| `Get-SPLogPath` | Return current log file path |

Severity levels: `DEBUG`, `INFO`, `WARN`, `ERROR`. Log files are named `{FilePrefix}_{date}.log`.

### SP.Auth.psm1

OAuth 2.0 client_credentials token management and browser token pass-through:

| Function | Purpose |
|----------|---------|
| `Get-SPAuthToken` | Acquire or return cached bearer token |
| `Clear-SPAuthCache` | Force token re-acquisition on next call |
| `Set-SPBrowserToken` | Store a manually supplied JWT (from browser dev tools) for use by all subsequent API calls in the session |
| `Clear-SPAuthToken` | Clear any cached token (OAuth or browser) and force re-authentication on next call |

Tokens are cached in module scope (`$script:TokenCache`). Expiry is tracked to avoid unnecessary re-authentication. When `Set-SPBrowserToken` is used, the cached token bypasses the OAuth flow entirely until it expires or `Clear-SPAuthToken` is called.

### SP.Vault.psm1

AES-256-CBC encrypted credential store:

| Function | Purpose |
|----------|---------|
| `Initialize-SPVault` | Create new vault file with passphrase |
| `Set-SPVaultCredential` | Store ClientId + ClientSecret under a key |
| `Get-SPVaultCredential` | Retrieve credentials by key (requires passphrase) |
| `Remove-SPVaultCredential` | Delete a stored credential |
| `Test-SPVaultExists` | Check if vault file exists |

Key derivation: PBKDF2 with SHA-256, 600,000 iterations (configurable). The passphrase is never stored.

---

## SP.Api Module Internals

### SP.ApiClient.psm1

Rate-limited REST client with retry logic:

| Function | Purpose |
|----------|---------|
| `Invoke-SPApiRequest` | Core HTTP call. Parameters: Method, Endpoint, Body, QueryParams, CorrelationID |

Features:
- Sliding-window rate limiter (95 requests / 10 seconds)
- Automatic retry on 5xx errors (configurable count and delay)
- 429 response handling with Retry-After header support
- Bearer token injection from `Get-SPAuthToken`

### SP.Campaigns.psm1

Campaign lifecycle management and search:

| Function | Purpose |
|----------|---------|
| `New-SPCampaign` | Create a certification campaign |
| `Start-SPCampaign` | Activate a staged campaign |
| `Get-SPCampaign` | Retrieve campaign by ID |
| `Get-SPCampaignStatus` | Poll until target status or timeout |
| `Complete-SPCampaign` | Complete a past-due campaign (guarded by Safety.AllowCompleteCampaign) |
| `Search-SPCampaigns` | Search campaigns by name substring using the ISC `name co "..."` filter |

### SP.Certifications.psm1

Certification and access review item queries:

| Function | Purpose |
|----------|---------|
| `Get-SPCertifications` | Get certifications for a campaign (single page) |
| `Get-SPAllCertifications` | Auto-paginate all certifications |
| `Get-SPAccessReviewItems` | Get review items for a certification (single page) |
| `Get-SPAllAccessReviewItems` | Auto-paginate all review items |

### SP.Decisions.psm1

Bulk decision and reassignment operations:

| Function | Purpose |
|----------|---------|
| `Invoke-SPBulkDecide` | Batch APPROVE/REVOKE decisions (max 250 per batch) |
| `Invoke-SPReassign` | Synchronous reassignment (max 50 items) |
| `Invoke-SPReassignAsync` | Asynchronous reassignment (max 500 items) |
| `Invoke-SPSignOff` | Sign off a certification |

---

## SP.Audit Module Internals

### SP.AuditQueries.psm1

Read-only campaign audit data retrieval:

| Function | Purpose |
|----------|---------|
| `Get-SPAuditCampaigns` | Query campaigns with name/status/date filters. Client-side date filtering. |
| `Get-SPAuditCertifications` | Get certs for a campaign. Adds `ReviewerClassification` (Primary/Reassigned). |
| `Get-SPAuditCertificationItems` | Get all review items for a certification. Auto-paginates. |
| `Get-SPAuditCampaignReport` | Download campaign report CSV. Tries v3 API first, falls back to legacy `/cc/api`. |
| `Import-SPAuditCampaignReport` | Import manually downloaded CSV files from local directory. |
| `Get-SPAuditIdentityEvents` | Get identity lifecycle events. Resolves source names. |
| `Resolve-SPAuditIdentityAccounts` | Batch-resolve identity IDs to account details (sAMAccountName, UPN). Cached per session. |

Internal helper: `Get-SPAuditSourceName` -- Module-scope cached source name resolver.

### SP.AuditReport.psm1

Categorization and report generation:

| Function | Purpose |
|----------|---------|
| `Group-SPAuditDecisions` | Group review items into Approved/Revoked/Pending |
| `Group-SPReviewerActions` | Group certifications into Primary/Reassigned reviewers |
| `Group-SPAuditIdentityEvents` | Group events into Revoked/Granted |
| `Measure-SPAuditReviewerMetrics` | Calculate per-reviewer time-to-decision statistics (min, max, median, mean) |
| `Group-SPAuditRemediationProof` | Assemble item-level remediation completion status and reassignment chain per reviewer |
| `Export-SPAuditHtml` | Generate Word-compatible HTML report (inline CSS, table layout) including Executive Summary Dashboard |
| `Export-SPAuditText` | Generate plain-text summary report |
| `Export-SPAuditJsonl` | Write JSONL audit trail (UTF-8 no BOM) |

Internal (not exported): `Build-ExecutiveSummaryHtml` -- renders the status badge, decision donut, remediation bar, risk scorecard, and reviewer response time summary that appear at the top of each per-campaign HTML report.

`Group-SPAuditDecisions` expects wrapper hashtables with an `Item` key pointing to the raw API object plus `CertificationId`, `CertificationName`, and `CampaignName` context fields.

---

## SP.DeltaCert Module Internals

### SP.DeltaCertQueries.psm1

Data retrieval and identity resolution for delta certifications:

| Function | Purpose |
|----------|---------|
| `Get-SPDeltaGrantEvents` | Query `GET /v3/account-activities` for `GRANT_ACCESS` events on specified AD sources within a time window |
| `Get-SPDeltaAffectedIdentities` | Resolve and filter identities from grant events. Calls `GET /v3/search/identities/{id}` (cached per session). Filters by lifecycle state and manager assignment. |
| `Group-SPDeltaByManager` | Group affected identities by their manager ID for per-manager campaign creation |
| `Get-SPDeltaCertStaleCertifications` | Find active delta cert certifications with no reviewer action past a configurable threshold |
| `Get-SPDeltaIdentityDetail` | Resolve a single identity ID to manager and lifecycle state via `GET /v3/search/identities/{id}`. Results cached in module scope. |

Internal (not exported): identity resolution cache stored in `$script:IdentityCache` to avoid redundant API calls within a session.

### SP.DeltaCertRunner.psm1

Campaign lifecycle orchestration for delta certifications:

| Function | Purpose |
|----------|---------|
| `Invoke-SPDeltaCertRun` | End-to-end delta cert run: query grants, group by manager, create and activate SEARCH campaigns. Supports Manager and SourceOwner reviewer modes. |
| `Invoke-SPDeltaCertCleanup` | Complete stale delta cert campaigns past the configured `CleanupDaysStale` threshold |
| `Invoke-SPDeltaCertEscalate` | Reassign stale certifications up the org tree. Uses `Get-SPDeltaIdentityDetail` to resolve the current reviewer's manager. |

---

## SP.DisconnectedApps Module Internals

### SP.DisconnectedAppValidator.psm1

CSV validation for disconnected application flat file imports:

| Function | Purpose |
|----------|---------|
| `Test-SPDisconnectedAppAccountFile` | Validate account CSV structure and data (required columns, duplicate IDs, encoding, email format, IIQDisabled values, sort order) |
| `Test-SPDisconnectedAppEntitlementFile` | Validate entitlement CSV structure and data (required columns, duplicate IDs, name character restrictions, description length) |
| `Test-SPDisconnectedAppCrossReference` | Cross-validate account `groups` references against entitlement IDs. Flags unmatched groups and orphaned entitlements. |

Internal (not exported): `Test-SPFileIsUtf8` (encoding check), `Get-SPCsvColumnsFromHeader` (header parser).

### SP.DisconnectedAppSnapshot.psm1

Date-stamped file archival and retrieval for day-over-day comparison:

| Function | Purpose |
|----------|---------|
| `Save-SPDisconnectedAppSnapshot` | Copy today's import file to `{SnapshotDir}/{AppName}/{YYYY-MM-DD}-{FileType}.csv`. Idempotent (re-run overwrites today's snapshot). |
| `Get-SPDisconnectedAppPreviousSnapshot` | Find the most recent snapshot before today. Returns `$null` on first run (no previous snapshot). |
| `Remove-SPDisconnectedAppOldSnapshots` | Delete snapshots older than the retention period (default 30 days). |

### SP.DisconnectedAppDelta.psm1

Day-over-day delta detection engine:

| Function | Purpose |
|----------|---------|
| `Compare-SPDisconnectedAppFiles` | Compare current vs. previous account CSV. Detects seven change types: AccountAdded, AccountRemoved, AccountDisabled, AccountEnabled, EntitlementGranted, EntitlementRevoked, AttributeChanged. On first run (no previous file), all accounts are treated as Added. |

Internal (not exported): `Split-GroupsValue` (comma-separated groups parser).

### SP.DisconnectedAppDelta.psm1 (continued)

Account deletion threshold protection:

| Function | Purpose |
|----------|---------|
| `Test-SPDisconnectedAppDeletionThreshold` | Compare removed-account percentage against a configurable threshold. Returns `Allowed`, `RemovedPct`, and `Reason` (OK, ThresholdExceeded, FirstRun, TooFewAccounts). Files with fewer than 5 previous accounts always pass. |

### SP.DisconnectedAppRunner.psm1

Identity resolution, campaign creation, HTML report generation, and enterprise operations:

| Function | Purpose |
|----------|---------|
| `Resolve-SPDisconnectedAppIdentities` | Correlate delta accounts to ISC identities via `POST /v3/search` using email (primary) or username (fallback). Fetches manager details via `Get-SPDeltaIdentityDetail`. Results cached per session. |
| `Invoke-SPDisconnectedAppCertRun` | Group resolved identities by manager, create one SEARCH campaign per group. Includes duplicate guard, max-campaigns safety, and WhatIf support. |
| `Export-SPDisconnectedAppDeltaHtml` | Generate self-contained HTML delta report with color-coded sections for all change types. Inline CSS for Word paste compatibility. |
| `Get-SPRegisteredApps` | Load enabled app registrations from `DisconnectedApps.Applications` in settings.json. Merges per-app fields with global defaults. Supports `-IncludeDisabled` switch. |
| `Initialize-SPDisconnectedAppDirectories` | Scaffold per-app snapshot and report directories for newly registered apps. |
| `Get-SPDisconnectedAppDeliveryStatus` | Check file delivery freshness for all registered apps. Classifies each as Delivered, Stale, Missing, Empty, or Disabled. Includes row count for delivered files. |
| `Get-SPDisconnectedAppIdentityRisk` | Cross-app identity risk analysis. Scans latest account snapshots, correlates by email, classifies risk: High (3+ apps), Elevated (2 apps), Normal (1 app). |
| `Export-SPDisconnectedAppIdentityRiskHtml` | Generate identity risk HTML report. |
| `Get-SPDisconnectedAppEntitlementCatalog` | Aggregate entitlements from all registered apps into a unified catalog with per-entitlement assignment counts. |
| `Export-SPDisconnectedAppEntitlementCatalogHtml` | Generate entitlement catalog HTML report. |
| `Export-SPDisconnectedAppBatchHtml` | Generate batch orchestrator summary HTML report with executive summary, per-app status rows, error details, and optional delivery status section. |
| `Get-SPDisconnectedAppSlaStatus` | Analyze snapshot filenames over a configurable window to compute per-app delivery rate, SLA compliance, longest gap, and missing dates. |
| `Export-SPDisconnectedAppSlaHtml` | Generate SLA compliance HTML report with delivery grid. |

Internal (not exported): `Search-SPIdentityByAttribute` (ISC search API wrapper with session cache), `Write-SPDisconnectedAppAuditEvent` (JSONL audit trail), `ConvertTo-DisconnectedHtmlSafe`, `Build-DisconnectedHtmlRow`, `Build-DisconnectedHtmlHeader` (HTML helper functions).

**Dependencies:** SP.Core (logging, config), SP.Api (REST client, campaign lifecycle), SP.DeltaCert (identity detail resolution via `Get-SPDeltaIdentityDetail`, manager grouping via `Group-SPDeltaByManager`, search filter via `Build-SPDeltaSearchFilter`).

### New CLI Scripts (Enterprise Operations)

| Script | Purpose |
|--------|---------|
| `Invoke-SPDisconnectedAppRegistry.ps1` | Manages the `Applications` array in settings.json. Actions: Register (add app with file paths and overrides), Unregister (remove app, preserve files), List (show all apps with file status), Test (run CSV validation on a registered app). |
| `Invoke-SPDisconnectedAppBatch.ps1` | Batch orchestrator that processes all (or filtered) registered apps in sequence. Full pipeline per app: validate, snapshot, delta, threshold check, resolve, campaign, report. Errors are isolated per-app. Writes JSONL batch audit trail and generates batch summary HTML report. |

---

## Testing

### Running Tests

```powershell
# Run all tests
Invoke-Pester -Path .\Tests\ -Output Detailed

# Run a specific test file
Invoke-Pester -Path .\Tests\SP.AuditQueries.Tests.ps1 -Output Detailed

# Run tests matching a tag or name pattern
Invoke-Pester -Path .\Tests\ -Output Detailed -Filter @{ Tag = 'Unit' }
```

### Test Naming Convention

Test IDs follow the pattern `{MODULE}-{NNN}`:
- `API-001` through `API-005` -- SP.ApiClient
- `CAMP-001` through `CAMP-005` -- SP.Campaigns
- `CERT-001` through `CERT-004` -- SP.Certifications
- `DEC-001` through `DEC-004` -- SP.Decisions
- `AQ-001` through `AQ-007` -- SP.AuditQueries
- `AR-001` through `AR-006` -- SP.AuditReport
- `CFG-001` through `CFG-007` -- SP.Config
- `VLT-001` through `VLT-006` -- SP.Vault
- `LOAD-001` through `LOAD-005` -- SP.TestLoader
- `EVD-001` through `EVD-005` -- SP.Evidence
- `ASRT-001` through `ASRT-005` -- SP.Assertions
- `DC-*` -- SP.DeltaCert (SP.DeltaCert.Tests.ps1)
- `DA-001` through `DA-011` -- SP.DisconnectedApps single-app features (SP.DisconnectedApps.Tests.ps1)
- `DA-12-T` -- Get-SPRegisteredApps (enabled filter + default merge)
- `DA-13-T` -- App registration config manipulation
- `DA-14-T`, `DA-14-T2` -- Test-SPDisconnectedAppDeletionThreshold (threshold + first-run)
- `DA-15-T` -- Invoke-SPDisconnectedAppBatch.ps1 syntax validation
- `DA-16-T` -- Get-SPDisconnectedAppDeliveryStatus (Delivered/Missing/Disabled)
- `DA-17-T` -- Get-SPDisconnectedAppIdentityRisk (cross-app risk classification)
- `DA-18-T` -- Get-SPDisconnectedAppEntitlementCatalog (multi-app aggregation)
- `DA-19-T` -- Export-SPDisconnectedAppBatchHtml (batch summary HTML)
- `DA-20-T` -- Get-SPDisconnectedAppSlaStatus (delivery rate from snapshots)

### Mock Scoping

All Pester 5.x mocks use `-ModuleName` to target the correct module scope:

```powershell
Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
    return @{ Success = $true; Data = $mockData; StatusCode = 200; Error = $null }
}
```

On PS7, mocks without explicit `-ModuleName` targeting do not intercept cross-module function calls from nested modules loaded via `.psd1` manifests. This is the root cause of 55 test failures on PS7 -- they pass on PS 5.1 Desktop where mock scoping is more permissive.

### Test Data

Test files use `$TestDrive` (Pester temp directory) for file I/O tests. Mock data is constructed inline within `BeforeAll` / `BeforeEach` blocks.

Static test data files:
- `Tests/TestData/valid-settings.json` -- Well-formed settings for config tests
- `Tests/TestData/sample-identities.csv` -- Sample identity CSV
- `Tests/TestData/sample-campaigns.csv` -- Sample campaign CSV

---

## Adding a New Module

1. Create directory `Modules/SP.NewModule/`
2. Create the `.psm1` file(s) following existing patterns:
   - `#Requires -Version 5.1`
   - CBH comment block with `.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`
   - Functions use `[CmdletBinding()]` and `[OutputType()]`
   - Return envelope pattern for all public functions
   - `Write-SPLog` for structured logging
   - `Export-ModuleMember -Function @(...)` at the end
3. Create `.psd1` manifest:
   - Generate a fresh GUID
   - List `.psm1` files in `NestedModules`
   - List public functions in `FunctionsToExport`
   - Set `RequiredModules = @()` with a comment noting caller handles import order
4. Create `Tests/SP.NewModule.Tests.ps1`:
   - Use test ID prefix matching the module
   - Mock all cross-module calls with `-ModuleName`
   - Use `$TestDrive` for file operations
5. Update `docs/toolkit-status.md` with the new module

---

## Common PowerShell Gotchas

These were discovered during development and are documented here for reference:

| Issue | Fix |
|-------|-----|
| `$var:` in strings parsed as scope prefix | Use `${var}:` instead |
| `Get-Content` returns string for single-line files | Wrap in `@()` for safe array indexing |
| PS 5.1 `SecureString` coerces to type name in `[string]` params | Extract via BSTR before passing |
| PS7 `ConvertFrom-Json` auto-converts ISO 8601 to DateTime | Handle both types with `[datetime]::TryParse` |
| Pester 5 mock scoping on PS7 | Always use `-ModuleName` for cross-module mocks |
| `.psd1` RequiredModules only resolves in `$env:PSModulePath` | Leave empty, caller handles import order |
| `$script:var` targets MODULE scope, not function scope | Use `List[T].Add()` for in-place mutation |
| `[Parameter(Mandatory)][string[]]` rejects empty strings | Add `[AllowEmptyString()]` if needed |
| `.ContainsKey()` only works on hashtables | Use `.PSObject.Properties.Name -contains 'key'` for PSCustomObject |

---

## ISC API Reference

### Key Endpoints Used

| Endpoint | Method | Module | Purpose |
|----------|--------|--------|---------|
| `/oauth/token` | POST | SP.Auth | OAuth 2.0 token acquisition |
| `/v3/campaigns` | GET/POST | SP.Campaigns, SP.AuditQueries | List/create campaigns. `Search-SPCampaigns` uses `?filters=name+co+"..."` for substring search. |
| `/v3/campaigns/{id}/activate` | POST | SP.Campaigns | Activate a staged campaign |
| `/v3/campaigns/{id}/complete` | POST | SP.Campaigns | Complete a past-due campaign |
| `/v3/campaigns/{id}/reports` | GET | SP.AuditQueries | Get report metadata |
| `/v3/certifications` | GET | SP.Certifications, SP.AuditQueries | List certifications |
| `/v3/certifications/{id}/access-review-items` | GET | SP.Certifications, SP.AuditQueries | List review items |
| `/v3/certifications/{id}/decide` | POST | SP.Decisions | Bulk approve/revoke |
| `/v3/certifications/{id}/reassign` | POST | SP.Decisions | Sync reassignment |
| `/v3/certifications/{id}/reassign-async` | POST | SP.Decisions | Async reassignment |
| `/v3/certifications/{id}/sign-off` | POST | SP.Decisions | Sign off certification |
| `/v3/account-activities` | GET | SP.AuditQueries | Identity lifecycle events. Requires `sp:scopes:all` (no granular scope). |
| `/v3/search/identities/{id}` | GET | SP.DeltaCert | Identity detail resolution (manager, lifecycle state). Requires `sp:search:read`. Note: `GET /v3/identities/{id}` does not exist -- use this search endpoint. |
| `/v3/search` | POST | SP.DisconnectedApps | Identity correlation by email or username for disconnected app accounts. Requires `sp:search:read`. |
| `/v3/sources/{id}` | GET | SP.AuditQueries | Source name resolution |
| `/v3/accounts` | GET | SP.AuditQueries | Identity account resolution (UPN/sAMAccountName) |
| `/v3/reports/{id}` | GET | SP.AuditQueries | CSV report download (v3, preferred) |
| `/cc/api/report/get/{id}` | GET | SP.AuditQueries | CSV report download (legacy fallback) |

### API Constraints

- Bulk decide: max 250 items per request
- Reassign sync: max 50 items
- Reassign async: max 500 items
- Rate limit: 95 requests per 10-second window (enforced by SP.ApiClient)
- No server-side date filter on GET /v3/campaigns (client-side filtering required)
- Campaign report CSV download tries v3 `GET /reports/{id}?fileFormat=csv` first, falls back to legacy `/cc/api`
- Campaign status machine: STAGED -> ACTIVATING -> ACTIVE -> COMPLETING -> COMPLETED
- `POST /campaigns/{id}/complete` only works on past-due campaigns
- `GET /v3/identities/{id}` does not exist in the ISC v3 API -- use `GET /v3/search/identities/{id}` instead (returns IdentityDocument)
- `GET /v3/account-activities` has no granular scope -- requires `sp:scopes:all` or a browser token

### PAT Scopes

Read-only audit requires 6 scopes: `idn:campaign:read`, `idn:campaign-report:read`, `sp:report:read`, `sp:search:read`, `idn:sources:read`, `idn:accounts:read`. The `sp:search:read` scope was added for Delta Cert identity resolution via `GET /v3/search/identities/{id}`. See `docs/SANDBOX-API-SETUP.md` for full details.

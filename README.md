# SailPoint ISC Governance Toolkit

A PowerShell 5.1 toolkit for automated testing of SailPoint IdentityNow (ISC) certification campaign workflows. The toolkit creates, activates, and validates certification campaigns against the ISC REST API v3, producing structured JSONL evidence and HTML reports for UAT sign-off.

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| PowerShell  | 5.1 Desktop | Windows PowerShell only. PS Core / PS 7 not supported. |
| Windows     | 10 / 11 / Server 2019+ | WPF requires Windows. CLI works on any edition. |
| .NET Framework | 4.5+ | Required for WPF dashboard. Included in Windows 10+. |
| Pester      | 5.x | Required only for running unit tests in Tests/. |
| SailPoint ISC API credentials | - | OAuth 2.0 client_credentials with certification read/write scope. |

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
- `Authentication.ConfigFile.OAuthTokenUrl` - `https://<tenant>.identitynow.com/oauth/token`
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
      "OAuthTokenUrl": "https://tenant.identitynow.com/oauth/token",
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
    "DefaultDaysBack": 30,
    "DefaultIdentityEventDays": 2,
    "DefaultStatuses": ["COMPLETED", "ACTIVE"],
    "IncludeCampaignReports": true,
    "IncludeIdentityEvents": true
  }
}
```

For production environments, set `Authentication.Mode` to `Vault` and store credentials using `New-SPVault.ps1` (see Vault section below).

---

## Authentication Modes

The toolkit supports three authentication modes, configured via `Authentication.Mode` in settings.json.

### ConfigFile

Reads `ClientId` and `ClientSecret` directly from settings.json. The client secret is stored in plain text.

Use only in isolated development environments where the config file is not shared or committed to version control.

### Vault

Credentials are stored in an AES-256-CBC encrypted vault file (`Data\sp-vault.enc` by default). The passphrase is never written to disk.

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
    "DefaultDaysBack": 30,
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

The dashboard provides four tabs:
- **Campaigns** - load CSV data, select and run tests, view progress and results
- **Evidence** - browse Evidence/ folder, view JSONL events in a grid
- **Settings** - edit all settings.json fields with form validation, test connectivity, and paste a browser token for quick authentication without OAuth setup
- **Audit** - query campaigns by keyword or substring search, select for audit, generate HTML compliance reports with reviewer performance metrics

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
    Scripts/                             # Thin-wrapper CLI entry points
        Invoke-GovernanceTest.ps1        # Primary test runner
        Invoke-SPCampaignAudit.ps1       # Post-campaign audit reporting
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
            SP.TestLoader.psm1           # CSV ingestion and cross-validation
            (SP.TestRunner.psm1)         # Test suite execution engine

        SP.Audit/                        # Post-campaign audit reporting layer
            SP.AuditQueries.psm1         # Campaign/cert/item/event API queries
            SP.AuditReport.psm1          # Decision grouping, HTML/text/JSONL export

        SP.Gui/                          # WPF presentation layer
            SP.GuiBridge.psm1            # GUI-to-module bridge adapter
            SP.MainWindow.psm1           # WPF window host + event wiring

    Gui/                                 # XAML UI definitions
        MainWindow.xaml
        CampaignTab.xaml
        EvidenceTab.xaml
        SettingsTab.xaml
        AuditTab.xaml

    Config/
        settings.json                    # Runtime configuration
        test-identities.csv              # Test identity definitions
        test-campaigns.csv               # Campaign test cases

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
- `SP.Gui` depends on SP.Core, SP.Api, SP.Testing, and SP.Audit (Audit tab bridge functions)
- Scripts are thin wrappers: module load -> config -> WhatIf guard -> dispatch

---

## Security Considerations

**Credential storage:**
- `ConfigFile` mode stores the `ClientSecret` in plain text in settings.json. Acceptable only in isolated development environments.
- `Vault` mode encrypts credentials using AES-256-CBC with PBKDF2 key derivation (600,000 iterations by default). Use this for any shared or production-adjacent environment.
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

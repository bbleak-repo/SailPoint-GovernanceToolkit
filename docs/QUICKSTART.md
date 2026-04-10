# Quick Start Guide

Get the SailPoint ISC Governance Toolkit running in under 10 minutes.

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| PowerShell | 5.1 Desktop | Windows PowerShell only. PS Core 7.x is not the target platform. |
| Windows | 10 / 11 / Server 2019+ | WPF GUI requires Windows. CLI scripts work on any edition. |
| .NET Framework | 4.5+ | Required for the WPF dashboard. Included in Windows 10+. |
| SailPoint ISC API credentials | -- | OAuth 2.0 client_credentials with certification read/write scope. |

Optional:
- **Pester 5.x** -- Only needed if running the unit tests in `Tests/`.

---

## Step 1: Extract the Toolkit

No build step is required. The toolkit is pure PowerShell modules.

```powershell
# Extract or clone to a local directory
cd C:\Tools\SailPoint-GovernanceToolkit
```

---

## Step 2: Generate Configuration

On first run, the toolkit auto-generates `Config\settings.json` from a template with `CHANGE_ME` placeholders.

```powershell
.\Scripts\Test-SPConnectivity.ps1
```

This creates the config file and exits with guidance. Open `Config\settings.json` and update these values:

| Key | Example Value |
|-----|---------------|
| `Global.EnvironmentName` | `Sandbox` or `Production` |
| `Authentication.ConfigFile.TenantUrl` | `https://acme.api.identitynow.com` |
| `Authentication.ConfigFile.OAuthTokenUrl` | `https://acme.identitynow.com/oauth/token` |
| `Authentication.ConfigFile.ClientId` | Your ISC API client ID |
| `Authentication.ConfigFile.ClientSecret` | Your ISC API client secret |
| `Api.BaseUrl` | `https://acme.api.identitynow.com/v3` |

For production environments, use the encrypted vault instead of plaintext credentials. See Step 6 below.

---

## Step 3: Test Connectivity

```powershell
.\Scripts\Test-SPConnectivity.ps1
```

Expected output: three PASS steps:
1. Configuration loaded successfully
2. OAuth token acquired
3. Live API call to ISC succeeded

If any step fails, check the error message and verify your `settings.json` values.

---

## Step 4: Run Campaign Tests

**Dry run first** (validates CSV data and configuration without making API calls):

```powershell
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke -WhatIf
```

**Execute against ISC:**

```powershell
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke
```

Other useful invocations:

```powershell
# Run regression suite, stop on first failure
.\Scripts\Invoke-GovernanceTest.ps1 -Tags regression -StopOnFirstFailure

# Run a single test by ID
.\Scripts\Invoke-GovernanceTest.ps1 -TestId TC-003

# Output machine-parseable JSON results
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke -OutputMode JSON

# Use a custom config file
.\Scripts\Invoke-GovernanceTest.ps1 -ConfigPath 'D:\Configs\prod-settings.json' -Tags smoke
```

---

## Step 5: Run Campaign Audits

Query completed campaigns and generate compliance reports:

```powershell
# Audit all campaigns completed in the last 7 days
.\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 7

# Audit a specific campaign by exact name
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignName 'Q1 2026 Access Review'

# Search campaigns by keyword anywhere in the name (substring match)
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignNameContains 'entitlement' -DaysBack 90

# Audit campaigns starting with a prefix
.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignNameStartsWith 'Q1'

# Use a browser token instead of OAuth credentials
.\Scripts\Invoke-SPCampaignAudit.ps1 -Token 'eyJhbGciOiJSUzI1NiIs...' -Status COMPLETED -DaysBack 7

# Output JSON results
.\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 30 -OutputMode JSON
```

At least one campaign filter must be specified (`-CampaignName`, `-CampaignNameStartsWith`, `-CampaignNameContains`, or `-Status`).

**Browser token authentication:** If you are already logged into the ISC admin console, you can skip OAuth setup entirely. Open browser dev tools (F12), go to the Network tab, copy the `Authorization: Bearer eyJ...` header from any API call, and pass the JWT via `-Token`. Tokens are typically valid for ~12 minutes.

**Output files** are written to `.\Audit\` by default:

```
Audit\
    <CampaignName>\
        <CampaignName>_audit.html       Per-campaign HTML (Word-compatible)
        <CampaignName>_summary.txt      Per-campaign text summary
    CampaignAudit_<ID>.html             Combined HTML (all campaigns)
    CampaignAudit_<ID>.jsonl            JSONL audit trail
```

The HTML reports are designed for copy-paste into Word documents. They use inline CSS and table-based layout only (no flexbox/grid).

Each campaign report includes 7 sections:
1. Campaign Summary (name, status, dates, certification count)
2. Reviewer Accountability (primary + reassigned reviewers with sign-off proof)
3. Reviewer Performance (time-to-decision metrics per reviewer, color-coded by response time)
4. Decision Summary (approved, revoked, pending items with identity/entitlement/reviewer detail)
5. Campaign Reports (Campaign Status Report + Certification Signoff Report from ISC)
6. Provisioning Proof (downstream REMOVE/ADD events confirming access changes were applied)
7. Audit Metadata (correlation ID, generation timestamp, filters used)

---

## Step 6: Secure Credentials (Optional)

For shared or production-adjacent environments, store credentials in an encrypted vault:

```powershell
# Interactive setup
.\Scripts\New-SPVault.ps1

# Or pre-supply the ClientId
.\Scripts\New-SPVault.ps1 -ClientId 'abc123def456'
```

After vault setup, update `settings.json`:
- Set `Authentication.Mode` to `"Vault"`
- Confirm `Authentication.Vault.VaultPath` matches the vault file location

The vault uses AES-256-CBC encryption with PBKDF2 key derivation (600,000 iterations). The passphrase is never written to disk.

---

## Step 7: Launch the GUI Dashboard (Optional)

The WPF dashboard provides a visual interface for running tests and browsing evidence.

```powershell
.\Scripts\Show-SPDashboard.ps1
```

The dashboard has four tabs:
- **Campaigns** -- Load test data, select and run tests, view progress and results
- **Evidence** -- Browse evidence directories, view JSONL events in a data grid
- **Settings** -- Edit settings.json fields, test connectivity, paste browser token for quick authentication
- **Audit** -- Query campaigns by keyword (substring search), select for audit, generate HTML compliance reports with reviewer performance metrics

The GUI requires Windows and .NET Framework 4.5+.

---

## View Reports

| Output Type | Location | Format |
|-------------|----------|--------|
| Test evidence | `Evidence\<TestId>\` | JSONL (one JSON object per line) |
| Test reports | `Reports\` | HTML |
| Audit reports | `Audit\<CampaignName>\` | HTML + TXT |
| Audit trail | `Audit\` | JSONL |
| Toolkit logs | `Logs\` | Structured text logs |

HTML reports can be opened directly in a browser. Audit HTML is formatted for copy-paste into Word documents.

---

## Troubleshooting

**"CHANGE_ME" values detected**: Run `Test-SPConnectivity.ps1` and update `settings.json` with your ISC tenant details.

**OAuth token failure**: Verify `TenantUrl` and `OAuthTokenUrl` are correct. The token URL uses `identitynow.com` (not `api.identitynow.com`). Confirm your API client has `sp:scopes:all` or appropriate certification scopes.

**Rate limit errors (429)**: The toolkit handles 429 responses automatically with backoff. If you see persistent rate limiting, reduce `Api.RateLimitRequestsPerWindow` below 95.

**Campaign not found after creation**: Campaigns transition through `STAGED -> ACTIVATING -> ACTIVE`. The `Get-SPCampaignStatus` function polls until the target status is reached or timeout expires.

**Audit reports show "Campaign reports unavailable"**: The CSV report download tries the v3 API first (`GET /v3/reports/{id}?fileFormat=csv`) and falls back to the legacy `/cc/api` endpoint. If both fail, re-run with `-CampaignReportCsvPath` to import manually downloaded CSVs.

**PS7 test failures**: 55 of 207 Pester tests fail on PowerShell 7 due to mock-scoping differences. This is expected. The target platform is Windows PS 5.1 Desktop.

---

## Exit Codes

### Invoke-GovernanceTest.ps1

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |
| 2 | Execution aborted (safety guard or user cancellation) |
| 3 | CSV load or validation error |
| 4 | Parameter or configuration error |

### Invoke-SPCampaignAudit.ps1

| Code | Meaning |
|------|---------|
| 0 | Audit completed successfully |
| 1 | No campaigns matched filter criteria |
| 2 | Parameter error (no filter specified) |
| 3 | Authentication or API error |
| 4 | Configuration error |

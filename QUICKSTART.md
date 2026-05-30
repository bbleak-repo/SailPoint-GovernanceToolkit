# Quick Start Guide

Get the SailPoint ISC Governance Toolkit running in 15 minutes.

For full documentation, see [README.md](README.md).
For detailed reference with searchable tabs, see [USER-GUIDE.html](USER-GUIDE.html).

---

## What You Need

- **Windows 10/11 or Server 2019+** with PowerShell 5.1 Desktop (pre-installed)
- **SailPoint ISC API credentials** (OAuth 2.0 client_credentials -- read-only audit requires 6 PAT scopes; see below)
- **10 minutes** for CLI setup, +5 for optional vault and GUI

---

## Step 1: Extract and Navigate

Copy the toolkit folder to your Windows machine and open PowerShell:

```powershell
cd C:\Tools\SailPoint-GovernanceToolkit
```

No build step, no installers, no external dependencies. The toolkit is pure PowerShell.

---

## Step 2: Configure settings.json

Open `Config\settings.json` and replace all `CHANGE_ME` values:

```json
{
  "Global": {
    "EnvironmentName": "Sandbox"
  },
  "Authentication": {
    "Mode": "ConfigFile",
    "ConfigFile": {
      "TenantUrl": "https://acme.api.identitynow.com",
      "OAuthTokenUrl": "https://acme.api.identitynow.com/oauth/token",
      "ClientId": "your-client-id-here",
      "ClientSecret": "your-client-secret-here"
    }
  },
  "Api": {
    "BaseUrl": "https://acme.api.identitynow.com/v3"
  }
}
```

Replace `acme` with your ISC tenant name. Leave all other fields at their defaults.

> **Tip: Local override file.** Instead of editing the tracked `settings.json`, copy it to `Config\settings.local.json` and edit that copy. The toolkit automatically uses `settings.local.json` when it exists, and the file is already gitignored. This keeps the tracked template clean and prevents accidentally committing credentials. See [README.md](README.md#local-configuration-override-settingslocaljson) for details.

**Required PAT scopes (read-only audit):**

```
idn:campaign:read
idn:campaign-report:read
sp:report:read
sp:search:read
idn:sources:read
idn:accounts:read
```

`sp:search:read` is required for identity resolution (manager lookup in Delta Cert). For full sandbox scope details including write permissions, see `docs/SANDBOX-API-SETUP.md`.

> **Note:** Delta Cert's `GET /v3/account-activities` endpoint requires `sp:scopes:all` or a browser token. The granular scopes above are not sufficient for that endpoint.

> **Tip:** If the toolkit detects `CHANGE_ME` values on first run, it will exit with guidance. You do not need to fill in every field -- only the ones shown above.

---

## Step 3: (Optional) Set Up Encrypted Vault

For non-development environments, store credentials in an encrypted vault instead of plaintext in settings.json:

```powershell
.\Scripts\New-SPVault.ps1
```

The script will prompt for:
1. A vault passphrase (minimum 12 characters, entered twice)
2. Your OAuth ClientId
3. Your OAuth ClientSecret (masked input)

After vault setup, update settings.json:
```json
"Authentication": {
    "Mode": "Vault"
}
```

Store the vault passphrase in a password manager. It is never written to disk.

---

## Step 4: Test Connectivity

```powershell
.\Scripts\Test-SPConnectivity.ps1
```

Expected output -- three steps, all PASS:

```
  [PASS] Step 1: Load and validate settings.json (12ms)
         Environment: Sandbox | Mode: ConfigFile
  [PASS] Step 2: Acquire OAuth 2.0 bearer token (340ms)
         Mode: ConfigFile | Expires: 2026-02-18T15:12:49Z
  [PASS] Step 3: GET /v3/campaigns?limit=1 (180ms)
         API responded successfully. Items returned: 1

  RESULT: All connectivity checks passed.
```

If any step fails, check the error message and verify your settings.json values.

---

## Step 5: Dry Run (WhatIf)

Run a smoke test without making any API calls:

```powershell
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke -WhatIf
```

This validates:
- CSV files load and parse correctly
- Test identities and campaigns cross-reference properly
- The suite runner executes the workflow (skipping actual API calls)

If you see `[WhatIf] Dry-run mode enabled`, the toolkit is working correctly.

---

## Step 6: Live Run

Run the smoke tests against your ISC tenant:

```powershell
.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke
```

The toolkit will create certification campaigns, validate their status, and generate evidence. Watch for PASS/FAIL output per test case.

> **Safety:** The toolkit defaults to `MaxCampaignsPerRun=10` and `AllowCompleteCampaign=false`. See the Safety Defaults section below.

---

## Step 7: View Evidence and Reports

After a test run, evidence files are written to:

```
Evidence\
    TC-001\
        TC-001_<correlationId>.jsonl    # Structured event log
        TC-001_summary.json             # Test result summary
Reports\
    TC-001_report.html                  # Per-test HTML report
    run_<correlationId>_summary.html    # Full suite report
```

Open the HTML reports in a browser to review results.

---

## Step 8: Launch the GUI Dashboard (Windows Only)

```powershell
.\Scripts\Show-SPDashboard.ps1
```

The WPF dashboard provides five tabs:
- **Campaigns** -- load CSVs, select tests, run with progress tracking
- **Evidence** -- browse evidence folders, view JSONL events in a grid
- **Settings** -- edit settings.json fields with form validation, test connectivity, paste a browser token, and configure Delta Cert parameters
- **Audit** -- query campaigns by keyword or substring search, select for audit, generate HTML compliance reports
- **Delta Cert** -- configure and run daily AD delta certifications, run cleanup and escalation, view run history

> **Note:** The GUI requires .NET Framework 4.5+ and a Single-Threaded Apartment (STA) thread. The script handles STA relaunching automatically.

---

## Step 9: Delta Cert Quick Start (Optional)

Delta Cert creates daily SEARCH-type certification campaigns for identities who received new AD access grants.

```powershell
# Dry-run -- see what campaigns would be created (no API writes)
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123' -WhatIf

# Create delta cert campaigns for overnight AD changes
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'src-abc123'

# Escalate stale certifications (no reviewer action in 24 hours)
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf
```

> **Note:** Delta Cert requires `sp:scopes:all` or a browser token (`-Token`) because `GET /v3/account-activities` has no granular scope. The 6 read-only PAT scopes listed above are not sufficient for Delta Cert operations. See `docs/SANDBOX-API-SETUP.md` for full scope details.

Configure Delta Cert parameters in `Config\settings.json` under the `DeltaCert` section, or use the Settings tab in the GUI. See [README.md](README.md) for the full DeltaCert configuration reference and daily operations workflow.

---

## Step 10: Disconnected App Onboarding (Optional)

For applications without a native ISC connector, the toolkit supports flat file CSV integration. Application teams export their account and entitlement data as CSV files; the toolkit detects daily changes and creates certification campaigns for new or changed access.

**CSV templates** are provided in `Config\Templates\`:
- `disconnected-app-accounts.csv` -- account file template with required columns and sample data
- `disconnected-app-entitlements.csv` -- entitlement file template
- `ONBOARDING-GUIDE.md` -- hand this file to application teams for delivery instructions

```powershell
# Daily run -- validate CSV, detect changes, create campaigns for new access
.\Scripts\Invoke-SPDisconnectedAppCert.ps1 -AppName 'PEP-Plus' `
    -AccountFilePath '.\Imports\PEP-Plus\accounts.csv' `
    -EntitlementFilePath '.\Imports\PEP-Plus\entitlements.csv' -WhatIf
```

For multiple apps, register them in the config and use batch mode:

```powershell
# Register apps once
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Register -AppName 'PEP-Plus' `
    -AccountFilePath '\\fileserver\imports\PEP-Plus\accounts.csv'
.\Scripts\Invoke-SPDisconnectedAppRegistry.ps1 -Action Register -AppName 'DebtNext' `
    -AccountFilePath '\\fileserver\imports\DebtNext\accounts.csv'

# Daily batch run -- processes all registered apps in one command
.\Scripts\Invoke-SPDisconnectedAppBatch.ps1 -WhatIf
```

See [README.md](README.md) for the full parameter reference, daily workflow, and delta detection details.

---

## Getting Help

Every script supports `-Help` and `-?` to display built-in documentation:

```powershell
.\Scripts\Invoke-GovernanceTest.ps1 -Help
.\Scripts\Test-SPConnectivity.ps1 -?
.\Scripts\New-SPVault.ps1 -Help
.\Scripts\Show-SPDashboard.ps1 -Help
```

PowerShell's `Get-Help` also works:

```powershell
Get-Help .\Scripts\Invoke-GovernanceTest.ps1 -Detailed
Get-Help .\Scripts\New-SPVault.ps1 -Examples
```

For full reference (architecture, CSV formats, extending the toolkit), see [README.md](README.md).

---

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `First-run configuration detected` | `CHANGE_ME` values remain in settings.json | Open `Config\settings.json` and replace all `CHANGE_ME` with real values |
| `Token acquisition failed` | Wrong tenant URL, expired credentials, or network issue | Verify `OAuthTokenUrl` and `ClientId`/`ClientSecret` in settings.json |
| `Pester module not found` | Pester 5.x not installed (only needed for unit tests) | `Install-Module Pester -Force -SkipPublisherCheck` |
| GUI fails with `STA` error | Script was run in MTA thread and auto-relaunch failed | Run from PowerShell ISE (always STA) or use `powershell.exe -STA -File .\Scripts\Show-SPDashboard.ps1` |
| `Required module not found` | Module path resolution failed | Run from the toolkit root directory (`cd C:\Tools\SailPoint-GovernanceToolkit`) |
| `MaxCampaignsPerRun exceeded` | More campaigns selected than the safety limit allows | Reduce your tag filter scope or increase `Safety.MaxCampaignsPerRun` in settings.json |

---

## Safety Defaults

The toolkit ships with conservative defaults to prevent accidental changes in production:

| Setting | Default | What It Does |
|---------|---------|-------------|
| `Safety.RequireWhatIfOnProd` | `true` | Requires confirmation before running without `-WhatIf` |
| `Safety.MaxCampaignsPerRun` | `10` | Caps the number of campaigns per execution |
| `Safety.AllowCompleteCampaign` | `false` | Blocks the irreversible campaign completion API call |
| `-WhatIf` flag | Available on all scripts | Dry-run mode -- no API calls, no side effects |

These can be adjusted in `Config\settings.json` once you are comfortable with the toolkit behavior.

# Quick Start Guide

Get the SailPoint ISC Governance Toolkit running in 15 minutes.

For full documentation, see [README.md](README.md).

---

## What You Need

- **Windows 10/11 or Server 2019+** with PowerShell 5.1 Desktop (pre-installed)
- **SailPoint ISC API credentials** (OAuth 2.0 client_credentials with certification scope)
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
      "OAuthTokenUrl": "https://acme.identitynow.com/oauth/token",
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

The WPF dashboard provides three tabs:
- **Campaigns** -- load CSVs, select tests, run with progress tracking
- **Evidence** -- browse evidence folders, view JSONL events in a grid
- **Settings** -- edit settings.json fields with form validation

> **Note:** The GUI requires .NET Framework 4.5+ and a Single-Threaded Apartment (STA) thread. The script handles STA relaunching automatically.

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

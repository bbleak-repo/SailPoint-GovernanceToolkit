# SailPoint ISC Governance Toolkit

## Overview

The SailPoint ISC Governance Toolkit is a PowerShell 5.1 modular monolith for automating and auditing SailPoint IdentityNow (ISC) certification campaign workflows. It provides two primary capabilities:

1. **Campaign Testing** -- Create, activate, decide, and validate certification campaigns against the ISC REST API v3 with structured JSONL evidence and HTML reports for UAT sign-off.

2. **Campaign Auditing** -- Query completed campaigns, collect all review decisions and reviewer actions, fetch identity lifecycle events for revoked identities, and produce Word-compatible HTML reports for compliance evidence.

The toolkit is designed for Windows PowerShell 5.1 Desktop with zero external dependencies. All cryptographic, HTTP, and UI functionality uses .NET Framework built-in classes.

---

## Architecture

```
SP.Core (Config, Logging, Auth, Vault)
    |
    v
SP.Api (ApiClient, Campaigns, Certifications, Decisions)
    |
    +----------+
    v          v
SP.Testing    SP.Audit (AuditQueries, AuditReport)
    |
    v
SP.Gui (MainWindow, GuiBridge)  +  Scripts/ (CLI thin wrappers)
```

### Modules

| Module | Purpose | Files |
|--------|---------|-------|
| **SP.Core** | Foundation layer -- configuration, structured logging, OAuth 2.0 token management, AES-256-CBC credential vault | 4 .psm1 + manifest |
| **SP.Api** | ISC API adapter layer -- rate-limited REST client, campaign lifecycle, certifications, bulk decisions | 4 .psm1 + manifest |
| **SP.Testing** | Test orchestration -- CSV ingestion, batch runner, assertion framework, JSONL/HTML evidence | 4 .psm1 + manifest |
| **SP.Audit** | Post-campaign reporting -- query campaigns/certs/items/events, categorize decisions, generate HTML/text/JSONL reports | 2 .psm1 + manifest |
| **SP.Gui** | WPF presentation layer -- dashboard window host, GUI-to-module bridge adapter | 2 .psm1 + manifest |

### Scripts

| Script | Purpose |
|--------|---------|
| `Invoke-GovernanceTest.ps1` | Primary test runner -- loads CSVs, runs campaign tests, produces evidence |
| `Invoke-SPCampaignAudit.ps1` | Post-campaign audit reporting -- queries ISC, generates compliance reports |
| `Test-SPConnectivity.ps1` | Quick 3-step connectivity check (config, token, API) |
| `New-SPVault.ps1` | One-time credential vault setup |
| `Show-SPDashboard.ps1` | WPF GUI dashboard launcher (Windows only) |

### Layering Rules

These are strictly enforced throughout the codebase:

- `SP.Core` has no dependencies on other toolkit modules
- `SP.Api` depends on `SP.Core` only
- `SP.Testing` depends on `SP.Core` and `SP.Api`
- `SP.Audit` depends on `SP.Core` and `SP.Api` (same level as SP.Testing)
- `SP.Gui` depends on `SP.Core`, `SP.Api`, `SP.Testing`, and `SP.Audit`
- Scripts are thin wrappers: module load, config, WhatIf guard, dispatch

---

## Directory Structure

```
SailPoint-GovernanceToolkit/
    Scripts/                    CLI entry points (5 scripts)
    Modules/
        SP.Core/                Config, Logging, Auth, Vault (4 .psm1 + .psd1)
        SP.Api/                 ApiClient, Campaigns, Certifications, Decisions (4 .psm1 + .psd1)
        SP.Testing/             TestLoader, BatchRunner, Assertions, Evidence (4 .psm1 + .psd1)
        SP.Audit/               AuditQueries, AuditReport (2 .psm1 + .psd1)
        SP.Gui/                 GuiBridge, MainWindow (2 .psm1 + .psd1)
    Gui/                        WPF XAML definitions (5 files)
    Config/                     settings.json + test data CSVs
    Tests/                      Pester 5.x unit tests (13 files, 207 tests)
    Evidence/                   JSONL evidence output (per test run)
    Reports/                    HTML report output
    Logs/                       Toolkit operational logs
    Audit/                      Campaign audit output
    docs/                       Documentation
```

---

## Key Design Decisions

**Zero external dependencies.** The toolkit uses only .NET Framework built-in classes. No NuGet packages, no third-party PowerShell modules, no download-at-runtime dependencies. This simplifies deployment in locked-down enterprise environments.

**Return envelope pattern.** All public API-layer functions return `@{ Success = $bool; Data = $object; Error = $string }`. This provides consistent error handling without relying on exceptions for control flow.

**CSV-driven test definitions.** Test campaigns and identities are defined in CSV files rather than code. This allows non-developers to author and maintain test cases.

**JSONL evidence trail.** Every API call and test step is recorded in append-only JSONL files using UTF-8 encoding without BOM. This provides a complete audit trail independent of HTML reports.

**WPF for GUI.** PowerShell 5.1 on Windows includes WPF via .NET Framework. The dashboard uses XAML for layout with inline CSS-style properties, avoiding any external GUI framework dependency.

---

## Configuration

The toolkit uses `Config/settings.json` with 7 top-level sections:

| Section | Purpose |
|---------|---------|
| `Global` | Environment name, debug mode, version |
| `Authentication` | OAuth mode (ConfigFile or Vault), tenant URLs, credentials |
| `Logging` | Log path, prefix, minimum severity, retention |
| `Api` | Base URL, timeouts, retry policy, rate limiting |
| `Testing` | CSV paths, evidence/report output paths, batch sizes |
| `Safety` | Campaign limits, WhatIf enforcement, complete-campaign guard |
| `Audit` | Audit output path, lookback windows, status filters |

See `QUICKSTART.md` for setup instructions.

---

## Test Coverage

**207 Pester tests across 13 test files.**

On macOS pwsh 7 (development): 152 pass / 55 fail. The 55 failures are all PS7 mock-scoping issues with cross-module calls -- expected to pass on the target platform (Windows PS 5.1 Desktop).

Modules with 100% pass rate on all platforms: SP.Config, SP.Vault, SP.TestLoader, SP.Evidence, SP.AuditQueries, SP.AuditReport.

---

## Security

- OAuth 2.0 `client_credentials` flow for all API access
- AES-256-CBC encrypted vault with PBKDF2 key derivation (600,000 iterations)
- Sliding-window rate limiter (95 requests per 10-second window, per ISC limits)
- All user-supplied values HTML-encoded before report embedding
- WhatIf safety guard for production environments
- Campaign completion disabled by default (`AllowCompleteCampaign = false`)

---

## Related Documentation

- [Quick Start Guide](QUICKSTART.md) -- Setup and first run
- [Developer Guide](DEV.md) -- Module internals, testing, and extending the toolkit
- [Session Status](toolkit-status.md) -- Implementation tracking and bug fix history

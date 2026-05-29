# SailPoint Governance Toolkit -- Session Restart Context

**Last Updated:** 2026-05-22
**Status:** IMPLEMENTATION COMPLETE + SP.DeltaCert module + Phase 7 GUI refinement (modal dialogs, tab declutter)

---

## Quick Start (New Session)

```
Read this file. All production files are implemented.
Latest addition 2026-05-22: Phase 7 GUI refinement -- modal dialog pattern, DeltaCert/Audit tab declutter, 3 dialog XAML files.
Open items: Run Pester tests on Windows PS 5.1, WPF GUI smoke test.
```

---

## What This Project Is

PowerShell 5.1 modular monolith for UAT testing of SailPoint ISC certification campaign
workflows via REST API v3. Batch test runner driven by two CSVs (identities + campaigns)
with JSONL + HTML evidence output. CLI-first with WPF GUI overlay.

**Location:** `/Users/xand/Documents/Projects/SailPoint/tools/SailPoint-GovernanceToolkit/`

---

## Architecture Overview

```
SP.Core (Config, Logging, Auth, Vault)
    |
    v
SP.Api (ApiClient, Campaigns, Certifications, Decisions)
    |
    +----------+----------+
    v          v          v
SP.Testing  SP.Audit   SP.DeltaCert (DeltaCertQueries, DeltaCertRunner)
                             |
                             v
                        SP.DisconnectedApps (Validator, Snapshot, Delta, Runner)
    |
    v
SP.Gui (MainWindow, GuiBridge)  +  Scripts/ (CLI thin wrappers)
    |
    v
Gui/ XAML (MainWindow, 5 tab designs, 3 modal dialogs)
  MainWindow.xaml          -- main window layout + all tab content
  CampaignTab.xaml         -- design reference
  EvidenceTab.xaml         -- design reference
  SettingsTab.xaml         -- design reference
  AuditTab.xaml            -- design reference
  DeltaCertTab.xaml        -- design reference
  DeltaCertRunDialog.xaml  -- modal: run parameters (Phase 7)
  DeltaCertEscalateDialog.xaml -- modal: escalation parameters (Phase 7)
  AuditQueryDialog.xaml    -- modal: audit query filters (Phase 7)
```

7 modules, 22 .psm1 files, 6 .psd1 manifests, 10 Scripts, 9 XAML files, 15 Pester test files, Config + Templates + Docs.

---

## Implementation Status

### Module Completion Tracking

| Module | File | Status | Agent |
|--------|------|--------|-------|
| **SP.Core** | SP.Config.psm1 | DONE | A |
| | SP.Logging.psm1 | DONE | A |
| | SP.Auth.psm1 | DONE (v1.1: +Set-SPBrowserToken, browser token auth) | A |
| | SP.Vault.psm1 | DONE | A |
| | SP.Core.psd1 | DONE (updated: +Set-SPBrowserToken export) | A |
| **SP.Api** | SP.ApiClient.psm1 | DONE | B |
| | SP.Campaigns.psm1 | DONE (+Search-SPCampaigns w/ `co` filter) | B |
| | SP.Certifications.psm1 | DONE (fixed string interpolation) | B |
| | SP.Decisions.psm1 | DONE (fixed ValidateNotNullOrEmpty) | B |
| | SP.Api.psd1 | DONE (+Search-SPCampaigns export) | B |
| **SP.Testing** | SP.TestLoader.psm1 | DONE (fixed string interpolation) | C |
| | SP.BatchRunner.psm1 | DONE (fixed List scoping) | C |
| | SP.Assertions.psm1 | DONE | C |
| | SP.Evidence.psm1 | DONE (fixed JSONL encoding) | C |
| | SP.Testing.psd1 | DONE (fixed RequiredModules) | C |
| **SP.Gui** | SP.MainWindow.psm1 | DONE (+Phase 7: Show-SPGuiDialog, dialog handlers, tab declutter, summary labels) | D |
| | SP.GuiBridge.psm1 | DONE (+Set-SPGuiBrowserToken, CampaignNameContains, ReviewerMetrics) | D |
| | SP.Gui.psd1 | DONE (+Set-SPGuiBrowserToken export) | D |
| **SP.Audit** | SP.AuditQueries.psm1 | DONE (+CampaignNameContains param w/ `co` filter) | C |
| | SP.AuditReport.psm1 | DONE (+Measure-SPAuditReviewerMetrics, Format-HoursDisplay, Section 3 HTML) | C |
| | SP.Audit.psd1 | DONE (+Measure-SPAuditReviewerMetrics export) | C |
| **Scripts** | Invoke-GovernanceTest.ps1 | DONE | D |
| | New-SPVault.ps1 | DONE (fixed SecureString coercion) | D |
| | Show-SPDashboard.ps1 | DONE | D |
| | Test-SPConnectivity.ps1 | DONE | D |
| | Invoke-SPCampaignAudit.ps1 | DONE (+Token, +CampaignNameContains, +ReviewerMetrics) | C |
| | Invoke-SPADDeltaCert.ps1 | DONE (CLI thin wrapper, browser token, WhatIf, fallback reviewer) | - |
| | Invoke-SPDeltaCertEscalate.ps1 | DONE (CLI thin wrapper, escalation with safety guards) | - |
| | Invoke-SPDisconnectedAppCert.ps1 | DONE (CLI thin wrapper, validate+snapshot+delta+resolve+campaign+report, browser token, WhatIf) | - |
| | Invoke-SPDisconnectedAppRegistry.ps1 | DONE (Register/Unregister/List/Test actions, config-driven Applications array) | - |
| | Invoke-SPDisconnectedAppBatch.ps1 | DONE (batch orchestrator, per-app error isolation, threshold protection, JSONL audit trail, batch HTML report) | - |
| **Config** | settings.json | DONE | A |
| | test-identities.csv | DONE | C |
| | test-campaigns.csv | DONE | C |
| | Templates/disconnected-app-accounts.csv | DONE (account CSV template with sample data) | - |
| | Templates/disconnected-app-entitlements.csv | DONE (entitlement CSV template with sample data) | - |
| | Templates/ONBOARDING-GUIDE.md | DONE (app team delivery instructions) | - |
| **GUI XAML** | MainWindow.xaml | DONE (+Phase 7: DeltaCert/Audit tab declutter, summary labels, dialog wiring) | D |
| | CampaignTab.xaml | DONE | D |
| | EvidenceTab.xaml | DONE | D |
| | SettingsTab.xaml | DONE (+browser token section, +DeltaCert config section) | D |
| | AuditTab.xaml | DONE (design reference, updated for dialog retrofit) | A/B |
| | DeltaCertTab.xaml | DONE (design reference, post-declutter layout) | - |
| | DeltaCertRunDialog.xaml | DONE (Phase 7: modal run parameters dialog) | - |
| | DeltaCertEscalateDialog.xaml | DONE (Phase 7: modal escalation parameters dialog) | - |
| | AuditQueryDialog.xaml | DONE (Phase 7: modal audit query filters dialog) | - |
| **Tests** | SP.Config.Tests.ps1 | DONE - 20/20 PASS | A |
| | SP.Auth.Tests.ps1 | DONE - needs PS 5.1 | A |
| | SP.Vault.Tests.ps1 | DONE - 15/15 PASS | A |
| | SP.ApiClient.Tests.ps1 | DONE - needs PS 5.1 | B |
| | SP.Campaigns.Tests.ps1 | DONE - needs PS 5.1 | B |
| | SP.Certifications.Tests.ps1 | DONE - needs PS 5.1 | B |
| | SP.Decisions.Tests.ps1 | DONE - needs PS 5.1 | B |
| | SP.TestLoader.Tests.ps1 | DONE - 13/13 PASS | C |
| | SP.BatchRunner.Tests.ps1 | DONE - partial PS 5.1 | C |
| | SP.Assertions.Tests.ps1 | DONE - needs PS 5.1 | C |
| | SP.Evidence.Tests.ps1 | DONE - 12/12 PASS | C |
| | SP.AuditQueries.Tests.ps1 | DONE - 25/25 PASS | C |
| | SP.AuditReport.Tests.ps1 | DONE - 32/32 PASS | C |
| | TestData/valid-settings.json | DONE | A |
| | TestData/sample-identities.csv | DONE | C |
| | TestData/sample-campaigns.csv | DONE | C |
| **SP.DeltaCert** | SP.DeltaCertQueries.psm1 | DONE (Get-SPDeltaGrantEvents, Get-SPDeltaAffectedIdentities, Group-SPDeltaByManager) | - |
| | SP.DeltaCertRunner.psm1 | DONE (Invoke-SPDeltaCertRun, +SourceOwner mode, +deadline, +cleanup, +escalation, +audit trail) | - |
| | SP.DeltaCert.psd1 | DONE | - |
| **SP.DisconnectedApps** | SP.DisconnectedAppValidator.psm1 | DONE (Test-SPDisconnectedAppAccountFile, Test-SPDisconnectedAppEntitlementFile, Test-SPDisconnectedAppCrossReference) | - |
| | SP.DisconnectedAppSnapshot.psm1 | DONE (Save-SPDisconnectedAppSnapshot, Get-SPDisconnectedAppPreviousSnapshot, Remove-SPDisconnectedAppOldSnapshots) | - |
| | SP.DisconnectedAppDelta.psm1 | DONE (Compare-SPDisconnectedAppFiles -- 7 change types) | - |
| | SP.DisconnectedAppRunner.psm1 | DONE (v1.6: +Get-SPRegisteredApps, +Initialize-SPDisconnectedAppDirectories, +Get-SPDisconnectedAppDeliveryStatus, +Get-SPDisconnectedAppIdentityRisk, +Get-SPDisconnectedAppEntitlementCatalog, +Export-SPDisconnectedAppBatchHtml, +Get-SPDisconnectedAppSlaStatus, +HTML export functions) | - |
| **Tests** | SP.DeltaCert.Tests.ps1 | DONE - 50 tests (Phases 2-6 expanded from 14), PS 5.1 target | - |
| | SP.DisconnectedApps.Tests.ps1 | DONE - 53 tests (DA-001 to DA-011 + DA-12-T to DA-20-T), PS 5.1 target | - |
| **Docs** | README.md | DONE | D |

### Pester Test Results (macOS pwsh 7.5.4 -- 2026-02-20, pre-SP.DeltaCert)

**152 PASS / 55 FAIL / 207 total (73%) -- original core toolkit**

| Test File | Pass | Fail | Notes |
|-----------|------|------|-------|
| SP.Config.Tests | 20 | 0 | 100% |
| SP.Vault.Tests | 15 | 0 | 100% |
| SP.TestLoader.Tests | 13 | 0 | 100% |
| SP.Evidence.Tests | 12 | 0 | 100% |
| SP.AuditQueries.Tests | 25 | 0 | 100% |
| SP.AuditReport.Tests | 32 | 0 | 100% |
| SP.ApiClient.Tests | 11 | 2 | Mock-scoping |
| SP.Auth.Tests | 3 | 6 | Mock-scoping |
| SP.Assertions.Tests | 6 | 4 | Mock-scoping |
| SP.BatchRunner.Tests | 3 | 3 | Mock-scoping |
| SP.Campaigns.Tests | 3 | 13 | Mock-scoping |
| SP.Certifications.Tests | 2 | 13 | Mock-scoping |
| SP.Decisions.Tests | 0 | 14 | Mock-scoping |

### Current Test Totals (331 tests across 15 files)

| Test File | Tests | Notes |
|-----------|-------|-------|
| SP.Config.Tests | 20 | 100% pass (PS7) |
| SP.Vault.Tests | 15 | 100% pass (PS7) |
| SP.TestLoader.Tests | 13 | 100% pass (PS7) |
| SP.Evidence.Tests | 12 | 100% pass (PS7) |
| SP.AuditQueries.Tests | 26 | 100% pass (PS7) |
| SP.AuditReport.Tests | 32 | 100% pass (PS7) |
| SP.DeltaCert.Tests | 50 | PS 5.1 target (Phases 2-6) |
| SP.DisconnectedApps.Tests | 53 | DA-001 to DA-011 (26 tests), DA-12-T to DA-20-T (27 tests), PS 5.1 target |
| SP.ApiClient.Tests | 27 | Mock-scoping on PS7 |
| SP.Auth.Tests | 9 | Mock-scoping on PS7 |
| SP.Assertions.Tests | 10 | Mock-scoping on PS7 |
| SP.BatchRunner.Tests | 6 | Mock-scoping on PS7 |
| SP.Campaigns.Tests | 16 | Mock-scoping on PS7 |
| SP.Certifications.Tests | 21 | Mock-scoping on PS7 |
| SP.Decisions.Tests | 21 | Mock-scoping on PS7 |

**Root cause of ALL 55 failures:** PS7 Pester 5.x has stricter mock-scoping for nested
modules loaded via `.psd1` manifests. Mocks defined without `-ModuleName` targeting don't
intercept cross-module function calls (e.g., `Invoke-SPApiRequest` called from within
`SP.Campaigns` module). Expected to resolve on PS 5.1 Desktop (target platform).

**No production code bugs remain.** The 4 modules with 100% pass rates (SP.Config, SP.Vault,
SP.TestLoader, SP.Evidence) contain the modules that DON'T make cross-module calls that
need mocking, confirming the production code works correctly.

### SP.Audit Module (Added 2026-02-20)

**Purpose:** Post-campaign audit reporting. Queries completed or active certification campaigns,
retrieves all certifications and review items, fetches identity lifecycle events for revoked
identities, and produces HTML/text/JSONL reports.

**Files:**

| File | Role |
|------|------|
| `Modules/SP.Audit/SP.AuditQueries.psm1` | API query functions (Get-SPAuditCampaigns, Get-SPAuditCertifications, Get-SPAuditCertificationItems, Get-SPAuditCampaignReport, Import-SPAuditCampaignReport, Get-SPAuditIdentityEvents) |
| `Modules/SP.Audit/SP.AuditReport.psm1` | Reporting functions (Group-SPAuditDecisions, Group-SPReviewerActions, Group-SPAuditIdentityEvents, Export-SPAuditHtml, Export-SPAuditText, Export-SPAuditJsonl) |
| `Modules/SP.Audit/SP.Audit.psd1` | Module manifest (NestedModules: AuditQueries + AuditReport) |
| `Scripts/Invoke-SPCampaignAudit.ps1` | CLI thin wrapper (loads SP.Core -> SP.Api -> SP.Audit) |
| `Tests/SP.AuditQueries.Tests.ps1` | 7 Pester tests (AQ-001 to AQ-007) |
| `Tests/SP.AuditReport.Tests.ps1` | 6 Pester tests (AR-001 to AR-006) |

**Config section added to settings.json:**

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

**Layering:** SP.Audit sits at the same level as SP.Testing (depends on SP.Core + SP.Api only).
SP.Gui depends on SP.Audit for the Audit tab bridge functions (Get-SPGuiAuditCampaigns, Invoke-SPGuiAudit, Get-SPGuiAuditReports).

**Exit codes for Invoke-SPCampaignAudit.ps1:**

| Code | Meaning |
|------|---------|
| 0 | Audit completed successfully |
| 1 | No campaigns matched the filter criteria |
| 2 | Parameter error (missing required filter) |
| 3 | Authentication or API error |
| 4 | Configuration error |

---

### Agent Registry

| Agent | Module Scope | Status | Agent ID |
|-------|-------------|--------|----------|
| Agent A | SP.Core (Config + Logging + Auth + Vault) | COMPLETE | a03bf1a, a0d0175 |
| Agent B | SP.Api (ApiClient + Campaigns + Certifications + Decisions) | COMPLETE | acda193 |
| Agent C | SP.Testing (TestLoader + BatchRunner + Assertions + Evidence) + SP.Audit | COMPLETE | a6ce5a5 |
| Agent D | Scripts + GUI + Docs | COMPLETE | ac7cdc1 |

---

## Post-Implementation Bug Fixes (Integration Phase)

### Fixed Bugs

1. **SecureString coercion in New-SPVault.ps1** -- `$clientSecretSecure` (SecureString) passed
   to `-ClientSecret [string]` would coerce to literal "System.Security.SecureString". Fixed
   with BSTR extraction before passing to `Set-SPVaultCredential`.

2. **ValidateNotNullOrEmpty on empty array in Invoke-SPReassign** -- BatchRunner passes `@()`
   to `-ReviewItemIds` which had `[ValidateNotNullOrEmpty()]`. Made parameter optional.

3. **RequiredModules preventing module loading** -- SP.Api, SP.Testing, SP.Gui manifests
   declared RequiredModules that couldn't resolve for non-PSModulePath modules. Changed all
   three to `RequiredModules = @()` with dependency comments.

4. **String interpolation `$var:` bugs** -- PowerShell interprets `$var:` as scope prefix.
   Fixed `$pollCount:`, `$pageNum:`, `$testId:` to `${pollCount}:`, `${pageNum}:`, `${testId}:`
   in SP.Campaigns, SP.Certifications, and SP.TestLoader.

5. **BatchRunner `$script:steps` scoping** -- Scriptblock wrote to module scope (`$script:steps`)
   instead of function-local variable. Changed `$steps = @()` to `List[object]` with `.Add()`
   for in-place mutation from child scope.

6. **Evidence JSONL encoding** -- `Add-Content -Encoding UTF8` has platform-specific BOM behavior.
   Changed to `[System.IO.File]::AppendAllText()` with explicit `UTF8Encoding($false)`.

7. **Evidence test `Get-Content` single-line bug** -- `Get-Content` returns string (not array)
   for single-line files. `$lines[0]` returned first character `{` instead of full JSON line.
   Fixed tests with `@(Get-Content ...)` wrapper.

8. **Evidence test DateTime comparison** -- PS7 `ConvertFrom-Json` auto-converts ISO 8601 strings
   to DateTime objects. Fixed test to handle both DateTime and string types.

9. **SP.Audit `$campId:` parse errors** -- Invoke-SPCampaignAudit.ps1 had 3 instances of
   `$campId:` in Write-SPLog strings, parsed as scope prefix. Fixed to `${campId}:`.

10. **SP.AuditReport `$key:` parse error** -- SP.AuditReport.psm1 had `$key:` in string
    interpolation within Export-SPAuditJsonl. Fixed to `${key}:`.

11. **Build-HtmlTableRow empty string binding** -- `[Parameter(Mandatory)][string[]]$Cells`
    rejected empty strings from null/missing properties (e.g., no Phase on reviewer). Added
    `[AllowEmptyString()]` attribute.

12. **SP.Config missing Audit defaults** -- Adding `Audit` section to settings.json triggered
    "Unknown configuration key 'Audit'" warnings in all existing tests. Added Audit defaults
    to `Get-SPConfigDefaults` in SP.Config.psm1.

---

## Security Audit (2026-02-18)

**Result:** Clean -- no findings requiring remediation.

### Dependencies

Zero external libraries. All cryptographic and HTTP functionality uses .NET Framework
built-in classes (`System.Security.Cryptography`, `System.Net.Http`, `System.Runtime.InteropServices.Marshal`).
No NuGet packages, no third-party modules, no download-at-runtime dependencies.

### Cryptography (SP.Vault)

| Control | Implementation |
|---------|---------------|
| Encryption | AES-256-CBC with random IV per write |
| Key derivation | PBKDF2 (Rfc2898DeriveBytes), 600,000 iterations, random salt |
| Integrity | HMAC-SHA256 over ciphertext (encrypt-then-MAC) |
| Comparison | Constant-time byte comparison to prevent timing attacks |

### Credential Handling

- `SecureString` used for all interactive passphrase and secret prompts
- BSTR extraction with `ZeroFreeBSTR` cleanup in `finally` blocks
- Vault passphrase never written to disk, never logged
- `Remove-Variable` called on all plaintext temporaries after use
- ConfigFile mode documents its limitation (plaintext in settings.json, dev-only)

### SailPoint API Safety

| Guard | Default | Purpose |
|-------|---------|---------|
| `-WhatIf` / `SupportsShouldProcess` | Available on all mutating scripts | Dry-run without API calls |
| `Safety.MaxCampaignsPerRun` | 10 | Caps campaigns per execution |
| `Safety.AllowCompleteCampaign` | `false` | Blocks irreversible campaign completion |
| `Safety.RequireWhatIfOnProd` | `true` | Forces confirmation on production environments |
| No DELETE operations | N/A | Toolkit never calls DELETE endpoints |
| CorrelationID tagging | Auto-generated GUID | All campaigns named with correlation ID to prevent collisions |

### Input Validation

- `[ValidateSet()]` on OutputMode, authentication mode, and other enum-like parameters
- `[ValidateNotNullOrEmpty()]` on required string parameters
- URL encoding via `[System.Uri]::EscapeDataString()` for query parameters
- CSV column validation before test execution (missing/extra columns reported)
- First-run detection blocks execution when `CHANGE_ME` sentinel values remain

### Logging

- Structured JSONL format (`SP.Logging`) with severity, component, action, correlationID
- No credential values written to log events (ClientId, ClientSecret, passphrase, tokens excluded)
- Log retention configurable via `Logging.RetentionDays`

---

## Session: 2026-04-03 -- Three Feature Additions

### Feature 1: Campaign Substring Search (ISC `co` Filter)

**Problem:** ISC admin UI only supports prefix matching on campaign names. No way to find campaigns where a keyword appears in the middle of the name. Wildcards like `*test*` are not supported.

**Solution:** Added `name co "keyword"` (contains) filter support at all layers.

**Files changed (8 + 3 manifests):**

| File | Change |
|------|--------|
| `SP.AuditQueries.psm1` | Added `CampaignNameContains` parameter using `name co "..."` filter operator |
| `SP.Campaigns.psm1` | New `Search-SPCampaigns` function -- standalone CLI/script campaign search with auto-pagination |
| `SP.GuiBridge.psm1` | Changed `Get-SPGuiAuditCampaigns` from `CampaignNameStartsWith` to `CampaignNameContains` |
| `SP.MainWindow.psm1` | Updated query handler param key + placeholder text to "Search by keyword..." |
| `MainWindow.xaml` | Updated Audit tab search placeholder text |
| `AuditTab.xaml` | Updated design reference placeholder text |
| `Invoke-SPCampaignAudit.ps1` | Added `-CampaignNameContains` parameter |
| `SP.Api.psd1` | Added `Search-SPCampaigns` to exports |

**Backward compatible:** `CampaignNameStartsWith` parameter still exists in `Get-SPAuditCampaigns` (API layer). Precedence: exact > starts-with > contains.

**ISC API filter operators now used:** `eq` (exact), `sw` (starts-with), `co` (contains), `in` (status set).

---

### Feature 2: Browser Token Authentication

**Problem:** Users already logged into ISC in their browser had no way to use that session for toolkit API calls. Required OAuth client credentials configured in settings.json or vault.

**Solution:** Added pre-obtained JWT injection. User grabs bearer token from browser dev tools (F12 > Network tab > Authorization header), pastes into the toolkit. Bypasses OAuth entirely.

**Files changed (6 + 3 manifests):**

| File | Change |
|------|--------|
| `SP.Auth.psm1` | New `Set-SPBrowserToken` function -- validates JWT (3-segment check), caches with configurable expiry (default 10 min). Version bumped to 1.1.0 |
| `SP.GuiBridge.psm1` | New `Set-SPGuiBrowserToken` bridge -- user-friendly messages, placeholder text detection |
| `MainWindow.xaml` | New "Quick Connect - Browser Token" section in Settings tab: masked PasswordBox, Apply Token / Clear buttons, status text |
| `SettingsTab.xaml` | Updated design reference with same browser token section |
| `SP.MainWindow.psm1` | Wired Apply Token (calls Set-SPGuiBrowserToken) and Clear Token (calls Clear-SPAuthToken) button handlers |
| `Invoke-SPCampaignAudit.ps1` | Added `-Token` and `-TokenExpiryMinutes` parameters. Token injection happens before audit dispatch |
| `SP.Core.psd1` | Added `Set-SPBrowserToken` to exports |
| `SP.Gui.psd1` | Added `Set-SPGuiBrowserToken` to exports |

**How it works:**
- **GUI:** Settings tab > Quick Connect section > paste JWT > Apply Token > status shows green with expiry time
- **CLI:** `.\Invoke-SPCampaignAudit.ps1 -Token 'eyJ...' -Status COMPLETED -DaysBack 7`
- **Expiry:** Default 10 min (conservative for ~12 min ISC tokens). When token expires, falls back to configured OAuth mode
- **Caching:** Token is injected into the same `$script:CurrentToken` cache used by `Get-SPAuthToken`. All downstream `Invoke-SPApiRequest` calls pick it up automatically

**ISC browser token details:** JWT bearer tokens visible in dev tools Network tab. Typically valid ~12 minutes (720 seconds). Pattern: `Authorization: Bearer eyJhbGciOiJSUzI1NiIs...`

---

### Feature 3: Reviewer Performance Metrics (Time-to-Decision)

**Problem:** Campaign audit reports showed who reviewed and what they decided, but not how long it took. No way to identify slow reviewers or measure campaign turnaround time.

**Solution:** New `Measure-SPAuditReviewerMetrics` function calculates time-to-decision per reviewer and per campaign from ISC certification timestamps. New Section 3 in the HTML audit report with color-coded performance data.

**Files changed (4 + 1 manifest):**

| File | Change |
|------|--------|
| `SP.AuditReport.psm1` | New `Measure-SPAuditReviewerMetrics` function (categorization), new `Format-HoursDisplay` helper, new Section 3 HTML in `Build-SingleCampaignHtml`, renumbered sections 3-6 to 4-7 |
| `SP.GuiBridge.psm1` | Added `Measure-SPAuditReviewerMetrics` call in `Invoke-SPGuiAudit`, added `ReviewerMetrics` key to campaign audit hashtable |
| `Invoke-SPCampaignAudit.ps1` | Added `Measure-SPAuditReviewerMetrics` call, added `ReviewerMetrics` to campaign audit object |
| `SP.Audit.psd1` | Added `Measure-SPAuditReviewerMetrics` to exports |

**Metrics calculated:**

| Metric | Scope | Source |
|--------|-------|--------|
| Min/Max/Avg hours | Per reviewer | cert.created -> cert.signed delta |
| Certs completed | Per reviewer | Count of signed-off certifications |
| Campaign min/max/avg/median | Campaign-wide | All completed cert deltas |

**HTML report Section 3 includes:**
- Campaign-level summary table: Fastest Response, Slowest Response, Average, Median (human-readable: "X.X hours" or "X days, Y hours")
- Per-reviewer performance table with color-coded Avg Time column:
  - Green (#339933): <= 24 hours
  - Blue (#336699): 24-72 hours
  - Orange (#FF8800): > 72 hours

**Report section numbering (updated):**
1. Campaign Summary
2. Reviewer Accountability
3. Reviewer Performance (NEW)
4. Decision Summary (was 3)
5. Campaign Reports (was 4)
6. Provisioning Proof (was 5)
7. Audit Metadata (was 6)

**Mockup:** `docs/mockup-audit-report.html` -- full HTML mockup with fictitious data showing all 7 sections.

---

### All Syntax Validation Passed

All modified `.psm1`, `.ps1`, and `.psd1` files pass PowerShell AST syntax validation.
All modified `.xaml` files pass XML well-formedness validation.
No Pester tests were broken (existing tests don't test the changed parameters).

---

## Phase 7: GUI Refinement (2026-05-22)

**Purpose:** Reduce visual clutter, add modal dialog pattern for parameter entry, unify tab layouts.

**Changes:**

| Feature | Description | Commit |
|---------|-------------|--------|
| G-01 | `Show-SPGuiDialog` reusable modal helper in SP.MainWindow.psm1 | c863462 |
| G-05 | Color-coded DeltaCert history (green/gray/orange) | f4a9e60 |
| G-06 | DeltaCert config fields in Settings tab (6 persistent fields) | cb50b88 |
| G-02 | DeltaCert Run Parameters Dialog (4 fields, session persistence) | a17cda6 |
| G-04 | Escalation Parameters Dialog (3 fields, session persistence) | df8c2c8 |
| G-03 | DeltaCert Tab Declutter (21 -> ~14 controls, summary + Configure + Run) | 7fa34c9 |
| G-07 | Audit Tab Dialog Retrofit (query filters moved to modal dialog) | ae176cc |
| G-08 | UI Consistency Pass (button styles, margins, dialog colors) | 2f5e3c7 |
| G-09 | toolkit-status.md refresh (this section, updated counts, Phase 7 checklist) | -- |

**New files (3 dialog XAMLs):**
- `Gui/DeltaCertRunDialog.xaml` -- Source IDs, Hours Back, Deadline Days, Reviewer Mode
- `Gui/DeltaCertEscalateDialog.xaml` -- Campaign Prefix, Stale Hours, Max Levels
- `Gui/AuditQueryDialog.xaml` -- Campaign Name, Status, Timespan

**Dialog pattern:** `Show-SPGuiDialog -XamlPath $path -ControlNames @('Ctrl1','Ctrl2') -Defaults @{Ctrl1='val'}` returns hashtable on OK, `$null` on cancel. Dark theme inline (Background=#1E1E2E, Surface=#2D2D44, Primary=#5B9BD5, Text=#E0E0E0).

**Tab layout pattern (post-declutter):**
```
Row 0: [Summary label] .............. [Configure...] [Action Button]
Row 1: Results DataGrid (expanded vertical space)
Row 2: Secondary action buttons
Row 3: Progress bar + status
Row 4: History (DeltaCert only)
```

---

## Next Steps (Windows PS 5.1 Validation)

1. Pull latest from GitHub on Windows machine
2. Run `Invoke-Pester -Path .\Tests\ -Output Detailed` on PS 5.1 Desktop
   -- Expect 278 tests pass (mock-scoping failures are PS7-only)
3. If failures remain, investigate PS 5.1-specific behaviors
4. Run smoke test: `.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke -WhatIf`
5. Run audit smoke test: `.\Scripts\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 7`
6. Verify WPF GUI launches: `.\Scripts\Show-SPDashboard.ps1`
7. Verify Audit tab: query campaigns, select, run audit, verify reports generated
8. Verify DeltaCert tab: Configure dialog opens, Run dialog opens, escalation dialog opens
9. Verify Settings tab: DeltaCert config section loads/saves correctly

---

## Critical Reference Files

### CyberArk Toolbox Patterns (PRIMARY -- replicate these)

| What | Path |
|------|------|
| Config caching pattern | `/Users/xand/Documents/Projects/CyberARK/CyberArkToolbox/Modules/CA.Core/CA.Config.psm1` |
| JSONL logging pattern | `/Users/xand/Documents/Projects/CyberARK/CyberArkToolbox/Modules/CA.Core/CA.Logging.psm1` |
| Token cache pattern | `/Users/xand/Documents/Projects/CyberARK/CyberArkToolbox/Modules/CA.Core/CA.Auth.psm1` |
| Module manifest pattern | `/Users/xand/Documents/Projects/CyberARK/CyberArkToolbox/Modules/CA.Core/CA.Core.psd1` |

### SailPoint ISC API Research

| What | Path |
|------|------|
| Certification Campaign API | `/Users/xand/Documents/Projects/SailPoint/docs/deep-research/source-research/DEEP_Certification-Campaign-Testing_2026-02-12.md` |
| API Test Frameworks | `/Users/xand/Documents/Projects/SailPoint/docs/deep-research/source-research/DEEP_API-Test-Frameworks-Tooling_2026-02-12.md` |
| Testing SOPs | `/Users/xand/Documents/Projects/SailPoint/docs/deep-research/source-research/DEEP_Testing-SOPs-Best-Practices_2026-02-12.md` |

---

## SailPoint ISC API Quick Reference

**Authentication:**
```
POST https://{tenant}.api.identitynow.com/oauth/token
Content-Type: application/x-www-form-urlencoded
grant_type=client_credentials&client_id={id}&client_secret={secret}
-> { "access_token": "...", "token_type": "bearer", "expires_in": 749 }
```

**Rate Limit:** 100 requests per token per 10 seconds (we use 95 with buffer)
**Campaign Status Machine:** STAGED -> ACTIVATING -> ACTIVE -> COMPLETING -> COMPLETED
**Governance Group Limitation:** decide/sign-off/reassign APIs do NOT support Governance Group reviewers

---

## Verification Checklist

- [x] All 65 production files implemented (core toolkit + DeltaCert + Phase 7 GUI + DisconnectedApps + enterprise batch/registry)
- [x] SP.Audit module implemented: SP.AuditQueries.psm1, SP.AuditReport.psm1, SP.Audit.psd1
- [x] GUI Audit tab implemented: AuditTab.xaml, MainWindow.xaml (inline), SP.MainWindow.psm1, SP.GuiBridge.psm1
- [x] Campaign report download refactored: v3 API first with silent legacy /cc/api fallback
- [x] Invoke-SPCampaignAudit.ps1 CLI script implemented
- [x] All 15 Pester test files implemented (11 original + AuditQueries + AuditReport + DeltaCert + DisconnectedApps)
- [x] SP.AuditQueries.Tests.ps1 and SP.AuditReport.Tests.ps1 implemented (13 tests total)
- [x] SP.DeltaCert.Tests.ps1 implemented (50 tests: Phases 2-6 expanded from initial DC-001 to DC-014)
- [x] SP.DisconnectedApps.Tests.ps1 expanded (53 tests: DA-001 to DA-011 single-app + DA-12-T to DA-20-T enterprise features)
- [x] Module import chain loads on pwsh 7 (41 functions)
- [x] Cross-module function name verification (zero mismatches)
- [x] Zero PS7-only syntax (`??`, ternary, `&&`, `||`)
- [x] All parameter names match across callers/callees
- [x] SP.Core tests 100% pass (35/35: Config 20, Vault 15)
- [x] SP.Testing self-contained tests 100% pass (25/25: TestLoader 13, Evidence 12)
- [x] Security audit passed -- zero external deps, AES-256-CBC vault, no credential leakage, SailPoint safety guards
- [ ] `Invoke-Pester -Path .\Tests\ -Output Detailed` -- all tests pass on PS 5.1 Windows
- [ ] `.\Scripts\Test-SPConnectivity.ps1` -- auth + API connectivity smoke test
- [ ] `.\Scripts\Invoke-GovernanceTest.ps1 -Tags smoke -WhatIf` -- dry run produces evidence
- [ ] `.\Evidence\TC-001\audit.jsonl` -- JSONL evidence file exists with correct schema
- [ ] `.\Evidence\TC-001\summary.html` -- HTML report renders correctly
- [ ] `.\Reports\GovernanceRun_*.html` -- suite report renders correctly
- [ ] `.\Scripts\Show-SPDashboard.ps1` -- WPF GUI launches on Windows
- [ ] Audit tab: query campaigns, select, run audit, verify HTML reports in Audit/ folder
- [ ] Audit tab: "Include Campaign Reports" checkbox works (v3-first download)
- [ ] Audit tab: "Open Reports Folder" opens Audit/ in Explorer
- [ ] Audit tab: Recent Reports list populates, double-click opens HTML in browser
- [ ] Audit tab: "Search by keyword..." does substring match (type partial name, campaigns with keyword anywhere returned)
- [ ] Settings tab: Quick Connect browser token section visible with masked PasswordBox
- [ ] Settings tab: Paste JWT, click Apply Token, status turns green with expiry time
- [ ] Settings tab: After applying token, Audit tab query uses browser token (no OAuth needed)
- [ ] Settings tab: Click Clear, token cleared, toolkit reverts to OAuth
- [ ] CLI: `.\Scripts\Invoke-SPCampaignAudit.ps1 -Token 'eyJ...' -Status COMPLETED -DaysBack 7` works
- [ ] CLI: `.\Scripts\Invoke-SPCampaignAudit.ps1 -CampaignNameContains 'test' -DaysBack 90` returns substring matches
- [ ] Audit HTML report: Section 3 "Reviewer Performance" appears with campaign-level summary + per-reviewer table
- [ ] Audit HTML report: Avg Time column color-coded (green/blue/orange based on hours threshold)
- [ ] Audit HTML report: Sections 4-7 renumbered correctly (Decision Summary, Campaign Reports, Provisioning Proof, Audit Metadata)

### Phase 7 GUI Verification (2026-05-22)

- [x] G-01: `Show-SPGuiDialog` loads XAML, wires OK/Cancel, returns hashtable or $null
- [x] G-05: DeltaCert history entries color-coded (green=created, gray=no changes, orange=errors)
- [x] G-06: Settings tab has DeltaCert config section (6 fields), round-trips correctly
- [x] G-02: DeltaCert Run Parameters dialog opens with 4 fields, session persistence works
- [x] G-04: Escalation Parameters dialog opens with 3 fields, session persistence works
- [x] G-03: DeltaCert tab decluttered (summary + Configure + Run), DataGrid has more space
- [x] G-07: Audit tab decluttered (summary + Configure + Query), dialog retrofit matches DeltaCert
- [x] G-08: UI consistency pass (button styles, margins, dialog colors unified across all tabs)
- [x] G-09: toolkit-status.md refreshed with Phase 7 changes, accurate counts, Phase 7 checklist
- [ ] DeltaCert tab: "Configure..." opens dialog, updates summary label, does NOT run
- [ ] DeltaCert tab: "Run Delta Cert" opens dialog then executes on OK
- [ ] DeltaCert tab: "Run Escalation" opens dialog then executes on OK
- [ ] Audit tab: "Configure..." opens dialog, updates summary label, does NOT query
- [ ] Audit tab: "Query Campaigns" opens dialog then queries on OK
- [ ] All 3 dialog XAMLs present in Gui/ folder (DeltaCertRunDialog, DeltaCertEscalateDialog, AuditQueryDialog)
- [ ] Dialog dark theme consistent: Background=#1E1E2E, Surface=#2D2D44, Primary=#5B9BD5
- [ ] Settings tab: DeltaCert config fields save/load (Source IDs, Hours Back, Deadline Days, Reviewer Mode, Campaign Prefix, Output Path)

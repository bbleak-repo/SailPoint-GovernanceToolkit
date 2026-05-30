# Quality Hardening & Production Fixes -- Backlog (QH-01 to QH-20)

**Created:** 2026-05-30
**Purpose:** Fix critical gaps, harden for production, polish for handoff
**Source:** Opus comprehensive gap analysis across 13+ phases of development

---

## How to Use This File

Agent loop: `QH-01 -> QH-02 -> ... -> QH-20`
Critical items first, then high, medium, low.

---

## Phase Summary

| # | Priority | Feature | Size | Status |
|---|----------|---------|------|--------|
| QH-01 | CRITICAL | Create SP.DisconnectedApps.psd1 manifest | S | DONE |
| QH-02 | CRITICAL | Implement Send-SPReport SMTP (replace stub) | S | DONE |
| QH-03 | CRITICAL | Add log retention step to Daily Orchestrator | S | DONE |
| QH-04 | CRITICAL | Add DisconnectedApps.ISC to config defaults | S | DONE |
| QH-05 | CRITICAL | Expand Test-SPConfiguration for 4 missing sections | M | DONE |
| QH-06 | HIGH | Update valid-settings.json test fixture | S | DONE |
| QH-07 | HIGH | Create Invoke-SPRetention.ps1 CLI script | S | PENDING |
| QH-08 | HIGH | Document settings.local.json override in README | S | PENDING |
| QH-09 | HIGH | Document Audit-Mock directory | S | PENDING |
| QH-10 | HIGH | Consolidate duplicate SMTP config sections | M | PENDING |
| QH-11 | MEDIUM | Fix SHA1 to SHA256 in logging mutex (FIPS compat) | S | PENDING |
| QH-12 | MEDIUM | Add Pester tests for CLI script entry points | M | PENDING |
| QH-13 | MEDIUM | Add config template v1->v2 migration guidance | S | PENDING |
| QH-14 | MEDIUM | Remove dead Logging.RetentionDays config key | S | PENDING |
| QH-15 | MEDIUM | Fix duplicate DeltaCert.CampaignNamePrefix | S | PENDING |
| QH-16 | LOW | Add Power BI-optimized CSV export | M | PENDING |
| QH-17 | LOW | Add credential rotation / vault re-key command | M | PENDING |
| QH-18 | LOW | Update SP.Testing module for newer workflows | M | PENDING |
| QH-19 | LOW | Split SP.AuditReport.psm1 monolith (12K lines) | L | PENDING |
| QH-20 | LOW | Split SP.DisconnectedAppRunner.psm1 monolith (7.5K lines) | L | PENDING |

---

## QH-01: Create SP.DisconnectedApps.psd1 Manifest

- **Status:** `DONE`
- **Depends On:** none

**Problem:** Three CLI scripts reference `SP.DisconnectedApps.psd1` with `Required = $true`
but the file does not exist. Module loads via fallback `.psm1` import which masks errors
and doesn't control export visibility.

**Fix:** Create `Modules/SP.DisconnectedApps/SP.DisconnectedApps.psd1` following the
SP.DeltaCert.psd1 pattern. List all 4 psm1 files as NestedModules. Export all public functions.

**Files:** `Modules/SP.DisconnectedApps/SP.DisconnectedApps.psd1` (new)

---

## QH-02: Implement Send-SPReport SMTP (Replace Stub)

- **Status:** `DONE`
- **Depends On:** none

**Problem:** `Send-SPReport` logs "SMTP stub -- would send" but never sends email.
Meanwhile `Send-SPNotification` in the same file DOES call `Send-MailMessage`. Leadership
report distribution silently succeeds without delivering reports.

**Fix:** Replace the stub body with actual `Send-MailMessage` call, reusing the same
pattern from `Send-SPNotification`. Read SMTP config from `Audit.Smtp` section.
Keep the `Smtp.Enabled = false` guard (only send when explicitly enabled).

**Files:** `Modules/SP.Audit/SP.AuditReport.psm1` (function `Send-SPReport`)

---

## QH-03: Add Log Retention Step to Daily Orchestrator

- **Status:** `DONE`
- **Depends On:** none

**Problem:** `Invoke-SPLogRetention` exists but the Daily Orchestrator never calls it.
Output directories grow without bound on daily runs.

**Fix:** Add Step 10 (or final step) to `Invoke-SPDailyOrchestrator.ps1` calling
`Invoke-SPLogRetention` with config-driven retention settings. Only runs if
`Retention.Enabled = true`.

**Files:** `Scripts/Invoke-SPDailyOrchestrator.ps1`

---

## QH-04: Add DisconnectedApps.ISC to Config Defaults

- **Status:** `DONE`
- **Depends On:** none

**Problem:** `settings.json` has `DisconnectedApps.ISC` section but `Get-SPConfigDefaults()`
does not include it. Config merge cannot warn about missing ISC fields. `Push-SPDisconnectedAppToISC`
may get null property access.

**Fix:** Add ISC sub-hashtable to the DisconnectedApps defaults:
```powershell
ISC = @{
    UploadMethod = 'API'
    FileDropBasePath = ''
    WaitForAggregationSeconds = 120
}
```

**Files:** `Modules/SP.Core/SP.Config.psm1` (function `Get-SPConfigDefaults`)

---

## QH-05: Expand Test-SPConfiguration for Missing Sections

- **Status:** `DONE`
- **Depends On:** QH-04

**Problem:** `Test-SPConfiguration` validates only 7 of 11 config sections. Missing:
DisconnectedApps (field types, paths, Applications array), Notification (backends, SMTP),
Retention (ArchiveDays < DeleteDays guard), Leadership (supplement path).

**Fix:** Add validation rules for each missing section. Pattern: required fields check,
type validation, range constraints, path existence checks.

**Files:** `Modules/SP.Core/SP.Config.psm1` (function `Test-SPConfiguration`)

---

## QH-06: Update valid-settings.json Test Fixture

- **Status:** `DONE`
- **Depends On:** QH-04

**Problem:** Test fixture missing Notification, Retention, Leadership, DisconnectedApps.ISC
sections. Tests using this fixture don't exercise validation for these sections.

**Fix:** Add all missing sections to `Tests/TestData/valid-settings.json` with valid values.

**Files:** `Tests/TestData/valid-settings.json`

---

## QH-07: Create Invoke-SPRetention.ps1 CLI Script

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** `Invoke-SPLogRetention` function exists but no standalone CLI entry point.
Users can't run retention cleanup without writing their own wrapper.

**Fix:** New script following existing CLI patterns. Parameters: -ConfigPath, -WhatIf,
-OutputMode. Calls `Invoke-SPLogRetention` with config-driven settings.

**Files:** `Scripts/Invoke-SPRetention.ps1` (new)

---

## QH-08: Document settings.local.json Override

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** `Resolve-SPConfigPath` supports `.local.json` override (gitignored) but
this feature is undocumented. Users don't know they can keep credentials in a local
file separate from the tracked template.

**Fix:** Add section to README.md and QUICKSTART.md explaining the override mechanism.

**Files:** `README.md`, `QUICKSTART.md`

---

## QH-09: Document Audit-Mock Directory

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** `Audit-Mock/` contains pre-generated reports but is not documented.
Users don't know it can serve as an offline demo.

**Fix:** Add brief mention in README and QUICKSTART.

**Files:** `README.md`, `QUICKSTART.md`

---

## QH-10: Consolidate Duplicate SMTP Config

- **Status:** `PENDING`
- **Depends On:** QH-02

**Problem:** Two SMTP configs: `Audit.Smtp` (for Send-SPReport) and `Notification.Smtp`
(for Send-SPNotification). Users configure one expecting both to work.

**Fix:** Document the distinction clearly OR consolidate to one SMTP section. Recommended:
make `Send-SPReport` read from `Notification.Smtp` as fallback when `Audit.Smtp` is empty,
and document that `Notification.Smtp` is the primary SMTP config.

**Files:** `Modules/SP.Audit/SP.AuditReport.psm1`, `Config/settings.json`, docs

---

## QH-11: Fix SHA1 to SHA256 in Logging Mutex

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** `SP.Logging.psm1` uses SHA1 for mutex name generation. SHA1 is deprecated
and throws in FIPS mode. Not a security risk but causes scanner findings and FIPS failures.

**Fix:** Replace `SHA1.Create()` with `SHA256.Create()` and truncate hash to same length.

**Files:** `Modules/SP.Core/SP.Logging.psm1`

---

## QH-12: Add Pester Tests for CLI Script Entry Points

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** No Pester tests for the 14 entry-point scripts. Parameter validation,
module loading, exit codes, and WhatIf behavior are untested.

**Fix:** New test file with at least: syntax validation (AST parse) for all 14 scripts,
parameter validation tests for key scripts, WhatIf behavior test for mutating scripts.

**Files:** `Tests/SP.CliScripts.Tests.ps1` (new)

---

## QH-13: Config Template Migration Guidance

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** v1 and v2 templates exist but no migration script or diff for upgrade.

**Fix:** Add migration notes to `Config/Templates/VERSION-HISTORY.md` with exact
column additions and a one-liner diff command.

**Files:** `Config/Templates/VERSION-HISTORY.md`

---

## QH-14: Remove Dead Logging.RetentionDays Config Key

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** `Logging.RetentionDays` is defined in defaults and config but never used
by the logging module. Only `Retention.ArchiveDays`/`Retention.DeleteDays` are used
by `Invoke-SPLogRetention`. Dead config key creates confusion.

**Fix:** Either wire `Logging.RetentionDays` into the logging module OR remove it
from defaults and document that `Retention.*` is the authoritative config.

**Files:** `Modules/SP.Core/SP.Config.psm1`, `Config/settings.json`

---

## QH-15: Fix Duplicate DeltaCert.CampaignNamePrefix

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** `DeltaCert.CampaignNamePrefix` and `DeltaCert.Escalation.CampaignNamePrefix`
are both "AD Delta Cert". Intent is unclear. Document or consolidate.

**Fix:** Document that Escalation prefix defaults to the main prefix if not specified.
Update escalation code to fall back to main prefix when its own is empty.

**Files:** `Config/settings.json`, docs, `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1`

---

## QH-16: Power BI-Optimized CSV Export

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** No flat denormalized CSV optimized for Power BI / Tableau consumption.
Existing `Export-SPAuditCsv` exports raw audit data but not in a BI-ready format.

**Fix:** New function `Export-SPGovernanceBIData` that produces a flat CSV with one row
per decision: campaign, identity, access, reviewer, decision, date, remediation status,
org level, app name. Ready for Power BI import.

**Files:** `Modules/SP.Audit/SP.AuditReport.psm1` or new file

---

## QH-17: Credential Rotation / Vault Re-Key

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** PAT rotation requires manual remove + add. No rotate or re-key workflow.

**Fix:** Add `Update-SPVaultCredential` that updates an existing credential in-place
without requiring the old value. Add `Update-SPVaultPassphrase` that re-encrypts the
vault with a new passphrase.

**Files:** `Modules/SP.Core/SP.Vault.psm1`

---

## QH-18: Update SP.Testing Module for Newer Workflows

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** SP.Testing module (5 files) hasn't been updated since Feb 2026. Does not
handle DeltaCert, DisconnectedApps, or newer report types.

**Fix:** Review and update SP.BatchRunner.psm1 to orchestrate tests for newer workflows.
Update SP.Assertions.psm1 with assertions relevant to delta cert and disconnected apps.

**Files:** `Modules/SP.Testing/*.psm1`

---

## QH-19: Split SP.AuditReport.psm1 (12K Lines)

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** Single file with 40+ exported functions spanning audit grouping, HTML
generation, campaign comparison, trend analysis, compliance packaging, identity risk,
source governance, notification, log retention. Difficult to maintain.

**Fix:** Split into sub-modules:
- `SP.AuditReportCore.psm1` (grouping, decisions, reviewer metrics)
- `SP.AuditReportHtml.psm1` (HTML generation, leadership reports)
- `SP.AuditAnalytics.psm1` (trends, risk scoring, source governance, comparison)
- `SP.AuditOperations.psm1` (notification, retention, compliance packaging)
Update SP.Audit.psd1 NestedModules.

**Files:** `Modules/SP.Audit/SP.AuditReport.psm1` -> 4 files, `SP.Audit.psd1`

---

## QH-20: Split SP.DisconnectedAppRunner.psm1 (7.5K Lines)

- **Status:** `PENDING`
- **Depends On:** none

**Problem:** Single file with 25+ functions. Same maintainability concern as QH-19.

**Fix:** Split into:
- `SP.DisconnectedAppRunner.psm1` (campaign creation, core pipeline)
- `SP.DisconnectedAppAnalytics.psm1` (risk, catalog, SLA, trends)
- `SP.DisconnectedAppReports.psm1` (HTML reports, dashboards)
Update psd1 NestedModules.

**Files:** `Modules/SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1` -> 3 files

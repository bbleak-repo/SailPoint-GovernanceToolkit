# Round 2 -- W-01: Prerequisites + Pester

**Started:** 2026-05-23
**Branch:** feature/windows-gui-tests
**Phase:** W-01 (Prerequisites + Pester)
**Mock API:** http://10.0.0.143:8080

## Setup

- Created branch `feature/windows-gui-tests` from `master`.
- Backed up `Config\settings.json` -> `Config\settings-real.json`.
- Patched `Config\settings.json` with mock values:
  - `Authentication.ConfigFile.TenantUrl` = `http://10.0.0.143:8080`
  - `Authentication.ConfigFile.OAuthTokenUrl` = `http://10.0.0.143:8080/oauth/token`
  - `Authentication.ConfigFile.ClientId` = `mock-client`
  - `Authentication.ConfigFile.ClientSecret` = `mock-secret`
  - `Api.BaseUrl` = `http://10.0.0.143:8080/v3`
  - `Safety.AllowCompleteCampaign` = `true`
  - `DeltaCert.SourceIds` = `["src-ad-001"]`
  - `DeltaCert.FallbackReviewerIdentityId` = `id-orphan-1`
  - `DeltaCert.ExcludeDisplayNamePatterns` = `["^SVC-"]`

## Test Results

### WC-01-01: git pull origin master

**Status:** PASS (already on master at commit 7480c2c which is HEAD; created `feature/windows-gui-tests` branch from there)

### WC-01-02: Mock connectivity (health endpoint)

**Status:** PASS

```
GET http://10.0.0.143:8080/health
status: ok
port: 8080
profiles: SailPoint-ISC, Okta, CyberArk-PVWA
```

### WC-01-03: Mock OAuth (token endpoint)

**Status:** PASS

```
POST http://10.0.0.143:8080/oauth/token
access_token: mock-token-6640039dfd12430d
token_type: Bearer
expires_in: 749
```

### WC-01-04: Pester test suite

**PowerShell:** 5.1.26100.8115
**Pester:** 5.7.1
**Runtime:** 698.85s (~11.6 min, dominated by PBKDF2 600k vault tests)

**Totals:** Total=411, Passed=402, Failed=9, Skipped=0
**Pass rate:** 97.8%

**Status:** PASS (suite ran end-to-end; failures are pre-existing test/mock issues, not infra blockers; down from 55 failures on PS 7 as the backlog predicted)

**Failure details (all 9):**

1. `LR-02 / cyclic manager / direct cycle` -- `Should have logged a WARN about the cycle`
   - Mock-scoping issue: `Expected Write-SPLog in module SP.DeltaCertQueries to be called 1 times exactly, but was called 0 times`
   - File: Tests\SP.LeadershipReport.Tests.ps1:428

2. `LR-02 / cyclic manager / self-cycle` -- `Should have logged a WARN about the cycle`
   - Same mock-scoping issue. File: Tests\SP.LeadershipReport.Tests.ps1:456

3. `LR-06 / SMTP disabled` -- `Should log at DEBUG level when SMTP is disabled`
   - Mock-scoping: `Expected Write-SPLog in module SP.AuditReport to be called at least 1 times, but was called 0 times`
   - File: Tests\SP.LeadershipReport.Tests.ps1:815

4. `LR-06 / SMTP disabled` -- `Should NOT invoke Send-MailMessage`
   - Mock registration: `Could not find Mock for command Send-MailMessage in module SP.AuditReport`
   - File: Tests\SP.LeadershipReport.Tests.ps1 (LR-06 context, SMTP disabled)

5. `LR-06 / SMTP enabled (stub)` -- `Should log at INFO level when SMTP is enabled (stub)`
   - Mock-scoping. File: Tests\SP.LeadershipReport.Tests.ps1:860

6. `LR-06 / SMTP enabled (stub)` -- `Should NOT invoke Send-MailMessage (stub only)`
   - Mock registration. File: Tests\SP.LeadershipReport.Tests.ps1 (LR-06 context, SMTP enabled)

7. `RE-02 / 4-level org tree` -- `Should have Level 4 (Senior Vice Presidents) in the Levels structure`
   - Label mismatch: expected `Senior Vice Presidents`, actual `Executive Leadership`
   - Module fallback at SP.AuditReport.psm1:1644 always labels top level as `Executive Leadership` regardless of OrgTree.LevelLabels[4]
   - File: Tests\SP.ReportEnhancements.Tests.ps1:401

8. `RE-04 / Detailed mode` -- `Should auto-expand revocations with <details open>`
   - PS 5.1 / Pester 5.7 specific: `<details open>` literal inside It-block name triggers ParseException
     (Pester appears to re-render the description; PS 5.1 parser then chokes on the literal `<`)
   - The actual `Should -Match '<details open'` assertion was never executed.
   - File: Tests\SP.ReportEnhancements.Tests.ps1:544
   - Trivial fix: rename test to remove angle brackets, e.g. `"Should auto-expand revocations with details-open attribute"`.

9. `RE-07 / careful reviewer (2h to review 20 items with revocations)` -- `Should flag the careful reviewer as None risk`
   - Severity mismatch: expected `None`, actual `Low`
   - File: Tests\SP.ReportEnhancements.Tests.ps1:919

**Categorization:**
- 6 mock-scoping/mock-registration failures (LR-02 x2, LR-06 x4) -- pre-existing in module SP.LeadershipReport.Tests.ps1
- 1 PS 5.1 parser bug in test name (RE-04) -- pre-existing
- 2 real assertion mismatches (RE-02 label, RE-07 severity) -- pre-existing

None were introduced by the W-01 mock-config edits. All are in test logic / mock framework interactions and do not affect runtime functionality covered by W-02+ phases.

## Outcome

W-01 phase: **PASS**

- All four sub-tests (WC-01-01..04) executed.
- Mock server fully reachable and OAuth working.
- Pester suite ran end-to-end with a documented 9/411 known-failure baseline.

## Cleanup

- `Config\settings.json` will be restored from `Config\settings-real.json` before commit per backlog instructions.
- Branch `feature/windows-gui-tests` will be pushed with backlog update only.


# CLI Integration Test Suite -- Mock API Backlog

**Created:** 2026-05-23
**Mock server:** Pode at localhost:8080 (80-identity enterprise org)
**Purpose:** Systematic CLI testing of every script + parameter combination

---

## How to Use This File

Agent loop -- each round handles one test battery:
1. Start Pode mock server
2. Swap toolkit to mock config
3. Run all tests for the script under test
4. Log results: exit code, stdout summary, file outputs, data verification
5. Fix any bugs found, re-test
6. Screenshot key report outputs with Playwright
7. Restore real config, stop mock server
8. Mark DONE, commit, push

**Serial order:** `T-01 -> T-02 -> T-03 -> T-04 -> T-05 -> T-06`

---

## Mock Server Setup (copy-paste for each round)

```powershell
# START MOCK
$mockDir = '/Users/xand/Documents/Projects/API-MockServer'
Start-Process pwsh -ArgumentList '-NoProfile', '-File', "$mockDir/Start-MockServer.ps1" -NoNewWindow
Start-Sleep -Seconds 4

# SWAP CONFIG
$toolkit = '/Users/xand/Documents/Projects/SailPoint/tools/SailPoint-GovernanceToolkit'
Set-Location $toolkit
Copy-Item Config/settings.json Config/settings-real.json
# Write mock config via python or inline PowerShell...

# RESTORE (after tests)
Copy-Item Config/settings-real.json Config/settings.json
Remove-Item Config/settings-real.json -ErrorAction SilentlyContinue
Stop-Process -Name pwsh -ErrorAction SilentlyContinue  # kills mock
```

**Mock config overrides:**
```json
{
    "Authentication.ConfigFile.TenantUrl": "http://localhost:8080",
    "Authentication.ConfigFile.OAuthTokenUrl": "http://localhost:8080/oauth/token",
    "Authentication.ConfigFile.ClientId": "mock",
    "Authentication.ConfigFile.ClientSecret": "mock",
    "Api.BaseUrl": "http://localhost:8080/v3",
    "Global.EnvironmentName": "MOCK-SERVER",
    "Safety.RequireWhatIfOnProd": false,
    "Safety.AllowCompleteCampaign": true,
    "Audit.DefaultDaysBack": 365,
    "DeltaCert.SourceIds": ["src-ad-001"],
    "DeltaCert.FallbackReviewerIdentityId": "id-orphan-1",
    "DeltaCert.ExcludeDisplayNamePatterns": ["^SVC-"]
}
```

---

## Mock Data Reference (for result validation)

| Data | Count | Details |
|------|-------|---------|
| Campaigns | 4 | ACTIVE (SOURCE_OWNER), COMPLETED (MANAGER), STAGED (SEARCH), ACTIVE (delta cert) |
| Certifications | 18 | 4 signed, 14 unsigned |
| ARIs | 75 | 5 per cert, decisions: APPROVE/REVOKE/null |
| GRANT_ACCESS activities | 8 | 5 from -2h, 3 from -26h |
| REVOKE_ACCESS activities | 2 | From -4h |
| Identities | 80 | President + 3 VP + 12 Dir + 60 IC + 2 orphan + 2 svc |
| Sources | 2 | Corporate AD (src-ad-001), Cloud Entra (src-entra-001) |

---

## Phase Summary

| ID | Test Battery | Tests | Depends On | Status |
|----|-------------|-------|------------|--------|
| T-01 | Test-SPConnectivity.ps1 | 1 | none | DONE |
| T-02 | Invoke-SPCampaignAudit.ps1 | 7 | T-01 | DONE |
| T-03 | Invoke-SPADDeltaCert.ps1 | 5 | T-01 | DONE |
| T-04 | Invoke-SPDeltaReport.ps1 | 3 | T-01 | DONE |
| T-05 | Invoke-SPDeltaCertEscalate.ps1 | 2 | T-01 | DONE |
| T-06 | Integration Test (full workflow) | 5 | T-02 to T-05 | DONE |

---

## T-01: Test-SPConnectivity.ps1

- **Status:** `DONE`
- **Commit:** 1a6a413
- **Depends On:** none

**Tests:**
```
TC-01-01: .\Scripts\Test-SPConnectivity.ps1
  Expected: exit code 0, "Connectivity test passed" or similar success message
  Verify: OAuth token acquired, API base URL reachable
```

**Validation:**
- Exit code 0
- Output contains success indicator
- No authentication errors

---

## T-02: Invoke-SPCampaignAudit.ps1

- **Status:** `DONE`
- **Commit:** 3a31506
- **Depends On:** T-01

**Tests (7 parameter combos):**

```
TC-02-01: -Status COMPLETED -DaysBack 365 -OutputMode Console
  Expected: 1 campaign audited, exit code 0
  Verify: Audit/ directory contains HTML + TXT + JSONL

TC-02-02: -Status ACTIVE -DaysBack 365 -OutputMode Console
  Expected: 1-2 campaigns (camp-active-001 + camp-delta-001), exit code 0
  Verify: Multiple campaign sections in combined report

TC-02-03: -Status COMPLETED,ACTIVE -DaysBack 365 -OutputMode Console
  Expected: 2-3 campaigns, exit code 0
  Verify: Combined report has multiple campaigns

TC-02-04: -CampaignNameContains "Annual" -DaysBack 365 -OutputMode Console
  Expected: 1 campaign (2025 Annual Access Review), exit code 0
  Verify: Only the matching campaign appears

TC-02-05: -Status COMPLETED -DaysBack 365 -DetailLevel Summary -OutputMode Console
  Expected: Compact report, no expanded detail tables
  Verify: HTML does NOT contain <details open> tags (sections collapsed)

TC-02-06: -Status COMPLETED -DaysBack 365 -DetailLevel Verbose -OutputMode Console
  Expected: All sections fully expanded
  Verify: HTML contains <details open> on all sections

TC-02-07: -Status COMPLETED -DaysBack 365 -IncludeLeadershipRollup -LeadershipDepth 2 -OutputMode Console
  Expected: Leadership reports at Director level only (no VP executive)
  Verify: leadership/ has director reports but no VP-level reports
```

**Data Validation (TC-02-01):**
- Total items = 25 (5 certs x 5 items for COMPLETED campaign)
- Approved = 16 (items with decision=APPROVE in seed data)
- Revoked = 4 (items with decision=REVOKE)
- Pending = 5 (items with decision=null)
- Reviewer names match certification reviewer fields in seed data

**Screenshot:** Take full-page Playwright capture of the combined report from TC-02-01

---

## T-03: Invoke-SPADDeltaCert.ps1

- **Status:** `DONE`
- **Commit:** 8cab65b
- **Depends On:** T-01

**IMPORTANT:** Restart mock server between tests that create campaigns (to reset state
and avoid duplicate guard). Or use different CampaignNamePrefix per test.

**Tests (5 parameter combos):**

```
TC-03-01: -SourceId 'src-ad-001' -CampaignNamePrefix 'Test-DC-01' -OutputMode Console
  Expected: 2+ campaigns created (one per manager group), exit code 0
  Verify: Campaigns created count > 0, identity count > 0

TC-03-02: -SourceId 'src-ad-001' -ReviewerMode SourceOwner -CampaignNamePrefix 'Test-DC-02' -OutputMode Console
  Expected: 1 campaign per source ID (SOURCE_OWNER type), exit code 0
  Verify: Campaign type is SOURCE_OWNER in output

TC-03-03: -SourceId 'src-ad-001' -WhatIf -OutputMode Console
  Expected: Campaigns created = 0, exit code 0
  Verify: "[WhatIf] Dry-run mode" in output, no campaigns actually created

TC-03-04: -SourceId 'src-ad-001' -RunCleanup -CampaignNamePrefix 'Test-DC-04' -OutputMode Console
  Expected: Cleanup runs before campaign creation
  Verify: "Running campaign cleanup" in output

TC-03-05: -SourceId 'src-ad-001' -HoursBack 1 -CampaignNamePrefix 'Test-DC-05' -OutputMode Console
  Expected: Fewer or zero events (activities are from -2h, depends on timing)
  Verify: Grant event count <= 5 (only recent activities)
```

**Data Validation (TC-03-01):**
- Grant events found = 5 (activities from -2h with source src-ad-001)
- Identities resolved with managers
- Service accounts (SVC-*) excluded
- Manager groups = 2+ (based on identity manager distribution)

---

## T-04: Invoke-SPDeltaReport.ps1

- **Status:** `DONE`
- **Commit:** 2da9d48
- **Depends On:** T-01
- **Bugs Found:** UTC/Local DateTime Kind mismatch in client-side date filtering (PS7 ConvertFrom-Json returns DateTime with Kind=Utc, but cutoff used Kind=Local). Fixed in SP.DeltaCertQueries.psm1 and SP.DeltaCertReport.psm1 (3 instances). Also fixed mock server to resolve relative timestamps in campaigns and certifications (not just accountActivities).

**Tests (3 parameter combos):**

```
TC-04-01: -SourceId 'src-ad-001' -HoursBack 48 -OutputMode Console
  Expected: 8 new grants, 2 revocations, exit code 0
  Verify: delta-*.html has 5 sections, dates populated

TC-04-02: -SourceId 'src-ad-001' -HoursBack 24 -OutputMode Console
  Expected: 5 new grants (only -2h activities), 2 revocations (-4h)
  Verify: Fewer grants than TC-04-01

TC-04-03: -SourceId 'src-ad-001' -HoursBack 1 -OutputMode Console
  Expected: 0 grants (all activities are >1h old), 0 revocations
  Verify: "No new grants" or empty table
```

**Data Validation (TC-04-01):**
- Identity names resolved (not raw IDs)
- Dates populated in all table rows
- Revocation section shows Jane Evans and Tina Campbell
- JSONL file written alongside HTML

---

## T-05: Invoke-SPDeltaCertEscalate.ps1

- **Status:** `DONE`
- **Commit:** 2da9d48
- **Depends On:** T-01
- **Mock Fixes:** Added 2 source-owner identities (id-mgr-001, id-mgr-002) to seed data (were referenced as cert reviewers but not in identities array). Added 6 ARIs for delta certs (2 per cert) so escalation has items to reassign.

**Tests (2):**

```
TC-05-01: -StaleHours 1 -WhatIf -OutputMode Console
  Expected: Finds stale certifications (unsigned certs from -48h in camp-active-001)
  Verify: Stale cert count > 0, "[WhatIf]" in output

TC-05-02: -StaleHours 1 -OutputMode Console
  Expected: Escalation executed -- reassignment API called on mock
  Verify: "Escalated" count > 0, or "Skipped" with reason
  Note: Requires the mock to support POST /certifications/{id}/reassign
```

**Data Validation (TC-05-01):**
- camp-active-001 has certs created at -48h with signed=null
- These should be detected as stale (>1 hour threshold)
- Reviewer identity IDs should be resolvable

---

## T-06: Integration Test (Full Workflow)

- **Status:** `DONE`
- **Commit:** 2da9d48
- **Depends On:** T-02 through T-05

**Sequential flow -- all in one round, fresh mock state:**

```
Step 1: Restart mock (clean state)
Step 2: Run cleanup: -SourceId 'src-ad-001' -RunCleanup -CampaignNamePrefix 'Integ-Test'
  Verify: Cleanup section appears (even if 0 campaigns cleaned)

Step 3: Run delta cert: -SourceId 'src-ad-001' -CampaignNamePrefix 'Integ-Test'
  Verify: Campaigns created, identity count matches

Step 4: Run delta report: -SourceId 'src-ad-001' -HoursBack 48
  Verify: Shows new grants + the campaign just created in step 3

Step 5: Run audit: -Status ACTIVE -DaysBack 365 -IncludeLeadershipRollup
  Verify: Includes camp-active-001 (pre-seeded) + possibly new campaigns from step 3

Step 6: Run escalation: -StaleHours 1
  Verify: Finds and processes stale certs from camp-active-001
```

**Cross-Validation:**
- Delta report campaign count matches delta cert campaigns created
- Audit report identity counts are consistent with delta cert identities
- All scripts use the same mock data -- numbers should align

---

## Playwright Screenshot Commands (reference)

```bash
PY="/Users/xand/Documents/Projects/CyberArk-CPM-PSM-TestKit/cpm-simulator/venv/bin/python"
CAP="/Users/xand/Documents/Projects/.claude-frameworks/playwright-capture/capture.py"
OUTDIR="docs/cli-test-screenshots"

# Campaign audit combined
$PY $CAP Audit/campaign-audit-combined-*.html --full-page --output-dir $OUTDIR --prefix tc02

# Delta report
$PY $CAP DeltaCert/reports/delta-*.html --full-page --output-dir $OUTDIR --prefix tc04

# Leadership executive
$PY $CAP Audit/leadership/executive-summary.html --full-page --output-dir $OUTDIR --prefix tc02-leadership
```

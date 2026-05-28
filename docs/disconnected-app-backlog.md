# Disconnected App Onboarding Kit -- Feature Backlog

**Created:** 2026-05-28
**Purpose:** Standardized flat file workflow for applications that cannot connect to ISC directly

---

## How to Use This File

Agent loop: `D-01 -> D-02 -> D-03 -> D-04 -> D-05 -> D-06 -> D-07 -> D-08 -> D-09 -> D-10`

---

## Overview

Applications that lack a native SailPoint connector provide daily CSV files (accounts +
entitlements). This kit:
1. **Validates** files against a standardized schema
2. **Detects deltas** by comparing today's file against yesterday's snapshot
3. **Resolves** file accounts to ISC identities (via email/username correlation)
4. **Creates targeted campaigns** for ONLY the changed accounts (not the whole source)
5. **Reports** what changed in a human-readable HTML summary

**File delivery:** App teams drop CSVs into a local shared directory per application.
The toolkit reads from there, stores snapshots for delta comparison.

**Directory structure:**
```
DisconnectedApps/
  Imports/
    {AppName}/
      accounts.csv          (today's full export from app team)
      entitlements.csv      (today's full export)
  Snapshots/
    {AppName}/
      {YYYY-MM-DD}-accounts.csv     (date-stamped copies)
      {YYYY-MM-DD}-entitlements.csv
  Reports/
    {AppName}/
      delta-{YYYY-MM-DD}.html       (what changed today)
```

---

## CSV Template Schema (Reference)

**Account file columns:**
| Column | Required | Description |
|--------|----------|-------------|
| `id` | Yes | Unique account ID within this app (max 128 chars) |
| `name` | Yes | Username/login |
| `givenName` | Yes | First name |
| `familyName` | Yes | Last name |
| `e-mail` | Yes | Email (primary correlation attribute to ISC identity) |
| `department` | Recommended | Department name |
| `groups` | Yes | Comma-separated entitlement IDs (multi-valued, quoted) |
| `IIQDisabled` | Yes | `true` = disabled/inactive, `false` = active |

**Entitlement file columns:**
| Column | Required | Description |
|--------|----------|-------------|
| `id` | Yes | Unique entitlement ID (must match values in accounts `groups` column) |
| `name` | Yes | Technical name |
| `displayName` | Yes | Human-readable name shown during certifications |
| `description` | Yes | Description shown to reviewers (max 2000 chars) |

**Rules:** UTF-8 encoding, file sorted by `id`, multi-values in double quotes, ISO 8601 dates.

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| D-01 | CSV Templates + Onboarding Guide | none | DONE |
| D-02 | CSV Validator | D-01 | DONE |
| D-03 | File Snapshot Manager | none | DONE |
| D-04 | Delta Detection Engine | D-03 | PENDING |
| D-05 | Identity Resolver (file accounts to ISC) | none | PENDING |
| D-06 | Delta Campaign Creator | D-04, D-05 | PENDING |
| D-07 | Delta Summary Report (HTML) | D-04 | PENDING |
| D-08 | CLI Script | D-06, D-07 | PENDING |
| D-09 | Config Section + Mock Test Data | D-02 | PENDING |
| D-10 | Pester Tests | D-08 | PENDING |

---

## D-01: CSV Templates + Onboarding Guide

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
Create template CSV files and a one-page onboarding guide that application teams receive
when they need to integrate a disconnected app with SailPoint ISC.

**Files to Create:**
- `Config/Templates/disconnected-app-accounts.csv` -- template with example rows
- `Config/Templates/disconnected-app-entitlements.csv` -- template with example rows
- `Config/Templates/ONBOARDING-GUIDE.md` -- instructions for app teams

**Onboarding guide content:**
1. What these files are and why they're needed
2. Column definitions with examples for each
3. File naming convention: `accounts.csv` and `entitlements.csv`
4. Encoding requirements (UTF-8)
5. Multi-value format (comma-separated within double quotes)
6. Sorting requirement (accounts file sorted by `id`)
7. Status mapping (active=`false`, disabled=`true` for IIQDisabled)
8. Drop location (placeholder: `\\fileserver\sailpoint-imports\{AppName}\`)
9. Daily deadline (placeholder: "Files must be refreshed by 04:00 UTC daily")
10. Common mistakes to avoid (encoding, date formats, empty rows)

**Template account CSV (5 example rows):**
```csv
id,name,givenName,familyName,e-mail,department,groups,IIQDisabled
EMP10001,jsmith,John,Smith,john.smith@corp.com,Treasury,"APP-ADMIN,APP-REPORTS",false
EMP10002,jdoe,Jane,Doe,jane.doe@corp.com,Operations,APP-READONLY,false
EMP10003,mjones,Mike,Jones,mike.jones@corp.com,Finance,"APP-ADMIN,APP-POWERUSER",false
EMP10004,alee,Alice,Lee,alice.lee@corp.com,IT,APP-READONLY,false
EMP10005,tresigned,Tom,Resigned,tom.resigned@corp.com,Treasury,,true
```

**Acceptance Criteria:**
- Templates are valid CSV parseable by `Import-Csv`
- Onboarding guide is clear enough for a non-technical app team to follow
- Example rows cover: multi-value groups, disabled account, empty groups

---

## D-02: CSV Validator (SP.DisconnectedAppValidator.psm1)

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** D-01

**Description:**
New module file with validation functions that check CSV files against the template schema
before processing.

**Files to Create:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppValidator.psm1`

**Functions:**

`Test-SPDisconnectedAppAccountFile`:
- Input: `-FilePath` (path to accounts CSV)
- Checks: file exists, UTF-8 encoding, required columns present, no empty `id` values,
  no duplicate `id` values, `IIQDisabled` is `true` or `false`, `e-mail` contains `@`,
  file is sorted by `id` column (if multi-row per account is used)
- Returns: `@{Success; Data=@{RowCount; ValidRows; InvalidRows; Errors=@(); Warnings=@()}; Error}`

`Test-SPDisconnectedAppEntitlementFile`:
- Input: `-FilePath` (path to entitlements CSV)
- Checks: file exists, required columns (id, name, displayName, description), no duplicates,
  description length <= 2000 chars, no emoji or `+` in names
- Returns: same structure

`Test-SPDisconnectedAppCrossReference`:
- Input: `-AccountFilePath`, `-EntitlementFilePath`
- Checks: every value in accounts `groups` column exists in entitlements `id` column
- Flags: orphaned entitlements (in entitlement file but not referenced by any account)
- Returns: `@{Success; Data=@{UnmatchedGroups=@(); OrphanedEntitlements=@()}; Error}`

**Acceptance Criteria:**
- Detects missing required columns
- Detects duplicate account IDs
- Detects invalid email format
- Detects entitlement references that don't exist in entitlement file
- Returns structured error/warning arrays (not just pass/fail)

---

## D-03: File Snapshot Manager

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
Functions to store date-stamped copies of imported files and retrieve the most recent
previous snapshot for delta comparison.

**Add to SP.DisconnectedAppValidator.psm1 or new file.**

**Functions:**

`Save-SPDisconnectedAppSnapshot`:
- Input: `-FilePath` (today's file), `-AppName`, `-FileType` (accounts|entitlements),
  `-SnapshotDir` (default from config)
- Copies file to `{SnapshotDir}/{AppName}/{YYYY-MM-DD}-{FileType}.csv`
- Returns: path to the saved snapshot

`Get-SPDisconnectedAppPreviousSnapshot`:
- Input: `-AppName`, `-FileType`, `-SnapshotDir`
- Finds the most recent snapshot BEFORE today
- Returns: path to previous snapshot, or `$null` if no previous exists (first run)

`Remove-SPDisconnectedAppOldSnapshots`:
- Input: `-AppName`, `-SnapshotDir`, `-RetentionDays` (default 30)
- Deletes snapshots older than retention period

**Acceptance Criteria:**
- Snapshot saved with correct date-stamped filename
- Previous snapshot correctly identified (not today's)
- First run (no previous snapshot) returns null gracefully
- Retention cleanup deletes old files but keeps recent ones

---

## D-04: Delta Detection Engine

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** D-03

**Description:**
Core delta engine that compares today's account file against yesterday's snapshot and
identifies all changes at the account AND entitlement level.

**File to Create or Add to:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppDelta.psm1`

**Function:** `Compare-SPDisconnectedAppFiles`
- Input: `-CurrentFilePath`, `-PreviousFilePath`, `-IdColumn` (default 'id'),
  `-GroupsColumn` (default 'groups')
- Parses both files with `Import-Csv`
- Builds hashtable keyed by `id` for O(1) lookup
- Detects:

| Change Type | Detection Logic |
|-------------|----------------|
| **AccountAdded** | ID in current, not in previous |
| **AccountRemoved** | ID in previous, not in current |
| **AccountDisabled** | IIQDisabled changed from `false` to `true` |
| **AccountEnabled** | IIQDisabled changed from `true` to `false` |
| **EntitlementGranted** | Groups in current that aren't in previous for same ID |
| **EntitlementRevoked** | Groups in previous that aren't in current for same ID |
| **AttributeChanged** | Any other column changed (name, email, department) |

- Returns:
```powershell
@{
    Success = $true
    Data = @{
        Added     = @(@{Account=$row; NewGroups=@(...)})
        Removed   = @(@{Account=$row})
        Disabled  = @(@{Account=$row})
        Enabled   = @(@{Account=$row})
        GrantedEntitlements = @(@{AccountId='EMP10001'; AccountEmail='...'; Entitlements=@('APP-NEW-ROLE')})
        RevokedEntitlements = @(@{AccountId='EMP10002'; AccountEmail='...'; Entitlements=@('APP-OLD-ROLE')})
        AttributeChanges    = @(@{AccountId='EMP10003'; Field='department'; OldValue='IT'; NewValue='Finance'})
        Unchanged = [int] count
        Summary = @{
            TotalCurrent=500; TotalPrevious=498
            Added=3; Removed=1; Disabled=0; Enabled=0
            EntitlementsGranted=5; EntitlementsRevoked=2
            AttributeChanges=1; Unchanged=494
        }
    }
    Error = $null
}
```

**Acceptance Criteria:**
- Correctly identifies added/removed accounts
- Correctly identifies new vs removed entitlements for existing accounts
- Handles multi-valued groups (comma-separated within quotes)
- First run (no previous file) treats all accounts as "Added"
- Empty files handled gracefully (all accounts removed = threshold warning)

---

## D-05: Identity Resolver (File Accounts to ISC Identities)

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** none

**Description:**
Resolves file account records to ISC identity IDs using email (primary) or username
(fallback) correlation. Reuses `Get-SPDeltaIdentityDetail` for manager resolution.

**File to Add to:** `SP.DisconnectedAppRunner.psm1` (new)

**Function:** `Resolve-SPDisconnectedAppIdentities`
- Input: array of delta records (from D-04), `-CorrelationAttribute` (default 'e-mail'),
  `-CorrelationID`
- For each delta account:
  1. Search ISC: `POST /v3/search` with `{"indices":["identities"],"query":{"query":"email:\"user@corp.com\""}}`
     OR use `GET /v3/search/identities/{id}` if identity ID is known
  2. If found: resolve manager via `Get-SPDeltaIdentityDetail`
  3. If not found: log warning, add to "unresolved" list
- Returns: resolved identities with ISC IDs + manager info

**ISC Search API for correlation:**
```
POST /v3/search
{
    "indices": ["identities"],
    "query": { "query": "attributes.email:\"john.smith@corp.com\"" },
    "limit": 1
}
```
Requires scope: `sp:search:read`

**Acceptance Criteria:**
- Resolves by email (primary) and username (fallback)
- Returns ISC identity ID + manager ID + display name
- Unresolved accounts tracked separately (not lost)
- Caches resolved identities for the session (reuse IdentityCache)

---

## D-06: Delta Campaign Creator

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** D-04, D-05

**Description:**
Takes resolved delta identities and creates targeted SEARCH campaigns per manager group.
Reuses the existing `New-SPCampaign` / `Start-SPCampaign` / `Build-SPDeltaSearchFilter`
infrastructure from SP.DeltaCert.

**Add to:** `SP.DisconnectedAppRunner.psm1`

**Function:** `Invoke-SPDisconnectedAppCertRun`
- Input: `-AppName`, `-DeltaResult` (from D-04), `-ResolvedIdentities` (from D-05),
  `-CampaignNamePrefix`, `-DeadlineDays`, `-FallbackManagerId`, `-MaxCampaignsPerRun`
- Groups resolved identities by manager (reuse `Group-SPDeltaByManager`)
- For each manager group: create SEARCH campaign with identity filter
- Campaign name: `"{AppName} Delta Cert {YYYY-MM-DD} - {ManagerName}"`
- Supports `-WhatIf`
- Returns: same structure as `Invoke-SPDeltaCertRun`

**What triggers a campaign:**
- AccountAdded (new user needs review)
- EntitlementGranted (existing user gets new access)
- AccountEnabled (previously disabled account reactivated)

**What does NOT trigger a campaign:**
- AccountRemoved (leaver -- handled by ISC lifecycle, not certification)
- EntitlementRevoked (already removed, no review needed)
- AccountDisabled (access removed, no review needed)
- AttributeChanged (metadata change, no access change)

**Acceptance Criteria:**
- Only creates campaigns for adds and grants (not removes/revokes)
- Correctly groups by manager
- WhatIf describes what would be created without writing
- Campaign name includes app name and date
- Duplicate guard (don't create if today's campaign already exists)

---

## D-07: Delta Summary Report (HTML)

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** D-04

**Description:**
HTML report showing what changed between yesterday's and today's file. Useful for
app team validation and audit evidence.

**Add to:** `SP.DisconnectedAppRunner.psm1` or new report file

**Function:** `Export-SPDisconnectedAppDeltaHtml`
- Input: delta result (from D-04), `-AppName`, `-OutputPath`
- Generates HTML with sections:
  1. Summary: total current, total previous, adds, removes, grants, revokes
  2. Added Accounts table (name, email, department, groups)
  3. Removed Accounts table
  4. Entitlement Changes table (account, granted/revoked entitlements)
  5. Disabled/Enabled Accounts
  6. Footer with generation timestamp
- Uses existing HTML styling patterns (inline CSS, Word-compatible)

**Acceptance Criteria:**
- Report is self-contained HTML (no external CSS)
- Tables are color-coded (green=added, red=removed, orange=changed)
- Report saved to `{OutputPath}/{AppName}/delta-{YYYY-MM-DD}.html`

---

## D-08: CLI Script (Invoke-SPDisconnectedAppCert.ps1)

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** D-06, D-07

**Description:**
Entry point CLI script that orchestrates the full workflow:
validate -> snapshot -> delta -> resolve -> campaign -> report

**File to Create:** `Scripts/Invoke-SPDisconnectedAppCert.ps1`

**Parameters:**
```powershell
-AppName "PEP-Plus"               # Application name (used for directory + campaign naming)
-AccountFilePath "path/to/accounts.csv"
-EntitlementFilePath "path/to/entitlements.csv"  # Optional
-CampaignNamePrefix "Disconnected App Cert"
-DeadlineDays 2
-FallbackReviewerIdentityId "id-xxx"
-SnapshotDir ".\DisconnectedApps\Snapshots"
-OutputPath ".\DisconnectedApps\Reports"
-ConfigPath, -Token, -TokenExpiryMinutes
-WhatIf, -OutputMode (Console|JSON|Both), -Help
```

**Workflow:**
```
1. Validate account CSV (and entitlement CSV if provided)
2. Save today's snapshot
3. Find previous snapshot (yesterday or most recent)
4. Compare files (delta detection)
5. If no changes: exit 1 (no campaign needed)
6. Resolve changed accounts to ISC identities
7. Create campaigns for adds + grants
8. Generate delta summary HTML report
9. Log to JSONL audit trail
10. Output summary
```

**Exit Codes:** 0=campaigns created, 1=no changes, 2=param error, 3=auth error,
4=config error, 5=validation failure, 6=campaign creation error

**Acceptance Criteria:**
- Full end-to-end workflow from CSV to campaign creation
- Validation errors block further processing (exit 5)
- No changes = clean exit with informational message
- WhatIf describes entire workflow without writing

---

## D-09: Config Section + Mock Test Data

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** D-02

**Description:**
Add `DisconnectedApps` config section to settings.json and create mock test CSV files
for Pester testing.

**Files to Modify:**
- `Config/settings.json` -- add section:
```json
"DisconnectedApps": {
    "ImportBasePath": ".\\DisconnectedApps\\Imports",
    "SnapshotPath": ".\\DisconnectedApps\\Snapshots",
    "ReportPath": ".\\DisconnectedApps\\Reports",
    "SnapshotRetentionDays": 30,
    "DefaultCampaignNamePrefix": "Disconnected App Cert",
    "DefaultDeadlineDays": 2,
    "CorrelationAttribute": "e-mail",
    "AccountDeletionThresholdPct": 20,
    "RequiredAccountColumns": ["id", "name", "givenName", "familyName", "e-mail", "groups", "IIQDisabled"],
    "RequiredEntitlementColumns": ["id", "name", "displayName", "description"]
}
```
- `Modules/SP.Core/SP.Config.psm1` -- add defaults

**Mock test data to create:**
- `Tests/TestData/disconnected-day1-accounts.csv` (5 accounts, 8 entitlement assignments)
- `Tests/TestData/disconnected-day2-accounts.csv` (6 accounts -- 1 added, 1 removed, 1 new entitlement)
- `Tests/TestData/disconnected-entitlements.csv` (4 entitlements)
- `Tests/TestData/disconnected-invalid-accounts.csv` (missing columns, bad data for validation testing)

**Acceptance Criteria:**
- Config section recognized by Get-SPConfig without warnings
- Day1 -> Day2 comparison produces: 1 added, 1 removed, 1 entitlement granted
- Invalid file triggers validation errors

---

## D-10: Pester Tests

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** D-08

**Description:**
Pester tests for all new functions.

**File to Create:** `Tests/SP.DisconnectedApps.Tests.ps1`
**Modify:** `Tests/Import-TestModules.ps1` -- add `-DisconnectedApps` switch

**Test IDs:**
- DA-01: Test-SPDisconnectedAppAccountFile detects missing required columns
- DA-02: Test-SPDisconnectedAppAccountFile detects duplicate IDs
- DA-03: Test-SPDisconnectedAppCrossReference finds unmatched groups
- DA-04: Save-SPDisconnectedAppSnapshot creates date-stamped file
- DA-05: Get-SPDisconnectedAppPreviousSnapshot returns correct file
- DA-06: Compare-SPDisconnectedAppFiles detects added accounts
- DA-07: Compare-SPDisconnectedAppFiles detects entitlement grants
- DA-08: Compare-SPDisconnectedAppFiles handles first run (no previous)
- DA-09: Resolve-SPDisconnectedAppIdentities maps email to ISC identity (mocked)
- DA-10: Export-SPDisconnectedAppDeltaHtml generates valid HTML
- DA-11: Invoke-SPDisconnectedAppCert.ps1 syntax validation

---

## Reusable Functions from Existing Toolkit

| Function | Source Module | Used By |
|----------|-------------|---------|
| `New-SPCampaign` | SP.Campaigns | D-06 |
| `Start-SPCampaign` | SP.Campaigns | D-06 |
| `Build-SPDeltaSearchFilter` | SP.DeltaCertRunner | D-06 |
| `Group-SPDeltaByManager` | SP.DeltaCertQueries | D-06 |
| `Get-SPDeltaIdentityDetail` | SP.DeltaCertQueries | D-05 |
| `Get-SPDeltaAffectedIdentities` | SP.DeltaCertQueries | D-05 (pattern) |
| `Write-SPLog` | SP.Logging | All |
| `Get-SPConfig` | SP.Config | All |
| `ConvertTo-SafeHtml` | SP.AuditReport | D-07 |
| `Build-HtmlTableRow` | SP.AuditReport | D-07 |

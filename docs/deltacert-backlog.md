# SP.DeltaCert Feature Backlog

**Created:** 2026-05-21
**Phase 1 Status:** COMPLETE (committed to master, pushed to origin)

---

## How to Use This File

This backlog is designed for a **loop workflow**:

1. Find the next feature with status `PENDING` (in phase order)
2. Check its **Depends On** field -- all dependencies must be `DONE`
3. Implement using the description, files, and acceptance criteria
4. Run the listed tests
5. Update status from `PENDING` to `DONE` and add the commit hash
6. Commit the feature + this file in one commit
7. Loop back to step 1

**Convention:** Each feature is one commit. Features within a phase can be done in order.
Cross-phase dependencies are noted explicitly.

---

## Phase Summary

| Phase | Scope | Features | Status |
|-------|-------|----------|--------|
| 1 | Core delta detection + manager campaigns | (complete) | DONE |
| 2 | Campaign lifecycle (deadline, dedup, cleanup, audit trail) | F-01 to F-04 | PENDING |
| 3 | Reviewer routing (SOURCE_OWNER / app owner mode) | F-05 | DONE |
| 4 | OOO escalation (stale detection, org tree walk, reassignment) | F-06 to F-08 | DONE |
| 5 | GUI tab integration (XAML, bridge, wiring) | F-09 | PENDING |
| 6 | Hardening (identity exclusion filters) | F-10 | PENDING |

---

## ISC API Constraints (Reference)

These constraints affect multiple features and should be kept in mind during implementation:

- `POST /v3/campaigns` accepts a `deadline` field (ISO 8601 string) -- used by F-01
- `POST /campaigns/{id}/complete` only works on **past-due** campaigns -- guarded by `Safety.AllowCompleteCampaign` -- used by F-03
- `POST /certifications/{id}/reassign` max **50 items** sync; `/reassign-async` max **500** -- used by F-07
- Work Reassignment does **NOT** apply to Governance Group certifications (ISC documented exception)
- ISC sends its own notification emails when certifications are reassigned -- no custom email needed for escalation
- No native ISC auto-escalation after timeout -- must be built as external poll + reassign
- `SOURCE_OWNER` campaign type is already supported in `Build-SPCampaignBody` -- used by F-05
- `GET /v3/account-activities` (without `requested-for`) requires `sp:scopes:all` -- unchanged from Phase 1

---

## Existing Functions to Reuse

Do not duplicate logic that already exists in the toolkit:

| Function | Module | Used By |
|----------|--------|---------|
| `Search-SPCampaigns` | SP.Campaigns.psm1 | F-02, F-03, F-06 |
| `Complete-SPCampaign` | SP.Campaigns.psm1 | F-03 |
| `New-SPCampaign` / `Build-SPCampaignBody` | SP.Campaigns.psm1 | F-01, F-05 |
| `Start-SPCampaign` | SP.Campaigns.psm1 | F-05 |
| `Get-SPAuditCertifications` | SP.AuditQueries.psm1 | F-06 |
| `Invoke-SPReassign` | SP.Decisions.psm1 | F-07 |
| `Invoke-SPReassignAsync` | SP.Decisions.psm1 | F-07 (if >50 items) |
| `Get-SPDeltaIdentityDetail` | SP.DeltaCertQueries.psm1 | F-07 |
| `Get-SPDeltaGrantEvents` | SP.DeltaCertQueries.psm1 | (Phase 1, no change) |
| `Get-SPDeltaAffectedIdentities` | SP.DeltaCertQueries.psm1 | F-10 |
| GUI bridge pattern | SP.GuiBridge.psm1 | F-09 |

---

## Phase 2: Campaign Lifecycle

### F-01: Campaign Deadline Support

- **Status:** `DONE`
- **Commit:** 5b602d4
- **Depends On:** none

**Description:**
Add a `-Deadline` parameter (ISO 8601 string) to `Build-SPCampaignBody` and `New-SPCampaign`
in SP.Campaigns.psm1. Then wire `DeadlineDays` through `Invoke-SPDeltaCertRun` so that
campaigns are created with an ISC-enforced deadline calculated as `(Get-Date).AddDays($DeadlineDays)`.

Currently `DeadlineDays` exists as a parameter but the deadline is never passed to the ISC API.
ISC uses its tenant default, which may not match the intended delta cert review window.

**Files to Modify:**
- `Modules/SP.Api/SP.Campaigns.psm1` -- add `[string]$Deadline` param to `Build-SPCampaignBody` and `New-SPCampaign`; add `$body['deadline'] = $Deadline` in body builder
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1` -- compute deadline string from `$DeadlineDays`, pass `-Deadline` to `New-SPCampaign`

**Acceptance Criteria:**
- `New-SPCampaign -Name 'Test' -Type SEARCH -SearchFilter 'id:"x"' -CertifierIdentityId 'y' -Deadline '2026-06-01T23:59:59Z'` includes `deadline` in the POST body
- `Invoke-SPDeltaCertRun -SourceIds @('src-1') -DeadlineDays 2` creates campaigns with deadline = now + 2 days
- Existing callers of `New-SPCampaign` that omit `-Deadline` are unaffected (no deadline in body)

**Tests:**
- DC-015: Verify `New-SPCampaign` includes deadline in API body when `-Deadline` is provided
- DC-016: Verify `New-SPCampaign` omits deadline from body when `-Deadline` is not provided

---

### F-02: Duplicate Campaign Guard

- **Status:** `DONE`
- **Commit:** 2205e7c
- **Depends On:** none

**Description:**
Before creating campaigns in `Invoke-SPDeltaCertRun`, check if a campaign with today's
name prefix already exists (e.g., `"AD Delta Cert 2026-05-21"`). If duplicates are found,
skip creation and return `Reason='DuplicatesExist'`. This prevents double-runs from creating
duplicate campaigns when the script is accidentally run twice in one day.

Uses `Search-SPCampaigns -Keyword "$CampaignNamePrefix $dateStamp"` (already exists in
SP.Campaigns.psm1) to find matches.

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1` -- add duplicate check in `Invoke-SPDeltaCertRun` between Step 3 (grouping) and Step 4 (creation). New step: search for active campaigns matching today's name prefix. If found, log warning and return early.

**Acceptance Criteria:**
- Running `Invoke-SPDeltaCertRun` twice on the same day with the same prefix: second run returns `Reason='DuplicatesExist'` and creates zero campaigns
- First run of the day proceeds normally
- `-Force` switch (new param) bypasses the duplicate check

**Tests:**
- DC-017: Mock `Search-SPCampaigns` returning a match -- verify `Reason='DuplicatesExist'`
- DC-018: Mock `Search-SPCampaigns` returning empty -- verify campaigns are created normally

---

### F-03: Campaign Cleanup (Auto-Complete Stale Campaigns)

- **Status:** `DONE`
- **Commit:** 47d0db4
- **Depends On:** F-01 (deadline must exist for meaningful staleness check)

**Description:**
New function `Invoke-SPDeltaCertCleanup` that finds past-due delta cert campaigns and
completes them. Intended to run daily before creating new campaigns, preventing campaign
pile-up from managers who never action their reviews.

Flow:
1. `Search-SPCampaigns -Keyword $CampaignNamePrefix -Status @('ACTIVE')` -- find active delta certs
2. For each campaign, check if `deadline` has passed (or if `created` is older than `CleanupDaysStale`)
3. Call `Complete-SPCampaign -CampaignId $id` on past-due campaigns
4. Return summary: campaigns completed, campaigns still active, errors

Add `-RunCleanup` switch to `Invoke-SPADDeltaCert.ps1`. When set, runs cleanup before
creating new campaigns. Add `DeltaCert.CleanupDaysStale` (default: 3) to config.

**ISC Constraint:** `Complete-SPCampaign` is guarded by `Safety.AllowCompleteCampaign` (default
`false`). This must be set to `true` in settings.json for cleanup to work. The function should
check this guard and log a clear warning if it's blocked.

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1` -- new `Invoke-SPDeltaCertCleanup` function
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` -- export new function
- `Scripts/Invoke-SPADDeltaCert.ps1` -- add `-RunCleanup` switch, call cleanup before main run
- `Config/settings.json` -- add `DeltaCert.CleanupDaysStale`
- `Modules/SP.Core/SP.Config.psm1` -- add `CleanupDaysStale` to DeltaCert defaults

**Acceptance Criteria:**
- `Invoke-SPDeltaCertCleanup -CampaignNamePrefix 'AD Delta Cert' -DaysStale 3` completes campaigns older than 3 days
- Returns `@{Success; Data=@{Completed; StillActive; Errors}; Error}`
- When `Safety.AllowCompleteCampaign` is `false`, returns `Success=$false` with clear error (no API call made)
- `-WhatIf` describes what would be completed without calling Complete-SPCampaign

**Tests:**
- DC-019: Mock Search-SPCampaigns + Complete-SPCampaign -- verify stale campaigns completed
- DC-020: Verify AllowCompleteCampaign=false blocks cleanup with clear error
- DC-021: Verify non-stale campaigns are not completed

---

### F-04: Delta Cert Run JSONL Audit Trail

- **Status:** `DONE`
- **Commit:** bce09b5
- **Depends On:** none

**Description:**
After each delta cert run (whether campaigns were created or not), append a structured
JSONL event to a log file in the DeltaCert output directory. This provides long-term
tracking of daily activity, useful for compliance reporting and troubleshooting.

Event fields: `Timestamp`, `CorrelationID`, `Action` ("DeltaCertRun"), `SourceIds`,
`HoursBack`, `GrantEventsFound`, `IdentitiesProcessed`, `ManagerGroups`,
`CampaignsCreated`, `CampaignIds`, `Reason`, `Errors`, `DurationSeconds`.

Add `DeltaCert.OutputPath` to config (default: `.\DeltaCert`).

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1` -- append JSONL at end of `Invoke-SPDeltaCertRun` (follow `Export-SPAuditJsonl` pattern from SP.AuditReport.psm1: `[System.IO.File]::AppendAllText()` with `UTF8Encoding($false)`)
- `Config/settings.json` -- add `DeltaCert.OutputPath`
- `Modules/SP.Core/SP.Config.psm1` -- add `OutputPath` to DeltaCert defaults

**Acceptance Criteria:**
- After any `Invoke-SPDeltaCertRun` call, a JSONL line is appended to `{OutputPath}/deltacert-audit.jsonl`
- File is created if it doesn't exist
- Each line is valid JSON parseable by `ConvertFrom-Json`
- No-change runs (Reason=NoChanges) are also logged

**Tests:**
- DC-022: Verify JSONL file is written after a successful run
- DC-023: Verify JSONL line contains expected fields

---

## Phase 3: Reviewer Routing

### F-05: SOURCE_OWNER Reviewer Mode (Application Owner)

- **Status:** `DONE`
- **Commit:** 2908e2a
- **Depends On:** F-01 (deadline support should be in place)

**Description:**
Add `-ReviewerMode` parameter (`Manager` | `SourceOwner`) to `Invoke-SPDeltaCertRun` and
the CLI script. This enables the "application owner" certification path the user requested.

- **Manager** (default, current behavior): One SEARCH campaign per manager group. Each
  manager reviews only their direct reports who received new AD access.

- **SourceOwner**: One `SOURCE_OWNER` campaign per source ID. ISC automatically routes
  certification items to whoever owns each source. No manager lookup or grouping needed --
  the flow skips `Get-SPDeltaAffectedIdentities` and `Group-SPDeltaByManager` entirely.

`Build-SPCampaignBody` already handles `SOURCE_OWNER` type with `-SourceId` parameter.
`New-SPCampaign -Type SOURCE_OWNER -SourceId $id` is the existing call pattern.

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1` -- add `-ReviewerMode` param to `Invoke-SPDeltaCertRun`; add SourceOwner branch that creates one campaign per source ID
- `Scripts/Invoke-SPADDeltaCert.ps1` -- add `-ReviewerMode` param, default from config
- `Config/settings.json` -- add `DeltaCert.DefaultReviewerMode` (default: "Manager")
- `Modules/SP.Core/SP.Config.psm1` -- add `DefaultReviewerMode` to DeltaCert defaults

**SourceOwner Flow:**
```
Get-SPDeltaGrantEvents (same as Manager mode)
  -> If events found, for each unique SourceId:
       New-SPCampaign -Type SOURCE_OWNER -SourceId $sourceId -Name "$Prefix $date - Source $sourceName"
       Start-SPCampaign
```

**Acceptance Criteria:**
- `-ReviewerMode SourceOwner` creates one `SOURCE_OWNER` campaign per source ID
- `-ReviewerMode Manager` (or omitted) uses existing SEARCH-per-manager behavior
- SourceOwner mode skips identity resolution and manager grouping (faster, fewer API calls)
- WhatIf works for both modes

**Tests:**
- DC-024: SourceOwner mode calls `New-SPCampaign -Type SOURCE_OWNER`
- DC-025: Manager mode still calls `New-SPCampaign -Type SEARCH` (regression check)
- DC-026: SourceOwner mode does NOT call `Get-SPDeltaAffectedIdentities`

---

## Phase 4: OOO Escalation

### F-06: Stale Certification Detection

- **Status:** `DONE`
- **Commit:** 6097f81
- **Depends On:** none (uses existing SP.AuditQueries functions)

**Description:**
New function `Get-SPDeltaCertStaleCertifications` that finds active delta cert campaigns
with certifications that have been open longer than a configurable threshold (default 24
hours with no reviewer action).

Flow:
1. `Search-SPCampaigns -Keyword $CampaignNamePrefix -Status @('ACTIVE')` -- find active delta certs
2. For each campaign, `Get-SPAuditCertifications -CampaignId $id` -- get all certifications
3. Filter to certifications where: `signed` is null (not completed) AND `created` is older than `StaleHours`
4. Return list of stale certs with: CertificationId, CampaignId, CampaignName, ReviewerIdentityId, ReviewerName, HoursOpen, ReviewerClassification

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` -- new `Get-SPDeltaCertStaleCertifications` function
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` -- export new function

**Acceptance Criteria:**
- Returns only certifications where `signed` is null AND age exceeds `StaleHours`
- Completed certifications (signed is not null) are excluded
- Returns empty array (not error) when no stale certs found
- Each result includes enough context for F-07 to escalate (cert ID, reviewer ID, campaign name)

**Tests:**
- DC-027: Mock returns one signed and one unsigned cert -- only unsigned is returned
- DC-028: Mock returns certs within threshold -- empty array returned

---

### F-07: Org Tree Escalation + Reassignment

- **Status:** `DONE`
- **Commit:** 8a68ba9
- **Depends On:** F-06 (stale detection provides input)

**Description:**
New function `Invoke-SPDeltaCertEscalate` that takes stale certifications and reassigns
them up the org tree. For each stale cert, looks up the current reviewer's manager and
reassigns the certification to that manager.

Flow:
1. Take stale certs from `Get-SPDeltaCertStaleCertifications`
2. For each stale cert:
   a. `Get-SPDeltaIdentityDetail -IdentityId $reviewerIdentityId` -- get reviewer's manager
   b. If reviewer has no manager, skip with warning (log as un-escalatable)
   c. Get all review item IDs for this certification via `Get-SPAuditCertificationItems`
   d. `Invoke-SPReassign -CertificationId $certId -NewCertifierIdentityId $managerOfReviewerId -ReviewItemIds $itemIds -Reason "SLA escalation: $hoursOpen hours without action"`
3. Return summary: escalated count, skipped count, errors

**Configurable:** `-MaxEscalationLevels` (default: 2). If the reviewer's manager was ALSO
the original escalation target from a previous run, walk up one more level. Track via the
certification's `ReviewerClassification` (if already `Reassigned`, look at original reviewer's
manager's manager). Ceiling prevents infinite escalation loops.

**ISC Constraint:** `Invoke-SPReassign` max 50 items per call. If a certification has >50
review items, use `Invoke-SPReassignAsync` automatically.

**ISC Constraint:** Reassignment does NOT work for Governance Group certifications. Detect
and skip with a WARN log.

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1` -- new `Invoke-SPDeltaCertEscalate` function
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` -- export new function

**Acceptance Criteria:**
- Stale cert is reassigned to reviewer's manager
- Reassignment reason includes hours-open context
- Reviewer with no manager is skipped with WARN log
- >50 review items triggers async reassignment automatically
- MaxEscalationLevels prevents infinite escalation
- WhatIf describes reassignments without making API calls
- Returns `@{Success; Data=@{Escalated; Skipped; Errors}; Error}`

**Tests:**
- DC-029: Mock stale cert + reviewer with manager -- verify `Invoke-SPReassign` called with manager ID
- DC-030: Mock reviewer with no manager -- verify skipped, not error
- DC-031: WhatIf mode -- verify `Invoke-SPReassign` NOT called

---

### F-08: Escalation CLI Script + Config

- **Status:** `DONE`
- **Commit:** PENDING_COMMIT
- **Depends On:** F-06, F-07

**Description:**
New CLI script `Invoke-SPDeltaCertEscalate.ps1` that wraps the escalation workflow.
Designed to run on a separate schedule from the main delta cert script (e.g., every 4
hours, or daily after business hours) to catch stale certifications.

Add `DeltaCert.Escalation` config section with thresholds and limits.

Escalation events are logged to JSONL in the DeltaCert output directory (same pattern as
F-04 audit trail) for compliance evidence.

**Files to Create:**
- `Scripts/Invoke-SPDeltaCertEscalate.ps1` -- CLI script

**Files to Modify:**
- `Config/settings.json` -- add `DeltaCert.Escalation` section:
  ```json
  "Escalation": {
      "DefaultStaleHours": 24,
      "MaxEscalationLevels": 2,
      "CampaignNamePrefix": "AD Delta Cert"
  }
  ```
- `Modules/SP.Core/SP.Config.psm1` -- add Escalation defaults

**CLI Parameters:**
- `-CampaignNamePrefix` (string, default from config)
- `-StaleHours` (int, default from config: 24)
- `-MaxEscalationLevels` (int, default from config: 2)
- `-ConfigPath`, `-Token`, `-TokenExpiryMinutes` (standard auth params)
- `-OutputMode` (Console|JSON|Both)
- `-WhatIf`, `-Help`

**Exit Codes:**
- 0 = Escalation completed (or WhatIf)
- 1 = No stale certifications found
- 2 = Parameter error
- 3 = Authentication error
- 4 = Configuration error
- 5 = Escalation error (partial or full failure)

**Acceptance Criteria:**
- `.\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf` shows stale certs that would be escalated
- Console output includes: stale cert count, escalated count, skipped count
- JSONL event appended to `{OutputPath}/deltacert-escalation.jsonl`
- ISC sends its own notification email to the new reviewer (no custom email needed)

**Tests:**
- Syntax validation via PS AST parser
- WhatIf smoke test

---

## Phase 5: GUI Integration

### F-09: DeltaCert GUI Tab

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** F-01 through F-08 (all CLI features should be stable before GUI)

**Description:**
Add a "Delta Cert" tab to the WPF GUI following the exact Audit tab pattern (MainWindow.xaml
lines 731-954, SP.GuiBridge.psm1 bridge functions, SP.MainWindow.psm1 button handlers).

**Tab Layout (5 rows, matching Audit tab structure):**

| Row | Content |
|-----|---------|
| 0 | Config: Source ID text input, HoursBack spinner, DeadlineDays spinner, ReviewerMode combo (Manager/SourceOwner) |
| 1 | Results DataGrid: Date, Campaigns Created, Identities, Manager Groups, Reason, Errors |
| 2 | Action buttons: Run Delta Cert, Run Cleanup, Run Escalation, Open Output Folder |
| 3 | Progress bar + status label |
| 4 | Recent run history from JSONL audit trail (F-04) |

**Bridge Functions (SP.GuiBridge.psm1):**
- `Invoke-SPGuiDeltaCertRun` -- wraps `Invoke-SPDeltaCertRun`, transforms result to display-ready PSCustomObject
- `Invoke-SPGuiDeltaCertCleanup` -- wraps `Invoke-SPDeltaCertCleanup`
- `Invoke-SPGuiDeltaCertEscalate` -- wraps `Invoke-SPDeltaCertEscalate`
- `Get-SPGuiDeltaCertHistory` -- reads JSONL audit trail, returns recent runs as PSCustomObjects

**Files to Create:**
- `Gui/DeltaCertTab.xaml` -- design reference (not runtime, matches AuditTab.xaml pattern)

**Files to Modify:**
- `Gui/MainWindow.xaml` -- add new TabItem with inline DeltaCert content
- `Modules/SP.Gui/SP.GuiBridge.psm1` -- add 4 bridge functions
- `Modules/SP.Gui/SP.MainWindow.psm1` -- add button click handlers
- `Modules/SP.Gui/SP.Gui.psd1` -- export new bridge functions

**Acceptance Criteria:**
- Tab appears in GUI between Audit and Settings (or after Audit)
- Run Delta Cert button calls `Invoke-SPGuiDeltaCertRun` on background thread
- Progress bar updates during run
- Results display in DataGrid after completion
- Recent history populates from JSONL audit trail
- All buttons respect browser token from Settings tab
- Dark theme styling matches existing tabs

**Tests:**
- XAML well-formedness validation
- PS AST syntax validation on all modified .psm1 files
- Manual: GUI launches with new tab visible (Windows PS 5.1 only)

---

## Phase 6: Hardening

### F-10: Identity Exclusion Filters

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** none (enhances Phase 1 function)

**Description:**
Add configurable identity exclusion patterns to `Get-SPDeltaAffectedIdentities` so that
service accounts, admin accounts, and other non-human identities can be excluded from
delta cert campaigns even if they receive AD group grants.

Exclusion criteria (all optional, config-driven):
- `ExcludeLifecycleStates`: array of cloudLifecycleState values to exclude (default: already excludes terminated, inactive, leaver, prehire -- make this configurable)
- `ExcludeDisplayNamePatterns`: array of regex patterns matched against identity displayName (e.g., `'^SVC-'`, `'^ADM-'`, `'Service Account'`)
- `ExcludeIdentityIds`: explicit array of identity IDs to always skip

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` -- enhance `Get-SPDeltaAffectedIdentities` to read exclusion config and apply filters
- `Config/settings.json` -- add exclusion fields to DeltaCert section:
  ```json
  "ExcludeLifecycleStates": ["terminated", "inactive", "leaver", "prehire"],
  "ExcludeDisplayNamePatterns": [],
  "ExcludeIdentityIds": []
  ```
- `Modules/SP.Core/SP.Config.psm1` -- add exclusion defaults

**Acceptance Criteria:**
- Identity matching `ExcludeDisplayNamePatterns` is skipped with DEBUG log
- Identity in `ExcludeIdentityIds` is skipped
- Custom lifecycle states in `ExcludeLifecycleStates` override the hardcoded list
- Empty exclusion arrays = no filtering (backwards compatible)

**Tests:**
- DC-032: Identity with displayName matching exclusion pattern is skipped
- DC-033: Identity in ExcludeIdentityIds is skipped
- DC-034: Empty exclusion config = all active identities included (regression)

---

## Daily Operations Reference

Once all phases are complete, the intended daily workflow is:

```
# Scheduled Task / cron -- runs daily at 06:00
# Step 1: Clean up stale campaigns from previous days
.\Invoke-SPADDeltaCert.ps1 -SourceId 'src-ad-001' -RunCleanup -Token $token

# Scheduled Task / cron -- runs every 4 hours during business hours
# Step 2: Escalate stale certifications
.\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -Token $token

# The main delta cert script (Step 1) handles:
#   - Cleanup past-due campaigns (if -RunCleanup)
#   - Query AD grant events (last 24h)
#   - Create campaigns for each manager (or source owner)
#   - Log run to JSONL audit trail
#
# The escalation script (Step 2) handles:
#   - Find active certs with no action past threshold
#   - Reassign up the org tree
#   - Log escalation to JSONL
#
# ISC handles:
#   - Email notifications to reviewers (campaign created)
#   - Email notifications on reassignment (cert escalated)
#   - Campaign deadline enforcement
```

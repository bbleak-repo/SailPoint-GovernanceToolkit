# Phase 9: Report Enhancements -- Feature Backlog

**Created:** 2026-05-23
**Prereqs:** Leadership reports (L-01 to L-08) complete, IdentityId fix applied
**Research:** Access review best practices (SOX, SOC2, ISO 27001, NIST) informing R-07 to R-09

---

## How to Use This File

Same agent-loop workflow as previous backlogs:
1. Find next `PENDING` feature in serial order
2. Check dependencies
3. Implement, validate, mark `DONE`, commit, push, loop

**Serial order:**
```
R-01 -> R-02 -> R-03 -> R-04 -> R-05 -> R-06 -> R-07 -> R-08 -> R-09 -> R-10
```

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| R-01 | Dynamic Org Levels | none | DONE |
| R-02 | Per-Level Report Generation | R-01 | DONE |
| R-03 | Expandable Detail Mode | R-02 | DONE |
| R-04 | Delta Report Generator | none | DONE |
| R-05 | Delta Report Mock Data | R-04 | DONE |
| R-06 | Delta Report CLI + GUI | R-05 | PENDING |
| R-07 | Anti-Rubber-Stamping Analytics | R-03 | PENDING |
| R-08 | Risk Indicators | R-03 | PENDING |
| R-09 | Compliance Fields | R-03 | PENDING |
| R-10 | Pester Tests | R-06, R-09 | PENDING |

---

## Auto-Detected Level Labels (Reference)

Reports auto-label org tree levels based on distance from leaf identities:

| Depth | Label | Report Type |
|-------|-------|-------------|
| 0 | Individual Contributors | (reviewed identities, no report) |
| 1 | Managers | Per-manager section in Director report |
| 2 | Directors | Per-director report |
| 3 | Vice Presidents | Per-VP report |
| 4 | Senior Vice Presidents | Per-SVP report |
| 5+ | Executive Leadership | Executive summary report |

The user selects a starting level (e.g., "from VP down") via `-LeadershipStartLevel`
in CLI or a dropdown in GUI. Reports are generated for every level from the selected
level down to Manager. The top level always gets an executive summary.

---

## Compliance Research Findings (Reference)

From SOX/SOC2/ISO 27001/NIST analysis:

**18 mandatory fields** for audit evidence: Identity Name/ID, Account ID (UPN),
Application/Source, Entitlement Name, Access Type, Reviewer Name, Reviewer Email,
Decision, Decision Date/Time, Justification/Comment, Campaign Name, Campaign Start,
Campaign Due Date, Campaign Completion, Remediation Status, Remediation Date,
Reassignment Chain, System Timestamp.

**Anti-rubber-stamping indicators**: Decision velocity (>50 items in <60s = red flag),
100% approval rate across cycles, empty/identical justifications, recommendation
override patterns.

**Risk categories**: Stale access (30/60/90 day inactive), excessive privileges,
orphan accounts, SoD violations, terminated-with-access, manager-less identities.

---

## R-01: Dynamic Org Levels

- **Status:** `DONE`
- **Commit:** 4e9867d
- **Depends On:** none

**Description:**
Replace the hardcoded Level 2 = "Director", Level 3+ = "VP/Executive" mapping in
Build-SPOrgTree and the leadership report generators with auto-detected level labels.

**Current problem:** The org tree assigns levels based on distance from leaf (Level 0 =
IC, Level 1 = Manager, Level 2 = Director, Level 3 = VP). The report generators hardcode
"Director Summary" and "Executive Rollup" regardless of actual org depth. With a 4-level
org (IC -> Manager -> Director -> VP -> President), the President and VP are both treated
as "TopLeaders" with no distinction.

**Changes:**
1. Add a `LevelLabels` property to the Build-SPOrgTree return structure:
   ```powershell
   LevelLabels = @{
       0 = 'Individual Contributors'
       1 = 'Managers'
       2 = 'Directors'
       3 = 'Vice Presidents'
       4 = 'Senior Vice Presidents'
       5 = 'Executive Leadership'
   }
   ```
2. Update Group-SPAuditByLeadership to group by EVERY level above Manager (not just
   Level 2 "Directors" and Level 3+ "TopLeaders").
3. Return structure should have per-level groupings:
   ```powershell
   @{
       Levels = @{
           3 = @{ Label = 'Vice Presidents'; Leaders = @{...} }
           2 = @{ Label = 'Directors'; Leaders = @{...} }
       }
       TopLevel = 4  # highest level found
   }
   ```

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` -- Build-SPOrgTree: add LevelLabels,
  reclassify nodes by actual level (not hardcoded Director/TopLeader buckets)
- `Modules/SP.Audit/SP.AuditReport.psm1` -- Group-SPAuditByLeadership: group by all levels

**Acceptance Criteria:**
- Build-SPOrgTree with 4-level org returns distinct Level 2, 3, 4 nodes
- Level labels match the auto-detect table above
- Group-SPAuditByLeadership groups decisions at every level, not just 2 fixed levels
- Existing 3-level orgs produce identical results (backwards compatible)

---

## R-02: Per-Level Report Generation

- **Status:** `DONE`
- **Commit:** 7d0dc0f
- **Depends On:** R-01

**Description:**
Replace the fixed "executive summary + per-director" report generation with a dynamic
per-level approach. One report per leader at EACH org level (except leaves).

With a 4-level org (IC -> Manager -> Director -> VP -> President):
```
Audit/leadership/
  executive-summary.html         (President level - highest)
  vp-AliceJohnson.html           (VP level)
  vp-BobSmith.html
  vp-CharlieWilliams.html
  director-DianaBrown.html       (Director level)
  director-EdwardJones.html
  ...
```

Add `-LeadershipStartLevel` parameter (default: highest level found). This controls
which level is the "top" for the executive summary. Setting it to 2 (Director) would
skip VP and President levels and make each Director's report the executive summary for
their branch.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- Refactor Export-SPLeadershipExecutiveHtml
  and Export-SPLeadershipDirectorHtml into a single `Export-SPLeadershipLevelHtml`
  function that generates a report for any level, using the level label and subordinate
  data dynamically
- `Scripts/Invoke-SPCampaignAudit.ps1` -- Add `-LeadershipStartLevel` param, loop
  through levels from StartLevel down to Managers
- `Modules/SP.Gui/SP.MainWindow.psm1` -- Wire start level if GUI depth control exists

**Report structure per level:**
- Header: "{LevelLabel} Report: {LeaderName}" (e.g., "VP Report: Alice Johnson")
- Summary cards: Total items, approval rate, revocation rate, completion %
- Subordinate table: next-level-down leaders with aggregate metrics
- Navigation links: up to parent report, down to child reports

**Acceptance Criteria:**
- 4-level org generates: 1 executive + 3 VP + 12 director reports = 16 files
- File naming: `{level-label}-{SafeName}.html` (lowercase level prefix)
- `-LeadershipStartLevel 2` generates only director-level reports (no VP/executive)
- Each report links to its parent and children reports
- Reports at the lowest generated level include per-identity decision detail

---

## R-03: Expandable Detail Mode

- **Status:** `DONE`
- **Commit:** 6d60d84
- **Depends On:** R-02

**Description:**
Add HTML5 `<details>/<summary>` collapsible sections to leadership reports. Three modes
controlled by `-DetailLevel` parameter:

- **Summary** (default): Aggregate counts only. Decision tables collapsed. Compact 1-2
  pages per report. Best for executives.
- **Detailed**: Decision tables expandable per manager/reviewer. Click to expand a
  manager's section to see identity-level decisions. Revocations auto-expanded.
- **Verbose**: Everything expanded (current behavior). All identity-level detail visible.
  Best for auditors.

**HTML pattern (pure HTML5, no JavaScript):**
```html
<details>
    <summary>Manager: Bob Smith (20 items: 15 approved, 4 revoked, 1 pending)</summary>
    <table>
        <tr><td>Alice Johnson</td><td>AD-SG-Finance</td><td>REVOKE</td>...</tr>
        ...
    </table>
</details>

<!-- Revocations auto-expanded in Detailed mode -->
<details open>
    <summary>Revocations (4 items) -- requires attention</summary>
    ...
</details>
```

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- Update report HTML builders to wrap
  identity-detail tables in `<details>` tags. Add `-DetailLevel` param (Summary/Detailed/Verbose)
- `Scripts/Invoke-SPCampaignAudit.ps1` -- Add `-DetailLevel` param
- `Modules/SP.Gui/SP.MainWindow.psm1` -- Add detail level dropdown to Audit options

**Acceptance Criteria:**
- Summary mode: no `<details>` tags, aggregate counts only, <2 pages per report
- Detailed mode: `<details>` tags on all sections, revocations auto-expanded (`<details open>`)
- Verbose mode: all `<details open>`, everything expanded
- `<details>/<summary>` renders correctly in Chrome, Edge, Firefox, and Word (Word
  ignores details/summary and shows everything expanded -- acceptable)

---

## R-04: Delta Report Generator

- **Status:** `DONE`
- **Commit:** 4b2e08c
- **Depends On:** none (independent from R-01/R-02/R-03)

**Description:**
New report type for daily operations: shows only what changed since the last run.
NOT a campaign audit -- this reads the delta cert JSONL audit trail and account
activity data to produce a lightweight actionable report.

**New functions in a new module file** `Modules/SP.DeltaCert/SP.DeltaCertReport.psm1`:

`Get-SPDeltaReportData`:
- Input: SourceIds, HoursBack (default 24)
- Queries: account-activities for GRANT_ACCESS events (reuse Get-SPDeltaGrantEvents)
- Queries: delta cert JSONL audit trail for campaigns created
- Queries: active campaign certifications for pending/decided items
- Returns structured data: NewGrants, CampaignsCreated, Revocations, PendingReviews

`Export-SPDeltaReportHtml`:
- Input: delta report data, output path
- Generates lightweight 1-2 page HTML:
  - Section 1: New Access Grants (identity, source, entitlement, date)
  - Section 2: Campaigns Created (campaign name, manager, identity count, status)
  - Section 3: Revocations (identity, access revoked, reviewer, date)
  - Section 4: Pending Reviews (items awaiting decision, age in hours)
  - Section 5: Anomalies (past-due campaigns, inactive reviewers)
- Color-coded: green for completed actions, orange for pending, red for overdue

**Files to Create:**
- `Modules/SP.DeltaCert/SP.DeltaCertReport.psm1`

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` -- add to NestedModules + FunctionsToExport

**Acceptance Criteria:**
- Delta report shows ONLY changes in the time window (not full campaign history)
- Report is 1-2 pages for a typical day (5-10 changes)
- No campaign detail sections (no reviewer accountability, no remediation proof)
- Timestamp shows "as of {date/time}" for clarity
- Generates both HTML and JSONL output

---

## R-05: Delta Report Mock Data

- **Status:** `DONE`
- **Commit:** 0fe76b9
- **Depends On:** R-04

**Description:**
Enrich the Pode mock server's seed data with multi-day account activities and
campaign data so delta reports have meaningful test content.

Add to API-MockServer seed-data.json:
- 5 account activities from 2 hours ago (existing)
- 3 account activities from 26 hours ago (yesterday -- outside default 24h window)
- 2 REVOKE_ACCESS activities from 4 hours ago
- 1 active campaign created today with 3 pending certifications

**Files to Modify:**
- `/Users/xand/Documents/Projects/API-MockServer/Profiles/SailPoint-ISC/seed-data.json`

**Acceptance Criteria:**
- `Get-SPDeltaReportData -HoursBack 24` shows 5 new grants + 2 revocations
- `Get-SPDeltaReportData -HoursBack 48` shows 8 new grants + 2 revocations
- Yesterday's activities excluded from 24h window

---

## R-06: Delta Report CLI + GUI

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** R-05

**Description:**
New CLI script `Scripts/Invoke-SPDeltaReport.ps1` and GUI integration for daily
delta reports.

**CLI Parameters:**
- `-SourceId` (string[], AD source IDs to monitor)
- `-HoursBack` (int, default 24)
- `-OutputPath` (default DeltaCert/reports/)
- `-ConfigPath`, `-Token`, `-TokenExpiryMinutes` (standard auth)
- `-OutputMode` (Console/JSON/Both)

**CLI Usage:**
```powershell
# Daily delta report
.\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -HoursBack 24

# Output: DeltaCert/reports/delta-2026-05-23.html
```

**GUI:** Add "Generate Delta Report" button to Delta Cert tab (alongside existing
Run/Cleanup/Escalation buttons).

**Files to Create:**
- `Scripts/Invoke-SPDeltaReport.ps1`

**Files to Modify:**
- `Gui/MainWindow.xaml` -- add button to DeltaCert tab
- `Modules/SP.Gui/SP.GuiBridge.psm1` -- add Invoke-SPGuiDeltaReport bridge function
- `Modules/SP.Gui/SP.MainWindow.psm1` -- wire button handler

**Acceptance Criteria:**
- CLI generates delta report HTML with 4 sections
- Report opens in browser with correct styling
- GUI button triggers report generation with progress feedback
- Report file named `delta-{YYYY-MM-DD}.html`

---

## R-07: Anti-Rubber-Stamping Analytics

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** R-03

**Description:**
Add a new section to campaign audit reports that flags potential rubber-stamping.
Based on compliance research (SOX/SOC2 auditor red flags).

**Metrics calculated per reviewer:**
1. **Decision velocity**: items decided per minute. Flag if >50 items in <60 seconds.
2. **Approval-only rate**: % of decisions that are APPROVE. Flag if 100% across >10 items.
3. **Bulk decision detection**: clusters of identical decisions within 30-second windows.
4. **Response latency**: time from campaign creation to first decision. Flag if <1 minute.

**New function** `Measure-SPAuditRubberStampRisk` in SP.AuditReport.psm1:
- Input: decisions, certifications (for timestamps)
- Returns per-reviewer risk assessment with severity (None/Low/Medium/High)
- High = multiple red flags

**Add as Section 8** (after Audit Metadata) in the campaign audit HTML report:
- Table: Reviewer | Items | Velocity (items/min) | Approval Rate | Risk Level
- Color-coded risk: green (None/Low), orange (Medium), red (High)
- Only shown when risk indicators are found (section omitted if all clean)

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new function + HTML section
- `Modules/SP.Audit/SP.Audit.psd1` -- export
- `Scripts/Invoke-SPCampaignAudit.ps1` -- call new function, add to campaign audit data

**Acceptance Criteria:**
- Reviewer who approved 100 items in 30 seconds flagged as High risk
- Reviewer who took 2 hours to review 20 items flagged as None
- Section only appears when at least one Medium/High risk reviewer exists
- Risk assessment included in JSONL audit trail

---

## R-08: Risk Indicators

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** R-03

**Description:**
Add per-identity risk flags to decision detail tables in audit and leadership reports.
Flags are displayed as colored tags next to each identity row.

**Risk flags:**
- **STALE** (orange): Identity's last login >90 days ago (from identity attributes)
- **PRIVILEGED** (red): Access type is admin/elevated (matched by entitlement name pattern)
- **ORPHAN** (red): Identity has no manager
- **TERMINATED** (red): Identity lifecycle state is terminated but still has access
- **SVC-ACCOUNT** (gray): Identity matches service account pattern

**Implementation:**
- New function `Get-SPAuditRiskFlags` in SP.AuditReport.psm1
- Called during the decision grouping phase
- Each decision item gets a `RiskFlags` array property
- HTML tables show flags as colored `<span>` badges next to identity name

**Configurable patterns** in settings.json:
```json
"Audit": {
    "RiskIndicators": {
        "StaleAccessDays": 90,
        "PrivilegedPatterns": ["Admin", "Root", "DBA", "Domain Admins"],
        "ServiceAccountPatterns": ["^SVC-", "^svc-"]
    }
}
```

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new function + HTML badge rendering
- `Modules/SP.Audit/SP.Audit.psd1` -- export
- `Config/settings.json` -- add RiskIndicators section
- `Modules/SP.Core/SP.Config.psm1` -- add defaults

**Acceptance Criteria:**
- Terminated identity with active access shows red TERMINATED badge
- Service account matches show gray SVC-ACCOUNT badge
- Flags visible in both campaign audit and leadership reports
- Empty patterns = no flagging (backwards compatible)

---

## R-09: Compliance Fields

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** R-03

**Description:**
Add missing mandatory compliance fields to the decision output and JSONL audit trail.
Based on the 18 mandatory fields identified in compliance research.

**Currently missing from Group-SPAuditDecisions output:**
1. `Justification` -- reviewer's comment/reason (from ISC review item `comment` field)
2. `RemediationStatus` -- whether revocations were actually provisioned
3. `SystemTimestamp` -- server-side timestamp (distinct from decision date)
4. `CampaignStartDate` -- when the campaign was created
5. `CampaignDueDate` -- campaign deadline
6. `ReviewerEmail` -- reviewer's email (for non-repudiation)

**Implementation:**
- Extend Group-SPAuditDecisions to include these 6 fields in each decision PSCustomObject
- Some fields come from the review item (comment, systemTimestamp)
- Some come from the campaign object (startDate, dueDate)
- ReviewerEmail from Get-SPAuditAccountForIdentity
- RemediationStatus requires checking provisioning events (Get-SPAuditIdentityEvents)
- Add these fields to Export-SPAuditJsonl for machine-readable compliance evidence

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- extend Group-SPAuditDecisions output, update
  HTML tables to include new columns (collapsible in non-verbose mode)
- `Scripts/Invoke-SPCampaignAudit.ps1` -- pass campaign metadata to grouping function

**Acceptance Criteria:**
- JSONL output includes all 18 mandatory fields per decision
- HTML tables show Justification column (or "N/A" if empty)
- RemediationStatus shows "Provisioned" / "Pending" / "N/A"
- Compliance fields present even when sections are collapsed (in HTML source)

---

## R-10: Pester Tests

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** R-06, R-09

**Description:**
Pester tests for all new functions added in R-01 through R-09.

**Test IDs:**
- RE-01: Build-SPOrgTree returns LevelLabels for 4-level org
- RE-02: Group-SPAuditByLeadership groups by all levels (not just 2)
- RE-03: Export-SPLeadershipLevelHtml generates reports at each level
- RE-04: HTML contains `<details>` tags in Detailed mode, none in Summary mode
- RE-05: Get-SPDeltaReportData returns NewGrants + Revocations
- RE-06: Export-SPDeltaReportHtml generates valid HTML <2 pages
- RE-07: Measure-SPAuditRubberStampRisk flags bulk-approve pattern
- RE-08: Get-SPAuditRiskFlags returns TERMINATED for terminated identity
- RE-09: Group-SPAuditDecisions includes Justification and RemediationStatus

**Files to Create/Modify:**
- `Tests/SP.ReportEnhancements.Tests.ps1` (new)
- `Tests/Import-TestModules.ps1` -- may need update

---

## Daily Operations Reference (Post-Enhancement)

```
# Morning: What changed overnight?
.\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -HoursBack 24
# -> DeltaCert/reports/delta-2026-05-23.html (1-2 pages, action items only)

# Daily: Create delta cert campaigns
.\Invoke-SPADDeltaCert.ps1 -SourceId 'src-ad-001' -RunCleanup

# Every 4 hours: Escalate stale certifications
.\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24

# Weekly/Monthly: Full campaign audit with leadership rollup
.\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 30 \
    -IncludeLeadershipRollup -LeadershipDepth 4 \
    -DetailLevel Detailed
# -> Audit/leadership/ (executive + VP + director reports with expandable detail)

# Quarterly: Compliance-grade audit with verbose detail
.\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 90 \
    -IncludeLeadershipRollup -LeadershipDepth 5 \
    -DetailLevel Verbose
# -> Full 18-field compliance evidence, rubber-stamp analysis, risk indicators
```

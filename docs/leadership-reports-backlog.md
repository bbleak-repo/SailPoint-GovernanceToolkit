# Leadership Rollup Reports -- Feature Backlog

**Created:** 2026-05-22
**Prereqs:** All Phases 1-7 complete, hallucinated endpoint fix applied

---

## How to Use This File

Same loop workflow as previous backlogs:

1. Find the next `PENDING` feature (follow serial order)
2. Check **Depends On** -- all dependencies must be `DONE`
3. Implement, validate, mark `DONE`, commit, push, loop

**Serial order:**
```
L-01 -> L-02 -> L-03 -> L-04 -> L-05 -> L-06 -> L-07 -> L-08
```

---

## Overview

Leadership needs aggregated rollup reports from campaign audits, not just individual
reviewer detail. This feature walks the ISC org tree (identity -> manager -> director -> VP)
and generates per-leader HTML reports showing what their org accomplished.

**Report hierarchy (3 levels above reviewed identities):**
```
VP / Top Leader (executive-summary.html)
  |
  +-- Director A (director-DirectorA.html)
  |     +-- Manager 1 (section in director report)
  |     |     +-- Alice (reviewed identity)
  |     |     +-- Bob
  |     +-- Manager 2
  |           +-- Charlie
  |
  +-- Director B (director-DirectorB.html)
        +-- Manager 3
              +-- Diana
```

**Output structure:**
```
Audit/
  campaign-audit-combined.html           (existing, unchanged)
  leadership/
    executive-summary.html               (VP sees all directors)
    director-BobSmith.html               (Bob's managers only)
    director-NancyJones.html             (Nancy's managers only)
```

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| L-01 | Org Tree Walker (Build-SPOrgTree) | none | DONE |
| L-02 | Leadership Grouping (Group-SPAuditByLeadership) | L-01 | DONE |
| L-03 | Executive Summary HTML | L-02 | PENDING |
| L-04 | Director-Level HTML Reports | L-03 | PENDING |
| L-05 | CLI Integration | L-04 | PENDING |
| L-06 | GUI Integration | L-05 | PENDING |
| L-07 | SMTP Config + Logging Stub | L-05 | PENDING |
| L-08 | Pester Tests | L-04 | PENDING |

---

## ISC Org Tree -- How It Works

SailPoint ISC has no org chart API. The hierarchy is implicit:

- Each identity has a `manager` field (returned by `GET /v3/search/identities/{id}`)
- `manager.id` points to another identity
- Walking: identity -> `manager.id` -> that identity's `manager.id` -> ... until null
- The toolkit's `Get-SPDeltaIdentityDetail` resolves one level with session caching
- For 100 identities under 10 managers under 3 directors under 1 VP:
  ~114 API calls total, all cached, well within the 95 req/10s rate limit

**Cycle protection:** Track visited identity IDs. Enforce max depth (default 3 levels
above the reviewed identity). ISC data can have circular manager references in rare
cases (data quality issues).

---

## Existing Functions to Reuse

| Function | Module | Purpose |
|----------|--------|---------|
| `Get-SPDeltaIdentityDetail` | SP.DeltaCertQueries | Single identity lookup with manager, cached |
| `Group-SPAuditDecisions` | SP.AuditReport | Categorizes items into Approved/Revoked/Pending |
| `Measure-SPAuditReviewerMetrics` | SP.AuditReport | Per-reviewer time-to-decision metrics |
| `Group-SPReviewerActions` | SP.AuditReport | Reviewer accountability aggregation |
| `Build-HtmlTableRow` / `Build-HtmlTableHeader` | SP.AuditReport | Styled HTML table helpers |
| `Build-ExecutiveSummaryHtml` | SP.AuditReport | Dashboard pattern (donut charts, summary cards) |
| `ConvertTo-SafeHtml` | SP.AuditReport | HTML encoding |
| `Format-HtmlDate` / `Format-HoursDisplay` | SP.AuditReport | Formatting helpers |
| `Get-SPAuditAccountForIdentity` | SP.AuditQueries | Email/UPN lookup for SMTP targeting |

---

## L-01: Org Tree Walker (Build-SPOrgTree)

- **Status:** `DONE`
- **Commit:** ecae282
- **Depends On:** none

**Description:**
New function `Build-SPOrgTree` in SP.DeltaCertQueries.psm1 that takes an array of identity
IDs and walks each one up the manager chain to build a complete org tree structure.

Uses `Get-SPDeltaIdentityDetail` (which caches per session) for each lookup. Walks
recursively: identity -> manager.id -> that manager's manager.id -> ... until either
manager is null or max depth is reached or a cycle is detected.

**Files to Modify:**
- `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` -- new public function
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` -- add to FunctionsToExport

**Function Signature:**
```powershell
function Build-SPOrgTree {
    param(
        [Parameter(Mandatory)][string[]]$IdentityIds,
        [Parameter()][int]$MaxDepth = 3,
        [Parameter()][string]$CorrelationID
    )
}
```

**Return Structure:**
```powershell
@{
    Success = $true
    Data = @{
        # Tree nodes keyed by identity ID
        Nodes = @{
            'id-alice' = @{
                Identity    = @{Id='id-alice'; Name='Alice'; ...}
                ManagerId   = 'id-mgr1'
                Level       = 0   # leaf (reviewed identity)
                Children    = @() # leaf nodes have no children
            }
            'id-mgr1' = @{
                Identity    = @{Id='id-mgr1'; Name='Manager 1'; ...}
                ManagerId   = 'id-dir-a'
                Level       = 1   # manager
                Children    = @('id-alice', 'id-bob')
            }
            'id-dir-a' = @{
                Identity    = @{Id='id-dir-a'; Name='Director A'; ...}
                ManagerId   = 'id-vp'
                Level       = 2   # director
                Children    = @('id-mgr1', 'id-mgr2')
            }
            'id-vp' = @{
                Identity    = @{Id='id-vp'; Name='VP'; ...}
                ManagerId   = ''  # top of tree
                Level       = 3   # VP
                Children    = @('id-dir-a', 'id-dir-b')
            }
        }
        # Quick lookups
        TopLeaders   = @('id-vp')           # identities with no manager (Level = max)
        Directors    = @('id-dir-a', ...)    # Level = 2
        Managers     = @('id-mgr1', ...)    # Level = 1
        LeafCount    = 100                  # original identities
        MaxDepthHit  = $false               # true if any chain exceeded MaxDepth
    }
    Error = $null
}
```

**Cycle Detection:** Track visited IDs in a `[HashSet[string]]`. If a manager ID is already
visited, stop walking that chain and log a WARN.

**Acceptance Criteria:**
- 5 identities under 2 managers under 1 director -> tree has 3 levels, 8 nodes
- Cycle in manager chain -> stops, logs WARN, doesn't crash
- MaxDepth=2 -> stops at director level, doesn't walk to VP
- Returns empty TopLeaders when all identities have no manager
- Identities already in the tree (shared manager) are not duplicated

**Tests:** LR-01, LR-02 (tree building, cycle detection)

---

## L-02: Leadership Grouping (Group-SPAuditByLeadership)

- **Status:** `DONE`
- **Commit:** f319e07
- **Depends On:** L-01

**Description:**
New function `Group-SPAuditByLeadership` in SP.AuditReport.psm1 that takes the existing
audit decisions (from `Group-SPAuditDecisions`) and the org tree (from `Build-SPOrgTree`)
and groups decisions by each leadership level.

For each director, aggregates: total items, approved, revoked, pending, completion
percentage, and which managers contributed. For each VP/top leader, aggregates across
all their directors.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new public function
- `Modules/SP.Audit/SP.Audit.psd1` -- add to FunctionsToExport

**Function Signature:**
```powershell
function Group-SPAuditByLeadership {
    param(
        [Parameter(Mandatory)][hashtable]$Decisions,    # from Group-SPAuditDecisions
        [Parameter(Mandatory)][hashtable]$OrgTree,      # from Build-SPOrgTree .Data
        [Parameter()][hashtable]$ReviewerMetrics        # from Measure-SPAuditReviewerMetrics
    )
}
```

**Return Structure:**
```powershell
@{
    # Per-director rollup
    Directors = @{
        'id-dir-a' = @{
            Name           = 'Director A'
            Email          = 'dir.a@corp.com'
            TotalItems     = 50
            Approved       = 40
            Revoked        = 8
            Pending        = 2
            CompletionPct  = 96.0
            Managers       = @{
                'id-mgr1' = @{ Name='Mgr 1'; Approved=20; Revoked=5; Pending=0; AvgHours=4.2 }
                'id-mgr2' = @{ Name='Mgr 2'; Approved=20; Revoked=3; Pending=2; AvgHours=12.1 }
            }
        }
    }
    # Top-level executive rollup
    Executive = @{
        'id-vp' = @{
            Name           = 'VP Smith'
            TotalItems     = 100
            Approved       = 85
            Revoked        = 12
            Pending        = 3
            CompletionPct  = 97.0
            Directors      = @('id-dir-a', 'id-dir-b')
        }
    }
}
```

**Acceptance Criteria:**
- Decisions are correctly attributed to each director via the org tree
- Completion percentage = (Approved + Revoked) / Total * 100
- Manager-level aggregates sum correctly to director-level totals
- Identities with no director (shallow tree) are grouped under "Unmanaged"

**Tests:** LR-03 (grouping logic, aggregation math)

---

## L-03: Executive Summary HTML

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** L-02

**Description:**
New function `Export-SPLeadershipExecutiveHtml` in SP.AuditReport.psm1. Generates the
top-level executive summary report (`executive-summary.html`).

Content:
- Campaign name + date range header
- Overall metrics: total items, approval rate, revocation rate, completion %
- Donut chart showing approve/revoke/pending split (reuse `Build-ExecutiveSummaryHtml` pattern)
- Per-director table: Director Name | Total | Approved | Revoked | Pending | Completion % | Avg Response Time
- Color-coded completion column (green >= 95%, orange 80-95%, red < 80%)

Style: Same inline CSS as existing audit reports (Word-compatible, white background, blue headers).

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new public function

**Acceptance Criteria:**
- HTML file is self-contained (all CSS inline, no external references)
- Opens correctly in Chrome, Edge, and Word
- Director rows are sorted by completion % ascending (worst first)
- Color coding matches existing report conventions (#339933, #FF8800, #CC3333)

**Tests:** LR-04 (HTML structure validation)

---

## L-04: Director-Level HTML Reports

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** L-03

**Description:**
Extend `Export-SPLeadershipExecutiveHtml` (or new function `Export-SPLeadershipDirectorHtml`)
to generate per-director reports. One HTML file per director.

Content:
- Director name + campaign name header
- Director-level metrics (same as their row in the executive summary)
- Per-manager table: Manager Name | Total | Approved | Revoked | Pending | Avg Hours
- Per-manager expandable sections (or separate tables) showing individual identity decisions:
  Identity Name | Account (UPN) | Access | Decision | Reviewer | Date

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new or extended function
- `Modules/SP.Audit/SP.Audit.psd1` -- export if new function

**Output:** One HTML file per director: `director-{SafeName}.html`

**Acceptance Criteria:**
- Each director's report shows ONLY their managers and identities
- Manager sections include per-identity decision detail
- File naming uses sanitized director name (no special chars)
- Report includes navigation link back to executive summary

**Tests:** LR-05 (per-director file generation, content isolation)

---

## L-05: CLI Integration

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** L-04

**Description:**
Add `-IncludeLeadershipRollup` switch and `-LeadershipDepth` parameter to
`Invoke-SPCampaignAudit.ps1`. When enabled, the audit pipeline:

1. Collects all unique identity IDs from review items (existing)
2. Calls `Build-SPOrgTree` to walk the manager chains (new)
3. Calls `Group-SPAuditByLeadership` to group decisions by leader (new)
4. Calls `Export-SPLeadershipExecutiveHtml` + director reports (new)
5. Outputs to `{OutputPath}/leadership/` subdirectory

The leadership rollup runs AFTER the existing audit pipeline completes, using the
same data (decisions, reviewer metrics, account map). It's supplementary -- the
existing per-campaign reports are always generated.

**Files to Modify:**
- `Scripts/Invoke-SPCampaignAudit.ps1` -- add parameters, wire pipeline
- `Config/settings.json` -- add `Audit.IncludeLeadershipRollup` (default false), `Audit.LeadershipDepth` (default 3)
- `Modules/SP.Core/SP.Config.psm1` -- add defaults

**CLI Usage:**
```powershell
# Generate audit + leadership rollup
.\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 30 -IncludeLeadershipRollup

# Custom depth (2 = manager + director only, no VP)
.\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -IncludeLeadershipRollup -LeadershipDepth 2
```

**Note:** This requires SP.DeltaCert module loaded (for Build-SPOrgTree). The script's
module load chain must include SP.DeltaCert. Currently it loads SP.Core -> SP.Api -> SP.Audit.
Add SP.DeltaCert to the chain.

**Acceptance Criteria:**
- `-IncludeLeadershipRollup` generates executive-summary.html + per-director files
- Omitting the flag generates only the existing reports (no regression)
- `-LeadershipDepth 2` produces director-level reports but no executive VP summary
- Console output shows leadership report generation progress
- Leadership reports appear in `{OutputPath}/leadership/`

**Tests:** Script-level WhatIf smoke test

---

## L-06: GUI Integration

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** L-05

**Description:**
Add "Include Leadership Rollup" checkbox to the Audit tab's options row (Row 2 in
MainWindow.xaml, alongside the existing "Include Campaign Reports" and "Include Identity
Events" checkboxes).

Wire through `Invoke-SPGuiAudit` in SP.GuiBridge.psm1 to pass the flag to the audit
pipeline.

**Files to Modify:**
- `Gui/MainWindow.xaml` -- add checkbox to Audit tab Row 2
- `Gui/AuditTab.xaml` -- update design reference
- `Modules/SP.Gui/SP.GuiBridge.psm1` -- add `-IncludeLeadershipRollup` param to `Invoke-SPGuiAudit`
- `Modules/SP.Gui/SP.MainWindow.psm1` -- wire checkbox value in `Invoke-GuiAuditRun`

**Acceptance Criteria:**
- Checkbox appears in Audit tab options row
- Checking it adds leadership reports to the audit output
- Unchecking it (default) produces only the existing reports

---

## L-07: SMTP Config + Logging Stub

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** L-05

**Description:**
Add SMTP configuration to settings.json and a `Send-SPReport` function that resolves
leader email addresses and logs the intent to send, but does NOT make any SMTP calls.
This is a stub for future email distribution.

The function resolves each leader's email via `Get-SPAuditAccountForIdentity` (which
returns the `mail` attribute from the identity's AD account).

**Files to Modify:**
- `Config/settings.json` -- add `Audit.Smtp` section
- `Modules/SP.Core/SP.Config.psm1` -- add Smtp defaults
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Send-SPReport` function (stub)
- `Modules/SP.Audit/SP.Audit.psd1` -- export

**Settings.json addition:**
```json
"Smtp": {
    "Enabled": false,
    "Server": "",
    "Port": 587,
    "From": "",
    "UseSsl": true,
    "SubjectPrefix": "[SailPoint Audit]"
}
```

**Send-SPReport function:**
```powershell
function Send-SPReport {
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][string]$RecipientEmail,
        [Parameter(Mandatory)][string]$RecipientName,
        [Parameter()][string]$Subject,
        [Parameter()][string]$CorrelationID
    )
    # Check if SMTP is enabled in config
    # If disabled: log "SMTP disabled -- would send {file} to {email}" and return
    # If enabled: log "SMTP stub -- would send {file} to {email}" (future: Send-MailMessage)
    # Return @{Success; Data=@{Action='Logged'|'Sent'; Recipient; File}; Error}
}
```

**Acceptance Criteria:**
- `Send-SPReport` logs the intended send with recipient, file path, subject
- When `Smtp.Enabled = false`, logs "SMTP disabled" at DEBUG level
- When `Smtp.Enabled = true`, logs "SMTP stub -- would send" at INFO level (no actual send)
- Email address resolved from ISC identity's mail attribute
- Function is callable from both CLI and GUI pipelines

---

## L-08: Pester Tests

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** L-04

**Description:**
Pester tests for the leadership report pipeline. Add to existing test files or create
new `Tests/SP.LeadershipReport.Tests.ps1`.

**Test IDs:**
- LR-01: Build-SPOrgTree with 5 identities, 2 managers, 1 director -> correct tree structure
- LR-02: Build-SPOrgTree with cyclic manager reference -> stops, doesn't crash
- LR-03: Group-SPAuditByLeadership aggregation math (approved + revoked + pending = total)
- LR-04: Export-SPLeadershipExecutiveHtml generates valid HTML with correct director rows
- LR-05: Export-SPLeadershipDirectorHtml generates per-director file with only their data
- LR-06: Send-SPReport stub logs intent without making SMTP calls

**Files to Create/Modify:**
- `Tests/SP.LeadershipReport.Tests.ps1` (new) or add to `Tests/SP.AuditReport.Tests.ps1`
- `Tests/Import-TestModules.ps1` -- may need update if new test file

**Mock patterns:**
- Mock `Get-SPDeltaIdentityDetail` to return predefined manager chains
- Mock `Get-SPConfig` for SMTP and leadership config
- Use inline HTML validation (check for expected strings in output)

---

## ISC API Constraints (Reference)

| Constraint | Impact on Leadership Reports |
|------------|------------------------------|
| No org chart API | Must walk manager chains via identity search (one call per unique identity) |
| `GET /v3/search/identities/{id}` scope: `sp:search:read` | Already required by toolkit |
| 95 requests / 10 seconds | ~114 calls for 100 identities is well within limits |
| Session cache (`$script:IdentityCache`) | Each identity resolved only once per session |
| No email attribute on identity search | Use `Get-SPAuditAccountForIdentity` for email (separate `idn:accounts:read` call) |

---

## Email Distribution Pattern (Future -- Beyond L-07 Stub)

When SMTP is fully implemented (post-stub), the distribution flow would be:

```
1. Generate executive summary + director reports
2. For each director in the org tree:
   a. Resolve email: Get-SPAuditAccountForIdentity -> .Email
   b. Send-SPReport -ReportPath director-{name}.html -RecipientEmail $email
3. For each top leader (VP):
   a. Resolve email
   b. Send-SPReport -ReportPath executive-summary.html -RecipientEmail $email
4. Log all send events to JSONL audit trail
```

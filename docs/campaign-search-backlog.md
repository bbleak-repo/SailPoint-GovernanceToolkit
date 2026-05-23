# Phase 10: Campaign Search Features -- Backlog

**Created:** 2026-05-23
**Prereqs:** All Phases 1-9 complete
**Constraint:** NO GUI file changes (Windows GUI testing in progress on W-01 to W-07)

---

## How to Use This File

Agent loop -- same pattern as previous backlogs.

**Serial order:** `S-01 -> S-02 -> S-03 -> S-04 -> S-05 -> S-06 -> S-07 -> S-08 -> S-09 -> S-10`

---

## GUI Constraint (CRITICAL)

Windows agents are currently testing the GUI. Do NOT modify these files:
- `Gui/*.xaml` (any XAML file)
- `Modules/SP.Gui/SP.MainWindow.psm1`
- `Modules/SP.Gui/SP.GuiBridge.psm1`
- `Modules/SP.Gui/SP.Gui.psd1`
- `Scripts/Invoke-SPCampaignAudit.ps1` (being tested)
- `Scripts/Invoke-SPADDeltaCert.ps1` (being tested)
- `Scripts/Invoke-SPDeltaReport.ps1` (being tested)
- `Scripts/Invoke-SPDeltaCertEscalate.ps1` (being tested)

Safe to modify:
- `Modules/SP.Api/SP.Campaigns.psm1` (add new search functions)
- `Modules/SP.Audit/SP.AuditQueries.psm1` (add new query functions)
- `Modules/SP.Audit/SP.AuditReport.psm1` (add new grouping/analytics functions)
- `Modules/SP.Api/SP.Api.psd1` (export new functions)
- `Modules/SP.Audit/SP.Audit.psd1` (export new functions)
- `Modules/SP.Core/SP.Config.psm1` (add search config defaults)
- `Config/settings.json` (add search config section)
- `Scripts/Invoke-SPCampaignSearch.ps1` (NEW script)
- `Tests/SP.CampaignSearch.Tests.ps1` (NEW test file)

---

## ISC API Filter Reference

**Currently used:** `eq` (exact), `sw` (starts-with), `co` (contains), `in` (multiple values)
**Available but unused:** `gt`, `gte`, `lt`, `lte` (comparison), `ne` (not equal), `pr` (exists)
**Campaign fields filterable server-side:** `name`, `status`, `type`
**NOT filterable server-side:** `created`, `deadline`, `completed` (must use client-side)

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| S-01 | Campaign Type Filter | none | DONE |
| S-02 | Date Range Search | none | DONE |
| S-03 | Deadline Analysis | S-02 | DONE |
| S-04 | Reviewer Workload Search | none | DONE |
| S-05 | Identity Decision History | none | DONE |
| S-06 | Campaign Metrics Aggregation | none | DONE |
| S-07 | Source Coverage Analysis | none | DONE |
| S-08 | Campaign Comparison | S-06 | DONE |
| S-09 | Campaign Search CLI | S-01 to S-08 | DONE |
| S-10 | Pester Tests | S-09 | DONE |

---

## S-01: Campaign Type Filter

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
Add campaign type filtering to `Search-SPCampaigns` and `Get-SPAuditCampaigns`.
ISC supports `type eq "MANAGER"` as a server-side filter.

Campaign types: `MANAGER`, `SOURCE_OWNER`, `SEARCH`, `ROLE_COMPOSITION`

**Files to Modify:**
- `Modules/SP.Api/SP.Campaigns.psm1` -- add `-Type` param to `Search-SPCampaigns`
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- add `-CampaignType` param to `Get-SPAuditCampaigns`

**Implementation:**
Add `type eq "MANAGER"` to the server-side filter expression when `-Type` is specified.
Use `[ValidateSet('MANAGER','SOURCE_OWNER','SEARCH','ROLE_COMPOSITION')]`.

**Acceptance Criteria:**
- `Search-SPCampaigns -Keyword "Review" -Type MANAGER` returns only MANAGER campaigns
- `Get-SPAuditCampaigns -CampaignType SOURCE_OWNER` returns only SOURCE_OWNER campaigns
- Omitting `-Type` returns all types (backwards compatible)

---

## S-02: Date Range Search

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
Add `-CreatedAfter` and `-CreatedBefore` parameters (ISO 8601 or DateTime) to
`Get-SPAuditCampaigns`. This supplements the existing `-DaysBack` with precise
date range control.

Client-side filtering (ISC API doesn't support `created` in filters).

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- add params, adjust client-side date filter logic

**Implementation:**
```powershell
# New params alongside existing DaysBack
[Parameter()][DateTime]$CreatedAfter,
[Parameter()][DateTime]$CreatedBefore

# Logic: CreatedAfter/Before take precedence over DaysBack when both specified
if ($CreatedAfter -or $CreatedBefore) {
    # Use explicit range
} else {
    # Fall back to DaysBack calculation (existing behavior)
}
```

**Acceptance Criteria:**
- `-CreatedAfter '2026-01-01' -CreatedBefore '2026-03-31'` returns Q1 campaigns only
- `-DaysBack 30` still works (backwards compatible)
- `-CreatedAfter '2026-01-01' -DaysBack 30` -- CreatedAfter wins, DaysBack ignored
- Dates compared using `.ToUniversalTime()` (UTC fix from CLI testing)

---

## S-03: Deadline Analysis

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** S-02

**Description:**
New function `Get-SPCampaignDeadlineStatus` in SP.Campaigns.psm1 that classifies
campaigns by deadline urgency.

**Classifications:**
- **Overdue**: deadline < now AND status is ACTIVE
- **Critical**: deadline within 24 hours AND status is ACTIVE
- **Warning**: deadline within 72 hours AND status is ACTIVE
- **OnTrack**: deadline > 72 hours away AND status is ACTIVE
- **Completed**: status is COMPLETED
- **NoDeadline**: deadline is null

**Files to Modify:**
- `Modules/SP.Api/SP.Campaigns.psm1` -- new function
- `Modules/SP.Api/SP.Api.psd1` -- export

**Function Signature:**
```powershell
function Get-SPCampaignDeadlineStatus {
    param(
        [Parameter()][string[]]$Status = @('ACTIVE'),
        [Parameter()][int]$DaysBack = 365,
        [Parameter()][string]$CorrelationID
    )
}
```

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        Overdue  = @([campaign objects with DeadlineStatus='Overdue'])
        Critical = @(...)
        Warning  = @(...)
        OnTrack  = @(...)
        Summary  = @{ Overdue=2; Critical=1; Warning=3; OnTrack=10; Completed=50 }
    }
}
```

**Acceptance Criteria:**
- Active campaign with deadline in the past -> classified as Overdue
- Active campaign with deadline in 12 hours -> Critical
- Completed campaigns always show as Completed regardless of deadline

---

## S-04: Reviewer Workload Search

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
New function `Get-SPReviewerWorkload` in SP.AuditQueries.psm1 that finds all
active campaigns/certifications assigned to a specific reviewer identity.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new function
- `Modules/SP.Audit/SP.Audit.psd1` -- export

**Function Signature:**
```powershell
function Get-SPReviewerWorkload {
    param(
        [Parameter(Mandatory)][string]$ReviewerIdentityId,
        [Parameter()][string[]]$Status = @('ACTIVE'),
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Get all campaigns matching status filter
2. For each campaign, get certifications
3. Filter certs where reviewer.id matches ReviewerIdentityId
4. Count: total items, decided items, pending items
5. Return per-campaign workload + totals

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        ReviewerId   = 'id-mgr-001'
        ReviewerName = 'Bob Manager'
        TotalCampaigns     = 3
        TotalItems         = 75
        TotalPending       = 12
        Campaigns = @(
            @{ CampaignId; CampaignName; ItemsAssigned; ItemsDecided; ItemsPending }
        )
    }
}
```

**Acceptance Criteria:**
- Returns only campaigns where the reviewer has active certifications
- Item counts match actual certification data
- Works across multiple campaigns

---

## S-05: Identity Decision History

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
New function `Get-SPIdentityDecisionHistory` in SP.AuditQueries.psm1 that finds
all access review decisions made about a specific identity across all campaigns.

Answers: "What has been decided about Alice Johnson's access in every campaign?"

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new function
- `Modules/SP.Audit/SP.Audit.psd1` -- export

**Function Signature:**
```powershell
function Get-SPIdentityDecisionHistory {
    param(
        [Parameter(Mandatory)][string]$IdentityId,
        [Parameter()][string[]]$Status = @('COMPLETED','ACTIVE'),
        [Parameter()][int]$DaysBack = 365,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Get campaigns matching status + date filters
2. For each campaign, get certifications
3. For each cert, get access review items
4. Filter items where identitySummary.id matches IdentityId
5. Return chronological list of decisions

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        IdentityId   = 'id-001'
        IdentityName = 'Alice Johnson'
        TotalDecisions = 12
        Campaigns = @(
            @{
                CampaignName = 'Q1 Review'
                CampaignDate = '2026-01-15'
                Decisions = @(
                    @{ AccessName; Decision; ReviewerName; DecisionDate }
                )
            }
        )
    }
}
```

**Acceptance Criteria:**
- Returns decisions across multiple campaigns for one identity
- Sorted chronologically (newest first)
- Includes campaign context (name, date) with each decision

---

## S-06: Campaign Metrics Aggregation

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
New function `Measure-SPCampaignMetrics` in SP.AuditReport.psm1 that calculates
comprehensive KPIs for one or more campaigns.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new function
- `Modules/SP.Audit/SP.Audit.psd1` -- export

**Metrics per campaign:**
- Approval rate (%)
- Revocation rate (%)
- Completion rate (%)
- Average reviewer response time (hours)
- Fastest / slowest reviewer
- Reviewer count
- Reassignment count
- Items per reviewer (distribution)
- Deadline compliance (on-time vs overdue)

**Returns:** Array of per-campaign metric objects, usable by S-08 comparison.

**Acceptance Criteria:**
- Metrics calculated correctly against mock data
- Handles campaigns with 0 decisions (no divide-by-zero)
- Compatible with Measure-SPAuditReviewerMetrics (can be composed)

---

## S-07: Source Coverage Analysis

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** none

**Description:**
New function `Get-SPSourceCampaignCoverage` in SP.AuditQueries.psm1 that analyzes
which sources/applications have been covered by campaigns and which haven't.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new function
- `Modules/SP.Audit/SP.Audit.psd1` -- export

**Flow:**
1. Get all sources via `GET /v3/sources` (paginated)
2. Get campaigns matching filters
3. For SOURCE_OWNER campaigns: directly extract sourceIds
4. For other campaigns: check certification items' access.sourceId
5. Build coverage map: source -> campaigns that covered it

**Returns:**
```powershell
@{
    Covered   = @(@{ SourceId; SourceName; LastCampaign; LastCampaignDate; CampaignCount })
    Uncovered = @(@{ SourceId; SourceName; NeverAudited=$true })
    Summary   = @{ TotalSources=10; Covered=8; Uncovered=2; CoverageRate=80 }
}
```

**Acceptance Criteria:**
- Sources with no campaigns show as Uncovered
- Coverage rate calculated correctly
- Works with both SOURCE_OWNER and non-SOURCE_OWNER campaigns

---

## S-08: Campaign Comparison

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** S-06

**Description:**
New function `Compare-SPCampaigns` in SP.AuditReport.psm1 that takes 2+ campaign
IDs and produces a side-by-side comparison of their metrics.

Uses `Measure-SPCampaignMetrics` (S-06) for per-campaign data.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new function + HTML export
- `Modules/SP.Audit/SP.Audit.psd1` -- export

**Output options:**
- PSCustomObject comparison table (default)
- HTML comparison report (`Export-SPCampaignComparisonHtml`)
- CSV export

**Comparison columns:** Campaign Name, Type, Status, Total Items, Approved, Revoked,
Pending, Completion %, Avg Response Time, Reviewer Count, Deadline Status.

**Acceptance Criteria:**
- 2 campaigns compared with correct side-by-side metrics
- HTML report renders with column-per-campaign layout
- Highlights differences (e.g., completion rate delta)

---

## S-09: Campaign Search CLI (Invoke-SPCampaignSearch.ps1)

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** S-01 through S-08

**Description:**
New unified CLI script that combines all search features into one powerful tool.
Supports all filter types, output modes, and can chain with comparison/analysis.

**File to Create:**
- `Scripts/Invoke-SPCampaignSearch.ps1`

**Parameters:**
```powershell
# Filters
-Keyword "text"               # name co "text"
-Type MANAGER                 # campaign type
-Status COMPLETED,ACTIVE      # status filter
-CreatedAfter '2026-01-01'    # date range start
-CreatedBefore '2026-03-31'   # date range end
-DaysBack 90                  # shorthand for CreatedAfter

# Analysis modes
-ShowDeadlines                # include deadline urgency classification
-ShowMetrics                  # include per-campaign KPIs
-ReviewerIdentityId 'id-xxx'  # filter to reviewer's campaigns
-IdentityId 'id-yyy'          # show decision history for identity
-SourceId 'src-zzz'           # show source coverage

# Output
-OutputMode Console|JSON|CSV|HTML
-OutputPath ".\SearchResults"
-CompareIds 'camp-1','camp-2' # side-by-side comparison mode

# Standard
-ConfigPath, -Token, -TokenExpiryMinutes, -Help
```

**Usage examples:**
```powershell
# Find all MANAGER campaigns from Q1
.\Invoke-SPCampaignSearch.ps1 -Type MANAGER -CreatedAfter '2026-01-01' -CreatedBefore '2026-03-31'

# Show deadline urgency for all active campaigns
.\Invoke-SPCampaignSearch.ps1 -Status ACTIVE -ShowDeadlines

# Find all decisions about a specific identity
.\Invoke-SPCampaignSearch.ps1 -IdentityId 'id-001' -Status COMPLETED -DaysBack 365

# Compare two campaigns side-by-side
.\Invoke-SPCampaignSearch.ps1 -CompareIds 'camp-active-001','camp-completed-001' -OutputMode HTML

# Source coverage analysis
.\Invoke-SPCampaignSearch.ps1 -SourceId 'src-ad-001' -ShowMetrics
```

**Acceptance Criteria:**
- All filter params work individually and in combination
- Console output is clean and tabular
- JSON output is machine-parseable
- HTML output uses existing report styling
- Exit codes: 0=success, 1=no results, 2=param error, 3=auth error

---

## S-10: Pester Tests

- **Status:** `DONE`
- **Commit:** (see git log)
- **Depends On:** S-09

**Description:**
Pester tests for all new functions added in S-01 through S-09.

**File to Create:**
- `Tests/SP.CampaignSearch.Tests.ps1`
- `Tests/Import-TestModules.ps1` -- may need update

**Test IDs:**
- CS-01: Search-SPCampaigns with -Type filter returns only matching type
- CS-02: Get-SPAuditCampaigns with -CreatedAfter/-CreatedBefore date range
- CS-03: Get-SPCampaignDeadlineStatus classifies Overdue/Critical/Warning/OnTrack
- CS-04: Get-SPReviewerWorkload returns correct item counts per campaign
- CS-05: Get-SPIdentityDecisionHistory returns decisions across campaigns
- CS-06: Measure-SPCampaignMetrics handles zero-decision campaigns
- CS-07: Get-SPSourceCampaignCoverage identifies uncovered sources
- CS-08: Compare-SPCampaigns produces side-by-side metrics
- CS-09: Invoke-SPCampaignSearch.ps1 syntax validation

---

## Existing Functions to Reuse

| Function | Module | Used By |
|----------|--------|---------|
| `Search-SPCampaigns` | SP.Campaigns | S-01 (extend) |
| `Get-SPAuditCampaigns` | SP.AuditQueries | S-01, S-02 (extend) |
| `Get-SPAuditCertifications` | SP.AuditQueries | S-04, S-05 |
| `Get-SPAuditCertificationItems` | SP.AuditQueries | S-05, S-07 |
| `Measure-SPAuditReviewerMetrics` | SP.AuditReport | S-06 (compose) |
| `Group-SPAuditDecisions` | SP.AuditReport | S-05, S-06 |
| `Get-SPAuditSourceName` | SP.AuditQueries | S-07 (source resolution) |
| `ConvertTo-SafeHtml` | SP.AuditReport | S-08 (HTML export) |
| `Build-HtmlTableRow/Header` | SP.AuditReport | S-08 (HTML tables) |

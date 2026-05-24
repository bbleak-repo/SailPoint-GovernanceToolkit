# Phase 13: Governance Depth & Automation -- Backlog

**Created:** 2026-05-23
**Prereqs:** All Phases 1-12 complete
**Constraint:** NO GUI file changes (Windows GUI testing in progress on W-01 to W-07)

---

## How to Use This File

Agent loop -- same pattern as previous backlogs.

**Serial order:** `P13-01 -> P13-02 -> P13-03 -> P13-04 -> P13-05 -> P13-06 -> P13-07 -> P13-08 -> P13-09 -> P13-10`

---

## GUI Constraint (CRITICAL)

Windows agents are currently testing the GUI. Do NOT modify these files:
- `Gui/*.xaml` (any XAML file)
- `Modules/SP.Gui/SP.MainWindow.psm1`
- `Modules/SP.Gui/SP.GuiBridge.psm1`
- `Modules/SP.Gui/SP.Gui.psd1`
- Any existing CLI scripts in `Scripts/` (being tested)

Safe to modify:
- `Modules/SP.Api/SP.Campaigns.psm1` (add new functions)
- `Modules/SP.Api/SP.ApiClient.psm1` (add new functions)
- `Modules/SP.Api/SP.Api.psd1` (export new functions)
- `Modules/SP.Audit/SP.AuditQueries.psm1` (add new functions)
- `Modules/SP.Audit/SP.AuditReport.psm1` (add new functions)
- `Modules/SP.Audit/SP.Audit.psd1` (export new functions)
- `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` (add new functions)
- `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1` (add new functions)
- `Modules/SP.DeltaCert/SP.DeltaCert.psd1` (export new functions)
- `Modules/SP.Core/SP.Config.psm1` (add config defaults)
- `Config/settings.json` (add new config sections)
- `Scripts/` (NEW scripts only)
- `Tests/` (NEW test files)

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| P13-01 | Access Profile Inventory | none | DONE |
| P13-02 | Role Inventory & Assignment Analysis | P13-01 | PENDING |
| P13-03 | Multi-Source Identity Correlation | none | PENDING |
| P13-04 | Governance Policy Engine | none | PENDING |
| P13-05 | Policy Compliance Report | P13-04 | PENDING |
| P13-06 | Audit Period Comparison | none | PENDING |
| P13-07 | Campaign Planning Calculator | none | PENDING |
| P13-08 | Governance Dashboard Data Export | none | PENDING |
| P13-09 | Invoke-SPGovernanceReport.ps1 | P13-08 | PENDING |
| P13-10 | Pester Tests | P13-09 | PENDING |

---

## Existing Functions to Reuse

| Function | Module | Used By |
|----------|--------|---------|
| `Get-SPConfig` | SP.Config | P13-04, P13-07, P13-08, P13-09 |
| `Invoke-SPApiRequest` | SP.ApiClient | P13-01, P13-02 |
| `Get-SPEntitlementInventory` | SP.AuditQueries | P13-01, P13-02, P13-03, P13-07 |
| `Get-SPAuditCampaigns` | SP.AuditQueries | P13-03, P13-06, P13-07, P13-09 |
| `Get-SPAuditCertifications` | SP.AuditQueries | P13-03, P13-06 |
| `Get-SPAuditCertificationItems` | SP.AuditQueries | P13-03 |
| `Group-SPAuditDecisions` | SP.AuditReport | P13-03, P13-06 |
| `Measure-SPIdentityRisk` | SP.AuditReport | P13-06, P13-08, P13-09 |
| `Measure-SPSourceGovernance` | SP.AuditReport | P13-06, P13-08, P13-09 |
| `Get-SPStaleAccess` | SP.AuditQueries | P13-04, P13-06, P13-08 |
| `Measure-SPCampaignMetrics` | SP.AuditReport | P13-06, P13-07, P13-08 |
| `Measure-SPCampaignTrends` | SP.AuditReport | P13-07, P13-08 |
| `Measure-SPReviewerReputation` | SP.AuditReport | P13-06, P13-08, P13-09 |
| `Get-SPCampaignHealth` | SP.Campaigns | P13-09 |
| `Get-SPRemediationStatus` | SP.AuditQueries | P13-06, P13-08, P13-09 |
| `Get-SPSourceCampaignCoverage` | SP.AuditQueries | P13-04, P13-07 |
| `Send-SPNotification` | SP.AuditReport | P13-09 |
| `Export-SPCompliancePackage` | SP.AuditReport | P13-09 |
| `Get-SPAuditRiskFlags` | SP.AuditReport | P13-03, P13-04 |
| `Build-HtmlTableRow` / `Build-HtmlTableHeader` | SP.AuditReport | P13-01, P13-02, P13-03, P13-05, P13-06 |
| `ConvertTo-SafeHtml` | SP.AuditReport | P13-01, P13-02, P13-03, P13-05, P13-06 |
| `Write-SPLog` | SP.Logging | All |

---

## P13-01: Access Profile Inventory

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Get-SPAccessProfileInventory` in SP.AuditQueries.psm1 that queries ISC
`/v3/access-profiles` to build a per-source catalog of access profiles with their
bundled entitlements. Also new function `Export-SPAccessProfileInventoryHtml` in
SP.AuditReport.psm1 for HTML output.

The toolkit currently operates at the entitlement level (`Get-SPEntitlementInventory`)
but ISC also governs access at the access profile level. Access profiles bundle
entitlements into logical groups (e.g., "Finance Read Access" bundles 5 AD groups).
Production teams need visibility into which access profiles exist, what they bundle,
whether they are requestable, and how they relate to campaign coverage.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPAccessProfileInventory` function
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPAccessProfileInventoryHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPAccessProfileInventory {
    param(
        [Parameter()][string[]]$SourceIds,
        [Parameter()][switch]$IncludeEntitlements,
        [Parameter()][switch]$IncludeReviewHistory,
        [Parameter()][hashtable[]]$CampaignAudits,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Query `GET /v3/access-profiles` for each source ID (paginated, use
   `Invoke-SPApiRequest`). If no SourceIds provided, query all.
   Filter: `source.id eq "{sourceId}"`. Pagination: `limit=250&offset=N`.
2. For each access profile, record: Id, Name, Description, SourceId, SourceName,
   Enabled, Requestable, OwnerName, OwnerId, Created, Modified.
3. If `-IncludeEntitlements`: for each access profile, extract the `entitlements`
   array from the API response. Record entitlement count, names, and privileged flag.
4. If `-IncludeReviewHistory` and `$CampaignAudits` provided: cross-reference access
   profile names and their entitlements against campaign review items. Mark each
   access profile as Reviewed (at least one entitlement reviewed) or Unreviewed.
5. Generate per-source summary: total access profiles, enabled count, requestable
   count, avg entitlements per profile, reviewed count.

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        Sources = @{
            'src-ad-001' = @{
                SourceName           = 'Corporate AD'
                TotalAccessProfiles  = 25
                Enabled              = 22
                Requestable          = 18
                AvgEntitlementsPerProfile = 4.2
                Reviewed             = 20     # (only with -IncludeReviewHistory)
                Unreviewed           = 5
                AccessProfiles = @(
                    @{
                        Id             = 'ap-001'
                        Name           = 'Finance Read Access'
                        Description    = 'Read-only finance share access'
                        Enabled        = $true
                        Requestable    = $true
                        OwnerName      = 'Jane Admin'
                        EntitlementCount = 5
                        Entitlements   = @('AD-SG-FinanceRead', 'AD-SG-SharedDrive')
                        HasPrivileged  = $false
                        Reviewed       = $true
                        LastReviewDate = '2026-04-15'
                    }
                )
            }
        }
        Summary = @{
            TotalSources         = 2
            TotalAccessProfiles  = 48
            TotalEnabled         = 42
            TotalRequestable     = 35
            ReviewCoverage       = 83.3   # % reviewed (with -IncludeReviewHistory)
        }
    }
}
```

New function `Export-SPAccessProfileInventoryHtml`:
- Per-source sections with access profile tables
- Entitlement bundle detail (expandable rows when -IncludeEntitlements)
- Unreviewed access profiles highlighted in orange
- Access profiles containing privileged entitlements highlighted in red
- Summary card with counts and coverage percentage

**Acceptance Criteria:**
- Paginated query handles >250 access profiles per source
- Without `-IncludeEntitlements`, EntitlementCount is populated from API but
  individual entitlement names are not (saves API calls)
- Without `-IncludeReviewHistory`, Reviewed field is null
- With `-IncludeReviewHistory` but no `$CampaignAudits`, returns warning and skips
  review history enrichment
- Empty source (no access profiles) shows "No access profiles found" (not error)
- HTML report groups access profiles by source with sortable columns

**Tests:** P13-T01, P13-T02

---

## P13-02: Role Inventory & Assignment Analysis

- **Status:** `PENDING`
- **Depends On:** P13-01

**Description:**
New function `Get-SPRoleInventory` in SP.AuditQueries.psm1 that queries ISC
`/v3/roles` to catalog roles with their access profile mappings, membership type,
and assignment metrics. Also new function `Export-SPRoleInventoryHtml` in
SP.AuditReport.psm1 for HTML output.

ISC roles are the top-level access container: Role -> Access Profiles -> Entitlements.
A role can be assigned via STANDARD membership (criteria-based, auto-assigned) or
IDENTITY_LIST (manually assigned). Production governance teams need to understand:
- How many roles exist and how many identities each covers
- Which roles bundle which access profiles (and transitively, which entitlements)
- Role sprawl indicators: roles with 0 members, roles with 1 access profile,
  duplicate roles covering the same access profiles

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPRoleInventory` function
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPRoleInventoryHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPRoleInventory {
    param(
        [Parameter()][switch]$IncludeAccessProfiles,
        [Parameter()][hashtable]$AccessProfileInventory,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Query `GET /v3/roles` (paginated, `limit=50&offset=N`). ISC default limit for
   roles is 50.
2. For each role, record: Id, Name, Description, Enabled, Requestable, OwnerName,
   OwnerId, MembershipType (STANDARD or IDENTITY_LIST), Created, Modified.
3. Extract `accessProfiles` array from each role: record count and names.
4. If `-IncludeAccessProfiles` and `$AccessProfileInventory` provided: cross-reference
   to enrich each role with transitive entitlement count (sum of entitlements across
   all access profiles in the role).
5. Calculate role health indicators:
   - **EmptyRoles**: Roles with 0 access profiles
   - **SingleProfileRoles**: Roles with exactly 1 access profile (potential over-wrapping)
   - **DisabledRoles**: Roles that are disabled but still exist
   - **OwnerlessRoles**: Roles with no owner assigned

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        Roles = @(
            @{
                Id                    = 'role-001'
                Name                  = 'Finance Analyst'
                Description           = 'Standard finance team access'
                Enabled               = $true
                Requestable           = $true
                OwnerName             = 'Jane Admin'
                MembershipType        = 'STANDARD'
                AccessProfileCount    = 3
                AccessProfileNames    = @('Finance Read', 'Shared Drive', 'SAP View')
                TransitiveEntitlements = 12   # (only with -IncludeAccessProfiles)
                Created               = '2025-06-01'
                Modified              = '2026-03-15'
            }
        )
        Summary = @{
            TotalRoles            = 15
            Enabled               = 12
            Disabled              = 3
            Requestable           = 10
            StandardMembership    = 8
            IdentityListMembership = 7
            AvgAccessProfilesPerRole = 2.8
            EmptyRoles            = 1
            SingleProfileRoles    = 4
            OwnerlessRoles        = 0
        }
        HealthIndicators = @{
            EmptyRoles       = @('Deprecated Legacy Role')
            DisabledRoles    = @('Old Contractor Role', 'Test Role', 'Migration Temp')
            OwnerlessRoles   = @()
            SingleProfileRoles = @('Simple Read', 'Basic User', 'Guest', 'Temp Access')
        }
    }
}
```

New function `Export-SPRoleInventoryHtml`:
- Role table with access profile count, membership type, enabled/requestable badges
- Health indicator section highlighting empty, disabled, and ownerless roles
- Per-role expandable detail showing access profile list (and transitive entitlements
  if enriched)
- Summary card with role sprawl indicators

**Acceptance Criteria:**
- Paginated query handles >50 roles
- Empty roles (0 access profiles) flagged in HealthIndicators
- Disabled roles flagged in HealthIndicators
- Without `-IncludeAccessProfiles`, TransitiveEntitlements field is null
- With `-IncludeAccessProfiles` but no `$AccessProfileInventory`, returns warning
  and skips enrichment
- HTML report renders with sortable columns and expandable access profile details
- Empty role list returns empty summary (not error)

**Tests:** P13-T03, P13-T04

---

## P13-03: Multi-Source Identity Correlation

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Get-SPIdentityAccessSpread` in SP.AuditReport.psm1 that analyzes
campaign audit data to identify identities with access spanning multiple sources.
Also new function `Export-SPIdentityAccessSpreadHtml` for HTML output.

Answers: "Which identities have the broadest access footprint across our environment?
Who has accounts on 5+ sources? Where is privilege concentrated?"

Currently the toolkit analyzes risk per identity (`Measure-SPIdentityRisk`) and
coverage per source (`Measure-SPSourceGovernance`), but neither shows the cross-source
view. An identity with low risk flags on each individual source may still represent
high aggregate risk if they hold access across 8 sources including both production
databases and cloud admin consoles.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Get-SPIdentityAccessSpread` and
  `Export-SPIdentityAccessSpreadHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPIdentityAccessSpread {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][int]$MinSources = 3,
        [Parameter()][switch]$PrivilegedOnly,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Iterate all campaign audit data. For each decision item, extract:
   IdentityId, IdentityName, SourceId, SourceName, EntitlementName, Privileged flag,
   Decision (Approved/Revoked).
2. Build per-identity map: for each identity, accumulate the set of unique sources
   they hold access on, plus per-source detail (entitlement count, privileged count,
   last review date).
3. Filter to identities with >= `$MinSources` unique sources.
4. If `-PrivilegedOnly`, only count sources where the identity holds at least one
   privileged entitlement.
5. Calculate concentration metrics:
   - **SourceCount**: Number of unique sources this identity has access on
   - **TotalEntitlements**: Total entitlements across all sources
   - **PrivilegedEntitlements**: Total privileged entitlements across all sources
   - **ApprovalOnlyFlag**: True if this identity has never had access revoked
   - **BroadestSource**: Source with the most entitlements for this identity
6. Sort by SourceCount descending, then by PrivilegedEntitlements descending.

**Returns:**
```powershell
@{
    Identities = @(
        @{
            IdentityId              = 'id-001'
            IdentityName            = 'Bob ServiceAcct'
            SourceCount             = 6
            TotalEntitlements       = 42
            PrivilegedEntitlements  = 8
            ApprovalOnlyFlag        = $true
            BroadestSource          = 'Corporate AD'
            Sources = @(
                @{
                    SourceId         = 'src-ad-001'
                    SourceName       = 'Corporate AD'
                    EntitlementCount = 15
                    PrivilegedCount  = 3
                    LastReviewDate   = '2026-05-01'
                }
            )
        }
    )
    Summary = @{
        TotalIdentitiesAnalyzed = 200
        IdentitiesAboveThreshold = 12
        AvgSourceCount           = 4.2
        MaxSourceCount           = 8
        IdentitiesWithPrivilegedSpread = 5   # privileged on 2+ sources
    }
}
```

New function `Export-SPIdentityAccessSpreadHtml`:
- Per-identity card with source count badge (color-coded: green <3, yellow 3-5, red 6+)
- Expandable source detail table per identity
- Privileged entitlements highlighted in red across all sources
- Summary card with spread distribution histogram
- ApprovalOnlyFlag marked with warning icon

**Acceptance Criteria:**
- Identity with access on 6 sources and MinSources=3 is included
- Identity with access on 2 sources and MinSources=3 is excluded
- `-PrivilegedOnly` counts only sources with privileged entitlements
- ApprovalOnlyFlag correctly identifies identities never revoked across all campaigns
- Empty campaign audit input returns empty summary (not error)
- Sorting is stable: SourceCount first, then PrivilegedEntitlements

**Tests:** P13-T05, P13-T06

---

## P13-04: Governance Policy Engine

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Test-SPGovernancePolicy` in SP.AuditReport.psm1 that evaluates the
current governance state against a set of configurable policies. Also new config
section `GovernancePolicy` in settings.json.

Answers: "Are we meeting our governance commitments? Which policies are failing?"

Production ISC deployments have governance obligations: "all privileged access reviewed
quarterly," "all sources at 75%+ entitlement coverage," "no identity with risk score
above 80 for more than 30 days." Currently these checks are manual -- an operator runs
various analytics functions and eyeballs the results. This function codifies the
checks and produces a pass/fail result per policy.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Test-SPGovernancePolicy` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function
- `Config/settings.json` -- add `GovernancePolicy` section
- `Modules/SP.Core/SP.Config.psm1` -- add GovernancePolicy defaults

**Config section:**
```json
"GovernancePolicy": {
    "Enabled": true,
    "Policies": [
        {
            "Id": "POL-001",
            "Name": "Privileged Access Review Frequency",
            "Description": "All privileged entitlements must be reviewed within 90 days",
            "Type": "ReviewFrequency",
            "Scope": "Privileged",
            "MaxDaysSinceReview": 90,
            "Severity": "Critical"
        },
        {
            "Id": "POL-002",
            "Name": "Source Coverage Minimum",
            "Description": "All sources must have at least 75% entitlement review coverage",
            "Type": "SourceCoverage",
            "MinCoveragePercent": 75,
            "Severity": "Warning"
        },
        {
            "Id": "POL-003",
            "Name": "Identity Risk Ceiling",
            "Description": "No identity should remain at High risk for more than 30 days",
            "Type": "IdentityRisk",
            "MaxRiskScore": 70,
            "Severity": "Critical"
        },
        {
            "Id": "POL-004",
            "Name": "Stale Access Limit",
            "Description": "No more than 10% of entitlements should be classified as stale",
            "Type": "StaleAccess",
            "MaxStalePercent": 10,
            "Severity": "Warning"
        },
        {
            "Id": "POL-005",
            "Name": "Reviewer Performance Floor",
            "Description": "No reviewer should have a reputation score below 40",
            "Type": "ReviewerPerformance",
            "MinReputationScore": 40,
            "Severity": "Warning"
        }
    ]
}
```

**Function Signature:**
```powershell
function Test-SPGovernancePolicy {
    param(
        [Parameter()][hashtable[]]$CampaignAudits,
        [Parameter()][hashtable]$IdentityRisk,
        [Parameter()][hashtable]$SourceGovernance,
        [Parameter()][hashtable]$StaleAccess,
        [Parameter()][hashtable]$ReviewerReputation,
        [Parameter()][hashtable]$EntitlementInventory,
        [Parameter()][string]$CorrelationID
    )
}
```

**Policy types and evaluation logic:**

1. **ReviewFrequency**: Check `$StaleAccess` or `$EntitlementInventory` for entitlements
   matching `Scope` (Privileged/All) not reviewed within `MaxDaysSinceReview`. PASS if
   all matching entitlements are within window. FAIL if any are overdue.

2. **SourceCoverage**: Check `$SourceGovernance.Sources` for sources below
   `MinCoveragePercent`. PASS if all sources meet threshold. FAIL with list of
   non-compliant sources.

3. **IdentityRisk**: Check `$IdentityRisk.Identities` for identities above
   `MaxRiskScore`. PASS if none exceed. FAIL with list of high-risk identities.

4. **StaleAccess**: Check `$StaleAccess.Summary.TotalStaleItems` against total
   entitlement count. PASS if stale percentage is below `MaxStalePercent`. FAIL with
   actual percentage.

5. **ReviewerPerformance**: Check `$ReviewerReputation.Reviewers` for reviewers below
   `MinReputationScore`. PASS if all reviewers meet threshold. FAIL with list of
   underperforming reviewers.

**Returns:**
```powershell
@{
    OverallCompliant = $false
    EvaluatedAt      = '2026-05-23T12:00:00Z'
    Policies = @(
        @{
            Id          = 'POL-001'
            Name        = 'Privileged Access Review Frequency'
            Severity    = 'Critical'
            Result      = 'FAIL'
            Details     = '3 privileged entitlements not reviewed within 90 days'
            Violations  = @(
                @{ Item = 'AD-SG-DomainAdmins'; Source = 'Corporate AD'; DaysSinceReview = 145 }
            )
        },
        @{
            Id          = 'POL-002'
            Name        = 'Source Coverage Minimum'
            Severity    = 'Warning'
            Result      = 'PASS'
            Details     = 'All 3 sources above 75% coverage'
            Violations  = @()
        }
    )
    Summary = @{
        TotalPolicies    = 5
        Passed           = 3
        Failed           = 2
        CriticalFailures = 1
        WarningFailures  = 1
        Skipped          = 0     # policies where required input data was null
    }
}
```

**Acceptance Criteria:**
- Policy with `Type=ReviewFrequency` and Scope=Privileged checks only privileged entitlements
- Policy with `Type=SourceCoverage` and MinCoveragePercent=75 fails for source at 60%
- Policy with missing required input data (e.g., IdentityRisk is null for IdentityRisk policy)
  produces Result='SKIPPED' with explanatory Details (not error)
- `GovernancePolicy.Enabled = false` returns early with all policies skipped
- OverallCompliant is true only when zero policies have Result='FAIL'
- Policies array is sorted: FAIL first (Critical before Warning), then PASS, then SKIPPED
- Empty Policies config array returns empty summary (not error)

**Tests:** P13-T07, P13-T08

---

## P13-05: Policy Compliance Report

- **Status:** `PENDING`
- **Depends On:** P13-04

**Description:**
New function `Export-SPPolicyComplianceHtml` in SP.AuditReport.psm1 that generates
an HTML compliance dashboard from `Test-SPGovernancePolicy` output.

This is the artifact that governance leadership reviews weekly or monthly to confirm
the organization is meeting its access governance commitments. Designed for attachment
to compliance evidence packages (P12-01) and weekly digests (P12-08).

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPPolicyComplianceHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Export-SPPolicyComplianceHtml {
    param(
        [Parameter(Mandatory)][hashtable]$PolicyResults,
        [Parameter()][hashtable]$PreviousPolicyResults,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter()][string]$CorrelationID
    )
}
```

**Report sections:**

1. **Compliance header**: Overall compliance status badge (COMPLIANT green /
   NON-COMPLIANT red), evaluation timestamp, policy count.

2. **Summary dashboard**: Pass/Fail/Skipped counts. Critical vs Warning breakdown.
   If `$PreviousPolicyResults` provided, show delta (policies that changed status
   since last evaluation).

3. **Policy detail table**: One row per policy with:
   - Status badge (PASS green / FAIL red / SKIPPED gray)
   - Severity badge (Critical red / Warning orange)
   - Policy name and description
   - Detail text explaining the result
   - Violation count (if any)

4. **Violation drill-down**: For each FAIL policy, expandable section listing
   every violation with item name, source, and metric value.

5. **Trend section** (if `$PreviousPolicyResults` provided):
   - Policies that improved (FAIL -> PASS)
   - Policies that regressed (PASS -> FAIL)
   - Stable policies

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        ReportPath = 'Audit/policy-compliance-2026-05-23.html'
        OverallCompliant = $false
        Passed  = 3
        Failed  = 2
        Skipped = 0
    }
}
```

**Acceptance Criteria:**
- Overall COMPLIANT badge shown only when all policies pass
- Without `$PreviousPolicyResults`, trend section shows "No prior evaluation data"
- FAIL policies rendered before PASS policies in the table
- Violation drill-down sections are collapsible (HTML details/summary elements)
- HTML uses same styling conventions as existing audit reports
- File naming: `policy-compliance-{date}.html`

**Tests:** P13-T09

---

## P13-06: Audit Period Comparison

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Compare-SPAuditPeriods` in SP.AuditReport.psm1 that compares two
time windows across all governance dimensions and produces a structured diff. Also
new function `Export-SPAuditPeriodComparisonHtml` for HTML output.

Answers: "How did our governance posture change between Q1 and Q2?" or "What improved
since last month?"

Unlike `Measure-SPCampaignTrends` (which shows time-series trends across campaign
cycles), this function does a direct side-by-side comparison of two defined periods
across multiple dimensions: campaign metrics, identity risk distribution, source
governance grades, reviewer reputation, and remediation performance.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Compare-SPAuditPeriods` and
  `Export-SPAuditPeriodComparisonHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Compare-SPAuditPeriods {
    param(
        [Parameter(Mandatory)][hashtable]$PeriodA,
        [Parameter(Mandatory)][hashtable]$PeriodB,
        [Parameter()][string]$CorrelationID
    )
}
```

**Input format:** Each period is a hashtable containing pre-computed analytics output:
```powershell
@{
    Label              = 'Q1 2026'
    DateRange          = @{ After = '2026-01-01'; Before = '2026-03-31' }
    CampaignMetrics    = $campaignMetricsOutput     # from Measure-SPCampaignMetrics
    IdentityRisk       = $identityRiskOutput        # from Measure-SPIdentityRisk
    SourceGovernance   = $sourceGovernanceOutput    # from Measure-SPSourceGovernance
    ReviewerReputation = $reviewerReputationOutput  # from Measure-SPReviewerReputation
    StaleAccess        = $staleAccessOutput         # from Get-SPStaleAccess
    RemediationStatus  = $remediationStatusOutput   # from Get-SPRemediationStatus (optional)
}
```

**Comparison dimensions:**

1. **Campaign metrics delta**: Change in total campaigns, approval rate, revocation
   rate, avg reviewer response time, completion rate.
2. **Identity risk delta**: Change in High/Medium/Low distribution, change in avg
   risk score, new High-risk identities in Period B not in Period A.
3. **Source governance delta**: Change in per-source governance grade, change in
   overall coverage percentage.
4. **Reviewer reputation delta**: Change in per-reviewer reputation score, new
   At-Risk reviewers in Period B, reviewers who improved tier.
5. **Stale access delta**: Change in total stale items, change in NeverReviewed count.
6. **Remediation delta**: Change in SLA compliance rate, change in avg days to
   remediate.

**Direction classification:**
- **Improved**: Metric moved in the governance-positive direction
- **Degraded**: Metric moved in the governance-negative direction
- **Stable**: Change within +/- 2% threshold

**Returns:**
```powershell
@{
    PeriodA = @{ Label = 'Q1 2026'; DateRange = @{...} }
    PeriodB = @{ Label = 'Q2 2026'; DateRange = @{...} }
    Dimensions = @{
        CampaignMetrics = @{
            ApprovalRate   = @{ A = 85.0; B = 82.0; Delta = -3.0; Direction = 'Stable' }
            RevocationRate = @{ A = 12.0; B = 15.0; Delta = +3.0; Direction = 'Improved' }
            AvgResponseHrs = @{ A = 18.5; B = 14.2; Delta = -4.3; Direction = 'Improved' }
        }
        IdentityRisk = @{
            HighCount      = @{ A = 5; B = 3; Delta = -2; Direction = 'Improved' }
            AvgRiskScore   = @{ A = 32.0; B = 28.5; Delta = -3.5; Direction = 'Improved' }
            NewHighRisk    = @('Identity-X')   # in B but not in A at High tier
        }
        SourceGovernance = @{
            OverallCoverage = @{ A = 72.5; B = 78.5; Delta = +6.0; Direction = 'Improved' }
            GradeChanges    = @(
                @{ Source = 'Corporate AD'; GradeA = 'C'; GradeB = 'B'; Direction = 'Improved' }
            )
        }
        ReviewerReputation = @{
            AvgScore       = @{ A = 65.0; B = 68.5; Delta = +3.5; Direction = 'Improved' }
            NewAtRisk      = @()
            TierImprovements = @('Dave Admin: At Risk -> Needs Attention')
        }
        StaleAccess = @{
            TotalStale     = @{ A = 30; B = 22; Delta = -8; Direction = 'Improved' }
            NeverReviewed  = @{ A = 12; B = 8; Delta = -4; Direction = 'Improved' }
        }
        Remediation = @{
            SlaCompliance  = @{ A = 82.0; B = 87.0; Delta = +5.0; Direction = 'Improved' }
        }
    }
    OverallDirection = 'Improved'   # majority of dimensions
    Summary = @{
        Improved = 8
        Degraded = 0
        Stable   = 2
    }
}
```

New function `Export-SPAuditPeriodComparisonHtml`:
- Side-by-side layout with Period A on left, Period B on right
- Delta column with directional arrows and color coding (green/red/gray)
- Per-dimension sections with detail tables
- Overall governance direction badge at the top
- New High-risk identities and At-Risk reviewers called out in highlight boxes

**Acceptance Criteria:**
- Decreasing approval rate by 1% classified as 'Stable' (within 2% threshold)
- Decreasing avg response hours classified as 'Improved' (faster is better)
- Increasing revocation rate classified as 'Improved' (more revocations = more
  governance enforcement, by convention)
- Dimensions with null input data on one side produce 'N/A' (not error)
- OverallDirection is majority vote across all non-N/A dimensions
- Empty periods (no data in either) returns summary with all N/A

**Tests:** P13-T10, P13-T11

---

## P13-07: Campaign Planning Calculator

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Get-SPCampaignForecast` in SP.AuditReport.psm1 that estimates the
effort, scope, and timeline for a planned future campaign based on historical campaign
data, current entitlement inventory, and reviewer capacity.

Answers: "If we run a quarterly access review next month, how many items will
reviewers need to process? How many reviewer-hours will it take? When should we
set the deadline?"

Currently campaign planning is guesswork. This function uses historical patterns
(items per identity, reviewer throughput, completion velocity) and current state
(entitlement inventory, identity count per source) to produce an evidence-based
forecast.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Get-SPCampaignForecast` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Get-SPCampaignForecast {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][hashtable]$EntitlementInventory,
        [Parameter()][string[]]$SourceIds,
        [Parameter()][string]$CampaignType = 'MANAGER',
        [Parameter()][int]$ReviewerCount,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. From `$CampaignAudits`, calculate historical averages:
   - Avg items per campaign (filtered to matching CampaignType if available)
   - Avg items per reviewer
   - Avg reviewer response hours (from `Measure-SPAuditReviewerMetrics`)
   - Avg campaign duration days (creation to completion)
   - Historical approval rate and revocation rate
2. From `$EntitlementInventory` (if provided), estimate scope:
   - Total entitlements across specified SourceIds
   - Total identities holding entitlements (estimated from item count patterns)
   - Privileged entitlement count (for effort weighting)
3. Calculate forecast:
   - **EstimatedItems**: Based on entitlement inventory count, or extrapolated from
     historical items per source
   - **EstimatedReviewerHours**: EstimatedItems * AvgHoursPerItem (from history)
   - **RecommendedDeadlineDays**: Based on historical duration + 20% buffer
   - **RecommendedReviewerCount**: If not specified, calculate from EstimatedItems /
     AvgItemsPerReviewer
   - **ProjectedApprovalRate**: Historical average
   - **ProjectedRevocations**: EstimatedItems * (1 - ProjectedApprovalRate)
   - **ConfidenceLevel**: High (5+ historical campaigns) / Medium (2-4) / Low (0-1)

**Returns:**
```powershell
@{
    Forecast = @{
        CampaignType             = 'MANAGER'
        SourceIds                = @('src-ad-001', 'src-entra-001')
        EstimatedItems           = 280
        EstimatedReviewerHours   = 35.0
        RecommendedDeadlineDays  = 14
        RecommendedReviewerCount = 5
        ProjectedApprovalRate    = 83.0
        ProjectedRevocations     = 48
        ConfidenceLevel          = 'High'
    }
    HistoricalBasis = @{
        CampaignsAnalyzed     = 8
        AvgItemsPerCampaign   = 245
        AvgHoursPerItem       = 0.125
        AvgDurationDays       = 11
        AvgItemsPerReviewer   = 55
        AvgApprovalRate       = 83.0
    }
    Caveats = @(
        'Forecast based on 8 historical MANAGER campaigns'
        'Entitlement inventory not provided -- using historical extrapolation'
    )
}
```

**Acceptance Criteria:**
- With 0 historical campaigns, ConfidenceLevel = 'Low' and forecast uses safe
  defaults (30 items/reviewer, 14 day deadline, 80% approval rate)
- With 5+ historical campaigns, ConfidenceLevel = 'High'
- RecommendedDeadlineDays includes 20% buffer over historical average
- When `$EntitlementInventory` provided, EstimatedItems derived from entitlement count
  rather than historical extrapolation
- When `$ReviewerCount` specified, that value used instead of calculated recommendation
- Caveats array includes notes about data quality and assumptions
- Empty CampaignAudits returns low-confidence forecast with defaults (not error)

**Tests:** P13-T12, P13-T13

---

## P13-08: Governance Dashboard Data Export

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Export-SPGovernanceDashboardData` in SP.AuditReport.psm1 that produces
a unified JSON and CSV dataset combining all governance analytics into a single
BI-tool-ready export. Designed for import into Power BI, Tableau, Splunk dashboards,
or any tool that consumes structured data.

Currently each analytics function returns its own data structure. To build a dashboard
in Power BI, an analyst would need to run 8+ functions and manually join the results.
This function pre-joins and normalizes the data into dimensional tables suitable for
BI consumption.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPGovernanceDashboardData`
  function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Export-SPGovernanceDashboardData {
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter()][hashtable[]]$CampaignAudits,
        [Parameter()][hashtable]$IdentityRisk,
        [Parameter()][hashtable]$SourceGovernance,
        [Parameter()][hashtable]$ReviewerReputation,
        [Parameter()][hashtable]$StaleAccess,
        [Parameter()][hashtable]$CampaignTrends,
        [Parameter()][hashtable]$PolicyCompliance,
        [Parameter()][ValidateSet('JSON','CSV','Both')]
        [string]$Format = 'Both',
        [Parameter()][string]$CorrelationID
    )
}
```

**Output files:**

1. **`dashboard-campaigns.csv`** -- One row per campaign
   Columns: CampaignId, CampaignName, CampaignType, Status, StartDate, EndDate,
   TotalItems, ApprovedCount, RevokedCount, PendingCount, ApprovalRate, RevocationRate,
   CompletionRate, ReviewerCount, AvgResponseHours, OnTimeCompletion

2. **`dashboard-identities.csv`** -- One row per identity with risk data
   Columns: IdentityId, IdentityName, RiskScore, RiskTier, StaleAccessCount,
   PrivilegedAccessCount, RubberStampApprovals, OrphanAccountFlag, SourceCount,
   TotalEntitlements, CampaignsReviewed, LastReviewDate

3. **`dashboard-sources.csv`** -- One row per source with governance data
   Columns: SourceId, SourceName, GovernanceGrade, GovernanceScore, TotalEntitlements,
   ReviewedEntitlements, EntitlementCoveragePct, PrivilegedEntitlements,
   PrivilegedReviewedPct, CampaignCount, DaysSinceLastReview

4. **`dashboard-reviewers.csv`** -- One row per reviewer with reputation data
   Columns: ReviewerName, ReviewerIdentityId, ReputationScore, ReputationTier,
   CampaignsParticipated, TotalItemsReviewed, AvgResponseHours, LifetimeApprovalRate,
   RubberStampCount, EscalationCount

5. **`dashboard-policies.csv`** -- One row per governance policy
   Columns: PolicyId, PolicyName, Severity, Result, ViolationCount, Details,
   EvaluatedAt

6. **`dashboard-summary.json`** -- Single JSON file with top-level KPIs
   ```json
   {
       "generatedAt": "2026-05-23T12:00:00Z",
       "kpis": {
           "totalCampaigns": 12,
           "activeCampaigns": 4,
           "avgApprovalRate": 83.0,
           "highRiskIdentities": 5,
           "avgGovernanceScore": 71.2,
           "staleAccessItems": 22,
           "policyComplianceRate": 60.0,
           "avgReviewerScore": 68.5
       },
       "dataSources": {
           "campaigns": "dashboard-campaigns.csv",
           "identities": "dashboard-identities.csv",
           "sources": "dashboard-sources.csv",
           "reviewers": "dashboard-reviewers.csv",
           "policies": "dashboard-policies.csv"
       }
   }
   ```

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        OutputPath     = 'Audit/dashboard/'
        FilesGenerated = @(
            'dashboard-campaigns.csv',
            'dashboard-identities.csv',
            'dashboard-sources.csv',
            'dashboard-reviewers.csv',
            'dashboard-policies.csv',
            'dashboard-summary.json'
        )
        RecordCounts = @{
            Campaigns  = 12
            Identities = 200
            Sources    = 3
            Reviewers  = 15
            Policies   = 5
        }
    }
}
```

**Acceptance Criteria:**
- CSV files use UTF-8 encoding without BOM, compatible with Excel and Power BI
- Date columns in ISO 8601 format
- Null analytics inputs (e.g., no IdentityRisk) produce an empty CSV with headers
  only (not missing file)
- `-Format JSON` produces JSON array files instead of CSVs (except summary which
  is always JSON)
- `-Format CSV` produces CSVs and summary JSON
- `-Format Both` produces both JSON arrays and CSVs
- All files written to `{OutputPath}/dashboard/` subdirectory
- dashboard-summary.json includes file cross-references for BI tool data loading

**Tests:** P13-T14, P13-T15

---

## P13-09: Invoke-SPGovernanceReport.ps1

- **Status:** `PENDING`
- **Depends On:** P13-08

**Description:**
New CLI script `Scripts/Invoke-SPGovernanceReport.ps1` that generates a comprehensive
governance report covering all dimensions in one invocation. Designed as the "run
everything" command for governance teams who want a full picture without running
individual analytics functions.

This script orchestrates: campaign audit collection, identity risk scoring, source
governance grading, stale access detection, reviewer reputation analysis, policy
compliance checking, and dashboard data export. It produces HTML reports for each
dimension plus the unified dashboard export.

**File to Create:**
- `Scripts/Invoke-SPGovernanceReport.ps1`

**Parameters:**
```powershell
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,
    [Parameter()][string[]]$SourceId,
    [Parameter()][int]$DaysBack = 90,

    # Section toggles
    [Parameter()][switch]$SkipIdentityRisk,
    [Parameter()][switch]$SkipSourceGovernance,
    [Parameter()][switch]$SkipStaleAccess,
    [Parameter()][switch]$SkipReviewerAnalysis,
    [Parameter()][switch]$SkipPolicyCheck,
    [Parameter()][switch]$SkipDashboardExport,

    # Output
    [Parameter()][ValidateSet('Console','HTML','JSON','All')]
    [string]$OutputMode = 'Console',
    [Parameter()][string]$OutputPath,

    # Notification
    [Parameter()][switch]$SendNotification,
    [Parameter()][string[]]$NotifyRecipients,

    # Compliance
    [Parameter()][switch]$BundleCompliancePackage,

    [Parameter()][switch]$Help,
    [Parameter()][switch]$WhatIf
)
```

**Execution steps:**

```
Step 1: Configuration & Authentication
  -> Load config, validate with Test-SPConfiguration
  -> Acquire token (browser token or OAuth)

Step 2: Campaign Data Collection
  -> Get-SPAuditCampaigns -DaysBack $DaysBack
  -> For each campaign: Get-SPAuditCampaignReport (with caching)
  -> Measure-SPCampaignMetrics on collected data

Step 3: Entitlement Inventory (if SourceIds provided)
  -> Get-SPEntitlementInventory -SourceIds $SourceId -IncludeReviewHistory

Step 4: Analytics (parallel-safe, each independent)
  4a: Measure-SPIdentityRisk (unless -SkipIdentityRisk)
  4b: Measure-SPSourceGovernance (unless -SkipSourceGovernance)
  4c: Get-SPStaleAccess (unless -SkipStaleAccess)
  4d: Measure-SPReviewerReputation (unless -SkipReviewerAnalysis)

Step 5: Policy Compliance (unless -SkipPolicyCheck)
  -> Test-SPGovernancePolicy with all analytics results

Step 6: Report Generation
  -> Console: summary table of all dimensions
  -> HTML: per-dimension HTML reports + policy compliance report
  -> JSON: structured JSON output
  -> All: everything

Step 7: Dashboard Export (unless -SkipDashboardExport)
  -> Export-SPGovernanceDashboardData with all analytics results

Step 8: Compliance Package (if -BundleCompliancePackage)
  -> Export-SPCompliancePackage bundling all generated reports

Step 9: Notification (if -SendNotification)
  -> Send-SPNotification with report summary and attachments
```

**Console output:**
```
=== Comprehensive Governance Report ===
Period:            2026-02-23 to 2026-05-23 (90 days)
Generated:         2026-05-23T12:00:00Z
Sources:           src-ad-001, src-entra-001

--- Campaign Activity ---
  Campaigns: 12 | Items Reviewed: 1,450 | Approval Rate: 83%

--- Identity Risk ---
  High: 5 | Medium: 12 | Low: 183 | Avg Score: 28.5

--- Source Governance ---
  Corporate AD: B (82.3) | Cloud Entra: A (91.5) | Legacy App: D (42.0)

--- Stale Access ---
  Total Stale: 22 | Never Reviewed: 8 | Privileged Stale: 2

--- Reviewer Performance ---
  Avg Score: 68.5 | At Risk: 1 (Dave Admin) | Excellent: 5

--- Policy Compliance ---
  PASS: 3/5 | FAIL: 2 (POL-001 Critical, POL-004 Warning)

--- Dashboard Export ---
  5 CSV files + summary JSON written to Audit/dashboard/

Result: COMPLETED (2 policy violations)
```

**Exit codes:**
- 0 = Report generated successfully, all policies passed
- 1 = Report generated, one or more non-critical policy failures
- 2 = Parameter error
- 3 = Authentication error
- 4 = Configuration error
- 5 = Critical data collection failure (no campaigns found)

**Acceptance Criteria:**
- All 9 steps execute in order with proper error isolation
- Step failure does not prevent subsequent steps from running
- Section skip switches exclude the corresponding analytics + report
- `-OutputMode HTML` produces per-dimension HTML files in OutputPath
- `-OutputMode All` produces console + HTML + JSON + dashboard export
- `-WhatIf` shows what would be generated without API calls
- `-BundleCompliancePackage` creates ZIP with all generated reports
- `-SendNotification` triggers notification dispatch if configured
- Console output is concise and scannable
- Works with both `-Token` and configured OAuth

**Tests:** P13-T16

---

## P13-10: Pester Tests

- **Status:** `PENDING`
- **Depends On:** P13-09

**Description:**
Pester tests for all new functions added in P13-01 through P13-09.

**File to Create:**
- `Tests/SP.GovernanceDepth.Tests.ps1`

**Test IDs:**

- P13-T01: Get-SPAccessProfileInventory returns access profiles with correct entitlement counts
- P13-T02: Get-SPAccessProfileInventory handles paginated responses (>250 profiles)
- P13-T03: Get-SPRoleInventory identifies empty roles in HealthIndicators
- P13-T04: Get-SPRoleInventory returns empty summary for empty role list
- P13-T05: Get-SPIdentityAccessSpread filters by MinSources threshold correctly
- P13-T06: Get-SPIdentityAccessSpread with PrivilegedOnly counts only privileged sources
- P13-T07: Test-SPGovernancePolicy returns FAIL for source below MinCoveragePercent
- P13-T08: Test-SPGovernancePolicy returns SKIPPED when required input is null
- P13-T09: Export-SPPolicyComplianceHtml generates HTML with correct status badges
- P13-T10: Compare-SPAuditPeriods classifies decreasing response hours as Improved
- P13-T11: Compare-SPAuditPeriods classifies 1% approval rate change as Stable
- P13-T12: Get-SPCampaignForecast returns Low confidence with 0 historical campaigns
- P13-T13: Get-SPCampaignForecast uses entitlement inventory when provided
- P13-T14: Export-SPGovernanceDashboardData produces CSV files with correct headers
- P13-T15: Export-SPGovernanceDashboardData produces empty CSV (headers only) for null input
- P13-T16: Invoke-SPGovernanceReport.ps1 syntax validation (PS AST parser)

**Mock patterns:**
- Mock `Invoke-SPApiRequest` for API calls (access profiles, roles)
- Mock `Get-SPConfig` for config-dependent tests
- Mock `Measure-SPIdentityRisk`, `Measure-SPSourceGovernance`, `Get-SPStaleAccess`,
  `Measure-SPReviewerReputation` for policy engine tests (pass pre-computed results)
- Use `TestDrive:\` for HTML output verification
- Use `TestDrive:\` for CSV/JSON dashboard export verification

**Files to Modify:**
- `Tests/Import-TestModules.ps1` -- add module imports if needed

**Acceptance Criteria:**
- All 16 tests pass on PowerShell 7 (pwsh)
- No dependencies on external services (all API calls mocked)
- Tests are self-contained (create and clean up their own test data)

---

## Existing Patterns to Follow

| Pattern | Location | Reuse In |
|---------|----------|----------|
| API pagination | SP.AuditQueries.psm1 `Get-SPAuditCampaigns` | P13-01, P13-02 |
| Entitlement inventory | SP.AuditQueries.psm1 `Get-SPEntitlementInventory` | P13-01, P13-02 |
| Identity risk aggregation | SP.AuditReport.psm1 `Measure-SPIdentityRisk` | P13-03 |
| Source governance scoring | SP.AuditReport.psm1 `Measure-SPSourceGovernance` | P13-04 |
| HTML report generation | SP.AuditReport.psm1 `Build-SingleCampaignHtml` | P13-01, P13-02, P13-03, P13-05, P13-06 |
| HTML table helpers | SP.AuditReport.psm1 `Build-HtmlTableRow` / `Build-HtmlTableHeader` | P13-01, P13-02, P13-03, P13-05, P13-06, P13-08 |
| Config defaults | SP.Config.psm1 `Get-SPConfigDefaults` | P13-04 |
| CLI script structure | Invoke-SPDailyOrchestrator.ps1 (param block, module loading, error handling) | P13-09 |
| Weekly digest script | Invoke-SPWeeklyDigest.ps1 (multi-section console + HTML output) | P13-09 |
| Pester mock patterns | Tests/SP.ProductionReadiness.Tests.ps1, Tests/SP.OperationalIntelligence.Tests.ps1 | P13-10 |
| CSV export | SP.AuditReport.psm1 `Export-SPAuditCsv` | P13-08 |
| Compliance package | SP.AuditReport.psm1 `Export-SPCompliancePackage` | P13-09 |
| Policy/config validation | SP.Config.psm1 `Test-SPConfiguration` | P13-04 |
| Campaign comparison | SP.AuditReport.psm1 `Compare-SPCampaigns` | P13-06 |

---

## ISC API Endpoints (New in Phase 13)

| Endpoint | Method | Used By | Purpose |
|----------|--------|---------|---------|
| `/v3/access-profiles` | GET | P13-01 | List access profiles per source |
| `/v3/roles` | GET | P13-02 | List roles with access profile mappings |

All other features consume existing function output (campaign audits, identity risk,
source governance, entitlement inventory, reviewer reputation, etc.).

**New PAT Scopes Required:**
- `idn:access-profile:read` -- for access profile inventory
- `idn:role:read` -- for role inventory

---

## Quarterly Governance Review Reference (Post-Phase 13)

```powershell
# Full governance report (the "run everything" command)
.\Invoke-SPGovernanceReport.ps1 -SourceId 'src-ad-001','src-entra-001' `
    -DaysBack 90 -OutputMode All -Token $token

# With compliance package and notification
.\Invoke-SPGovernanceReport.ps1 -SourceId 'src-ad-001' -DaysBack 90 `
    -OutputMode All -BundleCompliancePackage -SendNotification -Token $token

# Policy compliance check only (quick)
$audits = Get-SPAuditCampaigns -DaysBack 90 | ForEach-Object {
    Get-SPAuditCampaignReport -CampaignId $_.id
}
$risk = Measure-SPIdentityRisk -CampaignAudits $audits
$governance = Measure-SPSourceGovernance -CampaignAudits $audits
Test-SPGovernancePolicy -IdentityRisk $risk -SourceGovernance $governance

# Access profile + role inventory
$apInventory = Get-SPAccessProfileInventory -SourceIds @('src-ad-001') `
    -IncludeEntitlements -IncludeReviewHistory -CampaignAudits $audits
$roleInventory = Get-SPRoleInventory -IncludeAccessProfiles `
    -AccessProfileInventory $apInventory.Data

# Period comparison (Q1 vs Q2)
$q1 = @{ Label='Q1'; DateRange=@{After='2026-01-01';Before='2026-03-31'}; ... }
$q2 = @{ Label='Q2'; DateRange=@{After='2026-04-01';Before='2026-06-30'}; ... }
Compare-SPAuditPeriods -PeriodA $q1 -PeriodB $q2

# Campaign planning for next quarter
Get-SPCampaignForecast -CampaignAudits $audits `
    -EntitlementInventory $inventory.Data -SourceIds @('src-ad-001')

# Dashboard data export for Power BI
Export-SPGovernanceDashboardData -OutputPath './Audit' `
    -CampaignAudits $audits -IdentityRisk $risk `
    -SourceGovernance $governance -Format Both
```

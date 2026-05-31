# Phase 15: Integration, Compliance Depth & Operational Automation -- Backlog

**Created:** 2026-05-30
**Prereqs:** All Phases 1-12 complete, QH-01 to QH-18 complete
**Constraint:** NO GUI file changes

---

## How to Use This File

Agent loop -- same pattern as previous backlogs.

**Serial order:** `P15-01 -> P15-02 -> P15-03 -> P15-04 -> P15-05 -> P15-06 -> P15-07 -> P15-08 -> P15-09 -> P15-10`

**Parallel groups (items sharing no file targets):**
- **Group A** (independent): P15-01, P15-03, P15-06
- **Group B** (after P15-01): P15-02, P15-04, P15-05
- **Group C** (after P15-05): P15-07, P15-08
- **Group D** (after P15-07): P15-09
- **Group E** (after P15-09): P15-10

---

## GUI Constraint (CRITICAL)

Do NOT modify these files:
- `Gui/*.xaml` (any XAML file)
- `Modules/SP.Gui/SP.MainWindow.psm1`
- `Modules/SP.Gui/SP.GuiBridge.psm1`
- `Modules/SP.Gui/SP.Gui.psd1`

Safe to modify:
- `Modules/SP.Api/*.psm1` (add new functions)
- `Modules/SP.Api/SP.Api.psd1` (export new functions)
- `Modules/SP.Audit/SP.AuditQueries.psm1` (add new functions)
- `Modules/SP.Audit/SP.AuditReport.psm1` (add new functions)
- `Modules/SP.Audit/SP.Audit.psd1` (export new functions)
- `Modules/SP.Core/SP.Config.psm1` (add new functions)
- `Modules/SP.Core/SP.Core.psd1` (export new functions)
- `Config/settings.json` (add new config sections)
- `Scripts/` (NEW scripts only)
- `Tests/` (NEW test files)

---

## Phase Summary

| ID | Feature | Depends On | Files | Status |
|----|---------|------------|-------|--------|
| P15-01 | SoD Violation Scanner | none | SP.AuditQueries, SP.AuditReport, SP.Audit.psd1 | DONE |
| P15-02 | Entitlement Ownership Health | none | SP.AuditQueries, SP.AuditReport, SP.Audit.psd1 | DONE |
| P15-03 | Access Request Activity Monitor | none | SP.Campaigns, SP.Api.psd1 | DONE |
| P15-04 | Bulk Remediation Ticket Export | none | SP.AuditReport, SP.Audit.psd1 | DONE |
| P15-05 | SIEM Event Export (CEF/JSON) | none | SP.AuditReport, SP.Audit.psd1 | DONE |
| P15-06 | Governance Exception Register | none | SP.Config, SP.Core.psd1, settings.json | PENDING |
| P15-07 | Identity Lifecycle Correlation | none | SP.AuditReport, SP.Audit.psd1 | PENDING |
| P15-08 | Invoke-SPScheduledCampaign.ps1 | P15-06 | Scripts/ (new) | PENDING |
| P15-09 | Invoke-SPComplianceBundle.ps1 | P15-01, P15-02, P15-07 | Scripts/ (new) | PENDING |
| P15-10 | Pester Tests | P15-09 | Tests/ (new) | PENDING |

---

## Existing Functions to Reuse

| Function | Module | Used By |
|----------|--------|---------|
| `Get-SPConfig` | SP.Config | P15-06, P15-08, P15-09 |
| `Invoke-SPApiRequest` | SP.ApiClient | P15-01, P15-02, P15-03 |
| `Get-SPEntitlementInventory` | SP.AuditQueries | P15-02 |
| `Get-SPAccessProfileInventory` | SP.AuditQueries | P15-02 |
| `Get-SPAuditTrail` | SP.AuditReport | P15-05 |
| `Export-SPAuditJsonl` | SP.AuditReport | P15-05 |
| `Get-SPRemediationStatus` | SP.AuditQueries | P15-04 |
| `Get-SPAuditIdentityEvents` | SP.AuditQueries | P15-07 |
| `Get-SPAuditCampaigns` | SP.AuditQueries | P15-07, P15-09 |
| `Measure-SPIdentityRisk` | SP.AuditReport | P15-09 |
| `Measure-SPSourceGovernance` | SP.AuditReport | P15-09 |
| `Test-SPGovernancePolicy` | SP.AuditReport | P15-09 |
| `Export-SPCompliancePackage` | SP.AuditReport | P15-09 |
| `Send-SPNotification` | SP.AuditReport | P15-08, P15-09 |
| `Build-HtmlTableRow` / `Build-HtmlTableHeader` | SP.AuditReport | P15-01, P15-02, P15-04, P15-07 |
| `ConvertTo-SafeHtml` | SP.AuditReport | P15-01, P15-02, P15-04, P15-07 |
| `Write-SPLog` | SP.Logging | All |

---

## P15-01: Separation of Duties (SoD) Violation Scanner

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New functions `Get-SPSodPolicies` and `Get-SPSodViolations` in SP.AuditQueries.psm1
that query ISC's SoD APIs to retrieve current SoD policy definitions and active
violations. Also new function `Export-SPSodViolationHtml` in SP.AuditReport.psm1
for a compliance-ready violation report.

Answers: "Which identities currently violate Separation of Duties policies? Which
SoD policies have the most violations?"

SoD is a fundamental pillar of access governance required by SOX 302/404, SOC 2,
and ISO 27001 Annex A.9. The toolkit currently covers certification reviews, identity
risk, stale access, and policy compliance, but has no visibility into SoD conflicts.
An identity holding both "Finance-Approve" and "Finance-Pay" entitlements creates
segregation risk that certification reviews alone may not catch -- reviewers approve
each entitlement independently without seeing the conflicting combination.

ISC maintains SoD policies and detects violations natively. This feature surfaces
that data in the toolkit's reporting framework.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPSodPolicies` and
  `Get-SPSodViolations` functions
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPSodViolationHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signatures:**
```powershell
function Get-SPSodPolicies {
    param(
        [Parameter()][switch]$IncludeDisabled,
        [Parameter()][string]$CorrelationID
    )
}

function Get-SPSodViolations {
    param(
        [Parameter()][string[]]$PolicyIds,
        [Parameter()][switch]$PendingOnly,
        [Parameter()][int]$DaysBack = 90,
        [Parameter()][string]$CorrelationID
    )
}
```

**Get-SPSodPolicies flow:**
1. Query `GET /v3/sod-policies` (paginated, `limit=250&offset=N`).
2. For each policy, record: Id, Name, Description, State (ENFORCED/NOT_ENFORCED),
   Type (CONFLICTING_ACCESS_BASED), OwnerName, OwnerId, Created, Modified.
3. Extract `conflictingAccessCriteria`: left-hand entitlements/access profiles and
   right-hand entitlements/access profiles that define the conflict.
4. If `-IncludeDisabled` is false, filter to State = 'ENFORCED' only.

**Get-SPSodViolations flow:**
1. Query `GET /v3/sod-violations` (paginated).
2. If `$PolicyIds` specified, filter by policy ID.
3. For each violation, record: Id, ViolatingIdentityId, ViolatingIdentityName,
   PolicyId, PolicyName, ConflictingEntitlements (left and right side),
   Created, Status (PENDING/REMEDIATED/EXCEPTION_GRANTED).
4. If `-PendingOnly`, filter to Status = 'PENDING'.
5. Filter by `$DaysBack` on Created date.

**Returns (Get-SPSodPolicies):**
```powershell
@{
    Policies = @(
        @{
            Id          = 'sod-001'
            Name        = 'Finance Approve vs Pay'
            Description = 'No identity should hold both approval and payment authority'
            State       = 'ENFORCED'
            OwnerName   = 'Jane Compliance'
            LeftCriteria  = @('Finance-Approve', 'Finance-BatchApprove')
            RightCriteria = @('Finance-Pay', 'Finance-WireTransfer')
            Created     = '2025-06-01'
        }
    )
    Summary = @{
        TotalPolicies = 5
        Enforced      = 4
        NotEnforced   = 1
    }
}
```

**Returns (Get-SPSodViolations):**
```powershell
@{
    Violations = @(
        @{
            Id                    = 'viol-001'
            ViolatingIdentityId   = 'id-001'
            ViolatingIdentityName = 'Alice Johnson'
            PolicyId              = 'sod-001'
            PolicyName            = 'Finance Approve vs Pay'
            LeftEntitlements      = @('Finance-Approve')
            RightEntitlements     = @('Finance-Pay')
            Status                = 'PENDING'
            Created               = '2026-05-15T10:30:00Z'
        }
    )
    Summary = @{
        TotalViolations   = 12
        Pending           = 8
        Remediated        = 3
        ExceptionGranted  = 1
        PolicyBreakdown   = @{
            'Finance Approve vs Pay'     = 5
            'HR Read vs HR Write'        = 3
            'Admin vs Audit'             = 4
        }
        IdentitiesAffected = 9
    }
}
```

New function `Export-SPSodViolationHtml`:
- SoD policy summary table with enforcement status badges
- Per-violation table grouped by policy, sorted by created date descending
- Identity column with link context (identity name, number of violations)
- Conflicting entitlement pairs displayed side-by-side
- Status badges: PENDING (red), REMEDIATED (green), EXCEPTION_GRANTED (yellow)
- Summary card with violation count, pending count, affected identity count

**Acceptance Criteria:**
- Paginated query handles >250 SoD policies and violations
- `-PendingOnly` returns only PENDING violations
- `-PolicyIds` filters to specified policies
- Empty SoD policies (no policies configured) returns empty summary (not error)
- Empty violations returns empty summary with "No active SoD violations" message
- HTML report renders with same styling as existing audit reports
- All null inputs (API errors) produce graceful fallback, not crash

**Tests:** P15-T01, P15-T02

---

## P15-02: Entitlement Ownership Health Report

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Get-SPEntitlementOwnershipHealth` in SP.AuditQueries.psm1 that
analyzes entitlement and access profile inventory data to identify ownership gaps.
Also new function `Export-SPOwnershipHealthHtml` in SP.AuditReport.psm1 for HTML output.

Answers: "Which entitlements have no owner? Which owners are inactive or have left
the organization? Are privileged entitlements properly owned?"

Entitlement ownership is a governance prerequisite: every entitlement should have an
active, identifiable owner who is accountable for access decisions. Orphaned
entitlements (no owner) or stale-owner entitlements (owner left the company) create
governance blind spots because ISC cannot route certification reviews to the correct
person.

This function consumes existing entitlement and access profile inventory output and
cross-references ownership data.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditQueries.psm1` -- new `Get-SPEntitlementOwnershipHealth` function
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPOwnershipHealthHtml` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPEntitlementOwnershipHealth {
    param(
        [Parameter()][hashtable]$EntitlementInventory,
        [Parameter()][hashtable]$AccessProfileInventory,
        [Parameter()][string[]]$SourceIds,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. From `$EntitlementInventory.Data.Sources`, extract per-entitlement owner info
   (OwnerName, OwnerId -- available in ISC entitlement API response).
2. From `$AccessProfileInventory.Data.Sources`, extract per-access-profile owner info.
3. Classify each entitlement:
   - **Orphaned**: OwnerId is null or empty
   - **InactiveOwner**: Owner exists but lifecycle state is not 'active' (requires
     identity lookup via `GET /v3/public-identities/{id}` for lifecycle state check)
   - **SharedOwner**: Multiple entitlements across different sources share the same
     owner (governance concentration risk)
   - **Healthy**: Owner assigned and active
4. Flag privileged entitlements with ownership issues (higher severity).
5. Calculate ownership coverage metrics per source.

**Returns:**
```powershell
@{
    Sources = @{
        'src-ad-001' = @{
            SourceName           = 'Corporate AD'
            TotalEntitlements    = 150
            HealthyOwnership     = 130
            Orphaned             = 8
            InactiveOwner        = 5
            SharedOwner          = 7
            OwnershipCoveragePct = 86.7
            PrivilegedOrphaned   = 1
            Issues = @(
                @{
                    EntitlementName = 'AD-SG-LegacyAdmin'
                    Privileged      = $true
                    OwnerStatus     = 'Orphaned'
                    OwnerName       = $null
                    Severity        = 'Critical'
                    Recommendation  = 'Assign owner for privileged entitlement'
                }
            )
        }
    }
    Summary = @{
        TotalEntitlements        = 280
        HealthyOwnership         = 245
        Orphaned                 = 15
        InactiveOwner            = 10
        SharedOwner              = 10
        OverallCoveragePct       = 87.5
        PrivilegedWithIssues     = 3
        TopOrphanedSources       = @('Legacy App', 'Test Environment')
    }
}
```

New function `Export-SPOwnershipHealthHtml`:
- Per-source ownership health bar (green = healthy, red = orphaned, orange = inactive)
- Issue detail table grouped by source, severity-sorted
- Privileged orphaned entitlements called out in red highlight box
- Ownership concentration section showing owners with >20 entitlements
- Summary card with coverage percentage and issue counts

**Acceptance Criteria:**
- Entitlement with null OwnerId classified as 'Orphaned'
- Privileged orphaned entitlement gets Severity = 'Critical'
- Non-privileged orphaned entitlement gets Severity = 'High'
- InactiveOwner check uses identity lifecycle state (not presence of owner name)
- Without `$EntitlementInventory`, queries API directly using `$SourceIds`
- Without both `$EntitlementInventory` and `$SourceIds`, returns error
- Empty source (0 entitlements) returns valid entry with 100% coverage
- HTML report uses same styling as existing audit reports

**Tests:** P15-T03, P15-T04

---

## P15-03: Access Request Activity Monitor

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Get-SPAccessRequestActivity` in SP.Campaigns.psm1 that queries ISC's
access request APIs to retrieve recent request and approval patterns. Also new function
`Export-SPAccessRequestHtml` in SP.AuditReport.psm1 for HTML output.

Answers: "What access was requested and approved outside of certification campaigns?
Are there request patterns that indicate governance gaps?"

Certification campaigns review existing access, but new access grants happen through
ISC's access request workflow between campaign cycles. An identity could request and
receive privileged access the day after a campaign closes, and it would not be reviewed
until the next campaign. This function provides visibility into the request pipeline.

**Files to Modify:**
- `Modules/SP.Api/SP.Campaigns.psm1` -- new `Get-SPAccessRequestActivity` function
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPAccessRequestHtml` function
- `Modules/SP.Api/SP.Api.psd1` -- export new function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Get-SPAccessRequestActivity {
    param(
        [Parameter()][int]$DaysBack = 30,
        [Parameter()][string[]]$RequestedFor,
        [Parameter()][ValidateSet('PENDING','APPROVED','DENIED','CANCELLED','ALL')]
        [string]$Status = 'ALL',
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. Query `GET /v3/access-request-approvals` (paginated, `limit=250&offset=N`)
   with date filter for `$DaysBack`.
2. For each approval record, extract: RequestId, RequesterName, RequesterId,
   RequestedForName, RequestedForId, RequestedItemName, RequestedItemType
   (ENTITLEMENT/ACCESS_PROFILE/ROLE), ApproverName, ApproverId, Status,
   Created, Modified.
3. If `$RequestedFor` specified, filter to matching identity IDs.
4. If `$Status` is not 'ALL', filter to matching status.
5. Calculate activity metrics:
   - **RequestCount**: Total requests in window
   - **ApprovedCount**: Approved requests
   - **DeniedCount**: Denied requests
   - **PendingCount**: Requests awaiting approval
   - **AvgApprovalHours**: Average time from request to approval decision
   - **TopRequesters**: Identities with the most requests (potential abuse indicator)
   - **TopRequestedItems**: Most frequently requested entitlements/roles

**Returns:**
```powershell
@{
    Requests = @(
        @{
            RequestId       = 'req-001'
            RequesterName   = 'Alice Johnson'
            RequestedForName = 'Alice Johnson'
            RequestedItemName = 'Finance-Approve'
            RequestedItemType = 'ENTITLEMENT'
            ApproverName    = 'Bob Manager'
            Status          = 'APPROVED'
            Created         = '2026-05-20T09:00:00Z'
            Modified        = '2026-05-20T11:30:00Z'
            ApprovalHours   = 2.5
        }
    )
    Summary = @{
        TotalRequests    = 45
        Approved         = 30
        Denied           = 8
        Pending          = 5
        Cancelled        = 2
        AvgApprovalHours = 6.3
        TopRequesters = @(
            @{ Name = 'Alice Johnson'; Count = 5 }
        )
        TopRequestedItems = @(
            @{ Name = 'VPN-Access'; Type = 'ENTITLEMENT'; Count = 12 }
        )
    }
}
```

New function `Export-SPAccessRequestHtml`:
- Request timeline table sorted by date descending
- Status badges: APPROVED (green), DENIED (red), PENDING (yellow), CANCELLED (gray)
- Top requesters section with request count (flags identities with >5 requests)
- Top requested items section
- Summary card with approval rate and average approval hours

**Acceptance Criteria:**
- Paginated query handles >250 access request approvals
- `-Status PENDING` returns only pending approvals
- `-RequestedFor` filters to specified identity IDs
- AvgApprovalHours calculated only from APPROVED requests
- Empty request list returns empty summary (not error)
- TopRequesters sorted by count descending, limited to top 10
- HTML report uses same styling as existing audit reports
- Approval hours negative (approved before request -- clock skew) clamped to 0

**Tests:** P15-T05, P15-T06

---

## P15-04: Bulk Remediation Ticket Export

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New function `Export-SPRemediationTickets` in SP.AuditReport.psm1 that takes
remediation data (from `Get-SPRemediationStatus` or `Get-SPRemediationPriority`
output) and generates ITSM-formatted tickets suitable for import into ServiceNow,
Jira Service Management, or similar ticketing systems.

Answers: "How do I get these remediation items into our ticketing system without
manually creating 50 tickets?"

Currently the toolkit identifies remediation items (revocations, policy violations,
stale access) but requires manual handoff to the ITSM platform. This function
produces structured CSV and JSON exports with field mappings matching common ITSM
import schemas.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPRemediationTickets` function
- `Modules/SP.Audit/SP.Audit.psd1` -- export new function

**Function Signature:**
```powershell
function Export-SPRemediationTickets {
    param(
        [Parameter(Mandatory)][hashtable]$RemediationData,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter()][ValidateSet('ServiceNow','Jira','Generic')]
        [string]$Format = 'Generic',
        [Parameter()][string]$AssignmentGroup,
        [Parameter()][string]$Priority = 'Medium',
        [Parameter()][string]$Category = 'Access Governance',
        [Parameter()][string]$CorrelationID
    )
}
```

**Input:** `$RemediationData` is output from `Get-SPRemediationStatus` or
`Get-SPRemediationPriority` (P14-02). Function detects the input shape and
normalizes accordingly.

**Output formats:**

1. **ServiceNow CSV** (`-Format ServiceNow`):
   Columns: `number, short_description, description, assignment_group, priority,
   category, subcategory, u_identity_name, u_source_system, u_entitlement,
   u_action_required, u_due_date, u_governance_reference`

2. **Jira CSV** (`-Format Jira`):
   Columns: `Summary, Description, Priority, Labels, Assignee, Due Date,
   Custom field (Identity), Custom field (Source), Custom field (Entitlement),
   Custom field (Action)`

3. **Generic JSON** (`-Format Generic`):
   JSON array with normalized fields suitable for any ITSM API import.

**Per-ticket generation:**
- **Short description**: `"[Access Governance] Revoke {EntitlementName} from {IdentityName}"`
- **Description**: Multi-line with rationale, source, timeline, governance reference
- **Priority mapping**: Critical remediation -> P1/Highest, High -> P2/High,
  Medium -> P3/Medium, Low -> P4/Low
- **Due date**: Based on SLA hours from remediation status
- **Labels/Tags**: `access-governance`, `remediation`, `automated`

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        OutputPath     = 'Audit/tickets/'
        Format         = 'ServiceNow'
        TicketCount    = 35
        Files          = @(
            'remediation-tickets-2026-05-30.csv'
        )
        PriorityBreakdown = @{
            P1 = 5
            P2 = 12
            P3 = 15
            P4 = 3
        }
    }
}
```

**Acceptance Criteria:**
- ServiceNow CSV opens correctly in ServiceNow import set
- Jira CSV compatible with Jira CSV importer (External System Import)
- Generic JSON is a valid JSON array parseable by any REST client
- Priority mapping from remediation severity to ITSM priority is configurable
- `$AssignmentGroup` populates the assignment group field on all tickets
- Empty remediation data produces empty file with headers only (not error)
- Special characters in entitlement names are escaped in CSV output
- Each ticket has a unique governance reference ID for tracking

**Tests:** P15-T07

---

## P15-05: SIEM Event Export (CEF/JSON)

- **Status:** `DONE`
- **Depends On:** none

**Description:**
New functions `Export-SPAuditCef` and `Export-SPAuditSiemJson` in SP.AuditReport.psm1
that export audit trail events in industry-standard formats for SIEM ingestion
(Splunk, Microsoft Sentinel, QRadar, Elastic).

Answers: "How do I get governance events into our SIEM for correlation with security
alerts?"

The toolkit produces JSONL audit trails (`Export-SPAuditJsonl`) with a toolkit-specific
schema. Security operations teams need events in standard formats: CEF (Common Event
Format) for legacy SIEM and syslog infrastructure, and structured JSON matching
SIEM-specific schemas for modern platforms.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Export-SPAuditCef` and
  `Export-SPAuditSiemJson` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signatures:**
```powershell
function Export-SPAuditCef {
    param(
        [Parameter(Mandatory)][hashtable[]]$AuditEvents,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter()][string]$DeviceVendor = 'SailPoint',
        [Parameter()][string]$DeviceProduct = 'GovernanceToolkit',
        [Parameter()][string]$DeviceVersion = '1.0',
        [Parameter()][string]$CorrelationID
    )
}

function Export-SPAuditSiemJson {
    param(
        [Parameter(Mandatory)][hashtable[]]$AuditEvents,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter()][ValidateSet('Splunk','Sentinel','Elastic','Generic')]
        [string]$Format = 'Generic',
        [Parameter()][string]$CorrelationID
    )
}
```

**CEF format (ArcSight standard):**
```
CEF:0|SailPoint|GovernanceToolkit|1.0|AccessRevoked|Access Revoked for Alice Johnson|7|
  src=Corporate AD suser=Alice Johnson suid=id-001
  cs1Label=Entitlement cs1=AD-SG-DomainAdmins
  cs2Label=CampaignName cs2=Q2 Access Review
  cs3Label=ReviewerName cs3=Bob Manager
  rt=May 30 2026 12:00:00
  cat=AccessGovernance
```

**CEF event mapping:**
| Toolkit Event | CEF Event Name | CEF Severity |
|---------------|---------------|--------------|
| AccessApproved | Access Approved | 3 |
| AccessRevoked | Access Revoked | 7 |
| CampaignCreated | Campaign Created | 1 |
| CampaignCompleted | Campaign Completed | 1 |
| EscalationTriggered | Certification Escalated | 5 |
| RemediationOverdue | Remediation Overdue | 8 |
| PolicyViolation | Policy Violation | 9 |
| SodViolation | SoD Violation Detected | 9 |
| IdentityHighRisk | High Risk Identity | 6 |

**SIEM JSON format (Splunk HEC):**
```json
{
    "time": 1717070400,
    "source": "sailpoint:governance",
    "sourcetype": "sailpoint:governance:audit",
    "event": {
        "action": "AccessRevoked",
        "identityName": "Alice Johnson",
        "identityId": "id-001",
        "sourceName": "Corporate AD",
        "entitlementName": "AD-SG-DomainAdmins",
        "campaignName": "Q2 Access Review",
        "reviewerName": "Bob Manager",
        "correlationId": "abc-123"
    }
}
```

**Returns (both functions):**
```powershell
@{
    Success = $true
    Data = @{
        OutputPath     = 'Audit/siem/'
        Format         = 'CEF'
        EventCount     = 150
        FilePath       = 'Audit/siem/governance-events-2026-05-30.cef'
        EventBreakdown = @{
            AccessApproved = 100
            AccessRevoked  = 30
            CampaignCreated = 5
            EscalationTriggered = 3
            RemediationOverdue = 2
            PolicyViolation = 10
        }
    }
}
```

**Acceptance Criteria:**
- CEF output passes ArcSight CEF validation (pipe-delimited, correct field order)
- CEF severity 0-10 maps correctly from toolkit event types
- CEF special characters (pipe, backslash, equals) escaped per CEF spec
- Splunk JSON format is Splunk HEC compatible (epoch timestamp, source/sourcetype)
- Sentinel JSON format includes required fields for Azure Sentinel custom log
- Elastic format is ECS (Elastic Common Schema) compatible
- Generic format uses the toolkit's JSONL structure with ISO 8601 timestamps
- Empty audit events produces empty file (not error)
- File naming includes date for log rotation compatibility

**Tests:** P15-T08, P15-T09

---

## P15-06: Governance Exception Register

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New functions `Save-SPGovernanceException`, `Get-SPGovernanceException`,
`Get-SPGovernanceExceptionList`, and `Remove-SPGovernanceException` in SP.Config.psm1
that implement a local exception register for tracking approved deviations from
governance policies.

Answers: "We know this identity violates POL-003, but the CISO approved an exception
until December. How do we track that so it does not show up as a violation every week?"

Production governance programs always have exceptions: a contractor needs temporary
elevated access, a legacy system cannot be reviewed on the normal schedule, a specific
SoD conflict is accepted because compensating controls exist. Currently these
exceptions live in email approvals or SharePoint lists outside the toolkit. This
feature brings exception tracking into the governance workflow so that policy
evaluations can exclude approved exceptions and alert when exceptions expire.

**Files to Modify:**
- `Modules/SP.Core/SP.Config.psm1` -- new `Save-SPGovernanceException`,
  `Get-SPGovernanceException`, `Get-SPGovernanceExceptionList`,
  `Remove-SPGovernanceException`, `Test-SPGovernanceExceptionExpiry` functions
- `Modules/SP.Core/SP.Core.psd1` -- export new functions
- `Config/settings.json` -- add `Exceptions` section

**Config section:**
```json
"Exceptions": {
    "Path": ".\\Config\\exceptions",
    "AlertDaysBeforeExpiry": 14,
    "RequireApprover": true
}
```

**Function Signatures:**
```powershell
function Save-SPGovernanceException {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$PolicyId,
        [Parameter(Mandatory)][string]$Description,
        [Parameter()][string]$IdentityId,
        [Parameter()][string]$IdentityName,
        [Parameter()][string]$EntitlementName,
        [Parameter()][string]$SourceName,
        [Parameter(Mandatory)][DateTime]$ExpiryDate,
        [Parameter()][string]$ApprovedBy,
        [Parameter()][string]$CompensatingControl,
        [Parameter()][string]$CorrelationID
    )
}

function Get-SPGovernanceException {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter()][string]$CorrelationID
    )
}

function Get-SPGovernanceExceptionList {
    param(
        [Parameter()][string]$PolicyId,
        [Parameter()][switch]$IncludeExpired,
        [Parameter()][string]$CorrelationID
    )
}

function Remove-SPGovernanceException {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter()][string]$CorrelationID
    )
}

function Test-SPGovernanceExceptionExpiry {
    param(
        [Parameter()][int]$AlertDaysBeforeExpiry,
        [Parameter()][string]$CorrelationID
    )
}
```

**Exception file format:** `{Exceptions.Path}/{id}.json`
```json
{
    "id": "EXC-2026-001",
    "policyId": "POL-003",
    "description": "Contractor Bob needs elevated access for Project X until Dec 2026",
    "identityId": "id-bob-001",
    "identityName": "Bob Contractor",
    "entitlementName": "AD-SG-ProjectX-Admin",
    "sourceName": "Corporate AD",
    "expiryDate": "2026-12-31T23:59:59Z",
    "approvedBy": "CISO Jane Smith",
    "compensatingControl": "Weekly access review by project lead, audit log monitoring",
    "createdAt": "2026-05-30T12:00:00Z",
    "modifiedAt": "2026-05-30T12:00:00Z",
    "status": "Active"
}
```

**Test-SPGovernanceExceptionExpiry flow:**
1. List all active exceptions.
2. For each, calculate days until expiry.
3. Flag exceptions within `$AlertDaysBeforeExpiry` window.
4. Flag expired exceptions (past expiry date).

**Returns (Save):**
```powershell
@{
    Success = $true
    Data = @{
        Id     = 'EXC-2026-001'
        Path   = 'Config/exceptions/EXC-2026-001.json'
        Action = 'Created'
    }
}
```

**Returns (Test-SPGovernanceExceptionExpiry):**
```powershell
@{
    Exceptions = @(
        @{
            Id           = 'EXC-2026-001'
            PolicyId     = 'POL-003'
            IdentityName = 'Bob Contractor'
            ExpiryDate   = '2026-12-31'
            DaysRemaining = 215
            Status       = 'Active'
            Alert        = $false
        }
        @{
            Id           = 'EXC-2025-004'
            PolicyId     = 'POL-001'
            IdentityName = 'Legacy Service Account'
            ExpiryDate   = '2026-06-10'
            DaysRemaining = 11
            Status       = 'Active'
            Alert        = $true
            AlertMessage = 'Exception expires in 11 days'
        }
    )
    Summary = @{
        TotalActive    = 5
        Expiring       = 1
        Expired        = 2
        TotalExceptions = 7
    }
}
```

**Acceptance Criteria:**
- Exception ID with special characters rejected with descriptive error
- Save then Get returns identical exception data
- Save with existing ID overwrites and updates modifiedAt
- Get with non-existent ID returns Success = false
- List without `-IncludeExpired` excludes expired exceptions
- List with `$PolicyId` filters to matching policy
- Remove deletes the file and returns confirmation
- Remove with non-existent ID returns Success = false
- Test-SPGovernanceExceptionExpiry correctly identifies expiring and expired exceptions
- Exceptions directory created on first Save if it does not exist
- When `RequireApprover = true`, Save without `$ApprovedBy` returns error
- JSON files are human-readable (indented)

**Tests:** P15-T10, P15-T11

---

## P15-07: Identity Lifecycle Correlation Report

- **Status:** `PENDING`
- **Depends On:** none

**Description:**
New function `Get-SPIdentityLifecycleCorrelation` in SP.AuditReport.psm1 that
cross-references identity lifecycle events (joiners, movers, leavers) with access
review decisions to identify governance gaps in lifecycle transitions. Also new
function `Export-SPLifecycleCorrelationHtml` for HTML output.

Answers: "Are new joiners getting their access reviewed promptly? When someone
moves departments, is their old access being revoked? Do leavers still have
residual access?"

Identity lifecycle management (ILM) and access certification are two pillars of
governance that should work together but are often siloed. A new hire who receives
access on Day 1 should have that access reviewed in the next certification cycle.
An employee who transfers departments should have old access flagged for revocation.
A terminated employee should have all access revoked immediately.

This function detects gaps between lifecycle events and governance actions.

**Files to Modify:**
- `Modules/SP.Audit/SP.AuditReport.psm1` -- new `Get-SPIdentityLifecycleCorrelation`
  and `Export-SPLifecycleCorrelationHtml` functions
- `Modules/SP.Audit/SP.Audit.psd1` -- export new functions

**Function Signature:**
```powershell
function Get-SPIdentityLifecycleCorrelation {
    param(
        [Parameter(Mandatory)][hashtable[]]$CampaignAudits,
        [Parameter()][int]$LifecycleEventDaysBack = 90,
        [Parameter()][int]$ReviewGraceDays = 30,
        [Parameter()][string]$CorrelationID
    )
}
```

**Flow:**
1. From `$CampaignAudits`, extract all identity decisions with timestamps.
2. For identities appearing in campaign reviews, query `Get-SPAuditIdentityEvents`
   (existing function) to get lifecycle events within `$LifecycleEventDaysBack`.
3. Classify lifecycle event types from ISC account-activities:
   - **Joiner**: Identity created or account enabled events
   - **Mover**: Role change, department change, manager change events
   - **Leaver**: Identity disabled, terminated, or account deleted events
4. Cross-reference lifecycle events against campaign decisions:

   **Joiner correlation:**
   - Joiner who received access but was NOT included in any campaign within
     `$ReviewGraceDays` -> Gap: "New access unreviewed"
   - Joiner who WAS reviewed -> Covered: "New access reviewed"

   **Mover correlation:**
   - Mover who kept old department access and it was APPROVED (not revoked) ->
     Gap: "Old access retained after transfer"
   - Mover whose old access was REVOKED -> Covered: "Old access revoked on transfer"

   **Leaver correlation:**
   - Leaver with any access still showing APPROVED in latest campaign ->
     Gap: "Residual access after termination"
   - Leaver with all access REVOKED or no remaining access ->
     Covered: "Access properly removed"

5. Sort gaps by severity: Leaver residual > Mover retained > Joiner unreviewed.

**Returns:**
```powershell
@{
    Correlations = @(
        @{
            IdentityId        = 'id-001'
            IdentityName      = 'Alice Johnson'
            LifecycleEvent    = 'Mover'
            EventDate         = '2026-04-15T00:00:00Z'
            EventDetail       = 'Department changed: Finance -> Marketing'
            CorrelationStatus = 'Gap'
            GapType           = 'OldAccessRetained'
            RetainedAccess    = @('Finance-Approve', 'Finance-Reports')
            LastReviewDate    = '2026-05-01'
            ReviewDecision    = 'Approved'
            Severity          = 'High'
            Recommendation    = 'Review Finance entitlements for relevance after department transfer'
        }
    )
    Summary = @{
        TotalIdentitiesAnalyzed = 200
        LifecycleEventsFound    = 25
        Joiners = @{
            Total     = 10
            Reviewed  = 7
            Unreviewed = 3
        }
        Movers = @{
            Total          = 8
            OldAccessRevoked = 3
            OldAccessRetained = 5
        }
        Leavers = @{
            Total            = 7
            AccessRemoved    = 5
            ResidualAccess   = 2
        }
        TotalGaps  = 10
        GapsBySeverity = @{
            Critical = 2    # Leaver residual
            High     = 5    # Mover retained
            Medium   = 3    # Joiner unreviewed
        }
    }
}
```

New function `Export-SPLifecycleCorrelationHtml`:
- Timeline view showing lifecycle event -> expected governance action -> actual outcome
- Gap items highlighted with severity badges (Critical red, High orange, Medium yellow)
- Covered items shown in green
- Joiner/Mover/Leaver section tabs with detail tables
- Summary card with gap count and lifecycle event distribution
- Recommendations section for each gap type

**Acceptance Criteria:**
- Leaver with residual access gets Severity = 'Critical'
- Mover with retained old-department access gets Severity = 'High'
- Joiner unreviewed within grace period gets no gap (within grace window)
- Joiner unreviewed past grace period gets Severity = 'Medium'
- Identity with no lifecycle events is excluded from the report (no gap, no coverage)
- Empty campaign audit input returns empty summary (not error)
- HTML report renders lifecycle timeline with clear gap/covered indicators
- ReviewGraceDays of 0 means joiner must be reviewed immediately

**Tests:** P15-T12, P15-T13

---

## P15-08: Invoke-SPScheduledCampaign.ps1

- **Status:** `PENDING`
- **Depends On:** P15-06

**Description:**
New CLI script `Scripts/Invoke-SPScheduledCampaign.ps1` that runs campaigns from
saved templates on a recurring schedule with last-run tracking and idempotency
protection. Designed for cron/scheduled task execution alongside the daily orchestrator.

Answers: "I want to run the quarterly AD review automatically on the first Monday of
every quarter. Can I set it and forget it?"

The daily orchestrator (P11-09) handles delta cert workflows, but recurring
full-scope campaigns (quarterly reviews, monthly source audits) require manual
triggering. This script reads campaign templates (P14-08 `Get-SPCampaignTemplate`)
and a schedule configuration, determines which templates are due, and runs them.

Uses the governance exception register (P15-06) to skip identities with active
exceptions when building campaign scope.

**File to Create:**
- `Scripts/Invoke-SPScheduledCampaign.ps1`

**Parameters:**
```powershell
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,
    [Parameter()][string]$TemplateName,

    # Schedule
    [Parameter()][ValidateSet('Daily','Weekly','Monthly','Quarterly')]
    [string]$Cadence = 'Quarterly',
    [Parameter()][int]$MinDaysSinceLastRun = 80,

    # Exception handling
    [Parameter()][switch]$ExcludeExceptions,

    # Output
    [Parameter()][ValidateSet('Console','JSON','Both')]
    [string]$OutputMode = 'Console',
    [Parameter()][string]$OutputPath,

    # Safety
    [Parameter()][switch]$WhatIf,
    [Parameter()][switch]$Help
)
```

**Execution steps:**

```
Step 1: Load template(s)
  -> If $TemplateName specified, load that template
  -> Otherwise, load all templates and filter by cadence

Step 2: Check last-run tracking
  -> Read {Templates.Path}/.schedule-state.json
  -> For each template, check lastRunDate
  -> Skip templates run within $MinDaysSinceLastRun

Step 3: Load exceptions (if -ExcludeExceptions)
  -> Get-SPGovernanceExceptionList -IncludeExpired:$false
  -> Build exclusion list of identity+entitlement pairs

Step 4: Run due campaigns
  -> For each due template:
     -> Extract parameters from template
     -> If -ExcludeExceptions, add exclusion filters
     -> Invoke-SPDeltaCertRun or appropriate campaign function
     -> Update lastRunDate in schedule state

Step 5: Summary
  -> Report which templates were run, skipped, or failed
  -> Update .schedule-state.json
```

**Schedule state file:** `{Templates.Path}/.schedule-state.json`
```json
{
    "quarterly-ad-review": {
        "lastRunDate": "2026-03-01T06:00:00Z",
        "lastCorrelationId": "abc-123",
        "lastResult": "Success",
        "runCount": 4
    }
}
```

**Console output:**
```
=== Scheduled Campaign Runner ===
Timestamp:   2026-05-30T06:00:00Z

Template: quarterly-ad-review
  Last Run:  2026-03-01 (90 days ago)
  Cadence:   Quarterly (MinDays: 80)
  Status:    DUE -- running
  Result:    Created 3 campaigns for 12 identities
  Exceptions: 2 identities excluded (active exceptions)

Template: monthly-cloud-audit
  Last Run:  2026-05-01 (29 days ago)
  Cadence:   Monthly (MinDays: 25)
  Status:    DUE -- running
  Result:    Created 1 campaign for 45 identities

Template: weekly-privileged-review
  Last Run:  2026-05-28 (2 days ago)
  Cadence:   Weekly (MinDays: 6)
  Status:    SKIPPED -- too recent

Summary: 2 campaigns run, 1 skipped, 0 failed
```

**Exit codes:**
- 0 = All due campaigns run successfully (or none due)
- 1 = One or more campaigns had warnings
- 2 = Parameter error
- 3 = Authentication error
- 4 = Configuration error
- 5 = Critical campaign creation failure

**Acceptance Criteria:**
- Template not run within MinDaysSinceLastRun is classified as DUE
- Template run recently is SKIPPED with "too recent" message
- `-WhatIf` shows which templates are due without creating campaigns
- Schedule state file updated atomically after successful run
- Missing schedule state file treated as "never run" (all templates DUE)
- `-ExcludeExceptions` correctly filters identities with active exceptions
- Works with both `-Token` and configured OAuth
- Exit code 0 when no templates are due (nothing to do)

**Tests:** P15-T14

---

## P15-09: Invoke-SPComplianceBundle.ps1

- **Status:** `PENDING`
- **Depends On:** P15-01, P15-02, P15-07

**Description:**
New CLI script `Scripts/Invoke-SPComplianceBundle.ps1` that orchestrates a complete
compliance audit cycle and bundles all evidence into a single deliverable package.
Designed as the "quarterly audit preparation" command -- one invocation produces
everything an auditor needs.

Answers: "Our SOX auditors are coming next week. Can I generate all the evidence
they need in one command?"

Unlike `Invoke-SPGovernanceReport.ps1` (P13-09) which produces analytics reports,
and `Export-SPCompliancePackage` (P12-01) which packages existing artifacts, this
script runs the full audit cycle from scratch and produces a compliance-grade
evidence bundle with: SoD violation scan (P15-01), entitlement ownership health
(P15-02), identity lifecycle correlation (P15-07), plus all existing analytics.

**File to Create:**
- `Scripts/Invoke-SPComplianceBundle.ps1`

**Parameters:**
```powershell
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,
    [Parameter()][string[]]$SourceId,
    [Parameter()][int]$DaysBack = 90,

    # Section toggles
    [Parameter()][switch]$SkipSodScan,
    [Parameter()][switch]$SkipOwnershipHealth,
    [Parameter()][switch]$SkipLifecycleCorrelation,
    [Parameter()][switch]$SkipIdentityRisk,
    [Parameter()][switch]$SkipSourceGovernance,
    [Parameter()][switch]$SkipPolicyCheck,
    [Parameter()][switch]$SkipRemediationStatus,

    # Output
    [Parameter()][string]$OutputPath,
    [Parameter()][string]$PackageName,

    # Notification
    [Parameter()][switch]$SendNotification,
    [Parameter()][string[]]$NotifyRecipients,

    [Parameter()][switch]$Help,
    [Parameter()][switch]$WhatIf
)
```

**Execution steps:**

```
Step 1: Configuration & Authentication
  -> Load config, validate with Test-SPConfiguration
  -> Acquire token

Step 2: Campaign Data Collection
  -> Get-SPAuditCampaigns -DaysBack $DaysBack
  -> For each campaign: Get-SPAuditCampaignReport

Step 3: Entitlement & Access Profile Inventory
  -> Get-SPEntitlementInventory -SourceIds $SourceId -IncludeReviewHistory
  -> Get-SPAccessProfileInventory -SourceIds $SourceId -IncludeEntitlements

Step 4: Analytics (each independent)
  4a: Measure-SPIdentityRisk (unless -SkipIdentityRisk)
  4b: Measure-SPSourceGovernance (unless -SkipSourceGovernance)
  4c: Get-SPStaleAccess (unless implicit)
  4d: Measure-SPReviewerReputation

Step 5: Compliance-Specific Analyses
  5a: Get-SPSodViolations (unless -SkipSodScan)
  5b: Get-SPEntitlementOwnershipHealth (unless -SkipOwnershipHealth)
  5c: Get-SPIdentityLifecycleCorrelation (unless -SkipLifecycleCorrelation)

Step 6: Policy Compliance
  -> Test-SPGovernancePolicy with all analytics + exception register

Step 7: Remediation Status
  -> Get-SPRemediationStatus for all revocations

Step 8: Report Generation
  -> Generate HTML reports for each analysis
  -> Generate CSV exports

Step 9: Evidence Packaging
  -> Export-SPCompliancePackage with all generated artifacts
  -> Add compliance manifest with section cross-references

Step 10: Notification (if -SendNotification)
  -> Send summary with package attachment
```

**Console output:**
```
=== Compliance Audit Bundle ===
Period:    2026-03-01 to 2026-05-30 (90 days)
Sources:   src-ad-001, src-entra-001

--- Data Collection ---
  Campaigns: 12 | Items: 1,450

--- Identity Risk ---
  High: 5 | Medium: 12 | Low: 183

--- Source Governance ---
  Corporate AD: B (82.3) | Cloud Entra: A (91.5)

--- SoD Violations ---
  Active: 3 | Policies Checked: 5

--- Entitlement Ownership ---
  Coverage: 87.5% | Orphaned: 15 | Inactive Owner: 10

--- Lifecycle Correlation ---
  Gaps: 10 | Leaver Residual: 2 | Mover Retained: 5

--- Policy Compliance ---
  PASS: 3/5 | FAIL: 2

--- Remediation ---
  SLA Compliance: 87% | Overdue: 2

--- Evidence Package ---
  Package: compliance-bundle-2026-Q2.zip
  Artifacts: 22 | Size: 1.2 MB

Result: BUNDLE COMPLETE (2 policy violations, 3 SoD violations)
```

**Exit codes:**
- 0 = Bundle generated, all policies passed
- 1 = Bundle generated, non-critical issues found
- 2 = Parameter error
- 3 = Authentication error
- 4 = Configuration error
- 5 = Critical data collection failure

**Acceptance Criteria:**
- All 10 steps execute with proper error isolation
- Step failure does not prevent subsequent steps or packaging
- Section skip switches exclude corresponding analysis
- Evidence package includes all generated HTML, CSV, and JSON files
- Package manifest lists every artifact with SHA-256 hash
- Console output is concise and scannable
- `-WhatIf` shows what would be generated without API calls
- Works with both `-Token` and configured OAuth
- Package naming includes period (e.g., `compliance-bundle-2026-Q2.zip`)

**Tests:** P15-T15

---

## P15-10: Pester Tests

- **Status:** `PENDING`
- **Depends On:** P15-09

**Description:**
Pester tests for all new functions added in P15-01 through P15-09.

**File to Create:**
- `Tests/SP.IntegrationCompliance.Tests.ps1`

**Test IDs:**

- P15-T01: Get-SPSodPolicies returns paginated policy list with correct fields
- P15-T02: Get-SPSodViolations with -PendingOnly returns only PENDING violations
- P15-T03: Get-SPEntitlementOwnershipHealth classifies null OwnerId as Orphaned
- P15-T04: Get-SPEntitlementOwnershipHealth flags privileged orphaned as Critical severity
- P15-T05: Get-SPAccessRequestActivity returns correct approval rate calculation
- P15-T06: Get-SPAccessRequestActivity with -Status PENDING filters correctly
- P15-T07: Export-SPRemediationTickets produces valid ServiceNow CSV with correct columns
- P15-T08: Export-SPAuditCef produces valid CEF format with correct severity mapping
- P15-T09: Export-SPAuditSiemJson produces Splunk HEC compatible JSON
- P15-T10: Save-SPGovernanceException then Get returns identical data
- P15-T11: Test-SPGovernanceExceptionExpiry identifies exception expiring within alert window
- P15-T12: Get-SPIdentityLifecycleCorrelation flags leaver with residual access as Critical
- P15-T13: Get-SPIdentityLifecycleCorrelation flags joiner within grace period as covered
- P15-T14: Invoke-SPScheduledCampaign.ps1 syntax validation (PS AST parser)
- P15-T15: Invoke-SPComplianceBundle.ps1 syntax validation (PS AST parser)

**Mock patterns:**
- Mock `Invoke-SPApiRequest` for API calls (SoD policies, violations, access requests,
  entitlements, identity lifecycle events)
- Mock `Get-SPConfig` for config-dependent tests
- Mock `Get-SPAuditIdentityEvents` for lifecycle correlation tests
- Use `TestDrive:\` for exception register file I/O tests
- Use `TestDrive:\` for CEF/JSON export verification
- Use `TestDrive:\` for CSV ticket export verification
- Use `TestDrive:\` for HTML output verification

**Files to Modify:**
- `Tests/Import-TestModules.ps1` -- add module imports if needed

**Acceptance Criteria:**
- All 15 tests pass on PowerShell 7 (pwsh)
- No dependencies on external services (all API calls mocked)
- Tests are self-contained (create and clean up their own test data)

---

## Existing Patterns to Follow

| Pattern | Location | Reuse In |
|---------|----------|----------|
| API pagination | SP.AuditQueries.psm1 `Get-SPAuditCampaigns` | P15-01, P15-03 |
| HTML report generation | SP.AuditReport.psm1 `Build-SingleCampaignHtml` | P15-01, P15-02, P15-03, P15-04, P15-07 |
| HTML table helpers | SP.AuditReport.psm1 `Build-HtmlTableRow` / `Build-HtmlTableHeader` | P15-01, P15-02, P15-03, P15-04, P15-07 |
| CSV export | SP.AuditReport.psm1 `Export-SPAuditCsv` | P15-04 |
| JSONL write (BOM-free) | SP.AuditReport.psm1 `Export-SPAuditJsonl` | P15-05 |
| SHA-256 hashing | SP.AuditReport.psm1 `Export-SPCompliancePackage` | P15-09 |
| Config file I/O | SP.Config.psm1 `Save-SPCampaignTemplate` / `Get-SPCampaignTemplate` | P15-06 |
| Config defaults | SP.Config.psm1 `Get-SPConfigDefaults` | P15-06 |
| Identity events | SP.AuditQueries.psm1 `Get-SPAuditIdentityEvents` | P15-07 |
| CLI script structure | Invoke-SPDailyOrchestrator.ps1 (param block, module loading, error handling) | P15-08, P15-09 |
| Compliance packaging | SP.AuditReport.psm1 `Export-SPCompliancePackage` | P15-09 |
| Pester mock patterns | Tests/SP.ProductionReadiness.Tests.ps1, Tests/SP.OperationalIntelligence.Tests.ps1 | P15-10 |
| Template library | SP.Config.psm1 `Save-SPCampaignTemplate` | P15-08 |
| Exception validation | SP.Config.psm1 `Test-SPConfiguration` (filename/input validation patterns) | P15-06 |

---

## ISC API Endpoints (New in Phase 15)

| Endpoint | Method | Used By | Purpose |
|----------|--------|---------|---------|
| `/v3/sod-policies` | GET | P15-01 | List SoD policy definitions |
| `/v3/sod-violations` | GET | P15-01 | List active SoD violations |
| `/v3/access-request-approvals` | GET | P15-03 | List access request approvals |
| `/v3/public-identities/{id}` | GET | P15-02 | Check identity lifecycle state for ownership health |

All other features consume existing function output or operate on local files
(exception register, ticket export, SIEM export).

**New PAT Scopes Required:**
- `idn:sod-policy:read` -- for SoD policy and violation queries
- `idn:access-request:read` -- for access request activity monitoring

---

## Operational Reference (Post-Phase 15)

```powershell
# SoD violation scan
$sodPolicies = Get-SPSodPolicies
$sodViolations = Get-SPSodViolations -PendingOnly
Export-SPSodViolationHtml -Violations $sodViolations -Policies $sodPolicies `
    -OutputPath '.\Audit'

# Entitlement ownership health
$inventory = Get-SPEntitlementInventory -SourceIds @('src-ad-001') -IncludeReviewHistory
$apInventory = Get-SPAccessProfileInventory -SourceIds @('src-ad-001')
$ownership = Get-SPEntitlementOwnershipHealth -EntitlementInventory $inventory `
    -AccessProfileInventory $apInventory
Export-SPOwnershipHealthHtml -OwnershipHealth $ownership -OutputPath '.\Audit'

# Access request monitoring
$requests = Get-SPAccessRequestActivity -DaysBack 30 -Status ALL
Export-SPAccessRequestHtml -Requests $requests -OutputPath '.\Audit'

# Bulk remediation tickets for ServiceNow
$remediation = Get-SPRemediationStatus -RevocationDecisions $revocations
Export-SPRemediationTickets -RemediationData $remediation `
    -OutputPath '.\Audit\tickets' -Format ServiceNow `
    -AssignmentGroup 'IAM-Operations'

# SIEM event export
$auditEvents = Get-SPAuditTrail -DaysBack 7
Export-SPAuditCef -AuditEvents $auditEvents -OutputPath '.\Audit\siem'
Export-SPAuditSiemJson -AuditEvents $auditEvents -OutputPath '.\Audit\siem' `
    -Format Splunk

# Governance exception management
Save-SPGovernanceException -Id 'EXC-2026-001' -PolicyId 'POL-003' `
    -Description 'Contractor elevated access for Project X' `
    -IdentityName 'Bob Contractor' -ExpiryDate '2026-12-31' `
    -ApprovedBy 'CISO Jane Smith' `
    -CompensatingControl 'Weekly access review by project lead'
Test-SPGovernanceExceptionExpiry -AlertDaysBeforeExpiry 14

# Identity lifecycle correlation
$audits = Get-SPAuditCampaigns -DaysBack 90 | ForEach-Object {
    Get-SPAuditCampaignReport -CampaignId $_.id
}
$lifecycle = Get-SPIdentityLifecycleCorrelation -CampaignAudits $audits `
    -LifecycleEventDaysBack 90 -ReviewGraceDays 30
Export-SPLifecycleCorrelationHtml -Correlations $lifecycle -OutputPath '.\Audit'

# Scheduled campaign execution (quarterly cron)
.\Invoke-SPScheduledCampaign.ps1 -Cadence Quarterly `
    -MinDaysSinceLastRun 80 -ExcludeExceptions -Token $token

# Complete compliance audit bundle (pre-auditor delivery)
.\Invoke-SPComplianceBundle.ps1 -SourceId 'src-ad-001','src-entra-001' `
    -DaysBack 90 -OutputPath '.\Audit' -Token $token
```

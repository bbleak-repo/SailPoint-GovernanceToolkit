# Disconnected App Production Readiness -- Backlog (DA-21 to DA-30)

**Created:** 2026-05-29
**Prereqs:** DA-01 to DA-20 complete (single app kit + enterprise batch)
**Purpose:** Close the gaps between "toolkit creates campaigns" and "production-grade governance"

---

## How to Use This File

Agent loop: `DA-21 -> DA-22 -> DA-23 -> DA-24 -> DA-25 -> DA-26 -> DA-27 -> DA-28 -> DA-29 -> DA-30`

---

## Context

The toolkit creates daily delta campaigns for disconnected apps but currently operates
as fire-and-forget. It does not circle back to check decisions, track remediations,
upload data to ISC, or alert on failures. These 10 features close the loop from
"campaign created" to "compliance evidence packaged."

---

## Phase Summary

| Rank | ID | Feature | Depends On | Status |
|------|-----|---------|------------|--------|
| 1 | DA-21 | Post-Campaign Decision Collection | none | DONE |
| 2 | DA-22 | Disconnected App Remediation Tracker | DA-21 | DONE |
| 3 | DA-23 | Unified Daily Orchestrator Integration | none | DONE |
| 4 | DA-24 | ISC Source Aggregation (CSV Upload) | none | DONE |
| 5 | DA-25 | Operational Alerting (Wire Notifications) | none | DONE |
| 6 | DA-26 | Campaign Lifecycle Management (Cleanup) | none | DONE |
| 7 | DA-27 | Historical Trending + Compliance Packaging | DA-21 | DONE |
| 8 | DA-28 | Disconnected App Escalation | none | DONE |
| 9 | DA-29 | Self-Service App Team Dashboard | DA-21, DA-22 | PENDING |
| 10 | DA-30 | Pester Tests | DA-29 | PENDING |

---

## DA-21: Post-Campaign Decision Collection

- **Status:** `DONE`
- **Commit:** DA-21
- **Depends On:** none

**Description:**
The toolkit creates campaigns but never checks what managers decided. New function
`Get-SPDisconnectedAppCampaignDecisions` that reads campaign IDs from the JSONL audit
trail, queries ISC for completion status and item-level decisions, and writes results
back to the audit trail.

**The closed-loop problem:** Without this, the governance team has no idea whether
campaigns were completed, what was approved/revoked, or what needs remediation.

**Flow:**
1. Read JSONL audit trail for campaign IDs created in the last N days
2. For each campaign: `GET /v3/campaigns/{id}` for status
3. For completed campaigns: `Get-SPAuditCertifications` + `Get-SPAuditCertificationItems`
4. Categorize: Approved, Revoked, Pending, Expired
5. Write decision summary to JSONL + return structured data
6. Generate decision harvest HTML report

**Files to Create/Modify:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1` -- new function
- Export in `.psd1` if exists, or in Export-ModuleMember

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        CampaignsChecked = 15
        Completed = 10
        Active = 3
        Expired = 2
        Decisions = @{
            Approved = 47
            Revoked = 8
            Pending = 5
        }
        RevocationDetails = @(
            @{ AppName; IdentityName; AccountId; Entitlement; ReviewerName; DecisionDate }
        )
    }
}
```

**Acceptance Criteria:**
- Reads campaign IDs from existing JSONL audit trail
- Queries ISC for each campaign's current status + decisions
- Identifies revocations that need remediation follow-up
- Writes results to JSONL for historical tracking
- Handles campaigns that no longer exist in ISC (deleted/purged)

---

## DA-22: Disconnected App Remediation Tracker

- **Status:** `DONE`
- **Commit:** DA-22
- **Depends On:** DA-21

**Description:**
When a manager revokes access in a disconnected app campaign, ISC cannot auto-provision
the revocation (no connector). The app team must manually remove the access. This feature
tracks revocation decisions and verifies they were executed by checking the next day's CSV.

**The compliance problem:** SOX auditors require evidence that revocations were not just
decided but actually executed. This closes that gap.

**Flow:**
1. From DA-21 decision collection, extract all REVOKE decisions
2. Create remediation records: identity, app, entitlement, decision date, status=PENDING
3. Store in `{AppName}/remediation-tracker.json`
4. On next batch run: check if the revoked entitlement is ABSENT from today's CSV
5. If absent: mark remediation as CONFIRMED, record confirmation date
6. If still present: mark as OVERDUE, increment days-overdue counter
7. Generate remediation status report

**Remediation states:**
- `PENDING` -- revocation decided, waiting for app team to remove access
- `CONFIRMED` -- next CSV shows entitlement removed (closed loop)
- `OVERDUE` -- entitlement still present after N days (configurable, default 3)
- `ESCALATED` -- overdue remediation sent to app owner / governance team

**Files to Modify:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1` -- new functions:
  `New-SPRemediationRecord`, `Update-SPRemediationStatus`, `Get-SPRemediationReport`
- Wire into `Invoke-SPDisconnectedAppCert.ps1` as a post-delta check step

**Acceptance Criteria:**
- Revocation decision creates a PENDING remediation record
- Next-day delta confirms remediation (entitlement disappears from CSV)
- Overdue remediations flagged after configurable threshold
- Remediation history persisted in per-app JSON file

---

## DA-23: Unified Daily Orchestrator Integration

- **Status:** `DONE`
- **Commit:** DA-23
- **Depends On:** none

**Description:**
Extend `Invoke-SPDailyOrchestrator.ps1` to include a disconnected app batch step,
creating a single daily command that runs both the AD delta cert pipeline AND the
disconnected app pipeline with a unified summary.

Currently: two separate scheduled tasks, two credentials, two audit trails.
After: one command, one credential, one summary.

**Changes to Invoke-SPDailyOrchestrator.ps1:**
Add Step 7 (after existing steps 1-6):
```
Step 7: Disconnected App Batch
  - Run Get-SPRegisteredApps
  - If apps registered: run Invoke-SPDisconnectedAppBatch
  - Capture batch result
  - Include in unified summary
```

Also add:
- Step 8: Decision Collection (DA-21) -- harvest decisions from yesterday's campaigns
- Step 9: Remediation Check (DA-22) -- verify yesterday's revocations were executed

**Files to Modify:**
- `Scripts/Invoke-SPDailyOrchestrator.ps1` -- add steps 7-9
- Add `-IncludeDisconnectedApps` switch (default: $true if apps are registered)
- Add `-SkipDisconnectedApps` switch for AD-only runs

**Acceptance Criteria:**
- Single daily command covers both AD and disconnected app governance
- Disconnected app batch failure does not block AD pipeline (error isolation)
- Unified summary includes both pipelines' results
- Can skip disconnected apps with -SkipDisconnectedApps

---

## DA-24: ISC Source Aggregation (CSV Upload)

- **Status:** `DONE`
- **Commit:** DA-24
- **Depends On:** none

**Description:**
Push validated CSV files to ISC for source aggregation so ISC's own data model reflects
the disconnected app's accounts and entitlements. Uses the `ISCSourceId` config field
that exists but is currently unused.

**The architecture gap:** The toolkit creates SEARCH campaigns targeting ISC identity IDs,
but ISC itself has no record of the disconnected app's accounts. Reviewers in the ISC UI
cannot see the app's entitlement details.

**Two upload methods (implement both, config-selectable):**
1. **API upload:** `POST /beta/sources/{sourceId}/load-accounts` (multipart/form-data)
   - Requires ISC admin scope
   - Works for cloud-only deployments
2. **File drop:** Copy CSV to a VA-accessible path (SFTP/file share)
   - VA pulls the file on its aggregation schedule
   - Works for on-prem VA deployments

**Function:** `Push-SPDisconnectedAppToISC`
```powershell
function Push-SPDisconnectedAppToISC {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$AccountFilePath,
        [Parameter()][string]$EntitlementFilePath,
        [Parameter()][string]$ISCSourceId,
        [Parameter()][ValidateSet('API','FileDrop')][string]$UploadMethod = 'API',
        [Parameter()][string]$FileDropPath,  # for FileDrop method
        [Parameter()][switch]$WaitForAggregation,
        [Parameter()][string]$CorrelationID
    )
}
```

**Config addition:**
```json
"ISC": {
    "UploadMethod": "API",
    "FileDropBasePath": "",
    "WaitForAggregationSeconds": 120
}
```

**Acceptance Criteria:**
- API upload sends CSV to ISC and returns aggregation task ID
- File drop copies CSV to configured VA-accessible path
- -WaitForAggregation polls task status until complete
- Skipped gracefully if ISCSourceId is empty (app not yet registered in ISC)

---

## DA-25: Operational Alerting (Wire Notifications)

- **Status:** `DONE`
- **Commit:** DA-25
- **Depends On:** none

**Description:**
Wire the existing `Notification` config backends (SMTP, Webhook) into the disconnected
app pipeline. Send alerts on: batch failures, threshold blocks, chronic delivery misses,
overdue remediations.

**Alert triggers:**
| Trigger | Severity | Recipients |
|---------|----------|------------|
| Batch run: app failed validation | WARN | Governance team |
| Batch run: threshold blocked (mass deletion) | CRITICAL | Governance team + app owner |
| Batch run: 3+ apps missing files | WARN | Governance team |
| Remediation overdue > 3 days | WARN | App owner + governance team |
| Remediation overdue > 7 days | CRITICAL | App owner + director |
| Batch run: all apps failed (exit code 2) | CRITICAL | Governance team + PagerDuty |

**Function:** `Send-SPDisconnectedAppAlert`
- Reads notification config (SMTP server, webhook URL)
- Sends formatted email or webhook payload
- Falls back to Write-SPLog if notification backends not configured

**Files to Modify:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1` -- new alert function
- `Scripts/Invoke-SPDisconnectedAppBatch.ps1` -- wire alerts at failure points
- Reuse existing `Send-SPNotification` / `Send-SPWebhook` from SP.AuditReport if available

**Acceptance Criteria:**
- Threshold block sends CRITICAL alert with app name and removal percentage
- Missing files after 3 consecutive days triggers WARN
- Alert includes actionable context (what failed, what to do)
- Graceful no-op if notification backends not configured

---

## DA-26: Campaign Lifecycle Management (Cleanup for Disconnected Apps)

- **Status:** `DONE`
- **Commit:** DA-26
- **Depends On:** none

**Description:**
Port the AD delta cert cleanup pattern (`Invoke-SPDeltaCertCleanup`) to disconnected
app campaigns. Auto-complete campaigns past their deadline, preventing ISC from
accumulating hundreds of stale campaigns.

**The operations problem:** 20 apps x 30 days = 600 campaigns. If managers ignore reviews,
ISC's campaign list becomes unmanageable.

**Function:** `Invoke-SPDisconnectedAppCleanup`
- Search for active campaigns matching each app's CampaignNamePrefix
- Complete campaigns past their deadline (uses `Complete-SPCampaign`)
- Respects `Safety.AllowCompleteCampaign` guard
- Integrate as pre-step in batch orchestrator

**Files to Modify:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1` -- new function
- `Scripts/Invoke-SPDisconnectedAppBatch.ps1` -- add cleanup as first step

**Acceptance Criteria:**
- Campaigns past deadline are completed
- AllowCompleteCampaign=false blocks with clear message
- Cleanup runs before new campaign creation (prevents duplicates)
- Log shows which campaigns were cleaned up

---

## DA-27: Historical Trending + Compliance Packaging

- **Status:** `DONE`
- **Commit:** DA-27
- **Depends On:** DA-21

**Description:**
Aggregate disconnected app governance data over time for quarterly/annual compliance
reporting. Package all evidence for a specific audit period.

**Two functions:**

`Get-SPDisconnectedAppTrend`:
- Reads JSONL audit trails (batch runs, decision collections, remediations)
- Calculates per-app quarterly metrics: total accounts, delta counts, campaign completion
  rate, revocation rate, remediation closure rate, average review time
- Returns trend data for charting

`Export-SPDisconnectedAppCompliancePackage`:
- Input: date range (e.g., 2026-Q1)
- Bundles: all delta reports, batch summaries, decision harvests, remediation confirmations
- Generates a manifest with SHA256 checksums per file
- Outputs ZIP file ready for auditor handoff

**Files to Modify:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1` -- new functions

**Acceptance Criteria:**
- Trend function returns per-app per-quarter metrics
- Compliance package includes all evidence for the date range
- SHA256 manifest ensures integrity
- Package includes a cover page with scope and methodology

---

## DA-28: Disconnected App Escalation

- **Status:** `DONE`
- **Commit:** DA-28
- **Depends On:** none

**Description:**
Apply the existing escalation pattern (stale cert detection + org tree walk + reassignment)
to disconnected app campaigns.

Reuse `Get-SPDeltaCertStaleCertifications` and `Invoke-SPDeltaCertEscalate` but filter
campaigns by each app's CampaignNamePrefix.

**Function:** `Invoke-SPDisconnectedAppEscalation`
- For each registered app, find active campaigns matching its prefix
- Detect stale certifications (unsigned past StaleHours threshold)
- Escalate to reviewer's manager
- Integrate into batch orchestrator as a post-step

**Files to Modify:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1` -- new function
  (largely delegates to existing SP.DeltaCert escalation functions)
- `Scripts/Invoke-SPDisconnectedAppBatch.ps1` -- add escalation as final step

**Acceptance Criteria:**
- Filters escalation to disconnected app campaigns only (not AD delta certs)
- Per-app StaleHours configurable (from app registration config)
- Reuses existing Invoke-SPReassign for the actual reassignment
- Logs escalation actions to per-app JSONL

---

## DA-29: Self-Service App Team Dashboard

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** DA-21, DA-22

**Description:**
Generate a per-app HTML status page that app teams can view without PowerShell access.
Refreshed after each batch run, dropped to a web-accessible share.

**Dashboard content per app:**
1. **Delivery Status:** today's file received? validation passed?
2. **Delta Summary:** what changed today (adds, removes, grants, revokes)
3. **Campaign Status:** campaigns created today, pending campaigns, completed campaigns
4. **Remediation Queue:** revocations awaiting confirmation (from DA-22)
5. **SLA Compliance:** 30-day delivery calendar (green/red/gray)
6. **Trend Sparkline:** 90-day access count trend

**Function:** `Export-SPDisconnectedAppTeamDashboard`
- Reads: delivery status, delta summary, decision collection, remediation tracker, SLA data
- Generates: `{ReportPath}/{AppName}/team-dashboard.html`
- Self-contained HTML (inline CSS, no JavaScript dependencies)

**Files to Modify:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1` -- new export function
- Wire into batch orchestrator as final step (after all apps processed)

**Acceptance Criteria:**
- Dashboard is one self-contained HTML file per app
- Shows today's status prominently (delivered/missing/failed)
- Remediation queue shows overdue items in red
- SLA calendar shows 30-day history
- App team can view without PowerShell access (just open HTML in browser)

---

## DA-30: Pester Tests

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** DA-29

**Description:**
Pester tests for DA-21 to DA-29 features.

**File to Modify:** `Tests/SP.DisconnectedApps.Tests.ps1` (add to existing)

**Test IDs:**
- DA-21-T: Decision collection retrieves campaign decisions from ISC (mocked)
- DA-22-T: Remediation tracker creates PENDING record for REVOKE decisions
- DA-22-T2: Remediation confirmed when entitlement absent from next-day CSV
- DA-22-T3: Remediation marked OVERDUE after threshold days
- DA-23-T: Unified orchestrator runs both AD and disconnected app pipelines
- DA-24-T: Push-SPDisconnectedAppToISC calls API upload endpoint (mocked)
- DA-25-T: Alert triggered on threshold block
- DA-26-T: Cleanup completes past-due disconnected app campaigns
- DA-28-T: Escalation filters to disconnected app campaigns only
- DA-29-T: Team dashboard HTML generated with delivery status section

---

## Production Daily Workflow (After DA-21 to DA-30)

```
# Single daily command -- runs everything
.\Scripts\Invoke-SPDailyOrchestrator.ps1 -IncludeDisconnectedApps

# What happens:
Step 1: Config validation
Step 2: AD campaign cleanup
Step 3: AD delta cert (GRANT_ACCESS events -> SEARCH campaigns)
Step 4: AD delta report
Step 5: AD escalation (stale certs -> reassign to manager's manager)
Step 6: Health check
Step 7: Disconnected app cleanup (auto-complete expired campaigns)
Step 8: Disconnected app batch (validate -> delta -> upload to ISC -> campaigns)
Step 9: Decision harvest (check yesterday's campaign outcomes)
Step 10: Remediation check (verify revocations were executed in today's CSV)
Step 11: Send alerts (failures, thresholds, overdue remediations)
Step 12: Generate team dashboards (per-app HTML status pages)
Step 13: Unified summary report

# One command. One credential. One audit trail. One alert channel.
```

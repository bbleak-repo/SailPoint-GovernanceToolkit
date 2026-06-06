# T-01 -- Mock: add Approvals/Workflows/Filters collections to New-BulkSeedData + regenerate seed + verify served counts

## Read
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` (function `New-SailPointData`,
  lines ~1000-1119): the assembled `$data [ordered]@{}` (lines 1077-1095) emitted 14 keys
  ending at `workItems` but DROPPED the five SDK collections the handlers read.
- Helpers reused: `Format-Id` (l.97), `Get-IsoTimestamp` (l.116), `$identArr` (l.599),
  `$entitlementDefs` (l.613), `$trackedPrivilegedRoles` (l.666), `$privRoleMgr` (l.667).
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/SdkHandlers.ps1`
  approval-summary block (l.1445-1473): `pending = count(pendingApprovals)`,
  `approved/rejected` counted by `state` on `completedApprovals`.
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/seed-data.original.json` -- exact
  field shapes for pendingApprovals(4)/completedApprovals(3)/workflows(4)/
  workflowExecutions(5)/campaignFilters(3).

## Did
ADDITIVE only -- inserted one generation block after `$workItems = $workItems.ToArray()`
(line 1060) that builds five collections deterministically (NO new `$rng` draws; literals +
index math + already-settled `$identArr`/`$trackedPrivilegedRoles`/`$privRoleMgr`/
`$entitlementDefs`), then appended five keys to the existing `$data [ordered]@{}` and added
five `Write-Host` count lines to the summary. No existing key/generation/handler/test altered.
`git diff --stat` = 270 insertions, 0 deletions, in 3 additive hunks
(@@ -1059,+265, @@ -1092,+6, @@ -1109,+5).

Collections emitted:
- pendingApprovals = 4 (ids appr-pend-001..004; requestedObject = real tracked priv roles)
- completedApprovals = 4 (3 APPROVED + 1 REJECTED so summary approved>0 AND rejected>0)
- workflows = EXACTLY 4 (wf-001..wf-004; only wf-004 enabled=$false; real booleans)
- workflowExecutions = 6 (3 reference wf-001 so its /executions endpoint is non-empty)
- campaignFilters = 3 (2 INCLUSION + 1 EXCLUSION; full criteriaList shape)

Then regenerated + activated the seed, stopped the prior mock (PID 2880) and restarted
NON-ELEVATED via `Start-MockServer.ps1 -Fresh` (PID 11300). Error-injection/scenario is
in-memory and cleared by the fresh restart (left clean).

## Files
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` (EDIT -- hand-edited, additive)
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/seed-data.json` (REGENERATED output)
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/seed-data-bulk.json` (generator output)
- `C:/temp/Coding/API-mockserver/State/SailPointData.json` (REFRESHED by -Fresh restart)

## Verification

### 0. Parse-check (PowerShell tool, clean)
```
PS> $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw '.../New-BulkSeedData.ps1'), [ref]$null); 'PARSE_OK'
PARSE_OK
```

### Regenerate + activate
```
PS> powershell.exe -NoProfile -ExecutionPolicy Bypass -File Scripts/New-BulkSeedData.ps1 -Profile SailPoint-ISC -Activate
  SDK PendingAppr:   4
  SDK CompletedAppr: 4
  SDK Workflows:     4
  SDK WfExecutions:  6
  SDK CampFilters:   3
  Activated: .../seed-data.json
```
Restarted NON-ELEVATED: Start-MockServer.ps1 -Fresh -> PID 11300 -> MOCK_UP.

### 2. NEW collections non-empty (the core fix)
```
pending=4
completed=4
summary pending=4 approved=3 rejected=1
workflows=4
disabled=wf-004
enabledCount=3
wf001execs=3
filters=3
```
All expectations met: pending>=4, completed>=3, summary all>0, workflows=4 with only
wf-004 disabled, wf-001 executions>=1, filters>=3.

### 3. ENRICHED data NOT shrunk (regression guard)
```
templates=10
sources=6
workitems open=7 completed=23
campaigns=38
```
templates=10 (unchanged), sources=6 (>=6), work-items open>0 AND completed>0, campaigns=38.
NOTE on campaigns: the generator produces 38 campaigns (3 base + 30 daily-priv + completed
shapes); the "~53" in the spec refers to an earlier dataset. My change touched NO campaign
generation (diff is pure insertion in the 3 additive hunks above), so 38 is the generator's
own deterministic output, not a regression from this item.

### 4. Integration smoke (mock repo)
```
PS> powershell.exe -File Tests/Integration/Test-SailPointWorkflow.ps1
Steps 1-11: ALL PASS (campaigns, certs, review items, decide, sign-off, activate, reports)
Step 12 FAILS: GET /v3/identities/id-pres -> 404 "Identity 'id-pres' not found"
```
This Step-12 failure is PRE-EXISTING and unrelated to T-01: `id-pres` is hard-coded in the
integration test (l.323) and exists only in the hand-authored seed-data.original.json
(82 identities incl id-pres). The bulk generator produces `id-gen-*`/`id-vp-*`/`id-dir-*`
IDs and never emitted `id-pres` -- so Step 12 would fail identically against the
pre-existing generated seed. My additive edit touched no identity generation. Steps 1-11
(everything T-01 could affect) all PASS.

## Commit
- MOCK repo (C:/temp/Coding/API-mockserver, branch feature/manager-cert-30day-sim):
  `4a0f057` -- feat(mock-seed): emit SDK approvals/workflows/campaign-filters collections in New-BulkSeedData
  (3 files: Scripts/New-BulkSeedData.ps1, Profiles/SailPoint-ISC/seed-data.json, State/SailPointData.json)
- TOOLKIT repo: this record file committed separately on feature/manager-cert-30day-sim.

## Status
DONE -- all T-01 acceptance probes pass; only pre-existing/unrelated Step-12 failure remains.

# Round 01 - T-01 CODE-REVIEW GATE (independent)

Item: Mock -- add Approvals/Workflows/Filters collections to New-BulkSeedData + regenerate seed + verify served counts.

VERDICT: PASS | additiveOnly: true | claimsVerified: true

## Commits verified to exist
- MOCK repo (C:/temp/Coding/API-mockserver), branch feature/manager-cert-30day-sim:
  `4a0f057` feat(mock-seed): emit SDK approvals/workflows/campaign-filters collections in New-BulkSeedData -- `git cat-file -t` => commit. Touches EXACTLY the 3 claimed files: Scripts/New-BulkSeedData.ps1, Profiles/SailPoint-ISC/seed-data.json, State/SailPointData.json. Co-Authored-By present.
- TOOLKIT repo, branch feature/manager-cert-30day-sim:
  `b6930e5` docs(loop): record autoloop3 T-01 -- touches only round-01-t-01.md (+109). Co-Authored-By present.

## Generator diff is purely additive
`git show 4a0f057 -- Scripts/New-BulkSeedData.ps1`: 3 hunks, +270 / -0. No deletion lines. No new $rng/Get-Random/.Next() draws in inserted block (only a comment mentions rng). New block inserted after `$workItems = $workItems.ToArray()`; 5 keys appended to `$data` [ordered] after workItems; 5 Write-Host summary lines added. No campaign generation touched (only literal `recipientId='campaign-owner'` inside a workflow step).

## Pre-existing collections NOT shrunk (seed-data.json fc2be54 vs 4a0f057)
KEY                        PREV   NEW
sources                       6      6
identities                  100    100
campaigns                    38     38
certifications              315    315
entitlements                200    200
trackedPrivilegedRoles       10     10
campaignTemplates            10     10
workItems                    30     30
pendingApprovals        MISSING      4
completedApprovals      MISSING      4
workflows               MISSING      4
workflowExecutions      MISSING      6
campaignFilters         MISSING      3

Campaigns were ALREADY 38 in the prior committed seed -- the "~53" in the spec is an earlier dataset; this change did not shrink campaigns. The 5 SDK collections went MISSING -> populated.

## Live API probes (fresh mock http://localhost:8080)
pending=4 ; completed=4 ; summary pending=4 approved=3 rejected=1
workflows=4 ; disabled=wf-004 ; enabledCount=3 ; wf001execs=3
filters=3 ; filterModes=INCLUSION,INCLUSION,EXCLUSION
Regression guard: templates=10, sources=6, campaigns=38, work-items open=7 completed=23.

## Field-shape spot check (served rows)
PENDING[0]: id=appr-pend-001, requester=James Smith, owner=James Smith, requestedObject=AD-SG-Admins-3, valid ISO created.
REJECTED completed: appr-comp-004 state=REJECTED reviewerComment.comment populated.
FILTER[0]: filt-001 mode=INCLUSION criteriaList[0] name=Admin isSystemFilter=False.
Shapes match SdkHandlers expectations (state counted as APPROVED/REJECTED in approval-summary handler; campaignFilters/workflows/executions keys read directly).

## Parse + hygiene
PSParser.Tokenize(New-BulkSeedData.ps1) => PARSE_OK.
Mock ahead 1, NOT pushed. master/main untouched in both repos.

All inner claims reconciled true. No discrepancies.

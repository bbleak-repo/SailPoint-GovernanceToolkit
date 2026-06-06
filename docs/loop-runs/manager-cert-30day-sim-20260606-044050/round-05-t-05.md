# T-05 -- Validation Pester suite: manager-cert correctness, removal detection, privileged-role + manager-accountability, 7d vs 30d deltas

## Read
- `docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-05-t-05-spec.md` -- the MIDDLE spec for this item.
- `Tests/SP.LeadershipAttribution.Tests.ps1` -- canonical org-tree / band / leadership-rollup pattern ($script:-scoped fixtures, `Mock -ModuleName SP.DeltaCertQueries`/`SP.AuditReportCore`, Build-SPOrgTree / Resolve-SPIdentityBand / Group-SPAuditByLeadership invariants).
- `Tests/SP.DeltaCert.Tests.ps1` -- mock activity-event builder shape + `Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries`, `Get-SPConfig`/`Write-SPLog` module-scoped mocks.
- `Tests/SP.Campaigns.Tests.ps1` -- New/Start/Get-SPCampaign mock + return shape contract.
- `Tests/Import-TestModules.ps1` -- flat-import loader; `-Core -Api -Audit -DeltaCert`.
- `Modules/SP.Api/SP.Campaigns.psm1` -- `New-SPCampaign` (param `-CertifierIdentityId`; MANAGER body carries `certifiers=@(@{type='IDENTITY';id=...})` via `Build-SPCampaignBody`), `Start-SPCampaign` (`/campaigns/{id}/activate`), `Get-SPCampaign`, `Search-SPCampaigns` (`-Keyword`, auto-paginates, calls `Get-SPConfig`).
- `Modules/SP.Audit/SP.AuditOperations.psm1` -- `Send-SPReport`: when `Audit.Smtp.Enabled` is false it returns `@{Success=$true; Data=@{Action='Logged'; Recipient; File; Subject}; Error=$null}` and does NOT call `Send-MailMessage`; Write-SPLog component `SP.AuditReport`, module `SP.AuditOperations`.
- `Modules/SP.DeltaCert/SP.DeltaCertReport.psm1` -- `Get-SPDeltaRevokeEvents` (GET `/account-activities`, filter `type eq "REVOKE_ACCESS"`, items `operation -eq 'REMOVE'`, client-side HoursBack window; returns `IdentityId/SourceId/ItemValue`). It is **NOT exported** (Export-ModuleMember exports only Get-SPDeltaReportData + Export-SPDeltaReportHtml), so it must be exercised via `InModuleScope SP.DeltaCertReport`.
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1` -- from-date/to-date window semantics: `[datetime]$_.date >= capturedFrom` -- replicated in the suite's Layer-A window filter.
- `C:/temp/Coding/API-mockserver/State/SailPointData.json` -- source of the frozen fixture (seed 20260606).

## Did
- Copied the mock State JSON to `Tests/TestData/ManagerCert30DaySim.State.json` (frozen, deterministic fixture; 6.5 MB; not gitignored).
- Added `Tests/SP.ManagerCert30DaySim.Tests.ps1` -- a Pester 5 suite with 45 tests across MC-01..MC-07. Two layers against the frozen fixture: Layer A = pure data-truth assertions; Layer B = real toolkit functions with mocked transport.
- Derived facts FROM the fixture in-suite rather than hardcoding stale numbers. Confirmed the seed anchors actually present in the frozen copy:
  - `trackedPrivilegedRoles` = 10 (ent-003 AD-SG-Admins-3 mgr id-gen-001; ent-017 AD-SG-Marketing-17 mgr id-gen-002).
  - `ent-003.attributes.privileged=$true`, members = id-gen-069, id-gen-035, id-gen-050.
  - 1366 changelog events; 584 REMOVE total. **Anchor = newest daily-campaign `created` = 2026-06-05T12:16:28Z** (NOT Get-Date, and NOT the newest changelog date which is a day later and would shift the 7d window). With that anchor: REMOVE within 7d = 223, within 30d = 584; daily camps in 7d = 8, 30d = 30.
  - Named 7d removal id-gen-043 from ent-009 AD-SG-HR-9 (2026-05-30) -> in BOTH 7d & 30d. Priv-role removal id-gen-006 from ent-003 (2026-05-16) -> 30d ONLY (proves the window filters).
  - `camp-daily-priv-01` (2026-06-05): managerAttestation[10]; id-gen-002 Mary Johnson = missed (3/4), id-gen-007 Michael Miller = overdue, id-gen-001 James Smith = attested.
- MC-01 grounded in the REAL fixture manager chain id-gen-011 -> id-gen-006 -> id-gen-003 -> id-gen-001 (a genuine 4-rung chain in the dataset); asserts depth levels, depth-derived bands E/D/C/B, and certifier=manager leadership rollup with no double-count.
- Pester-5 scoping: helper functions defined at top-of-file (for DISCOVERY) AND re-defined inside the top-level `BeforeAll` (Pester 5 does not surface file-body functions into the run-time BeforeAll scope); `-ForEach` data + named anchors computed at discovery into `$script:` vars.
- MC-03 Layer B invokes the unexported `Get-SPDeltaRevokeEvents` via `InModuleScope SP.DeltaCertReport` and asserts the endpoint with `Should -Invoke ... -Scope Context` inside InModuleScope (call happens in BeforeAll).
- MC-04 emulates the campaign WRITE round-trip with an in-memory store mock of Invoke-SPApiRequest (POST /campaigns, POST /:id/activate, GET /campaigns/{id}, GET /campaigns) and submits 10 MANAGER campaigns, one per tracked privileged role.
- No existing suite/module/test was edited (additive). Did not add the new test to SP.CliScripts.Tests.ps1 (it is a test file, not a CLI script).

## Files
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Tests/SP.ManagerCert30DaySim.Tests.ps1` (CREATE)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Tests/TestData/ManagerCert30DaySim.State.json` (CREATE -- frozen fixture)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-05-t-05.md` (CREATE -- this record)

## Verification
All from `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit` (Windows PowerShell 5.1).

(1) Parse check:
```
powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Tests/SP.ManagerCert30DaySim.Tests.ps1',[ref]$null,[ref]$e); 'ParseErrors=' + @($e).Count"
=> ParseErrors=0
```

(2) Fixture present:
```
powershell -NoProfile -Command "Test-Path 'Tests/TestData/ManagerCert30DaySim.State.json'"
=> True
```

(3) Affected-suite gate (run ONLY this file):
```
Invoke-Pester -Path .\Tests\SP.ManagerCert30DaySim.Tests.ps1 -Output Detailed
```
Real summary line:
```
Pester v5.7.1
Discovery found 45 tests in ...
Tests completed in 6.x s
Tests Passed: 45, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```
All seven areas present and green in the Detailed output:
- MC-01: Manager cert ORG + MANAGER reports attribute the real fixture chain to correct bands and leaders (6 It)
- MC-02: SMTP-WhatIf logs each leader email as Action='Logged' and never sends a real email (3 It; Send-MailMessage invoked 0 times)
- MC-03: REMOVED users detected/shown in BOTH 7d and 30d -- Layer A (3 It) + Layer B Get-SPDeltaRevokeEvents (3 It)
- MC-04: Campaign WRITE path round-trips -- 10 MANAGER campaigns submit/activate/found (5 It)
- MC-05: 7-day vs 30-day deltas/trends (4 It)
- MC-06: Privileged-role reports -- 10 roles, members, day-over-day churn (5 It incl. 10 -ForEach privileged-flag cases)
- MC-07: Manager accountability -- per-day status + monotone window rollup (7 It)

(Full `Invoke-Pester .\Tests` NOT run here -- that is the Finalize gate.)

## Commit
704478b test(sim): add 30-day manager-cert validation Pester suite (T-05)
(initial commit 6f9bc95, amended to 704478b to embed the final hash in this record)

## Status
DONE

# T-02 -- Model + validate OVERDUE/MISSED attestation, org-chain ESCALATION, and reassignment/delegation

## Read
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` (daily-campaign loop ~l.705-818, `$privRoleMgr` build ~l.571-580, per-manager attestation block, cert.reassignment field) -- confirmed status is RNG-drawn ONLY on day-1 (`$isMostRecent`) and hardcoded `'attested'` days 2..30, and `reassignment = $null` on every cert.
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Tests/SP.ManagerCert30DaySim.Tests.ps1` (BeforeDiscovery/BeforeAll fixture loaders, `Get-MC30AccountabilityRollup`, MC-07 day-1 anchors at l.856-869, MC-04/MC-08 `Invoke-SPApiRequest` mock shape).
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Modules/SP.Audit/SP.AuditQueries.psm1` (Get-SPAuditCertifications l.539-669: reads `cert.reassignment.to` -> `EffectiveReviewer`, classification `'Reassigned'`; page normalization `$page = $result.Data` then `@($page)` -- it does NOT unwrap a hashtable `items` key, so the mock must return `Data` as the cert array directly).
- Verified the REAL org chain against the live frozen fixture: `id-gen-006` (Jennifer Garcia) -> `id-gen-003` (Robert Williams) -> `id-gen-001` (James Smith); `id-gen-007` -> `id-gen-004` -> `id-gen-001`.

## Did
ADDITIVE, deterministic (NO new rng draw anywhere -- the frozen MC-01..MC-08 anchors are byte-identical):
1. **mock** (`New-BulkSeedData.ps1`): before the daily loop added `$escalationChain` (real up-chain map), `$escNameById` (deterministic name lookup), `$streakManagerId='id-gen-006'`, `$streakDays=8`.
2. **mock**: inside the per-manager attestation block, for the streak manager on days `1..$streakDays`, deterministically override status from the loop index: `$daysOverdue = $streakDays - $d + 1` (counts UP toward the present so the streak STARTS overdue at the oldest day and ESCALATES to missed toward today), `$st = overdue` while `daysOverdue<=4` else `missed`, `$escalationLevel = 1` (-> direct manager id-gen-003) while overdue else `2` (-> VP id-gen-001), `escalatedTo`/`escalatedToName` from `$escalationChain`. APPENDED 4 new keys (`daysOverdue`, `escalationLevel`, `escalatedTo`, `escalatedToName`) to the existing `[ordered]@{}` -- the original 5 keys keep their position. Non-streak managers get `0/$null` so MC-01..MC-08 are untouched.
3. **mock**: populated `cert.reassignment` for ONE deterministic cert (streak manager on the most-recent day) -- `from=id-gen-006`, `to=id-gen-003`, reason + date. Every other cert stays `$null`.
4. Regenerated `State/SailPointData.json` (seed 20260606) and refreshed the frozen toolkit fixture.
5. **toolkit tests**: appended Describe block **MC-09** (10 tests) after MC-07 -- Layer A data-truth (>=7-consecutive-day non-attest streak, overdue->missed transition, escalation up the real chain id-gen-003 then id-gen-001, valid identity, monotone daysOverdue, non-streak managers un-escalated, single delegated cert from->to) + Layer B (real `Get-SPAuditCertifications` over a mocked transport returning the fixture cert proves `ReviewerClassification='Reassigned'` and `EffectiveReviewer.id='id-gen-003'`).

No toolkit module code changed -- the existing `Get-SPAuditCertifications` reassignment classifier consumes the new `reassignment.to` for free (the spec's preferred no-new-code path).

## Files
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` (mock repo, EDIT)
- `C:/temp/Coding/API-mockserver/State/SailPointData.json` (mock repo, regenerated)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Tests/TestData/ManagerCert30DaySim.State.json` (toolkit repo, refreshed fixture)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/Tests/SP.ManagerCert30DaySim.Tests.ps1` (toolkit repo, EDIT -- appended MC-09)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/docs/loop-runs/autoloop1-20260606-082147/round-02-t-02.md` (this record)

## Verification
1. Parse-check the generator:
   `[Parser]::ParseFile('.../New-BulkSeedData.ps1', ...)` -> `PARSE-OK`
2. Backed up prior State to `State/_backups/SailPointData.20260606-083919.json`, then regenerated:
   `powershell -NoProfile -File New-BulkSeedData.ps1 -Profile SailPoint-ISC -Scale 100 -Seed 20260606 -OutputPath State/SailPointData.json`
   -> `Daily Campaigns:30  Certifications:315  File size: 6.35 MB  Done.`
3. Refreshed fixture via `Copy-Item ... State/SailPointData.json ... Tests/TestData/ManagerCert30DaySim.State.json -Force` -> `refreshed`.
4. Data-truth headless check on the refreshed fixture:
   `maxStreak=8`
   `escTo=id-gen-003 lvl=1`
   `escValid=True`
   `reassignFrom=id-gen-006 to=id-gen-003`
   (EXPECTED maxStreak>=7, escValid=True, from=id-gen-006 to=id-gen-003 -- all met.)
   Calendar-order streak (oldest first): priv-08 overdue/dOver=1/lvl1->id-gen-003 ... priv-05 overdue/dOver=4/lvl1 -> priv-04 missed/dOver=5/lvl2->id-gen-001 ... priv-01 missed/dOver=8/lvl2.
5. Targeted Pester (toolkit): `Invoke-Pester -Path Tests/SP.ManagerCert30DaySim.Tests.ps1 -Output Detailed`
   -> **Tests Passed: 65, Failed: 0, Skipped: 0** (MC-01..MC-08 all still green; new MC-09 10/10 green incl. the Layer-B Reassigned/EffectiveReviewer assertions).
6. No Export-SPRollingTrendHtml change made (no-new-code path), so SP.RollingTrendHtml.Tests.ps1 not required for this item; full suite runs in Finalize.

## Commit
- mock repo: see commitHash below (`feat(mock): ...`).
- toolkit repo: see commitHash below (`test(mgr-cert): ...`).

## Status
DONE

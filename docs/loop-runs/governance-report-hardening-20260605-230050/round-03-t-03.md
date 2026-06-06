# T-03 -- Leadership band attribution + org-chain rollup correctness tests and minimal fix

**Read**
- `Tests/Import-TestModules.ps1` -- confirmed `Import-SPTestModules -Core -Api -Audit -DeltaCert` (flat-import rule; mocks target the `.psm1` base name).
- `Tests/SP.LeadershipReport.Tests.ps1` -- copied `New-MockIdentityDetail` (lines 31-48), `New-MockOrgTreeData` fixture shape (lines 55-131), the `$script:mockDetails` + `Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries` pattern (lines 246-263), and the LR-03 `__unmanaged__` unknown-identity case (lines 567-591).
- `Tests/SP.OrgChart.Tests.ps1` -- OC-06 ISC-cache override pattern: `InModuleScope SP.DeltaCertQueries { $script:IdentityCache[...] = ... }` seed (lines 771-788) and `AfterAll { ... $script:IdentityCache.Remove(...) }` cleanup (lines 795-801).
- `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1` -- `Build-SPOrgTree` (line 898; leaf=0, +1 per manager step, `MaxDepth` default 3 truncates a 5-deep chain, cycle detection, TopLeaders for level >=3) and `Resolve-SPIdentityBand` (line 2704; default depth map `0=E..4=A`, priority Supplement > ISC(`$script:IdentityCache`.JobLevel) > Depth).
- `Modules/SP.Audit/SP.AuditReportCore.psm1` -- `Group-SPAuditByLeadership` (line 1320; name->leaf->manager->director mapping, Directors rollup, per-level Levels with level-N aggregating level N-1 subtree, Executive rollup, `__unmanaged__` bucket).

**Did**
- Authored `Tests/SP.LeadershipAttribution.Tests.ps1` (NEW) with 21 tests in 4 Describe blocks, asserting against hand-computed governance truth:
  - **LA-01** (9 tests): synthetic 5-level chain CEO->VP->Director->Manager->IC built via `Build-SPOrgTree -IdentityIds @('id-ic') -MaxDepth 4` (MaxDepth 4 required so level-4 CEO is not truncated). Asserts node count = 5; per-rung Levels 0..4; child wiring; CEO (ManagerId='') in TopLeaders; `Resolve-SPIdentityBand` bands ic=E,mgr=D,dir=C,vp=B,ceo=A; Source='Depth' for all; Summary @{A=1;B=1;C=1;D=1;E=1}; no null bands.
  - **LA-02** (7 tests): local `New-MockOrgTreeData` (VP->DirA->{Mgr1:Alice,Bob; Mgr2:Carol}, DirB->Mgr3:{Dave,Eve}). Asserts each identity lands under the right director; no cross-attribution (DirA managers = mgr1+mgr2 only); director TotalItems == sum of its managers (no double-count); VP Executive TotalItems == sum of both directors counted once (=5); VP references exactly dir-a+dir-b; Approved+Revoked+Pending==TotalItems for every director AND the VP.
  - **LA-03** (3 tests): a decision for an identity name absent from the tree lands in `__unmanaged__` with exactly 1 item, is NOT counted under any real director (real total unchanged at 1), and is not silently dropped (real+unmanaged == 2).
  - **LA-04** (2 tests): seeds `$script:IdentityCache['la04-ic'].JobLevel='B'` via `InModuleScope SP.DeltaCertQueries`; asserts ISC source overrides Depth (band='B', Source='ISC') for the seeded node while un-seeded nodes stay Depth-sourced; `AfterAll` removes the cache key.
- **No production change.** Every assertion passed against hand-computed truth on the first run, so the spec's "minimal fix" is a no-op (explicitly anticipated/acceptable by the spec). No edit was made to `SP.DeltaCertQueries.psm1` or `SP.AuditReportCore.psm1`. No existing function/export/test was removed, renamed, or weakened. The new test file is the additive deliverable.

**Files**
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Tests\SP.LeadershipAttribution.Tests.ps1` (CREATE)
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\docs\loop-runs\governance-report-hardening-20260605-230050\round-03-t-03.md` (CREATE, this record)

**Verification** (real commands + real output)

1) Parse/syntax check (suppressed AST output via `$null =`):
```
PS> $t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('Tests\SP.LeadershipAttribution.Tests.ps1',[ref]$t,[ref]$e); if($e){$e|ForEach-Object{$_.Message};exit 1}else{'PARSE-OK'}
PARSE-OK
```

2) No production fix made -> module re-import step not required (no module edited).

3) Run the NEW test file:
```
PS> Invoke-Pester -Path .\Tests\SP.LeadershipAttribution.Tests.ps1 -Output Detailed
Pester v5.7.1
Discovery found 21 tests in 365ms.
Describing LA-01: Build-SPOrgTree + Resolve-SPIdentityBand attribute the full A-E chain
 Context When given a 5-level chain CEO -> VP -> Director -> Manager -> IC
   [+] Should return Success=true for Build-SPOrgTree
   [+] Should build exactly 5 nodes (IC + Manager + Director + VP + CEO)
   [+] Should assign the correct depth level to each rung of the chain
   [+] Should wire each child under its correct manager
   [+] Should place the CEO (no manager) at the top of the chain via TopLeaders
   [+] Should resolve the correct band letter for each level (E..A)
   [+] Should source every band from Depth (no supplement/cache present)
   [+] Should summarise exactly one identity in each band A..E
   [+] Should assign a non-null band to every node
Describing LA-02: Group-SPAuditByLeadership attributes each identity to the RIGHT leader and rolls up subtrees without double-count
 Context When given decisions across both directors under one VP
   [+] Should attribute Alice/Bob/Carol to Director A (id-dir-a)
   [+] Should attribute Dave/Eve to Director B (id-dir-b)
   [+] Should NOT cross-attribute: Director A holds none of Director B's identities
   [+] Should make each director's TotalItems == sum of its managers' items (no double-count)
   [+] Should roll the VP Executive total to the sum of both directors, counted once
   [+] Should reference exactly the two directors under the VP
   [+] Should satisfy Approved + Revoked + Pending == TotalItems for every director AND the VP
Describing LA-03: orphaned/missing-manager identity goes to the documented __unmanaged__ bucket, not silently dropped
 Context When a decision names an identity not present in the org tree
   [+] Should create the __unmanaged__ bucket with exactly the 1 orphan item
   [+] Should NOT count the orphan under any real director
   [+] Should not silently drop any decision (real + unmanaged totals == 2)
Describing LA-04: band attribution honors supplement/ISC override on the same A-E chain
 Context When one node carries an ISC jobLevel that disagrees with its tree depth
   [+] Should let ISC jobLevel override depth for the seeded node
   [+] Should still source the un-seeded nodes from Depth
Tests completed in 3.67s
Tests Passed: 21, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

4) Run existing leadership + org-chart suites to prove ADDITIVE:
```
PS> Invoke-Pester -Path .\Tests\SP.LeadershipReport.Tests.ps1,.\Tests\SP.OrgChart.Tests.ps1 -Output Detailed
Pester v5.7.1
Discovery found 141 tests in 428ms.
... (LR-01..LR-06 all [+]; OC-01..OC-09 all [+]) ...
Tests completed in 7.85s
Tests Passed: 141, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
EXIT=0
```

Pass criteria met: step 1 = PARSE-OK; step 3 = Failed 0 (LA-01..LA-04 band/attribution/rollup/orphan all green); step 4 = Failed 0 (no regression in LR-01/LR-02/LR-03/OC-06 etc.). No dashboard/FlaUI/W-08b interactive gate launched. Full suite deferred to Finalize.

**Commit**
- `5e8d8ac` -- test(audit): add leadership band attribution + org-chain rollup correctness tests (T-03)
  (Round-05 doc-accuracy fix: corrected the recorded hash from the pre-amend `9c7dd15` to the actual
  `5e8d8ac` reported by `git log -- round-03-t-03.md`.)

**Status**
- DONE

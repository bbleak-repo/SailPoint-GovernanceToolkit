# Round 06 -- INNER (fix): T-03 regression guard PS 5.1 array-flattening trap

## Did
Fixed a real bug in the T-03 empty-collection regression guard. Three `It` blocks
in `Tests/SP.MockSdkCollections.Tests.ps1` used `@(& $script:Probe '...').Count`
where `& $script:Probe` returns an `Object[]` from `Invoke-RestMethod`. In Windows
PowerShell 5.1, `@(...)` around a DIRECT array-returning expression does NOT unroll
the inner array -- it wraps the whole `Object[]` as a single element, so `.Count`
is ALWAYS 1 regardless of served data. That meant the assertions evaluated
`1 -gt 0 = PASS` even when the mock regressed to serving an empty `[]` -- defeating
the exact empty-collection regression these tests were authored to catch.

Switched the 3 broken blocks to the assign-first idiom
(`$x = & $script:Probe '...'; @($x).Count | Should -BeGreaterThan 0`), which
unrolls correctly so an empty `[]` yields `.Count = 0` and the guard fires.

Blocks fixed:
- L93  completed-approvals  (`/v3/access-request-approvals/completed`)
- L118 campaign-filters     (`/v3/campaign-filters`)
- L122 campaign-templates   (`/v3/campaign-templates`)

The sibling blocks that already assigned first (pending, workflows, executions)
and the summary-field blocks were already correct and were left unchanged.
Change is additive/corrective only -- no endpoints, exports, or other tests touched.

## Files
- C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Tests\SP.MockSdkCollections.Tests.ps1

## Verification (real output)

### Proof the trap is real and the assign-first form catches empty arrays
Probed a known-empty endpoint (`/v3/workflows/wf-DOESNOTEXIST/executions` -> `[]`):
```
broken-form (direct @()) count: 1
assign-first count: 0
```
The broken form reports 1 for an empty array (false PASS); assign-first reports 0
(would correctly FAIL the guard). The fix uses assign-first.

### Affected test (mock up at http://localhost:8080, health: ok)
Invoke-Pester Tests/SP.MockSdkCollections.Tests.ps1 -Output Detailed
```
Describing SP.MockSdkCollections - mock serves non-empty SDK collections (seed-drop regression guard)
 Context Live mock SDK collections are non-empty
   [+] serves >=1 pending approval (/v3/access-request-approvals/pending) 205ms
   [+] serves >=1 completed approval (/v3/access-request-approvals/completed) 50ms
   [+] serves an approval-summary with pending+approved+rejected total > 0 (...) 44ms
   [+] serves >=1 workflow (/v3/workflows) 43ms
   [+] serves >=1 execution for at least one workflow (...) 85ms
   [+] serves >=1 campaign-filter (/v3/campaign-filters) 52ms
   [+] serves >=1 campaign-template (/v3/campaign-templates) 50ms
   [+] serves a work-items summary with open+completed > 0 (...) 44ms
Tests Passed: 8, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

### Full suite gate
Invoke-Pester .\Tests
```
Tests completed in 490.93s
Tests Passed: 1301, Failed: 0, Skipped: 1, Inconclusive: 0, NotRun: 0
```

## Commit
See structured result for hash. Branch: feature/manager-cert-30day-sim. No push.

## Status
DONE -- bug fixed, affected test + full suite green.

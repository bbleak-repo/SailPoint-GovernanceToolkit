# T-03 -- Toolkit: add a Pester regression test asserting the mock serves non-empty SDK collections

**Read**
- `Tests/SP.AdaptiveTabEnrichedGui.Tests.ps1` (lines 1-30) -- mirrored the `#Requires` header,
  `.SYNOPSIS` comment style, and Describe/Context/It + BeforeAll patterns.
- Live mock health probe `GET http://localhost:8080/health` -> `{"status":"ok",...}` confirming the
  mock was up and serving the enriched data this session.

**Did**
- CREATED a brand-new Pester 5.x live-probe regression test that catches the exact regression that
  triggered this run (seed regeneration dropping Approvals/Workflows/Filters). Pure raw
  `Invoke-RestMethod` probing -- no toolkit modules imported.
- BeforeAll: BaseUrl overridable via `$env:SP_MOCK_BASEURL` (default `http://localhost:8080`);
  reachability probe to `/health` sets `$script:MockUp`; obtains the OAuth Bearer token EXACTLY ONCE
  (mock tokens rotate -- a mid-suite re-fetch can 401) and reuses `$script:Headers` for every probe;
  `$script:Probe` closure GETs a `/v3` endpoint with the bearer header.
- Context BeforeEach: `Set-ItResult -Inconclusive` when the mock is not reachable / OAuth failed, so
  the full suite stays GREEN in headless CI without a running mock.
- 8 `It` assertions: pending approvals >=1, completed approvals >=1, approval-summary
  pending+approved+rejected > 0, workflows >=1, >=1 execution for at least one workflow (loops ALL
  workflow ids, does not assume the first has executions), campaign-filters >=1, campaign-templates
  >=1, work-items summary open+completed > 0.
- ADDITIVE: brand-new file; touches no existing code, endpoint, or test.

**Files**
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Tests\SP.MockSdkCollections.Tests.ps1` (new)
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\docs\loop-runs\autoloop3-sdk-collections-20260606-1620\round-04-t-03.md` (this record)

**Verification** (exact commands + REAL output)

1) Mock-UP, all assertions PASS:
```
powershell -NoProfile -Command "Invoke-Pester -Path Tests/SP.MockSdkCollections.Tests.ps1 -Output Detailed"
```
```
Pester v5.7.1
Discovery found 8 tests in 370ms.
Describing SP.MockSdkCollections - mock serves non-empty SDK collections (seed-drop regression guard)
 Context Live mock SDK collections are non-empty
   [+] serves >=1 pending approval (/v3/access-request-approvals/pending) 248ms
   [+] serves >=1 completed approval (/v3/access-request-approvals/completed) 56ms
   [+] serves an approval-summary with pending+approved+rejected total > 0 (/v3/access-request-approvals/approval-summary) 61ms
   [+] serves >=1 workflow (/v3/workflows) 55ms
   [+] serves >=1 execution for at least one workflow (/v3/workflows/{id}/executions) 100ms
   [+] serves >=1 campaign-filter (/v3/campaign-filters) 52ms
   [+] serves >=1 campaign-template (/v3/campaign-templates) 49ms
   [+] serves a work-items summary with open+completed > 0 (/v3/work-items/summary) 47ms
Tests completed in 1.9s
Tests Passed: 8, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

2) Skip-when-down safety net -- static check:
```
Select-String -Path Tests/SP.MockSdkCollections.Tests.ps1 -Pattern 'Set-ItResult|-Inconclusive|-Skip'
```
```
28: marked Inconclusive via Set-ItResult so the full suite stays GREEN in a
83: Set-ItResult -Inconclusive -Because 'mock not reachable at /health or OAuth failed; live regression guard skipped (headless CI without a mock stays green)'
```

   Stronger proof (point the BaseUrl at a dead port, re-run):
```
$env:SP_MOCK_BASEURL='http://localhost:9'; Invoke-Pester -Path ...SP.MockSdkCollections.Tests.ps1 -PassThru -Output None; Remove-Item Env:SP_MOCK_BASEURL
-> Passed=0 Failed=0 Inconclusive=8 Skipped=0
```

3) Parse/lint check (PS 5.1):
```
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path Tests/SP.MockSdkCollections.Tests.ps1), [ref]$null, [ref]$null); 'PARSE-OK'
-> PARSE-OK
```

**Commit**
- f0c93ae test(mock): add SP.MockSdkCollections live regression guard for non-empty SDK collections

**Status**
DONE

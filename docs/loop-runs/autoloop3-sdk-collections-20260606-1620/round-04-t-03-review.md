# Round 04 -- T-03 CODE-REVIEW GATE

**Item:** Toolkit: add a Pester regression test asserting the mock serves non-empty SDK collections.
**Verdict:** PASS
**additiveOnly:** true
**claimsVerified:** true

## Independent verification

### 1. Live Pester run (mock UP at http://localhost:8080)
```
$ curl -s http://localhost:8080/health
{"port":8080,"status":"ok","profiles":[...],"uptime":"2026-06-06T17:20:04Z"}

$ powershell -NoProfile -Command "Invoke-Pester -Path Tests/SP.MockSdkCollections.Tests.ps1 -Output Detailed"
Pester v5.7.1 -- Discovery found 8 tests.
Describing SP.MockSdkCollections - mock serves non-empty SDK collections (seed-drop regression guard)
 Context Live mock SDK collections are non-empty
   [+] serves >=1 pending approval (/v3/access-request-approvals/pending)
   [+] serves >=1 completed approval (/v3/access-request-approvals/completed)
   [+] serves an approval-summary with pending+approved+rejected total > 0
   [+] serves >=1 workflow (/v3/workflows)
   [+] serves >=1 execution for at least one workflow (/v3/workflows/{id}/executions)
   [+] serves >=1 campaign-filter (/v3/campaign-filters)
   [+] serves >=1 campaign-template (/v3/campaign-templates)
   [+] serves a work-items summary with open+completed > 0 (/v3/work-items/summary)
Tests Passed: 8, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

### 2. Skip-when-down safety net (dead port)
```
$ $env:SP_MOCK_BASEURL='http://localhost:9'; Invoke-Pester ... -PassThru
Passed=0 Failed=0 Inconclusive=8 Skipped=0
```
Confirmed: Set-ItResult -Inconclusive (line 83, BeforeEach) keeps the full suite GREEN with no mock. 0 Failed.

### 3. Files / commit reconcile
```
$ git diff --name-status HEAD~2 HEAD
A  Tests/SP.MockSdkCollections.Tests.ps1
A  docs/loop-runs/.../round-04-t-03.md   (+ 1-line hash fix in 2af0265)
```
- Claimed filesChanged match the actual diff (new test file + journal record). Purely ADDITIVE (two A entries, no M/D to existing code/tests/endpoints).
- commitHash 99655d2 exists (git cat-file -t -> commit); follow-up 2af0265 exists.
- Co-Authored-By present on both commits.
- Not pushed (commits ahead of origin); master untouched (item commits are above master..HEAD only as additive history); mock repo not touched by this toolkit item.

## Goal-fit
The test catches the exact seed-drop regression: asserts non-empty pending/completed approvals,
approval-summary total>0, workflows>=1, per-workflow executions, campaign-filters>=1,
campaign-templates>=1, and work-items summary open+completed>0. Pure raw Invoke-RestMethod,
single OAuth token in BeforeAll, BaseUrl overridable, Describe/Context/It pattern consistent with
sibling SP.Sdk*.Tests.ps1. No GUI/FlaUI launched.

## Discrepancies
None.

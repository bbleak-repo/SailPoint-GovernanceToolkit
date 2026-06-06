# T-02 -- Toolkit: make W-08b interactive SDK test data-adaptive (read expected counts from the live mock at runtime)

## Read
- `Tests/Harness/Test-W08b-SdkTabInteractive.ps1` (full, 760 lines) -- the harness to refactor; identified the hard-coded literals in WG-08-12/14/16/17/18/19/20.
- `Tests/Harness/Invoke-FullGuiValidation.ps1` lines 288-337 -- `Test-MockOAuth` (token POST pattern) + the SDK BaseUrl `/v3` suffix (line 331), the real reference (the spec-cited `Tests/Integration/Test-SailPointWorkflow.ps1` does not exist).
- Live mock at http://localhost:8080 -- probed `/oauth/token` and each collection endpoint with a Bearer token to capture the runtime-derived expected values the refactored test will now compute.

## Did
ADDITIVE single-file edit of `Tests/Harness/Test-W08b-SdkTabInteractive.ps1`:
1. Added helper `Get-SPMockExpectedCounts -BaseUrl` (before the Mock-up check section). It gets a Bearer token via `POST /oauth/token` (client_credentials form, mirroring Test-MockOAuth), then queries each SDK collection endpoint under `$BaseUrl/v3` ONCE with `Invoke-RestMethod -TimeoutSec 5`. Returns a pscustomobject: Templates, ApprovalsPending, ApprovalsCompleted, WorkItemsOpen, WorkItemsCompleted, WorkItemsTotal, ShowCompletedTotal (=open+completed), Workflows, DisabledWorkflowId (id of the workflow with `enabled -eq $false`, read from served data), Filters. EACH probe is wrapped in its own try/catch -> field is `$null` on failure (never crashes).
2. Added a runtime-counts block right after the health check, guarded by `if ($mockUp)`: `$expected = Get-SPMockExpectedCounts -BaseUrl $MockBaseUrl` (try/catch -> `$null`). Added local resolvers (`Resolve-ExpInt` + `$expTemplates`/`$expPending`/`$expCompleted`/`$expWiOpen`/`$expWiCompleted`/`$expWiTotal`/`$expShowCompletedTotal`/`$expWorkflows`/`$expFilters`/`$expDisabledWfId`) that yield an int when served, else `$null` (= unknown -> step degrades to >=1 / `-Expected -1`).
3. Replaced the hard-coded `-Expected`/comparison literals with the derived values, keeping ALL polling/wait/finder/screenshot/Add-Result mechanics intact:
   - WG-08-12 templates: `-Expected 3` -> `$expTpl` (=$expTemplates or -1); PASS on `==$expTemplates`, else `>=1` when unknown.
   - WG-08-14 approvals: pending `-Expected 4`/completed `-Expected 3` -> `$expPnd`/`$expCmp`; PASS condition uses `$pndOk`/`$cmpOk` (==served or >=1). (Fixes the completed 3->4 drift.)
   - WG-08-16 work items: grid `-Expected 4` -> `$expGrid` (=$expWiOpen); badge `'4'`/`'2'`/`'6'` compares -> string compares vs `$wantOpenStr`/`$wantCmpStr`/`$wantTotalStr`; unknown -> badges `^\d+$`. IsSdkRunning re-click loop + 40000/20000ms budgets unchanged.
   - WG-08-17 show-completed: `-Expected 6` -> `$expSC` (=$expShowCompletedTotal=open+completed); unknown fallback `>= open` else `>=1`.
   - WG-08-18 workflows: `-Expected 4` -> `$expWf`; PASS via `$wfRowsOk` (==served or >=1). Executions sub-check unchanged.
   - WG-08-19 enabled column: hard-coded `'wf-004'` -> `$expDisabledWfId` (served disabled id); `$null` falls back to the existing soft "exactly one disabled, id not asserted" branch.
   - WG-08-20 filters: first `-Expected 3` -> `$expFlt`; PASS strengthened to `allRows.Count -ge $expFilters` when known, else `>=1`. Second refresh `-Expected $allRows.Count` unchanged.
4. No XAML change (all 15 referenced AutomationIds already exist). The STA guard, Start-SPDashboardForTest, and live run remain AUTHOR-ONLY -- NOT executed.

## Files
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Tests\Harness\Test-W08b-SdkTabInteractive.ps1`
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\docs\loop-runs\autoloop3-sdk-collections-20260606-1620\round-02-t-02.md` (this record)

## Verification
All HEADLESS. The live FlaUI W-08b was NOT executed (deferred human gate).

### 1) Live probe of runtime-derived expected values (documents the drift fixed)
```
templates=10
pending=4
completed=4
wi-open=7
wi-completed=23
wi-summary={"total":30,"completed":23,"open":7}
['wf-004']workflows=4
filters=3
```
=> derived: templates=10, pending=4, completed=4, wi open/completed/total=7/23/30, show-completed=30, workflows=4, disabled=wf-004, filters=3. (Hard-coded literals were 3 / 4,3 / 4,2,6 / 6 / 4 / wf-004 / 3 -- templates and completed had drifted.)

### 2) Parse/compile (must be 0 errors)
```
powershell -NoProfile -Command "$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'Tests/Harness/Test-W08b-SdkTabInteractive.ps1'),[ref]$t,[ref]$e); if(-not $e){$e=@()}; 'errors=' + $e.Count"
errors=0
```

### 3) AutomationId / x:Name cross-check (every referenced id exists in runtime XAML)
```
SdkTemplateGrid = True
SdkApprovalGrid = True
RbSdkPending = True
RbSdkCompleted = True
SdkWorkItemGrid = True
SdkWiBadgeOpen = True
SdkWiBadgeCompleted = True
SdkWiBadgeTotal = True
ChkSdkShowCompleted = True
SdkWorkflowGrid = True
ChkSdkIncludeSystem = True
SdkFilterGrid = True
SdkExecutionGrid = True
BtnSdkViewExecutions = True
SdkWorkItemStatusLabel = True
```

### 4) No surviving hard-coded data assertions driving PASS/FAIL (hits are comments only)
```
powershell -NoProfile -Command "Select-String ... -Pattern '-Expected 3\b|-Expected 4\b|-Expected 6\b|''4''|''2''|''6''|wf-004' ..."
300: # rather than hard-coding 'wf-004' -- robust to any seed.
771: # ----- WG-08-19: Workflow enabled column -- wf-004 enabled=False, others True
```
Both surviving hits are COMMENTS (helper docstring + section header). No live `-Expected N` literal or `'4'/'2'/'6'` comparison remains.

### 5) Probe helper sanity (helper defined, Bearer token via /oauth/token, call site guarded by $mockUp)
```
210: function Get-SPMockExpectedCounts {
246:     # Bearer token (mirror Test-MockOAuth: client_credentials form POST).
250:     $tok  = Invoke-RestMethod -Uri "$BaseUrl/oauth/token" -Method POST -Body $body `
252:     if ($tok.access_token) { $headers = @{ Authorization = "Bearer $($tok.access_token)" } }
314: $mockUp = $false
329: if ($mockUp) {
330:     try { $expected = Get-SPMockExpectedCounts -BaseUrl $MockBaseUrl } catch { $expected = $null }
```
Helper defined (210); token POST (250) + Authorization Bearer header (252); `$expected = Get-SPMockExpectedCounts` call site (330) is inside `if ($mockUp)` -- i.e. only after the health check.

DID NOT run Invoke-Pester on this harness; DID NOT launch the dashboard / FlaUI / W-08b.

## Commit
<filled in after commit>

## Status
AUTHORED -- the file is an AUTHOR-ONLY live FlaUI harness (deferred human-run gate). The refactor is complete and statically verified headlessly (parse 0 errors, all AutomationIds present, no surviving hard-coded literals, probe helper + $mockUp-guarded call site confirmed); the live run is intentionally NOT executed here.

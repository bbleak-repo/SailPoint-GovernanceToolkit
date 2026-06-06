# T-02 -- Add membership-changelog mock endpoint (+ wire activities) additively

**Read**
- `docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-02-t-02-spec.md` (the spec).
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/IdentityHandlers.ps1`
  -- mirrored `$GetAccountActivitiesHandler` (l.162-211, ExtraFilter closure pattern)
  and the dual-shape/missing-key guard from `$GetRolesHandler` (l.376-404) and
  `$GetEntitlementsHandler` (l.220-234).
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Register-SailPointRoutes.ps1`
  -- 80 `Add-PodeRoute` lines before; dot-source block l.17-23; account-activities
  route at l.59.
- `C:/temp/Coding/API-mockserver/Shared/MockHelpers.psm1` -- `ConvertFrom-ISCFilter`,
  `Invoke-MockPagination` (`-ExtraFilter` semantics, ForEach-Object `$_` binding,
  single-item `@()` wrap contract).
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` (l.591-635, 845-850)
  -- confirmed the T-01 changelog record shape emitted to top-level
  `membershipChangelog`: `date`, `groupId`, `groupName`, `identityId`,
  `operation` (values `ADD`/`REMOVE`).

**Did**
- CREATE `Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1`
  defining ONE scriptblock `$GetMembershipChangelogHandler` for
  `GET /v3/membership-changelog`. It: reads `SailPointData` via `Get-PodeState`;
  safely pulls `membershipChangelog` tolerating IDictionary (`.Contains()`),
  PSCustomObject, AND a missing key (defaults to `@()`); parses `filters` via
  `ConvertFrom-ISCFilter` (enables `groupId`/`operation`/`identityId` filtering);
  parses `limit`(250)/`offset`(0) with the existing `IsNullOrWhiteSpace`+`[int]`
  pattern; builds an `-ExtraFilter` closure ONLY when `from-date`/`to-date` are
  present (captured `[datetime]` bounds, try/catch parse of `$_.date`, unconstrained
  side when a bound is absent); calls `Invoke-MockPagination`; sets
  `X-Total-Count`; writes `@($result.Items)`.
- EDIT `Profiles/SailPoint-ISC/Register-SailPointRoutes.ps1` (ADDITIVE, nothing
  removed/reordered): +1 dot-source line for `MembershipChangelogHandlers.ps1`
  after the `SdkHandlers.ps1` line; +1 `Add-PodeRoute` for
  `/v3/membership-changelog` directly after the `/v3/account-activities` route.
  Route count 80 -> 81.
- CREATE `Tests/Integration/Test-MembershipChangelog.ps1` -- self-contained
  HEADLESS harness (no live server): imports `MockHelpers.psm1`, stubs
  `Get-PodeState`/`Add-PodeHeader`/`Write-PodeJsonResponse`/`$WebEvent`,
  dot-sources the handler, and asserts no-filter/operation/groupId filter,
  limit+offset paging with correct `X-Total-Count`, from/to-date window, from-date
  only, and the missing-key tolerance path.
- No edits to `MockHelpers.psm1` or any other handler. PS 5.1 only.

**Files**
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1` (CREATE)
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Register-SailPointRoutes.ps1` (EDIT: +1 dot-source, +1 route)
- `C:/temp/Coding/API-mockserver/Tests/Integration/Test-MembershipChangelog.ps1` (CREATE)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-02-t-02.md` (this record, toolkit repo)

**Verification** (run from `C:/temp/Coding/API-mockserver`, Windows PowerShell 5.1)

1. Parse checks (handler, registry, harness) -- each printed `0`:
```
powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1',[ref]$null,[ref]$e); $e.Count"
-> 0
powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Profiles/SailPoint-ISC/Register-SailPointRoutes.ps1',[ref]$null,[ref]$e); $e.Count"
-> 0
powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Tests/Integration/Test-MembershipChangelog.ps1',[ref]$null,[ref]$e); $e.Count"
-> 0
```

2. Route-count guard (Grep tool) -- `Add-PodeRoute` count = **81** (was 80).
   Presence confirmed:
```
24: . (Join-Path $handlerDir 'MembershipChangelogHandlers.ps1')
60: Add-PodeRoute -Method Get  -Path '/v3/account-activities'   -ScriptBlock $GetAccountActivitiesHandler
61: Add-PodeRoute -Method Get  -Path '/v3/membership-changelog' -ScriptBlock $GetMembershipChangelogHandler
```

3. Headless functional harness -- ALL 11 asserts PASSED (exit 0):
```
Test-MembershipChangelog: GET /v3/membership-changelog handler
  [PASS] no-filter returns all records
  [PASS] no-filter X-Total-Count = full count
  [PASS] operation eq REMOVE returns only REMOVE
  [PASS] groupId eq ent-001 returns 2 records
  [PASS] limit=1 offset=1 returns single item
  [PASS] paged X-Total-Count = full count
  [PASS] limit=1 offset=1 is the 2nd record
  [PASS] from/to-date window narrows set
  [PASS] from-date only returns 2 records (>= 05-20)
  [PASS] missing key returns empty array
  [PASS] missing key X-Total-Count = 0

Test-MembershipChangelog: ALL ASSERTS PASSED
EXITCODE=0
```

4. No regression on touched-registry tests -- both still parse with 0 errors:
```
Tests/Smoke/Invoke-SmokeTest.ps1        -> 0
Tests/Integration/Test-SailPointWorkflow.ps1 -> 0
```
Did NOT start an elevated server or launch GUI/FlaUI.

**Commit**
- Mock repo (`C:/temp/Coding/API-mockserver`), branch `feature/manager-cert-30day-sim`:
  `9fda6f1` feat(sailpoint): add GET /v3/membership-changelog mock endpoint (date-windowed Added/Removed)
- Toolkit repo (this record file): committed separately on the same branch.

**Status** DONE

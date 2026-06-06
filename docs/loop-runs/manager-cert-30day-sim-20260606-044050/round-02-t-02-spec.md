# T-02 SPEC -- Add membership-changelog mock endpoint (+ confirm activities) additively

ROLE: MIDDLE (spec). For the INNER implementer. Commit to the MOCK repo
(`C:/temp/Coding/API-mockserver`), branch `feature/manager-cert-30day-sim`. ADDITIVE only.

## Goal (precise)
Add a READ endpoint that serves the dated membership changelog produced by T-01
(`$data.membershipChangelog`) so the toolkit can query Added/Removed events by
date window and by group/entitlement. Register it alongside the existing 80
routes WITHOUT removing any (count must go 80 -> 81). Confirm
`GET /v3/account-activities` still serves the GRANT/REVOKE activities. Mirror the
existing handler style exactly.

## Ground truth (read these)
- Route registry: `Profiles/SailPoint-ISC/Register-SailPointRoutes.ps1` -- 80
  `Add-PodeRoute` lines today. Handler files dot-sourced at top (lines 17-23).
- Handler style to mirror: `Profiles/SailPoint-ISC/Handlers/IdentityHandlers.ps1`
  -- specifically `$GetAccountActivitiesHandler` (l.162-211) and
  `$GetRolesHandler` (l.376-404). Both do: `Get-PodeState -Name 'SailPointData'`,
  pull the collection, `ConvertFrom-ISCFilter -FilterExpression $WebEvent.Query['filters']`,
  read `limit`/`offset` from `$WebEvent.Query`, call `Invoke-MockPagination`,
  `Add-PodeHeader -Name 'X-Total-Count' -Value $result.TotalCount.ToString()`,
  `Write-PodeJsonResponse -Value @($result.Items)`.
- Shared helpers (already exported, do NOT modify): `Shared/MockHelpers.psm1` --
  `ConvertFrom-ISCFilter`, `Invoke-MockPagination` (supports `-ExtraFilter`
  scriptblock for query params outside the `filters` string), `Resolve-NestedProperty`,
  `Write-MockErrorResponse`.
- Changelog record shape from T-01 (`Scripts/New-BulkSeedData.ps1` l.607-613,
  emitted to top-level `membershipChangelog`):
  ```
  { date: <ISO8601 string>, groupId: "ent-NNN", groupName: <string>,
    identityId: "id-NNN", operation: "ADD" | "REMOVE" }
  ```
  NOTE the field is `operation` with values `ADD`/`REMOVE` (NOT Added/Removed).
- The live `State/SailPointData.json` does NOT yet contain `membershipChangelog`
  (regenerating/loading it is T-03's job -- do NOT do it here). The handler MUST
  therefore tolerate a missing key and return an empty array + `X-Total-Count: 0`.

## Files to create / edit
1. CREATE `Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1`
   - Define ONE scriptblock variable: `$GetMembershipChangelogHandler`.
   - Logic (mirror `$GetAccountActivitiesHandler`):
     - `$data = Get-PodeState -Name 'SailPointData'`.
     - Safely read the changelog collection tolerating BOTH IDictionary (hashtable)
       and PSCustomObject shapes AND a missing key -- copy the exact dual-shape
       guard used in `$GetRolesHandler` (l.378-386): if IDictionary use
       `.Contains('membershipChangelog')` then `$data['membershipChangelog']`;
       else `$data.PSObject.Properties['membershipChangelog']`. Default to `@()`.
     - `$clauses = ConvertFrom-ISCFilter -FilterExpression $WebEvent.Query['filters']`
       (lets callers filter `groupId eq "ent-003"`, `operation eq "REMOVE"`,
       `identityId eq "id-007"`, etc. via the existing nested-property matcher).
     - `limit` (default 250) / `offset` (default 0) parsed exactly as the existing
       handlers (the `[string]::IsNullOrWhiteSpace` guard + `[int]` cast).
     - DATE WINDOW (additive, optional): support two standalone query params
       `from-date` and `to-date` (ISO8601 strings) via an `-ExtraFilter`
       scriptblock (same closure/`$captured*` pattern as the `requested-for`
       block in `$GetAccountActivitiesHandler` l.179-205). The predicate compares
       `[datetime]$_.date` against captured `[datetime]` bounds; if a bound param
       is absent that side is unconstrained; wrap the `[datetime]` parse of
       `$_.date` in try/catch returning `$false` on unparseable. Only build the
       ExtraFilter when at least one of the two params is present (else pass `$null`).
     - `$result = Invoke-MockPagination -Collection @($changelog) -FilterClauses $clauses -Limit $limit -Offset $offset -ExtraFilter $extraFilter`.
     - `Add-PodeHeader -Name 'X-Total-Count' -Value $result.TotalCount.ToString()`.
     - `Write-PodeJsonResponse -Value @($result.Items)`.
   - File header comment block in the same style as `IdentityHandlers.ps1`
     (purpose, "Dot-sourced inside ... Register-SailPointRoutes.ps1", PS 5.1 note,
     handler listing). PS 5.1 ONLY: no `?.`, `??`, ternary, no `.ContainsKey()`.

2. EDIT `Profiles/SailPoint-ISC/Register-SailPointRoutes.ps1`
   - ADD a dot-source line in the handler-loading block (after l.23, the
     `SdkHandlers.ps1` line):
     `. (Join-Path $handlerDir 'MembershipChangelogHandlers.ps1')`
   - ADD ONE route in the Identities/Accounts section (after the
     `/v3/account-activities` route, l.59) -- do NOT remove or reorder any line:
     `Add-PodeRoute -Method Get -Path '/v3/membership-changelog' -ScriptBlock $GetMembershipChangelogHandler`
   - Use `/v3/membership-changelog` (the no-`:id` variant) so the standalone
     route does not collide with the existing parameterised `:id` routes and so
     callers filter by `groupId`/`identityId` via the `filters` param. (Do NOT add
     a `/v3/entitlements/:id/membership-changelog` variant -- one route is enough
     and avoids touching the entitlements route group.)
   - The header comment "79 routes total" / "80" count comment on l.10 is stale
     prose; you MAY bump it to reflect the new total but it is optional and must
     not change behaviour.

3. (OPTIONAL, recommended) ADD an integration assertion. Do NOT rewrite existing
   tests. Either:
   - APPEND new `Assert-Test` blocks to `Tests/Integration/Test-SailPointWorkflow.ps1`
     (live-server test; mirror its `Invoke-Api` helper) -- requires a running mock
     and is therefore a human/optional gate, OR
   - CREATE a self-contained headless harness (preferred for headless verify)
     `Tests/Integration/Test-MembershipChangelog.ps1` that does NOT need a live
     server: import `Shared/MockHelpers.psm1`, dot-source the new handler file,
     build a fake `$data` hashtable with a small `membershipChangelog` (>=1 ADD,
     >=1 REMOVE across >=2 dates) plus a stub `Get-PodeState`/`Add-PodeHeader`/
     `Write-PodeJsonResponse`/`$WebEvent` so the scriptblock can be invoked, then
     assert: (a) no-filter returns all records; (b) `operation eq "REMOVE"`
     returns only REMOVE; (c) `limit=1`/`offset=1` paging slices correctly and
     `X-Total-Count` = full count; (d) a `from-date`/`to-date` window narrows the
     set. This harness is the headless evidence below.

## Headless verification (run all; paste real output in the INNER record)
Run from `C:/temp/Coding/API-mockserver`. Windows PowerShell 5.1 (`powershell.exe`).

1. Parse check (0 errors) on new handler + edited registry:
   ```
   powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1',[ref]$null,[ref]$e); $e.Count"
   powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Profiles/SailPoint-ISC/Register-SailPointRoutes.ps1',[ref]$null,[ref]$e); $e.Count"
   ```
   Both MUST print `0`. If a Tests harness file is added, parse-check it too.

2. Route-count guard -- no route removed, exactly one added (80 -> 81):
   Use the Grep tool: `Add-PodeRoute` in `Register-SailPointRoutes.ps1` -> count
   must be 81 (was 80). Also grep that the literal
   `Add-PodeRoute -Method Get  -Path '/v3/account-activities'` line and the new
   `'/v3/membership-changelog'` line are BOTH present, and the dot-source line
   `MembershipChangelogHandlers.ps1` is present.

3. Headless functional assertion (handler scriptblock over a generated dataset):
   Prefer running the new `Tests/Integration/Test-MembershipChangelog.ps1` harness
   (above) and confirm all asserts PASS -- it must demonstrate ADD and REMOVE
   records returned AND limit/offset paging respected AND a date window narrowing.
   Acceptable alternative evidence: generate a real dataset to a temp file via
   `Scripts/New-BulkSeedData.ps1` (it emits `membershipChangelog`), load it as
   `$data`, dot-source the handler with stubbed Pode cmdlets, and assert the same.

4. No regression on touched files: run the smoke test ONLY if a mock is already
   running headless (it is a live-server test -- do NOT start an elevated server;
   start NON-ELEVATED via `Start-MockServer.ps1` if needed). At minimum confirm
   `Tests/Smoke/Invoke-SmokeTest.ps1` and `Tests/Integration/Test-SailPointWorkflow.ps1`
   still PARSE with 0 errors (they were not edited, but the registry they exercise
   was). Do NOT launch GUI / FlaUI.

## Constraints / gotchas
- ADDITIVE: do not remove/reorder existing dot-source lines or routes; do not edit
  `MockHelpers.psm1` or any other handler file.
- PS 5.1 ONLY: ordered/hashtable membership via `.Contains()` not `.ContainsKey()`;
  no ternary/`?.`/`??`; ASCII.
- Tolerate missing `membershipChangelog` key (State JSON is stale until T-03) ->
  return `@()` and `X-Total-Count: 0`, never throw.
- `operation` values are `ADD`/`REMOVE` (match T-01 exactly); filter examples in
  any doc/comment must use those literals.
- Wrap `Write-PodeJsonResponse -Value @($result.Items)` in `@()` so a single-item
  page is still a JSON array (ISC contract; see Invoke-MockPagination H1 note).
- Commit ONLY to the mock repo with a conventional message ending in the required
  Co-Authored-By line. Never push; never touch master/main.

## Suggested commit message
```
feat(sailpoint): add GET /v3/membership-changelog mock endpoint (date-windowed Added/Removed)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

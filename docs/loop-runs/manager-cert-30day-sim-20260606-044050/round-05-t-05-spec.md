# T-05 (SPEC) -- Validation Pester suite: manager-cert correctness, removal detection, privileged-role + manager-accountability, 7d vs 30d deltas

ROLE: MIDDLE (spec only -- do NOT implement). This document is the concrete spec the
INNER implementer follows. Everything ADDITIVE; commit to the TOOLKIT repo only.

---

## 0. Objective

ADD one new Pester 5 suite under `Tests/` that headlessly ASSERTS the point of the
30-day manager-cert exercise against the T-03 dataset (the regenerated
`State/SailPointData.json`, seed 20260606) and the toolkit functions T-04 exercises.
Green = 0 failed, non-trivial count, all 7 required areas covered, every `It` checks a
REAL outcome (a specific removed user/group/day appears in BOTH windows; a manager's
overdue/missed count matches seeded data; a privileged role's member list matches).

Run ONLY this new suite for the item; full `Invoke-Pester .\Tests` is the Finalize gate.

---

## 1. Files to CREATE (additive -- do NOT edit any existing suite)

1. `Tests/SP.ManagerCert30DaySim.Tests.ps1` -- the new Pester 5 suite.
2. `Tests/TestData/ManagerCert30DaySim.State.json` -- a FROZEN snapshot fixture
   (copy of the mock's `State/SailPointData.json`, seed 20260606) committed into the
   toolkit so the suite is deterministic and does NOT depend on a live mock server.
   Create by copying `C:/temp/Coding/API-mockserver/State/SailPointData.json` to that
   path. (~6.2 MB; that is acceptable -- the suite must be reproducible in CI/Finalize
   with NO server running.) Tests/TestData already exists and holds other fixtures.

DO NOT add the new script to `Tests/SP.CliScripts.Tests.ps1` (that suite hardcodes
CLI script lists; this item adds a TEST file, not a CLI script).

---

## 2. Architecture decision (READ THIS FIRST -- avoids the live-server trap)

The existing `Tests/*.Tests.ps1` suites are all UNIT-style: they import flat modules via
`Tests/Import-TestModules.ps1` and `Mock Invoke-RestMethod`/`Invoke-SPApiRequest`. The
only live-mock callers (`localhost:8080`) are the GUI/FlaUI harnesses under
`Tests/Harness/` -- which are NOT part of the Pester `.Tests.ps1` gate and are human-run.

Therefore this suite MUST NOT require a running mock. Use a TWO-LAYER approach against
the FROZEN fixture (`Tests/TestData/ManagerCert30DaySim.State.json`):

- **Layer A -- DATA-TRUTH assertions (pure):** load the fixture JSON once in `BeforeAll`
  / `BeforeDiscovery` and assert correctness directly on the seeded data. Covers
  areas (3) removal detection, (5) 7d-vs-30d deltas, (6) privileged-role reports,
  (7) manager accountability. These prove the *dataset* encodes the governance truth the
  reports consume, and pin specific user/group/day facts so a real regression fails.

- **Layer B -- TOOLKIT-FUNCTION assertions (real code, mocked transport):** import the
  flat modules and `Mock Invoke-SPApiRequest` / `Mock Invoke-RestMethod` to return SLICES
  of the fixture, then call the REAL toolkit functions and assert their output. Covers
  areas (1) org/leadership rollup, (2) SMTP-WhatIf logged, (4) campaign write round-trip.

This mirrors the proven patterns in `Tests/SP.LeadershipAttribution.Tests.ps1` (org tree +
`Group-SPAuditByLeadership` + band resolution against hand-computed truth) and
`Tests/SP.DeltaCert.Tests.ps1` (mock activity events -> real delta query functions).

### Pester-5 scoping rule (MANDATORY)
- Load the fixture and compute the concrete "expected" facts (the named removed
  user/group/day, the priv-role id + member list, the manager id + overdue/missed counts)
  at DISCOVERY time into `$script:`-scoped variables inside a top-level `BeforeDiscovery`
  block, so `-ForEach`/`-TestCases` data is available when Pester discovers tests. Do NOT
  put `-ForEach` source data only inside `BeforeAll` (runs too late -> empty discovery).
  Re-load the same fixture in `BeforeAll` for run-time use. (See
  `SP.LeadershipAttribution.Tests.ps1` `$script:` usage; add `BeforeDiscovery` for any
  `-ForEach`/`-TestCases`.)
- The fixture path is `Join-Path $PSScriptRoot 'TestData\ManagerCert30DaySim.State.json'`
  (2-arg Join-Path; PS 5.1).

### Module import
- `BeforeAll { . (Join-Path $PSScriptRoot 'Import-TestModules.ps1'); Import-SPTestModules -Core -Api -Audit -DeltaCert }`
  (same switch set the leadership + delta suites use; gives Build-SPOrgTree,
  Resolve-SPIdentityBand, Group-SPAuditByLeadership, the delta query/report functions,
  New-SPCampaign/Start-SPCampaign/Get-SPCampaign/Search-SPCampaigns, Invoke-SPApiRequest).

### "Anchor date" for windows
The dataset is anchored at **2026-06-05T12:16:28Z** (the most-recent daily campaign
`created` and the changelog top date). Compute window cutoffs relative to a FIXED anchor
read from the fixture (e.g. the max changelog date, or the newest daily-campaign
`created`), NOT `Get-Date` -- the fixture is static so a wall-clock cutoff would drift and
make the suite flaky/red over time. Define `$script:Anchor = [datetime]` of that max date.

---

## 3. Concrete fixture facts (verified from State seed 20260606 -- use these EXACT values)

These were read from the live State on 2026-06-06; the seed is deterministic so they hold
for the frozen copy. The implementer SHOULD re-derive them in-suite (compute from the
loaded fixture) AND assert the named anchors below so the test is self-checking.

- **trackedPrivilegedRoles**: exactly 10. First two: `ent-003` "AD-SG-Admins-3"
  (responsibleManagerId `id-gen-001` James Smith), `ent-017` "AD-SG-Marketing-17"
  (`id-gen-002` Mary Johnson). Each has id / name / responsibleManagerId /
  responsibleManagerName.
- **entitlements**: each tracked role exists in `entitlements` with
  `attributes.privileged = $true` and a `members` array of identity ids. e.g. `ent-003`
  members = `id-gen-069, id-gen-035, id-gen-050` (3 members). (Area 6: assert the
  privileged flag + the member list equality.)
- **membershipChangelog**: 1366 events, ops ADD + REMOVE. 584 REMOVE total. Within 30
  days of anchor: 584 REMOVE; within 7 days: 223 REMOVE. 41 REMOVE events are FROM a
  tracked privileged role group.
- **Named removal anchor for area (3)** -- pick a REMOVE that is INSIDE the 7-day window
  (so it surfaces in BOTH 7d and 30d): `id-gen-043` removed from `ent-009`
  "AD-SG-HR-9" on `2026-05-30` (within 7 days of the 2026-06-05 anchor).
  - For a privileged-role removal (ties areas 3+6): `id-gen-006` removed from `ent-003`
    "AD-SG-Admins-3" on `2026-05-16` (within 30 days, OUTSIDE 7 days -> demonstrates a
    30d-only delta). Also `id-gen-072` removed from `ent-017` on `2026-05-15`.
  - The INNER should programmatically CONFIRM these exact records exist in the fixture in
    `BeforeAll` (fail fast with a clear message if the seed changed), then assert they
    surface in the right window(s). This makes the named facts self-validating.
- **Daily privileged campaigns**: 30 of them, `name` = "Daily Privileged Role
  Attestation <ISO date>", `type` = MANAGER, ids `camp-daily-priv-01`..`-30`. Each carries
  a `managerAttestation` array (10 entries) with `managerId, managerName, status
  (attested|overdue|missed), decisionsMade, decisionsTotal`.
  - **Named accountability anchor for area (7)**: in `camp-daily-priv-01`
    (name dated 2026-06-05), `id-gen-002` Mary Johnson status = `missed`
    (decisionsMade 3 / decisionsTotal 4); `id-gen-007` Michael Miller = `overdue`;
    `id-gen-001` James Smith = `attested`. The INNER must assert a specific manager's
    per-day status matches, AND that rolling counts across the 7-day and 30-day windows
    (count of attested/overdue/missed for a given manager over the daily campaigns in
    each window) are computed correctly and 30d-count >= 7d-count.
- **campaigns** total = 33 (30 daily MANAGER + Q1 Manager Review + 2 Source Owner).

(If the INNER finds any of the above no longer matches the frozen fixture, it must
recompute from the fixture and update the named anchors -- the assertions must reflect the
ACTUAL committed fixture, never stale numbers. Re-derive, do not hardcode blindly.)

---

## 4. Required test areas -> concrete It-blocks (all 7 MUST be present)

Use one `Describe` per area (suggested ids MC-01..MC-07). Non-trivial = each Describe has
>= 2 real assertions; target ~25-40 It blocks total.

### MC-01 (Layer B) -- Manager cert ORG + MANAGER reports correct
Mirror `SP.LeadershipAttribution.Tests.ps1` LA-01/LA-02 EXACTLY (it is the canonical
pattern), but seed the org tree from REAL fixture identities so the test is grounded in
the 30-day dataset rather than a toy tree:
- Build a small deterministic org chain from fixture identities (e.g. one tracked-role
  responsible manager + that manager's manager/director/VP as present in the fixture
  `identities[].managerId` chain) by mocking `Get-SPDeltaIdentityDetail -ModuleName
  SP.DeltaCertQueries` to return details sourced from the fixture identities.
- Assert `Build-SPOrgTree` Success, node count, per-rung `Level`, child wiring; assert
  `Resolve-SPIdentityBand` produces the right A-E band letters for the chain (E at depth
  0 up to A at top) -- same band-letter logic LA-01 asserts.
- Assert `Group-SPAuditByLeadership` attributes a set of approve/revoke decisions (the
  certifier = the responsible MANAGER) to the correct director/VP, rolls up
  director.TotalItems == sum(managers) and VP == sum(directors) with NO double-count, and
  that reviewer attribution = the manager (LA-02 invariants:
  `Approved+Revoked+Pending == TotalItems` at every level).

### MC-02 (Layer B) -- SMTP-WhatIf logs (Action='Logged'), NO real send
Find the toolkit's report-distribution / SMTP send path. Likely `Send-SPReport` /
the SMTP-WhatIf branch invoked by `Invoke-SPAdaptiveReport.ps1 -DistributeToLeadership`
WITHOUT `-SendReports` (T-04 confirmed it prints "Distribution (simulate / WhatIf -- no
email sent)" / "WOULD send" and 0 "Sent"). INNER must:
- Grep/locate the send function (search `Modules/` for `Send-MailMessage`,
  `Send-SPReport`, `Smtp`, `WhatIf`, `WOULD send`, `Action.*Logged`). Read it to learn the
  EXACT return/log contract (the spec author confirmed `Audit.Smtp.Enabled=false` in
  `Config/settings.local.json` makes it log not send; T-04 record shows the "Logged"
  Action semantics).
- Mock `Send-MailMessage` (the real SMTP call) so a FAIL = it was actually invoked; call
  the send/distribute function in WhatIf/simulate mode for each of >=2 leaders; assert
  the returned record(s) have `Action -eq 'Logged'` (or the equivalent the code uses) and
  that `Send-MailMessage` received 0 invocations (`Should -Invoke Send-MailMessage -Times
  0`). Assert the per-leader "would email" entries name the right leader + report path.

### MC-03 (Layer A + B) -- REMOVED users detected/shown in BOTH 7d and 30d
- Layer A (data truth): from the fixture changelog, filter REMOVE events by the
  `from-date` window logic the mock endpoint implements (`[datetime]$_.date >= anchor -
  N days`). Assert the NAMED 7-day removal (`id-gen-043` / `ent-009` "AD-SG-HR-9" /
  2026-05-30) appears in BOTH the 7-day and 30-day filtered sets. Assert the
  30d-only privileged removal (`id-gen-006` / `ent-003` / 2026-05-16) appears in the
  30-day set but NOT the 7-day set (proves the window actually filters, not just caps).
  Assert `removeCount_30d >= removeCount_7d` and both > 0.
- Layer B (toolkit path): mock `Invoke-SPApiRequest` (REVOKE_ACCESS account-activities)
  to return the fixture's REMOVE-derived events and call `Get-SPDeltaRevokeEvents`
  (`Modules/SP.DeltaCert/SP.DeltaCertReport.psm1`); assert `-HoursBack 168` (7d) vs
  `-HoursBack 720` (30d) returns a subset/superset relationship and that the named
  removed identity/group surfaces in the returned data. (Mock pattern: copy
  `SP.DeltaCert.Tests.ps1` `New-MockGrantActivity` shape but type='REVOKE_ACCESS';
  mock `Write-SPLog -ModuleName SP.DeltaCertReport` and `Get-SPConfig`.)
  - If wiring the activity-event mock proves too brittle, area (3)'s toolkit-path
    requirement may instead assert on the RC04-Diff component
    (`Modules/SP.ReportComponents/RC04-Diff.ps1`) or the changelog-window filter; the
    Layer-A data-truth assertions are mandatory regardless.

### MC-04 (Layer B) -- Campaign WRITE path round-trips (the ~10 manager campaigns appear)
Mirror `SP.Campaigns.Tests.ps1` mocking. With `Invoke-SPApiRequest` mocked to emulate
the mock's POST /v3/campaigns (assign an id, store), POST /:id/activate (status ACTIVE),
and GET /campaigns?filters=name co "..." (return the stored ones):
- Submit 10 MANAGER campaigns (one per tracked privileged role, CertifierIdentityId =
  the role's responsibleManagerId) via `New-SPCampaign`; assert each returns
  `.Success -eq $true` and a `.Data.id`.
- `Start-SPCampaign` each; assert success.
- `Search-SPCampaigns -Keyword '<name fragment>'` returns all 10 (round-trip confirmed) AND
  `Get-SPCampaign -CampaignId <id>` returns each by id. Assert count == 10 and the
  certifier on each == the expected responsible manager. (This proves the
  New-SPCampaign/Start-SPCampaign/Search/Get contract the T-04 driver round-tripped live,
  but headlessly via mocked transport.)

### MC-05 (Layer A) -- 7-day vs 30-day views show expected deltas/trends
Compute, from the fixture, window aggregates over BOTH the changelog and the daily
campaigns for 7d and 30d windows (relative to `$script:Anchor`):
- changelog: ADD count, REMOVE count per window; assert 30d counts >= 7d counts and 7d>0.
- daily campaigns: count of daily campaigns whose `created` falls in each window; assert
  30d count >= 7d count (e.g. 30d ~= 30, 7d ~= 7) and that the windowing is a strict
  subset relationship (every campaign/changelog row in the 7d set is also in the 30d set).
- Assert at least one metric STRICTLY differs between 7d and 30d (a real delta, not equal).

### MC-06 (Layer A) -- Privileged-role reports: fixed roles, current members, day-over-day adds/removes
- Assert `trackedPrivilegedRoles.Count == 10` and the set of ids is stable (contains
  `ent-003` and `ent-017`).
- For each tracked role, assert the matching `entitlements` entry has
  `attributes.privileged -eq $true`.
- For a NAMED role (`ent-003`), assert its `members` array equals the seeded set
  (`id-gen-069, id-gen-035, id-gen-050`) -- WHO is in the role.
- Day-over-day: from the changelog, compute ADD and REMOVE events scoped to tracked-role
  groupIds; assert the count > 0 and that the named priv-role REMOVE (`id-gen-006` from
  `ent-003` on 2026-05-16) is present. Assert at least one tracked role has both an ADD
  and a REMOVE across the 30 days (membership CHANGED).

### MC-07 (Layer A) -- Manager accountability: per-day status + rollup across windows
- For `camp-daily-priv-01`, assert a NAMED manager's per-day attestation matches the seed:
  `id-gen-002` (Mary Johnson) status `missed`, decisionsMade 3 / decisionsTotal 4;
  `id-gen-007` `overdue`; `id-gen-001` `attested`. Assert the attestation array has 10
  entries and every `status` is one of attested/overdue/missed and
  `decisionsMade <= decisionsTotal`.
- Rollup: for a given manager id across all daily campaigns within the 7d window and within
  the 30d window, compute counts of {attested, overdue, missed}; assert the 30d total
  campaign count for that manager >= the 7d total, the per-status counts sum to the number
  of daily campaigns in the window, and 30d missed/overdue counts >= the 7d ones (monotone
  rollup). Assert at least one manager has a non-zero overdue or missed count in 30d (the
  accountability signal is present).

---

## 5. Patterns to MIRROR (cite when implementing)

- `Tests/SP.LeadershipAttribution.Tests.ps1` -- `$script:`-scoped fixtures, `Mock ...
  -ModuleName SP.DeltaCertQueries`/`SP.AuditReportCore`, Build-SPOrgTree / Resolve-
  SPIdentityBand / Group-SPAuditByLeadership invariants (MC-01).
- `Tests/SP.DeltaCert.Tests.ps1` -- `New-MockDeltaConfig`, mock activity-event builders,
  `Mock Invoke-RestMethod`/`Invoke-SPApiRequest`, `Get-SPConfig` mock, `Write-SPLog`
  module-scoped mock (MC-03, MC-04).
- `Tests/SP.Campaigns.Tests.ps1` -- New-SPCampaign / Start-SPCampaign / Get-SPCampaign /
  Search-SPCampaigns mock + return-shape (MC-04).
- `Tests/Import-TestModules.ps1` -- the flat-import loader (Bug-1 rule); use
  `-Core -Api -Audit -DeltaCert`.
- Mock data source of truth: `C:/temp/Coding/API-mockserver/State/SailPointData.json`
  (copy to `Tests/TestData/ManagerCert30DaySim.State.json`); endpoint window-filter
  semantics in `Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1`
  (`from-date`/`to-date` = `[datetime]$_.date` >= / <= bound) -- replicate that exact
  comparison in Layer-A window filtering so the test matches what the mock serves.

## 6. PS 5.1 / house rules (MUST follow)
- Windows PowerShell 5.1 ONLY: 2-arg `Join-Path` (nest for 3 segments), `.Contains()` not
  `.ContainsKey()` on OrderedDictionary, no ternary/`??`/`?.`.
- `@{Success;Data;Error}` envelope on all module-function results; check `.Success`.
- Import modules with `-DisableNameChecking` (via Import-SPTestModules).
- No live server, no GUI, no FlaUI, no real SMTP. Fixture-driven + mocked transport only.
- ASCII; conventional commit message ending in the required Co-Authored-By trailer.

---

## 7. HEADLESS VERIFICATION (the gate -- run ONLY this suite)

From `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit` (Windows PowerShell 5.1):

1. Parse check (0 errors):
```
powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('Tests/SP.ManagerCert30DaySim.Tests.ps1',[ref]$null,[ref]$e); 'ParseErrors=' + @($e).Count"
```
Expect `ParseErrors=0`.

2. Fixture present:
```
powershell -NoProfile -Command "Test-Path 'Tests/TestData/ManagerCert30DaySim.State.json'"
```
Expect `True`.

3. Run ONLY the new suite (the affected-tests gate for this item):
```
Invoke-Pester -Path .\Tests\SP.ManagerCert30DaySim.Tests.ps1 -Output Detailed
```
PASS criteria: `Failed: 0`, `Skipped: 0`, `Passed` non-trivial (>= ~25), and the Detailed
output shows all of MC-01..MC-07 present (all 7 areas). Paste the real Pester summary line
(`Tests Passed: N, Failed: 0, Skipped: 0` / the `Tests completed ... Passed: N Failed: 0`
line) into the INNER record. Do NOT run the full `Invoke-Pester .\Tests` here -- that is
the Finalize gate.

Each It must check a REAL outcome: the named removed user/group/day (`id-gen-043` /
`ent-009` / 2026-05-30) appears in BOTH windows AND the priv-role removal (`id-gen-006` /
`ent-003` / 2026-05-16) is 30d-only; a manager's overdue/missed count matches the seed
(`id-gen-002` missed in camp-daily-priv-01); a privileged role's member list matches
(`ent-003` = id-gen-069, id-gen-035, id-gen-050). Render-only / always-true assertions are
a spec violation.

## 8. Commit
Commit to the TOOLKIT repo on branch `feature/manager-cert-30day-sim` (NEVER push;
NEVER touch master/main; the fixture + the suite + this/the INNER record together):
```
test(sim): add 30-day manager-cert validation Pester suite (T-05)
```
ending in:
```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
Note: `Tests/TestData/` is tracked (other fixtures live there) -- confirm the new fixture
is NOT gitignored before commit; if it is, force-add it.

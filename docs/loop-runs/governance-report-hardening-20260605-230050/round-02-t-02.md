# T-02 -- Governance content-correctness tests + minimal fixes for baseline membership reports B03/B04/B05/B06 and B10 KPIs

## Read
- `Tests/SP.AdaptiveBaselineReports.Tests.ps1` -- existing render-only suite (BR-001..BR-007); mirrored its BeforeAll/Import-Module/Render-Report structure but build the fixture BY HAND (no Build-SPRCDataset) per spec.
- `Modules/SP.AdaptiveReports/BaselineReports/B03-privileged-group-review.ps1` -- privileged-name heuristic (`Test-B03PrivilegedName` matches `administrators?`, `domain admins`, etc.); badge markup `<div class="badge[ crit|muted]"><b>N</b>privileged groups</div>` / `disabled w/ privilege` (one disabled-priv ROW per member-per-group).
- `Modules/SP.AdaptiveReports/BaselineReports/B04-sod-toxic-comembership.ps1` -- RoleAliases map Finance-Payments->'AP Payments', Finance-Approvals->'AP Payment Approval'; SOD-001 Critical; violation = group intersection; cards `<div class="n">N</div><div class="l">Active Violations</div>` / `Distinct Users`.
- `Modules/SP.AdaptiveReports/BaselineReports/B05-orphaned-disabled-members.ps1` -- one row per disabled-member->group pair; `distinctSam` dedups; cards `Disabled-member findings` / `Distinct disabled accounts` / `In privileged groups`.
- `Modules/SP.AdaptiveReports/BaselineReports/B06-group-inventory-catalog.ps1` -- group names in `<td class="group-name">NAME</td>`.
- `Modules/SP.AdaptiveReports/BaselineReports/B10-governance-executive-summary.ps1` -- KPI tiles `<div class="n">N</div><div class="l">Distinct Members</div>` / `Groups in Scope`; metric rows `Name</td>\n  <td class="tier">...</td>\n  <td class="num">N</td>`; SoD = member in 2+ distinct priv groups.

## Did
- Probed all five reports against the hand-built fixture FIRST to derive the real seeded-truth numbers (see Verification). Every probed value matched the intended governance signal, so NO module fix was required -- this is test-authoring ONLY (additive).
- Created `Tests/SP.BaselineGovernanceCorrectness.Tests.ps1` with helpers `M`/`GR` (documented GroupResults shape) and a fixture of 5 groups / 5 distinct identities:
  - 'Domain Admins' (priv): alice (enabled) + bob (DISABLED)
  - 'Administrators' (priv): bob (same disabled identity, 2nd priv group)
  - 'Marketing Distribution' (non-priv): carol
  - 'AP Payments' (Finance-Payments): dave + erin
  - 'AP Payment Approval' (Finance-Approvals): dave
- Asserted per report (one It block each, BGC-B03..BGC-B10):
  - BGC-B03: priv-groups badge = 2 (both Domain Admins + Administrators match heuristic), priv-members badge = 3, disabled-w/-privilege badge = 2 (bob disabled in both priv groups = 2 rows); flags Bob/Domain Admins/Administrators; does NOT flag Marketing Distribution / Carol / AP Payments.
  - BGC-B04: Active Violations = 1, Distinct Users = 1; flags Dave Both; does NOT flag Erin (single-side false-positive guard) or Carol.
  - BGC-B05: Distinct disabled accounts = 1 (round-10 dedup: bob in 2 groups counted once); Disabled-member findings = 2 (by-design row count); In privileged groups = 2; flags Bob; does NOT flag Alice Admin / Carol.
  - BGC-B06: all 5 seeded group names present (count == 5).
  - BGC-B10: Distinct Members KPI = 5; Groups in Scope = 5; metric Disabled members in groups = 2 (row count), SoD conflicts found = 1, Privileged-group members = 3.

## Files
- `Tests/SP.BaselineGovernanceCorrectness.Tests.ps1` (CREATE)
- `docs/loop-runs/governance-report-hardening-20260605-230050/round-02-t-02.md` (this record)

No `Modules/SP.AdaptiveReports/BaselineReports/B0x*.ps1` file was modified (no semantic mismatch found).

## Verification

### (0) Pre-write probe of seeded truth (PowerShell 5.1, hand-built fixture)
```
=== B03 ===
  groups scanned = 5
  privileged groups = 2
  privileged members = 3
  inherited (nested) = 0
  disabled w/ privilege = 2
  Bob Disabled match: True / Administrators: True / Marketing: False / Carol: False / AP Payments: False
=== B04 ===
  Active Violations = 1 / Distinct Users = 1 / Critical = 1
  Dave Both: True / Erin: False / Carol: False
=== B05 ===
  Disabled-member findings = 2 / Distinct disabled accounts = 1 / In privileged groups = 2
  Bob: True / Alice: False / Carol: False
=== B06 ===
  Domain Admins/Administrators/Marketing Distribution/AP Payments/AP Payment Approval: all True
=== B10 ===
  KPI Groups in Scope = 5 / Distinct Members = 5 / Findings = 3 / Privileged Members = 3
  metric Disabled members in groups = 2 / SoD conflicts found = 1 / Privileged-group members = 3
```
Note vs spec: B03 "disabled w/ privilege" badge is 2 (bob disabled in BOTH priv groups -> 2 rows), not 1; the test regexes the ACTUAL badge per spec guidance ("the inner impl MUST regex the actual badge").

### (1) New tests green
`Invoke-Pester -Path .\Tests\SP.BaselineGovernanceCorrectness.Tests.ps1 -Output Detailed`
```
Describing SP.AdaptiveReports — baseline governance correctness (synthetic truth)
  [+] BGC-B03: privileged review flags ONLY the privileged groups/members and counts disabled-with-privilege correctly 276ms
  [+] BGC-B04: SoD report flags EXACTLY the one seeded conflicting identity (no false pos/neg) 120ms
  [+] BGC-B05: orphaned/disabled surfaces disabled accounts and dedups distinct count across groups 63ms
  [+] BGC-B06: inventory catalog lists every seeded group exactly 67ms
  [+] BGC-B10: executive summary KPIs + aggregate counts equal the seeded input 139ms
Tests completed in 1.42s
Tests Passed: 5, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

### (2) Additive proof -- existing render suite still green
`Invoke-Pester -Path .\Tests\SP.AdaptiveBaselineReports.Tests.ps1 -Output Detailed`
```
Tests Passed: 13, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```
(BR-001..BR-007, 13 test cases incl. the BR-002 -ForEach expansion -- all Passed.)

### (3) Parse/lint the new file
`$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile('...SP.BaselineGovernanceCorrectness.Tests.ps1',[ref]$t,[ref]$e); $e`
```
PARSE OK (no errors)
```

Did NOT launch the dashboard / FlaUI / W-08b (human-run gates).

## Commit
`6e0c10c` -- test(reports): governance content-correctness for B03/B04/B05/B06/B10 on synthetic truth
(Note: this record was committed in the same commit; an --amend updated the recorded hash, so the
final SHA of THIS commit as resolved by `git log -1` supersedes the literal value above if they differ.)

## Status
DONE

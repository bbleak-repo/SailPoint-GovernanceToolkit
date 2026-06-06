# Round 10 (fix round)
**Started:** 2026-06-05
**Item:** Hunt fix -- StaleResults.Disabled over-count in Build-SPRCDataset

> NOTE: `round-10.md` already records backlog item AR-10 (SoD port). This is the
> round-10 **fix loop** for a bug found by the hunt; it is written to a distinct
> file to stay additive and not clobber AR-10's ledger entry.

**Read:**
- `Modules/SP.AdaptiveReports/SP.RCDataset.psm1` (Build-SPRCDataset, both anchors)
- `Modules/SP.ReportComponents/RC01-KpiCards.ps1` (At-Risk Members KPI, line 56)
- `Tests/SP.AdaptiveReports.Tests.ps1` (existing AR-001..AR-009)
- `docs/adaptive-reports-rounds/round-00-PROTOCOL.md`

**Did:**
Fixed a genuine net-new SP logic bug: `Build-SPRCDataset` appended an entry to the
`$disabled` (StaleResults.Disabled) list once PER decision RECORD instead of per
distinct identity. A disabled identity holding N entitlements (entitlement anchor)
or appearing across N campaigns/decision categories (campaign anchor) was counted N
times, and the `$disabled` list was never de-duped before return. `RC01-KpiCards`
renders that raw count verbatim as the "At-Risk Members" KPI
(`$risk += @($dis).Count`), so the composable report inflated the at-risk/disabled
number. The per-group Members lists were already de-duped in `New-RCDGroup`
(MemberCount correct), so ONLY the StaleResults.Disabled KPI was affected.

Fix is minimal and additive: introduced a `$disabledSeen` hashtable keyed by
IdentityId and guarded both `$disabled.Add(...)` sites (the entitlement-anchor loop
and the campaign-anchor loop) so each disabled identity is recorded exactly once.
No existing behavior, export, grouping logic, or member-dedup path changed. Added
regression test AR-004b asserting StaleResults.Disabled.Count == 1 for a single
disabled identity 'u1' holding two entitlements (and, separately, appearing across
two campaigns under the campaign anchor).

**Files:** (additive -- behavior fix on net-new SP logic; no removals/rewires)
- `Modules/SP.AdaptiveReports/SP.RCDataset.psm1` (modified -- de-dup guard at both
  `$disabled.Add` sites + comment)
- `Tests/SP.AdaptiveReports.Tests.ps1` (modified -- added regression test AR-004b)
- `docs/adaptive-reports-rounds/round-10-fix.md` (new)

**Verification:**
  - Pester (affected): `Invoke-Pester .\Tests\SP.AdaptiveReports.Tests.ps1` ->
    **10/10 passed** (was 9; +1 new AR-004b). Pre-fix the AR-004b scenario yielded
    StaleResults.Disabled.Count = 2 for 1 distinct identity (reproduced the hunt).
  - Pester (full suite): `Invoke-Pester .\Tests` -> **1118 passed, 0 failed, 0
    skipped, 1118 total**. Green (baseline 1117 + new AR-004b = 1118).
  - Module import: clean within the suite run (no parse/import errors).

**Review:** (pending independent code-review gate)
**Backlog update:** n/a (fix round; no backlog status change)

**Completed:** 2026-06-05
**Status:** SUCCESS

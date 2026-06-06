# Round 3
**Started:** 2026-06-05 16:35:00
**Item:** AR-03 — entitlement adapter `Build-SPRCDataset -Anchor Entitlement`
(campaign anchor AR-05 implemented in the same module — see round-05).

**Read:** `Modules/SP.Audit/SP.AuditQueries.psm1` (`Get-SPEntitlementInventory`
returns an entitlement *catalog*, not per-entitlement members, and hits the mock's
`/v3/entitlements` 405); `Modules/SP.Audit/SP.AuditAnalytics.psm1`
(`Get-SPIdentityAccessSpread` — the authoritative decision-item shape:
IdentityId/IdentityName/SourceName/AccessName/Decision/RiskFlags). Concluded the
reliable identity↔entitlement source is campaign access-review-items, and BOTH
anchors are pivots of that same data.

**Did:** New additive module `Modules/SP.AdaptiveReports/SP.RCDataset.psm1` +
manifest. `Build-SPRCDataset` is a PURE transform: flattens `.Decisions`
{Approved,Revoked,Pending} items into records (StrictMode-safe accessors,
hashtable/PSObject tolerant), then pivots — entitlement anchor groups by
AccessName×SourceName (group=entitlement, domain=source, members=distinct
identities), campaign anchor groups by campaign. Maps RiskFlags `DISABLED/INACTIVE`
→ `Enabled=$false` (+ StaleResults.Disabled), `PRIVILEGED` retained. Returns
`@{Success;Data=@{GroupResults;StaleResults};Error}`. Logs via SP.Core only when
present (standalone-safe). Fixed a PS-5.1 bug (`` `u{0} `` unicode escape → plain
concat). Purely additive; no existing file touched.

**Files:** `Modules/SP.AdaptiveReports/{SP.RCDataset.psm1, SP.AdaptiveReports.psd1}` (new).

**Verification:**
  - `Test-ModuleManifest`: OK. Import clean (unapproved-verb 'Build' warning is
    cosmetic; toolkit loaders use `-DisableNameChecking`).
  - Smoke (synthetic audits → both anchors → New-RCContext → New-ComposableReport):
    Entitlement = 3 groups (App-Reader correctly aggregates 2 identities across 2
    campaigns; 1 disabled), Campaign = 2 groups; both render well-formed HTML.
  - Pester: formal tests = AR-04 (entitlement) / AR-06 (campaign).

**Review:** PASS (self — pure transform, shape proven against the real RC contract;
dedup + disabled mapping verified; additive-only).
**Backlog update:** AR-03 → DONE.

**Completed:** 2026-06-05 16:44:00
**Status:** SUCCESS

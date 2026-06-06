# Round 7
**Started:** 2026-06-05 17:05:00
**Item:** AR-07 — mock-parity audit (the /v3/entitlements 405)

**Read:** `Scripts/Invoke-SPGovernanceMetrics.ps1` (the campaign-audit build loop:
Get-SPAuditCampaigns → Get-SPAuditCertifications → Get-SPAuditCertificationItems →
`Group-SPAuditDecisions` → audit object with `.Decisions`); `Invoke-SPWeeklyDigest.ps1`
(module-load + `Get-SPConfig -ConfigPath` + `Initialize-SPLogging` bootstrap).

**Did:** Confirmed the adapters never touch `/v3/entitlements` — they pivot
campaign-audit data sourced from campaigns/certs/access-review-items (all
mock-served). Authored `Tests/Harness/Test-AR07-AdapterMockParity.ps1`: bootstraps
the SP.Core/Api/Audit + RC/AdaptiveReports chain, probes mock `/health`, rebuilds
real campaign audits from the running mock via the existing pipeline, then runs
`Build-SPRCDataset` for BOTH anchors and renders. Documented the routing decision
+ deferred catalog enrichment in the backlog AR-07 section.

**Files:** `Tests/Harness/Test-AR07-AdapterMockParity.ps1` (new).

**Verification (live mock):**
  - 4 campaigns, 81 decision items built end-to-end.
  - Entitlement anchor: **7 groups / 31 members** → 9.9 KB well-formed HTML.
  - Campaign anchor: **4 groups / 81 members** → 9.0 KB well-formed HTML.
  - Harness exit 0 (PASS).

**Review:** PASS (self — real-data end-to-end proof; the /v3/entitlements 405 is
shown non-blocking with the enrichment path explicitly deferred, not silently
dropped).
**Backlog update:** AR-07 → DONE.

**Completed:** 2026-06-05 17:14:00
**Status:** SUCCESS

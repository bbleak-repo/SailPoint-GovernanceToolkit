# Round 4
**Started:** 2026-06-05 16:50:00
**Item:** AR-04 — entitlement adapter tests (+ AR-06 campaign adapter tests, same file)

**Read:** `Modules/SP.AdaptiveReports/SP.RCDataset.psm1` (anchor logic); the RC
GroupResults contract.

**Did:** Added `Tests/SP.AdaptiveReports.Tests.ps1` (AR-001..AR-009). Synthetic
audits (production decision-item shape) drive both anchors. Entitlement (AR-04):
envelope shape; grouping by entitlement×source (3 groups); cross-campaign dedup
(Okta/App-Reader = Carol+Alice = 2 distinct); RiskFlags DISABLED → member
Enabled=$false + StaleResults.Disabled; empty-audits → Success/0-groups; renders
through the RC engine. Campaign (AR-06): grouping by campaign under one synthetic
domain; distinct identities per campaign (Q1=4, Q2=1); renders.

**Files:** `Tests/SP.AdaptiveReports.Tests.ps1` (new).

**Verification:**
  - Pester (this file): **9 passed / 0 failed** (6 entitlement + 3 campaign).
  - Imports the manifests directly (adapter is pure — no SP.Api mocks needed).

**Review:** PASS (self — asserts real pivot semantics: grouping, dedup, disabled
mapping, render compatibility).
**Backlog update:** AR-04 → DONE (AR-06 covered same file, see round-06).

**Completed:** 2026-06-05 16:55:00
**Status:** SUCCESS

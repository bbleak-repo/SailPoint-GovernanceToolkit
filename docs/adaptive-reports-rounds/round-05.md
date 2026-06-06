# Round 5
**Started:** 2026-06-05 16:44:00
**Item:** AR-05 — campaign adapter `Build-SPRCDataset -Anchor Campaign`

**Read:** (covered by round-03) the decision-record shape; the RC GroupResults contract.

**Did:** No new file — the campaign anchor was implemented in the same
`SP.RCDataset.psm1` write as AR-03 (one module, two anchors). `-Anchor Campaign`
buckets the flattened decision records by CampaignName under a single synthetic
`ISC Campaigns` domain; each group = one campaign, members = its distinct
identities; disabled mapping + StaleResults shared with the entitlement path.

**Files:** (none new — `Modules/SP.AdaptiveReports/SP.RCDataset.psm1`, shipped with AR-03).

**Verification:**
  - Smoke: Campaign anchor → 2 groups (Q1 = 4 distinct identities, Q2 = 1) →
    rendered well-formed HTML through New-ComposableReport.
  - Formal Pester: AR-06.

**Review:** PASS (self — same pure-transform path as AR-03; verified by smoke).
**Backlog update:** AR-05 → DONE.

**Completed:** 2026-06-05 16:46:00
**Status:** SUCCESS

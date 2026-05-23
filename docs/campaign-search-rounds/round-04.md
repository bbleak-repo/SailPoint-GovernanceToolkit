# Round 4
**Started:** 2026-05-23 17:25:43

**S-04 complete.** Added `Get-SPReviewerWorkload` to `SP.AuditQueries.psm1`:

- Takes `-ReviewerIdentityId` (mandatory) and `-Status` (default `@('ACTIVE')`)
- Scans all matching campaigns, fetches certs, filters by `EffectiveReviewer.id`
- Returns per-campaign workload (`CampaignId`, `CampaignName`, `ItemsAssigned`, `ItemsDecided`, `ItemsPending`) plus aggregate totals
- Uses cert-level `decisionsTotal`/`decisionsMade` stats to avoid per-item API overhead
- Exported from `SP.Audit.psd1`

Committed as `288bba5`, pushed to `feature/campaign-search`.

**Completed:** 2026-05-23 17:28:30
**Status:** SUCCESS

# Round 7
**Started:** 2026-05-23 17:34:09

**S-07 complete.** `Get-SPSourceCampaignCoverage` added to `SP.AuditQueries.psm1` and exported from `SP.Audit.psd1`.

The function:
- Paginates `GET /v3/sources` to discover all ISC sources
- Retrieves campaigns via `Get-SPAuditCampaigns` with status/date filters
- For SOURCE_OWNER campaigns: extracts `sourceIds` directly from the campaign object
- For other types: drills into certifications -> access review items -> `access.sourceId`
- Returns `Covered` (with LastCampaign/LastCampaignDate/CampaignCount), `Uncovered` (NeverAudited=true), and `Summary` (TotalSources/Covered/Uncovered/CoverageRate%)

Committed as `df6eb48`, pushed to `feature/campaign-search`.

**Completed:** 2026-05-23 17:36:40
**Status:** SUCCESS

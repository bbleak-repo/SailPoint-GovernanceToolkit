# Round 5
**Started:** 2026-05-23 19:05:49

**P11-05 done.** Added `Get-SPCampaignHealth` to `Modules/SP.Api/SP.Campaigns.psm1` and exported it from `SP.Api.psd1`.

The function:
- Reuses `Get-SPCampaignDeadlineStatus` for deadline classification and campaign retrieval
- Fetches certifications via `Get-SPAuditCertifications` to identify stale/unresponsive reviewers
- Calculates completion velocity (items/day) and projects completion date
- Classifies each campaign as **Red** (overdue, >50% stale, or zero decisions after 48h), **Yellow** (critical/warning deadline, >25% stale, or velocity too slow), or **Green**
- Returns per-campaign health detail plus a summary with Red/Yellow/Green counts

Committed as `a7bda49` and pushed to `feature/auto-phase-11`.

**Completed:** 2026-05-23 19:08:43

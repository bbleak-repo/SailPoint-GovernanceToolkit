# Round 8
**Started:** 2026-05-23 19:15:47

**P11-08 complete.** Added `Measure-SPReviewerReputation` to `SP.AuditReport.psm1` and exported it from `SP.Audit.psd1`.

The function:
- Aggregates reviewer behavior across all provided campaign audits
- Computes a 0-100 reputation score weighted by response time (30%), completion rate (25%), decision diversity (20%), consistency (15%), and escalation history (10%)
- Classifies reviewers into tiers: Excellent (80+), Good (60-79), Needs Attention (40-59), At Risk (<40)
- Excludes reviewers below `MinCampaigns` threshold
- Returns results sorted by score ascending (worst first) for actionability

**Completed:** 2026-05-23 19:19:09

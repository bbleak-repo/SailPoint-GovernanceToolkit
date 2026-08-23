# SailPoint Governance Toolkit -- Status

**Date:** 2026-08-22
**Branch:** master (up to date with origin)
**Commits since V7c initial build:** 29
**Scripts:** 66 | **Tests:** 106 | **Parse errors:** 0 | **TODO/FIXME/HACK:** 0

---

## Evidence Report Family (15 scripts)

| Script | Lines | Type | Status | Notes |
|--------|-------|------|--------|-------|
| V1 | -- | EXPORT+REPORT | Stable | Standalone KPI dashboard |
| V2 | -- | EXPORT+REPORT | Stable | Lean per-campaign evidence |
| V3 | -- | EXPORT+REPORT | Stable | Day-over-day delta hybrid |
| V4 | -- | EXPORT+TRANSFORM+REPORT | Stable | Base cache-honest engine |
| V4b | ~2,120 | EXPORT+TRANSFORM+REPORT | **Fixed** | Honest `completionPctByReviewer` in JSONL (force-close inflation fix) |
| V4c | -- | TRANSFORM+REPORT | Stable | Series-aware delta (restored after V4g rename) |
| V4d | -- | TRANSFORM+REPORT | Deprecated | Prefer V4e |
| V4e | -- | TRANSFORM+REPORT | Stable | Current series recommendation |
| V4f | 1,423 | TRANSFORM+REPORT | **Uncommitted edits** | V4e + first-approval timeline. +54 lines for campaign name filters |
| V4g | 2,362 | EXPORT+TRANSFORM+REPORT | Stable | Persistent entitlement state DB (was briefly V4c, renamed) |
| V5 | -- | EXPORT+REPORT | Stable | Trend-aware with 14 chart styles |
| V6 | -- | TRANSFORM+REPORT | Stable | Read-only visualizer |
| V7 | 2,234 | TRANSFORM+REPORT | Stable | Calendar-day visualizer (13 charts, suspect heuristic fix, accountability rebuild) |
| V7c | 2,670 | TRANSFORM+REPORT | Stable | V7 + engagement heatmap + entitlement state summary (15 charts). Rebuilt on fixed V7 |
| V8 | 1,408 | TRANSFORM+REPORT | Stable | State-powered, <30s render, -AutoFetch, 8 sections |

## State Tracking Modules (v2.1)

| Module | Lines | Status | Key Functions |
|--------|-------|--------|---------------|
| SP.EntitlementState | 767 | Committed | Read/Update/Write-SPEntitlementState, Invoke-SPEntitlementScopeSweep, ReApproved detection |
| SP.ReviewerState | 718 | Committed | Read/Update/Write-SPReviewerState, C/P/M/U classification, weekly compliance |
| SP.StateOrchestrator | 685+26 | **Uncommitted edits** | Invoke-SPStateTracking, Resolve-SPReportDateRange, Select-SPSeriesByCampaignName. +26 lines: incremental checkpointing |

## B2B Governance (ALL UNCOMMITTED)

| File | Lines | Purpose |
|------|-------|---------|
| Scripts/Invoke-SPB2BSetup.ps1 | 1,312 | 8-step idempotent B2B partner onboarding (ISC-side) |
| Scripts/Invoke-SPB2BHealthCheck.ps1 | 993 | 11-check ongoing B2B governance verification |
| Modules/SP.Api/SP.AccessGovernance.psm1 | 971 | Access profile, role, transform CRUD primitives |
| Modules/SP.Api/SP.Sources.psm1 | 605 | Source lookup, entitlement query, aggregation, provisioning |
| Tests/SP.AccessGovernance.Tests.ps1 | 510 | Pester tests |
| Tests/SP.Sources.Tests.ps1 | 468 | Pester tests |
| docs/plans/B2B-SETUP-PLAN.md | 554 | TIER 2 implementation plan |
| Config/settings.json | +12 | B2B configuration block |
| Modules/SP.Api/SP.Api.psd1 | +21 | Manifest registration |
| Modules/SP.Core/SP.Config.psm1 | +7 | B2B defaults |

## Scraper Tools

| Script | Lines | Status | Notes |
|--------|-------|--------|-------|
| Invoke-SPDecisionScrape.ps1 | 919 | **Uncommitted edits** | +170 lines: intra-report dupe detection, re-revoked grants, gap-fill |
| Invoke-SPPendingReviewerScrape.ps1 | 810 | **Uncommitted edits** | +25 lines: chronic trend direction, trailing streak logic |

## SP.CampaignSeries

| Item | Status |
|------|--------|
| SP.CampaignSeries.psm1 | 1,344 lines, committed, registered in SP.Audit.psd1 |
| 6 exported functions | Get-SPCampaignSeriesKey, Group-SPCampaignSeries, Get-SPSeriesItemKey, Resolve-SPSeriesItemState, Get-SPSeriesAttestationDelta, Get-SPSeriesInstanceCompletion |

## Uncommitted Changes Summary

**Modified (13 files, ~358 insertions):**
- Config/settings.json -- B2B config block
- Modules/SP.Api/SP.Api.psd1 -- SP.Sources + SP.AccessGovernance registration
- Modules/SP.Audit/SP.StateOrchestrator.psm1 -- incremental checkpointing
- Modules/SP.Core/SP.Config.psm1 -- B2B defaults
- Scripts/Invoke-SPDailyEvidenceReportV4f.ps1 -- campaign name filters
- Scripts/Invoke-SPDecisionScrape.ps1 -- dupe detection, re-revoked, gap-fill
- Scripts/Invoke-SPPendingReviewerScrape.ps1 -- chronic trend, trailing streak
- Tests/Import-TestModules.ps1 -- loader updates
- Tests/Tools/Test-ScraperReplica.py -- minor test update
- USER-GUIDE.html + docs/USER-GUIDE.html -- user guide updates
- docs/playbook/07-reporting-analytics.md -- playbook updates
- docs/playbook/cli-playbook.md -- CLI playbook additions

**Untracked (new):**
- All B2B files (scripts, modules, tests, plan, PlantUML designs)
- CLAUDE.md (project-local)
- _local-wip/ (reference files, not for commit)

## Key Decisions Since V7c Initial Build

1. **V4c naming conflict resolved:** Original V4c (read-only series-attestation) restored; state-powered version renamed to V4g
2. **V7 reviewer accountability rebuilt:** "Absence is not inaction" -- reviewers not assigned to a day's campaign are no longer penalized
3. **V7 suspect heuristic fixed:** schemaVersion gate prevents false positives on pre-fix JSONL records
4. **V7c rebuilt on fixed V7:** Picks up all V7 bug fixes (corrupt-line counter, CSS, accountability)
5. **V8 gets -AutoFetch:** Single entry point that refreshes state files before rendering
6. **ReApproved detection:** SP.EntitlementState now tracks REVOKE->APPROVE transitions
7. **State v2.1:** Fixed broken orchestrator contract, hardened both state modules
8. **Scraper hardening:** Decision scraper gains gaming pattern detection, auto-MinMisses

## Next Steps / Open Items

1. **Commit B2B work** -- 6 new files + 4 supporting modifications, all parse-clean
2. **Commit scraper enhancements** -- dupe detection, re-revoked grants, chronic trend direction
3. **Commit V4f campaign name filters** -- parity with V4b/V4g
4. **Commit StateOrchestrator checkpointing** -- crash resilience for multi-hour runs
5. **Playbook updates** -- V4f, V4g, V8 entries may need expansion; B2B section needed
6. **Version bumps** -- all scripts still at 1.0.0 despite significant evolution
7. **_local-wip/ cleanup** -- reference files incorporated into V7c; can be .gitignored

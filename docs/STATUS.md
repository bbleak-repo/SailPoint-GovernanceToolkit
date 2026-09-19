# SailPoint Governance Toolkit -- Status

**Date:** 2026-08-22 (commit-status corrections 2026-09-07; validation-loop update 2026-09-06/07; change narrative lives in `CHANGES.md`)
**Branch:** master (up to date with origin)
**Commits since V7c initial build:** 29
**Scripts:** 67 | **Test files:** 109 | **Suite:** 2,486 tests, 0 failures, 44 skipped (pwsh 7.6.5 / Pester 5.7.1) | **Parse errors:** 0

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
| V8 | ~1,540 | TRANSFORM+REPORT | **Uncommitted edits** | State-powered, <30s render, -AutoFetch, 8 sections. +Decision Activity (daily transition trend, top revoked, source breakdown from stateLog); covered by SP.DailyEvidenceV8Decision.Tests (11) |

## State Tracking Modules (v2.1)

| Module | Lines | Status | Key Functions |
|--------|-------|--------|---------------|
| SP.EntitlementState | 767 | Committed | Read/Update/Write-SPEntitlementState, Invoke-SPEntitlementScopeSweep, ReApproved detection |
| SP.ReviewerState | 718 | Committed | Read/Update/Write-SPReviewerState, C/P/M/U classification, weekly compliance |
| SP.StateOrchestrator | 685+26 | **Uncommitted edits** | Invoke-SPStateTracking, Resolve-SPReportDateRange, Select-SPSeriesByCampaignName. +26 lines: incremental checkpointing |

## B2B Governance (committed 2026-08-23 in `a31f218`; see CHANGES.md for the full entry)

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
| Invoke-SPDecisionScrape.ps1 | 919 | Committed (`a31f218`) | Intra-report dupe detection, re-revoked grants, gap-fill; validated live 2026-09-06 |
| Invoke-SPPendingReviewerScrape.ps1 | 810 | Committed (`a31f218`) | Chronic trend direction, trailing streak logic; validated live 2026-09-06 |

## Configuration Inventory (NEW 2026-09-06, uncommitted)

| Item | Status |
|------|--------|
| Scripts/Invoke-SPConfigInventory.ps1 | Read-only ISC configuration documentation: 19 object types, HTML + JSON + optional CSVs, identity count |
| -PermissionCheck probe | Per-endpoint tenant-truth permission matrix (200 / 403 + required level / 404) |
| Governance Posture Findings | Severity-ranked assessment: unhealthy/ownerless sources, overdue ACTIVE campaigns, ownerless roles/APs, privileged+requestable entitlements, failing workflows, unenforced SoD, degraded VA clusters |
| Tests/SP.ConfigInventory.Tests.ps1 | 13 integration tests vs Tests/Tools/mock-isc-inventory.js |

## SP.CampaignSeries

| Item | Status |
|------|--------|
| SP.CampaignSeries.psm1 | 1,344 lines, committed, registered in SP.Audit.psd1 |
| 6 exported functions | Get-SPCampaignSeriesKey, Group-SPCampaignSeries, Get-SPSeriesItemKey, Resolve-SPSeriesItemState, Get-SPSeriesAttestationDelta, Get-SPSeriesInstanceCompletion |

## Uncommitted Changes Summary

**RESOLVED 2026-08-23:** everything below was committed in `a31f218` (22 files,
6,025 insertions), followed by three playbook doc commits (`b276fd3`,
`a32dc84`, `a8c41a6`). Original pre-commit inventory kept below for the record.

**CURRENT uncommitted set (2026-09-06 validation loop -- full narrative in
`CHANGES.md`, final gate 2,486 tests / 0 failures):**

- NEW: `Scripts/Invoke-SPConfigInventory.ps1`, `Tests/SP.ConfigInventory.Tests.ps1`,
  `Tests/SP.DailyEvidenceV8Decision.Tests.ps1`, `Tests/SP.DailyEvidenceV4gLive.Tests.ps1`,
  `Tests/Tools/mock-isc-inventory.js`, `Tests/Tools/mock-isc-v4g.js`
- `Scripts/Invoke-SPDailyEvidenceReportV8.ps1` -- Decision Activity sub-section
  (stateLog-mined daily trend + rankings + source breakdown)
- PID bug fix (`$pId` collides with read-only automatic `$PID`; degraded the
  High-Risk Exposure KPI on every engine): `Modules/SP.Audit/SP.AuditAnalytics.psm1`,
  `Scripts/Invoke-SPDailyEvidenceReport{,V2,V3,V4g}.ps1`
- Cross-platform test fixes: `Tests/SP.CacheRobustness.Tests.ps1` (-Encoding Byte),
  `Tests/SP.DailyEvidenceV7Reconcile.Tests.ps1` (engine autodetect),
  `Tests/SP.ScheduledVaultSecret.Tests.ps1` (DPAPI skips on non-Windows)
- Docs: `docs/playbook/cli-playbook.md`, `docs/playbook/07-reporting-analytics.md`,
  both `USER-GUIDE.html` copies, `docs/toolkit-status.md` pointer, `docs/CHANGES.md`
  + this file; `.gitignore` +`.pwsh/`

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

1. ~~Commit B2B work~~ -- DONE 2026-08-23 (`a31f218`)
2. ~~Commit scraper enhancements~~ -- DONE 2026-08-23 (`a31f218`)
3. ~~Commit V4f campaign name filters~~ -- DONE 2026-08-23 (`a31f218`)
4. ~~Commit StateOrchestrator checkpointing~~ -- DONE 2026-08-23 (`a31f218`)
5. ~~Playbook updates~~ -- DONE 2026-08-23 (`b276fd3`, `a32dc84`, `a8c41a6`)
6. **Version bumps** -- all scripts still at 1.0.0 despite significant evolution
7. **_local-wip/ cleanup** -- reference files incorporated into V7c; can be .gitignored
8. **B2B Mac-side follow-ups** -- PS 5.1 Pester pass; PlantUML render of
   `docs/designs/b2b-governance/01-b2b-group-naming-convention.puml`
9. **Commit or document the post-a31f218 working tree** -- V4g/V8/V1-V3 edits,
   SP.AuditAnalytics, Invoke-SPConfigInventory + tests, mock-isc tools

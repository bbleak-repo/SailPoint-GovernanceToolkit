# Modularization Plan -- #CODE TIER4

## Archive Point
- Tag: `v1.5.0-pre-modularization`
- Commit: `0124061` (last commit before refactoring)
- All tests passing, zip current

## Problem Statement
Rapid feature delivery (V1-V4 evidence reports, escalation enhancements, CampaignDiff, GUI integration) created duplicated patterns across 15+ modules and 40+ scripts. Three key areas need shared module extraction.

## New Modules to Create

### SP.Shared/SP.HtmlHelpers.psm1 (Phase 1 -- LOW risk)
Extract from: SP.CampaignDiff, SP.AuditReportHtml, SP.DeltaCertReport, SP.DisconnectedAppReports, V1-V4 scripts, Escalate script

Functions to export:
- `ConvertTo-SPHtmlSafe` -- unified HTML encoder (PS 5.1 safe, replaces ConvertTo-SafeHtml, ConvertTo-EscHtml, Get-SPDiffEnc, raw WebUtility calls)
- `Format-SPHtmlDate` -- merge Format-HtmlDate + Get-SPDiffShortDate + ConvertTo-CTDate
- `Get-SPHtmlColorPalette` -- returns @{ Green='#339933'; Red='#CC3333'; Amber='#FF8800'; Blue='#336699'; Dark='#1f3a5f'; Gray='#777777' }
- `New-SPHtmlDocument` -- StringBuilder + embedded CSS + charset + viewport meta
- `Write-SPHtmlFile` -- UTF8 no-BOM WriteAllText wrapper
- `Get-SPObjectProperty` -- merge Get-SPDiffProp (369 uses) / Get-V3Prop / Get-V4Prop / Get-CTProp -- polymorphic hashtable+PSCustomObject property reader

Consumers to update (15 files):
- Modules/SP.Audit/SP.CampaignDiff.psm1
- Modules/SP.Audit/SP.AuditReportHtml.psm1
- Modules/SP.Audit/SP.CampaignTrend.psm1
- Modules/SP.Audit/SP.CertTracker.psm1
- Modules/SP.Audit/SP.CampaignVelocity.psm1
- Modules/SP.DeltaCert/SP.DeltaCertReport.psm1
- Modules/SP.DisconnectedApps/SP.DisconnectedAppReports.psm1
- Scripts/Invoke-SPDailyEvidenceReport.ps1 (V1)
- Scripts/Invoke-SPDailyEvidenceReportV2.ps1
- Scripts/Invoke-SPDailyEvidenceReportV3.ps1
- Scripts/Invoke-SPDailyEvidenceReportV4.ps1
- Scripts/Invoke-SPDeltaCertEscalate.ps1
- Scripts/Invoke-SPGovernanceMetrics.ps1
- Scripts/Invoke-SPGovernanceHealthCheck.ps1
- Scripts/Invoke-SPWeeklyDigest.ps1

### SP.Shared/SP.IdentityService.psm1 (Phase 2 -- MEDIUM risk)
Extract from: SP.DeltaCert/SP.DeltaCertQueries.psm1, SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1

Functions to export:
- `Get-SPIdentityDetail` -- unified ID -> name/email/manager/active (merge DeltaCert + DisconnectedApps)
- `Search-SPIdentityByEmail` -- email -> identity ID (consolidate email-to-ID lookups)
- `Get-SPManagerChain` -- walk up org tree, return chain array (used by escalation, hierarchy)
- `Clear-SPIdentityCache` -- flush all identity caches

Caching: single `$script:IdentityCache` with configurable TTL from `Audit.IdentityCacheTtlMinutes`

### SP.Shared/SP.CacheService.psm1 (Phase 3 -- MEDIUM risk)
Extract from: scattered $script:*Cache patterns across 5 modules

Functions to export:
- `Get-SPCachedItem` -- key -> value with TTL check
- `Set-SPCachedItem` -- key + value + optional TTL
- `Clear-SPCacheStore` -- flush by store name
- `Test-SPCacheValid` -- check item age vs TTL
- `New-SPCacheStore` -- create a named store with config-driven TTL

## Phase 4: Cleanup
- Remove duplicate private functions from source modules
- Update all .psd1 manifests to declare SP.Shared dependency
- Update build-dist.ps1 if needed (should auto-include via recursive Modules/)
- Run full Pester test suite
- Verify GUI still loads

## Risk Mitigation
- Tagged archive at v1.5.0-pre-modularization
- Each phase gets its own commit + test pass
- Use worktree agents for parallel file updates
- Opus review agent validates each phase before merge
- Keep old function names as thin wrappers initially (deprecation aliases)

## Estimated Effort
- Phase 1: 2-3 hours (15 files, low risk, just extracting + re-pointing)
- Phase 2: 2-3 hours (merge 2 implementations, update callers)
- Phase 3: 1-2 hours (abstract caching layer)
- Phase 4: 1 hour (cleanup + full test)
- Total: 6-9 hours wall clock with TIER4 parallel agents

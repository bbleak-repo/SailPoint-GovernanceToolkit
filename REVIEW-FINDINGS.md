# Code Review Findings — 2026-07-07

Full-codebase review focused on logic, reporting accuracy, and cache correctness.
Every finding was verified against source; several were verified empirically under
Windows PowerShell 5.1. Findings marked **[FIXED]** were remediated on branches
`fix/review-findings` and `fix/remaining-findings` (all 49 findings resolved) — see `REVIEW-CHANGES.html` for before/after details.

Severity: **C** = critical (feature broken), **H** = high (wrong data / cache
integrity), **M** = medium, **L** = low.

---

## A. Broken API plumbing

| # | Sev | Finding | Location |
|---|-----|---------|----------|
| A1 | C | **Double `/v3` in URLs.** `Api.BaseUrl` ends in `/v3` and the client concatenates endpoints verbatim, but 14 call sites pass `/v3/...` endpoints → `/v3/v3/...` 404s. Kills Get-SPEntitlementInventory, Get-SPAccessProfileInventory, Get-SPRoleInventory, Save-SPConfigurationSnapshot, Get-SPOrphanAccounts (returns empty result as *success*), Get-SPSourceAggregationHealth, Measure-SPIdentityDataQuality, Test-SPSourceOnboardingReadiness. **[FIXED]** | `SP.ApiClient.psm1:324`; `SP.AuditQueries.psm1:3141, 3482, 3881, 4607, 5105, 5217, 5378, 5420, 5490, 5826, 6605, 6671, 6780, 6831`; `SP.Config.psm1:1170+` |
| A2 | H | **`Test-SPConfiguration -ValidateConnectivity/-ResolveEntities` always fails.** Passes a nonexistent `-Config` parameter to `Get-SPAuthToken` / `Invoke-SPApiRequest` (ParameterBindingException caught and reported as config error). Latent behind that: `if ($token)` is truthy for the failure envelope; `.name` read on the envelope instead of `.Data`; `/v3/...` endpoints (A1). **[FIXED — parameter + envelope + endpoints]** | `SP.Config.psm1:1156, 1170, 1189, 1209` |
| A3 | H | **Single-op JSON Patch serialized as object, not array.** `$Body | ConvertTo-Json` unwraps a one-element array, so a single RFC 6902 op is sent as `{...}` instead of `[{...}]` → 400. **[FIXED]** | `SP.ApiClient.psm1:392` |
| A4 | M | **Retry loop re-sends non-idempotent requests.** `$shouldRetry` is computed from status code only (429/5xx/0 incl. client timeout); POST/PATCH/DELETE are re-sent — duplicate campaign creation / decision resubmission risk. **[FIXED — Method-aware retries: 5xx/status-0 retry only idempotent methods; 429 retries all.]** | `SP.ApiClient.psm1:455` |
| A5 | L | **`Build-SPQueryString` NREs on `$null` param value**, bypassing the normalized error envelope (call site is outside the retry try/catch). **[FIXED — Null query-param values are skipped.]** | `SP.ApiClient.psm1:114` |

## B. Cache correctness

| # | Sev | Finding | Location |
|---|-----|---------|----------|
| B1 | H | **`-RefreshCache` never bypasses cache reads.** Both memory and disk read layers gate only on `-not $NoCache`; a completed (permanent) campaign cache can never be refreshed. **[FIXED]** | `SP.AuditQueries.psm1:7155, 7178` |
| B2 | H | **`-NoCache -RefreshCache` writes items but never the meta sidecar.** Fresh items pair with stale meta; the seal-on-transition path then stamps post-completion data `CapturedWhileActive=$true` — provenance flags lie. **[FIXED]** | `SP.AuditQueries.psm1:7420` |
| B3 | H | **Transient API failures cached as "identity not found" for the whole session.** SPIdentity store has TTL 0; a 429/timeout caches `Found=$false` → blank names/managers in all reports for the session. Same in `Search-SPIdentityByEmail`. **[FIXED — failures now carry a 15-min TTL]** | `SP.IdentityService.psm1:379-382, 481; 553, 601` |
| B4 | H | **Dead tenant-isolation guard in `Get-SPAuthToken`.** `$config` read at :554 but assigned at :609 → `TenantUrl` never cached, mismatch eviction never fires; token for tenant A served to tenant B in-process. **[FIXED]** | `SP.Auth.psm1:554, 678` |
| B5 | M | **Interrupted TTL-refresh permanently seals partial data.** Old items file deleted at fetch start, old meta replaced only at finalize; crash mid-fetch + campaign completes → partial set sealed permanent, no self-heal. **[FIXED — Stale meta removed (provenance captured first) at refetch start; partials can no longer be sealed.]** | `SP.AuditQueries.psm1:7320, 7461` |
| B6 | M | **Identity disk-cache compaction silently no-ops when all entries are expired** — `Write-SPHtmlFile` has `[Parameter(Mandatory)][string]$Content`, which rejects empty strings; swallowed by `catch { }`. **[FIXED — AllowEmptyString]** | `SP.IdentityService.psm1:258`; `SP.HtmlHelpers.psm1:253` |
| B7 | L | **JWT payload decoded as standard Base64, not base64url** — tenant URL extraction fails for most real JWTs (silently). **[FIXED]** | `SP.Auth.psm1:784` |
| B8 | L | `Get-SPConfig` returns a shared mutable object reference; caller mutation poisons all later reads. **[FIXED (follow-up branch) — -AsCopy private deep clone added; read-only contract documented on the shared default return (per-call clone too slow for identity hot loops).]** | `SP.Config.psm1:1463` |
| B9 | L | Item memory cache keyed by campaign id only — ignores `-CachePath`; second path gets the other directory's items. **[FIXED — Memory cache keyed by campaignId|cachePath.]** | `SP.AuditQueries.psm1:7155` |
| B10 | L | Partial-fetch resume path ignores `-NoCache` — "fresh" fetch silently includes leftover partial disk data. **[FIXED — resume now applies only to default fetches (fixed with B1/B2).]** | `SP.AuditQueries.psm1:7290` |
| B11 | L | PII ACL warning misses `FullControl` (`FileSystemRights -match 'Read'` doesn't match "FullControl"). **[FIXED — ACL match extended to FullControl/Modify.]** | `SP.IdentityService.psm1:175` |
| B12 | L | Concurrent processes can lose identity-cache appends during another session's compaction rewrite (read → rewrite → move window). **[FIXED (follow-up branch) — Cross-process mutex (G10 pattern) guards per-entry appends AND the compaction read->rewrite->replace.]** | `SP.IdentityService.psm1:220-261` |
| B13 | L | `Test-SPCacheValid` doesn't lazy-load from disk the way `Get-SPCachedItem` does (latent — only tests use it today). **[FIXED (follow-up branch) — Shared _EnsureDiskLoaded helper; Test-SPCacheValid now lazy-loads like Get-SPCachedItem.]** | `SP.CacheService.psm1:297` |
| B14 | L | `TrimStart('.\')` treats the argument as a character set — corrupts `..\`-style and `.hidden\` relative vault/credential paths. **[FIXED (follow-up branch) — Single-prefix regex strip in all 16 sites across 8 files; '..' parent paths now resolve via GetFullPath.]** | `SP.Auth.psm1:225, 306, 413, 443` |

## C. Reporting — rendering corruption

| # | Sev | Finding | Location |
|---|-----|---------|----------|
| C1 | H | **Argument-mode `ConvertTo-SPHtmlSafe [string]$x`** renders literal `[string]…` garbage: Audit Metadata table in every audit HTML (`[string]System.Collections.Hashtable[Tenant]`), master leadership rollup (every name/date), hierarchical report Access Name/Type (full object dump), level-report `<th>` (binding error → blank). **[FIXED]** | `SP.AuditReportHtml.psm1:1349, 2991, 11047-11049, 11457` |
| C2 | H | **Per-campaign HTML/text reports overwrite each other** when campaign names share a 35-char prefix (all "Daily Attestation …" campaigns) — same truncated filename + same run timestamp; TOC anchors collide too. **[FIXED — campaign-id suffix]** | `SP.AuditReportHtml.psm1:1400, 1406, 1709` |
| C3 | M | Leadership level-report drill-down/nav links point to filenames that are never written (missing `-$safeId-$runStamp` suffix). **[FIXED — Links now mirror the real filename scheme (prefix-name-id-runStamp) with a shared per-set RunStamp; dead fallback link removed.]** | `SP.AuditReportHtml.psm1:2967, 3277-3287` |

## D. Reporting — wrong numbers

| # | Sev | Finding | Location |
|---|-----|---------|----------|
| D1 | H | **`RubberStampRisk` always "None"** in reviewers CSV and BI export — lookup reads `$rr.Name`; objects carry `ReviewerName`. **[FIXED]** | `SP.AuditReportHtml.psm1:4147, 6854` |
| D2 | M | Remediation proof only matches literal `REVOKE` — `REVOKED`/`DENY`/`REJECT`/`EXCEPTION` and nested `{value:...}` shapes dropped; Section 4 vs Section 6 totals contradict. **[FIXED — Canonical decision unwrap/variants in all three surfaces.]** | `SP.AuditReportCore.psm1:1609`; also `:928`, `Get-SPRevocationDisposition:83` |
| D3 | M | `Get-SPRemediationStatus` accepts source-only match → unrelated revocations marked "Provisioned", failed revokes hidden. **[FIXED — Events with items require entitlement match; source-only fallback only when the event has no items.]** | `SP.AuditQueries.psm1:2896` |
| D4 | M | Pending items get fabricated `DecisionDate` (modified/created fallback) rendered as a real decision time; also feeds false "bulk decision cluster" rubber-stamp flags and a pending-inclusive approval-rate denominator. **[FIXED — Pending rows render blank dates; rubber-stamp metrics decided-only (user-approved).]** | `SP.AuditReportCore.psm1:966, 2050` |
| D5 | M | Exec summary double-counts reassigned reviewers (one entry per cert) in "Reviewers Signed Off" / completion %; `Group-SPReviewerActions` keeps first cert's Phase/SignOffDate. **[FIXED — Distinct-reviewer exec counting; Phase=all-signed; SignOffDate=most recent (user-approved).]** | `SP.AuditReportHtml.psm1:226`; `SP.AuditReportCore.psm1:1117` |
| D6 | M | `Sort-Object -Property` on hashtable elements is a no-op on PS 5.1 → `LastCampaign`/`LastCampaignDate` wrong in source-coverage report. **[FIXED — Scriptblock sort key.]** | `SP.AuditQueries.psm1:2568` |
| D7 | M | Reviewer-delegation metric uses loop-leaked `$campaignCreated` (last campaign only) for all reviewers' `AvgHoursBeforeDelegation`. **[FIXED — Lead-times computed at collection against each delegation’s own campaign.]** | `SP.AuditQueries.psm1:6466` |
| D8 | M | `Get-SPSourceAggregationHealth` mixes `[datetime]::UtcNow` with local-Kind parse — freshness off by the UTC offset (false/missed staleness). **[FIXED — RoundtripKind parse + ToUniversalTime.]** | `SP.AuditQueries.psm1:5471, 5563` |
| D9 | M | Empty (0-item) signed certs classified NotStarted and escalated on the leadership "stalled reviewers" list. **[FIXED — NotStarted requires items present and cert not completed.]** | `SP.CampaignDiff.psm1:207, 219, 379` |
| D10 | L | `Get-SPOrphanAccounts` include-switches only apply to Uncorrelated orphans; Terminated/Dangling categories always include disabled/service accounts. **[FIXED (follow-up branch) — Both switches now gate every orphan category (Uncorrelated, TerminatedOwner, DanglingReference).]** | `SP.AuditQueries.psm1:5148, 5241-5269` |
| D11 | L | `Measure-SPCampaignMetrics` doesn't unwrap nested decision objects → 0% completion on nested-shape tenants while audit shows approvals. **[FIXED — Nested decision unwrap added to Measure-SPCampaignMetrics.]** | `SP.AuditReportCore.psm1:3021` |
| D12 | L | `ReviewerCount` metric is a certification count — double-counts multi-cert/reassigned reviewers. **[FIXED (follow-up branch) — Distinct reviewers by id (name fallback); unknown-reviewer certs still count once each.]** | `SP.AuditReportCore.psm1:3084` |
| D13 | L | Campaign comparison colors slower response times green (delta sign not inverted for time metrics). **[FIXED (follow-up branch) — All hours-format metrics (response times) invert delta colors like RevocationRate.]** | `SP.AuditReportHtml.psm1:3724` |
| D14 | L | BI export leadership columns read keys that never exist (`ExecutiveName`, `Identities`) → always blank. **[FIXED (follow-up branch) — Group-SPAuditByLeadership now emits per-manager Identities + per-director ExecutiveName; BI columns populate.]** | `SP.AuditReportHtml.psm1:6716` |
| D15 | L | RC03 expanded tree labels unknown-Enabled members as "enabled", contradicting the collapsed 3-state counts. **[FIXED (follow-up branch) — 3-state badge; unknown Enabled renders 'unknown' (neutral).]** | `RC03-Tree.ps1:64` |

## E. Evidence scripts & orchestrator

| # | Sev | Finding | Location |
|---|-----|---------|----------|
| E1 | C | **V5 crashes on every run with data** — `$isCrossCampaign`/`$distinctCampIds` read ~40 lines before assignment under `Set-StrictMode -Version 1` + `EAP=Stop`. **[FIXED]** | `Invoke-SPDailyEvidenceReportV5.ps1:634 / 666-671` |
| E2 | H | V5 baseline scope-added reads the wrong trend record when a day has multiple captures (`$trendRecords[$dailyData.IndexOf($d)]` misalignment). **[FIXED — scope.added read from the same record the day entry is built from.]** | `Invoke-SPDailyEvidenceReportV5.ps1:799` |
| E3 | H | V7 "suspect" filter silently drops every legitimately 100%-completed day by default; all-complete window → exit 5 "No calendar days resolved". **[FIXED — Suspect records dropped only when the day has an honest capture; suspect-only days kept flagged.]** | `Invoke-SPDailyEvidenceReportV7.ps1:421, 441` |
| E4 | M | V4e "series attestation coverage" counts undecided NewlyInScope items as attested (can print "100% genuinely attested" with zero decisions). **[FIXED — Coverage subtracts the independent IsPersistentlyUndecided fact (user-approved).]** | `Invoke-SPDailyEvidenceReportV4e.ps1:807` |
| E5 | M | Series chrono-key parses period tokens with current culture — wrong instance ordering (wrong baseline/newest) on dd/MM locales; whole V4c/V4d/V4e delta engine misclassifies. **[FIXED — InvariantCulture-first parse.]** | `SP.AuditQueries.psm1:7726` |
| E6 | M | Orchestrator Steps 8/9 swallow `Success=$false` results — green "Success" line, exit 0, audit JSONL certifies a run that collected nothing. **[FIXED — Returned Success=$false now counted as errors.]** | `Invoke-SPDailyOrchestrator.ps1:1075, 1136` |
| E7 | M | Step 11 stalled-reviewer warnings never recorded in step results/audit trail; Step 11/12 warnings never raise the exit code. **[FIXED — Step 11 recorded in step results/audit trail; Step 11/12 warnings raise exit code.]** | `Invoke-SPDailyOrchestrator.ps1:1266, 1310, 1354` |
| E8 | M | V6 Chart 10 / V7 Chart 7 "CUMULATIVE/TOTALS" rows sum daily *snapshots*, not deltas — multiply-count when one campaign spans days. **[FIXED — Window aggregates use latest snapshot per distinct campaign.]** | `V6.ps1:1292`; `V7.ps1:1362` |
| E9 | M | Scraper `-Until` excludes reports from the Until day when filenames carry timestamps (time-of-day vs midnight comparison). **[FIXED — Dates day-normalized at parse; -Until inclusive again.]** | `Invoke-SPPendingReviewerScrape.ps1:255` |
| E10 | L | Scraper `-MinMisses` / chronic-pending denominator count per report file, not per calendar day — regenerated reports skew both. **[FIXED — Per-calendar-day counting for -MinMisses/Pct/heatmap.]** | `Invoke-SPPendingReviewerScrape.ps1:282` |
| E11 | L | Scraper takes only the first `<table>` per Pending/Undecided collapsible (latent multi-table format hazard). **[FIXED (follow-up branch) — All tables per Pending/Undecided collapsible are scraped (Matches, not Match).]** | `Invoke-SPPendingReviewerScrape.ps1:124` |

## F. Scope-key stability (user-reported, 2026-07-07 second session)

| # | Sev | Finding | Location |
|---|-----|---------|----------|
| F1 | H | **Reassignment-driven AccessId churn fabricated "newly approved"/"newly in scope" items.** Every scope key (snapshot `Key`, diff maps, series `ItemKey`, V3's `Get-V3Key`, entitlement-history timelines) was AccessId-first, but ISC regenerates access ids when a certification is reassigned to a new reviewer (already detected by `Invoke-SPCacheDiagnostic`'s cross-campaign check). A reassigned grant changed keys between captures: diff classified it Removed+Added, the series engine as NewlyInScope/NewlyAttested, and its decision reported as "newly approved". **[FIXED — grants keyed by IdentityId + entitlement NAME (lowercased) + SourceId-else-name via shared `Get-SPStableScopeKey`; AccessId only when the name is blank; diff/timelines/V3 recompute at load so old snapshots stay comparable. Verified: simulated reassignment now diffs 0 added / 0 removed (was 1/1).]** | `SP.CampaignDelta.psm1` (new `Get-SPStableScopeKey` + snapshot Key), `SP.CampaignDiff.psm1` (map/timeline/CSV recompute), `SP.CampaignSeries.psm1:484` (name-first precedence), `Invoke-SPDailyEvidenceReportV3.ps1` |

---

*Review conducted 2026-07-07 on branch `fix/review-findings` (base: master 558e908).*

# SailPoint Governance Toolkit -- Change Log

Newest first. Each entry records what changed, why, and how it was verified.
Inventory-style state lives in `STATUS.md`; this file is the narrative record.
Entries before 2026-08-21 are summarized from commit messages.

---

## 2026-09-06 -- Deep validation loop: everything executed for real + three enhancements (uncommitted)

Two back-to-back autonomous validation/enhancement rounds run entirely under real
PowerShell in the analysis container (pwsh 7.6.5 bootstrapped from scratch into
`/work/.pwsh`, now gitignored). Every change below was gated by full Pester runs.
**Final gate: 2,486 tests -- 2,434 passed / 0 failed / 44 skipped** (session start:
2,455 tests with 8 failures; +31 tests, all protecting new functionality).

### New files

| File | Purpose |
|------|---------|
| `Scripts/Invoke-SPConfigInventory.ps1` | Read-only ISC configuration inventory: 19 object types, HTML + JSON (+ optional per-section CSVs), `-PermissionCheck` probe, Governance Posture Findings assessment |
| `Tests/SP.ConfigInventory.Tests.ps1` | 13 integration tests vs the committed node mock (paging exactness, sample caps, 403/404 degradation, findings, CSV, identity count) |
| `Tests/SP.DailyEvidenceV8Decision.Tests.ps1` | 11 tests: V8 Section-2 family (Newly Decided / Re-Approved / Decision Activity) rendered from state built through the REAL state machine |
| `Tests/SP.DailyEvidenceV4gLive.Tests.ps1` | 7 tests: LIVE V4g pipeline (OAuth -> fetch -> cache -> snapshot -> state DB -> HTML) against a two-phase mock ISC; DV7R-style config swap, sandboxed output |
| `Tests/Tools/mock-isc-inventory.js` | Node mock ISC for the inventory tests (paged collections, 403/404 endpoints, X-Total-Count search) |
| `Tests/Tools/mock-isc-v4g.js` | Node mock ISC for the V4g live tests (oauth/campaigns/certifications/access-review-items, env-parameterized port + phase file) |

### Invoke-SPConfigInventory.ps1 (the "document everything" deliverable)

Sources, identity profiles, campaigns + templates, roles, access profiles, entitlements
(100-item sample unless `-IncludeEntitlements`), governance groups, SoD policies,
identity attributes, transforms, workflows, VA clusters, service desk integrations,
password policies, segments, connector rules, branding, public-identities config, plus
an identity count from the search API's X-Total-Count header. **Permissions answer:**
`-PermissionCheck` probes every endpoint and prints the tenant-truth matrix (200
readable / 403 denied with the least-privilege user level to grant / 404 absent);
simplest full coverage is an ORG_ADMIN-owned PAT with `sp:scopes:all`. **Governance
Posture Findings** turns the inventory into an assessment: unhealthy/ownerless sources,
ACTIVE campaigns past deadline, ownerless roles/access profiles,
privileged-AND-requestable entitlements, failing workflows, unenforced SoD policies,
degraded VA clusters -- severity-ranked in HTML/JSON/console, computed only from
sections the token could read.

### V8: Decision Activity (closes the August ask to expose the DecisionScrape analytics)

Section 2 gains daily approval/revocation transition trend chart (adaptive SVG), raw
daily table, top revoked entitlements/identities, and per-source breakdown -- computed
from honest stateLog transitions (an event is an entry whose code differs from the
previous entry and lands on A/R; first-seen states and idNowAutoApproved U entries
never count). Justifications remain in the V4g register by design.

### Production bug: `$pId` IS `$PID`

`$pId = ...` in `SP.AuditAnalytics.psm1` and `Invoke-SPDailyEvidenceReport{,V2,V3,V4g}`
collided with the read-only automatic `$PID` (variable names are case-insensitive).
The assignment throws on EVERY engine and silently degraded the High-Risk Exposure
KPI behind its catch block in production. Renamed to `$polId`/`$pendId`; V4g Step 6
now computes Green. Found by the first-ever live V4g run, not by reading.

### Test suite: 8 cross-platform failures fixed (environmental, not logic)

`-Encoding Byte` -> `ReadAllBytes` (SP.CacheRobustness); hardcoded `powershell` exe ->
engine autodetect (SP.DailyEvidenceV7Reconcile -- V7 now executes end-to-end in tests
on Linux); DPAPI ScheduledVault tests SV-01/02/03 now skip on non-Windows (SV-04/05
AclFile mode run everywhere).

### Verification highlights

- V4g ran live end-to-end twice against the mock: phase-1 baseline seeds with ZERO
  false newly-decided; phase-2 detects exactly 1 newly decided + 1 re-approved with
  correct dates; re-runs converge (idempotency observed live). Flop attribution goes
  to the cert-assigned reviewer -- confirmed as the cache-honesty design, not a bug.
- Both scrapers + V4f executed under real pwsh for the first time; every count matched
  the Python-replica baselines; V4f campaign filters + no-match stem listing verified
  against the committed 11-instance cache fixture.
- Gotchas recorded in the test files for future sessions: Pester discovery-phase
  variables are invisible in run-phase BeforeAll; TestDrive deletes files created
  inside a Describe when the block exits; `ni` aliases New-Item and aliases outrank
  functions; `-WindowStyle` throws on non-Windows; `@(Generic.List)` can throw
  "Argument types do not match" (use `.ToArray()`).

### Docs

cli-playbook: Invoke-SPConfigInventory entry + quick-reference row (66 -> 67 scripts),
V8 section-2 description; 07-reporting-analytics: Configuration Inventory catalog row,
V8 sections table; USER-GUIDE.html regenerated; `.gitignore` +`.pwsh/`;
`docs/toolkit-status.md` now points here.

---

## 2026-08-21 -- B2B Guest Governance (committed 2026-08-23 in `a31f218`)

Implements `docs/plans/B2B-SETUP-PLAN.md` (TIER 2): ISC-side governance for
Entra B2B guests. The toolkit picks up after the manual Entra work (app
registration, CLD-B2B-* groups, source connection) and builds access profiles,
criteria roles, the domain-resolver transform, and certification campaigns on
top of an aggregated source. Original runbook:
`/work/docs/temp/sailpoint-b2b-automation-prompt.md`.

### New files

| File | Lines | Purpose |
|------|-------|---------|
| `Modules/SP.Api/SP.Sources.psm1` | 605 | Source/entitlement primitives: Get-SPSource(s), Get-SPEntitlements, Start-SPAccountAggregation, Start-SPEntitlementAggregation, Get-SPProvisioningPolicies |
| `Modules/SP.Api/SP.AccessGovernance.psm1` | 971 | Access profile, role, and transform CRUD: New/Get-SPAccessProfile(s), New/Get-SPRole(s), New/Set/Get-SPTransform(s) |
| `Scripts/Invoke-SPB2BSetup.ps1` | 1,312 | 8-step idempotent partner onboarding orchestrator |
| `Scripts/Invoke-SPB2BHealthCheck.ps1` | 993 | 11-check governance verification, HTML report + JSONL evidence |
| `Tests/SP.Sources.Tests.ps1` | 468 | SRC-001..008 |
| `Tests/SP.AccessGovernance.Tests.ps1` | 510 | AG-001..009 |
| `docs/designs/b2b-governance/01-b2b-group-naming-convention.puml` | 147 | Taxonomy / routing / app-mapping diagram (render pending on the Mac) |
| `docs/plans/B2B-SETUP-PLAN.md` | 554 | Plan with pre-implementation review log |

### Modified

- `Modules/SP.Api/SP.Api.psd1` -- registered both new nested modules, +13 exports (17 -> 30 commands)
- `Modules/SP.Core/SP.Config.psm1` + `Config/settings.json` -- `B2B` config section (GroupPrefix, CertifierIdentityId, DefaultCertDeadlineDays, DefaultLeadershipTitles, AutoCreateCampaign)
- `Tests/Import-TestModules.ps1` -- `-Api` now flat-imports the two new psm1 files (required for mock scoping)

### Key design decisions

1. **Certifier, never manager.** B2B guests arrive via cross-tenant sync and
   have no manager identity in the local tenant, so a manager-reviewed campaign
   would assign every item to nobody. Campaigns always carry an explicit
   certifier, resolved: `-CertifierIdentityId` / config -> the source's
   `owner.id` -> `-OwnerIdentityId` -> REFUSED (exit 4). This is a deliberate,
   documented deviation from the DeltaCert manager-review standard.
2. **No saved-search API.** `New-SPCampaign -Type SEARCH -SearchFilter` already
   supports inline queries (the DisconnectedApps path), so the planned
   `New-SPSavedSearch` function, endpoint, and scope were dropped.
3. **Transform is a split chain.** ISC lookup transforms are EXACT match, so
   the input is `email -> split("@", index 1) -> lower -> lookup`. Setup Step 2
   samples a guest and warns when the email attribute carries a `#EXT#` UPN
   (which would make every guest resolve to the home tenant domain).
4. **Health check reuses SP.Audit.** Checks 1-6 build on
   Get-SPSourceAggregationHealth and the entitlement/AP/role inventories
   instead of re-implementing pagination. Check 3 evaluates the source
   aggregation timeline (ISC exposes no entitlement-aggregation history);
   a check that cannot run reports Error and exits 2, never a clean pass.
5. **Idempotent by GET-first.** ISC returns 400 on duplicate names, so every
   create checks existence first; re-runs after partial failure are safe, and
   transform updates merge the existing lookup table (PUT is full-replacement).

### Bugs caught before commit

- `-WhatIf` on the setup script suppressed creation of its own audit directory,
  so dry runs left no JSONL record (fixed with `-WhatIf:$false` on local writes).
- The 403 permission hint printed for any API error, including 404s.
- The JSONL audit trail only flushed at the final summary, so early exits --
  including the certifier refusal that fires AFTER steps 3-6 have mutated the
  tenant -- lost the entire record. Extracted `Write-B2BAuditTrail`, called on
  every exit path.
- Health check wrote its HTML before creating the output directory.
- Paginators appended a null item when a page returned null Data
  (`@($null).Count` is 1 in PowerShell).

### Verification

- Implemented by an Opus agent against the reviewed plan; independently
  verified afterward: every file read in full, cross-module contracts checked
  against the real SP.Audit/SP.Shared/SP.Campaigns code, parser clean on all
  files, ASCII-only confirmed byte-wise.
- 157 Pester tests pass, 0 fail (PS 7.4.6 / Pester 5.7.1 in the work
  container): SP.Sources 24, SP.AccessGovernance 26, plus regression on
  SP.Config, SP.ApiClient, SP.Campaigns, SP.Certifications, SP.Decisions.
- End-to-end run against an ISC-shaped mock: creation, re-run idempotency,
  transform table merge across two partners, leadership-role skip, exit codes
  0/1/2/3, health check verdicts and `-Quiet`.
- Still owed on the Mac: a PS 5.1 Pester pass and the PlantUML render.
- Not verified against a live tenant: exact PAT scope strings (deliberately
  not hardcoded in messages), nested `name` fields in AP/entitlement
  references, `roleCount` on identity search documents.

---

## 2026-08-23 -- Playbook documentation pass (`b276fd3`, `a32dc84`, `a8c41a6`)

- V7c, V4f, and B2B sections added to `cli-playbook.md` and
  `07-reporting-analytics.md`
- Production runbook for the V4g/V8 pipeline + utility scripts
- Script Quick Reference master index covering all 66 scripts

## 2026-08-23 -- Bundled WIP committed with the B2B work (`a31f218`)

- `Invoke-SPDecisionScrape.ps1` +170: intra-report dupe detection, re-revoked
  grants, gap-fill
- `Invoke-SPPendingReviewerScrape.ps1` +25: chronic trend direction, trailing
  streak logic
- `Invoke-SPDailyEvidenceReportV4f.ps1` +54: campaign name filters (parity
  with V4b/V4g)
- `SP.StateOrchestrator.psm1` +26: incremental checkpointing for multi-hour runs
- `docs/STATUS.md` created

## 2026-08-05 -- Scraper + state hardening (`695dce6`..`6f3d90c`)

- Decision scraper, reviewer trend indicators, ISC date series fix, campaign
  name filter (V4b/V4g)
- ReApproved detection in SP.EntitlementState, decision charts, V4g/V8
  enhancements
- Relative output path bug fixed in both scrapers; handoff zips rebuilt

# B2B Governance Setup -- Implementation Plan

**Created:** 2026-08-20
**Reviewed:** 2026-08-21 (verified against codebase -- see Review Findings at bottom)
**Status:** IMPLEMENTED 2026-08-21 (all 4 phases; 157 tests pass on PS7; Pester run on PS5.1 and PlantUML render still pending on the Mac)
**Scope:** TIER 2 (~9 files, 2-3 agents)
**Trigger:** `#CODE TIER2` when ready to execute

---

## Goal

Extend the Governance Toolkit so users can configure their SailPoint ISC tenant
for B2B guest governance. Pure ISC API -- no Graph API / Entra operations. The user
manually creates Entra app registrations and B2B groups outside the toolkit (change
control). The toolkit picks up from "source exists, groups aggregated" and builds
the ISC governance layer on top.

## Context Document

`/docs/temp/sailpoint-b2b-automation-prompt.md` -- the original 10-task B2B
automation runbook. Tasks 1, 3, 8 are Entra-side (out of scope). Tasks 2, 4, 5,
6, 7, 9, 10 are ISC-side (in scope). Task 2 (source creation) is partially in
scope -- we verify the source exists and is healthy, but initial connector setup
is manual (certificate upload, connection test).

**NOTE (2026-08-21 review):** the path is relative to the WORKSPACE root, not
this repo: `/work/docs/temp/sailpoint-b2b-automation-prompt.md`. Verified
present and read in full; the plan's task mapping matches it.

## Design Decisions

1. **No SP.Entra module.** SailPoint's Entra connector owns the Graph API
   relationship. The toolkit configures ISC, not Entra. Entra app registrations
   are manual for change control compliance.

2. **No Graph API client.** No `Invoke-SPEntraRequest`, no Graph token management,
   no direct group creation or user add/remove. If entitlements aren't visible
   after aggregation, the orchestrator tells the user to create groups in Entra
   and aggregate -- it doesn't do it for them.

3. **Extend SP.Api, not new module.** The new ISC v3 endpoints (sources,
   access profiles, roles, transforms) are generic ISC capabilities, not
   B2B-specific. They go into SP.Api as new `.psm1` files alongside the existing
   Campaigns/Certifications/Decisions files.

4. **Orchestrator is a script, not a module.** `Invoke-SPB2BSetup.ps1` is a
   workflow script like `Invoke-SPDisconnectedAppCert.ps1`. The reusable parts
   are the SP.Api functions it calls.

5. **All write operations use ShouldProcess.** Every POST/PUT function supports
   `-WhatIf` so the orchestrator can do a full dry run.

---

## Phase 1: SP.Api Extensions (Foundation)

### File: Modules/SP.Api/SP.Sources.psm1

New file. ~6 functions covering ISC source and entitlement queries:

| Function | HTTP | Endpoint | Purpose |
|----------|------|----------|---------|
| `Get-SPSource` | GET | /v3/sources/{id} | Retrieve source by ID |
| `Get-SPSources` | GET | /v3/sources | List sources with name/type filters |
| `Get-SPEntitlements` | GET | /v3/entitlements | List entitlements with source + name prefix filters |
| `Start-SPAccountAggregation` | POST | /v3/sources/{id}/load-accounts | Trigger account aggregation (ShouldProcess) |
| `Start-SPEntitlementAggregation` | POST | /v3/sources/{id}/load-entitlements | Trigger entitlement aggregation (ShouldProcess) |
| `Get-SPProvisioningPolicies` | GET | /v3/sources/{id}/provisioning-policies | Verify provisioning policies exist |

All functions use `Invoke-SPApiRequest` from SP.ApiClient.psm1. Pagination follows
existing offset/limit pattern. Filters use ISC filter syntax (`eq`, `sw`, `co`, `in`).

### File: Modules/SP.Api/SP.AccessGovernance.psm1

New file. ~7 functions covering access profiles, roles, and transforms:

| Function | HTTP | Endpoint | Purpose |
|----------|------|----------|---------|
| `New-SPAccessProfile` | POST | /v3/access-profiles | Create access profile (ShouldProcess) |
| `Get-SPAccessProfiles` | GET | /v3/access-profiles | List access profiles with filters |
| `New-SPRole` | POST | /v3/roles | Create role with criteria hashtable (ShouldProcess) |
| `Get-SPRoles` | GET | /v3/roles | List roles with filters |
| `New-SPTransform` | POST | /v3/transforms | Deploy transform (ShouldProcess) |
| `Set-SPTransform` | PUT | /v3/transforms/{id} | Update transform (ShouldProcess) |
| `Get-SPTransforms` | GET | /v3/transforms | List transforms |

`New-SPRole` accepts a `-Criteria` parameter as a hashtable matching the ISC role
membership criteria schema (operation, key, value, children). The orchestrator
builds the criteria structure; the API function just ships it.

**Dropped from original plan:** `New-SPSavedSearch`. Verified 2026-08-21 that
`New-SPCampaign -Type SEARCH -SearchFilter <query>` (SP.Campaigns.psm1) already
builds a search campaign with an inline `filter.query.query` -- exactly how
`Invoke-SPDisconnectedAppCert.ps1` creates its per-manager campaigns. No saved
search object is needed for a campaign filter, which also removes the
`idn:saved-searches:manage` scope and the saved-search `indices` gotcha.

**Collision check (verified 2026-08-21):** none of the planned function names
exist anywhere in Modules/. Nearest neighbors are SP.Audit's cached inventory
functions (`Get-SPEntitlementInventory`, `Get-SPAccessProfileInventory`,
`Get-SPRoleInventory`, `Get-SPSourceAggregationHealth`) -- those are
report-oriented aggregators; the new SP.Api functions are thin primitives.
Keep both layers; do not duplicate the inventory logic.

### File: Modules/SP.Api/SP.Api.psd1 (Modified)

Add both new files to `NestedModules`. Add all new function names to
`FunctionsToExport`.

### File: Config/settings.json (Modified)

Add B2B defaults section:

```json
"B2B": {
    "GroupPrefix": "CLD-B2B",
    "CertifierIdentityId": "",
    "DefaultCertDeadlineDays": 30,
    "DefaultLeadershipTitles": ["Director", "VP", "Chief"],
    "AutoCreateCampaign": false
}
```

Reviewer semantics (corrected 2026-08-21, second pass): B2B guests arrive via
cross-tenant sync and have NO manager identity in the local tenant -- a
manager-reviewed campaign would assign every review to nobody. The runbook
(Task 7) is explicit: "for B2B, SOURCE_OWNER or IDENTITY_LIST is most
practical". `SOURCE_OWNER` is a campaign *type* (whole-source scope, not
B2B-filtered), so the Step 7 SEARCH campaign expresses owner review as an
EXPLICIT `certifiers` block. This deliberately deviates from the toolkit's
DeltaCert manager-review standard. Certifier resolution order:

1. `-CertifierIdentityId` parameter / config `B2B.CertifierIdentityId`
2. The Entra source's `owner.id` (already fetched in Step 1 -- this is the
   "SOURCE_OWNER reviews" semantics, scoped to B2B guests only)
3. `-OwnerIdentityId` (the AP/role owner)
4. No resolvable certifier -> REFUSE campaign creation (exit 4). Never fall
   back to manager review for B2B.

### File: Modules/SP.Core/SP.Config.psm1 (Modified)

Add B2B section defaults to `Get-SPConfigDefaults` (same pattern as the Audit
section addition -- prevents "Unknown configuration key" warnings in existing tests).

---

## Phase 2: Scripts

### File: Scripts/Invoke-SPB2BSetup.ps1

Main orchestrator. Walks user through ISC-side B2B governance setup for a partner.

**Parameters:**

```
-PartnerName        [string]    "PartnerA" (used in naming)
-PartnerDomain      [string]    "partnera.com" (used in role criteria)
-SourceId           [string]    ISC source ID for Entra connector
-SourceName         [string]    Alternative to SourceId -- lookup by name
-OwnerIdentityId    [string]    IAM admin identity ID (owner for APs/roles)
-Tier2Apps          [string[]]  Optional: app names for elevated groups (e.g., "SvcNow","SharePoint")
-LeadershipTitles   [string[]]  Optional: job title keywords for leadership role criteria
                                Default: @("Director","VP","Chief") from config
-IncludeTransform   [switch]    Deploy/update B2B Partner Group Resolver transform
-CreateCampaign     [switch]    Create certification campaign after setup
-CampaignDeadline   [datetime]  Campaign deadline (default: config B2B.DefaultCertDeadlineDays from today)
-Token              [string]    ISC bearer token (browser token auth)
-WhatIf             [switch]    Dry run -- show what would be created
```

**Step Sequence:**

```
Step 1: VERIFY SOURCE
  GET /v3/sources/{id}
  -> Fail if source doesn't exist
  -> Warn if connector type isn't azure-active-directory
  -> Log source name, connector, status

Step 2: VERIFY ENTITLEMENTS AGGREGATED
  GET /v3/entitlements?filters=source.id eq "{id}" and name sw "CLD-B2B-{Partner}"
  -> Gate: must find at least CLD-B2B-{Partner}-Users entitlement
  -> If missing: output message --
     "No CLD-B2B-{Partner}-* entitlements found. Ensure groups exist in Entra
      and run entitlement aggregation before retrying."
  -> Offer to trigger aggregation and retry (-TriggerAggregation switch)
  -> List all found entitlements for user confirmation

Step 3: CREATE ACCESS PROFILES
  For each CLD-B2B-{Partner}-* entitlement:
    -> Derive AP name: "B2B {Partner} - {GroupSuffix} Access"
    -> Check if AP already exists (idempotent -- skip if found)
    -> Baseline groups (*-Users): requestable=false
    -> Tier 2 groups (*-Admin, *-SvcNow-Admin, etc.): requestable=true
    -> POST /v3/access-profiles
    -> Log created AP ID

Step 4: CREATE ROLES WITH CRITERIA
  Baseline role ("B2B-{Partner}-User"):
    -> Criteria: userType=Guest AND email contains {domain}
    -> Links to baseline AP
    -> Check if role already exists (idempotent)
    -> POST /v3/roles

  Leadership role ("B2B-{Partner}-Leadership") -- only if Leadership entitlement found:
    -> Criteria: baseline AND (jobTitle contains "Director" OR "VP" OR "Chief")
    -> Links to leadership AP
    -> POST /v3/roles

  NOTE on criteria attribute names: The script outputs a warning that users must
  verify attribute names match their ISC identity profile mappings. The defaults
  (attribute.userType, attribute.email, attribute.jobTitle) are standard but not
  guaranteed. The script accepts -UserTypeAttribute, -EmailAttribute,
  -JobTitleAttribute overrides if the tenant uses different names.

Step 5: VERIFY PROVISIONING POLICIES
  GET /v3/sources/{id}/provisioning-policies
  -> Check for ADD_ENTITLEMENT and REMOVE_ENTITLEMENT policies
  -> Warn if missing: "Provisioning policies not found. The Entra connector may
     not be configured for provisioning. Enable provisioning on the source in
     ISC admin UI."
  -> This is a read-only check -- can't auto-fix

Step 6: DEPLOY TRANSFORM (optional, -IncludeTransform)
  GET /v3/transforms?filters=name eq "B2B Partner Group Resolver"
  -> If exists: PUT to update table with new partner domain
  -> If not: POST to create new transform
  -> Transform type: lookup, source: email identity attribute,
     table: {domain} -> CLD-B2B-{Partner}-Users,
     default: "CLD-B2B-Unknown-Review"

Step 7: CREATE CERTIFICATION CAMPAIGN (optional, -CreateCampaign)
  -> Build search query for B2B guests with CLD-B2B-{Partner}-* entitlements
  -> REUSE existing New-SPCampaign -Type SEARCH -SearchFilter <query>
     (inline filter.query.query -- same path Invoke-SPDisconnectedAppCert uses;
      no saved search object required)
  -> Certifier: ALWAYS explicit (B2B guests have no local manager).
     Resolution: -CertifierIdentityId / config -> source owner.id from Step 1
     -> -OwnerIdentityId -> REFUSE (exit 4). Never manager review.
  -> Deadline from -CampaignDeadline / config B2B.DefaultCertDeadlineDays
  -> If runbook extras are wanted (emailNotificationEnabled, autoRevokeAllowed,
     recommendationsEnabled), extend Build-SPCampaignBody with optional
     parameters rather than bypassing New-SPCampaign

Step 8: OUTPUT SUMMARY
  -> Table: what was created (APs, roles, transform, campaign) with ISC IDs
  -> Validation checklist (pass/warn/fail for each step)
  -> JSONL audit file: every API call with request/response
  -> Next steps: "Run identity refresh to trigger role evaluation"
```

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Setup completed successfully |
| 1 | Entitlements not found (groups not aggregated) |
| 2 | Parameter error |
| 3 | API error (auth failure, rate limit, etc.) |
| 4 | Configuration error |
| 5 | Partial completion (some steps succeeded, some failed -- see audit log) |

**Idempotency:** Every create step checks if the object already exists first.
Running the script twice for the same partner is safe -- it skips existing objects
and reports "already exists" rather than failing on duplicates.

### File: Scripts/Invoke-SPB2BHealthCheck.ps1

Ongoing governance verification. Run weekly or before cert campaigns.

**Parameters:**

```
-SourceId / -SourceName    [string]
-Token                     [string]
-OutputPath                [string]   Default: .\Reports\B2B-HealthCheck_{date}.html
-Quiet                     [switch]   Suppress console output, exit code only
```

**Checks performed:**

| # | Check | Severity |
|---|-------|----------|
| 1 | Source exists and connection status | FAIL if missing |
| 2 | Last account aggregation within 24h | WARN if stale |
| 3 | Last entitlement aggregation within 48h | WARN if stale |
| 4 | Every CLD-B2B-* entitlement has an Access Profile | FAIL per orphan |
| 5 | Every B2B Access Profile is linked to a Role | WARN per unlinked |
| 6 | All B2B roles have non-empty criteria | FAIL per empty |
| 7 | Role criteria reference valid identity attributes | WARN if unknown |
| 8 | Transform lookup covers all observed partner domains | WARN per gap |
| 9 | Provisioning policies exist (ADD/REMOVE_ENTITLEMENT) | FAIL if missing |
| 10 | B2B guests with zero role assignments | WARN with identity list |
| 11 | Group naming convention compliance (CLD-B2B-* pattern) | INFO |

**Reuse (verified 2026-08-21):** SP.Audit already implements the machinery for
checks 1-6. Import SP.Audit (in addition to SP.Core + SP.Api) and build on:

- `Get-SPSourceAggregationHealth -SourceIds @($id) -MaxAcceptableStalenessHours N`
  -- covers checks 1-3 (source status, aggregation staleness) including
  pagination ceilings and Healthy/Warning/Critical classification
- `Get-SPEntitlementInventory` / `Get-SPAccessProfileInventory` /
  `Get-SPRoleInventory` -- the data gathering for checks 4-6; the script adds
  only the B2B-specific cross-referencing (orphan entitlements, unlinked APs,
  empty criteria)

Do NOT re-implement raw pagination against /v3/sources or /v3/entitlements here;
the SP.Api primitives are for the setup orchestrator, the audit inventories are
for reporting.

**Output:** HTML report matching existing toolkit report styling (dark header,
status badges, tables). Plus JSONL evidence file.

**Exit codes:** 0 = all checks pass, 1 = warnings only, 2 = failures found.

---

## Phase 3: Tests

### File: Tests/SP.Sources.Tests.ps1

Pester tests for SP.Sources.psm1. Pattern: mock `Invoke-SPApiRequest`, verify
correct URL construction, filter syntax, pagination handling.

Test IDs: SRC-001 through SRC-0xx.

Expected tests:
- Get-SPSource returns source object
- Get-SPSources applies name filter correctly
- Get-SPEntitlements applies source + name prefix filters
- Start-SPAccountAggregation calls correct endpoint with ShouldProcess
- Start-SPEntitlementAggregation calls correct endpoint
- Get-SPProvisioningPolicies returns policy list

### File: Tests/SP.AccessGovernance.Tests.ps1

Pester tests for SP.AccessGovernance.psm1.

Test IDs: AG-001 through AG-0xx.

Expected tests:
- New-SPAccessProfile constructs correct POST body
- New-SPAccessProfile respects -WhatIf
- Get-SPAccessProfiles applies filters
- New-SPRole constructs criteria structure correctly
- New-SPRole with nested OR criteria (leadership titles)
- New-SPRole respects -WhatIf
- New-SPTransform / Set-SPTransform construct correct payloads
- Get-SPTransforms returns list

### Mock-scoping note

These tests will face the same PS7 mock-scoping issue as existing SP.Api tests
(mocking Invoke-SPApiRequest across module boundaries). Precedent:
`Tests/SP.DeltaCert.Tests.ps1` header note -- tests DC-001..DC-010 pass on both
PS 5.1 and PS7 because they mock only within their own module; cross-module
mocks need `-ModuleName` adjustments on PS7 + Pester 5. Follow that pattern
where possible. Target PS 5.1 for full pass; on PS7, expect failures from
mock-scoping, not production bugs.

---

## Phase 4: Diagram

### File: docs/designs/b2b-governance/01-b2b-group-naming-convention.puml

Path corrected 2026-08-21: `docs/designs/` has no top-level numbered series --
the existing convention is a per-topic subdirectory with its own numbering
(`docs/designs/disconnected-app-workflows/01-...` through `06-...`). Follow
that: new `b2b-governance/` subdirectory, numbering starts at 01.

PlantUML diagram showing:
- CLD-B2B-* naming convention taxonomy (3 tiers: Users, Leadership, App-Admin)
- Routing logic: SG-* prefix -> AD connector, CLD-* prefix -> Entra connector
- Group-to-enterprise-app mapping (which groups grant access to which apps)
- Color scheme per existing taxonomy:
  - Orange (#FF6600) for ISC
  - Green (#339933) for Entra/cloud
  - Gray (#999999) for AD/on-prem
  - Blue (#336699) for B2B groups
  - Purple (#663399) for app assignments

Generate with: `cd /Users/xand/Documents/Projects/PlantUML && python3 launcher.py /path/to/01-b2b-group-naming-convention.puml`

NOTE: the PlantUML launcher lives on the Mac, which is not reachable from the
work container. Author the .puml in this phase; rendering is a Mac-side step
(same deferral as the RSA diagrams).

---

## Dependency Chain (Updated)

```
SP.Shared (HtmlHelpers, CacheService, IdentityService) -- no dependencies
    |
    v
SP.Core (Config, Logging, Auth, Vault)
    |
    v
SP.Api (ApiClient, Campaigns, Certifications, Decisions,
        Sources [NEW], AccessGovernance [NEW])
    |
    +----------+----------+----------+----------+
    v          v          v          v          v
SP.Testing  SP.Audit   SP.DeltaCert  SP.Recon  SP.DisconnectedApps
    |
    v
SP.Gui

Scripts:
    Invoke-SPB2BSetup.ps1 [NEW]        (imports SP.Core + SP.Api)
    Invoke-SPB2BHealthCheck.ps1 [NEW]  (imports SP.Core + SP.Api + SP.Audit,
                                        reusing the audit inventory functions)
```

No new modules. No new dependencies. Just new files in SP.Api and new scripts.

---

## File Inventory Summary

| # | File | Action | Phase |
|---|------|--------|-------|
| 1 | Modules/SP.Api/SP.Sources.psm1 | NEW | 1 |
| 2 | Modules/SP.Api/SP.AccessGovernance.psm1 | NEW | 1 |
| 3 | Modules/SP.Api/SP.Api.psd1 | MODIFIED | 1 |
| 4 | Modules/SP.Core/SP.Config.psm1 | MODIFIED | 1 |
| 5 | Config/settings.json | MODIFIED | 1 |
| 6 | Scripts/Invoke-SPB2BSetup.ps1 | NEW | 2 |
| 7 | Scripts/Invoke-SPB2BHealthCheck.ps1 | NEW | 2 |
| 8 | Tests/SP.Sources.Tests.ps1 | NEW | 3 |
| 9 | Tests/SP.AccessGovernance.Tests.ps1 | NEW | 3 |
| 10 | docs/designs/b2b-governance/01-b2b-group-naming-convention.puml | NEW | 4 |

**10 files total: 6 new, 4 modified.**

---

## ISC API Quick Reference (B2B-Relevant Endpoints)

| Endpoint | Method | Scope Required (UNVERIFIED -- see note) |
|----------|--------|---------------|
| /v3/sources | GET | source read scope |
| /v3/sources/{id} | GET | source read scope |
| /v3/sources/{id}/load-accounts | POST | UNPROVEN -- likely a manage scope, NOT read |
| /v3/sources/{id}/load-entitlements | POST | UNPROVEN -- likely a manage scope, NOT read |
| /v3/sources/{id}/provisioning-policies | GET | source read scope |
| /v3/entitlements | GET | entitlement read scope |
| /v3/access-profiles | GET/POST | access-profile read / manage |
| /v3/roles | GET/POST | role read / manage |
| /v3/transforms | GET/POST/PUT | transform read / manage |
| /v3/campaigns | POST | idn:campaign:manage (verified -- already used by DisconnectedApps) |

**Scope-name caveat (2026-08-21 review):** exact scope strings are NOT
verified against a live tenant. The original plan wrote `idn:sources:read`,
but the existing codebase's own 403 guidance (SP.AuditQueries.psm1) says
`idn:source:read` (singular). The original claim that aggregation triggers
are "read-scoped" is implausible (they mutate tenant state) and is marked
UNPROVEN. Do not hardcode scope names in error messages without checking the
tenant's PAT scope picker; prefer wording like "your token lacks source
read/manage permission".

**New write capability needed beyond existing toolkit PAT (read-only):**
access-profile manage, role manage, transform manage, plus entitlement read.
B2B setup requires a separate PAT with manage scopes, or a browser token from
an admin session. The orchestrator should warn about this at startup and on
any 403, echoing the failed endpoint.

---

## Key Gotchas to Watch For

1. **Role criteria attribute names are tenant-specific.** The defaults
   (attribute.userType, attribute.email, attribute.jobTitle) are standard ISC
   identity attributes, but tenants can customize identity profile mappings.
   The orchestrator must accept attribute name overrides.

2. **Role criteria evaluation is async.** After creating roles, access isn't
   granted immediately. ISC evaluates criteria during identity refresh
   (aggregation cycle). The orchestrator should note this in its output.

3. **Access Profile source must match entitlement source.** An AP can only
   contain entitlements from its own source. The orchestrator validates this
   before attempting creation.

4. **The ISC lookup transform is EXACT-match, not substring.** (Corrected
   2026-08-21 -- the original plan guessed substring matching.) A table keyed
   `partnera.com` will never match the input `user@partnera.com`; unmatched
   input falls through to the `default` entry, silently routing every guest to
   CLD-B2B-Unknown-Review. The transform MUST be a chain that extracts the
   domain first: email -> `split` on "@" (index 1) -> `lower` -> `lookup`.
   Build it that way from the start; add a health check assertion that the
   transform's input stage is the split chain, not raw email.
   RELATED TRAP (from the runbook): if the tenant's `email` identity attribute
   maps to the guest UPN (`user_partnera.com#EXT#@corp.onmicrosoft.com`)
   instead of `mail`, split-on-@ yields `corp.onmicrosoft.com` for EVERY guest
   and the whole table misses. Step 2 of the orchestrator should sample one
   found guest and warn if the email attribute value contains `#EXT#`.

5. **Idempotency on name collision.** ISC returns 400 if you create an AP/role
   with a name that already exists. The orchestrator must GET first, skip if
   exists. This also handles re-runs after partial failures.

6. **Browser token scope.** Admin browser tokens (JWT from ISC console) have
   full admin permissions. They bypass PAT scope restrictions. This is the
   recommended auth method for initial setup (no need to create a manage-scoped
   PAT just for one-time setup).

7. **(Retired 2026-08-21)** The saved-search `indices` gotcha no longer applies:
   Step 7 now reuses `New-SPCampaign -Type SEARCH` with an inline query instead
   of creating a saved search. The query itself must still target the identity
   index semantics (`@access(...)` clauses over identities), which the existing
   DisconnectedApps campaigns already demonstrate.

---

## Review Findings (2026-08-21)

Plan verified against the live codebase before execution. Structural claims
that checked out: SP.Api layout (ApiClient/Campaigns/Certifications/Decisions
+ psd1 NestedModules/FunctionsToExport pattern), `Invoke-SPApiRequest`
signature and `@{Success; Data; StatusCode; Error}` return contract,
`Get-SPConfigDefaults` section pattern (Audit precedent), the
`Invoke-SPDisconnectedAppCert.ps1` orchestrator template (Token/-WhatIf/exit
codes/JSONL audit), and the PS7 mock-scoping caveat (documented in
SP.DeltaCert.Tests.ps1). No function-name collisions.

Changes made by this review:

1. Context runbook located at `/work/docs/temp/sailpoint-b2b-automation-prompt.md`
   (workspace root, not the toolkit repo) -- read in full; plan's task mapping
   and gotchas cross-checked against it.
2. Dropped `New-SPSavedSearch` and the /v3/saved-searches endpoint + scope.
   `New-SPCampaign -Type SEARCH -SearchFilter` already covers Step 7 with an
   inline query (SP.AccessGovernance is now ~7 functions).
3. Health check now imports SP.Audit and reuses
   `Get-SPSourceAggregationHealth` (checks 1-3) and the
   entitlement/access-profile/role inventory functions (data for checks 4-6)
   instead of re-implementing pagination.
4. Corrected gotcha #4: ISC lookup transforms are exact-match; the transform
   is specified as a split("@",1) -> lower -> lookup chain from the start.
5. Corrected reviewer config (two passes): `SOURCE_OWNER` is a campaign type,
   not a SEARCH reviewer option, so owner review is expressed as an explicit
   `certifiers` block. B2B guests have no local manager (cross-tenant sync),
   so manager review is REFUSED, not a fallback -- certifier resolves from
   config/param -> source owner -> AP/role owner -> hard fail. This is a
   deliberate, documented deviation from the DeltaCert manager-review standard.
6. Scope names marked UNVERIFIED (codebase itself uses `idn:source:read`
   singular in 403 guidance; "aggregation triggers are read-scoped" marked
   UNPROVEN -- assume manage scope or browser token).
7. Diagram moved to `docs/designs/b2b-governance/01-...puml` matching the
   per-topic subdirectory convention; rendering deferred to the Mac (PlantUML
   launcher unreachable from the container).

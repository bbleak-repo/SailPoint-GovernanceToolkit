# Delta Cert: Entitlement-Scoped Delta + FullCert Quarterly Mode — Round 01

## Overview

This round adds two capabilities to the AD Delta Certification workflow:

1. **Entitlement data pass-through** in `Get-SPDeltaGrantEvents` — grant event objects
   now carry `EntitlementId`, `EntitlementName`, and `AccessProfileId` fields extracted
   from the ISC account-activity provisioning item, available for audit/reporting.

2. **FullCert quarterly baseline mode** — a new `-FullCert` switch on
   `Invoke-SPADDeltaCert.ps1` (backed by `Invoke-SPDeltaCertFullRun` in the runner
   module) creates one MANAGER-type campaign per manager with staff on the monitored
   AD sources, covering all current entitlements (not just window-scoped grants).

---

## ISC API Ceiling (Entitlement Scoping)

**The ISC `/v3/campaigns` SEARCH type does not support an entitlement-level filter.**

The `filter.query.query` field is a Lucene identity query of the form:

```
id:"identity-id-1" OR id:"identity-id-2"
```

There is no `filter.type = 'ENTITLEMENT'` or combined identity+entitlement filter
parameter in the campaign creation body. This means:

- A SEARCH campaign scoped to N identities presents **ALL** of those identities'
  entitlements for review, not only the newly-granted AD group.
- The toolkit works around this by keeping the identity set as small as possible:
  only identities who received new access in the window are included.
- The specific `EntitlementId`/`EntitlementName` data is captured in grant events
  and written to the JSONL audit trail for post-hoc traceability.

---

## Changes

### `Modules/SP.DeltaCert/SP.DeltaCertQueries.psm1`

- **`Get-SPDeltaGrantEvents`**: Each `[PSCustomObject]` grant event now includes three
  additional fields:
  - `EntitlementId` — extracted from `item.entitlementId`, `item.entitlement_id`, or
    `item.entitlement.id` (whichever is present). Empty string if not available.
  - `EntitlementName` — set to `ItemName` (which already falls back to `ItemValue`),
    providing the best available display name for the granted item.
  - `AccessProfileId` — extracted from `item.accessProfileId` or
    `item.access_profile_id`. Empty string if not available.

- **`Get-SPDeltaManagersForSources`** (new exported function): Queries
  `/v3/search/identities` with a server-side filter that selects active identities
  with accounts on the specified source IDs and a manager assignment. Falls back to
  client-side filtering if the server-side filter is not supported by the tenant.
  Returns `@{ managerId = ManagerName }` for use by `Invoke-SPDeltaCertFullRun`.
  Applies the same exclusion filters as `Get-SPDeltaAffectedIdentities`.

### `Modules/SP.DeltaCert/SP.DeltaCertRunner.psm1`

- **`Write-SPDeltaCertAuditEvent`**: Added optional `-RunMode` parameter (default
  `'Delta'`). The audit JSONL event now includes a `RunMode` field (`'Delta'` or
  `'Full'`). Backward-compatible: existing JSONL consumers using `ConvertFrom-Json`
  ignore unknown keys.

- **`Test-SPDeltaCertBaselineExists`** (new internal-but-exported function): Checks
  whether `deltacert-audit.jsonl` exists at `DeltaCert.OutputPath`. Used by
  `Invoke-SPADDeltaCert.ps1` for first-run advisory without an ISC API call.

- **`Invoke-SPDeltaCertFullRun`** (new exported public function): Orchestrates the
  quarterly full-certification workflow:
  1. Calls `Get-SPDeltaManagersForSources` to find all managers with staff on the
     monitored sources.
  2. Applies duplicate-campaign guard (searches for existing campaigns matching
     `"{FullCertPrefix} {YYYY-MM-DD}"`).
  3. Applies safety guard (aborts if manager count exceeds `MaxCampaignsPerRun`).
  4. Creates one `MANAGER`-type campaign per manager via `New-SPCampaign`.
  5. Activates each campaign via `Start-SPCampaign`.
  6. Writes a `RunMode='Full'` audit event to the JSONL trail.
  Return envelope shape is identical to `Invoke-SPDeltaCertRun`.

### `Scripts/Invoke-SPADDeltaCert.ps1`

- **`-FullCert` switch** added to the param block.
- **Header output** updated to show `AD Full Certification (Quarterly Baseline Mode)`
  when `-FullCert` is set.
- **Config loading** extended to read `DeltaCert.FullCert.CampaignNamePrefix` and
  `DeltaCert.FullCert.DeadlineDays` from `settings.json`.
- **First-run advisory**: After config loads, calls `Test-SPDeltaCertBaselineExists`.
  If the audit file is absent AND `-FullCert` is not set, emits a `WARNING` message
  advising the operator to run with `-FullCert` first to establish a baseline.
- **Dispatch region** branches on `$FullCert`:
  - `$FullCert = $true` → `Invoke-SPDeltaCertFullRun`
  - `$FullCert = $false` → `Invoke-SPDeltaCertRun` (existing DELTA behavior, unchanged)
  - `-ReviewerMode` parameter is logged as ignored when `-FullCert` is set.
- **Summary object** gains `RunMode = 'Full'|'Delta'` field.
- **Output section** shows `Full Certification Complete` or `Delta Certification Complete`.
- **Exit code** `1` extended to cover `NoManagers` (FullCert equivalent of `NoChanges`).
- **`-help` .SYNOPSIS / .DESCRIPTION** updated to document both modes and ISC limitations.
- Version bumped to `1.1.0` in the Notes block.

### `Modules/SP.DeltaCert/SP.DeltaCert.psd1`

- `ModuleVersion` bumped from `1.0.0` to `1.1.0`.
- `FunctionsToExport` extended with:
  - `Get-SPDeltaManagersForSources`
  - `Invoke-SPDeltaCertFullRun`
  - `Test-SPDeltaCertBaselineExists`

### `Config/settings.json`

- Added `DeltaCert.FullCert` sub-object:
  ```json
  "FullCert": {
      "CampaignNamePrefix": "AD Full Cert",
      "DeadlineDays": 14,
      "MaxIdentitiesPerPage": 250
  }
  ```
  `CampaignNamePrefix` uses a separate value from `DeltaCert.CampaignNamePrefix`
  so same-day full and delta campaigns do not collide in the duplicate guard.
  `DeadlineDays` defaults to 14 (two weeks) for quarterly review cadence.
  `MaxIdentitiesPerPage` controls pagination in `Get-SPDeltaManagersForSources`.

---

## Design Decisions

1. **DELTA mode unchanged.** `Invoke-SPDeltaCertRun` and its SEARCH-per-manager-group
   behavior are not modified. The existing per-manager SEARCH campaign is already the
   correct DELTA behavior.

2. **FULL mode uses MANAGER campaign type.** ISC's MANAGER campaign automatically
   scopes to all direct reports of the certifier identity. No identity list or Lucene
   filter is needed, and there is no 250-identity Lucene filter length limit.

3. **Entitlement data is captured but not passed to the API.** The ISC API ceiling
   prevents entitlement-level filtering at campaign creation time. The data is
   available in the JSONL audit trail and in memory for downstream reporting.

4. **Separate name prefix for Full campaigns.** `'AD Full Cert'` vs `'AD Delta Cert'`
   prevents the duplicate guard from blocking a same-day full run when a delta run
   already ran (or vice versa).

5. **First-run detection uses the audit JSONL file.** No dedicated state file or ISC
   API call is needed. The check is advisory (a warning, not a hard stop).

6. **`Get-SPDeltaManagersForSources` falls back gracefully.** If the server-side
   `accounts.source.id in (...)` filter is not supported, the function retries without
   it and filters client-side from the identity `accounts` array.

---

## Known Limitations

1. **MANAGER campaign scope is not limited to monitored AD sources.** ISC's MANAGER
   campaign presents all direct reports and all their entitlements regardless of source.
   If a manager has reports on other sources, those will appear in the campaign.
   This is the correct full-cert semantic but operators should be aware.

2. **No entitlement-level filter at campaign creation.** The ISC `/v3/campaigns` API
   does not expose an entitlement filter for SEARCH campaigns. DELTA campaigns still
   show all entitlements for the affected identities (not just the newly-granted item).

3. **`MaxCampaignsPerRun` safety guard applies to Full mode.** Large orgs with many
   managers will need to raise `DeltaCert.MaxCampaignsPerRun` in `settings.json`
   before running `-FullCert`.

4. **FULL + DELTA same day creates two campaigns per manager.** The duplicate guard
   prevents two FULL or two DELTA campaigns on the same day but not one of each.
   This is expected and documented in the help text.

5. **`Test-SPDeltaCertBaselineExists` is advisory only.** It does not block DELTA runs.
   Operators may have valid reasons to start with DELTA mode without a full baseline.

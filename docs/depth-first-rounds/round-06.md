# Round 6
**Started:** 2026-05-31 12:01:52

**DF-06 complete.** `Test-SPSourceOnboardingReadiness` added to `SP.AuditQueries.psm1`.

**What it does:** Pre-flight checklist that validates 7 criteria for governance onboarding:

| Check | What it queries |
|-------|----------------|
| SourceExists | `GET /v3/sources/{id}` |
| OwnerAssigned | Source owner object |
| SchemaConfigured | `GET /v3/sources/{id}/schemas` -- looks for account + entitlement schemas |
| CorrelationRules | `accountCorrelationConfig` / `connectorAttributes` on source |
| AccountsAggregated | Source `accountCount` + `GET /v3/account-aggregations` history |
| EntitlementsAggregated | `GET /v3/entitlements?filters=source.id eq "{id}"` |
| CampaignReadiness | Composite -- fails if any of the above critical checks fail |

Returns `@{ Success; Data = @{ SourceId; SourceName; Checks; Summary = @{ TotalChecks; Passed; Failed; Warnings; ReadyForGovernance } }; Error }`.

Next PENDING: **DF-07** (Configuration Drift Report).

**Completed:** 2026-05-31 12:06:03
**Status:** SUCCESS

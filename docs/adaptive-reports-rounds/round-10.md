# Round 10
**Started:** 2026-06-05 17:56:00
**Item:** AR-10 — port SoD (B04) with an ISC entitlement-conflict rule-set

**Read:** B04's rule-set block (`$RuleSetName` / `$RoleAliases` / `$Conflicts`) and
detection engine. RoleAliases map a role name -> the ACTUAL group/entitlement name;
the engine flags identities holding BOTH entitlements of a Conflict pair.

**Did:** Copied B04 verbatim, then the one ADAPT: replaced the GE 'AD Lab SoD Rule
Set v1' (`GG_Scale_000x` AD-group values) with a **SailPoint ISC SoD Starter** —
kept the role-alias KEYS + the 9 classic toxic-pair Conflicts + risk tiers, swapped
the alias VALUES to readable ISC entitlement-name placeholders (AP Payments / AP
Payment Approval / ...), and added an EDIT-for-your-tenant header (the rule-set is
declarative data, not logic). Engine untouched. Added to loader + manifest
(`Export-SodToxicComembershipReport`).

**Files:** `BaselineReports/B04-sod-toxic-comembership.ps1` (verbatim + rule-set
swap); `SP.BaselineReports.psm1`, `SP.AdaptiveReports.psd1` (updated).

**Verification:** B04 AST parse OK; renders the full SoD register (17.9 KB) from
adapter GroupResults. Manifest OK. Formal Pester: AR-11.

**Review:** PASS (self — engine verbatim; rule-set is the documented ADAPT, clearly
editable; renders).
**Backlog update:** AR-10 → DONE.

**Completed:** 2026-06-05 18:02:00
**Status:** SUCCESS

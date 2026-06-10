# Cross-Project Contract — AD ↔ ISC ↔ HR Reconciliation

> **Audience:** the SailPoint Governance Toolkit (`C:\temp\Coding\SailPoint\SailPoint-GovernanceToolkit`,
> the ISC-facing project) and the Group Enumerator (the AD-facing project). This is the **interface both
> sides coordinate to.** A future merge script joins the AD export (here) with an ISC export and an HR
> (SuccessFactors) export to produce a unified compliance report with findings, gaps, and audit findings.
> **What is lost vs. what must be achieved is the point of this doc** — keep it current as either side changes.

## The model
Three sources, one authority:
- **SuccessFactors (HR)** = authoritative ("should be"). Provisions both AD and ISC.
- **Active Directory** = source A (Group Enumerator reads it).
- **SailPoint ISC** = source B (governs/attests access; SailPoint toolkit reads it).
Goal: **prove AD and ISC agree with each other and with HR; surface drift.** Audit-but-confirm; no blame.

## The JOIN KEY (both sides MUST honor)
- **Primary: `employeeID`** — the SuccessFactors authoritative key. Guaranteed in ISC
  (`identity.employeeNumber`/`identificationNumber` ← SF `personIdExternal`). In AD it lives in a
  **configurable attribute** (`JoinKeyAttribute`, default `employeeID`; may be `employeeNumber` or a
  custom `extensionAttribute`). **A privileged account with no `employeeID` is a finding (`JOINKEY_MISSING`)** —
  an IAM-maturity gap the AD side is enforcing remediation for.
- **Secondary: `mail`** (email). Then `userPrincipalName`, then `Domain\sAMAccountName`.
- The merge joins on `employeeID` when present on both sides; falls back down the ladder; any identity
  whose only match is mail/sam-fuzzy is flagged **`JoinConfidence=Low` (itself a finding)**.
- **Match-rate per source-pair is a reported KPI** (AD↔HR, ISC↔HR, AD↔ISC). A low match-rate is a
  completeness finding AND invalidates any agreement %.

## What the AD side PRODUCES (the export the SailPoint toolkit consumes)
`Export-AdReconciliationModel` → versioned JSON (UTF-8 **no-BOM**) + CSV twin, `schemaVersion 1.0.0`.
Three collections keyed on identity (mirrors ISC Identity/Account/Entitlement):
- `identities[]`: `dnKey, objectGuid, sam, domain, ou, displayName, joinKeys{employeeId,mail,upn,samDomain},
  joinKeyResolved{value,source,confidence}, enabled, privileged, manager{dnKey,employeeId,resolved},
  chain{toTop[],depth,state,breakReason,breakDepth,skipLevelViable,reachesOrgTop}, accessGrants[],
  recon{adManagerEmployeeId, iscReviewerEmployeeId:null, iscActive:null, hrActive:null, findings[]}`
- `managerEdges[]`, `accessGrants[]`, `generated{}` (provenance), `summary{}` (pre-aggregated).
The `recon` block has **AD filled, ISC/HR null** — the SailPoint toolkit fills the ISC side.

## What the SailPoint toolkit must PROVIDE (the ISC export, keyed the same way)
For the merge to be a join, the ISC export should carry per identity (keyed by `employeeID`):
- `employeeId`, `iscIdentityId`, `active` (lifecycle state), `manager`/`reviewer` `employeeId`
  (who certs route to), and **governed entitlements** (access profiles/roles/entitlements) with enough
  to match AD groups (name/source) so `ACCESS_NOT_GOVERNED` can be computed.
- Provenance: `sourceSystem=SailPointISC`, `snapshotAsOfUtc`, `extractMethod`, `toolVersion`,
  `recordCount`, `contentHash`.

## Drift findings the merge produces (shared taxonomy — stable codes)
`CHAIN_BROKEN`, `PRIV_UNREVIEWABLE`, `MGR_DISABLED_IN_CHAIN`, `JOINKEY_MISSING`, `MAIL_NE_UPN`,
`AD_NOT_IN_HR` (AD side now); `MGR_MISMATCH` (AD manager ≠ ISC reviewer → cert routes to wrong/absent
approver), `STATUS_MISMATCH` (AD enabled ≠ ISC active), `ACCESS_NOT_GOVERNED` (priv AD grant not in ISC
= shadow access), `ORGCHART_DIVERGENCE`, `STATUS_TERMINATED` (active in AD/ISC, terminated in HR),
`HR_NOT_PROVISIONED`, `AS_OF_SKEW` (merge-time). **The HR anchor decides** orphan vs coverage-gap.
Each maps to SOX ITGC (access review/certification routing, least privilege, deprovisioning,
reviewer independence, orphan ownership). Findings are worded as **process/control gaps, not blame.**

## Evidence requirements (for the merged report to be audit-defensible)
Per-source provenance (system, **authority** — HR is authoritative; **snapshotAsOfUtc ≠ extractedAt**;
method; version; configHash; contentHash SHA-256). **Reproducibility triple** per merged finding (3
contentHashes + 3 as-of stamps). **As-of skew tolerance** (a "AD-active & HR-terminated" finding is only
credible if AD's snapshot is at/after HR's termination date). **Attestation matrix**: per-source
data-owner sign-offs + one reconciliation-owner. Finding counts always shown against matched denominators.

## Coordination notes
- Keep the **shared finding-code vocabulary** and the **join-key ladder** identical on both sides.
- `schemaVersion` is semver; the merge pins the major. Breaking changes require a coordinated bump.
- The AD export is a **complete, self-describing operand** (it pre-stages every `pending*` finding's
  AD side) — the merge fills the ISC/HR side and never re-reads AD.
- Full AD-side spec: `EntraIDScripts/Group-Enumerator/docs/planning/ARCHITECTURE-AD-ISC-Reconciliation.md`.

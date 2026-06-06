# Round 14
**Started:** <YYYY-MM-DD HH:MM:SS>
**Item:** SDK-14 -- Mock parity audit (cert-summary fixtures esp.)

**Read:**
- `docs/phase7-sdk-gui-backlog.md` (SDK-14 row L43 + section L288-300; Accept =
  "documented coverage list; gaps either filled or flagged for SDK-18")
- `docs/phase7-sdk-gui-rounds/round-00-PROTOCOL.md` (loop contract + round template;
  "Headless verification toolbox" -- live-mock probe / JSON parse, no live WPF)
- `docs/planning/PHASE7_GUI_SDK_TAB.md` (bridge mapping table; SCOPE DECISION
  callout for SDK-18; "GUI Testing Methods")
- `Modules/SP.Gui/SP.SdkBridge.psm1` (the read bridges: `Get-SPGuiSdkCertSummaries`
  L567, `Get-SPGuiSdkDecisionSummary` L636, `Get-SPGuiSdkCertCampaigns` L692, plus
  the 5 non-cert reads at L125/L200/L287/L371/L433/L499)
- (mock repo, SEPARATE git repo `C:/temp/Coding/API-MockServer`)
  `Profiles/SailPoint-ISC/Register-SailPointRoutes.ps1`,
  `Profiles/SailPoint-ISC/Handlers/SdkHandlers.ps1`,
  `Profiles/SailPoint-ISC/seed-data.json`

**Did:**
SDK-14 is a MOCK-PARITY AUDIT, sized M, note-first (backlog Files = "note-only
otherwise"). I audited every endpoint the SP.SdkBridge read functions reach (via
their SP.Sdk backings) against the `SailPoint-ISC` mock profile -- route
registration, handler presence, and seed coverage. Result: every bridge read is
COVERED except one parity hole in the cert-summary `access-summaries`
sub-resource. Per the loop protocol I escalated the only code-producing action
(filling that hole in the mock seed) to the outer loop because it is GATED by the
SDK-18 ship-vs-defer scope decision, which the protocol reserves for the human /
outer loop. SDK-18 is still `TODO` (undecided), so this round is
DOCUMENTATION-ONLY: the gap is flagged as an SDK-18 sub-task with NO mock edit and
NO toolkit-branch code change beyond this round file + the backlog status flip.
No `seed-data.json` edit, no parity Pester (the parity test is a backlog
nice-to-have, not required by Accept).

**Coverage table (the Accept's "documented coverage list"):**

| Bridge read | SP.Sdk backing | Mock endpoint | Route (Register-SailPointRoutes.ps1 line) | Seed key | Status |
|---|---|---|---|---|---|
| `Get-SPGuiSdkCampaignTemplates` | `Get-SPSdkCampaignTemplates` | `GET /v3/campaign-templates` (+ `/:id/schedule`) | L88 (L93 schedule) | `campaignTemplates` (3) | COVERED |
| `Get-SPGuiSdkApprovals` | `Get-SPSdkPendingApprovals` / `Get-SPSdkCompletedApprovals` | `GET /v3/access-request-approvals/{pending\|completed}` | L117 / L118 | `pendingApprovals` (4) / `completedApprovals` (3) | COVERED |
| `Get-SPGuiSdkWorkItems` | `Get-SPSdkWorkItems` | `GET /v3/work-items` (+ `/summary`) | L127 (L128 summary) | `workItems` (6) | COVERED |
| `Get-SPGuiSdkWorkflows` | `Get-SPSdkWorkflows` | `GET /v3/workflows` | L142 | `workflows` (4) | COVERED |
| `Get-SPGuiSdkWorkflowExecutions` | `Get-SPSdkWorkflowExecutions` | `GET /v3/workflows/:id/executions` | L151 | `workflowExecutions` (5) | COVERED |
| `Get-SPGuiSdkCampaignFilters` | `Get-SPSdkCampaignFilters` | `GET /v3/campaign-filters` | L100 | `campaignFilters` (3) | COVERED |
| `Get-SPGuiSdkCertCampaigns` | `Get-SPGuiAuditCampaigns` (SP.GuiBridge -- NOT SP.Sdk) | `GET /v3/campaigns` | L33 | `campaigns` (4) | COVERED (via different endpoint) |
| `Get-SPGuiSdkCertSummaries -SummaryType Identity` | `Get-SPSdkIdentitySummaries` | `GET /v3/certifications/:id/identity-summaries` | L109 | derived from `accessReviewItems` | COVERED |
| `Get-SPGuiSdkCertSummaries -SummaryType Access` (ENTITLEMENT) | `Get-SPSdkAccessSummaries` | `GET /v3/certifications/:id/access-summaries/ENTITLEMENT` | L111 | derived from `accessReviewItems` (81 ENTITLEMENT ARIs) | COVERED |
| `Get-SPGuiSdkCertSummaries -SummaryType Access` (ROLE / ACCESS_PROFILE) | `Get-SPSdkAccessSummaries` | `GET /v3/certifications/:id/access-summaries/{ROLE\|ACCESS_PROFILE}` | L111 | derived from `accessReviewItems` | **GAP** -- 0 fixtures (all 81 ARIs are `access.type=ENTITLEMENT`) -> returns `[]` |
| `Get-SPGuiSdkDecisionSummary` | `Get-SPSdkDecisionSummary` | `GET /v3/certifications/:id/decision-summary` | L112 | derived from `accessReviewItems` (decisions: APPROVE 24 / REVOKE 6 / none 51) | COVERED |

Routes are registered and handlers exist for ALL of the above. The three
cert-summary handlers DERIVE their output dynamically from the seed
`accessReviewItems` collection (`SdkHandlers.ps1` L814 comment "No separate seed
data required"; `GetIdentitySummariesHandler` L816, `GetAccessSummariesHandler`
L1087, `GetDecisionSummaryHandler` L1239) -- there is no dedicated cert-summary
seed block to populate.

**The single parity gap (FLAGGED for SDK-18 -- no code change this round):**
1. **`access-summaries` ROLE / ACCESS_PROFILE hole.** All 81 seed ARIs across the
   18 certifications have `access.type = ENTITLEMENT`. So
   `GET /v3/certifications/:id/access-summaries/ROLE` and `/ACCESS_PROFILE` return
   an empty array. The bridge `-SummaryType Access` defaults `-AccessType` to
   `ENTITLEMENT` (so the default path works), but the `CboSdkAccessType` combo's
   ROLE / ACCESS_PROFILE values have ZERO fixtures.
2. **Secondary: no `access.id`.** 0 / 81 seed `access` objects carry an `id`. The
   `GetAccessSummariesHandler` falls back to grouping by `name` (functions
   correctly), but the bridge row `Id` column is blank for access summaries.

**SDK-18 sub-task (owned by SDK-18, do NOT action under SDK-14):**
> Only if SDK-18 SHIPS the Cert Summaries sub-tab: in the MOCK repo
> (`C:/temp/Coding/API-MockServer`, NOT the toolkit branch) append to
> `accessReviewItems['cert-active-001']` >= 1 ARI with
> `access = @{ type='ROLE'; id='role-xxxx'; name='...' }` and >= 1 with
> `access = @{ type='ACCESS_PROFILE'; id='ap-xxxx'; name='...' }`, each with a
> `decision` so `completedItems > 0`; then probe
> `GET /v3/certifications/cert-active-001/access-summaries/{ROLE,ACCESS_PROFILE}`
> for non-empty arrays. If SDK-18 DEFERS, this gap is irrelevant (the UI never
> exercises non-ENTITLEMENT) -> leave as-is.

**Files:**
- CREATED `docs/phase7-sdk-gui-rounds/round-14.md` (this file)
- MODIFIED `docs/phase7-sdk-gui-backlog.md` (SDK-14 row + section -> DONE)
- (no mock-repo edit; no parity Pester added -- documentation-only round)

**Verification:**
  - Pester: P=38 F=0 Total=38 (`Tests/SP.SdkBridge.Tests.ps1` -- the nearest
    affected suite; SDK-14 adds no toolkit code so this is a no-regression check)
  - JSON parse: `Profiles/SailPoint-ISC/seed-data.json` parses cleanly via
    `ConvertFrom-Json` (and Python `json.load`); audit confirmed 18 cert keys,
    81 ARIs, `access.type` breakdown `{ENTITLEMENT: 81}`, `access.id` present
    on 0/81, decisions `{APPROVE: 24, REVOKE: 6, null: 51}`
  - Route/handler presence: all 11 endpoints in the table confirmed registered in
    `Register-SailPointRoutes.ps1` and backed by an existing handler
  - XAML parse: n/a (SDK-14 touches no XAML)
  - Manifest/import: n/a (SDK-14 touches no module)

**Plan-vs-code disagreements noted:**
- Plan L305 says `Get-SPGuiSdkCertCampaigns` uses `SP.Api/SP.Certifications`. That
  module/function DOES NOT EXIST (confirmed in code + SDK-01 round notes); the
  bridge actually backs onto `Get-SPGuiAuditCampaigns` (SP.GuiBridge), covered by
  the mock `GET /v3/campaigns` (L33, 4 campaigns seeded). Noted so SDK-18 does not
  hunt for a phantom SP.Sdk campaign-list endpoint.
- Plan test-note L516 ("Mock `Invoke-SPApiRequest` at the module level") is wrong
  for the bridge layer -- the bridges call SP.Sdk wrappers, not
  `Invoke-SPApiRequest`. Already corrected in `SP.SdkBridge.Tests.ps1` header
  (L15-23). Any future parity test must hit the LIVE mock, not mock the API.

**WPF/testing convention applicability:** WPF Framework Notes 1-6 (module-scope
handler `& $module {} + .GetNewClosure()`, background STA runspace for API/bridge
calls, `Show-SPGuiDialog` reuse, Btn*/Chk* ToolTips, DPI-fit) are N/A to SDK-14 --
it touches no XAML and no UI-thread code. Verification used the protocol's
"Headless verification toolbox" (JSON parse of seed + route/handler inspection)
only; no live WPF window (that is SDK-19 / W-08b, the deferral boundary).

**Scope decision (escalated to outer loop):** SDK-14's only code-producing action
(filling the `access-summaries` ROLE/ACCESS_PROFILE seed gap) is GATED by the
SDK-18 ship-vs-defer call, which the protocol reserves for the human/outer loop.
Recommended default applied this round: documentation-only -- coverage table +
gap flagged as an SDK-18 sub-task; seed edit DEFERRED to SDK-18. All mock edits
(when SDK-18 decides) target the SEPARATE repo `C:/temp/Coding/API-MockServer` and
are NOT commits on `feature/phase7-sdk-gui-tab`.

**Review:** <PASS | FAIL: findings>
**Backlog update:** SDK-14 -> DONE

**Completed:** <YYYY-MM-DD HH:MM:SS>
**Status:** SUCCESS

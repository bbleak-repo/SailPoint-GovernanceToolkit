# Cache Honesty & Completion-Tracking Hardening — `#Loop` Plan

**Branch:** `feature/cache-honesty-hardening`
**Execution:** `#Loop`, all-opus (planner/middle/inner/reviewer/hunter/scribe = opus), additive-only.
**Verify:** `Invoke-Pester .\Tests` (scoped per round; full suite pre-finalize).
**Mock:** `C:\temp\Coding\API-MockServer` (SailPoint-ISC profile).
**Journals:** OUTSIDE the repo (`..\_loop-journals\cache-honesty-<stamp>`); never committed.

---

## 1. Goal (one sentence)

Make certification-campaign completion tracking **reliable in both ACTIVE and COMPLETED states** — correctly reporting *which assigned reviewer did or did not complete their review* — and **prove it end-to-end against the mock API** with ACTIVE, COMPLETED, and ACTIVE→COMPLETED-transition fixtures.

## 2. Why this is needed — confirmed root cause

COMPLETED campaigns mis-report **even when a correct ACTIVE-state item cache exists**:

- `Group-SPAuditDecisions` sets an item's `ReviewerName` **only** from `$rawItem.reviewedBy.name`
  (`Modules/SP.Audit/SP.AuditReportCore.psm1:179-181`). `reviewedBy` is *who reviewed the item*.
- A **pending/undecided item has no `reviewedBy`** → `ReviewerName = 'N/A'`.
- The COMPLETED branch groups pending items **by `ReviewerName`**
  (`Scripts/Invoke-SPDailyEvidenceReportV4.ps1:1918-1925`); blank → `(Unassigned)`.
- **Result:** every undecided item collapses into a single `(Unassigned)` row — the report
  cannot attribute undone work to the **assigned** reviewer.

The ACTIVE path works because it uses the **cert-level** assigned reviewer
(`$cert.reviewer.name`, `SP.AuditReportCore.psm1:472`) via `Group-SPReviewerActions`.
Accountability data lives at the **certification** level; the COMPLETED path discards it.

**Core fix:** attribute each undecided item to its certification's *assigned* reviewer
(`item.CertificationId → cert.reviewer`), and **seal the cert→reviewer roster at ACTIVE state**
(today only *items* are cached; certs are re-fetched live, where ISC force-sign / reassignment
distort `Phase`, `decisionsMade`, and possibly the effective reviewer).

## 3. Surrounding gaps (from the ultrathink review) — fold into the backlog

| ID | Severity | Gap |
|----|----------|-----|
| G1 | CRITICAL | First-seen-**after**-COMPLETED seals ISC post-completion "lies" as permanent truth; no cache-meta flag distinguishes "honest ACTIVE seal" vs "post-completion seal" (`SP.AuditQueries.psm1:6933-6954`, miss-path `:7117-7128`). |
| **R0** | **CRITICAL** | **COMPLETED reviewer attribution uses `reviewedBy` not cert-assigned reviewer (section 2). This is the "doesn't work even with active cache" bug.** |
| G2 | HIGH | Reassigned-away exclusion matches `ReassignedFrom` names against the item's *current* `ReviewerName` — likely inverted (`Invoke-SPDailyEvidenceReportV4.ps1:1904-1921`). Verify with a fixture. |
| G3 | HIGH | Reviewer identity keyed on **display name** everywhere, not identity ID (name collisions merge people; renames split them). |
| G4 | HIGH | Two contradictory completion definitions — `Measure-SPCampaignMetrics` (`SP.AuditReportCore.psm1:2130-2152`) recomputes from live ISC fields (no `idNowAutoApproved`, lumps REVOKE/DENY into pending), disagreeing with the honest `Group-SPAuditDecisions`. |
| G5 | MEDIUM | Sealed snapshot is the *last* ACTIVE capture (TTL default 180m); work done between final capture and close shows as falsely pending. No forced final capture. Doc says "30 min", code says 180. |
| G6 | MEDIUM | Store asymmetry: `governance-metrics.jsonl` and `SP.CampaignTrend` are append-only, no dedup, no ACTIVE-protection; trend's per-reviewer array is written but never read. |
| G7 | MEDIUM | `captureDate = campaign created date` (constant per campaign) → V7 "day-over-day" is campaign-to-campaign; same-created-day campaigns collide and one is dropped. |
| G8 | MEDIUM | Stalled-reviewer bugs (`SP.ReviewerAccountability.psm1`): window `Select -Last` is a no-op (`:207`); finished-but-unsigned flagged stalled; double `Sort-Object` clobbers primary key (`:264`). |
| G9 | LOW | `idNowAutoApproved` is a brittle vendor string match. |
| G10 | LOW | Item-cache file append (`SP.AuditQueries.psm1:7093`) is not mutex-guarded; GUI + scheduler concurrent fetch can interleave. |
| G11 | LOW | COMPLETED fetch returning 0 items never writes meta → re-fetches every run. |
| G12 | LOW | V4 COMPLETED path assumes `$audit['Decisions']['Pending']` exists; malformed audit throws. |

## 4. Backlog (work items, in dependency order)

> Critical path = **WI-0 → WI-1 → WI-2 → WI-3 → WI-4 → WI-11**. The rest is hardening,
> sequenced after the critical path proves out.

### WI-0 — Mock-data foundation (ACTIVE + COMPLETED + transition)
Build SailPoint-ISC mock seed data (in `C:\temp\Coding\API-MockServer`, additive to existing
`SailPointData` state / seed-data) covering, each with a documented **expected-truth table**:
- `camp-active-001` — **ACTIVE**: ≥3 certs, each a *distinct assigned reviewer*; per cert a mix of
  decided (with `reviewedBy`) and undecided (no `reviewedBy`) items.
- `camp-completed-001` — **COMPLETED / force-signed**: all certs `phase=SIGNED`, inflated
  `decisionsMade`, but underlying items include genuine undecided + `idNowAutoApproved` approvals.
- `camp-transition-001` — same campaign payload served **ACTIVE first**, flippable to COMPLETED
  (to exercise seal-on-transition end to end).
- Reassignment fixtures: a cert reassigned A→B with undecided items, to settle G2.
- **Acceptance:** mock serves `/v3/certifications`, `/v3/certifications/:id/access-review-items`
  for each; a documented JSON "truth" file states who *should* show complete/incomplete per campaign.

### WI-1 — Reproduction harness (red test)
Pester test(s) that drive the daily-evidence pipeline against the mock and **assert the COMPLETED
who-didn't-complete list attributes undecided items to the correct *assigned* reviewers** — must be
**RED** against current code (proving R0). Include the transition path (cache ACTIVE → flip → report).
- **Acceptance:** failing test reproduces `(Unassigned)` collapse; checked in.

### WI-2 — Seal the cert/reviewer roster at ACTIVE
Extend the item cache (or add a sibling) so the **certification roster (cert→assigned reviewer,
incl. reassignment-from)** is captured and **sealed at ACTIVE state** alongside items, and the
COMPLETED path reads the *sealed* roster, not live certs.
- **Acceptance:** for a sealed campaign, the cert→reviewer map used by the report is the ACTIVE-state
  one; covered by a unit test. Additive — live-cert fetch remains the fallback when no seal exists.

### WI-3 — Fix COMPLETED reviewer attribution (R0)
Attribute undecided items to the **cert-assigned reviewer** (`item.CertificationId → sealed roster`),
not `reviewedBy`. Keep `reviewedBy` for *decided* items. `(Unassigned)` only when a cert genuinely
has no assigned reviewer.
- **Acceptance:** WI-1 test goes **GREEN**; ACTIVE path unchanged; full suite still green.

### WI-4 — First-seen-after-COMPLETED provenance (G1)
On the cache-miss path, stamp meta with `CapturedWhileActive` / `FirstSeenStatus`; when a COMPLETED
campaign is sealed **without** a prior ACTIVE capture, mark the record `Unverified` and have the
report render "⚠ no active-state capture — completion unverified" instead of silently trusting it.
- **Acceptance:** unit test for both paths; report visibly distinguishes verified vs unverified.

### WI-5 — Reviewer identity by ID (G3)
Key reviewer accountability on ISC **identity ID** (name as display only), including the reassignment
match. Scope to the completion-tracking paths; additive shim where other code still keys on name.

### WI-6 — Reconcile completion definitions (G4)
Make `Measure-SPCampaignMetrics` use the honest classifier (or quarantine it explicitly as
"raw ISC — not for evidence"). One completion number of record.

### WI-7 — Reassignment exclusion direction (G2)
Using the WI-0 reassignment fixture, confirm the from/to direction and fix if inverted.

### WI-8 — Last-capture staleness / forced final capture (G5)
Add an opt-in "final capture near deadline" (or shrink ACTIVE TTL as due date approaches); fix the
30-vs-180 doc/behavior mismatch.

### WI-9 — Store dedup + ACTIVE-protection (G6)
Port the daily-evidence dedup + ACTIVE-record protection to `governance-metrics.jsonl` and
`SP.CampaignTrend`; expose the trend per-reviewer array via a read path (or stop writing it).

### WI-10 — Stalled-reviewer fixes (G8)
Fix the no-op window (`SP.ReviewerAccountability.psm1:207`), the finished-but-unsigned false
positive, and the double-`Sort-Object` that clobbers the primary key (`:264`).

### WI-12 — Time-axis semantics decision (G7)
`captureDate = campaign created date` makes V7 "day-over-day" a campaign-to-campaign axis and
collides same-created-day campaigns (one is dropped). **Decision required:** keep created-date keying
(correct for *recurring daily* campaigns) vs add a composite/run-date key (needed for true per-day
progression of a single long-running campaign). Implement the chosen option additively (e.g. an
opt-in `-PerRunDay` key) and document the trade-off; do not silently change existing report meaning.

### WI-13 — Low-severity robustness cluster (G9-G12)
- **G9** — make `idNowAutoApproved` detection resilient (config-driven marker list / case-insensitive),
  so an ISC rename doesn't silently re-inflate completion.
- **G10** — mutex-guard the item-cache append (`SP.AuditQueries.psm1:7093`) like the log writer, so a
  GUI + scheduler concurrent fetch can't interleave/corrupt the JSONL.
- **G11** — a COMPLETED fetch returning 0 items should still write meta (sealed-empty) so it isn't
  re-fetched every run.
- **G12** — null-safe the V4 COMPLETED path (`$audit['Decisions']['Pending']`) so a malformed/missing
  audit degrades gracefully instead of throwing.

### WI-11 — End-to-end evidence run (proof)
A scripted run against the mock that produces the daily-evidence report for `camp-active-001` and
`camp-completed-001` and asserts the rendered "who completed / who didn't" matches the WI-0 truth
tables. This is the demonstration that "everything actually works."

### WI-T — Triage the 2 pre-existing Pester failures
`DIST-06` (settings.json template integrity) and `DE-02` (sparkline weekly buckets) fail on current
`master` (unrelated to this work). Triage: fix if cheap, else document as pre-existing. (The 16 DV6
failures are environment-only — they shell out to `pwsh`/PS7, absent here; document, do not chase.)

## 5. Constraints & guardrails

- **Additive-only.** Do not remove/rewire working ACTIVE-path behavior; new behavior is opt-in or
  strictly corrective.
- **PowerShell 5.1** throughout (no 3-arg `Join-Path`, `OrderedDictionary.Contains`, ASCII `.psd1`).
- **Return envelope** `@{Success;Data;Error}`; `Write-SPLog`.
- **Mock work is additive** to the API-MockServer; start it non-elevated with `-Fresh`.
- **Human-run gates:** interactive W-08b / W-09b FlaUI phases are NOT run autonomously.
- **No push.** Loop writes `PUSH-NOTES.md`; the human pushes.

## 6. Definition of done

1. WI-1 repro test RED → GREEN after WI-2/WI-3.
2. WI-11 end-to-end: COMPLETED report attributes undecided items to the correct **assigned**
   reviewers (no `(Unassigned)` collapse), matching the truth tables, for both ACTIVE and COMPLETED.
3. G1 unverified-provenance visible in output.
4. Full `Invoke-Pester .\Tests` green except the documented pre-existing/env failures.
5. Additive: no regression in ACTIVE-path or other suites.

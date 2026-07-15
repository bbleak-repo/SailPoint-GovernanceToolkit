# V4c: Entitlement State Database

## Problem

"Newly Decided" has been broken across V4/V5/V6/V7 because:
1. ISC doesn't commit item decisions until reviewer sign-off (timing artifacts)
2. ISC auto-approves with `decision: "APPROVE"` + `comments: "idNowAutoApproved"` on force-close
3. Two-campaign diffs can't distinguish genuine state changes from timing noise
4. No persistent per-entitlement state tracking across campaigns

## Critical ISC API Fact

**ISC will NEVER return `decision: "UNDECIDED"` via the API.** The only values are:
- `decision: "APPROVE"` (genuine OR auto-closed)
- `decision: "REVOKE"` (genuine)
- `decision: null` (unsigned reviewer, ISC hasn't committed)

The ONLY way to detect auto-closed items is `decision: "APPROVE"` + `comments`
containing `"idNowAutoApproved"`. The ISC GUI shows "Undecided" but the API
returns "APPROVE" with that breadcrumb. Our code maps this to `UNDECIDED` state
internally -- that state NEVER comes from ISC directly.

## Solution

V4c = fork of V4 with a persistent **entitlement state database** (`entitlement-state.jsonl`).
One line per unique Key (IdentityId|AccessId|SourceId). ~3000 records, ~1.2MB.
Acts like a SQLite key-value store: read-modify-write on each run.

V4 stays as-is (production stable). V4c is the new implementation.

---

## Schema (one JSONL line per Key)

```json
{
  "key": "id123|ent456|src789",
  "identityId": "id123",
  "identityName": "John Smith",
  "accessId": "ent456",
  "accessName": "Enterprise Admin",
  "sourceId": "src789",
  "sourceName": "Corporate AD",
  "privileged": true,

  "currentDecision": "APPROVE",
  "currentReviewer": "Alice Chen",
  "currentCampaignId": "camp-0611",
  "currentCampaignDate": "2026-06-11",
  "decisionDate": "2026-06-11T10:30:00Z",

  "firstSeenDate": "2026-06-05",
  "lastStateChange": "2026-06-11",
  "lastStateFrom": "PENDING",
  "campaignsObserved": 7,
  "inCurrentScope": true,
  "lastRunDate": "2026-06-24",

  "stateLog": "P:0605|A:0611"
}
```

### Decision Values (Internal)

| Internal Value | Source | Meaning |
|---|---|---|
| `APPROVE` | ISC `decision: "APPROVE"` + comments is NULL or non-idNowAutoApproved | Genuine reviewer approval |
| `REVOKE` | ISC `decision: "REVOKE"` | Genuine reviewer revocation |
| `PENDING` | ISC `decision: null` (unsigned reviewer on ACTIVE campaign) | Not yet committed by ISC |
| `UNDECIDED` | ISC `decision: "APPROVE"` + `comments: "idNowAutoApproved"` | Auto-closed, reviewer never acted. ISC NEVER returns "UNDECIDED" directly |

### stateLog Format

Compact string, append on STATE CHANGE only (not every observation):
```
P:0605|A:0611|R:0815|U:0623|A:0625
```
- `P` = PENDING, `A` = APPROVE, `R` = REVOKE, `U` = UNDECIDED
- Date is MMDD (4 chars)
- Separator is `|`
- Most items: 1-3 entries per year

---

## Processing Algorithm

### Per V4c Run

```
1. Read entitlement-state.jsonl into $stateMap (hashtable keyed by Key)
   - If file doesn't exist: $stateMap = empty (first run)

2. Sort $campaignAudits by created date ASCENDING (oldest first)

3. For each campaign (chronological order):
   a. Determine honest decision for each item:
      - If decision == "APPROVE" AND justification contains "idNowAutoApproved":
        → honestDecision = "UNDECIDED"
      - Else if decision is null/empty:
        → honestDecision = "PENDING"  
      - Else:
        → honestDecision = decision (APPROVE or REVOKE)
   
   b. For each item (from $audit['Decisions'] which already has idNowAutoApproved
      classification via Group-SPAuditDecisions):
      - Map bucket name: Approved→"APPROVE", Revoked→"REVOKE", Pending→check original
        - If item was reclassified from APPROVE to Pending by idNowAutoApproved:
          → honestDecision = "UNDECIDED"
        - If item was naturally PENDING (decision was null):
          → honestDecision = "PENDING"
      - Look up Key in $stateMap
      
      IF NOT FOUND (new entitlement pair):
        - Create record with firstSeenDate, currentDecision, stateLog="X:MMDD"
      
      IF FOUND AND decision DIFFERS from currentDecision:
        - Set lastStateFrom = currentDecision
        - Set currentDecision = honestDecision
        - Set lastStateChange = campaign date
        - Append to stateLog: "X:MMDD"
        - Update: currentReviewer, currentCampaignId, decisionDate
      
      IF FOUND AND decision SAME:
        - Update: campaignsObserved++, currentCampaignId, currentCampaignDate
        - Do NOT append to stateLog (no state change)
      
      ALWAYS: set inCurrentScope = true, lastRunDate = today

4. After ALL campaigns processed:
   - Keys in $stateMap not seen in ANY campaign this run:
     → set inCurrentScope = false (dropped from scope)
     → do NOT delete the record (history preservation)

5. Write $stateMap to entitlement-state.jsonl (atomic: write .tmp, rename)
```

### Distinguishing PENDING vs UNDECIDED in Step 3b

`Group-SPAuditDecisions` puts idNowAutoApproved items in the `Pending` bucket.
But we need to distinguish two types of Pending:
- **PENDING**: `decision: null` from ISC (unsigned reviewer, genuinely not committed)
- **UNDECIDED**: `decision: "APPROVE"` + `idNowAutoApproved` (auto-closed, never reviewed)

To tell them apart, check the item's `Justification` field:
- If `Justification.Contains('idNowAutoApproved')` → UNDECIDED
- Else → PENDING

Both are in the Pending bucket from Group-SPAuditDecisions, but the Justification
field tells us WHY.

---

## What This Enables

| Query | State File Filter |
|---|---|
| Newly Decided (genuine) | `lastStateChange == today AND lastStateFrom in ('PENDING','UNDECIDED')` |
| Never reviewed (chronic) | `currentDecision in ('PENDING','UNDECIDED') AND campaignsObserved >= N` |
| Auto-closed then re-approved | `stateLog contains 'U' followed by 'A'` |
| Dropped from scope | `inCurrentScope == false` |
| Privileged exposure | `privileged == true AND currentDecision != 'APPROVE'` |
| Reviewer changed | Compare currentReviewer across runs |
| State unchanged for N days | `lastStateChange < today - N` |
| First-time grants | `firstSeenDate == today AND currentDecision == 'APPROVE'` |

---

## File Location

`{Metrics.Path}/entitlement-state.jsonl` (alongside daily-metrics.jsonl)
Default: `{toolkit-root}/Audit/metrics/entitlement-state.jsonl`

---

## Multi-Campaign Scenarios

### Scenario A: 17 COMPLETED + 1 ACTIVE (normal daily)
- Process camps 1-17 (COMPLETED) chronologically, then camp 18 (ACTIVE)
- COMPLETED campaigns: items with idNowAutoApproved → UNDECIDED
- ACTIVE campaign (last): items with decision=null → PENDING, decision=APPROVE → APPROVE
- Final state reflects the ACTIVE campaign's honest data
- UNDECIDED items from COMPLETED camps that are APPROVE in the ACTIVE camp:
  → stateLog shows `U:0623|A:0624` (auto-closed, then genuinely re-approved)

### Scenario B: All 18 COMPLETED (force-closed)
- All items with idNowAutoApproved → UNDECIDED
- Items genuinely reviewed before close: APPROVE (no idNowAutoApproved)
- State file correctly shows who was genuinely reviewed vs auto-closed

### Scenario C: First run (no state file)
- $stateMap starts empty
- All items are CREATE operations
- Process all 18 campaigns chronologically
- stateLog captures the full history from campaign 1 through 18
- After run: state file has ~3000 records with complete history

### Scenario D: Resume after 3-day gap
- State file last updated 2026-06-20
- V4c processes campaigns from 6/21, 6/22, 6/23, 6/24
- Only state CHANGES get new stateLog entries
- Keys unchanged since 6/20: just campaignsObserved++ and metadata update

### Scenario E: Restored pre-completion cache
- Cache has ACTIVE-state items (decision=null for unsigned reviewers)
- State file may have prior COMPLETED data with UNDECIDED
- Processing the ACTIVE cache: items with decision=null → PENDING
- If state was UNDECIDED (from auto-close) and now PENDING (from restored cache):
  → This is a regression (less info, not more). The UNDECIDED state was more honest.
  → Consider: don't downgrade UNDECIDED to PENDING (UNDECIDED is more specific)

---

## Retention

- Active records (inCurrentScope=true): retained indefinitely
- Dropped records (inCurrentScope=false): retained for 90 days, then pruned
- stateLog: no truncation needed (compact format, 1-5 entries per year)

---

## Implementation Notes

### Script
`Scripts/Invoke-SPDailyEvidenceReportV4c.ps1` -- fork of V4, NOT V4b.
V4 stays as-is (production stable). V4c adds the entitlement state layer.

### Module (extracted for reuse)
`Modules/SP.Audit/SP.EntitlementState.psm1` -- 3 public functions:
- `Read-SPEntitlementState` -- load JSONL into hashtable
- `Update-SPEntitlementState` -- process campaigns through state machine
- `Write-SPEntitlementState` -- atomic write (.tmp + rename)

Registered as a nested module in SP.Audit.psd1. Any script (V1-V7) can call these
functions -- the state file is script-agnostic.

Future reviewer state tracker follows the same pattern in a separate module.

### Dependencies
- Same modules as V4 (SP.Shared, SP.Core, SP.Api, SP.Audit)
- `SP.EntitlementState` (new nested module in SP.Audit)
- `Group-SPAuditDecisions` with `idNowAutoApproved` detection (already in SP.AuditReportCore)
- `Audit/metrics/entitlement-state.jsonl` (created on first run)

### PS 5.1 Compatibility
- Same constraints as V4: no ternary, .Contains() not .ContainsKey(), explicit casts
- Hashtable for $stateMap (not [ordered] -- keyed access, not iteration order)
- Atomic write: UTF8 no-BOM, write to .tmp, rename

### Integration with V7
V7 can read `entitlement-state.jsonl` for:
- "Newly Decided" section (query lastStateChange == today)
- "Never Reviewed" section (query currentDecision == PENDING/UNDECIDED for N+ campaigns)
- "Entitlement Timeline" chart (render stateLog as a visual timeline)

### HTML Report Changes
V4c's HTML adds/modifies:
- "Newly Decided" section: sourced from entitlement-state.jsonl (genuine state changes only)
- "Entitlement State Summary" section: counts by currentDecision (APPROVE/REVOKE/PENDING/UNDECIDED)
- "Dropped from Scope" section: keys where inCurrentScope flipped to false

---

## Testing

1. First run (no state file): verify ~3000 records created with correct states
2. Second run (same data): verify 0 state changes, only metadata updates
3. Force-close scenario: verify idNowAutoApproved → UNDECIDED in state file
4. Genuine approval: verify PENDING → APPROVE with correct stateLog
5. Re-approval after auto-close: verify UNDECIDED → APPROVE transition
6. Dropped scope: verify inCurrentScope=false for removed items
7. PS 5.1 compatibility audit

---

## Done-When

- [x] V4c reads/writes entitlement-state.jsonl
- [x] UNDECIDED state correctly derived from idNowAutoApproved (NOT from ISC API)
- [x] stateLog only appends on genuine state changes
- [x] Multi-campaign processing in chronological order
- [x] First run creates clean state file
- [x] Subsequent runs update correctly (no duplicates, no lost history)
- [x] "Newly Decided" section sourced from state file
- [x] State logic extracted to SP.EntitlementState.psm1 module (reusable by V1-V7)
- [x] Pester tests for all scenarios (ES-001 through ES-009, 12 tests passing)
- [x] Read/Write round-trip test (ES-008) with actual JSONL file I/O
- [x] StateSummary counts test (ES-009)
- [ ] PS 5.1 Desktop compatible (syntax validated via pwsh parser, needs Windows PS 5.1 runtime test)

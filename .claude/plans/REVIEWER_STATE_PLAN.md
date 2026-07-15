# Reviewer State Database

## Problem

We track entitlement state (per identity+access pair) but NOT reviewer engagement
state across campaigns. We can't answer:
- Does this reviewer always miss Fridays? (shift worker pattern)
- Did they miss 2+ days this week? (weekly compliance threshold)
- Have they NEVER completed ANY campaign type? (chronic non-compliant)
- Do they complete Daily Attestation but ignore SOX reviews? (selective compliance)
- Are they trending better or worse over 30/60/90 days?

## Design Principles (from entitlement-state lessons learned)

1. **JSONL as database** -- read-modify-write, one line per reviewer, NOT append-only log
2. **Module extracted** -- `SP.ReviewerState.psm1` with `Read-`, `Update-`, `Write-` functions
3. **Campaign-type aware** -- track engagement per campaign series, not just globally
4. **ISC API facts** -- cert-level `Phase=SIGNED` is honest for ACTIVE campaigns but inflated
   for COMPLETED (force-signed). Use item-level data (from entitlement-state or reviewer
   records) as the source of truth for "did they actually review."

## Key Design Decision: Campaign Series

Reviewers participate in MULTIPLE campaign types:
- `Daily Privileged Role Attestation *` (daily, same scope)
- `Q2 SOX Access Review` (quarterly, different scope)
- `Annual Role Recertification` (annual)

The reviewer state file needs to track engagement PER CAMPAIGN SERIES, not just globally.
A reviewer who completes every Daily Attestation but ignores SOX reviews is a different
problem than one who ignores everything.

### Campaign Series Detection

Use the campaign name prefix (before the date portion) as the series identifier:
- `Daily Privileged Role Attestation Monday, June 8, 2026` → series: `Daily Privileged Role Attestation`
- `Q2 SOX Access Review` → series: `Q2 SOX Access Review`

V4c already has `CampaignNameContains` / `CampaignNameStartsWith` filters.
The reviewer state module should accept a `-SeriesName` parameter to scope queries.

---

## Schema (one JSONL line per reviewer)

```json
{
  "reviewerName": "Alice Chen",
  "reviewerEmail": "alice.chen@corp.test",
  "reviewerId": "id-alice-chen",

  "series": {
    "Daily Privileged Role Attestation": {
      "firstSeenDate": "2026-06-05",
      "lastActiveDate": "2026-06-24",
      "lastDecisionCount": 200,
      "lastItemsTotal": 200,
      "lastCompletionPct": 100.0,
      "campaignsObserved": 14,
      "campaignsCompleted": 14,
      "campaignsMissed": 0,
      "dayLog": "C:0605|C:0608|C:0609|C:0610|C:0611|C:0612|M:0613|M:0614|C:0615|C:0616|C:0617|C:0618|C:0619|M:0620|M:0621|C:0622|C:0623|C:0624",
      "weeklyStats": {
        "2026-W24": { "expected": 5, "completed": 4, "missed": 1, "partials": 0 },
        "2026-W25": { "expected": 5, "completed": 5, "missed": 0, "partials": 0 },
        "2026-W26": { "expected": 3, "completed": 3, "missed": 0, "partials": 0 }
      },
      "streaks": {
        "currentStreak": 8,
        "longestStreak": 14,
        "currentMissStreak": 0,
        "longestMissStreak": 2
      }
    },
    "Q2 SOX Access Review": {
      "firstSeenDate": "2026-04-01",
      "lastActiveDate": "2026-04-15",
      "lastDecisionCount": 50,
      "lastItemsTotal": 50,
      "lastCompletionPct": 100.0,
      "campaignsObserved": 1,
      "campaignsCompleted": 1,
      "campaignsMissed": 0,
      "dayLog": "C:0401",
      "weeklyStats": {},
      "streaks": { "currentStreak": 1, "longestStreak": 1, "currentMissStreak": 0, "longestMissStreak": 0 }
    }
  },

  "global": {
    "totalCampaignsObserved": 15,
    "totalCampaignsCompleted": 15,
    "totalCampaignsMissed": 0,
    "lastRunDate": "2026-06-24",
    "engagementScore": 100
  }
}
```

### dayLog Format

Compact per-campaign-day log (only business days with campaigns):
- `C` = Completed (all items decided, signed off)
- `P` = Partial (some items decided, not signed)
- `M` = Missed (campaign existed, reviewer made 0 decisions)
- `U` = Undecided (campaign force-closed, reviewer's items auto-approved)
- `X` = Not in scope (reviewer not assigned to this campaign)

Date is MMDD. Weekends/holidays with no campaign get no entry (not "missed").

### weeklyStats

Per ISO-week summary for weekly reporting:
- `expected`: campaigns that existed this week where reviewer was in scope
- `completed`: campaigns where reviewer decided all items
- `missed`: campaigns where reviewer made 0 decisions
- `partials`: campaigns where reviewer made some but not all decisions

Enables: "Did they miss 2+ days this week?" → check `missed >= 2`

### streaks

Running counts for trend detection:
- `currentStreak`: consecutive campaigns completed (resets on miss/partial)
- `longestStreak`: all-time best consecutive completions
- `currentMissStreak`: consecutive campaigns missed (resets on completion)
- `longestMissStreak`: worst consecutive misses

Enables: "Is this reviewer trending worse?" → currentMissStreak > 0

### engagementScore (global)

Simple 0-100 score: `totalCampaignsCompleted / totalCampaignsObserved * 100`
Weighted by recency: last 30 days count 2x vs older. Enables: sort reviewers
by engagement for escalation priority.

---

## Determining "Completed" vs "Missed" vs "Partial"

Source: `$audit['ReviewerRecords']` from V4c (item-level, honest).

| Reviewer State | Detection |
|---|---|
| **Completed** | `total > 0 AND pending == 0` (all items decided) |
| **Partial** | `total > 0 AND pending > 0 AND (approved + revoked) > 0` |
| **Missed** | `total > 0 AND (approved + revoked) == 0` (zero decisions) |
| **Undecided** | `total > 0 AND item justification contains idNowAutoApproved` (force-closed) |
| **Not in scope** | Reviewer not in this campaign's reviewer list |

For COMPLETED campaigns: use item-level data (idNowAutoApproved detection).
For ACTIVE campaigns: use item-level data (decision=null → PENDING).
Do NOT use cert-level Phase=SIGNED (ISC inflates on force-close).

---

## Processing Algorithm

```
1. Read reviewer-state.jsonl into $reviewerMap (hashtable by reviewerName)
   - If file doesn't exist: $reviewerMap = empty (first run)

2. Sort $campaignAudits by created date ASCENDING

3. Detect campaign series from campaign name:
   - Strip date suffix: "Daily Privileged Role Attestation Monday, June 8, 2026"
     → seriesName = "Daily Privileged Role Attestation"
   - Use longest common prefix across campaign names if unclear

4. For each campaign (chronological):
   a. campaignDate = campaign created date (MMDD)
   b. isoWeek = ISO week number for this date
   c. For each reviewer in $audit['ReviewerRecords']:
      - Determine state: Completed / Partial / Missed / Undecided
      - Look up reviewer in $reviewerMap
      - If not found: CREATE with firstSeenDate
      - If found: UPDATE series entry
        - Append to dayLog: "X:MMDD"
        - Update weeklyStats for this ISO week
        - Update streaks
        - Update campaignsObserved/Completed/Missed
   d. For reviewers in $reviewerMap[seriesName] NOT in this campaign:
      - They might have been removed from scope
      - Don't mark as missed (they weren't assigned)
      - Track separately if needed

5. Update global stats for each reviewer

6. Write $reviewerMap to reviewer-state.jsonl (atomic)
```

---

## File Location

`{Metrics.Path}/reviewer-state.jsonl` (alongside entitlement-state.jsonl)
Default: `{toolkit-root}/Audit/metrics/reviewer-state.jsonl`

Separate from entitlement-state.jsonl because:
- Different key (reviewer name vs entitlement pair)
- Different update frequency (reviewer state changes less often)
- Different consumers (V7 compliance accountability vs V4c newly decided)

---

## Module

`Modules/SP.Audit/SP.ReviewerState.psm1` -- follows SP.EntitlementState pattern:
- `Read-SPReviewerState` -- load JSONL into hashtable
- `Update-SPReviewerState` -- process campaigns through state machine
- `Write-SPReviewerState` -- atomic write
- `Get-SPReviewerEngagement` -- query helpers (by series, by week, streaks)

Registered as nested module in SP.Audit.psd1.

---

## V7 Integration

V7 can read `reviewer-state.jsonl` for:

### Existing sections (enhanced)
- **Reviewer Compliance Accountability**: use dayLog for per-day classification
  instead of computing from JSONL per-reviewer data
- **Reviewer Activity Heatmap**: use dayLog directly (C/P/M/U per day)

### New sections (enabled by reviewer state)
- **Weekly Compliance Report**: per-reviewer weekly stats (expected/completed/missed)
  with threshold highlighting (missed >= 2 = amber, missed >= 3 = red)
- **Engagement Trend**: 30/60/90 day engagement scores per reviewer
- **Pattern Detection**: "Always misses Fridays" (dayLog analysis by day-of-week)
- **Cross-Series Compliance**: matrix of reviewers x campaign series showing
  who completes Daily Attestation but misses SOX reviews

### Filtering
```powershell
# V7 for Daily Attestation only
.\Invoke-SPDailyEvidenceReportV7.ps1 -CampaignNameContains 'Daily' -DaysBack 30

# V7 reads reviewer-state.jsonl, filters series to "Daily Privileged Role Attestation"
# Shows only engagement data for that series
```

---

## Weekly Reporting Use Case

The user wants: "show me reviewers who missed 2+ days during the work week"

```powershell
# After V4c run populates reviewer-state.jsonl:
$state = Read-SPReviewerState
$thisWeek = Get-Date -UFormat '%Y-W%V'
$delinquent = $state.Values | Where-Object {
    $_.series.'Daily Privileged Role Attestation'.weeklyStats.$thisWeek.missed -ge 2
}
# $delinquent = reviewers who missed 2+ days this week for Daily Attestation
```

---

## Shift Worker / Pattern Detection

dayLog enables day-of-week analysis:
```
Alice Chen dayLog: C:0605(Thu)|C:0608(Mon)|C:0609(Tue)|C:0610(Wed)|C:0611(Thu)|M:0612(Fri)|
                   C:0615(Mon)|C:0616(Tue)|C:0617(Wed)|C:0618(Thu)|M:0619(Fri)|
                   C:0622(Mon)|C:0623(Tue)|C:0624(Wed)
```

Pattern: misses every Friday → shift worker or part-time. Not a compliance issue,
but should be reassigned for Fridays or excluded from Friday escalation.

Detection: count misses by day-of-week. If one day has >= 3x the miss rate of
other days, flag as "pattern detected: [day]".

---

## Size Estimate

- 180 reviewers × ~500 bytes per record = ~90KB
- With 2 campaign series: ~120KB
- After 1 year of daily dayLog entries (~250 chars): ~200KB total
- Well within single-file JSONL limits

---

## Done-When

- [x] SP.ReviewerState.psm1 module with Read/Update/Write + Get-SPCampaignSeriesName
- [x] reviewer-state.jsonl with per-series tracking
- [x] dayLog with C/P/M/U classification + idempotency guard
- [x] weeklyStats computed per ISO week
- [x] Streak tracking (current/longest for completions and misses)
- [x] Campaign series auto-detection from name prefix (regex date stripping)
- [x] Undecided (U) detection via idNowAutoApproved cross-reference
- [x] engagementScore as simple completed/observed ratio (recency weighting deferred)
- [x] Registered as nested module in SP.Audit.psd1 + Import-TestModules.ps1
- [x] Pester tests: RS-001 through RS-011 (22 tests passing)
- [ ] V4c integration: add Step 1d to call Read/Update/Write-SPReviewerState
- [ ] V7 integration: enhanced compliance accountability from state file
- [ ] Pattern detection: day-of-week miss analysis (Get-SPReviewerEngagement)
- [ ] PS 5.1 Desktop compatible (syntax validated via pwsh parser)

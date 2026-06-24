# V7 Architecture: Calendar-Day-Oriented Visualization

## Problem

V6 was designed as a time-series visualizer (one data point per day). But with
daily certification campaigns, the JSONL contains one record PER CAMPAIGN -- and
multiple campaigns can share the same calendar date (or the same campaign can
have records from multiple V4 runs). This causes:

1. **Duplicate day labels** -- 12 bars all labeled "06/23" because each campaign
   is a separate data point but they share the same captureDate
2. **Conflicting data** -- same day shows 0%, 91%, and 100% for different campaigns
   (one ACTIVE, one COMPLETED with inflated data, one with pre-fix JSONL)
3. **Heatmap uniformity** -- delta computation between adjacent records yields 0
   when records are from the same day
4. **Risk Matrix sort broken** -- compound dedup key disrupts date ordering
5. **Decision Activity table** -- repeated day entries with same scope numbers

### V6 Assumptions (Wrong for Daily Campaigns)
- One campaign spans multiple days (within-campaign progression)
- captureDate increases monotonically (one capture per day)
- Each record is a distinct day in a time series

### Reality (Daily Campaigns)
- One campaign per day (cross-campaign progression)
- Multiple campaigns exist simultaneously (all ACTIVE for 18+ days due to ISC bug)
- V4 writes one JSONL record per campaign per run (11+ records per run)
- Same campaign gets re-captured each day V4 runs (but only its creation date matters)

---

## Solution

V7 is calendar-day-oriented: the X-axis is the **calendar date** and each date
shows the **campaign that represents that day** (the campaign created on that date).

### Core Data Model Change

V6's `$dailyData` is an array of records (one per JSONL line, deduplicated by
captureDate|campaignId). V7 replaces this with a calendar-day index:

```
$calendarDays = [ordered]@{
    '2026-06-05' = @{
        Campaign    = $mostRepresentativeRecord   # the campaign created on this date
        DayLabel    = '06/05'
        Date        = '2026-06-05'
    }
    '2026-06-06' = @{ ... }
    ...
}
```

**Resolution rules** (when multiple records map to the same calendar date):
1. Prefer ACTIVE-status records over COMPLETED (honest data)
2. Among same-status records, prefer the latest captureTimestamp (most current)
3. One and only one record per calendar day -- no duplicates in any chart

**Calendar date derivation**: Use `campaign.created` date (already stored in JSONL
as `captureDate` after our V4 fix). This is the campaign's own date, not when V4 ran.

---

## JSONL Data Quality Layer

V7 should clean the data BEFORE building charts:

### Step 2a: Load and filter
- Read all JSONL lines within DaysBack window
- Apply -CampaignNameContains and -Status filters (same as V6)

### Step 2b: Detect and flag idNowAutoApproved
- V4 now writes honest counts (with idNowAutoApproved detection)
- But older JSONL records (pre-fix) have inflated numbers
- V7 can detect these: if `campaign.status = COMPLETED` and `summary.pending = 0`
  and `summary.completionPct = 100`, the record is likely pre-fix inflated data
- Flag these with `dataQuality = 'suspect'` and show a visual indicator

### Step 2c: Calendar-day resolution
- Group all records by calendar date (from captureDate)
- Apply resolution rules (ACTIVE preferred, latest timestamp wins)
- Result: one clean record per calendar day

### Step 2d: Compute deltas
- For each consecutive pair of calendar days, compute:
  - completionDelta = today.completionPct - yesterday.completionPct
  - approvedDelta = today.approved - yesterday.approved
  - revokedDelta = today.revoked - yesterday.revoked
  - undecidedDelta = today.pending - yesterday.pending (note: may be negative as items get decided)
- These deltas drive the heatmap, bar charts, and trending table

---

## Charts (Refined from V6)

### 1. KPI Banner + Executive Summary
Same as V6 but uses the LATEST calendar day's data. Shows:
- Current completion % (from most recent day)
- Delta vs first day in window
- Days to deadline (from latest campaign's deadline)
- Undecided count prominently displayed

### 2. Completion Progression -- Day-by-Day Line Chart
- X-axis: calendar dates (one tick per day, no duplicates)
- Y-axis: completion % (0-100)
- Single line showing progression across daily campaigns
- Data quality indicator: suspect records shown with dashed segments

### 3. Decision Distribution -- Stacked Area Chart
- X-axis: calendar dates
- Three stacked areas: Approved (green), Revoked (red), Undecided (amber)
- Shows how the decision mix evolves day over day

### 4. Per-Reviewer Accountability Table
Same as V6 but:
- Reviewer first/last seen dates derived from calendar days (not record indices)
- Direction arrows based on first-day vs last-day completion delta
- "In Scope Since" uses campaign creation date, not data point index

### 5. Reviewer Activity Heatmap
- X-axis: calendar dates (one column per day, no duplicates)
- Y-axis: reviewers
- Cell color = daily delta in decisions (today.decided - yesterday.decided)
- Inactive reviewers (zero delta across all days) highlighted in light red

### 6. Completion Projection vs Deadline
Same as V6 but:
- Uses calendar-day velocity (completion change per calendar day)
- Deadline from the latest campaign's deadline field
- Projection line extends from the latest calendar day

### 7. Decision Activity Trending -- Table (from V6 Chart 10)
- One row per calendar day (no duplicates)
- Columns: Day | Campaign | Revoked | Newly Decided | New Scope | Completion
- Cumulative row at bottom
- Campaign column shows the short campaign name for that day

### 8. Decision Activity Trending -- Stacked Bars (from V6 Chart 11)
- X-axis: calendar dates (one bar per day)
- Stacked: Revoked (red) + Newly Decided (green) + New Scope (blue)
- Cumulative dashed line overlay

### 9. Cross-Campaign Risk Matrix
- One row per calendar day (sorted by date descending)
- Shows the campaign for that day with: completion donut, thermometer, deadline,
  privileged pending, stalled reviewers, risk score
- Data quality badge on suspect records

### Removed from V6
- Vertical Completion Progression (redundant with #2)
- Privileged Access Trend as standalone (folded into KPI banner)

---

## Parameters

```powershell
param(
    [int]$DaysBack = 7,
    [string]$CampaignNameContains,
    [ValidateSet('ACTIVE', 'COMPLETED', 'COMPLETING', '')]
    [string]$Status,
    [string]$OutputPath,
    [ValidateSet('Console', 'HTML', 'Both')]
    [string]$OutputMode = 'Both',
    [switch]$IncludeSuspect,   # Include suspect (pre-fix) JSONL records
    [switch]$Help
)
```

No -Token, no -NoCache, no API parameters. V7 is pure read-only visualization.

---

## Implementation Notes

### File
`Scripts/Invoke-SPDailyEvidenceReportV7.ps1`

### Dependencies
- SP.Shared (ConvertTo-SPHtmlSafe, Format-SPHtmlDate, Get-SPHtmlColorPalette, etc.)
- SP.Core (Get-SPConfig, Resolve-SPConfigPath)
- daily-metrics.jsonl (written by V4)

### PS 5.1 Compatibility Checklist
- No ternary `? :` or null-coalescing `??`
- `.Contains()` not `.ContainsKey()` on OrderedDictionary
- No `Measure-Object -Property` on hashtables
- Explicit `[int]`/`[double]` casts on all numeric operations
- `[System.Collections.Generic.List[object]]::new()` (requires PS 5+)
- `[datetime]::Parse()` with `DateTimeStyles.RoundtripKind` for ISO dates

### HTML Output
- Self-contained (no external JS/CSS)
- Inline SVG charts (Word/email compatible)
- Same CSS theme as V4/V6 (Segoe UI, #1f3a5f headers, .section containers)
- Filename: `daily-evidence-v7-{campaignPrefix}-{timestamp}.html`

---

## Migration from V6

V7 replaces V6 for the user-facing report. V6 can remain as a reference.
The JSONL format is unchanged -- V7 reads the same `daily-metrics.jsonl` that V4
writes. No V4 changes needed.

---

## Testing

1. Generate synthetic JSONL with:
   - 10 campaigns across 10 days (one per day)
   - Mixed ACTIVE/COMPLETED status
   - Some campaigns with idNowAutoApproved-inflated records (pre-fix)
   - One day with two campaigns (edge case)
2. Verify:
   - Calendar day resolution produces exactly 10 data points
   - ACTIVE records preferred over COMPLETED for same day
   - Suspect records flagged (or excluded with default, included with -IncludeSuspect)
   - All charts show one bar/column per calendar day
   - Heatmap deltas computed between consecutive calendar days
   - Risk Matrix sorted by date descending
   - Decision Activity table has no duplicate day rows
3. Run with real 18-day data from user's JSONL
4. PS 5.1 compatibility audit (same as V6)

---

## Done-When

- [ ] V7 reads daily-metrics.jsonl with calendar-day resolution
- [ ] One data point per calendar day (no duplicates in any chart)
- [ ] ACTIVE records preferred over COMPLETED for same day
- [ ] Suspect (pre-fix) records detected and flagged
- [ ] All charts use calendar date as X-axis
- [ ] Heatmap shows per-day deltas (not per-record)
- [ ] Risk Matrix sorted by campaign creation date descending
- [ ] Decision Activity table: one row per calendar day
- [ ] Numbers match V4's output for the same campaign
- [ ] No ISC API calls
- [ ] PS 5.1 Desktop compatible
- [ ] Pester tests covering all edge cases

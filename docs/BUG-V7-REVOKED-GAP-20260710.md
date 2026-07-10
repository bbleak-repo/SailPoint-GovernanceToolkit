# Bug Report: V7 Shows 399 Fewer Revokes Than V4e

**Date:** 2026-07-10
**Reporter:** Production testing -- June full-month report comparison
**Severity:** Medium (data display, not data loss -- V4e has correct numbers)
**Status:** Open -- needs investigation

---

## Summary

V7's Campaign Completion Evidence table and stacked bar chart show approximately
399 fewer revoked items across the June campaign period compared to V4e's series
attestation report. Both were generated from the same V4b run (fresh, no cache,
23 campaigns written to daily-metrics.jsonl).

## Environment

- V4b ran with `-DaysBack 40 -CampaignNameContains 'June' -RefreshCache`
- No prior cache -- clean fetch from ISC
- All June campaigns are COMPLETED (force-closed late June)
- 23 campaigns written to daily-metrics.jsonl, 0 skipped
- V4e ran against the same cache (read-only, series engine)
- V7 ran with `-StartDate '2026-06-01' -EndDate '2026-06-30'`

## Observed Behavior

| Report | Revoked Count (June total) | Source |
|---|---|---|
| V4b HTML | ~X (per-campaign sums) | Direct from `$d['Revoked'].Count` in memory |
| V4e HTML | Higher (series engine, deduplicated by Key) | Cache items via `Get-SPSeriesAttestationDelta` |
| V7 HTML | V4e minus ~399 | `daily-metrics.jsonl` per-campaign `summary.revoked` |

V7 is UNDER-reporting by ~399 revoked items compared to V4e.

## Additional Data Points

### Per-Campaign Spot Check (June 15)
- V4b cache (fresh COMPLETED fetch): **18 revoked**
- Original old V4 (6/12 build, ACTIVE-state cache): **6 revoked**
- Difference: 12 additional revocations happened between the ACTIVE capture and force-close
- This is expected -- ISC preserves genuine REVOKE decisions through completion

### Duplicate Revokes
- 93 items appear as revoked in multiple campaigns (disconnected app remediation backlog)
- These are legitimate -- the disconnected app admin didn't handle the first revocation
- Each subsequent campaign correctly shows the item as still revoked
- NOT a data bug -- it's an operational finding about remediation follow-through

### Force-Close Behavior Confirmed
- ISC does NOT reverse genuine REVOKE decisions on force-close
- `idNowAutoApproved` only applies to items that were PENDING (undecided)
- Items with `decision: "REVOKE"` retain that decision through COMPLETED status
- COMPLETED campaigns have MORE revocation data than ACTIVE snapshots (late decisions included)

## Root Cause Hypotheses

### Hypothesis 1: JSONL `summary.revoked` Under-Counts (Most Likely)
V4b's JSONL writer computes `$revCount2 = @($d['Revoked']).Count` from
`Group-SPAuditDecisions` output. V4e's series engine reads cache items directly
and applies `Resolve-SPSeriesItemState`. If these classify items differently,
the JSONL would have a lower revoked count than V4e sees.

Possible cause: `Group-SPAuditDecisions` reclassifies some REVOKE items
(e.g., `idNowAutoApproved` check might catch REVOKE items whose justification
contains "idNowAutoApproved" even though the decision is REVOKE not APPROVE).
The `.Contains('idNowAutoApproved')` check is on the APPROVE branch only, but
worth verifying.

### Hypothesis 2: V7 Calendar-Day Resolution Drops Records
V7 deduplicates JSONL records by `captureDate|campaignId`. If the JSONL has
duplicate records for the same campaign (from multiple V4b runs), V7 keeps only
the latest. If an earlier record had more revokes than the latest, data is lost.

However: user confirmed this was a clean run (no prior JSONL, no cache). So
duplicates are unlikely unless V4b wrote the same campaign twice in one run.

### Hypothesis 3: V7 Rendering Bug
The Campaign Completion Evidence table in V7 reads per-campaign `$d.Revoked`
from the `$dailyData` array. If the array construction drops or miscounts the
revoked field during calendar-day resolution, the display would be lower.

### Hypothesis 4: ACTIVE-Record Protection Logic
The JSONL writer has logic to skip writing COMPLETED records if an ACTIVE record
already exists (to preserve honest data). In this case there were NO prior records
(clean run), so this should not apply. But worth confirming the "skipped 0" count
in the console output.

## Investigation Steps for Next Session

1. **Compare JSONL to V4b HTML for one campaign:**
   ```powershell
   # Pick June 15 campaign
   Get-Content .\Audit\metrics\daily-metrics.jsonl | ForEach-Object {
       $r = $_ | ConvertFrom-Json
       if ($r.captureDate -eq '2026-06-15') {
           Write-Host "JSONL: status=$($r.campaign.status) revoked=$($r.summary.revoked) approved=$($r.summary.approved) pending=$($r.summary.pending)"
       }
   }
   ```
   Compare to V4b HTML's Campaign Completion Evidence row for June 15.
   If they match: JSONL is correct, V7 rendering is the bug.
   If they differ: V4b JSONL writer is the bug.

2. **Compare V4e to JSONL for the same campaign:**
   Check V4e's HTML for June 15 revoked count. If V4e > JSONL, the series
   engine classifies items differently than `Group-SPAuditDecisions`.

3. **Check for multi-record JSONL entries:**
   ```powershell
   Get-Content .\Audit\metrics\daily-metrics.jsonl | ForEach-Object {
       ($_ | ConvertFrom-Json).captureDate
   } | Group-Object | Where-Object { $_.Count -gt 1 }
   ```
   If any date has multiple records, V7's dedup may be picking the wrong one.

4. **Grep cache for idNowAutoApproved on REVOKE items:**
   ```powershell
   # Check if any REVOKE items have idNowAutoApproved (shouldn't happen)
   $f = Get-ChildItem '.\Audit\.cache\' -Filter 'items-*.jsonl' | Select-Object -First 1
   Get-Content $f.FullName | ForEach-Object {
       $item = ($_ | ConvertFrom-Json).Item
       if ($item.decision -eq 'REVOKE' -and $item.comments -match 'idNowAutoApproved') {
           Write-Host "FOUND: REVOKE + idNowAutoApproved (unexpected)"
       }
   }
   ```

5. **Sum V7's per-row revoked vs V4e total:**
   Open V7 HTML, sum the "Revoked" column manually for all June rows.
   Compare to V4e's total. This isolates whether the gap is per-row
   or in the cumulative/total calculation.

## Trust Hierarchy (for compliance reporting)

| Source | Trust Level | Why |
|---|---|---|
| V4e (series engine) | **Highest** | Reads cache directly, deduplicates by Key, honest classification |
| V4b HTML | **High** | Same cache, but per-campaign aggregates (includes 93 recurring disconnected-app dupes) |
| V7 (from JSONL) | **Investigate** | 399 gap needs root cause before trusting for compliance |
| Old ACTIVE-state cache | **Historical** | Point-in-time, misses late revocations before force-close |

## Related Issues

- V4b "no active-state capture -- completion unverified" -- expected when running
  without cache against COMPLETED campaigns. V4b has no prior ACTIVE snapshot to
  compare against, so it can't verify the completion percentage is honest. The
  `idNowAutoApproved` detection still works at the item level.

- 93 recurring disconnected-app revokes -- operational finding, not a bug. The
  remediation backlog means the same revocation appears in each subsequent campaign
  because the downstream app admin hasn't processed it. Should be escalated.

## Files Referenced

- `Scripts/Invoke-SPDailyEvidenceReportV4b.ps1` -- JSONL writer
- `Scripts/Invoke-SPDailyEvidenceReportV4e.ps1` -- series engine report
- `Scripts/Invoke-SPDailyEvidenceReportV7.ps1` -- calendar-day visualization
- `Modules/SP.Audit/SP.AuditReportCore.psm1` -- `Group-SPAuditDecisions` (idNowAutoApproved)
- `Modules/SP.Audit/SP.CampaignSeries.psm1` -- `Resolve-SPSeriesItemState`, `Get-SPSeriesAttestationDelta`
- `Audit/metrics/daily-metrics.jsonl` -- V4b output, V7 input

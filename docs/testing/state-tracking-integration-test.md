# State Tracking Integration Test Guide

> **Updated 2026-07-16 (state stack v2.1):** the automated equivalents of these
> tests now live in `Tests/SP.StateOrchestrator.Tests.ps1` (bootstrap populates
> BOTH files, same-day rerun is a no-op, ACTIVE instances re-process until
> COMPLETED, corrupt state file aborts, `-Force` rebuilds without double-counting)
> plus the reworked `SP.EntitlementState`/`SP.ReviewerState` suites. Behavior
> changes vs the original guide: reviewer records key on stable identity
> (`id:<ReviewerId>` else `nm:<name>`), dayLog/stateLog day keys are `yyyyMMdd`,
> ACTIVE campaigns re-process on every run until they complete, and a corrupt
> state file makes the run FAIL (exit 5) instead of silently rebuilding.
> The console header reads `State File Update` (not `State Tracking:`).

> **Pre-requisite:** a populated rich audit cache (`Audit/cache/items-*.jsonl`,
> `roster-*.json`, `items-*.meta.json`) from at least one prior V4/V4b/V4e run.
> You need ISC network access only if the cache is empty and you need to
> run V4/V4e first to populate it.

## Test 1: Bootstrap State Files (first run)

This is the critical test -- the first time real cached data flows through the
state modules. Most issues will surface here.

```powershell
# From the toolkit root:
cd tools/SailPoint-GovernanceToolkit

# Option A: Run V8 directly (it auto-bootstraps if state files are missing)
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -DaysBack 14

# Option B: Run the state update explicitly (if you want to see the update output separately)
.\Scripts\Update-SPStateFiles.ps1 -Force
```

### What to check

**Console output should show:**
```
  State Tracking: ...
    [Series Stem] CampaignName (N items, yyyy-MM-dd)
    [Series Stem] CampaignName (N items, yyyy-MM-dd)
    ...
  State Update Complete
    Entitlement: NNNN records (NNNN new, 0 changed, 0 decided)
    Reviewer:    NNN records (NNN new, 0 updated)
```

**If you see errors instead:**
- `Get-SPCachedCampaignSeries not available` -- SP.Audit module didn't load fully. Check `Import-Module .\Modules\SP.Audit\SP.Audit.psd1 -Force` for errors.
- `Failed to load items for CampaignName` -- cache file is corrupt or missing. Check `Audit/cache/` for the referenced campaign ID.
- `Resolve-SPSeriesItemState not available` -- SP.CampaignSeries.psm1 is missing or has a load error. Run `Get-Command Resolve-SPSeriesItemState` to verify.
- Property errors like `The property 'ItemKey' cannot be found` -- the resolved item shape doesn't match what the state modules expect. This is the most likely integration failure. Note the exact property name and report it.

### Verify the state files

```powershell
# Check files exist and have content
ls Audit/metrics/entitlement-state.jsonl
ls Audit/metrics/reviewer-state.jsonl

# Check file sizes (entitlement ~500KB-1.5MB, reviewer ~50-200KB)
(Get-Item Audit/metrics/entitlement-state.jsonl).Length / 1KB
(Get-Item Audit/metrics/reviewer-state.jsonl).Length / 1KB

# Check _meta line (first line -- should have processedInstances)
Get-Content Audit/metrics/entitlement-state.jsonl -First 1 | ConvertFrom-Json | Select-Object _meta, processedInstances, lastRunDate

# Check a data record (second line)
Get-Content Audit/metrics/entitlement-state.jsonl -First 2 | Select-Object -Last 1 | ConvertFrom-Json | Format-List

# Check reviewer record
Get-Content Audit/metrics/reviewer-state.jsonl -First 2 | Select-Object -Last 1 | ConvertFrom-Json | Format-List
```

**Expected entitlement record shape:**
```
itemKey             : id-xxx|ent-xxx|src-xxx
identityId          : id-xxx
identityName        : John Smith
accessName          : AD_Users
currentDecision     : APPROVE (or REVOKE/PENDING/UNDECIDED)
priorDecision       :
inCurrentScope      : True
stateLog            : A:0624
consecutiveUndecided: 0
```

**Expected reviewer record shape:**
```
reviewerName  : Alice Chen
reviewerEmail : alice.chen@corp.test
series        : @{Daily Attestation=@{dayLog=C:0624; campaignsObserved=1; ...}}
global        : @{engagementScore=100; totalCampaignsObserved=1; ...}
```

---

## Test 2: Delta Mode (second run)

Run the update again WITHOUT `-Force`. It should skip all already-processed
instances and complete in seconds.

```powershell
.\Scripts\Update-SPStateFiles.ps1
```

**Expected output:**
```
  Mode:       Delta (new instances only)
  ...
    (no instance lines -- all skipped)
  State Update Complete
    Entitlement: NNNN records (0 new, 0 changed, 0 decided)
    Duration:    1.2 seconds
```

If it reprocesses everything again, the `processedInstances` tracking is broken --
check the `_meta` line of the state files.

---

## Test 3: V8 Report Rendering

```powershell
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -DaysBack 14
```

**Check the HTML output:**
1. Open the generated `daily-evidence-v8-*.html` in a browser
2. Verify each section renders:
   - Section 1 (Entitlement State Summary): four KPI tiles with non-zero counts
   - Section 2 (Newly Decided): may be empty on first run (no prior state to compare)
   - Section 3 (Chronically Unreviewed): items with PENDING/UNDECIDED
   - Section 4 (Dropped from Scope): usually empty on first run
   - Section 5 (Reviewer Engagement): table with engagement scores
   - Section 6 (Weekly Compliance): reviewers who missed 2+ days
   - Section 7 (Engagement Heatmap): colored C/P/M/U grid
   - Section 8 (Campaign Summary): table from daily-metrics.jsonl

3. Cross-check numbers against V4e output for the same campaigns:
   - V8 Approved + Revoked + Pending + Undecided should roughly equal V4e's total items
   - V8 Undecided count should match V4e's "Persistently Undecided" count
   - V8 reviewer list should match V4e's Section B reviewers

---

## Test 4: Parameter Filtering

```powershell
# Date range
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -DaysBack 7
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -StartDate 2026-07-01 -EndDate 2026-07-15

# Campaign name filter
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -CampaignNameContains 'Daily'

# Status filter
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -Status COMPLETED

# Combined
.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -DaysBack 30 -CampaignNameContains 'Daily' -Status ACTIVE
```

**Check:** each filter should narrow Section 8 (Campaign Summary) and Section 2
(Newly Decided by date range). Sections 1, 3-7 show all state data regardless
of filters (they read the full state file).

---

## Test 5: Auto-Refresh

Delete the state files and run V8 directly. It should detect the missing files,
auto-bootstrap from cache, and then render the report -- all in one command.

```powershell
Remove-Item Audit/metrics/entitlement-state.jsonl -Force -ErrorAction SilentlyContinue
Remove-Item Audit/metrics/reviewer-state.jsonl -Force -ErrorAction SilentlyContinue

.\Scripts\Invoke-SPDailyEvidenceReportV8.ps1
```

**Expected:** console shows "Auto-refresh needed (no state files found)" followed by
the bootstrap output, then the HTML report renders normally.

---

## Test 6: Performance Measurement

```powershell
# Time the bootstrap (all cached campaigns)
Measure-Command { .\Scripts\Update-SPStateFiles.ps1 -Force } | Select-Object TotalSeconds

# Time the delta (should be <30 seconds)
Measure-Command { .\Scripts\Update-SPStateFiles.ps1 } | Select-Object TotalSeconds

# Time V8 with fresh state (should be <30 seconds)
Measure-Command { .\Scripts\Invoke-SPDailyEvidenceReportV8.ps1 -OutputMode HTML } | Select-Object TotalSeconds
```

Record the actual times and compare against estimates:
- Bootstrap: estimated 2-5 minutes
- Delta: estimated <30 seconds
- V8 render: estimated <30 seconds

---

## Common Failure Modes

| Symptom | Likely Cause | Fix |
|---|---|---|
| `The property 'ItemKey' cannot be found` | Resolve-SPSeriesItemState output shape mismatch | Check the actual property names on a resolved item; update module to match |
| `Cannot index into a null array` | Null items in cache | Add null guards in the orchestrator's per-item loop |
| `Exception calling "Parse"` | Date string format mismatch (PS 5.1 vs PS 7) | Use `[System.Globalization.DateTimeStyles]::RoundtripKind` |
| V8 renders but all counts are 0 | State update ran but produced empty results | Check `_meta` line for processedInstances; check if Get-SPCachedCampaignSeries returns data |
| V8 auto-refresh fails silently | Cache directory not found or empty | Run V4/V4e first to populate the cache |
| `ConvertTo-SPHtmlSafe not found` | SP.Shared not loaded | Check module chain in V8 |
| State file grows unbounded | Retention pruning not working | Check RetentionDays parameter on Update-SPEntitlementState |
| Duplicate stateLog entries | Idempotency guard not working | Check Update-StateLogEntry logic with the MMDD from the failing record |

---

## Test 7: ACTIVE vs COMPLETED Capture Quality

This test validates whether the state files contain honest ACTIVE-capture data
or inflated COMPLETED-capture data. The answer determines whether a future
enhancement (status-aware processing) is needed.

```powershell
# 1. Check what status the cached campaigns have
Get-ChildItem Audit/cache/items-*.meta.json | ForEach-Object {
    $meta = Get-Content $_.FullName -Raw | ConvertFrom-Json
    [PSCustomObject]@{
        CampaignName = $meta.CampaignName
        Status       = $meta.Status
        CachedAt     = $meta.CachedAt
        Active       = if ($meta.PSObject.Properties['CapturedWhileActive']) { $meta.CapturedWhileActive } else { 'N/A' }
    }
} | Format-Table -AutoSize
```

**What to look for:**
- If most campaigns show `Status = ACTIVE` and `CapturedWhileActive = True`:
  the state files have honest data. No enhancement needed yet.
- If most show `Status = COMPLETED` and `CapturedWhileActive = False`:
  the state files have post-force-close data. Items that were genuinely PENDING
  during the ACTIVE window now show as UNDECIDED (idNowAutoApproved). The
  reviewer engagement data shows U instead of M for those reviewers.

```powershell
# 2. Check how many UNDECIDED vs PENDING items are in the state file
$state = Get-Content Audit/metrics/entitlement-state.jsonl | 
    Where-Object { -not $_.Contains('"_meta"') } |
    ForEach-Object { $_ | ConvertFrom-Json }
$state | Group-Object currentDecision | Select-Object Name, Count | Sort-Object Count -Descending
```

**If UNDECIDED count is very high and PENDING is near zero:** this suggests the
cache only had COMPLETED captures. The ACTIVE-capture honest data was overwritten
before the state update ran. This is the scenario where status-aware processing
would help.

### Known Design Gap: Status-Aware Processing

**Current behavior:** `processedInstances` tracks CampaignId only. The first
version of a campaign in the cache (ACTIVE or COMPLETED) is what gets persisted.
If the cache was overwritten with COMPLETED data before the state update ran,
the honest ACTIVE-capture data is lost.

**Planned enhancement (post-integration-test):** Track `processedInstances` as
`{ campId: "ACTIVE" }` instead of `{ campId: true }`. Then:
- ACTIVE processed, COMPLETED appears later: reprocess (status upgrade)
- COMPLETED processed, ACTIVE appears: skip (stale)
- Add `capturedStatus` field to each entitlement/reviewer record
- V8 can display which capture the data came from

**Workaround until enhancement:** Run `Update-SPStateFiles.ps1` while campaigns
are still ACTIVE (before force-close). The processedInstances set will record
the CampaignId, and when the COMPLETED version overwrites the cache later, the
state update will skip it (the honest ACTIVE data is preserved).

**Upstream consideration:** The richest fix is in the cache layer -- V4e or the
cache service should preserve ACTIVE-captured items separately from
COMPLETED-captured items, the same way V4c's daily-metrics.jsonl protects
ACTIVE records from COMPLETED overwrites. This is a broader change that
benefits all downstream consumers.

---

## PS 5.1 vs PS 7 Checklist

If testing on Windows PowerShell 5.1 Desktop specifically:

- [ ] `ConvertFrom-Json` returns PSCustomObject (not hashtable) -- `ConvertFrom-PSOToHashtable` handles this
- [ ] ISO 8601 date strings are NOT auto-converted to DateTime -- they stay as strings
- [ ] `[ordered]@{}` creates `OrderedDictionary` -- `.ContainsKey()` works, not `.Contains()`
- [ ] `ConvertTo-Json -Depth 6` handles nested series/weeklyStats correctly
- [ ] No ternary operators anywhere in the modules
- [ ] `$var:` in strings parsed as scope prefix -- verify no `${var}:` patterns needed

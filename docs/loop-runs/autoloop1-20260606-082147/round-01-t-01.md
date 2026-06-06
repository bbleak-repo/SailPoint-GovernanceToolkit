# T-01 -- Fix the 3 latent bug-hunt items: rolling-trend window math + anchor (toolkit) and changelog date-filter culture (mock)

## Read
- `Modules/SP.Audit/SP.AuditReportHtml.psm1` -- `Export-SPRollingTrendHtml` (param doc 10620-10673, anchor else-branch 10784-10797, window loop 10803-10827, fold predicates 10831/10849, label 10951, HTML tail/Anchor line 10999).
- `Tests/SP.RollingTrendHtml.Tests.ps1` -- full file (BeforeAll anchor derivation 34-37, existing bucket/remove assertions, -AnchorDate determinism test).
- `Tests/SP.ManagerCert30DaySim.Tests.ps1` -- `Import-MC30Fixture` anchor rule (66-74) to mirror.
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/MembershipChangelogHandlers.ps1` -- from/to/item-date casts (79/83/90), comment (31).

## Did
- **(a) Window math (toolkit):** changed `$cutoffDay = $anchorDay.AddDays(-$W).Date` to `$anchorDay.AddDays(-($W - 1)).Date` so a W-day window yields exactly W contiguous buckets ending at anchorDay (was W+1). Loop + both fold predicates key off `$cutoffDay`, so they auto-stay consistent; the `$($dayList.Count) calendar days` label and the `Window: cutoff to anchor` string auto-correct. No hardcoded W+1 elsewhere.
- **(b) Anchor (toolkit):** rewrote the default (`-AnchorDate` not supplied) branch to prefer the max DAILY-campaign day (`$maxCampDay` over `$campRows.Day`, which are built only from `$campaigns` = DailyCampaigns) when campaigns exist; fall back to changelog max (preserved `_RtParseDateUtc` loop over `$events`) only when no campaigns, then `Get-Date` last resort. Eliminates the trailing empty 06-06 bucket; newest bucket = real daily campaign (06-05). Explicit `-AnchorDate` branch and `$anchorDay = $anchor.Date` unchanged. Updated the AnchorDate param doc-comment to describe the new rule (doc-only).
- **(c) Culture-invariant parse (mock):** replaced bare `[datetime]$fromRaw` / `[datetime]$toRaw` / `[datetime]$_.date` casts with `[datetime]::Parse(..., InvariantCulture, DateTimeStyles::RoundtripKind)` (item date wrapped `[string]$_.date`), preserving the surrounding try/catch -> exclude-on-unparseable behaviour and missing-key tolerance. Updated the stale `[datetime]$_.date` comment (doc-only). offset/limit/clauses/Invoke-MockPagination unchanged.
- **Tests (toolkit, additive):** added 3 It-blocks ('7-day window yields exactly 7 day-buckets', '30-day window yields exactly 30 day-buckets', 'newest 30-day bucket corresponds to a real daily campaign'). Minimal change: rewrote the `$script:Anchor` BeforeAll derivation to mirror the function's new rule (max daily-campaign created when Daily.Count>0, else changelog max) so the data-derived `$expected` remove count at 108-117 recomputes against 06-05 (now 39) and the `-AnchorDate` determinism test still passes. This was the ONLY existing assertion encoding the old changelog-max anchor; the count was data-derived (not a literal). Docstring '41 removes in 30d' -> '39 removes in 30d' (doc-only).

## Files
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Modules\SP.Audit\SP.AuditReportHtml.psm1`
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\Tests\SP.RollingTrendHtml.Tests.ps1`
- `C:\temp\coding\SailPoint\SailPoint-GovernanceToolkit\docs\loop-runs\autoloop1-20260606-082147\round-01-t-01.md`
- `C:\temp\Coding\API-mockserver\Profiles\SailPoint-ISC\Handlers\MembershipChangelogHandlers.ps1` (committed in mock repo)

## Verification
All headless. Windows PowerShell 5.1 from toolkit root.

```
> Invoke-Pester .\Tests\SP.RollingTrendHtml.Tests.ps1 -Output Detailed
Tests Passed: 19, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
  [+] a 7-day window yields exactly 7 day-buckets
  [+] a 30-day window yields exactly 30 day-buckets
  [+] the newest 30-day bucket corresponds to a real daily campaign (no trailing empty bucket)
  [+] priv-scoped 30-day Removed matches the fixture-derived expected count

> Invoke-Pester .\Tests\SP.ManagerCert30DaySim.Tests.ps1 -Output Detailed
Tests Passed: 55, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0

> direct default-anchor proof (Export-SPRollingTrendHtml, no -AnchorDate)
win7=7
win30=30
newest30Day=2026-06-05
newest30CampaignCount=1
anchorLine matches 2026-06-05=True

> [datetime]::Parse('2026-06-05T12:16:28Z',InvariantCulture,RoundtripKind).ToString('o')
2026-06-05T12:16:28.0000000Z

> Grep '\[datetime\]\$' MembershipChangelogHandlers.ps1
(only a comment match remained pre-edit at line 31; predicate casts gone; comment then updated)

> PSParser::Tokenize(MembershipChangelogHandlers.ps1)
parse-ok
```

## Commit
- toolkit: 6f218b7 -- fix(audit): rolling-trend W-day window = W buckets + anchor to daily-campaign signal
- mock:    0029cb3 -- fix(changelog): culture-invariant date parse in /v3/membership-changelog filter

## Status
DONE

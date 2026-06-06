# T-01 -- Extend mock generator: 100 users + 200 groups + ~10 privileged roles + 30-day membership changelog + daily manager campaigns

## Read
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` (full): param block (l.39-49), shared helpers Format-Id/Get-RandomName/Get-IsoTimestamp/Get-UnixTimestamp (l.94-124), `New-SailPointData` (identities l.155-274, baseline 3 campaigns l.276-311, certifications + accessReviewItems l.313-391, account-activities l.399-436, assemble l.452-463), the Main dispatcher (l.1341-1345) and JSON write block (l.1347-1401).
- Confirmed mock repo branch = `feature/manager-cert-30day-sim`.

## Did (purely ADDITIVE; mock repo only; single file)
- Added top-level `[int]$Seed = 20260606` script param; threaded it to the dispatcher: `New-SailPointData -IdentityCount $Scale -Seed $Seed`.
- `New-SailPointData` now takes `[int]$Seed` and creates one `$rng = [System.Random]::new($Seed)`; ALL churn/decision/membership randomness goes through `$rng`.
- (a) Identities scaled to 100 with real multi-level tiers: 1 VP (band A) -> ~4 directors (band B) -> line managers (band C) -> ICs (band E). Added `attributes.leadershipBand`; refined `manager` to a real IC->manager->director->VP chain (depth >=3). Existing fields/shape preserved; existing flat-pool logic kept and then refined.
- (b) New top-level `entitlements`: 200 groups (`ent-001`..`ent-200`), each ENTITLEMENT on src-ad-001 with `attributes.privileged` and a settled `members` array. Fixed privileged subset of exactly 10 (`attributes.privileged=$true`). New top-level `trackedPrivilegedRoles`: 10 stable ids/names each with `responsibleManagerId`/`responsibleManagerName` (real manager-tier identity).
- (c) Churn: 4 simulated weeks (days 28..1), 10-25% per-week ADD+REMOVE per group via `$rng`; running roster tracked so final `members` reflect net state; <=3 identities flagged leaver (cloudLifecycleState='inactive', base 100 preserved).
- (d) New top-level `membershipChangelog` (date/groupId/groupName/identityId/operation ADD|REMOVE). Each churn event ALSO appends to the EXISTING `$accountActivities` (GRANT_ACCESS/ADD, REVOKE_ACCESS/REMOVE) with a REAL ISO `created` (Get-IsoTimestamp -DaysAgo N, parseable by Get-SPDeltaGrantEvents) and `requestedFor.id`. Baseline ~5 activities preserved.
- (e) 30 daily MANAGER campaigns appended to `$campaigns` (`camp-daily-priv-01`..`-30`), each covering the SAME 10 tracked privileged roles; per role a certification with `reviewer` = responsible manager + access-review-items carrying APPROVE/REVOKE (mostly APPROVE via `$rng`); each daily campaign carries a new `managerAttestation` array (managerId/managerName/status attested|overdue|missed/decisionsMade/decisionsTotal). Baseline 3 campaigns preserved.
- Assemble: added `entitlements`, `trackedPrivilegedRoles`, `membershipChangelog` AFTER existing keys; updated Write-Host summary additively.
- PS 5.1 compliance: replaced an accidental `? :` ternary with `if/else`; used a script-block helper with passed-in ArrayLists + a single-element counter array (PS 5.1 nested fns don't see enclosing locals via `$script:`); `.Contains()` on ordered dict; ArrayList + `[void].Add()` + `.ToArray()`.

## Files
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1`
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-01-t-01.md`

## Verification (real output)
**(1) Branch**
```
git -C C:/temp/Coding/API-mockserver rev-parse --abbrev-ref HEAD
-> feature/manager-cert-30day-sim
```
**(2) Parse**
```
[Parser]::ParseFile(...New-BulkSeedData.ps1...) -> ParseErrors=0
```
**(3) Generate to temp (twice, default seed)** -- both succeeded:
```
Generated SailPoint-ISC seed data:
  Identities:     100
  Accounts:       130
  Entitlements:   200
  Priv Roles:     10
  Changelog Evts: 1366
  Daily Campaigns:30
```
**(4) Assertions on temp-a (ConvertFrom-Json)**
```
identities=100
entitlements=200
privileged=10
trackedRoles=10
changelogOps=ADD,REMOVE
changelogDistinctDates=29        (>=25 required)
managerCampaigns=31              (30 daily + camp-completed-001; >=30 required)
dailyCertsWithReviewer=300       (30 days x 10 roles, all have reviewer.id)
actTypes=ACCOUNT_ATTRIBUTE_UPDATE,CLOUD_AUTOMATED,GRANT_ACCESS,IDENTITY_REFRESH,REVOKE_ACCESS
actAdd=786  actRemove=585
actDistinctDates=29              (>=~20 required)
baseActive=True baseCompleted=True baseStaged=True
hasManagerAttestation=30
bandsPresent=A,B,C,E
hashMatch=False  (timestamps anchor to UtcNow by design)
```
**(5) Determinism (structural counts a vs b -- identical)**
```
identities   100 vs 100
entitlements 200 vs 200
campaigns    33 vs 33
certs        315 vs 315
activities   1371 vs 1371
changelog    1366 vs 1366
totalMembers 663 vs 663
```
Byte-hash differs ONLY because the pre-existing `Get-IsoTimestamp` helper anchors to `[datetime]::UtcNow`; structural determinism (the hard requirement) is fully met. Temp files cleaned up. Live `State/SailPointData.json` NOT touched (that is T-03). Mock not started; no GUI.

## Commit
- Mock repo (C:/temp/Coding/API-mockserver): `79a0be5` -- feat(seed): 30-day manager-cert sim dataset (100 users/200 groups/10 priv roles/changelog/daily campaigns)
- Toolkit repo: this record file committed separately on `feature/manager-cert-30day-sim`.

## Status
DONE

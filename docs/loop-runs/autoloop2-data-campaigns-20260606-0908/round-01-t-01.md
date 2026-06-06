# T-01 -- Mock data enrichment: more sources + multi-type/historical campaigns (deterministic)

**Read**

- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` -- `New-SailPointData`:
  - `$sources` literal array (lines 142-159): 2 existing rows `src-ad-001` (Active Directory - Direct, owner id-gen-001) and `src-entra-001` (Azure Active Directory, owner id-gen-002), each shaped id/name/type/description/owner([ordered]@{type;id;name=''})/connectorAttributes([ordered]@{}).
  - `$campaigns` literal array (lines 334-368): 3 existing rows `camp-active-001` (SOURCE_OWNER, ACTIVE), `camp-completed-001` (MANAGER, COMPLETED), `camp-staged-001` (SOURCE_OWNER, STAGED).
  - Confirmed the 30-day churn loop / `$rng.Next` draws / `$privIndexes` / `$campaignList` flow are independent of the two literal arrays; the post-loop reassignments index `$campaigns[0..2]`, so appending after row 3 keeps those valid. Daily campaigns (`camp-daily-priv-NN`) are merged in separately.
- Auth: `Tests/Integration/Test-SailPointWorkflow.ps1` -- mock requires an OAuth bearer token from `POST /oauth/token`; unauthenticated `/v3/*` returns 401.
- `Start-MockServer.ps1` -- by default restores from `State/` checkpoint and does NOT reload seed-data; `-Fresh` forces seed reload from disk.

**Did**

- ADDITIVE edit of `New-SailPointData`, two literal arrays only -- no rng draws added, no ids renamed, no existing rows altered (byte-identical):
  - `$sources`: appended 4 rows after `src-entra-001`:
    - `src-workday-001` (Workday, owner id-gen-003) -- connected HR/authoritative
    - `src-jdbc-001` (JDBC, owner id-gen-004) -- connected database
    - `src-pepplus-001` (DelimitedFile, owner id-gen-005, connectorAttributes connectorClass='sailpoint.connector.DelimitedFileConnector') -- disconnected flat-file
    - `src-debtnext-001` (DelimitedFile, owner id-gen-006, same connectorClass) -- disconnected flat-file
  - `$campaigns`: appended 5 rows after `camp-staged-001` (literals only, all with totalCertifications/completedCertifications):
    - `camp-search-001` (SEARCH, COMPLETED, DaysAgo 75, 4/4) -- the previously-missing type
    - `camp-srcowner-hist-001` (SOURCE_OWNER, COMPLETED, DaysAgo 200, 6/6)
    - `camp-mgr-hist-001` (MANAGER, COMPLETED, DaysAgo 160, 5/5)
    - `camp-search-hist-001` (SEARCH, COMPLETED, DaysAgo 250, 3/3)
    - `camp-srcowner-hist-002` (SOURCE_OWNER, COMPLETED, DaysAgo 300, 4/4)
- Regenerated `seed-data-bulk.json` and activated it over `Profiles/SailPoint-ISC/seed-data.json` via `-Activate` (backup `seed-data.original.json` already present from a prior activate).
- Restarted the mock fresh NON-elevated with `-Fresh` (the running instance had restored a stale checkpoint that predated this seed; `-Fresh` forces the new seed from disk). Mock left running clean on http://localhost:8080, no error-injection/scenario set.

**Files**

- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` (EDIT -- two literal arrays in New-SailPointData)
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/seed-data.json` (REGENERATED artifact, committed)
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/docs/loop-runs/autoloop2-data-campaigns-20260606-0908/round-01-t-01.md` (this record, toolkit repo)

**Verification**

1) Regenerate + activate:
```
powershell -NoProfile -File .\Scripts\New-BulkSeedData.ps1 -Profile SailPoint-ISC -Scale 100 -Activate
```
Real output (tail):
```
Generated SailPoint-ISC seed data:
  Identities:     100
  Accounts:       130
  Entitlements:   200
  Daily Campaigns:30
  Campaigns:      3        # baseline-count message (pre daily-merge); served total = 38
  Certifications: 315
  Backed up original: C:\temp\Coding\API-mockserver\Profiles\SailPoint-ISC\seed-data.original.json
  Activated:      C:\temp\Coding\API-mockserver\Profiles\SailPoint-ISC\seed-data.json
Done.
```

2) Structure assertions on activated JSON (full spec block, PS 5.1):
```
OK structure: sources=6 campaigns=38 periods=8
```
(sources grew to 6 incl. src-ad-001/src-entra-001 + DelimitedFile + src-workday-001/src-jdbc-001; campaign types SOURCE_OWNER/MANAGER/SEARCH all present; 8 distinct created periods >= 3; camp-active-001/camp-completed-001/camp-staged-001 + camp-daily-priv-01..30 all present.)

3) Served-row check (mock restarted fresh; OAuth bearer obtained from /oauth/token):
```
OK served: sources=6 campaigns=38
```
(served source count == file count; >=1 DelimitedFile source served; served campaign types include SOURCE_OWNER, MANAGER, SEARCH. Unauthenticated probe correctly returned 401 -- auth enforcement intact.)

**Commit**

- mock-api repo (`C:/temp/Coding/API-mockserver`, branch feature/manager-cert-30day-sim): `c3d05cf` -- feat(seed): enrich mock -- add connected + DelimitedFile sources and SOURCE_OWNER/MANAGER/SEARCH historical campaigns (T-01)
- toolkit repo: this record committed separately (see structured result commitHash).

**Status**

DONE

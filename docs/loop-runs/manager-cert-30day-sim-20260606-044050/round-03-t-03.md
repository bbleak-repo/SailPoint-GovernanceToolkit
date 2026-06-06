# T-03 -- Regenerate the coherent 30-day SailPointData.json and load it into the non-elevated mock

## Read
- `C:/temp/Coding/API-mockserver/State/SailPointData.json` (prior STALE state -- verified: identities=82, entitlements=10, campaigns=16, trackedPriv=0, changelog=0).
- `C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` -- confirmed it accepts `-Profile`, `-Scale`, `-Seed`, `-OutputPath`.
- `C:/temp/Coding/API-mockserver/Config/mock-settings.json` -- OAuth `AcceptAnyCredentials=true`, `TokenExpirySeconds=749`.
- `C:/temp/Coding/API-mockserver/Profiles/SailPoint-ISC/Handlers/OAuthHandler.ps1` -- auth requires a token minted via `POST /oauth/token` (token must exist in the `MockTokens` Pode state); a dummy `Bearer mock` is rejected 401. So smoke tests mint a real `client_credentials` token first.
- `C:/temp/Coding/API-mockserver/.gitignore` -- lists `State/`, so the State file and in-repo backup must be force-added.
- `Start-MockServer.ps1` / `Stop-MockServer.ps1` -- standard repo lifecycle scripts; restore from `State/SailPointData.json` when present.

## Did
- Data-only regeneration in the MOCK repo. NO mock CODE/endpoint/test changes. NO toolkit code changes (only the journal record below).
- A) Backed up prior `State/SailPointData.json` to `State/_backups/SailPointData.20260606-051610.json` (created `State/_backups`).
- B) Stopped the running mock via `Stop-MockServer.ps1`; polled `GET /health` until DOWN (1 poll) so the dying process could not re-checkpoint over the new file.
- C) Ran the extended generator writing directly onto the State file: `powershell -NoProfile -File Scripts/New-BulkSeedData.ps1 -Profile SailPoint-ISC -Scale 100 -Seed 20260606 -OutputPath State/SailPointData.json`.
- E) Started the mock FRESH + NON-ELEVATED in the background via `powershell.exe -NoProfile -File Start-MockServer.ps1` (NO `-Fresh`, so it restores the NEW State); polled `GET /health` until ok (6 polls).
- F) HTTP-smoked the four required endpoints + a date-windowed changelog query.
- G) Force-added and committed the regenerated State file + in-repo backup to the MOCK repo on `feature/manager-cert-30day-sim`.

## Files
- `C:/temp/Coding/API-mockserver/State/SailPointData.json` (REGENERATED -- 6.22 MB; 100 identities, 200 entitlements, 10 privileged roles, 1366 changelog events, 33 campaigns incl. 30 daily MANAGER campaigns).
- `C:/temp/Coding/API-mockserver/State/_backups/SailPointData.20260606-051610.json` (CREATED -- timestamped in-repo backup of prior state, 519101 bytes).
- `C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit/docs/loop-runs/manager-cert-30day-sim-20260606-044050/round-03-t-03.md` (this record, in the TOOLKIT repo).

## Verification

### Generator output
```
Generated SailPoint-ISC seed data:
  Identities:     100
  Accounts:       130
  Entitlements:   200
  Priv Roles:     10
  Changelog Evts: 1366
  Daily Campaigns:30
  Campaigns:      3
  Certifications: 315
  Review Items:   1575
  Activities:     5
  Output:         C:\temp\Coding\API-mockserver\State\SailPointData.json
  File size:      6.22 MB
```

### Static parse of new State file
```
identities=100
entitlements=200
privFlagged=10
trackedPriv=10
changelog=1366
changelogOps=ADD,REMOVE
campaigns=33
dailyMgrCamps=30
activityTypes=ACCOUNT_ATTRIBUTE_UPDATE,CLOUD_AUTOMATED,GRANT_ACCESS,IDENTITY_REFRESH,REVOKE_ACCESS
```
ASSERTS PASS: identities=100; entitlements>=200; privFlagged>=10; trackedPriv>=10; changelog>0 w/ ADD+REMOVE; campaigns>=33; dailyMgrCamps>=30; activityTypes contains GRANT_ACCESS & REVOKE_ACCESS.

### Backup exists
```
Name                               Length
----                               ------
SailPointData.20260606-051610.json 519101
```

### Mock stopped (between stop and write)
```
DOWN - OK to write State (after 1 polls)
```

### Mock up after fresh start (restored new State)
```
UP after 6 polls: {"port":8080,"status":"ok","profiles":["SailPoint-ISC","Okta","CyberArk-PVWA","MicrosoftGraph-Entra"],"uptime":"2026-06-06T05:17:01Z"}
```

### HTTP smoke (token minted via POST /oauth/token client_credentials)
```
TOKEN minted: mock-token-de9437c97...
SMOKE1 identities=100
SMOKE2 dailyMgr=30
SMOKE3 types=ACCOUNT_ATTRIBUTE_UPDATE,CLOUD_AUTOMATED,GRANT_ACCESS,IDENTITY_REFRESH,REVOKE_ACCESS
SMOKE4 ops=ADD,REMOVE count=250
```
Note: `Bearer mock` dummy is rejected 401 by AuthMiddleware (token must be minted); minted a real `client_credentials` token first. The four smokes then pass: identities=100; dailyMgr=30; activity types contain GRANT_ACCESS & REVOKE_ACCESS; changelog ops contain ADD & REMOVE.

### Date-windowed changelog filter (proves filtering, not just limit cap)
```
FULL count=1366
WINDOWED(3d) count=170
SUBSET=True
```
The full changelog (limit=2000) returns 1366; a `from-date` of -3 days returns 170 -- a strict subset, confirming the T-02 date-window filter works. (An earlier -7d query at limit=250 returned 250 because of the limit cap, hence the high-limit re-check.)

## Commit
- Mock repo (`C:/temp/Coding/API-mockserver`, branch feature/manager-cert-30day-sim): `9fa7efe` -- `test(seed): regenerate coherent 30-day State/SailPointData.json + backup prior state` (2 files changed, 97465 insertions: State/SailPointData.json + State/_backups/SailPointData.20260606-051610.json, both force-added since State/ is gitignored).
- Toolkit repo: this record committed separately on branch feature/manager-cert-30day-sim. Neither repo pushed; master/main untouched.

## Status
DONE

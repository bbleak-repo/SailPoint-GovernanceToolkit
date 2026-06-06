# Round 06 -- FIX: regenerate STALE SERVED MOCK STATE (manager-accountability)

Role: INNER (fix). Branch: feature/manager-cert-30day-sim (both repos).

## Bug fixed (from the hunt)

STALE SERVED MOCK STATE -- the mock seed generator
`C:/temp/Coding/API-mockserver/Scripts/New-BulkSeedData.ps1` was extended at
commit `848c12a` to emit the deterministic OVERDUE/MISSED streak, org-chain
escalation (`daysOverdue`/`escalationLevel`/`escalatedTo`/`escalatedToName`) and
the delegated reassignment ("Delegated up-chain ...") -- the heart of the
"managers kept accountable" use case. But the SERVED state file
`C:/temp/Coding/API-mockserver/State/SailPointData.json` had last been committed
at `b06c1dc` (T-07), which PREDATES `848c12a`, so the live mock served daily
attestation campaigns with NONE of the accountability fields. The round-02
journal claimed it had been regenerated; git history and grep contradicted that.

## Did

1. Stopped the running mock server. ROOT-CAUSE refinement: the mock
   (`Start-MockServer.ps1`, PID 20056, listening on :8080) was LIVE and
   persisting its in-memory (stale, BOM-prefixed) state back to
   `State/SailPointData.json`, clobbering a fresh regeneration. The first regen
   was silently overwritten by the live mock. This is exactly why the fix note
   says "then restart the mock". Stopped PID 20056; confirmed port 8080 free.

2. Re-ran the generator into the served state path (with the mock stopped so no
   live writer could clobber it):

       New-BulkSeedData.ps1 -Profile SailPoint-ISC -Scale 100 -Seed 20260606 \
         -OutputPath C:/temp/Coding/API-mockserver/State/SailPointData.json

3. Left the mock STOPPED (clean). A human / the next live step starts it fresh
   so it loads the corrected state. Headless verification only; no live session
   left running.

## Files

- `C:/temp/Coding/API-mockserver/State/SailPointData.json` (MOCK repo, regenerated; the only changed file)

No toolkit CODE changed and no mock CODE changed -- this is a pure
data-regeneration fix. Fully additive: no endpoint, test, export, or behaviour
removed or rewired.

## Verification (real output)

### Served state now matches the generator + the toolkit fixture

Before (committed HEAD = b06c1dc):

    HEAD escalationLevel: 0
    WORKING escalationLevel: 300

Regenerated content (single shell, no live writer):

    BOM present: False
    escalationLevel: 300  daysOverdue: 300  escalatedTo: 300  Delegated up-chain: 1  camp-daily-priv-: 2070
    Parse OK. identities=100 campaigns=33 changelog=1366

`git -C C:/temp/Coding/API-mockserver status --short`:

    M State/SailPointData.json

Structural parity with the toolkit fixture
`Tests/TestData/ManagerCert30DaySim.State.json` (the fixture the Pester suite
loads): identical top-level keys; identities=100, campaigns=33, changelog=1366,
entitlements=200, privRoles=10; daily-priv campaigns with daysOverdue>0 = 8 and
escalationLevel>0 = 8 in BOTH; delegation note present. The accountability data
lives at `campaign.managerAttestation[].{daysOverdue,escalationLevel,escalatedTo,escalatedToName}`.

### Affected toolkit tests (re-run)

    Invoke-Pester SP.ManagerCert30DaySim.Tests.ps1, SP.RollingTrendHtml.Tests.ps1, SP.ApiResilience.Tests.ps1
    Tests Passed: 93, Failed: 0, Skipped: 0

### Full toolkit suite (Invoke-Pester .\Tests)

    RESULT: Passed=1255 Failed=0 Skipped=0 Total=1255
    (also confirmed by a second independent run: "Tests Passed: 1255, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0", Tests completed in 691.41s)

## Commit

Mock repo (C:/temp/Coding/API-mockserver), branch feature/manager-cert-30day-sim:

    fe40fcf fix(mock): regenerate served state with manager-accountability fields (overdue/escalation/delegation)
    (1 file changed, 6528 insertions(+), 5315 deletions(-) -- State/SailPointData.json only)

Toolkit repo (C:/temp/coding/SailPoint/SailPoint-GovernanceToolkit): this record
file committed separately (see below). No toolkit code/test changed.

## Status

DONE -- served mock state now carries the manager-accountability signal
(overdue/missed/escalation/delegation) and is byte-aligned with the generator
and the toolkit fixture. Mock left stopped/clean (error injection / scenarios
untouched, were already normal). Full suite green. NOT pushed; master/main
untouched.

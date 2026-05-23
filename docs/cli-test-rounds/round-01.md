# Round 1 -- T-01: Test-SPConnectivity.ps1

**Date:** 2026-05-23
**Battery:** T-01
**Script:** Scripts/Test-SPConnectivity.ps1

---

## Test Results

| Test ID | Command | Exit Code | Result | Notes |
|---------|---------|-----------|--------|-------|
| TC-01-01 | `.\Scripts\Test-SPConnectivity.ps1` | 0 | PASS | All 3 steps passed |

## Detail: TC-01-01

**Command:**
```powershell
pwsh -NoProfile -Command "& ./Scripts/Test-SPConnectivity.ps1"
```

**Output:**
```
SailPoint ISC Governance Toolkit - Connectivity Test
  ========================================================
  CorrelationID: 0eaa7695-6515-40a1-82a5-1bf51baed13e

  [PASS] Step 1: Load and validate settings.json (43ms)
         Environment: MOCK-SERVER | Mode: ConfigFile
  [PASS] Step 2: Acquire OAuth 2.0 bearer token (57ms)
         Mode: ConfigFile | Expires: 05/23/2026 15:46:30
  [PASS] Step 3: GET /v3/campaigns?limit=1 (live API call) (33ms)
         API responded successfully. Items returned: 1

  ========================================================
  RESULT: All connectivity checks passed.
```

**Validation:**
- Exit code: 0 (expected 0)
- OAuth token acquired successfully via ConfigFile mode
- API call to /v3/campaigns returned 1 item
- Environment correctly shows MOCK-SERVER
- No authentication errors

## Bugs Found

None.

## Screenshots

None required for T-01 (no HTML output).

## Summary

T-01 passed cleanly on first attempt. The connectivity test validates the full auth stack
(config load -> OAuth token -> API call) against the Pode mock server. All three steps
completed without errors.

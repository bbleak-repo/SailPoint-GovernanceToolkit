# Disconnected App Enterprise Features -- Backlog (DA-11 to DA-20)

**Created:** 2026-05-28
**Prereqs:** Disconnected App Kit D-01 to D-10 complete
**Purpose:** Scale from single-app to 20+ apps in production

---

## How to Use This File

Agent loop: `DA-11 -> DA-12 -> DA-13 -> DA-14 -> DA-15 -> DA-16 -> DA-17 -> DA-18 -> DA-19 -> DA-20`

---

## Context

The D-01 to D-10 kit handles one app at a time via CLI parameters. For 20+ disconnected
apps, we need config-driven multi-app support, batch processing with error isolation,
safety guards (the `AccountDeletionThresholdPct` config value exists but is NOT implemented),
delivery monitoring, cross-app analytics, and consolidated reporting.

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| DA-11 | App Registry (config-driven multi-app) | none | DONE |
| DA-12 | App Registration CLI | DA-11 | DONE |
| DA-13 | Account Deletion Threshold Protection | none | DONE |
| DA-14 | Batch Orchestrator | DA-11, DA-13 | DONE |
| DA-15 | File Delivery Monitor | DA-11 | DONE |
| DA-16 | Cross-App Identity Risk Report | DA-11 | DONE |
| DA-17 | Unified Entitlement Catalog | DA-11 | DONE |
| DA-18 | Batch Summary HTML Report | DA-14 | DONE |
| DA-19 | SLA Tracking + Delivery History | DA-15 | PENDING |
| DA-20 | Pester Tests | DA-19 | PENDING |

---

## DA-11: App Registry (Config-Driven Multi-App)

- **Status:** `DONE`
- **Commit:** DA-11
- **Depends On:** none

**Description:**
Add an `Applications` array to the `DisconnectedApps` config section. Each entry defines
one disconnected app with its file paths, correlation settings, and campaign preferences.

Also create `Initialize-SPDisconnectedAppDirectories` to scaffold the directory structure
for all registered apps (Imports/, Snapshots/, Reports/ per app).

**Config structure:**
```json
"DisconnectedApps": {
    "ImportBasePath": ".\\DisconnectedApps\\Imports",
    "SnapshotPath": ".\\DisconnectedApps\\Snapshots",
    "ReportPath": ".\\DisconnectedApps\\Reports",
    "SnapshotRetentionDays": 30,
    "DefaultCampaignNamePrefix": "Disconnected App Cert",
    "DefaultDeadlineDays": 2,
    "DefaultCorrelationAttribute": "e-mail",
    "AccountDeletionThresholdPct": 20,
    "RequiredAccountColumns": ["id","name","givenName","familyName","e-mail","groups","IIQDisabled"],
    "RequiredEntitlementColumns": ["id","name","displayName","description"],
    "Applications": [
        {
            "Name": "PEP-Plus",
            "AccountFilePath": "\\\\fileserver\\imports\\PEP-Plus\\accounts.csv",
            "EntitlementFilePath": "\\\\fileserver\\imports\\PEP-Plus\\entitlements.csv",
            "ISCSourceId": "",
            "CorrelationAttribute": "e-mail",
            "CampaignNamePrefix": "PEP+ Cert",
            "DeadlineDays": 2,
            "SlaDays": 1,
            "Enabled": true
        }
    ]
}
```

**Files to Modify:**
- `Config/settings.json` -- add Applications array with 2 example entries
- `Modules/SP.Core/SP.Config.psm1` -- add Applications defaults
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppRunner.psm1` -- add `Get-SPRegisteredApps`
  and `Initialize-SPDisconnectedAppDirectories` functions

**Function signatures:**
```powershell
function Get-SPRegisteredApps {
    # Returns array of app config objects from settings.json
    # Filters to Enabled=true only
    # Merges per-app settings with defaults (app-level overrides global defaults)
}

function Initialize-SPDisconnectedAppDirectories {
    param([Parameter()][string[]]$AppNames)
    # Creates Imports/{AppName}/, Snapshots/{AppName}/, Reports/{AppName}/ for each app
}
```

**Acceptance Criteria:**
- `Get-SPRegisteredApps` returns only enabled apps
- Per-app settings override global defaults (e.g., app-specific DeadlineDays)
- Missing per-app fields fall back to global defaults
- Directory initialization creates all required folders

---

## DA-12: App Registration CLI

- **Status:** `DONE`
- **Commit:** DA-12
- **Depends On:** DA-11

**Description:**
New CLI script `Scripts/Invoke-SPDisconnectedAppRegistry.ps1` with subcommands:
- `Register` -- add a new app to the config
- `Unregister` -- remove an app from the config
- `List` -- show all registered apps with status
- `Test` -- validate file paths and run CSV validation for one app

**File to Create:** `Scripts/Invoke-SPDisconnectedAppRegistry.ps1`

**Parameters:**
```powershell
-Action Register|Unregister|List|Test
-AppName "PEP-Plus"
-AccountFilePath "\\fileserver\imports\PEP-Plus\accounts.csv"
-EntitlementFilePath "..." (optional)
-ISCSourceId "2c918..." (optional)
-CorrelationAttribute "e-mail" (optional, defaults to global)
-CampaignNamePrefix "PEP+ Cert" (optional)
-DeadlineDays 2 (optional)
-SlaDays 1 (optional)
-ConfigPath, -OutputMode
```

**Behaviors:**
- `Register`: validates paths exist, adds to Applications array, creates directories
- `Unregister`: removes from Applications array (does NOT delete snapshots/reports)
- `List`: table output -- Name, Enabled, AccountPath, LastProcessed, FileStatus
- `Test`: runs CSV validator on the app's current files, reports pass/fail

**Acceptance Criteria:**
- Register adds app to settings.json Applications array
- Duplicate app name detection (error if already registered)
- List shows clean table output
- Test runs full validation without creating campaigns

---

## DA-13: Account Deletion Threshold Protection

- **Status:** `DONE`
- **Commit:** DA-13
- **Depends On:** none

**Description:**
Implement the `AccountDeletionThresholdPct` config value that EXISTS but is NOT USED.
Before processing the delta, check if the percentage of removed accounts exceeds the
threshold. If so, abort processing for that app with a clear error.

This prevents a bad file (empty, partial export, wrong app's data) from triggering
mass-removal campaigns.

**Files to Modify:**
- `Modules/SP.DisconnectedApps/SP.DisconnectedAppDelta.psm1` -- add threshold check
  in `Compare-SPDisconnectedAppFiles` or new wrapper function

**New function:** `Test-SPDisconnectedAppDeletionThreshold`
```powershell
function Test-SPDisconnectedAppDeletionThreshold {
    param(
        [Parameter(Mandatory)][hashtable]$DeltaSummary,  # from Compare-SPDisconnectedAppFiles
        [Parameter()][int]$ThresholdPct = 20
    )
    # If Removed / TotalPrevious > ThresholdPct/100, return blocked=true
    # Exception: first run (no previous file) is always allowed
    # Exception: TotalPrevious < 5 accounts -- too small for percentage to be meaningful
}
```

**Returns:**
```powershell
@{
    Allowed = $bool
    RemovedPct = [double]
    RemovedCount = [int]
    TotalPrevious = [int]
    ThresholdPct = [int]
    Reason = 'OK' | 'ThresholdExceeded' | 'FirstRun' | 'TooFewAccounts'
}
```

**Wire into:** `Invoke-SPDisconnectedAppCert.ps1` -- check threshold AFTER delta detection
but BEFORE identity resolution and campaign creation.

**Acceptance Criteria:**
- File with 50% accounts removed (exceeds 20% threshold) blocks processing
- First run (no previous file) always allowed
- Source with 3 accounts (below minimum) always allowed
- Clear error message: "Threshold exceeded: 45% accounts removed (threshold: 20%). Aborting."

---

## DA-14: Batch Orchestrator

- **Status:** `DONE`
- **Commit:** DA-14
- **Depends On:** DA-11, DA-13

**Description:**
New CLI script `Scripts/Invoke-SPDisconnectedAppBatch.ps1` that processes all registered
apps in sequence, isolating errors per-app so one failure doesn't stop the batch.

**File to Create:** `Scripts/Invoke-SPDisconnectedAppBatch.ps1`

**Parameters:**
```powershell
-AppNames @('PEP-Plus','DebtNext')  # Optional filter; omit = all enabled apps
-ConfigPath, -Token, -TokenExpiryMinutes
-WhatIf, -OutputMode (Console|JSON|Both)
```

**Flow:**
```
1. Load registered apps (Get-SPRegisteredApps)
2. Filter by -AppNames if specified
3. For each app:
   a. Validate files (Test-SPDisconnectedAppAccountFile)
   b. Check deletion threshold (Test-SPDisconnectedAppDeletionThreshold)
   c. Run full pipeline (snapshot -> delta -> resolve -> campaign -> report)
   d. Capture result: Success/Fail/NoChanges/ThresholdBlocked
   e. Continue to next app regardless of result
4. Generate batch summary
5. Log to JSONL audit trail
```

**Per-app error isolation:**
```powershell
foreach ($app in $apps) {
    try {
        $result = Invoke-SPDisconnectedAppCert -AppName $app.Name ...
        $batchResults.Add(@{ App=$app.Name; Status='Success'; Result=$result })
    }
    catch {
        $batchResults.Add(@{ App=$app.Name; Status='Error'; Error=$_.Exception.Message })
        Write-SPLog -Message "App '$($app.Name)' failed: $($_.Exception.Message)" -Severity ERROR
        # Continue to next app
    }
}
```

**Exit codes:** 0=all success, 1=partial (some apps failed), 2=all failed, 3=auth error

**Acceptance Criteria:**
- 3 registered apps, 1 fails -> other 2 still process, exit code 1
- All succeed -> exit code 0
- WhatIf describes what would be processed for each app
- Console output shows per-app status line (green/red)

---

## DA-15: File Delivery Monitor

- **Status:** `DONE`
- **Commit:** DA-15
- **Depends On:** DA-11

**Description:**
New function `Get-SPDisconnectedAppDeliveryStatus` that checks which registered apps
have fresh files today and which are missing or stale.

**Add to:** `SP.DisconnectedAppRunner.psm1`

**Function:**
```powershell
function Get-SPDisconnectedAppDeliveryStatus {
    param(
        [Parameter()][int]$StaleHours = 24,
        [Parameter()][string]$CorrelationID
    )
}
```

**Per-app status classification:**
- **Delivered**: Account file exists, modified within StaleHours
- **Stale**: Account file exists, modified > StaleHours ago
- **Missing**: Account file path does not exist
- **Disabled**: App is registered but Enabled=false
- **Error**: File exists but is empty or unreadable

**Returns:**
```powershell
@{
    Success = $true
    Data = @{
        Apps = @(
            @{ Name='PEP-Plus'; Status='Delivered'; LastModified='2026-05-28T04:00:00Z'; FileSize=1024; RowCount=500 }
            @{ Name='DebtNext'; Status='Missing'; LastModified=$null }
        )
        Summary = @{ Total=20; Delivered=18; Stale=1; Missing=1; Disabled=0 }
    }
}
```

**Acceptance Criteria:**
- Correctly classifies each app's file status
- RowCount populated by quick `Import-Csv | Measure-Object` (not full validation)
- Missing files don't cause errors (graceful)

---

## DA-16: Cross-App Identity Risk Report

- **Status:** `DONE`
- **Commit:** DA-16
- **Depends On:** DA-11

**Description:**
New function that reads the latest account snapshots from all registered apps and finds
identities that appear in multiple apps. Identities with access across 3+ disconnected
apps are flagged as higher risk (broader access footprint).

**Add to:** `SP.DisconnectedAppRunner.psm1`

**Function:** `Get-SPDisconnectedAppIdentityRisk`

**Flow:**
1. For each registered app, load latest snapshot (accounts.csv)
2. Build identity map: email -> list of apps
3. Flag: 1 app = Normal, 2 apps = Elevated, 3+ apps = High
4. Return sorted by app count descending

**Returns:**
```powershell
@{
    Data = @{
        Identities = @(
            @{ Email='john@corp.com'; Name='John Smith'; Apps=@('PEP-Plus','DebtNext','IPAY'); AppCount=3; Risk='High' }
        )
        Summary = @{ TotalIdentities=200; SingleApp=180; MultiApp=15; HighRisk=5 }
    }
}
```

**HTML export:** `Export-SPDisconnectedAppIdentityRiskHtml`

**Acceptance Criteria:**
- Identity appearing in 3 apps flagged as High risk
- Report sorted by app count descending (highest risk first)
- Handles apps with no snapshots gracefully

---

## DA-17: Unified Entitlement Catalog

- **Status:** `DONE`
- **Commit:** DA-17
- **Depends On:** DA-11

**Description:**
Aggregates entitlements from all registered apps' entitlement files into a unified
searchable catalog. Useful for governance review and SoD analysis.

**Function:** `Get-SPDisconnectedAppEntitlementCatalog`

**Returns:** Array of entitlements with source app:
```powershell
@(
    @{ AppName='PEP-Plus'; EntitlementId='PEP-ADMIN'; DisplayName='PEP+ Admin'; Description='...'; AssignedCount=5 }
    @{ AppName='DebtNext'; EntitlementId='DN-COLLECTOR'; DisplayName='Debt Collector'; Description='...'; AssignedCount=12 }
)
```

AssignedCount = how many accounts in the latest snapshot have this entitlement.

**HTML export:** `Export-SPDisconnectedAppEntitlementCatalogHtml`
- Grouped by app
- Searchable (name/description columns)
- Color-coded by assignment count (high = more scrutiny)

**Acceptance Criteria:**
- Catalog includes entitlements from all registered apps
- AssignedCount matches actual account references
- Apps with no entitlement file are skipped gracefully

---

## DA-18: Batch Summary HTML Report

- **Status:** `DONE`
- **Commit:** DA-18
- **Depends On:** DA-14

**Description:**
After a batch run, generate a consolidated HTML report showing per-app processing
results. Designed for operations team review.

**Function:** `Export-SPDisconnectedAppBatchHtml`

**Report sections:**
1. **Executive Summary**: total apps processed, success/fail/no-changes counts,
   total campaigns created, total identities affected
2. **Per-App Status Table**: App Name | Status | Accounts | Changes | Campaigns | Errors
   Color coded: green=success, gray=no changes, red=error, orange=threshold blocked
3. **Error Detail**: for failed apps, show the error message and which step failed
4. **Delivery Status**: which apps delivered files, which were missing
5. **Footer**: batch start/end times, duration, correlation ID

**Acceptance Criteria:**
- Report is self-contained HTML (inline CSS)
- Per-app rows color-coded by status
- Error details expandable (`<details>` tags)
- Executive summary math is correct (sums match per-app rows)

---

## DA-19: SLA Tracking + Delivery History

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** DA-15

**Description:**
Track file delivery history over time by reading snapshot timestamps. Build a 30-day
delivery timeline per app. Flag apps that are chronically late or have gaps.

**Function:** `Get-SPDisconnectedAppSlaStatus`

**Flow:**
1. For each registered app, scan Snapshots/{AppName}/ directory
2. Parse date from filenames ({YYYY-MM-DD}-accounts.csv)
3. Build 30-day calendar: which days had a delivery, which didn't
4. Calculate: delivery rate (%), longest gap, average gap, consecutive misses

**Returns per app:**
```powershell
@{
    AppName = 'PEP-Plus'
    DeliveryRate = 96.7   # 29 of 30 days
    LongestGapDays = 1
    ConsecutiveMisses = 0
    SlaDays = 1           # from config
    SlaCompliant = $true  # no gap exceeds SlaDays
    DaysMissing = @('2026-05-15')
}
```

**HTML export:** `Export-SPDisconnectedAppSlaHtml`
- Per-app 30-day grid (green=delivered, red=missing, gray=weekend/excluded)
- SLA compliance badge per app
- Overall delivery health score

**Acceptance Criteria:**
- Correctly identifies missing days from snapshot gaps
- SLA compliance based on config SlaDays
- Handles new apps (< 30 days of history) gracefully

---

## DA-20: Pester Tests

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** DA-19

**Description:**
Pester tests for DA-11 to DA-19 features.

**File to Modify:** `Tests/SP.DisconnectedApps.Tests.ps1` (add to existing)
**Modify:** `Tests/Import-TestModules.ps1` if needed

**Test IDs:**
- DA-12-T: Get-SPRegisteredApps returns only enabled apps
- DA-13-T: Register-SPDisconnectedApp adds to Applications array
- DA-14-T: Test-SPDisconnectedAppDeletionThreshold blocks at 50% removal
- DA-14-T2: Threshold allows first run (no previous file)
- DA-15-T: Batch orchestrator continues on per-app error
- DA-16-T: Get-SPDisconnectedAppDeliveryStatus classifies Delivered vs Missing
- DA-17-T: Cross-app identity risk flags 3+ app identities as High
- DA-18-T: Entitlement catalog aggregates across multiple apps
- DA-19-T: Export-SPDisconnectedAppBatchHtml generates valid HTML
- DA-20-T: SLA tracking calculates delivery rate from snapshot filenames

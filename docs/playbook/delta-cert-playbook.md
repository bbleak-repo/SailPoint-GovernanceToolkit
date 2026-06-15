# Delta Certification — Complete Playbook

> **Source of truth.** Edit this Markdown; never the HTML. See [Foundations](00-foundations.md)
> for installation, authentication, vault setup, and the Safety model.

**Audience:** operators, governance leads, and auditors who need to understand, run, and
troubleshoot the Delta Certification workflow — including people who are not SailPoint
experts. This playbook explains not just *how* to run the commands but *why* they work
the way they do and where the system has hard limits.

---

## 1. What problem Delta Cert solves — and what it doesn't

### The problem it solves
Quarterly access reviews are the traditional approach: once every 90 days, every manager
reviews every entitlement their direct reports hold. The problem is clear — a user could
receive broad AD admin access on day 1 of a quarter and hold it unchallenged for 89 days
before anyone reviews it.

Delta Certification solves this by triggering a targeted review **the same day new access
is granted**: ISC detects the AD group membership change, the toolkit creates a focused
certification campaign for just the affected managers, and those managers must approve
or revoke the new access within the deadline (typically 24–48 hours).

**What it achieves:**
- New access reviewed within hours, not months
- Only managers with affected staff get campaigns — NOT all 200 managers daily
- Every grant is logged in a JSONL audit trail with the reviewer's decision
- Escalation to skip-level managers if a reviewer misses the deadline

### What it does NOT replace — both are always needed

Delta cert is **event-driven** (fires when access is granted). Periodic full cert is
**time-driven** (fires on a calendar regardless of what changed). Neither replaces the
other:

| | Delta cert (daily) | Periodic cert (quarterly/annual) |
|---|---|---|
| **Trigger** | New AD grant detected | Calendar schedule |
| **Answers** | "Should they keep what they just received?" | "Should they keep everything they've accumulated?" |
| **Covers** | Access granted since last run | All current access, including pre-toolkit access |
| **Compliance control** | New access reviewed promptly | All access periodically re-certified |

Delta cert runs indefinitely as long as new grants occur. Periodic full cert (`-FullCert`)
runs quarterly or annually as your compliance framework requires (most frameworks typically
require both). The two work together — neither is "once and done."

### Volume reality check (200 managers)

A common concern: "Won't this create 200 campaigns every day?"

No — **daily delta only creates campaigns for managers who have at least one direct report
that received new access today**. If 8 people across the organization got new AD group
memberships today and they report to 4 different managers, you get 4 campaigns. On quiet
days you get 0. Quarterly `-FullCert` does touch all managers with AD staff — that's the
planned large run, not the daily operation.

Campaign count guidance:
- **Daily delta, typical day**: 0–15 campaigns (only affected managers)
- **Daily delta, mass onboarding**: potentially more — consider `-MinIdentities` threshold
  (planned feature) to suppress singleton campaigns for low-risk groups
- **Quarterly -FullCert**: ~150–200 campaigns (one per manager with AD staff)

If you're seeing daily campaigns for the same managers every day, it means your AD has
frequent group membership churn (automated provisioning, project assignments). That's
useful signal — those managers are the ones certifying the most frequently-granted access.

---

## 2. The most important concept — read this first

**"Delta" does NOT mean "certify only the one new entitlement."**

This is the biggest source of confusion for everyone new to this system. Here is exactly
what happens when Alice receives a new AD group membership:

```
Alice gets added to the "Finance-Admins" AD group in Active Directory
    ↓
ISC aggregates the AD source and detects a GRANT_ACCESS event
    ↓
The toolkit creates a certification campaign for Alice's manager, Bob
    ↓
Bob's campaign shows ALL of Alice's current access:
  - Finance-Admins      ← the NEW grant (what triggered this)
  - CorpNetwork-Users   ← existing access from 6 months ago
  - VPN-Standard        ← existing access from 2 years ago
  - ... 47 more groups  ← everything Alice currently holds
```

Bob reviews all 50 items, not just the one new group.

**Why?** Because ISC's certification model is built around *identities*, not individual
entitlements. A certification campaign says "review this person's access" — and ISC
includes every entitlement they currently hold. The API does not (as of the v3 campaigns
endpoint) support a filter that says "show only the entitlement with ID xyz."

**What "delta" actually means:** The delta is *which identities are in scope* — only
people who received new access today, not everyone in the company. Bob does NOT get a
campaign just because Carol (his other direct report) already had Finance-Admins from a
year ago. Bob only gets a campaign today because Alice got something new today.

**The practical benefit:** On most days, 0–5 people across the organization receive new
access. Bob might get a campaign with 1 identity (Alice, 50 items) instead of a
quarterly campaign with 20 direct reports × 50 items each = 1,000 items. That's the
delta.

---

## 3. Two modes: DELTA (daily) and FULL (quarterly)

### DELTA mode — daily default

```powershell
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID'
```

**What it does:**
1. Calls ISC's `/v3/account-activities` endpoint to find `GRANT_ACCESS` events on your AD
   source in the last 24 hours (configurable with `-HoursBack`)
2. For each affected identity, resolves their manager from ISC
3. Groups identities by manager — one campaign per manager group
4. Creates a targeted SEARCH-type campaign for each manager covering their affected staff
5. Writes a JSONL audit event for each campaign created

**No grants today = no campaigns created.** This is correct behavior. If nobody received
new AD access in the window, the script exits cleanly with "No grant events found."

### FULL mode — quarterly baseline

```powershell
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID' -FullCert
```

**What it does:**
1. Skips account-activities detection entirely — does NOT look at what changed
2. Queries all managers who have direct reports with accounts on the specified AD source
3. Creates one MANAGER-type campaign per manager covering ALL their direct reports' access
4. Uses a separate campaign name prefix (`AD Full Cert`) so it doesn't collide with daily
   delta runs on the same day
5. Default deadline: 14 days (configurable via `DeltaCert.FullCert.DeadlineDays`)

**When to use `-FullCert`:**
- **First time you ever run** — establishes the baseline everyone has reviewed
- **Quarterly** — periodic comprehensive review of all current access
- **After a major onboarding wave** — when many new hires received access in bulk

### First-run advisory

If you run the daily delta without ever having run `-FullCert`, the script warns you:

```
WARNING: No delta-cert baseline found in .\DeltaCert\deltacert-audit.jsonl.
Consider running with -FullCert first to establish a baseline review of all current
access, then switch to daily delta runs. Without a baseline, your first delta cert
campaigns may find recent grants but existing access will never have been certified.
```

This warning does not stop execution — you can start with daily delta if you prefer —
but auditors typically want to see that all access was certified at least once before the
daily differential review began.

---

## 4. Configuration reference

All settings live in `Config\settings.json` (or `settings.local.json` for machine-local
overrides).

```json
"DeltaCert": {
    "SourceIds":               ["src-ad-001"],
    "DefaultHoursBack":        24,
    "DefaultDeadlineDays":     2,
    "CampaignNamePrefix":      "AD Delta Cert",
    "MaxCampaignsPerRun":      50,
    "CleanupDaysStale":        3,
    "OutputPath":              ".\\DeltaCert",
    "DefaultReviewerMode":     "Manager",
    "ExcludeLifecycleStates":  ["terminated", "inactive", "leaver", "prehire"],
    "Escalation": {
        "DefaultStaleHours":         24,
        "MaxEscalationLevels":       2,
        "CampaignNamePrefix":        ""
    },
    "FullCert": {
        "CampaignNamePrefix":        "AD Full Cert",
        "DeadlineDays":              14,
        "MaxIdentitiesPerPage":      250
    }
}
```

| Setting | What it controls |
|---|---|
| `SourceIds` | Default AD source(s) to monitor. Passed as `-SourceId` default. |
| `DefaultHoursBack` | Look-back window for grant detection. `24` = last 24 hours. |
| `DefaultDeadlineDays` | How many days managers have to review. `2` = 48-hour deadline. |
| `PrivilegedOnly` | **`true` (default)** — only certify grants to privileged entitlements. Set to `false` to certify all grants regardless of privilege flag. Checks ISC `privileged:true` attribute; falls back to `Audit.RiskIndicators.PrivilegedPatterns` for untagged entitlements. |
| `CampaignNamePrefix` | Daily delta campaign names: `"AD Delta Cert 2026-06-08 - Manager Smith"`. |
| `MaxCampaignsPerRun` | Safety cap — refuses to create more than this many campaigns in one run. |
| `ExcludeLifecycleStates` | Identities in these states are skipped even if they received new access. |
| `Escalation.DefaultStaleHours` | Hours with no reviewer action before escalation triggers. |
| `FullCert.CampaignNamePrefix` | Quarterly run campaign names: `"AD Full Cert 2026-06-08 - Manager Smith"`. |
| `FullCert.DeadlineDays` | Quarterly review deadline in days (default 14). |

### Required ISC API scopes

| Scope | Why needed |
|---|---|
| `idn:campaign:read` | Read existing campaigns |
| `idn:campaign:manage` | Create new campaigns |
| `idn:campaign-report:read` | Read certifications and review items |
| **`sp:scopes:all`** or `idn:account-activities:read` | **Required** — read the account-activities events that detect new grants |
| `idn:entitlement:read` | Required only when using `-PrivilegedOnly` to check ISC entitlement metadata |

Without `sp:scopes:all` (or the specific account-activities scope), the script fails at
grant detection with a 403. This is the most common setup issue. See the
[Foundations](00-foundations.md) doc for how to add scopes to your Personal Access Token.

### How to find your AD Source ID

In ISC Admin Console: **Connections → Sources → [select your AD source] → the ID
appears in the browser URL**, e.g. `https://tenant.identitynow.com/ui/admin/source/2c91808...`.
The `2c91808...` part is your Source ID.

Alternatively: `.\Scripts\Invoke-SPSdkCampaignTemplates.ps1 -Action List` won't show
sources, but `Test-SPConnectivity.ps1` logs the tenant it connected to. Check your ISC
Admin → Sources page directly.

---

## 5. Running the commands

### Test without creating anything (-WhatIf)

Always start with `-WhatIf` to see what would happen:

```powershell
# What would a daily delta create today?
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID' -WhatIf

# What would a quarterly full cert create?
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID' -FullCert -WhatIf
```

### First-ever run (establish baseline)

```powershell
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID' -FullCert
```

This creates MANAGER campaigns for every manager with staff on the AD source. Expect
this to run for several minutes and create dozens of campaigns.

### Daily delta run

```powershell
# Default: last 24 hours
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID'

# Look back 48 hours (catch-up after a skipped day)
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID' -HoursBack 48
```

### Targeting only privileged grants (-PrivilegedOnly)

The single highest-leverage volume control for daily delta. Instead of certifying every
AD group grant, only trigger a campaign when the specific group is marked `privileged:true`
in ISC — distribution lists, project groups, and standard access get ignored entirely.

```powershell
# Only certify managers whose staff received a privileged AD entitlement today
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID' -PrivilegedOnly

# Preview what would be caught (no campaigns created)
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID' -PrivilegedOnly -WhatIf
```

**What "privileged" means in ISC:** In ISC Admin → Entitlements, each AD group entry can
have its `privileged` attribute set to `true`. ISC populates this from your source connector
(AD has no native "privileged" flag, so someone must tag them manually or via an ISC rule).

**Pattern-match fallback:** If the entitlement isn't in ISC yet (not yet aggregated, or
the source hasn't been fully catalogued), the toolkit falls back to the name patterns in
`Audit.RiskIndicators.PrivilegedPatterns` (default: `Admin`, `Root`, `DBA`, `Domain Admins`).
A group named "Finance-Admins" would be caught by the "Admin" pattern.

**ISC scope required:** `idn:entitlement:read` or `sp:scopes:all` (needs to read entitlement
metadata to check the privileged attribute).

**This is the default.** `"PrivilegedOnly": true` is already set in `settings.json`. Every
daily run automatically filters to privileged grants only. To certify ALL grants instead,
pass `-PrivilegedOnly:$false` on the command line or set `"PrivilegedOnly": false` in
`settings.json`.

**For the ISC `at-access(privileged:true)` Lucene query:** This ISC search expression finds
identities who hold ANY privileged access. `-PrivilegedOnly` is more specific — it filters by
whether the specific *new grant event* is for a privileged entitlement, not whether the
identity happened to already hold other privileged access.

### Escalation — deadline-aware (recommended)

```powershell
# Escalate if campaign deadline is within 8 hours AND cert is unsigned
# Run this at noon for 11pm deadlines (gives 11h for escalated reviewer)
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 `
    -StaleHours 0 `
    -EscalateBeforeDeadlineHours 11

# Traditional wall-clock mode (15h after creation = run at 2pm for 11pm campaigns)
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 15
```

### Org chart audit — validate manager chains before going live (-DaysBack)

Before enabling automatic escalation against real campaigns, validate that ISC's
manager chain data is complete for every reviewer who has appeared in the last N days.

```powershell
# Dry-run org chart audit: last 30 days, all campaign statuses, no write calls
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf

# Same, but against a specific campaign prefix (e.g. a peer's campaign)
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 `
    -CampaignNamePrefix 'Daily Attestation' `
    -DaysBack 30 -WhatIf
```

What `-DaysBack` does differently from normal mode:
- Searches **all** campaign statuses (ACTIVE + COMPLETED + STAGED), not just ACTIVE
- Returns **all** certifications regardless of signed/stale status
- In `-WhatIf`, shows the full reviewer → skip-level chain per certification
- Lines printed in **red** = ISC could not resolve a skip-level manager — those are org chain
  gaps that would cause live escalation to silently skip the cert

**Fix the red lines before running live escalation.** Take the `ReviewerIdentityId` values
and have your AD/HR team correct the `manager` attribute in the source system.

### Org chart audit with CSV export (-Csv)

Combine `-DaysBack` with `-Csv` to produce a spreadsheet you can review, share, or
archive as evidence:

```powershell
# 30-day org chain audit → CSV auto-named in DeltaCert.OutputPath
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf -Csv

# Custom path
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf `
    -CsvPath 'C:\temp\org-chain-audit.csv'
```

The CSV has one row per certification with these columns:

| Column | Meaning |
|---|---|
| `CampaignName` | Which campaign the cert belongs to |
| `CampaignStatus` | ACTIVE / COMPLETED / etc. |
| `ReviewerName` | The manager who was/is assigned the cert |
| `SkipLevelName` | Who ISC would escalate to |
| `SkipLevelResolved` | **False = org chain gap** (no manager in ISC) |
| `HoursOpen` | How long the cert has been open |
| `EscalationReason` | Stale / Deadline / Both / AuditAll |
| `CertSigned` | Whether the cert was completed before the audit |
| `Outcome` | WouldEscalate / Skip-NoManagerInISC / Skip-MaxLevelsReached / etc. |

Open in Excel, filter `SkipLevelResolved = False` to see every org chain gap.

### Clean up completed/stale campaigns

```powershell
# Complete campaigns older than CleanupDaysStale (default 3 days)
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID' -RunCleanup
```

---

## 6. How escalation works — and yes, ISC sends the email

### What the toolkit actually does

When `Invoke-SPDeltaCertEscalate.ps1` runs, it calls ISC's reassignment API
(`/v3/certifications/{id}/reassign`). This moves the certification items from the
original reviewer (the manager who didn't act) to their skip-level manager. The toolkit
itself sends no email — **ISC sends the notification automatically** as part of the
reassignment.

The complete chain:

```
Toolkit calls ISC reassignment API
    ↓
ISC moves the certification to the skip-level manager's queue
    ↓
ISC triggers its standard "certification assignment" notification
    ↓
Skip-level manager receives: "You have a new certification to review"
    (same email template they'd receive for any new campaign assignment)
```

### What the email contains

The notification email uses ISC's built-in certification assignment template —
the same one managers receive when a campaign is originally created. You configure
the template in **ISC Admin Console → Notifications → Certification**. ISC sends it;
the toolkit has no control over the content or whether it's sent.

**If no email arrives after escalation:**
1. Check ISC Admin → Notifications → Certification is enabled
2. Check the skip-level manager has a valid email address in ISC (identity attribute)
3. Check ISC's notification delivery history (Admin → Notification Delivery)

### ISC constraints the escalation respects

The toolkit handles two ISC API limits automatically:

| Constraint | What it means | How toolkit handles it |
|---|---|---|
| Max 50 items per sync reassignment | A certification with >50 review items can't use the sync reassignment API | Automatically switches to the async reassignment API for large certifications |
| Max escalation levels | ISC tracks how many times a cert has been reassigned | `MaxEscalationLevels` in settings.json (default 2) prevents infinite escalation chains |
| Governance Group certifications | Cannot be reassigned via this API | Toolkit logs a warning and skips; manual reassignment required in ISC UI |

### What "Reassigned" classification means

When a certification has already been escalated once, ISC marks it as
`ReviewerClassification = 'Reassigned'`. The toolkit treats this as "one level already
consumed" — so if `MaxEscalationLevels = 2` and the cert is already Reassigned, it gets
one more escalation hop (to the next level up the org tree) and then stops.

### WhatIf mode for escalation

```powershell
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 0 -EscalateBeforeDeadlineHours 11 -WhatIf
```

WhatIf shows exactly who would be escalated and to which skip-level manager — without
calling the reassignment API and without triggering any ISC notifications.

---

## 7. Scheduling escalation correctly (the timing trap)

This is the second most common misunderstanding after the "all entitlements" issue above.

### The problem with `-StaleHours 24`

If a campaign is created at 11pm and has a 24-hour deadline (11pm tomorrow):

```
11pm  Campaign created — certs assigned to managers
 6am  Managers arrive at work (7 hours elapsed, 0 business hours)
 2pm  Managers leave work (15 hours elapsed, 8 business hours)
11pm  -StaleHours 24 triggers → escalation fires
      → Too late. The deadline is right now.
```

Using `-StaleHours 24` on a 24-hour campaign means you escalate **at the deadline**, not
before it.

### The fix: `-EscalateBeforeDeadlineHours`

Instead of measuring from campaign creation, measure from the campaign deadline:

```powershell
# Run at noon daily:
# Finds certifications whose campaign expires within 11 hours (by 11pm tonight)
# → The escalated reviewer has 11 hours to act
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 `
    -StaleHours 0 `
    -EscalateBeforeDeadlineHours 11
```

```
11pm  Campaign created
 6am  Managers arrive
12pm  Escalation script runs:
      "Campaign expires within 11 hours, cert is unsigned → escalate"
      → Manager's skip-level gets the items
      → Skip-level has 11 hours (until 11pm) to act
 2pm  Original managers leave — doesn't matter, skip-level has it
11pm  Deadline
```

**Rule of thumb:** Set `-EscalateBeforeDeadlineHours` to the number of hours you want the
*escalated reviewer* to have. If your review window is 6am–5pm (11 hours), run the
escalation script at a time that leaves 11 hours before deadline.

---

## 7. Understanding the campaign types

ISC distinguishes between different campaign types that affect how reviewers are assigned
and what appears in the ISC UI.

### DELTA mode uses SEARCH campaigns

Daily delta campaigns are `SEARCH` type with `filter.type = "IDENTITY"`. This means:
- The campaign was built by searching for specific identity IDs
- Each matched identity contributes all their entitlements to the review
- The certifier (reviewer) is explicitly set to the manager's identity ID

In the ISC UI, these appear under **Certifications** for each manager. The manager sees
a queue filtered to their affected direct reports.

### FULL mode uses MANAGER campaigns

Quarterly full-cert campaigns are `MANAGER` type. This means:
- ISC automatically routes each certification to the appropriate manager
- The campaign was not built from a specific identity search but from the source
- All direct reports of each manager appear in their certification queue

### Your peer's "Identity" campaign type

When your peer says their custom campaign uses "Identity" type, they are likely referring
to `filter.type = "IDENTITY"` in a SEARCH campaign — the same fundamental structure as
the daily delta. The key limitation remains: the campaign reviews all access of matched
identities, not only specific entitlements.

True entitlement-level scoping (certify *only* the Finance-Admins membership, nothing
else) would require a Campaign Template with `searchCampaignInfo.type = "ENTITLEMENT"`.
This is not currently supported by the toolkit's campaign creation path but is a planned
enhancement using the SDK Features tab's campaign template infrastructure.

---

## 8. The JSONL audit trail

Every campaign creation and escalation event writes a line to
`DeltaCert\deltacert-audit.jsonl`. This file:

- **Is the baseline marker** — if this file exists, the script knows a prior run occurred
- **Provides compliance evidence** — each line records: timestamp, action, campaign ID,
  campaign name, manager identity, number of identities included, correlation ID
- **Includes entitlement context** — since the recent update, grant events also carry
  `EntitlementId`, `EntitlementName`, and `AccessProfileId` from the account-activities
  data, so you can trace which specific AD group membership triggered each campaign

The audit trail grows over time. See `Invoke-SPRetention.ps1` to configure archival
(default: archive after 30 days, delete archives after 90 days).

**Important:** The audit trail records that campaigns were *created* and *escalated*. The
actual reviewer decisions (who approved what, who revoked what) are in the ISC platform
and in the toolkit's campaign audit reports (`Invoke-SPCampaignAudit.ps1`).

---

## 9. Limitations

These are hard constraints, not bugs:

### 9.1 Campaigns review all access, not just the new grant

**Constraint:** ISC's `/v3/campaigns` API does not support entitlement-level scoping.
A SEARCH campaign with `filter.type = "IDENTITY"` presents all entitlements of matched
identities.

**Impact:** If Alice has 50 AD groups and receives 1 new one, her manager sees 51 items
in the certification, not 1.

**Mitigation:** The scope of *who* gets campaigns is still narrow (only managers with
affected staff), reducing total volume significantly compared to quarterly full certs.
Entitlement-level scoping is planned via Campaign Templates (SDK Features).

### 9.2 Only detects grants, not all access changes

**Constraint:** The toolkit reads `GRANT_ACCESS` events from account-activities. It does
not detect revocations, role changes, or attribute changes.

**Impact:** If a user's access is removed outside of a certification (e.g., manually
de-provisioned), no delta cert campaign is triggered.

**Mitigation:** ISC's lifecycle management handles provisioning; use quarterly `-FullCert`
runs for comprehensive reconciliation.

### 9.3 Depends on ISC aggregation timing

**Constraint:** Grant events only appear in account-activities AFTER ISC has aggregated
the AD source. If aggregation runs every 4 hours, a grant at 3:00am may not appear until
7:00am, even with `-HoursBack 24`.

**Impact:** There's a small window (up to one aggregation cycle) between when access is
granted in AD and when the toolkit detects it.

**Mitigation:** Schedule the daily delta run *after* your ISC aggregation completes.
Check your ISC Admin Console → Sources → [your source] → Aggregation History for
typical schedule.

### 9.4 Requires `sp:scopes:all` for grant detection

**Constraint:** The `/v3/account-activities` endpoint requires broad API scope.

**Impact:** Without this scope, grant detection fails with 403. The toolkit now emits a
clear error message pointing to this scope.

**Resolution:** Add `sp:scopes:all` to your ISC Personal Access Token (Admin Console →
Security Settings → Personal Access Tokens).

### 9.5 MaxCampaignsPerRun safety cap

**Constraint:** If more campaigns would be created than `DeltaCert.MaxCampaignsPerRun`
(default 50), the entire run aborts with an error.

**Impact:** On days with unusually high access grant activity, the run fails.

**Resolution:** Increase `MaxCampaignsPerRun` in settings.json, or investigate why so
many grants occurred (potential security incident).

### 9.6 No cross-manager deduplication

**Constraint:** If Alice is a direct report of Bob, AND Alice also has a dotted-line
relationship to Carol (not modeled in ISC's org tree), only Bob gets a campaign.

**Impact:** Second-level or matrix reporting structures are not visible to the toolkit.

### 9.7 ExcludeLifecycleStates only applies to delta

**Constraint:** `ExcludeLifecycleStates` (e.g., `terminated`) only filters identities in
DELTA mode. `-FullCert` creates MANAGER campaigns which ISC manages directly — lifecycle
filtering happens at the ISC campaign level.

---

## 10. Troubleshooting

### "No grant events found" but you know access was granted

**Possible causes:**
1. **Source ID is wrong** — verify the exact source ID from ISC Admin Console
2. **Aggregation hasn't run yet** — wait for ISC to aggregate the source, then re-run
3. **DaysBack window too narrow** — the grant may have occurred outside the window;
   try `-HoursBack 48`
4. **Lifecycle state excluded** — if the identity is `inactive`, it's excluded by
   `ExcludeLifecycleStates`. Remove the state from config if this is intentional.
5. **Account-activities 403** — missing `sp:scopes:all` scope (see §9.4)

### Campaign created but manager sees 50+ items, not 1

This is expected behavior — see §2 and §9.1. The manager sees all of the identity's
entitlements, not just the new grant. The delta is in *who* gets a campaign, not in the
scope of items within each campaign.

### "Campaign search failed: request timed out / error 400"

**Cause:** Escalation was previously using a full-text `co` (contains) filter on campaign
names, which ISC times out. **Fixed:** The escalation script now uses `sw` (starts-with)
which is an indexed prefix scan.

**Resolution:** Pull the latest toolkit version.

### "Campaign search failed: access denied (403)"

**Cause:** Missing ISC API scope.

**Resolution:** Add `sp:scopes:all` to your PAT and re-run `New-SPVault.ps1` with the
new client secret.

### "Escalation fires but it's too late"

**Cause:** Using `-StaleHours 24` on a 24-hour campaign. See §6.

**Resolution:** Switch to `-EscalateBeforeDeadlineHours` mode. Run the escalation script
at a time that leaves enough hours before the deadline for the escalated reviewer to act.

### Campaigns are created with wrong manager

**Cause:** ISC's identity-to-manager mapping is based on the `manager` attribute in the
identity profile. If the manager attribute is missing or incorrect, ISC resolves to the
fallback reviewer (`FallbackReviewerIdentityId` in config).

**Resolution:** Verify the manager attribute is populated in ISC Admin → Identities →
[affected identity] → Attributes. Run a data quality check:
`Invoke-SPDataQualityReport.ps1` (Section 3 checks manager self-references and missing
attributes).

### `-FullCert` creates duplicate campaigns when run twice

**Cause:** There is no deduplication check for FULL mode. Running it twice creates two
sets of campaigns.

**Resolution:** Complete (or cancel) existing full-cert campaigns before running again.
Use `Invoke-SPADDeltaCert.ps1 -RunCleanup` to close out stale campaigns first.

### First-run advisory keeps appearing

**Cause:** The `DeltaCert\deltacert-audit.jsonl` file doesn't exist. Either the output
directory is wrong or a previous run was on a different machine.

**Resolution:** Run `-FullCert` once, OR manually create the file with an empty JSON line
if you're intentionally skipping the baseline (not recommended for production).

---

## 11. Gotchas by experience level

### If you're new to this toolkit

- **Always run `-WhatIf` first.** It shows exactly what would be created without making
  any API calls.
- **Start with `-FullCert`.** Your auditors will thank you for having a clear baseline
  certification before the daily delta started.
- **The vault passphrase is prompted once** when you launch the GUI or run the first
  script. It's shared across all operations in the same session — you won't be prompted
  again.

### If you've been running daily delta for a while

- **Check your escalation timing.** If you're using `-StaleHours 24` and your campaigns
  have 24-hour deadlines, escalation is firing at the worst possible moment. Switch to
  `-EscalateBeforeDeadlineHours`.
- **Monitor MaxCampaignsPerRun.** A spike in campaign count (50+) means a lot of access
  was granted in one day — which might be a security event worth investigating.
- **Archive your JSONL.** The `DeltaCert\deltacert-audit.jsonl` file grows indefinitely.
  Add `DeltaCert` to your `Retention.Paths` in settings.json.

### If you're a governance auditor reviewing evidence

- The JSONL audit trail proves **campaigns were created** and **escalations occurred**.
- The campaign audit reports (`Invoke-SPCampaignAudit.ps1`) prove **decisions made**
  (who approved, who revoked, who didn't respond).
- Both together prove the chain of custody: access was granted → campaign created →
  manager reviewed (or was escalated to skip-level) → decision recorded.

---

## 12. Recommended operational calendar

| Frequency | Action | Command |
|---|---|---|
| **One time** (setup) | Establish full baseline | `-FullCert` |
| **Daily** (cron, ~11pm) | Detect and certify new grants | default mode |
| **Daily** (noon) | Escalate uncompleted reviews | `-EscalateBeforeDeadlineHours 11` |
| **Daily** (cleanup) | Close stale/overdue campaigns | `-RunCleanup` |
| **Quarterly** | Full portfolio review | `-FullCert` |
| **As needed** | Catch-up after missed run | `-HoursBack 48` |

### Suggested Task Scheduler setup (Windows)

```powershell
# Task 1: Daily delta (after AD aggregation completes — adjust time to match your ISC schedule)
# Trigger: Daily at 11:30pm
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID'

# Task 2: Midday escalation (business-hours aware)
# Trigger: Daily at 12:00pm  
.\Scripts\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 0 -EscalateBeforeDeadlineHours 11

# Task 3: Cleanup stale campaigns
# Trigger: Daily at 11:45pm (after delta run)
.\Scripts\Invoke-SPADDeltaCert.ps1 -SourceId 'YOUR-SOURCE-ID' -RunCleanup
```

---

## 13. The path to true entitlement-scoped certification

The ideal state — certifying only the specific new entitlement, not the full identity
portfolio — is not achievable through the current v3/campaigns API endpoint. It requires
ISC's Campaign Templates feature with `searchCampaignInfo.type = "ENTITLEMENT"`.

The toolkit's SDK Features tab and `Invoke-SPSdkCampaignTemplates.ps1` already have the
infrastructure to create and schedule campaign templates. The gap is building a
template-per-entitlement creation workflow that:

1. Detects a new grant (same as current delta cert)
2. Creates or references a campaign template scoped to that specific entitlement ID
3. Triggers the template to generate a campaign for only that entitlement

This approach would give managers a single-item queue ("Should Alice keep Finance-Admins?")
rather than a 50-item queue. It is documented as a planned enhancement in
[future-features-modernization.md](../planning/future-features-modernization.md).

Until that work is done, the current delta cert meaningfully reduces the *frequency* of
broad reviews (daily targeted vs. quarterly comprehensive) even if it cannot yet reduce
the *scope* of each review to a single entitlement.

---

## 14. Identity Cache Management

Delta cert resolves identity details (name, email, manager, active status) via the ISC
API and caches results in `identities.jsonl` under the `.cache` directory. The cache
is backed by `SP.IdentityService` (part of `SP.Shared`) with a configurable TTL
(default 24 hours via `Audit.IdentityCacheTtlMinutes`).

**When to clear the cache:**
- After a reorg or bulk termination (stale manager chains produce incorrect escalation targets)
- Before SOX-critical evidence generation (ensures fresh data from ISC)
- After manually correcting identity data in ISC

```powershell
# Clear all identity caches (memory + disk)
Clear-SPIdentityCache

# Inspect cache health
Get-SPCacheStoreInfo -Store 'SPIdentity'

# Validate JSONL integrity
Test-SPCacheStoreIntegrity -Store 'SPIdentity'
```

**TTL tuning:** The 24-hour default means a termination processed at 9 AM will not be
reflected until the next day. For same-day termination SLAs, set
`Audit.IdentityCacheTtlMinutes` to 480 (8 hours) or clear the cache before evidence runs.

**Security:** `identities.jsonl` contains PII (names, emails). Restrict the `.cache`
directory to the service account. The toolkit warns at startup if ACLs are too permissive.

---

*Related playbooks: [CLI Playbook](cli-playbook.md) · [GUI Playbook](gui-playbook.md) ·
[Foundations](00-foundations.md)*

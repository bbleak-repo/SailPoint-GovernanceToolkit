# Disconnected App Template Version History

## v2 (2026-05-29) -- Current

**Account CSV:** 11 columns (8 required + 3 optional)
- Added: `accountType` (standard/admin/service/shared)
- Added: `created` (YYYY-MM-DD, account creation date)
- Added: `lastLogin` (ISO 8601, last authentication timestamp)

**Entitlement CSV:** 7 columns (4 required + 3 optional)
- Added: `owner` (email, entitlement steward -- recommended)
- Added: `type` (role/group/permission/license)
- Added: `riskLevel` (low/medium/high/critical)

**Onboarding Guide:** Major update
- Clarified "full export required" (not delta)
- Added self-service validation command
- Added entitlement design guidance
- Added multiple account types documentation
- Added file size guidance (100K rows)
- Added specific support contacts (ServiceNow, email, Teams)
- Added version number

**Backward compatible:** v1 files still work. New columns are optional.

## v1 (2026-05-28) -- Original

**Account CSV:** 8 columns (all required)
- id, name, givenName, familyName, e-mail, department, groups, IIQDisabled

**Entitlement CSV:** 4 columns (all required)
- id, name, displayName, description

**Onboarding Guide:** Initial version

---

## Migrating v1 to v2

### Quick Diff

Compare your current files against v2 templates:

```bash
diff <(head -1 your-accounts.csv) <(head -1 Config/Templates/v2/disconnected-app-accounts.csv)
diff <(head -1 your-entitlements.csv) <(head -1 Config/Templates/v2/disconnected-app-entitlements.csv)
```

### Step-by-Step: Account CSV

v1 header:
```
id,name,givenName,familyName,e-mail,department,groups,IIQDisabled
```

v2 header (append 3 columns):
```
id,name,givenName,familyName,e-mail,department,groups,IIQDisabled,accountType,created,lastLogin
```

**What to do:**

1. Add `accountType` column. Valid values: `standard`, `admin`, `service`, `shared`.
   If unknown, use `standard` as default.
2. Add `created` column. Format: `YYYY-MM-DD`. Leave empty if unavailable.
3. Add `lastLogin` column. Format: ISO 8601 (`YYYY-MM-DDTHH:mm:ssZ`). Leave empty if
   unavailable.

PowerShell one-liner to append empty v2 columns to an existing v1 file:

```powershell
$csv = Import-Csv accounts.csv
$csv | Select-Object *, @{N='accountType';E={'standard'}}, @{N='created';E={''}}, @{N='lastLogin';E={''}} | Export-Csv accounts-v2.csv -NoTypeInformation
```

### Step-by-Step: Entitlement CSV

v1 header:
```
id,name,displayName,description
```

v2 header (append 3 columns):
```
id,name,displayName,description,owner,type,riskLevel
```

**What to do:**

1. Add `owner` column. Email of the entitlement steward. Leave empty if unknown.
2. Add `type` column. Valid values: `role`, `group`, `permission`, `license`.
   Default: `group`.
3. Add `riskLevel` column. Valid values: `low`, `medium`, `high`, `critical`.
   Default: `low`.

PowerShell one-liner to append empty v2 columns to an existing v1 file:

```powershell
$csv = Import-Csv entitlements.csv
$csv | Select-Object *, @{N='owner';E={''}}, @{N='type';E={'group'}}, @{N='riskLevel';E={'low'}} | Export-Csv entitlements-v2.csv -NoTypeInformation
```

### Onboarding Guide

Replace `v1/ONBOARDING-GUIDE.md` with `v2/ONBOARDING-GUIDE.md`. The v2 guide is a
superset -- all v1 content is preserved with additions. See the "What Changed in v2"
table at the top of the v2 guide for a full summary.

### No Code Changes Required

The toolkit accepts both v1 and v2 files. The new columns are optional. Existing v1
exports continue to work without modification. Upgrading to v2 enables richer
reviewer context (last login, account type, risk level) but is not required.

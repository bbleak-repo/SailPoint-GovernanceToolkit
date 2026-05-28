# Disconnected Application Onboarding Guide

## What This Is

Your application does not have a native connector to SailPoint IdentityNow (ISC). To bring it
under governance, your team provides **daily CSV exports** of all accounts and entitlements.
SailPoint uses these files to:

- Track who has access to your application
- Detect when access changes (new accounts, new permissions, removals)
- Trigger certification campaigns so managers can review changes
- Maintain an audit trail of access decisions

---

## Files You Need to Provide

Two CSV files, refreshed daily:

| File | Name | Contents |
|------|------|----------|
| **Accounts** | `accounts.csv` | Every user account in your application |
| **Entitlements** | `entitlements.csv` | Every role/group/permission your application defines |

Template files with example data are included alongside this guide.

---

## Account File Columns

| Column | Required | Description | Example |
|--------|----------|-------------|---------|
| `id` | Yes | Unique account identifier (max 128 characters) | `EMP10001` |
| `name` | Yes | Username or login name | `jsmith` |
| `givenName` | Yes | First name | `John` |
| `familyName` | Yes | Last name | `Smith` |
| `e-mail` | Yes | Corporate email address (used to match to SailPoint identity) | `john.smith@corp.com` |
| `department` | Recommended | Department name | `Treasury` |
| `groups` | Yes | Entitlement IDs assigned to this account (see multi-value format below) | `"APP-ADMIN,APP-REPORTS"` |
| `IIQDisabled` | Yes | Account status: `true` = disabled/inactive, `false` = active | `false` |

---

## Entitlement File Columns

| Column | Required | Description | Example |
|--------|----------|-------------|---------|
| `id` | Yes | Unique entitlement identifier (must match values used in accounts `groups` column) | `APP-ADMIN` |
| `name` | Yes | Technical name | `APP-ADMIN` |
| `displayName` | Yes | Human-readable name shown to reviewers during certification | `Administrator` |
| `description` | Yes | Description shown to reviewers (max 2000 characters) | `Full administrative access` |

---

## File Format Requirements

### Encoding
- **UTF-8** encoding (without BOM preferred, BOM accepted)
- Files saved from Excel: use "CSV UTF-8 (Comma delimited)" format

### Multi-Value Fields
When an account has multiple entitlements, list them comma-separated inside double quotes:

```
"APP-ADMIN,APP-REPORTS"
```

A single entitlement does not require quotes:

```
APP-READONLY
```

An account with no entitlements should have an empty value:

```
EMP10005,tresigned,Tom,Resigned,tom.resigned@corp.com,Treasury,,true
```

### Sorting
The accounts file must be sorted by the `id` column in ascending order.

### Status Mapping

| Your Application State | IIQDisabled Value |
|------------------------|-------------------|
| Active / Enabled | `false` |
| Disabled / Inactive / Locked / Terminated | `true` |

---

## File Delivery

### Drop Location
Place both files in your application's import directory:

```
\\fileserver\sailpoint-imports\{YourAppName}\
```

Replace `{YourAppName}` with the name assigned during onboarding (e.g., `PEP-Plus`).

### Schedule
Files must be refreshed by **04:00 UTC daily**. The SailPoint import job runs shortly after
this deadline. Late files will be processed in the next day's cycle.

### File Names
Always use these exact names:
- `accounts.csv`
- `entitlements.csv`

Do not append dates or version numbers to the filename. The toolkit handles date-stamped
archival automatically.

---

## Common Mistakes to Avoid

| Mistake | Impact | Fix |
|---------|--------|-----|
| Saving as ANSI instead of UTF-8 | Special characters (accents, symbols) corrupt | Use "CSV UTF-8" in Excel save dialog |
| Including a UTF-8 BOM | May cause first column header to be unrecognized | Save without BOM, or use a text editor to strip it |
| Empty rows at end of file | Phantom accounts with blank IDs | Delete trailing blank rows before saving |
| Dates in non-ISO format | Parsing failures | Use `YYYY-MM-DD` format for any date fields |
| Entitlement IDs with spaces | Mismatched cross-references | Use hyphens or underscores: `APP-ADMIN` not `APP ADMIN` |
| Missing `IIQDisabled` column | All accounts treated as active | Always include this column, even if all values are `false` |
| Entitlement in `groups` not in entitlements file | Cross-reference validation failure | Ensure every group ID has a matching row in `entitlements.csv` |
| Unsorted `id` column | Delta detection may produce incorrect results | Sort by `id` ascending before exporting |
| Stale files (same file multiple days) | No deltas detected, no campaigns created | Ensure the export reflects current state each day |

---

## Questions?

Contact the SailPoint governance team for:
- Your assigned application name
- Drop location credentials
- Custom column mapping (if your export cannot match the template exactly)
- Testing with a sample file before going live

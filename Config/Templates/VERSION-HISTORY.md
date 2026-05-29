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

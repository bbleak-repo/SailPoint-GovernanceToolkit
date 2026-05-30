# Round 7
**Started:** 2026-05-30 00:31:27

**OC-07 complete.** Here's what was implemented:

**Modified `Export-SPLeadershipLevelHtml`** (`SP.AuditReport.psm1`):
- Added optional `-BandData` parameter (hashtable from `Resolve-SPIdentityBand .Data`)
- When provided, report titles include band designation: "VP Report (Band B): Alice Johnson" / "Executive Summary (Band A)"

**New `Export-SPLeadershipBandHtml`** (wrapper function):
- `-TargetBands @('A','B','C')` -- include only these bands
- `-ExcludeBands @('D','E')` -- exclude these bands (ignored if TargetBands is set)
- Filters `LeadershipData.Levels` leaders by band classification before delegating to `Export-SPLeadershipLevelHtml`
- Returns `@{Success; Data=@{Files; ReportCount; BandsIncluded; LeadersSkipped}; Error}`
- Works with supplement-derived, ISC-derived, and depth-fallback bands

**Exported** in both `Export-ModuleMember` and `SP.Audit.psd1`.

Commit `1070f9a`, pushed to `feature/org-chart-reports`.

**Completed:** 2026-05-30 00:38:13
**Status:** SUCCESS

# Round 3
**Started:** 2026-05-30 00:02:02

**OC-03 complete.** Committed and pushed `0820150`.

**What was built:** `Show-SPCampaignOrgPreview` in `SP.DeltaCertQueries.psm1` -- takes an array of identity IDs and MaxDepth, builds the org tree via `Build-SPOrgTree`, then renders an ASCII preview showing:
- Header with identity count and branch count
- Each VP/branch root with total identities to review
- Direct managers under each branch with their leaf identity names
- Unmanaged identities (no campaign)
- Total campaign count (one per manager with affected reports)

Exported in both `Export-ModuleMember` and `SP.DeltaCert.psd1`.

**Completed:** 2026-05-30 00:07:49
**Status:** SUCCESS

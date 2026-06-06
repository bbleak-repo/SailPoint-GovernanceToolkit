# Round 21
**Started:** 2026-06-05 18:30:00
**Item:** AR-21 — Adaptive -> Leadership distribution (bands + WhatIf SMTP + upper rollup)

**Read:** `Scripts/Invoke-SPReportDistribution.ps1` (the full leadership flow:
`Resolve-SPAuditIdentityAccounts` -> `Build-SPOrgTree` -> optional
`Import/Merge-SPOrgChartSupplement` -> `Resolve-SPIdentityBand` ->
`Group-SPAuditByLeadership` -> `Show-SPReportDistributionPreview` /
`Export-SPLeadershipBandHtml` -> `Send-SPReport`), capturing exact arg shapes.

**Did:** Extended `Invoke-SPAdaptiveReport.ps1` with an additive
`-DistributeToLeadership` mode (+ `-TargetBands`/`-LeadershipDepth`/`-OrgSupplementPath`
/`-PreviewOnly`/`-SendReports`/`-DetailLevel`; added SP.DeltaCert to the chain).
After generating the adaptive reports it collects reviewed identity IDs from the
decisions, builds the org tree + bands, groups by leadership, generates the
**upper-leadership executive rollup** (`Export-SPLeadershipExecutiveHtml`) + **per-band
reports** (`Export-SPLeadershipBandHtml -TargetBands`), resolves leader emails, and:
- `-PreviewOnly` -> `Show-SPReportDistributionPreview` + exit (no generation/send);
- default -> **SIMULATE**: print "WOULD send -> <leader> <email> [band]", send nothing;
- `-SendReports` -> `Send-SPReport` (which only emails when Audit.Smtp.Enabled=$true).
Added a compact-name match fallback so `director-AliceJohnson.html` resolves to the
leader. **Zero edits to existing files** — only the new CLI was extended.

**Files:** `Scripts/Invoke-SPAdaptiveReport.ps1` (extended).

**Verification (live mock):**
  - AST parse OK.
  - Default (simulate): 29 identities -> org tree (11 mgr/3 dir/1 top); bands
    A0/B1/C3/D11/E29; exec rollup + 4 per-band (B,C); **3 "WOULD send" to directors,
    0 emails sent**, exit 0.
  - `-PreviewOnly`: full plan (Exec -> Richard Sterling [B]; Directors -> Alice/Bob/
    Charlie [C] with manager + completion detail) + "SMTP NOT CONFIGURED", exit 0,
    no reports generated.
  - Pester/AST: AR-22.

**Review:** PASS (self — reuses existing distribution fns; WhatIf-by-default proven
to send nothing; upper rollup + bands + date period all delivered; additive).
**Backlog update:** AR-21 → DONE.

**Completed:** 2026-06-05 18:46:00
**Status:** SUCCESS

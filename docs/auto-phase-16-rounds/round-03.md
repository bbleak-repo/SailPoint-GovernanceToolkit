# Round 3
**Started:** 2026-05-30 23:21:56
Warning: no stdin data received in 3s, proceeding without it. If piping from a slow command, redirect stdin explicitly: < /dev/null to skip, or wait longer.
**P16-03 Identity Attribute Quality Score** -- done.

- `Measure-SPIdentityDataQuality` in SP.AuditQueries.psm1 -- queries `/v3/public-identities`, checks required attribute completeness, detects manager self-references, duplicate emails, stale profiles, and computes per-identity quality scores (0-100) with grade distribution (A-F).
- `Export-SPIdentityDataQualityHtml` in SP.AuditReportHtml.psm1 -- summary card with overall grade, attribute completeness bar chart, grade distribution table, quality issues callouts, per-identity issue table, and recommendations.
- Exports added to SP.Audit.psd1 and module member exports.

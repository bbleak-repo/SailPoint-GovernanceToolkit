# Round 9
**Started:** 2026-06-05 17:50:00
**Item:** AR-09 — port roster (B01) + access-cert attestation (B02)

**Read:** B01/B02 signatures (standard `-GroupResults -OutputPath -Title -Theme`;
B02's attestation cover sheet — scope/review-period/control-owner/signature lines —
is generated internally, not parameters).

**Did:** Copied B01/B02 **verbatim** into `BaselineReports/`; added them to the
`SP.BaselineReports.psm1` loader + the manifest `FunctionsToExport`. Functions:
`Export-MembershipSnapshotRosterReport`, `Export-AccessCertificationAttestationReport`.

**Files:** `BaselineReports/B01-*.ps1`, `B02-*.ps1` (new, verbatim);
`SP.BaselineReports.psm1`, `SP.AdaptiveReports.psd1` (updated).

**Verification:** both render valid HTML from adapter GroupResults (Roster 4.7 KB,
Access-Cert 9.7 KB). Manifest OK; 8 functions export. Formal Pester: AR-11.

**Review:** PASS (self — verbatim port; additive).
**Backlog update:** AR-09 → DONE.

**Completed:** 2026-06-05 17:56:00
**Status:** SUCCESS

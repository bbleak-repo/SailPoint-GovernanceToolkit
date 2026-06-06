# SP.BaselineReports.psm1 -- loads the ported baseline report library.
#
# The B0x report files under .\BaselineReports are VERBATIM copies of the
# Group-Enumerator BaselineReports (AR-08..AR-10). Each is fully self-contained:
# its helpers are B0x-prefixed (no cross-file collisions) and it has no external
# dependencies (no dot-sourcing, no RC-framework calls, no shared modules), so
# dot-sourcing them all into this one module scope is safe. Each renders the
# generic RC GroupResults shape (produced by Build-SPRCDataset), so it works for
# either the entitlement or campaign anchor.
#
# Only the public Export-*Report functions are exported (the B0x helpers stay
# module-private). The reports render whatever GroupResults they are handed, so
# the original (AD-flavoured) function names are kept verbatim; the CLI/GUI map
# friendly keys (inventory, privileged, orphaned, exec-summary, ...) onto them.

$here = $PSScriptRoot
$bdir = Join-Path $here 'BaselineReports'

foreach ($b in @(
    'B01-membership-snapshot-roster.ps1',
    'B02-access-certification-attestation.ps1',
    'B03-privileged-group-review.ps1',
    'B04-sod-toxic-comembership.ps1',
    'B05-orphaned-disabled-members.ps1',
    'B06-group-inventory-catalog.ps1',
    'B10-governance-executive-summary.ps1'
)) {
    . (Join-Path $bdir $b)
}

Export-ModuleMember -Function @(
    'Export-MembershipSnapshotRosterReport',        # B01
    'Export-AccessCertificationAttestationReport',  # B02
    'Export-PrivilegedGroupReviewReport',           # B03
    'Export-SodToxicComembershipReport',            # B04
    'Export-OrphanedDisabledMembersReport',         # B05
    'Export-GroupInventoryCatalogReport',           # B06
    'Export-GovernanceExecutiveSummaryReport'       # B10
)

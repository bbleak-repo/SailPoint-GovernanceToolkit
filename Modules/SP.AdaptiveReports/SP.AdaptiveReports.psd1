@{
    NestedModules        = @('SP.RCDataset.psm1', 'SP.BaselineReports.psm1')
    ModuleVersion        = '1.0.0'
    GUID                 = '1d9e2502-2f73-4c52-ad96-252e5fd61415'
    Author               = 'SailPoint ISC Governance Toolkit'
    CompanyName          = 'SailPoint ISC Governance Toolkit'
    Copyright            = '(c) 2026 SailPoint ISC Governance Toolkit. All rights reserved.'
    Description          = 'Adaptive-report data adapters (Build-SPRCDataset: entitlement / campaign anchors) plus the ported baseline report library (B0x), rendering the RC GroupResults shape. Pairs with SP.ReportComponents.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')
    # SP.Shared is auto-imported by SP.BaselineReports if not already loaded.
    RequiredModules      = @()
    FunctionsToExport    = @(
        'Build-SPRCDataset',
        'Export-MembershipSnapshotRosterReport',        # B01
        'Export-AccessCertificationAttestationReport',  # B02
        'Export-PrivilegedGroupReviewReport',           # B03
        'Export-SodToxicComembershipReport',            # B04
        'Export-OrphanedDisabledMembersReport',         # B05
        'Export-GroupInventoryCatalogReport',           # B06
        'Export-GovernanceExecutiveSummaryReport'       # B10
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}

@{
    # Module GUID
    GUID              = '9cf32c9d-73ec-4df9-adcb-7502d51725eb'

    # Module version
    ModuleVersion     = '1.0.0'

    # Minimum PowerShell version
    PowerShellVersion = '5.1'

    # Module author and description
    Author            = 'SailPoint ISC Governance Toolkit'
    CompanyName       = 'Internal'
    Description       = 'SailPoint ISC Governance Toolkit - ISC Reconciliation Module. Produces the ISC-side operand for the cross-project AD <-> ISC <-> HR reconciliation contract: a self-describing, employeeID-keyed export of identities, lifecycle state, cert-reviewer routing and governed entitlements, with provenance + SHA-256 content hash, that a future merge joins against the AD and HR exports to surface drift.'
    Copyright         = '(c) 2026. All rights reserved.'

    # SP.Core must be imported before SP.Reconciliation when the export runner resolves config /
    # logs (Get-SPConfig / Write-SPLog). SP.Shared is auto-imported by SP.IscReconciliation if not already loaded.
    # The pure builder (Build-SPIscReconciliationModel) has no toolkit dependency.
    # RequiredModules is empty to avoid PSModulePath resolution failures in
    # non-standard deployment layouts (caller handles import order).
    RequiredModules   = @()

    # Sub-modules loaded as part of this module. SP.IscReconciliation (the pure model builder +
    # exporter) loads first; SP.IscReconciliationSource (fetch + non-expiring cache) reuses its
    # Get-SPReconProp helper, so it must load AFTER.
    NestedModules     = @(
        'SP.IscReconciliation.psm1'
        'SP.IscReconciliationSource.psm1'
    )

    # Public functions exported by this module
    FunctionsToExport = @(
        # SP.IscReconciliation - pure model builder + exporter
        'Build-SPIscReconciliationModel'
        'Save-SPIscReconciliationExport'
        'Resolve-SPIscJoinKey'

        # SP.IscReconciliationSource - ISC fetch + non-expiring cache
        'ConvertTo-SPIscIdentityRecord'
        'Expand-SPIscEntitlementMembers'
        'Get-SPIscReconciliationData'
        'Save-SPIscReconCache'
        'Get-SPIscReconCache'
    )

    # Do not export variables or aliases from nested modules
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}

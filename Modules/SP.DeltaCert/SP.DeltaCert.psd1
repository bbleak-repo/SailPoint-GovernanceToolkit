@{
    # Module GUID
    GUID              = 'f4a82c17-9e3b-4d61-b5f8-0c7a1e6d2948'

    # Module version
    ModuleVersion     = '1.1.0'

    # Minimum PowerShell version
    PowerShellVersion = '5.1'

    # Module author and description
    Author            = 'SailPoint ISC Governance Toolkit'
    CompanyName       = 'Internal'
    Description       = 'SailPoint ISC Governance Toolkit - AD Delta Certification Module. Identifies newly-granted AD entitlements via account-activity events, groups affected active identities by manager, and creates targeted SEARCH-type certification campaigns so each manager reviews only their direct reports who received new AD access.'
    Copyright         = '(c) 2026. All rights reserved.'

    # SP.Core and SP.Api must be imported before SP.DeltaCert (caller handles import order).
    # SP.DeltaCertQueries calls Write-SPLog (SP.Core) and Invoke-SPApiRequest (SP.Api).
    # SP.DeltaCertRunner calls New-SPCampaign and Start-SPCampaign (SP.Api).
    # RequiredModules is empty to avoid PSModulePath resolution failures in
    # non-standard deployment layouts.
    RequiredModules   = @()

    # Sub-modules loaded as part of this module
    NestedModules     = @(
        'SP.DeltaCertQueries.psm1'
        'SP.DeltaCertRunner.psm1'
        'SP.DeltaCertReport.psm1'
    )

    # Public functions exported by this module
    FunctionsToExport = @(
        # SP.DeltaCertQueries - Data retrieval and query functions
        'Get-SPDeltaGrantEvents'
        'Select-SPPrivilegedGrantEvents'
        'Get-SPDeltaAffectedIdentities'
        'Group-SPDeltaByManager'
        'Get-SPDeltaCertStaleCertifications'
        'Get-SPDeltaIdentityDetail'
        'Get-SPDeltaManagersForSources'
        'Build-SPOrgTree'
        'Import-SPOrgChartSupplement'
        'Merge-SPOrgTreeWithSupplement'
        'Show-SPOrgTree'
        'Show-SPCampaignOrgPreview'
        'Show-SPReportDistributionPreview'
        'Export-SPOrgChartHtml'
        'Resolve-SPIdentityBand'
        'Get-SPOrgChartGaps'

        # SP.DeltaCertRunner - Campaign orchestration
        'Invoke-SPDeltaCertRun'
        'Invoke-SPDeltaCertFullRun'
        'Invoke-SPDeltaCertCleanup'
        'Invoke-SPDeltaCertEscalate'
        'Test-SPDeltaCertBaselineExists'

        # SP.DeltaCertReport - Delta report generation
        'Get-SPDeltaReportData'
        'Export-SPDeltaReportHtml'
    )

    # Do not export variables or aliases from nested modules
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}

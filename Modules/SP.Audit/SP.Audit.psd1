@{
    # Module GUID
    GUID              = '7e0487c0-2196-49e8-89c9-2395335cb139'

    # Module version
    ModuleVersion     = '1.0.0'

    # Minimum PowerShell version
    PowerShellVersion = '5.1'

    # Module author and description
    Author            = 'SailPoint ISC Governance Toolkit'
    CompanyName       = 'Internal'
    Description       = 'SailPoint ISC Governance Toolkit - Campaign Audit Module. Provides query, categorization, and report generation functions for campaign access review audits. Produces HTML (Word-compatible), plain-text, and JSONL audit trail outputs for compliance evidence.'
    Copyright         = '(c) 2026. All rights reserved.'

    # SP.Core and SP.Api must be imported before SP.Audit (caller handles import order).
    # SP.Audit calls Write-SPLog (SP.Core) and may call Invoke-SPApiRequest (SP.Api)
    # indirectly through the query module. RequiredModules is empty to avoid
    # PSModulePath resolution failures in non-standard deployment layouts.
    RequiredModules   = @()

    # Sub-modules loaded as part of this module
    NestedModules     = @(
        'SP.AuditQueries.psm1'
        'SP.AuditReport.psm1'
    )

    # Public functions exported by this module
    FunctionsToExport = @(
        # SP.AuditQueries - Data retrieval and query functions
        'Get-SPAuditCampaigns'
        'Get-SPAuditCertifications'
        'Get-SPAuditCertificationItems'
        'Get-SPAuditCampaignReport'
        'Import-SPAuditCampaignReport'
        'Get-SPAuditIdentityEvents'

        # SP.AuditReport - Categorization functions
        'Group-SPAuditDecisions'
        'Group-SPReviewerActions'
        'Group-SPAuditIdentityEvents'
        'Group-SPAuditRemediationProof'
        'Measure-SPAuditReviewerMetrics'

        # SP.AuditReport - Export functions
        'Export-SPAuditHtml'
        'Export-SPAuditText'
        'Export-SPAuditJsonl'
    )

    # Do not export variables or aliases from nested modules
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}

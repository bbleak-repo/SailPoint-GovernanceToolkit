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
        'Resolve-SPAuditIdentityAccounts'
        'Get-SPReviewerWorkload'
        'Get-SPIdentityDecisionHistory'
        'Get-SPSourceCampaignCoverage'

        # SP.AuditReport - Categorization functions
        'Group-SPAuditDecisions'
        'Group-SPReviewerActions'
        'Group-SPAuditIdentityEvents'
        'Group-SPAuditRemediationProof'
        'Measure-SPAuditReviewerMetrics'
        'Measure-SPAuditRubberStampRisk'
        'Measure-SPCampaignMetrics'
        'Get-SPAuditRiskFlags'
        'Group-SPAuditByLeadership'

        # SP.AuditReport - Export functions
        'Export-SPAuditHtml'
        'Export-SPAuditText'
        'Export-SPAuditJsonl'
        'Export-SPLeadershipExecutiveHtml'
        'Export-SPLeadershipDirectorHtml'
        'Export-SPLeadershipLevelHtml'
        'Send-SPReport'

        # SP.AuditReport - Comparison functions
        'Compare-SPCampaigns'
        'Export-SPCampaignComparisonHtml'

        # SP.AuditReport - Audit Trail Consolidator (P11-02)
        'Get-SPAuditTrail'
        'Export-SPAuditTrailHtml'

        # SP.AuditReport - CSV Export (P11-03)
        'Export-SPAuditCsv'

        # SP.AuditQueries - Remediation Verification (P11-04)
        'Get-SPRemediationStatus'

        # SP.AuditReport - Campaign Trend Analytics (P11-06)
        'Measure-SPCampaignTrends'
        'Export-SPCampaignTrendHtml'

        # SP.AuditQueries - Entitlement Inventory (P11-07)
        'Get-SPEntitlementInventory'

        # SP.AuditReport - Entitlement Inventory HTML (P11-07)
        'Export-SPEntitlementInventoryHtml'

        # SP.AuditReport - Cross-Campaign Reviewer Analysis (P11-08)
        'Measure-SPReviewerReputation'

        # SP.AuditReport - Compliance Evidence Package (P12-01)
        'Export-SPCompliancePackage'

        # SP.AuditReport - Identity Risk Scoring (P12-02)
        'Measure-SPIdentityRisk'
        'Export-SPIdentityRiskHtml'

        # SP.AuditReport - Source Governance Scorecard (P12-03)
        'Measure-SPSourceGovernance'
        'Export-SPSourceGovernanceHtml'

        # SP.AuditQueries - Stale Access Detector (P12-04)
        'Get-SPStaleAccess'

        # SP.AuditReport - Stale Access HTML (P12-04)
        'Export-SPStaleAccessHtml'

        # SP.AuditReport - Campaign Completion Report (P12-05)
        'Export-SPCampaignCompletionReport'

        # SP.AuditReport - Notification Dispatcher (P12-06)
        'Send-SPNotification'
        'Send-SPWebhook'
    )

    # Do not export variables or aliases from nested modules
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}

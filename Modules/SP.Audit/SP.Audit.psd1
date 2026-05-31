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
    # Order: Queries first, then Core (grouping/metrics), Analytics (trends/risk),
    # Html (all exports), Operations (notification/retention/compliance)
    NestedModules     = @(
        'SP.AuditQueries.psm1'
        'SP.AuditReportCore.psm1'
        'SP.AuditAnalytics.psm1'
        'SP.AuditReportHtml.psm1'
        'SP.AuditOperations.psm1'
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

        # SP.AuditReportCore - Categorization and metrics
        'Group-SPAuditDecisions'
        'Group-SPReviewerActions'
        'Group-SPAuditIdentityEvents'
        'Group-SPAuditRemediationProof'
        'Measure-SPAuditReviewerMetrics'
        'Measure-SPAuditRubberStampRisk'
        'Measure-SPCampaignMetrics'
        'Get-SPAuditRiskFlags'
        'Group-SPAuditByLeadership'

        # SP.AuditAnalytics - Trends, risk scoring, comparison
        'Compare-SPCampaigns'
        'Get-SPAuditTrail'
        'Measure-SPCampaignTrends'
        'Measure-SPReviewerReputation'
        'Measure-SPIdentityRisk'
        'Measure-SPSourceGovernance'

        # SP.AuditReportHtml - HTML, text, CSV, JSONL exports
        'Export-SPAuditHtml'
        'Export-SPAuditText'
        'Export-SPAuditJsonl'
        'Export-SPLeadershipExecutiveHtml'
        'Export-SPLeadershipDirectorHtml'
        'Export-SPLeadershipLevelHtml'
        'Export-SPLeadershipBandHtml'
        'Export-SPCampaignComparisonHtml'
        'Export-SPAuditTrailHtml'
        'Export-SPAuditCsv'
        'Export-SPCampaignTrendHtml'
        'Export-SPEntitlementInventoryHtml'
        'Export-SPAccessProfileInventoryHtml'
        'Export-SPRoleInventoryHtml'
        'Export-SPIdentityRiskHtml'
        'Export-SPSourceGovernanceHtml'
        'Export-SPStaleAccessHtml'
        'Export-SPCampaignCompletionReport'
        'Export-SPOrchestratorHistoryHtml'
        'Export-SPGovernanceBIData'

        # SP.AuditOperations - Notification, retention, compliance
        'Send-SPReport'
        'Export-SPCompliancePackage'
        'Send-SPWebhook'
        'Send-SPNotification'
        'Get-SPOrchestratorHistory'
        'Invoke-SPLogRetention'

        # SP.AuditQueries - Remediation Verification (P11-04)
        'Get-SPRemediationStatus'

        # SP.AuditQueries - Entitlement Inventory (P11-07)
        'Get-SPEntitlementInventory'

        # SP.AuditQueries - Stale Access Detector (P12-04)
        'Get-SPStaleAccess'

        # SP.AuditQueries - Access Profile Inventory (P13-01)
        'Get-SPAccessProfileInventory'

        # SP.AuditQueries - Role Inventory (P13-02)
        'Get-SPRoleInventory'

        # SP.AuditQueries - SoD Violation Scanner (P15-01)
        'Get-SPSodPolicies'
        'Get-SPSodViolations'

        # SP.AuditReportHtml - SoD Violation Report (P15-01)
        'Export-SPSodViolationHtml'

        # SP.AuditQueries - Entitlement Ownership Health (P15-02)
        'Get-SPEntitlementOwnershipHealth'

        # SP.AuditReportHtml - Entitlement Ownership Health Report (P15-02)
        'Export-SPOwnershipHealthHtml'

        # SP.AuditReportHtml - Access Request Activity Report (P15-03)
        'Export-SPAccessRequestHtml'

        # SP.AuditReportHtml - Bulk Remediation Ticket Export (P15-04)
        'Export-SPRemediationTickets'

        # SP.AuditReportHtml - SIEM Event Export (P15-05)
        'Export-SPAuditCef'
        'Export-SPAuditSiemJson'
    )

    # Do not export variables or aliases from nested modules
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}

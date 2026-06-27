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
    # SP.Shared is auto-imported by nested modules if not already loaded.
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
        'SP.CampaignDelta.psm1'
        'SP.CampaignDiff.psm1'
        'SP.CampaignTrend.psm1'
        'SP.GovernanceTrendQuery.psm1'
        'SP.CampaignVelocity.psm1'
        'SP.CertTracker.psm1'
        'SP.ReviewerAccountability.psm1'
    )

    # Public functions exported by this module
    FunctionsToExport = @(
        # SP.AuditQueries - Data retrieval and query functions
        'Get-SPAuditCampaigns'
        'Get-SPAuditCertifications'
        'Get-SPAuditCertificationItems'
        'Get-SPCachedCampaignItems'
        'Get-SPCachedCampaignRoster'
        'Get-SPAuditEffectiveCacheTtl'
        'Clear-SPAuditItemCache'
        'Clear-SPAuditAccountCache'
        'Get-SPAuditCampaignReport'
        'Import-SPAuditCampaignReport'
        'Get-SPAuditIdentityEvents'
        'Resolve-SPAuditIdentityAccounts'
        'Get-SPReviewerWorkload'
        'Get-SPIdentityDecisionHistory'
        'Get-SPSourceCampaignCoverage'

        # SP.AuditReportCore - Categorization and metrics
        'Group-SPAuditDecisions'
        'Test-SPConnectedADSource'
        'Get-SPRevocationDisposition'
        'Group-SPReviewerActions'
        'Group-SPCompletedPendingByReviewer'
        'Resolve-SPCaptureDateKey'
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

        # SP.AuditReportHtml - Rolling 7/30-day manager-cert trend HTML (T-06)
        'Export-SPRollingTrendHtml'

        # SP.AuditReportCore + SP.AuditReportHtml - Hierarchical Leadership Rollup (P17-01)
        'Build-SPLeadershipHierarchy'
        'Export-SPHierarchicalLeadershipHtml'
        'Export-SPMasterLeadershipHtml'

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

        # SP.AuditQueries - Configuration Snapshot (P14-06)
        'Save-SPConfigurationSnapshot'
        'Get-SPConfigurationSnapshot'

        # SP.AuditAnalytics - Identity Access Spread (P13-03)
        'Get-SPIdentityAccessSpread'

        # SP.AuditReportHtml - Identity Access Spread Report (P13-03)
        'Export-SPIdentityAccessSpreadHtml'

        # SP.AuditAnalytics - Remediation Priority Queue (P14-02)
        'Get-SPRemediationPriority'

        # SP.AuditReportHtml - Remediation Priority Report (P14-02)
        'Export-SPRemediationPriorityHtml'

        # SP.AuditAnalytics - Governance Maturity Scorecard (P14-01)
        'Measure-SPGovernanceMaturity'

        # SP.AuditReportHtml - Governance Maturity Report (P14-01)
        'Export-SPGovernanceMaturityHtml'

        # SP.AuditAnalytics - Audit Period Comparison (P13-06)
        'Compare-SPAuditPeriods'

        # SP.AuditReportHtml - Audit Period Comparison Report (P13-06)
        'Export-SPAuditPeriodComparisonHtml'

        # SP.AuditAnalytics - Governance Policy Engine (P13-04)
        'Test-SPGovernancePolicy'

        # SP.AuditQueries - Orphan Account Detector (P16-01)
        'Get-SPOrphanAccounts'

        # SP.AuditReportHtml - Orphan Account Report (P16-01)
        'Export-SPOrphanAccountHtml'

        # SP.AuditQueries - Source Aggregation Health Monitor (P16-02)
        'Get-SPSourceAggregationHealth'

        # SP.AuditReportHtml - Source Aggregation Health Report (P16-02)
        'Export-SPSourceAggregationHealthHtml'

        # SP.AuditQueries - Identity Data Quality (P16-03)
        'Measure-SPIdentityDataQuality'

        # SP.AuditReportHtml - Identity Data Quality Report (P16-03)
        'Export-SPIdentityDataQualityHtml'

        # SP.AuditAnalytics - Campaign Coverage Gap Analysis (P16-04)
        'Get-SPCampaignCoverageGaps'

        # SP.AuditReportHtml - Campaign Coverage Gap Report (P16-04)
        'Export-SPCampaignCoverageGapHtml'

        # SP.AuditAnalytics - Campaign Completion Forecast (P16-05)
        'Get-SPCampaignCompletionForecast'

        # SP.AuditReportHtml - Campaign Completion Forecast Report (P16-05)
        'Export-SPCampaignCompletionForecastHtml'

        # SP.AuditOperations - Governance Metrics Time Series (P16-06)
        'Save-SPGovernanceMetrics'
        'Get-SPGovernanceMetrics'
        'Get-SPGovernanceMetricsTrend'

        # SP.AuditQueries - Reviewer Delegation Audit Trail (P16-07)
        'Get-SPReviewerDelegations'

        # SP.AuditReportHtml - Reviewer Delegation Report (P16-07)
        'Export-SPReviewerDelegationHtml'

        # SP.AuditReportHtml - Policy Compliance Report (P13-05 / DF-01)
        'Export-SPPolicyComplianceHtml'

        # SP.AuditOperations - Governance Dashboard Data Export (P13-08 / DF-02)
        'Export-SPGovernanceDashboardData'

        # SP.AuditOperations - Audit Evidence Integrity Chain (P14-03 / DF-05)
        'New-SPAuditEvidenceChain'

        # SP.AuditQueries - Source Onboarding Readiness (P14-04 / DF-06)
        'Test-SPSourceOnboardingReadiness'

        # SP.AuditAnalytics - Configuration Drift Comparison (P14-07 / DF-07)
        'Compare-SPConfigurationSnapshots'

        # SP.AuditReportHtml - Configuration Drift Report (P14-07 / DF-07)
        'Export-SPConfigDriftHtml'

        # SP.AuditOperations - Bulk Remediation Ticket Export (P15-04 / DF-09)
        'Export-SPRemediationTickets'

        # SP.CampaignDelta - Dated campaign snapshots (diff/trend foundation)
        'Build-SPCampaignSnapshotData'
        'Save-SPCampaignSnapshot'
        'Get-SPCampaignSnapshot'
        'Get-SPCampaignSnapshotList'
        'Get-SPCampaignPreviousSnapshot'
        'Get-SPCampaignSnapshotSet'
        'Remove-SPCampaignOldSnapshots'
        'Test-SPCampaignSnapshotIntegrity'

        # SP.CampaignDiff - Snapshot comparison + diff reporting (completion/scope/compliance)
        'Compare-SPCampaignSnapshots'
        'Export-SPCampaignCompletionDiffHtml'
        'Export-SPCampaignScopeDiffHtml'
        'Export-SPCampaignDiffCsv'
        'Split-SPCampaignDiffByDirector'
        'Export-SPCampaignDiffByDirectorHtml'

        # SP.CampaignDiff - Per-entitlement decision history (N snapshots)
        'Get-SPEntitlementHistory'
        'Export-SPEntitlementHistoryHtml'
        'Export-SPEntitlementHistoryCsv'

        # SP.CampaignTrend - Per-campaign KPI time-series (rate trend, daily/weekly/monthly)
        'Save-SPCampaignTrendPoint'
        'Get-SPCampaignTrend'
        'Get-SPCampaignReviewerTrend'
        'Export-SPCampaignTrendHtml'
        'Get-SPProgramTrend'
        'Export-SPProgramTrendHtml'

        # SP.GovernanceTrendQuery - Unified trend query layer (dashboard KPIs, comparisons, alerts)
        'Get-SPGovernanceDashboardData'
        'Compare-SPGovernancePeriods'
        'Get-SPGovernanceAlerts'

        # SP.AuditReportHtml - Governance Trend Dashboard (Phase 5)
        'Export-SPGovernanceDashboardHtml'

        # SP.ReviewerAccountability - Cross-campaign stalled reviewer detection
        'Get-SPStalledReviewers'
        'Export-SPStalledReviewerHtml'

        # SP.CampaignVelocity - Opt-in review-velocity advisory (rubber-stamp prompt)
        'Measure-SPReviewerVelocity'
        'Export-SPReviewerVelocityHtml'

        # SP.CertTracker - Executive certification progress tracker (pace/stage/projection)
        'Build-SPCertTrackerData'
        'Export-SPCertTrackerHtml'
        'Export-SPAttestationEvidenceHtml'
    )

    # Do not export variables or aliases from nested modules
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}

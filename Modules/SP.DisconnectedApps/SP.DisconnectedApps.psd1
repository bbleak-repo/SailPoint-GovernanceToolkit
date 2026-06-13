@{
    # Module GUID
    GUID              = 'a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d'

    # Module version
    ModuleVersion     = '1.0.0'

    # Minimum PowerShell version
    PowerShellVersion = '5.1'

    # Module author and description
    Author            = 'SailPoint ISC Governance Toolkit'
    CompanyName       = 'Internal'
    Description       = 'SailPoint ISC Governance Toolkit - Disconnected Application Module. Validates disconnected app CSV files, compares snapshots for delta detection, creates certification campaigns for orphaned accounts, tracks remediation, generates risk and SLA reports, and pushes account/entitlement data to ISC via API or file drop.'
    Copyright         = '(c) 2026. All rights reserved.'

    # SP.Core and SP.Api must be imported before SP.DisconnectedApps (caller handles import order).
    # SP.Shared is auto-imported by SP.DisconnectedAppReports and SP.DisconnectedAppRunner if not already loaded.
    # SP.DisconnectedAppRunner calls Write-SPLog (SP.Core) and Invoke-SPApiRequest (SP.Api).
    # RequiredModules is empty to avoid PSModulePath resolution failures in
    # non-standard deployment layouts.
    RequiredModules   = @()

    # Sub-modules loaded as part of this module
    # Load order: Validator/Snapshot/Delta are independent; Runner before Analytics
    # and Reports (Analytics/Reports call Get-SPRegisteredApps and
    # Get-SPRemediationReport from Runner).
    NestedModules     = @(
        'SP.DisconnectedAppValidator.psm1'
        'SP.DisconnectedAppSnapshot.psm1'
        'SP.DisconnectedAppDelta.psm1'
        'SP.DisconnectedAppRunner.psm1'
        'SP.DisconnectedAppAnalytics.psm1'
        'SP.DisconnectedAppReports.psm1'
    )

    # Public functions exported by this module
    FunctionsToExport = @(
        # SP.DisconnectedAppValidator - File validation
        'Test-SPFileIsUtf8'
        'Get-SPCsvColumnsFromHeader'
        'Test-SPDisconnectedAppAccountFile'
        'Test-SPDisconnectedAppEntitlementFile'
        'Test-SPDisconnectedAppCrossReference'

        # SP.DisconnectedAppSnapshot - Snapshot management
        'Save-SPDisconnectedAppSnapshot'
        'Get-SPDisconnectedAppPreviousSnapshot'
        'Remove-SPDisconnectedAppOldSnapshots'

        # SP.DisconnectedAppDelta - Delta comparison
        'Compare-SPDisconnectedAppFiles'
        'Test-SPDisconnectedAppDeletionThreshold'

        # SP.DisconnectedAppRunner - Core pipeline (identity resolution, campaigns,
        # registry, remediation, ISC integration, alerting, cleanup, escalation)
        'Search-SPIdentityByAttribute'
        'Write-SPDisconnectedAppAuditEvent'
        'Resolve-SPDisconnectedAppIdentities'
        'Invoke-SPDisconnectedAppCertRun'
        'Get-SPRegisteredApps'
        'Initialize-SPDisconnectedAppDirectories'
        'New-SPRemediationRecord'
        'Update-SPRemediationStatus'
        'Get-SPRemediationReport'
        'Push-SPDisconnectedAppToISC'
        'Invoke-SPISCMultipartUpload'
        'Invoke-SPISCFileDrop'
        'Wait-SPISCAggregation'
        'Send-SPDisconnectedAppAlert'
        'Invoke-SPDisconnectedAppCleanup'
        'Invoke-SPDisconnectedAppEscalation'

        # SP.DisconnectedAppAnalytics - Data gathering and analysis
        'Get-SPDisconnectedAppDeliveryStatus'
        'Get-SPDisconnectedAppIdentityRisk'
        'Get-SPDisconnectedAppEntitlementCatalog'
        'Get-SPDisconnectedAppSlaStatus'
        'Get-SPDisconnectedAppCampaignDecisions'
        'Get-SPDisconnectedAppTrend'
        'Export-SPDisconnectedAppCompliancePackage'

        # SP.DisconnectedAppReports - HTML reports and dashboards
        'Export-SPDisconnectedAppDeltaHtml'
        'Export-SPDisconnectedAppIdentityRiskHtml'
        'Export-SPDisconnectedAppEntitlementCatalogHtml'
        'Export-SPDisconnectedAppBatchHtml'
        'Export-SPDisconnectedAppSlaHtml'
        'Export-SPDisconnectedAppDecisionHarvestHtml'
        'Export-SPDisconnectedAppTeamDashboard'
    )

    # Do not export variables or aliases from nested modules
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}

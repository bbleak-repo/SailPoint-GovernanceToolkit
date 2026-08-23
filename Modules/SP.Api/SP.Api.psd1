@{
    # Module GUID
    GUID              = 'a7f3c2e1-5b8d-4f6a-9c0e-2d1b3a4e5f7c'

    # Module version
    ModuleVersion     = '1.0.0'

    # Minimum PowerShell version
    PowerShellVersion = '5.1'

    # Module author and description
    Author            = 'SailPoint ISC Governance Toolkit'
    CompanyName       = 'Internal'
    Description       = 'SailPoint ISC Governance Toolkit - API Client Module. Provides rate-limited, retry-capable REST client plus campaign, certification, decision, source, and access-governance functions for the SailPoint ISC v3 API.'
    Copyright         = '(c) 2026. All rights reserved.'

    # Dependency: SP.Core must be imported before SP.Api (caller handles import order).
    # SP.Api calls Get-SPConfig, Get-SPAuthToken, and Write-SPLog from SP.Core.
    RequiredModules   = @()

    # Sub-modules loaded as part of this module
    NestedModules     = @(
        'SP.ApiClient.psm1'
        'SP.Campaigns.psm1'
        'SP.Certifications.psm1'
        'SP.Decisions.psm1'
        'SP.Sources.psm1'
        'SP.AccessGovernance.psm1'
    )

    # Public functions exported by this module
    FunctionsToExport = @(
        # SP.ApiClient
        'Invoke-SPApiRequest'

        # SP.Campaigns
        'New-SPCampaign'
        'Start-SPCampaign'
        'Get-SPCampaign'
        'Get-SPCampaignStatus'
        'Search-SPCampaigns'
        'Get-SPCampaignDeadlineStatus'
        'Complete-SPCampaign'
        'Get-SPCampaignHealth'

        # SP.Certifications
        'Get-SPCertifications'
        'Get-SPAllCertifications'
        'Get-SPAccessReviewItems'
        'Get-SPAllAccessReviewItems'

        # SP.Decisions
        'Invoke-SPBulkDecide'
        'Invoke-SPReassign'
        'Invoke-SPReassignAsync'
        'Invoke-SPSignOff'

        # SP.Sources
        'Get-SPSource'
        'Get-SPSources'
        'Get-SPEntitlements'
        'Start-SPAccountAggregation'
        'Start-SPEntitlementAggregation'
        'Get-SPProvisioningPolicies'

        # SP.AccessGovernance
        'New-SPAccessProfile'
        'Get-SPAccessProfiles'
        'New-SPRole'
        'Get-SPRoles'
        'New-SPTransform'
        'Set-SPTransform'
        'Get-SPTransforms'
    )

    # Do not export variables or aliases from nested modules
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()
}

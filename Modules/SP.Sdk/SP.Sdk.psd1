#
# Module manifest for SP.Sdk
#
# SDK-derived ISC feature extensions. Wraps SailPoint ISC API endpoints
# that are covered by the official PSSailpoint SDK (PS 6.2+) but reimplemented
# here for PS 5.1 compatibility, using the toolkit's existing infrastructure.
#
# Depends on: SP.Core (config, logging, auth), SP.Api (Invoke-SPApiRequest)
# Caller must import SP.Core and SP.Api before importing this module.
#

@{
    RootModule        = ''
    ModuleVersion     = '1.0.0'
    GUID              = 'b7e3a4f1-9c2d-4e8b-a6f0-1d3c5e7b9a2f'
    Author            = 'SailPoint Governance Toolkit'
    CompanyName       = ''
    Copyright         = '(c) 2026. All rights reserved.'
    Description       = 'SDK-derived ISC API extensions: campaign templates, certification summaries, approvals, work items, workflows.'
    PowerShellVersion = '5.1'

    # Caller handles SP.Core + SP.Api dependency via import order
    RequiredModules   = @()

    # Nested modules loaded in dependency order
    NestedModules     = @(
        'SP.SdkCommon.psm1',
        'SP.SdkPatch.psm1',
        'SP.SdkCampaignTemplates.psm1',
        'SP.SdkCertSummaries.psm1',
        'SP.SdkApprovals.psm1',
        'SP.SdkWorkItems.psm1',
        'SP.SdkWorkflows.psm1',
        'SP.SdkCampaignFilters.psm1'
    )

    FunctionsToExport = @(
        # SP.SdkCommon
        'Invoke-SPSdkPaginatedGet',

        # SP.SdkPatch
        'New-SPSdkPatchOp',
        'New-SPSdkPatchReplace',
        'ConvertTo-SPSdkPatchBody',

        # SP.SdkCampaignTemplates
        'Get-SPSdkCampaignTemplates',
        'Get-SPSdkCampaignTemplate',
        'New-SPSdkCampaignTemplate',
        'Update-SPSdkCampaignTemplate',
        'Remove-SPSdkCampaignTemplate',
        'Get-SPSdkTemplateSchedule',
        'Set-SPSdkTemplateSchedule',
        'Remove-SPSdkTemplateSchedule',

        # SP.SdkCertSummaries
        'Get-SPSdkIdentitySummaries',
        'Get-SPSdkAllIdentitySummaries',
        'Get-SPSdkIdentitySummary',
        'Get-SPSdkAccessSummaries',
        'Get-SPSdkAllAccessSummaries',
        'Get-SPSdkDecisionSummary',

        # SP.SdkApprovals
        'Get-SPSdkPendingApprovals',
        'Get-SPSdkAllPendingApprovals',
        'Get-SPSdkCompletedApprovals',
        'Get-SPSdkAllCompletedApprovals',
        'Get-SPSdkApprovalSummary',
        'Approve-SPSdkAccessRequest',
        'Deny-SPSdkAccessRequest',
        'Forward-SPSdkAccessRequest',

        # SP.SdkWorkItems
        'Get-SPSdkWorkItems',
        'Get-SPSdkAllWorkItems',
        'Get-SPSdkWorkItem',
        'Get-SPSdkWorkItemsSummary',
        'Get-SPSdkWorkItemCount',
        'Get-SPSdkCompletedWorkItems',
        'Get-SPSdkAllCompletedWorkItems',
        'Get-SPSdkCompletedWorkItemCount',
        'Complete-SPSdkWorkItem',
        'Approve-SPSdkApprovalItem',
        'Deny-SPSdkApprovalItem',
        'Forward-SPSdkWorkItem',
        'Invoke-SPSdkBulkApproveWorkItem',
        'Invoke-SPSdkBulkRejectWorkItem',
        'Submit-SPSdkAccountSelection',

        # SP.SdkWorkflows
        'New-SPSdkWorkflow',
        'Get-SPSdkWorkflows',
        'Get-SPSdkAllWorkflows',
        'Get-SPSdkWorkflow',
        'Update-SPSdkWorkflow',
        'Set-SPSdkWorkflow',
        'Remove-SPSdkWorkflow',
        'Test-SPSdkWorkflow',
        'Invoke-SPSdkExternalWorkflow',
        'Test-SPSdkExternalWorkflow',
        'New-SPSdkWorkflowExternalTrigger',
        'Get-SPSdkWorkflowExecutions',
        'Get-SPSdkWorkflowExecution',
        'Get-SPSdkWorkflowExecutionHistory',
        'Stop-SPSdkWorkflowExecution',
        'Get-SPSdkWorkflowLibraryActions',
        'Get-SPSdkWorkflowLibraryOperators',
        'Get-SPSdkWorkflowLibraryTriggers',
        'Set-SPSdkOOOFallbackWorkflow',

        # SP.SdkCampaignFilters
        'Get-SPSdkCampaignFilters',
        'Get-SPSdkAllCampaignFilters',
        'Get-SPSdkCampaignFilter',
        'New-SPSdkCampaignFilter',
        'Update-SPSdkCampaignFilter',
        'Remove-SPSdkCampaignFilter'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('SailPoint', 'ISC', 'IGA', 'SDK', 'Governance', 'CampaignTemplates', 'Workflows', 'WorkItems')
            ProjectUri = 'https://github.com/bbleak-repo/SailPoint-GovernanceToolkit'
        }
    }
}

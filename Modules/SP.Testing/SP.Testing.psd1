@{
    # Module identity
    GUID              = 'c4e8a1f2-7b3d-4e9a-8c5f-2d6e1a0b4c7f'
    ModuleVersion     = '1.0.0'
    PowerShellVersion = '5.1'

    # Authoring
    Author            = 'SailPoint ISC Governance Toolkit'
    CompanyName       = ''
    Copyright         = '(c) 2026. All rights reserved.'
    Description       = 'SailPoint ISC Governance Toolkit - Test Orchestration Module'

    # Dependency: SP.Core and SP.Api must be imported before SP.Testing (caller handles import order).
    RequiredModules   = @()

    # Sub-modules loaded when this manifest is imported
    NestedModules     = @(
        'SP.TestLoader.psm1',
        'SP.Assertions.psm1',
        'SP.Evidence.psm1',
        'SP.BatchRunner.psm1'
    )

    # Exported public functions
    FunctionsToExport = @(
        # SP.TestLoader
        'Import-SPTestIdentities',
        'Import-SPTestCampaigns',
        'Test-SPTestData',

        # SP.Assertions
        'Assert-SPCampaignStatus',
        'Assert-SPCertificationCount',
        'Assert-SPDecisionAccepted',
        'Assert-SPRemediationComplete',

        # SP.Evidence
        'New-SPCampaignEvidencePath',
        'Write-SPEvidenceEvent',
        'Export-SPCampaignReport',
        'Export-SPSuiteReport',

        # SP.BatchRunner
        'Invoke-SPTestSuite',
        'Invoke-SPSingleTest'
    )

    # Do not export variables or aliases
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()

    # Module metadata
    PrivateData = @{
        PSData = @{
            Tags         = @('SailPoint', 'ISC', 'Governance', 'Testing', 'Certification', 'UAT')
            ProjectUri   = ''
            ReleaseNotes = 'Initial release: Test orchestration for SailPoint ISC certification campaign UAT.'
        }
    }
}

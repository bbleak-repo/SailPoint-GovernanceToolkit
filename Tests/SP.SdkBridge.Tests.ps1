#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Pester tests for SP.SdkBridge module (SDK-to-GUI bridge adapter).
.DESCRIPTION
    Validates the bridge read functions and write dispatchers that adapt the
    SP.Sdk envelope layer for the WPF SDK Features tab. Asserts grid-bindable
    row shape (IsSelected, display columns, _Raw passthrough), State routing,
    items+summary aggregation, workflow enabled/trigger surfacing, action
    routing + argument validation, and the SDK-03 Safety gate (terminal verbs,
    bulk cap, non-gated routing-only verbs).

    ARCHITECTURE NOTE (plan disagreement, resolved in favour of the code):
    PHASE7_GUI_SDK_TAB.md Test Plan (~line 516) says "Mock Invoke-SPApiRequest
    at the module level". That is WRONG for the bridge layer. SP.SdkBridge.psm1
    does NOT call Invoke-SPApiRequest; it calls the SP.Sdk wrapper functions
    (Get-SPSdkCampaignTemplates, Get-SPSdkPendingApprovals, Approve-SPSdkAccessRequest,
    Update-SPSdkWorkflow, etc.), each of which already returns the
    @{Success;Data;Error} envelope. These tests therefore mock the SP.Sdk
    wrapper functions at -ModuleName SP.SdkBridge -- NOT Invoke-SPApiRequest.

    Test IDs: SDK-BR-001 through SDK-BR-007 plus SDK-03 Safety-gate cases.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    # -Core/-Api/-Sdk load the command NAMES so `Mock -ModuleName SP.SdkBridge`
    # can resolve them; -SdkBridge flat-imports the module under test (Bug-1).
    Import-SPTestModules -Core -Api -Sdk -SdkBridge
}

Describe 'SP.SdkBridge - SDK-to-GUI Bridge Adapter' {

    Context 'SDK-BR-001: Get-SPGuiSdkCampaignTemplates shapes rows + schedule status' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Get-SPSdkCampaignTemplates -ModuleName SP.SdkBridge {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id               = 'tpl-sched'
                            name             = 'Quarterly Access'
                            deadlineDuration = 'P14D'
                            modified         = '2026-05-01T00:00:00Z'
                            ownerRef         = [PSCustomObject]@{ name = 'Alice Owner' }
                        },
                        [PSCustomObject]@{
                            id               = 'tpl-unsched'
                            name             = 'Ad-hoc Review'
                            deadlineDuration = 'P7D'
                            modified         = '2026-05-02T00:00:00Z'
                            ownerRef         = [PSCustomObject]@{ name = 'Bob Owner' }
                        }
                    )
                    Error   = $null
                }
            }
            # Scheduled id returns Data=<obj>; the 404-style id returns Data=$null.
            Mock Get-SPSdkTemplateSchedule -ModuleName SP.SdkBridge -ParameterFilter { $TemplateId -eq 'tpl-sched' } {
                return @{ Success = $true; Data = [PSCustomObject]@{ cronString = '0 0 * * *' }; Error = $null }
            }
            Mock Get-SPSdkTemplateSchedule -ModuleName SP.SdkBridge -ParameterFilter { $TemplateId -eq 'tpl-unsched' } {
                return @{ Success = $true; Data = $null; Error = $null }
            }
        }

        It 'returns a success envelope with two display rows' {
            $result = Get-SPGuiSdkCampaignTemplates -CorrelationID 'sdk-br-001a'
            $result.Success    | Should -Be $true
            $result.Error      | Should -BeNullOrEmpty
            $result.Data.Count | Should -Be 2
        }

        It 'populates Name/Id/Deadline/Owner columns from the raw template' {
            $result = Get-SPGuiSdkCampaignTemplates -CorrelationID 'sdk-br-001b'
            $row = $result.Data | Where-Object { $_.Id -eq 'tpl-sched' }
            $row.Name     | Should -Be 'Quarterly Access'
            $row.Deadline | Should -Be 'P14D'
            $row.Owner    | Should -Be 'Alice Owner'
        }

        It 'marks every row IsSelected=$false and carries _Raw' {
            $result = Get-SPGuiSdkCampaignTemplates -CorrelationID 'sdk-br-001c'
            foreach ($row in $result.Data) {
                $row.PSObject.Properties.Name | Should -Contain 'IsSelected'
                $row.IsSelected | Should -Be $false
                $row._Raw       | Should -Not -BeNullOrEmpty
            }
        }

        It 'sets Scheduled=$true for a template with a schedule and $false for a 404 (Data=$null)' {
            $result = Get-SPGuiSdkCampaignTemplates -CorrelationID 'sdk-br-001d'
            $scheduled   = $result.Data | Where-Object { $_.Id -eq 'tpl-sched' }
            $unscheduled = $result.Data | Where-Object { $_.Id -eq 'tpl-unsched' }
            $scheduled.Scheduled   | Should -Be $true
            $unscheduled.Scheduled | Should -Be $false
        }

        It 'returns Success=false when the backing read fails' {
            Mock Get-SPSdkCampaignTemplates -ModuleName SP.SdkBridge {
                return @{ Success = $false; Data = $null; Error = 'Service unavailable' }
            }
            $result = Get-SPGuiSdkCampaignTemplates -CorrelationID 'sdk-br-001e'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-BR-002: Get-SPGuiSdkApprovals -State Pending' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Get-SPSdkPendingApprovals -ModuleName SP.SdkBridge {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            name         = 'Request A'
                            requestType  = 'GRANT_ACCESS'
                            created      = '2026-05-10T00:00:00Z'
                            requestedBy  = [PSCustomObject]@{ name = 'Requester One' }
                            requestedFor = [PSCustomObject]@{ name = 'Target One' }
                            owner        = [PSCustomObject]@{ name = 'Owner One' }
                        }
                    )
                    Error   = $null
                }
            }
            Mock Get-SPSdkCompletedApprovals -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = @(); Error = $null }
            }
        }

        It 'invokes the pending backing (not completed) and returns rows' {
            $result = Get-SPGuiSdkApprovals -State Pending -CorrelationID 'sdk-br-002a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 1
            Should -Invoke Get-SPSdkPendingApprovals -ModuleName SP.SdkBridge -Times 1 -Exactly
            Should -Invoke Get-SPSdkCompletedApprovals -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'emits the pending column set (RequestType/Created/Owner) with IsSelected and nested names' {
            $result = Get-SPGuiSdkApprovals -State Pending -CorrelationID 'sdk-br-002b'
            $row = $result.Data[0]
            $row.PSObject.Properties.Name | Should -Contain 'IsSelected'
            $row.PSObject.Properties.Name | Should -Contain 'RequestType'
            $row.PSObject.Properties.Name | Should -Contain 'Created'
            $row.PSObject.Properties.Name | Should -Contain 'Owner'
            $row.RequestType  | Should -Be 'GRANT_ACCESS'
            $row.Requester    | Should -Be 'Requester One'
            $row.RequestedFor | Should -Be 'Target One'
            $row.Owner        | Should -Be 'Owner One'
            $row._Raw         | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-BR-003: Get-SPGuiSdkApprovals -State Completed' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Get-SPSdkPendingApprovals -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = @(); Error = $null }
            }
            Mock Get-SPSdkCompletedApprovals -ModuleName SP.SdkBridge {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            name         = 'Completed A'
                            state        = 'APPROVED'
                            modified     = '2026-05-11T00:00:00Z'
                            requestedBy  = [PSCustomObject]@{ name = 'Requester Two' }
                            requestedFor = [PSCustomObject]@{ name = 'Target Two' }
                            reviewedBy   = [PSCustomObject]@{ name = 'Reviewer Two' }
                        }
                    )
                    Error   = $null
                }
            }
        }

        It 'invokes the completed backing (not pending) and returns rows' {
            $result = Get-SPGuiSdkApprovals -State Completed -CorrelationID 'sdk-br-003a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 1
            Should -Invoke Get-SPSdkCompletedApprovals -ModuleName SP.SdkBridge -Times 1 -Exactly
            Should -Invoke Get-SPSdkPendingApprovals -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'emits the completed column set (State/ReviewedBy/Modified) and NOT the pending-only columns' {
            $result = Get-SPGuiSdkApprovals -State Completed -CorrelationID 'sdk-br-003b'
            $row = $result.Data[0]
            $row.PSObject.Properties.Name | Should -Contain 'IsSelected'
            $row.PSObject.Properties.Name | Should -Contain 'State'
            $row.PSObject.Properties.Name | Should -Contain 'ReviewedBy'
            $row.PSObject.Properties.Name | Should -Contain 'Modified'
            $row.PSObject.Properties.Name | Should -Not -Contain 'RequestType'
            $row.PSObject.Properties.Name | Should -Not -Contain 'Created'
            $row.State      | Should -Be 'APPROVED'
            $row.ReviewedBy | Should -Be 'Reviewer Two'
        }
    }

    Context 'SDK-BR-004: Get-SPGuiSdkWorkItems returns rows + summary in one call' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Get-SPSdkWorkItems -ModuleName SP.SdkBridge {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            type        = 'APPROVAL'
                            description = 'Review access'
                            ownerName   = 'WI Owner'
                            state       = 'PENDING'
                            created     = '2026-05-12T00:00:00Z'
                            numItems    = 3
                        }
                    )
                    Error   = $null
                }
            }
            Mock Get-SPSdkWorkItemsSummary -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ open = 4; completed = 2; total = 6 }; Error = $null }
            }
        }

        It 'returns both .Data rows and .Summary from a single call' {
            $result = Get-SPGuiSdkWorkItems -CorrelationID 'sdk-br-004a'
            $result.Success         | Should -Be $true
            $result.Data.Count      | Should -Be 1
            $result.Summary.Open      | Should -Be 4
            $result.Summary.Completed | Should -Be 2
            $result.Summary.Total     | Should -Be 6
            Should -Invoke Get-SPSdkWorkItems -ModuleName SP.SdkBridge -Times 1 -Exactly
        }

        It 'shapes work-item rows with IsSelected, Type/Description/Owner/State/NumItems and _Raw' {
            $result = Get-SPGuiSdkWorkItems -CorrelationID 'sdk-br-004b'
            $row = $result.Data[0]
            $row.IsSelected  | Should -Be $false
            $row.Type        | Should -Be 'APPROVAL'
            $row.Description  | Should -Be 'Review access'
            $row.Owner       | Should -Be 'WI Owner'
            $row.State       | Should -Be 'PENDING'
            $row.NumItems    | Should -Be 3
            $row._Raw        | Should -Not -BeNullOrEmpty
        }

        It 'still returns rows with zeroed Summary when the summary call fails (non-fatal)' {
            Mock Get-SPSdkWorkItemsSummary -ModuleName SP.SdkBridge {
                return @{ Success = $false; Data = $null; Error = 'summary unavailable' }
            }
            $result = Get-SPGuiSdkWorkItems -CorrelationID 'sdk-br-004c'
            $result.Success           | Should -Be $true
            $result.Data.Count        | Should -Be 1
            $result.Summary.Open      | Should -Be 0
            $result.Summary.Completed | Should -Be 0
            $result.Summary.Total     | Should -Be 0
        }
    }

    Context 'SDK-BR-005: Get-SPGuiSdkWorkflows surfaces enabled + trigger type' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Get-SPSdkWorkflows -ModuleName SP.SdkBridge {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            name           = 'OOO Fallback'
                            id             = 'wf-001'
                            enabled        = $true
                            trigger        = [PSCustomObject]@{ type = 'EVENT' }
                            executionCount = 12
                            failureCount   = 1
                            modified       = '2026-05-13T00:00:00Z'
                        }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns Enabled (bool) and TriggerType columns from .enabled and .trigger.type' {
            $result = Get-SPGuiSdkWorkflows -CorrelationID 'sdk-br-005a'
            $row = $result.Data[0]
            $row.Enabled     | Should -BeOfType [bool]
            $row.Enabled     | Should -Be $true
            $row.TriggerType | Should -Be 'EVENT'
        }

        It 'surfaces ExecutionCount/FailureCount as ints with IsSelected and _Raw' {
            $result = Get-SPGuiSdkWorkflows -CorrelationID 'sdk-br-005b'
            $row = $result.Data[0]
            $row.ExecutionCount | Should -Be 12
            $row.FailureCount   | Should -Be 1
            $row.IsSelected     | Should -Be $false
            $row._Raw           | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-BR-006: Invoke-SPGuiSdkApprovalAction routes + validates args' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Approve-SPSdkAccessRequest -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ status = 'APPROVED' }; Error = $null }
            }
            Mock Deny-SPSdkAccessRequest -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ status = 'REJECTED' }; Error = $null }
            }
            Mock Forward-SPSdkAccessRequest -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ status = 'FORWARDED' }; Error = $null }
            }
        }

        It 'Approve routes to Approve-SPSdkAccessRequest' {
            $result = Invoke-SPGuiSdkApprovalAction -Action Approve -ApprovalId 'appr-1' -CorrelationID 'sdk-br-006a'
            $result.Success | Should -Be $true
            Should -Invoke Approve-SPSdkAccessRequest -ModuleName SP.SdkBridge -Times 1 -Exactly -ParameterFilter {
                $ApprovalId -eq 'appr-1'
            }
        }

        It 'Deny without -Comment returns Success=$false and does NOT invoke the backing' {
            $result = Invoke-SPGuiSdkApprovalAction -Action Deny -ApprovalId 'appr-1' -CorrelationID 'sdk-br-006b'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'requires -Comment'
            Should -Invoke Deny-SPSdkAccessRequest -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'Deny with -Comment routes to Deny-SPSdkAccessRequest' {
            $result = Invoke-SPGuiSdkApprovalAction -Action Deny -ApprovalId 'appr-1' -Comment 'No' -CorrelationID 'sdk-br-006c'
            $result.Success | Should -Be $true
            Should -Invoke Deny-SPSdkAccessRequest -ModuleName SP.SdkBridge -Times 1 -Exactly
        }

        It 'Forward without -NewOwnerId returns Success=$false and does NOT invoke' {
            $result = Invoke-SPGuiSdkApprovalAction -Action Forward -ApprovalId 'appr-1' -Comment 'fwd' -CorrelationID 'sdk-br-006d'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'requires -NewOwnerId'
            Should -Invoke Forward-SPSdkAccessRequest -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'Forward with -NewOwnerId and -Comment routes to Forward-SPSdkAccessRequest' {
            $result = Invoke-SPGuiSdkApprovalAction -Action Forward -ApprovalId 'appr-1' -NewOwnerId 'own-2' -Comment 'fwd' -CorrelationID 'sdk-br-006e'
            $result.Success | Should -Be $true
            Should -Invoke Forward-SPSdkAccessRequest -ModuleName SP.SdkBridge -Times 1 -Exactly -ParameterFilter {
                $NewOwnerId -eq 'own-2'
            }
        }

        It 'an out-of-set Action throws (ValidateSet guard)' {
            { Invoke-SPGuiSdkApprovalAction -Action 'Bogus' -ApprovalId 'appr-1' } | Should -Throw
        }
    }

    Context 'SDK-BR-007: Invoke-SPGuiSdkWorkflowAction routes + validates args' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock New-SPSdkPatchReplace -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ op = 'replace'; path = $Path; value = $Value }
            }
            Mock Update-SPSdkWorkflow -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'wf-1'; enabled = $true }; Error = $null }
            }
            Mock Test-SPSdkWorkflow -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ result = 'ok' }; Error = $null }
            }
            Mock Set-SPSdkOOOFallbackWorkflow -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'wf-ooo' }; Error = $null }
            }
        }

        It 'Toggle routes to Update-SPSdkWorkflow via a New-SPSdkPatchReplace op on /enabled' {
            $result = Invoke-SPGuiSdkWorkflowAction -Action Toggle -WorkflowId 'wf-1' -Enabled $true -CorrelationID 'sdk-br-007a'
            $result.Success | Should -Be $true
            Should -Invoke New-SPSdkPatchReplace -ModuleName SP.SdkBridge -Times 1 -Exactly -ParameterFilter {
                $Path -eq '/enabled'
            }
            Should -Invoke Update-SPSdkWorkflow -ModuleName SP.SdkBridge -Times 1 -Exactly
        }

        It 'Toggle without -Enabled returns Success=$false and does NOT invoke Update' {
            $result = Invoke-SPGuiSdkWorkflowAction -Action Toggle -WorkflowId 'wf-1' -CorrelationID 'sdk-br-007b'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'requires -Enabled'
            Should -Invoke Update-SPSdkWorkflow -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'Test without -TestInput returns Success=$false and does NOT invoke' {
            $result = Invoke-SPGuiSdkWorkflowAction -Action Test -WorkflowId 'wf-1' -CorrelationID 'sdk-br-007c'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'requires -TestInput'
            Should -Invoke Test-SPSdkWorkflow -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'Test with -TestInput routes to Test-SPSdkWorkflow' {
            $result = Invoke-SPGuiSdkWorkflowAction -Action Test -WorkflowId 'wf-1' -TestInput @{ k = 'v' } -CorrelationID 'sdk-br-007d'
            $result.Success | Should -Be $true
            Should -Invoke Test-SPSdkWorkflow -ModuleName SP.SdkBridge -Times 1 -Exactly
        }

        It 'CreateOOO without -FallbackReviewerId returns Success=$false and does NOT invoke' {
            $result = Invoke-SPGuiSdkWorkflowAction -Action CreateOOO -PrimaryReviewerId 'r-1' -CorrelationID 'sdk-br-007e'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'requires -FallbackReviewerId'
            Should -Invoke Set-SPSdkOOOFallbackWorkflow -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'CreateOOO with both reviewer ids routes to Set-SPSdkOOOFallbackWorkflow' {
            $result = Invoke-SPGuiSdkWorkflowAction -Action CreateOOO -PrimaryReviewerId 'r-1' -FallbackReviewerId 'r-2' -CorrelationID 'sdk-br-007f'
            $result.Success | Should -Be $true
            Should -Invoke Set-SPSdkOOOFallbackWorkflow -ModuleName SP.SdkBridge -Times 1 -Exactly -ParameterFilter {
                $PrimaryReviewerId -eq 'r-1' -and $FallbackReviewerId -eq 'r-2'
            }
        }
    }

    Context 'SDK-03 Safety: terminal verb gate (Template Delete)' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Remove-SPSdkCampaignTemplate -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'tpl-1' }; Error = $null }
            }
        }

        It 'blocks Template Delete when AllowCompleteCampaign=$false (backing invoked 0 times)' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $false; MaxCampaignsPerRun = 10 } }
            }
            $result = Invoke-SPGuiSdkTemplateAction -Action Delete -TemplateId 'tpl-1' -CorrelationID 'sdk-saf-001a'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'blocked by Safety'
            Should -Invoke Remove-SPSdkCampaignTemplate -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'proceeds with Template Delete when AllowCompleteCampaign=$true (backing invoked once)' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $true; MaxCampaignsPerRun = 10 } }
            }
            $result = Invoke-SPGuiSdkTemplateAction -Action Delete -TemplateId 'tpl-1' -CorrelationID 'sdk-saf-001b'
            $result.Success | Should -Be $true
            Should -Invoke Remove-SPSdkCampaignTemplate -ModuleName SP.SdkBridge -Times 1 -Exactly
        }
    }

    Context 'SDK-03 Safety: terminal verb gate (WorkItem Complete)' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Complete-SPSdkWorkItem -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'wi-1' }; Error = $null }
            }
        }

        It 'blocks WorkItem Complete when AllowCompleteCampaign=$false (backing invoked 0 times)' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $false; MaxCampaignsPerRun = 10 } }
            }
            $result = Invoke-SPGuiSdkWorkItemAction -Action Complete -WorkItemId 'wi-1' -CorrelationID 'sdk-saf-002a'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'blocked by Safety'
            Should -Invoke Complete-SPSdkWorkItem -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'proceeds with WorkItem Complete when AllowCompleteCampaign=$true (backing invoked once)' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $true; MaxCampaignsPerRun = 10 } }
            }
            $result = Invoke-SPGuiSdkWorkItemAction -Action Complete -WorkItemId 'wi-1' -CorrelationID 'sdk-saf-002b'
            $result.Success | Should -Be $true
            Should -Invoke Complete-SPSdkWorkItem -ModuleName SP.SdkBridge -Times 1 -Exactly
        }
    }

    Context 'SDK-03 Safety: bulk cap (Filter Delete)' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Remove-SPSdkCampaignFilter -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ deleted = 1 }; Error = $null }
            }
        }

        It 'refuses the whole Delete when count exceeds MaxCampaignsPerRun (no truncation)' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $true; MaxCampaignsPerRun = 2 } }
            }
            $result = Invoke-SPGuiSdkFilterAction -Action Delete -FilterId @('a', 'b', 'c') -CorrelationID 'sdk-saf-003a'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'blocked by Safety'
            $result.Error   | Should -Match '3'
            $result.Error   | Should -Match '2'
            Should -Invoke Remove-SPSdkCampaignFilter -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'proceeds with Delete when count is within MaxCampaignsPerRun' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $true; MaxCampaignsPerRun = 2 } }
            }
            $result = Invoke-SPGuiSdkFilterAction -Action Delete -FilterId @('a', 'b') -CorrelationID 'sdk-saf-003b'
            $result.Success | Should -Be $true
            Should -Invoke Remove-SPSdkCampaignFilter -ModuleName SP.SdkBridge -Times 1 -Exactly
        }
    }

    Context 'SDK-03 Safety: non-gated routing-only verbs proceed' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            # Gate reads config; force the most restrictive setting to prove these verbs are ungated.
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $false; MaxCampaignsPerRun = 10 } }
            }
            Mock Approve-SPSdkAccessRequest -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ status = 'APPROVED' }; Error = $null }
            }
            Mock New-SPSdkPatchReplace -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ op = 'replace'; path = $Path; value = $Value }
            }
            Mock Update-SPSdkWorkflow -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'wf-1' }; Error = $null }
            }
        }

        It 'Approval Approve succeeds even when AllowCompleteCampaign=$false' {
            $result = Invoke-SPGuiSdkApprovalAction -Action Approve -ApprovalId 'appr-1' -CorrelationID 'sdk-saf-004a'
            $result.Success | Should -Be $true
            Should -Invoke Approve-SPSdkAccessRequest -ModuleName SP.SdkBridge -Times 1 -Exactly
        }

        It 'Workflow Toggle succeeds even when AllowCompleteCampaign=$false' {
            $result = Invoke-SPGuiSdkWorkflowAction -Action Toggle -WorkflowId 'wf-1' -Enabled $false -CorrelationID 'sdk-saf-004b'
            $result.Success | Should -Be $true
            Should -Invoke Update-SPSdkWorkflow -ModuleName SP.SdkBridge -Times 1 -Exactly
        }
    }

    # =======================================================================
    # SDK-12: the GUI write handlers (SP.MainWindow.psm1) dispatch through these
    # bridge functions on a background runspace and surface @{Success=$false;
    # Error=...} VERBATIM via Invoke-SdkActionRun (no throw). The handler-side
    # MessageBox/Show-SPGuiDialog/RequireWhatIfOnProd plumbing is UI-thread-only
    # and is proven interactively in SDK-19 (W-08b); these headless cases assert
    # the dispatcher contract the UI relies on -- specifically that the two NEW
    # SDK-12-wired destructive verbs (Template RemoveSchedule, WorkItem
    # BulkApprove) are Safety-blocked so the UI status label shows the block.
    # =======================================================================
    Context 'SDK-12: destructive-verb Safety block reaches the UI verbatim' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkBridge { }
            Mock Remove-SPSdkTemplateSchedule -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'tpl-1' }; Error = $null }
            }
            Mock Invoke-SPSdkBulkApproveWorkItem -ModuleName SP.SdkBridge {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'wi-1' }; Error = $null }
            }
        }

        It 'Template RemoveSchedule returns a Success=$false block (backing invoked 0 times) when AllowCompleteCampaign=$false' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $false; MaxCampaignsPerRun = 10 } }
            }
            $result = Invoke-SPGuiSdkTemplateAction -Action RemoveSchedule -TemplateId 'tpl-1' -CorrelationID 'sdk-12-001a'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'blocked by Safety'
            # The UI engine surfaces $result.Error as a plain string -- prove it is one.
            $result.Error   | Should -BeOfType ([string])
            Should -Invoke Remove-SPSdkTemplateSchedule -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'Template RemoveSchedule proceeds (backing invoked once) when AllowCompleteCampaign=$true' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $true; MaxCampaignsPerRun = 10 } }
            }
            $result = Invoke-SPGuiSdkTemplateAction -Action RemoveSchedule -TemplateId 'tpl-1' -CorrelationID 'sdk-12-001b'
            $result.Success | Should -Be $true
            Should -Invoke Remove-SPSdkTemplateSchedule -ModuleName SP.SdkBridge -Times 1 -Exactly
        }

        It 'WorkItem BulkApprove returns a Success=$false block (backing invoked 0 times) when AllowCompleteCampaign=$false' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $false; MaxCampaignsPerRun = 10 } }
            }
            $result = Invoke-SPGuiSdkWorkItemAction -Action BulkApprove -WorkItemId 'wi-1' -CorrelationID 'sdk-12-002a'
            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'blocked by Safety'
            Should -Invoke Invoke-SPSdkBulkApproveWorkItem -ModuleName SP.SdkBridge -Times 0 -Exactly
        }

        It 'WorkItem BulkApprove proceeds (backing invoked once) when AllowCompleteCampaign=$true' {
            Mock Get-SPConfig -ModuleName SP.SdkBridge {
                return [PSCustomObject]@{ Safety = [PSCustomObject]@{ AllowCompleteCampaign = $true; MaxCampaignsPerRun = 10 } }
            }
            $result = Invoke-SPGuiSdkWorkItemAction -Action BulkApprove -WorkItemId 'wi-1' -CorrelationID 'sdk-12-002b'
            $result.Success | Should -Be $true
            Should -Invoke Invoke-SPSdkBulkApproveWorkItem -ModuleName SP.SdkBridge -Times 1 -Exactly
        }
    }
}

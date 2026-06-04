#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Pester tests for SP.SdkWorkflows module.
.DESCRIPTION
    Validates workflow CRUD, test, execution monitoring, and OOO composite operations.
    Covers the 10 most critical functions from the 20-function module.
    Test IDs: SDK-WF-001 through SDK-WF-010.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Sdk
}

Describe 'SP.SdkWorkflows - Workflow Management' {

    Context 'SDK-WF-001: New-SPSdkWorkflow creates a workflow' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        id      = 'wf-new-001'
                        name    = 'Test Workflow'
                        enabled = $false
                    }
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with created workflow' {
            $wf = @{ name = 'Test Workflow'; description = 'A test workflow' }
            $result = New-SPSdkWorkflow -Workflow $wf -CorrelationID 'sdk-wf-001a' -Confirm:$false
            $result.Success  | Should -Be $true
            $result.Data.id  | Should -Be 'wf-new-001'
        }

        It 'calls POST /workflows with workflow body' {
            $wf = @{ name = 'Test Workflow'; description = 'A test workflow' }
            New-SPSdkWorkflow -Workflow $wf -CorrelationID 'sdk-wf-001b' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/workflows' -and $Body.name -eq 'Test Workflow'
            }
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $wf = @{ name = 'WhatIf Workflow' }
            $result = New-SPSdkWorkflow -Workflow $wf -WhatIf -CorrelationID 'sdk-wf-001c'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -Times 0 -Exactly
        }
    }

    Context 'SDK-WF-002: Get-SPSdkWorkflows lists workflows' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'wf-001'; name = 'Workflow 1'; enabled = $true },
                        [PSCustomObject]@{ id = 'wf-002'; name = 'Workflow 2'; enabled = $false }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with workflow list' {
            $result = Get-SPSdkWorkflows -CorrelationID 'sdk-wf-002a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
        }

        It 'calls GET /workflows' {
            Get-SPSdkWorkflows -CorrelationID 'sdk-wf-002b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/workflows'
            }
        }

        It 'passes filters and sorters as query params' {
            Get-SPSdkWorkflows -Filters 'enabled eq true' -Sorters 'name' -CorrelationID 'sdk-wf-002c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $QueryParams['filters'] -eq 'enabled eq true' -and $QueryParams['sorters'] -eq 'name'
            }
        }

        It 'passes limit and offset as query params' {
            Get-SPSdkWorkflows -Limit 100 -Offset 25 -CorrelationID 'sdk-wf-002d'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $QueryParams['limit'] -eq '100' -and $QueryParams['offset'] -eq '25'
            }
        }
    }

    Context 'SDK-WF-003: Get-SPSdkWorkflow gets a single workflow' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        id      = 'wf-001'
                        name    = 'My Workflow'
                        enabled = $true
                    }
                    Error   = $null
                }
            }
        }

        It 'returns the workflow data' {
            $result = Get-SPSdkWorkflow -WorkflowId 'wf-001' -CorrelationID 'sdk-wf-003a'
            $result.Success   | Should -Be $true
            $result.Data.id   | Should -Be 'wf-001'
            $result.Data.name | Should -Be 'My Workflow'
        }

        It 'calls GET /workflows/{id}' {
            Get-SPSdkWorkflow -WorkflowId 'wf-001' -CorrelationID 'sdk-wf-003b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/workflows/wf-001'
            }
        }

        It 'returns Success=false on API failure' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{ Success = $false; Data = $null; Error = 'Not Found' }
            }

            $result = Get-SPSdkWorkflow -WorkflowId 'wf-nonexistent' -CorrelationID 'sdk-wf-003c'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-WF-004: Update-SPSdkWorkflow patches with json-patch+json' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{ id = 'wf-001'; name = 'Patched Workflow' }
                    Error   = $null
                }
            }
        }

        It 'calls PATCH with application/json-patch+json content type' {
            $ops = @(New-SPSdkPatchReplace -Path '/name' -Value 'Patched Workflow')
            Update-SPSdkWorkflow -WorkflowId 'wf-001' -PatchOperations $ops `
                -CorrelationID 'sdk-wf-004a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $Method -eq 'PATCH' -and
                $Endpoint -eq '/workflows/wf-001' -and
                $ContentType -eq 'application/json-patch+json'
            }
        }

        It 'returns Success=true with patched workflow' {
            $ops = @(New-SPSdkPatchReplace -Path '/name' -Value 'Patched Workflow')
            $result = Update-SPSdkWorkflow -WorkflowId 'wf-001' -PatchOperations $ops `
                -CorrelationID 'sdk-wf-004b' -Confirm:$false
            $result.Success   | Should -Be $true
            $result.Data.name | Should -Be 'Patched Workflow'
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $ops = @(New-SPSdkPatchReplace -Path '/enabled' -Value $true)
            $result = Update-SPSdkWorkflow -WorkflowId 'wf-001' -PatchOperations $ops `
                -WhatIf -CorrelationID 'sdk-wf-004c'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -Times 0 -Exactly
        }
    }

    Context 'SDK-WF-005: Set-SPSdkWorkflow replaces via PUT' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        id      = 'wf-001'
                        name    = 'Replaced Workflow'
                        enabled = $true
                    }
                    Error   = $null
                }
            }
        }

        It 'calls PUT /workflows/{id} with complete body' {
            $body = @{ name = 'Replaced Workflow'; enabled = $true; description = 'Full replacement' }
            Set-SPSdkWorkflow -WorkflowId 'wf-001' -WorkflowBody $body `
                -CorrelationID 'sdk-wf-005a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $Method -eq 'PUT' -and
                $Endpoint -eq '/workflows/wf-001' -and
                $Body.name -eq 'Replaced Workflow'
            }
        }

        It 'returns Success=true with replaced workflow' {
            $body = @{ name = 'Replaced Workflow'; enabled = $true }
            $result = Set-SPSdkWorkflow -WorkflowId 'wf-001' -WorkflowBody $body `
                -CorrelationID 'sdk-wf-005b' -Confirm:$false
            $result.Success   | Should -Be $true
            $result.Data.name | Should -Be 'Replaced Workflow'
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $body = @{ name = 'WhatIf Workflow' }
            $result = Set-SPSdkWorkflow -WorkflowId 'wf-001' -WorkflowBody $body `
                -WhatIf -CorrelationID 'sdk-wf-005c'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -Times 0 -Exactly
        }
    }

    Context 'SDK-WF-006: Remove-SPSdkWorkflow deletes a workflow' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{ Success = $true; Data = $null; Error = $null }
            }
        }

        It 'calls DELETE /workflows/{id}' {
            Remove-SPSdkWorkflow -WorkflowId 'wf-001' -CorrelationID 'sdk-wf-006a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $Method -eq 'DELETE' -and $Endpoint -eq '/workflows/wf-001'
            }
        }

        It 'returns Success=true with null Data after delete' {
            $result = Remove-SPSdkWorkflow -WorkflowId 'wf-001' -CorrelationID 'sdk-wf-006b' -Confirm:$false
            $result.Success | Should -Be $true
            $result.Data    | Should -BeNullOrEmpty
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $result = Remove-SPSdkWorkflow -WorkflowId 'wf-001' -WhatIf -CorrelationID 'sdk-wf-006c'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -Times 0 -Exactly
        }
    }

    Context 'SDK-WF-007: Test-SPSdkWorkflow tests workflow execution' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{ workflowExecutionId = 'exec-test-001' }
                    Error   = $null
                }
            }
        }

        It 'calls POST /workflows/{id}/test with input body' {
            $testInput = @{ identityId = 'id-001'; event = 'test' }
            Test-SPSdkWorkflow -WorkflowId 'wf-001' -TestInput $testInput `
                -CorrelationID 'sdk-wf-007a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $Method -eq 'POST' -and
                $Endpoint -eq '/workflows/wf-001/test'
            }
        }

        It 'returns workflowExecutionId on success' {
            $testInput = @{ identityId = 'id-001' }
            $result = Test-SPSdkWorkflow -WorkflowId 'wf-001' -TestInput $testInput `
                -CorrelationID 'sdk-wf-007b' -Confirm:$false
            $result.Success                       | Should -Be $true
            $result.Data.workflowExecutionId      | Should -Be 'exec-test-001'
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $testInput = @{ identityId = 'id-001' }
            $result = Test-SPSdkWorkflow -WorkflowId 'wf-001' -TestInput $testInput `
                -WhatIf -CorrelationID 'sdk-wf-007c'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -Times 0 -Exactly
        }
    }

    Context 'SDK-WF-008: Get-SPSdkWorkflowExecutions lists workflow executions' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'exec-001'; status = 'COMPLETED' },
                        [PSCustomObject]@{ id = 'exec-002'; status = 'RUNNING' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns execution list for the workflow' {
            $result = Get-SPSdkWorkflowExecutions -WorkflowId 'wf-001' -CorrelationID 'sdk-wf-008a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
        }

        It 'calls GET /workflows/{id}/executions' {
            Get-SPSdkWorkflowExecutions -WorkflowId 'wf-001' -CorrelationID 'sdk-wf-008b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/workflows/wf-001/executions'
            }
        }

        It 'passes filters, limit, and offset as query params' {
            Get-SPSdkWorkflowExecutions -WorkflowId 'wf-001' `
                -Filters 'status eq "COMPLETED"' -Limit 50 -Offset 10 `
                -CorrelationID 'sdk-wf-008c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $QueryParams['filters'] -eq 'status eq "COMPLETED"' -and
                $QueryParams['limit'] -eq '50' -and
                $QueryParams['offset'] -eq '10'
            }
        }
    }

    Context 'SDK-WF-009: Stop-SPSdkWorkflowExecution cancels a running execution' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{ Success = $true; Data = $null; Error = $null }
            }
        }

        It 'calls POST /workflow-executions/{id}/cancel' {
            Stop-SPSdkWorkflowExecution -ExecutionId 'exec-001' `
                -CorrelationID 'sdk-wf-009a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/workflow-executions/exec-001/cancel'
            }
        }

        It 'returns Success=true after cancellation' {
            $result = Stop-SPSdkWorkflowExecution -ExecutionId 'exec-001' `
                -CorrelationID 'sdk-wf-009b' -Confirm:$false
            $result.Success | Should -Be $true
            $result.Data    | Should -BeNullOrEmpty
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $result = Stop-SPSdkWorkflowExecution -ExecutionId 'exec-001' `
                -WhatIf -CorrelationID 'sdk-wf-009c'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -Times 0 -Exactly
        }

        It 'returns Success=false on API failure' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{ Success = $false; Data = $null; Error = 'Execution already completed' }
            }

            $result = Stop-SPSdkWorkflowExecution -ExecutionId 'exec-done' `
                -CorrelationID 'sdk-wf-009d' -Confirm:$false
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-WF-010: Set-SPSdkOOOFallbackWorkflow creates OOO workflow' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkWorkflows { }
        }

        It 'creates a new workflow when none exists' {
            # Get-SPSdkWorkflows returns empty (no existing workflow with that name)
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                param($Method, $Endpoint, $Body, $QueryParams, $CorrelationID)
                if ($Method -eq 'GET' -and $Endpoint -eq '/workflows') {
                    return @{ Success = $true; Data = @(); Error = $null }
                }
                # POST /workflows (create)
                if ($Method -eq 'POST' -and $Endpoint -eq '/workflows') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            id      = 'wf-ooo-001'
                            name    = $Body.name
                            enabled = $false
                        }
                        Error   = $null
                    }
                }
                return @{ Success = $false; Data = $null; Error = 'Unexpected call' }
            }

            $result = Set-SPSdkOOOFallbackWorkflow `
                -PrimaryReviewerId 'reviewer-001' `
                -FallbackReviewerId 'backup-001' `
                -FallbackDays 5 `
                -CorrelationID 'sdk-wf-010a' -Confirm:$false

            $result.Success | Should -Be $true
            $result.Data.id | Should -Be 'wf-ooo-001'
        }

        It 'updates existing workflow when one is found' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                param($Method, $Endpoint, $Body, $QueryParams, $CorrelationID)
                if ($Method -eq 'GET' -and $Endpoint -eq '/workflows') {
                    return @{
                        Success = $true
                        Data    = @(
                            [PSCustomObject]@{ id = 'wf-existing-001'; name = 'OOO Fallback: reviewer-001' }
                        )
                        Error   = $null
                    }
                }
                # PUT /workflows/{id} (replace)
                if ($Method -eq 'PUT' -and $Endpoint -eq '/workflows/wf-existing-001') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            id      = 'wf-existing-001'
                            name    = $Body.name
                            enabled = $false
                        }
                        Error   = $null
                    }
                }
                return @{ Success = $false; Data = $null; Error = 'Unexpected call' }
            }

            $result = Set-SPSdkOOOFallbackWorkflow `
                -PrimaryReviewerId 'reviewer-001' `
                -FallbackReviewerId 'backup-002' `
                -CorrelationID 'sdk-wf-010b' -Confirm:$false

            $result.Success | Should -Be $true
            $result.Data.id | Should -Be 'wf-existing-001'
        }

        It 'uses default workflow name when WorkflowName is not provided' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                param($Method, $Endpoint, $Body, $QueryParams, $CorrelationID)
                if ($Method -eq 'GET' -and $Endpoint -eq '/workflows') {
                    return @{ Success = $true; Data = @(); Error = $null }
                }
                if ($Method -eq 'POST' -and $Endpoint -eq '/workflows') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{ id = 'wf-ooo-002'; name = $Body.name }
                        Error   = $null
                    }
                }
                return @{ Success = $false; Data = $null; Error = 'Unexpected call' }
            }

            $result = Set-SPSdkOOOFallbackWorkflow `
                -PrimaryReviewerId 'reviewer-xyz' `
                -FallbackReviewerId 'backup-xyz' `
                -CorrelationID 'sdk-wf-010c' -Confirm:$false

            $result.Data.name | Should -Be 'OOO Fallback: reviewer-xyz'
        }

        It 'respects ShouldProcess (WhatIf skips all API calls)' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkWorkflows {
                return @{ Success = $true; Data = @(); Error = $null }
            }

            $result = Set-SPSdkOOOFallbackWorkflow `
                -PrimaryReviewerId 'reviewer-001' `
                -FallbackReviewerId 'backup-001' `
                -WhatIf -CorrelationID 'sdk-wf-010d'

            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkWorkflows -Times 0 -Exactly
        }
    }
}

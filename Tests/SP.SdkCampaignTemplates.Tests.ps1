#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Pester tests for SP.SdkCampaignTemplates module.
.DESCRIPTION
    Validates campaign template CRUD and schedule management functions.
    Test IDs: SDK-TMPL-001 through SDK-TMPL-008.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Sdk
}

Describe 'SP.SdkCampaignTemplates - Campaign Template Management' {

    Context 'SDK-TMPL-001: Get-SPSdkCampaignTemplates lists templates' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignTemplates { }
            Mock Get-SPConfig -ModuleName SP.SdkCommon {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{
                        BaseUrl = 'https://test.api.identitynow.com/v3'
                        MaxPaginationPages = 200
                    }
                    Sdk = [PSCustomObject]@{ OutputPath = '.\SdkReports' }
                }
            }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'tmpl-001'; name = 'Quarterly Review' },
                        [PSCustomObject]@{ id = 'tmpl-002'; name = 'Annual Review' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with template list' {
            $result = Get-SPSdkCampaignTemplates -CorrelationID 'sdk-tmpl-001a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
            $result.Error      | Should -BeNullOrEmpty
        }

        It 'calls Invoke-SPApiRequest with GET /campaign-templates' {
            Get-SPSdkCampaignTemplates -CorrelationID 'sdk-tmpl-001b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/campaign-templates'
            }
        }

        It 'passes filters and sorters as query params' {
            Get-SPSdkCampaignTemplates -Filters 'name co "quarterly"' -Sorters 'name' -CorrelationID 'sdk-tmpl-001c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $QueryParams['filters'] -eq 'name co "quarterly"' -and $QueryParams['sorters'] -eq 'name'
            }
        }

        It 'passes limit and offset as query params' {
            Get-SPSdkCampaignTemplates -Limit 50 -Offset 10 -CorrelationID 'sdk-tmpl-001d'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $QueryParams['limit'] -eq '50' -and $QueryParams['offset'] -eq '10'
            }
        }
    }

    Context 'SDK-TMPL-001b: Get-SPSdkCampaignTemplates handles API failure' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignTemplates { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{ Success = $false; Data = $null; Error = 'API connection failed' }
            }
        }

        It 'returns Success=false with error on API failure' {
            $result = Get-SPSdkCampaignTemplates -CorrelationID 'sdk-tmpl-001e'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-TMPL-002: Get-SPSdkCampaignTemplate gets single template' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignTemplates { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        id          = 'tmpl-001'
                        name        = 'Quarterly Review'
                        description = 'Standard quarterly manager certification'
                    }
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with template data' {
            $result = Get-SPSdkCampaignTemplate -TemplateId 'tmpl-001' -CorrelationID 'sdk-tmpl-002a'
            $result.Success   | Should -Be $true
            $result.Data.id   | Should -Be 'tmpl-001'
            $result.Data.name | Should -Be 'Quarterly Review'
        }

        It 'calls the correct endpoint with template ID' {
            Get-SPSdkCampaignTemplate -TemplateId 'tmpl-001' -CorrelationID 'sdk-tmpl-002b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/campaign-templates/tmpl-001'
            }
        }
    }

    Context 'SDK-TMPL-003: New-SPSdkCampaignTemplate creates a template' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignTemplates { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        id          = 'tmpl-new-001'
                        name        = 'New Campaign Template'
                    }
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with created template' {
            $template = @{
                name        = 'New Campaign Template'
                description = 'A new template'
                campaign    = @{ type = 'MANAGER' }
            }
            $result = New-SPSdkCampaignTemplate -Template $template -CorrelationID 'sdk-tmpl-003a' -Confirm:$false
            $result.Success   | Should -Be $true
            $result.Data.id   | Should -Be 'tmpl-new-001'
        }

        It 'calls POST /campaign-templates with the template body' {
            $template = @{
                name        = 'New Campaign Template'
                description = 'A new template'
                campaign    = @{ type = 'MANAGER' }
            }
            New-SPSdkCampaignTemplate -Template $template -CorrelationID 'sdk-tmpl-003b' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/campaign-templates' -and $Body.name -eq 'New Campaign Template'
            }
        }

        It 'respects ShouldProcess (WhatIf returns skip message)' {
            $template = @{ name = 'WhatIf Test'; description = 'test'; campaign = @{ type = 'MANAGER' } }
            $result = New-SPSdkCampaignTemplate -Template $template -WhatIf -CorrelationID 'sdk-tmpl-003c'
            $result.Error | Should -Be 'Skipped (WhatIf)'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -Times 0 -Exactly
        }
    }

    Context 'SDK-TMPL-004: Update-SPSdkCampaignTemplate patches a template' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignTemplates { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{ id = 'tmpl-001'; name = 'Updated Name' }
                    Error   = $null
                }
            }
        }

        It 'calls PATCH with json-patch+json content type' {
            $ops = @(New-SPSdkPatchReplace -Path '/name' -Value 'Updated Name')
            Update-SPSdkCampaignTemplate -TemplateId 'tmpl-001' -PatchOperations $ops `
                -CorrelationID 'sdk-tmpl-004a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $Method -eq 'PATCH' -and
                $Endpoint -eq '/campaign-templates/tmpl-001' -and
                $ContentType -eq 'application/json-patch+json'
            }
        }

        It 'returns Success=true with updated template' {
            $ops = @(New-SPSdkPatchReplace -Path '/name' -Value 'Updated Name')
            $result = Update-SPSdkCampaignTemplate -TemplateId 'tmpl-001' -PatchOperations $ops `
                -CorrelationID 'sdk-tmpl-004b' -Confirm:$false
            $result.Success   | Should -Be $true
            $result.Data.name | Should -Be 'Updated Name'
        }
    }

    Context 'SDK-TMPL-005: Remove-SPSdkCampaignTemplate deletes a template' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignTemplates { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{ Success = $true; Data = $null; Error = $null }
            }
        }

        It 'calls DELETE /campaign-templates/{id}' {
            Remove-SPSdkCampaignTemplate -TemplateId 'tmpl-001' -CorrelationID 'sdk-tmpl-005a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $Method -eq 'DELETE' -and $Endpoint -eq '/campaign-templates/tmpl-001'
            }
        }

        It 'returns Success=true with null Data after delete' {
            $result = Remove-SPSdkCampaignTemplate -TemplateId 'tmpl-001' -CorrelationID 'sdk-tmpl-005b' -Confirm:$false
            $result.Success | Should -Be $true
            $result.Data    | Should -BeNullOrEmpty
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $result = Remove-SPSdkCampaignTemplate -TemplateId 'tmpl-001' -WhatIf -CorrelationID 'sdk-tmpl-005c'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -Times 0 -Exactly
        }
    }

    Context 'SDK-TMPL-006: Get-SPSdkTemplateSchedule gets schedule' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignTemplates { }
        }

        It 'calls GET /campaign-templates/{id}/schedule' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        type  = 'MONTHLY'
                        hours = [PSCustomObject]@{ type = 'LIST'; values = @('9') }
                    }
                    Error   = $null
                }
            }

            $result = Get-SPSdkTemplateSchedule -TemplateId 'tmpl-001' -CorrelationID 'sdk-tmpl-006a'
            $result.Success    | Should -Be $true
            $result.Data.type  | Should -Be 'MONTHLY'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/campaign-templates/tmpl-001/schedule'
            }
        }

        It 'returns Success=true with null Data on 404 (no schedule)' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{ Success = $false; Data = $null; Error = 'Not Found'; StatusCode = 404 }
            }

            $result = Get-SPSdkTemplateSchedule -TemplateId 'tmpl-no-sched' -CorrelationID 'sdk-tmpl-006b'
            $result.Success | Should -Be $true
            $result.Data    | Should -BeNullOrEmpty
            $result.Error   | Should -BeNullOrEmpty
        }
    }

    Context 'SDK-TMPL-007: Set-SPSdkTemplateSchedule sets schedule' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignTemplates { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{ Success = $true; Data = $null; Error = $null }
            }
        }

        It 'calls PUT /campaign-templates/{id}/schedule with schedule body' {
            $schedule = @{
                type  = 'MONTHLY'
                hours = @{ type = 'LIST'; values = @('9') }
                days  = @{ type = 'LIST'; values = @('1') }
            }
            Set-SPSdkTemplateSchedule -TemplateId 'tmpl-001' -Schedule $schedule `
                -CorrelationID 'sdk-tmpl-007a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $Method -eq 'PUT' -and
                $Endpoint -eq '/campaign-templates/tmpl-001/schedule' -and
                $Body.type -eq 'MONTHLY'
            }
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $schedule = @{ type = 'WEEKLY'; hours = @{ type = 'LIST'; values = @('8') } }
            $result = Set-SPSdkTemplateSchedule -TemplateId 'tmpl-001' -Schedule $schedule `
                -WhatIf -CorrelationID 'sdk-tmpl-007b'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -Times 0 -Exactly
        }
    }

    Context 'SDK-TMPL-008: Remove-SPSdkTemplateSchedule removes schedule' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignTemplates { }
        }

        It 'calls DELETE /campaign-templates/{id}/schedule' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{ Success = $true; Data = $null; Error = $null }
            }

            $result = Remove-SPSdkTemplateSchedule -TemplateId 'tmpl-001' -CorrelationID 'sdk-tmpl-008a' -Confirm:$false
            $result.Success | Should -Be $true

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates -ParameterFilter {
                $Method -eq 'DELETE' -and $Endpoint -eq '/campaign-templates/tmpl-001/schedule'
            }
        }

        It 'returns Success=true on 404 (schedule already absent)' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{ Success = $false; Data = $null; Error = 'Not Found'; StatusCode = 404 }
            }

            $result = Remove-SPSdkTemplateSchedule -TemplateId 'tmpl-no-sched' -CorrelationID 'sdk-tmpl-008b' -Confirm:$false
            $result.Success | Should -Be $true
            $result.Error   | Should -BeNullOrEmpty
        }

        It 'returns Success=false on non-404 API error' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignTemplates {
                return @{ Success = $false; Data = $null; Error = 'Server Error'; StatusCode = 500 }
            }

            $result = Remove-SPSdkTemplateSchedule -TemplateId 'tmpl-err' -CorrelationID 'sdk-tmpl-008c' -Confirm:$false
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}

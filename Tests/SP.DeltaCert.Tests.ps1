#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.DeltaCert module (SP.DeltaCertQueries + SP.DeltaCertRunner)
.DESCRIPTION
    Tests: DC-001 through DC-014
    Covers:
        DC-001 to DC-004: Get-SPDeltaGrantEvents  -- event retrieval, time-window filtering, API errors
        DC-005 to DC-008: Get-SPDeltaAffectedIdentities -- active/inactive filtering, fallback manager
        DC-009 to DC-010: Group-SPDeltaByManager  -- grouping and consolidation
        DC-011 to DC-014: Invoke-SPDeltaCertRun   -- no-changes guard, campaign creation, WhatIf, safety cap

    Note on mock-scoping:
        DC-011 to DC-014 mock cross-module calls (e.g. Get-SPDeltaGrantEvents called from within
        SP.DeltaCertRunner). These use -ModuleName SP.DeltaCertRunner and are expected to pass on
        PS 5.1 Desktop. On PS7 + Pester 5 strict scoping they may require -ModuleName adjustments.
        DC-001 to DC-010 mock only within their own modules and pass on both PS5.1 and PS7.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    # Minimal mock config used by pagination-ceiling logic inside query functions
    function New-MockDeltaConfig {
        return [PSCustomObject]@{
            Api = [PSCustomObject]@{
                BaseUrl                    = 'https://test.api.identitynow.com/v3'
                TimeoutSeconds             = 30
                RetryCount                 = 1
                RetryDelaySeconds          = 1
                RateLimitRequestsPerWindow = 95
                RateLimitWindowSeconds     = 10
                MaxPaginationPages         = 200
            }
            DeltaCert = [PSCustomObject]@{
                DefaultHoursBack           = 24
                DefaultDeadlineDays        = 2
                FallbackReviewerIdentityId = ''
                CampaignNamePrefix         = 'AD Delta Cert'
                MaxCampaignsPerRun         = 50
            }
        }
    }

    # Builds a minimal mock grant-activity response with one ADD item
    function New-MockGrantActivity {
        param(
            [string]$IdentityId   = 'id-001',
            [string]$SourceId     = 'src-ad-001',
            [string]$ItemValue    = 'CN=GroupA,OU=Groups,DC=corp,DC=com',
            [int]$HoursAgo        = 1
        )
        return [PSCustomObject]@{
            id           = "act-$IdentityId"
            type         = 'GRANT_ACCESS'
            created      = (Get-Date).AddHours(-$HoursAgo).ToString('yyyy-MM-ddTHH:mm:ssZ')
            requestedFor = @([PSCustomObject]@{ id = $IdentityId; name = "User $IdentityId" })
            items        = @(
                [PSCustomObject]@{
                    operation = 'ADD'
                    type      = 'ENTITLEMENT'
                    sourceId  = $SourceId
                    value     = $ItemValue
                    name      = 'GroupA'
                }
            )
        }
    }
}

# ---------------------------------------------------------------------------
#region DC-001: Get-SPDeltaGrantEvents returns matching ADD events
# ---------------------------------------------------------------------------

Describe "DC-001: Get-SPDeltaGrantEvents returns ADD events for specified source" {

    Context "When the API returns a GRANT_ACCESS activity with an ADD item" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Get-SPConfig   -ModuleName SP.DeltaCertQueries { New-MockDeltaConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @( New-MockGrantActivity -IdentityId 'id-001' -SourceId 'src-ad-001' )
                    Error      = $null
                }
            }
        }

        It "Should return Success=true with one grant event" {
            $result = Get-SPDeltaGrantEvents -SourceIds @('src-ad-001') -HoursBack 24

            $result.Success      | Should -Be $true
            $result.Data.Count   | Should -Be 1
            $result.Data[0].IdentityId | Should -Be 'id-001'
            $result.Data[0].SourceId   | Should -Be 'src-ad-001'
        }

        It "Should call GET /account-activities with GRANT_ACCESS type filter" {
            Get-SPDeltaGrantEvents -SourceIds @('src-ad-001') -HoursBack 24

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/account-activities'
            }
        }

        It "Should exclude items from sources not in SourceIds" {
            $result = Get-SPDeltaGrantEvents -SourceIds @('src-other') -HoursBack 24

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-002: Get-SPDeltaGrantEvents returns empty array when no events
# ---------------------------------------------------------------------------

Describe "DC-002: Get-SPDeltaGrantEvents returns empty data when API returns no activities" {

    Context "When the API returns an empty page" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Get-SPConfig   -ModuleName SP.DeltaCertQueries { New-MockDeltaConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{ Success = $true; StatusCode = 200; Data = @(); Error = $null }
            }
        }

        It "Should return Success=true with empty Data array" {
            $result = Get-SPDeltaGrantEvents -SourceIds @('src-ad-001') -HoursBack 24

            $result.Success      | Should -Be $true
            $result.Data.Count   | Should -Be 0
            $result.Error        | Should -BeNullOrEmpty
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-003: Get-SPDeltaGrantEvents excludes events older than HoursBack
# ---------------------------------------------------------------------------

Describe "DC-003: Get-SPDeltaGrantEvents excludes events outside the time window" {

    Context "When the API returns a mix of recent and old activities" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Get-SPConfig   -ModuleName SP.DeltaCertQueries { New-MockDeltaConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        # Recent: 2 hours ago - should be included with 24h window
                        New-MockGrantActivity -IdentityId 'id-recent' -SourceId 'src-ad-001' -HoursAgo 2
                        # Old: 48 hours ago - should be excluded with 24h window
                        New-MockGrantActivity -IdentityId 'id-old'    -SourceId 'src-ad-001' -HoursAgo 48
                    )
                    Error      = $null
                }
            }
        }

        It "Should include only the recent event within the HoursBack window" {
            $result = Get-SPDeltaGrantEvents -SourceIds @('src-ad-001') -HoursBack 24

            $result.Success      | Should -Be $true
            $result.Data.Count   | Should -Be 1
            $result.Data[0].IdentityId | Should -Be 'id-recent'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-004: Get-SPDeltaGrantEvents propagates API failure
# ---------------------------------------------------------------------------

Describe "DC-004: Get-SPDeltaGrantEvents returns failure when API call fails" {

    Context "When Invoke-SPApiRequest returns Success=false" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Get-SPConfig   -ModuleName SP.DeltaCertQueries { New-MockDeltaConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{ Success = $false; StatusCode = 503; Data = $null; Error = 'Service unavailable' }
            }
        }

        It "Should return Success=false with an error message" {
            $result = Get-SPDeltaGrantEvents -SourceIds @('src-ad-001') -HoursBack 24

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'unavailable'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-005: Get-SPDeltaAffectedIdentities includes active identities with managers
# ---------------------------------------------------------------------------

Describe "DC-005: Get-SPDeltaAffectedIdentities includes active identities with a manager" {

    Context "When the identity is active and has a manager" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        id          = 'id-001'
                        displayName = 'Jane Smith'
                        manager     = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Manager One' }
                        attributes  = [PSCustomObject]@{ cloudLifecycleState = 'active' }
                    }
                    Error      = $null
                }
            }
        }

        It "Should return the identity with correct manager ID" {
            $events = @([PSCustomObject]@{ IdentityId = 'id-001'; SourceId = 'src-ad-001' })
            $result = Get-SPDeltaAffectedIdentities -GrantEvents $events

            $result.Success           | Should -Be $true
            $result.Data.Count        | Should -Be 1
            $result.Data[0].IdentityId | Should -Be 'id-001'
            $result.Data[0].ManagerId  | Should -Be 'mgr-001'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-006: Get-SPDeltaAffectedIdentities skips inactive identities
# ---------------------------------------------------------------------------

Describe "DC-006: Get-SPDeltaAffectedIdentities skips identities with terminated lifecycle state" {

    Context "When the identity's cloudLifecycleState is terminated" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        id          = 'id-terminated'
                        displayName = 'Former Employee'
                        manager     = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Manager' }
                        attributes  = [PSCustomObject]@{ cloudLifecycleState = 'terminated' }
                    }
                    Error      = $null
                }
            }
        }

        It "Should return an empty Data array" {
            $events = @([PSCustomObject]@{ IdentityId = 'id-terminated'; SourceId = 'src-ad-001' })
            $result = Get-SPDeltaAffectedIdentities -GrantEvents $events

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-007: Get-SPDeltaAffectedIdentities uses fallback manager for orphaned identities
# ---------------------------------------------------------------------------

Describe "DC-007: Get-SPDeltaAffectedIdentities uses FallbackManagerId for identities with no manager" {

    Context "When the identity has no manager and FallbackManagerId is provided" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        id          = 'id-orphan'
                        displayName = 'Orphaned User'
                        manager     = $null
                        attributes  = [PSCustomObject]@{ cloudLifecycleState = 'active' }
                    }
                    Error      = $null
                }
            }
        }

        It "Should include the identity with the fallback manager ID" {
            $events = @([PSCustomObject]@{ IdentityId = 'id-orphan'; SourceId = 'src-ad-001' })
            $result = Get-SPDeltaAffectedIdentities -GrantEvents $events `
                -FallbackManagerId 'mgr-fallback'

            $result.Success           | Should -Be $true
            $result.Data.Count        | Should -Be 1
            $result.Data[0].ManagerId  | Should -Be 'mgr-fallback'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-008: Get-SPDeltaAffectedIdentities skips orphaned identities with no fallback
# ---------------------------------------------------------------------------

Describe "DC-008: Get-SPDeltaAffectedIdentities skips manager-less identities when no fallback configured" {

    Context "When the identity has no manager and FallbackManagerId is not provided" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        id          = 'id-orphan'
                        displayName = 'Orphaned User'
                        manager     = $null
                        attributes  = [PSCustomObject]@{ cloudLifecycleState = 'active' }
                    }
                    Error      = $null
                }
            }
        }

        It "Should return an empty Data array" {
            $events = @([PSCustomObject]@{ IdentityId = 'id-orphan'; SourceId = 'src-ad-001' })
            $result = Get-SPDeltaAffectedIdentities -GrantEvents $events

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-009: Group-SPDeltaByManager groups identities by manager ID
# ---------------------------------------------------------------------------

Describe "DC-009: Group-SPDeltaByManager groups identities by manager ID" {

    Context "When two identities have different managers" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }
        }

        It "Should produce two groups with one identity each" {
            $identities = @(
                [PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User One'; IsActive = $true }
                [PSCustomObject]@{ IdentityId = 'id-002'; ManagerId = 'mgr-002'; ManagerName = 'Mgr Two'; DisplayName = 'User Two'; IsActive = $true }
            )
            $result = Group-SPDeltaByManager -AffectedIdentities $identities

            $result.Success        | Should -Be $true
            $result.Data.Count     | Should -Be 2
            $result.Data['mgr-001'].Count | Should -Be 1
            $result.Data['mgr-002'].Count | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-010: Group-SPDeltaByManager consolidates identities under same manager
# ---------------------------------------------------------------------------

Describe "DC-010: Group-SPDeltaByManager consolidates multiple identities under the same manager" {

    Context "When three identities all report to the same manager" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }
        }

        It "Should produce one group with all three identities" {
            $identities = @(
                [PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User One';   IsActive = $true }
                [PSCustomObject]@{ IdentityId = 'id-002'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User Two';   IsActive = $true }
                [PSCustomObject]@{ IdentityId = 'id-003'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User Three'; IsActive = $true }
            )
            $result = Group-SPDeltaByManager -AffectedIdentities $identities

            $result.Success                  | Should -Be $true
            $result.Data.Count               | Should -Be 1
            $result.Data['mgr-001'].Count    | Should -Be 3
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-011: Invoke-SPDeltaCertRun returns NoChanges when no grant events found
# ---------------------------------------------------------------------------

Describe "DC-011: Invoke-SPDeltaCertRun returns NoChanges when no grant events found" {

    Context "When Get-SPDeltaGrantEvents returns an empty result" {
        BeforeEach {
            Mock Write-SPLog              -ModuleName SP.DeltaCertRunner { }
            Mock Get-SPDeltaGrantEvents   -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = @(); Error = $null }
            }
            Mock New-SPCampaign           -ModuleName SP.DeltaCertRunner { }
            Mock Start-SPCampaign         -ModuleName SP.DeltaCertRunner { }
        }

        It "Should return Success=true with CampaignsCreated=0 and Reason=NoChanges" {
            $result = Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -HoursBack 24

            $result.Success               | Should -Be $true
            $result.Data.CampaignsCreated | Should -Be 0
            $result.Data.Reason           | Should -Be 'NoChanges'
        }

        It "Should not call New-SPCampaign when there are no grant events" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -HoursBack 24

            Should -Not -Invoke New-SPCampaign -ModuleName SP.DeltaCertRunner
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-012: Invoke-SPDeltaCertRun creates one campaign per manager group
# ---------------------------------------------------------------------------

Describe "DC-012: Invoke-SPDeltaCertRun creates one SEARCH campaign per manager group" {

    Context "When two manager groups are resolved from grant events" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ IdentityId = 'id-001'; SourceId = 'src-ad-001' }
                        [PSCustomObject]@{ IdentityId = 'id-002'; SourceId = 'src-ad-001' }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPDeltaAffectedIdentities -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User One'; IsActive = $true }
                        [PSCustomObject]@{ IdentityId = 'id-002'; ManagerId = 'mgr-002'; ManagerName = 'Mgr Two'; DisplayName = 'User Two'; IsActive = $true }
                    )
                    Error   = $null
                }
            }

            Mock Group-SPDeltaByManager -ModuleName SP.DeltaCertRunner {
                $groups = @{}
                $groups['mgr-001'] = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One' })
                $groups['mgr-002'] = @([PSCustomObject]@{ IdentityId = 'id-002'; ManagerId = 'mgr-002'; ManagerName = 'Mgr Two' })
                return @{ Success = $true; Data = $groups; Error = $null }
            }

            Mock Search-SPCampaigns -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = @(); Error = $null }
            }

            Mock New-SPCampaign -ModuleName SP.DeltaCertRunner {
                param($Name)
                return @{ Success = $true; Data = [PSCustomObject]@{ id = "camp-$([guid]::NewGuid().ToString('N').Substring(0,8))" }; Error = $null }
            }

            Mock Start-SPCampaign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = $null; Error = $null }
            }
        }

        It "Should return CampaignsCreated=2 and Reason=Created" {
            $result = Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50

            $result.Success               | Should -Be $true
            $result.Data.CampaignsCreated | Should -Be 2
            $result.Data.Reason           | Should -Be 'Created'
            $result.Data.ManagerGroups    | Should -Be 2
        }

        It "Should call New-SPCampaign with Type=SEARCH for each manager group" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50

            Should -Invoke New-SPCampaign -ModuleName SP.DeltaCertRunner -Times 2 -ParameterFilter {
                $Type -eq 'SEARCH'
            }
        }

        It "Should call Start-SPCampaign once per successful campaign creation" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50

            Should -Invoke Start-SPCampaign -ModuleName SP.DeltaCertRunner -Times 2
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-013: Invoke-SPDeltaCertRun returns WhatIf data without writing
# ---------------------------------------------------------------------------

Describe "DC-013: Invoke-SPDeltaCertRun returns WhatIf preview without creating campaigns" {

    Context "When -WhatIf is specified" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; SourceId = 'src-ad-001' })
                    Error   = $null
                }
            }

            Mock Get-SPDeltaAffectedIdentities -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User One'; IsActive = $true })
                    Error   = $null
                }
            }

            Mock Group-SPDeltaByManager -ModuleName SP.DeltaCertRunner {
                $groups = @{}
                $groups['mgr-001'] = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One' })
                return @{ Success = $true; Data = $groups; Error = $null }
            }

            Mock Search-SPCampaigns -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = @(); Error = $null }
            }

            Mock New-SPCampaign   -ModuleName SP.DeltaCertRunner { }
            Mock Start-SPCampaign -ModuleName SP.DeltaCertRunner { }
        }

        It "Should return Reason=WhatIf with WhatIfGroups populated" {
            $result = Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50 -WhatIf

            $result.Success            | Should -Be $true
            $result.Data.Reason        | Should -Be 'WhatIf'
            $result.Data.CampaignsCreated | Should -Be 0
            $result.Data.WhatIfGroups  | Should -Not -BeNullOrEmpty
        }

        It "Should not call New-SPCampaign in WhatIf mode" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50 -WhatIf

            Should -Not -Invoke New-SPCampaign -ModuleName SP.DeltaCertRunner
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-014: Invoke-SPDeltaCertRun aborts when MaxCampaignsPerRun is exceeded
# ---------------------------------------------------------------------------

Describe "DC-014: Invoke-SPDeltaCertRun aborts when manager group count exceeds MaxCampaignsPerRun" {

    Context "When Group-SPDeltaByManager returns more groups than the safety cap" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; SourceId = 'src-ad-001' })
                    Error   = $null
                }
            }

            Mock Get-SPDeltaAffectedIdentities -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User One'; IsActive = $true })
                    Error   = $null
                }
            }

            # Return 3 groups but MaxCampaignsPerRun will be set to 2
            Mock Group-SPDeltaByManager -ModuleName SP.DeltaCertRunner {
                $groups = @{}
                $groups['mgr-001'] = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'M1' })
                $groups['mgr-002'] = @([PSCustomObject]@{ IdentityId = 'id-002'; ManagerId = 'mgr-002'; ManagerName = 'M2' })
                $groups['mgr-003'] = @([PSCustomObject]@{ IdentityId = 'id-003'; ManagerId = 'mgr-003'; ManagerName = 'M3' })
                return @{ Success = $true; Data = $groups; Error = $null }
            }

            Mock New-SPCampaign   -ModuleName SP.DeltaCertRunner { }
            Mock Start-SPCampaign -ModuleName SP.DeltaCertRunner { }
        }

        It "Should return Success=false with an error about the safety cap" {
            $result = Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 2

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'MaxCampaignsPerRun'
        }

        It "Should not call New-SPCampaign when the safety cap is exceeded" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 2

            Should -Not -Invoke New-SPCampaign -ModuleName SP.DeltaCertRunner
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-017: Duplicate campaign guard returns DuplicatesExist when match found
# ---------------------------------------------------------------------------

Describe "DC-017: Invoke-SPDeltaCertRun returns DuplicatesExist when campaigns already exist for today" {

    Context "When Search-SPCampaigns finds existing campaigns matching today's prefix" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; SourceId = 'src-ad-001' })
                    Error   = $null
                }
            }

            Mock Get-SPDeltaAffectedIdentities -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User One'; IsActive = $true })
                    Error   = $null
                }
            }

            Mock Group-SPDeltaByManager -ModuleName SP.DeltaCertRunner {
                $groups = @{}
                $groups['mgr-001'] = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One' })
                return @{ Success = $true; Data = $groups; Error = $null }
            }

            Mock Search-SPCampaigns -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ id = 'camp-existing'; name = 'AD Delta Cert 2026-05-22 - Mgr One'; status = 'ACTIVE' })
                    Error   = $null
                }
            }

            Mock New-SPCampaign   -ModuleName SP.DeltaCertRunner { }
            Mock Start-SPCampaign -ModuleName SP.DeltaCertRunner { }
        }

        It "Should return Success=true with Reason=DuplicatesExist" {
            $result = Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50

            $result.Success               | Should -Be $true
            $result.Data.CampaignsCreated | Should -Be 0
            $result.Data.Reason           | Should -Be 'DuplicatesExist'
        }

        It "Should not call New-SPCampaign when duplicates exist" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50

            Should -Not -Invoke New-SPCampaign -ModuleName SP.DeltaCertRunner
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-018: Duplicate campaign guard allows creation when no match found
# ---------------------------------------------------------------------------

Describe "DC-018: Invoke-SPDeltaCertRun creates campaigns normally when no duplicates exist" {

    Context "When Search-SPCampaigns returns empty results" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; SourceId = 'src-ad-001' })
                    Error   = $null
                }
            }

            Mock Get-SPDeltaAffectedIdentities -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User One'; IsActive = $true })
                    Error   = $null
                }
            }

            Mock Group-SPDeltaByManager -ModuleName SP.DeltaCertRunner {
                $groups = @{}
                $groups['mgr-001'] = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One' })
                return @{ Success = $true; Data = $groups; Error = $null }
            }

            Mock Search-SPCampaigns -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = @(); Error = $null }
            }

            Mock New-SPCampaign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'camp-new-001' }; Error = $null }
            }

            Mock Start-SPCampaign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = $null; Error = $null }
            }
        }

        It "Should return Success=true with Reason=Created" {
            $result = Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50

            $result.Success               | Should -Be $true
            $result.Data.CampaignsCreated | Should -Be 1
            $result.Data.Reason           | Should -Be 'Created'
        }

        It "Should call New-SPCampaign when no duplicates exist" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50

            Should -Invoke New-SPCampaign -ModuleName SP.DeltaCertRunner -Times 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-015: New-SPCampaign includes deadline in API body when -Deadline is provided
# ---------------------------------------------------------------------------

Describe "DC-015: New-SPCampaign includes deadline in API body when -Deadline is provided" {

    Context "When -Deadline is specified" {
        BeforeEach {
            Mock Write-SPLog        -ModuleName SP.Campaigns { }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'camp-001' }; Error = $null }
            }
        }

        It "Should include 'deadline' key in the POST body" {
            $result = New-SPCampaign -Name 'Test' -Type SEARCH `
                -SearchFilter 'id:"x"' -CertifierIdentityId 'y' `
                -Deadline '2026-06-01T23:59:59Z'

            $result.Success | Should -Be $true

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $Body -is [hashtable] -and $Body.ContainsKey('deadline') -and $Body['deadline'] -eq '2026-06-01T23:59:59Z'
            }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-016: New-SPCampaign omits deadline from body when -Deadline is not provided
# ---------------------------------------------------------------------------

Describe "DC-016: New-SPCampaign omits deadline from body when -Deadline is not provided" {

    Context "When -Deadline is omitted" {
        BeforeEach {
            Mock Write-SPLog        -ModuleName SP.Campaigns { }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'camp-002' }; Error = $null }
            }
        }

        It "Should NOT include 'deadline' key in the POST body" {
            $result = New-SPCampaign -Name 'Test' -Type SEARCH `
                -SearchFilter 'id:"x"' -CertifierIdentityId 'y'

            $result.Success | Should -Be $true

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $Body -is [hashtable] -and -not $Body.ContainsKey('deadline')
            }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-019: Invoke-SPDeltaCertCleanup completes stale campaigns
# ---------------------------------------------------------------------------

Describe "DC-019: Invoke-SPDeltaCertCleanup completes campaigns older than DaysStale" {

    Context "When Search-SPCampaigns returns a stale campaign and AllowCompleteCampaign is true" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPConfig -ModuleName SP.DeltaCertRunner {
                return [PSCustomObject]@{
                    Safety = [PSCustomObject]@{
                        AllowCompleteCampaign = $true
                    }
                }
            }

            Mock Search-SPCampaigns -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id       = 'camp-stale-001'
                            name     = 'AD Delta Cert 2026-05-18 - Mgr One'
                            status   = 'ACTIVE'
                            created  = (Get-Date).AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            deadline = (Get-Date).AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    )
                    Error   = $null
                }
            }

            Mock Complete-SPCampaign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Error = $null }
            }
        }

        It "Should return Success=true with the stale campaign in Completed" {
            $result = Invoke-SPDeltaCertCleanup -CampaignNamePrefix 'AD Delta Cert' -DaysStale 3

            $result.Success                 | Should -Be $true
            $result.Data.Completed.Count    | Should -Be 1
            $result.Data.Completed[0]       | Should -Be 'camp-stale-001'
            $result.Data.StillActive.Count  | Should -Be 0
        }

        It "Should call Complete-SPCampaign for the stale campaign" {
            Invoke-SPDeltaCertCleanup -CampaignNamePrefix 'AD Delta Cert' -DaysStale 3

            Should -Invoke Complete-SPCampaign -ModuleName SP.DeltaCertRunner -Times 1 -ParameterFilter {
                $CampaignId -eq 'camp-stale-001'
            }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-020: Invoke-SPDeltaCertCleanup blocked when AllowCompleteCampaign is false
# ---------------------------------------------------------------------------

Describe "DC-020: Invoke-SPDeltaCertCleanup returns error when AllowCompleteCampaign is false" {

    Context "When Safety.AllowCompleteCampaign is false" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPConfig -ModuleName SP.DeltaCertRunner {
                return [PSCustomObject]@{
                    Safety = [PSCustomObject]@{
                        AllowCompleteCampaign = $false
                    }
                }
            }

            Mock Search-SPCampaigns  -ModuleName SP.DeltaCertRunner { }
            Mock Complete-SPCampaign -ModuleName SP.DeltaCertRunner { }
        }

        It "Should return Success=false with a clear error about the safety guard" {
            $result = Invoke-SPDeltaCertCleanup -CampaignNamePrefix 'AD Delta Cert' -DaysStale 3

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'AllowCompleteCampaign'
        }

        It "Should not call Search-SPCampaigns or Complete-SPCampaign" {
            Invoke-SPDeltaCertCleanup -CampaignNamePrefix 'AD Delta Cert' -DaysStale 3

            Should -Not -Invoke Search-SPCampaigns  -ModuleName SP.DeltaCertRunner
            Should -Not -Invoke Complete-SPCampaign -ModuleName SP.DeltaCertRunner
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-021: Invoke-SPDeltaCertCleanup does not complete non-stale campaigns
# ---------------------------------------------------------------------------

Describe "DC-021: Invoke-SPDeltaCertCleanup does not complete campaigns that are not stale" {

    Context "When all active campaigns are within the staleness threshold" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPConfig -ModuleName SP.DeltaCertRunner {
                return [PSCustomObject]@{
                    Safety = [PSCustomObject]@{
                        AllowCompleteCampaign = $true
                    }
                }
            }

            Mock Search-SPCampaigns -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id       = 'camp-recent-001'
                            name     = 'AD Delta Cert 2026-05-22 - Mgr One'
                            status   = 'ACTIVE'
                            created  = (Get-Date).AddHours(-6).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            deadline = (Get-Date).AddDays(1).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    )
                    Error   = $null
                }
            }

            Mock Complete-SPCampaign -ModuleName SP.DeltaCertRunner { }
        }

        It "Should return the campaign in StillActive, not Completed" {
            $result = Invoke-SPDeltaCertCleanup -CampaignNamePrefix 'AD Delta Cert' -DaysStale 3

            $result.Success                 | Should -Be $true
            $result.Data.Completed.Count    | Should -Be 0
            $result.Data.StillActive.Count  | Should -Be 1
            $result.Data.StillActive[0]     | Should -Be 'camp-recent-001'
        }

        It "Should not call Complete-SPCampaign for non-stale campaigns" {
            Invoke-SPDeltaCertCleanup -CampaignNamePrefix 'AD Delta Cert' -DaysStale 3

            Should -Not -Invoke Complete-SPCampaign -ModuleName SP.DeltaCertRunner
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-022: JSONL audit file is written after a successful run
# ---------------------------------------------------------------------------

Describe "DC-022: Invoke-SPDeltaCertRun writes a JSONL audit event after completion" {

    Context "When a run completes with NoChanges (no grant events)" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @()
                    Error   = $null
                }
            }

            # Mock Get-SPConfig to return an OutputPath pointing to a temp directory
            $script:testOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "dc-test-$([guid]::NewGuid().ToString('N'))"
            Mock Get-SPConfig -ModuleName SP.DeltaCertRunner {
                return [PSCustomObject]@{
                    DeltaCert = [PSCustomObject]@{
                        OutputPath = $script:testOutputPath
                    }
                }
            }
        }

        AfterEach {
            if (Test-Path $script:testOutputPath) {
                Remove-Item -Path $script:testOutputPath -Recurse -Force
            }
        }

        It "Should create the deltacert-audit.jsonl file" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50

            $jsonlPath = Join-Path $script:testOutputPath 'deltacert-audit.jsonl'
            $jsonlPath | Should -Exist
        }

        It "Should write exactly one JSONL line" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -MaxCampaignsPerRun 50

            $jsonlPath = Join-Path $script:testOutputPath 'deltacert-audit.jsonl'
            $lines = @(Get-Content -Path $jsonlPath | Where-Object { $_ -ne '' })
            $lines.Count | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-024: SourceOwner mode calls New-SPCampaign -Type SOURCE_OWNER
# ---------------------------------------------------------------------------

Describe "DC-024: Invoke-SPDeltaCertRun SourceOwner mode creates SOURCE_OWNER campaigns" {

    Context "When ReviewerMode is SourceOwner and grant events exist" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ IdentityId = 'id-001'; SourceId = 'src-ad-001' }
                        [PSCustomObject]@{ IdentityId = 'id-002'; SourceId = 'src-ad-002' }
                    )
                    Error   = $null
                }
            }

            Mock Search-SPCampaigns -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = @(); Error = $null }
            }

            Mock New-SPCampaign -ModuleName SP.DeltaCertRunner {
                param($Name)
                return @{ Success = $true; Data = [PSCustomObject]@{ id = "camp-$([guid]::NewGuid().ToString('N').Substring(0,8))" }; Error = $null }
            }

            Mock Start-SPCampaign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = $null; Error = $null }
            }

            # These should NOT be called in SourceOwner mode
            Mock Get-SPDeltaAffectedIdentities -ModuleName SP.DeltaCertRunner { }
            Mock Group-SPDeltaByManager        -ModuleName SP.DeltaCertRunner { }
        }

        It "Should call New-SPCampaign with Type=SOURCE_OWNER for each unique source" {
            $result = Invoke-SPDeltaCertRun -SourceIds @('src-ad-001', 'src-ad-002') `
                -ReviewerMode SourceOwner -MaxCampaignsPerRun 50

            $result.Success               | Should -Be $true
            $result.Data.CampaignsCreated | Should -Be 2
            $result.Data.Reason           | Should -Be 'Created'

            Should -Invoke New-SPCampaign -ModuleName SP.DeltaCertRunner -Times 2 -ParameterFilter {
                $Type -eq 'SOURCE_OWNER'
            }
        }

        It "Should call Start-SPCampaign for each SOURCE_OWNER campaign" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001', 'src-ad-002') `
                -ReviewerMode SourceOwner -MaxCampaignsPerRun 50

            Should -Invoke Start-SPCampaign -ModuleName SP.DeltaCertRunner -Times 2
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-025: Manager mode still calls New-SPCampaign -Type SEARCH (regression)
# ---------------------------------------------------------------------------

Describe "DC-025: Invoke-SPDeltaCertRun Manager mode creates SEARCH campaigns (regression)" {

    Context "When ReviewerMode is Manager (explicit) and grant events exist" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; SourceId = 'src-ad-001' })
                    Error   = $null
                }
            }

            Mock Get-SPDeltaAffectedIdentities -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One'; DisplayName = 'User One'; IsActive = $true })
                    Error   = $null
                }
            }

            Mock Group-SPDeltaByManager -ModuleName SP.DeltaCertRunner {
                $groups = @{}
                $groups['mgr-001'] = @([PSCustomObject]@{ IdentityId = 'id-001'; ManagerId = 'mgr-001'; ManagerName = 'Mgr One' })
                return @{ Success = $true; Data = $groups; Error = $null }
            }

            Mock Search-SPCampaigns -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = @(); Error = $null }
            }

            Mock New-SPCampaign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'camp-mgr-001' }; Error = $null }
            }

            Mock Start-SPCampaign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = $null; Error = $null }
            }
        }

        It "Should call New-SPCampaign with Type=SEARCH" {
            $result = Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') `
                -ReviewerMode Manager -MaxCampaignsPerRun 50

            $result.Success               | Should -Be $true
            $result.Data.CampaignsCreated | Should -Be 1
            $result.Data.Reason           | Should -Be 'Created'

            Should -Invoke New-SPCampaign -ModuleName SP.DeltaCertRunner -Times 1 -ParameterFilter {
                $Type -eq 'SEARCH'
            }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-026: SourceOwner mode does NOT call Get-SPDeltaAffectedIdentities
# ---------------------------------------------------------------------------

Describe "DC-026: Invoke-SPDeltaCertRun SourceOwner mode skips identity resolution" {

    Context "When ReviewerMode is SourceOwner" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @([PSCustomObject]@{ IdentityId = 'id-001'; SourceId = 'src-ad-001' })
                    Error   = $null
                }
            }

            Mock Search-SPCampaigns -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = @(); Error = $null }
            }

            Mock New-SPCampaign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'camp-so-001' }; Error = $null }
            }

            Mock Start-SPCampaign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = $null; Error = $null }
            }

            Mock Get-SPDeltaAffectedIdentities -ModuleName SP.DeltaCertRunner { }
            Mock Group-SPDeltaByManager        -ModuleName SP.DeltaCertRunner { }
        }

        It "Should NOT call Get-SPDeltaAffectedIdentities" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') `
                -ReviewerMode SourceOwner -MaxCampaignsPerRun 50

            Should -Not -Invoke Get-SPDeltaAffectedIdentities -ModuleName SP.DeltaCertRunner
        }

        It "Should NOT call Group-SPDeltaByManager" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') `
                -ReviewerMode SourceOwner -MaxCampaignsPerRun 50

            Should -Not -Invoke Group-SPDeltaByManager -ModuleName SP.DeltaCertRunner
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-027: Stale cert detection returns only unsigned certs past threshold
# ---------------------------------------------------------------------------

Describe "DC-027: Get-SPDeltaCertStaleCertifications returns only unsigned certs past threshold" {

    Context "When one cert is signed and one is unsigned and stale" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }
            Mock Get-SPConfig -ModuleName SP.DeltaCertQueries { New-MockDeltaConfig }

            Mock Get-SPAuditCampaigns -ModuleName SP.DeltaCertQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id     = 'camp-001'
                            name   = 'AD Delta Cert 2026-05-20 - Mgr One'
                            status = 'ACTIVE'
                        }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPAuditCertifications -ModuleName SP.DeltaCertQueries {
                return @{
                    Success = $true
                    Data    = @(
                        # Signed (completed) cert -- should be excluded
                        [PSCustomObject]@{
                            id                     = 'cert-signed-001'
                            created                = (Get-Date).AddHours(-48).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            signed                 = (Get-Date).AddHours(-24).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            EffectiveReviewer      = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Mgr One' }
                            ReviewerClassification = 'Primary'
                        },
                        # Unsigned stale cert -- should be included
                        [PSCustomObject]@{
                            id                     = 'cert-unsigned-001'
                            created                = (Get-Date).AddHours(-48).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            signed                 = $null
                            EffectiveReviewer      = [PSCustomObject]@{ id = 'mgr-002'; displayName = 'Mgr Two' }
                            ReviewerClassification = 'Primary'
                        }
                    )
                    Error   = $null
                }
            }
        }

        It "Should return only the unsigned cert" {
            $result = Get-SPDeltaCertStaleCertifications -CampaignNamePrefix 'AD Delta Cert' -StaleHours 24

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 1
            $result.Data[0].CertificationId    | Should -Be 'cert-unsigned-001'
            $result.Data[0].ReviewerIdentityId  | Should -Be 'mgr-002'
            $result.Data[0].ReviewerName        | Should -Be 'Mgr Two'
            $result.Data[0].CampaignId          | Should -Be 'camp-001'
            $result.Data[0].HoursOpen           | Should -BeGreaterOrEqual 47
            $result.Data[0].ReviewerClassification | Should -Be 'Primary'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-028: Stale cert detection returns empty when all certs are within threshold
# ---------------------------------------------------------------------------

Describe "DC-028: Get-SPDeltaCertStaleCertifications returns empty when all certs are within threshold" {

    Context "When all unsigned certs are newer than StaleHours" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }
            Mock Get-SPConfig -ModuleName SP.DeltaCertQueries { New-MockDeltaConfig }

            Mock Get-SPAuditCampaigns -ModuleName SP.DeltaCertQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id     = 'camp-002'
                            name   = 'AD Delta Cert 2026-05-22 - Mgr One'
                            status = 'ACTIVE'
                        }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPAuditCertifications -ModuleName SP.DeltaCertQueries {
                return @{
                    Success = $true
                    Data    = @(
                        # Unsigned but recent cert -- within threshold, should be excluded
                        [PSCustomObject]@{
                            id                     = 'cert-recent-001'
                            created                = (Get-Date).AddHours(-6).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            signed                 = $null
                            EffectiveReviewer      = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Mgr One' }
                            ReviewerClassification = 'Primary'
                        }
                    )
                    Error   = $null
                }
            }
        }

        It "Should return an empty Data array" {
            $result = Get-SPDeltaCertStaleCertifications -CampaignNamePrefix 'AD Delta Cert' -StaleHours 24

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 0
            $result.Error      | Should -BeNullOrEmpty
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-023: JSONL audit line contains expected fields
# ---------------------------------------------------------------------------

Describe "DC-023: JSONL audit line contains all required fields" {

    Context "When a run completes with NoChanges" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaGrantEvents -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @()
                    Error   = $null
                }
            }

            $script:testOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "dc-test-$([guid]::NewGuid().ToString('N'))"
            Mock Get-SPConfig -ModuleName SP.DeltaCertRunner {
                return [PSCustomObject]@{
                    DeltaCert = [PSCustomObject]@{
                        OutputPath = $script:testOutputPath
                    }
                }
            }
        }

        AfterEach {
            if (Test-Path $script:testOutputPath) {
                Remove-Item -Path $script:testOutputPath -Recurse -Force
            }
        }

        It "Should contain Timestamp, CorrelationID, Action, SourceIds, HoursBack, Reason, and DurationSeconds" {
            Invoke-SPDeltaCertRun -SourceIds @('src-ad-001') -HoursBack 12 -MaxCampaignsPerRun 50

            $jsonlPath = Join-Path $script:testOutputPath 'deltacert-audit.jsonl'
            # Select-Object preserves pipeline-item identity; bare (...)[0] on a single-string
            # pipeline result indexes into the string and returns a [char], which ConvertFrom-Json
            # then chokes on as 'Invalid object passed in (1): {'.
            $line = Get-Content -Path $jsonlPath | Where-Object { $_ -ne '' } | Select-Object -First 1
            $event = $line | ConvertFrom-Json

            $event.Timestamp       | Should -Not -BeNullOrEmpty
            $event.CorrelationID   | Should -Not -BeNullOrEmpty
            $event.Action          | Should -Be 'DeltaCertRun'
            $event.SourceIds       | Should -Contain 'src-ad-001'
            $event.HoursBack       | Should -Be 12
            $event.Reason          | Should -Be 'NoChanges'
            $event.DurationSeconds | Should -BeGreaterOrEqual 0
            $event.GrantEventsFound    | Should -Be 0
            $event.IdentitiesProcessed | Should -Be 0
            $event.ManagerGroups       | Should -Be 0
            $event.CampaignsCreated    | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DC-029: Stale cert with reviewer who has a manager triggers Invoke-SPReassign
# ---------------------------------------------------------------------------

Describe "DC-029: Invoke-SPDeltaCertEscalate reassigns stale cert to reviewer's manager" {

    Context "When stale cert reviewer has a manager in ISC" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertRunner {
                return @{
                    IdentityId  = $IdentityId
                    DisplayName = 'Reviewer One'
                    ManagerId   = 'mgr-boss-001'
                    ManagerName = 'Boss One'
                    IsActive    = $true
                    Found       = $true
                }
            }

            Mock Get-SPAuditCertificationItems -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'item-001' }
                        [PSCustomObject]@{ id = 'item-002' }
                    )
                    Error   = $null
                }
            }

            Mock Invoke-SPReassign -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = $null; Error = $null }
            }

            Mock Invoke-SPReassignAsync -ModuleName SP.DeltaCertRunner { }
        }

        It "Should call Invoke-SPReassign with the manager's identity ID" {
            $staleCerts = @(
                [PSCustomObject]@{
                    CertificationId        = 'cert-stale-001'
                    CampaignId             = 'camp-001'
                    CampaignName           = 'AD Delta Cert 2026-05-20 - Mgr One'
                    CampaignStatus         = 'ACTIVE'
                    ReviewerIdentityId     = 'reviewer-001'
                    ReviewerName           = 'Reviewer One'
                    HoursOpen              = 36
                    HoursUntilDeadline     = $null
                    EscalationReason       = 'Stale'
                    ReviewerClassification = 'Primary'
                    CertSigned             = $false
                }
            )

            $result = Invoke-SPDeltaCertEscalate -StaleCertifications $staleCerts

            $result.Success              | Should -Be $true
            $result.Data.Escalated.Count | Should -Be 1
            $result.Data.Escalated[0]    | Should -Be 'cert-stale-001'
            $result.Data.Skipped.Count   | Should -Be 0

            Should -Invoke Invoke-SPReassign -ModuleName SP.DeltaCertRunner -Times 1 -ParameterFilter {
                $CertificationId -eq 'cert-stale-001' -and
                $NewCertifierIdentityId -eq 'mgr-boss-001' -and
                $Reason -match '36 hours'
            }
        }

        It "Should return Escalated count and no errors" {
            $staleCerts = @(
                [PSCustomObject]@{
                    CertificationId        = 'cert-stale-002'
                    CampaignId             = 'camp-002'
                    CampaignName           = 'AD Delta Cert 2026-05-20 - Mgr Two'
                    CampaignStatus         = 'ACTIVE'
                    ReviewerIdentityId     = 'reviewer-002'
                    ReviewerName           = 'Reviewer Two'
                    HoursOpen              = 48
                    HoursUntilDeadline     = $null
                    EscalationReason       = 'Stale'
                    ReviewerClassification = 'Primary'
                    CertSigned             = $false
                }
            )

            $result = Invoke-SPDeltaCertEscalate -StaleCertifications $staleCerts

            $result.Success            | Should -Be $true
            $result.Data.Errors.Count  | Should -Be 0
        }
    }
}

#endregion DC-029

# ---------------------------------------------------------------------------
#region DC-030: Reviewer with no manager is skipped, not errored
# ---------------------------------------------------------------------------

Describe "DC-030: Invoke-SPDeltaCertEscalate skips reviewer with no manager" {

    Context "When reviewer has no manager in ISC" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertRunner {
                return @{
                    IdentityId  = $IdentityId
                    DisplayName = 'Top Level Exec'
                    ManagerId   = ''
                    ManagerName = ''
                    IsActive    = $true
                    Found       = $true
                }
            }

            Mock Get-SPAuditCertificationItems -ModuleName SP.DeltaCertRunner { }
            Mock Invoke-SPReassign             -ModuleName SP.DeltaCertRunner { }
            Mock Invoke-SPReassignAsync         -ModuleName SP.DeltaCertRunner { }
        }

        It "Should skip the cert and not call Invoke-SPReassign" {
            $staleCerts = @(
                [PSCustomObject]@{
                    CertificationId        = 'cert-nomanager-001'
                    CampaignId             = 'camp-003'
                    CampaignName           = 'AD Delta Cert 2026-05-20 - Top Exec'
                    CampaignStatus         = 'ACTIVE'
                    ReviewerIdentityId     = 'exec-001'
                    ReviewerName           = 'Top Level Exec'
                    HoursOpen              = 48
                    HoursUntilDeadline     = $null
                    EscalationReason       = 'Stale'
                    ReviewerClassification = 'Primary'
                    CertSigned             = $false
                }
            )

            $result = Invoke-SPDeltaCertEscalate -StaleCertifications $staleCerts
            $result.Success             | Should -Be $true
            $result.Data.Skipped.Count  | Should -Be 1
            $result.Data.Skipped[0]     | Should -Be 'cert-nomanager-001'
            $result.Data.Escalated.Count | Should -Be 0
            $result.Data.Errors.Count   | Should -Be 0

            Should -Not -Invoke Invoke-SPReassign      -ModuleName SP.DeltaCertRunner
            Should -Not -Invoke Invoke-SPReassignAsync  -ModuleName SP.DeltaCertRunner
        }
    }
}

#endregion DC-030

# ---------------------------------------------------------------------------
#region DC-031: WhatIf mode does not call Invoke-SPReassign
# ---------------------------------------------------------------------------

Describe "DC-031: Invoke-SPDeltaCertEscalate WhatIf does not call reassignment APIs" {

    Context "When -WhatIf is specified" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }

            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertRunner {
                return @{
                    IdentityId  = $IdentityId
                    DisplayName = 'Reviewer One'
                    ManagerId   = 'mgr-boss-001'
                    ManagerName = 'Boss One'
                    IsActive    = $true
                    Found       = $true
                }
            }

            Mock Get-SPAuditCertificationItems -ModuleName SP.DeltaCertRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'item-001' }
                    )
                    Error   = $null
                }
            }

            Mock Invoke-SPReassign      -ModuleName SP.DeltaCertRunner { }
            Mock Invoke-SPReassignAsync  -ModuleName SP.DeltaCertRunner { }
        }

        It "Should not call Invoke-SPReassign or Invoke-SPReassignAsync" {
            $staleCerts = @(
                [PSCustomObject]@{
                    CertificationId        = 'cert-whatif-001'
                    CampaignId             = 'camp-004'
                    CampaignName           = 'AD Delta Cert 2026-05-20 - Mgr One'
                    CampaignStatus         = 'ACTIVE'
                    ReviewerIdentityId     = 'reviewer-whatif-001'
                    ReviewerName           = 'Reviewer One'
                    HoursOpen              = 36
                    HoursUntilDeadline     = $null
                    EscalationReason       = 'Stale'
                    ReviewerClassification = 'Primary'
                    CertSigned             = $false
                }
            )

            $result = Invoke-SPDeltaCertEscalate -StaleCertifications $staleCerts -WhatIf

            $result.Success              | Should -Be $true
            $result.Data.Escalated.Count | Should -Be 1

            Should -Not -Invoke Invoke-SPReassign      -ModuleName SP.DeltaCertRunner
            Should -Not -Invoke Invoke-SPReassignAsync  -ModuleName SP.DeltaCertRunner
        }
    }
}

#endregion DC-031

# ---------------------------------------------------------------------------
#region DC-032: Identity with displayName matching exclusion pattern is skipped
# ---------------------------------------------------------------------------

Describe "DC-032: Get-SPDeltaAffectedIdentities skips identity matching ExcludeDisplayNamePatterns" {

    Context "When identity displayName matches a configured exclusion regex" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Get-SPConfig   -ModuleName SP.DeltaCertQueries {
                return [PSCustomObject]@{
                    DeltaCert = [PSCustomObject]@{
                        ExcludeLifecycleStates     = @('terminated', 'inactive', 'leaver', 'prehire')
                        ExcludeDisplayNamePatterns = @('^SVC-')
                        ExcludeIdentityIds         = @()
                    }
                }
            }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        id          = 'id-svc-001'
                        displayName = 'SVC-SQLBackup'
                        manager     = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Manager One' }
                        attributes  = [PSCustomObject]@{ cloudLifecycleState = 'active' }
                    }
                    Error      = $null
                }
            }
        }

        It "Should return an empty Data array (identity skipped)" {
            $events = @([PSCustomObject]@{ IdentityId = 'id-svc-001'; SourceId = 'src-ad-001' })
            $result = Get-SPDeltaAffectedIdentities -GrantEvents $events

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 0
        }
    }
}

#endregion DC-032

# ---------------------------------------------------------------------------
#region DC-033: Identity in ExcludeIdentityIds is skipped
# ---------------------------------------------------------------------------

Describe "DC-033: Get-SPDeltaAffectedIdentities skips identity in ExcludeIdentityIds" {

    Context "When identity ID is in the exclusion list" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Get-SPConfig   -ModuleName SP.DeltaCertQueries {
                return [PSCustomObject]@{
                    DeltaCert = [PSCustomObject]@{
                        ExcludeLifecycleStates     = @('terminated', 'inactive', 'leaver', 'prehire')
                        ExcludeDisplayNamePatterns = @()
                        ExcludeIdentityIds         = @('id-excluded-001')
                    }
                }
            }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries { }
        }

        It "Should skip the identity without calling the identity API" {
            $events = @([PSCustomObject]@{ IdentityId = 'id-excluded-001'; SourceId = 'src-ad-001' })
            $result = Get-SPDeltaAffectedIdentities -GrantEvents $events

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 0
            Should -Not -Invoke Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries
        }
    }
}

#endregion DC-033

# ---------------------------------------------------------------------------
#region DC-034: Empty exclusion config includes all active identities (regression)
# ---------------------------------------------------------------------------

Describe "DC-034: Get-SPDeltaAffectedIdentities includes all active identities with empty exclusion config" {

    Context "When ExcludeDisplayNamePatterns and ExcludeIdentityIds are empty" {
        BeforeEach {
            Mock Write-SPLog    -ModuleName SP.DeltaCertQueries { }
            Mock Get-SPConfig   -ModuleName SP.DeltaCertQueries {
                return [PSCustomObject]@{
                    DeltaCert = [PSCustomObject]@{
                        ExcludeLifecycleStates     = @('terminated', 'inactive', 'leaver', 'prehire')
                        ExcludeDisplayNamePatterns = @()
                        ExcludeIdentityIds         = @()
                    }
                }
            }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        id          = 'id-normal-001'
                        displayName = 'Jane Smith'
                        manager     = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Manager One' }
                        attributes  = [PSCustomObject]@{ cloudLifecycleState = 'active' }
                    }
                    Error      = $null
                }
            }
        }

        It "Should include the active identity" {
            $events = @([PSCustomObject]@{ IdentityId = 'id-normal-001'; SourceId = 'src-ad-001' })
            $result = Get-SPDeltaAffectedIdentities -GrantEvents $events

            $result.Success            | Should -Be $true
            $result.Data.Count         | Should -Be 1
            $result.Data[0].IdentityId | Should -Be 'id-normal-001'
        }
    }
}

#endregion DC-034

# ---------------------------------------------------------------------------
#region DC-040: Escalation skips already-signed/complete certs
# ---------------------------------------------------------------------------

Describe "DC-040: Invoke-SPDeltaCertEscalate skips already-signed certs" {

    Context "When audit mode returns a mix of signed and unsigned certs" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DeltaCertRunner { }
            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertRunner {
                return @{ IdentityId = $IdentityId; DisplayName = 'Reviewer'; ManagerId = 'mgr-boss-001'; ManagerName = 'Boss One'; IsActive = $true; Found = $true }
            }
            Mock Get-SPAuditCertificationItems -ModuleName SP.DeltaCertRunner {
                return @{ Success = $true; Data = @([PSCustomObject]@{ id = 'item-001' }); Error = $null }
            }
            Mock Invoke-SPReassign      -ModuleName SP.DeltaCertRunner { }
            Mock Invoke-SPReassignAsync -ModuleName SP.DeltaCertRunner { }
        }

        It "Skips the signed cert and escalates only the unsigned one" {
            # Both have a resolvable manager + items, so WITHOUT the signed guard the runner would
            # escalate both. The signed cert must be skipped (no escalation needed).
            $staleCerts = @(
                [PSCustomObject]@{ CertificationId = 'cert-signed-001';   CampaignId = 'c1'; CampaignName = 'C'; CampaignStatus = 'ACTIVE'; ReviewerIdentityId = 'rev-1'; ReviewerName = 'R1'; HoursOpen = 48; HoursUntilDeadline = $null; EscalationReason = 'AuditAll'; ReviewerClassification = 'Primary'; CertSigned = $true }
                [PSCustomObject]@{ CertificationId = 'cert-unsigned-001'; CampaignId = 'c1'; CampaignName = 'C'; CampaignStatus = 'ACTIVE'; ReviewerIdentityId = 'rev-2'; ReviewerName = 'R2'; HoursOpen = 48; HoursUntilDeadline = $null; EscalationReason = 'AuditAll'; ReviewerClassification = 'Primary'; CertSigned = $false }
            )
            $result = Invoke-SPDeltaCertEscalate -StaleCertifications $staleCerts -WhatIf
            $result.Success              | Should -Be $true
            $result.Data.Skipped         | Should -Contain 'cert-signed-001'
            $result.Data.Escalated.Count | Should -Be 1
            $result.Data.Escalated       | Should -Contain 'cert-unsigned-001'
        }
    }
}

#endregion DC-040

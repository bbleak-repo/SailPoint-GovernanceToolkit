#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.Certifications module
.DESCRIPTION
    Tests: CERT-001 through CERT-004
    Covers: Single-page certifications, auto-pagination of certifications,
            access review items retrieval, auto-pagination of access review items
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api

    # Helper: generate a mock certification object
    function New-MockCert {
        param([string]$Id = 'cert-001', [string]$Status = 'PENDING')
        return [PSCustomObject]@{
            id       = $Id
            status   = $Status
            reviewer = [PSCustomObject]@{ name = 'Test Reviewer' }
        }
    }

    # Helper: generate a mock access review item
    function New-MockItem {
        param([string]$Id = 'item-001')
        return [PSCustomObject]@{
            id          = $Id
            decision    = $null
            accessType  = 'ENTITLEMENT'
        }
    }

    # Helper: build N mock objects
    function New-MockArray {
        param([int]$Count, [scriptblock]$Factory)
        $list = [System.Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le $Count; $i++) {
            $list.Add((&$Factory "obj-$i"))
        }
        return $list.ToArray()
    }
}

Describe "CERT-001: Get-SPCertifications returns paginated results" {
    Context "When certifications exist for the given campaign" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Certifications { }

            $mockCerts = New-MockArray -Count 5 -Factory { param($id) New-MockCert -Id $id }

            Mock Invoke-SPApiRequest -ModuleName SP.Certifications {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = $mockCerts
                    Error      = $null
                }
            }
        }

        It "Should return Success=true with the certifications array" {
            $result = Get-SPCertifications -CampaignId 'camp-cert-001' `
                -Limit 250 -Offset 0 -CorrelationID 'cert-cid-001'

            $result.Success    | Should -Be $true
            $result.Data       | Should -Not -BeNullOrEmpty
            $result.Data.Count | Should -Be 5
            $result.Error      | Should -BeNullOrEmpty
        }

        It "Should call Invoke-SPApiRequest with GET and /certifications endpoint" {
            Get-SPCertifications -CampaignId 'camp-cert-001' -CorrelationID 'cert-cid-001b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Certifications -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/certifications'
            }
        }

        It "Should include campaign filter and limit in query parameters" {
            Get-SPCertifications -CampaignId 'camp-cert-001' -Limit 50 -Offset 100 `
                -CorrelationID 'cert-cid-001c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Certifications -ParameterFilter {
                $QueryParams -ne $null -and
                $QueryParams['filters'] -like '*camp-cert-001*' -and
                $QueryParams['limit'] -eq '50' -and
                $QueryParams['offset'] -eq '100'
            }
        }
    }

    Context "When no certifications exist for the campaign" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Certifications { }
            Mock Invoke-SPApiRequest -ModuleName SP.Certifications {
                return @{ Success = $true; StatusCode = 200; Data = @(); Error = $null }
            }
        }

        It "Should return Success=true with an empty array" {
            $result = Get-SPCertifications -CampaignId 'empty-camp' -CorrelationID 'cert-cid-001d'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 0
        }
    }
}

Describe "CERT-002: Get-SPAllCertifications auto-paginates" {
    Context "When there are multiple pages of certifications" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Certifications { }

            # Page 1: full page of 250 items
            # Page 2: partial page (< 250 items) -- signals last page
            $page1 = New-MockArray -Count 250 -Factory { param($id) New-MockCert -Id "p1-$id" }
            $page2 = New-MockArray -Count 75  -Factory { param($id) New-MockCert -Id "p2-$id" }

            $script:PageCallCount = 0
            Mock Get-SPCertifications -ModuleName SP.Certifications {
                $script:PageCallCount++
                if ($script:PageCallCount -eq 1) {
                    return @{ Success = $true; Data = $page1; TotalCount = 325; Error = $null }
                }
                else {
                    return @{ Success = $true; Data = $page2; TotalCount = 325; Error = $null }
                }
            }
        }

        It "Should retrieve all items across multiple pages" {
            $result = Get-SPAllCertifications -CampaignId 'camp-all-001' `
                -CorrelationID 'cert-cid-002'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 325
        }

        It "Should call Get-SPCertifications exactly twice (2 pages)" {
            $script:PageCallCount = 0
            Get-SPAllCertifications -CampaignId 'camp-all-001' -CorrelationID 'cert-cid-002b'

            $script:PageCallCount | Should -Be 2
        }

        It "Should stop paginating when the last page has fewer items than page size" {
            $script:PageCallCount = 0
            $result = Get-SPAllCertifications -CampaignId 'camp-all-001' -CorrelationID 'cert-cid-002c'

            # Verify no extra empty call was made
            $script:PageCallCount | Should -Be 2
            $result.Data.Count    | Should -Be 325
        }
    }

    Context "When all certifications fit on a single page" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Certifications { }

            $singlePage = New-MockArray -Count 10 -Factory { param($id) New-MockCert -Id "sp-$id" }
            Mock Get-SPCertifications -ModuleName SP.Certifications {
                return @{ Success = $true; Data = $singlePage; TotalCount = 10; Error = $null }
            }
        }

        It "Should return all items from a single page" {
            $result = Get-SPAllCertifications -CampaignId 'small-camp' -CorrelationID 'cert-cid-002d'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 10
        }
    }

    Context "When a page request fails mid-pagination" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Certifications { }

            $page1 = New-MockArray -Count 250 -Factory { param($id) New-MockCert -Id "fail-$id" }
            $script:FailPageCount = 0
            Mock Get-SPCertifications -ModuleName SP.Certifications {
                $script:FailPageCount++
                if ($script:FailPageCount -eq 1) {
                    return @{ Success = $true; Data = $page1; TotalCount = 500; Error = $null }
                }
                else {
                    return @{ Success = $false; Data = $null; TotalCount = 0; Error = 'API unavailable' }
                }
            }
        }

        It "Should return Success=false with an error on page failure" {
            $result = Get-SPAllCertifications -CampaignId 'fail-camp' -CorrelationID 'cert-cid-002e'

            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    # H1 regression test: PS 5.1 ConvertFrom-Json unwraps 1-element JSON arrays,
    # so a response body like {"items":[{...}]} lands in Invoke-RestMethod's
    # output with .items as a bare PSCustomObject. Get-SPCertifications must
    # force-array the normalized value so the paginator doesn't drop it.
    Context "H1: When the API returns a single certification (PS 5.1 unwrap)" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Certifications { }

            $singleCert = New-MockCert -Id 'lone-cert-001'
            # Simulate the ConvertFrom-Json unwrap: .items is a bare object,
            # NOT a 1-element array.
            Mock Invoke-SPApiRequest -ModuleName SP.Certifications {
                return @{
                    Success    = $true
                    Data       = [PSCustomObject]@{ items = $singleCert }
                    StatusCode = 200
                    Error      = $null
                }
            }
        }

        It "Get-SPCertifications should return a 1-element array, not drop the item" {
            $result = Get-SPCertifications -CampaignId 'lone-camp' -CorrelationID 'cert-h1-a'

            $result.Success        | Should -Be $true
            ,$result.Data          | Should -BeOfType [System.Array]
            $result.Data.Count     | Should -Be 1
            $result.Data[0].id     | Should -Be 'lone-cert-001'
        }

        It "Get-SPAllCertifications should surface the single item through pagination" {
            $result = Get-SPAllCertifications -CampaignId 'lone-camp' -CorrelationID 'cert-h1-b'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 1
            $result.Data[0].id | Should -Be 'lone-cert-001'
        }
    }
}

Describe "CERT-003: Get-SPAccessReviewItems returns items" {
    Context "When access review items exist for the certification" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Certifications { }

            $mockItems = New-MockArray -Count 10 -Factory { param($id) New-MockItem -Id $id }
            Mock Invoke-SPApiRequest -ModuleName SP.Certifications {
                return @{ Success = $true; StatusCode = 200; Data = $mockItems; Error = $null }
            }
        }

        It "Should return Success=true with items array" {
            $result = Get-SPAccessReviewItems -CertificationId 'cert-003' `
                -Limit 250 -Offset 0 -CorrelationID 'cert-cid-003'

            $result.Success    | Should -Be $true
            $result.Data       | Should -Not -BeNullOrEmpty
            $result.Data.Count | Should -Be 10
        }

        It "Should call Invoke-SPApiRequest with the correct endpoint" {
            Get-SPAccessReviewItems -CertificationId 'cert-003' -CorrelationID 'cert-cid-003b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Certifications -ParameterFilter {
                $Method -eq 'GET' -and
                $Endpoint -eq '/certifications/cert-003/access-review-items'
            }
        }

        It "Should include limit and offset in query parameters" {
            Get-SPAccessReviewItems -CertificationId 'cert-003' -Limit 100 -Offset 200 `
                -CorrelationID 'cert-cid-003c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Certifications -ParameterFilter {
                $QueryParams['limit'] -eq '100' -and $QueryParams['offset'] -eq '200'
            }
        }
    }

    Context "When the API returns an error" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Certifications { }
            Mock Invoke-SPApiRequest -ModuleName SP.Certifications {
                return @{ Success = $false; Data = $null; StatusCode = 404; Error = 'Certification not found' }
            }
        }

        It "Should return Success=false with the error" {
            $result = Get-SPAccessReviewItems -CertificationId 'missing-cert' `
                -CorrelationID 'cert-cid-003d'

            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "CERT-004: Get-SPAllAccessReviewItems auto-paginates" {
    Context "When there are multiple pages of access review items" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Certifications { }

            $page1 = New-MockArray -Count 250 -Factory { param($id) New-MockItem -Id "p1-$id" }
            $page2 = New-MockArray -Count 130 -Factory { param($id) New-MockItem -Id "p2-$id" }

            $script:ItemPageCount = 0
            Mock Get-SPAccessReviewItems -ModuleName SP.Certifications {
                $script:ItemPageCount++
                if ($script:ItemPageCount -eq 1) {
                    return @{ Success = $true; Data = $page1; TotalCount = 380; Error = $null }
                }
                else {
                    return @{ Success = $true; Data = $page2; TotalCount = 380; Error = $null }
                }
            }
        }

        It "Should retrieve all items across multiple pages" {
            $result = Get-SPAllAccessReviewItems -CertificationId 'cert-all-001' `
                -CorrelationID 'cert-cid-004'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 380
        }

        It "Should call Get-SPAccessReviewItems exactly twice for two pages" {
            $script:ItemPageCount = 0
            Get-SPAllAccessReviewItems -CertificationId 'cert-all-001' `
                -CorrelationID 'cert-cid-004b'

            $script:ItemPageCount | Should -Be 2
        }
    }

    Context "When access review items all fit on one page" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Certifications { }

            $singlePage = New-MockArray -Count 3 -Factory { param($id) New-MockItem -Id "solo-$id" }
            Mock Get-SPAccessReviewItems -ModuleName SP.Certifications {
                return @{ Success = $true; Data = $singlePage; TotalCount = 3; Error = $null }
            }
        }

        It "Should return 3 items without making more than one page call" {
            $result = Get-SPAllAccessReviewItems -CertificationId 'cert-small' `
                -CorrelationID 'cert-cid-004c'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 3
        }
    }

    # H1 regression test: same PS 5.1 unwrap concern for access review items.
    Context "H1: When the API returns a single access review item (PS 5.1 unwrap)" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Certifications { }

            $singleItem = New-MockItem -Id 'lone-item-001'
            Mock Invoke-SPApiRequest -ModuleName SP.Certifications {
                return @{
                    Success    = $true
                    Data       = [PSCustomObject]@{ items = $singleItem }
                    StatusCode = 200
                    Error      = $null
                }
            }
        }

        It "Get-SPAccessReviewItems should return a 1-element array" {
            $result = Get-SPAccessReviewItems -CertificationId 'lone-cert' `
                -CorrelationID 'cert-h1-c'

            $result.Success        | Should -Be $true
            $result.Data.Count     | Should -Be 1
            $result.Data[0].id     | Should -Be 'lone-item-001'
        }

        It "Get-SPAllAccessReviewItems should surface the single item through pagination" {
            $result = Get-SPAllAccessReviewItems -CertificationId 'lone-cert' `
                -CorrelationID 'cert-h1-d'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 1
            $result.Data[0].id | Should -Be 'lone-item-001'
        }
    }
}

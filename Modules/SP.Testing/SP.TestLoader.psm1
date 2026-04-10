#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Test Data Loader
.DESCRIPTION
    CSV ingestion and validation for test identities and campaign test cases.
    Provides structured test data loading with cross-referential validation.
.NOTES
    Module: SP.Testing / SP.TestLoader
    Version: 1.0.0
    Component: Test Orchestration
#>

#region CSV Import Functions

function Import-SPTestIdentities {
    <#
    .SYNOPSIS
        Import and validate test identities from CSV.
    .DESCRIPTION
        Reads the identities CSV, validates required columns, and returns
        a hashtable keyed by IdentityId for O(1) lookup during campaign validation.
    .PARAMETER CsvPath
        Absolute path to the identities CSV file.
    .OUTPUTS
        @{Success=$true; Data=@{"id-alice-001"=[PSCustomObject]@{...}}; Error=$null}
    .EXAMPLE
        $result = Import-SPTestIdentities -CsvPath "C:\toolkit\Config\test-identities.csv"
        if ($result.Success) { $result.Data["id-alice-001"] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    $requiredColumns = @('IdentityId', 'DisplayName', 'Email', 'Role', 'CertifierFor', 'IsReassignTarget')

    try {
        if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Identities CSV not found: $CsvPath"
            }
        }

        $rows = Import-Csv -Path $CsvPath -ErrorAction Stop

        if ($null -eq $rows -or $rows.Count -eq 0) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Identities CSV is empty: $CsvPath"
            }
        }

        # Validate required columns exist
        $firstRow = $rows | Select-Object -First 1
        $actualColumns = $firstRow.PSObject.Properties.Name
        $missingColumns = $requiredColumns | Where-Object { $actualColumns -notcontains $_ }

        if ($missingColumns.Count -gt 0) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Identities CSV missing required columns: $($missingColumns -join ', ')"
            }
        }

        # Build hashtable keyed by IdentityId
        $identities = @{}
        $duplicates = @()
        $rowNum = 1

        foreach ($row in $rows) {
            $rowNum++
            $id = ($row.IdentityId).Trim()

            if ([string]::IsNullOrWhiteSpace($id)) {
                if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                    Write-SPLog -Message "Row $rowNum has empty IdentityId, skipping" `
                        -Severity WARN -Component "SP.TestLoader" -Action "ImportTestIdentities"
                }
                continue
            }

            if ($identities.ContainsKey($id)) {
                $duplicates += $id
                continue
            }

            $identities[$id] = [PSCustomObject]@{
                IdentityId        = $id
                DisplayName       = ($row.DisplayName).Trim()
                Email             = ($row.Email).Trim()
                Role              = ($row.Role).Trim()
                CertifierFor      = ($row.CertifierFor).Trim()
                IsReassignTarget  = ($row.IsReassignTarget).Trim() -eq 'true'
            }
        }

        if ($duplicates.Count -gt 0) {
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message "Duplicate IdentityIds found (first occurrence kept): $($duplicates -join ', ')" `
                    -Severity WARN -Component "SP.TestLoader" -Action "ImportTestIdentities"
            }
        }

        if ($identities.Count -eq 0) {
            return @{
                Success = $false
                Data    = $null
                Error   = "No valid identities loaded from: $CsvPath"
            }
        }

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Loaded $($identities.Count) test identities from $CsvPath" `
                -Severity INFO -Component "SP.TestLoader" -Action "ImportTestIdentities"
        }

        return @{
            Success = $true
            Data    = $identities
            Error   = $null
        }
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to import test identities: $($_.Exception.Message)"
        }
    }
}

function Import-SPTestCampaigns {
    <#
    .SYNOPSIS
        Import, validate, and filter campaign test cases from CSV.
    .DESCRIPTION
        Reads the campaigns CSV, validates required columns, validates identity
        cross-references, optionally filters by tags, and sorts by priority.
    .PARAMETER CsvPath
        Absolute path to the campaigns CSV file.
    .PARAMETER Identities
        Hashtable of identities returned by Import-SPTestIdentities.
    .PARAMETER Tags
        Optional array of tag strings. If provided, only campaigns whose Tags
        column contains at least one matching tag are returned.
    .OUTPUTS
        @{Success=$true; Data=@([PSCustomObject]@{TestId=...},...); Error=$null}
    .EXAMPLE
        $result = Import-SPTestCampaigns -CsvPath $path -Identities $ids -Tags @('smoke')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [Parameter(Mandatory)]
        [hashtable]$Identities,

        [Parameter()]
        [string[]]$Tags
    )

    $requiredColumns = @(
        'TestId', 'TestName', 'CampaignType', 'CampaignName',
        'CertifierIdentityId', 'ReassignTargetIdentityId',
        'SourceId', 'SearchFilter', 'RoleId',
        'DecisionToMake', 'ReassignBeforeDecide', 'ValidateRemediation',
        'ExpectCampaignStatus', 'Priority', 'Tags'
    )

    try {
        if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Campaigns CSV not found: $CsvPath"
            }
        }

        $rows = Import-Csv -Path $CsvPath -ErrorAction Stop

        if ($null -eq $rows -or $rows.Count -eq 0) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Campaigns CSV is empty: $CsvPath"
            }
        }

        # Validate required columns
        $firstRow = $rows | Select-Object -First 1
        $actualColumns = $firstRow.PSObject.Properties.Name
        $missingColumns = $requiredColumns | Where-Object { $actualColumns -notcontains $_ }

        if ($missingColumns.Count -gt 0) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Campaigns CSV missing required columns: $($missingColumns -join ', ')"
            }
        }

        $campaigns = @()
        $validationErrors = @()
        $rowNum = 1

        foreach ($row in $rows) {
            $rowNum++
            $testId = ($row.TestId).Trim()

            if ([string]::IsNullOrWhiteSpace($testId)) {
                $validationErrors += "Row $rowNum has empty TestId, skipping"
                continue
            }

            # Validate CertifierIdentityId exists in identities
            $certifierId = ($row.CertifierIdentityId).Trim()
            if (-not $Identities.ContainsKey($certifierId)) {
                $validationErrors += "${testId}: CertifierIdentityId '$certifierId' not found in identities"
            }

            # Validate ReassignTargetIdentityId if ReassignBeforeDecide is true
            $reassignBefore = ($row.ReassignBeforeDecide).Trim() -eq 'true'
            $reassignTargetId = ($row.ReassignTargetIdentityId).Trim()
            if ($reassignBefore -and [string]::IsNullOrWhiteSpace($reassignTargetId)) {
                $validationErrors += "${testId}: ReassignBeforeDecide is true but ReassignTargetIdentityId is empty"
            }
            elseif ($reassignBefore -and -not [string]::IsNullOrWhiteSpace($reassignTargetId) -and -not $Identities.ContainsKey($reassignTargetId)) {
                $validationErrors += "${testId}: ReassignTargetIdentityId '$reassignTargetId' not found in identities"
            }

            # Parse priority
            $priority = 99
            if (-not [int]::TryParse(($row.Priority).Trim(), [ref]$priority)) {
                $priority = 99
            }

            # Build campaign test case object
            $testCase = [PSCustomObject]@{
                TestId                   = $testId
                TestName                 = ($row.TestName).Trim()
                CampaignType             = ($row.CampaignType).Trim()
                CampaignName             = ($row.CampaignName).Trim()
                CertifierIdentityId      = $certifierId
                ReassignTargetIdentityId = $reassignTargetId
                SourceId                 = ($row.SourceId).Trim()
                SearchFilter             = ($row.SearchFilter).Trim()
                RoleId                   = ($row.RoleId).Trim()
                DecisionToMake           = ($row.DecisionToMake).Trim().ToUpper()
                ReassignBeforeDecide     = $reassignBefore
                ValidateRemediation      = ($row.ValidateRemediation).Trim() -eq 'true'
                ExpectCampaignStatus     = ($row.ExpectCampaignStatus).Trim().ToUpper()
                Priority                 = $priority
                Tags                     = ($row.Tags).Trim()
            }

            # Tag filtering - if Tags specified, campaign must match at least one
            if ($Tags -and $Tags.Count -gt 0) {
                $campaignTags = $testCase.Tags -split ',' | ForEach-Object { $_.Trim().ToLower() }
                $requestedTags = $Tags | ForEach-Object { $_.Trim().ToLower() }
                $hasMatch = $false
                foreach ($rt in $requestedTags) {
                    if ($campaignTags -contains $rt) {
                        $hasMatch = $true
                        break
                    }
                }
                if (-not $hasMatch) {
                    continue
                }
            }

            $campaigns += $testCase
        }

        if ($validationErrors.Count -gt 0) {
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                foreach ($err in $validationErrors) {
                    Write-SPLog -Message "Validation warning: $err" `
                        -Severity WARN -Component "SP.TestLoader" -Action "ImportTestCampaigns"
                }
            }
        }

        # Sort by Priority ascending
        $campaigns = $campaigns | Sort-Object -Property Priority

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Loaded $($campaigns.Count) test campaigns from $CsvPath (filter: $($Tags -join ','))" `
                -Severity INFO -Component "SP.TestLoader" -Action "ImportTestCampaigns"
        }

        return @{
            Success = $true
            Data    = @($campaigns)
            Error   = $null
        }
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to import test campaigns: $($_.Exception.Message)"
        }
    }
}

function Test-SPTestData {
    <#
    .SYNOPSIS
        Cross-validate loaded test campaigns and identities.
    .DESCRIPTION
        Checks for duplicate TestIds, validates all identity references,
        and warns if no smoke-tagged tests exist.
    .PARAMETER Campaigns
        Array of campaign test case objects from Import-SPTestCampaigns.
    .PARAMETER Identities
        Hashtable of identities from Import-SPTestIdentities.
    .OUTPUTS
        @{Success=$true/$false; ValidationErrors=@(); Warnings=@()}
    .EXAMPLE
        $result = Test-SPTestData -Campaigns $campaigns -Identities $identities
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Campaigns,

        [Parameter(Mandatory)]
        [hashtable]$Identities
    )

    $errors   = @()
    $warnings = @()

    try {
        # Check for duplicate TestIds
        $idGroups = $Campaigns | Group-Object -Property TestId | Where-Object { $_.Count -gt 1 }
        foreach ($group in $idGroups) {
            $errors += "Duplicate TestId found: '$($group.Name)' appears $($group.Count) times"
        }

        # Validate identity cross-references for each campaign
        foreach ($campaign in $Campaigns) {
            if (-not $Identities.ContainsKey($campaign.CertifierIdentityId)) {
                $errors += "$($campaign.TestId): CertifierIdentityId '$($campaign.CertifierIdentityId)' not found in identities"
            }

            if ($campaign.ReassignBeforeDecide) {
                if ([string]::IsNullOrWhiteSpace($campaign.ReassignTargetIdentityId)) {
                    $errors += "$($campaign.TestId): ReassignBeforeDecide=true but ReassignTargetIdentityId is empty"
                }
                elseif (-not $Identities.ContainsKey($campaign.ReassignTargetIdentityId)) {
                    $errors += "$($campaign.TestId): ReassignTargetIdentityId '$($campaign.ReassignTargetIdentityId)' not found in identities"
                }
            }
        }

        # Warn if no smoke-tagged tests
        $smokeTests = $Campaigns | Where-Object {
            $tags = $_.Tags -split ',' | ForEach-Object { $_.Trim().ToLower() }
            $tags -contains 'smoke'
        }

        if ($smokeTests.Count -eq 0) {
            $warnings += "No smoke-tagged tests found. Add Tags=smoke to at least one test case for quick validation runs."
        }

        $success = ($errors.Count -eq 0)

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            $severity = if ($success) { 'INFO' } else { 'WARN' }
            Write-SPLog -Message "Test data validation completed: $($errors.Count) errors, $($warnings.Count) warnings" `
                -Severity $severity -Component "SP.TestLoader" -Action "TestSPTestData"
        }

        return @{
            Success          = $success
            ValidationErrors = $errors
            Warnings         = $warnings
        }
    }
    catch {
        return @{
            Success          = $false
            ValidationErrors = @("Test data validation threw exception: $($_.Exception.Message)")
            Warnings         = $warnings
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Import-SPTestIdentities',
    'Import-SPTestCampaigns',
    'Test-SPTestData'
)

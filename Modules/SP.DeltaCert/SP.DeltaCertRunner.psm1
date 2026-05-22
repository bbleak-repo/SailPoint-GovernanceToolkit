#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - AD Delta Certification Campaign Runner
.DESCRIPTION
    Orchestrates the full AD delta certification workflow:
        1. Enumerate AD GRANT_ACCESS events in a configurable time window
        2. Resolve affected active identities and their managers
        3. Group identities by manager
        4. Create one SEARCH-type certification campaign per manager group
        5. Activate each campaign

    Each campaign is scoped to only the identities under that manager who received
    new AD access. Each manager reviews only their changed direct reports.

    Campaign naming convention: "{Prefix} {YYYY-MM-DD} - {ManagerName}"
    Campaign type:              SEARCH (certifier = manager identity ID)

    Empty-run guard: if no GRANT_ACCESS events are found, the function returns
    successfully with CampaignsCreated=0 and Reason='NoChanges'. No write API
    calls are made.

.NOTES
    Module: SP.DeltaCertRunner
    Version: 1.0.0
#>

#region Internal Functions

function Build-SPDeltaSearchFilter {
    <#
    .SYNOPSIS
        Builds an ISC SEARCH campaign identity filter query from identity IDs.
    .DESCRIPTION
        Produces a Lucene-style query string for use in a SEARCH campaign's
        filter.query.query field.

        Single identity:  id:"identity-id-1"
        Multiple:         id:"id-1" OR id:"id-2" OR id:"id-3"

        Double-quotes and backslashes in identity IDs are escaped.
    .PARAMETER IdentityIds
        Array of identity ID strings.
    .OUTPUTS
        [string] ISC search filter query string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$IdentityIds
    )

    $escaped = $IdentityIds | ForEach-Object {
        $id = $_ -replace '\\', '\\' -replace '"', '\"'
        "id:`"$id`""
    }
    return ($escaped -join ' OR ')
}

#endregion

#region Public Functions

function Invoke-SPDeltaCertRun {
    <#
    .SYNOPSIS
        Runs the full AD delta certification workflow for a given time window.
    .DESCRIPTION
        Calls the SP.DeltaCertQueries pipeline to find identities who received
        new AD access, groups them by manager, then creates and activates one
        SEARCH-type certification campaign per manager group.

        If no AD GRANT_ACCESS events are found in the time window:
          - Returns Success=$true with CampaignsCreated=0, Reason='NoChanges'
          - No write API calls are made

        Safety guard: aborts before creating any campaigns if the number of
        manager groups exceeds MaxCampaignsPerRun. Prevents runaway campaign
        creation from misconfigured source IDs or unexpectedly large change sets.

    .PARAMETER SourceIds
        Array of SailPoint ISC source IDs to monitor for AD group add operations.
    .PARAMETER HoursBack
        Look-back window in hours for grant events. Default: 24.
    .PARAMETER DeadlineDays
        Days from today until the campaign deadline. Default: 2.
    .PARAMETER CampaignNamePrefix
        Prefix for campaign names. Default: 'AD Delta Cert'.
        Full name format: "{Prefix} {YYYY-MM-DD} - {ManagerName}"
    .PARAMETER FallbackManagerId
        Identity ID used as reviewer for identities who have no manager in ISC.
        If omitted, manager-less identities are skipped.
    .PARAMETER MaxCampaignsPerRun
        Abort before creating any campaigns if manager group count exceeds this.
        Default: 50.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                CampaignsCreated = [int]
                CampaignIds      = [string[]]
                IdentityCount    = [int]
                ManagerGroups    = [int]
                Reason           = [string]    # NoChanges | NoActiveIdentities |
                                               # NoManagerGroups | DuplicatesExist |
                                               # WhatIf | Created
                Errors           = [string[]]  # per-campaign errors (partial failure)
                WhatIfGroups     = [hashtable] # only present when WhatIf=true
            }
            Error   = $string
        }
    .EXAMPLE
        $result = Invoke-SPDeltaCertRun -SourceIds @('src-abc123') -HoursBack 24
        if ($result.Success) {
            "Created $($result.Data.CampaignsCreated) campaign(s)"
        }
    .EXAMPLE
        Invoke-SPDeltaCertRun -SourceIds @('src-abc','src-def') -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SourceIds,

        [Parameter()]
        [int]$HoursBack = 24,

        [Parameter()]
        [int]$DeadlineDays = 2,

        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [string]$FallbackManagerId,

        [Parameter()]
        [int]$MaxCampaignsPerRun = 50,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Invoke-SPDeltaCertRun: Sources='$($SourceIds -join ',')' HoursBack=$HoursBack DeadlineDays=$DeadlineDays WhatIf=$($WhatIfPreference.IsPresent)" `
        -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: Grant events
        Write-SPLog -Message "Step 1: Querying GRANT_ACCESS events (last $HoursBack hours)" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        $eventsResult = Get-SPDeltaGrantEvents -SourceIds $SourceIds -HoursBack $HoursBack `
            -CorrelationID $CorrelationID

        if (-not $eventsResult.Success) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Grant event query failed: $($eventsResult.Error)"
            }
        }

        $grantEvents = @($eventsResult.Data)

        if ($grantEvents.Count -eq 0) {
            Write-SPLog -Message "No AD GRANT_ACCESS events found in the last $HoursBack hours -- no campaigns created" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = 0
                    ManagerGroups    = 0
                    Reason           = 'NoChanges'
                    Errors           = @()
                }
                Error   = $null
            }
        }

        # Step 2: Resolve active identities with managers
        Write-SPLog -Message "Step 2: Resolving $($grantEvents.Count) event(s) to active identities" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        $identResult = Get-SPDeltaAffectedIdentities -GrantEvents $grantEvents `
            -FallbackManagerId $FallbackManagerId -CorrelationID $CorrelationID

        if (-not $identResult.Success) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Identity resolution failed: $($identResult.Error)"
            }
        }

        $affectedIdentities = @($identResult.Data)

        if ($affectedIdentities.Count -eq 0) {
            Write-SPLog -Message "No active identities with managers after filtering -- no campaigns created" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = 0
                    ManagerGroups    = 0
                    Reason           = 'NoActiveIdentities'
                    Errors           = @()
                }
                Error   = $null
            }
        }

        # Step 3: Group by manager
        Write-SPLog -Message "Step 3: Grouping $($affectedIdentities.Count) identit(ies) by manager" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        $groupResult = Group-SPDeltaByManager -AffectedIdentities $affectedIdentities `
            -CorrelationID $CorrelationID

        if (-not $groupResult.Success) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Manager grouping failed: $($groupResult.Error)"
            }
        }

        $managerGroups = $groupResult.Data

        if ($managerGroups.Count -eq 0) {
            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = $affectedIdentities.Count
                    ManagerGroups    = 0
                    Reason           = 'NoManagerGroups'
                    Errors           = @()
                }
                Error   = $null
            }
        }

        # Safety guard
        if ($managerGroups.Count -gt $MaxCampaignsPerRun) {
            $errMsg = "Manager group count ($($managerGroups.Count)) exceeds MaxCampaignsPerRun ($MaxCampaignsPerRun). " +
                      "Increase DeltaCert.MaxCampaignsPerRun in settings.json if expected."
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $dateStamp = Get-Date -Format 'yyyy-MM-dd'

        # Duplicate campaign guard
        if (-not $Force) {
            Write-SPLog -Message "Checking for existing campaigns matching '$CampaignNamePrefix $dateStamp'" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $searchResult = Search-SPCampaigns -Keyword "$CampaignNamePrefix $dateStamp" `
                -CorrelationID $CorrelationID

            if ($searchResult.Success -and @($searchResult.Data).Count -gt 0) {
                $existingCount = @($searchResult.Data).Count
                Write-SPLog -Message "Duplicate guard: Found $existingCount existing campaign(s) matching '$CampaignNamePrefix $dateStamp'. Use -Force to bypass." `
                    -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                    -CorrelationID $CorrelationID
                return @{
                    Success = $true
                    Data    = @{
                        CampaignsCreated = 0
                        CampaignIds      = @()
                        IdentityCount    = $affectedIdentities.Count
                        ManagerGroups    = $managerGroups.Count
                        Reason           = 'DuplicatesExist'
                        Errors           = @()
                    }
                    Error   = $null
                }
            }
        }

        # WhatIf: describe without writing
        if ($WhatIfPreference.IsPresent) {
            $whatIfGroups = @{}
            foreach ($managerId in $managerGroups.Keys) {
                $identities  = $managerGroups[$managerId]
                $managerName = if ($identities.Count -gt 0 -and
                                   -not [string]::IsNullOrWhiteSpace($identities[0].ManagerName)) {
                                   $identities[0].ManagerName
                               } else { $managerId }
                $whatIfGroups[$managerId] = @{
                    ManagerName   = $managerName
                    IdentityCount = $identities.Count
                    IdentityIds   = @($identities | Select-Object -ExpandProperty IdentityId)
                    CampaignName  = "$CampaignNamePrefix $dateStamp - $managerName"
                    Deadline      = (Get-Date).AddDays($DeadlineDays).ToString('yyyy-MM-dd')
                }
            }

            Write-SPLog -Message "WhatIf: Would create $($managerGroups.Count) campaign(s) for $($affectedIdentities.Count) identit(ies)" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = $affectedIdentities.Count
                    ManagerGroups    = $managerGroups.Count
                    Reason           = 'WhatIf'
                    Errors           = @()
                    WhatIfGroups     = $whatIfGroups
                }
                Error   = $null
            }
        }

        # Step 4: Create and activate one SEARCH campaign per manager group
        Write-SPLog -Message "Step 4: Creating $($managerGroups.Count) campaign(s) (deadline +$DeadlineDays day(s))" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        $campaignIds    = [System.Collections.Generic.List[string]]::new()
        $campaignErrors = [System.Collections.Generic.List[string]]::new()
        $deadlineStr    = (Get-Date).AddDays($DeadlineDays).ToString('yyyy-MM-ddTHH:mm:ssZ')

        foreach ($managerId in $managerGroups.Keys) {
            $identities  = $managerGroups[$managerId]
            $managerName = if ($identities.Count -gt 0 -and
                               -not [string]::IsNullOrWhiteSpace($identities[0].ManagerName)) {
                               $identities[0].ManagerName
                           } else { $managerId }

            $campaignName = "$CampaignNamePrefix $dateStamp - $managerName"
            $identityIds  = @($identities | Select-Object -ExpandProperty IdentityId)
            $searchFilter = Build-SPDeltaSearchFilter -IdentityIds $identityIds

            Write-SPLog -Message "Creating campaign '$campaignName' ($($identityIds.Count) identit(ies), manager='$managerId')" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID

            $createResult = New-SPCampaign `
                -Name                $campaignName `
                -Type                'SEARCH' `
                -SearchFilter        $searchFilter `
                -CertifierIdentityId $managerId `
                -Description         "Daily AD delta certification: $($identityIds.Count) identit(ies) with new AD access assigned $dateStamp." `
                -Deadline            $deadlineStr `
                -CorrelationID       $CorrelationID

            if (-not $createResult.Success) {
                $errMsg = "Campaign '$campaignName' create failed: $($createResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID
                $campaignErrors.Add($errMsg)
                continue
            }

            $campaignId = $createResult.Data.id

            $activateResult = Start-SPCampaign -CampaignId $campaignId -CorrelationID $CorrelationID

            if (-not $activateResult.Success) {
                $errMsg = "Campaign '$campaignName' ($campaignId) created but activation failed: $($activateResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
                    -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID
                $campaignErrors.Add($errMsg)
                $campaignIds.Add($campaignId)  # track even if activation failed
                continue
            }

            Write-SPLog -Message "Campaign '$campaignName' ($campaignId) created and activation requested" `
                -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID
            $campaignIds.Add($campaignId)
        }

        $overallSuccess = ($campaignErrors.Count -eq 0)

        if ($campaignErrors.Count -gt 0) {
            Write-SPLog -Message "$($campaignErrors.Count) campaign(s) had creation/activation errors" `
                -Severity WARN -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
                -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Invoke-SPDeltaCertRun complete: $($campaignIds.Count) campaign(s) for $($affectedIdentities.Count) identit(ies) across $($managerGroups.Count) manager group(s)" `
            -Severity INFO -Component 'SP.DeltaCertRunner' -Action 'Invoke-SPDeltaCertRun' `
            -CorrelationID $CorrelationID

        return @{
            Success = $overallSuccess
            Data    = @{
                CampaignsCreated = $campaignIds.Count
                CampaignIds      = $campaignIds.ToArray()
                IdentityCount    = $affectedIdentities.Count
                ManagerGroups    = $managerGroups.Count
                Reason           = 'Created'
                Errors           = $campaignErrors.ToArray()
            }
            Error   = if ($campaignErrors.Count -gt 0) { $campaignErrors -join '; ' } else { $null }
        }
    }
    catch {
        $errMsg = "Invoke-SPDeltaCertRun failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertRunner' `
            -Action 'Invoke-SPDeltaCertRun' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-SPDeltaCertRun'
)

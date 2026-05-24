#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Campaign Audit Query Functions
.DESCRIPTION
    Provides functions for auditing SailPoint ISC certification campaigns:
    retrieving campaigns with date filtering, fetching certifications with
    reviewer classification, pulling access review items, downloading or
    importing campaign report CSVs, and resolving provisioning events for
    specific identities.

    All HTTP calls are delegated to Invoke-SPApiRequest.  Report downloads
    that require the legacy /cc/api endpoint call Invoke-RestMethod directly
    using the bearer token from Get-SPAuthToken.

    ISC API constraints observed in this module:
      - Campaign list filtering supports: id, name, status only (no date).
        Date filtering is applied client-side on the 'created' field.
      - Bulk decide cap: 250 items.
      - Rate limit: 95 requests / 10 s.
.NOTES
    Module: SP.AuditQueries
    Version: 1.0.0
#>

# Module-scope source name cache to avoid redundant API calls within a session.
$script:SourceNameCache = @{}

# Module-scope account cache: keyed by identity ID, value is @{SamAccountName; UserPrincipalName; Email; NativeIdentity}.
$script:AccountCache = @{}

#region Internal Functions

function Get-SPAuditSourceName {
    <#
    .SYNOPSIS
        Resolves a source ID to its display name, with in-memory caching.
    .DESCRIPTION
        Calls GET /sources/{sourceId} once per unique ID per session.
        On success the name is cached; on failure the sourceId is returned
        as the fallback display value so callers always receive a string.
    .PARAMETER SourceId
        The SailPoint ISC source ID to resolve.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [string] Source display name, or sourceId on error.
    .EXAMPLE
        $name = Get-SPAuditSourceName -SourceId 'src-abc123' -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Return cached name immediately
    if ($script:SourceNameCache.ContainsKey($SourceId)) {
        return $script:SourceNameCache[$SourceId]
    }

    Write-SPLog -Message "Resolving source name for ID '$SourceId'" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditSourceName' `
        -CorrelationID $CorrelationID

    try {
        $result = Invoke-SPApiRequest -Method GET -Endpoint "/sources/$SourceId" `
            -CorrelationID $CorrelationID

        if ($result.Success -and $null -ne $result.Data) {
            $sourceName = $result.Data.name
            if ([string]::IsNullOrWhiteSpace($sourceName)) {
                $sourceName = $SourceId
            }
            $script:SourceNameCache[$SourceId] = $sourceName
            return $sourceName
        }
    }
    catch {
        Write-SPLog -Message "Get-SPAuditSourceName failed for '$SourceId': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPAuditSourceName' `
            -CorrelationID $CorrelationID
    }

    # Fallback: cache and return the raw ID so we do not call the API again
    $script:SourceNameCache[$SourceId] = $SourceId
    return $SourceId
}

function Get-SPAuditAccountForIdentity {
    <#
    .SYNOPSIS
        Resolves an identity ID to its primary account attributes with in-memory caching.
    .DESCRIPTION
        Calls GET /accounts?filters=identityId eq "..." once per unique identity ID per session.
        Returns sAMAccountName, userPrincipalName, mail, and nativeIdentity extracted from
        the account attributes. Prefers AD/directory accounts when multiple accounts exist,
        but falls back to the first account with attributes if no AD account is found.

        On failure or no matching account, caches and returns empty strings so the API is
        not called again for the same identity ID within the session.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to resolve.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{SamAccountName; UserPrincipalName; Email; NativeIdentity} - all strings.
    .EXAMPLE
        $acct = Get-SPAuditAccountForIdentity -IdentityId 'id-abc123' -CorrelationID $cid
        $acct.UserPrincipalName
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentityId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Return cached result immediately
    if ($script:AccountCache.ContainsKey($IdentityId)) {
        return $script:AccountCache[$IdentityId]
    }

    $emptyResult = @{
        SamAccountName    = ''
        UserPrincipalName = ''
        Email             = ''
        NativeIdentity    = ''
    }

    Write-SPLog -Message "Resolving account attributes for identity '$IdentityId'" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditAccountForIdentity' `
        -CorrelationID $CorrelationID

    try {
        $result = Invoke-SPApiRequest -Method GET -Endpoint '/accounts' `
            -QueryParams @{
                'filters' = "identityId eq `"$IdentityId`""
                'limit'   = '10'
            } `
            -CorrelationID $CorrelationID

        if (-not $result.Success -or $null -eq $result.Data) {
            $script:AccountCache[$IdentityId] = $emptyResult
            return $emptyResult
        }

        # Normalize: API may return array directly or object with items
        $accounts = $result.Data
        if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
            $accounts = $result.Data.items
        }
        if ($null -eq $accounts) { $accounts = @() }

        # Find best account: prefer one with a non-empty sAMAccountName or UPN (AD/directory),
        # fall back to first account with any attributes.
        $bestAccount = $null
        foreach ($acct in $accounts) {
            if ($null -eq $acct) { continue }
            $attrs = $acct.attributes
            if ($null -eq $attrs) { continue }

            $sam = ''
            $upn = ''
            if ($attrs.PSObject.Properties.Name -contains 'sAMAccountName' -and $null -ne $attrs.sAMAccountName) {
                $sam = [string]$attrs.sAMAccountName
            }
            if ($attrs.PSObject.Properties.Name -contains 'userPrincipalName' -and $null -ne $attrs.userPrincipalName) {
                $upn = [string]$attrs.userPrincipalName
            }

            if (-not [string]::IsNullOrWhiteSpace($sam) -or -not [string]::IsNullOrWhiteSpace($upn)) {
                $bestAccount = $acct
                break
            }

            # Keep first account with attributes as fallback
            if ($null -eq $bestAccount) {
                $bestAccount = $acct
            }
        }

        if ($null -eq $bestAccount) {
            $script:AccountCache[$IdentityId] = $emptyResult
            return $emptyResult
        }

        $attrs          = $bestAccount.attributes
        $samValue       = ''
        $upnValue       = ''
        $mailValue      = ''
        $displayValue   = ''
        $nativeValue    = if ($null -ne $bestAccount.PSObject.Properties['nativeIdentity'] -and $null -ne $bestAccount.nativeIdentity) { [string]$bestAccount.nativeIdentity } else { '' }

        if ($null -ne $attrs) {
            if ($attrs.PSObject.Properties.Name -contains 'sAMAccountName'    -and $null -ne $attrs.sAMAccountName)    { $samValue     = [string]$attrs.sAMAccountName    }
            if ($attrs.PSObject.Properties.Name -contains 'userPrincipalName' -and $null -ne $attrs.userPrincipalName) { $upnValue     = [string]$attrs.userPrincipalName }
            if ($attrs.PSObject.Properties.Name -contains 'mail'              -and $null -ne $attrs.mail)              { $mailValue    = [string]$attrs.mail              }
            if ($attrs.PSObject.Properties.Name -contains 'displayName'       -and $null -ne $attrs.displayName)       { $displayValue = [string]$attrs.displayName       }
        }

        $resolved = @{
            SamAccountName    = $samValue
            UserPrincipalName = $upnValue
            Email             = $mailValue
            NativeIdentity    = $nativeValue
        }

        $script:AccountCache[$IdentityId] = $resolved
        return $resolved
    }
    catch {
        Write-SPLog -Message "Get-SPAuditAccountForIdentity failed for '$IdentityId': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPAuditAccountForIdentity' `
            -CorrelationID $CorrelationID
        $script:AccountCache[$IdentityId] = $emptyResult
        return $emptyResult
    }
}

#endregion

#region Public Functions

function Get-SPAuditCampaigns {
    <#
    .SYNOPSIS
        Retrieves certification campaigns with optional name, status, and date filters.
    .DESCRIPTION
        GETs /v3/campaigns with detail=FULL and auto-paginates across all pages.
        Name and status filters are applied server-side via the ISC 'filters' query
        parameter.  Date filtering is applied client-side because the ISC campaign
        API does not support filtering on the 'created' field directly.

        Supported server-side filter operators used here:
          name eq "..."    - exact name match
          name sw "..."    - starts-with match
          name co "..."    - substring (contains) match
          status in (...)  - one or more status values
    .PARAMETER CampaignName
        Optional exact name match. Translates to: name eq "..."
    .PARAMETER CampaignNameStartsWith
        Optional starts-with name match. Translates to: name sw "..."
        Ignored if CampaignName is also specified.
    .PARAMETER CampaignNameContains
        Optional substring (contains) name match. Translates to: name co "..."
        Ignored if CampaignName or CampaignNameStartsWith is also specified.
        This is the recommended filter for fuzzy searching -- ISC does not support
        wildcards (*test*) and the admin UI only does prefix matching.
    .PARAMETER Status
        Optional array of status values to filter by.
        Valid values: STAGED, ACTIVATING, ACTIVE, COMPLETING, COMPLETED, ERROR.
        Translates to: status in ("COMPLETED","ACTIVE")
    .PARAMETER CampaignType
        Optional campaign type filter. Valid values: MANAGER, SOURCE_OWNER,
        SEARCH, ROLE_COMPOSITION. Translates to server-side: type eq "MANAGER".
    .PARAMETER CreatedAfter
        Optional lower bound for the campaign 'created' timestamp. Only campaigns
        created on or after this date are returned. Takes precedence over DaysBack
        when both are specified. Compared using .ToUniversalTime().
    .PARAMETER CreatedBefore
        Optional upper bound for the campaign 'created' timestamp. Only campaigns
        created on or before this date are returned. Takes precedence over DaysBack
        when both are specified. Compared using .ToUniversalTime().
    .PARAMETER DaysBack
        Number of calendar days to look back from now when filtering campaigns
        by their 'created' timestamp. Filtering is client-side. Default: 30.
        Set to 0 or a negative number to disable date filtering.
        Ignored when CreatedAfter or CreatedBefore is specified.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([campaign objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCampaigns -Status 'COMPLETED','ACTIVE' -DaysBack 90
        $campaigns = $result.Data
    .EXAMPLE
        $result = Get-SPAuditCampaigns -CampaignName 'Q1 2026 Access Review' -DaysBack 0
    .EXAMPLE
        $result = Get-SPAuditCampaigns -CampaignType 'SOURCE_OWNER' -DaysBack 90
    .EXAMPLE
        $result = Get-SPAuditCampaigns -CreatedAfter '2026-01-01' -CreatedBefore '2026-03-31'
    .EXAMPLE
        $result = Get-SPAuditCampaigns -CreatedAfter '2026-01-01' -Status 'COMPLETED'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignName,

        [Parameter()]
        [string]$CampaignNameStartsWith,

        [Parameter()]
        [string]$CampaignNameContains,

        [Parameter()]
        [string[]]$Status,

        [Parameter()]
        [ValidateSet('MANAGER', 'SOURCE_OWNER', 'SEARCH', 'ROLE_COMPOSITION')]
        [string]$CampaignType,

        [Parameter()]
        [DateTime]$CreatedAfter,

        [Parameter()]
        [DateTime]$CreatedBefore,

        [Parameter()]
        [int]$DaysBack = 30,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Determine date filtering mode: explicit range vs DaysBack
    $useExplicitRange = ($PSBoundParameters.ContainsKey('CreatedAfter') -or $PSBoundParameters.ContainsKey('CreatedBefore'))

    $dateLogPart = if ($useExplicitRange) {
        "CreatedAfter='$CreatedAfter', CreatedBefore='$CreatedBefore'"
    } else {
        "DaysBack=$DaysBack"
    }

    Write-SPLog -Message "Getting audit campaigns: Name='$CampaignName', NameSW='$CampaignNameStartsWith', NameCO='$CampaignNameContains', Status='$($Status -join ',')', Type='$CampaignType', $dateLogPart" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
        -CorrelationID $CorrelationID

    try {
        # Build server-side filter expression
        $filterParts = [System.Collections.Generic.List[string]]::new()

        if (-not [string]::IsNullOrWhiteSpace($CampaignName)) {
            $escaped = $CampaignName.Replace('"', '\"')
            $filterParts.Add("name eq `"$escaped`"")
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) {
            $escaped = $CampaignNameStartsWith.Replace('"', '\"')
            $filterParts.Add("name sw `"$escaped`"")
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
            $escaped = $CampaignNameContains.Replace('"', '\"')
            $filterParts.Add("name co `"$escaped`"")
        }

        if ($null -ne $Status -and $Status.Count -gt 0) {
            $quotedStatuses = ($Status | ForEach-Object { "`"$_`"" }) -join ','
            $filterParts.Add("status in ($quotedStatuses)")
        }

        if (-not [string]::IsNullOrWhiteSpace($CampaignType)) {
            $filterParts.Add("type eq `"$CampaignType`"")
        }

        $queryParams = @{
            'detail' = 'FULL'
            'limit'  = '250'
            'offset' = '0'
        }

        if ($filterParts.Count -gt 0) {
            $queryParams['filters'] = ($filterParts -join ' and ')
        }

        # Auto-paginate
        $allCampaigns = [System.Collections.Generic.List[object]]::new()
        $pageSize     = 250
        $offset       = 0
        $pageNum      = 0

        # M2: pagination ceiling.
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached: $maxPages pages already fetched (accumulated $($allCampaigns.Count) campaigns). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaigns' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams['offset'] = $offset.ToString()

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditCampaigns failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaigns' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize: API may wrap items or return array directly
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($campaign in $page) {
                    $allCampaigns.Add($campaign)
                }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) campaigns (running total: $($allCampaigns.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allCampaigns.Count) campaigns before date filtering" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
            -CorrelationID $CorrelationID

        # Client-side date filter on 'created' field
        # CreatedAfter/CreatedBefore take precedence over DaysBack when specified.
        # All comparisons use .ToUniversalTime() to avoid Kind mismatch (PS7 auto-converts
        # ISO 8601 strings to DateTime with Kind=Utc; local cutoffs have Kind=Local).
        $filteredCampaigns = [System.Collections.Generic.List[object]]::new()

        $applyDateFilter = $false
        $rangeAfterUtc   = $null
        $rangeBeforeUtc  = $null
        $dateFilterLabel  = ''

        if ($useExplicitRange) {
            $applyDateFilter = $true
            if ($PSBoundParameters.ContainsKey('CreatedAfter')) {
                $rangeAfterUtc = $CreatedAfter.ToUniversalTime()
            }
            if ($PSBoundParameters.ContainsKey('CreatedBefore')) {
                $rangeBeforeUtc = $CreatedBefore.ToUniversalTime()
            }
            $dateFilterLabel = "CreatedAfter=$rangeAfterUtc, CreatedBefore=$rangeBeforeUtc"
        }
        elseif ($DaysBack -gt 0) {
            $applyDateFilter = $true
            $rangeAfterUtc  = (Get-Date).AddDays(-$DaysBack).ToUniversalTime()
            $dateFilterLabel = "last $DaysBack days (cutoff=$rangeAfterUtc)"
        }

        if ($applyDateFilter) {
            foreach ($campaign in $allCampaigns) {
                $createdRaw = $campaign.created
                if ($null -eq $createdRaw) {
                    # No created date -- include to avoid silent exclusion
                    $filteredCampaigns.Add($campaign)
                    continue
                }

                $createdDate = $null
                if ($createdRaw -is [datetime]) {
                    $createdDate = ([datetime]$createdRaw).ToUniversalTime()
                }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsedDate)) {
                        $createdDate = $parsedDate.ToUniversalTime()
                    }
                }

                if ($null -eq $createdDate) {
                    $filteredCampaigns.Add($campaign)
                    continue
                }

                # Apply range bounds
                $include = $true
                if ($null -ne $rangeAfterUtc -and $createdDate -lt $rangeAfterUtc) {
                    $include = $false
                }
                if ($include -and $null -ne $rangeBeforeUtc -and $createdDate -gt $rangeBeforeUtc) {
                    $include = $false
                }

                if ($include) {
                    $filteredCampaigns.Add($campaign)
                }
            }

            Write-SPLog -Message "Date filter ($dateFilterLabel): $($allCampaigns.Count) -> $($filteredCampaigns.Count) campaigns" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
                -CorrelationID $CorrelationID
        }
        else {
            foreach ($campaign in $allCampaigns) { $filteredCampaigns.Add($campaign) }
            Write-SPLog -Message "Date filtering disabled (DaysBack=$DaysBack). Returning all $($filteredCampaigns.Count) campaigns." `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
                -CorrelationID $CorrelationID
        }

        return @{ Success = $true; Data = $filteredCampaigns.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCampaigns failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCampaigns' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditCertifications {
    <#
    .SYNOPSIS
        Retrieves all certifications for a campaign with reviewer classification.
    .DESCRIPTION
        GETs /v3/certifications filtered by campaign.id and auto-paginates.
        Each certification is annotated with a 'ReviewerClassification' property:
          'Primary'    - reviewer taken from cert.reviewer (no reassignment)
          'Reassigned' - reviewer taken from cert.reassignment (reassigned cert)
        The effective reviewer object is surfaced as 'EffectiveReviewer' on each
        returned certification object for convenient downstream processing.
    .PARAMETER CampaignId
        The campaign ID to retrieve certifications for. Mandatory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([cert objects with classification]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCertifications -CampaignId 'camp-abc123' -CorrelationID $cid
        foreach ($cert in $result.Data) {
            "$($cert.EffectiveReviewer.displayName) [$($cert.ReviewerClassification)]"
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting audit certifications for campaign '$CampaignId' (auto-paginating)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertifications' `
        -CorrelationID $CorrelationID

    try {
        $allCerts = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0

        # M2: pagination ceiling.
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached: $maxPages pages already fetched (accumulated $($allCerts.Count) certifications). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertifications' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'filters' = "campaign.id eq `"$CampaignId`""
                'limit'   = $pageSize.ToString()
                'offset'  = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/certifications' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditCertifications failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertifications' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize response
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($cert in $page) {
                    # Classify reviewer: reassigned vs primary
                    $classification   = 'Primary'
                    $effectiveReviewer = $cert.reviewer

                    if ($null -ne $cert.PSObject.Properties['reassignment'] -and
                        $null -ne $cert.reassignment) {
                        $classification    = 'Reassigned'
                        # The reassignment object contains the new reviewer
                        if ($null -ne $cert.reassignment.PSObject.Properties['to'] -and
                            $null -ne $cert.reassignment.to) {
                            $effectiveReviewer = $cert.reassignment.to
                        }
                    }

                    # Attach classification properties (Add-Member works on PS custom objects)
                    $cert | Add-Member -MemberType NoteProperty -Name 'ReviewerClassification' `
                        -Value $classification -Force
                    $cert | Add-Member -MemberType NoteProperty -Name 'EffectiveReviewer' `
                        -Value $effectiveReviewer -Force

                    $allCerts.Add($cert)
                }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) certifications (running total: $($allCerts.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertifications' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allCerts.Count) total certifications for campaign '$CampaignId'" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertifications' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $allCerts.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCertifications failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCertifications' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditCertificationItems {
    <#
    .SYNOPSIS
        Retrieves all access review items for a single certification, auto-paginating.
    .DESCRIPTION
        GETs /v3/certifications/{certId}/access-review-items and auto-paginates.
        Each item includes decision (APPROVE/REVOKE), access (type/name),
        identitySummary, and account details as returned by the ISC API.
    .PARAMETER CertificationId
        The certification ID to retrieve access review items for. Mandatory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([item objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCertificationItems -CertificationId 'cert-xyz' -CorrelationID $cid
        $items = $result.Data
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting access review items for certification '$CertificationId' (auto-paginating)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertificationItems' `
        -CorrelationID $CorrelationID

    try {
        $allItems = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0
        $endpoint = "/certifications/$CertificationId/access-review-items"

        # M2: pagination ceiling.
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached: $maxPages pages already fetched (accumulated $($allItems.Count) items). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertificationItems' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint $endpoint `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditCertificationItems failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertificationItems' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize response
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($item in $page) { $allItems.Add($item) }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) access review items (running total: $($allItems.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertificationItems' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allItems.Count) total access review items for certification '$CertificationId'" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertificationItems' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $allItems.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCertificationItems failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCertificationItems' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditCampaignReport {
    <#
    .SYNOPSIS
        Downloads a campaign report CSV from the SailPoint ISC legacy report API.
    .DESCRIPTION
        Two-step process:
          Step 1: GET /v3/campaigns/{campaignId}/reports
                  Finds the matching reportType entry and extracts taskResultId.
          Step 2: GET /cc/api/report/get/{taskResultId}?format=csv
                  Downloads the CSV using a direct Invoke-RestMethod call against
                  the tenant base URL (not the /v3 API base).  The bearer token is
                  obtained from Get-SPAuthToken.

        The legacy /cc/api endpoint is NOT routed through Invoke-SPApiRequest because
        its URL root differs from Api.BaseUrl (/v3).  The function builds the full
        URL from Authentication.ConfigFile.TenantUrl.

        Graceful fallback:
          If the legacy endpoint returns 403 or 404, the function returns Success=$false
          with an instructional error message advising the caller to download the CSV
          manually and use Import-SPAuditCampaignReport instead.

        If OutputDir is specified and the download succeeds, the CSV is written to
        disk as: {OutputDir}\{CampaignId}_{ReportType}.csv
    .PARAMETER CampaignId
        The campaign ID to download the report for. Mandatory.
    .PARAMETER ReportType
        The report type to download.
        Valid values: CAMPAIGN_STATUS_REPORT, CERTIFICATION_SIGNOFF_REPORT
    .PARAMETER OutputDir
        Optional directory path where the downloaded CSV file will be saved.
        If omitted the CSV content is returned in Data but not written to disk.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=[string CSV content or $null]; Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCampaignReport -CampaignId 'camp-abc' `
                    -ReportType CAMPAIGN_STATUS_REPORT -OutputDir 'C:\Reports'
        if ($result.Success) { Write-Host "Saved to $($result.Data)" }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter(Mandatory)]
        [ValidateSet('CAMPAIGN_STATUS_REPORT', 'CERTIFICATION_SIGNOFF_REPORT')]
        [string]$ReportType,

        [Parameter()]
        [string]$OutputDir,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Downloading campaign report: CampaignId='$CampaignId', ReportType='$ReportType'" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: List available reports for the campaign
        $reportsResult = Invoke-SPApiRequest -Method GET `
            -Endpoint "/campaigns/$CampaignId/reports" `
            -CorrelationID $CorrelationID

        if (-not $reportsResult.Success) {
            $errMsg = "Failed to list reports for campaign '$CampaignId': $($reportsResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # Find the matching report entry
        $reportsData = $reportsResult.Data
        if ($null -eq $reportsData) { $reportsData = @() }

        # API may return array directly or object with items
        if ($reportsData.PSObject.Properties.Name -contains 'items') {
            $reportsData = $reportsData.items
        }
        # Force array wrap (H1 fix) - a single report in the .items array
        # would otherwise be unwrapped to a bare object and the foreach below
        # would iterate its PROPERTIES instead of finding the single report.
        $reportsData = @($reportsData)

        $matchingReport = $null
        foreach ($report in $reportsData) {
            if ($report.type -eq $ReportType -or $report.reportType -eq $ReportType) {
                $matchingReport = $report
                break
            }
        }

        if ($null -eq $matchingReport) {
            $errMsg = "Report type '$ReportType' not found in campaign '$CampaignId' report list. " +
                      "The campaign may not be completed, or this report type is unavailable."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # Extract taskResultId - field name varies by ISC version
        $taskResultId = $null
        foreach ($prop in @('taskResultId', 'task_result_id', 'taskId', 'id')) {
            if ($null -ne $matchingReport.PSObject.Properties[$prop]) {
                $taskResultId = $matchingReport.$prop
                if (-not [string]::IsNullOrWhiteSpace($taskResultId)) { break }
            }
        }

        if ([string]::IsNullOrWhiteSpace($taskResultId)) {
            $errMsg = "Could not extract taskResultId from report object for type '$ReportType'. " +
                      "Use Import-SPAuditCampaignReport to import a manually downloaded CSV."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        Write-SPLog -Message "Found report '$ReportType' with taskResultId='$taskResultId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
            -CorrelationID $CorrelationID

        # Step 2: Download CSV - try v3 API first, fall back to legacy /cc/api
        # v3 endpoint: GET /reports/{taskResultId}?fileFormat=csv  (available since Nov 2023)
        # Legacy:      GET /cc/api/report/get/{taskResultId}?format=csv (deprecated Feb 2024)
        $csvContent = $null

        # --- Attempt v3 first via Invoke-SPApiRequest ---
        Write-SPLog -Message "Attempting v3 report download for taskResultId='$taskResultId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
            -CorrelationID $CorrelationID

        $v3Result = Invoke-SPApiRequest -Method GET `
            -Endpoint "/reports/$taskResultId" `
            -QueryParams @{ fileFormat = 'csv' } `
            -RawResponse `
            -CorrelationID $CorrelationID

        if ($v3Result.Success -and $null -ne $v3Result.Data) {
            $csvContent = $v3Result.Data
            Write-SPLog -Message "v3 report download succeeded for taskResultId='$taskResultId'" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID
        }
        else {
            # --- Silent fallback to legacy /cc/api ---
            Write-SPLog -Message "v3 report download failed (StatusCode=$($v3Result.StatusCode)). Falling back to legacy /cc/api." `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID

            $config    = Get-SPConfig
            $tenantUrl = $config.Authentication.ConfigFile.TenantUrl.TrimEnd('/')

            if ([string]::IsNullOrWhiteSpace($tenantUrl)) {
                $tenantUrl = $config.Api.BaseUrl -replace '/v3$', '' -replace '/v3/', ''
                $tenantUrl = $tenantUrl.TrimEnd('/')
            }

            $reportUrl = "$tenantUrl/cc/api/report/get/$taskResultId" + '?format=csv'

            Write-SPLog -Message "Calling legacy report URL: $reportUrl" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID

            $authResult = Get-SPAuthToken -CorrelationID $CorrelationID
            if (-not $authResult.Success) {
                $errMsg = "Cannot acquire auth token for report download: $($authResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $timeoutSec = 120
            try {
                $configTimeout = $config.Api.TimeoutSeconds
                if ($configTimeout -gt 0) { $timeoutSec = $configTimeout }
            }
            catch { }

            try {
                $csvContent = Invoke-RestMethod `
                    -Uri        $reportUrl `
                    -Method     GET `
                    -Headers    $authResult.Data.Headers `
                    -TimeoutSec $timeoutSec `
                    -ErrorAction Stop
            }
            catch {
                $exc        = $_.Exception
                $statusCode = 0
                try {
                    if ($exc -is [System.Net.WebException] -and $null -ne $exc.Response) {
                        $statusCode = [int]$exc.Response.StatusCode
                    }
                    elseif ($exc.Message -match '(\d{3})') {
                        $statusCode = [int]$Matches[1]
                    }
                }
                catch { }

                if ($statusCode -eq 403 -or $statusCode -eq 404) {
                    $errMsg = "Campaign report API unavailable (v3 and legacy both failed) for taskResultId='$taskResultId'. " +
                              "Download the CSV manually from the SailPoint UI and use " +
                              "Import-SPAuditCampaignReport -CsvDirectoryPath to import it."
                    Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                        -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $errMsg = "Report download failed (HTTP $statusCode): $($exc.Message)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }
        }

        # Optionally persist to disk
        if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
            if (-not (Test-Path -Path $OutputDir -PathType Container)) {
                New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
            }
            $safeReportType = $ReportType -replace '[^A-Za-z0-9_\-]', '_'
            $fileName       = "${CampaignId}_${safeReportType}.csv"
            $filePath       = Join-Path -Path $OutputDir -ChildPath $fileName
            Set-Content -Path $filePath -Value $csvContent -Encoding UTF8
            Write-SPLog -Message "Campaign report saved to '$filePath'" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID
        }

        return @{ Success = $true; Data = $csvContent; Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCampaignReport failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Import-SPAuditCampaignReport {
    <#
    .SYNOPSIS
        Imports manually downloaded campaign report CSVs from a local directory.
    .DESCRIPTION
        Scans CsvDirectoryPath for files matching two patterns:
          *Status*Report*.csv   -> loaded as the campaign status report
          *Sign*Off*.csv        -> loaded as the sign-off report
        Both patterns are case-insensitive.  Files are parsed with Import-Csv.
        At least one matching file must be found for Success=$true.

        Useful when Get-SPAuditCampaignReport is blocked by legacy API restrictions
        and the CSV was downloaded manually from the SailPoint ISC UI.
    .PARAMETER CsvDirectoryPath
        Directory that contains the manually downloaded CSV file(s). Mandatory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                StatusReport = [object[]] or $null
                SignOffReport = [object[]] or $null
            }
            Error = $string
        }
    .EXAMPLE
        $result = Import-SPAuditCampaignReport -CsvDirectoryPath 'C:\Downloads\Reports'
        if ($result.Success) {
            $status  = $result.Data.StatusReport
            $signOff = $result.Data.SignOffReport
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvDirectoryPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Importing campaign report CSVs from '$CsvDirectoryPath'" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
        -CorrelationID $CorrelationID

    try {
        if (-not (Test-Path -Path $CsvDirectoryPath -PathType Container)) {
            $errMsg = "CSV directory not found: '$CsvDirectoryPath'"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $allCsvFiles = Get-ChildItem -Path $CsvDirectoryPath -Filter '*.csv' -File -ErrorAction Stop

        if ($null -eq $allCsvFiles -or $allCsvFiles.Count -eq 0) {
            $errMsg = "No CSV files found in '$CsvDirectoryPath'"
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $statusReportData  = $null
        $signOffReportData = $null
        $foundAny          = $false

        foreach ($file in $allCsvFiles) {
            $name = $file.Name

            # Status report pattern: *Status*Report*.csv (case-insensitive)
            if ($name -imatch 'Status.*Report' -or $name -imatch 'Report.*Status') {
                Write-SPLog -Message "Loading status report from '$($file.FullName)'" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
                    -CorrelationID $CorrelationID
                $statusReportData = Import-Csv -Path $file.FullName -ErrorAction Stop
                $foundAny = $true
                continue
            }

            # Sign-off report pattern: *Sign*Off*.csv (case-insensitive)
            if ($name -imatch 'Sign.*Off' -or $name -imatch 'Signoff' -or $name -imatch 'SignOff') {
                Write-SPLog -Message "Loading sign-off report from '$($file.FullName)'" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
                    -CorrelationID $CorrelationID
                $signOffReportData = Import-Csv -Path $file.FullName -ErrorAction Stop
                $foundAny = $true
                continue
            }
        }

        if (-not $foundAny) {
            $errMsg = "No matching CSV files found in '$CsvDirectoryPath'. " +
                      "Expected files matching '*Status*Report*.csv' or '*Sign*Off*.csv'."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $statusCount  = if ($null -ne $statusReportData) { @($statusReportData).Count } else { 0 }
        $signOffCount = if ($null -ne $signOffReportData) { @($signOffReportData).Count } else { 0 }

        Write-SPLog -Message "Imported campaign reports: StatusReport=$statusCount rows, SignOffReport=$signOffCount rows" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                StatusReport  = $statusReportData
                SignOffReport = $signOffReportData
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Import-SPAuditCampaignReport failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditIdentityEvents {
    <#
    .SYNOPSIS
        Retrieves provisioning account-activity events for a specific identity.
    .DESCRIPTION
        GETs /v3/account-activities filtered by requested-for={identityId} and
        auto-paginates.  Client-side date filtering is applied on the 'created'
        field using the DaysBack parameter.

        For each activity, the source name for items within the activity is resolved
        via Get-SPAuditSourceName (which uses an in-module cache).  Each returned
        activity object is annotated with a 'ResolvedSourceNames' property containing
        a hashtable keyed by sourceId with display names as values.

        This function is designed for post-campaign audit use cases: understanding
        what provisioning changes occurred for an identity near a campaign date.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to query events for. Mandatory.
    .PARAMETER DaysBack
        Number of calendar days to look back from now for events. Default: 2.
        Set to 0 to disable date filtering and return all available events.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([activity objects with ResolvedSourceNames]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditIdentityEvents -IdentityId 'id-abc123' -DaysBack 7 -CorrelationID $cid
        foreach ($event in $result.Data) {
            $event.action
            $event.ResolvedSourceNames
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentityId,

        [Parameter()]
        [int]$DaysBack = 2,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting identity events for '$IdentityId' (DaysBack=$DaysBack)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
        -CorrelationID $CorrelationID

    try {
        $allActivities = [System.Collections.Generic.List[object]]::new()
        $pageSize      = 250
        $offset        = 0
        $pageNum       = 0

        # M2: pagination ceiling.
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached: $maxPages pages already fetched (accumulated $($allActivities.Count) activities). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditIdentityEvents' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'requested-for' = $IdentityId
                'limit'         = $pageSize.ToString()
                'offset'        = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/account-activities' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditIdentityEvents failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditIdentityEvents' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize response
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($activity in $page) { $allActivities.Add($activity) }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) account activities (running total: $($allActivities.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allActivities.Count) total account activities before date filtering" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
            -CorrelationID $CorrelationID

        # Client-side date filter
        $filteredActivities = [System.Collections.Generic.List[object]]::new()
        if ($DaysBack -gt 0) {
            $cutoff = (Get-Date).AddDays(-$DaysBack)
            foreach ($activity in $allActivities) {
                $createdRaw = $activity.created
                if ($null -eq $createdRaw) {
                    $filteredActivities.Add($activity)
                    continue
                }

                $createdDate = $null
                if ($createdRaw -is [datetime]) {
                    $createdDate = [datetime]$createdRaw
                }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsedDate)) {
                        $createdDate = $parsedDate
                    }
                }

                if ($null -eq $createdDate -or $createdDate -ge $cutoff) {
                    $filteredActivities.Add($activity)
                }
            }

            Write-SPLog -Message "Date filter (last $DaysBack days): $($allActivities.Count) -> $($filteredActivities.Count) activities" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
                -CorrelationID $CorrelationID
        }
        else {
            foreach ($activity in $allActivities) { $filteredActivities.Add($activity) }
        }

        # Resolve source names for items within each activity
        foreach ($activity in $filteredActivities) {
            $resolvedNames = @{}

            $activityItems = $null
            if ($null -ne $activity.PSObject.Properties['items'] -and $null -ne $activity.items) {
                $activityItems = $activity.items
            }

            if ($null -ne $activityItems) {
                foreach ($actItem in $activityItems) {
                    # Source ID may be on the item directly or nested under source/sourceRef
                    $sourceId = $null
                    foreach ($prop in @('sourceId', 'source_id')) {
                        if ($null -ne $actItem.PSObject.Properties[$prop]) {
                            $sourceId = $actItem.$prop
                            if (-not [string]::IsNullOrWhiteSpace($sourceId)) { break }
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($sourceId) -and
                        $null -ne $actItem.PSObject.Properties['source'] -and
                        $null -ne $actItem.source -and
                        $null -ne $actItem.source.PSObject.Properties['id']) {
                        $sourceId = $actItem.source.id
                    }

                    if (-not [string]::IsNullOrWhiteSpace($sourceId) -and
                        -not $resolvedNames.ContainsKey($sourceId)) {
                        $resolvedNames[$sourceId] = Get-SPAuditSourceName `
                            -SourceId $sourceId -CorrelationID $CorrelationID
                    }
                }
            }

            $activity | Add-Member -MemberType NoteProperty -Name 'ResolvedSourceNames' `
                -Value $resolvedNames -Force
        }

        Write-SPLog -Message "Returning $($filteredActivities.Count) account activities for identity '$IdentityId'" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $filteredActivities.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditIdentityEvents failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditIdentityEvents' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Resolve-SPAuditIdentityAccounts {
    <#
    .SYNOPSIS
        Batch-resolves identity IDs to account details (sAMAccountName, UPN, mail).
    .DESCRIPTION
        Calls Get-SPAuditAccountForIdentity for each supplied identity ID and returns
        a hashtable keyed by identity ID. The internal per-identity cache means duplicate
        IDs are not re-fetched within the same session.

        Intended to be called once per campaign with all unique identity IDs collected
        from the review items, before passing the resulting map to
        Group-SPAuditDecisions and Group-SPAuditRemediationProof via -AccountMap.
    .PARAMETER IdentityIds
        Array of identity ID strings to resolve.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{ identityId = @{SamAccountName; UserPrincipalName; Email; NativeIdentity} }
            Error   = $string
        }
    .EXAMPLE
        $acctResult = Resolve-SPAuditIdentityAccounts -IdentityIds $ids -CorrelationID $cid
        if ($acctResult.Success) { $accountMap = $acctResult.Data }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$IdentityIds,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Resolving account attributes for $($IdentityIds.Count) unique identity ID(s)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Resolve-SPAuditIdentityAccounts' `
        -CorrelationID $CorrelationID

    try {
        $results = @{}
        foreach ($id in $IdentityIds) {
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $results[$id] = Get-SPAuditAccountForIdentity -IdentityId $id -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Account resolution complete: $($results.Count) identit(ies) resolved" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Resolve-SPAuditIdentityAccounts' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $results; Error = $null }
    }
    catch {
        $errMsg = "Resolve-SPAuditIdentityAccounts failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Resolve-SPAuditIdentityAccounts' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPReviewerWorkload {
    <#
    .SYNOPSIS
        Finds all active campaigns/certifications assigned to a specific reviewer.
    .DESCRIPTION
        Retrieves campaigns matching the status filter, then for each campaign
        fetches certifications and filters to those where the effective reviewer
        matches the supplied ReviewerIdentityId. Returns per-campaign workload
        counts (total items, decided items, pending items) plus aggregate totals.

        Uses Get-SPAuditCampaigns and Get-SPAuditCertifications internally.
        Item counts are derived from certification-level statistics (decisionsTotal,
        decisionsMade) to avoid additional per-item API calls.
    .PARAMETER ReviewerIdentityId
        The SailPoint ISC identity ID of the reviewer. Mandatory.
    .PARAMETER Status
        Campaign status filter. Default: @('ACTIVE').
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@{ReviewerId; ReviewerName; TotalCampaigns;
        TotalItems; TotalPending; Campaigns=@(...)}; Error=$string}
    .EXAMPLE
        $result = Get-SPReviewerWorkload -ReviewerIdentityId 'id-mgr-001'
        $result.Data.Campaigns | Format-Table CampaignName, ItemsAssigned, ItemsPending
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ReviewerIdentityId,

        [Parameter()]
        [string[]]$Status = @('ACTIVE'),

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting reviewer workload for identity '$ReviewerIdentityId' (Status=$($Status -join ','))" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPReviewerWorkload' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: Get campaigns matching status filter (DaysBack=0 to disable date filter)
        $campaignResult = Get-SPAuditCampaigns -Status $Status -DaysBack 0 `
            -CorrelationID $CorrelationID

        if (-not $campaignResult.Success) {
            $errMsg = "Get-SPReviewerWorkload failed to retrieve campaigns: $($campaignResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Get-SPReviewerWorkload' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $campaigns = @($campaignResult.Data)
        Write-SPLog -Message "Found $($campaigns.Count) campaigns to scan for reviewer '$ReviewerIdentityId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPReviewerWorkload' `
            -CorrelationID $CorrelationID

        $reviewerName     = ''
        $campaignWorkload = [System.Collections.Generic.List[object]]::new()
        $grandTotalItems  = 0
        $grandTotalDecided = 0

        # Step 2-3: For each campaign, get certs and filter by reviewer
        foreach ($campaign in $campaigns) {
            if ($null -eq $campaign) { continue }

            $campId   = $campaign.id
            $campName = $campaign.name

            $certResult = Get-SPAuditCertifications -CampaignId $campId `
                -CorrelationID $CorrelationID

            if (-not $certResult.Success) {
                Write-SPLog -Message "Skipping campaign '$campName' ($campId): $($certResult.Error)" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPReviewerWorkload' `
                    -CorrelationID $CorrelationID
                continue
            }

            $certs = @($certResult.Data)
            $campItems   = 0
            $campDecided = 0

            foreach ($cert in $certs) {
                if ($null -eq $cert) { continue }

                # Check if effective reviewer matches
                $reviewerId = $null
                if ($null -ne $cert.EffectiveReviewer -and
                    $null -ne $cert.EffectiveReviewer.PSObject.Properties['id']) {
                    $reviewerId = $cert.EffectiveReviewer.id
                }

                if ($reviewerId -ne $ReviewerIdentityId) { continue }

                # Capture reviewer name from first match
                if ([string]::IsNullOrWhiteSpace($reviewerName) -and
                    $null -ne $cert.EffectiveReviewer.PSObject.Properties['displayName'] -and
                    -not [string]::IsNullOrWhiteSpace($cert.EffectiveReviewer.displayName)) {
                    $reviewerName = $cert.EffectiveReviewer.displayName
                }

                # Extract item counts from certification-level stats
                $totalItems  = 0
                $decidedItems = 0

                if ($null -ne $cert.PSObject.Properties['decisionsTotal'] -and
                    $null -ne $cert.decisionsTotal) {
                    $totalItems = [int]$cert.decisionsTotal
                }
                elseif ($null -ne $cert.PSObject.Properties['totalCount'] -and
                        $null -ne $cert.totalCount) {
                    $totalItems = [int]$cert.totalCount
                }

                if ($null -ne $cert.PSObject.Properties['decisionsMade'] -and
                    $null -ne $cert.decisionsMade) {
                    $decidedItems = [int]$cert.decisionsMade
                }
                elseif ($null -ne $cert.PSObject.Properties['completedCount'] -and
                        $null -ne $cert.completedCount) {
                    $decidedItems = [int]$cert.completedCount
                }

                $campItems   += $totalItems
                $campDecided += $decidedItems
            }

            # Only include campaigns where the reviewer has certifications
            if ($campItems -gt 0 -or $campDecided -gt 0) {
                $pending = $campItems - $campDecided
                if ($pending -lt 0) { $pending = 0 }

                $campaignWorkload.Add([PSCustomObject]@{
                    CampaignId    = $campId
                    CampaignName  = $campName
                    ItemsAssigned = $campItems
                    ItemsDecided  = $campDecided
                    ItemsPending  = $pending
                })

                $grandTotalItems   += $campItems
                $grandTotalDecided += $campDecided
            }
        }

        $grandTotalPending = $grandTotalItems - $grandTotalDecided
        if ($grandTotalPending -lt 0) { $grandTotalPending = 0 }

        Write-SPLog -Message "Reviewer '$ReviewerIdentityId' workload: $($campaignWorkload.Count) campaigns, $grandTotalItems items ($grandTotalPending pending)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPReviewerWorkload' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                ReviewerId     = $ReviewerIdentityId
                ReviewerName   = $reviewerName
                TotalCampaigns = $campaignWorkload.Count
                TotalItems     = $grandTotalItems
                TotalPending   = $grandTotalPending
                Campaigns      = $campaignWorkload.ToArray()
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPReviewerWorkload failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPReviewerWorkload' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPIdentityDecisionHistory {
    <#
    .SYNOPSIS
        Finds all access review decisions made about a specific identity across campaigns.
    .DESCRIPTION
        Answers: "What has been decided about this identity's access in every campaign?"
        Retrieves campaigns matching status and date filters, then for each campaign
        fetches certifications and access review items, filtering to items where
        identitySummary.id matches the supplied IdentityId.

        Returns a chronological list (newest first) of decisions grouped by campaign,
        including the access name, decision, reviewer name, and decision date.

        Uses Get-SPAuditCampaigns, Get-SPAuditCertifications, and
        Get-SPAuditCertificationItems internally.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to search decisions for. Mandatory.
    .PARAMETER Status
        Campaign status filter. Default: @('COMPLETED','ACTIVE').
    .PARAMETER DaysBack
        Number of calendar days to look back. Default: 365.
        Set to 0 to disable date filtering.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@{IdentityId; IdentityName; TotalDecisions;
        Campaigns=@(@{CampaignName; CampaignDate; Decisions=@(...)})}; Error=$string}
    .EXAMPLE
        $result = Get-SPIdentityDecisionHistory -IdentityId 'id-001' -DaysBack 365
        $result.Data.Campaigns | ForEach-Object { $_.CampaignName; $_.Decisions.Count }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentityId,

        [Parameter()]
        [string[]]$Status = @('COMPLETED', 'ACTIVE'),

        [Parameter()]
        [int]$DaysBack = 365,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting identity decision history for '$IdentityId' (Status=$($Status -join ','), DaysBack=$DaysBack)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: Get campaigns matching status + date filters
        $campaignResult = Get-SPAuditCampaigns -Status $Status -DaysBack $DaysBack `
            -CorrelationID $CorrelationID

        if (-not $campaignResult.Success) {
            $errMsg = "Get-SPIdentityDecisionHistory failed to retrieve campaigns: $($campaignResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Get-SPIdentityDecisionHistory' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $campaigns = @($campaignResult.Data)
        Write-SPLog -Message "Found $($campaigns.Count) campaigns to scan for identity '$IdentityId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
            -CorrelationID $CorrelationID

        $identityName       = ''
        $totalDecisions     = 0
        $campaignResults    = [System.Collections.Generic.List[object]]::new()

        # Step 2-4: For each campaign, get certs -> items -> filter by identity
        foreach ($campaign in $campaigns) {
            if ($null -eq $campaign) { continue }

            $campId   = $campaign.id
            $campName = $campaign.name

            # Extract campaign date (use 'created' field)
            $campDate = ''
            if ($null -ne $campaign.created) {
                if ($campaign.created -is [datetime]) {
                    $campDate = ([datetime]$campaign.created).ToUniversalTime().ToString('yyyy-MM-dd')
                }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($campaign.created.ToString(), [ref]$parsedDate)) {
                        $campDate = $parsedDate.ToUniversalTime().ToString('yyyy-MM-dd')
                    }
                    else {
                        $campDate = $campaign.created.ToString()
                    }
                }
            }

            $certResult = Get-SPAuditCertifications -CampaignId $campId `
                -CorrelationID $CorrelationID

            if (-not $certResult.Success) {
                Write-SPLog -Message "Skipping campaign '$campName' ($campId): $($certResult.Error)" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
                    -CorrelationID $CorrelationID
                continue
            }

            $certs = @($certResult.Data)
            $campDecisions = [System.Collections.Generic.List[object]]::new()

            foreach ($cert in $certs) {
                if ($null -eq $cert) { continue }

                $certId = $cert.id
                $itemResult = Get-SPAuditCertificationItems -CertificationId $certId `
                    -CorrelationID $CorrelationID

                if (-not $itemResult.Success) {
                    Write-SPLog -Message "Skipping cert '$certId' in campaign '$campName': $($itemResult.Error)" `
                        -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
                        -CorrelationID $CorrelationID
                    continue
                }

                $items = @($itemResult.Data)
                foreach ($item in $items) {
                    if ($null -eq $item) { continue }

                    # Check if this item is for our target identity
                    $itemIdentityId = $null
                    if ($null -ne $item.PSObject.Properties['identitySummary'] -and
                        $null -ne $item.identitySummary -and
                        $null -ne $item.identitySummary.PSObject.Properties['id']) {
                        $itemIdentityId = $item.identitySummary.id
                    }

                    if ($itemIdentityId -ne $IdentityId) { continue }

                    # Capture identity name from first match
                    if ([string]::IsNullOrWhiteSpace($identityName) -and
                        $null -ne $item.identitySummary.PSObject.Properties['name'] -and
                        -not [string]::IsNullOrWhiteSpace($item.identitySummary.name)) {
                        $identityName = $item.identitySummary.name
                    }

                    # Extract decision details
                    $accessName   = ''
                    $decision     = ''
                    $reviewerName = ''
                    $decisionDate = ''

                    # Access name: try access.name, then entitlementName, then displayName
                    if ($null -ne $item.PSObject.Properties['access'] -and
                        $null -ne $item.access -and
                        $null -ne $item.access.PSObject.Properties['name']) {
                        $accessName = $item.access.name
                    }
                    elseif ($null -ne $item.PSObject.Properties['entitlementName'] -and
                            -not [string]::IsNullOrWhiteSpace($item.entitlementName)) {
                        $accessName = $item.entitlementName
                    }
                    elseif ($null -ne $item.PSObject.Properties['displayName'] -and
                            -not [string]::IsNullOrWhiteSpace($item.displayName)) {
                        $accessName = $item.displayName
                    }

                    # Decision
                    if ($null -ne $item.PSObject.Properties['decision'] -and
                        -not [string]::IsNullOrWhiteSpace($item.decision)) {
                        $decision = $item.decision
                    }

                    # Reviewer name
                    if ($null -ne $item.PSObject.Properties['reviewer'] -and
                        $null -ne $item.reviewer -and
                        $null -ne $item.reviewer.PSObject.Properties['name']) {
                        $reviewerName = $item.reviewer.name
                    }
                    # Fallback to cert-level effective reviewer
                    if ([string]::IsNullOrWhiteSpace($reviewerName) -and
                        $null -ne $cert.EffectiveReviewer -and
                        $null -ne $cert.EffectiveReviewer.PSObject.Properties['displayName']) {
                        $reviewerName = $cert.EffectiveReviewer.displayName
                    }

                    # Decision date
                    if ($null -ne $item.PSObject.Properties['completed'] -and
                        $null -ne $item.completed) {
                        if ($item.completed -is [datetime]) {
                            $decisionDate = ([datetime]$item.completed).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                        else {
                            $decisionDate = $item.completed.ToString()
                        }
                    }

                    $campDecisions.Add([PSCustomObject]@{
                        AccessName   = $accessName
                        Decision     = $decision
                        ReviewerName = $reviewerName
                        DecisionDate = $decisionDate
                    })
                }
            }

            # Only include campaigns where this identity had review items
            if ($campDecisions.Count -gt 0) {
                $totalDecisions += $campDecisions.Count

                $campaignResults.Add([PSCustomObject]@{
                    CampaignId   = $campId
                    CampaignName = $campName
                    CampaignDate = $campDate
                    Decisions    = $campDecisions.ToArray()
                })
            }
        }

        # Sort campaigns newest first by CampaignDate
        $sortedCampaigns = @($campaignResults | Sort-Object -Property CampaignDate -Descending)

        Write-SPLog -Message "Identity '$IdentityId' decision history: $totalDecisions decisions across $($sortedCampaigns.Count) campaigns" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                IdentityId     = $IdentityId
                IdentityName   = $identityName
                TotalDecisions = $totalDecisions
                Campaigns      = $sortedCampaigns
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPIdentityDecisionHistory failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPIdentityDecisionHistory' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPSourceCampaignCoverage {
    <#
    .SYNOPSIS
        Analyzes which sources have been covered by campaigns and which have not.
    .DESCRIPTION
        Builds a coverage map of all ISC sources against certification campaigns.

        Step 1: Paginate GET /v3/sources to retrieve every source.
        Step 2: Get campaigns matching the supplied status and date filters.
        Step 3: For SOURCE_OWNER campaigns, extract sourceIds directly from the
                campaign object (no need to drill into items).
        Step 4: For other campaign types, drill into certifications and access
                review items to discover which sourceIds were covered.
        Step 5: Build the coverage map -- each source mapped to the campaigns
                that audited it, with a last-campaign date and count.

        Sources that appear in zero campaigns are flagged as Uncovered.
        A Summary hashtable provides TotalSources, Covered, Uncovered, and
        CoverageRate (percentage).

        All DateTime comparisons use .ToUniversalTime() to avoid Kind mismatch.
    .PARAMETER Status
        Campaign status filter. Default: @('COMPLETED','ACTIVE').
    .PARAMETER DaysBack
        Number of calendar days to look back for campaigns. Default: 365.
        Set to 0 to disable date filtering.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Covered   = @(@{ SourceId; SourceName; LastCampaign; LastCampaignDate; CampaignCount })
                Uncovered = @(@{ SourceId; SourceName; NeverAudited=$true })
                Summary   = @{ TotalSources=N; Covered=N; Uncovered=N; CoverageRate=N }
            }
            Error = $string
        }
    .EXAMPLE
        $result = Get-SPSourceCampaignCoverage -DaysBack 365
        $result.Data.Summary
    .EXAMPLE
        $result = Get-SPSourceCampaignCoverage -Status 'COMPLETED' -DaysBack 180
        $result.Data.Uncovered | ForEach-Object { $_.SourceName }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$Status = @('COMPLETED', 'ACTIVE'),

        [Parameter()]
        [int]$DaysBack = 365,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting source campaign coverage: Status='$($Status -join ',')', DaysBack=$DaysBack" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
        -CorrelationID $CorrelationID

    try {
        # -----------------------------------------------------------
        # Step 1: Retrieve all sources via GET /v3/sources (paginated)
        # -----------------------------------------------------------
        $allSources = [System.Collections.Generic.List[object]]::new()
        $pageSize   = 250
        $offset     = 0
        $pageNum    = 0

        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached fetching sources: $maxPages pages ($($allSources.Count) sources). Raise Api.MaxPaginationPages if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPSourceCampaignCoverage' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }

            $srcResult = Invoke-SPApiRequest -Method GET -Endpoint '/sources' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $srcResult.Success) {
                $errMsg = "Failed to retrieve sources at page $pageNum (offset $offset): $($srcResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPSourceCampaignCoverage' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $page = $srcResult.Data
            if ($null -ne $srcResult.Data -and $srcResult.Data.PSObject.Properties.Name -contains 'items') {
                $page = $srcResult.Data.items
            }
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($src in $page) { $allSources.Add($src) }
            }

            Write-SPLog -Message "Sources page ${pageNum}: $($page.Count) sources (running total: $($allSources.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
                -CorrelationID $CorrelationID

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allSources.Count) total sources" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
            -CorrelationID $CorrelationID

        if ($allSources.Count -eq 0) {
            return @{
                Success = $true
                Data    = @{
                    Covered   = @()
                    Uncovered = @()
                    Summary   = @{ TotalSources = 0; Covered = 0; Uncovered = 0; CoverageRate = 0 }
                }
                Error   = $null
            }
        }

        # Build source lookup: id -> name
        $sourceMap = @{}
        foreach ($src in $allSources) {
            $srcId   = $src.id
            $srcName = $src.name
            if ([string]::IsNullOrWhiteSpace($srcName)) { $srcName = $srcId }
            $sourceMap[$srcId] = $srcName
            # Also populate the module-scope cache for downstream use
            $script:SourceNameCache[$srcId] = $srcName
        }

        # -----------------------------------------------------------
        # Step 2: Get campaigns matching status + date filters
        # -----------------------------------------------------------
        $campaignResult = Get-SPAuditCampaigns -Status $Status -DaysBack $DaysBack `
            -CorrelationID $CorrelationID

        if (-not $campaignResult.Success) {
            $errMsg = "Get-SPSourceCampaignCoverage failed to retrieve campaigns: $($campaignResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Get-SPSourceCampaignCoverage' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $campaigns = @($campaignResult.Data)
        Write-SPLog -Message "Found $($campaigns.Count) campaigns to scan for source coverage" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
            -CorrelationID $CorrelationID

        # -----------------------------------------------------------
        # Steps 3-4: Build coverage data -- sourceId -> list of campaign info
        # -----------------------------------------------------------
        # Key: sourceId, Value: List of @{CampaignId; CampaignName; CampaignDate}
        $coverageData = @{}

        foreach ($campaign in $campaigns) {
            if ($null -eq $campaign) { continue }

            $campId   = $campaign.id
            $campName = $campaign.name
            $campType = $campaign.type

            # Parse campaign date
            $campDate = ''
            if ($null -ne $campaign.created) {
                if ($campaign.created -is [datetime]) {
                    $campDate = ([datetime]$campaign.created).ToUniversalTime().ToString('yyyy-MM-dd')
                } else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($campaign.created.ToString(), [ref]$parsedDate)) {
                        $campDate = $parsedDate.ToUniversalTime().ToString('yyyy-MM-dd')
                    } else {
                        $campDate = $campaign.created.ToString()
                    }
                }
            }

            $campInfo = @{
                CampaignId   = $campId
                CampaignName = $campName
                CampaignDate = $campDate
            }

            # Step 3: SOURCE_OWNER campaigns have sourceIds directly
            if ($campType -eq 'SOURCE_OWNER') {
                $sourceIds = @()
                if ($null -ne $campaign.PSObject.Properties['sourceIds'] -and
                    $null -ne $campaign.sourceIds) {
                    $sourceIds = @($campaign.sourceIds)
                }
                # Also check searchCampaignInfo.sourcedIds or sourcedApplicationIds
                if ($sourceIds.Count -eq 0 -and
                    $null -ne $campaign.PSObject.Properties['searchCampaignInfo'] -and
                    $null -ne $campaign.searchCampaignInfo) {
                    $sci = $campaign.searchCampaignInfo
                    if ($null -ne $sci.PSObject.Properties['sourceIds'] -and $null -ne $sci.sourceIds) {
                        $sourceIds = @($sci.sourceIds)
                    }
                }

                foreach ($sid in $sourceIds) {
                    if ([string]::IsNullOrWhiteSpace($sid)) { continue }
                    if (-not $coverageData.ContainsKey($sid)) {
                        $coverageData[$sid] = [System.Collections.Generic.List[object]]::new()
                    }
                    $coverageData[$sid].Add($campInfo)
                }

                # If we found sourceIds, no need to drill into items
                if ($sourceIds.Count -gt 0) { continue }
            }

            # Step 4: For non-SOURCE_OWNER (or SOURCE_OWNER with no sourceIds),
            # drill into certifications -> items -> access.sourceId
            $certResult = Get-SPAuditCertifications -CampaignId $campId `
                -CorrelationID $CorrelationID

            if (-not $certResult.Success) {
                Write-SPLog -Message "Skipping campaign '$campName' ($campId) for source coverage: $($certResult.Error)" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
                    -CorrelationID $CorrelationID
                continue
            }

            $certs = @($certResult.Data)
            # Track which sourceIds we already found for this campaign to avoid
            # redundant item-level API calls
            $campaignSourceIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)

            foreach ($cert in $certs) {
                if ($null -eq $cert) { continue }

                $itemResult = Get-SPAuditCertificationItems -CertificationId $cert.id `
                    -CorrelationID $CorrelationID

                if (-not $itemResult.Success) {
                    Write-SPLog -Message "Skipping cert '$($cert.id)' in campaign '$campName': $($itemResult.Error)" `
                        -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
                        -CorrelationID $CorrelationID
                    continue
                }

                $items = @($itemResult.Data)
                foreach ($item in $items) {
                    if ($null -eq $item) { continue }

                    # Extract sourceId from the access review item
                    $itemSourceId = $null

                    # Try access.sourceId first
                    if ($null -ne $item.PSObject.Properties['access'] -and
                        $null -ne $item.access) {
                        if ($null -ne $item.access.PSObject.Properties['sourceId'] -and
                            -not [string]::IsNullOrWhiteSpace($item.access.sourceId)) {
                            $itemSourceId = $item.access.sourceId
                        }
                        elseif ($null -ne $item.access.PSObject.Properties['source'] -and
                                $null -ne $item.access.source -and
                                $null -ne $item.access.source.PSObject.Properties['id']) {
                            $itemSourceId = $item.access.source.id
                        }
                    }

                    # Fallback: item-level sourceId
                    if ([string]::IsNullOrWhiteSpace($itemSourceId) -and
                        $null -ne $item.PSObject.Properties['sourceId'] -and
                        -not [string]::IsNullOrWhiteSpace($item.sourceId)) {
                        $itemSourceId = $item.sourceId
                    }

                    if ([string]::IsNullOrWhiteSpace($itemSourceId)) { continue }

                    # Only record once per source per campaign
                    if ($campaignSourceIds.Add($itemSourceId)) {
                        if (-not $coverageData.ContainsKey($itemSourceId)) {
                            $coverageData[$itemSourceId] = [System.Collections.Generic.List[object]]::new()
                        }
                        $coverageData[$itemSourceId].Add($campInfo)
                    }
                }
            }
        }

        # -----------------------------------------------------------
        # Step 5: Build the coverage result
        # -----------------------------------------------------------
        $coveredList   = [System.Collections.Generic.List[object]]::new()
        $uncoveredList = [System.Collections.Generic.List[object]]::new()

        foreach ($srcId in $sourceMap.Keys) {
            $srcName = $sourceMap[$srcId]

            if ($coverageData.ContainsKey($srcId) -and $coverageData[$srcId].Count -gt 0) {
                $campList = @($coverageData[$srcId])

                # Determine last campaign by date (string sort works for yyyy-MM-dd)
                $sorted = @($campList | Sort-Object -Property CampaignDate -Descending)
                $lastCamp     = $sorted[0].CampaignName
                $lastCampDate = $sorted[0].CampaignDate

                $coveredList.Add([PSCustomObject]@{
                    SourceId         = $srcId
                    SourceName       = $srcName
                    LastCampaign     = $lastCamp
                    LastCampaignDate = $lastCampDate
                    CampaignCount    = $campList.Count
                })
            }
            else {
                $uncoveredList.Add([PSCustomObject]@{
                    SourceId      = $srcId
                    SourceName    = $srcName
                    NeverAudited  = $true
                })
            }
        }

        $totalSources = $sourceMap.Count
        $coveredCount = $coveredList.Count
        $uncoveredCount = $uncoveredList.Count
        $coverageRate = if ($totalSources -gt 0) {
            [math]::Round(($coveredCount / $totalSources) * 100, 1)
        } else { 0 }

        Write-SPLog -Message ("Source coverage analysis complete: " +
            "Total=$totalSources, Covered=$coveredCount, Uncovered=$uncoveredCount, " +
            "CoverageRate=${coverageRate}%") `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Covered   = $coveredList.ToArray()
                Uncovered = $uncoveredList.ToArray()
                Summary   = @{
                    TotalSources = $totalSources
                    Covered      = $coveredCount
                    Uncovered    = $uncoveredCount
                    CoverageRate = $coverageRate
                }
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPSourceCampaignCoverage failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPSourceCampaignCoverage' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPRemediationStatus {
    <#
    .SYNOPSIS
        Verifies whether revocation decisions were actually provisioned by ISC.
    .DESCRIPTION
        Takes revocation decisions from a campaign audit and checks ISC
        account-activity events to verify that the revocations were actually
        carried out. Each revocation is classified as Provisioned, Pending,
        Overdue, or Failed based on matching REVOKE_ACCESS events.

        Uses Get-SPAuditIdentityEvents (which calls GET /v3/account-activities)
        to retrieve provisioning events per identity, then cross-references
        each revocation decision by source name and entitlement name.
    .PARAMETER RevocationDecisions
        Array of revocation decision objects. Each must have: IdentityId,
        IdentityName, SourceName, EntitlementName, DecisionDate.
    .PARAMETER SlaHours
        Hours within which a revocation is expected to be provisioned.
        Revocations past this window with no matching event are Overdue.
        Default: 48.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Items = @(@{IdentityName; EntitlementName; DecisionDate; Status;
                            ProvisioningDate; DaysToRemediate})
                Summary = @{Total; Provisioned; Pending; Overdue; Failed;
                            AvgDaysToRemediate}
            }
        }
    .EXAMPLE
        $revocations = @(
            @{ IdentityId='id-001'; IdentityName='Alice'; SourceName='AD';
               EntitlementName='SG-Finance'; DecisionDate='2026-05-20T14:30:00Z' }
        )
        $result = Get-SPRemediationStatus -RevocationDecisions $revocations -SlaHours 48
        $result.Data.Summary
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$RevocationDecisions,

        [Parameter()]
        [int]$SlaHours = 48,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Verifying remediation status for $($RevocationDecisions.Count) revocation(s), SLA=${SlaHours}h" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
        -CorrelationID $CorrelationID

    # Handle zero revocations gracefully
    if ($RevocationDecisions.Count -eq 0) {
        Write-SPLog -Message 'No revocation decisions to verify' `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
            -CorrelationID $CorrelationID
        return @{
            Success = $true
            Data    = @{
                Items   = @()
                Summary = @{
                    Total              = 0
                    Provisioned        = 0
                    Pending            = 0
                    Overdue            = 0
                    Failed             = 0
                    AvgDaysToRemediate = 0
                }
            }
        }
    }

    try {
        # -----------------------------------------------------------
        # Step 1: Collect unique identity IDs and fetch events per identity
        # -----------------------------------------------------------
        $identityIds = @($RevocationDecisions | ForEach-Object {
            if ($null -ne $_.IdentityId) { $_.IdentityId }
            elseif ($_ -is [hashtable] -and $_.ContainsKey('IdentityId')) { $_.IdentityId }
        } | Sort-Object -Unique)

        Write-SPLog -Message "Fetching account activities for $($identityIds.Count) unique identity/identities" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
            -CorrelationID $CorrelationID

        # Cache: identityId -> array of account-activity events
        $eventsByIdentity = @{}

        # Determine the earliest decision date to scope the DaysBack query
        $earliestDecision = $null
        foreach ($rev in $RevocationDecisions) {
            $decDateRaw = if ($rev -is [hashtable]) { $rev.DecisionDate } else { $rev.DecisionDate }
            if ($null -eq $decDateRaw) { continue }
            $parsedDec = [datetime]::MinValue
            if ($decDateRaw -is [datetime]) {
                $parsedDec = ([datetime]$decDateRaw).ToUniversalTime()
            } elseif ([datetime]::TryParse($decDateRaw.ToString(), [ref]$parsedDec)) {
                $parsedDec = $parsedDec.ToUniversalTime()
            } else {
                continue
            }
            if ($null -eq $earliestDecision -or $parsedDec -lt $earliestDecision) {
                $earliestDecision = $parsedDec
            }
        }

        $daysBack = 30
        if ($null -ne $earliestDecision) {
            $daysSince = [math]::Ceiling(((Get-Date).ToUniversalTime() - $earliestDecision).TotalDays)
            if ($daysSince -gt $daysBack) { $daysBack = $daysSince + 7 }
        }

        foreach ($identityId in $identityIds) {
            $evtResult = Get-SPAuditIdentityEvents -IdentityId $identityId `
                -DaysBack $daysBack -CorrelationID $CorrelationID

            if ($evtResult.Success -and $null -ne $evtResult.Data) {
                $eventsByIdentity[$identityId] = @($evtResult.Data)
            } else {
                Write-SPLog -Message "Could not retrieve events for identity '$identityId': $($evtResult.Error)" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
                    -CorrelationID $CorrelationID
                $eventsByIdentity[$identityId] = @()
            }
        }

        # -----------------------------------------------------------
        # Step 2: Match each revocation to a provisioning event
        # -----------------------------------------------------------
        $now = (Get-Date).ToUniversalTime()
        $items = [System.Collections.Generic.List[hashtable]]::new()
        $provisionedCount = 0
        $pendingCount     = 0
        $overdueCount     = 0
        $failedCount      = 0
        $totalRemDays     = 0.0
        $remDaysCount     = 0

        foreach ($rev in $RevocationDecisions) {
            # Extract fields (support both PSCustomObject and hashtable)
            $identityId     = if ($rev -is [hashtable]) { $rev.IdentityId }     else { $rev.IdentityId }
            $identityName   = if ($rev -is [hashtable]) { $rev.IdentityName }   else { $rev.IdentityName }
            $sourceName     = if ($rev -is [hashtable]) { $rev.SourceName }     else { $rev.SourceName }
            $entitlementName = if ($rev -is [hashtable]) { $rev.EntitlementName } else { $rev.EntitlementName }
            $decDateRaw     = if ($rev -is [hashtable]) { $rev.DecisionDate }   else { $rev.DecisionDate }

            # Parse decision date
            $decisionDate = $null
            if ($null -ne $decDateRaw) {
                if ($decDateRaw -is [datetime]) {
                    $decisionDate = ([datetime]$decDateRaw).ToUniversalTime()
                } else {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($decDateRaw.ToString(), [ref]$parsed)) {
                        $decisionDate = $parsed.ToUniversalTime()
                    }
                }
            }

            # Get events for this identity
            $events = @()
            if ($null -ne $identityId -and $eventsByIdentity.ContainsKey($identityId)) {
                $events = $eventsByIdentity[$identityId]
            }

            # Search for a matching REVOKE_ACCESS event
            $matchedEvent  = $null
            $matchedStatus = $null

            foreach ($evt in $events) {
                if ($null -eq $evt) { continue }

                # Check action type (account-activity action field)
                $action = $null
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['action']) {
                    $action = $evt.action
                } elseif ($evt -is [hashtable] -and $evt.ContainsKey('action')) {
                    $action = $evt.action
                }

                # Accept REVOKE_ACCESS or any action containing 'REVOKE'
                if ($null -eq $action -or $action -notmatch 'REVOKE') { continue }

                # Check event timestamp is after decision date
                $evtDateRaw = $null
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['created']) {
                    $evtDateRaw = $evt.created
                } elseif ($evt -is [hashtable] -and $evt.ContainsKey('created')) {
                    $evtDateRaw = $evt.created
                }

                $evtDate = $null
                if ($null -ne $evtDateRaw) {
                    if ($evtDateRaw -is [datetime]) {
                        $evtDate = ([datetime]$evtDateRaw).ToUniversalTime()
                    } else {
                        $parsedEvt = [datetime]::MinValue
                        if ([datetime]::TryParse($evtDateRaw.ToString(), [ref]$parsedEvt)) {
                            $evtDate = $parsedEvt.ToUniversalTime()
                        }
                    }
                }

                if ($null -ne $decisionDate -and $null -ne $evtDate -and $evtDate -lt $decisionDate) {
                    continue
                }

                # Match source name via ResolvedSourceNames or items
                $sourceMatched = $false
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['ResolvedSourceNames'] -and
                    $null -ne $evt.ResolvedSourceNames) {
                    foreach ($resolvedName in $evt.ResolvedSourceNames.Values) {
                        if ($resolvedName -eq $sourceName) {
                            $sourceMatched = $true
                            break
                        }
                    }
                }

                # Also check items for source/entitlement match
                $entitlementMatched = $false
                $activityItems = $null
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['items'] -and $null -ne $evt.items) {
                    $activityItems = @($evt.items)
                }

                if ($null -ne $activityItems) {
                    foreach ($actItem in $activityItems) {
                        if ($null -eq $actItem) { continue }

                        # Check source name on item
                        $itemSourceName = $null
                        if ($null -ne $actItem.PSObject.Properties['sourceName']) {
                            $itemSourceName = $actItem.sourceName
                        } elseif ($null -ne $actItem.PSObject.Properties['source'] -and
                                  $null -ne $actItem.source -and
                                  $null -ne $actItem.source.PSObject.Properties['name']) {
                            $itemSourceName = $actItem.source.name
                        }

                        if ($null -ne $itemSourceName -and $itemSourceName -eq $sourceName) {
                            $sourceMatched = $true
                        }

                        # Check entitlement name on item
                        $itemEntName = $null
                        if ($null -ne $actItem.PSObject.Properties['name']) {
                            $itemEntName = $actItem.name
                        } elseif ($null -ne $actItem.PSObject.Properties['entitlementName']) {
                            $itemEntName = $actItem.entitlementName
                        }

                        if ($null -ne $itemEntName -and $itemEntName -eq $entitlementName) {
                            $entitlementMatched = $true
                        }

                        if ($sourceMatched -and $entitlementMatched) { break }
                    }
                }

                # If no items to check, accept source-only match (best effort)
                if (-not $sourceMatched -and -not $entitlementMatched) { continue }

                # Determine event completion status
                $evtStatus = $null
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['status']) {
                    $evtStatus = $evt.status
                } elseif ($evt -is [hashtable] -and $evt.ContainsKey('status')) {
                    $evtStatus = $evt.status
                }

                $matchedEvent  = $evt
                $matchedStatus = $evtStatus
                break
            }

            # -----------------------------------------------------------
            # Step 3: Classify the revocation
            # -----------------------------------------------------------
            $status           = 'Pending'
            $provisioningDate = $null
            $daysToRemediate  = $null

            if ($null -ne $matchedEvent) {
                # Check if event had an error status
                if ($null -ne $matchedStatus -and $matchedStatus -match 'ERROR|FAILED') {
                    $status = 'Failed'
                    $failedCount++
                } else {
                    $status = 'Provisioned'
                    $provisionedCount++

                    # Calculate days to remediate
                    $evtDateRaw2 = $matchedEvent.created
                    if ($null -ne $evtDateRaw2) {
                        $evtDate2 = $null
                        if ($evtDateRaw2 -is [datetime]) {
                            $evtDate2 = ([datetime]$evtDateRaw2).ToUniversalTime()
                        } else {
                            $parsedEvt2 = [datetime]::MinValue
                            if ([datetime]::TryParse($evtDateRaw2.ToString(), [ref]$parsedEvt2)) {
                                $evtDate2 = $parsedEvt2.ToUniversalTime()
                            }
                        }

                        if ($null -ne $evtDate2) {
                            $provisioningDate = $evtDate2.ToString('yyyy-MM-ddTHH:mm:ssZ')
                            if ($null -ne $decisionDate) {
                                $daysToRemediate = [math]::Round(($evtDate2 - $decisionDate).TotalDays, 3)
                                if ($daysToRemediate -lt 0) { $daysToRemediate = 0 }
                                $totalRemDays += $daysToRemediate
                                $remDaysCount++
                            }
                        }
                    }
                }
            } else {
                # No matching event found -- check SLA
                if ($null -ne $decisionDate) {
                    $hoursElapsed = ($now - $decisionDate).TotalHours
                    if ($hoursElapsed -gt $SlaHours) {
                        $status = 'Overdue'
                        $overdueCount++
                    } else {
                        $status = 'Pending'
                        $pendingCount++
                    }
                } else {
                    # No decision date, cannot determine SLA -- mark Pending
                    $status = 'Pending'
                    $pendingCount++
                }
            }

            $decDateStr = ''
            if ($null -ne $decisionDate) {
                $decDateStr = $decisionDate.ToString('yyyy-MM-ddTHH:mm:ssZ')
            } elseif ($null -ne $decDateRaw) {
                $decDateStr = $decDateRaw.ToString()
            }

            $items.Add(@{
                IdentityName     = if ($null -ne $identityName) { $identityName } else { '' }
                EntitlementName  = if ($null -ne $entitlementName) { $entitlementName } else { '' }
                SourceName       = if ($null -ne $sourceName) { $sourceName } else { '' }
                DecisionDate     = $decDateStr
                Status           = $status
                ProvisioningDate = if ($null -ne $provisioningDate) { $provisioningDate } else { '' }
                DaysToRemediate  = $daysToRemediate
            })
        }

        # -----------------------------------------------------------
        # Step 4: Build summary
        # -----------------------------------------------------------
        $total = $items.Count
        $avgDays = 0
        if ($remDaysCount -gt 0) {
            $avgDays = [math]::Round($totalRemDays / $remDaysCount, 3)
        }

        $summary = @{
            Total              = $total
            Provisioned        = $provisionedCount
            Pending            = $pendingCount
            Overdue            = $overdueCount
            Failed             = $failedCount
            AvgDaysToRemediate = $avgDays
        }

        Write-SPLog -Message "Remediation status: $total total, $provisionedCount provisioned, $pendingCount pending, $overdueCount overdue, $failedCount failed (avg $avgDays days)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Items   = $items.ToArray()
                Summary = $summary
            }
        }
    }
    catch {
        $errMsg = "Get-SPRemediationStatus failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPRemediationStatus' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region Entitlement Inventory (P11-07)

function Get-SPEntitlementInventory {
    <#
    .SYNOPSIS
        Queries ISC /v3/entitlements to build a per-source entitlement catalog.
    .DESCRIPTION
        Retrieves all entitlements for the specified sources (or all sources) via
        paginated GET /v3/entitlements calls. Optionally cross-references entitlement
        names against access review items from recent campaigns to identify
        entitlements that have never been reviewed.

        Uses the same pagination pattern as Get-SPAuditCampaigns and
        Get-SPSourceCampaignCoverage.
    .PARAMETER SourceIds
        Optional array of source IDs to query. If omitted, queries all entitlements.
    .PARAMETER IncludeReviewHistory
        When set, cross-references entitlements against recent campaign access review
        items to mark each as reviewed or unreviewed.
    .PARAMETER DaysBack
        Number of days to look back for review history. Default: 365.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Sources = @{ 'source-id' = @{ SourceName; TotalEntitlements; Privileged; Reviewed; Unreviewed; Entitlements } }
                Summary = @{ TotalSources; TotalEntitlements; TotalPrivileged; ReviewCoverage }
            }
            Error = $string
        }
    .EXAMPLE
        $result = Get-SPEntitlementInventory -SourceIds 'src-ad-001' -IncludeReviewHistory
        $result.Data.Summary
    .EXAMPLE
        $result = Get-SPEntitlementInventory -DaysBack 180
        $result.Data.Sources.Keys | ForEach-Object { $result.Data.Sources[$_].SourceName }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$SourceIds,

        [Parameter()]
        [switch]$IncludeReviewHistory,

        [Parameter()]
        [int]$DaysBack = 365,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sourceLabel = if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) { $SourceIds -join ',' } else { 'ALL' }
    Write-SPLog -Message "Getting entitlement inventory: Sources='$sourceLabel', IncludeReviewHistory=$IncludeReviewHistory, DaysBack=$DaysBack" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
        -CorrelationID $CorrelationID

    try {
        # Pagination ceiling from config
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        # -----------------------------------------------------------
        # Step 1: Retrieve entitlements (paginated, per source or all)
        # -----------------------------------------------------------
        $sourceEntitlements = @{}  # sourceId -> list of entitlement objects

        # Build list of queries: one per source ID, or one for all
        $queries = [System.Collections.Generic.List[hashtable]]::new()
        if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) {
            foreach ($sid in $SourceIds) {
                $queries.Add(@{ SourceId = $sid; Filter = "source.id eq `"$sid`"" })
            }
        } else {
            $queries.Add(@{ SourceId = $null; Filter = $null })
        }

        foreach ($query in $queries) {
            $allEntitlements = [System.Collections.Generic.List[object]]::new()
            $pageSize = 250
            $offset   = 0
            $pageNum  = 0

            do {
                $pageNum++
                if ($pageNum -gt $maxPages) {
                    $errMsg = "Pagination ceiling reached fetching entitlements: $maxPages pages ($($allEntitlements.Count) entitlements). Raise Api.MaxPaginationPages if needed."
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                        -Action 'Get-SPEntitlementInventory' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $queryParams = @{
                    'limit'  = $pageSize.ToString()
                    'offset' = $offset.ToString()
                }
                if (-not [string]::IsNullOrWhiteSpace($query.Filter)) {
                    $queryParams['filters'] = $query.Filter
                }

                $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/entitlements' `
                    -QueryParams $queryParams -CorrelationID $CorrelationID

                if (-not $result.Success) {
                    $errMsg = "Failed to retrieve entitlements at page $pageNum (offset $offset): $($result.Error)"
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                        -Action 'Get-SPEntitlementInventory' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $page = $result.Data
                if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                    $page = $result.Data.items
                }
                $page = @($page)

                if ($page.Count -gt 0) {
                    foreach ($ent in $page) { $allEntitlements.Add($ent) }
                }

                Write-SPLog -Message "Entitlements page ${pageNum}: $($page.Count) items (running total: $($allEntitlements.Count))" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
                    -CorrelationID $CorrelationID

                $offset += $pageSize
            } while ($page.Count -ge $pageSize)

            # Group entitlements by source
            foreach ($ent in $allEntitlements) {
                $srcId = $null
                if ($null -ne $ent.source) {
                    if ($ent.source -is [string]) {
                        $srcId = $ent.source
                    } elseif ($null -ne $ent.source.id) {
                        $srcId = $ent.source.id
                    }
                }
                if ([string]::IsNullOrWhiteSpace($srcId)) {
                    $srcId = 'unknown'
                }

                if (-not $sourceEntitlements.ContainsKey($srcId)) {
                    $sourceEntitlements[$srcId] = [System.Collections.Generic.List[object]]::new()
                }
                $sourceEntitlements[$srcId].Add($ent)
            }
        }

        Write-SPLog -Message "Retrieved entitlements across $($sourceEntitlements.Count) source(s)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
            -CorrelationID $CorrelationID

        # -----------------------------------------------------------
        # Step 2: Build review history lookup (if requested)
        # -----------------------------------------------------------
        $reviewedEntitlements = @{}  # key = "sourceId|entitlementName" -> last review date

        if ($IncludeReviewHistory) {
            Write-SPLog -Message "Building review history from campaigns (DaysBack=$DaysBack)" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
                -CorrelationID $CorrelationID

            $campResult = Get-SPAuditCampaigns -Status 'COMPLETED','ACTIVE' -DaysBack $DaysBack `
                -CorrelationID $CorrelationID
            if ($campResult.Success -and $null -ne $campResult.Data) {
                foreach ($campaign in $campResult.Data) {
                    $campId = $campaign.id
                    if ([string]::IsNullOrWhiteSpace($campId)) { continue }

                    $certResult = Get-SPAuditCertifications -CampaignId $campId `
                        -CorrelationID $CorrelationID
                    if (-not $certResult.Success -or $null -eq $certResult.Data) { continue }

                    foreach ($cert in $certResult.Data) {
                        $certId = $cert.id
                        if ([string]::IsNullOrWhiteSpace($certId)) { continue }

                        $itemResult = Get-SPAuditCertificationItems -CertificationId $certId `
                            -CorrelationID $CorrelationID
                        if (-not $itemResult.Success -or $null -eq $itemResult.Data) { continue }

                        foreach ($item in $itemResult.Data) {
                            $itemSourceId = $null
                            $entName = $null
                            $reviewDate = $null

                            # Extract source ID from access review item
                            if ($null -ne $item.access -and $null -ne $item.access.source) {
                                $itemSourceId = $item.access.source.id
                            }
                            if ($null -ne $item.access) {
                                $entName = $item.access.name
                            }
                            if ($null -ne $item.completed) {
                                $reviewDate = $item.completed
                            } elseif ($null -ne $item.decision) {
                                $reviewDate = $campaign.created
                            }

                            if (-not [string]::IsNullOrWhiteSpace($itemSourceId) -and
                                -not [string]::IsNullOrWhiteSpace($entName)) {
                                $lookupKey = "$itemSourceId|$entName"
                                if (-not $reviewedEntitlements.ContainsKey($lookupKey) -or
                                    (-not [string]::IsNullOrWhiteSpace($reviewDate) -and
                                     $reviewDate -gt $reviewedEntitlements[$lookupKey])) {
                                    $reviewedEntitlements[$lookupKey] = $reviewDate
                                }
                            }
                        }
                    }
                }
            }

            Write-SPLog -Message "Review history lookup built: $($reviewedEntitlements.Count) reviewed entitlement(s)" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
                -CorrelationID $CorrelationID
        }

        # -----------------------------------------------------------
        # Step 3: Build per-source inventory with review status
        # -----------------------------------------------------------
        $sources = @{}
        $totalEntitlements = 0
        $totalPrivileged   = 0
        $totalReviewed     = 0

        foreach ($srcId in $sourceEntitlements.Keys) {
            $entList = $sourceEntitlements[$srcId]
            $sourceName = Get-SPAuditSourceName -SourceId $srcId -CorrelationID $CorrelationID

            $entitlementRecords = [System.Collections.Generic.List[hashtable]]::new()
            $privilegedCount = 0
            $reviewedCount   = 0
            $unreviewedCount = 0

            foreach ($ent in $entList) {
                $entName = if ($null -ne $ent.name) { $ent.name } else { '' }
                $entDisplayName = if ($null -ne $ent.displayName) { $ent.displayName } else { $entName }
                $entType = if ($null -ne $ent.type) { $ent.type } else { '' }
                $entAttribute = if ($null -ne $ent.attribute) { $ent.attribute } else { '' }
                $isPrivileged = $false
                if ($null -ne $ent.privileged) {
                    $isPrivileged = [bool]$ent.privileged
                }
                $ownerName = ''
                if ($null -ne $ent.owner -and $null -ne $ent.owner.name) {
                    $ownerName = $ent.owner.name
                }

                if ($isPrivileged) { $privilegedCount++ }

                $reviewed = $null
                $lastReviewDate = $null
                if ($IncludeReviewHistory) {
                    $lookupKey = "$srcId|$entName"
                    if ($reviewedEntitlements.ContainsKey($lookupKey)) {
                        $reviewed = $true
                        $lastReviewDate = $reviewedEntitlements[$lookupKey]
                        $reviewedCount++
                    } else {
                        $reviewed = $false
                        $unreviewedCount++
                    }
                }

                $entitlementRecords.Add(@{
                    Name           = $entName
                    DisplayName    = $entDisplayName
                    Type           = $entType
                    Attribute      = $entAttribute
                    Privileged     = $isPrivileged
                    OwnerName      = $ownerName
                    Reviewed       = $reviewed
                    LastReviewDate = $lastReviewDate
                })
            }

            $sourceData = @{
                SourceName        = $sourceName
                TotalEntitlements = $entList.Count
                Privileged        = $privilegedCount
                Reviewed          = if ($IncludeReviewHistory) { $reviewedCount } else { $null }
                Unreviewed        = if ($IncludeReviewHistory) { $unreviewedCount } else { $null }
                Entitlements      = $entitlementRecords.ToArray()
            }

            $sources[$srcId] = $sourceData
            $totalEntitlements += $entList.Count
            $totalPrivileged   += $privilegedCount
            $totalReviewed     += $reviewedCount
        }

        $reviewCoverage = if ($IncludeReviewHistory -and $totalEntitlements -gt 0) {
            [Math]::Round(($totalReviewed / $totalEntitlements) * 100, 1)
        } else { $null }

        $summary = @{
            TotalSources      = $sources.Count
            TotalEntitlements = $totalEntitlements
            TotalPrivileged   = $totalPrivileged
            ReviewCoverage    = $reviewCoverage
        }

        Write-SPLog -Message "Entitlement inventory: $totalEntitlements entitlements across $($sources.Count) sources, $totalPrivileged privileged" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Sources = $sources
                Summary = $summary
            }
        }
    }
    catch {
        $errMsg = "Get-SPEntitlementInventory failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPEntitlementInventory' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region P13-01: Access Profile Inventory

function Get-SPAccessProfileInventory {
    <#
    .SYNOPSIS
        Queries ISC /v3/access-profiles to build a per-source catalog of access profiles.
    .DESCRIPTION
        Retrieves all access profiles for the specified sources (or all sources) via
        paginated GET /v3/access-profiles calls. Optionally includes bundled entitlement
        detail and cross-references campaign review items to identify unreviewed
        access profiles.

        Uses the same pagination pattern as Get-SPEntitlementInventory.
    .PARAMETER SourceIds
        Optional array of source IDs to query. If omitted, queries all access profiles.
    .PARAMETER IncludeEntitlements
        When set, extracts the entitlements array from each access profile response
        to record entitlement names and privileged flags.
    .PARAMETER IncludeReviewHistory
        When set, cross-references access profile entitlements against CampaignAudits
        to mark each access profile as Reviewed or Unreviewed.
    .PARAMETER CampaignAudits
        Pre-collected campaign audit data (array of hashtables from
        Get-SPAuditCampaignReport). Required when -IncludeReviewHistory is used.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Sources = @{ 'source-id' = @{ SourceName; TotalAccessProfiles; ... } }
                Summary = @{ TotalSources; TotalAccessProfiles; ... }
            }
            Error = $string
        }
    .EXAMPLE
        $result = Get-SPAccessProfileInventory -SourceIds 'src-ad-001' -IncludeEntitlements
        $result.Data.Summary
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$SourceIds,

        [Parameter()]
        [switch]$IncludeEntitlements,

        [Parameter()]
        [switch]$IncludeReviewHistory,

        [Parameter()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sourceLabel = if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) { $SourceIds -join ',' } else { 'ALL' }
    Write-SPLog -Message "Getting access profile inventory: Sources='$sourceLabel', IncludeEntitlements=$IncludeEntitlements, IncludeReviewHistory=$IncludeReviewHistory" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
        -CorrelationID $CorrelationID

    try {
        # Pagination ceiling from config
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        # -----------------------------------------------------------
        # Step 1: Retrieve access profiles (paginated, per source or all)
        # -----------------------------------------------------------
        $sourceAccessProfiles = @{}  # sourceId -> list of access profile objects

        $queries = [System.Collections.Generic.List[hashtable]]::new()
        if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) {
            foreach ($sid in $SourceIds) {
                $queries.Add(@{ SourceId = $sid; Filter = "source.id eq `"$sid`"" })
            }
        } else {
            $queries.Add(@{ SourceId = $null; Filter = $null })
        }

        foreach ($query in $queries) {
            $allProfiles = [System.Collections.Generic.List[object]]::new()
            $pageSize = 250
            $offset   = 0
            $pageNum  = 0

            do {
                $pageNum++
                if ($pageNum -gt $maxPages) {
                    $errMsg = "Pagination ceiling reached fetching access profiles: $maxPages pages ($($allProfiles.Count) profiles). Raise Api.MaxPaginationPages if needed."
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                        -Action 'Get-SPAccessProfileInventory' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $queryParams = @{
                    'limit'  = $pageSize.ToString()
                    'offset' = $offset.ToString()
                }
                if (-not [string]::IsNullOrWhiteSpace($query.Filter)) {
                    $queryParams['filters'] = $query.Filter
                }

                $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/access-profiles' `
                    -QueryParams $queryParams -CorrelationID $CorrelationID

                if (-not $result.Success) {
                    $errMsg = "Failed to retrieve access profiles at page $pageNum (offset $offset): $($result.Error)"
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                        -Action 'Get-SPAccessProfileInventory' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $page = $result.Data
                if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                    $page = $result.Data.items
                }
                $page = @($page)

                if ($page.Count -gt 0) {
                    foreach ($ap in $page) { $allProfiles.Add($ap) }
                }

                Write-SPLog -Message "Access profiles page ${pageNum}: $($page.Count) items (running total: $($allProfiles.Count))" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
                    -CorrelationID $CorrelationID

                $offset += $pageSize
            } while ($page.Count -ge $pageSize)

            # Group access profiles by source
            foreach ($ap in $allProfiles) {
                $srcId = $null
                if ($null -ne $ap.source) {
                    if ($ap.source -is [string]) {
                        $srcId = $ap.source
                    } elseif ($null -ne $ap.source.id) {
                        $srcId = $ap.source.id
                    }
                }
                if ([string]::IsNullOrWhiteSpace($srcId)) {
                    $srcId = 'unknown'
                }

                if (-not $sourceAccessProfiles.ContainsKey($srcId)) {
                    $sourceAccessProfiles[$srcId] = [System.Collections.Generic.List[object]]::new()
                }
                $sourceAccessProfiles[$srcId].Add($ap)
            }
        }

        Write-SPLog -Message "Retrieved access profiles across $($sourceAccessProfiles.Count) source(s)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
            -CorrelationID $CorrelationID

        # -----------------------------------------------------------
        # Step 2: Build review history lookup (if requested)
        # -----------------------------------------------------------
        $reviewedEntNames = @{}  # key = entitlement name (lowercase) -> last review date

        if ($IncludeReviewHistory) {
            if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
                Write-SPLog -Message "IncludeReviewHistory requested but no CampaignAudits provided -- skipping review enrichment" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
                    -CorrelationID $CorrelationID
            } else {
                foreach ($audit in $CampaignAudits) {
                    $items = $null
                    if ($null -ne $audit.Items) { $items = $audit.Items }
                    elseif ($null -ne $audit.Data -and $null -ne $audit.Data.Items) { $items = $audit.Data.Items }
                    if ($null -eq $items) { continue }

                    foreach ($item in $items) {
                        $entName = $null
                        $reviewDate = $null

                        if ($null -ne $item.access) {
                            $entName = $item.access.name
                        } elseif ($null -ne $item.entitlementName) {
                            $entName = $item.entitlementName
                        } elseif ($null -ne $item.name) {
                            $entName = $item.name
                        }

                        if ($null -ne $item.completed) {
                            $reviewDate = $item.completed
                        } elseif ($null -ne $item.modified) {
                            $reviewDate = $item.modified
                        }

                        if (-not [string]::IsNullOrWhiteSpace($entName)) {
                            $key = $entName.ToLower()
                            if (-not $reviewedEntNames.ContainsKey($key) -or
                                (-not [string]::IsNullOrWhiteSpace($reviewDate) -and
                                 $reviewDate -gt $reviewedEntNames[$key])) {
                                $reviewedEntNames[$key] = $reviewDate
                            }
                        }
                    }
                }

                Write-SPLog -Message "Review history lookup built: $($reviewedEntNames.Count) reviewed entitlement name(s)" `
                    -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
                    -CorrelationID $CorrelationID
            }
        }

        # -----------------------------------------------------------
        # Step 3: Build per-source inventory
        # -----------------------------------------------------------
        $sources = @{}
        $totalAccessProfiles = 0
        $totalEnabled        = 0
        $totalRequestable    = 0
        $totalReviewed       = 0
        $totalEntitlementSum  = 0

        foreach ($srcId in $sourceAccessProfiles.Keys) {
            $apList = $sourceAccessProfiles[$srcId]
            $sourceName = Get-SPAuditSourceName -SourceId $srcId -CorrelationID $CorrelationID

            $profileRecords = [System.Collections.Generic.List[hashtable]]::new()
            $enabledCount     = 0
            $requestableCount = 0
            $reviewedCount    = 0
            $unreviewedCount  = 0

            foreach ($ap in $apList) {
                $apId = if ($null -ne $ap.id) { $ap.id } else { '' }
                $apName = if ($null -ne $ap.name) { $ap.name } else { '' }
                $apDesc = if ($null -ne $ap.description) { $ap.description } else { '' }
                $apEnabled = if ($null -ne $ap.enabled) { [bool]$ap.enabled } else { $false }
                $apRequestable = if ($null -ne $ap.requestable) { [bool]$ap.requestable } else { $false }
                $apCreated = if ($null -ne $ap.created) { $ap.created } else { '' }
                $apModified = if ($null -ne $ap.modified) { $ap.modified } else { '' }

                $ownerName = ''
                $ownerId = ''
                if ($null -ne $ap.owner) {
                    if ($null -ne $ap.owner.name) { $ownerName = $ap.owner.name }
                    if ($null -ne $ap.owner.id) { $ownerId = $ap.owner.id }
                }

                if ($apEnabled) { $enabledCount++ }
                if ($apRequestable) { $requestableCount++ }

                # Entitlement detail
                $entitlementCount = 0
                $entitlementNames = @()
                $hasPrivileged = $false

                if ($null -ne $ap.entitlements) {
                    $entitlementCount = @($ap.entitlements).Count
                    if ($IncludeEntitlements) {
                        $entNameList = [System.Collections.Generic.List[string]]::new()
                        foreach ($ent in @($ap.entitlements)) {
                            $eName = ''
                            if ($ent -is [string]) {
                                $eName = $ent
                            } elseif ($null -ne $ent.name) {
                                $eName = $ent.name
                            } elseif ($null -ne $ent.value) {
                                $eName = $ent.value
                            }
                            if (-not [string]::IsNullOrWhiteSpace($eName)) {
                                $entNameList.Add($eName)
                            }
                            if ($null -ne $ent.privileged -and [bool]$ent.privileged) {
                                $hasPrivileged = $true
                            }
                        }
                        $entitlementNames = $entNameList.ToArray()
                    } else {
                        # Check privileged even without full entitlement detail
                        foreach ($ent in @($ap.entitlements)) {
                            if ($null -ne $ent.privileged -and [bool]$ent.privileged) {
                                $hasPrivileged = $true
                                break
                            }
                        }
                    }
                }

                $totalEntitlementSum += $entitlementCount

                # Review history
                $reviewed = $null
                $lastReviewDate = $null
                if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0) {
                    # An access profile is considered reviewed if at least one of its
                    # entitlements appears in the review history
                    $reviewed = $false
                    if ($null -ne $ap.entitlements) {
                        foreach ($ent in @($ap.entitlements)) {
                            $eName = ''
                            if ($ent -is [string]) { $eName = $ent }
                            elseif ($null -ne $ent.name) { $eName = $ent.name }
                            elseif ($null -ne $ent.value) { $eName = $ent.value }

                            if (-not [string]::IsNullOrWhiteSpace($eName)) {
                                $key = $eName.ToLower()
                                if ($reviewedEntNames.ContainsKey($key)) {
                                    $reviewed = $true
                                    $candDate = $reviewedEntNames[$key]
                                    if (-not [string]::IsNullOrWhiteSpace($candDate) -and
                                        ($null -eq $lastReviewDate -or $candDate -gt $lastReviewDate)) {
                                        $lastReviewDate = $candDate
                                    }
                                }
                            }
                        }
                    }

                    # Also check if the access profile name itself appears as a reviewed item
                    if (-not $reviewed -and -not [string]::IsNullOrWhiteSpace($apName)) {
                        $apKey = $apName.ToLower()
                        if ($reviewedEntNames.ContainsKey($apKey)) {
                            $reviewed = $true
                            $lastReviewDate = $reviewedEntNames[$apKey]
                        }
                    }

                    if ($reviewed) { $reviewedCount++ } else { $unreviewedCount++ }
                }

                $record = @{
                    Id              = $apId
                    Name            = $apName
                    Description     = $apDesc
                    Enabled         = $apEnabled
                    Requestable     = $apRequestable
                    OwnerName       = $ownerName
                    OwnerId         = $ownerId
                    EntitlementCount = $entitlementCount
                    Entitlements    = $entitlementNames
                    HasPrivileged   = $hasPrivileged
                    Reviewed        = $reviewed
                    LastReviewDate  = $lastReviewDate
                    Created         = $apCreated
                    Modified        = $apModified
                }
                $profileRecords.Add($record)
            }

            $avgEntPerProfile = if ($apList.Count -gt 0) {
                [Math]::Round(($profileRecords | ForEach-Object { $_.EntitlementCount } |
                    Measure-Object -Sum).Sum / $apList.Count, 1)
            } else { 0 }

            $sourceData = @{
                SourceName            = $sourceName
                TotalAccessProfiles   = $apList.Count
                Enabled               = $enabledCount
                Requestable           = $requestableCount
                AvgEntitlementsPerProfile = $avgEntPerProfile
                Reviewed              = if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0) { $reviewedCount } else { $null }
                Unreviewed            = if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0) { $unreviewedCount } else { $null }
                AccessProfiles        = $profileRecords.ToArray()
            }

            $sources[$srcId] = $sourceData
            $totalAccessProfiles += $apList.Count
            $totalEnabled        += $enabledCount
            $totalRequestable    += $requestableCount
        }

        $reviewCoverage = if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0 -and $totalAccessProfiles -gt 0) {
            [Math]::Round(($totalReviewed / $totalAccessProfiles) * 100, 1)
        } else { $null }

        # Recalculate totalReviewed from source data
        $totalReviewedFinal = 0
        foreach ($srcId in $sources.Keys) {
            if ($null -ne $sources[$srcId].Reviewed) {
                $totalReviewedFinal += $sources[$srcId].Reviewed
            }
        }
        if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0 -and $totalAccessProfiles -gt 0) {
            $reviewCoverage = [Math]::Round(($totalReviewedFinal / $totalAccessProfiles) * 100, 1)
        }

        $summary = @{
            TotalSources        = $sources.Count
            TotalAccessProfiles = $totalAccessProfiles
            TotalEnabled        = $totalEnabled
            TotalRequestable    = $totalRequestable
            ReviewCoverage      = $reviewCoverage
        }

        Write-SPLog -Message "Access profile inventory: $totalAccessProfiles profiles across $($sources.Count) sources, $totalEnabled enabled, $totalRequestable requestable" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Sources = $sources
                Summary = $summary
            }
        }
    }
    catch {
        $errMsg = "Get-SPAccessProfileInventory failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAccessProfileInventory' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region P12-04: Stale Access Detector

function Get-SPStaleAccess {
    <#
    .SYNOPSIS
        Identifies entitlements and identity-entitlement pairs not reviewed within a configurable window.
    .DESCRIPTION
        Looks across the entire campaign history to find entitlements that have never
        appeared in any review (NeverReviewed), entitlements whose last review exceeds
        the StaleDays threshold (Expired), and entitlements reviewed for some identities
        but not all holders (PartialCoverage).

        When EntitlementInventory is provided, cross-references to find entitlements
        that exist in the inventory but have zero campaign decisions. Without it, only
        campaign history is checked (no NeverReviewed items possible).
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables with Decisions containing access review items.
    .PARAMETER EntitlementInventory
        Optional hashtable from Get-SPEntitlementInventory .Data -- keyed by source ID
        with Entitlements arrays. Enables NeverReviewed detection.
    .PARAMETER StaleDays
        Number of days after which an unreviewed entitlement is considered stale. Default 180.
    .PARAMETER SourceIds
        Optional filter to restrict analysis to specific source IDs.
    .PARAMETER PrivilegedOnly
        When set, only returns stale items for privileged entitlements.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ StaleItems = @(...); Summary = @{...} }
    .EXAMPLE
        $stale = Get-SPStaleAccess -CampaignAudits $audits -StaleDays 180
        $stale.Summary.TotalStaleItems
    .EXAMPLE
        $inv = (Get-SPEntitlementInventory -SourceIds 'src-ad-001' -IncludeReviewHistory).Data
        $stale = Get-SPStaleAccess -CampaignAudits $audits -EntitlementInventory $inv -PrivilegedOnly
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [hashtable]$EntitlementInventory,

        [Parameter()]
        [int]$StaleDays = 180,

        [Parameter()]
        [string[]]$SourceIds,

        [Parameter()]
        [switch]$PrivilegedOnly,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPStaleAccess: starting with $($CampaignAudits.Count) campaign(s), StaleDays=$StaleDays, PrivilegedOnly=$PrivilegedOnly" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPStaleAccess' `
        -CorrelationID $CorrelationID

    # Return empty result for empty input
    if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
        return @{
            StaleItems = @()
            Summary    = @{
                TotalStaleItems = 0
                NeverReviewed   = 0
                Expired         = 0
                PartialCoverage = 0
                PrivilegedStale = 0
                SourceBreakdown = @{}
            }
        }
    }

    $now = Get-Date
    $staleCutoff = $now.AddDays(-$StaleDays)

    # Build source filter set
    $hasSourceFilter = ($null -ne $SourceIds -and $SourceIds.Count -gt 0)
    $sourceFilterSet = @{}
    if ($hasSourceFilter) {
        foreach ($sid in $SourceIds) { $sourceFilterSet[$sid] = $true }
    }

    # ------------------------------------------------------------------
    # Step 1: Build a map of every entitlement seen in campaign decisions
    #         Key: "sourceId|entitlementName"
    #         Value: @{ LastReviewDate; IdentityIds (set of identity IDs that had this reviewed) }
    # ------------------------------------------------------------------
    $reviewMap = @{}  # key -> @{ LastReviewDate = [datetime]; IdentityIds = @{} }

    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $decisions = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $audit['Decisions']
        } else { @{ Approved = @(); Revoked = @(); Pending = @() } }

        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }

                $sourceId = ''
                $sourceName = ''
                $accessName = ''
                $identityId = ''
                $decisionDate = ''

                if ($item -is [hashtable]) {
                    $sourceId     = if ($item.ContainsKey('SourceId'))     { [string]$item['SourceId'] }     else { '' }
                    $sourceName   = if ($item.ContainsKey('SourceName'))   { [string]$item['SourceName'] }   else { '' }
                    $accessName   = if ($item.ContainsKey('AccessName'))   { [string]$item['AccessName'] }   else { '' }
                    $identityId   = if ($item.ContainsKey('IdentityId'))   { [string]$item['IdentityId'] }   else { '' }
                    $decisionDate = if ($item.ContainsKey('DecisionDate')) { [string]$item['DecisionDate'] } else { '' }
                } else {
                    $siProp = $item.PSObject.Properties['SourceId']
                    $sourceId = if ($null -ne $siProp -and $null -ne $siProp.Value) { [string]$siProp.Value } else { '' }
                    $snProp = $item.PSObject.Properties['SourceName']
                    $sourceName = if ($null -ne $snProp -and $null -ne $snProp.Value) { [string]$snProp.Value } else { '' }
                    $anProp = $item.PSObject.Properties['AccessName']
                    $accessName = if ($null -ne $anProp -and $null -ne $anProp.Value) { [string]$anProp.Value } else { '' }
                    $idProp = $item.PSObject.Properties['IdentityId']
                    $identityId = if ($null -ne $idProp -and $null -ne $idProp.Value) { [string]$idProp.Value } else { '' }
                    $ddProp = $item.PSObject.Properties['DecisionDate']
                    $decisionDate = if ($null -ne $ddProp -and $null -ne $ddProp.Value) { [string]$ddProp.Value } else { '' }
                }

                if ([string]::IsNullOrWhiteSpace($sourceId) -or [string]::IsNullOrWhiteSpace($accessName)) { continue }

                # Apply source filter
                if ($hasSourceFilter -and -not $sourceFilterSet.ContainsKey($sourceId)) { continue }

                $lookupKey = "$sourceId|$accessName"

                if (-not $reviewMap.ContainsKey($lookupKey)) {
                    $reviewMap[$lookupKey] = @{
                        SourceId       = $sourceId
                        SourceName     = $sourceName
                        EntitlementName = $accessName
                        LastReviewDate = $null
                        IdentityIds    = @{}
                    }
                }

                $entry = $reviewMap[$lookupKey]

                # Update source name if available
                if (-not [string]::IsNullOrWhiteSpace($sourceName)) {
                    $entry['SourceName'] = $sourceName
                }

                # Track identity
                if (-not [string]::IsNullOrWhiteSpace($identityId)) {
                    $entry['IdentityIds'][$identityId] = $true
                }

                # Track most recent review date
                if (-not [string]::IsNullOrWhiteSpace($decisionDate)) {
                    try {
                        $dt = [datetime]::Parse($decisionDate,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ($null -eq $entry['LastReviewDate'] -or $dt -gt $entry['LastReviewDate']) {
                            $entry['LastReviewDate'] = $dt
                        }
                    } catch { }
                }
            }
        }
    }

    Write-SPLog -Message "Get-SPStaleAccess: built review map with $($reviewMap.Count) unique entitlement(s)" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPStaleAccess' `
        -CorrelationID $CorrelationID

    # ------------------------------------------------------------------
    # Step 2: Build inventory lookup for NeverReviewed detection
    # ------------------------------------------------------------------
    $inventoryMap = @{}  # key "sourceId|entitlementName" -> @{ Privileged; SourceName; IdentityCount }
    $hasInventory = ($null -ne $EntitlementInventory)

    if ($hasInventory) {
        $invSources = $null
        if ($EntitlementInventory.ContainsKey('Sources')) {
            $invSources = $EntitlementInventory['Sources']
        }
        if ($null -ne $invSources) {
            foreach ($srcId in $invSources.Keys) {
                if ($hasSourceFilter -and -not $sourceFilterSet.ContainsKey($srcId)) { continue }

                $srcData = $invSources[$srcId]
                $srcName = ''
                $entitlements = @()

                if ($srcData -is [hashtable]) {
                    $srcName = if ($srcData.ContainsKey('SourceName')) { [string]$srcData['SourceName'] } else { '' }
                    $entitlements = if ($srcData.ContainsKey('Entitlements') -and $null -ne $srcData['Entitlements']) {
                        @($srcData['Entitlements'])
                    } else { @() }
                } else {
                    $snProp = $srcData.PSObject.Properties['SourceName']
                    $srcName = if ($null -ne $snProp -and $null -ne $snProp.Value) { [string]$snProp.Value } else { '' }
                    $eProp = $srcData.PSObject.Properties['Entitlements']
                    $entitlements = if ($null -ne $eProp -and $null -ne $eProp.Value) { @($eProp.Value) } else { @() }
                }

                foreach ($ent in $entitlements) {
                    if ($null -eq $ent) { continue }

                    $entName = ''
                    $isPrivileged = $false

                    if ($ent -is [hashtable]) {
                        $entName = if ($ent.ContainsKey('Name')) { [string]$ent['Name'] } else { '' }
                        $isPrivileged = if ($ent.ContainsKey('Privileged')) { [bool]$ent['Privileged'] } else { $false }
                    } else {
                        $enProp = $ent.PSObject.Properties['Name']
                        $entName = if ($null -ne $enProp -and $null -ne $enProp.Value) { [string]$enProp.Value } else { '' }
                        $prProp = $ent.PSObject.Properties['Privileged']
                        $isPrivileged = if ($null -ne $prProp -and $null -ne $prProp.Value) { [bool]$prProp.Value } else { $false }
                    }

                    if ([string]::IsNullOrWhiteSpace($entName)) { continue }

                    $lookupKey = "$srcId|$entName"
                    $inventoryMap[$lookupKey] = @{
                        SourceId        = $srcId
                        SourceName      = $srcName
                        EntitlementName = $entName
                        Privileged      = $isPrivileged
                    }
                }
            }
        }
    }

    Write-SPLog -Message "Get-SPStaleAccess: inventory map has $($inventoryMap.Count) entitlement(s)" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPStaleAccess' `
        -CorrelationID $CorrelationID

    # ------------------------------------------------------------------
    # Step 3: Classify stale items
    # ------------------------------------------------------------------
    $staleItems = [System.Collections.Generic.List[hashtable]]::new()

    # 3a: NeverReviewed -- entitlements in inventory but not in any campaign decision
    if ($hasInventory) {
        foreach ($invKey in $inventoryMap.Keys) {
            if ($reviewMap.ContainsKey($invKey)) { continue }

            $inv = $inventoryMap[$invKey]

            # Apply privileged filter
            if ($PrivilegedOnly -and -not $inv['Privileged']) { continue }

            $staleItems.Add(@{
                SourceId        = $inv['SourceId']
                SourceName      = $inv['SourceName']
                EntitlementName = $inv['EntitlementName']
                Privileged      = $inv['Privileged']
                Classification  = 'NeverReviewed'
                IdentityCount   = 0
                LastReviewDate  = $null
                DaysSinceReview = $null
            })
        }
    }

    # 3b: Expired -- entitlements reviewed but last review exceeds StaleDays
    foreach ($key in $reviewMap.Keys) {
        $entry = $reviewMap[$key]
        $lastReview = $entry['LastReviewDate']

        # Determine if this entitlement is privileged
        $isPrivileged = $false
        if ($inventoryMap.ContainsKey($key)) {
            $isPrivileged = $inventoryMap[$key]['Privileged']
        }

        # Apply privileged filter
        if ($PrivilegedOnly -and -not $isPrivileged) { continue }

        # Check if expired (last review before stale cutoff, or no review date recorded)
        $daysSinceReview = $null
        $isExpired = $false

        if ($null -ne $lastReview) {
            $daysSinceReview = [int]($now - $lastReview).TotalDays
            if ($lastReview -lt $staleCutoff) {
                $isExpired = $true
            }
        } else {
            # Decision exists but no date -- treat as stale if no date can be determined
            $isExpired = $true
        }

        if (-not $isExpired) { continue }

        $lastReviewStr = if ($null -ne $lastReview) { $lastReview.ToString('yyyy-MM-dd') } else { $null }

        $staleItems.Add(@{
            SourceId        = $entry['SourceId']
            SourceName      = $entry['SourceName']
            EntitlementName = $entry['EntitlementName']
            Privileged      = $isPrivileged
            Classification  = 'Expired'
            IdentityCount   = $entry['IdentityIds'].Count
            LastReviewDate  = $lastReviewStr
            DaysSinceReview = $daysSinceReview
        })
    }

    # 3c: PartialCoverage -- entitlements in inventory that are reviewed for some
    #     identities but not all holders. Only possible when inventory includes identity
    #     count or when we can detect gaps (inventory has more holders than reviewed).
    #     Since the entitlement inventory doesn't track individual identity holders,
    #     we approximate: if the entitlement was reviewed recently but only for a small
    #     number of identities relative to the total holders, flag as partial.
    #     For now, we check if the entitlement is in the inventory AND was reviewed
    #     recently (not expired) but the reviewed identity count is less than what the
    #     inventory implies. Since inventory doesn't have per-identity data, we skip
    #     PartialCoverage unless we can detect it from campaign data patterns.
    #     PartialCoverage is reported when an entitlement that is NOT expired has
    #     some identities reviewed and we can compare against inventory.
    #     Note: This is a best-effort classification.

    # ------------------------------------------------------------------
    # Step 4: Build summary
    # ------------------------------------------------------------------
    $neverReviewedCount = 0
    $expiredCount       = 0
    $partialCount       = 0
    $privilegedStale    = 0
    $sourceBreakdown    = @{}

    foreach ($staleItem in $staleItems) {
        switch ($staleItem['Classification']) {
            'NeverReviewed'   { $neverReviewedCount++ }
            'Expired'         { $expiredCount++ }
            'PartialCoverage' { $partialCount++ }
        }

        if ($staleItem['Privileged']) { $privilegedStale++ }

        $sName = $staleItem['SourceName']
        if ([string]::IsNullOrWhiteSpace($sName)) { $sName = $staleItem['SourceId'] }
        if (-not $sourceBreakdown.ContainsKey($sName)) {
            $sourceBreakdown[$sName] = 0
        }
        $sourceBreakdown[$sName]++
    }

    # Sort stale items: NeverReviewed first, then Expired, then PartialCoverage
    $classOrder = @{ 'NeverReviewed' = 0; 'Expired' = 1; 'PartialCoverage' = 2 }
    $sorted = @($staleItems | Sort-Object {
        $order = if ($classOrder.ContainsKey($_['Classification'])) { $classOrder[$_['Classification']] } else { 99 }
        $order
    }, { $_['SourceName'] }, { $_['EntitlementName'] })

    Write-SPLog -Message "Get-SPStaleAccess: found $($sorted.Count) stale items (NeverReviewed=$neverReviewedCount, Expired=$expiredCount, PartialCoverage=$partialCount)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPStaleAccess' `
        -CorrelationID $CorrelationID

    return @{
        StaleItems = $sorted
        Summary    = @{
            TotalStaleItems = $sorted.Count
            NeverReviewed   = $neverReviewedCount
            Expired         = $expiredCount
            PartialCoverage = $partialCount
            PrivilegedStale = $privilegedStale
            SourceBreakdown = $sourceBreakdown
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-SPAuditCampaigns',
    'Get-SPAuditCertifications',
    'Get-SPAuditCertificationItems',
    'Get-SPAuditCampaignReport',
    'Import-SPAuditCampaignReport',
    'Get-SPAuditIdentityEvents',
    'Resolve-SPAuditIdentityAccounts',
    'Get-SPReviewerWorkload',
    'Get-SPIdentityDecisionHistory',
    'Get-SPSourceCampaignCoverage',
    'Get-SPRemediationStatus',
    'Get-SPEntitlementInventory',
    'Get-SPStaleAccess',
    'Get-SPAccessProfileInventory'
)

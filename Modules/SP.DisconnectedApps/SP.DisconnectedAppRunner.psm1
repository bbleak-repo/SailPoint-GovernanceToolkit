#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Disconnected App Runner Functions
.DESCRIPTION
    Orchestration functions for the disconnected app onboarding kit.
    Resolves file-based account records to ISC identities using email
    (primary) or username (fallback) correlation via POST /v3/search.
    Creates targeted SEARCH campaigns per manager group for delta changes.

    Functions:
        1. Resolve-SPDisconnectedAppIdentities - correlates delta accounts to ISC identities
        2. Invoke-SPDisconnectedAppCertRun - creates SEARCH campaigns per manager group
        3. Export-SPDisconnectedAppDeltaHtml - generates delta summary HTML report
        4. Get-SPRegisteredApps - returns enabled app registrations from config
        5. Initialize-SPDisconnectedAppDirectories - scaffolds per-app directories
        6. Get-SPDisconnectedAppDeliveryStatus - checks file delivery freshness per app

    Dependencies:
        - SP.Api (Invoke-SPApiRequest)
        - SP.Campaigns (New-SPCampaign, Start-SPCampaign, Search-SPCampaigns)
        - SP.DeltaCertRunner (Build-SPDeltaSearchFilter)
        - SP.DeltaCertQueries (Get-SPDeltaIdentityDetail, Group-SPDeltaByManager)
        - SP.Core (Write-SPLog, Get-SPConfig)

.NOTES
    Module: SP.DisconnectedAppRunner
    Version: 1.2.0
#>

# Module-scope cache: email/username -> ISC identity ID (avoids duplicate searches)
$script:EmailToIdentityCache = @{}

#region Internal Functions

function Search-SPIdentityByAttribute {
    <#
    .SYNOPSIS
        Searches ISC for an identity by email or username via POST /v3/search.
    .DESCRIPTION
        Uses the ISC search API to find an identity matching the given attribute
        value. Searches by email first (attributes.email field), with optional
        username fallback (name field). Requires sp:search:read scope.

        Results are cached per attribute value for the session to avoid
        redundant API calls when multiple delta records reference the same user.
    .PARAMETER AttributeValue
        The value to search for (email address or username).
    .PARAMETER AttributeField
        The ISC search field to query. Default: 'attributes.email'.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{Found=$bool; IdentityId=$string; DisplayName=$string}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AttributeValue,

        [Parameter()]
        [string]$AttributeField = 'attributes.email',

        [Parameter()]
        [string]$CorrelationID
    )

    $emptyResult = @{
        Found       = $false
        IdentityId  = ''
        DisplayName = ''
    }

    # Check cache first
    $cacheKey = "${AttributeField}:$($AttributeValue.ToLower())"
    if ($script:EmailToIdentityCache.ContainsKey($cacheKey)) {
        return $script:EmailToIdentityCache[$cacheKey]
    }

    Write-SPLog -Message "Searching ISC for identity: $AttributeField='$AttributeValue'" `
        -Severity DEBUG -Component 'SP.DisconnectedAppRunner' -Action 'Search-SPIdentityByAttribute' `
        -CorrelationID $CorrelationID

    try {
        # Escape double-quotes in the search value
        $escapedValue = $AttributeValue -replace '"', '\"'

        $searchBody = @{
            indices = @('identities')
            query   = @{ query = "${AttributeField}:`"$escapedValue`"" }
            limit   = 1
        }

        $result = Invoke-SPApiRequest -Method POST -Endpoint '/search' `
            -Body $searchBody -CorrelationID $CorrelationID

        if (-not $result.Success -or $null -eq $result.Data) {
            $script:EmailToIdentityCache[$cacheKey] = $emptyResult
            return $emptyResult
        }

        # POST /v3/search returns an array
        $hits = @($result.Data)
        if ($hits.Count -eq 0) {
            $script:EmailToIdentityCache[$cacheKey] = $emptyResult
            return $emptyResult
        }

        $identity = $hits[0]

        # Extract identity ID
        $identityId = ''
        if ($null -ne $identity.PSObject.Properties['id'] -and
            -not [string]::IsNullOrWhiteSpace($identity.id)) {
            $identityId = [string]$identity.id
        }

        if ([string]::IsNullOrWhiteSpace($identityId)) {
            $script:EmailToIdentityCache[$cacheKey] = $emptyResult
            return $emptyResult
        }

        # Extract display name
        $displayName = ''
        foreach ($prop in @('displayName', 'name')) {
            if ($null -ne $identity.PSObject.Properties[$prop] -and
                -not [string]::IsNullOrWhiteSpace($identity.$prop)) {
                $displayName = [string]$identity.$prop
                break
            }
        }

        $found = @{
            Found       = $true
            IdentityId  = $identityId
            DisplayName = $displayName
        }

        $script:EmailToIdentityCache[$cacheKey] = $found
        return $found
    }
    catch {
        Write-SPLog -Message "Search-SPIdentityByAttribute failed for '$AttributeValue': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.DisconnectedAppRunner' -Action 'Search-SPIdentityByAttribute' `
            -CorrelationID $CorrelationID
        $script:EmailToIdentityCache[$cacheKey] = $emptyResult
        return $emptyResult
    }
}

function Write-SPDisconnectedAppAuditEvent {
    <#
    .SYNOPSIS
        Appends a JSONL audit event for a disconnected app cert run.
    .DESCRIPTION
        Writes a single JSON line to {OutputPath}/{AppName}/disconnected-app-audit.jsonl
        following the Export-SPAuditJsonl pattern (UTF-8 no BOM, AppendAllText).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CorrelationID,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][int]$IdentitiesProcessed,
        [Parameter(Mandatory)][int]$ManagerGroups,
        [Parameter(Mandatory)][int]$CampaignsCreated,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CampaignIds,
        [Parameter(Mandatory)][int]$UnresolvedCount,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Errors,
        [Parameter(Mandatory)][double]$DurationSeconds,
        [Parameter()][string]$OutputPath = '.\DisconnectedApps\Reports'
    )

    try {
        $appOutputPath = Join-Path -Path $OutputPath -ChildPath $AppName
        if (-not (Test-Path -Path $appOutputPath -PathType Container)) {
            New-Item -Path $appOutputPath -ItemType Directory -Force | Out-Null
        }

        $event = [ordered]@{
            Timestamp           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            CorrelationID       = $CorrelationID
            Action              = 'DisconnectedAppCertRun'
            AppName             = $AppName
            IdentitiesProcessed = $IdentitiesProcessed
            ManagerGroups       = $ManagerGroups
            CampaignsCreated    = $CampaignsCreated
            CampaignIds         = $CampaignIds
            UnresolvedCount     = $UnresolvedCount
            Reason              = $Reason
            Errors              = $Errors
            DurationSeconds     = [math]::Round($DurationSeconds, 2)
        }

        $jsonLine = $event | ConvertTo-Json -Depth 5 -Compress
        $filePath = Join-Path -Path $appOutputPath -ChildPath 'disconnected-app-audit.jsonl'
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($filePath, "$jsonLine`n", $utf8NoBom)

        Write-SPLog -Message "Audit event written to $filePath" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Write-SPDisconnectedAppAuditEvent' `
            -CorrelationID $CorrelationID
    }
    catch {
        Write-SPLog -Message "Failed to write audit JSONL event: $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.DisconnectedAppRunner' -Action 'Write-SPDisconnectedAppAuditEvent' `
            -CorrelationID $CorrelationID
    }
}

function ConvertTo-DisconnectedHtmlSafe {
    <#
    .SYNOPSIS
        HTML-encodes a value for safe embedding in report output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        $Value
    )

    if ($null -eq $Value) { return '' }
    $str = [string]$Value
    if ([string]::IsNullOrWhiteSpace($str)) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($str)
}

function Build-DisconnectedHtmlRow {
    <#
    .SYNOPSIS
        Builds a single HTML table row with inline styling.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Cells,

        [Parameter()]
        [bool]$IsAlternate = $false
    )

    $rowStyle  = if ($IsAlternate) { ' style="background:#f9f9f9;"' } else { '' }
    $tdPadding = 'style="padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;"'

    $tds = ($Cells | ForEach-Object { "<td $tdPadding>$_</td>" }) -join ''
    return "<tr$rowStyle>$tds</tr>"
}

function Build-DisconnectedHtmlHeader {
    <#
    .SYNOPSIS
        Builds an HTML table header row with inline styling.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Headers
    )

    $thStyle = 'style="background:#34495e; color:#fff; padding:8px 10px; text-align:left; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; font-size:13px;"'
    $ths = ($Headers | ForEach-Object { "<th $thStyle>$(ConvertTo-DisconnectedHtmlSafe $_)</th>" }) -join ''
    return "<tr>$ths</tr>"
}

#endregion

#region Public Functions

function Resolve-SPDisconnectedAppIdentities {
    <#
    .SYNOPSIS
        Resolves disconnected app delta accounts to ISC identities.
    .DESCRIPTION
        Takes the delta result from Compare-SPDisconnectedAppFiles and resolves
        campaign-triggering accounts (Added, Enabled, GrantedEntitlements) to
        ISC identity IDs using email (primary) or username (fallback) correlation.

        For each resolved identity, manager details are fetched via
        Get-SPDeltaIdentityDetail (from SP.DeltaCertQueries) which handles
        its own caching.

        Accounts that cannot be correlated to an ISC identity are tracked in
        the Unresolved list for downstream reporting.

    .PARAMETER DeltaResult
        The .Data hashtable from Compare-SPDisconnectedAppFiles containing
        Added, Enabled, GrantedEntitlements, and other change arrays.
    .PARAMETER CorrelationAttribute
        CSV column name used as the primary correlation attribute.
        Default: 'e-mail'.
    .PARAMETER FallbackAttribute
        CSV column name used as fallback when primary correlation fails.
        Default: 'name' (username).
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                Resolved   = @([hashtable] with AccountId, Email, Username,
                               IdentityId, DisplayName, ManagerId, ManagerName,
                               IsActive, ChangeTypes)
                Unresolved = @([hashtable] with AccountId, Email, Username, Reason)
                Summary    = @{TotalAccounts; Resolved; Unresolved; ByChangeType}
            }
            Error = $string
        }
    .EXAMPLE
        $delta = (Compare-SPDisconnectedAppFiles -CurrentFilePath $today -PreviousFilePath $yesterday).Data
        $resolved = Resolve-SPDisconnectedAppIdentities -DeltaResult $delta
        $resolved.Data.Resolved | Format-Table AccountId, IdentityId, ManagerName
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$DeltaResult,

        [Parameter()]
        [string]$CorrelationAttribute = 'e-mail',

        [Parameter()]
        [string]$FallbackAttribute = 'name',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Resolve-SPDisconnectedAppIdentities: Starting identity resolution (correlation=$CorrelationAttribute)" `
        -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Resolve-SPDisconnectedAppIdentities' `
        -CorrelationID $CorrelationID

    try {
        # ---------------------------------------------------------------
        # Step 1: Extract unique accounts from campaign-triggering changes
        # ---------------------------------------------------------------
        # AccountAdded, AccountEnabled, and EntitlementGranted trigger campaigns.
        # Each change type has a different record shape; normalize to a flat list.
        $accountMap = @{}  # keyed by account ID -> @{Email; Username; ChangeTypes}

        # Added: @{Account=$row; NewGroups=@(...)}
        $addedRecords = @()
        if ($null -ne $DeltaResult['Added']) { $addedRecords = @($DeltaResult['Added']) }
        foreach ($record in $addedRecords) {
            $acct = $record['Account']
            if ($null -eq $acct) { continue }
            $id = [string]$acct.id
            if ([string]::IsNullOrWhiteSpace($id)) { continue }

            if (-not $accountMap.ContainsKey($id)) {
                $accountMap[$id] = @{
                    Email       = if ($null -ne $acct.PSObject.Properties[$CorrelationAttribute]) { [string]$acct.$CorrelationAttribute } else { '' }
                    Username    = if ($null -ne $acct.PSObject.Properties[$FallbackAttribute]) { [string]$acct.$FallbackAttribute } else { '' }
                    GivenName   = if ($null -ne $acct.PSObject.Properties['givenName']) { [string]$acct.givenName } else { '' }
                    FamilyName  = if ($null -ne $acct.PSObject.Properties['familyName']) { [string]$acct.familyName } else { '' }
                    ChangeTypes = [System.Collections.Generic.List[string]]::new()
                }
            }
            $accountMap[$id].ChangeTypes.Add('Added')
        }

        # Enabled: @{Account=$row}
        $enabledRecords = @()
        if ($null -ne $DeltaResult['Enabled']) { $enabledRecords = @($DeltaResult['Enabled']) }
        foreach ($record in $enabledRecords) {
            $acct = $record['Account']
            if ($null -eq $acct) { continue }
            $id = [string]$acct.id
            if ([string]::IsNullOrWhiteSpace($id)) { continue }

            if (-not $accountMap.ContainsKey($id)) {
                $accountMap[$id] = @{
                    Email       = if ($null -ne $acct.PSObject.Properties[$CorrelationAttribute]) { [string]$acct.$CorrelationAttribute } else { '' }
                    Username    = if ($null -ne $acct.PSObject.Properties[$FallbackAttribute]) { [string]$acct.$FallbackAttribute } else { '' }
                    GivenName   = if ($null -ne $acct.PSObject.Properties['givenName']) { [string]$acct.givenName } else { '' }
                    FamilyName  = if ($null -ne $acct.PSObject.Properties['familyName']) { [string]$acct.familyName } else { '' }
                    ChangeTypes = [System.Collections.Generic.List[string]]::new()
                }
            }
            if ('Enabled' -notin $accountMap[$id].ChangeTypes) {
                $accountMap[$id].ChangeTypes.Add('Enabled')
            }
        }

        # GrantedEntitlements: @{AccountId='EMP10001'; AccountEmail='...'; Entitlements=@(...)}
        $grantedRecords = @()
        if ($null -ne $DeltaResult['GrantedEntitlements']) { $grantedRecords = @($DeltaResult['GrantedEntitlements']) }
        foreach ($record in $grantedRecords) {
            $id = [string]$record['AccountId']
            if ([string]::IsNullOrWhiteSpace($id)) { continue }

            if (-not $accountMap.ContainsKey($id)) {
                $accountMap[$id] = @{
                    Email       = if ($null -ne $record['AccountEmail']) { [string]$record['AccountEmail'] } else { '' }
                    Username    = ''
                    GivenName   = ''
                    FamilyName  = ''
                    ChangeTypes = [System.Collections.Generic.List[string]]::new()
                }
            }
            if ('EntitlementGranted' -notin $accountMap[$id].ChangeTypes) {
                $accountMap[$id].ChangeTypes.Add('EntitlementGranted')
            }
        }

        $totalAccounts = $accountMap.Count

        if ($totalAccounts -eq 0) {
            Write-SPLog -Message "No campaign-triggering accounts found in delta result" `
                -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Resolve-SPDisconnectedAppIdentities' `
                -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{
                    Resolved   = @()
                    Unresolved = @()
                    Summary    = @{
                        TotalAccounts = 0
                        Resolved      = 0
                        Unresolved    = 0
                        ByChangeType  = @{}
                    }
                }
                Error   = $null
            }
        }

        Write-SPLog -Message "Extracted $totalAccounts unique account(s) from campaign-triggering changes" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Resolve-SPDisconnectedAppIdentities' `
            -CorrelationID $CorrelationID

        # ---------------------------------------------------------------
        # Step 2: Resolve each account to an ISC identity
        # ---------------------------------------------------------------
        $resolved   = [System.Collections.Generic.List[hashtable]]::new()
        $unresolved = [System.Collections.Generic.List[hashtable]]::new()
        $changeTypeCounts = @{}

        foreach ($accountId in $accountMap.Keys) {
            $entry    = $accountMap[$accountId]
            $email    = $entry.Email
            $username = $entry.Username

            $searchResult = $null

            # Primary: search by email
            if (-not [string]::IsNullOrWhiteSpace($email)) {
                $searchResult = Search-SPIdentityByAttribute `
                    -AttributeValue $email `
                    -AttributeField 'attributes.email' `
                    -CorrelationID $CorrelationID
            }

            # Fallback: search by username (name field in ISC)
            if (($null -eq $searchResult -or -not $searchResult.Found) -and
                -not [string]::IsNullOrWhiteSpace($username)) {
                Write-SPLog -Message "Email lookup failed for '$accountId' ($email) -- trying username fallback '$username'" `
                    -Severity DEBUG -Component 'SP.DisconnectedAppRunner' -Action 'Resolve-SPDisconnectedAppIdentities' `
                    -CorrelationID $CorrelationID
                $searchResult = Search-SPIdentityByAttribute `
                    -AttributeValue $username `
                    -AttributeField 'name' `
                    -CorrelationID $CorrelationID
            }

            # Not found by either method
            if ($null -eq $searchResult -or -not $searchResult.Found) {
                $reason = 'Not found in ISC'
                if ([string]::IsNullOrWhiteSpace($email) -and [string]::IsNullOrWhiteSpace($username)) {
                    $reason = 'No correlation attribute available'
                }
                $unresolved.Add(@{
                    AccountId = $accountId
                    Email     = $email
                    Username  = $username
                    Reason    = $reason
                })
                Write-SPLog -Message "Account '$accountId' ($email) could not be resolved to ISC identity: $reason" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' -Action 'Resolve-SPDisconnectedAppIdentities' `
                    -CorrelationID $CorrelationID
                continue
            }

            # ---------------------------------------------------------------
            # Step 3: Resolve manager details via Get-SPDeltaIdentityDetail
            # ---------------------------------------------------------------
            $identityId = $searchResult.IdentityId
            $detail = Get-SPDeltaIdentityDetail -IdentityId $identityId -CorrelationID $CorrelationID

            $changeTypes = @($entry.ChangeTypes)
            foreach ($ct in $changeTypes) {
                if (-not $changeTypeCounts.ContainsKey($ct)) {
                    $changeTypeCounts[$ct] = 0
                }
                $changeTypeCounts[$ct]++
            }

            $resolved.Add(@{
                AccountId   = $accountId
                Email       = $email
                Username    = $username
                GivenName   = $entry.GivenName
                FamilyName  = $entry.FamilyName
                IdentityId  = $identityId
                DisplayName = $detail.DisplayName
                ManagerId   = $detail.ManagerId
                ManagerName = $detail.ManagerName
                IsActive    = $detail.IsActive
                ChangeTypes = $changeTypes
            })

            Write-SPLog -Message "Resolved '$accountId' ($email) -> ISC identity '$identityId' ($($detail.DisplayName)), manager='$($detail.ManagerName)'" `
                -Severity DEBUG -Component 'SP.DisconnectedAppRunner' -Action 'Resolve-SPDisconnectedAppIdentities' `
                -CorrelationID $CorrelationID
        }

        # ---------------------------------------------------------------
        # Step 4: Build summary
        # ---------------------------------------------------------------
        $summary = @{
            TotalAccounts = $totalAccounts
            Resolved      = $resolved.Count
            Unresolved    = $unresolved.Count
            ByChangeType  = $changeTypeCounts
        }

        Write-SPLog -Message "Identity resolution complete: $($resolved.Count) resolved, $($unresolved.Count) unresolved out of $totalAccounts account(s)" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Resolve-SPDisconnectedAppIdentities' `
            -CorrelationID $CorrelationID `
            -AdditionalFields @{
                ResolvedCount   = $resolved.Count
                UnresolvedCount = $unresolved.Count
                TotalAccounts   = $totalAccounts
            }

        return @{
            Success = $true
            Data    = @{
                Resolved   = $resolved.ToArray()
                Unresolved = $unresolved.ToArray()
                Summary    = $summary
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Resolve-SPDisconnectedAppIdentities failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Resolve-SPDisconnectedAppIdentities' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

function Invoke-SPDisconnectedAppCertRun {
    <#
    .SYNOPSIS
        Creates targeted SEARCH campaigns for disconnected app delta changes.
    .DESCRIPTION
        Takes resolved delta identities (from Resolve-SPDisconnectedAppIdentities)
        and creates one SEARCH-type certification campaign per manager group.
        Only campaign-triggering changes are included: AccountAdded, AccountEnabled,
        and EntitlementGranted.

        Reuses the existing campaign infrastructure:
        - Group-SPDeltaByManager for manager grouping
        - Build-SPDeltaSearchFilter for identity filter queries
        - New-SPCampaign / Start-SPCampaign for campaign lifecycle

        Campaign naming: "{AppName} Delta Cert {YYYY-MM-DD} - {ManagerName}"

        Safety guards:
        - Duplicate guard: skips if today's campaigns already exist (bypass with -Force)
        - Max campaigns per run: aborts if manager group count exceeds limit
        - WhatIf: describes what would be created without making API calls

    .PARAMETER AppName
        Application name used for campaign naming and directory paths.
    .PARAMETER DeltaResult
        The .Data hashtable from Compare-SPDisconnectedAppFiles.
    .PARAMETER ResolvedIdentities
        The .Data hashtable from Resolve-SPDisconnectedAppIdentities containing
        Resolved and Unresolved arrays.
    .PARAMETER CampaignNamePrefix
        Optional override for the campaign name prefix. Default uses AppName.
    .PARAMETER DeadlineDays
        Days from today until the campaign deadline. Default: 2.
    .PARAMETER FallbackManagerId
        Identity ID used as reviewer for identities who have no manager in ISC.
        If omitted, manager-less identities are skipped.
    .PARAMETER MaxCampaignsPerRun
        Abort before creating any campaigns if manager group count exceeds this.
        Default: 20.
    .PARAMETER OutputPath
        Directory for JSONL audit trail. Default: '.\DisconnectedApps\Reports'.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .PARAMETER Force
        Bypass the duplicate campaign guard.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                CampaignsCreated = [int]
                CampaignIds      = [string[]]
                IdentityCount    = [int]
                ManagerGroups    = [int]
                UnresolvedCount  = [int]
                Reason           = [string]  # NoChanges | NoCampaignTriggers |
                                             # NoManagerGroups | DuplicatesExist |
                                             # WhatIf | Created
                Errors           = [string[]]
                WhatIfGroups     = [hashtable]  # only present when WhatIf
            }
            Error   = $string
        }
    .EXAMPLE
        $delta = (Compare-SPDisconnectedAppFiles -CurrentFilePath $today -PreviousFilePath $yesterday).Data
        $resolved = (Resolve-SPDisconnectedAppIdentities -DeltaResult $delta).Data
        $result = Invoke-SPDisconnectedAppCertRun -AppName 'PEP-Plus' -DeltaResult $delta `
                    -ResolvedIdentities $resolved -DeadlineDays 2
    .EXAMPLE
        Invoke-SPDisconnectedAppCertRun -AppName 'PEP-Plus' -DeltaResult $delta `
            -ResolvedIdentities $resolved -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter(Mandatory)]
        [hashtable]$DeltaResult,

        [Parameter(Mandatory)]
        [hashtable]$ResolvedIdentities,

        [Parameter()]
        [string]$CampaignNamePrefix,

        [Parameter()]
        [int]$DeadlineDays = 2,

        [Parameter()]
        [string]$FallbackManagerId,

        [Parameter()]
        [int]$MaxCampaignsPerRun = 20,

        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if ([string]::IsNullOrWhiteSpace($CampaignNamePrefix)) {
        $CampaignNamePrefix = "$AppName Delta Cert"
    }

    $runStartTime = [System.Diagnostics.Stopwatch]::StartNew()
    $dateStamp    = Get-Date -Format 'yyyy-MM-dd'

    Write-SPLog -Message "Invoke-SPDisconnectedAppCertRun: AppName='$AppName' DeadlineDays=$DeadlineDays WhatIf=$(($WhatIfPreference -eq $true))" `
        -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
        -CorrelationID $CorrelationID

    try {
        # ---------------------------------------------------------------
        # Step 1: Validate inputs -- check for campaign-triggering changes
        # ---------------------------------------------------------------
        $resolvedList = @()
        if ($null -ne $ResolvedIdentities -and $null -ne $ResolvedIdentities['Resolved']) {
            $resolvedList = @($ResolvedIdentities['Resolved'])
        }

        $unresolvedCount = 0
        if ($null -ne $ResolvedIdentities -and $null -ne $ResolvedIdentities['Unresolved']) {
            $unresolvedCount = @($ResolvedIdentities['Unresolved']).Count
        }

        if ($resolvedList.Count -eq 0) {
            Write-SPLog -Message "No resolved identities with campaign-triggering changes -- no campaigns created" `
                -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDisconnectedAppAuditEvent -CorrelationID $CorrelationID -AppName $AppName `
                -IdentitiesProcessed 0 -ManagerGroups 0 -CampaignsCreated 0 `
                -CampaignIds @() -UnresolvedCount $unresolvedCount `
                -Reason 'NoCampaignTriggers' -Errors @() `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds -OutputPath $OutputPath

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = 0
                    ManagerGroups    = 0
                    UnresolvedCount  = $unresolvedCount
                    Reason           = 'NoCampaignTriggers'
                    Errors           = @()
                }
                Error   = $null
            }
        }

        Write-SPLog -Message "Step 1: $($resolvedList.Count) resolved identit(ies), $unresolvedCount unresolved" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
            -CorrelationID $CorrelationID

        # ---------------------------------------------------------------
        # Step 2: Duplicate campaign guard
        # ---------------------------------------------------------------
        if (-not $Force) {
            Write-SPLog -Message "Step 2: Checking for existing campaigns matching '$CampaignNamePrefix $dateStamp'" `
                -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                -CorrelationID $CorrelationID

            $searchResult = Search-SPCampaigns -Keyword "$CampaignNamePrefix $dateStamp" `
                -CorrelationID $CorrelationID

            if ($searchResult.Success -and @($searchResult.Data).Count -gt 0) {
                $existingCount = @($searchResult.Data).Count
                Write-SPLog -Message "Duplicate guard: Found $existingCount existing campaign(s) matching '$CampaignNamePrefix $dateStamp'. Use -Force to bypass." `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                    -CorrelationID $CorrelationID

                $runStartTime.Stop()
                Write-SPDisconnectedAppAuditEvent -CorrelationID $CorrelationID -AppName $AppName `
                    -IdentitiesProcessed $resolvedList.Count -ManagerGroups 0 `
                    -CampaignsCreated 0 -CampaignIds @() -UnresolvedCount $unresolvedCount `
                    -Reason 'DuplicatesExist' -Errors @() `
                    -DurationSeconds $runStartTime.Elapsed.TotalSeconds -OutputPath $OutputPath

                return @{
                    Success = $true
                    Data    = @{
                        CampaignsCreated = 0
                        CampaignIds      = @()
                        IdentityCount    = $resolvedList.Count
                        ManagerGroups    = 0
                        UnresolvedCount  = $unresolvedCount
                        Reason           = 'DuplicatesExist'
                        Errors           = @()
                    }
                    Error   = $null
                }
            }
        }

        # ---------------------------------------------------------------
        # Step 3: Convert resolved identities to PSCustomObjects for
        #         Group-SPDeltaByManager compatibility
        # ---------------------------------------------------------------
        Write-SPLog -Message "Step 3: Grouping $($resolvedList.Count) identit(ies) by manager" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
            -CorrelationID $CorrelationID

        $identityObjects = [System.Collections.Generic.List[object]]::new()
        foreach ($resolved in $resolvedList) {
            $managerId = $resolved['ManagerId']

            # Apply fallback manager if needed
            if ([string]::IsNullOrWhiteSpace($managerId)) {
                if (-not [string]::IsNullOrWhiteSpace($FallbackManagerId)) {
                    $managerId = $FallbackManagerId
                    Write-SPLog -Message "Identity '$($resolved['IdentityId'])' has no manager -- using fallback '$FallbackManagerId'" `
                        -Severity WARN -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                        -CorrelationID $CorrelationID
                }
                else {
                    Write-SPLog -Message "Identity '$($resolved['IdentityId'])' has no manager and no fallback -- skipping" `
                        -Severity WARN -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                        -CorrelationID $CorrelationID
                    continue
                }
            }

            $identityObjects.Add([PSCustomObject]@{
                IdentityId  = $resolved['IdentityId']
                DisplayName = $resolved['DisplayName']
                ManagerId   = $managerId
                ManagerName = if (-not [string]::IsNullOrWhiteSpace($resolved['ManagerName'])) {
                                  $resolved['ManagerName']
                              }
                              elseif (-not [string]::IsNullOrWhiteSpace($FallbackManagerId) -and
                                      $managerId -eq $FallbackManagerId) {
                                  '(fallback)'
                              }
                              else { $managerId }
                IsActive    = $resolved['IsActive']
            })
        }

        if ($identityObjects.Count -eq 0) {
            Write-SPLog -Message "No identities with managers after filtering -- no campaigns created" `
                -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDisconnectedAppAuditEvent -CorrelationID $CorrelationID -AppName $AppName `
                -IdentitiesProcessed $resolvedList.Count -ManagerGroups 0 `
                -CampaignsCreated 0 -CampaignIds @() -UnresolvedCount $unresolvedCount `
                -Reason 'NoManagerGroups' -Errors @() `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds -OutputPath $OutputPath

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = $resolvedList.Count
                    ManagerGroups    = 0
                    UnresolvedCount  = $unresolvedCount
                    Reason           = 'NoManagerGroups'
                    Errors           = @()
                }
                Error   = $null
            }
        }

        # Group by manager using shared function
        $groupResult = Group-SPDeltaByManager -AffectedIdentities $identityObjects.ToArray() `
            -CorrelationID $CorrelationID

        if (-not $groupResult.Success) {
            $runStartTime.Stop()
            Write-SPDisconnectedAppAuditEvent -CorrelationID $CorrelationID -AppName $AppName `
                -IdentitiesProcessed $resolvedList.Count -ManagerGroups 0 `
                -CampaignsCreated 0 -CampaignIds @() -UnresolvedCount $unresolvedCount `
                -Reason 'Error' -Errors @("Manager grouping failed: $($groupResult.Error)") `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds -OutputPath $OutputPath

            return @{
                Success = $false
                Data    = $null
                Error   = "Manager grouping failed: $($groupResult.Error)"
            }
        }

        $managerGroups = $groupResult.Data

        if ($managerGroups.Count -eq 0) {
            $runStartTime.Stop()
            Write-SPDisconnectedAppAuditEvent -CorrelationID $CorrelationID -AppName $AppName `
                -IdentitiesProcessed $identityObjects.Count -ManagerGroups 0 `
                -CampaignsCreated 0 -CampaignIds @() -UnresolvedCount $unresolvedCount `
                -Reason 'NoManagerGroups' -Errors @() `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds -OutputPath $OutputPath

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = $identityObjects.Count
                    ManagerGroups    = 0
                    UnresolvedCount  = $unresolvedCount
                    Reason           = 'NoManagerGroups'
                    Errors           = @()
                }
                Error   = $null
            }
        }

        # ---------------------------------------------------------------
        # Step 4: Safety guard -- max campaigns per run
        # ---------------------------------------------------------------
        if ($managerGroups.Count -gt $MaxCampaignsPerRun) {
            $errMsg = "Manager group count ($($managerGroups.Count)) exceeds MaxCampaignsPerRun ($MaxCampaignsPerRun). " +
                      "Increase -MaxCampaignsPerRun if expected."
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
                -Action 'Invoke-SPDisconnectedAppCertRun' -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDisconnectedAppAuditEvent -CorrelationID $CorrelationID -AppName $AppName `
                -IdentitiesProcessed $identityObjects.Count -ManagerGroups $managerGroups.Count `
                -CampaignsCreated 0 -CampaignIds @() -UnresolvedCount $unresolvedCount `
                -Reason 'Error' -Errors @($errMsg) `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds -OutputPath $OutputPath

            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # ---------------------------------------------------------------
        # Step 5: WhatIf -- describe without writing
        # ---------------------------------------------------------------
        if (($WhatIfPreference -eq $true)) {
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

            Write-SPLog -Message "WhatIf: Would create $($managerGroups.Count) campaign(s) for $($identityObjects.Count) identit(ies)" `
                -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                -CorrelationID $CorrelationID

            $runStartTime.Stop()
            Write-SPDisconnectedAppAuditEvent -CorrelationID $CorrelationID -AppName $AppName `
                -IdentitiesProcessed $identityObjects.Count -ManagerGroups $managerGroups.Count `
                -CampaignsCreated 0 -CampaignIds @() -UnresolvedCount $unresolvedCount `
                -Reason 'WhatIf' -Errors @() `
                -DurationSeconds $runStartTime.Elapsed.TotalSeconds -OutputPath $OutputPath

            return @{
                Success = $true
                Data    = @{
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = $identityObjects.Count
                    ManagerGroups    = $managerGroups.Count
                    UnresolvedCount  = $unresolvedCount
                    Reason           = 'WhatIf'
                    Errors           = @()
                    WhatIfGroups     = $whatIfGroups
                }
                Error   = $null
            }
        }

        # ---------------------------------------------------------------
        # Step 6: Create and activate one SEARCH campaign per manager group
        # ---------------------------------------------------------------
        Write-SPLog -Message "Step 6: Creating $($managerGroups.Count) campaign(s) (deadline +$DeadlineDays day(s))" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
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
                -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                -CorrelationID $CorrelationID

            $createResult = New-SPCampaign `
                -Name                $campaignName `
                -Type                'SEARCH' `
                -SearchFilter        $searchFilter `
                -CertifierIdentityId $managerId `
                -Description         "$AppName delta certification: $($identityIds.Count) identit(ies) with new or changed access, $dateStamp." `
                -Deadline            $deadlineStr `
                -CorrelationID       $CorrelationID

            if (-not $createResult.Success) {
                $errMsg = "Campaign '$campaignName' create failed: $($createResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Invoke-SPDisconnectedAppCertRun' -CorrelationID $CorrelationID
                $campaignErrors.Add($errMsg)
                continue
            }

            $campaignId = $createResult.Data.id

            $activateResult = Start-SPCampaign -CampaignId $campaignId -CorrelationID $CorrelationID

            if (-not $activateResult.Success) {
                $errMsg = "Campaign '$campaignName' ($campaignId) created but activation failed: $($activateResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Invoke-SPDisconnectedAppCertRun' -CorrelationID $CorrelationID
                $campaignErrors.Add($errMsg)
                $campaignIds.Add($campaignId)
                continue
            }

            Write-SPLog -Message "Campaign '$campaignName' ($campaignId) created and activation requested" `
                -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                -CorrelationID $CorrelationID
            $campaignIds.Add($campaignId)
        }

        $overallSuccess = ($campaignErrors.Count -eq 0)

        if ($campaignErrors.Count -gt 0) {
            Write-SPLog -Message "$($campaignErrors.Count) campaign(s) had creation/activation errors" `
                -Severity WARN -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
                -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Invoke-SPDisconnectedAppCertRun complete: $($campaignIds.Count) campaign(s) for $($identityObjects.Count) identit(ies) across $($managerGroups.Count) manager group(s)" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Invoke-SPDisconnectedAppCertRun' `
            -CorrelationID $CorrelationID

        $runStartTime.Stop()
        Write-SPDisconnectedAppAuditEvent -CorrelationID $CorrelationID -AppName $AppName `
            -IdentitiesProcessed $identityObjects.Count -ManagerGroups $managerGroups.Count `
            -CampaignsCreated $campaignIds.Count -CampaignIds $campaignIds.ToArray() `
            -UnresolvedCount $unresolvedCount `
            -Reason 'Created' -Errors $campaignErrors.ToArray() `
            -DurationSeconds $runStartTime.Elapsed.TotalSeconds -OutputPath $OutputPath

        return @{
            Success = $overallSuccess
            Data    = @{
                CampaignsCreated = $campaignIds.Count
                CampaignIds      = $campaignIds.ToArray()
                IdentityCount    = $identityObjects.Count
                ManagerGroups    = $managerGroups.Count
                UnresolvedCount  = $unresolvedCount
                Reason           = 'Created'
                Errors           = $campaignErrors.ToArray()
            }
            Error   = if ($campaignErrors.Count -gt 0) { $campaignErrors -join '; ' } else { $null }
        }
    }
    catch {
        $errMsg = "Invoke-SPDisconnectedAppCertRun failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Invoke-SPDisconnectedAppCertRun' -CorrelationID $CorrelationID

        $runStartTime.Stop()
        Write-SPDisconnectedAppAuditEvent -CorrelationID $CorrelationID -AppName $AppName `
            -IdentitiesProcessed 0 -ManagerGroups 0 -CampaignsCreated 0 `
            -CampaignIds @() -UnresolvedCount 0 `
            -Reason 'Error' -Errors @($errMsg) `
            -DurationSeconds $runStartTime.Elapsed.TotalSeconds -OutputPath $OutputPath

        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Export-SPDisconnectedAppDeltaHtml {
    <#
    .SYNOPSIS
        Generates an HTML delta summary report for a disconnected app file comparison.
    .DESCRIPTION
        Takes the delta result from Compare-SPDisconnectedAppFiles and produces a
        self-contained HTML report with sections for added accounts, removed accounts,
        entitlement changes, disabled/enabled accounts, and attribute changes.

        The report uses 100% inline CSS for Microsoft Word paste compatibility.
        No external resources, no flexbox, no grid.

        Color coding:
        - Green (#339933): added accounts, granted entitlements
        - Red (#CC3333): removed accounts, revoked entitlements, disabled
        - Orange (#FF8800): attribute changes, enabled (re-activated)

    .PARAMETER DeltaResult
        The .Data hashtable from Compare-SPDisconnectedAppFiles.
    .PARAMETER AppName
        Application name shown in the report title.
    .PARAMETER OutputPath
        Base directory for reports. Report is saved to
        {OutputPath}/{AppName}/delta-{YYYY-MM-DD}.html
    .PARAMETER ReportDate
        Date stamp for the report filename and header. Defaults to today.
    .OUTPUTS
        [hashtable] @{Success; Data=@{FilePath=[string]}; Error}
    .EXAMPLE
        $delta = (Compare-SPDisconnectedAppFiles -CurrentFilePath $today -PreviousFilePath $yesterday).Data
        Export-SPDisconnectedAppDeltaHtml -DeltaResult $delta -AppName 'PEP-Plus' -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$DeltaResult,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [string]$ReportDate
    )

    if ([string]::IsNullOrWhiteSpace($ReportDate)) {
        $ReportDate = Get-Date -Format 'yyyy-MM-dd'
    }

    try {
        # ---------------------------------------------------------------
        # Ensure output directory exists
        # ---------------------------------------------------------------
        $appOutputPath = Join-Path -Path $OutputPath -ChildPath $AppName
        if (-not (Test-Path -Path $appOutputPath -PathType Container)) {
            New-Item -Path $appOutputPath -ItemType Directory -Force | Out-Null
        }
        $filePath = Join-Path -Path $appOutputPath -ChildPath "delta-${ReportDate}.html"

        # ---------------------------------------------------------------
        # Extract data arrays safely
        # ---------------------------------------------------------------
        $summary  = if ($null -ne $DeltaResult['Summary']) { $DeltaResult['Summary'] } else { @{} }
        $added    = @(); if ($null -ne $DeltaResult['Added'])    { $added    = @($DeltaResult['Added']) }
        $removed  = @(); if ($null -ne $DeltaResult['Removed'])  { $removed  = @($DeltaResult['Removed']) }
        $disabled = @(); if ($null -ne $DeltaResult['Disabled']) { $disabled = @($DeltaResult['Disabled']) }
        $enabled  = @(); if ($null -ne $DeltaResult['Enabled'])  { $enabled  = @($DeltaResult['Enabled']) }
        $granted  = @(); if ($null -ne $DeltaResult['GrantedEntitlements']) { $granted = @($DeltaResult['GrantedEntitlements']) }
        $revoked  = @(); if ($null -ne $DeltaResult['RevokedEntitlements']) { $revoked = @($DeltaResult['RevokedEntitlements']) }
        $attrChg  = @(); if ($null -ne $DeltaResult['AttributeChanges'])   { $attrChg = @($DeltaResult['AttributeChanges']) }
        $unchanged = if ($null -ne $DeltaResult['Unchanged']) { $DeltaResult['Unchanged'] } else { 0 }

        # ---------------------------------------------------------------
        # Reusable style constants
        # ---------------------------------------------------------------
        $sectionHeadingStyle = 'font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;'
        $labelTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; font-weight:bold; width:220px; background:#f4f4f4; vertical-align:top;'
        $valueTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;'
        $tableStyle          = 'width:100%; border-collapse:collapse; margin-bottom:18px; font-size:13px; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif;'
        $badgeGreen          = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#339933;'
        $badgeRed            = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#CC3333;'
        $badgeOrange         = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#FF8800;'

        # ---------------------------------------------------------------
        # Build HTML
        # ---------------------------------------------------------------
        $html = [System.Text.StringBuilder]::new(8192)

        # Document shell
        [void]$html.AppendLine('<!DOCTYPE html>')
        [void]$html.AppendLine('<html lang="en">')
        [void]$html.AppendLine('<head>')
        [void]$html.AppendLine('    <meta charset="UTF-8">')
        [void]$html.AppendLine('    <meta name="viewport" content="width=device-width, initial-scale=1.0">')
        [void]$html.AppendLine("    <title>$(ConvertTo-DisconnectedHtmlSafe $AppName) - Delta Summary $ReportDate</title>")
        [void]$html.AppendLine('</head>')
        [void]$html.AppendLine('<body style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">')
        [void]$html.AppendLine('<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">')

        # Report title
        $safeAppName = ConvertTo-DisconnectedHtmlSafe $AppName
        [void]$html.AppendLine("<h1 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin-top:0; margin-bottom:4px; font-size:22px;`">$safeAppName - Delta Summary</h1>")
        [void]$html.AppendLine("<p style=`"color:#777; font-size:13px; margin-top:0; margin-bottom:20px;`">Report date: $ReportDate</p>")

        # ---------------------------------------------------------------
        # Section 1: Summary
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Summary</h2>")
        [void]$html.AppendLine("<table style=`"$tableStyle`">")

        $totalCurrent  = if ($null -ne $summary['TotalCurrent'])  { $summary['TotalCurrent'] }  else { 0 }
        $totalPrevious = if ($null -ne $summary['TotalPrevious']) { $summary['TotalPrevious'] } else { 0 }

        $summaryRows = @(
            @('Total Current Accounts',  $totalCurrent)
            @('Total Previous Accounts', $totalPrevious)
            @('Accounts Added',          $added.Count)
            @('Accounts Removed',        $removed.Count)
            @('Accounts Disabled',       $disabled.Count)
            @('Accounts Enabled',        $enabled.Count)
            @('Entitlements Granted',    $granted.Count)
            @('Entitlements Revoked',    $revoked.Count)
            @('Attribute Changes',       $attrChg.Count)
            @('Unchanged',              $unchanged)
        )

        foreach ($row in $summaryRows) {
            $label = ConvertTo-DisconnectedHtmlSafe $row[0]
            $value = ConvertTo-DisconnectedHtmlSafe $row[1]
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        # ---------------------------------------------------------------
        # Section 2: Added Accounts
        # ---------------------------------------------------------------
        if ($added.Count -gt 0) {
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`"><span style=`"$badgeGreen`">ADDED</span> Accounts ($($added.Count))</h2>")
            [void]$html.AppendLine("<table style=`"$tableStyle`">")
            [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Account ID', 'Name', 'Email', 'Department', 'Groups')))

            $rowIdx = 0
            foreach ($entry in $added) {
                $acct = $entry['Account']
                if ($null -eq $acct) { continue }
                $cells = @(
                    (ConvertTo-DisconnectedHtmlSafe $acct.id),
                    (ConvertTo-DisconnectedHtmlSafe "$($acct.givenName) $($acct.familyName)"),
                    (ConvertTo-DisconnectedHtmlSafe $acct.'e-mail'),
                    (ConvertTo-DisconnectedHtmlSafe $acct.department),
                    (ConvertTo-DisconnectedHtmlSafe ($entry['NewGroups'] -join ', '))
                )
                [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                $rowIdx++
            }
            [void]$html.AppendLine('</table>')
        }

        # ---------------------------------------------------------------
        # Section 3: Removed Accounts
        # ---------------------------------------------------------------
        if ($removed.Count -gt 0) {
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`"><span style=`"$badgeRed`">REMOVED</span> Accounts ($($removed.Count))</h2>")
            [void]$html.AppendLine("<table style=`"$tableStyle`">")
            [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Account ID', 'Name', 'Email', 'Department')))

            $rowIdx = 0
            foreach ($entry in $removed) {
                $acct = $entry['Account']
                if ($null -eq $acct) { continue }
                $cells = @(
                    (ConvertTo-DisconnectedHtmlSafe $acct.id),
                    (ConvertTo-DisconnectedHtmlSafe "$($acct.givenName) $($acct.familyName)"),
                    (ConvertTo-DisconnectedHtmlSafe $acct.'e-mail'),
                    (ConvertTo-DisconnectedHtmlSafe $acct.department)
                )
                [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                $rowIdx++
            }
            [void]$html.AppendLine('</table>')
        }

        # ---------------------------------------------------------------
        # Section 4: Entitlement Changes
        # ---------------------------------------------------------------
        if ($granted.Count -gt 0 -or $revoked.Count -gt 0) {
            $entTotal = $granted.Count + $revoked.Count
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Entitlement Changes ($entTotal)</h2>")

            if ($granted.Count -gt 0) {
                [void]$html.AppendLine("<h3 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#339933; margin-top:16px; margin-bottom:8px; font-size:14px;`"><span style=`"$badgeGreen`">GRANTED</span> ($($granted.Count))</h3>")
                [void]$html.AppendLine("<table style=`"$tableStyle`">")
                [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Account ID', 'Email', 'Entitlements Granted')))

                $rowIdx = 0
                foreach ($entry in $granted) {
                    $cells = @(
                        (ConvertTo-DisconnectedHtmlSafe $entry['AccountId']),
                        (ConvertTo-DisconnectedHtmlSafe $entry['AccountEmail']),
                        (ConvertTo-DisconnectedHtmlSafe ($entry['Entitlements'] -join ', '))
                    )
                    [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                    $rowIdx++
                }
                [void]$html.AppendLine('</table>')
            }

            if ($revoked.Count -gt 0) {
                [void]$html.AppendLine("<h3 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#CC3333; margin-top:16px; margin-bottom:8px; font-size:14px;`"><span style=`"$badgeRed`">REVOKED</span> ($($revoked.Count))</h3>")
                [void]$html.AppendLine("<table style=`"$tableStyle`">")
                [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Account ID', 'Email', 'Entitlements Revoked')))

                $rowIdx = 0
                foreach ($entry in $revoked) {
                    $cells = @(
                        (ConvertTo-DisconnectedHtmlSafe $entry['AccountId']),
                        (ConvertTo-DisconnectedHtmlSafe $entry['AccountEmail']),
                        (ConvertTo-DisconnectedHtmlSafe ($entry['Entitlements'] -join ', '))
                    )
                    [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                    $rowIdx++
                }
                [void]$html.AppendLine('</table>')
            }
        }

        # ---------------------------------------------------------------
        # Section 5: Disabled / Enabled Accounts
        # ---------------------------------------------------------------
        if ($disabled.Count -gt 0 -or $enabled.Count -gt 0) {
            $statusTotal = $disabled.Count + $enabled.Count
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Status Changes ($statusTotal)</h2>")

            if ($disabled.Count -gt 0) {
                [void]$html.AppendLine("<h3 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#CC3333; margin-top:16px; margin-bottom:8px; font-size:14px;`"><span style=`"$badgeRed`">DISABLED</span> ($($disabled.Count))</h3>")
                [void]$html.AppendLine("<table style=`"$tableStyle`">")
                [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Account ID', 'Name', 'Email')))

                $rowIdx = 0
                foreach ($entry in $disabled) {
                    $acct = $entry['Account']
                    if ($null -eq $acct) { continue }
                    $cells = @(
                        (ConvertTo-DisconnectedHtmlSafe $acct.id),
                        (ConvertTo-DisconnectedHtmlSafe "$($acct.givenName) $($acct.familyName)"),
                        (ConvertTo-DisconnectedHtmlSafe $acct.'e-mail')
                    )
                    [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                    $rowIdx++
                }
                [void]$html.AppendLine('</table>')
            }

            if ($enabled.Count -gt 0) {
                [void]$html.AppendLine("<h3 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#FF8800; margin-top:16px; margin-bottom:8px; font-size:14px;`"><span style=`"$badgeOrange`">ENABLED</span> ($($enabled.Count))</h3>")
                [void]$html.AppendLine("<table style=`"$tableStyle`">")
                [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Account ID', 'Name', 'Email')))

                $rowIdx = 0
                foreach ($entry in $enabled) {
                    $acct = $entry['Account']
                    if ($null -eq $acct) { continue }
                    $cells = @(
                        (ConvertTo-DisconnectedHtmlSafe $acct.id),
                        (ConvertTo-DisconnectedHtmlSafe "$($acct.givenName) $($acct.familyName)"),
                        (ConvertTo-DisconnectedHtmlSafe $acct.'e-mail')
                    )
                    [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                    $rowIdx++
                }
                [void]$html.AppendLine('</table>')
            }
        }

        # ---------------------------------------------------------------
        # Section 6: Attribute Changes
        # ---------------------------------------------------------------
        if ($attrChg.Count -gt 0) {
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`"><span style=`"$badgeOrange`">CHANGED</span> Attributes ($($attrChg.Count))</h2>")
            [void]$html.AppendLine("<table style=`"$tableStyle`">")
            [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Account ID', 'Field', 'Old Value', 'New Value')))

            $rowIdx = 0
            foreach ($entry in $attrChg) {
                $cells = @(
                    (ConvertTo-DisconnectedHtmlSafe $entry['AccountId']),
                    (ConvertTo-DisconnectedHtmlSafe $entry['Field']),
                    (ConvertTo-DisconnectedHtmlSafe $entry['OldValue']),
                    (ConvertTo-DisconnectedHtmlSafe $entry['NewValue'])
                )
                [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                $rowIdx++
            }
            [void]$html.AppendLine('</table>')
        }

        # ---------------------------------------------------------------
        # No changes notice
        # ---------------------------------------------------------------
        $totalChanges = $added.Count + $removed.Count + $disabled.Count + $enabled.Count + $granted.Count + $revoked.Count + $attrChg.Count
        if ($totalChanges -eq 0) {
            [void]$html.AppendLine("<p style=`"color:#339933; font-size:14px; font-weight:bold; margin-top:24px;`">No changes detected between snapshots.</p>")
        }

        # ---------------------------------------------------------------
        # Footer
        # ---------------------------------------------------------------
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        [void]$html.AppendLine("<hr style=`"border:none; border-top:1px solid #dee2e6; margin-top:32px;`">")
        [void]$html.AppendLine("<p style=`"color:#999; font-size:11px; margin-top:8px;`">Generated by SailPoint Governance Toolkit - Disconnected App Onboarding Kit | $timestamp UTC</p>")

        # Close document
        [void]$html.AppendLine('</div>')
        [void]$html.AppendLine('</body>')
        [void]$html.AppendLine('</html>')

        # ---------------------------------------------------------------
        # Write file (UTF-8 no BOM)
        # ---------------------------------------------------------------
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($filePath, $html.ToString(), $utf8NoBom)

        Write-SPLog -Message "Delta HTML report saved to $filePath ($totalChanges change(s))" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Export-SPDisconnectedAppDeltaHtml'

        return @{
            Success = $true
            Data    = @{ FilePath = $filePath }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Export-SPDisconnectedAppDeltaHtml failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Export-SPDisconnectedAppDeltaHtml'
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPRegisteredApps {
    <#
    .SYNOPSIS
        Returns enabled disconnected app registrations from settings.json.
    .DESCRIPTION
        Reads the Applications array from the DisconnectedApps config section,
        filters to Enabled=true entries, and merges per-app settings with global
        defaults. Per-app values override global defaults for CorrelationAttribute,
        CampaignNamePrefix, and DeadlineDays.
    .PARAMETER IncludeDisabled
        If set, includes apps with Enabled=false in the results (with Enabled=$false).
    .PARAMETER ConfigPath
        Path to settings.json. Defaults to auto-resolved path.
    .OUTPUTS
        [hashtable] @{Success; Data=@([hashtable]); Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][switch]$IncludeDisabled,
        [Parameter()][string]$ConfigPath
    )

    try {
        $configParams = @{}
        if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }
        $config = Get-SPConfig @configParams

        $daConfig = $config.DisconnectedApps

        # Global defaults for per-app overridable fields
        $globalCorrelation = 'e-mail'
        if ($null -ne $daConfig.PSObject.Properties['CorrelationAttribute'] -and
            -not [string]::IsNullOrWhiteSpace($daConfig.CorrelationAttribute)) {
            $globalCorrelation = [string]$daConfig.CorrelationAttribute
        }

        $globalPrefix = 'Disconnected App Cert'
        if ($null -ne $daConfig.PSObject.Properties['DefaultCampaignNamePrefix'] -and
            -not [string]::IsNullOrWhiteSpace($daConfig.DefaultCampaignNamePrefix)) {
            $globalPrefix = [string]$daConfig.DefaultCampaignNamePrefix
        }

        $globalDeadline = 2
        if ($null -ne $daConfig.PSObject.Properties['DefaultDeadlineDays'] -and
            $null -ne $daConfig.DefaultDeadlineDays) {
            $globalDeadline = [int]$daConfig.DefaultDeadlineDays
        }

        $globalThreshold = 20
        if ($null -ne $daConfig.PSObject.Properties['AccountDeletionThresholdPct'] -and
            $null -ne $daConfig.AccountDeletionThresholdPct) {
            $globalThreshold = [int]$daConfig.AccountDeletionThresholdPct
        }

        # Read Applications array
        $apps = @()
        if ($null -ne $daConfig.PSObject.Properties['Applications']) {
            $apps = @($daConfig.Applications)
        }

        $result = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($app in $apps) {
            if ($null -eq $app) { continue }

            # Check enabled status (default to enabled if field missing)
            $enabled = $true
            if ($null -ne $app.PSObject.Properties['Enabled']) {
                $enabled = [bool]$app.Enabled
            }
            if (-not $enabled -and -not $IncludeDisabled) { continue }

            # Name is required
            $appName = ''
            if ($null -ne $app.PSObject.Properties['Name']) {
                $appName = [string]$app.Name
            }
            if ([string]::IsNullOrWhiteSpace($appName)) {
                Write-Warning "Skipping app entry with no Name"
                continue
            }

            # Merge per-app with global defaults
            $merged = @{
                Name                       = $appName
                AccountFilePath            = if ($null -ne $app.PSObject.Properties['AccountFilePath'])      { [string]$app.AccountFilePath }      else { '' }
                EntitlementFilePath         = if ($null -ne $app.PSObject.Properties['EntitlementFilePath'])  { [string]$app.EntitlementFilePath }  else { '' }
                ISCSourceId                 = if ($null -ne $app.PSObject.Properties['ISCSourceId'])          { [string]$app.ISCSourceId }          else { '' }
                CorrelationAttribute        = if ($null -ne $app.PSObject.Properties['CorrelationAttribute'] -and
                                                  -not [string]::IsNullOrWhiteSpace($app.CorrelationAttribute)) {
                                                  [string]$app.CorrelationAttribute
                                              } else { $globalCorrelation }
                CampaignNamePrefix          = if ($null -ne $app.PSObject.Properties['CampaignNamePrefix'] -and
                                                  -not [string]::IsNullOrWhiteSpace($app.CampaignNamePrefix)) {
                                                  [string]$app.CampaignNamePrefix
                                              } else { $globalPrefix }
                DeadlineDays                = if ($null -ne $app.PSObject.Properties['DeadlineDays'] -and
                                                  $null -ne $app.DeadlineDays) {
                                                  [int]$app.DeadlineDays
                                              } else { $globalDeadline }
                SlaDays                     = if ($null -ne $app.PSObject.Properties['SlaDays'] -and
                                                  $null -ne $app.SlaDays) {
                                                  [int]$app.SlaDays
                                              } else { $null }
                AccountDeletionThresholdPct = $globalThreshold
                Enabled                     = $enabled
            }

            $result.Add($merged)
        }

        return @{
            Success = $true
            Data    = $result.ToArray()
            Error   = $null
        }
    }
    catch {
        return @{
            Success = $false
            Data    = @()
            Error   = "Get-SPRegisteredApps failed: $($_.Exception.Message)"
        }
    }
}

function Initialize-SPDisconnectedAppDirectories {
    <#
    .SYNOPSIS
        Creates Imports, Snapshots, and Reports directories for registered apps.
    .DESCRIPTION
        Scaffolds the directory structure for all (or specified) registered apps:
        {ImportBasePath}/{AppName}/, {SnapshotPath}/{AppName}/, {ReportPath}/{AppName}/
    .PARAMETER AppNames
        Optional filter. If omitted, creates directories for all enabled registered apps.
    .PARAMETER ConfigPath
        Path to settings.json. Defaults to auto-resolved path.
    .OUTPUTS
        [hashtable] @{Success; Data=@{AppsProcessed; DirectoriesCreated}; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][string[]]$AppNames,
        [Parameter()][string]$ConfigPath
    )

    try {
        $configParams = @{}
        if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }
        $config = Get-SPConfig @configParams

        $daConfig     = $config.DisconnectedApps
        $importBase   = $daConfig.ImportBasePath
        $snapshotBase = $daConfig.SnapshotPath
        $reportBase   = $daConfig.ReportPath

        # Determine which app names to process
        $names = @()
        if ($AppNames -and $AppNames.Count -gt 0) {
            $names = $AppNames
        }
        else {
            $appsResult = Get-SPRegisteredApps @configParams
            if ($appsResult.Success) {
                $names = @($appsResult.Data | ForEach-Object { $_.Name })
            }
        }

        $created = [System.Collections.Generic.List[string]]::new()

        foreach ($name in $names) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $dirs = @(
                (Join-Path $importBase $name),
                (Join-Path $snapshotBase $name),
                (Join-Path $reportBase $name)
            )

            foreach ($dir in $dirs) {
                if (-not (Test-Path -Path $dir -PathType Container)) {
                    New-Item -Path $dir -ItemType Directory -Force | Out-Null
                    $created.Add($dir)
                }
            }
        }

        Write-SPLog -Message "Initialize-SPDisconnectedAppDirectories: $($names.Count) app(s), $($created.Count) director(ies) created" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Initialize-SPDisconnectedAppDirectories'

        return @{
            Success = $true
            Data    = @{
                AppsProcessed      = $names.Count
                DirectoriesCreated = $created.ToArray()
            }
            Error   = $null
        }
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Initialize-SPDisconnectedAppDirectories failed: $($_.Exception.Message)"
        }
    }
}

function Get-SPDisconnectedAppDeliveryStatus {
    <#
    .SYNOPSIS
        Checks file delivery status for all registered disconnected apps.
    .DESCRIPTION
        Examines the AccountFilePath for each registered app and classifies
        its delivery status:
        - Delivered: file exists, modified within StaleHours
        - Stale: file exists, modified more than StaleHours ago
        - Missing: file path does not exist
        - Disabled: app is registered but Enabled=false
        - Error: file exists but is empty or unreadable

        For Delivered and Stale files, RowCount is populated via a quick
        Import-Csv | Measure-Object (no full validation).
    .PARAMETER StaleHours
        Number of hours after which a file is considered stale. Default: 24.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .PARAMETER ConfigPath
        Path to settings.json. Defaults to auto-resolved path.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Apps = @(
                    @{ Name; Status; LastModified; FileSize; RowCount; FilePath; ErrorDetail }
                )
                Summary = @{ Total; Delivered; Stale; Missing; Disabled; Error }
            }
            Error = $string
        }
    .EXAMPLE
        $status = Get-SPDisconnectedAppDeliveryStatus -StaleHours 24
        $status.Data.Apps | Format-Table Name, Status, RowCount
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [int]$StaleHours = 24,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPDisconnectedAppDeliveryStatus: Checking file delivery (StaleHours=$StaleHours)" `
        -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Get-SPDisconnectedAppDeliveryStatus' `
        -CorrelationID $CorrelationID

    try {
        # Get all registered apps including disabled
        $configParams = @{ IncludeDisabled = $true }
        if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }
        $appsResult = Get-SPRegisteredApps @configParams

        if (-not $appsResult.Success) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Failed to load registered apps: $($appsResult.Error)"
            }
        }

        $apps = @($appsResult.Data)
        $cutoff = (Get-Date).AddHours(-$StaleHours)

        $appStatuses = [System.Collections.Generic.List[hashtable]]::new()
        $summaryCounters = @{
            Total     = $apps.Count
            Delivered = 0
            Stale     = 0
            Missing   = 0
            Disabled  = 0
            Error     = 0
        }

        foreach ($app in $apps) {
            $appName  = $app.Name
            $filePath = $app.AccountFilePath

            # Disabled apps
            if (-not $app.Enabled) {
                $appStatuses.Add(@{
                    Name         = $appName
                    Status       = 'Disabled'
                    LastModified = $null
                    FileSize     = $null
                    RowCount     = $null
                    FilePath     = $filePath
                    ErrorDetail  = $null
                })
                $summaryCounters['Disabled']++
                continue
            }

            # Missing file path or file does not exist
            if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -Path $filePath -PathType Leaf)) {
                $appStatuses.Add(@{
                    Name         = $appName
                    Status       = 'Missing'
                    LastModified = $null
                    FileSize     = $null
                    RowCount     = $null
                    FilePath     = $filePath
                    ErrorDetail  = $null
                })
                $summaryCounters['Missing']++
                Write-SPLog -Message "App '$appName': file missing at '$filePath'" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppDeliveryStatus' -CorrelationID $CorrelationID
                continue
            }

            # File exists -- check if readable and non-empty
            try {
                $fileInfo = Get-Item -Path $filePath -ErrorAction Stop
                $lastModified = $fileInfo.LastWriteTimeUtc

                if ($fileInfo.Length -eq 0) {
                    $appStatuses.Add(@{
                        Name         = $appName
                        Status       = 'Error'
                        LastModified = $lastModified.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        FileSize     = 0
                        RowCount     = 0
                        FilePath     = $filePath
                        ErrorDetail  = 'File is empty (0 bytes)'
                    })
                    $summaryCounters['Error']++
                    Write-SPLog -Message "App '$appName': file is empty at '$filePath'" `
                        -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                        -Action 'Get-SPDisconnectedAppDeliveryStatus' -CorrelationID $CorrelationID
                    continue
                }

                # Quick row count via Import-Csv
                $rowCount = 0
                try {
                    $rowCount = @(Import-Csv -Path $filePath -ErrorAction Stop).Count
                }
                catch {
                    $appStatuses.Add(@{
                        Name         = $appName
                        Status       = 'Error'
                        LastModified = $lastModified.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        FileSize     = $fileInfo.Length
                        RowCount     = $null
                        FilePath     = $filePath
                        ErrorDetail  = "File unreadable as CSV: $($_.Exception.Message)"
                    })
                    $summaryCounters['Error']++
                    Write-SPLog -Message "App '$appName': CSV parse error at '$filePath': $($_.Exception.Message)" `
                        -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                        -Action 'Get-SPDisconnectedAppDeliveryStatus' -CorrelationID $CorrelationID
                    continue
                }

                # Classify as Delivered or Stale based on last modification time
                $status = if ($lastModified -ge $cutoff) { 'Delivered' } else { 'Stale' }

                $appStatuses.Add(@{
                    Name         = $appName
                    Status       = $status
                    LastModified = $lastModified.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    FileSize     = $fileInfo.Length
                    RowCount     = $rowCount
                    FilePath     = $filePath
                    ErrorDetail  = $null
                })
                $summaryCounters[$status]++

                Write-SPLog -Message "App '$appName': $status (rows=$rowCount, modified=$($lastModified.ToString('yyyy-MM-dd HH:mm')))" `
                    -Severity $(if ($status -eq 'Stale') { 'WARN' } else { 'INFO' }) `
                    -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppDeliveryStatus' -CorrelationID $CorrelationID
            }
            catch {
                $appStatuses.Add(@{
                    Name         = $appName
                    Status       = 'Error'
                    LastModified = $null
                    FileSize     = $null
                    RowCount     = $null
                    FilePath     = $filePath
                    ErrorDetail  = "File access error: $($_.Exception.Message)"
                })
                $summaryCounters['Error']++
                Write-SPLog -Message "App '$appName': file access error at '$filePath': $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppDeliveryStatus' -CorrelationID $CorrelationID
            }
        }

        Write-SPLog -Message "Delivery status: $($summaryCounters['Delivered']) delivered, $($summaryCounters['Stale']) stale, $($summaryCounters['Missing']) missing, $($summaryCounters['Disabled']) disabled, $($summaryCounters['Error']) error (of $($apps.Count) total)" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Get-SPDisconnectedAppDeliveryStatus' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Apps    = $appStatuses.ToArray()
                Summary = $summaryCounters
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPDisconnectedAppDeliveryStatus failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Get-SPDisconnectedAppDeliveryStatus' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Resolve-SPDisconnectedAppIdentities',
    'Invoke-SPDisconnectedAppCertRun',
    'Export-SPDisconnectedAppDeltaHtml',
    'Get-SPRegisteredApps',
    'Initialize-SPDisconnectedAppDirectories',
    'Get-SPDisconnectedAppDeliveryStatus'
)

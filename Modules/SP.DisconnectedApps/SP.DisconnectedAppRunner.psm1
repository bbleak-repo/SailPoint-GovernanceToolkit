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
        7. Get-SPDisconnectedAppIdentityRisk - cross-app identity risk analysis
        8. Export-SPDisconnectedAppIdentityRiskHtml - identity risk HTML report
        9. Get-SPDisconnectedAppEntitlementCatalog - unified entitlement catalog across apps
       10. Export-SPDisconnectedAppEntitlementCatalogHtml - entitlement catalog HTML report
       11. Export-SPDisconnectedAppBatchHtml - batch orchestrator summary HTML report
       12. Get-SPDisconnectedAppSlaStatus - 30-day SLA tracking from snapshot history
       13. Export-SPDisconnectedAppSlaHtml - SLA compliance HTML report with delivery grid
       14. Get-SPDisconnectedAppCampaignDecisions - harvests campaign decisions from ISC
       15. Export-SPDisconnectedAppDecisionHarvestHtml - decision harvest HTML report
       16. Send-SPDisconnectedAppAlert - operational alerting for pipeline events

    Dependencies:
        - SP.Api (Invoke-SPApiRequest)
        - SP.Campaigns (New-SPCampaign, Start-SPCampaign, Search-SPCampaigns)
        - SP.DeltaCertRunner (Build-SPDeltaSearchFilter)
        - SP.DeltaCertQueries (Get-SPDeltaIdentityDetail, Group-SPDeltaByManager)
        - SP.Core (Write-SPLog, Get-SPConfig)

.NOTES
    Module: SP.DisconnectedAppRunner
    Version: 1.7.0
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

function Get-SPDisconnectedAppIdentityRisk {
    <#
    .SYNOPSIS
        Identifies identities appearing across multiple disconnected apps.
    .DESCRIPTION
        Reads the latest account snapshot from each registered app and builds
        an identity map keyed by the correlation attribute (email). Identities
        found in multiple apps receive a risk classification:
        - Normal: 1 app
        - Elevated: 2 apps
        - High: 3+ apps

        Results are sorted by app count descending (highest risk first).
        Only reads local snapshot files -- no ISC API calls.
    .PARAMETER CorrelationAttribute
        CSV column used to correlate identities across apps. Default: 'e-mail'.
    .PARAMETER SnapshotDir
        Root snapshot directory. Defaults to config SnapshotPath.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .PARAMETER ConfigPath
        Path to settings.json. Defaults to auto-resolved path.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Identities = @(
                    @{ Email; Name; Apps; AppCount; Risk }
                )
                Summary = @{ TotalIdentities; SingleApp; MultiApp; HighRisk }
            }
            Error = $string
        }
    .EXAMPLE
        $risk = Get-SPDisconnectedAppIdentityRisk
        $risk.Data.Identities | Where-Object { $_.Risk -eq 'High' } | Format-Table
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CorrelationAttribute = 'e-mail',

        [Parameter()]
        [string]$SnapshotDir,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPDisconnectedAppIdentityRisk: Starting cross-app identity risk analysis" `
        -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Get-SPDisconnectedAppIdentityRisk' `
        -CorrelationID $CorrelationID

    try {
        # Load config for snapshot path if not provided
        if ([string]::IsNullOrWhiteSpace($SnapshotDir)) {
            $configParams = @{}
            if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }
            $config = Get-SPConfig @configParams
            $SnapshotDir = $config.DisconnectedApps.SnapshotPath
        }

        # Get registered apps
        $configParams = @{}
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
        if ($apps.Count -eq 0) {
            return @{
                Success = $true
                Data    = @{
                    Identities = @()
                    Summary    = @{ TotalIdentities = 0; SingleApp = 0; MultiApp = 0; HighRisk = 0 }
                }
                Error   = $null
            }
        }

        # Build identity map: email -> @{ Name; Apps = List[string] }
        $identityMap = @{}

        foreach ($app in $apps) {
            $appName = $app.Name
            $appDir  = Join-Path -Path $SnapshotDir -ChildPath $appName

            if (-not (Test-Path -Path $appDir -PathType Container)) {
                Write-SPLog -Message "App '$appName': no snapshot directory at '$appDir' -- skipping" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppIdentityRisk' -CorrelationID $CorrelationID
                continue
            }

            # Find latest accounts snapshot (descending sort by filename = date)
            $snapshots = @(Get-ChildItem -Path $appDir -Filter '*-accounts.csv' -File |
                Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-accounts\.csv$' } |
                Sort-Object -Property Name -Descending)

            if ($snapshots.Count -eq 0) {
                Write-SPLog -Message "App '$appName': no account snapshots found -- skipping" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppIdentityRisk' -CorrelationID $CorrelationID
                continue
            }

            $latestSnapshot = $snapshots[0].FullName

            Write-SPLog -Message "App '$appName': loading snapshot '$($snapshots[0].Name)'" `
                -Severity DEBUG -Component 'SP.DisconnectedAppRunner' `
                -Action 'Get-SPDisconnectedAppIdentityRisk' -CorrelationID $CorrelationID

            try {
                $rows = @(Import-Csv -Path $latestSnapshot -ErrorAction Stop)
            }
            catch {
                Write-SPLog -Message "App '$appName': failed to parse snapshot '$latestSnapshot': $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppIdentityRisk' -CorrelationID $CorrelationID
                continue
            }

            # Check that the correlation column exists
            if ($rows.Count -gt 0 -and $null -eq $rows[0].PSObject.Properties[$CorrelationAttribute]) {
                Write-SPLog -Message "App '$appName': snapshot missing column '$CorrelationAttribute' -- skipping" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppIdentityRisk' -CorrelationID $CorrelationID
                continue
            }

            foreach ($row in $rows) {
                $email = ''
                if ($null -ne $row.PSObject.Properties[$CorrelationAttribute]) {
                    $email = [string]$row.$CorrelationAttribute
                }
                if ([string]::IsNullOrWhiteSpace($email)) { continue }

                $emailKey = $email.Trim().ToLower()

                # Build display name from givenName + familyName if available
                $displayName = ''
                if ($null -ne $row.PSObject.Properties['givenName'] -and
                    $null -ne $row.PSObject.Properties['familyName']) {
                    $gn = [string]$row.givenName
                    $fn = [string]$row.familyName
                    if (-not [string]::IsNullOrWhiteSpace($gn) -or -not [string]::IsNullOrWhiteSpace($fn)) {
                        $displayName = ("$gn $fn").Trim()
                    }
                }

                if (-not $identityMap.ContainsKey($emailKey)) {
                    $identityMap[$emailKey] = @{
                        Email = $email.Trim()
                        Name  = $displayName
                        Apps  = [System.Collections.Generic.List[string]]::new()
                    }
                }

                # Update name if we have a better one (non-empty)
                if (-not [string]::IsNullOrWhiteSpace($displayName) -and
                    [string]::IsNullOrWhiteSpace($identityMap[$emailKey].Name)) {
                    $identityMap[$emailKey].Name = $displayName
                }

                # Add app if not already listed (handles duplicate emails within one file)
                if ($appName -notin $identityMap[$emailKey].Apps) {
                    $identityMap[$emailKey].Apps.Add($appName)
                }
            }

            Write-SPLog -Message "App '$appName': processed $($rows.Count) account(s)" `
                -Severity INFO -Component 'SP.DisconnectedAppRunner' `
                -Action 'Get-SPDisconnectedAppIdentityRisk' -CorrelationID $CorrelationID
        }

        # Build result list sorted by app count descending
        $identities = [System.Collections.Generic.List[hashtable]]::new()
        $singleApp = 0
        $multiApp  = 0
        $highRisk  = 0

        foreach ($key in $identityMap.Keys) {
            $entry    = $identityMap[$key]
            $appCount = $entry.Apps.Count
            $risk     = switch ($appCount) {
                1       { 'Normal' }
                2       { 'Elevated' }
                default { 'High' }
            }

            $identities.Add(@{
                Email    = $entry.Email
                Name     = $entry.Name
                Apps     = @($entry.Apps)
                AppCount = $appCount
                Risk     = $risk
            })

            if ($appCount -eq 1)     { $singleApp++ }
            elseif ($appCount -eq 2) { $multiApp++ }
            else                     { $multiApp++; $highRisk++ }
        }

        # Sort by AppCount descending, then by Email ascending
        $sorted = @($identities | Sort-Object -Property @(
            @{ Expression = { $_.AppCount }; Descending = $true },
            @{ Expression = { $_.Email };    Descending = $false }
        ))

        $totalIdentities = $sorted.Count

        Write-SPLog -Message "Cross-app identity risk: $totalIdentities total, $singleApp single-app, $multiApp multi-app, $highRisk high-risk" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Get-SPDisconnectedAppIdentityRisk' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Identities = $sorted
                Summary    = @{
                    TotalIdentities = $totalIdentities
                    SingleApp       = $singleApp
                    MultiApp        = $multiApp
                    HighRisk        = $highRisk
                }
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPDisconnectedAppIdentityRisk failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Get-SPDisconnectedAppIdentityRisk' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Export-SPDisconnectedAppIdentityRiskHtml {
    <#
    .SYNOPSIS
        Generates an HTML report of cross-app identity risk findings.
    .DESCRIPTION
        Takes the output of Get-SPDisconnectedAppIdentityRisk and produces a
        self-contained HTML report with:
        - Executive summary with risk distribution counts
        - Identity risk table sorted by app count descending
        - Risk-level color coding (green=Normal, orange=Elevated, red=High)

        Uses 100% inline CSS for Word paste compatibility.
    .PARAMETER RiskResult
        The .Data hashtable from Get-SPDisconnectedAppIdentityRisk.
    .PARAMETER OutputPath
        Directory where the report is saved. File: identity-risk-{YYYY-MM-DD}.html
    .PARAMETER ReportDate
        Date stamp for the filename and header. Defaults to today.
    .OUTPUTS
        [hashtable] @{Success; Data=@{FilePath}; Error}
    .EXAMPLE
        $risk = Get-SPDisconnectedAppIdentityRisk
        Export-SPDisconnectedAppIdentityRiskHtml -RiskResult $risk.Data -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$RiskResult,

        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [string]$ReportDate
    )

    if ([string]::IsNullOrWhiteSpace($ReportDate)) {
        $ReportDate = Get-Date -Format 'yyyy-MM-dd'
    }

    try {
        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        $filePath = Join-Path -Path $OutputPath -ChildPath "identity-risk-${ReportDate}.html"

        $identities = @()
        if ($null -ne $RiskResult['Identities']) { $identities = @($RiskResult['Identities']) }
        $summary = if ($null -ne $RiskResult['Summary']) { $RiskResult['Summary'] } else { @{} }

        $totalIdentities = if ($null -ne $summary['TotalIdentities']) { $summary['TotalIdentities'] } else { 0 }
        $singleApp       = if ($null -ne $summary['SingleApp'])       { $summary['SingleApp'] }       else { 0 }
        $multiApp        = if ($null -ne $summary['MultiApp'])        { $summary['MultiApp'] }        else { 0 }
        $highRisk        = if ($null -ne $summary['HighRisk'])        { $summary['HighRisk'] }        else { 0 }

        # Style constants (reuse from existing HTML patterns)
        $sectionHeadingStyle = 'font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;'
        $labelTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; font-weight:bold; width:220px; background:#f4f4f4; vertical-align:top;'
        $valueTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;'
        $tableStyle          = 'width:100%; border-collapse:collapse; margin-bottom:18px; font-size:13px; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif;'
        $badgeGreen          = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#339933;'
        $badgeRed            = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#CC3333;'
        $badgeOrange         = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#FF8800;'

        $html = [System.Text.StringBuilder]::new(8192)

        # Document shell
        [void]$html.AppendLine('<!DOCTYPE html>')
        [void]$html.AppendLine('<html lang="en">')
        [void]$html.AppendLine('<head>')
        [void]$html.AppendLine('    <meta charset="UTF-8">')
        [void]$html.AppendLine('    <meta name="viewport" content="width=device-width, initial-scale=1.0">')
        [void]$html.AppendLine("    <title>Cross-App Identity Risk Report - $ReportDate</title>")
        [void]$html.AppendLine('</head>')
        [void]$html.AppendLine('<body style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">')
        [void]$html.AppendLine('<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">')

        # Title
        [void]$html.AppendLine("<h1 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin-top:0; margin-bottom:4px; font-size:22px;`">Cross-App Identity Risk Report</h1>")
        [void]$html.AppendLine("<p style=`"color:#777; font-size:13px; margin-top:0; margin-bottom:20px;`">Report date: $ReportDate</p>")

        # Section 1: Executive Summary
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Executive Summary</h2>")
        [void]$html.AppendLine("<table style=`"$tableStyle`">")

        $summaryRows = @(
            @('Total Unique Identities', $totalIdentities),
            @('Single-App Identities',   $singleApp),
            @('Multi-App Identities',    $multiApp),
            @('High Risk (3+ Apps)',      $highRisk)
        )

        foreach ($row in $summaryRows) {
            $label = ConvertTo-DisconnectedHtmlSafe $row[0]
            $value = ConvertTo-DisconnectedHtmlSafe $row[1]
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        # Section 2: Identity Risk Table (only multi-app identities, or all if few)
        $multiAppIdentities = @($identities | Where-Object { $_.AppCount -gt 1 })

        if ($multiAppIdentities.Count -gt 0) {
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Multi-App Identities ($($multiAppIdentities.Count))</h2>")
            [void]$html.AppendLine("<table style=`"$tableStyle`">")
            [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Email', 'Name', 'Apps', 'App Count', 'Risk')))

            $rowIdx = 0
            foreach ($identity in $multiAppIdentities) {
                $riskBadge = switch ($identity.Risk) {
                    'High'     { "<span style=`"$badgeRed`">HIGH</span>" }
                    'Elevated' { "<span style=`"$badgeOrange`">ELEVATED</span>" }
                    default    { "<span style=`"$badgeGreen`">NORMAL</span>" }
                }

                $cells = @(
                    (ConvertTo-DisconnectedHtmlSafe $identity.Email),
                    (ConvertTo-DisconnectedHtmlSafe $identity.Name),
                    (ConvertTo-DisconnectedHtmlSafe ($identity.Apps -join ', ')),
                    (ConvertTo-DisconnectedHtmlSafe $identity.AppCount),
                    $riskBadge
                )
                [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                $rowIdx++
            }
            [void]$html.AppendLine('</table>')
        }
        else {
            [void]$html.AppendLine("<p style=`"color:#339933; font-size:14px; font-weight:bold; margin-top:24px;`">No multi-app identities found. All identities appear in only one disconnected app.</p>")
        }

        # Section 3: Full identity list (if total is manageable, <= 500)
        if ($identities.Count -gt 0 -and $identities.Count -le 500) {
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">All Identities ($($identities.Count))</h2>")
            [void]$html.AppendLine("<table style=`"$tableStyle`">")
            [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Email', 'Name', 'Apps', 'App Count', 'Risk')))

            $rowIdx = 0
            foreach ($identity in $identities) {
                $riskBadge = switch ($identity.Risk) {
                    'High'     { "<span style=`"$badgeRed`">HIGH</span>" }
                    'Elevated' { "<span style=`"$badgeOrange`">ELEVATED</span>" }
                    default    { "<span style=`"$badgeGreen`">NORMAL</span>" }
                }

                $cells = @(
                    (ConvertTo-DisconnectedHtmlSafe $identity.Email),
                    (ConvertTo-DisconnectedHtmlSafe $identity.Name),
                    (ConvertTo-DisconnectedHtmlSafe ($identity.Apps -join ', ')),
                    (ConvertTo-DisconnectedHtmlSafe $identity.AppCount),
                    $riskBadge
                )
                [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                $rowIdx++
            }
            [void]$html.AppendLine('</table>')
        }
        elseif ($identities.Count -gt 500) {
            [void]$html.AppendLine("<p style=`"color:#777; font-size:13px; margin-top:16px;`">Full identity list omitted ($($identities.Count) identities exceeds display limit of 500). Multi-app identities are shown above.</p>")
        }

        # Footer
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        [void]$html.AppendLine("<hr style=`"border:none; border-top:1px solid #dee2e6; margin-top:32px;`">")
        [void]$html.AppendLine("<p style=`"color:#999; font-size:11px; margin-top:8px;`">Generated by SailPoint Governance Toolkit - Cross-App Identity Risk Analysis | $timestamp UTC</p>")

        # Close document
        [void]$html.AppendLine('</div>')
        [void]$html.AppendLine('</body>')
        [void]$html.AppendLine('</html>')

        # Write file (UTF-8 no BOM)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($filePath, $html.ToString(), $utf8NoBom)

        Write-SPLog -Message "Identity risk HTML report saved to $filePath ($($identities.Count) identit(ies))" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Export-SPDisconnectedAppIdentityRiskHtml'

        return @{
            Success = $true
            Data    = @{ FilePath = $filePath }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Export-SPDisconnectedAppIdentityRiskHtml failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Export-SPDisconnectedAppIdentityRiskHtml'
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPDisconnectedAppEntitlementCatalog {
    <#
    .SYNOPSIS
        Aggregates entitlements from all registered apps into a unified catalog.
    .DESCRIPTION
        Reads the latest entitlement snapshot from each registered app and builds
        a unified searchable catalog. For each entitlement, calculates AssignedCount
        by counting how many accounts in the latest account snapshot reference it
        via the groups column.

        Only reads local snapshot files -- no ISC API calls.
        Apps with no entitlement snapshot are skipped gracefully.
    .PARAMETER SnapshotDir
        Root snapshot directory. Defaults to config SnapshotPath.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .PARAMETER ConfigPath
        Path to settings.json. Defaults to auto-resolved path.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Catalog = @(
                    @{ AppName; EntitlementId; DisplayName; Description; AssignedCount }
                )
                Summary = @{ TotalEntitlements; TotalApps; AppsSkipped }
            }
            Error = $string
        }
    .EXAMPLE
        $catalog = Get-SPDisconnectedAppEntitlementCatalog
        $catalog.Data.Catalog | Format-Table AppName, EntitlementId, DisplayName, AssignedCount
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$SnapshotDir,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPDisconnectedAppEntitlementCatalog: Starting unified entitlement catalog build" `
        -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Get-SPDisconnectedAppEntitlementCatalog' `
        -CorrelationID $CorrelationID

    try {
        # Load config for snapshot path if not provided
        if ([string]::IsNullOrWhiteSpace($SnapshotDir)) {
            $configParams = @{}
            if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }
            $config = Get-SPConfig @configParams
            $SnapshotDir = $config.DisconnectedApps.SnapshotPath
        }

        # Get registered apps
        $configParams = @{}
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
        if ($apps.Count -eq 0) {
            return @{
                Success = $true
                Data    = @{
                    Catalog = @()
                    Summary = @{ TotalEntitlements = 0; TotalApps = 0; AppsSkipped = 0 }
                }
                Error   = $null
            }
        }

        $catalog     = [System.Collections.Generic.List[hashtable]]::new()
        $totalApps   = 0
        $appsSkipped = 0

        foreach ($app in $apps) {
            $appName = $app.Name
            $appDir  = Join-Path -Path $SnapshotDir -ChildPath $appName

            if (-not (Test-Path -Path $appDir -PathType Container)) {
                Write-SPLog -Message "App '$appName': no snapshot directory at '$appDir' -- skipping" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppEntitlementCatalog' -CorrelationID $CorrelationID
                $appsSkipped++
                continue
            }

            # Find latest entitlements snapshot
            $entSnapshots = @(Get-ChildItem -Path $appDir -Filter '*-entitlements.csv' -File |
                Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-entitlements\.csv$' } |
                Sort-Object -Property Name -Descending)

            if ($entSnapshots.Count -eq 0) {
                Write-SPLog -Message "App '$appName': no entitlement snapshots found -- skipping" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppEntitlementCatalog' -CorrelationID $CorrelationID
                $appsSkipped++
                continue
            }

            $latestEntPath = $entSnapshots[0].FullName

            Write-SPLog -Message "App '$appName': loading entitlement snapshot '$($entSnapshots[0].Name)'" `
                -Severity DEBUG -Component 'SP.DisconnectedAppRunner' `
                -Action 'Get-SPDisconnectedAppEntitlementCatalog' -CorrelationID $CorrelationID

            try {
                $entRows = @(Import-Csv -Path $latestEntPath -ErrorAction Stop)
            }
            catch {
                Write-SPLog -Message "App '$appName': failed to parse entitlement snapshot: $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppEntitlementCatalog' -CorrelationID $CorrelationID
                $appsSkipped++
                continue
            }

            if ($entRows.Count -eq 0) {
                Write-SPLog -Message "App '$appName': entitlement snapshot is empty -- skipping" `
                    -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                    -Action 'Get-SPDisconnectedAppEntitlementCatalog' -CorrelationID $CorrelationID
                $appsSkipped++
                continue
            }

            # Build assignment count map from the latest accounts snapshot
            $assignmentCounts = @{}

            $acctSnapshots = @(Get-ChildItem -Path $appDir -Filter '*-accounts.csv' -File |
                Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-accounts\.csv$' } |
                Sort-Object -Property Name -Descending)

            if ($acctSnapshots.Count -gt 0) {
                try {
                    $acctRows = @(Import-Csv -Path $acctSnapshots[0].FullName -ErrorAction Stop)

                    foreach ($acct in $acctRows) {
                        $groupsRaw = $acct.groups
                        if ([string]::IsNullOrWhiteSpace($groupsRaw)) { continue }

                        $groupList = @($groupsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                        foreach ($g in $groupList) {
                            if ($assignmentCounts.ContainsKey($g)) {
                                $assignmentCounts[$g]++
                            }
                            else {
                                $assignmentCounts[$g] = 1
                            }
                        }
                    }

                    Write-SPLog -Message "App '$appName': built assignment counts from $($acctRows.Count) account(s)" `
                        -Severity DEBUG -Component 'SP.DisconnectedAppRunner' `
                        -Action 'Get-SPDisconnectedAppEntitlementCatalog' -CorrelationID $CorrelationID
                }
                catch {
                    Write-SPLog -Message "App '$appName': failed to parse account snapshot for assignment counts: $($_.Exception.Message)" `
                        -Severity WARN -Component 'SP.DisconnectedAppRunner' `
                        -Action 'Get-SPDisconnectedAppEntitlementCatalog' -CorrelationID $CorrelationID
                    # Continue without assignment counts -- they'll all be 0
                }
            }

            # Build catalog entries from entitlement rows
            foreach ($ent in $entRows) {
                $entId = ''
                if ($null -ne $ent.PSObject.Properties['id']) {
                    $entId = [string]$ent.id
                }
                if ([string]::IsNullOrWhiteSpace($entId)) { continue }

                $displayName = ''
                if ($null -ne $ent.PSObject.Properties['displayName']) {
                    $displayName = [string]$ent.displayName
                }

                $description = ''
                if ($null -ne $ent.PSObject.Properties['description']) {
                    $description = [string]$ent.description
                }

                $name = ''
                if ($null -ne $ent.PSObject.Properties['name']) {
                    $name = [string]$ent.name
                }

                $assignedCount = 0
                if ($assignmentCounts.ContainsKey($entId)) {
                    $assignedCount = $assignmentCounts[$entId]
                }
                # Also check by name if id didn't match (groups column may use name)
                if ($assignedCount -eq 0 -and -not [string]::IsNullOrWhiteSpace($name) -and
                    $name -ne $entId -and $assignmentCounts.ContainsKey($name)) {
                    $assignedCount = $assignmentCounts[$name]
                }

                $catalog.Add(@{
                    AppName       = $appName
                    EntitlementId = $entId
                    Name          = $name
                    DisplayName   = $displayName
                    Description   = $description
                    AssignedCount = $assignedCount
                })
            }

            $totalApps++
            Write-SPLog -Message "App '$appName': added $($entRows.Count) entitlement(s) to catalog" `
                -Severity INFO -Component 'SP.DisconnectedAppRunner' `
                -Action 'Get-SPDisconnectedAppEntitlementCatalog' -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Entitlement catalog: $($catalog.Count) entitlement(s) from $totalApps app(s), $appsSkipped skipped" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Get-SPDisconnectedAppEntitlementCatalog' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Catalog = $catalog.ToArray()
                Summary = @{
                    TotalEntitlements = $catalog.Count
                    TotalApps         = $totalApps
                    AppsSkipped       = $appsSkipped
                }
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPDisconnectedAppEntitlementCatalog failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Get-SPDisconnectedAppEntitlementCatalog' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Export-SPDisconnectedAppEntitlementCatalogHtml {
    <#
    .SYNOPSIS
        Generates an HTML report of the unified entitlement catalog.
    .DESCRIPTION
        Takes the output of Get-SPDisconnectedAppEntitlementCatalog and produces a
        self-contained HTML report with:
        - Executive summary with total entitlements and app counts
        - Per-app entitlement tables grouped by application
        - Assignment count color coding (high=red, medium=orange, low=green)

        Uses 100% inline CSS for Word paste compatibility.
    .PARAMETER CatalogResult
        The .Data hashtable from Get-SPDisconnectedAppEntitlementCatalog.
    .PARAMETER OutputPath
        Directory where the report is saved. File: entitlement-catalog-{YYYY-MM-DD}.html
    .PARAMETER ReportDate
        Date stamp for the filename and header. Defaults to today.
    .OUTPUTS
        [hashtable] @{Success; Data=@{FilePath}; Error}
    .EXAMPLE
        $catalog = Get-SPDisconnectedAppEntitlementCatalog
        Export-SPDisconnectedAppEntitlementCatalogHtml -CatalogResult $catalog.Data -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$CatalogResult,

        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [string]$ReportDate
    )

    if ([string]::IsNullOrWhiteSpace($ReportDate)) {
        $ReportDate = Get-Date -Format 'yyyy-MM-dd'
    }

    try {
        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        $filePath = Join-Path -Path $OutputPath -ChildPath "entitlement-catalog-${ReportDate}.html"

        $catalogEntries = @()
        if ($null -ne $CatalogResult['Catalog']) { $catalogEntries = @($CatalogResult['Catalog']) }
        $summary = if ($null -ne $CatalogResult['Summary']) { $CatalogResult['Summary'] } else { @{} }

        $totalEntitlements = if ($null -ne $summary['TotalEntitlements']) { $summary['TotalEntitlements'] } else { 0 }
        $totalApps         = if ($null -ne $summary['TotalApps'])         { $summary['TotalApps'] }         else { 0 }
        $appsSkipped       = if ($null -ne $summary['AppsSkipped'])       { $summary['AppsSkipped'] }       else { 0 }

        # Style constants
        $sectionHeadingStyle = 'font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;'
        $labelTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; font-weight:bold; width:220px; background:#f4f4f4; vertical-align:top;'
        $valueTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;'
        $tableStyle          = 'width:100%; border-collapse:collapse; margin-bottom:18px; font-size:13px; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif;'
        $badgeGreen          = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#339933;'
        $badgeRed            = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#CC3333;'
        $badgeOrange         = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#FF8800;'
        $appHeadingStyle     = 'font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#336699; margin-top:20px; margin-bottom:8px; font-size:15px;'

        $html = [System.Text.StringBuilder]::new(8192)

        # Document shell
        [void]$html.AppendLine('<!DOCTYPE html>')
        [void]$html.AppendLine('<html lang="en">')
        [void]$html.AppendLine('<head>')
        [void]$html.AppendLine('    <meta charset="UTF-8">')
        [void]$html.AppendLine('    <meta name="viewport" content="width=device-width, initial-scale=1.0">')
        [void]$html.AppendLine("    <title>Unified Entitlement Catalog - $ReportDate</title>")
        [void]$html.AppendLine('</head>')
        [void]$html.AppendLine('<body style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">')
        [void]$html.AppendLine('<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">')

        # Title
        [void]$html.AppendLine("<h1 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin-top:0; margin-bottom:4px; font-size:22px;`">Unified Entitlement Catalog</h1>")
        [void]$html.AppendLine("<p style=`"color:#777; font-size:13px; margin-top:0; margin-bottom:20px;`">Report date: $ReportDate</p>")

        # Section 1: Executive Summary
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Executive Summary</h2>")
        [void]$html.AppendLine("<table style=`"$tableStyle`">")

        $summaryRows = @(
            @('Total Entitlements',      $totalEntitlements),
            @('Applications Included',   $totalApps),
            @('Applications Skipped',    $appsSkipped)
        )

        foreach ($row in $summaryRows) {
            $label = ConvertTo-DisconnectedHtmlSafe $row[0]
            $value = ConvertTo-DisconnectedHtmlSafe $row[1]
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        # Section 2: Entitlement tables grouped by app
        if ($catalogEntries.Count -gt 0) {
            # Group entries by AppName
            $appGroups = [ordered]@{}
            foreach ($entry in $catalogEntries) {
                $aName = $entry.AppName
                if (-not $appGroups.Contains($aName)) {
                    $appGroups[$aName] = [System.Collections.Generic.List[hashtable]]::new()
                }
                $appGroups[$aName].Add($entry)
            }

            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Entitlements by Application</h2>")

            foreach ($aName in $appGroups.Keys) {
                $entries = $appGroups[$aName]
                $safeAppName = ConvertTo-DisconnectedHtmlSafe $aName

                [void]$html.AppendLine("<h3 style=`"$appHeadingStyle`">$safeAppName ($($entries.Count) entitlement(s))</h3>")
                [void]$html.AppendLine("<table style=`"$tableStyle`">")
                [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Entitlement ID', 'Display Name', 'Description', 'Assigned')))

                $rowIdx = 0
                foreach ($entry in $entries) {
                    # Color-code assignment count: 20+ = red, 10-19 = orange, 0-9 = green
                    $count = $entry.AssignedCount
                    $countBadge = if ($count -ge 20) {
                        "<span style=`"$badgeRed`">$count</span>"
                    }
                    elseif ($count -ge 10) {
                        "<span style=`"$badgeOrange`">$count</span>"
                    }
                    else {
                        "<span style=`"$badgeGreen`">$count</span>"
                    }

                    # Truncate long descriptions for display
                    $descDisplay = $entry.Description
                    if (-not [string]::IsNullOrWhiteSpace($descDisplay) -and $descDisplay.Length -gt 200) {
                        $descDisplay = $descDisplay.Substring(0, 197) + '...'
                    }

                    $cells = @(
                        (ConvertTo-DisconnectedHtmlSafe $entry.EntitlementId),
                        (ConvertTo-DisconnectedHtmlSafe $entry.DisplayName),
                        (ConvertTo-DisconnectedHtmlSafe $descDisplay),
                        $countBadge
                    )
                    [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                    $rowIdx++
                }
                [void]$html.AppendLine('</table>')
            }
        }
        else {
            [void]$html.AppendLine("<p style=`"color:#777; font-size:14px; margin-top:24px;`">No entitlements found across registered applications.</p>")
        }

        # Footer
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        [void]$html.AppendLine("<hr style=`"border:none; border-top:1px solid #dee2e6; margin-top:32px;`">")
        [void]$html.AppendLine("<p style=`"color:#999; font-size:11px; margin-top:8px;`">Generated by SailPoint Governance Toolkit - Unified Entitlement Catalog | $timestamp UTC</p>")

        # Close document
        [void]$html.AppendLine('</div>')
        [void]$html.AppendLine('</body>')
        [void]$html.AppendLine('</html>')

        # Write file (UTF-8 no BOM)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($filePath, $html.ToString(), $utf8NoBom)

        Write-SPLog -Message "Entitlement catalog HTML report saved to $filePath ($($catalogEntries.Count) entitlement(s))" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Export-SPDisconnectedAppEntitlementCatalogHtml'

        return @{
            Success = $true
            Data    = @{ FilePath = $filePath }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Export-SPDisconnectedAppEntitlementCatalogHtml failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Export-SPDisconnectedAppEntitlementCatalogHtml'
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Export-SPDisconnectedAppBatchHtml {
    <#
    .SYNOPSIS
        Generates a consolidated HTML report for a batch orchestrator run.
    .DESCRIPTION
        Takes the per-app results from Invoke-SPDisconnectedAppBatch and produces
        a self-contained HTML report with executive summary, per-app status table,
        error details, delivery status, and batch timing footer.

        Designed for operations team review after a batch certification run.

        The report uses 100% inline CSS for Microsoft Word paste compatibility.
        No external resources, no flexbox, no grid.

        Color coding:
        - Green (#339933): success
        - Red (#CC3333): error
        - Orange (#FF8800): threshold blocked
        - Gray (#999999): no changes

    .PARAMETER BatchResults
        Array of hashtables from the batch orchestrator, each containing:
        App, Status, CorrelationID, StartedAt, CompletedAt, DurationSeconds,
        CampaignsCreated, CampaignIds, IdentityCount, DeltaSummary, ReportPath,
        Error, Reason.
    .PARAMETER CorrelationID
        Batch-level correlation ID for the overall run.
    .PARAMETER StartedAt
        UTC timestamp string for batch start time.
    .PARAMETER CompletedAt
        UTC timestamp string for batch end time.
    .PARAMETER DurationSeconds
        Total batch duration in seconds.
    .PARAMETER DeliveryStatus
        Optional output from Get-SPDisconnectedAppDeliveryStatus. If provided,
        a delivery status section is included in the report.
    .PARAMETER Environment
        Environment name from config (e.g., 'Production', 'Sandbox').
    .PARAMETER WhatIfRun
        If true, the report header indicates this was a dry-run.
    .PARAMETER OutputPath
        Base directory for reports. Report is saved to
        {OutputPath}/batch-summary-{YYYY-MM-DD}.html
    .PARAMETER ReportDate
        Date stamp for the report filename and header. Defaults to today.
    .OUTPUTS
        [hashtable] @{Success; Data=@{FilePath=[string]}; Error}
    .EXAMPLE
        Export-SPDisconnectedAppBatchHtml -BatchResults $batchResults `
            -CorrelationID $batchCorrelationID -StartedAt $start -CompletedAt $end `
            -DurationSeconds 45.2 -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$BatchResults,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$StartedAt,

        [Parameter()]
        [string]$CompletedAt,

        [Parameter()]
        [double]$DurationSeconds = 0,

        [Parameter()]
        [hashtable]$DeliveryStatus,

        [Parameter()]
        [string]$Environment,

        [Parameter()]
        [switch]$WhatIfRun,

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
        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        $filePath = Join-Path -Path $OutputPath -ChildPath "batch-summary-${ReportDate}.html"

        # ---------------------------------------------------------------
        # Compute summary metrics
        # ---------------------------------------------------------------
        $totalApps      = $BatchResults.Count
        $successCount   = @($BatchResults | Where-Object { $_.Status -eq 'Success' }).Count
        $noChangesCount = @($BatchResults | Where-Object { $_.Status -eq 'NoChanges' }).Count
        $blockedCount   = @($BatchResults | Where-Object { $_.Status -eq 'ThresholdBlocked' }).Count
        $errorCount     = @($BatchResults | Where-Object { $_.Status -eq 'Error' }).Count
        $totalCampaigns = 0
        $totalIdentities = 0
        foreach ($r in $BatchResults) {
            $totalCampaigns  += $r.CampaignsCreated
            $totalIdentities += $r.IdentityCount
        }

        # ---------------------------------------------------------------
        # Reusable style constants (matching toolkit conventions)
        # ---------------------------------------------------------------
        $sectionHeadingStyle = 'font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;'
        $labelTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; font-weight:bold; width:220px; background:#f4f4f4; vertical-align:top;'
        $valueTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;'
        $tableStyle          = 'width:100%; border-collapse:collapse; margin-bottom:18px; font-size:13px; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif;'
        $badgeGreen          = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#339933;'
        $badgeRed            = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#CC3333;'
        $badgeOrange         = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#FF8800;'
        $badgeGray           = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#999999;'

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
        [void]$html.AppendLine("    <title>Batch Summary - $ReportDate</title>")
        [void]$html.AppendLine('</head>')
        [void]$html.AppendLine('<body style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">')
        [void]$html.AppendLine('<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">')

        # Report title
        $titleSuffix = ''
        if ($WhatIfRun) { $titleSuffix = ' <span style="' + $badgeOrange + '">DRY RUN</span>' }
        $envLabel = ''
        if (-not [string]::IsNullOrWhiteSpace($Environment)) {
            $envLabel = " - $(ConvertTo-DisconnectedHtmlSafe $Environment)"
        }
        [void]$html.AppendLine("<h1 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin-top:0; margin-bottom:4px; font-size:22px;`">Disconnected App Batch Summary${envLabel}${titleSuffix}</h1>")
        [void]$html.AppendLine("<p style=`"color:#777; font-size:13px; margin-top:0; margin-bottom:20px;`">Report date: $ReportDate</p>")

        # ---------------------------------------------------------------
        # Section 1: Executive Summary
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Executive Summary</h2>")

        # Overall status badge
        $overallBadge = $badgeGreen
        $overallLabel = 'ALL SUCCEEDED'
        if ($errorCount -gt 0 -and $errorCount -eq $totalApps) {
            $overallBadge = $badgeRed
            $overallLabel = 'ALL FAILED'
        }
        elseif ($errorCount -gt 0 -or $blockedCount -gt 0) {
            $overallBadge = $badgeOrange
            $overallLabel = 'PARTIAL'
        }
        elseif ($totalApps -eq 0) {
            $overallBadge = $badgeGray
            $overallLabel = 'NO APPS'
        }
        [void]$html.AppendLine("<p style=`"margin-bottom:12px;`"><span style=`"$overallBadge`">$overallLabel</span></p>")

        [void]$html.AppendLine("<table style=`"$tableStyle`">")
        $summaryRows = @(
            @('Apps Processed',     $totalApps)
            @('Succeeded',          $successCount)
            @('No Changes',         $noChangesCount)
            @('Threshold Blocked',  $blockedCount)
            @('Errors',             $errorCount)
            @('Campaigns Created',  $totalCampaigns)
            @('Identities Affected', $totalIdentities)
        )
        foreach ($row in $summaryRows) {
            $label = ConvertTo-DisconnectedHtmlSafe $row[0]
            $value = ConvertTo-DisconnectedHtmlSafe $row[1]
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        # ---------------------------------------------------------------
        # Section 2: Per-App Status Table
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Per-App Results</h2>")
        [void]$html.AppendLine("<table style=`"$tableStyle`">")
        [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('App Name', 'Status', 'Accounts (Delta)', 'Changes', 'Campaigns', 'Duration', 'Errors')))

        $rowIdx = 0
        foreach ($r in $BatchResults) {
            # Row background color by status
            $rowBg = ''
            switch ($r.Status) {
                'Success'          { $rowBg = 'background:#f0fff0;' }
                'NoChanges'        { $rowBg = 'background:#f9f9f9;' }
                'ThresholdBlocked' { $rowBg = 'background:#fff8f0;' }
                'Error'            { $rowBg = 'background:#fff0f0;' }
            }

            # Status badge
            $statusBadge = switch ($r.Status) {
                'Success'          { "<span style=`"$badgeGreen`">SUCCESS</span>" }
                'NoChanges'        { "<span style=`"$badgeGray`">NO CHANGES</span>" }
                'ThresholdBlocked' { "<span style=`"$badgeOrange`">BLOCKED</span>" }
                'Error'            { "<span style=`"$badgeRed`">ERROR</span>" }
                default            { "<span style=`"$badgeGray`">$($r.Status)</span>" }
            }

            # Delta summary
            $deltaInfo = '-'
            if ($null -ne $r.DeltaSummary -and $r.DeltaSummary.Count -gt 0) {
                $parts = @()
                if ($r.DeltaSummary.Added -gt 0)   { $parts += "+$($r.DeltaSummary.Added)" }
                if ($r.DeltaSummary.Removed -gt 0)  { $parts += "-$($r.DeltaSummary.Removed)" }
                if ($r.DeltaSummary.Enabled -gt 0)  { $parts += "~$($r.DeltaSummary.Enabled)en" }
                if ($r.DeltaSummary.Granted -gt 0)  { $parts += "~$($r.DeltaSummary.Granted)ent" }
                if ($parts.Count -gt 0) { $deltaInfo = $parts -join ' / ' }
            }

            # Changes count (campaign triggers)
            $changesCount = 0
            if ($null -ne $r.DeltaSummary) {
                $changesCount = ($r.DeltaSummary.Added + $r.DeltaSummary.Enabled + $r.DeltaSummary.Granted)
            }

            # Error text (truncated for table)
            $errorCell = '-'
            if (-not [string]::IsNullOrWhiteSpace($r.Error)) {
                $truncErr = $r.Error
                if ($truncErr.Length -gt 60) { $truncErr = $truncErr.Substring(0, 57) + '...' }
                $errorCell = ConvertTo-DisconnectedHtmlSafe $truncErr
            }

            # Duration
            $durationCell = if ($r.DurationSeconds -gt 0) { "$($r.DurationSeconds)s" } else { '-' }

            $tdStyle = "padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; $rowBg"
            [void]$html.AppendLine("<tr>")
            [void]$html.AppendLine("  <td style=`"$tdStyle font-weight:bold;`">$(ConvertTo-DisconnectedHtmlSafe $r.App)</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle`">$statusBadge</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle`">$(ConvertTo-DisconnectedHtmlSafe $deltaInfo)</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle text-align:center;`">$(ConvertTo-DisconnectedHtmlSafe $changesCount)</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle text-align:center;`">$(ConvertTo-DisconnectedHtmlSafe $r.CampaignsCreated)</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle`">$(ConvertTo-DisconnectedHtmlSafe $durationCell)</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle`">$errorCell</td>")
            [void]$html.AppendLine('</tr>')
            $rowIdx++
        }
        [void]$html.AppendLine('</table>')

        # ---------------------------------------------------------------
        # Section 3: Error Details (expandable)
        # ---------------------------------------------------------------
        $errorApps = @($BatchResults | Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'ThresholdBlocked' })

        if ($errorApps.Count -gt 0) {
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Error Details ($($errorApps.Count))</h2>")

            foreach ($errApp in $errorApps) {
                $detailBadge = if ($errApp.Status -eq 'Error') { "<span style=`"$badgeRed`">ERROR</span>" } else { "<span style=`"$badgeOrange`">THRESHOLD BLOCKED</span>" }
                $safeAppName = ConvertTo-DisconnectedHtmlSafe $errApp.App
                $safeError   = ConvertTo-DisconnectedHtmlSafe $errApp.Error

                [void]$html.AppendLine("<details style=`"margin-bottom:12px; border:1px solid #dee2e6; border-radius:4px; padding:0;`">")
                [void]$html.AppendLine("  <summary style=`"padding:10px 14px; cursor:pointer; font-weight:bold; font-size:14px; background:#f8f9fa;`">$detailBadge $safeAppName</summary>")
                [void]$html.AppendLine("  <div style=`"padding:12px 14px; font-size:13px;`">")
                [void]$html.AppendLine("    <table style=`"$tableStyle`">")

                $detailRows = @(
                    @('App Name', $errApp.App)
                    @('Status', $errApp.Status)
                    @('Reason', $errApp.Reason)
                    @('Error Message', $errApp.Error)
                    @('Correlation ID', $errApp.CorrelationID)
                    @('Started At', $errApp.StartedAt)
                    @('Completed At', $errApp.CompletedAt)
                    @('Duration', "$($errApp.DurationSeconds)s")
                )

                foreach ($dRow in $detailRows) {
                    $dLabel = ConvertTo-DisconnectedHtmlSafe $dRow[0]
                    $dValue = ConvertTo-DisconnectedHtmlSafe $dRow[1]
                    [void]$html.AppendLine("      <tr><td style=`"$labelTdStyle`">$dLabel</td><td style=`"$valueTdStyle`">$dValue</td></tr>")
                }

                [void]$html.AppendLine('    </table>')
                [void]$html.AppendLine('  </div>')
                [void]$html.AppendLine('</details>')
            }
        }

        # ---------------------------------------------------------------
        # Section 4: Delivery Status (optional)
        # ---------------------------------------------------------------
        if ($null -ne $DeliveryStatus -and $DeliveryStatus.Success -eq $true -and
            $null -ne $DeliveryStatus.Data -and $null -ne $DeliveryStatus.Data.Apps) {

            $deliveryApps = @($DeliveryStatus.Data.Apps)
            $deliverySummary = $DeliveryStatus.Data.Summary

            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">File Delivery Status</h2>")

            # Delivery summary
            if ($null -ne $deliverySummary) {
                [void]$html.AppendLine("<table style=`"$tableStyle width:auto;`">")
                $dSummaryRows = @(
                    @('Total Apps',  $deliverySummary.Total)
                    @('Delivered',   $deliverySummary.Delivered)
                    @('Stale',       $deliverySummary.Stale)
                    @('Missing',     $deliverySummary.Missing)
                    @('Disabled',    $deliverySummary.Disabled)
                )
                foreach ($ds in $dSummaryRows) {
                    $dsLabel = ConvertTo-DisconnectedHtmlSafe $ds[0]
                    $dsValue = ConvertTo-DisconnectedHtmlSafe $ds[1]
                    [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$dsLabel</td><td style=`"$valueTdStyle`">$dsValue</td></tr>")
                }
                [void]$html.AppendLine('</table>')
            }

            # Per-app delivery table
            [void]$html.AppendLine("<table style=`"$tableStyle`">")
            [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('App Name', 'Delivery Status', 'Last Modified', 'File Size', 'Row Count')))

            $dRowIdx = 0
            foreach ($dApp in $deliveryApps) {
                $dStatusBadge = switch ($dApp.Status) {
                    'Delivered' { "<span style=`"$badgeGreen`">DELIVERED</span>" }
                    'Stale'     { "<span style=`"$badgeOrange`">STALE</span>" }
                    'Missing'   { "<span style=`"$badgeRed`">MISSING</span>" }
                    'Disabled'  { "<span style=`"$badgeGray`">DISABLED</span>" }
                    'Error'     { "<span style=`"$badgeRed`">ERROR</span>" }
                    default     { "<span style=`"$badgeGray`">$($dApp.Status)</span>" }
                }

                $lastMod  = if ($null -ne $dApp.LastModified) { ConvertTo-DisconnectedHtmlSafe $dApp.LastModified } else { '-' }
                $fileSize = if ($null -ne $dApp.FileSize) { ConvertTo-DisconnectedHtmlSafe "$([math]::Round($dApp.FileSize / 1KB, 1)) KB" } else { '-' }
                $rowCount = if ($null -ne $dApp.RowCount) { ConvertTo-DisconnectedHtmlSafe $dApp.RowCount } else { '-' }

                $dBg = if (($dRowIdx % 2) -eq 1) { 'background:#f9f9f9;' } else { '' }
                $dTdStyle = "padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; $dBg"

                [void]$html.AppendLine("<tr>")
                [void]$html.AppendLine("  <td style=`"$dTdStyle font-weight:bold;`">$(ConvertTo-DisconnectedHtmlSafe $dApp.Name)</td>")
                [void]$html.AppendLine("  <td style=`"$dTdStyle`">$dStatusBadge</td>")
                [void]$html.AppendLine("  <td style=`"$dTdStyle`">$lastMod</td>")
                [void]$html.AppendLine("  <td style=`"$dTdStyle`">$fileSize</td>")
                [void]$html.AppendLine("  <td style=`"$dTdStyle text-align:center;`">$rowCount</td>")
                [void]$html.AppendLine('</tr>')
                $dRowIdx++
            }
            [void]$html.AppendLine('</table>')
        }

        # ---------------------------------------------------------------
        # Section 5: Footer
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<hr style=`"border:none; border-top:1px solid #dee2e6; margin-top:32px;`">")
        [void]$html.AppendLine("<table style=`"$tableStyle width:auto; margin-top:8px;`">")

        $footerRows = @(
            @('Batch Start',    $(if (-not [string]::IsNullOrWhiteSpace($StartedAt)) { $StartedAt } else { '-' }))
            @('Batch End',      $(if (-not [string]::IsNullOrWhiteSpace($CompletedAt)) { $CompletedAt } else { '-' }))
            @('Duration',       $(if ($DurationSeconds -gt 0) { "${DurationSeconds}s" } else { '-' }))
            @('Correlation ID', $(if (-not [string]::IsNullOrWhiteSpace($CorrelationID)) { $CorrelationID } else { '-' }))
        )

        foreach ($fRow in $footerRows) {
            $fLabel = ConvertTo-DisconnectedHtmlSafe $fRow[0]
            $fValue = ConvertTo-DisconnectedHtmlSafe $fRow[1]
            [void]$html.AppendLine("<tr><td style=`"padding:4px 10px; color:#999; font-size:11px; font-weight:bold; vertical-align:top;`">$fLabel</td><td style=`"padding:4px 10px; color:#999; font-size:11px; vertical-align:top;`">$fValue</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        [void]$html.AppendLine("<p style=`"color:#999; font-size:11px; margin-top:8px;`">Generated by SailPoint Governance Toolkit - Batch Orchestrator | $timestamp UTC</p>")

        # Close document
        [void]$html.AppendLine('</div>')
        [void]$html.AppendLine('</body>')
        [void]$html.AppendLine('</html>')

        # Write file (UTF-8 no BOM)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($filePath, $html.ToString(), $utf8NoBom)

        Write-SPLog -Message "Batch summary HTML report saved to $filePath ($totalApps app(s))" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Export-SPDisconnectedAppBatchHtml'

        return @{
            Success = $true
            Data    = @{ FilePath = $filePath }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Export-SPDisconnectedAppBatchHtml failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Export-SPDisconnectedAppBatchHtml'
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPDisconnectedAppSlaStatus {
    <#
    .SYNOPSIS
        Tracks 30-day file delivery history and SLA compliance per app.
    .DESCRIPTION
        Scans the Snapshots/{AppName}/ directory for each registered app, parses
        date-stamped filenames ({YYYY-MM-DD}-accounts.csv), and builds a 30-day
        delivery calendar. Calculates delivery rate, longest gap, consecutive
        misses, and SLA compliance based on each app's configured SlaDays.

        New apps with less than 30 days of history are handled gracefully --
        delivery rate is calculated against only the days since the first snapshot.
    .PARAMETER DaysBack
        Number of days of history to analyze. Default: 30.
    .PARAMETER SnapshotDir
        Root snapshot directory. Defaults to .\DisconnectedApps\Snapshots.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .PARAMETER ConfigPath
        Path to settings.json. Defaults to auto-resolved path.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Apps = @(
                    @{
                        AppName; DeliveryRate; LongestGapDays; ConsecutiveMisses;
                        SlaDays; SlaCompliant; DaysMissing; DaysDelivered; TotalDaysTracked;
                        FirstSnapshotDate; LatestSnapshotDate
                    }
                )
                Summary = @{ TotalApps; Compliant; NonCompliant; AvgDeliveryRate }
            }
            Error = $string
        }
    .EXAMPLE
        $sla = Get-SPDisconnectedAppSlaStatus -DaysBack 30
        $sla.Data.Apps | Format-Table AppName, DeliveryRate, SlaCompliant
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [ValidateRange(1, 365)]
        [int]$DaysBack = 30,

        [Parameter()]
        [string]$SnapshotDir = '.\DisconnectedApps\Snapshots',

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPDisconnectedAppSlaStatus: Analyzing $DaysBack day delivery history" `
        -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Get-SPDisconnectedAppSlaStatus' `
        -CorrelationID $CorrelationID

    try {
        # Get registered apps (enabled only)
        $configParams = @{}
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
        $today = (Get-Date).Date
        $windowStart = $today.AddDays(-($DaysBack - 1))

        # Build the full date window as strings for comparison
        $windowDates = [System.Collections.Generic.HashSet[string]]::new()
        for ($d = 0; $d -lt $DaysBack; $d++) {
            [void]$windowDates.Add($windowStart.AddDays($d).ToString('yyyy-MM-dd'))
        }

        $appResults = [System.Collections.Generic.List[hashtable]]::new()
        $compliantCount    = 0
        $nonCompliantCount = 0
        $rateSum           = 0.0

        foreach ($app in $apps) {
            $appName = $app.Name
            $slaDays = if ($null -ne $app.SlaDays) { [int]$app.SlaDays } else { 1 }
            $appDir  = Join-Path -Path $SnapshotDir -ChildPath $appName

            # No snapshot directory -- new app, no history
            if (-not (Test-Path -Path $appDir -PathType Container)) {
                $appResults.Add(@{
                    AppName            = $appName
                    DeliveryRate       = 0.0
                    LongestGapDays     = $DaysBack
                    ConsecutiveMisses  = $DaysBack
                    SlaDays            = $slaDays
                    SlaCompliant       = $false
                    DaysMissing        = @($windowDates | Sort-Object)
                    DaysDelivered      = @()
                    TotalDaysTracked   = 0
                    FirstSnapshotDate  = $null
                    LatestSnapshotDate = $null
                })
                $nonCompliantCount++
                continue
            }

            # Scan snapshot files for account snapshots
            $snapshotFiles = @(Get-ChildItem -Path $appDir -Filter '*-accounts.csv' -File -ErrorAction SilentlyContinue)

            # Parse dates from filenames
            $allSnapshotDates = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($sf in $snapshotFiles) {
                $datePart = $sf.Name.Substring(0, 10)
                if ($datePart -match '^\d{4}-\d{2}-\d{2}$') {
                    [void]$allSnapshotDates.Add($datePart)
                }
            }

            if ($allSnapshotDates.Count -eq 0) {
                $appResults.Add(@{
                    AppName            = $appName
                    DeliveryRate       = 0.0
                    LongestGapDays     = $DaysBack
                    ConsecutiveMisses  = $DaysBack
                    SlaDays            = $slaDays
                    SlaCompliant       = $false
                    DaysMissing        = @($windowDates | Sort-Object)
                    DaysDelivered      = @()
                    TotalDaysTracked   = 0
                    FirstSnapshotDate  = $null
                    LatestSnapshotDate = $null
                })
                $nonCompliantCount++
                continue
            }

            # Filter to dates within our window
            $deliveredDates = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($sd in $allSnapshotDates) {
                if ($windowDates.Contains($sd)) {
                    [void]$deliveredDates.Add($sd)
                }
            }

            # Determine the effective tracking window for new apps
            $sortedAllDates = @($allSnapshotDates | Sort-Object)
            $firstSnapshotDate  = $sortedAllDates[0]
            $latestSnapshotDate = $sortedAllDates[$sortedAllDates.Count - 1]

            # For delivery rate, only count days from first snapshot (or window start, whichever is later)
            $effectiveStart = $windowStart.ToString('yyyy-MM-dd')
            if ($firstSnapshotDate -gt $effectiveStart) {
                $effectiveStart = $firstSnapshotDate
            }

            # Count trackable days (from effective start to today)
            $effectiveStartDate = [datetime]::ParseExact($effectiveStart, 'yyyy-MM-dd', $null)
            $totalDaysTracked = [math]::Max(1, ($today - $effectiveStartDate).Days + 1)

            # Build missing days list (within window only)
            $missingDays = [System.Collections.Generic.List[string]]::new()
            foreach ($wd in ($windowDates | Sort-Object)) {
                if (-not $deliveredDates.Contains($wd) -and $wd -ge $effectiveStart) {
                    $missingDays.Add($wd)
                }
            }

            # Delivery rate
            $deliveredInWindow = @($deliveredDates | Where-Object { $_ -ge $effectiveStart }).Count
            $deliveryRate = if ($totalDaysTracked -gt 0) {
                [math]::Round(($deliveredInWindow / $totalDaysTracked) * 100, 1)
            } else { 0.0 }

            # Longest gap and consecutive misses (within trackable window)
            $longestGap       = 0
            $currentGap       = 0
            $consecutiveMisses = 0

            $trackableDates = @($windowDates | Sort-Object | Where-Object { $_ -ge $effectiveStart })
            foreach ($td in $trackableDates) {
                if ($deliveredDates.Contains($td)) {
                    if ($currentGap -gt $longestGap) { $longestGap = $currentGap }
                    $currentGap = 0
                } else {
                    $currentGap++
                }
            }
            # Check if final streak of misses is the longest
            if ($currentGap -gt $longestGap) { $longestGap = $currentGap }
            # Consecutive misses = trailing gap (from most recent date backward)
            $consecutiveMisses = $currentGap

            # SLA compliance: no gap exceeds SlaDays
            $slaCompliant = ($longestGap -le $slaDays)

            $appResults.Add(@{
                AppName            = $appName
                DeliveryRate       = $deliveryRate
                LongestGapDays     = $longestGap
                ConsecutiveMisses  = $consecutiveMisses
                SlaDays            = $slaDays
                SlaCompliant       = $slaCompliant
                DaysMissing        = $missingDays.ToArray()
                DaysDelivered      = @($deliveredDates | Sort-Object)
                TotalDaysTracked   = $totalDaysTracked
                FirstSnapshotDate  = $firstSnapshotDate
                LatestSnapshotDate = $latestSnapshotDate
            })

            $rateSum += $deliveryRate
            if ($slaCompliant) { $compliantCount++ } else { $nonCompliantCount++ }

            Write-SPLog -Message "App '$appName': $deliveryRate% delivery rate, SLA $(if ($slaCompliant) { 'COMPLIANT' } else { 'NON-COMPLIANT' }) (longest gap: ${longestGap}d, SLA: ${slaDays}d)" `
                -Severity $(if ($slaCompliant) { 'INFO' } else { 'WARN' }) `
                -Component 'SP.DisconnectedAppRunner' -Action 'Get-SPDisconnectedAppSlaStatus' `
                -CorrelationID $CorrelationID
        }

        $avgRate = if ($apps.Count -gt 0) { [math]::Round($rateSum / $apps.Count, 1) } else { 0.0 }

        Write-SPLog -Message "SLA status: $compliantCount compliant, $nonCompliantCount non-compliant, avg delivery rate ${avgRate}% (of $($apps.Count) apps)" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Get-SPDisconnectedAppSlaStatus' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Apps    = $appResults.ToArray()
                Summary = @{
                    TotalApps       = $apps.Count
                    Compliant       = $compliantCount
                    NonCompliant    = $nonCompliantCount
                    AvgDeliveryRate = $avgRate
                }
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPDisconnectedAppSlaStatus failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Get-SPDisconnectedAppSlaStatus' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Export-SPDisconnectedAppSlaHtml {
    <#
    .SYNOPSIS
        Generates an SLA compliance HTML report with 30-day delivery grids.
    .DESCRIPTION
        Takes the output of Get-SPDisconnectedAppSlaStatus and produces a self-contained
        HTML report with per-app 30-day delivery calendars, SLA compliance badges, and
        an overall delivery health score.

        The report uses 100% inline CSS for Microsoft Word paste compatibility.
        No external resources.

        Color coding:
        - Green (#339933): delivered / compliant
        - Red (#CC3333): missing / non-compliant
        - Gray (#999999): before tracking period
        - Orange (#FF8800): warning (high miss rate)
    .PARAMETER SlaData
        Output from Get-SPDisconnectedAppSlaStatus (the .Data property).
    .PARAMETER DaysBack
        Number of days in the delivery window. Default: 30.
    .PARAMETER OutputPath
        Base directory for reports. Report is saved to
        {OutputPath}/sla-report-{YYYY-MM-DD}.html
    .PARAMETER ReportDate
        Date stamp for the report filename and header. Defaults to today.
    .PARAMETER CorrelationID
        Correlation ID for log entries.
    .OUTPUTS
        [hashtable] @{Success; Data=@{FilePath=[string]}; Error}
    .EXAMPLE
        $sla = Get-SPDisconnectedAppSlaStatus -DaysBack 30
        Export-SPDisconnectedAppSlaHtml -SlaData $sla.Data -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$SlaData,

        [Parameter()]
        [int]$DaysBack = 30,

        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [string]$ReportDate,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($ReportDate)) {
        $ReportDate = Get-Date -Format 'yyyy-MM-dd'
    }

    try {
        # Ensure output directory exists
        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        $filePath = Join-Path -Path $OutputPath -ChildPath "sla-report-${ReportDate}.html"

        # Style constants (matching toolkit conventions)
        $sectionHeadingStyle = 'font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;'
        $labelTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; font-weight:bold; width:220px; background:#f4f4f4; vertical-align:top;'
        $valueTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;'
        $tableStyle          = 'width:100%; border-collapse:collapse; margin-bottom:18px; font-size:13px; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif;'
        $badgeGreen          = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#339933;'
        $badgeRed            = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#CC3333;'
        $badgeOrange         = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#FF8800;'
        $badgeGray           = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#999999;'

        # Grid cell styles for the 30-day calendar
        $cellDelivered = 'display:inline-block; width:16px; height:16px; margin:1px; background:#339933; border-radius:2px; vertical-align:middle;'
        $cellMissing   = 'display:inline-block; width:16px; height:16px; margin:1px; background:#CC3333; border-radius:2px; vertical-align:middle;'
        $cellPreTrack  = 'display:inline-block; width:16px; height:16px; margin:1px; background:#e0e0e0; border-radius:2px; vertical-align:middle;'

        $apps    = @($SlaData.Apps)
        $summary = $SlaData.Summary

        # Build the date window
        $today       = (Get-Date).Date
        $windowStart = $today.AddDays(-($DaysBack - 1))
        $windowDates = [System.Collections.Generic.List[string]]::new()
        for ($d = 0; $d -lt $DaysBack; $d++) {
            $windowDates.Add($windowStart.AddDays($d).ToString('yyyy-MM-dd'))
        }

        # Build HTML
        $html = [System.Text.StringBuilder]::new(8192)

        [void]$html.AppendLine('<!DOCTYPE html>')
        [void]$html.AppendLine('<html lang="en">')
        [void]$html.AppendLine('<head>')
        [void]$html.AppendLine('    <meta charset="UTF-8">')
        [void]$html.AppendLine('    <meta name="viewport" content="width=device-width, initial-scale=1.0">')
        [void]$html.AppendLine("    <title>SLA Delivery Report - $ReportDate</title>")
        [void]$html.AppendLine('</head>')
        [void]$html.AppendLine('<body style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">')
        [void]$html.AppendLine('<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">')

        # Title
        [void]$html.AppendLine("<h1 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin-top:0; margin-bottom:4px; font-size:22px;`">Disconnected App SLA Delivery Report</h1>")
        [void]$html.AppendLine("<p style=`"color:#777; font-size:13px; margin-top:0; margin-bottom:20px;`">Report date: $ReportDate | Window: $DaysBack days</p>")

        # -----------------------------------------------------------
        # Section 1: Overall Health Score
        # -----------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Delivery Health Summary</h2>")

        # Overall health badge
        $avgRate = $summary.AvgDeliveryRate
        $healthBadge = $badgeGreen
        $healthLabel = 'HEALTHY'
        if ($avgRate -lt 80) {
            $healthBadge = $badgeRed
            $healthLabel = 'AT RISK'
        } elseif ($avgRate -lt 95) {
            $healthBadge = $badgeOrange
            $healthLabel = 'WARNING'
        }
        [void]$html.AppendLine("<p style=`"margin-bottom:12px;`"><span style=`"$healthBadge`">$healthLabel</span></p>")

        [void]$html.AppendLine("<table style=`"$tableStyle width:auto;`">")
        $summaryRows = @(
            @('Total Apps',         $summary.TotalApps)
            @('SLA Compliant',      $summary.Compliant)
            @('SLA Non-Compliant',  $summary.NonCompliant)
            @('Avg Delivery Rate',  "${avgRate}%")
        )
        foreach ($row in $summaryRows) {
            $label = ConvertTo-DisconnectedHtmlSafe $row[0]
            $value = ConvertTo-DisconnectedHtmlSafe $row[1]
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        # -----------------------------------------------------------
        # Section 2: Per-App SLA Table
        # -----------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Per-App SLA Status</h2>")
        [void]$html.AppendLine("<table style=`"$tableStyle`">")
        [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('App Name', 'SLA', 'Delivery Rate', 'Longest Gap', 'Trailing Misses', 'SLA Days', 'Tracked Days')))

        $rowIdx = 0
        foreach ($app in $apps) {
            $rowBg = if (($rowIdx % 2) -eq 1) { 'background:#f9f9f9;' } else { '' }
            $tdStyle = "padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; $rowBg"

            # SLA compliance badge
            $slaBadge = if ($app.SlaCompliant) {
                "<span style=`"$badgeGreen`">COMPLIANT</span>"
            } else {
                "<span style=`"$badgeRed`">NON-COMPLIANT</span>"
            }

            # Delivery rate with color coding
            $rateColor = '#339933'
            if ($app.DeliveryRate -lt 80) { $rateColor = '#CC3333' }
            elseif ($app.DeliveryRate -lt 95) { $rateColor = '#FF8800' }
            $rateDisplay = "<span style=`"font-weight:bold; color:${rateColor};`">$($app.DeliveryRate)%</span>"

            [void]$html.AppendLine('<tr>')
            [void]$html.AppendLine("  <td style=`"$tdStyle font-weight:bold;`">$(ConvertTo-DisconnectedHtmlSafe $app.AppName)</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle`">$slaBadge</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle`">$rateDisplay</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle text-align:center;`">$(ConvertTo-DisconnectedHtmlSafe $app.LongestGapDays)d</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle text-align:center;`">$(ConvertTo-DisconnectedHtmlSafe $app.ConsecutiveMisses)</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle text-align:center;`">$(ConvertTo-DisconnectedHtmlSafe $app.SlaDays)</td>")
            [void]$html.AppendLine("  <td style=`"$tdStyle text-align:center;`">$(ConvertTo-DisconnectedHtmlSafe $app.TotalDaysTracked)</td>")
            [void]$html.AppendLine('</tr>')
            $rowIdx++
        }
        [void]$html.AppendLine('</table>')

        # -----------------------------------------------------------
        # Section 3: 30-Day Delivery Grids
        # -----------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">30-Day Delivery Calendar</h2>")

        # Legend
        [void]$html.AppendLine('<p style="font-size:12px; margin-bottom:16px;">')
        [void]$html.AppendLine("  <span style=`"$cellDelivered`"></span> Delivered")
        [void]$html.AppendLine("  <span style=`"margin-left:12px; $cellMissing`"></span> Missing")
        [void]$html.AppendLine("  <span style=`"margin-left:12px; $cellPreTrack`"></span> Before tracking")
        [void]$html.AppendLine('</p>')

        foreach ($app in $apps) {
            # Build a set of delivered dates for quick lookup
            $deliveredSet = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($dd in $app.DaysDelivered) {
                [void]$deliveredSet.Add($dd)
            }

            # App header with compliance badge
            $appSlaBadge = if ($app.SlaCompliant) {
                "<span style=`"$badgeGreen`">COMPLIANT</span>"
            } else {
                "<span style=`"$badgeRed`">NON-COMPLIANT</span>"
            }

            [void]$html.AppendLine("<div style=`"margin-bottom:20px; padding:12px 16px; border:1px solid #dee2e6; border-radius:4px;`">")
            [void]$html.AppendLine("  <p style=`"font-weight:bold; font-size:14px; margin:0 0 8px 0;`">$(ConvertTo-DisconnectedHtmlSafe $app.AppName) $appSlaBadge <span style=`"font-weight:normal; color:#777; font-size:12px; margin-left:8px;`">$($app.DeliveryRate)% delivery rate</span></p>")

            # Grid of day cells
            [void]$html.AppendLine('  <div style="line-height:0;">')
            foreach ($dateStr in $windowDates) {
                $cellTitle = $dateStr
                if ($null -ne $app.FirstSnapshotDate -and $dateStr -lt $app.FirstSnapshotDate) {
                    # Before this app started tracking
                    $cellStyle = $cellPreTrack
                    $cellTitle = "$dateStr (before tracking)"
                } elseif ($deliveredSet.Contains($dateStr)) {
                    $cellStyle = $cellDelivered
                    $cellTitle = "$dateStr (delivered)"
                } else {
                    $cellStyle = $cellMissing
                    $cellTitle = "$dateStr (missing)"
                }
                [void]$html.Append("<span style=`"$cellStyle`" title=`"$cellTitle`"></span>")
            }
            [void]$html.AppendLine('')
            [void]$html.AppendLine('  </div>')

            # Date labels (first and last)
            $firstDate = $windowDates[0]
            $lastDate  = $windowDates[$windowDates.Count - 1]
            [void]$html.AppendLine("  <p style=`"margin:4px 0 0 0; font-size:10px; color:#999;`">$firstDate to $lastDate</p>")

            # Missing days detail (if any)
            if ($app.DaysMissing.Count -gt 0 -and $app.DaysMissing.Count -le 10) {
                $missingList = ($app.DaysMissing | ForEach-Object { ConvertTo-DisconnectedHtmlSafe $_ }) -join ', '
                [void]$html.AppendLine("  <p style=`"margin:4px 0 0 0; font-size:11px; color:#CC3333;`">Missing: $missingList</p>")
            } elseif ($app.DaysMissing.Count -gt 10) {
                [void]$html.AppendLine("  <p style=`"margin:4px 0 0 0; font-size:11px; color:#CC3333;`">$($app.DaysMissing.Count) days missing</p>")
            }

            [void]$html.AppendLine('</div>')
        }

        # -----------------------------------------------------------
        # Footer
        # -----------------------------------------------------------
        [void]$html.AppendLine("<hr style=`"border:none; border-top:1px solid #dee2e6; margin-top:32px;`">")
        [void]$html.AppendLine("<table style=`"$tableStyle width:auto; margin-top:8px;`">")

        $footerRows = @(
            @('Window',        "${DaysBack} days")
            @('Correlation ID', $(if (-not [string]::IsNullOrWhiteSpace($CorrelationID)) { $CorrelationID } else { '-' }))
        )
        foreach ($fRow in $footerRows) {
            $fLabel = ConvertTo-DisconnectedHtmlSafe $fRow[0]
            $fValue = ConvertTo-DisconnectedHtmlSafe $fRow[1]
            [void]$html.AppendLine("<tr><td style=`"padding:4px 10px; color:#999; font-size:11px; font-weight:bold; vertical-align:top;`">$fLabel</td><td style=`"padding:4px 10px; color:#999; font-size:11px; vertical-align:top;`">$fValue</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        [void]$html.AppendLine("<p style=`"color:#999; font-size:11px; margin-top:8px;`">Generated by SailPoint Governance Toolkit - SLA Monitor | $timestamp UTC</p>")

        # Close document
        [void]$html.AppendLine('</div>')
        [void]$html.AppendLine('</body>')
        [void]$html.AppendLine('</html>')

        # Write file (UTF-8 no BOM)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($filePath, $html.ToString(), $utf8NoBom)

        Write-SPLog -Message "SLA HTML report saved to $filePath ($($apps.Count) app(s))" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Export-SPDisconnectedAppSlaHtml'

        return @{
            Success = $true
            Data    = @{ FilePath = $filePath }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Export-SPDisconnectedAppSlaHtml failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Export-SPDisconnectedAppSlaHtml'
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPDisconnectedAppCampaignDecisions {
    <#
    .SYNOPSIS
        Harvests campaign decisions from ISC for disconnected app campaigns.
    .DESCRIPTION
        Reads campaign IDs from the per-app JSONL audit trail, queries ISC for
        each campaign's current status, and for completed campaigns retrieves
        item-level decisions (APPROVE / REVOKE). Results are categorized and
        written back to the audit trail as a DecisionHarvest event.

        This closes the governance loop: the toolkit created campaigns (cert run),
        and now it checks what managers decided.

        Uses Get-SPCampaign for status, Get-SPAuditCertifications for reviewer
        info, and Get-SPAuditCertificationItems for item-level decisions.
    .PARAMETER AppName
        Application name. Used to locate the correct JSONL audit trail.
    .PARAMETER OutputPath
        Base directory for reports. Reads from {OutputPath}/{AppName}/disconnected-app-audit.jsonl.
    .PARAMETER DaysBack
        How many days of audit trail to scan for campaign IDs. Default: 7.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@{CampaignsChecked; Completed; Active;
            Expired; Purged; Decisions=@{Approved; Revoked; Pending};
            RevocationDetails=@(...)  }; Error=$string}
    .EXAMPLE
        $result = Get-SPDisconnectedAppCampaignDecisions -AppName 'PEP-Plus' -OutputPath '.\Reports'
        $result.Data.Decisions.Revoked  # count of REVOKE decisions
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [ValidateRange(1, 365)]
        [int]$DaysBack = 7,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Get-SPDisconnectedAppCampaignDecisions'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-SPLog -Message "Starting decision harvest for app '$AppName' (DaysBack=$DaysBack)" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    try {
        # -----------------------------------------------------------
        # Step 1: Read JSONL audit trail and extract campaign IDs
        # -----------------------------------------------------------
        $appOutputPath   = Join-Path -Path $OutputPath -ChildPath $AppName
        $auditTrailPath  = Join-Path -Path $appOutputPath -ChildPath 'disconnected-app-audit.jsonl'

        if (-not (Test-Path -Path $auditTrailPath -PathType Leaf)) {
            $errMsg = "No audit trail found at '$auditTrailPath'. Run a cert cycle first."
            Write-SPLog -Message $errMsg -Severity WARN -Component $component `
                -Action $action -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $cutoffDate = (Get-Date).ToUniversalTime().AddDays(-$DaysBack)
        $lines = @(Get-Content -Path $auditTrailPath -Encoding UTF8)
        $campaignIdSet = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

            try {
                $event = $trimmed | ConvertFrom-Json
            }
            catch { continue }

            # Only look at DisconnectedAppCertRun events
            if ($event.Action -ne 'DisconnectedAppCertRun') { continue }

            # Parse timestamp and apply cutoff
            $eventTime = $null
            if (-not [string]::IsNullOrWhiteSpace($event.Timestamp)) {
                try {
                    $eventTime = [datetime]::Parse($event.Timestamp).ToUniversalTime()
                }
                catch { }
            }
            if ($null -ne $eventTime -and $eventTime -lt $cutoffDate) { continue }

            # Collect campaign IDs
            if ($null -ne $event.CampaignIds) {
                foreach ($cid in @($event.CampaignIds)) {
                    if (-not [string]::IsNullOrWhiteSpace($cid)) {
                        [void]$campaignIdSet.Add($cid)
                    }
                }
            }
        }

        if ($campaignIdSet.Count -eq 0) {
            Write-SPLog -Message "No campaign IDs found in audit trail for '$AppName' within $DaysBack days" `
                -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
            $emptyData = @{
                CampaignsChecked = 0
                Completed        = 0
                Active           = 0
                Expired          = 0
                Purged           = 0
                Decisions        = @{ Approved = 0; Revoked = 0; Pending = 0 }
                RevocationDetails = @()
            }
            return @{ Success = $true; Data = $emptyData; Error = $null }
        }

        Write-SPLog -Message "Found $($campaignIdSet.Count) campaign ID(s) in audit trail for '$AppName'" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        # -----------------------------------------------------------
        # Step 2: Query ISC for each campaign's status
        # -----------------------------------------------------------
        $completedCount = 0
        $activeCount    = 0
        $expiredCount   = 0
        $purgedCount    = 0
        $approvedCount  = 0
        $revokedCount   = 0
        $pendingCount   = 0
        $revocationDetails = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($campId in $campaignIdSet) {
            Write-SPLog -Message "Checking campaign '$campId'" `
                -Severity DEBUG -Component $component -Action $action -CorrelationID $CorrelationID

            $campResult = Get-SPCampaign -CampaignId $campId -CorrelationID $CorrelationID
            if (-not $campResult.Success) {
                # Campaign may have been purged/deleted from ISC
                if ($campResult.Error -match '404|Not Found|does not exist') {
                    $purgedCount++
                    Write-SPLog -Message "Campaign '$campId' no longer exists in ISC (purged/deleted)" `
                        -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
                }
                else {
                    Write-SPLog -Message "Failed to query campaign '$campId': $($campResult.Error)" `
                        -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
                }
                continue
            }

            $campaign = $campResult.Data
            $status   = if ($null -ne $campaign.status) { $campaign.status } else { 'UNKNOWN' }

            # Categorize by status
            if ($status -eq 'COMPLETED') {
                $completedCount++
            }
            elseif ($status -in @('ACTIVE', 'STAGED', 'ACTIVATING')) {
                $activeCount++
                # Cannot harvest decisions from non-completed campaigns yet
                continue
            }
            else {
                # COMPLETING or other transitional states -- treat as active
                $activeCount++
                continue
            }

            # -----------------------------------------------------------
            # Step 3: For completed campaigns, get certifications + items
            # -----------------------------------------------------------
            $certResult = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $CorrelationID
            if (-not $certResult.Success) {
                Write-SPLog -Message "Failed to get certifications for campaign '$campId': $($certResult.Error)" `
                    -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
                continue
            }

            $certifications = @($certResult.Data)
            foreach ($cert in $certifications) {
                $certId = $cert.id
                if ([string]::IsNullOrWhiteSpace($certId)) { continue }

                $itemResult = Get-SPAuditCertificationItems -CertificationId $certId `
                    -CorrelationID $CorrelationID
                if (-not $itemResult.Success) {
                    Write-SPLog -Message "Failed to get items for certification '$certId': $($itemResult.Error)" `
                        -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
                    continue
                }

                $items = @($itemResult.Data)
                $reviewerName = ''
                if ($null -ne $cert.EffectiveReviewer -and
                    $null -ne $cert.EffectiveReviewer.displayName) {
                    $reviewerName = $cert.EffectiveReviewer.displayName
                }

                foreach ($item in $items) {
                    $decision = if ($null -ne $item.decision) { $item.decision.ToUpper() } else { '' }

                    if ($decision -eq 'APPROVE') {
                        $approvedCount++
                    }
                    elseif ($decision -eq 'REVOKE') {
                        $revokedCount++

                        # Extract revocation details for remediation tracking
                        $identityName = ''
                        if ($null -ne $item.identitySummary -and
                            $null -ne $item.identitySummary.name) {
                            $identityName = $item.identitySummary.name
                        }

                        $accountId = ''
                        if ($null -ne $item.PSObject.Properties['accountId']) {
                            $accountId = [string]$item.accountId
                        }
                        elseif ($null -ne $item.accessSummary -and
                                $null -ne $item.accessSummary.PSObject.Properties['accountId']) {
                            $accountId = [string]$item.accessSummary.accountId
                        }

                        $entitlementName = ''
                        if ($null -ne $item.accessSummary -and
                            $null -ne $item.accessSummary.PSObject.Properties['entitlement'] -and
                            $null -ne $item.accessSummary.entitlement.PSObject.Properties['name']) {
                            $entitlementName = $item.accessSummary.entitlement.name
                        }
                        elseif ($null -ne $item.accessSummary -and
                                $null -ne $item.accessSummary.PSObject.Properties['access'] -and
                                $null -ne $item.accessSummary.access.PSObject.Properties['name']) {
                            $entitlementName = $item.accessSummary.access.name
                        }

                        $decisionDate = ''
                        if ($null -ne $item.PSObject.Properties['completed'] -and
                            $null -ne $item.completed) {
                            $decisionDate = [string]$item.completed
                        }

                        $revocationDetails.Add(@{
                            AppName         = $AppName
                            CampaignId      = $campId
                            CertificationId = $certId
                            IdentityName    = $identityName
                            AccountId       = $accountId
                            Entitlement     = $entitlementName
                            ReviewerName    = $reviewerName
                            DecisionDate    = $decisionDate
                        })
                    }
                    else {
                        # No decision yet (should not happen for COMPLETED campaigns)
                        $pendingCount++
                    }
                }
            }
        }

        # -----------------------------------------------------------
        # Step 5: Write decision harvest event to JSONL
        # -----------------------------------------------------------
        $stopwatch.Stop()

        $harvestEvent = [ordered]@{
            Timestamp        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            CorrelationID    = $CorrelationID
            Action           = 'DecisionHarvest'
            AppName          = $AppName
            DaysBack         = $DaysBack
            CampaignsChecked = $campaignIdSet.Count
            Completed        = $completedCount
            Active           = $activeCount
            Expired          = $expiredCount
            Purged           = $purgedCount
            Approved         = $approvedCount
            Revoked          = $revokedCount
            Pending          = $pendingCount
            RevocationCount  = $revocationDetails.Count
            DurationSeconds  = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        }

        try {
            if (-not (Test-Path -Path $appOutputPath -PathType Container)) {
                New-Item -Path $appOutputPath -ItemType Directory -Force | Out-Null
            }
            $jsonLine = $harvestEvent | ConvertTo-Json -Depth 5 -Compress
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::AppendAllText($auditTrailPath, "$jsonLine`n", $utf8NoBom)
        }
        catch {
            Write-SPLog -Message "Failed to write decision harvest event to JSONL: $($_.Exception.Message)" `
                -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
        }

        # -----------------------------------------------------------
        # Step 6: Return structured data
        # -----------------------------------------------------------
        $resultData = @{
            CampaignsChecked  = $campaignIdSet.Count
            Completed         = $completedCount
            Active            = $activeCount
            Expired           = $expiredCount
            Purged            = $purgedCount
            Decisions         = @{
                Approved = $approvedCount
                Revoked  = $revokedCount
                Pending  = $pendingCount
            }
            RevocationDetails = $revocationDetails.ToArray()
        }

        Write-SPLog -Message ("Decision harvest complete for '$AppName': " +
            "$($campaignIdSet.Count) campaigns checked, " +
            "$completedCount completed, $approvedCount approved, " +
            "$revokedCount revoked, $purgedCount purged") `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $resultData; Error = $null }
    }
    catch {
        $errMsg = "Get-SPDisconnectedAppCampaignDecisions failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Export-SPDisconnectedAppDecisionHarvestHtml {
    <#
    .SYNOPSIS
        Generates an HTML decision harvest report for a disconnected app.
    .DESCRIPTION
        Takes the output of Get-SPDisconnectedAppCampaignDecisions and renders
        a self-contained HTML report showing campaign statuses, decision breakdown,
        and revocation details requiring remediation follow-up.

        Uses 100% inline CSS for Microsoft Word paste compatibility.
    .PARAMETER DecisionData
        The .Data hashtable from Get-SPDisconnectedAppCampaignDecisions.
    .PARAMETER AppName
        Application name shown in the report title.
    .PARAMETER OutputPath
        Base directory for reports. Report is saved to
        {OutputPath}/{AppName}/decision-harvest-{YYYY-MM-DD}.html
    .PARAMETER ReportDate
        Date stamp for the report filename and header. Defaults to today.
    .OUTPUTS
        [hashtable] @{Success; Data=@{FilePath=[string]}; Error}
    .EXAMPLE
        $decisions = (Get-SPDisconnectedAppCampaignDecisions -AppName 'PEP-Plus').Data
        Export-SPDisconnectedAppDecisionHarvestHtml -DecisionData $decisions -AppName 'PEP-Plus'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$DecisionData,

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
        # -----------------------------------------------------------
        # Ensure output directory
        # -----------------------------------------------------------
        $appOutputPath = Join-Path -Path $OutputPath -ChildPath $AppName
        if (-not (Test-Path -Path $appOutputPath -PathType Container)) {
            New-Item -Path $appOutputPath -ItemType Directory -Force | Out-Null
        }
        $filePath = Join-Path -Path $appOutputPath -ChildPath "decision-harvest-${ReportDate}.html"

        # -----------------------------------------------------------
        # Extract data
        # -----------------------------------------------------------
        $campaignsChecked = if ($null -ne $DecisionData['CampaignsChecked']) { $DecisionData['CampaignsChecked'] } else { 0 }
        $completed        = if ($null -ne $DecisionData['Completed'])        { $DecisionData['Completed'] }        else { 0 }
        $active           = if ($null -ne $DecisionData['Active'])           { $DecisionData['Active'] }           else { 0 }
        $expired          = if ($null -ne $DecisionData['Expired'])          { $DecisionData['Expired'] }          else { 0 }
        $purged           = if ($null -ne $DecisionData['Purged'])           { $DecisionData['Purged'] }           else { 0 }
        $decisions        = if ($null -ne $DecisionData['Decisions'])        { $DecisionData['Decisions'] }        else { @{} }
        $approved         = if ($null -ne $decisions['Approved'])            { $decisions['Approved'] }            else { 0 }
        $revoked          = if ($null -ne $decisions['Revoked'])             { $decisions['Revoked'] }             else { 0 }
        $pending          = if ($null -ne $decisions['Pending'])             { $decisions['Pending'] }             else { 0 }
        $revocations      = @()
        if ($null -ne $DecisionData['RevocationDetails']) {
            $revocations = @($DecisionData['RevocationDetails'])
        }

        # -----------------------------------------------------------
        # Style constants
        # -----------------------------------------------------------
        $sectionHeadingStyle = 'font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;'
        $labelTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; font-weight:bold; width:220px; background:#f4f4f4; vertical-align:top;'
        $valueTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;'
        $tableStyle          = 'width:100%; border-collapse:collapse; margin-bottom:18px; font-size:13px; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif;'
        $badgeGreen          = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#339933;'
        $badgeRed            = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#CC3333;'
        $badgeOrange         = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#FF8800;'
        $badgeBlue           = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#336699;'

        # -----------------------------------------------------------
        # Build HTML
        # -----------------------------------------------------------
        $html = [System.Text.StringBuilder]::new(8192)

        [void]$html.AppendLine('<!DOCTYPE html>')
        [void]$html.AppendLine('<html lang="en">')
        [void]$html.AppendLine('<head>')
        [void]$html.AppendLine('    <meta charset="UTF-8">')
        [void]$html.AppendLine('    <meta name="viewport" content="width=device-width, initial-scale=1.0">')
        [void]$html.AppendLine("    <title>$(ConvertTo-DisconnectedHtmlSafe $AppName) - Decision Harvest $ReportDate</title>")
        [void]$html.AppendLine('</head>')
        [void]$html.AppendLine('<body style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">')
        [void]$html.AppendLine('<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">')

        $safeAppName = ConvertTo-DisconnectedHtmlSafe $AppName
        [void]$html.AppendLine("<h1 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin-top:0; margin-bottom:4px; font-size:22px;`">$safeAppName - Decision Harvest</h1>")
        [void]$html.AppendLine("<p style=`"color:#777; font-size:13px; margin-top:0; margin-bottom:20px;`">Report date: $ReportDate</p>")

        # -----------------------------------------------------------
        # Section 1: Campaign Status Summary
        # -----------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Campaign Status Summary</h2>")
        [void]$html.AppendLine("<table style=`"$tableStyle`">")

        $statusRows = @(
            @('Campaigns Checked', $campaignsChecked)
            @('Completed',         $completed)
            @('Active',            $active)
            @('Expired',           $expired)
            @('Purged / Deleted',  $purged)
        )
        foreach ($row in $statusRows) {
            $label = ConvertTo-DisconnectedHtmlSafe $row[0]
            $value = ConvertTo-DisconnectedHtmlSafe $row[1]
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        # -----------------------------------------------------------
        # Section 2: Decision Breakdown
        # -----------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Decision Breakdown</h2>")
        [void]$html.AppendLine("<table style=`"$tableStyle`">")

        $totalDecisions = $approved + $revoked + $pending
        $decisionRows = @(
            @('Total Decisions', $totalDecisions)
        )
        foreach ($row in $decisionRows) {
            $label = ConvertTo-DisconnectedHtmlSafe $row[0]
            $value = ConvertTo-DisconnectedHtmlSafe $row[1]
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
        }

        # Approved with green badge
        [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`"><span style=`"$badgeGreen`">APPROVED</span></td><td style=`"$valueTdStyle`">$(ConvertTo-DisconnectedHtmlSafe $approved)</td></tr>")
        # Revoked with red badge
        [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`"><span style=`"$badgeRed`">REVOKED</span></td><td style=`"$valueTdStyle`">$(ConvertTo-DisconnectedHtmlSafe $revoked)</td></tr>")
        # Pending with orange badge
        if ($pending -gt 0) {
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`"><span style=`"$badgeOrange`">PENDING</span></td><td style=`"$valueTdStyle`">$(ConvertTo-DisconnectedHtmlSafe $pending)</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        # -----------------------------------------------------------
        # Section 3: Revocation Details (remediation required)
        # -----------------------------------------------------------
        if ($revocations.Count -gt 0) {
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`"><span style=`"$badgeRed`">ACTION REQUIRED</span> Revocations Requiring Remediation ($($revocations.Count))</h2>")
            [void]$html.AppendLine("<table style=`"$tableStyle`">")
            [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Identity', 'Account ID', 'Entitlement', 'Reviewer', 'Decision Date')))

            $rowIdx = 0
            foreach ($rev in $revocations) {
                $cells = @(
                    (ConvertTo-DisconnectedHtmlSafe $rev.IdentityName),
                    (ConvertTo-DisconnectedHtmlSafe $rev.AccountId),
                    (ConvertTo-DisconnectedHtmlSafe $rev.Entitlement),
                    (ConvertTo-DisconnectedHtmlSafe $rev.ReviewerName),
                    (ConvertTo-DisconnectedHtmlSafe $rev.DecisionDate)
                )
                [void]$html.AppendLine((Build-DisconnectedHtmlRow -Cells $cells -IsAlternate (($rowIdx % 2) -eq 1)))
                $rowIdx++
            }
            [void]$html.AppendLine('</table>')
        }
        else {
            [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Revocations</h2>")
            [void]$html.AppendLine("<p style=`"color:#339933; font-size:13px;`">No revocations requiring remediation.</p>")
        }

        # -----------------------------------------------------------
        # Footer
        # -----------------------------------------------------------
        [void]$html.AppendLine("<hr style=`"border:none; border-top:1px solid #dee2e6; margin-top:32px;`">")
        [void]$html.AppendLine("<table style=`"$tableStyle width:auto; margin-top:8px;`">")

        $footerRows = @(
            @('Report Type', 'Decision Harvest')
            @('Application', $AppName)
        )
        foreach ($fRow in $footerRows) {
            $fLabel = ConvertTo-DisconnectedHtmlSafe $fRow[0]
            $fValue = ConvertTo-DisconnectedHtmlSafe $fRow[1]
            [void]$html.AppendLine("<tr><td style=`"padding:4px 10px; color:#999; font-size:11px; font-weight:bold; vertical-align:top;`">$fLabel</td><td style=`"padding:4px 10px; color:#999; font-size:11px; vertical-align:top;`">$fValue</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        [void]$html.AppendLine("<p style=`"color:#999; font-size:11px; margin-top:8px;`">Generated by SailPoint Governance Toolkit - Decision Harvest | $timestamp UTC</p>")

        [void]$html.AppendLine('</div>')
        [void]$html.AppendLine('</body>')
        [void]$html.AppendLine('</html>')

        # -----------------------------------------------------------
        # Write file (UTF-8 no BOM)
        # -----------------------------------------------------------
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($filePath, $html.ToString(), $utf8NoBom)

        Write-SPLog -Message "Decision harvest HTML report saved to $filePath" `
            -Severity INFO -Component 'SP.DisconnectedAppRunner' -Action 'Export-SPDisconnectedAppDecisionHarvestHtml'

        return @{
            Success = $true
            Data    = @{ FilePath = $filePath }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Export-SPDisconnectedAppDecisionHarvestHtml failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DisconnectedAppRunner' `
            -Action 'Export-SPDisconnectedAppDecisionHarvestHtml'
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region DA-22: Remediation Tracker

function New-SPRemediationRecord {
    <#
    .SYNOPSIS
        Creates PENDING remediation records from revocation decisions.
    .DESCRIPTION
        Takes the RevocationDetails array from Get-SPDisconnectedAppCampaignDecisions
        and creates (or updates) a per-app remediation-tracker.json file. Each revocation
        decision becomes a PENDING remediation record that must be confirmed by observing
        the entitlement's absence in a subsequent CSV delivery.

        Duplicate detection: if a record already exists for the same AccountId +
        Entitlement + CampaignId combination, it is not re-added.
    .PARAMETER RevocationDetails
        Array of hashtables from Get-SPDisconnectedAppCampaignDecisions .Data.RevocationDetails.
        Each must contain: AppName, CampaignId, IdentityName, AccountId, Entitlement,
        ReviewerName, DecisionDate.
    .PARAMETER AppName
        Application name. Used to locate the remediation tracker file.
    .PARAMETER OutputPath
        Base directory for reports. Tracker stored at {OutputPath}/{AppName}/remediation-tracker.json.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success; Data=@{Created; Skipped; Total}; Error}
    .EXAMPLE
        $decisions = (Get-SPDisconnectedAppCampaignDecisions -AppName 'PEP-Plus').Data
        New-SPRemediationRecord -RevocationDetails $decisions.RevocationDetails -AppName 'PEP-Plus'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$RevocationDetails,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'New-SPRemediationRecord'

    try {
        $appOutputPath = Join-Path -Path $OutputPath -ChildPath $AppName
        if (-not (Test-Path -Path $appOutputPath -PathType Container)) {
            New-Item -Path $appOutputPath -ItemType Directory -Force | Out-Null
        }

        $trackerPath = Join-Path -Path $appOutputPath -ChildPath 'remediation-tracker.json'

        # Load existing tracker or create new
        $tracker = @()
        if (Test-Path -Path $trackerPath -PathType Leaf) {
            $raw = Get-Content -Path $trackerPath -Encoding UTF8 -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json
                $tracker = @($parsed)
            }
        }

        # Build a set of existing keys for duplicate detection
        $existingKeys = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($rec in $tracker) {
            $key = "$($rec.AccountId)|$($rec.Entitlement)|$($rec.CampaignId)"
            [void]$existingKeys.Add($key)
        }

        $createdCount = 0
        $skippedCount = 0
        $newRecords   = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($rev in $RevocationDetails) {
            $accountId   = if ($null -ne $rev['AccountId'])   { [string]$rev['AccountId'] }   else { '' }
            $entitlement = if ($null -ne $rev['Entitlement']) { [string]$rev['Entitlement'] } else { '' }
            $campaignId  = if ($null -ne $rev['CampaignId'])  { [string]$rev['CampaignId'] }  else { '' }

            if ([string]::IsNullOrWhiteSpace($accountId) -and [string]::IsNullOrWhiteSpace($entitlement)) {
                $skippedCount++
                continue
            }

            $key = "$accountId|$entitlement|$campaignId"
            if ($existingKeys.Contains($key)) {
                $skippedCount++
                continue
            }

            $record = [ordered]@{
                RecordId       = [guid]::NewGuid().ToString()
                AppName        = $AppName
                AccountId      = $accountId
                Entitlement    = $entitlement
                IdentityName   = if ($null -ne $rev['IdentityName'])  { [string]$rev['IdentityName'] }  else { '' }
                ReviewerName   = if ($null -ne $rev['ReviewerName'])  { [string]$rev['ReviewerName'] }  else { '' }
                CampaignId     = $campaignId
                CertificationId = if ($null -ne $rev['CertificationId']) { [string]$rev['CertificationId'] } else { '' }
                DecisionDate   = if ($null -ne $rev['DecisionDate'])  { [string]$rev['DecisionDate'] }  else { '' }
                Status         = 'PENDING'
                CreatedAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                ConfirmedAt    = $null
                DaysOverdue    = 0
                EscalatedAt    = $null
                CorrelationID  = $CorrelationID
            }

            $newRecords.Add($record)
            [void]$existingKeys.Add($key)
            $createdCount++
        }

        # Merge and write
        if ($createdCount -gt 0) {
            # Convert existing PSCustomObjects to ordered hashtables for uniform serialization
            $allRecords = [System.Collections.Generic.List[object]]::new()
            foreach ($existing in $tracker) {
                $allRecords.Add($existing)
            }
            foreach ($nr in $newRecords) {
                $allRecords.Add($nr)
            }

            $json = $allRecords | ConvertTo-Json -Depth 5
            # Single-item arrays lose their array wrapper in PS -- force array syntax
            if ($allRecords.Count -eq 1) {
                $json = "[$json]"
            }
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($trackerPath, $json, $utf8NoBom)
        }

        Write-SPLog -Message "Remediation records for '$AppName': $createdCount created, $skippedCount skipped, $($tracker.Count + $createdCount) total" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Created = $createdCount
                Skipped = $skippedCount
                Total   = $tracker.Count + $createdCount
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "New-SPRemediationRecord failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Update-SPRemediationStatus {
    <#
    .SYNOPSIS
        Checks today's CSV to confirm or flag overdue remediations.
    .DESCRIPTION
        Reads the remediation-tracker.json for an app, then inspects the current
        account CSV to verify whether revoked entitlements have been removed by the
        app team. Updates remediation status:

        - PENDING -> CONFIRMED: the entitlement is absent from today's CSV for that account
        - PENDING -> OVERDUE: the entitlement is still present and OverdueDays threshold exceeded
        - OVERDUE stays OVERDUE with incremented DaysOverdue counter
        - CONFIRMED and ESCALATED records are not modified

        This function should be called AFTER today's CSV snapshot has been saved.
    .PARAMETER AppName
        Application name. Used to locate the remediation tracker and CSV.
    .PARAMETER AccountFilePath
        Path to today's account CSV file (the same file used for delta detection).
    .PARAMETER OutputPath
        Base directory for reports. Tracker at {OutputPath}/{AppName}/remediation-tracker.json.
    .PARAMETER OverdueDays
        Number of days after the decision date before a remediation is marked OVERDUE.
        Default: 3.
    .PARAMETER GroupsColumn
        Column name in the CSV containing comma-separated entitlement IDs. Default: 'groups'.
    .PARAMETER IdColumn
        Column name in the CSV used as the unique account identifier. Default: 'id'.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success; Data=@{Confirmed; Overdue; Pending; Escalated; Total}; Error}
    .EXAMPLE
        Update-SPRemediationStatus -AppName 'PEP-Plus' -AccountFilePath '.\Imports\PEP-Plus\accounts.csv'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AccountFilePath,

        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [ValidateRange(1, 365)]
        [int]$OverdueDays = 3,

        [Parameter()]
        [string]$GroupsColumn = 'groups',

        [Parameter()]
        [string]$IdColumn = 'id',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Update-SPRemediationStatus'

    try {
        $appOutputPath = Join-Path -Path $OutputPath -ChildPath $AppName
        $trackerPath   = Join-Path -Path $appOutputPath -ChildPath 'remediation-tracker.json'

        if (-not (Test-Path -Path $trackerPath -PathType Leaf)) {
            Write-SPLog -Message "No remediation tracker found for '$AppName'. Nothing to update." `
                -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{ Confirmed = 0; Overdue = 0; Pending = 0; Escalated = 0; Total = 0 }
                Error   = $null
            }
        }

        if (-not (Test-Path -Path $AccountFilePath -PathType Leaf)) {
            $errMsg = "Account file not found: $AccountFilePath"
            Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
                -Action $action -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # Load tracker
        $raw = Get-Content -Path $trackerPath -Encoding UTF8 -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{
                Success = $true
                Data    = @{ Confirmed = 0; Overdue = 0; Pending = 0; Escalated = 0; Total = 0 }
                Error   = $null
            }
        }
        $tracker = @(ConvertFrom-Json -InputObject $raw)

        # Parse today's CSV into a lookup: AccountId -> Set of entitlements
        $csvData = Import-Csv -Path $AccountFilePath -Encoding UTF8
        $accountEntitlements = @{}
        foreach ($row in $csvData) {
            $acctId = $row.$IdColumn
            if ([string]::IsNullOrWhiteSpace($acctId)) { continue }

            $groups = @()
            $groupVal = $row.$GroupsColumn
            if (-not [string]::IsNullOrWhiteSpace($groupVal)) {
                $groups = @($groupVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            }

            $groupSet = @{}
            foreach ($g in $groups) { $groupSet[$g] = $true }
            $accountEntitlements[$acctId] = $groupSet
        }

        $nowUtc        = (Get-Date).ToUniversalTime()
        $confirmedCount = 0
        $overdueCount   = 0
        $pendingCount   = 0
        $escalatedCount = 0
        $modified       = $false

        for ($i = 0; $i -lt $tracker.Count; $i++) {
            $rec = $tracker[$i]
            $status = if ($null -ne $rec.Status) { [string]$rec.Status } else { 'PENDING' }

            # Skip already-confirmed or escalated records
            if ($status -eq 'CONFIRMED') {
                $confirmedCount++
                continue
            }
            if ($status -eq 'ESCALATED') {
                $escalatedCount++
                continue
            }

            $recAccountId   = if ($null -ne $rec.AccountId)   { [string]$rec.AccountId }   else { '' }
            $recEntitlement = if ($null -ne $rec.Entitlement) { [string]$rec.Entitlement } else { '' }

            # Check if the entitlement still exists in today's CSV
            $stillPresent = $false
            if ($accountEntitlements.ContainsKey($recAccountId)) {
                $acctGroups = $accountEntitlements[$recAccountId]
                if ($acctGroups.ContainsKey($recEntitlement)) {
                    $stillPresent = $true
                }
            }
            # Account removed entirely also counts as confirmed (access gone)

            if (-not $stillPresent) {
                # Entitlement removed or account gone -- remediation confirmed
                $rec.Status      = 'CONFIRMED'
                $rec.ConfirmedAt = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
                $tracker[$i]     = $rec
                $confirmedCount++
                $modified = $true
            }
            else {
                # Still present -- check if overdue
                $decisionDateStr = if ($null -ne $rec.DecisionDate) { [string]$rec.DecisionDate } else { '' }
                $daysElapsed = 0

                if (-not [string]::IsNullOrWhiteSpace($decisionDateStr)) {
                    try {
                        $decisionDate = [datetime]::Parse($decisionDateStr).ToUniversalTime()
                        $daysElapsed  = [int][math]::Floor(($nowUtc - $decisionDate).TotalDays)
                    }
                    catch {
                        # Cannot parse decision date -- use CreatedAt as fallback
                        $createdAtStr = if ($null -ne $rec.CreatedAt) { [string]$rec.CreatedAt } else { '' }
                        if (-not [string]::IsNullOrWhiteSpace($createdAtStr)) {
                            try {
                                $createdAt   = [datetime]::Parse($createdAtStr).ToUniversalTime()
                                $daysElapsed = [int][math]::Floor(($nowUtc - $createdAt).TotalDays)
                            }
                            catch { }
                        }
                    }
                }
                else {
                    # No decision date -- fall back to CreatedAt
                    $createdAtStr = if ($null -ne $rec.CreatedAt) { [string]$rec.CreatedAt } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($createdAtStr)) {
                        try {
                            $createdAt   = [datetime]::Parse($createdAtStr).ToUniversalTime()
                            $daysElapsed = [int][math]::Floor(($nowUtc - $createdAt).TotalDays)
                        }
                        catch { }
                    }
                }

                $rec.DaysOverdue = $daysElapsed

                if ($daysElapsed -ge $OverdueDays) {
                    $rec.Status = 'OVERDUE'
                    $overdueCount++
                }
                else {
                    $pendingCount++
                }

                $tracker[$i] = $rec
                $modified = $true
            }
        }

        # Write back if anything changed
        if ($modified) {
            $json = $tracker | ConvertTo-Json -Depth 5
            if ($tracker.Count -eq 1) {
                $json = "[$json]"
            }
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($trackerPath, $json, $utf8NoBom)
        }

        # Write audit event
        $auditEvent = [ordered]@{
            Timestamp    = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            CorrelationID = $CorrelationID
            Action       = 'RemediationStatusUpdate'
            AppName      = $AppName
            Confirmed    = $confirmedCount
            Overdue      = $overdueCount
            Pending      = $pendingCount
            Escalated    = $escalatedCount
            Total        = $tracker.Count
        }

        try {
            $auditPath = Join-Path -Path $appOutputPath -ChildPath 'disconnected-app-audit.jsonl'
            $jsonLine  = $auditEvent | ConvertTo-Json -Depth 5 -Compress
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::AppendAllText($auditPath, "$jsonLine`n", $utf8NoBom)
        }
        catch {
            Write-SPLog -Message "Failed to write remediation audit event: $($_.Exception.Message)" `
                -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Remediation update for '$AppName': Confirmed=$confirmedCount Overdue=$overdueCount Pending=$pendingCount Escalated=$escalatedCount Total=$($tracker.Count)" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Confirmed = $confirmedCount
                Overdue   = $overdueCount
                Pending   = $pendingCount
                Escalated = $escalatedCount
                Total     = $tracker.Count
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Update-SPRemediationStatus failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPRemediationReport {
    <#
    .SYNOPSIS
        Reads the remediation tracker and returns a structured status report.
    .DESCRIPTION
        Loads the per-app remediation-tracker.json and groups records by status.
        Returns summary counts plus detailed lists for PENDING, OVERDUE, and
        recently CONFIRMED records (within the last 7 days).

        This is a read-only function -- it does not modify the tracker file.
    .PARAMETER AppName
        Application name. Used to locate the remediation tracker file.
    .PARAMETER OutputPath
        Base directory for reports. Tracker at {OutputPath}/{AppName}/remediation-tracker.json.
    .PARAMETER RecentDays
        Number of days to include in the "recently confirmed" list. Default: 7.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success; Data=@{Summary; PendingRecords; OverdueRecords;
            RecentlyConfirmed; EscalatedRecords}; Error}
    .EXAMPLE
        $report = Get-SPRemediationReport -AppName 'PEP-Plus'
        $report.Data.OverdueRecords  # items needing follow-up
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [ValidateRange(1, 365)]
        [int]$RecentDays = 7,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Get-SPRemediationReport'

    try {
        $appOutputPath = Join-Path -Path $OutputPath -ChildPath $AppName
        $trackerPath   = Join-Path -Path $appOutputPath -ChildPath 'remediation-tracker.json'

        if (-not (Test-Path -Path $trackerPath -PathType Leaf)) {
            Write-SPLog -Message "No remediation tracker found for '$AppName'." `
                -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{
                    Summary           = @{ Pending = 0; Overdue = 0; Confirmed = 0; Escalated = 0; Total = 0 }
                    PendingRecords    = @()
                    OverdueRecords    = @()
                    RecentlyConfirmed = @()
                    EscalatedRecords  = @()
                }
                Error   = $null
            }
        }

        $raw = Get-Content -Path $trackerPath -Encoding UTF8 -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{
                Success = $true
                Data    = @{
                    Summary           = @{ Pending = 0; Overdue = 0; Confirmed = 0; Escalated = 0; Total = 0 }
                    PendingRecords    = @()
                    OverdueRecords    = @()
                    RecentlyConfirmed = @()
                    EscalatedRecords  = @()
                }
                Error   = $null
            }
        }

        $tracker = @(ConvertFrom-Json -InputObject $raw)

        $pending   = [System.Collections.Generic.List[object]]::new()
        $overdue   = [System.Collections.Generic.List[object]]::new()
        $confirmed = [System.Collections.Generic.List[object]]::new()
        $escalated = [System.Collections.Generic.List[object]]::new()

        $nowUtc        = (Get-Date).ToUniversalTime()
        $recentCutoff  = $nowUtc.AddDays(-$RecentDays)

        foreach ($rec in $tracker) {
            $status = if ($null -ne $rec.Status) { [string]$rec.Status } else { 'PENDING' }

            switch ($status) {
                'PENDING' {
                    $pending.Add($rec)
                }
                'OVERDUE' {
                    $overdue.Add($rec)
                }
                'CONFIRMED' {
                    # Include in recently confirmed if within RecentDays
                    $confirmedAtStr = if ($null -ne $rec.ConfirmedAt) { [string]$rec.ConfirmedAt } else { '' }
                    $includeRecent  = $false
                    if (-not [string]::IsNullOrWhiteSpace($confirmedAtStr)) {
                        try {
                            $confirmedAt = [datetime]::Parse($confirmedAtStr).ToUniversalTime()
                            if ($confirmedAt -ge $recentCutoff) {
                                $includeRecent = $true
                            }
                        }
                        catch { $includeRecent = $true }
                    }
                    else {
                        $includeRecent = $true
                    }
                    if ($includeRecent) {
                        $confirmed.Add($rec)
                    }
                }
                'ESCALATED' {
                    $escalated.Add($rec)
                }
            }
        }

        $confirmedTotal = @($tracker | Where-Object { $_.Status -eq 'CONFIRMED' }).Count

        $resultData = @{
            Summary = @{
                Pending   = $pending.Count
                Overdue   = $overdue.Count
                Confirmed = $confirmedTotal
                Escalated = $escalated.Count
                Total     = $tracker.Count
            }
            PendingRecords    = $pending.ToArray()
            OverdueRecords    = $overdue.ToArray()
            RecentlyConfirmed = $confirmed.ToArray()
            EscalatedRecords  = $escalated.ToArray()
        }

        Write-SPLog -Message "Remediation report for '$AppName': Pending=$($pending.Count) Overdue=$($overdue.Count) Confirmed=$confirmedTotal Escalated=$($escalated.Count)" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $resultData; Error = $null }
    }
    catch {
        $errMsg = "Get-SPRemediationReport failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region DA-24: ISC Source Aggregation (CSV Upload)

function Push-SPDisconnectedAppToISC {
    <#
    .SYNOPSIS
        Pushes validated CSV files to ISC for source aggregation.
    .DESCRIPTION
        Uploads account (and optionally entitlement) CSV files to an ISC source
        so that ISC's data model reflects the disconnected app's current state.
        Supports two methods: API upload (multipart/form-data to the load-accounts
        endpoint) and FileDrop (copy to a VA-accessible path).
        Gracefully skips if ISCSourceId is not configured.
    .PARAMETER AppName
        Name of the disconnected app.
    .PARAMETER AccountFilePath
        Path to the validated account CSV file.
    .PARAMETER EntitlementFilePath
        Optional path to the entitlement CSV file.
    .PARAMETER ISCSourceId
        ISC source ID to upload to. If empty, upload is skipped.
    .PARAMETER UploadMethod
        Upload method: API (default) or FileDrop.
    .PARAMETER FileDropPath
        Destination directory for FileDrop method (VA-accessible share).
    .PARAMETER WaitForAggregation
        Poll ISC task status until aggregation completes.
    .PARAMETER WaitTimeoutSeconds
        Maximum seconds to wait for aggregation completion. Default: 120.
    .PARAMETER CorrelationID
        Unique ID for log correlation.
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=[hashtable]; Error=[string]}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$AppName,

        [Parameter(Mandatory)]
        [string]$AccountFilePath,

        [Parameter()]
        [string]$EntitlementFilePath,

        [Parameter()]
        [string]$ISCSourceId,

        [Parameter()]
        [ValidateSet('API', 'FileDrop')]
        [string]$UploadMethod = 'API',

        [Parameter()]
        [string]$FileDropPath,

        [Parameter()]
        [switch]$WaitForAggregation,

        [Parameter()]
        [int]$WaitTimeoutSeconds = 120,

        [Parameter()]
        [string]$CorrelationID
    )

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Push-SPDisconnectedAppToISC'

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Skip gracefully if no ISCSourceId configured
    if ([string]::IsNullOrWhiteSpace($ISCSourceId)) {
        Write-SPLog -Message "ISC upload skipped for '$AppName': no ISCSourceId configured" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
        return @{
            Success = $true
            Data    = @{
                AppName           = $AppName
                Method            = 'Skipped'
                TaskId            = $null
                EntitlementTaskId = $null
                UploadedAt        = $null
                AggregationStatus = 'Skipped'
                Reason            = 'NoISCSourceId'
            }
            Error   = $null
        }
    }

    # Validate account file exists
    if (-not (Test-Path -Path $AccountFilePath -PathType Leaf)) {
        $errMsg = "Account file not found: $AccountFilePath"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }

    try {
        if ($UploadMethod -eq 'FileDrop') {
            return Invoke-SPISCFileDrop -AppName $AppName `
                -AccountFilePath $AccountFilePath `
                -EntitlementFilePath $EntitlementFilePath `
                -FileDropPath $FileDropPath `
                -CorrelationID $CorrelationID
        }

        # --- API Upload Method ---
        $authResult = Get-SPAuthToken -CorrelationID $CorrelationID
        if (-not $authResult.Success) {
            throw "Auth token acquisition failed: $($authResult.Error)"
        }

        $config  = Get-SPConfig
        $baseUrl = $config.Api.BaseUrl.TrimEnd('/')
        $timeout = if ($config.Api.TimeoutSeconds) { $config.Api.TimeoutSeconds } else { 120 }

        # Upload accounts CSV
        $accountTaskId = Invoke-SPISCMultipartUpload `
            -BaseUrl $baseUrl `
            -SourceId $ISCSourceId `
            -FilePath $AccountFilePath `
            -FileType 'accounts' `
            -AuthHeaders $authResult.Data.Headers `
            -TimeoutSeconds $timeout `
            -CorrelationID $CorrelationID

        Write-SPLog -Message "Account CSV uploaded for '$AppName' to source '$ISCSourceId'. TaskId=$accountTaskId" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        # Upload entitlements CSV if provided
        $entitlementTaskId = $null
        if (-not [string]::IsNullOrWhiteSpace($EntitlementFilePath) -and
            (Test-Path -Path $EntitlementFilePath -PathType Leaf)) {

            $entitlementTaskId = Invoke-SPISCMultipartUpload `
                -BaseUrl $baseUrl `
                -SourceId $ISCSourceId `
                -FilePath $EntitlementFilePath `
                -FileType 'entitlements' `
                -AuthHeaders $authResult.Data.Headers `
                -TimeoutSeconds $timeout `
                -CorrelationID $CorrelationID

            Write-SPLog -Message "Entitlement CSV uploaded for '$AppName'. TaskId=$entitlementTaskId" `
                -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
        }

        $uploadedAt = (Get-Date).ToUniversalTime()
        $aggStatus  = 'QUEUED'

        # Poll aggregation status if requested
        if ($WaitForAggregation -and -not [string]::IsNullOrWhiteSpace($accountTaskId)) {
            $aggStatus = Wait-SPISCAggregation `
                -TaskId $accountTaskId `
                -AuthHeaders $authResult.Data.Headers `
                -BaseUrl $baseUrl `
                -TimeoutSeconds $WaitTimeoutSeconds `
                -CorrelationID $CorrelationID
        }

        return @{
            Success = $true
            Data    = @{
                AppName           = $AppName
                Method            = 'API'
                TaskId            = $accountTaskId
                EntitlementTaskId = $entitlementTaskId
                UploadedAt        = $uploadedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
                AggregationStatus = $aggStatus
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Push-SPDisconnectedAppToISC failed for '$AppName': $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}


function Invoke-SPISCMultipartUpload {
    <#
    .SYNOPSIS
        Sends a CSV file to ISC via multipart/form-data upload (PS 5.1 compatible).
    .DESCRIPTION
        Constructs a multipart body as a byte array and posts to the ISC beta
        load-accounts or load-entitlements endpoint. Returns the task ID from
        the ISC response.
    .OUTPUTS
        [string] Task ID returned by ISC, or $null if not provided.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][ValidateSet('accounts', 'entitlements')][string]$FileType,
        [Parameter(Mandatory)][hashtable]$AuthHeaders,
        [Parameter()][int]$TimeoutSeconds = 120,
        [Parameter()][string]$CorrelationID
    )

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Invoke-SPISCMultipartUpload'

    $endpoint  = if ($FileType -eq 'accounts') { 'load-accounts' } else { 'load-entitlements' }
    $uploadUrl = "$BaseUrl/beta/sources/$SourceId/$endpoint"

    # Build PS 5.1-compatible multipart/form-data body
    $boundary    = [guid]::NewGuid().ToString()
    $fileName    = [System.IO.Path]::GetFileName($FilePath)
    $fileContent = [System.IO.File]::ReadAllBytes($FilePath)
    $enc         = [System.Text.Encoding]::UTF8

    $headerStr = "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$fileName`"`r`nContent-Type: text/csv`r`n`r`n"
    $footerStr = "`r`n--$boundary--`r`n"

    $headerBytes = $enc.GetBytes($headerStr)
    $footerBytes = $enc.GetBytes($footerStr)

    $bodyBytes = New-Object byte[] ($headerBytes.Length + $fileContent.Length + $footerBytes.Length)
    [System.Buffer]::BlockCopy($headerBytes, 0, $bodyBytes, 0, $headerBytes.Length)
    [System.Buffer]::BlockCopy($fileContent, 0, $bodyBytes, $headerBytes.Length, $fileContent.Length)
    [System.Buffer]::BlockCopy($footerBytes, 0, $bodyBytes, ($headerBytes.Length + $fileContent.Length), $footerBytes.Length)

    Write-SPLog -Message "Uploading $FileType CSV to ISC: $uploadUrl ($($fileContent.Length) bytes)" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    $headers = @{}
    foreach ($key in $AuthHeaders.Keys) {
        $headers[$key] = $AuthHeaders[$key]
    }

    $response = Invoke-RestMethod -Method POST -Uri $uploadUrl `
        -Headers $headers `
        -ContentType "multipart/form-data; boundary=$boundary" `
        -Body $bodyBytes `
        -TimeoutSec $TimeoutSeconds `
        -ErrorAction Stop

    # Extract task ID from response (handles both {task:{id:...}} and {id:...})
    $taskId = $null
    if ($null -ne $response) {
        if ($response -is [hashtable]) {
            if ($response.ContainsKey('task')) {
                $taskId = if ($response.task -is [hashtable]) { $response.task['id'] } else { $response.task.id }
            }
            elseif ($response.ContainsKey('id')) {
                $taskId = $response['id']
            }
        }
        elseif ($null -ne $response.PSObject) {
            if ($response.PSObject.Properties.Name -contains 'task') {
                $taskId = $response.task.id
            }
            elseif ($response.PSObject.Properties.Name -contains 'id') {
                $taskId = $response.id
            }
        }
    }

    Write-SPLog -Message "Upload complete: $FileType -> TaskId=$taskId" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    return $taskId
}


function Invoke-SPISCFileDrop {
    <#
    .SYNOPSIS
        Copies CSV files to a VA-accessible path for file-based aggregation.
    .DESCRIPTION
        Copies account (and optionally entitlement) CSV files to a configured
        directory that a Virtual Appliance monitors for aggregation. Creates
        per-app subdirectories automatically.
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=[hashtable]; Error=[string]}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$AccountFilePath,
        [Parameter()][string]$EntitlementFilePath,
        [Parameter()][string]$FileDropPath,
        [Parameter()][string]$CorrelationID
    )

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Invoke-SPISCFileDrop'

    if ([string]::IsNullOrWhiteSpace($FileDropPath)) {
        $errMsg = "FileDropPath is required for FileDrop upload method"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }

    try {
        # Ensure per-app destination directory exists
        $appDropDir = Join-Path $FileDropPath $AppName
        if (-not (Test-Path -Path $appDropDir)) {
            New-Item -Path $appDropDir -ItemType Directory -Force | Out-Null
        }

        # Copy account file
        $acctDest = Join-Path $appDropDir 'accounts.csv'
        Copy-Item -Path $AccountFilePath -Destination $acctDest -Force
        Write-SPLog -Message "Account CSV copied to file drop: $acctDest" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        # Copy entitlement file if provided
        $entDest = $null
        if (-not [string]::IsNullOrWhiteSpace($EntitlementFilePath) -and
            (Test-Path -Path $EntitlementFilePath -PathType Leaf)) {
            $entDest = Join-Path $appDropDir 'entitlements.csv'
            Copy-Item -Path $EntitlementFilePath -Destination $entDest -Force
            Write-SPLog -Message "Entitlement CSV copied to file drop: $entDest" `
                -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
        }

        return @{
            Success = $true
            Data    = @{
                AppName           = $AppName
                Method            = 'FileDrop'
                TaskId            = $null
                EntitlementTaskId = $null
                UploadedAt        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                AggregationStatus = 'FileDropped'
                AccountPath       = $acctDest
                EntitlementPath   = $entDest
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "FileDrop failed for '$AppName': $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}


function Wait-SPISCAggregation {
    <#
    .SYNOPSIS
        Polls ISC task status until aggregation completes or times out.
    .DESCRIPTION
        Checks the ISC beta task-status endpoint at 5-second intervals until
        the task reaches a terminal state (SUCCESS, ERROR) or the timeout expires.
    .OUTPUTS
        [string] Final status: COMPLETED, FAILED, or TIMEOUT.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][hashtable]$AuthHeaders,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter()][int]$TimeoutSeconds = 120,
        [Parameter()][string]$CorrelationID
    )

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Wait-SPISCAggregation'

    Write-SPLog -Message "Waiting for aggregation task '$TaskId' (timeout: ${TimeoutSeconds}s)" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    $pollUrl   = "$BaseUrl/beta/task-status/$TaskId"
    $deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
    $pollDelay = 5

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $pollDelay

        try {
            $headers = @{}
            foreach ($key in $AuthHeaders.Keys) {
                $headers[$key] = $AuthHeaders[$key]
            }

            $status = Invoke-RestMethod -Method GET -Uri $pollUrl `
                -Headers $headers -TimeoutSec 30 -ErrorAction Stop

            $completionStatus = $null
            if ($null -ne $status) {
                if ($status -is [hashtable]) {
                    $completionStatus = $status['completionStatus']
                }
                elseif ($null -ne $status.PSObject) {
                    $completionStatus = $status.completionStatus
                }
            }

            if ($completionStatus -eq 'SUCCESS') {
                Write-SPLog -Message "Aggregation task '$TaskId' completed successfully" `
                    -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
                return 'COMPLETED'
            }

            if ($completionStatus -in @('ERROR', 'FAILED')) {
                Write-SPLog -Message "Aggregation task '$TaskId' failed: $completionStatus" `
                    -Severity ERROR -Component $component -Action $action -CorrelationID $CorrelationID
                return 'FAILED'
            }

            Write-SPLog -Message "Aggregation task '$TaskId' status: $completionStatus -- polling..." `
                -Severity DEBUG -Component $component -Action $action -CorrelationID $CorrelationID
        }
        catch {
            Write-SPLog -Message "Error polling aggregation task '$TaskId': $($_.Exception.Message)" `
                -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
        }
    }

    Write-SPLog -Message "Aggregation task '$TaskId' timed out after ${TimeoutSeconds}s" `
        -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID

    return 'TIMEOUT'
}

#endregion

#region DA-25: Operational Alerting

function Send-SPDisconnectedAppAlert {
    <#
    .SYNOPSIS
        Sends operational alerts for the disconnected app pipeline.
    .DESCRIPTION
        Dispatches formatted alerts through the toolkit's notification backends
        (SMTP, Webhook) for pipeline events: validation failures, threshold blocks,
        chronic delivery misses, overdue remediations, and batch-level failures.

        Delegates to Send-SPNotification from SP.AuditReport when available.
        Falls back to Write-SPLog if notification backends are not configured
        or the SP.Audit module is not loaded.

        Alert severity mapping:
        - WARN    -> Send-SPNotification -Severity Warning
        - CRITICAL -> Send-SPNotification -Severity Critical
        - INFO    -> Send-SPNotification -Severity Info

    .PARAMETER AlertType
        The type of alert event. Used to build the subject line and classify the alert.
        Valid values: ValidationFailed, ThresholdBlocked, DeliveryMissing,
        RemediationOverdue, BatchAllFailed, BatchPartialFailure, BatchSummary.
    .PARAMETER Severity
        Alert severity: INFO, WARN, or CRITICAL.
    .PARAMETER AppName
        Application name related to this alert. Omit for batch-level alerts.
    .PARAMETER Message
        Human-readable description of the alert condition.
    .PARAMETER Details
        Hashtable of structured details included in the alert body and webhook metadata.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success; Data=@{Backend; Dispatched}; Error}
    .EXAMPLE
        Send-SPDisconnectedAppAlert -AlertType ThresholdBlocked -Severity CRITICAL `
            -AppName 'PEP-Plus' -Message '42% accounts removed (threshold: 20%)'
    .EXAMPLE
        Send-SPDisconnectedAppAlert -AlertType BatchAllFailed -Severity CRITICAL `
            -Message 'All 5 apps failed processing' -Details @{ErrorCount=5; Apps=@('A','B','C','D','E')}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ValidationFailed', 'ThresholdBlocked', 'DeliveryMissing',
                     'RemediationOverdue', 'BatchAllFailed', 'BatchPartialFailure',
                     'BatchSummary')]
        [string]$AlertType,

        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'WARN', 'CRITICAL')]
        [string]$Severity,

        [Parameter()]
        [string]$AppName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [hashtable]$Details,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Send-SPDisconnectedAppAlert'

    # Build subject line
    $severityTag = switch ($Severity) {
        'CRITICAL' { 'CRITICAL' }
        'WARN'     { 'WARNING' }
        default    { 'INFO' }
    }
    $appTag = if (-not [string]::IsNullOrWhiteSpace($AppName)) { " - $AppName" } else { '' }
    $subject = "[SailPoint DisconnectedApps] [$severityTag] $AlertType$appTag"

    # Build plain-text body for logging
    $bodyLines = [System.Collections.Generic.List[string]]::new()
    $bodyLines.Add("Alert Type: $AlertType")
    $bodyLines.Add("Severity:   $Severity")
    if (-not [string]::IsNullOrWhiteSpace($AppName)) {
        $bodyLines.Add("App:        $AppName")
    }
    $bodyLines.Add("Message:    $Message")
    $bodyLines.Add("Timestamp:  $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
    $bodyLines.Add("CorrelationID: $CorrelationID")

    if ($null -ne $Details -and $Details.Count -gt 0) {
        $bodyLines.Add('')
        $bodyLines.Add('Details:')
        foreach ($key in $Details.Keys | Sort-Object) {
            $val = $Details[$key]
            if ($val -is [array]) {
                $val = ($val -join ', ')
            }
            $bodyLines.Add("  $key = $val")
        }
    }

    # Build HTML body for email
    $htmlBody = @"
<html><body style="font-family: Segoe UI, Arial, sans-serif; font-size: 14px; color: #333;">
<h2 style="color: $(switch ($Severity) { 'CRITICAL' { '#CC3333' } 'WARN' { '#FF6600' } default { '#336699' } });">$([System.Net.WebUtility]::HtmlEncode($subject))</h2>
<table style="border-collapse: collapse; margin: 16px 0;">
<tr><td style="padding: 4px 12px 4px 0; font-weight: bold;">Alert Type</td><td style="padding: 4px 0;">$([System.Net.WebUtility]::HtmlEncode($AlertType))</td></tr>
<tr><td style="padding: 4px 12px 4px 0; font-weight: bold;">Severity</td><td style="padding: 4px 0;">$([System.Net.WebUtility]::HtmlEncode($Severity))</td></tr>
$(if (-not [string]::IsNullOrWhiteSpace($AppName)) { "<tr><td style='padding: 4px 12px 4px 0; font-weight: bold;'>Application</td><td style='padding: 4px 0;'>$([System.Net.WebUtility]::HtmlEncode($AppName))</td></tr>" })
<tr><td style="padding: 4px 12px 4px 0; font-weight: bold;">Message</td><td style="padding: 4px 0;">$([System.Net.WebUtility]::HtmlEncode($Message))</td></tr>
<tr><td style="padding: 4px 12px 4px 0; font-weight: bold;">Timestamp</td><td style="padding: 4px 0;">$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))</td></tr>
<tr><td style="padding: 4px 12px 4px 0; font-weight: bold;">CorrelationID</td><td style="padding: 4px 0;">$CorrelationID</td></tr>
</table>
"@

    if ($null -ne $Details -and $Details.Count -gt 0) {
        $htmlBody += "<h3 style='margin-top: 16px;'>Details</h3>`n<table style='border-collapse: collapse;'>`n"
        foreach ($key in $Details.Keys | Sort-Object) {
            $val = $Details[$key]
            if ($val -is [array]) {
                $val = ($val -join ', ')
            }
            $htmlBody += "<tr><td style='padding: 4px 12px 4px 0; font-weight: bold;'>$([System.Net.WebUtility]::HtmlEncode($key))</td>"
            $htmlBody += "<td style='padding: 4px 0;'>$([System.Net.WebUtility]::HtmlEncode([string]$val))</td></tr>`n"
        }
        $htmlBody += "</table>`n"
    }

    $htmlBody += @"
<hr style="margin-top: 24px; border: none; border-top: 1px solid #ccc;" />
<p style="font-size: 12px; color: #999;">SailPoint ISC Governance Toolkit -- Disconnected App Pipeline</p>
</body></html>
"@

    # Map severity for Send-SPNotification
    $notifySeverity = switch ($Severity) {
        'CRITICAL' { 'Critical' }
        'WARN'     { 'Warning' }
        default    { 'Info' }
    }

    # Always log the alert
    $logSeverity = switch ($Severity) {
        'CRITICAL' { 'ERROR' }
        'WARN'     { 'WARN' }
        default    { 'INFO' }
    }
    Write-SPLog -Message "ALERT [$AlertType] $Message" `
        -Severity $logSeverity -Component $component -Action $action -CorrelationID $CorrelationID

    # Try to dispatch via Send-SPNotification
    $dispatched = $false
    $notifyError = $null

    $notifyCmdAvailable = $null -ne (Get-Command -Name 'Send-SPNotification' -ErrorAction SilentlyContinue)

    if ($notifyCmdAvailable) {
        try {
            $notifyParams = @{
                Subject       = $subject
                Body          = $htmlBody
                Severity      = $notifySeverity
                Category      = 'DisconnectedApp'
                CorrelationID = $CorrelationID
                Metadata      = @{
                    AlertType = $AlertType
                    AppName   = if ($AppName) { $AppName } else { '' }
                }
            }
            if ($null -ne $Details) {
                foreach ($key in $Details.Keys) {
                    $notifyParams.Metadata[$key] = $Details[$key]
                }
            }

            $notifyResult = Send-SPNotification @notifyParams

            if ($notifyResult.Success) {
                $dispatched = $true
                Write-SPLog -Message "Alert dispatched via Send-SPNotification: $subject" `
                    -Severity DEBUG -Component $component -Action $action -CorrelationID $CorrelationID
            }
            else {
                $notifyError = "Notification dispatch returned failure"
                Write-SPLog -Message "Send-SPNotification returned failure for alert '$AlertType'" `
                    -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
            }
        }
        catch {
            $notifyError = $_.Exception.Message
            Write-SPLog -Message "Send-SPNotification failed: $($_.Exception.Message)" `
                -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
        }
    }
    else {
        Write-SPLog -Message "Send-SPNotification not available; alert logged only: $subject" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
    }

    return @{
        Success = $true
        Data    = @{
            Backend    = if ($dispatched) { 'Notification' } else { 'LogOnly' }
            Dispatched = $dispatched
            Subject    = $subject
            Severity   = $Severity
            AlertType  = $AlertType
        }
        Error   = $notifyError
    }
}

#endregion

#region DA-26: Campaign Lifecycle Management (Cleanup)

function Invoke-SPDisconnectedAppCleanup {
    <#
    .SYNOPSIS
        Completes past-due disconnected app campaigns to prevent ISC campaign pile-up.
    .DESCRIPTION
        Ports the AD delta cert cleanup pattern to disconnected app campaigns.
        For each registered app, searches for ACTIVE campaigns matching the app's
        CampaignNamePrefix, evaluates deadline/staleness, and completes past-due
        campaigns via Complete-SPCampaign.

        Guarded by Safety.AllowCompleteCampaign (default false).

        Intended to run as a pre-step before new campaign creation in the batch
        orchestrator, preventing duplicate/stale campaign accumulation.
    .PARAMETER AppNames
        Optional filter: only clean up campaigns for these app names.
        If omitted, all enabled registered apps are checked.
    .PARAMETER DaysStale
        Days after creation (without a deadline) before a campaign is considered
        stale. Default: 3.
    .PARAMETER ConfigPath
        Path to settings.json. Uses Resolve-SPConfigPath if omitted.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                AppsChecked = [int]
                TotalCompleted = [int]
                TotalStillActive = [int]
                TotalErrors = [int]
                PerApp = @(
                    @{ AppName; Completed; StillActive; Errors }
                )
            }
            Error   = $string
        }
    .EXAMPLE
        Invoke-SPDisconnectedAppCleanup -DaysStale 3
    .EXAMPLE
        Invoke-SPDisconnectedAppCleanup -AppNames @('PEP-Plus') -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$AppNames,

        [Parameter()]
        [int]$DaysStale = 3,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Invoke-SPDisconnectedAppCleanup'

    Write-SPLog -Message "Invoke-SPDisconnectedAppCleanup: DaysStale=$DaysStale WhatIf=$(($WhatIfPreference -eq $true))" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    try {
        # Safety guard: check AllowCompleteCampaign before any API calls
        $config = Get-SPConfig
        $allowComplete = $false
        if ($null -ne $config -and
            $null -ne $config.PSObject.Properties['Safety'] -and
            $null -ne $config.Safety -and
            $config.Safety.PSObject.Properties.Name -contains 'AllowCompleteCampaign') {
            $allowComplete = [bool]$config.Safety.AllowCompleteCampaign
        }
        if (-not $allowComplete) {
            $errMsg = "Invoke-SPDisconnectedAppCleanup blocked: Safety.AllowCompleteCampaign is false in settings.json. " +
                      "Set to true to allow campaign completion."
            Write-SPLog -Message $errMsg -Severity WARN -Component $component -Action $action `
                -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # Load registered apps
        $loadParams = @{}
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
            $loadParams['ConfigPath'] = $ConfigPath
        }
        $appsResult = Get-SPRegisteredApps @loadParams
        if (-not $appsResult.Success) {
            return @{ Success = $false; Data = $null; Error = "Failed to load registered apps: $($appsResult.Error)" }
        }

        $apps = @($appsResult.Data)
        if ($apps.Count -eq 0) {
            return @{
                Success = $true
                Data    = @{
                    AppsChecked      = 0
                    TotalCompleted   = 0
                    TotalStillActive = 0
                    TotalErrors      = 0
                    PerApp           = @()
                }
                Error   = $null
            }
        }

        # Filter by AppNames if specified
        if ($AppNames -and $AppNames.Count -gt 0) {
            $apps = @($apps | Where-Object { $_.Name -in $AppNames })
        }

        $nowUtc         = (Get-Date).ToUniversalTime()
        $staleThreshold = $nowUtc.AddDays(-$DaysStale)

        $totalCompleted   = 0
        $totalStillActive = 0
        $totalErrors      = 0
        $perAppResults    = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($app in $apps) {
            $appName = $app.Name

            # Determine the campaign name prefix for this app
            $appPrefix = $null
            if ($null -ne $app.PSObject.Properties['CampaignNamePrefix'] -and
                -not [string]::IsNullOrWhiteSpace($app.CampaignNamePrefix)) {
                $appPrefix = $app.CampaignNamePrefix
            }
            else {
                $appPrefix = "$appName Delta Cert"
            }

            Write-SPLog -Message "Checking app '$appName' with prefix '$appPrefix'" `
                -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

            # Search for active campaigns matching this app's prefix
            $searchResult = Search-SPCampaigns -Keyword $appPrefix -Status @('ACTIVE') `
                -CorrelationID $CorrelationID

            if (-not $searchResult.Success) {
                $errMsg = "Campaign search failed for app '$appName': $($searchResult.Error)"
                Write-SPLog -Message $errMsg -Severity WARN -Component $component -Action $action `
                    -CorrelationID $CorrelationID
                $totalErrors++
                $perAppResults.Add(@{
                    AppName     = $appName
                    Completed   = @()
                    StillActive = @()
                    Errors      = @($errMsg)
                })
                continue
            }

            $activeCampaigns = @($searchResult.Data)

            if ($activeCampaigns.Count -eq 0) {
                $perAppResults.Add(@{
                    AppName     = $appName
                    Completed   = @()
                    StillActive = @()
                    Errors      = @()
                })
                continue
            }

            $completed   = [System.Collections.Generic.List[string]]::new()
            $stillActive = [System.Collections.Generic.List[string]]::new()
            $errors      = [System.Collections.Generic.List[string]]::new()

            foreach ($campaign in $activeCampaigns) {
                $campaignId   = $campaign.id
                $campaignName = $campaign.name
                $isStale      = $false

                # Check if deadline has passed
                $deadlineStr = $null
                if ($campaign -is [PSCustomObject] -and $campaign.PSObject.Properties.Name -contains 'deadline') {
                    $deadlineStr = $campaign.deadline
                }
                elseif ($campaign -is [hashtable] -and $campaign.ContainsKey('deadline')) {
                    $deadlineStr = $campaign['deadline']
                }

                if (-not [string]::IsNullOrWhiteSpace($deadlineStr)) {
                    try {
                        $deadline = [datetime]::Parse([string]$deadlineStr).ToUniversalTime()
                        if ($deadline -lt $nowUtc) {
                            $isStale = $true
                        }
                    }
                    catch {
                        Write-SPLog -Message "Failed to parse deadline for campaign '$campaignName': $($_.Exception.Message)" `
                            -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
                    }
                }

                # Fallback: check if created date is older than DaysStale
                if (-not $isStale) {
                    $createdStr = $null
                    if ($campaign -is [PSCustomObject] -and $campaign.PSObject.Properties.Name -contains 'created') {
                        $createdStr = $campaign.created
                    }
                    elseif ($campaign -is [hashtable] -and $campaign.ContainsKey('created')) {
                        $createdStr = $campaign['created']
                    }

                    if (-not [string]::IsNullOrWhiteSpace($createdStr)) {
                        try {
                            $created = [datetime]::Parse([string]$createdStr).ToUniversalTime()
                            if ($created -lt $staleThreshold) {
                                $isStale = $true
                            }
                        }
                        catch {
                            Write-SPLog -Message "Failed to parse created date for campaign '$campaignName': $($_.Exception.Message)" `
                                -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
                        }
                    }
                }

                if (-not $isStale) {
                    $stillActive.Add($campaignId)
                    continue
                }

                # WhatIf: describe without completing
                if (($WhatIfPreference -eq $true)) {
                    Write-SPLog -Message "WhatIf: Would complete stale campaign '$campaignName' ($campaignId) for app '$appName'" `
                        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
                    $completed.Add($campaignId)
                    continue
                }

                # Complete the stale campaign
                Write-SPLog -Message "Completing stale campaign '$campaignName' ($campaignId) for app '$appName'" `
                    -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

                $completeResult = Complete-SPCampaign -CampaignId $campaignId -CorrelationID $CorrelationID

                if ($completeResult.Success) {
                    $completed.Add($campaignId)
                }
                else {
                    $errMsg = "Failed to complete campaign '$campaignName' ($campaignId): $($completeResult.Error)"
                    Write-SPLog -Message $errMsg -Severity ERROR -Component $component -Action $action `
                        -CorrelationID $CorrelationID
                    $errors.Add($errMsg)
                }
            }

            $totalCompleted   += $completed.Count
            $totalStillActive += $stillActive.Count
            $totalErrors      += $errors.Count

            $perAppResults.Add(@{
                AppName     = $appName
                Completed   = $completed.ToArray()
                StillActive = $stillActive.ToArray()
                Errors      = $errors.ToArray()
            })

            if ($completed.Count -gt 0) {
                Write-SPLog -Message "App '$appName': completed $($completed.Count) stale campaign(s), $($stillActive.Count) still active" `
                    -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
            }
        }

        Write-SPLog -Message "Invoke-SPDisconnectedAppCleanup complete: Apps=$($apps.Count) Completed=$totalCompleted StillActive=$totalStillActive Errors=$totalErrors" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        $allErrors = @($perAppResults | ForEach-Object { $_.Errors } | Where-Object { $_.Count -gt 0 } | ForEach-Object { $_ })

        return @{
            Success = $true
            Data    = @{
                AppsChecked      = $apps.Count
                TotalCompleted   = $totalCompleted
                TotalStillActive = $totalStillActive
                TotalErrors      = $totalErrors
                PerApp           = @($perAppResults)
            }
            Error   = if ($allErrors.Count -gt 0) { $allErrors -join '; ' } else { $null }
        }
    }
    catch {
        $errMsg = "Invoke-SPDisconnectedAppCleanup failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component -Action $action `
            -CorrelationID $CorrelationID
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
    'Get-SPDisconnectedAppDeliveryStatus',
    'Get-SPDisconnectedAppIdentityRisk',
    'Export-SPDisconnectedAppIdentityRiskHtml',
    'Get-SPDisconnectedAppEntitlementCatalog',
    'Export-SPDisconnectedAppEntitlementCatalogHtml',
    'Export-SPDisconnectedAppBatchHtml',
    'Get-SPDisconnectedAppSlaStatus',
    'Export-SPDisconnectedAppSlaHtml',
    'Get-SPDisconnectedAppCampaignDecisions',
    'Export-SPDisconnectedAppDecisionHarvestHtml',
    'New-SPRemediationRecord',
    'Update-SPRemediationStatus',
    'Get-SPRemediationReport',
    'Push-SPDisconnectedAppToISC',
    'Send-SPDisconnectedAppAlert',
    'Invoke-SPDisconnectedAppCleanup'
)

#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Disconnected App Runner (Core Pipeline)
.DESCRIPTION
    Core orchestration functions for the disconnected app onboarding kit.
    Resolves file-based account records to ISC identities, creates targeted
    SEARCH campaigns per manager group, manages remediation tracking,
    pushes account/entitlement data to ISC via API or file drop, handles
    operational alerting, campaign cleanup, and escalation.

    Functions:
        1. Resolve-SPDisconnectedAppIdentities - correlates delta accounts to ISC identities
        2. Invoke-SPDisconnectedAppCertRun - creates SEARCH campaigns per manager group
        3. Get-SPRegisteredApps - returns enabled app registrations from config
        4. Initialize-SPDisconnectedAppDirectories - scaffolds per-app directories
        5. New-SPRemediationRecord - creates remediation tracking record
        6. Update-SPRemediationStatus - updates remediation status
        7. Get-SPRemediationReport - generates remediation summary report
        8. Push-SPDisconnectedAppToISC - pushes account/entitlement data to ISC
        9. Invoke-SPISCMultipartUpload - multipart CSV upload to ISC source
       10. Invoke-SPISCFileDrop - drops CSV to ISC file share
       11. Wait-SPISCAggregation - polls ISC aggregation task until complete
       12. Send-SPDisconnectedAppAlert - operational alerting for pipeline events
       13. Invoke-SPDisconnectedAppCleanup - campaign lifecycle cleanup
       14. Invoke-SPDisconnectedAppEscalation - escalates stale disconnected app certs

    Dependencies:
        - SP.Api (Invoke-SPApiRequest)
        - SP.Campaigns (New-SPCampaign, Start-SPCampaign, Search-SPCampaigns)
        - SP.DeltaCertRunner (Build-SPDeltaSearchFilter)
        - SP.DeltaCertQueries (Get-SPDeltaIdentityDetail, Group-SPDeltaByManager)
        - SP.Core (Write-SPLog, Get-SPConfig)

.NOTES
    Module: SP.DisconnectedApps / SP.DisconnectedAppRunner
    Version: 2.0.0
    Component: Core Pipeline
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
                     'RemediationOverdue', 'EscalationTriggered', 'BatchAllFailed',
                     'BatchPartialFailure', 'BatchSummary')]
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

#region DA-28: Disconnected App Escalation

function Invoke-SPDisconnectedAppEscalation {
    <#
    .SYNOPSIS
        Escalates stale disconnected app certifications by reassigning up the org tree.
    .DESCRIPTION
        Applies the existing escalation pattern (Get-SPDeltaCertStaleCertifications +
        Invoke-SPDeltaCertEscalate) to disconnected app campaigns, filtered by each
        app's CampaignNamePrefix.

        For each registered app:
        1. Searches for ACTIVE campaigns matching the app's CampaignNamePrefix
        2. Detects stale certifications (unsigned past StaleHours threshold)
        3. Escalates to the reviewer's manager via Invoke-SPDeltaCertEscalate
        4. Logs escalation actions to per-app JSONL audit trail

        Per-app StaleHours is configurable via the app registration config
        (EscalationStaleHours field). Falls back to 24 hours if not set.
        MaxEscalationLevels defaults to 2.

        Delegates all reassignment logic to SP.DeltaCert module functions.
    .PARAMETER AppNames
        Optional filter: only escalate for these app names.
        If omitted, all enabled registered apps are checked.
    .PARAMETER DefaultStaleHours
        Default hours before a certification is considered stale.
        Overridden by per-app EscalationStaleHours config. Default: 24.
    .PARAMETER MaxEscalationLevels
        Maximum escalation hops from the original reviewer. Default: 2.
    .PARAMETER ConfigPath
        Path to settings.json. Uses Resolve-SPConfigPath if omitted.
    .PARAMETER ReportPath
        Base output path for per-app JSONL audit files.
        Default: .\DisconnectedApps\Reports.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                AppsChecked       = [int]
                TotalStaleCerts   = [int]
                TotalEscalated    = [int]
                TotalSkipped      = [int]
                TotalErrors       = [int]
                PerApp = @(
                    @{
                        AppName; StaleHours; StaleCertsFound;
                        Escalated; Skipped; Errors
                    }
                )
            }
            Error   = $string
        }
    .EXAMPLE
        Invoke-SPDisconnectedAppEscalation
    .EXAMPLE
        Invoke-SPDisconnectedAppEscalation -AppNames @('PEP-Plus') -DefaultStaleHours 12 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$AppNames,

        [Parameter()]
        [int]$DefaultStaleHours = 24,

        [Parameter()]
        [int]$MaxEscalationLevels = 2,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$ReportPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Invoke-SPDisconnectedAppEscalation'

    Write-SPLog -Message "Invoke-SPDisconnectedAppEscalation: DefaultStaleHours=$DefaultStaleHours MaxEscalationLevels=$MaxEscalationLevels WhatIf=$(($WhatIfPreference -eq $true))" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    try {
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
                    AppsChecked     = 0
                    TotalStaleCerts = 0
                    TotalEscalated  = 0
                    TotalSkipped    = 0
                    TotalErrors     = 0
                    PerApp          = @()
                }
                Error   = $null
            }
        }

        # Filter by AppNames if specified
        if ($AppNames -and $AppNames.Count -gt 0) {
            $apps = @($apps | Where-Object { $_.Name -in $AppNames })
        }

        $totalStaleCerts = 0
        $totalEscalated  = 0
        $totalSkipped    = 0
        $totalErrors     = 0
        $perAppResults   = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($app in $apps) {
            $appName = $app.Name

            # Determine per-app StaleHours (fall back to parameter default)
            $appStaleHours = $DefaultStaleHours
            if ($app.PSObject.Properties.Name -contains 'EscalationStaleHours' -and
                $null -ne $app.EscalationStaleHours) {
                $parsed = 0
                if ([int]::TryParse([string]$app.EscalationStaleHours, [ref]$parsed) -and $parsed -gt 0) {
                    $appStaleHours = $parsed
                }
            }

            # Determine per-app MaxEscalationLevels (fall back to parameter default)
            $appMaxLevels = $MaxEscalationLevels
            if ($app.PSObject.Properties.Name -contains 'MaxEscalationLevels' -and
                $null -ne $app.MaxEscalationLevels) {
                $parsedLvl = 0
                if ([int]::TryParse([string]$app.MaxEscalationLevels, [ref]$parsedLvl) -and $parsedLvl -gt 0) {
                    $appMaxLevels = $parsedLvl
                }
            }

            # Determine the campaign name prefix for this app
            $appPrefix = $null
            if ($null -ne $app.PSObject.Properties['CampaignNamePrefix'] -and
                -not [string]::IsNullOrWhiteSpace($app.CampaignNamePrefix)) {
                $appPrefix = $app.CampaignNamePrefix
            }
            else {
                $appPrefix = "$appName Delta Cert"
            }

            Write-SPLog -Message "Checking escalation for app '$appName': prefix='$appPrefix' staleHours=$appStaleHours maxLevels=$appMaxLevels" `
                -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

            # Step 1: Find stale certifications for this app's campaigns
            $staleResult = Get-SPDeltaCertStaleCertifications `
                -CampaignNamePrefix $appPrefix `
                -StaleHours $appStaleHours `
                -CorrelationID $CorrelationID

            if (-not $staleResult.Success) {
                $errMsg = "Stale cert detection failed for app '$appName': $($staleResult.Error)"
                Write-SPLog -Message $errMsg -Severity WARN -Component $component -Action $action `
                    -CorrelationID $CorrelationID
                $totalErrors++
                $perAppResults.Add(@{
                    AppName        = $appName
                    StaleHours     = $appStaleHours
                    StaleCertsFound = 0
                    Escalated      = @()
                    Skipped        = @()
                    Errors         = @($errMsg)
                })
                continue
            }

            $staleCerts = @($staleResult.Data)
            $totalStaleCerts += $staleCerts.Count

            if ($staleCerts.Count -eq 0) {
                Write-SPLog -Message "No stale certifications for app '$appName'" `
                    -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
                $perAppResults.Add(@{
                    AppName        = $appName
                    StaleHours     = $appStaleHours
                    StaleCertsFound = 0
                    Escalated      = @()
                    Skipped        = @()
                    Errors         = @()
                })
                continue
            }

            Write-SPLog -Message "Found $($staleCerts.Count) stale certification(s) for app '$appName' -- escalating" `
                -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

            # Step 2: Escalate via existing SP.DeltaCert function
            $escalateParams = @{
                StaleCertifications = $staleCerts
                MaxEscalationLevels = $appMaxLevels
                CorrelationID       = $CorrelationID
            }

            if ($WhatIfPreference -eq $true) {
                $escalateResult = Invoke-SPDeltaCertEscalate @escalateParams -WhatIf
            }
            else {
                $escalateResult = Invoke-SPDeltaCertEscalate @escalateParams
            }

            $appEscalated = @()
            $appSkipped   = @()
            $appErrors    = @()

            if ($escalateResult.Success -or $null -ne $escalateResult.Data) {
                $appEscalated = @($escalateResult.Data.Escalated)
                $appSkipped   = @($escalateResult.Data.Skipped)
                $appErrors    = @($escalateResult.Data.Errors)
            }
            else {
                $appErrors = @("Escalation failed for app '$appName': $($escalateResult.Error)")
            }

            $totalEscalated += $appEscalated.Count
            $totalSkipped   += $appSkipped.Count
            $totalErrors    += $appErrors.Count

            $perAppResults.Add(@{
                AppName         = $appName
                StaleHours      = $appStaleHours
                StaleCertsFound = $staleCerts.Count
                Escalated       = $appEscalated
                Skipped         = $appSkipped
                Errors          = $appErrors
            })

            # Step 3: Write per-app escalation audit event to JSONL
            try {
                $appOutputPath = Join-Path -Path $ReportPath -ChildPath $appName
                if (-not (Test-Path -Path $appOutputPath -PathType Container)) {
                    New-Item -Path $appOutputPath -ItemType Directory -Force | Out-Null
                }

                $auditEvent = [ordered]@{
                    Timestamp       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    CorrelationID   = $CorrelationID
                    Action          = 'DisconnectedAppEscalation'
                    AppName         = $appName
                    StaleHours      = $appStaleHours
                    MaxEscalationLevels = $appMaxLevels
                    StaleCertsFound = $staleCerts.Count
                    Escalated       = $appEscalated.Count
                    Skipped         = $appSkipped.Count
                    Errors          = $appErrors
                    WhatIf          = ($WhatIfPreference -eq $true)
                }

                $jsonLine = $auditEvent | ConvertTo-Json -Depth 5 -Compress
                $filePath = Join-Path -Path $appOutputPath -ChildPath 'disconnected-app-escalation.jsonl'
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::AppendAllText($filePath, "$jsonLine`n", $utf8NoBom)

                Write-SPLog -Message "Escalation audit event written to $filePath" `
                    -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
            }
            catch {
                Write-SPLog -Message "Failed to write escalation audit JSONL for '$appName': $($_.Exception.Message)" `
                    -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
            }
        }

        Write-SPLog -Message "Invoke-SPDisconnectedAppEscalation complete: Apps=$($apps.Count) StaleCerts=$totalStaleCerts Escalated=$totalEscalated Skipped=$totalSkipped Errors=$totalErrors" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        return @{
            Success = ($totalErrors -eq 0)
            Data    = @{
                AppsChecked     = $apps.Count
                TotalStaleCerts = $totalStaleCerts
                TotalEscalated  = $totalEscalated
                TotalSkipped    = $totalSkipped
                TotalErrors     = $totalErrors
                PerApp          = $perAppResults.ToArray()
            }
            Error   = if ($totalErrors -gt 0) {
                $allErrors = @($perAppResults | ForEach-Object { $_.Errors } | Where-Object { $_.Count -gt 0 } | ForEach-Object { $_ })
                $allErrors -join '; '
            } else { $null }
        }
    }
    catch {
        $errMsg = "Invoke-SPDisconnectedAppEscalation failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Search-SPIdentityByAttribute',
    'Write-SPDisconnectedAppAuditEvent',
    'Resolve-SPDisconnectedAppIdentities',
    'Invoke-SPDisconnectedAppCertRun',
    'Get-SPRegisteredApps',
    'Initialize-SPDisconnectedAppDirectories',
    'New-SPRemediationRecord',
    'Update-SPRemediationStatus',
    'Get-SPRemediationReport',
    'Push-SPDisconnectedAppToISC',
    'Invoke-SPISCMultipartUpload',
    'Invoke-SPISCFileDrop',
    'Wait-SPISCAggregation',
    'Send-SPDisconnectedAppAlert',
    'Invoke-SPDisconnectedAppCleanup',
    'Invoke-SPDisconnectedAppEscalation'
)

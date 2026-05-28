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

    Dependencies:
        - SP.Api (Invoke-SPApiRequest)
        - SP.Campaigns (New-SPCampaign, Start-SPCampaign, Search-SPCampaigns)
        - SP.DeltaCertRunner (Build-SPDeltaSearchFilter)
        - SP.DeltaCertQueries (Get-SPDeltaIdentityDetail, Group-SPDeltaByManager)
        - SP.Core (Write-SPLog, Get-SPConfig)

.NOTES
    Module: SP.DisconnectedAppRunner
    Version: 1.1.0
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

#endregion

Export-ModuleMember -Function @(
    'Resolve-SPDisconnectedAppIdentities',
    'Invoke-SPDisconnectedAppCertRun'
)

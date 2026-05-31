#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Disconnected App Analytics
.DESCRIPTION
    Analytics and data-gathering functions for the disconnected app onboarding kit.
    Provides delivery status checks, identity risk analysis, entitlement catalog
    aggregation, SLA compliance tracking, campaign decision harvesting, trend
    analysis, and compliance package generation.

    Functions:
        1. Get-SPDisconnectedAppDeliveryStatus - checks file delivery freshness per app
        2. Get-SPDisconnectedAppIdentityRisk - cross-app identity risk analysis
        3. Get-SPDisconnectedAppEntitlementCatalog - unified entitlement catalog across apps
        4. Get-SPDisconnectedAppSlaStatus - 30-day SLA tracking from snapshot history
        5. Get-SPDisconnectedAppCampaignDecisions - harvests campaign decisions from ISC
        6. Get-SPDisconnectedAppTrend - trend analysis over time
        7. Export-SPDisconnectedAppCompliancePackage - compliance evidence package

    Dependencies:
        - SP.DisconnectedAppRunner (Get-SPRegisteredApps)
        - SP.Api (Invoke-SPApiRequest)
        - SP.Core (Write-SPLog, Get-SPConfig)

.NOTES
    Module: SP.DisconnectedApps / SP.DisconnectedAppAnalytics
    Version: 1.0.0
    Component: Analytics
#>

#region Delivery Status

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

#region Identity Risk

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

#endregion

#region Entitlement Catalog

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

#endregion

#region SLA Status

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

#endregion

#region Campaign Decisions

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

#endregion

#region Trends and Compliance

function Get-SPDisconnectedAppTrend {
    <#
    .SYNOPSIS
        Aggregates disconnected app governance data for quarterly/annual trending.
    .DESCRIPTION
        Reads JSONL audit trails (DisconnectedAppCertRun, DecisionHarvest,
        RemediationStatusUpdate events) across all registered apps and calculates
        per-app per-quarter metrics: total accounts processed, delta counts,
        campaign completion rate, revocation rate, remediation closure rate,
        and average review time.

        Results are returned as structured data suitable for charting or
        compliance reporting.
    .PARAMETER OutputPath
        Base directory for reports. Reads from {OutputPath}/{AppName}/disconnected-app-audit.jsonl.
    .PARAMETER StartDate
        Start of the reporting period (inclusive). Defaults to 90 days ago.
    .PARAMETER EndDate
        End of the reporting period (inclusive). Defaults to today.
    .PARAMETER AppName
        Optional. If specified, returns trend data for a single app only.
        If omitted, returns data for all registered apps found in OutputPath.
    .PARAMETER QuarterGrouping
        If set, groups metrics by calendar quarter (Q1-Q4). Default: $true.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success; Data=@{Apps=@([hashtable]); Summary=[hashtable]}; Error}
    .EXAMPLE
        $trend = Get-SPDisconnectedAppTrend -OutputPath '.\Reports' -StartDate '2026-01-01' -EndDate '2026-03-31'
        $trend.Data.Apps | ForEach-Object { "$($_.AppName): $($_.Quarters.Count) quarters" }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [datetime]$StartDate,

        [Parameter()]
        [datetime]$EndDate,

        [Parameter()]
        [string]$AppName,

        [Parameter()]
        [bool]$QuarterGrouping = $true,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Get-SPDisconnectedAppTrend'

    if ($null -eq $EndDate -or $EndDate -eq [datetime]::MinValue) {
        $EndDate = (Get-Date).Date
    }
    if ($null -eq $StartDate -or $StartDate -eq [datetime]::MinValue) {
        $StartDate = $EndDate.AddDays(-90)
    }

    Write-SPLog -Message "Starting trend analysis: $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd'))" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    try {
        # -----------------------------------------------------------
        # Step 1: Discover app directories
        # -----------------------------------------------------------
        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            return @{ Success = $false; Data = $null; Error = "Output path not found: $OutputPath" }
        }

        $appDirs = @()
        if (-not [string]::IsNullOrWhiteSpace($AppName)) {
            $appDir = Join-Path -Path $OutputPath -ChildPath $AppName
            if (Test-Path -Path $appDir -PathType Container) {
                $appDirs = @(@{ Name = $AppName; Path = $appDir })
            }
            else {
                return @{ Success = $false; Data = $null; Error = "App directory not found: $appDir" }
            }
        }
        else {
            $subdirs = Get-ChildItem -Path $OutputPath -Directory -ErrorAction SilentlyContinue
            foreach ($dir in $subdirs) {
                $auditFile = Join-Path -Path $dir.FullName -ChildPath 'disconnected-app-audit.jsonl'
                if (Test-Path -Path $auditFile -PathType Leaf) {
                    $appDirs += @{ Name = $dir.Name; Path = $dir.FullName }
                }
            }
        }

        if ($appDirs.Count -eq 0) {
            Write-SPLog -Message "No app audit trails found in '$OutputPath'" `
                -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{ Apps = @(); Summary = @{ TotalApps = 0 } }
                Error   = $null
            }
        }

        # -----------------------------------------------------------
        # Step 2: Parse JSONL events per app
        # -----------------------------------------------------------
        $startUtc = $StartDate.ToUniversalTime()
        $endUtc   = $EndDate.Date.AddDays(1).ToUniversalTime()  # end of day inclusive

        $allAppResults = [System.Collections.Generic.List[hashtable]]::new()
        $grandTotalCertRuns    = 0
        $grandTotalDecisions   = 0
        $grandTotalRevocations = 0

        foreach ($app in $appDirs) {
            $auditPath = Join-Path -Path $app.Path -ChildPath 'disconnected-app-audit.jsonl'
            $lines = @(Get-Content -Path $auditPath -Encoding UTF8 -ErrorAction SilentlyContinue)

            # Buckets: keyed by quarter label (e.g., "2026-Q1") or "all" if not grouping
            $quarterBuckets = [ordered]@{}

            # Per-app totals
            $appCertRuns           = 0
            $appIdentitiesTotal    = 0
            $appCampaignsCreated   = 0
            $appCampaignsCompleted = 0
            $appCampaignsChecked   = 0
            $appApproved           = 0
            $appRevoked            = 0
            $appPendingDecisions   = 0
            $appRemediationConfirmed = 0
            $appRemediationOverdue   = 0
            $appRemediationTotal     = 0

            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

                try {
                    $event = $trimmed | ConvertFrom-Json
                }
                catch { continue }

                # Parse timestamp
                $eventTime = $null
                if (-not [string]::IsNullOrWhiteSpace($event.Timestamp)) {
                    try {
                        $eventTime = [datetime]::Parse($event.Timestamp).ToUniversalTime()
                    }
                    catch { continue }
                }
                if ($null -eq $eventTime) { continue }

                # Apply date filter
                if ($eventTime -lt $startUtc -or $eventTime -ge $endUtc) { continue }

                # Determine quarter key
                $qKey = 'all'
                if ($QuarterGrouping) {
                    $qNum = [math]::Ceiling($eventTime.Month / 3)
                    $qKey = "$($eventTime.Year)-Q$qNum"
                }

                if (-not $quarterBuckets.Contains($qKey)) {
                    $quarterBuckets[$qKey] = @{
                        Quarter              = $qKey
                        CertRuns             = 0
                        IdentitiesProcessed  = 0
                        CampaignsCreated     = 0
                        CampaignsChecked     = 0
                        CampaignsCompleted   = 0
                        Approved             = 0
                        Revoked              = 0
                        PendingDecisions     = 0
                        RemediationConfirmed = 0
                        RemediationOverdue   = 0
                        RemediationTotal     = 0
                    }
                }
                $bucket = $quarterBuckets[$qKey]

                # Aggregate by event type
                $eventAction = if ($null -ne $event.Action) { [string]$event.Action } else { '' }

                switch ($eventAction) {
                    'DisconnectedAppCertRun' {
                        $bucket.CertRuns++
                        $appCertRuns++
                        $grandTotalCertRuns++

                        $identities = 0
                        if ($null -ne $event.PSObject.Properties['IdentitiesProcessed']) {
                            $identities = [int]$event.IdentitiesProcessed
                        }
                        $bucket.IdentitiesProcessed += $identities
                        $appIdentitiesTotal += $identities

                        $campaigns = 0
                        if ($null -ne $event.PSObject.Properties['CampaignsCreated']) {
                            $campaigns = [int]$event.CampaignsCreated
                        }
                        $bucket.CampaignsCreated += $campaigns
                        $appCampaignsCreated += $campaigns
                    }
                    'DecisionHarvest' {
                        $checked = 0
                        if ($null -ne $event.PSObject.Properties['CampaignsChecked']) {
                            $checked = [int]$event.CampaignsChecked
                        }
                        $bucket.CampaignsChecked += $checked
                        $appCampaignsChecked += $checked

                        $completed = 0
                        if ($null -ne $event.PSObject.Properties['Completed']) {
                            $completed = [int]$event.Completed
                        }
                        $bucket.CampaignsCompleted += $completed
                        $appCampaignsCompleted += $completed

                        $approved = 0
                        if ($null -ne $event.PSObject.Properties['Approved']) {
                            $approved = [int]$event.Approved
                        }
                        $bucket.Approved += $approved
                        $appApproved += $approved

                        $revoked = 0
                        if ($null -ne $event.PSObject.Properties['Revoked']) {
                            $revoked = [int]$event.Revoked
                        }
                        $bucket.Revoked += $revoked
                        $appRevoked += $revoked
                        $grandTotalRevocations += $revoked

                        $pending = 0
                        if ($null -ne $event.PSObject.Properties['Pending']) {
                            $pending = [int]$event.Pending
                        }
                        $bucket.PendingDecisions += $pending
                        $appPendingDecisions += $pending

                        $grandTotalDecisions += ($approved + $revoked + $pending)
                    }
                    'RemediationStatusUpdate' {
                        $confirmed = 0
                        if ($null -ne $event.PSObject.Properties['Confirmed']) {
                            $confirmed = [int]$event.Confirmed
                        }
                        # Use latest snapshot values (not cumulative -- each update is a point-in-time)
                        $bucket.RemediationConfirmed = $confirmed
                        $appRemediationConfirmed = $confirmed

                        $overdue = 0
                        if ($null -ne $event.PSObject.Properties['Overdue']) {
                            $overdue = [int]$event.Overdue
                        }
                        $bucket.RemediationOverdue = $overdue
                        $appRemediationOverdue = $overdue

                        $total = 0
                        if ($null -ne $event.PSObject.Properties['Total']) {
                            $total = [int]$event.Total
                        }
                        $bucket.RemediationTotal = $total
                        $appRemediationTotal = $total
                    }
                }
            }

            # Calculate derived metrics
            $completionRate   = if ($appCampaignsChecked -gt 0) {
                [math]::Round(($appCampaignsCompleted / $appCampaignsChecked) * 100, 1)
            } else { 0.0 }

            $totalDecisions   = $appApproved + $appRevoked + $appPendingDecisions
            $revocationRate   = if ($totalDecisions -gt 0) {
                [math]::Round(($appRevoked / $totalDecisions) * 100, 1)
            } else { 0.0 }

            $remediationClosureRate = if ($appRemediationTotal -gt 0) {
                [math]::Round(($appRemediationConfirmed / $appRemediationTotal) * 100, 1)
            } else { 0.0 }

            $appResult = @{
                AppName                = $app.Name
                PeriodStart            = $StartDate.ToString('yyyy-MM-dd')
                PeriodEnd              = $EndDate.ToString('yyyy-MM-dd')
                CertRuns               = $appCertRuns
                IdentitiesProcessed    = $appIdentitiesTotal
                CampaignsCreated       = $appCampaignsCreated
                CampaignsChecked       = $appCampaignsChecked
                CampaignsCompleted     = $appCampaignsCompleted
                CompletionRatePct      = $completionRate
                Approved               = $appApproved
                Revoked                = $appRevoked
                PendingDecisions       = $appPendingDecisions
                RevocationRatePct      = $revocationRate
                RemediationConfirmed   = $appRemediationConfirmed
                RemediationOverdue     = $appRemediationOverdue
                RemediationTotal       = $appRemediationTotal
                RemediationClosurePct  = $remediationClosureRate
                Quarters               = @($quarterBuckets.Values)
            }

            $allAppResults.Add($appResult)
        }

        $summary = @{
            TotalApps         = $allAppResults.Count
            PeriodStart       = $StartDate.ToString('yyyy-MM-dd')
            PeriodEnd         = $EndDate.ToString('yyyy-MM-dd')
            TotalCertRuns     = $grandTotalCertRuns
            TotalDecisions    = $grandTotalDecisions
            TotalRevocations  = $grandTotalRevocations
        }

        Write-SPLog -Message "Trend analysis complete: $($allAppResults.Count) apps, $grandTotalCertRuns cert runs, $grandTotalDecisions decisions" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Apps    = @($allAppResults)
                Summary = $summary
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPDisconnectedAppTrend failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Export-SPDisconnectedAppCompliancePackage {
    <#
    .SYNOPSIS
        Packages all disconnected app governance evidence for a date range into a ZIP.
    .DESCRIPTION
        Bundles delta reports, batch summaries, decision harvests, remediation
        confirmations, audit trails, and snapshots for all apps within the
        specified date range. Generates a SHA256 manifest for integrity
        verification and a cover page describing the scope and methodology.

        The output is a single ZIP file ready for auditor handoff.
    .PARAMETER OutputPath
        Base directory for reports. Scans {OutputPath}/{AppName}/ for evidence files.
    .PARAMETER SnapshotPath
        Base directory for snapshots. Scans {SnapshotPath}/{AppName}/ for CSV files.
    .PARAMETER StartDate
        Start of the audit period (inclusive).
    .PARAMETER EndDate
        End of the audit period (inclusive).
    .PARAMETER PackageOutputPath
        Directory where the ZIP file is created. Defaults to OutputPath.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success; Data=@{PackagePath; FileCount; ManifestPath}; Error}
    .EXAMPLE
        Export-SPDisconnectedAppCompliancePackage -OutputPath '.\Reports' `
            -StartDate '2026-01-01' -EndDate '2026-03-31'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$OutputPath = '.\DisconnectedApps\Reports',

        [Parameter()]
        [string]$SnapshotPath = '.\DisconnectedApps\Snapshots',

        [Parameter(Mandatory)]
        [datetime]$StartDate,

        [Parameter(Mandatory)]
        [datetime]$EndDate,

        [Parameter()]
        [string]$PackageOutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if ([string]::IsNullOrWhiteSpace($PackageOutputPath)) {
        $PackageOutputPath = $OutputPath
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Export-SPDisconnectedAppCompliancePackage'
    $startStr  = $StartDate.ToString('yyyy-MM-dd')
    $endStr    = $EndDate.ToString('yyyy-MM-dd')

    Write-SPLog -Message "Starting compliance package: $startStr to $endStr" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    try {
        # -----------------------------------------------------------
        # Step 1: Create staging directory
        # -----------------------------------------------------------
        $packageName = "DisconnectedApp-Compliance-${startStr}_to_${endStr}"
        $stagingDir  = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $packageName
        if (Test-Path -Path $stagingDir) {
            Remove-Item -Path $stagingDir -Recurse -Force
        }
        New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null

        $manifest   = [System.Collections.Generic.List[hashtable]]::new()
        $fileCount  = 0

        # Helper: copy file to staging and add to manifest
        $copyToStaging = {
            param([string]$SourcePath, [string]$RelativePath)
            $destPath = Join-Path -Path $stagingDir -ChildPath $RelativePath
            $destDir  = Split-Path -Path $destPath -Parent
            if (-not (Test-Path -Path $destDir -PathType Container)) {
                New-Item -Path $destDir -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $SourcePath -Destination $destPath -Force

            $hash = (Get-FileHash -Path $SourcePath -Algorithm SHA256).Hash
            $manifest.Add(@{
                File   = $RelativePath
                SHA256 = $hash
                Size   = (Get-Item -Path $SourcePath).Length
            })
        }

        # Helper: check if a date-stamped filename falls within range
        $isInDateRange = {
            param([string]$FileName)
            # Match patterns: delta-2026-01-15.html, batch-summary-2026-01-15.html,
            # decision-harvest-2026-01-15.html, sla-report-2026-01-15.html,
            # 2026-01-15-accounts.csv
            if ($FileName -match '(\d{4}-\d{2}-\d{2})') {
                $fileDate = $null
                try { $fileDate = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) }
                catch { return $false }
                return ($fileDate -ge $StartDate.Date -and $fileDate -le $EndDate.Date)
            }
            return $false
        }

        # -----------------------------------------------------------
        # Step 2: Collect per-app evidence
        # -----------------------------------------------------------
        if (Test-Path -Path $OutputPath -PathType Container) {
            $appDirs = Get-ChildItem -Path $OutputPath -Directory -ErrorAction SilentlyContinue
            foreach ($appDir in $appDirs) {
                $appName = $appDir.Name

                # Collect date-stamped HTML reports
                $htmlFiles = Get-ChildItem -Path $appDir.FullName -Filter '*.html' -File `
                    -ErrorAction SilentlyContinue
                foreach ($file in $htmlFiles) {
                    if (& $isInDateRange $file.Name) {
                        & $copyToStaging $file.FullName "reports/$appName/$($file.Name)"
                        $fileCount++
                    }
                }

                # Collect JSONL audit trail (always included -- contains full history)
                $auditFile = Join-Path -Path $appDir.FullName -ChildPath 'disconnected-app-audit.jsonl'
                if (Test-Path -Path $auditFile -PathType Leaf) {
                    & $copyToStaging $auditFile "reports/$appName/disconnected-app-audit.jsonl"
                    $fileCount++
                }

                # Collect remediation tracker
                $trackerFile = Join-Path -Path $appDir.FullName -ChildPath 'remediation-tracker.json'
                if (Test-Path -Path $trackerFile -PathType Leaf) {
                    & $copyToStaging $trackerFile "reports/$appName/remediation-tracker.json"
                    $fileCount++
                }
            }
        }

        # Collect global reports (batch summaries, SLA reports)
        if (Test-Path -Path $OutputPath -PathType Container) {
            $globalHtmlFiles = Get-ChildItem -Path $OutputPath -Filter '*.html' -File `
                -ErrorAction SilentlyContinue
            foreach ($file in $globalHtmlFiles) {
                if (& $isInDateRange $file.Name) {
                    & $copyToStaging $file.FullName "reports/$($file.Name)"
                    $fileCount++
                }
            }
        }

        # -----------------------------------------------------------
        # Step 3: Collect snapshots
        # -----------------------------------------------------------
        if (Test-Path -Path $SnapshotPath -PathType Container) {
            $snapshotAppDirs = Get-ChildItem -Path $SnapshotPath -Directory `
                -ErrorAction SilentlyContinue
            foreach ($snapDir in $snapshotAppDirs) {
                $csvFiles = Get-ChildItem -Path $snapDir.FullName -Filter '*.csv' -File `
                    -ErrorAction SilentlyContinue
                foreach ($file in $csvFiles) {
                    if (& $isInDateRange $file.Name) {
                        & $copyToStaging $file.FullName "snapshots/$($snapDir.Name)/$($file.Name)"
                        $fileCount++
                    }
                }
            }
        }

        # -----------------------------------------------------------
        # Step 4: Generate trend summary for the period
        # -----------------------------------------------------------
        $trendResult = Get-SPDisconnectedAppTrend -OutputPath $OutputPath `
            -StartDate $StartDate -EndDate $EndDate -CorrelationID $CorrelationID
        if ($trendResult.Success -and $null -ne $trendResult.Data) {
            $trendJson = $trendResult.Data | ConvertTo-Json -Depth 10
            $trendPath = Join-Path -Path $stagingDir -ChildPath 'trend-summary.json'
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($trendPath, $trendJson, $utf8NoBom)

            $hash = (Get-FileHash -Path $trendPath -Algorithm SHA256).Hash
            $manifest.Add(@{
                File   = 'trend-summary.json'
                SHA256 = $hash
                Size   = (Get-Item -Path $trendPath).Length
            })
            $fileCount++
        }

        # -----------------------------------------------------------
        # Step 5: Generate SHA256 manifest
        # -----------------------------------------------------------
        $manifestLines = [System.Collections.Generic.List[string]]::new()
        $manifestLines.Add("# SHA256 Integrity Manifest")
        $manifestLines.Add("# Generated: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
        $manifestLines.Add("# Period: $startStr to $endStr")
        $manifestLines.Add("# Files: $fileCount")
        $manifestLines.Add("")

        foreach ($entry in ($manifest | Sort-Object { $_.File })) {
            $manifestLines.Add("$($entry.SHA256)  $($entry.File)  ($($entry.Size) bytes)")
        }

        $manifestFilePath = Join-Path -Path $stagingDir -ChildPath 'SHA256MANIFEST.txt'
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($manifestFilePath, ($manifestLines -join "`n"), $utf8NoBom)

        # -----------------------------------------------------------
        # Step 6: Generate cover page
        # -----------------------------------------------------------
        $coverLines = [System.Collections.Generic.List[string]]::new()
        $coverLines.Add("DISCONNECTED APPLICATION GOVERNANCE -- COMPLIANCE EVIDENCE PACKAGE")
        $coverLines.Add("=" * 72)
        $coverLines.Add("")
        $coverLines.Add("Audit Period:     $startStr to $endStr")
        $coverLines.Add("Generated:        $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC")
        $coverLines.Add("Total Files:      $fileCount")
        $coverLines.Add("Integrity:        SHA256MANIFEST.txt (SHA-256 checksums for all files)")
        $coverLines.Add("")
        $coverLines.Add("SCOPE")
        $coverLines.Add("-" * 72)
        $coverLines.Add("This package contains all governance evidence for disconnected")
        $coverLines.Add("applications managed by the SailPoint Governance Toolkit during")
        $coverLines.Add("the specified audit period.")
        $coverLines.Add("")
        $coverLines.Add("CONTENTS")
        $coverLines.Add("-" * 72)
        $coverLines.Add("  reports/               Per-app and global governance reports")
        $coverLines.Add("    {AppName}/            Delta reports, decision harvests, remediation trackers")
        $coverLines.Add("    batch-summary-*.html  Daily batch run summaries")
        $coverLines.Add("    sla-report-*.html     SLA compliance reports")
        $coverLines.Add("  snapshots/             Daily CSV snapshots of app account/entitlement data")
        $coverLines.Add("  trend-summary.json     Aggregated metrics for the audit period")
        $coverLines.Add("  SHA256MANIFEST.txt     Integrity verification checksums")
        $coverLines.Add("  COVER.txt              This file")
        $coverLines.Add("")
        $coverLines.Add("METHODOLOGY")
        $coverLines.Add("-" * 72)
        $coverLines.Add("1. Daily CSV files are delivered by each application team.")
        $coverLines.Add("2. The toolkit validates, snapshots, and computes deltas against")
        $coverLines.Add("   the previous day's data.")
        $coverLines.Add("3. Access changes trigger ISC certification campaigns assigned")
        $coverLines.Add("   to each identity's manager for review.")
        $coverLines.Add("4. Campaign decisions (APPROVE/REVOKE) are harvested daily.")
        $coverLines.Add("5. Revocation decisions create remediation records tracked until")
        $coverLines.Add("   the entitlement is confirmed removed from subsequent CSVs.")
        $coverLines.Add("6. All events are recorded in per-app JSONL audit trails.")
        $coverLines.Add("")
        $coverLines.Add("VERIFICATION")
        $coverLines.Add("-" * 72)
        $coverLines.Add("To verify file integrity:")
        $coverLines.Add("  PowerShell:  Get-FileHash -Algorithm SHA256 <file>")
        $coverLines.Add("  Linux/Mac:   sha256sum <file>")
        $coverLines.Add("Compare output against SHA256MANIFEST.txt entries.")
        $coverLines.Add("")

        # Add per-app summary if trend data available
        if ($trendResult.Success -and $null -ne $trendResult.Data -and
            $null -ne $trendResult.Data.Apps) {
            $coverLines.Add("PER-APPLICATION SUMMARY")
            $coverLines.Add("-" * 72)
            foreach ($appTrend in $trendResult.Data.Apps) {
                $coverLines.Add("  $($appTrend.AppName):")
                $coverLines.Add("    Cert Runs:            $($appTrend.CertRuns)")
                $coverLines.Add("    Identities Processed: $($appTrend.IdentitiesProcessed)")
                $coverLines.Add("    Campaigns Created:    $($appTrend.CampaignsCreated)")
                $coverLines.Add("    Completion Rate:      $($appTrend.CompletionRatePct)%")
                $coverLines.Add("    Decisions:            $($appTrend.Approved) approved, $($appTrend.Revoked) revoked")
                $coverLines.Add("    Revocation Rate:      $($appTrend.RevocationRatePct)%")
                $coverLines.Add("    Remediation Closure:  $($appTrend.RemediationClosurePct)%")
                $coverLines.Add("")
            }
        }

        $coverFilePath = Join-Path -Path $stagingDir -ChildPath 'COVER.txt'
        [System.IO.File]::WriteAllText($coverFilePath, ($coverLines -join "`n"), $utf8NoBom)

        # -----------------------------------------------------------
        # Step 7: Create ZIP
        # -----------------------------------------------------------
        if (-not (Test-Path -Path $PackageOutputPath -PathType Container)) {
            New-Item -Path $PackageOutputPath -ItemType Directory -Force | Out-Null
        }

        $zipFileName = "${packageName}.zip"
        $zipPath     = Join-Path -Path $PackageOutputPath -ChildPath $zipFileName

        # Remove existing ZIP if present
        if (Test-Path -Path $zipPath) {
            Remove-Item -Path $zipPath -Force
        }

        # Use .NET compression (available in PS 5.1+)
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $stagingDir,
            $zipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false  # do not include base directory name
        )

        # -----------------------------------------------------------
        # Step 8: Cleanup staging
        # -----------------------------------------------------------
        Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

        Write-SPLog -Message "Compliance package created: $zipPath ($fileCount files)" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                PackagePath  = $zipPath
                FileCount    = $fileCount
                ManifestPath = 'SHA256MANIFEST.txt'
                PeriodStart  = $startStr
                PeriodEnd    = $endStr
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Export-SPDisconnectedAppCompliancePackage failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID

        # Cleanup staging on error
        if ($null -ne $stagingDir -and (Test-Path -Path $stagingDir)) {
            Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#endregion

Export-ModuleMember -Function @(
    'Get-SPDisconnectedAppDeliveryStatus',
    'Get-SPDisconnectedAppIdentityRisk',
    'Get-SPDisconnectedAppEntitlementCatalog',
    'Get-SPDisconnectedAppSlaStatus',
    'Get-SPDisconnectedAppCampaignDecisions',
    'Get-SPDisconnectedAppTrend',
    'Export-SPDisconnectedAppCompliancePackage'
)

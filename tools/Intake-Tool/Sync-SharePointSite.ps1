#Requires -Version 5.1
<#
.SYNOPSIS
    Bidirectional sync tool for SharePoint Server on-premises (2013+).

.DESCRIPTION
    Downloads, uploads, or bidirectionally syncs files between a SharePoint
    on-premises document library and a local folder. Uses the SharePoint REST
    API exclusively -- no external modules or DLLs required.

    Supports NTLM/Kerberos authentication, WhatIf mode, include/exclude
    filters, exponential-backoff retry, and JSON Lines logging.

.PARAMETER SiteUrl
    The root URL of the SharePoint site (e.g. https://sharepoint.corp.com/sites/IT).

.PARAMETER RemotePath
    Server-relative path to the document library or subfolder.
    Default is '/'. Example: /Shared Documents/Apps/IAM/AppsToMigrate

.PARAMETER LocalPath
    Local filesystem directory to sync with.

.PARAMETER Direction
    Download, Upload, or Sync (bidirectional). Default is Download.

.PARAMETER Credential
    Optional PSCredential for NTLM authentication. If omitted the script
    attempts default Windows credentials, then prompts interactively.

.PARAMETER Include
    Wildcard patterns for files to include (e.g. *.xlsx, *.docx).

.PARAMETER Exclude
    Wildcard patterns for files to exclude (e.g. ~$*, *.tmp).

.PARAMETER ConflictResolution
    How to handle files that exist on both sides with different timestamps.
    NewerWins (default), LocalWins, RemoteWins, or ReportOnly.

.PARAMETER MaxDepth
    Maximum folder recursion depth. Default 50.

.PARAMETER RetryCount
    Number of retries for transient HTTP errors. Default 3.

.PARAMETER LogPath
    Path to a JSON Lines log file. Each operation is appended as one line.

.PARAMETER Force
    Suppress confirmation prompts for upload/sync operations.

.PARAMETER ConfirmReplace
    Prompt Yes / Yes to All / No / No to All before each file REPLACEMENT
    (DownloadUpdate / UploadUpdate). New files and in-sync files never prompt,
    so only genuinely changed files require a decision. Declined files are
    logged as skipped. Requires an interactive session; not honored under -WhatIf
    (nothing is replaced there anyway).

.EXAMPLE
    .\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
        -RemotePath '/Shared Documents/Apps/IAM' -LocalPath C:\sync\IAM

.EXAMPLE
    .\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
        -RemotePath '/Shared Documents/Apps/IAM' -LocalPath C:\sync\IAM `
        -Direction Sync -ConfirmReplace

.EXAMPLE
    .\Sync-SharePointSite.ps1 -SiteUrl https://sp.corp.com/sites/IT `
        -RemotePath '/Shared Documents' -LocalPath C:\sync -Direction Upload -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [string]$SiteUrl,

    [string]$RemotePath = '/',

    [Parameter(Mandatory)]
    [string]$LocalPath,

    [ValidateSet('Download', 'Upload', 'Sync')]
    [string]$Direction = 'Download',

    [PSCredential]$Credential,

    [string[]]$Include,
    [string[]]$Exclude,

    [ValidateSet('NewerWins', 'LocalWins', 'RemoteWins', 'ReportOnly')]
    [string]$ConflictResolution = 'NewerWins',

    [int]$MaxDepth = 50,

    [int]$RetryCount = 3,

    [string]$LogPath,

    [switch]$Force,

    [switch]$ConfirmReplace
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:VERSION = '1.0'
$script:LARGE_FILE_THRESHOLD = 10 * 1024 * 1024  # 10 MB
$script:MAX_PATH_LENGTH = 240
$script:SYSTEM_FOLDERS = @('Forms', '_catalogs', '_private', '_vti_cnf', '_vti_pvt')
$script:TEMP_FILE_PATTERNS = @('~$*', '*.tmp', 'Thumbs.db', '.DS_Store')
$script:DIGEST_CACHE = @{ Value = $null; Expires = [datetime]::MinValue }

# Session state populated by Connect-SharePoint
$script:Session = $null

# ---------------------------------------------------------------------------
# Helpers -- console output
# ---------------------------------------------------------------------------
function Write-Banner {
    param(
        [string]$SiteTitle,
        [string]$AuthMethod
    )
    $divider = '-' * 30
    Write-Host ''
    Write-Host "SharePoint Site Sync Tool v$script:VERSION" -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor Cyan
    Write-Host "  Site:       $SiteUrl"
    if ($SiteTitle) { Write-Host "  Title:      $SiteTitle" }
    Write-Host "  Remote:     $RemotePath"
    Write-Host "  Local:      $LocalPath"
    Write-Host "  Direction:  $Direction"
    Write-Host "  Auth:       $AuthMethod"
    Write-Host ''
}

function Write-Progress2 {
    param([int]$Current, [int]$Total, [string]$Path, [string]$Size, [string]$Result)
    $pad = "$Total".Length
    $idx = "$Current".PadLeft($pad)
    $prefix = "[$idx/$Total]"
    Write-Host "  $prefix  " -NoNewline
    Write-Host "$Path" -ForegroundColor White -NoNewline
    if ($Size) { Write-Host " ($Size)" -NoNewline -ForegroundColor DarkGray }
    Write-Host "... " -NoNewline
    switch ($Result) {
        'Downloaded'  { Write-Host $Result -ForegroundColor Green }
        'Uploaded'    { Write-Host $Result -ForegroundColor Green }
        'Created'     { Write-Host $Result -ForegroundColor Green }
        'Skipped'     { Write-Host $Result -ForegroundColor Yellow }
        'Error'       { Write-Host $Result -ForegroundColor Red }
        'WhatIf'      { Write-Host $Result -ForegroundColor DarkYellow }
        default       { Write-Host $Result }
    }
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -lt 1024)           { return "$Bytes B" }
    if ($Bytes -lt 1024 * 1024)    { return '{0:N1} KB' -f ($Bytes / 1024) }
    if ($Bytes -lt 1024 * 1024 * 1024) { return '{0:N1} MB' -f ($Bytes / 1024 / 1024) }
    return '{0:N2} GB' -f ($Bytes / 1024 / 1024 / 1024)
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-LogEntry {
    param(
        [string]$Action,
        [string]$Path,
        [long]$Size,
        [string]$Status,
        [int]$DurationMs = 0
    )
    if (-not $LogPath) { return }
    $entry = [ordered]@{
        timestamp   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        action      = $Action
        path        = $Path
        size        = $Size
        status      = $Status
        duration_ms = $DurationMs
    }
    $json = $entry | ConvertTo-Json -Compress
    Add-Content -Path $LogPath -Value $json -Encoding UTF8
}

# ---------------------------------------------------------------------------
# URL / path helpers
# ---------------------------------------------------------------------------
function ConvertTo-EncodedUrlSegment {
    param([string]$Segment)
    # Encode characters that are problematic in SharePoint REST URLs.
    # We encode space, parentheses, single-quote, hash, percent, ampersand.
    $Segment = $Segment -replace '%', '%25'
    $Segment = $Segment -replace ' ', '%20'
    $Segment = $Segment -replace '#', '%23'
    $Segment = $Segment -replace '&', '%26'
    $Segment = $Segment -replace "'", "''"   # SharePoint REST uses doubled single-quotes
    return $Segment
}

function ConvertTo-ServerRelativeUrl {
    param([string]$Path)
    $Path = $Path -replace '\\', '/'
    if (-not $Path.StartsWith('/')) { $Path = '/' + $Path }
    # Remove trailing slash unless root
    if ($Path.Length -gt 1 -and $Path.EndsWith('/')) {
        $Path = $Path.TrimEnd('/')
    }
    return $Path
}

function Get-SiteRelativePrefix {
    # Extract the site-relative prefix from the SiteUrl.
    # e.g. https://sp.corp.com/sites/IT -> /sites/IT
    $uri = [System.Uri]$SiteUrl
    $prefix = $uri.AbsolutePath.TrimEnd('/')
    return $prefix
}

# ---------------------------------------------------------------------------
# File filter
# ---------------------------------------------------------------------------
function Test-FileFilter {
    param(
        [string]$FileName,
        [string[]]$IncludePatterns,
        [string[]]$ExcludePatterns
    )
    # Always exclude temp files
    foreach ($tp in $script:TEMP_FILE_PATTERNS) {
        if ($FileName -like $tp) { return $false }
    }
    if ($ExcludePatterns) {
        foreach ($pattern in $ExcludePatterns) {
            if ($FileName -like $pattern) { return $false }
        }
    }
    if ($IncludePatterns) {
        foreach ($pattern in $IncludePatterns) {
            if ($FileName -like $pattern) { return $true }
        }
        return $false  # Include specified but no match
    }
    return $true  # No filters
}

function Test-SystemFolder {
    param([string]$FolderName)
    return ($script:SYSTEM_FOLDERS -contains $FolderName)
}

# ---------------------------------------------------------------------------
# Authentication and connectivity
# ---------------------------------------------------------------------------
function Connect-SharePoint {
    <#
    .SYNOPSIS
        Establishes authentication and tests connectivity to SharePoint.
        Returns a session hashtable with BaseUrl, AuthParams, and AuthMethod.
    #>

    $baseUrl = $SiteUrl.TrimEnd('/')
    $testEndpoint = "$baseUrl/_api/web?`$select=Title,Url"
    $session = @{
        BaseUrl    = $baseUrl
        AuthParams = @{}
        AuthMethod = 'Unknown'
        Credential = $null
    }

    # --- Strategy 1: Explicit credential ---
    if ($Credential) {
        Write-Host '  Authenticating with supplied credential...' -ForegroundColor DarkGray
        $session.Credential = $Credential
        # -Credential alone handles NTLM/Negotiate via the 401 challenge on both
        # Windows PowerShell and PS 7+ ('Negotiate' is not a valid -Authentication value on PS 7).
        $session.AuthParams = @{
            Credential = $Credential
        }
        $session.AuthMethod = "NTLM ($($Credential.UserName))"
        try {
            $resp = Invoke-SPRequest -Url $testEndpoint -Session $session -Method GET
            $title = $resp.d.Title
            $session.SiteTitle = $title
            $script:Session = $session
            return $session
        }
        catch {
            Write-Warning "Supplied credential failed: $($_.Exception.Message)"
            # Fall through to prompt
        }
    }

    # --- Strategy 2: Default credentials (Windows session) ---
    # -UseDefaultCredentials is supported by both Windows PowerShell and PS 7+.
    Write-Host '  Trying default Windows credentials...' -ForegroundColor DarkGray
    $session.AuthParams = @{ UseDefaultCredentials = $true }
    $session.AuthMethod = 'Kerberos/NTLM (default credentials)'
    try {
        $resp = Invoke-SPRequest -Url $testEndpoint -Session $session -Method GET
        $title = $resp.d.Title
        $session.SiteTitle = $title
        try {
            $whoami = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $session.AuthMethod = "Kerberos/NTLM ($whoami)"
        }
        catch {
            # Non-Windows PS Core -- WindowsIdentity is unavailable; keep generic label
        }
        $script:Session = $session
        return $session
    }
    catch {
        Write-Verbose "Default credentials failed: $($_.Exception.Message)"
    }

    # --- Strategy 3: Interactive prompt ---
    Write-Host '  Default credentials failed. Prompting for credentials...' -ForegroundColor Yellow
    $prompted = Get-Credential -Message "Enter credentials for $SiteUrl"
    if (-not $prompted) {
        throw 'No credentials provided. Cannot connect to SharePoint.'
    }
    $session.Credential = $prompted
    $session.AuthParams = @{
        Credential = $prompted
    }
    $session.AuthMethod = "NTLM ($($prompted.UserName))"

    try {
        $resp = Invoke-SPRequest -Url $testEndpoint -Session $session -Method GET
        $title = $resp.d.Title
        $session.SiteTitle = $title
        $script:Session = $session
        return $session
    }
    catch {
        throw "Authentication failed for $SiteUrl -- $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# HTTP request wrapper
# ---------------------------------------------------------------------------
function Invoke-SPRequest {
    <#
    .SYNOPSIS
        Wraps Invoke-RestMethod / Invoke-WebRequest with auth, retry, and headers.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [hashtable]$Session = $script:Session,

        [ValidateSet('GET', 'POST')]
        [string]$Method = 'GET',

        [hashtable]$Headers = @{},

        [object]$Body,

        [string]$ContentType,

        [string]$OutFile,

        [switch]$RawResponse
    )

    $baseHeaders = @{
        'Accept' = 'application/json;odata=verbose'
    }
    foreach ($k in $Headers.Keys) { $baseHeaders[$k] = $Headers[$k] }

    $attempt = 0
    $maxAttempts = $RetryCount + 1

    while ($true) {
        $attempt++
        $splat = @{
            Uri     = $Url
            Method  = $Method
            Headers = $baseHeaders
        }
        # Merge auth params
        if ($Session -and $Session.AuthParams) {
            foreach ($k in $Session.AuthParams.Keys) {
                $splat[$k] = $Session.AuthParams[$k]
            }
        }
        if ($Body)        { $splat['Body']        = $Body }
        if ($ContentType) { $splat['ContentType']  = $ContentType }
        if ($OutFile)     { $splat['OutFile']       = $OutFile }

        try {
            if ($OutFile -or $RawResponse) {
                $result = Invoke-WebRequest @splat -ErrorAction Stop
                if ($RawResponse) { return $result }
                return $null
            }
            else {
                $result = Invoke-RestMethod @splat -ErrorAction Stop
                return $result
            }
        }
        catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            # Retryable status codes
            if ($statusCode -in @(429, 500, 503) -and $attempt -lt $maxAttempts) {
                $waitSec = [math]::Pow(3, $attempt - 1)   # 1, 3, 9, ...
                Write-Verbose "HTTP $statusCode on attempt $attempt -- retrying in ${waitSec}s..."
                Start-Sleep -Seconds $waitSec
                continue
            }

            # 401 -- if we have not already tried prompting
            if ($statusCode -eq 401 -and $attempt -eq 1) {
                Write-Warning "401 Unauthorized. Prompting for credentials..."
                $newCred = Get-Credential -Message "Credentials required for $($Session.BaseUrl)"
                if ($newCred) {
                    $Session.AuthParams = @{ Credential = $newCred }
                    $Session.Credential = $newCred
                    $Session.AuthMethod = "NTLM ($($newCred.UserName))"
                    continue
                }
            }

            throw
        }
    }
}

# ---------------------------------------------------------------------------
# Form digest for POST operations
# ---------------------------------------------------------------------------
function Get-FormDigest {
    if ($script:DIGEST_CACHE.Expires -gt (Get-Date)) {
        return $script:DIGEST_CACHE.Value
    }

    $url = "$($script:Session.BaseUrl)/_api/contextinfo"
    $resp = Invoke-SPRequest -Url $url -Method POST -ContentType 'application/json;odata=verbose'
    $digest = $resp.d.GetContextWebInformation.FormDigestValue
    $timeout = $resp.d.GetContextWebInformation.FormDigestTimeoutSeconds
    if (-not $timeout -or $timeout -gt 1800) { $timeout = 1800 }

    $script:DIGEST_CACHE.Value = $digest
    $script:DIGEST_CACHE.Expires = (Get-Date).AddSeconds($timeout - 60)  # 1-minute safety margin
    return $digest
}

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------
function Resolve-SharePointPath {
    <#
    .SYNOPSIS
        Resolves the user-supplied RemotePath to a full server-relative URL.
        Queries the site for document libraries to validate the path.
    #>
    param([string]$Path)

    $Path = $Path -replace '\\', '/'
    if (-not $Path.StartsWith('/')) { $Path = '/' + $Path }
    $Path = $Path.TrimEnd('/')
    if ($Path -eq '') { $Path = '/' }

    $sitePrefix = Get-SiteRelativePrefix

    # If the path already starts with the site prefix, assume fully qualified
    if ($Path.StartsWith($sitePrefix + '/') -or $Path -eq $sitePrefix) {
        return $Path
    }

    # Query document libraries (BaseTemplate 101 = Document Library)
    $libUrl = "$($script:Session.BaseUrl)/_api/web/lists?`$filter=BaseTemplate eq 101&`$select=Title,RootFolder/ServerRelativeUrl&`$expand=RootFolder"
    try {
        $libResp = Invoke-SPRequest -Url $libUrl -Method GET
        $libraries = @()
        if ($libResp.d -and $libResp.d.results) {
            $libraries = $libResp.d.results
        }
    }
    catch {
        Write-Warning "Could not query document libraries: $($_.Exception.Message)"
        $libraries = @()
    }

    # Check if the first segment of Path matches a library's server-relative URL
    foreach ($lib in $libraries) {
        $libServerUrl = $lib.RootFolder.ServerRelativeUrl
        # Check if path starts with the library root folder name
        $libRelative = $libServerUrl.Replace($sitePrefix, '')
        if ($Path -eq $libRelative -or $Path.StartsWith("$libRelative/")) {
            # Path is relative to site, prepend site prefix
            return $sitePrefix + $Path
        }
    }

    # If Path is just '/', use the first document library found or "Shared Documents"
    if ($Path -eq '/') {
        foreach ($lib in $libraries) {
            $libServerUrl = $lib.RootFolder.ServerRelativeUrl
            # Prefer "Shared Documents" or "Documents"
            if ($lib.Title -in @('Documents', 'Shared Documents')) {
                return $libServerUrl
            }
        }
        # Fallback to first library
        if ($libraries.Count -gt 0) {
            return $libraries[0].RootFolder.ServerRelativeUrl
        }
        # Last resort
        return "$sitePrefix/Shared Documents"
    }

    # Path does not match any known library -- prepend site prefix and hope for the best
    return $sitePrefix + $Path
}

# ---------------------------------------------------------------------------
# Remote inventory
# ---------------------------------------------------------------------------
function Get-RemoteInventory {
    <#
    .SYNOPSIS
        Recursively lists files and folders from a SharePoint path via REST.
    #>
    param(
        [string]$ServerRelativeUrl,
        [string]$BasePath,
        [int]$CurrentDepth = 0
    )

    if ($CurrentDepth -ge $MaxDepth) {
        Write-Warning "Max depth ($MaxDepth) reached at: $ServerRelativeUrl"
        return @()
    }

    $encodedPath = ConvertTo-EncodedUrlSegment $ServerRelativeUrl
    $apiUrl = "$($script:Session.BaseUrl)/_api/web/GetFolderByServerRelativeUrl('$encodedPath')" +
              '?$expand=Folders,Files' +
              '&$select=Name,ServerRelativeUrl,TimeLastModified,' +
              'Folders/Name,Folders/ServerRelativeUrl,' +
              'Files/Name,Files/ServerRelativeUrl,Files/TimeLastModified,Files/Length'

    try {
        $resp = Invoke-SPRequest -Url $apiUrl -Method GET
    }
    catch {
        Write-Warning "Failed to list remote folder '$ServerRelativeUrl': $($_.Exception.Message)"
        return @()
    }

    $results = [System.Collections.ArrayList]::new()

    # Process files
    $files = @()
    if ($resp.d -and $resp.d.Files -and $resp.d.Files.results) {
        $files = $resp.d.Files.results
    }
    foreach ($f in $files) {
        $relativePath = $f.ServerRelativeUrl
        if ($BasePath) {
            $relativePath = $f.ServerRelativeUrl.Substring($BasePath.Length).TrimStart('/')
        }

        $fileName = $f.Name
        if (-not (Test-FileFilter -FileName $fileName -IncludePatterns $Include -ExcludePatterns $Exclude)) {
            continue
        }

        $modified = [datetime]::MinValue
        if ($f.TimeLastModified) {
            # SharePoint returns UTC (ISO 8601). Parse as UTC so comparisons against
            # local LastWriteTimeUtc are not skewed by the machine's UTC offset.
            $modified = [datetime]::Parse($f.TimeLastModified,
                [System.Globalization.CultureInfo]::InvariantCulture,
                ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                 [System.Globalization.DateTimeStyles]::AdjustToUniversal))
        }

        $obj = [PSCustomObject]@{
            RelativePath     = $relativePath
            Name             = $fileName
            Type             = 'File'
            Size             = [long]($f.Length)
            Modified         = $modified
            ServerRelativeUrl = $f.ServerRelativeUrl
        }
        [void]$results.Add($obj)
    }

    # Process subfolders
    $folders = @()
    if ($resp.d -and $resp.d.Folders -and $resp.d.Folders.results) {
        $folders = $resp.d.Folders.results
    }
    foreach ($folder in $folders) {
        $folderName = $folder.Name
        if (Test-SystemFolder -FolderName $folderName) { continue }

        $relativePath = $folder.ServerRelativeUrl
        if ($BasePath) {
            $relativePath = $folder.ServerRelativeUrl.Substring($BasePath.Length).TrimStart('/')
        }

        $folderObj = [PSCustomObject]@{
            RelativePath      = $relativePath
            Name              = $folderName
            Type              = 'Folder'
            Size              = 0
            Modified          = [datetime]::MinValue
            ServerRelativeUrl = $folder.ServerRelativeUrl
        }
        [void]$results.Add($folderObj)

        # Recurse
        $children = Get-RemoteInventory -ServerRelativeUrl $folder.ServerRelativeUrl `
                                        -BasePath $BasePath `
                                        -CurrentDepth ($CurrentDepth + 1)
        foreach ($child in $children) {
            [void]$results.Add($child)
        }
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Local inventory
# ---------------------------------------------------------------------------
function Get-LocalInventory {
    <#
    .SYNOPSIS
        Recursively lists local files and folders, matching the remote inventory format.
    #>
    param([string]$RootPath)

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return @()
    }

    $results = [System.Collections.ArrayList]::new()
    $items = Get-ChildItem -LiteralPath $RootPath -Recurse -Force -ErrorAction SilentlyContinue

    foreach ($item in $items) {
        $relativePath = $item.FullName.Substring($RootPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
        # Normalize to forward slashes for comparison
        $relativePath = $relativePath -replace '\\', '/'

        if ($item.PSIsContainer) {
            $folderName = $item.Name
            if (Test-SystemFolder -FolderName $folderName) { continue }

            $obj = [PSCustomObject]@{
                RelativePath      = $relativePath
                Name              = $folderName
                Type              = 'Folder'
                Size              = 0
                Modified          = $item.LastWriteTimeUtc
                ServerRelativeUrl = $null
                FullPath          = $item.FullName
            }
            [void]$results.Add($obj)
        }
        else {
            if (-not (Test-FileFilter -FileName $item.Name -IncludePatterns $Include -ExcludePatterns $Exclude)) {
                continue
            }

            $obj = [PSCustomObject]@{
                RelativePath      = $relativePath
                Name              = $item.Name
                Type              = 'File'
                Size              = $item.Length
                Modified          = $item.LastWriteTimeUtc
                ServerRelativeUrl = $null
                FullPath          = $item.FullName
            }
            [void]$results.Add($obj)
        }
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Sync manifest
# ---------------------------------------------------------------------------
function Build-SyncManifest {
    <#
    .SYNOPSIS
        Compares remote and local inventories and produces a list of actions.
    #>
    param(
        [array]$RemoteItems,
        [array]$LocalItems,
        [string]$ResolvedRemotePath
    )

    $manifest = [System.Collections.ArrayList]::new()

    # Build lookup dictionaries (files only, keyed by RelativePath)
    $remoteFiles = @{}
    foreach ($r in $RemoteItems) {
        if ($r.Type -eq 'File') { $remoteFiles[$r.RelativePath] = $r }
    }

    $localFiles = @{}
    foreach ($l in $LocalItems) {
        if ($l.Type -eq 'File') { $localFiles[$l.RelativePath] = $l }
    }

    # Collect all unique relative paths
    $allPaths = @{}
    foreach ($k in $remoteFiles.Keys) { $allPaths[$k] = $true }
    foreach ($k in $localFiles.Keys)  { $allPaths[$k] = $true }

    foreach ($path in $allPaths.Keys | Sort-Object) {
        $inRemote = $remoteFiles.ContainsKey($path)
        $inLocal  = $localFiles.ContainsKey($path)
        $remote   = if ($inRemote) { $remoteFiles[$path] } else { $null }
        $local    = if ($inLocal)  { $localFiles[$path]  } else { $null }

        $action = $null
        $fileSize = 0
        $serverRelUrl = $null

        if ($inRemote -and -not $inLocal) {
            # Remote only
            $fileSize = $remote.Size
            $serverRelUrl = $remote.ServerRelativeUrl
            switch ($Direction) {
                'Download' { $action = 'DownloadNew' }
                'Sync'     { $action = 'DownloadNew' }
                'Upload'   { $action = 'SkipRemoteOnly' }
            }
        }
        elseif (-not $inRemote -and $inLocal) {
            # Local only
            $fileSize = $local.Size
            switch ($Direction) {
                'Upload'   { $action = 'UploadNew' }
                'Sync'     { $action = 'UploadNew' }
                'Download' { $action = 'SkipLocalOnly' }
            }
        }
        else {
            # Both exist -- compare timestamps
            $fileSize = $remote.Size
            $serverRelUrl = $remote.ServerRelativeUrl

            $remoteTime = $remote.Modified
            $localTime  = $local.Modified

            # Tolerance of 2 seconds for timestamp comparison
            $diffSeconds = [math]::Abs(($remoteTime - $localTime).TotalSeconds)

            if ($diffSeconds -le 2) {
                $action = 'SkipInSync'
            }
            else {
                $remoteNewer = $remoteTime -gt $localTime

                switch ($Direction) {
                    'Download' {
                        if ($remoteNewer) {
                            $action = 'DownloadUpdate'
                        }
                        else {
                            $action = 'SkipLocalNewer'
                        }
                    }
                    'Upload' {
                        if (-not $remoteNewer) {
                            $action = 'UploadUpdate'
                        }
                        else {
                            $action = 'SkipRemoteNewer'
                        }
                    }
                    'Sync' {
                        switch ($ConflictResolution) {
                            'NewerWins' {
                                if ($remoteNewer) { $action = 'DownloadUpdate' }
                                else              { $action = 'UploadUpdate'   }
                            }
                            'LocalWins' {
                                $action = 'UploadUpdate'
                            }
                            'RemoteWins' {
                                $action = 'DownloadUpdate'
                            }
                            'ReportOnly' {
                                $action = 'Conflict'
                            }
                        }
                    }
                }
            }
        }

        $entry = [PSCustomObject]@{
            RelativePath      = $path
            Action            = $action
            Size              = $fileSize
            ServerRelativeUrl = $serverRelUrl
            RemoteModified    = if ($remote) { $remote.Modified } else { $null }
            LocalModified     = if ($local)  { $local.Modified  } else { $null }
            LocalFullPath     = if ($local)  { $local.FullPath  } else { $null }
            RemoteFolder      = $ResolvedRemotePath
        }
        [void]$manifest.Add($entry)
    }

    return $manifest.ToArray()
}

# ---------------------------------------------------------------------------
# File operations
# ---------------------------------------------------------------------------
function Save-SharePointFile {
    <#
    .SYNOPSIS
        Downloads a single file from SharePoint to the local filesystem.
    #>
    param(
        [string]$ServerRelativeUrl,
        [string]$LocalFilePath,
        [datetime]$RemoteModified
    )

    # Ensure parent directory exists
    $parentDir = Split-Path -Path $LocalFilePath -Parent
    if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
    }

    # Warn about long paths
    if ($LocalFilePath.Length -gt $script:MAX_PATH_LENGTH) {
        Write-Warning "Path exceeds $($script:MAX_PATH_LENGTH) characters: $LocalFilePath"
    }

    $encodedPath = ConvertTo-EncodedUrlSegment $ServerRelativeUrl
    $downloadUrl = "$($script:Session.BaseUrl)/_api/web/GetFileByServerRelativeUrl('$encodedPath')/`$value"

    Invoke-SPRequest -Url $downloadUrl -Method GET -OutFile $LocalFilePath -RawResponse

    # Preserve the remote modified timestamp
    if ($RemoteModified -and $RemoteModified -ne [datetime]::MinValue) {
        $fileInfo = Get-Item -LiteralPath $LocalFilePath -Force
        $fileInfo.LastWriteTimeUtc = $RemoteModified
    }
}

function Send-SharePointFile {
    <#
    .SYNOPSIS
        Uploads a single file to SharePoint.
        Files > 10 MB will generate a warning (chunked upload not implemented).
    #>
    param(
        [string]$LocalFilePath,
        [string]$RemoteFolderUrl,
        [string]$FileName
    )

    $fileSize = (Get-Item -LiteralPath $LocalFilePath -Force).Length
    if ($fileSize -gt $script:LARGE_FILE_THRESHOLD) {
        # NOTE: For files >10 MB, SharePoint supports chunked upload via
        # StartUpload/ContinueUpload/FinishUpload REST endpoints. This
        # implementation uses the simple single-request upload which may
        # fail or time out for very large files.
        Write-Warning "File '$FileName' is $(Format-FileSize $fileSize). Large file upload may be slow or fail. Consider chunked upload for files >10 MB."
    }

    $digest = Get-FormDigest
    $encodedFolder = ConvertTo-EncodedUrlSegment $RemoteFolderUrl
    $encodedName   = ConvertTo-EncodedUrlSegment $FileName

    $uploadUrl = "$($script:Session.BaseUrl)/_api/web/GetFolderByServerRelativeUrl('$encodedFolder')/Files/add(url='$encodedName',overwrite=true)"

    $fileBytes = [System.IO.File]::ReadAllBytes($LocalFilePath)

    $uploadHeaders = @{
        'X-RequestDigest' = $digest
    }

    Invoke-SPRequest -Url $uploadUrl -Method POST -Body $fileBytes `
                     -ContentType 'application/octet-stream' `
                     -Headers $uploadHeaders -RawResponse
}

function New-SharePointFolder {
    <#
    .SYNOPSIS
        Creates a folder path on SharePoint, building each segment if needed.
    #>
    param([string]$ServerRelativeUrl)

    $digest = Get-FormDigest
    $encodedPath = ConvertTo-EncodedUrlSegment $ServerRelativeUrl

    $createUrl = "$($script:Session.BaseUrl)/_api/web/folders/add('$encodedPath')"

    $createHeaders = @{
        'X-RequestDigest' = $digest
    }

    try {
        Invoke-SPRequest -Url $createUrl -Method POST -Headers $createHeaders -RawResponse | Out-Null
    }
    catch {
        # Folder may already exist -- 500 with "already exists" is common
        $msg = $_.Exception.Message
        if ($msg -match 'already exists' -or $msg -match 'exists') {
            Write-Verbose "Folder already exists: $ServerRelativeUrl"
        }
        else {
            throw
        }
    }
}

function Ensure-RemoteFolderPath {
    <#
    .SYNOPSIS
        Ensures all segments of a remote folder path exist, creating as needed.
    #>
    param(
        [string]$BasePath,
        [string]$RelativeFolderPath
    )

    if (-not $RelativeFolderPath -or $RelativeFolderPath -eq '.') { return }

    $segments = $RelativeFolderPath -split '/'
    $current = $BasePath

    foreach ($seg in $segments) {
        if (-not $seg) { continue }
        $current = "$current/$seg"
        if ($PSCmdlet.ShouldProcess($current, 'Create remote folder')) {
            try {
                New-SharePointFolder -ServerRelativeUrl $current
            }
            catch {
                Write-Warning "Could not create remote folder '$current': $($_.Exception.Message)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
function Invoke-Main {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # --- Initialize log file ---
    if ($LogPath) {
        $logDir = Split-Path -Path $LogPath -Parent
        if ($logDir -and -not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
    }

    # --- Connect ---
    Write-Host ''
    Write-Host 'Connecting to SharePoint...' -ForegroundColor Cyan
    $session = Connect-SharePoint

    # --- Resolve remote path ---
    $resolvedRemotePath = Resolve-SharePointPath -Path $RemotePath

    Write-Banner -SiteTitle $session.SiteTitle -AuthMethod $session.AuthMethod

    # --- Ensure local directory exists (for download/sync) ---
    if ($Direction -in @('Download', 'Sync')) {
        if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
            New-Item -Path $LocalPath -ItemType Directory -Force | Out-Null
            Write-Verbose "Created local directory: $LocalPath"
        }
    }

    # --- Scan remote ---
    Write-Host 'Scanning remote...' -ForegroundColor Cyan
    $remoteItems = @(Get-RemoteInventory -ServerRelativeUrl $resolvedRemotePath -BasePath $resolvedRemotePath)
    $remoteFolders = @($remoteItems | Where-Object { $_.Type -eq 'Folder' })
    $remoteFiles   = @($remoteItems | Where-Object { $_.Type -eq 'File'   })
    $remoteTotalSize = ($remoteFiles | Measure-Object -Property Size -Sum).Sum
    if (-not $remoteTotalSize) { $remoteTotalSize = 0 }
    Write-Host "  Found: $($remoteFolders.Count) folders, $($remoteFiles.Count) files ($(Format-FileSize $remoteTotalSize) total)" -ForegroundColor Gray

    # --- Scan local ---
    Write-Host 'Scanning local...' -ForegroundColor Cyan
    $localItems = @(Get-LocalInventory -RootPath $LocalPath)
    $localFolders = @($localItems | Where-Object { $_.Type -eq 'Folder' })
    $localFiles   = @($localItems | Where-Object { $_.Type -eq 'File'   })
    $localTotalSize = ($localFiles | Measure-Object -Property Size -Sum).Sum
    if (-not $localTotalSize) { $localTotalSize = 0 }
    Write-Host "  Found: $($localFolders.Count) folders, $($localFiles.Count) files ($(Format-FileSize $localTotalSize) total)" -ForegroundColor Gray

    # --- Build manifest ---
    Write-Host ''
    Write-Host 'Building sync manifest...' -ForegroundColor Cyan
    $manifest = @(Build-SyncManifest -RemoteItems $remoteItems -LocalItems $localItems -ResolvedRemotePath $resolvedRemotePath)

    # Categorize
    $downloadNew    = @($manifest | Where-Object { $_.Action -eq 'DownloadNew' })
    $downloadUpdate = @($manifest | Where-Object { $_.Action -eq 'DownloadUpdate' })
    $uploadNew      = @($manifest | Where-Object { $_.Action -eq 'UploadNew' })
    $uploadUpdate   = @($manifest | Where-Object { $_.Action -eq 'UploadUpdate' })
    $skipInSync     = @($manifest | Where-Object { $_.Action -eq 'SkipInSync' })
    $skipOther      = @($manifest | Where-Object { $_.Action -like 'Skip*' -and $_.Action -ne 'SkipInSync' })
    $conflicts      = @($manifest | Where-Object { $_.Action -eq 'Conflict' })

    $downloadNewSize    = ($downloadNew    | Measure-Object -Property Size -Sum).Sum; if (-not $downloadNewSize)    { $downloadNewSize = 0 }
    $downloadUpdateSize = ($downloadUpdate | Measure-Object -Property Size -Sum).Sum; if (-not $downloadUpdateSize) { $downloadUpdateSize = 0 }
    $uploadNewSize      = ($uploadNew      | Measure-Object -Property Size -Sum).Sum; if (-not $uploadNewSize)      { $uploadNewSize = 0 }
    $uploadUpdateSize   = ($uploadUpdate   | Measure-Object -Property Size -Sum).Sum; if (-not $uploadUpdateSize)   { $uploadUpdateSize = 0 }

    $totalActionCount = $downloadNew.Count + $downloadUpdate.Count + $uploadNew.Count + $uploadUpdate.Count
    $totalActionSize  = $downloadNewSize + $downloadUpdateSize + $uploadNewSize + $uploadUpdateSize

    Write-Host "  Download (new):      $($downloadNew.Count) files ($(Format-FileSize $downloadNewSize))" -ForegroundColor Gray
    Write-Host "  Download (updated):  $($downloadUpdate.Count) files ($(Format-FileSize $downloadUpdateSize))" -ForegroundColor Gray
    Write-Host "  Upload (new):        $($uploadNew.Count) files ($(Format-FileSize $uploadNewSize))" -ForegroundColor Gray
    Write-Host "  Upload (updated):    $($uploadUpdate.Count) files ($(Format-FileSize $uploadUpdateSize))" -ForegroundColor Gray
    Write-Host "  Skip (in sync):      $($skipInSync.Count) files" -ForegroundColor Gray
    if ($skipOther.Count -gt 0) {
        Write-Host "  Skip (other):        $($skipOther.Count) files" -ForegroundColor Gray
    }
    if ($conflicts.Count -gt 0) {
        Write-Host "  Conflicts:           $($conflicts.Count) files" -ForegroundColor Yellow
        foreach ($c in $conflicts) {
            Write-Host "    CONFLICT: $($c.RelativePath)  Remote=$(($c.RemoteModified).ToString('s'))  Local=$(($c.LocalModified).ToString('s'))" -ForegroundColor Yellow
        }
    }
    Write-Host "  Total actions:       $totalActionCount files ($(Format-FileSize $totalActionSize))" -ForegroundColor White
    Write-Host ''

    # Nothing to do?
    if ($totalActionCount -eq 0) {
        Write-Host 'Nothing to sync. All files are up to date.' -ForegroundColor Green
        $stopwatch.Stop()
        Write-Host "Duration: $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s" -ForegroundColor DarkGray
        return
    }

    # --- Confirmation prompt for upload/sync ---
    $uploadActionCount = $uploadNew.Count + $uploadUpdate.Count
    if ($uploadActionCount -gt 0 -and -not $Force -and -not $WhatIfPreference) {
        Write-Host "WARNING: $uploadActionCount file(s) will be modified on SharePoint." -ForegroundColor Yellow
        $confirm = Read-Host "Continue? [y/N]"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host 'Operation cancelled by user.' -ForegroundColor Yellow
            return
        }
    }

    # --- Execute actions ---
    $actionItems = @($manifest | Where-Object { $_.Action -in @('DownloadNew', 'DownloadUpdate', 'UploadNew', 'UploadUpdate') })
    $current = 0
    $downloadedCount = 0
    $downloadedBytes = [long]0
    $uploadedCount   = 0
    $uploadedBytes   = [long]0
    $skippedCount    = $skipInSync.Count + $skipOther.Count + $conflicts.Count
    $errorCount      = 0
    $errorFiles      = [System.Collections.ArrayList]::new()
    $replaceYesToAll = $false
    $replaceNoToAll  = $false

    foreach ($item in $actionItems) {
        $current++
        $sizeLabel = Format-FileSize $item.Size
        $opTimer = [System.Diagnostics.Stopwatch]::StartNew()

        switch ($item.Action) {
            { $_ -in @('DownloadNew', 'DownloadUpdate') } {
                $localFilePath = Join-Path $LocalPath ($item.RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar.ToString())

                $proceed = $true
                if ($ConfirmReplace -and $item.Action -eq 'DownloadUpdate' -and -not $WhatIfPreference) {
                    $query = "Overwrite local file '$($item.RelativePath)' " +
                             "(modified $($item.LocalModified.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))) " +
                             "with remote version (modified $($item.RemoteModified.ToLocalTime().ToString('yyyy-MM-dd HH:mm')))?"
                    $proceed = $PSCmdlet.ShouldContinue($query, 'Confirm file replacement',
                        [ref]$replaceYesToAll, [ref]$replaceNoToAll)
                }
                if (-not $proceed) {
                    $opTimer.Stop()
                    $skippedCount++
                    Write-Progress2 -Current $current -Total $totalActionCount `
                                    -Path $item.RelativePath -Size $sizeLabel -Result 'Skipped'
                    Write-LogEntry -Action 'Download' -Path $item.RelativePath `
                                   -Size $item.Size -Status 'SKIPPED (user declined)' `
                                   -DurationMs $opTimer.ElapsedMilliseconds
                }
                elseif ($PSCmdlet.ShouldProcess($item.RelativePath, "Download from SharePoint")) {
                    try {
                        Save-SharePointFile -ServerRelativeUrl $item.ServerRelativeUrl `
                                            -LocalFilePath $localFilePath `
                                            -RemoteModified $item.RemoteModified
                        $opTimer.Stop()
                        Write-Progress2 -Current $current -Total $totalActionCount `
                                        -Path $item.RelativePath -Size $sizeLabel -Result 'Downloaded'
                        Write-LogEntry -Action 'Download' -Path $item.RelativePath `
                                       -Size $item.Size -Status 'OK' -DurationMs $opTimer.ElapsedMilliseconds
                        $downloadedCount++
                        $downloadedBytes += $item.Size
                    }
                    catch {
                        $opTimer.Stop()
                        $errorCount++
                        [void]$errorFiles.Add($item.RelativePath)
                        Write-Progress2 -Current $current -Total $totalActionCount `
                                        -Path $item.RelativePath -Size $sizeLabel -Result 'Error'
                        Write-Warning "  Error downloading '$($item.RelativePath)': $($_.Exception.Message)"
                        Write-LogEntry -Action 'Download' -Path $item.RelativePath `
                                       -Size $item.Size -Status "ERROR: $($_.Exception.Message)" `
                                       -DurationMs $opTimer.ElapsedMilliseconds
                    }
                }
                else {
                    $opTimer.Stop()
                    Write-Progress2 -Current $current -Total $totalActionCount `
                                    -Path $item.RelativePath -Size $sizeLabel -Result 'WhatIf'
                }
            }

            { $_ -in @('UploadNew', 'UploadUpdate') } {
                $localFilePath = $item.LocalFullPath
                if (-not $localFilePath) {
                    $localFilePath = Join-Path $LocalPath ($item.RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar.ToString())
                }
                $fileName = Split-Path -Path $item.RelativePath -Leaf
                $remoteFolder = $item.RemoteFolder
                $parentRelative = Split-Path -Path $item.RelativePath -Parent
                if ($parentRelative) {
                    $parentRelative = $parentRelative -replace '\\', '/'
                    $remoteFolder = "$($item.RemoteFolder)/$parentRelative"
                }

                $proceed = $true
                if ($ConfirmReplace -and $item.Action -eq 'UploadUpdate' -and -not $WhatIfPreference) {
                    $query = "Overwrite remote file '$($item.RelativePath)' " +
                             "(modified $($item.RemoteModified.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))) " +
                             "with local version (modified $($item.LocalModified.ToLocalTime().ToString('yyyy-MM-dd HH:mm')))?"
                    $proceed = $PSCmdlet.ShouldContinue($query, 'Confirm file replacement',
                        [ref]$replaceYesToAll, [ref]$replaceNoToAll)
                }
                if (-not $proceed) {
                    $opTimer.Stop()
                    $skippedCount++
                    Write-Progress2 -Current $current -Total $totalActionCount `
                                    -Path $item.RelativePath -Size $sizeLabel -Result 'Skipped'
                    Write-LogEntry -Action 'Upload' -Path $item.RelativePath `
                                   -Size $item.Size -Status 'SKIPPED (user declined)' `
                                   -DurationMs $opTimer.ElapsedMilliseconds
                }
                elseif ($PSCmdlet.ShouldProcess($item.RelativePath, "Upload to SharePoint")) {
                    try {
                        # Ensure remote folder path exists
                        if ($parentRelative) {
                            Ensure-RemoteFolderPath -BasePath $item.RemoteFolder -RelativeFolderPath $parentRelative
                        }

                        Send-SharePointFile -LocalFilePath $localFilePath `
                                            -RemoteFolderUrl $remoteFolder `
                                            -FileName $fileName
                        $opTimer.Stop()
                        Write-Progress2 -Current $current -Total $totalActionCount `
                                        -Path $item.RelativePath -Size $sizeLabel -Result 'Uploaded'
                        Write-LogEntry -Action 'Upload' -Path $item.RelativePath `
                                       -Size $item.Size -Status 'OK' -DurationMs $opTimer.ElapsedMilliseconds
                        $uploadedCount++
                        $uploadedBytes += $item.Size
                    }
                    catch {
                        $opTimer.Stop()
                        $errorCount++
                        [void]$errorFiles.Add($item.RelativePath)
                        Write-Progress2 -Current $current -Total $totalActionCount `
                                        -Path $item.RelativePath -Size $sizeLabel -Result 'Error'
                        Write-Warning "  Error uploading '$($item.RelativePath)': $($_.Exception.Message)"
                        Write-LogEntry -Action 'Upload' -Path $item.RelativePath `
                                       -Size $item.Size -Status "ERROR: $($_.Exception.Message)" `
                                       -DurationMs $opTimer.ElapsedMilliseconds
                    }
                }
                else {
                    $opTimer.Stop()
                    Write-Progress2 -Current $current -Total $totalActionCount `
                                    -Path $item.RelativePath -Size $sizeLabel -Result 'WhatIf'
                }
            }
        }
    }

    # --- Summary ---
    $stopwatch.Stop()
    Write-Host ''
    Write-Host 'Summary' -ForegroundColor Cyan
    Write-Host ('-' * 30) -ForegroundColor Cyan
    Write-Host "  Downloaded:  $downloadedCount files ($(Format-FileSize $downloadedBytes))"
    Write-Host "  Uploaded:    $uploadedCount files ($(Format-FileSize $uploadedBytes))"
    Write-Host "  Skipped:     $skippedCount files"

    if ($errorCount -gt 0) {
        Write-Host "  Errors:      $errorCount" -ForegroundColor Red
        foreach ($ef in $errorFiles) {
            Write-Host "    - $ef" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  Errors:      0" -ForegroundColor Green
    }

    Write-Host "  Duration:    $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s" -ForegroundColor DarkGray
    Write-Host ''

    Write-LogEntry -Action 'Summary' -Path '' -Size 0 `
                   -Status "Downloaded=$downloadedCount Uploaded=$uploadedCount Skipped=$skippedCount Errors=$errorCount" `
                   -DurationMs $stopwatch.ElapsedMilliseconds
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
try {
    Invoke-Main
}
catch {
    Write-Host ''
    Write-Host "FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-LogEntry -Action 'Fatal' -Path '' -Size 0 -Status $_.Exception.Message
    exit 1
}

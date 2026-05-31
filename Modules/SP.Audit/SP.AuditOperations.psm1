#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Audit Operations
.DESCRIPTION
    Provides operational functions for report distribution, notification dispatch,
    compliance evidence packaging, orchestrator history tracking, and log
    retention/archival. These functions produce side effects (send email, write
    archives, clean up old files).

    HTML output uses inline CSS only and table-based layout for Word
    copy-paste compatibility. No flexbox, no grid, no external stylesheets.
.NOTES
    Module: SP.Audit / SP.AuditOperations
    Version: 1.0.0
    Component: Audit Operations

    Color taxonomy:
        Green  #339933 - Approved / success
        Red    #CC3333 - Revoked / error
        Orange #FF8800 - Pending / warn
        Blue   #336699 - Info / neutral
        Gray   #777777 - N/A / footer
#>

#region Report Distribution

function Send-SPReport {
    <#
    .SYNOPSIS
        Sends a leadership report to a recipient via SMTP email.
    .DESCRIPTION
        Reads SMTP configuration from Audit.Smtp and sends the report file
        as an attachment to the specified recipient. Requires Enabled field
        in the Audit.Smtp config section.

        When Audit.Smtp.Enabled is false, logs at DEBUG level and returns without sending.
        When Audit.Smtp.Enabled is true, sends the report via Send-MailMessage.

        SMTP fallback: if Audit.Smtp connection fields (Server, Port, From,
        UseSsl) are empty, they are inherited from Notification.Smtp. This
        allows a single SMTP config in the Notification section to serve both
        notification delivery and report distribution. Audit.Smtp.Enabled and
        Audit.Smtp.SubjectPrefix remain exclusive to this function.
    .PARAMETER ReportPath
        Full path to the HTML report file to send.
    .PARAMETER RecipientEmail
        Email address of the recipient.
    .PARAMETER RecipientName
        Display name of the recipient (for log messages and future Subject line).
    .PARAMETER Subject
        Optional email subject. Defaults to "{SubjectPrefix} Report for {RecipientName}".
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{Success; Data=@{Action; Recipient; File; Subject}; Error}
    .EXAMPLE
        Send-SPReport -ReportPath 'C:\Audit\leadership\executive-summary.html' `
            -RecipientEmail 'vp@corp.com' -RecipientName 'VP Smith'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ReportPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RecipientEmail,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RecipientName,

        [Parameter()]
        [string]$Subject,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Load SMTP config -- primary: Audit.Smtp, fallback: Notification.Smtp
    $smtpConfig = $null
    $notifSmtpConfig = $null
    try {
        $config = Get-SPConfig
        if ($null -ne $config) {
            if ($config.PSObject.Properties.Name -contains 'Audit' -and
                $config.Audit.PSObject.Properties.Name -contains 'Smtp') {
                $smtpConfig = $config.Audit.Smtp
            }
            if ($config.PSObject.Properties.Name -contains 'Notification' -and
                $config.Notification.PSObject.Properties.Name -contains 'Smtp') {
                $notifSmtpConfig = $config.Notification.Smtp
            }
        }
    }
    catch {
        # Config unavailable -- treat as disabled
    }

    $smtpEnabled = $false
    if ($null -ne $smtpConfig -and
        $smtpConfig.PSObject.Properties.Name -contains 'Enabled') {
        $smtpEnabled = $smtpConfig.Enabled -eq $true
    }

    # Build subject line
    $subjectPrefix = '[SailPoint Audit]'
    if ($null -ne $smtpConfig -and
        $smtpConfig.PSObject.Properties.Name -contains 'SubjectPrefix' -and
        -not [string]::IsNullOrWhiteSpace($smtpConfig.SubjectPrefix)) {
        $subjectPrefix = $smtpConfig.SubjectPrefix
    }
    if ([string]::IsNullOrWhiteSpace($Subject)) {
        $Subject = "$subjectPrefix Report for $RecipientName"
    }

    $fileName = Split-Path -Path $ReportPath -Leaf

    if (-not $smtpEnabled) {
        # SMTP disabled -- log at DEBUG and return
        $logMsg = "SMTP disabled -- would send '$fileName' to $RecipientEmail ($RecipientName)"
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message $logMsg `
                -Severity DEBUG -Component 'SP.AuditReport' -Action 'Send-SPReport' `
                -CorrelationID $CorrelationID `
                -AdditionalFields @{
                    Recipient = $RecipientEmail
                    File      = $ReportPath
                    Subject   = $Subject
                    SmtpState = 'Disabled'
                }
        }
        Write-Verbose $logMsg

        return @{
            Success = $true
            Data    = @{
                Action    = 'Logged'
                Recipient = $RecipientEmail
                File      = $ReportPath
                Subject   = $Subject
            }
            Error   = $null
        }
    }

    # SMTP enabled -- read connection settings from Audit.Smtp
    $smtpServer = ''
    $smtpPort   = 587
    $smtpFrom   = ''
    $smtpUseSsl = $true
    $smtpSource = 'Audit.Smtp'

    if ($null -ne $smtpConfig) {
        if ($smtpConfig.PSObject.Properties.Name -contains 'Server') { $smtpServer = $smtpConfig.Server }
        if ($smtpConfig.PSObject.Properties.Name -contains 'Port')   { $smtpPort   = $smtpConfig.Port }
        if ($smtpConfig.PSObject.Properties.Name -contains 'From')   { $smtpFrom   = $smtpConfig.From }
        if ($smtpConfig.PSObject.Properties.Name -contains 'UseSsl') { $smtpUseSsl = $smtpConfig.UseSsl -eq $true }
    }

    # Fallback to Notification.Smtp when Audit.Smtp connection fields are empty
    if (([string]::IsNullOrWhiteSpace($smtpServer) -or [string]::IsNullOrWhiteSpace($smtpFrom)) -and
        $null -ne $notifSmtpConfig) {
        if ([string]::IsNullOrWhiteSpace($smtpServer) -and
            $notifSmtpConfig.PSObject.Properties.Name -contains 'Server' -and
            -not [string]::IsNullOrWhiteSpace($notifSmtpConfig.Server)) {
            $smtpServer = $notifSmtpConfig.Server
            $smtpSource = 'Notification.Smtp'
        }
        if ([string]::IsNullOrWhiteSpace($smtpFrom) -and
            $notifSmtpConfig.PSObject.Properties.Name -contains 'From' -and
            -not [string]::IsNullOrWhiteSpace($notifSmtpConfig.From)) {
            $smtpFrom = $notifSmtpConfig.From
            $smtpSource = 'Notification.Smtp'
        }
        # Inherit Port and UseSsl from fallback only if Server came from there
        if ($smtpSource -eq 'Notification.Smtp') {
            if ($null -ne $smtpConfig -and
                -not ($smtpConfig.PSObject.Properties.Name -contains 'Port') -and
                $notifSmtpConfig.PSObject.Properties.Name -contains 'Port') {
                $smtpPort = $notifSmtpConfig.Port
            }
            if ($null -ne $smtpConfig -and
                -not ($smtpConfig.PSObject.Properties.Name -contains 'UseSsl') -and
                $notifSmtpConfig.PSObject.Properties.Name -contains 'UseSsl') {
                $smtpUseSsl = $notifSmtpConfig.UseSsl -eq $true
            }
            $fallbackMsg = "Audit.Smtp connection fields empty -- using Notification.Smtp as fallback"
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message $fallbackMsg `
                    -Severity INFO -Component 'SP.AuditReport' -Action 'Send-SPReport' `
                    -CorrelationID $CorrelationID
            }
            Write-Verbose $fallbackMsg
        }
    }

    # Validate required SMTP fields (after fallback)
    if ([string]::IsNullOrWhiteSpace($smtpServer) -or [string]::IsNullOrWhiteSpace($smtpFrom)) {
        $warnMsg = "SMTP enabled but Server or From is empty in both Audit.Smtp and Notification.Smtp -- cannot send '$fileName' to $RecipientEmail"
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message $warnMsg -Severity WARN -Component 'SP.AuditReport' `
                -Action 'Send-SPReport' -CorrelationID $CorrelationID
        }
        Write-Warning $warnMsg

        return @{
            Success = $false
            Data    = @{
                Action    = 'Failed'
                Recipient = $RecipientEmail
                File      = $ReportPath
                Subject   = $Subject
            }
            Error   = $warnMsg
        }
    }

    # Validate report file exists
    if (-not (Test-Path -Path $ReportPath -PathType Leaf)) {
        $errMsg = "Report file not found: $ReportPath"
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditReport' `
                -Action 'Send-SPReport' -CorrelationID $CorrelationID
        }
        Write-Warning $errMsg

        return @{
            Success = $false
            Data    = @{
                Action    = 'Failed'
                Recipient = $RecipientEmail
                File      = $ReportPath
                Subject   = $Subject
            }
            Error   = $errMsg
        }
    }

    try {
        $mailParams = @{
            SmtpServer    = $smtpServer
            Port          = $smtpPort
            From          = $smtpFrom
            To            = $RecipientEmail
            Subject       = $Subject
            Body          = "Please find the attached leadership report for $RecipientName."
            BodyAsHtml    = $false
            UseSsl        = $smtpUseSsl
            Attachments   = @($ReportPath)
            ErrorAction   = 'Stop'
            WarningAction = 'SilentlyContinue'
        }

        Send-MailMessage @mailParams

        $logMsg = "Report '$fileName' sent to $RecipientEmail ($RecipientName) via $smtpSource"
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message $logMsg `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Send-SPReport' `
                -CorrelationID $CorrelationID `
                -AdditionalFields @{
                    Recipient  = $RecipientEmail
                    File       = $ReportPath
                    Subject    = $Subject
                    Server     = $smtpServer
                    Port       = $smtpPort
                    SmtpSource = $smtpSource
                }
        }
        Write-Verbose $logMsg

        return @{
            Success = $true
            Data    = @{
                Action    = 'Sent'
                Recipient = $RecipientEmail
                File      = $ReportPath
                Subject   = $Subject
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "SMTP send failed for '$fileName' to ${RecipientEmail}: $($_.Exception.Message)"
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message $errMsg `
                -Severity ERROR -Component 'SP.AuditReport' -Action 'Send-SPReport' `
                -CorrelationID $CorrelationID `
                -AdditionalFields @{
                    Recipient  = $RecipientEmail
                    File       = $ReportPath
                    Subject    = $Subject
                    Server     = $smtpServer
                    Port       = $smtpPort
                    ErrorDetail = $_.Exception.Message
                }
        }
        Write-Warning $errMsg

        return @{
            Success = $false
            Data    = @{
                Action    = 'Failed'
                Recipient = $RecipientEmail
                File      = $ReportPath
                Subject   = $Subject
            }
            Error   = $errMsg
        }
    }
}

#endregion

#region Compliance Evidence Package

function Export-SPCompliancePackage {
    <#
    .SYNOPSIS
        Bundles audit artifacts from a date range into a single ZIP evidence package.
    .DESCRIPTION
        Scans Audit and DeltaCert output directories for HTML, CSV, JSONL, and TXT
        artifacts, then packages them into a single ZIP file with a JSON manifest
        containing SHA256 hashes per artifact. Designed for SOX 404, SOC 2, and
        ISO 27001 evidence delivery.
    .PARAMETER After
        Include artifacts modified after this datetime.
    .PARAMETER Before
        Include artifacts modified before this datetime.
    .PARAMETER AuditOutputPath
        Audit output directory. Resolved from config if omitted.
    .PARAMETER DeltaCertOutputPath
        DeltaCert output directory. Resolved from config if omitted.
    .PARAMETER OutputPath
        Directory for the output ZIP. Defaults to current directory.
    .PARAMETER PackageName
        Custom ZIP file name (without extension). Auto-generated from date range if omitted.
    .PARAMETER Scope
        Which directories to include: Full (both), AuditOnly, or DeltaCertOnly.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] Package result with path, artifact count, and category breakdown.
    .EXAMPLE
        Export-SPCompliancePackage -After (Get-Date).AddDays(-90) -Before (Get-Date)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][DateTime]$After,
        [Parameter()][DateTime]$Before,
        [Parameter()][string]$AuditOutputPath,
        [Parameter()][string]$DeltaCertOutputPath,
        [Parameter()][string]$OutputPath = '.',
        [Parameter()][string]$PackageName,
        [Parameter()][ValidateSet('Full','AuditOnly','DeltaCertOnly')]
        [string]$Scope = 'Full',
        [Parameter()][string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Export-SPCompliancePackage: starting (Scope=$Scope)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
        -CorrelationID $CorrelationID

    # Resolve paths from config if not provided
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -or
        [string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) {
        try {
            $config = Get-SPConfig
            if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -and
                $null -ne $config -and
                $config.PSObject.Properties.Name -contains 'Audit' -and
                $config.Audit.PSObject.Properties.Name -contains 'OutputPath' -and
                -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
                $AuditOutputPath = $config.Audit.OutputPath
            }
            if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath) -and
                $null -ne $config -and
                $config.PSObject.Properties.Name -contains 'DeltaCert' -and
                $config.DeltaCert.PSObject.Properties.Name -contains 'OutputPath' -and
                -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
                $DeltaCertOutputPath = $config.DeltaCert.OutputPath
            }
        }
        catch {
            Write-SPLog -Message "Could not load config for path resolution: $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
                -CorrelationID $CorrelationID
        }
    }
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath))     { $AuditOutputPath     = '.\Audit' }
    if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) { $DeltaCertOutputPath = '.\DeltaCert' }

    # Resolve toolkit version
    $toolkitVersion = 'Unknown'
    try {
        $cfgCheck = Get-SPConfig
        if ($null -ne $cfgCheck -and
            $cfgCheck.PSObject.Properties.Name -contains 'Global' -and
            $cfgCheck.Global.PSObject.Properties.Name -contains 'ToolkitVersion') {
            $toolkitVersion = $cfgCheck.Global.ToolkitVersion
        }
    } catch { }

    # Ensure output directory exists
    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    # Supported artifact extensions
    $supportedExtensions = @('.html', '.csv', '.jsonl', '.txt', '.json', '.log')

    # Collect artifacts
    $artifacts = [System.Collections.Generic.List[hashtable]]::new()

    # Helper: scan a directory for matching files
    function _ScanDirectory {
        param(
            [string]$Path,
            [string]$Category,
            [string]$ZipSubfolder
        )
        if (-not (Test-Path -Path $Path -PathType Container)) { return }
        $files = Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.Extension -notin $supportedExtensions) { continue }
            # Date range filter by last write time
            if ($PSBoundParameters.ContainsKey('After') -or $After -ne $null) {
                # Use the outer scope After/Before
            }
            if ($null -ne $script:filterAfter -and $f.LastWriteTime -lt $script:filterAfter) { continue }
            if ($null -ne $script:filterBefore -and $f.LastWriteTime -gt $script:filterBefore) { continue }

            # Determine sub-category
            $subCategory = $Category
            if ($f.Extension -eq '.csv') { $subCategory = 'CsvExports' }
            elseif ($f.Extension -eq '.jsonl') { $subCategory = 'AuditTrails' }
            elseif ($f.Extension -eq '.txt') { $subCategory = 'RemediationProof' }

            # Determine zip subfolder for CSVs
            $targetFolder = $ZipSubfolder
            if ($f.Extension -eq '.csv') { $targetFolder = 'csv' }

            $artifacts.Add(@{
                FullPath     = $f.FullName
                FileName     = $f.Name
                Category     = $subCategory
                ZipFolder    = $targetFolder
                SizeBytes    = $f.Length
                LastModified = $f.LastWriteTime
            })
        }
    }

    # Store filter dates in script scope for the helper
    $script:filterAfter  = if ($PSBoundParameters.ContainsKey('After'))  { $After }  else { $null }
    $script:filterBefore = if ($PSBoundParameters.ContainsKey('Before')) { $Before } else { $null }

    # Scan directories based on scope
    if ($Scope -ne 'DeltaCertOnly') {
        _ScanDirectory -Path $AuditOutputPath -Category 'AuditReports' -ZipSubfolder 'audit'
        # Scan leadership subdirectory
        $leadershipPath = Join-Path -Path $AuditOutputPath -ChildPath 'leadership'
        if (Test-Path -Path $leadershipPath -PathType Container) {
            $leaderFiles = Get-ChildItem -Path $leadershipPath -File -ErrorAction SilentlyContinue
            foreach ($f in $leaderFiles) {
                if ($f.Extension -notin $supportedExtensions) { continue }
                if ($null -ne $script:filterAfter -and $f.LastWriteTime -lt $script:filterAfter) { continue }
                if ($null -ne $script:filterBefore -and $f.LastWriteTime -gt $script:filterBefore) { continue }
                $artifacts.Add(@{
                    FullPath     = $f.FullName
                    FileName     = $f.Name
                    Category     = 'LeadershipReports'
                    ZipFolder    = 'leadership'
                    SizeBytes    = $f.Length
                    LastModified = $f.LastWriteTime
                })
            }
        }
    }

    if ($Scope -ne 'AuditOnly') {
        _ScanDirectory -Path $DeltaCertOutputPath -Category 'DeltaCertReports' -ZipSubfolder 'deltacert'
    }

    Write-SPLog -Message "Export-SPCompliancePackage: found $($artifacts.Count) artifacts" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
        -CorrelationID $CorrelationID

    # Build package name
    if ([string]::IsNullOrWhiteSpace($PackageName)) {
        $afterStr  = if ($null -ne $script:filterAfter)  { $script:filterAfter.ToString('yyyy-MM-dd') }  else { 'all' }
        $beforeStr = if ($null -ne $script:filterBefore) { $script:filterBefore.ToString('yyyy-MM-dd') } else { 'now' }
        $PackageName = "compliance-evidence-${afterStr}-to-${beforeStr}"
    }
    $zipFileName = "${PackageName}.zip"
    $zipFilePath = Join-Path -Path $OutputPath -ChildPath $zipFileName

    # Remove existing ZIP if present (overwrite)
    if (Test-Path -Path $zipFilePath) {
        Remove-Item -Path $zipFilePath -Force
    }

    # Build manifest and create ZIP
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $packageId    = [guid]::NewGuid().ToString()
    $generatedAt  = (Get-Date).ToUniversalTime().ToString('o')
    $manifestArts = [System.Collections.Generic.List[hashtable]]::new()

    # Compute SHA256 for each artifact
    foreach ($art in $artifacts) {
        $sha256 = ''
        try {
            $hashResult = Get-FileHash -Path $art.FullPath -Algorithm SHA256
            $sha256 = $hashResult.Hash
        } catch {
            Write-SPLog -Message "Could not hash file $($art.FileName): $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
                -CorrelationID $CorrelationID
        }

        $manifestArts.Add(@{
            FileName     = $art.FileName
            OriginalPath = $art.FullPath
            Type         = $art.ZipFolder
            Category     = $art.Category
            SizeBytes    = $art.SizeBytes
            SHA256       = $sha256
        })
    }

    # Build category counts
    $categories = @{
        AuditReports      = 0
        CsvExports        = 0
        AuditTrails       = 0
        LeadershipReports = 0
        DeltaCertReports  = 0
        RemediationProof  = 0
    }
    foreach ($art in $artifacts) {
        if ($categories.ContainsKey($art.Category)) {
            $categories[$art.Category]++
        }
    }

    $totalSizeBytes = 0
    foreach ($art in $artifacts) { $totalSizeBytes += $art.SizeBytes }

    $dateRange = @{
        After  = if ($null -ne $script:filterAfter)  { $script:filterAfter.ToString('o') }  else { $null }
        Before = if ($null -ne $script:filterBefore) { $script:filterBefore.ToString('o') } else { $null }
    }

    $manifest = @{
        PackageId      = $packageId
        GeneratedAt    = $generatedAt
        DateRange      = $dateRange
        ToolkitVersion = $toolkitVersion
        Artifacts      = @($manifestArts)
        Summary        = @{
            TotalArtifacts = $artifacts.Count
            TotalSizeBytes = $totalSizeBytes
            Categories     = $categories
        }
    }

    # Create ZIP archive
    try {
        $zipStream  = [System.IO.File]::Create($zipFilePath)
        $zipArchive = [System.IO.Compression.ZipArchive]::new($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)

        # Add manifest.json at root
        $manifestJson = $manifest | ConvertTo-Json -Depth 10
        $manifestEntry = $zipArchive.CreateEntry('manifest.json')
        $manifestWriter = [System.IO.StreamWriter]::new($manifestEntry.Open())
        $manifestWriter.Write($manifestJson)
        $manifestWriter.Close()

        # Add each artifact to its subfolder
        foreach ($art in $artifacts) {
            $entryName = "$($art.ZipFolder)/$($art.FileName)"
            $entry = $zipArchive.CreateEntry($entryName)
            $entryStream = $entry.Open()
            try {
                $fileBytes = [System.IO.File]::ReadAllBytes($art.FullPath)
                $entryStream.Write($fileBytes, 0, $fileBytes.Length)
            } finally {
                $entryStream.Close()
            }
        }

        $zipArchive.Dispose()
        $zipStream.Close()
    }
    catch {
        Write-SPLog -Message "Failed to create ZIP: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
            -CorrelationID $CorrelationID
        return @{
            Success = $false
            Error   = "Failed to create ZIP: $($_.Exception.Message)"
        }
    }

    $resolvedZipPath = (Resolve-Path -Path $zipFilePath).Path

    Write-SPLog -Message "Export-SPCompliancePackage: created $resolvedZipPath ($($artifacts.Count) artifacts, $totalSizeBytes bytes)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Export-SPCompliancePackage' `
        -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            PackagePath    = $resolvedZipPath
            PackageId      = $packageId
            ArtifactCount  = $artifacts.Count
            TotalSizeBytes = $totalSizeBytes
            Categories     = $categories
        }
    }
}

#endregion

#region Notification Dispatch

function Send-SPWebhook {
    <#
    .SYNOPSIS
        Sends a JSON payload to an HTTP webhook endpoint.
    .DESCRIPTION
        Converts the payload hashtable to JSON and sends it via Invoke-RestMethod.
        Returns a result hashtable with Success, StatusCode, Response, and Error fields.
    .PARAMETER Url
        The webhook endpoint URL.
    .PARAMETER Payload
        Hashtable to serialize as the JSON request body.
    .PARAMETER Method
        HTTP method. Defaults to POST.
    .PARAMETER Headers
        Optional hashtable of additional HTTP headers.
    .PARAMETER TimeoutSeconds
        Request timeout in seconds. Defaults to 30.
    .PARAMETER CorrelationID
        Optional correlation ID for log tracing.
    .OUTPUTS
        [hashtable] @{ Success; StatusCode; Response; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter(Mandatory)]
        [hashtable]$Payload,

        [Parameter()]
        [string]$Method = 'POST',

        [Parameter()]
        [hashtable]$Headers,

        [Parameter()]
        [int]$TimeoutSeconds = 30,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        $json = $Payload | ConvertTo-Json -Depth 10 -Compress

        $restParams = @{
            Method      = $Method
            Uri         = $Url
            Body        = $json
            ContentType = 'application/json'
            TimeoutSec  = $TimeoutSeconds
            ErrorAction = 'Stop'
        }
        if ($null -ne $Headers -and $Headers.Count -gt 0) {
            $restParams['Headers'] = $Headers
        }

        $response = Invoke-RestMethod @restParams

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Webhook sent to $Url ($Method)" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Send-SPWebhook' `
                -CorrelationID $CorrelationID
        }

        return @{
            Success    = $true
            StatusCode = 200
            Response   = $response
            Error      = $null
        }
    }
    catch {
        $statusCode = 0
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and
            $null -ne $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        }

        $errMsg = "Webhook call to $Url failed: $($_.Exception.Message)"
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message $errMsg `
                -Severity ERROR -Component 'SP.AuditReport' -Action 'Send-SPWebhook' `
                -CorrelationID $CorrelationID
        }

        return @{
            Success    = $false
            StatusCode = $statusCode
            Response   = $null
            Error      = $errMsg
        }
    }
}

function Send-SPNotification {
    <#
    .SYNOPSIS
        Dispatches notifications via configured backends (Log, Smtp, Webhook).
    .DESCRIPTION
        Reads the Notification config section and delivers the message through
        each active backend. The Log backend always runs. Smtp sends email via
        Send-MailMessage. Webhook sends a JSON POST via Send-SPWebhook.

        Missing or incomplete backend configuration produces a WARN log and
        skips that backend (does not throw).
    .PARAMETER Subject
        Notification subject line.
    .PARAMETER Body
        Notification body content. For SMTP this is sent as HTML.
    .PARAMETER Severity
        Severity level: Info, Warning, or Critical. Maps to log severity and
        is included in webhook payloads.
    .PARAMETER Category
        Notification category (e.g. HealthAlert, Escalation, Completion, Digest).
    .PARAMETER Recipients
        Email addresses for the SMTP backend.
    .PARAMETER Attachments
        File paths to attach (SMTP only). Non-existent files are skipped with WARN.
    .PARAMETER Metadata
        Extra fields included in the webhook JSON payload.
    .PARAMETER CorrelationID
        Optional correlation ID for log tracing.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Backends=@(...) } }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Body,

        [Parameter()]
        [ValidateSet('Info','Warning','Critical')]
        [string]$Severity = 'Info',

        [Parameter()]
        [string]$Category,

        [Parameter()]
        [string[]]$Recipients,

        [Parameter()]
        [string[]]$Attachments,

        [Parameter()]
        [hashtable]$Metadata,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Load notification config
    $notifConfig = $null
    try {
        $config = Get-SPConfig
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'Notification') {
            $notifConfig = $config.Notification
        }
    }
    catch {
        # Config unavailable -- fall back to Log only
    }

    # Determine active backends
    $backends = @('Log')
    if ($null -ne $notifConfig -and
        $notifConfig.PSObject.Properties.Name -contains 'Backends') {
        $configuredBackends = @($notifConfig.Backends)
        if ($configuredBackends.Count -gt 0) {
            $backends = $configuredBackends
        }
    }

    # Ensure Log is always present
    if ('Log' -notin $backends) {
        $backends = @('Log') + $backends
    }

    $backendResults = [System.Collections.Generic.List[hashtable]]::new()

    # Map severity to Write-SPLog severity
    $logSeverity = switch ($Severity) {
        'Critical' { 'ERROR' }
        'Warning'  { 'WARN'  }
        default    { 'INFO'  }
    }

    # --- Log backend (always) ---
    $logMsg = "[$Severity] $Subject -- $Body"
    if (-not [string]::IsNullOrWhiteSpace($Category)) {
        $logMsg = "[$Severity][$Category] $Subject -- $Body"
    }
    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message $logMsg `
            -Severity $logSeverity -Component 'SP.AuditReport' -Action 'Send-SPNotification' `
            -CorrelationID $CorrelationID
    }
    $backendResults.Add(@{ Backend = 'Log'; Status = 'Sent' })

    # --- SMTP backend ---
    if ('Smtp' -in $backends) {
        $smtpResult = @{ Backend = 'Smtp'; Status = 'Skipped' }

        # Read SMTP settings from Notification.Smtp config
        $smtpConf = $null
        if ($null -ne $notifConfig -and
            $notifConfig.PSObject.Properties.Name -contains 'Smtp') {
            $smtpConf = $notifConfig.Smtp
        }

        $smtpServer = ''
        $smtpPort   = 587
        $smtpFrom   = ''
        $smtpUseSsl = $true

        if ($null -ne $smtpConf) {
            if ($smtpConf.PSObject.Properties.Name -contains 'Server') { $smtpServer = $smtpConf.Server }
            if ($smtpConf.PSObject.Properties.Name -contains 'Port')   { $smtpPort   = $smtpConf.Port }
            if ($smtpConf.PSObject.Properties.Name -contains 'From')   { $smtpFrom   = $smtpConf.From }
            if ($smtpConf.PSObject.Properties.Name -contains 'UseSsl') { $smtpUseSsl = $smtpConf.UseSsl -eq $true }
        }

        if ([string]::IsNullOrWhiteSpace($smtpServer) -or [string]::IsNullOrWhiteSpace($smtpFrom)) {
            $warnMsg = 'SMTP backend configured but Server or From is empty -- skipping SMTP delivery'
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message $warnMsg -Severity WARN -Component 'SP.AuditReport' `
                    -Action 'Send-SPNotification' -CorrelationID $CorrelationID
            }
        }
        elseif ($null -eq $Recipients -or $Recipients.Count -eq 0) {
            $warnMsg = 'SMTP backend configured but no Recipients provided -- skipping SMTP delivery'
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message $warnMsg -Severity WARN -Component 'SP.AuditReport' `
                    -Action 'Send-SPNotification' -CorrelationID $CorrelationID
            }
        }
        else {
            # Validate attachments
            $validAttachments = @()
            if ($null -ne $Attachments -and $Attachments.Count -gt 0) {
                foreach ($att in $Attachments) {
                    if (Test-Path -Path $att -PathType Leaf) {
                        $validAttachments += $att
                    }
                    else {
                        $attWarn = "Attachment not found, skipping: $att"
                        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                            Write-SPLog -Message $attWarn -Severity WARN -Component 'SP.AuditReport' `
                                -Action 'Send-SPNotification' -CorrelationID $CorrelationID
                        }
                    }
                }
            }

            try {
                $mailParams = @{
                    SmtpServer = $smtpServer
                    Port       = $smtpPort
                    From       = $smtpFrom
                    To         = $Recipients
                    Subject    = $Subject
                    Body       = $Body
                    BodyAsHtml = $true
                    UseSsl     = $smtpUseSsl
                    ErrorAction = 'Stop'
                    WarningAction = 'SilentlyContinue'
                }
                if ($validAttachments.Count -gt 0) {
                    $mailParams['Attachments'] = $validAttachments
                }

                Send-MailMessage @mailParams
                $smtpResult['Status'] = 'Sent'

                if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                    Write-SPLog -Message "SMTP notification sent to $($Recipients -join ', ')" `
                        -Severity INFO -Component 'SP.AuditReport' -Action 'Send-SPNotification' `
                        -CorrelationID $CorrelationID
                }
            }
            catch {
                $smtpResult['Status'] = 'Failed'
                $smtpResult['Error']  = $_.Exception.Message
                if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                    Write-SPLog -Message "SMTP send failed: $($_.Exception.Message)" `
                        -Severity ERROR -Component 'SP.AuditReport' -Action 'Send-SPNotification' `
                        -CorrelationID $CorrelationID
                }
            }
        }

        $backendResults.Add($smtpResult)
    }

    # --- Webhook backend ---
    if ('Webhook' -in $backends) {
        $webhookResult = @{ Backend = 'Webhook'; Status = 'Skipped' }

        $webhookConf = $null
        if ($null -ne $notifConfig -and
            $notifConfig.PSObject.Properties.Name -contains 'Webhook') {
            $webhookConf = $notifConfig.Webhook
        }

        $webhookUrl     = ''
        $webhookMethod  = 'POST'
        $webhookHeaders = @{}
        $includePayload = $true

        if ($null -ne $webhookConf) {
            if ($webhookConf.PSObject.Properties.Name -contains 'Url')            { $webhookUrl     = $webhookConf.Url }
            if ($webhookConf.PSObject.Properties.Name -contains 'Method')         { $webhookMethod  = $webhookConf.Method }
            if ($webhookConf.PSObject.Properties.Name -contains 'IncludePayload') { $includePayload = $webhookConf.IncludePayload -eq $true }
            if ($webhookConf.PSObject.Properties.Name -contains 'Headers' -and
                $null -ne $webhookConf.Headers) {
                # Convert PSCustomObject headers to hashtable
                $webhookHeaders = @{}
                foreach ($prop in $webhookConf.Headers.PSObject.Properties) {
                    $webhookHeaders[$prop.Name] = $prop.Value
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
            $warnMsg = 'Webhook backend configured but Url is empty -- skipping webhook delivery'
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message $warnMsg -Severity WARN -Component 'SP.AuditReport' `
                    -Action 'Send-SPNotification' -CorrelationID $CorrelationID
            }
        }
        else {
            $payload = @{
                timestamp = (Get-Date).ToUniversalTime().ToString('o')
                severity  = $Severity
                subject   = $Subject
            }
            if (-not [string]::IsNullOrWhiteSpace($Category)) {
                $payload['category'] = $Category
            }
            if ($includePayload) {
                $payload['body'] = $Body
            }
            if ($null -ne $Metadata -and $Metadata.Count -gt 0) {
                $payload['metadata'] = $Metadata
            }

            $whResult = Send-SPWebhook -Url $webhookUrl -Payload $payload `
                -Method $webhookMethod -Headers $webhookHeaders -CorrelationID $CorrelationID

            $webhookResult['Status']     = if ($whResult.Success) { 'Sent' } else { 'Failed' }
            $webhookResult['StatusCode'] = $whResult.StatusCode
            if (-not $whResult.Success) {
                $webhookResult['Error'] = $whResult.Error
            }
        }

        $backendResults.Add($webhookResult)
    }

    # Determine overall success -- true if at least one backend sent successfully
    $overallSuccess = ($backendResults | Where-Object { $_.Status -eq 'Sent' }).Count -gt 0

    return @{
        Success = $overallSuccess
        Data    = @{
            Backends = @($backendResults)
        }
    }
}

#endregion

#region Orchestrator Run History

function Get-SPOrchestratorHistory {
    <#
    .SYNOPSIS
        Parses orchestrator-audit.jsonl and produces operational run history metrics.
    .DESCRIPTION
        Reads the JSONL audit trail written by Invoke-SPDailyOrchestrator.ps1 and
        calculates reliability, duration trends, step-level success rates, and
        failure breakdowns for a configurable lookback window.
    .PARAMETER JournalPath
        Path to orchestrator-audit.jsonl. Defaults to {DeltaCert.OutputPath}/orchestrator-audit.jsonl.
    .PARAMETER DaysBack
        Number of days to include. Default 30.
    .PARAMETER CorrelationID
        Optional correlation ID for log tracing.
    .OUTPUTS
        [hashtable] Runs array and Metrics summary.
    .EXAMPLE
        Get-SPOrchestratorHistory -DaysBack 7
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][string]$JournalPath,
        [Parameter()][int]$DaysBack = 30,
        [Parameter()][string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Parsing orchestrator run history (DaysBack=$DaysBack)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPOrchestratorHistory' `
        -CorrelationID $CorrelationID

    # Resolve journal path from config if not provided
    if ([string]::IsNullOrWhiteSpace($JournalPath)) {
        try {
            $cfg = Get-SPConfig
            $dcOutput = $cfg.DeltaCert.OutputPath
            if (-not [string]::IsNullOrWhiteSpace($dcOutput)) {
                $JournalPath = Join-Path $dcOutput 'orchestrator-audit.jsonl'
            }
        }
        catch {
            # Config not available -- fall through to empty return
        }
    }

    # Empty return structure
    $emptyMetrics = @{
        Runs    = @()
        Metrics = @{
            RunCount            = 0
            SuccessRate         = 0.0
            AvgDurationSeconds  = 0
            DurationTrend       = 'N/A'
            FailureBreakdown    = @{}
            ConsecutiveFailures = 0
            LastSuccessfulRun   = $null
            StepReliability     = @{
                Validation  = 0.0
                Cleanup     = 0.0
                DeltaCert   = 0.0
                DeltaReport = 0.0
                Escalation  = 0.0
                HealthCheck = 0.0
            }
        }
    }

    # If no path or file missing, return empty
    if ([string]::IsNullOrWhiteSpace($JournalPath) -or -not (Test-Path $JournalPath)) {
        Write-SPLog -Message "Journal file not found: $JournalPath -- returning empty metrics" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPOrchestratorHistory' `
            -CorrelationID $CorrelationID
        return $emptyMetrics
    }

    # Read and parse JSONL
    $cutoffDate = (Get-Date).AddDays(-$DaysBack).ToUniversalTime()
    $runs = [System.Collections.ArrayList]::new()

    try {
        $lines = [System.IO.File]::ReadAllLines($JournalPath)
    }
    catch {
        Write-SPLog -Message "Failed to read journal: $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.AuditReport' -Action 'Get-SPOrchestratorHistory' `
            -CorrelationID $CorrelationID
        return $emptyMetrics
    }

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try {
            $parsed = $line | ConvertFrom-Json
        }
        catch {
            Write-SPLog -Message "Malformed JSONL line: $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Get-SPOrchestratorHistory' `
                -CorrelationID $CorrelationID
            continue
        }

        # Parse timestamp and apply date filter
        $ts = $null
        if ($null -ne $parsed.Timestamp) {
            try { $ts = [datetime]::Parse([string]$parsed.Timestamp).ToUniversalTime() }
            catch { $ts = $null }
        }
        if ($null -eq $ts) { continue }
        if ($ts -lt $cutoffDate) { continue }

        # Skip WhatIf runs -- they are not real executions
        if ($null -ne $parsed.Data -and $parsed.Data.WhatIf -eq $true) { continue }

        # Extract run data
        $exitCode = 0
        $duration = 0
        $steps = @{}

        if ($null -ne $parsed.Data) {
            if ($null -ne $parsed.Data.ExitCode) { $exitCode = [int]$parsed.Data.ExitCode }
            if ($null -ne $parsed.Data.DurationSeconds) { $duration = [double]$parsed.Data.DurationSeconds }

            if ($null -ne $parsed.Data.Steps) {
                $stepNames = @('Validation','Cleanup','DeltaCert','DeltaReport','Escalation','HealthCheck')
                foreach ($sn in $stepNames) {
                    $stepData = $parsed.Data.Steps.$sn
                    if ($null -ne $stepData) {
                        $steps[$sn] = [string]$stepData.Status + ': ' + [string]$stepData.Detail
                    }
                    else {
                        $steps[$sn] = 'Skipped'
                    }
                }
            }
        }

        # PSCustomObject (not hashtable): later code uses
        # `Measure-Object -Property DurationSeconds`, which requires
        # reflection-accessible properties. Hashtable keys aren't visible
        # through that path and caused AvgDuration to silently be 0.
        $runEntry = [PSCustomObject]@{
            Timestamp       = $ts.ToString('yyyy-MM-ddTHH:mm:ssZ')
            CorrelationID   = if ($null -ne $parsed.CorrelationID) { [string]$parsed.CorrelationID } else { '' }
            ExitCode        = $exitCode
            DurationSeconds = $duration
            Steps           = $steps
        }
        [void]$runs.Add($runEntry)
    }

    # Sort by timestamp descending (most recent first)
    $sortedRuns = @($runs | Sort-Object { $_.Timestamp } -Descending)

    if ($sortedRuns.Count -eq 0) {
        Write-SPLog -Message "No orchestrator runs found within $DaysBack days" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPOrchestratorHistory' `
            -CorrelationID $CorrelationID
        return $emptyMetrics
    }

    # Calculate metrics
    $runCount = $sortedRuns.Count
    $successCount = @($sortedRuns | Where-Object { $_.ExitCode -eq 0 }).Count
    $successRate = [math]::Round(($successCount / $runCount) * 100, 1)

    $totalDuration = ($sortedRuns | Measure-Object -Property DurationSeconds -Sum).Sum
    $avgDuration = [math]::Round($totalDuration / $runCount, 0)

    # Duration trend: compare first half avg vs second half avg
    $durationTrend = 'Stable'
    if ($sortedRuns.Count -ge 4) {
        $halfPoint = [math]::Floor($sortedRuns.Count / 2)
        $recentHalf = $sortedRuns[0..($halfPoint - 1)]
        $olderHalf = $sortedRuns[$halfPoint..($sortedRuns.Count - 1)]
        $recentAvg = ($recentHalf | Measure-Object -Property DurationSeconds -Average).Average
        $olderAvg = ($olderHalf | Measure-Object -Property DurationSeconds -Average).Average
        if ($olderAvg -gt 0) {
            $changePct = (($recentAvg - $olderAvg) / $olderAvg) * 100
            if ($changePct -gt 15) { $durationTrend = 'Increasing' }
            elseif ($changePct -lt -15) { $durationTrend = 'Decreasing' }
        }
    }

    # Failure breakdown by exit code
    $failureBreakdown = @{}
    $failedRuns = @($sortedRuns | Where-Object { $_.ExitCode -ne 0 })
    foreach ($fr in $failedRuns) {
        $key = "ExitCode$($fr.ExitCode)"
        if ($failureBreakdown.ContainsKey($key)) { $failureBreakdown[$key]++ }
        else { $failureBreakdown[$key] = 1 }
    }

    # Consecutive failures from most recent
    $consecutiveFailures = 0
    foreach ($r in $sortedRuns) {
        if ($r.ExitCode -ne 0) { $consecutiveFailures++ }
        else { break }
    }

    # Last successful run
    $lastSuccess = $sortedRuns | Where-Object { $_.ExitCode -eq 0 } | Select-Object -First 1
    $lastSuccessfulRun = if ($null -ne $lastSuccess) { $lastSuccess.Timestamp } else { $null }

    # Step reliability: per-step success rate
    $stepNames = @('Validation','Cleanup','DeltaCert','DeltaReport','Escalation','HealthCheck')
    $stepReliability = @{}
    foreach ($sn in $stepNames) {
        $totalWithStep = 0
        $successWithStep = 0
        foreach ($r in $sortedRuns) {
            if ($r.Steps.ContainsKey($sn)) {
                $stepVal = $r.Steps[$sn]
                if ($stepVal -ne 'Skipped') {
                    $totalWithStep++
                    if ($stepVal -like 'Success*') {
                        $successWithStep++
                    }
                }
            }
        }
        if ($totalWithStep -gt 0) {
            $stepReliability[$sn] = [math]::Round(($successWithStep / $totalWithStep) * 100, 1)
        }
        else {
            $stepReliability[$sn] = 0.0
        }
    }

    Write-SPLog -Message "Parsed $runCount runs: SuccessRate=$successRate% AvgDuration=${avgDuration}s" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPOrchestratorHistory' `
        -CorrelationID $CorrelationID

    return @{
        Runs    = $sortedRuns
        Metrics = @{
            RunCount            = $runCount
            SuccessRate         = $successRate
            AvgDurationSeconds  = $avgDuration
            DurationTrend       = $durationTrend
            FailureBreakdown    = $failureBreakdown
            ConsecutiveFailures = $consecutiveFailures
            LastSuccessfulRun   = $lastSuccessfulRun
            StepReliability     = $stepReliability
        }
    }
}

#endregion

#region Log Retention and Archival

function Invoke-SPLogRetention {
    <#
    .SYNOPSIS
        Enforces retention policies on toolkit output directories.
    .DESCRIPTION
        Archives old files to monthly ZIP archives and deletes files past their
        retention period. Only processes known toolkit-generated file extensions.
        Requires Retention.Enabled = true in config (opt-in safety default).
    .PARAMETER ArchiveDays
        Files older than this many days are archived. Minimum 7.
    .PARAMETER DeleteDays
        Archive ZIPs older than this many days are deleted. Minimum 30. Must be > ArchiveDays.
    .PARAMETER ArchivePath
        Directory for archive ZIPs. Created if it does not exist.
    .PARAMETER Paths
        Array of directory names (relative to toolkit root) to process.
    .PARAMETER WhatIf
        Lists all actions without performing them.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] Result with Archived, Deleted, and Skipped counts.
    .EXAMPLE
        Invoke-SPLogRetention -WhatIf
    .EXAMPLE
        Invoke-SPLogRetention -ArchiveDays 30 -DeleteDays 90
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][int]$ArchiveDays,
        [Parameter()][int]$DeleteDays,
        [Parameter()][string]$ArchivePath,
        [Parameter()][string[]]$Paths,
        [Parameter()][switch]$WhatIf,
        [Parameter()][string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.AuditReport'
    $action    = 'Invoke-SPLogRetention'

    Write-SPLog -Message 'Invoke-SPLogRetention: starting' `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    # Load config for defaults
    $retentionEnabled = $false
    $toolkitRoot = $null
    try {
        $config = Get-SPConfig
        if ($null -ne $config -and $config.PSObject.Properties.Name -contains 'Retention') {
            $retCfg = $config.Retention
            $retentionEnabled = if ($retCfg.PSObject.Properties.Name -contains 'Enabled') { $retCfg.Enabled } else { $false }
            if ($ArchiveDays -le 0 -and $retCfg.PSObject.Properties.Name -contains 'ArchiveDays') {
                $ArchiveDays = $retCfg.ArchiveDays
            }
            if ($DeleteDays -le 0 -and $retCfg.PSObject.Properties.Name -contains 'DeleteDays') {
                $DeleteDays = $retCfg.DeleteDays
            }
            if ([string]::IsNullOrWhiteSpace($ArchivePath) -and $retCfg.PSObject.Properties.Name -contains 'ArchivePath') {
                $ArchivePath = $retCfg.ArchivePath
            }
            if (($null -eq $Paths -or $Paths.Count -eq 0) -and $retCfg.PSObject.Properties.Name -contains 'Paths') {
                $Paths = @($retCfg.Paths)
            }
        }
    }
    catch {
        Write-SPLog -Message "Could not load config: $($_.Exception.Message)" `
            -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
    }

    # Resolve toolkit root from module location
    try {
        $toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..' ))
    }
    catch {
        $toolkitRoot = (Get-Location).Path
    }

    # Apply defaults if still unset
    if ($ArchiveDays -le 0) { $ArchiveDays = 30 }
    if ($DeleteDays  -le 0) { $DeleteDays  = 90 }
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath = '.\Archive' }
    if ($null -eq $Paths -or $Paths.Count -eq 0)    { $Paths = @('Audit', 'DeltaCert', 'Logs') }

    # Check Retention.Enabled (unless parameters were provided explicitly, which implies intent)
    if (-not $retentionEnabled -and -not $PSBoundParameters.ContainsKey('ArchiveDays') -and
        -not $PSBoundParameters.ContainsKey('DeleteDays')) {
        Write-SPLog -Message 'Retention.Enabled is false. No action taken. Set Retention.Enabled = true in config or pass explicit parameters.' `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
        return @{
            Success = $true
            Data    = @{
                Archived = @{ FileCount = 0; TotalBytes = 0; Archives = @() }
                Deleted  = @{ FileCount = 0; TotalBytes = 0; Files = @() }
                Skipped  = @{ FileCount = 0; Reasons = @() }
            }
        }
    }

    # Validate constraints
    if ($ArchiveDays -lt 7) {
        Write-SPLog -Message "ArchiveDays ($ArchiveDays) is less than minimum 7. Aborting." `
            -Severity ERROR -Component $component -Action $action -CorrelationID $CorrelationID
        return @{
            Success = $false
            Data    = @{ Error = "ArchiveDays must be at least 7 (got $ArchiveDays)" }
        }
    }
    if ($DeleteDays -lt 30) {
        Write-SPLog -Message "DeleteDays ($DeleteDays) is less than minimum 30. Aborting." `
            -Severity ERROR -Component $component -Action $action -CorrelationID $CorrelationID
        return @{
            Success = $false
            Data    = @{ Error = "DeleteDays must be at least 30 (got $DeleteDays)" }
        }
    }
    if ($DeleteDays -le $ArchiveDays) {
        Write-SPLog -Message "DeleteDays ($DeleteDays) must be greater than ArchiveDays ($ArchiveDays). Aborting." `
            -Severity ERROR -Component $component -Action $action -CorrelationID $CorrelationID
        return @{
            Success = $false
            Data    = @{ Error = "DeleteDays ($DeleteDays) must be greater than ArchiveDays ($ArchiveDays)" }
        }
    }

    # Resolve archive path
    if (-not [System.IO.Path]::IsPathRooted($ArchivePath)) {
        $ArchivePath = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $ArchivePath))
    }

    # Known safe extensions
    $safeExtensions = @('.html', '.csv', '.jsonl', '.txt', '.log', '.json')

    $now           = Get-Date
    $archiveCutoff = $now.AddDays(-$ArchiveDays)
    $deleteCutoff  = $now.AddDays(-$DeleteDays)

    # Result accumulators
    $archivedCount    = 0
    $archivedBytes    = 0
    $archiveFiles     = [System.Collections.Generic.List[string]]::new()
    $deletedCount     = 0
    $deletedBytes     = 0
    $deletedFiles     = [System.Collections.Generic.List[string]]::new()
    $skippedCount     = 0
    $skippedReasons   = [System.Collections.Generic.List[string]]::new()

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    # Phase 1: Archive files older than ArchiveDays but younger than DeleteDays
    foreach ($relPath in $Paths) {
        $dirPath = $relPath
        if (-not [System.IO.Path]::IsPathRooted($dirPath)) {
            $dirPath = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $dirPath))
        }
        if (-not (Test-Path -Path $dirPath -PathType Container)) {
            Write-SPLog -Message "Path not found, skipping: $dirPath" `
                -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
            continue
        }

        # Get files eligible for archival (older than archiveCutoff)
        $files = Get-ChildItem -Path $dirPath -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $archiveCutoff }

        if ($null -eq $files -or @($files).Count -eq 0) { continue }

        # Group by month for monthly archives
        $monthGroups = @($files) | Group-Object { $_.LastWriteTime.ToString('yyyy-MM') }
        $dirName = Split-Path -Path $dirPath -Leaf

        foreach ($group in $monthGroups) {
            $monthLabel  = $group.Name
            $zipName     = "${dirName}-${monthLabel}.zip"
            $zipFullPath = Join-Path -Path $ArchivePath -ChildPath $zipName

            $filesToArchive = @($group.Group | Where-Object {
                $_.Extension -in $safeExtensions
            })

            $skippedInGroup = @($group.Group | Where-Object {
                $_.Extension -notin $safeExtensions
            })
            foreach ($sf in $skippedInGroup) {
                $skippedCount++
                $skippedReasons.Add("Unknown extension: $($sf.Extension) ($($sf.Name))")
            }

            if ($filesToArchive.Count -eq 0) { continue }

            if ($WhatIf) {
                Write-SPLog -Message "WhatIf: Would archive $($filesToArchive.Count) file(s) to $zipName" `
                    -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
                foreach ($f in $filesToArchive) {
                    $archivedCount++
                    $archivedBytes += $f.Length
                }
                if ($zipFullPath -notin $archiveFiles) {
                    $archiveFiles.Add($zipFullPath)
                }
                continue
            }

            # Ensure archive directory exists
            if (-not (Test-Path -Path $ArchivePath -PathType Container)) {
                New-Item -Path $ArchivePath -ItemType Directory -Force | Out-Null
            }

            # Create or open the archive ZIP
            try {
                $zipMode = if (Test-Path -Path $zipFullPath) {
                    [System.IO.Compression.ZipArchiveMode]::Update
                } else {
                    [System.IO.Compression.ZipArchiveMode]::Create
                }
                $zipStream  = [System.IO.File]::Open($zipFullPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite)
                $zipArchive = [System.IO.Compression.ZipArchive]::new($zipStream, $zipMode)

                foreach ($f in $filesToArchive) {
                    try {
                        # Check if entry already exists (for Update mode)
                        $entryName = $f.Name
                        $existing  = $zipArchive.GetEntry($entryName)
                        if ($null -ne $existing) {
                            $entryName = "$($f.BaseName)_$(Get-Date -Format 'yyyyMMddHHmmss')$($f.Extension)"
                        }

                        $entry       = $zipArchive.CreateEntry($entryName)
                        $entryStream = $entry.Open()
                        try {
                            $fileBytes = [System.IO.File]::ReadAllBytes($f.FullName)
                            $entryStream.Write($fileBytes, 0, $fileBytes.Length)
                        } finally {
                            $entryStream.Close()
                        }

                        # Remove the source file after successful archive
                        try {
                            Remove-Item -Path $f.FullName -Force -ErrorAction Stop
                        }
                        catch {
                            $skippedCount++
                            $skippedReasons.Add("File locked: $($f.Name)")
                            continue
                        }

                        $archivedCount++
                        $archivedBytes += $f.Length
                    }
                    catch {
                        $skippedCount++
                        $skippedReasons.Add("Archive error: $($f.Name) - $($_.Exception.Message)")
                    }
                }

                $zipArchive.Dispose()
                $zipStream.Close()

                if ($zipFullPath -notin $archiveFiles) {
                    $archiveFiles.Add($zipFullPath)
                }

                Write-SPLog -Message "Archived $($filesToArchive.Count) file(s) to $zipName" `
                    -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
            }
            catch {
                Write-SPLog -Message "Failed to create archive $zipName : $($_.Exception.Message)" `
                    -Severity ERROR -Component $component -Action $action -CorrelationID $CorrelationID
                foreach ($f in $filesToArchive) {
                    $skippedCount++
                    $skippedReasons.Add("Archive creation failed: $($f.Name)")
                }
            }
        }
    }

    # Phase 2: Delete expired archives older than DeleteDays
    if (Test-Path -Path $ArchivePath -PathType Container) {
        $oldArchives = Get-ChildItem -Path $ArchivePath -File -Filter '*.zip' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $deleteCutoff }

        foreach ($arc in $oldArchives) {
            if ($WhatIf) {
                Write-SPLog -Message "WhatIf: Would delete expired archive $($arc.Name)" `
                    -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
                $deletedCount++
                $deletedBytes += $arc.Length
                $deletedFiles.Add($arc.FullName)
                continue
            }

            try {
                $arcSize = $arc.Length
                Remove-Item -Path $arc.FullName -Force -ErrorAction Stop
                $deletedCount++
                $deletedBytes += $arcSize
                $deletedFiles.Add($arc.FullName)
                Write-SPLog -Message "Deleted expired archive: $($arc.Name)" `
                    -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
            }
            catch {
                $skippedCount++
                $skippedReasons.Add("File locked: $($arc.Name)")
                Write-SPLog -Message "Could not delete archive $($arc.Name): $($_.Exception.Message)" `
                    -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
            }
        }
    }

    $whatIfLabel = if ($WhatIf) { ' (WhatIf)' } else { '' }
    Write-SPLog -Message "Invoke-SPLogRetention complete${whatIfLabel}: archived=$archivedCount, deleted=$deletedCount, skipped=$skippedCount" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            Archived = @{
                FileCount  = $archivedCount
                TotalBytes = $archivedBytes
                Archives   = @($archiveFiles)
            }
            Deleted = @{
                FileCount  = $deletedCount
                TotalBytes = $deletedBytes
                Files      = @($deletedFiles)
            }
            Skipped = @{
                FileCount = $skippedCount
                Reasons   = @($skippedReasons)
            }
        }
    }
}

#endregion

#region Governance Metrics Time Series

function Save-SPGovernanceMetrics {
    <#
    .SYNOPSIS
        Persists governance KPIs to a local JSONL time-series file.
    .DESCRIPTION
        Extracts key metrics from analytics outputs (identity risk, source governance,
        campaign metrics, reviewer reputation, stale access, governance maturity,
        orchestrator history) and appends a timestamped record to a JSONL file for
        historical trend analysis. Applies retention to remove records older than
        the configured RetentionDays.

        The JSONL file uses BOM-free UTF-8 encoding, matching the convention used
        by Export-SPAuditJsonl.
    .PARAMETER IdentityRisk
        Output from Measure-SPIdentityRisk.
    .PARAMETER SourceGovernance
        Output from Measure-SPSourceGovernance.
    .PARAMETER CampaignMetrics
        Output from Measure-SPCampaignMetrics.
    .PARAMETER ReviewerReputation
        Output from Measure-SPReviewerReputation.
    .PARAMETER StaleAccess
        Output from Get-SPStaleAccess.
    .PARAMETER GovernanceMaturity
        Output from Measure-SPGovernanceMaturity.
    .PARAMETER OrchestratorHistory
        Output from Get-SPOrchestratorHistory.
    .PARAMETER Label
        Optional label for the metrics record (e.g. 'weekly-digest-2026-05-30').
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Timestamp; MetricCount; FilePath } }
    .EXAMPLE
        Save-SPGovernanceMetrics -IdentityRisk $risk -GovernanceMaturity $maturity `
            -Label 'daily-2026-05-30'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][hashtable]$IdentityRisk,
        [Parameter()][hashtable]$SourceGovernance,
        [Parameter()][hashtable]$CampaignMetrics,
        [Parameter()][hashtable]$ReviewerReputation,
        [Parameter()][hashtable]$StaleAccess,
        [Parameter()][hashtable]$GovernanceMaturity,
        [Parameter()][hashtable]$OrchestratorHistory,
        [Parameter()][string]$Label,
        [Parameter()][string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.AuditReport'
    $action    = 'Save-SPGovernanceMetrics'

    Write-SPLog -Message 'Save-SPGovernanceMetrics: starting' `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    # Resolve metrics path and retention from config
    $metricsPath   = '.\Audit\metrics'
    $retentionDays = 365
    try {
        $config = Get-SPConfig
        if ($null -ne $config -and $config.PSObject.Properties.Name -contains 'Metrics') {
            $metricsCfg = $config.Metrics
            if ($metricsCfg.PSObject.Properties.Name -contains 'Path' -and
                -not [string]::IsNullOrWhiteSpace($metricsCfg.Path)) {
                $metricsPath = $metricsCfg.Path
            }
            if ($metricsCfg.PSObject.Properties.Name -contains 'RetentionDays' -and
                $null -ne $metricsCfg.RetentionDays) {
                $retentionDays = [int]$metricsCfg.RetentionDays
            }
        }
    }
    catch {
        Write-SPLog -Message "Could not load Metrics config, using defaults: $($_.Exception.Message)" `
            -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
    }

    # Ensure metrics directory exists
    if (-not (Test-Path -Path $metricsPath -PathType Container)) {
        New-Item -Path $metricsPath -ItemType Directory -Force | Out-Null
    }

    $filePath = Join-Path -Path $metricsPath -ChildPath 'governance-metrics.jsonl'
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # Extract KPIs from each analytics output
    $metrics = [ordered]@{}

    # Identity Risk
    if ($null -ne $IdentityRisk) {
        $irSummary = $null
        if ($IdentityRisk.ContainsKey('Summary')) { $irSummary = $IdentityRisk['Summary'] }
        if ($null -ne $irSummary) {
            $metrics['identityRisk.highCount'] = if ($irSummary.ContainsKey('HighRiskCount')) { $irSummary['HighRiskCount'] } else { $null }
            $metrics['identityRisk.avgScore']  = if ($irSummary.ContainsKey('AvgRiskScore'))  { $irSummary['AvgRiskScore'] }  else { $null }
        } else {
            $metrics['identityRisk.highCount'] = $null
            $metrics['identityRisk.avgScore']  = $null
        }
    } else {
        $metrics['identityRisk.highCount'] = $null
        $metrics['identityRisk.avgScore']  = $null
    }

    # Source Governance
    if ($null -ne $SourceGovernance) {
        $sgSummary = $null
        if ($SourceGovernance.ContainsKey('Summary')) { $sgSummary = $SourceGovernance['Summary'] }
        if ($null -ne $sgSummary) {
            $metrics['sourceGovernance.coveragePct'] = if ($sgSummary.ContainsKey('OverallCoveragePct')) { $sgSummary['OverallCoveragePct'] } else { $null }
            $metrics['sourceGovernance.avgScore']    = if ($sgSummary.ContainsKey('AvgGovernanceScore')) { $sgSummary['AvgGovernanceScore'] } else { $null }
        } else {
            $metrics['sourceGovernance.coveragePct'] = $null
            $metrics['sourceGovernance.avgScore']    = $null
        }
    } else {
        $metrics['sourceGovernance.coveragePct'] = $null
        $metrics['sourceGovernance.avgScore']    = $null
    }

    # Campaign Metrics
    if ($null -ne $CampaignMetrics) {
        $cmSummary = $null
        if ($CampaignMetrics.ContainsKey('Summary')) { $cmSummary = $CampaignMetrics['Summary'] }
        if ($null -ne $cmSummary) {
            $metrics['campaigns.total']            = if ($cmSummary.ContainsKey('TotalCampaigns'))   { $cmSummary['TotalCampaigns'] }   else { $null }
            $metrics['campaigns.avgApprovalRate']   = if ($cmSummary.ContainsKey('AvgApprovalRate'))  { $cmSummary['AvgApprovalRate'] }  else { $null }
            $metrics['campaigns.avgResponseHours']  = if ($cmSummary.ContainsKey('AvgResponseHours')) { $cmSummary['AvgResponseHours'] } else { $null }
        } else {
            $metrics['campaigns.total']            = $null
            $metrics['campaigns.avgApprovalRate']   = $null
            $metrics['campaigns.avgResponseHours']  = $null
        }
    } else {
        $metrics['campaigns.total']            = $null
        $metrics['campaigns.avgApprovalRate']   = $null
        $metrics['campaigns.avgResponseHours']  = $null
    }

    # Reviewer Reputation
    if ($null -ne $ReviewerReputation) {
        $rrSummary = $null
        if ($ReviewerReputation.ContainsKey('Summary')) { $rrSummary = $ReviewerReputation['Summary'] }
        if ($null -ne $rrSummary) {
            $metrics['reviewers.avgScore']    = if ($rrSummary.ContainsKey('AvgReputationScore')) { $rrSummary['AvgReputationScore'] } else { $null }
            $metrics['reviewers.atRiskCount'] = if ($rrSummary.ContainsKey('AtRiskCount'))        { $rrSummary['AtRiskCount'] }        else { $null }
        } else {
            $metrics['reviewers.avgScore']    = $null
            $metrics['reviewers.atRiskCount'] = $null
        }
    } else {
        $metrics['reviewers.avgScore']    = $null
        $metrics['reviewers.atRiskCount'] = $null
    }

    # Stale Access
    if ($null -ne $StaleAccess) {
        $saSummary = $null
        if ($StaleAccess.ContainsKey('Summary')) { $saSummary = $StaleAccess['Summary'] }
        if ($null -ne $saSummary) {
            $metrics['staleAccess.totalItems']    = if ($saSummary.ContainsKey('TotalStaleItems'))    { $saSummary['TotalStaleItems'] }    else { $null }
            $metrics['staleAccess.neverReviewed']  = if ($saSummary.ContainsKey('NeverReviewedCount')) { $saSummary['NeverReviewedCount'] } else { $null }
        } else {
            $metrics['staleAccess.totalItems']    = $null
            $metrics['staleAccess.neverReviewed']  = $null
        }
    } else {
        $metrics['staleAccess.totalItems']    = $null
        $metrics['staleAccess.neverReviewed']  = $null
    }

    # Governance Maturity
    if ($null -ne $GovernanceMaturity) {
        $gmData = $null
        if ($GovernanceMaturity.ContainsKey('Data')) { $gmData = $GovernanceMaturity['Data'] }
        if ($null -ne $gmData) {
            $metrics['maturity.overallScore'] = if ($gmData.ContainsKey('OverallScore')) { $gmData['OverallScore'] } else { $null }
            $metrics['maturity.overallLevel'] = if ($gmData.ContainsKey('OverallLevel')) { $gmData['OverallLevel'] } else { $null }
        } else {
            $metrics['maturity.overallScore'] = $null
            $metrics['maturity.overallLevel'] = $null
        }
    } else {
        $metrics['maturity.overallScore'] = $null
        $metrics['maturity.overallLevel'] = $null
    }

    # Orchestrator History
    if ($null -ne $OrchestratorHistory) {
        $ohMetrics = $null
        if ($OrchestratorHistory.ContainsKey('Metrics')) { $ohMetrics = $OrchestratorHistory['Metrics'] }
        if ($null -ne $ohMetrics) {
            $metrics['orchestrator.successRate'] = if ($ohMetrics.ContainsKey('SuccessRate')) { $ohMetrics['SuccessRate'] } else { $null }
        } else {
            $metrics['orchestrator.successRate'] = $null
        }
    } else {
        $metrics['orchestrator.successRate'] = $null
    }

    # Build the record
    $record = [ordered]@{
        timestamp = $timestamp
        label     = if ([string]::IsNullOrWhiteSpace($Label)) { $null } else { $Label }
        metrics   = $metrics
    }

    $metricCount = 0
    foreach ($v in $metrics.Values) {
        if ($null -ne $v) { $metricCount++ }
    }

    # Write to temp file then rename for atomic append
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $jsonLine  = $record | ConvertTo-Json -Depth 5 -Compress

    $tmpPath = "${filePath}.tmp"
    try {
        # If the file already exists, copy it to tmp; otherwise start fresh
        if (Test-Path -Path $filePath) {
            Copy-Item -Path $filePath -Destination $tmpPath -Force
        } else {
            # Create empty tmp file
            [System.IO.File]::WriteAllText($tmpPath, '', $utf8NoBom)
        }

        # Append the new record
        [System.IO.File]::AppendAllText($tmpPath, "$jsonLine`n", $utf8NoBom)

        # Apply retention: remove lines older than RetentionDays
        $retentionCutoff = (Get-Date).AddDays(-$retentionDays).ToUniversalTime()
        $lines = [System.IO.File]::ReadAllLines($tmpPath, $utf8NoBom)
        $keptLines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $parsed = $line | ConvertFrom-Json
                $lineTs = $null
                if ($null -ne $parsed.timestamp) {
                    $lineTs = [datetime]::Parse([string]$parsed.timestamp).ToUniversalTime()
                }
                if ($null -ne $lineTs -and $lineTs -lt $retentionCutoff) {
                    continue
                }
            }
            catch {
                # Keep unparseable lines to avoid data loss
            }
            $keptLines.Add($line)
        }

        # Write retained lines back
        $content = ($keptLines -join "`n")
        if ($keptLines.Count -gt 0) { $content += "`n" }
        [System.IO.File]::WriteAllText($tmpPath, $content, $utf8NoBom)

        # Atomic rename
        if (Test-Path -Path $filePath) {
            Remove-Item -Path $filePath -Force
        }
        Move-Item -Path $tmpPath -Destination $filePath -Force
    }
    catch {
        # Clean up tmp on failure
        if (Test-Path -Path $tmpPath) {
            Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
        }
        $errMsg = "Failed to save governance metrics: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{
            Success = $false
            Data    = @{ Error = $errMsg }
        }
    }

    Write-SPLog -Message "Save-SPGovernanceMetrics: saved $metricCount metrics to $filePath" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            Timestamp   = $timestamp
            MetricCount = $metricCount
            FilePath    = $filePath
        }
    }
}

function Get-SPGovernanceMetrics {
    <#
    .SYNOPSIS
        Reads governance metrics from the JSONL time-series file.
    .DESCRIPTION
        Reads the governance-metrics.jsonl file and returns records within the
        specified DaysBack window, sorted by timestamp ascending.
    .PARAMETER DaysBack
        Number of days to include. Default 90.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable[]] Array of metric records sorted by timestamp ascending.
    .EXAMPLE
        $metrics = Get-SPGovernanceMetrics -DaysBack 30
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter()][int]$DaysBack = 90,
        [Parameter()][string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.AuditReport'
    $action    = 'Get-SPGovernanceMetrics'

    # Resolve metrics path from config
    $metricsPath = '.\Audit\metrics'
    try {
        $config = Get-SPConfig
        if ($null -ne $config -and $config.PSObject.Properties.Name -contains 'Metrics') {
            $metricsCfg = $config.Metrics
            if ($metricsCfg.PSObject.Properties.Name -contains 'Path' -and
                -not [string]::IsNullOrWhiteSpace($metricsCfg.Path)) {
                $metricsPath = $metricsCfg.Path
            }
        }
    }
    catch { }

    $filePath = Join-Path -Path $metricsPath -ChildPath 'governance-metrics.jsonl'

    if (-not (Test-Path -Path $filePath)) {
        Write-SPLog -Message "Metrics file not found: $filePath -- returning empty" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
        return @()
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $cutoff = (Get-Date).AddDays(-$DaysBack).ToUniversalTime()
    $records = [System.Collections.Generic.List[hashtable]]::new()

    try {
        $lines = [System.IO.File]::ReadAllLines($filePath, $utf8NoBom)
    }
    catch {
        Write-SPLog -Message "Failed to read metrics file: $($_.Exception.Message)" `
            -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
        return @()
    }

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $parsed = $line | ConvertFrom-Json
            $ts = $null
            if ($null -ne $parsed.timestamp) {
                $ts = [datetime]::Parse([string]$parsed.timestamp).ToUniversalTime()
            }
            if ($null -eq $ts) { continue }
            if ($ts -lt $cutoff) { continue }

            # Convert metrics PSCustomObject to hashtable
            $metricsHt = [ordered]@{}
            if ($null -ne $parsed.metrics) {
                foreach ($prop in $parsed.metrics.PSObject.Properties) {
                    $metricsHt[$prop.Name] = $prop.Value
                }
            }

            $records.Add(@{
                timestamp = [string]$parsed.timestamp
                label     = if ($null -ne $parsed.label) { [string]$parsed.label } else { $null }
                metrics   = $metricsHt
            })
        }
        catch {
            continue
        }
    }

    # Sort ascending by timestamp
    $sorted = @($records | Sort-Object { $_.timestamp })

    Write-SPLog -Message "Get-SPGovernanceMetrics: returning $($sorted.Count) records (DaysBack=$DaysBack)" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    return $sorted
}

function Get-SPGovernanceMetricsTrend {
    <#
    .SYNOPSIS
        Computes trend analysis from governance metrics time series.
    .DESCRIPTION
        Reads metrics within DaysBack, groups by Granularity (Daily/Weekly/Monthly),
        and for each metric computes min, max, avg, latest per period plus
        period-over-period change and overall direction.
    .PARAMETER DaysBack
        Number of days to include. Default 180.
    .PARAMETER MetricNames
        Filter to specific metric names. Default: all metrics.
    .PARAMETER Granularity
        Grouping period: Daily, Weekly, or Monthly. Default Weekly.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Trends; Summary }
    .EXAMPLE
        $trend = Get-SPGovernanceMetricsTrend -DaysBack 180 -Granularity Weekly
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][int]$DaysBack = 180,
        [Parameter()][string[]]$MetricNames,
        [Parameter()][ValidateSet('Daily','Weekly','Monthly')]
        [string]$Granularity = 'Weekly',
        [Parameter()][string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.AuditReport'
    $action    = 'Get-SPGovernanceMetricsTrend'

    Write-SPLog -Message "Get-SPGovernanceMetricsTrend: DaysBack=$DaysBack Granularity=$Granularity" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    # Get raw metrics
    $records = Get-SPGovernanceMetrics -DaysBack $DaysBack -CorrelationID $CorrelationID

    $emptyResult = @{
        Trends  = @{}
        Summary = @{
            MetricsTracked   = 0
            DataPointCount   = 0
            OldestRecord     = $null
            NewestRecord     = $null
            ImprovingMetrics = 0
            DecliningMetrics = 0
            StableMetrics    = 0
        }
    }

    if ($null -eq $records -or @($records).Count -eq 0) {
        Write-SPLog -Message 'No metrics data available for trend analysis' `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
        return $emptyResult
    }

    $records = @($records)

    # Collect all metric names from data
    $allMetricNames = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($rec in $records) {
        if ($null -ne $rec.metrics) {
            foreach ($key in $rec.metrics.Keys) {
                [void]$allMetricNames.Add($key)
            }
        }
    }

    # Filter to requested metric names
    if ($null -ne $MetricNames -and $MetricNames.Count -gt 0) {
        $filtered = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($mn in $MetricNames) {
            if ($allMetricNames.Contains($mn)) {
                [void]$filtered.Add($mn)
            }
        }
        $allMetricNames = $filtered
    }

    if ($allMetricNames.Count -eq 0) {
        return $emptyResult
    }

    # Helper: get period key for a timestamp
    function _GetPeriodKey {
        param([datetime]$Dt, [string]$Gran)
        switch ($Gran) {
            'Daily'   { return $Dt.ToString('yyyy-MM-dd') }
            'Weekly'  {
                $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
                $weekNum = $cal.GetWeekOfYear($Dt, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek,
                    [System.DayOfWeek]::Monday)
                return "$($Dt.ToString('yyyy'))-W$($weekNum.ToString('D2'))"
            }
            'Monthly' { return $Dt.ToString('yyyy-MM') }
        }
    }

    # Build per-metric period buckets
    $trends = @{}
    foreach ($metricName in $allMetricNames) {
        $periodBuckets = [ordered]@{}

        foreach ($rec in $records) {
            $ts = [datetime]::Parse($rec.timestamp).ToUniversalTime()
            $periodKey = _GetPeriodKey -Dt $ts -Gran $Granularity

            $value = $null
            if ($null -ne $rec.metrics -and $rec.metrics.ContainsKey($metricName)) {
                $value = $rec.metrics[$metricName]
            }
            if ($null -eq $value) { continue }

            $numVal = 0
            try { $numVal = [double]$value } catch { continue }

            if (-not $periodBuckets.Contains($periodKey)) {
                $periodBuckets[$periodKey] = [System.Collections.Generic.List[double]]::new()
            }
            $periodBuckets[$periodKey].Add($numVal)
        }

        if ($periodBuckets.Count -eq 0) { continue }

        $periods = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($pk in $periodBuckets.Keys) {
            $vals = $periodBuckets[$pk]
            $min  = ($vals | Measure-Object -Minimum).Minimum
            $max  = ($vals | Measure-Object -Maximum).Maximum
            $avg  = [math]::Round(($vals | Measure-Object -Average).Average, 1)
            $latest = $vals[$vals.Count - 1]

            $periods.Add(@{
                Period = $pk
                Min    = $min
                Max    = $max
                Avg    = $avg
                Latest = $latest
            })
        }

        # Calculate overall direction from first to last period
        $firstPeriodAvg = $periods[0].Avg
        $lastPeriodAvg  = $periods[$periods.Count - 1].Avg
        $totalChange    = [math]::Round($lastPeriodAvg - $firstPeriodAvg, 1)
        $changePct      = 0.0
        if ($firstPeriodAvg -ne 0) {
            $changePct = [math]::Round(($totalChange / [math]::Abs($firstPeriodAvg)) * 100, 1)
        }

        $direction = 'Stable'
        if ($changePct -gt 2)  { $direction = 'Improving' }
        if ($changePct -lt -2) { $direction = 'Declining' }

        $trends[$metricName] = @{
            Periods          = @($periods)
            OverallDirection = $direction
            TotalChange      = $totalChange
            ChangePercent    = $changePct
        }
    }

    # Build summary
    $improving = 0
    $declining = 0
    $stable    = 0
    foreach ($t in $trends.Values) {
        switch ($t.OverallDirection) {
            'Improving' { $improving++ }
            'Declining' { $declining++ }
            'Stable'    { $stable++ }
        }
    }

    $oldestRec = $records[0].timestamp
    $newestRec = $records[$records.Count - 1].timestamp

    $totalDataPoints = 0
    foreach ($rec in $records) { $totalDataPoints++ }

    Write-SPLog -Message "Get-SPGovernanceMetricsTrend: $($trends.Count) metrics tracked, $totalDataPoints data points" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    return @{
        Trends  = $trends
        Summary = @{
            MetricsTracked   = $trends.Count
            DataPointCount   = $totalDataPoints
            OldestRecord     = $oldestRec
            NewestRecord     = $newestRec
            ImprovingMetrics = $improving
            DecliningMetrics = $declining
            StableMetrics    = $stable
        }
    }
}

#endregion

#region Governance Dashboard Data Export (P13-08 / DF-02)

function Export-SPGovernanceDashboardData {
    <#
    .SYNOPSIS
        Exports a unified, analytics-enriched dataset for BI/SIEM consumption.
    .DESCRIPTION
        Produces a flat denormalized dataset combining campaign audit decisions with
        cross-domain analytics: identity risk scores, source governance grades, policy
        compliance status, and reviewer reputation. Each row represents one
        campaign-identity-entitlement combination, enriched with all available
        governance signals.

        Designed for Power BI, Tableau, Splunk, or any system that consumes flat
        CSV/JSON feeds. Outputs CSV, JSON, or both.

        Column set (50+ columns):
        - Campaign: Id, Name, Type, Status, Created, Deadline, Completed,
          TotalItems, CompletionPct, ApprovalRate, RevocationRate, AvgResponseHours
        - Decision: IdentityName, IdentityId, AccountName, SourceName,
          EntitlementName, AccessType, Decision, DecisionDate, Justification
        - Identity Risk: RiskScore, RiskTier, StaleAccessCount,
          PrivilegedAccessCount, TopRiskFactors
        - Source Governance: GovernanceGrade, GovernanceScore
        - Policy: OverallCompliant, PassedPolicies, FailedPolicies
        - Reviewer: ReviewerName, ReputationScore, ReputationTier
        - Metadata: ExportTimestamp

        Uses Export-Csv -NoTypeInformation for PS 5.1 compatibility.
        JSON uses BOM-free UTF-8 encoding. Date columns are ISO 8601.
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables as produced by the campaign audit pipeline.
        Each must contain: CampaignName, Decisions.
    .PARAMETER CampaignMetrics
        Optional hashtable from Measure-SPCampaignMetrics. When provided, each row
        is enriched with campaign-level KPIs (approval rate, response time).
    .PARAMETER PolicyResults
        Optional hashtable from Test-SPGovernancePolicy. When provided, each row
        includes the overall compliance status and pass/fail counts.
    .PARAMETER IdentityRisk
        Optional hashtable from Measure-SPIdentityRisk. When provided, each row
        includes the identity's risk score, tier, and top risk factors.
    .PARAMETER SourceGovernance
        Optional hashtable from Measure-SPSourceGovernance. When provided, each row
        includes the source's governance grade and score.
    .PARAMETER ReviewerReputation
        Optional hashtable from Measure-SPReviewerReputation. When provided, each row
        includes the reviewer's reputation score and tier.
    .PARAMETER OutputPath
        Directory in which to write output files. Created if absent.
    .PARAMETER Format
        Output format: CSV, JSON, or Both. Default: Both.
    .PARAMETER CorrelationID
        Unique ID for tracing and file naming. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{ Success = [bool]; Data = @{ CsvFile; JsonFile; RowCount; Columns }; Error }
    .EXAMPLE
        $result = Export-SPGovernanceDashboardData -CampaignAudits $audits `
            -IdentityRisk $risk -SourceGovernance $gov -OutputPath 'C:\Dashboard'
    .EXAMPLE
        $result = Export-SPGovernanceDashboardData -CampaignAudits $audits `
            -PolicyResults $policy -ReviewerReputation $rep `
            -OutputPath 'C:\Dashboard' -Format CSV
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object[]]$CampaignAudits,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [hashtable]$CampaignMetrics,

        [Parameter()]
        [hashtable]$PolicyResults,

        [Parameter()]
        [hashtable]$IdentityRisk,

        [Parameter()]
        [hashtable]$SourceGovernance,

        [Parameter()]
        [hashtable]$ReviewerReputation,

        [Parameter()]
        [ValidateSet('CSV', 'JSON', 'Both')]
        [string]$Format = 'Both',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.AuditReport'
    $action    = 'Export-SPGovernanceDashboardData'

    Write-SPLog -Message "Exporting dashboard data for $($CampaignAudits.Count) campaign(s), Format=$Format" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    # --- Helper: safe value extraction from hashtable or PSCustomObject ---
    function _DVal ($obj, [string]$key, [string]$default = '') {
        if ($null -eq $obj) { return $default }
        if ($obj -is [hashtable]) {
            if ($obj.ContainsKey($key) -and $null -ne $obj[$key]) { return [string]$obj[$key] }
            return $default
        }
        if ($null -ne $obj.PSObject -and $null -ne $obj.PSObject.Properties[$key]) {
            $v = $obj.PSObject.Properties[$key].Value
            if ($null -ne $v) { return [string]$v }
        }
        return $default
    }

    # --- Build identity risk lookup: IdentityId -> { RiskScore, RiskTier, ... } ---
    $riskLookup = @{}
    if ($null -ne $IdentityRisk -and $IdentityRisk.ContainsKey('Identities')) {
        foreach ($id in @($IdentityRisk['Identities'])) {
            if ($null -eq $id) { continue }
            $idKey = _DVal $id 'IdentityId'
            if ([string]::IsNullOrWhiteSpace($idKey)) {
                $idKey = _DVal $id 'IdentityName'
            }
            if (-not [string]::IsNullOrWhiteSpace($idKey) -and -not $riskLookup.ContainsKey($idKey)) {
                $riskLookup[$idKey] = $id
            }
            # Also index by name for fallback matching
            $idName = _DVal $id 'IdentityName'
            if (-not [string]::IsNullOrWhiteSpace($idName) -and -not $riskLookup.ContainsKey($idName)) {
                $riskLookup[$idName] = $id
            }
        }
    }

    # --- Build source governance lookup: SourceName -> { GovernanceGrade, GovernanceScore } ---
    $sourceLookup = @{}
    if ($null -ne $SourceGovernance -and $SourceGovernance.ContainsKey('Sources')) {
        foreach ($src in @($SourceGovernance['Sources'])) {
            if ($null -eq $src) { continue }
            $srcName = _DVal $src 'SourceName'
            if (-not [string]::IsNullOrWhiteSpace($srcName) -and -not $sourceLookup.ContainsKey($srcName)) {
                $sourceLookup[$srcName] = $src
            }
        }
    }

    # --- Build reviewer reputation lookup: ReviewerName -> { ReputationScore, ReputationTier } ---
    $repLookup = @{}
    if ($null -ne $ReviewerReputation -and $ReviewerReputation.ContainsKey('Reviewers')) {
        foreach ($rev in @($ReviewerReputation['Reviewers'])) {
            if ($null -eq $rev) { continue }
            $revName = ''
            if ($rev -is [hashtable] -and $rev.ContainsKey('Name')) { $revName = [string]$rev['Name'] }
            elseif ($null -ne $rev.PSObject -and $null -ne $rev.PSObject.Properties['Name']) { $revName = [string]$rev.Name }
            if (-not [string]::IsNullOrWhiteSpace($revName) -and -not $repLookup.ContainsKey($revName)) {
                $repLookup[$revName] = $rev
            }
        }
    }

    # --- Build campaign metrics lookup: CampaignId -> metrics object ---
    $metricsLookup = @{}
    if ($null -ne $CampaignMetrics -and $CampaignMetrics.ContainsKey('Data')) {
        foreach ($cm in @($CampaignMetrics['Data'])) {
            if ($null -eq $cm) { continue }
            $cmId = ''
            if ($null -ne $cm.PSObject -and $null -ne $cm.PSObject.Properties['CampaignId']) {
                $cmId = [string]$cm.CampaignId
            }
            if (-not [string]::IsNullOrWhiteSpace($cmId) -and -not $metricsLookup.ContainsKey($cmId)) {
                $metricsLookup[$cmId] = $cm
            }
        }
    }

    # --- Extract policy summary ---
    $policyCompliant = ''
    $policyPassed    = ''
    $policyFailed    = ''
    if ($null -ne $PolicyResults) {
        $policyCompliant = _DVal $PolicyResults 'OverallCompliant'
        if ($PolicyResults.ContainsKey('Summary') -and $null -ne $PolicyResults['Summary']) {
            $pSummary = $PolicyResults['Summary']
            $policyPassed = _DVal $pSummary 'Passed'
            $policyFailed = _DVal $pSummary 'Failed'
        }
    }

    $exportTimestamp = (Get-Date).ToUniversalTime().ToString('o')
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $campName      = _DVal $audit 'CampaignName'
        $campId        = _DVal $audit 'CampaignId'
        $campType      = _DVal $audit 'CampaignType'
        $campStatus    = _DVal $audit 'Status'
        $campCreated   = _DVal $audit 'Created'
        $campDeadline  = _DVal $audit 'Deadline'
        $campCompleted = _DVal $audit 'Completed'

        # Campaign-level decision counts
        $decisions = $null
        if ($audit -is [hashtable] -and $audit.ContainsKey('Decisions')) {
            $decisions = $audit['Decisions']
        } elseif ($null -ne $audit.PSObject -and $null -ne $audit.PSObject.Properties['Decisions']) {
            $decisions = $audit.Decisions
        }

        $approvedCt = 0; $revokedCt = 0; $pendingCt = 0
        if ($null -ne $decisions -and $decisions -is [hashtable]) {
            if ($decisions.ContainsKey('Approved') -and $null -ne $decisions['Approved']) {
                $approvedCt = @($decisions['Approved']).Count
            }
            if ($decisions.ContainsKey('Revoked') -and $null -ne $decisions['Revoked']) {
                $revokedCt = @($decisions['Revoked']).Count
            }
            if ($decisions.ContainsKey('Pending') -and $null -ne $decisions['Pending']) {
                $pendingCt = @($decisions['Pending']).Count
            }
        }
        $totalItems    = $approvedCt + $revokedCt + $pendingCt
        $completionPct = if ($totalItems -gt 0) {
            [Math]::Round((($approvedCt + $revokedCt) / $totalItems) * 100, 1)
        } else { 0.0 }

        # Campaign metrics enrichment
        $campApprovalRate   = ''
        $campRevocationRate = ''
        $campAvgRespHours   = ''
        if ($metricsLookup.ContainsKey($campId)) {
            $cm = $metricsLookup[$campId]
            if ($null -ne $cm.PSObject.Properties['ApprovalRate'])         { $campApprovalRate   = [string]$cm.ApprovalRate }
            if ($null -ne $cm.PSObject.Properties['RevocationRate'])       { $campRevocationRate = [string]$cm.RevocationRate }
            if ($null -ne $cm.PSObject.Properties['AvgResponseTimeHours']) { $campAvgRespHours   = [string]$cm.AvgResponseTimeHours }
        }

        # Iterate all decisions
        if ($null -eq $decisions) { continue }

        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }

                $identityName = if ($null -ne $item.IdentityName) { [string]$item.IdentityName } else { '' }
                $identityId   = if ($null -ne $item.IdentityId)   { [string]$item.IdentityId }   else { '' }
                $sourceName   = if ($null -ne $item.SourceName)   { [string]$item.SourceName }   else { '' }
                $revName      = if ($null -ne $item.ReviewerName) { [string]$item.ReviewerName } else { '' }

                # Identity risk enrichment
                $idRiskScore    = ''
                $idRiskTier     = ''
                $idStaleCount   = ''
                $idPrivCount    = ''
                $idTopFactors   = ''
                $riskEntry = $null
                if ($riskLookup.ContainsKey($identityId)) {
                    $riskEntry = $riskLookup[$identityId]
                } elseif ($riskLookup.ContainsKey($identityName)) {
                    $riskEntry = $riskLookup[$identityName]
                }
                if ($null -ne $riskEntry) {
                    $idRiskScore  = _DVal $riskEntry 'RiskScore'
                    $idRiskTier   = _DVal $riskEntry 'RiskTier'
                    $idStaleCount = _DVal $riskEntry 'StaleAccessCount'
                    $idPrivCount  = _DVal $riskEntry 'PrivilegedAccessCount'
                    $factors = $null
                    if ($riskEntry -is [hashtable] -and $riskEntry.ContainsKey('TopRiskFactors')) {
                        $factors = $riskEntry['TopRiskFactors']
                    }
                    if ($null -ne $factors -and $factors -is [array] -and $factors.Count -gt 0) {
                        $idTopFactors = ($factors | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
                    }
                }

                # Source governance enrichment
                $srcGrade = ''
                $srcScore = ''
                if ($sourceLookup.ContainsKey($sourceName)) {
                    $srcEntry = $sourceLookup[$sourceName]
                    $srcGrade = _DVal $srcEntry 'GovernanceGrade'
                    $srcScore = _DVal $srcEntry 'GovernanceScore'
                }

                # Reviewer reputation enrichment
                $revRepScore = ''
                $revRepTier  = ''
                if ($repLookup.ContainsKey($revName)) {
                    $repEntry = $repLookup[$revName]
                    if ($repEntry -is [hashtable]) {
                        $revRepScore = _DVal $repEntry 'ReputationScore'
                        $revRepTier  = _DVal $repEntry 'ReputationTier'
                    } else {
                        if ($null -ne $repEntry.PSObject.Properties['ReputationScore']) { $revRepScore = [string]$repEntry.ReputationScore }
                        if ($null -ne $repEntry.PSObject.Properties['ReputationTier'])  { $revRepTier  = [string]$repEntry.ReputationTier }
                    }
                }

                $rows.Add([PSCustomObject]@{
                    CampaignId              = $campId
                    CampaignName            = $campName
                    CampaignType            = $campType
                    CampaignStatus          = $campStatus
                    CampaignCreated         = $campCreated
                    CampaignDeadline        = $campDeadline
                    CampaignCompleted       = $campCompleted
                    CampaignTotalItems      = $totalItems
                    CampaignCompletionPct   = $completionPct
                    CampaignApprovalRate    = $campApprovalRate
                    CampaignRevocationRate  = $campRevocationRate
                    CampaignAvgResponseHrs  = $campAvgRespHours
                    IdentityName            = $identityName
                    IdentityId              = $identityId
                    AccountName             = if ($null -ne $item.AccountName) { [string]$item.AccountName } else { '' }
                    SourceName              = $sourceName
                    EntitlementName         = if ($null -ne $item.AccessName)  { [string]$item.AccessName }  else { '' }
                    AccessType              = if ($null -ne $item.AccessType)  { [string]$item.AccessType }  else { '' }
                    Decision                = if ($null -ne $item.Decision)    { [string]$item.Decision }    else { $category }
                    DecisionDate            = if ($null -ne $item.DecisionDate) { [string]$item.DecisionDate } else { '' }
                    Justification           = if ($null -ne $item.Justification) { [string]$item.Justification } else { '' }
                    ReviewerName            = $revName
                    IdentityRiskScore       = $idRiskScore
                    IdentityRiskTier        = $idRiskTier
                    IdentityStaleAccess     = $idStaleCount
                    IdentityPrivilegedAccess = $idPrivCount
                    IdentityTopRiskFactors  = $idTopFactors
                    SourceGovernanceGrade   = $srcGrade
                    SourceGovernanceScore   = $srcScore
                    PolicyOverallCompliant  = $policyCompliant
                    PolicyPassed            = $policyPassed
                    PolicyFailed            = $policyFailed
                    ReviewerReputationScore = $revRepScore
                    ReviewerReputationTier  = $revRepTier
                    ExportTimestamp         = $exportTimestamp
                })
            }
        }
    }

    $columnNames = @(
        'CampaignId','CampaignName','CampaignType','CampaignStatus',
        'CampaignCreated','CampaignDeadline','CampaignCompleted',
        'CampaignTotalItems','CampaignCompletionPct',
        'CampaignApprovalRate','CampaignRevocationRate','CampaignAvgResponseHrs',
        'IdentityName','IdentityId','AccountName','SourceName',
        'EntitlementName','AccessType','Decision','DecisionDate','Justification',
        'ReviewerName',
        'IdentityRiskScore','IdentityRiskTier','IdentityStaleAccess',
        'IdentityPrivilegedAccess','IdentityTopRiskFactors',
        'SourceGovernanceGrade','SourceGovernanceScore',
        'PolicyOverallCompliant','PolicyPassed','PolicyFailed',
        'ReviewerReputationScore','ReviewerReputationTier',
        'ExportTimestamp'
    )

    $csvFile  = $null
    $jsonFile = $null

    # --- Write CSV ---
    if ($Format -eq 'CSV' -or $Format -eq 'Both') {
        $csvFile = Join-Path $OutputPath "dashboard-governance-${CorrelationID}.csv"
        if ($rows.Count -gt 0) {
            $rows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
        } else {
            $emptyRow = [ordered]@{}
            foreach ($col in $columnNames) { $emptyRow[$col] = '' }
            [PSCustomObject]$emptyRow | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
            $headerLine = (Get-Content -Path $csvFile -TotalCount 1)
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($csvFile, "$headerLine`n", $utf8NoBom)
        }
        Write-SPLog -Message "Dashboard CSV written ($($rows.Count) rows): $csvFile" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
    }

    # --- Write JSON ---
    if ($Format -eq 'JSON' -or $Format -eq 'Both') {
        $jsonFile = Join-Path $OutputPath "dashboard-governance-${CorrelationID}.json"
        $jsonPayload = @{
            exportTimestamp = $exportTimestamp
            correlationId  = $CorrelationID
            rowCount       = $rows.Count
            columns        = $columnNames
            data           = @($rows)
        }
        $jsonText = $jsonPayload | ConvertTo-Json -Depth 10 -Compress:$false
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($jsonFile, $jsonText, $utf8NoBom)
        Write-SPLog -Message "Dashboard JSON written ($($rows.Count) rows): $jsonFile" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
    }

    Write-SPLog -Message "Export-SPGovernanceDashboardData complete: $($rows.Count) rows, $($columnNames.Count) columns" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            CsvFile  = $csvFile
            JsonFile = $jsonFile
            RowCount = $rows.Count
            Columns  = $columnNames.Count
        }
        Error   = $null
    }
}

#endregion

#region Audit Evidence Integrity

function New-SPAuditEvidenceChain {
    <#
    .SYNOPSIS
        Creates a cryptographic integrity chain over JSONL audit trail files.
    .DESCRIPTION
        Scans audit output directories for JSONL files within a date range,
        computes a SHA-256 hash for each file, and links hashes into a chain
        where each entry includes the previous entry's hash. The resulting
        manifest provides tamper-evident proof: if any file is modified after
        the chain is built, re-verification will detect the broken link.

        Chain algorithm:
          - File 0: ChainHash = SHA256( SHA256(file) + "GENESIS" )
          - File N: ChainHash = SHA256( SHA256(file) + ChainHash[N-1] )

        The manifest JSON contains file paths, individual hashes, chain
        hashes, file sizes, and timestamps. A companion Verify flag can be
        passed to validate an existing manifest rather than create a new one.

        Designed for SOX 404 / SOC 2 evidence integrity requirements.
    .PARAMETER AuditOutputPath
        Directory containing JSONL audit trail files. Resolved from
        config (Audit.OutputPath) if omitted.
    .PARAMETER DeltaCertOutputPath
        DeltaCert output directory. Resolved from config if omitted.
    .PARAMETER After
        Include files modified after this datetime.
    .PARAMETER Before
        Include files modified before this datetime.
    .PARAMETER OutputPath
        Directory in which to write the evidence-chain manifest JSON.
        Created if absent. Defaults to AuditOutputPath.
    .PARAMETER ManifestName
        Custom manifest file name (without extension). Defaults to
        "evidence-chain-{yyyyMMdd-HHmmss}".
    .PARAMETER Verify
        Path to an existing manifest JSON to verify. When provided, the
        function re-hashes each referenced file and checks the chain.
        No new manifest is written.
    .PARAMETER Scope
        Which directories to include: Full (both), AuditOnly, or
        DeltaCertOnly. Default: Full.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{ Success; Data = @{ ManifestPath; FileCount; ChainValid;
        Violations }; Error }
    .EXAMPLE
        New-SPAuditEvidenceChain -After (Get-Date).AddDays(-30)
    .EXAMPLE
        New-SPAuditEvidenceChain -Verify 'C:\Audit\evidence-chain-20260531.json'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$AuditOutputPath,

        [Parameter()]
        [string]$DeltaCertOutputPath,

        [Parameter()]
        [DateTime]$After,

        [Parameter()]
        [DateTime]$Before,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$ManifestName,

        [Parameter()]
        [string]$Verify,

        [Parameter()]
        [ValidateSet('Full', 'AuditOnly', 'DeltaCertOnly')]
        [string]$Scope = 'Full',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.AuditReport'
    $action    = 'New-SPAuditEvidenceChain'

    # --- Verify mode: validate an existing manifest ---
    if (-not [string]::IsNullOrWhiteSpace($Verify)) {
        Write-SPLog -Message "Verifying evidence chain from $Verify" `
            -Severity INFO -Component $component -Action $action `
            -CorrelationID $CorrelationID

        if (-not (Test-Path -Path $Verify -PathType Leaf)) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Manifest file not found: $Verify"
            }
        }

        try {
            $manifestJson = Get-Content -Path $Verify -Raw -ErrorAction Stop
            $manifest = $manifestJson | ConvertFrom-Json
        }
        catch {
            return @{
                Success = $false
                Data    = $null
                Error   = "Failed to parse manifest: $($_.Exception.Message)"
            }
        }

        $violations   = [System.Collections.Generic.List[hashtable]]::new()
        $previousHash = 'GENESIS'
        $fileCount    = 0

        foreach ($entry in @($manifest.Files)) {
            $fileCount++
            $filePath = $entry.FilePath

            # Check file exists
            if (-not (Test-Path -Path $filePath -PathType Leaf)) {
                $violations.Add(@{
                    File   = $filePath
                    Reason = 'File missing'
                })
                $previousHash = $entry.ChainHash
                continue
            }

            # Recompute file hash
            try {
                $currentHash = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash
            }
            catch {
                $violations.Add(@{
                    File   = $filePath
                    Reason = "Hash computation failed: $($_.Exception.Message)"
                })
                $previousHash = $entry.ChainHash
                continue
            }

            # Check file hash
            if ($currentHash -ne $entry.FileHash) {
                $violations.Add(@{
                    File     = $filePath
                    Reason   = 'File content modified'
                    Expected = $entry.FileHash
                    Actual   = $currentHash
                })
            }

            # Recompute chain hash
            $chainInput    = $currentHash + $previousHash
            $chainBytes    = [System.Text.Encoding]::UTF8.GetBytes($chainInput)
            $sha           = [System.Security.Cryptography.SHA256]::Create()
            $chainHashBytes = $sha.ComputeHash($chainBytes)
            $computedChain = [BitConverter]::ToString($chainHashBytes) -replace '-', ''
            $sha.Dispose()

            if ($computedChain -ne $entry.ChainHash) {
                $violations.Add(@{
                    File     = $filePath
                    Reason   = 'Chain link broken'
                    Expected = $entry.ChainHash
                    Actual   = $computedChain
                })
            }

            $previousHash = $entry.ChainHash
        }

        $chainValid = ($violations.Count -eq 0)

        Write-SPLog -Message "Evidence chain verification complete: $fileCount files, $($violations.Count) violation(s)" `
            -Severity $(if ($chainValid) { 'INFO' } else { 'WARN' }) `
            -Component $component -Action $action -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                ManifestPath = $Verify
                FileCount    = $fileCount
                ChainValid   = $chainValid
                Violations   = @($violations)
            }
            Error   = $null
        }
    }

    # --- Create mode: build a new evidence chain ---

    Write-SPLog -Message "Building evidence chain (Scope=$Scope)" `
        -Severity INFO -Component $component -Action $action `
        -CorrelationID $CorrelationID

    # Resolve paths from config if not provided
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -or
        [string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) {
        try {
            $config = Get-SPConfig
            if ($null -ne $config) {
                if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -and
                    $config.PSObject.Properties.Name -contains 'Audit' -and
                    $config.Audit.PSObject.Properties.Name -contains 'OutputPath' -and
                    -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
                    $AuditOutputPath = $config.Audit.OutputPath
                }
                if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath) -and
                    $config.PSObject.Properties.Name -contains 'DeltaCert' -and
                    $config.DeltaCert.PSObject.Properties.Name -contains 'OutputPath' -and
                    -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
                    $DeltaCertOutputPath = $config.DeltaCert.OutputPath
                }
            }
        }
        catch {
            Write-SPLog -Message "Could not load config for path resolution: $($_.Exception.Message)" `
                -Severity WARN -Component $component -Action $action `
                -CorrelationID $CorrelationID
        }
    }
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath))     { $AuditOutputPath     = '.\Audit' }
    if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) { $DeltaCertOutputPath = '.\DeltaCert' }
    if ([string]::IsNullOrWhiteSpace($OutputPath))          { $OutputPath          = $AuditOutputPath }

    # Collect JSONL files
    $jsonlFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    if ($Scope -ne 'DeltaCertOnly' -and (Test-Path -Path $AuditOutputPath -PathType Container)) {
        $found = Get-ChildItem -Path $AuditOutputPath -Filter '*.jsonl' -File -ErrorAction SilentlyContinue
        foreach ($f in $found) { $jsonlFiles.Add($f) }
    }

    if ($Scope -ne 'AuditOnly' -and (Test-Path -Path $DeltaCertOutputPath -PathType Container)) {
        $found = Get-ChildItem -Path $DeltaCertOutputPath -Filter '*.jsonl' -File -ErrorAction SilentlyContinue
        foreach ($f in $found) { $jsonlFiles.Add($f) }
    }

    # Apply date range filter
    if ($PSBoundParameters.ContainsKey('After')) {
        $jsonlFiles = [System.Collections.Generic.List[System.IO.FileInfo]]@(
            $jsonlFiles | Where-Object { $_.LastWriteTime -ge $After }
        )
    }
    if ($PSBoundParameters.ContainsKey('Before')) {
        $jsonlFiles = [System.Collections.Generic.List[System.IO.FileInfo]]@(
            $jsonlFiles | Where-Object { $_.LastWriteTime -le $Before }
        )
    }

    # Sort by last write time for deterministic chain order
    $sortedFiles = @($jsonlFiles | Sort-Object -Property LastWriteTime, FullName)

    if ($sortedFiles.Count -eq 0) {
        Write-SPLog -Message "No JSONL files found in specified path(s) and date range" `
            -Severity WARN -Component $component -Action $action `
            -CorrelationID $CorrelationID
        return @{
            Success = $true
            Data    = @{
                ManifestPath = $null
                FileCount    = 0
                ChainValid   = $true
                Violations   = @()
            }
            Error   = $null
        }
    }

    # Build the chain
    $chainEntries = [System.Collections.Generic.List[hashtable]]::new()
    $previousHash = 'GENESIS'
    $totalBytes   = 0

    foreach ($file in $sortedFiles) {
        # Compute file hash
        try {
            $fileHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
        }
        catch {
            Write-SPLog -Message "Failed to hash $($file.Name): $($_.Exception.Message)" `
                -Severity WARN -Component $component -Action $action `
                -CorrelationID $CorrelationID
            continue
        }

        # Compute chain hash: SHA256( fileHash + previousChainHash )
        $chainInput     = $fileHash + $previousHash
        $chainBytes     = [System.Text.Encoding]::UTF8.GetBytes($chainInput)
        $sha            = [System.Security.Cryptography.SHA256]::Create()
        $chainHashBytes = $sha.ComputeHash($chainBytes)
        $chainHash      = [BitConverter]::ToString($chainHashBytes) -replace '-', ''
        $sha.Dispose()

        $totalBytes += $file.Length

        $chainEntries.Add(@{
            FilePath     = $file.FullName
            FileName     = $file.Name
            FileHash     = $fileHash
            ChainHash    = $chainHash
            SizeBytes    = $file.Length
            LastModified = $file.LastWriteTime.ToUniversalTime().ToString('o')
        })

        $previousHash = $chainHash
    }

    # Resolve toolkit version
    $toolkitVersion = 'Unknown'
    try {
        $cfgCheck = Get-SPConfig
        if ($null -ne $cfgCheck -and
            $cfgCheck.PSObject.Properties.Name -contains 'Global' -and
            $cfgCheck.Global.PSObject.Properties.Name -contains 'ToolkitVersion') {
            $toolkitVersion = $cfgCheck.Global.ToolkitVersion
        }
    } catch { }

    # Build manifest
    $generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $manifest = @{
        ManifestId      = [guid]::NewGuid().ToString()
        GeneratedAt     = $generatedAt
        CorrelationID   = $CorrelationID
        ToolkitVersion  = $toolkitVersion
        Algorithm       = 'SHA-256'
        ChainAlgorithm  = 'SHA256(FileHash + PreviousChainHash)'
        GenesisValue    = 'GENESIS'
        Scope           = $Scope
        DateRange       = @{
            After  = if ($PSBoundParameters.ContainsKey('After'))  { $After.ToUniversalTime().ToString('o') }  else { $null }
            Before = if ($PSBoundParameters.ContainsKey('Before')) { $Before.ToUniversalTime().ToString('o') } else { $null }
        }
        Files           = @($chainEntries)
        Summary         = @{
            FileCount   = $chainEntries.Count
            TotalBytes  = $totalBytes
            FinalChainHash = if ($chainEntries.Count -gt 0) { $chainEntries[$chainEntries.Count - 1].ChainHash } else { $null }
        }
    }

    # Write manifest
    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($ManifestName)) {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $ManifestName = "evidence-chain-${ts}"
    }
    $manifestPath = Join-Path -Path $OutputPath -ChildPath "${ManifestName}.json"

    try {
        $manifestJson = $manifest | ConvertTo-Json -Depth 10
        $utf8NoBom    = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)
    }
    catch {
        Write-SPLog -Message "Failed to write manifest: $($_.Exception.Message)" `
            -Severity ERROR -Component $component -Action $action `
            -CorrelationID $CorrelationID
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to write manifest: $($_.Exception.Message)"
        }
    }

    $resolvedPath = (Resolve-Path -Path $manifestPath).Path

    Write-SPLog -Message "Evidence chain created: $resolvedPath ($($chainEntries.Count) files, $totalBytes bytes)" `
        -Severity INFO -Component $component -Action $action `
        -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            ManifestPath = $resolvedPath
            FileCount    = $chainEntries.Count
            ChainValid   = $true
            Violations   = @()
        }
        Error   = $null
    }
}

#endregion

#region Remediation Ticket Export

function Export-SPRemediationTickets {
    <#
    .SYNOPSIS
        Exports revocation decisions as ITSM-ready ticket rows for ServiceNow or Jira import.
    .DESCRIPTION
        Reads revocation decisions from campaign audit data (Group-SPAuditRemediationProof
        output) and optionally from disconnected app remediation tracker files. Produces
        a CSV formatted for bulk import into ServiceNow or Jira.

        Columns: TicketType, Priority, AssignedTo, AppName, IdentityName, AccountId,
        EntitlementRevoked, ReviewerName, DecisionDate, DueDate, Description

        Each revocation = one ticket row. Priority is derived from remediation status:
        overdue items get P2, pending items get P3.

        For disconnected apps: reads remediation-tracker.json files from the configured
        DisconnectedApps.Reports directory. Only PENDING records are exported as tickets.
    .PARAMETER RemediationProof
        Hashtable output from Group-SPAuditRemediationProof. Must contain a RevokedItems
        array with PSCustomObjects having: IdentityName, AccessName, SourceName,
        ReviewerName, DecisionDate, RemediationComplete, AccountIdentifier.
    .PARAMETER DisconnectedAppPath
        Path to the disconnected apps report directory. Each subdirectory should contain
        a remediation-tracker.json. Resolved from config (DisconnectedApps.Reports) if
        omitted. Pass $null or empty string to skip disconnected app processing.
    .PARAMETER SkipDisconnectedApps
        Skip reading disconnected app remediation trackers entirely.
    .PARAMETER SlaBusinessDays
        Number of business days for the remediation SLA. Used to compute DueDate
        from DecisionDate. Default: 5.
    .PARAMETER AssignedTo
        Default assignee for tickets when no specific owner can be determined.
        Default: 'IAM Operations'.
    .PARAMETER OutputPath
        Directory in which to write the CSV file. Created if absent.
    .PARAMETER FileName
        Custom CSV file name (without extension). Defaults to
        "remediation-tickets-{yyyyMMdd-HHmmss}".
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{ Success = [bool]; Data = @{ CsvPath; TicketCount;
        ConnectedCount; DisconnectedCount }; Error }
    .EXAMPLE
        $proof = Group-SPAuditRemediationProof -Items $items -Certifications $certs
        $result = Export-SPRemediationTickets -RemediationProof $proof -OutputPath 'C:\Tickets'
    .EXAMPLE
        Export-SPRemediationTickets -RemediationProof $proof -SkipDisconnectedApps `
            -SlaBusinessDays 3 -OutputPath 'C:\Tickets'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$RemediationProof,

        [Parameter()]
        [string]$DisconnectedAppPath,

        [Parameter()]
        [switch]$SkipDisconnectedApps,

        [Parameter()]
        [ValidateRange(1, 30)]
        [int]$SlaBusinessDays = 5,

        [Parameter()]
        [string]$AssignedTo = 'IAM Operations',

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$FileName,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.AuditReport'
    $action    = 'Export-SPRemediationTickets'

    Write-SPLog -Message "Exporting remediation tickets (SLA=${SlaBusinessDays} days)" `
        -Severity INFO -Component $component -Action $action `
        -CorrelationID $CorrelationID

    try {
        $tickets = [System.Collections.Generic.List[PSCustomObject]]::new()
        $connectedCount     = 0
        $disconnectedCount  = 0

        # --- Helper: add business days to a date ---
        $addBusinessDays = {
            param([DateTime]$StartDate, [int]$Days)
            $current = $StartDate
            $added   = 0
            while ($added -lt $Days) {
                $current = $current.AddDays(1)
                if ($current.DayOfWeek -ne [DayOfWeek]::Saturday -and
                    $current.DayOfWeek -ne [DayOfWeek]::Sunday) {
                    $added++
                }
            }
            return $current
        }

        # --- Connected app revocations from RemediationProof ---
        $revokedItems = @()
        if ($RemediationProof.ContainsKey('RevokedItems') -and
            $null -ne $RemediationProof['RevokedItems']) {
            $revokedItems = @($RemediationProof['RevokedItems'])
        }

        foreach ($item in $revokedItems) {
            # Skip items already remediated
            if ($item.RemediationComplete -eq $true) { continue }

            # Parse decision date
            $decisionDt = $null
            if (-not [string]::IsNullOrWhiteSpace($item.DecisionDate)) {
                try { $decisionDt = [DateTime]::Parse($item.DecisionDate) }
                catch { $decisionDt = $null }
            }

            # Compute due date
            $dueDateStr = ''
            if ($null -ne $decisionDt) {
                $dueDate    = & $addBusinessDays $decisionDt $SlaBusinessDays
                $dueDateStr = $dueDate.ToString('yyyy-MM-dd')
            }

            # Determine priority: overdue = P2, pending = P3
            $priority = 'P3 - Medium'
            if ($null -ne $decisionDt) {
                $slaCutoff = & $addBusinessDays $decisionDt $SlaBusinessDays
                if ((Get-Date) -gt $slaCutoff) {
                    $priority = 'P2 - High'
                }
            }

            $description = "Revoke access [$($item.AccessName)] from [$($item.IdentityName)] " +
                           "on source [$($item.SourceName)]. Reviewer: $($item.ReviewerName). " +
                           "Decision date: $($item.DecisionDate)."

            $tickets.Add([PSCustomObject]@{
                TicketType         = 'Access Revocation'
                Priority           = $priority
                AssignedTo         = $AssignedTo
                AppName            = $item.SourceName
                IdentityName       = $item.IdentityName
                AccountId          = $item.AccountIdentifier
                EntitlementRevoked = $item.AccessName
                ReviewerName       = $item.ReviewerName
                DecisionDate       = $item.DecisionDate
                DueDate            = $dueDateStr
                Description        = $description
            })
            $connectedCount++
        }

        # --- Disconnected app revocations from remediation-tracker.json ---
        if (-not $SkipDisconnectedApps) {
            # Resolve path from config if not provided
            if ([string]::IsNullOrWhiteSpace($DisconnectedAppPath)) {
                try {
                    $config = Get-SPConfig
                    if ($null -ne $config -and
                        $config.PSObject.Properties.Name -contains 'DisconnectedApps' -and
                        $config.DisconnectedApps.PSObject.Properties.Name -contains 'Reports' -and
                        -not [string]::IsNullOrWhiteSpace($config.DisconnectedApps.Reports)) {
                        $DisconnectedAppPath = $config.DisconnectedApps.Reports
                    }
                }
                catch {
                    Write-SPLog -Message "Could not load config for disconnected app path: $($_.Exception.Message)" `
                        -Severity WARN -Component $component -Action $action `
                        -CorrelationID $CorrelationID
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($DisconnectedAppPath) -and
                (Test-Path -Path $DisconnectedAppPath -PathType Container)) {

                $trackerFiles = Get-ChildItem -Path $DisconnectedAppPath -Filter 'remediation-tracker.json' `
                    -Recurse -File -ErrorAction SilentlyContinue

                foreach ($trackerFile in $trackerFiles) {
                    try {
                        $raw = Get-Content -Path $trackerFile.FullName -Encoding UTF8 -Raw
                        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

                        $records = @($raw | ConvertFrom-Json)
                    }
                    catch {
                        Write-SPLog -Message "Failed to parse tracker: $($trackerFile.FullName) - $($_.Exception.Message)" `
                            -Severity WARN -Component $component -Action $action `
                            -CorrelationID $CorrelationID
                        continue
                    }

                    foreach ($rec in $records) {
                        # Only export PENDING records
                        $status = ''
                        if ($null -ne $rec.PSObject.Properties['Status']) {
                            $status = [string]$rec.Status
                        }
                        if ($status -ne 'Pending') { continue }

                        # Parse decision date
                        $decisionDt = $null
                        $decisionDateStr = ''
                        if ($null -ne $rec.PSObject.Properties['DecisionDate'] -and
                            -not [string]::IsNullOrWhiteSpace($rec.DecisionDate)) {
                            $decisionDateStr = [string]$rec.DecisionDate
                            try { $decisionDt = [DateTime]::Parse($decisionDateStr) }
                            catch { $decisionDt = $null }
                        }

                        # Compute due date and priority
                        $dueDateStr = ''
                        $priority   = 'P3 - Medium'
                        if ($null -ne $decisionDt) {
                            $dueDate    = & $addBusinessDays $decisionDt $SlaBusinessDays
                            $dueDateStr = $dueDate.ToString('yyyy-MM-dd')
                            if ((Get-Date) -gt $dueDate) {
                                $priority = 'P2 - High'
                            }
                        }

                        $appName       = if ($null -ne $rec.PSObject.Properties['AppName'])      { [string]$rec.AppName }      else { '' }
                        $identityName  = if ($null -ne $rec.PSObject.Properties['IdentityName']) { [string]$rec.IdentityName } else { '' }
                        $accountId     = if ($null -ne $rec.PSObject.Properties['AccountId'])    { [string]$rec.AccountId }    else { '' }
                        $entitlement   = if ($null -ne $rec.PSObject.Properties['Entitlement'])  { [string]$rec.Entitlement }  else { '' }
                        $reviewerName  = if ($null -ne $rec.PSObject.Properties['ReviewerName']) { [string]$rec.ReviewerName } else { '' }

                        $description = "Revoke access [$entitlement] from [$identityName] " +
                                       "on disconnected app [$appName]. Reviewer: $reviewerName. " +
                                       "Decision date: $decisionDateStr. Manual removal required."

                        $tickets.Add([PSCustomObject]@{
                            TicketType         = 'Disconnected App Revocation'
                            Priority           = $priority
                            AssignedTo         = $AssignedTo
                            AppName            = $appName
                            IdentityName       = $identityName
                            AccountId          = $accountId
                            EntitlementRevoked = $entitlement
                            ReviewerName       = $reviewerName
                            DecisionDate       = $decisionDateStr
                            DueDate            = $dueDateStr
                            Description        = $description
                        })
                        $disconnectedCount++
                    }
                }
            }
            else {
                Write-SPLog -Message 'No disconnected app report path configured or found -- skipping' `
                    -Severity DEBUG -Component $component -Action $action `
                    -CorrelationID $CorrelationID
            }
        }

        # --- Write CSV ---
        if ($tickets.Count -eq 0) {
            Write-SPLog -Message 'No pending remediation tickets to export' `
                -Severity INFO -Component $component -Action $action `
                -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{
                    CsvPath           = $null
                    TicketCount       = 0
                    ConnectedCount    = 0
                    DisconnectedCount = 0
                }
                Error   = $null
            }
        }

        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }

        if ([string]::IsNullOrWhiteSpace($FileName)) {
            $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $FileName = "remediation-tickets-${ts}"
        }
        $csvPath = Join-Path -Path $OutputPath -ChildPath "${FileName}.csv"

        $tickets | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
        $resolvedPath = (Resolve-Path -Path $csvPath).Path

        Write-SPLog -Message "Exported $($tickets.Count) remediation ticket(s) to $resolvedPath (connected=$connectedCount, disconnected=$disconnectedCount)" `
            -Severity INFO -Component $component -Action $action `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                CsvPath           = $resolvedPath
                TicketCount       = $tickets.Count
                ConnectedCount    = $connectedCount
                DisconnectedCount = $disconnectedCount
            }
            Error   = $null
        }
    }
    catch {
        Write-SPLog -Message "Export-SPRemediationTickets failed: $($_.Exception.Message)" `
            -Severity ERROR -Component $component -Action $action `
            -CorrelationID $CorrelationID
        return @{
            Success = $false
            Data    = $null
            Error   = $_.Exception.Message
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Send-SPReport',
    'Export-SPCompliancePackage',
    'Send-SPWebhook',
    'Send-SPNotification',
    'Get-SPOrchestratorHistory',
    'Invoke-SPLogRetention',
    'Save-SPGovernanceMetrics',
    'Get-SPGovernanceMetrics',
    'Get-SPGovernanceMetricsTrend',
    'Export-SPGovernanceDashboardData',
    'New-SPAuditEvidenceChain',
    'Export-SPRemediationTickets'
)

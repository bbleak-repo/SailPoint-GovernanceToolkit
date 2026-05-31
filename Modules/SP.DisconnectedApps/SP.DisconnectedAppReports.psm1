#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Disconnected App HTML Reports
.DESCRIPTION
    HTML report generation functions for the disconnected app onboarding kit.
    Produces Word-paste-compatible HTML reports with inline CSS for delta
    summaries, identity risk, entitlement catalogs, batch orchestration,
    SLA compliance, decision harvesting, and self-service team dashboards.

    Functions:
        1. Export-SPDisconnectedAppDeltaHtml - delta summary HTML report
        2. Export-SPDisconnectedAppIdentityRiskHtml - identity risk HTML report
        3. Export-SPDisconnectedAppEntitlementCatalogHtml - entitlement catalog HTML report
        4. Export-SPDisconnectedAppBatchHtml - batch orchestrator summary HTML report
        5. Export-SPDisconnectedAppSlaHtml - SLA compliance HTML report with delivery grid
        6. Export-SPDisconnectedAppDecisionHarvestHtml - decision harvest HTML report
        7. Export-SPDisconnectedAppTeamDashboard - self-service app team dashboard

    Dependencies:
        - SP.DisconnectedAppRunner (Get-SPRemediationReport, Get-SPRegisteredApps)
        - SP.DisconnectedAppAnalytics (data-gathering functions)
        - SP.Core (Write-SPLog, Get-SPConfig)

.NOTES
    Module: SP.DisconnectedApps / SP.DisconnectedAppReports
    Version: 1.0.0
    Component: HTML Reports

    Color taxonomy:
        Green  #339933 - Approved / success
        Red    #CC3333 - Revoked / error
        Orange #FF8800 - Pending / warn
        Blue   #336699 - Info / neutral
        Gray   #777777 - N/A / footer
#>

#region Internal HTML Helpers

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

#region Delta HTML Report

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

#endregion

#region Identity Risk HTML Report

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

#endregion

#region Entitlement Catalog HTML Report

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

#endregion

#region Batch HTML Report

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

#endregion

#region SLA HTML Report

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

#endregion

#region Decision Harvest HTML Report

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

#region DA-29: Self-Service App Team Dashboard

function Export-SPDisconnectedAppTeamDashboard {
    <#
    .SYNOPSIS
        Generates a per-app HTML status page for app team self-service review.
    .DESCRIPTION
        Produces a self-contained HTML dashboard for a single disconnected app
        that app teams can view in any browser without PowerShell access. The
        dashboard consolidates:

        1. Delivery Status -- today's file received? validation passed?
        2. Delta Summary -- what changed today (adds, removes, grants, revokes)
        3. Campaign Status -- campaigns created today, pending, completed
        4. Remediation Queue -- revocations awaiting confirmation (from DA-22)
        5. SLA Compliance -- 30-day delivery calendar (green/red/gray)
        6. Trend Sparkline -- 90-day access count trend (CSS bar chart)

        The report uses 100% inline CSS for Microsoft Word paste compatibility.
        No external resources, no JavaScript dependencies.

    .PARAMETER AppName
        Application name. Used to locate audit trail, remediation tracker,
        and snapshots.
    .PARAMETER OutputPath
        Base directory for reports. Dashboard is saved to
        {OutputPath}/{AppName}/team-dashboard.html.
    .PARAMETER SnapshotDir
        Root snapshot directory for SLA calendar data.
        Defaults to .\DisconnectedApps\Snapshots.
    .PARAMETER ConfigPath
        Path to settings.json. Used to get app registration details.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=[bool]; Data=@{FilePath=[string]}; Error=[string]}
    .EXAMPLE
        Export-SPDisconnectedAppTeamDashboard -AppName 'PEP-Plus' -OutputPath '.\Reports'
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
        [string]$SnapshotDir = '.\DisconnectedApps\Snapshots',

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.DisconnectedAppRunner'
    $action    = 'Export-SPDisconnectedAppTeamDashboard'

    Write-SPLog -Message "Generating team dashboard for app '$AppName'" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    try {
        $appOutputPath = Join-Path -Path $OutputPath -ChildPath $AppName
        if (-not (Test-Path -Path $appOutputPath -PathType Container)) {
            New-Item -Path $appOutputPath -ItemType Directory -Force | Out-Null
        }
        $filePath = Join-Path -Path $appOutputPath -ChildPath 'team-dashboard.html'

        $reportDate = Get-Date -Format 'yyyy-MM-dd'
        $reportTime = (Get-Date).ToUniversalTime().ToString('HH:mm:ss')

        # ---------------------------------------------------------------
        # Data Gathering: Delivery Status
        # ---------------------------------------------------------------
        $deliveryStatus = 'Unknown'
        $deliveryDetail = ''
        $deliveryRowCount = 0
        $deliveryFileSize = 0
        $deliveryLastMod  = ''

        # Get app registration to find AccountFilePath
        $appReg = $null
        try {
            $configParams = @{}
            if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }
            $appsResult = Get-SPRegisteredApps @configParams
            if ($appsResult.Success) {
                $appReg = @($appsResult.Data) | Where-Object { $_.Name -eq $AppName } | Select-Object -First 1
            }
        }
        catch { }

        if ($null -ne $appReg -and -not [string]::IsNullOrWhiteSpace($appReg.AccountFilePath)) {
            $acctPath = $appReg.AccountFilePath
            if (Test-Path -Path $acctPath -PathType Leaf) {
                $fileInfo = Get-Item -Path $acctPath
                $deliveryFileSize = $fileInfo.Length
                $deliveryLastMod  = $fileInfo.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss')
                $hoursSinceModified = ((Get-Date).ToUniversalTime() - $fileInfo.LastWriteTimeUtc).TotalHours

                if ($hoursSinceModified -le 24) {
                    $deliveryStatus = 'Delivered'
                    $deliveryDetail = "File received today ($deliveryLastMod UTC)"
                }
                else {
                    $deliveryStatus = 'Stale'
                    $deliveryDetail = "Last modified: $deliveryLastMod UTC ($([math]::Round($hoursSinceModified, 0))h ago)"
                }

                # Quick row count
                try {
                    $rows = @(Import-Csv -Path $acctPath -ErrorAction SilentlyContinue)
                    $deliveryRowCount = $rows.Count
                }
                catch { }
            }
            else {
                $deliveryStatus = 'Missing'
                $deliveryDetail = "Expected at: $acctPath"
            }
        }
        else {
            $deliveryDetail = 'App registration not found or AccountFilePath not configured.'
        }

        # ---------------------------------------------------------------
        # Data Gathering: Delta Summary (from per-app audit JSONL)
        # ---------------------------------------------------------------
        $deltaAdded   = 0
        $deltaRemoved = 0
        $deltaEnabled = 0
        $deltaGranted = 0
        $deltaRevoked = 0
        $deltaDate    = '-'
        $latestCertRunFound = $false

        $auditTrailPath = Join-Path -Path $appOutputPath -ChildPath 'disconnected-app-audit.jsonl'
        if (Test-Path -Path $auditTrailPath -PathType Leaf) {
            $auditLines = @(Get-Content -Path $auditTrailPath -Encoding UTF8 -ErrorAction SilentlyContinue)

            # Walk backward to find the latest DisconnectedAppCertRun
            for ($i = $auditLines.Count - 1; $i -ge 0; $i--) {
                $trimmed = $auditLines[$i].Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                try {
                    $evt = $trimmed | ConvertFrom-Json
                }
                catch { continue }

                if ($evt.Action -eq 'DisconnectedAppCertRun') {
                    $latestCertRunFound = $true
                    if ($null -ne $evt.Timestamp) {
                        $deltaDate = ([string]$evt.Timestamp).Substring(0, 10)
                    }
                    if ($null -ne $evt.PSObject.Properties['DeltaSummary'] -and $null -ne $evt.DeltaSummary) {
                        $ds = $evt.DeltaSummary
                        if ($null -ne $ds.PSObject.Properties['Added'])               { $deltaAdded   = [int]$ds.Added }
                        if ($null -ne $ds.PSObject.Properties['Removed'])              { $deltaRemoved = [int]$ds.Removed }
                        if ($null -ne $ds.PSObject.Properties['Enabled'])              { $deltaEnabled = [int]$ds.Enabled }
                        if ($null -ne $ds.PSObject.Properties['EntitlementsGranted'])  { $deltaGranted = [int]$ds.EntitlementsGranted }
                        if ($null -ne $ds.PSObject.Properties['EntitlementsRevoked'])  { $deltaRevoked = [int]$ds.EntitlementsRevoked }
                    }
                    break
                }
            }
        }

        # ---------------------------------------------------------------
        # Data Gathering: Campaign Status (from audit trail)
        # ---------------------------------------------------------------
        $campaignsToday     = 0
        $campaignsActive    = 0
        $campaignsCompleted = 0
        $totalCampaigns7d   = 0

        $sevenDaysAgo = (Get-Date).ToUniversalTime().AddDays(-7)

        if (Test-Path -Path $auditTrailPath -PathType Leaf) {
            foreach ($line in $auditLines) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                try { $evt = $trimmed | ConvertFrom-Json } catch { continue }

                $eventTime = $null
                if (-not [string]::IsNullOrWhiteSpace($evt.Timestamp)) {
                    try { $eventTime = [datetime]::Parse($evt.Timestamp).ToUniversalTime() }
                    catch { }
                }
                if ($null -eq $eventTime -or $eventTime -lt $sevenDaysAgo) { continue }

                if ($evt.Action -eq 'DisconnectedAppCertRun') {
                    $createdCount = 0
                    if ($null -ne $evt.PSObject.Properties['CampaignsCreated']) {
                        $createdCount = [int]$evt.CampaignsCreated
                    }
                    $totalCampaigns7d += $createdCount
                    if ($eventTime.Date -eq (Get-Date).ToUniversalTime().Date) {
                        $campaignsToday += $createdCount
                    }
                }
                elseif ($evt.Action -eq 'DecisionHarvest') {
                    if ($null -ne $evt.PSObject.Properties['Completed']) {
                        $campaignsCompleted += [int]$evt.Completed
                    }
                    if ($null -ne $evt.PSObject.Properties['Active']) {
                        $campaignsActive = [int]$evt.Active  # latest value (not cumulative)
                    }
                }
            }
        }

        # ---------------------------------------------------------------
        # Data Gathering: Remediation Queue
        # ---------------------------------------------------------------
        $remPending   = 0
        $remOverdue   = 0
        $remConfirmed = 0
        $remEscalated = 0
        $remTotal     = 0
        $overdueRecords = @()

        try {
            $remReport = Get-SPRemediationReport -AppName $AppName -OutputPath $OutputPath `
                -CorrelationID $CorrelationID
            if ($remReport.Success -and $null -ne $remReport.Data) {
                $remPending   = $remReport.Data.Summary.Pending
                $remOverdue   = $remReport.Data.Summary.Overdue
                $remConfirmed = $remReport.Data.Summary.Confirmed
                $remEscalated = $remReport.Data.Summary.Escalated
                $remTotal     = $remReport.Data.Summary.Total
                $overdueRecords = @($remReport.Data.OverdueRecords)
            }
        }
        catch { }

        # ---------------------------------------------------------------
        # Data Gathering: SLA 30-day Calendar
        # ---------------------------------------------------------------
        $slaDeliveryRate = 0.0
        $slaCompliant    = $false
        $slaDaysDelivered = @()
        $slaDaysMissing   = @()

        $appSnapshotDir = Join-Path -Path $SnapshotDir -ChildPath $AppName
        $today = (Get-Date).Date
        $calendarStart = $today.AddDays(-29)

        # Build 30-day date list
        $calendarDates = @()
        for ($d = 0; $d -lt 30; $d++) {
            $calendarDates += $calendarStart.AddDays($d).ToString('yyyy-MM-dd')
        }

        $deliveredSet = [System.Collections.Generic.HashSet[string]]::new()
        if (Test-Path -Path $appSnapshotDir -PathType Container) {
            $snapshotFiles = @(Get-ChildItem -Path $appSnapshotDir -Filter '*-accounts.csv' -File -ErrorAction SilentlyContinue)
            foreach ($sf in $snapshotFiles) {
                $datePart = $sf.Name.Substring(0, 10)
                if ($datePart -match '^\d{4}-\d{2}-\d{2}$') {
                    [void]$deliveredSet.Add($datePart)
                }
            }
        }

        foreach ($cd in $calendarDates) {
            if ($deliveredSet.Contains($cd)) {
                $slaDaysDelivered += $cd
            }
            else {
                $slaDaysMissing += $cd
            }
        }

        $deliveredInWindow = $slaDaysDelivered.Count
        $slaDeliveryRate = if ($calendarDates.Count -gt 0) {
            [math]::Round(($deliveredInWindow / $calendarDates.Count) * 100, 1)
        } else { 0.0 }
        $slaCompliant = ($slaDaysMissing.Count -eq 0)

        # ---------------------------------------------------------------
        # Data Gathering: 90-day Trend (account counts from cert run events)
        # ---------------------------------------------------------------
        $trendData = [System.Collections.Generic.List[hashtable]]::new()
        $ninetyDaysAgo = (Get-Date).ToUniversalTime().AddDays(-90)

        if (Test-Path -Path $auditTrailPath -PathType Leaf) {
            foreach ($line in $auditLines) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                try { $evt = $trimmed | ConvertFrom-Json } catch { continue }

                if ($evt.Action -ne 'DisconnectedAppCertRun') { continue }

                $eventTime = $null
                if (-not [string]::IsNullOrWhiteSpace($evt.Timestamp)) {
                    try { $eventTime = [datetime]::Parse($evt.Timestamp).ToUniversalTime() }
                    catch { }
                }
                if ($null -eq $eventTime -or $eventTime -lt $ninetyDaysAgo) { continue }

                $accountCount = 0
                if ($null -ne $evt.PSObject.Properties['TotalAccounts']) {
                    $accountCount = [int]$evt.TotalAccounts
                }
                elseif ($null -ne $evt.PSObject.Properties['IdentitiesProcessed']) {
                    $accountCount = [int]$evt.IdentitiesProcessed
                }

                $trendData.Add(@{
                    Date  = $eventTime.ToString('yyyy-MM-dd')
                    Count = $accountCount
                })
            }
        }

        # ---------------------------------------------------------------
        # Build HTML
        # ---------------------------------------------------------------
        $sectionHeadingStyle = 'font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px; margin-top:24px; margin-bottom:12px; font-size:16px;'
        $labelTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; font-weight:bold; width:220px; background:#f4f4f4; vertical-align:top;'
        $valueTdStyle        = 'padding:7px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top;'
        $tableStyle          = 'width:100%; border-collapse:collapse; margin-bottom:18px; font-size:13px; font-family:-apple-system,''Segoe UI'',system-ui,sans-serif;'
        $badgeGreen          = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#339933;'
        $badgeRed            = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#CC3333;'
        $badgeOrange         = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#FF8800;'
        $badgeGray           = 'display:inline-block; padding:2px 8px; border-radius:3px; font-size:11px; font-weight:bold; color:#fff; background:#999999;'

        $html = [System.Text.StringBuilder]::new(16384)

        # Document shell
        [void]$html.AppendLine('<!DOCTYPE html>')
        [void]$html.AppendLine('<html lang="en">')
        [void]$html.AppendLine('<head>')
        [void]$html.AppendLine('    <meta charset="UTF-8">')
        [void]$html.AppendLine('    <meta name="viewport" content="width=device-width, initial-scale=1.0">')
        [void]$html.AppendLine("    <title>$(ConvertTo-DisconnectedHtmlSafe $AppName) - Team Dashboard</title>")
        [void]$html.AppendLine('</head>')
        [void]$html.AppendLine('<body style="font-family:-apple-system,''Segoe UI'',system-ui,sans-serif; margin:0; padding:24px; background:#f0f2f5; color:#333;">')
        [void]$html.AppendLine('<div style="max-width:900px; margin:0 auto; background:#fff; padding:32px 40px;">')

        # Header
        $safeAppName = ConvertTo-DisconnectedHtmlSafe $AppName
        [void]$html.AppendLine("<h1 style=`"font-family:-apple-system,'Segoe UI',system-ui,sans-serif; color:#2c3e50; margin-top:0; margin-bottom:4px; font-size:22px;`">$safeAppName - Team Dashboard</h1>")
        [void]$html.AppendLine("<p style=`"color:#777; font-size:13px; margin-top:0; margin-bottom:20px;`">Generated: $reportDate $reportTime UTC</p>")

        # ---------------------------------------------------------------
        # Section 1: Delivery Status (prominent)
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Today's Delivery Status</h2>")

        $deliveryBadge = switch ($deliveryStatus) {
            'Delivered' { "<span style=`"$badgeGreen`">DELIVERED</span>" }
            'Stale'     { "<span style=`"$badgeOrange`">STALE</span>" }
            'Missing'   { "<span style=`"$badgeRed`">MISSING</span>" }
            default     { "<span style=`"$badgeGray`">UNKNOWN</span>" }
        }

        [void]$html.AppendLine("<p style=`"margin-bottom:12px; font-size:18px;`">$deliveryBadge</p>")

        [void]$html.AppendLine("<table style=`"$tableStyle width:auto;`">")
        $deliveryRows = @(
            @('Status',        $deliveryStatus)
            @('Detail',        $deliveryDetail)
            @('Accounts',      $(if ($deliveryRowCount -gt 0) { $deliveryRowCount } else { '-' }))
            @('File Size',     $(if ($deliveryFileSize -gt 0) { "$([math]::Round($deliveryFileSize / 1KB, 1)) KB" } else { '-' }))
            @('Last Modified', $(if (-not [string]::IsNullOrWhiteSpace($deliveryLastMod)) { "$deliveryLastMod UTC" } else { '-' }))
        )
        foreach ($row in $deliveryRows) {
            $label = ConvertTo-DisconnectedHtmlSafe $row[0]
            $value = ConvertTo-DisconnectedHtmlSafe $row[1]
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        # ---------------------------------------------------------------
        # Section 2: Delta Summary
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Delta Summary (Latest Run: $deltaDate)</h2>")

        if ($latestCertRunFound) {
            $totalChanges = $deltaAdded + $deltaRemoved + $deltaEnabled + $deltaGranted + $deltaRevoked
            $changeBadge = if ($totalChanges -gt 0) {
                "<span style=`"$badgeOrange`">$totalChanges CHANGE(S)</span>"
            } else {
                "<span style=`"$badgeGreen`">NO CHANGES</span>"
            }
            [void]$html.AppendLine("<p style=`"margin-bottom:12px;`">$changeBadge</p>")

            [void]$html.AppendLine("<table style=`"$tableStyle width:auto;`">")
            $deltaRows = @(
                @('Accounts Added',         $deltaAdded)
                @('Accounts Removed',       $deltaRemoved)
                @('Accounts Enabled',       $deltaEnabled)
                @('Entitlements Granted',   $deltaGranted)
                @('Entitlements Revoked',   $deltaRevoked)
            )
            foreach ($row in $deltaRows) {
                $label = ConvertTo-DisconnectedHtmlSafe $row[0]
                $rawVal = $row[1]
                $valueColor = if ([int]$rawVal -gt 0) { 'color:#CC3333; font-weight:bold;' } else { '' }
                $value = ConvertTo-DisconnectedHtmlSafe $rawVal
                [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle $valueColor`">$value</td></tr>")
            }
            [void]$html.AppendLine('</table>')
        }
        else {
            [void]$html.AppendLine("<p style=`"color:#999;`">No certification runs recorded yet.</p>")
        }

        # ---------------------------------------------------------------
        # Section 3: Campaign Status (7-day window)
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Campaign Status (Last 7 Days)</h2>")

        [void]$html.AppendLine("<table style=`"$tableStyle width:auto;`">")
        $campaignRows = @(
            @('Created Today',      $campaignsToday)
            @('Total (7 days)',     $totalCampaigns7d)
            @('Pending Review',     $campaignsActive)
            @('Completed',          $campaignsCompleted)
        )
        foreach ($row in $campaignRows) {
            $label = ConvertTo-DisconnectedHtmlSafe $row[0]
            $value = ConvertTo-DisconnectedHtmlSafe $row[1]
            [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
        }
        [void]$html.AppendLine('</table>')

        # ---------------------------------------------------------------
        # Section 4: Remediation Queue
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">Remediation Queue</h2>")

        if ($remTotal -gt 0) {
            # Summary badges
            $remBadges = @()
            if ($remPending -gt 0)   { $remBadges += "<span style=`"$badgeOrange`">$remPending PENDING</span>" }
            if ($remOverdue -gt 0)   { $remBadges += "<span style=`"$badgeRed`">$remOverdue OVERDUE</span>" }
            if ($remEscalated -gt 0) { $remBadges += "<span style=`"$badgeRed`">$remEscalated ESCALATED</span>" }
            if ($remConfirmed -gt 0) { $remBadges += "<span style=`"$badgeGreen`">$remConfirmed CONFIRMED</span>" }
            if ($remBadges.Count -eq 0) { $remBadges += "<span style=`"$badgeGray`">$remTotal TOTAL</span>" }
            [void]$html.AppendLine("<p style=`"margin-bottom:12px;`">$($remBadges -join ' ')</p>")

            # Summary table
            [void]$html.AppendLine("<table style=`"$tableStyle width:auto;`">")
            $remRows = @(
                @('Pending',    $remPending)
                @('Overdue',    $remOverdue)
                @('Escalated',  $remEscalated)
                @('Confirmed',  $remConfirmed)
                @('Total',      $remTotal)
            )
            foreach ($row in $remRows) {
                $label = ConvertTo-DisconnectedHtmlSafe $row[0]
                $value = ConvertTo-DisconnectedHtmlSafe $row[1]
                [void]$html.AppendLine("<tr><td style=`"$labelTdStyle`">$label</td><td style=`"$valueTdStyle`">$value</td></tr>")
            }
            [void]$html.AppendLine('</table>')

            # Overdue details table (red highlight)
            if ($overdueRecords.Count -gt 0) {
                [void]$html.AppendLine("<h3 style=`"color:#CC3333; font-size:14px; margin-top:16px; margin-bottom:8px;`">Overdue Remediations ($($overdueRecords.Count))</h3>")
                [void]$html.AppendLine("<table style=`"$tableStyle`">")
                [void]$html.AppendLine((Build-DisconnectedHtmlHeader -Headers @('Identity', 'Entitlement', 'Decision Date', 'Days Overdue')))

                $odIdx = 0
                foreach ($od in $overdueRecords) {
                    $identity = if ($null -ne $od.IdentityName) { ConvertTo-DisconnectedHtmlSafe $od.IdentityName }
                                elseif ($null -ne $od.AccountId) { ConvertTo-DisconnectedHtmlSafe $od.AccountId }
                                else { '-' }
                    $entitlement = if ($null -ne $od.Entitlement) { ConvertTo-DisconnectedHtmlSafe $od.Entitlement } else { '-' }
                    $decDate = if ($null -ne $od.DecisionDate) { ConvertTo-DisconnectedHtmlSafe ([string]$od.DecisionDate).Substring(0, 10) } else { '-' }
                    $daysOverdue = '-'
                    if ($null -ne $od.DaysOverdue) { $daysOverdue = ConvertTo-DisconnectedHtmlSafe $od.DaysOverdue }
                    elseif ($null -ne $od.DecisionDate) {
                        try {
                            $ddParsed = [datetime]::Parse([string]$od.DecisionDate).ToUniversalTime()
                            $daysOverdue = [math]::Max(0, [int]((Get-Date).ToUniversalTime() - $ddParsed).TotalDays)
                        }
                        catch { }
                    }

                    $odBg = if (($odIdx % 2) -eq 1) { 'background:#f9f9f9;' } else { '' }
                    $odTdStyle = "padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; $odBg"
                    $odTdRedStyle = "padding:8px 10px; border-bottom:1px solid #e0e0e0; vertical-align:top; color:#CC3333; font-weight:bold; $odBg"

                    [void]$html.AppendLine("<tr>")
                    [void]$html.AppendLine("  <td style=`"$odTdStyle`">$identity</td>")
                    [void]$html.AppendLine("  <td style=`"$odTdStyle`">$entitlement</td>")
                    [void]$html.AppendLine("  <td style=`"$odTdStyle`">$decDate</td>")
                    [void]$html.AppendLine("  <td style=`"$odTdRedStyle`">$daysOverdue</td>")
                    [void]$html.AppendLine('</tr>')
                    $odIdx++
                }
                [void]$html.AppendLine('</table>')
            }
        }
        else {
            [void]$html.AppendLine("<p style=`"color:#999;`">No remediation records. Revocations from completed campaigns will appear here.</p>")
        }

        # ---------------------------------------------------------------
        # Section 5: SLA Compliance (30-day delivery calendar)
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">SLA Compliance - 30 Day Delivery</h2>")

        $slaBadge = if ($slaCompliant) {
            "<span style=`"$badgeGreen`">COMPLIANT</span>"
        } else {
            "<span style=`"$badgeRed`">NON-COMPLIANT</span>"
        }
        [void]$html.AppendLine("<p style=`"margin-bottom:8px;`">$slaBadge Delivery Rate: <strong>${slaDeliveryRate}%</strong> ($deliveredInWindow / $($calendarDates.Count) days)</p>")

        # Calendar grid: 7 columns x ~5 rows using a table
        [void]$html.AppendLine("<table style=`"border-collapse:collapse; margin-bottom:18px;`">")
        # Weekday headers
        [void]$html.AppendLine('<tr>')
        $weekdays = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
        foreach ($wd in $weekdays) {
            [void]$html.AppendLine("  <td style=`"width:36px; padding:2px 4px; text-align:center; font-size:10px; color:#999; font-weight:bold;`">$wd</td>")
        }
        [void]$html.AppendLine('</tr>')

        # Determine starting day-of-week offset for first date
        $firstDate = [datetime]::ParseExact($calendarDates[0], 'yyyy-MM-dd', $null)
        # Monday=0 ... Sunday=6
        $startDow = ([int]$firstDate.DayOfWeek + 6) % 7

        # Pad leading empty cells
        [void]$html.AppendLine('<tr>')
        for ($pad = 0; $pad -lt $startDow; $pad++) {
            [void]$html.AppendLine("  <td style=`"width:36px; height:28px;`"></td>")
        }

        $cellIdx = $startDow
        foreach ($cd in $calendarDates) {
            $dayNum = $cd.Substring(8, 2)
            $isToday = ($cd -eq $today.ToString('yyyy-MM-dd'))

            if ($deliveredSet.Contains($cd)) {
                $cellBg = '#339933'
                $cellColor = '#fff'
            }
            elseif ([datetime]::ParseExact($cd, 'yyyy-MM-dd', $null) -gt $today) {
                $cellBg = '#e9ecef'
                $cellColor = '#999'
            }
            else {
                $cellBg = '#CC3333'
                $cellColor = '#fff'
            }

            $borderStyle = if ($isToday) { 'border:2px solid #336699;' } else { 'border:1px solid #dee2e6;' }

            [void]$html.AppendLine("  <td style=`"width:36px; height:28px; text-align:center; font-size:11px; background:$cellBg; color:$cellColor; $borderStyle`">$dayNum</td>")

            $cellIdx++
            if ($cellIdx % 7 -eq 0) {
                [void]$html.AppendLine('</tr>')
                [void]$html.AppendLine('<tr>')
            }
        }

        # Close trailing row
        $remainingCells = 7 - ($cellIdx % 7)
        if ($remainingCells -lt 7) {
            for ($pad = 0; $pad -lt $remainingCells; $pad++) {
                [void]$html.AppendLine("  <td style=`"width:36px; height:28px;`"></td>")
            }
        }
        [void]$html.AppendLine('</tr>')
        [void]$html.AppendLine('</table>')

        # Calendar legend
        [void]$html.AppendLine("<p style=`"font-size:11px; color:#777; margin-top:2px;`">")
        [void]$html.AppendLine("  <span style=`"display:inline-block; width:12px; height:12px; background:#339933; vertical-align:middle;`"></span> Delivered ")
        [void]$html.AppendLine("  <span style=`"display:inline-block; width:12px; height:12px; background:#CC3333; vertical-align:middle; margin-left:8px;`"></span> Missing ")
        [void]$html.AppendLine("  <span style=`"display:inline-block; width:12px; height:12px; background:#e9ecef; vertical-align:middle; margin-left:8px;`"></span> Future")
        [void]$html.AppendLine('</p>')

        # ---------------------------------------------------------------
        # Section 6: 90-Day Trend Sparkline (CSS bar chart)
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<h2 style=`"$sectionHeadingStyle`">90-Day Account Trend</h2>")

        if ($trendData.Count -gt 0) {
            $maxCount = ($trendData | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
            if ($maxCount -eq 0) { $maxCount = 1 }

            $chartHeight = 80

            [void]$html.AppendLine("<div style=`"display:table; width:100%; height:${chartHeight}px; margin-bottom:4px; border-bottom:1px solid #dee2e6;`">")

            $barWidth = [math]::Max(2, [math]::Floor(700 / [math]::Max(1, $trendData.Count)))
            if ($barWidth -gt 12) { $barWidth = 12 }

            foreach ($point in $trendData) {
                $barHeightPx = [math]::Max(2, [math]::Round(($point.Count / $maxCount) * $chartHeight))
                $topPad = $chartHeight - $barHeightPx

                [void]$html.AppendLine("  <div style=`"display:table-cell; vertical-align:bottom; width:${barWidth}px; padding:0 1px;`"><div style=`"width:${barWidth}px; height:${barHeightPx}px; background:#336699;`" title=`"$(ConvertTo-DisconnectedHtmlSafe $point.Date): $($point.Count) accounts`"></div></div>")
            }

            [void]$html.AppendLine('</div>')

            # Labels: first and last date
            $firstTrendDate = $trendData[0].Date
            $lastTrendDate  = $trendData[$trendData.Count - 1].Date
            $latestCount    = $trendData[$trendData.Count - 1].Count
            [void]$html.AppendLine("<p style=`"font-size:11px; color:#777; margin-top:2px;`">$firstTrendDate to $lastTrendDate | Latest: <strong>$latestCount</strong> accounts | Peak: <strong>$maxCount</strong></p>")
        }
        else {
            [void]$html.AppendLine("<p style=`"color:#999;`">No trend data available. Account counts will appear after certification runs are recorded.</p>")
        }

        # ---------------------------------------------------------------
        # Footer
        # ---------------------------------------------------------------
        [void]$html.AppendLine("<hr style=`"border:none; border-top:1px solid #dee2e6; margin-top:32px;`">")
        [void]$html.AppendLine("<p style=`"color:#999; font-size:11px; margin-top:8px;`">Generated by SailPoint Governance Toolkit - Team Dashboard | $reportDate $reportTime UTC | CorrelationID: $(ConvertTo-DisconnectedHtmlSafe $CorrelationID)</p>")
        [void]$html.AppendLine("<p style=`"color:#bbb; font-size:10px;`">This dashboard refreshes after each batch run. Open in any browser -- no PowerShell required.</p>")

        # Close document
        [void]$html.AppendLine('</div>')
        [void]$html.AppendLine('</body>')
        [void]$html.AppendLine('</html>')

        # Write file (UTF-8 no BOM)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($filePath, $html.ToString(), $utf8NoBom)

        Write-SPLog -Message "Team dashboard generated for '$AppName' at $filePath" `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{ FilePath = $filePath }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Export-SPDisconnectedAppTeamDashboard failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component $component `
            -Action $action -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Export-SPDisconnectedAppDeltaHtml',
    'Export-SPDisconnectedAppIdentityRiskHtml',
    'Export-SPDisconnectedAppEntitlementCatalogHtml',
    'Export-SPDisconnectedAppBatchHtml',
    'Export-SPDisconnectedAppSlaHtml',
    'Export-SPDisconnectedAppDecisionHarvestHtml',
    'Export-SPDisconnectedAppTeamDashboard'
)

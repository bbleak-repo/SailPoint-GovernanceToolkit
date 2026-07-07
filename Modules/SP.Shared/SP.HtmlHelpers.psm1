#Requires -Version 5.1
<#
.SYNOPSIS
    SP.HtmlHelpers -- shared HTML utility functions for all toolkit report modules.
.DESCRIPTION
    Consolidates duplicate helper patterns that were independently implemented across
    SP.CampaignDiff, SP.AuditReportHtml, SP.CertTracker, SP.CampaignVelocity,
    SP.DisconnectedAppReports, and the daily evidence scripts (V1-V4).

    Functions:
        ConvertTo-SPHtmlSafe   - HTML-encode a value safely (null-tolerant)
        Format-SPHtmlDate      - Parse and format a date string for HTML display
        Get-SPObjectProperty   - Read a property from hashtable or PSCustomObject
        Get-SPHtmlColorPalette - Standard color palette for HTML reports
        New-SPHtmlDocument     - StringBuilder with DOCTYPE/head/CSS boilerplate
        Write-SPHtmlFile       - Write string content to a UTF-8 no-BOM file

    No dependencies on SP.Core, SP.Api, or any other toolkit module.

.NOTES
    Module: SP.Shared / SP.HtmlHelpers
    Version: 1.0.0
#>

Set-StrictMode -Version 1

#region HTML Encoding

function ConvertTo-SPHtmlSafe {
    <#
    .SYNOPSIS
        HTML-encodes a value for safe embedding in markup.
    .DESCRIPTION
        Converts the input to a string and applies System.Net.WebUtility.HtmlEncode.
        Returns an empty string for null or whitespace-only input rather than throwing.
    .PARAMETER Value
        The value to encode. Accepts any type; will be cast to [string].
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

#endregion

#region Date Formatting

function Format-SPHtmlDate {
    <#
    .SYNOPSIS
        Parses and formats a date string for HTML display.
    .DESCRIPTION
        Attempts to parse the input as a datetime and returns 'yyyy-MM-dd HH:mm'.
        On parse failure, returns the raw input string. On null/empty, returns ''.
        Use -AsDateTime to return a [datetime] object (or $null) instead of a
        formatted string -- this replaces the ConvertTo-CTDate pattern.
    .PARAMETER DateString
        The date string to parse and format.
    .PARAMETER AsDateTime
        When set, returns the parsed [datetime] object or $null instead of a
        formatted string. Useful for date arithmetic (e.g. CertTracker pace).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$DateString,

        [Parameter()]
        [switch]$AsDateTime
    )

    if ([string]::IsNullOrWhiteSpace($DateString)) {
        if ($AsDateTime) { return $null }
        return ''
    }
    try {
        $dt = [datetime]::Parse($DateString)
        if ($AsDateTime) { return $dt }
        return $dt.ToString('yyyy-MM-dd HH:mm')
    }
    catch {
        if ($AsDateTime) { return $null }
        return $DateString
    }
}

#endregion

#region Property Access

function Get-SPObjectProperty {
    <#
    .SYNOPSIS
        Reads a named property from either a hashtable/ordered-dict or a PSCustomObject.
    .DESCRIPTION
        Snapshots arrive as [ordered] hashtables when freshly built in-memory and as
        PSCustomObjects when round-tripped through JSON on disk. This function reads
        the named property from either shape, returning $Default when the member is
        absent or null.
    .PARAMETER Object
        The hashtable or PSCustomObject to read from.
    .PARAMETER Name
        The property/key name.
    .PARAMETER Default
        Value to return when the property is absent or null. Defaults to $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [object]$Object,

        [Parameter()]
        [string]$Name,

        [Parameter()]
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    try {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                $v = $Object[$Name]
                if ($null -ne $v) { return $v }
            }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    } catch { }
    return $Default
}

#endregion

#region Color Palette

function Get-SPHtmlColorPalette {
    <#
    .SYNOPSIS
        Returns the standard color palette used across toolkit HTML reports.
    .DESCRIPTION
        Provides a consistent set of named colors. Uses the modern palette
        (#0a7d2c green, #b00020 red, #9a6700 amber) adopted by CampaignDiff,
        CertTracker, and CampaignTrend modules.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        Green  = '#0a7d2c'
        Red    = '#b00020'
        Amber  = '#9a6700'
        Blue   = '#336699'
        Dark   = '#1f3a5f'
        Gray   = '#777777'
        LightRedBg   = '#fdecec'
        DarkRedText  = '#7a0014'
        LightAmberBg = '#fff7e6'
        DarkAmberText = '#7a5a00'
        LightGrayBg  = '#f6f9fc'
        Border       = '#d4dce6'
    }
}

#endregion

#region HTML Document Scaffolding

function New-SPHtmlDocument {
    <#
    .SYNOPSIS
        Creates a StringBuilder pre-loaded with a standard HTML document head.
    .DESCRIPTION
        Returns a System.Text.StringBuilder containing the DOCTYPE, html/head
        with charset, viewport meta, title, and embedded CSS. The caller appends
        body content and closes with </body></html>.
    .PARAMETER Title
        The HTML document title.
    .PARAMETER Css
        Optional CSS string to embed. If omitted, a sensible default for
        Word-compatible table-based reports is used.
    #>
    [CmdletBinding()]
    [OutputType([System.Text.StringBuilder])]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter()]
        [string]$Css
    )

    if ([string]::IsNullOrWhiteSpace($Css)) {
        $Css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;background:#ffffff;}
h1{font-size:20px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;margin-bottom:4px;}
h2{font-size:15px;color:#1f3a5f;margin-top:26px;border-bottom:1px solid #d4dce6;padding-bottom:4px;}
.meta{color:#566;font-size:12px;margin-bottom:8px;}
table{border-collapse:collapse;width:100%;margin-top:8px;font-size:12px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 8px;font-weight:600;}
td{border-bottom:1px solid #e3e9f0;padding:5px 8px;vertical-align:top;}
tr:nth-child(even) td{background:#f6f9fc;}
.kpi{display:inline-block;min-width:120px;margin:6px 10px 6px 0;padding:10px 14px;border:1px solid #d4dce6;border-radius:6px;background:#f6f9fc;}
.kpi .n{font-size:22px;font-weight:700;color:#1f3a5f;display:block;}
.kpi .l{font-size:11px;color:#566;text-transform:uppercase;letter-spacing:.04em;}
.note{font-size:11px;color:#777;margin-top:4px;}
'@
    }

    $sb = New-Object System.Text.StringBuilder 8192
    [void]$sb.Append("<!DOCTYPE html><html><head><meta charset='utf-8'>")
    [void]$sb.Append("<meta name='viewport' content='width=device-width,initial-scale=1'>")
    [void]$sb.Append("<title>$(ConvertTo-SPHtmlSafe $Title)</title>")
    [void]$sb.Append("<style>$Css</style></head><body>")
    return $sb
}

#endregion

#region File Writing

function Write-SPHtmlFile {
    <#
    .SYNOPSIS
        Writes content to a file using UTF-8 encoding without a BOM.
    .DESCRIPTION
        Wraps [System.IO.File]::WriteAllText with UTF8Encoding($false) to produce
        clean UTF-8 files without the byte-order mark. Creates parent directories
        if they do not exist.
    .PARAMETER Path
        The output file path.
    .PARAMETER Content
        The string content to write (typically from a StringBuilder.ToString()).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

#endregion

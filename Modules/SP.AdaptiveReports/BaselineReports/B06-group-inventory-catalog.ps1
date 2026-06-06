<#
.SYNOPSIS
    B06 - Group Inventory / Catalog (BASELINE report module)

.DESCRIPTION
    Parameterized product module. Accepts group results via -GroupResults and
    emits one HTML row per group: the baseline directory inventory auditors use
    to spot groups with no members or anomalous structure.

    Account treatment: numbers-only. No individual account identities are
    rendered anywhere in this report; member information is reduced to direct
    counts and derived hygiene flags only.

    Column order follows the spec: identity first (GroupName, Domain), then
    structural fields (IsNested, Skipped), then metric fields (MemberCount),
    then risk/flag fields last (IsEmpty, NoMembers).

.NOTES
    Readable / auditable by design (no encoded or hidden PowerShell).
    Self-contained: dot-sources nothing; no hardcoded input/output paths.
#>

function ConvertTo-B06HtmlText {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s.Replace('&', '&amp;')
    $s = $s.Replace('<', '&lt;')
    $s = $s.Replace('>', '&gt;')
    $s = $s.Replace('"', '&quot;')
    $s = $s.Replace("'", '&#39;')
    return $s
}

function Get-B06Prop {
    # Safe property accessor that tolerates missing members under StrictMode.
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    # Dual-mode: -FromCache passes hashtables; live enumeration passes objects.
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-B06BoolBadge {
    param([bool]$Value, [bool]$YesIsBad = $true)
    if ($Value) {
        $cls = if ($YesIsBad) { 'yes' } else { 'no' }
        return ('<span class="badge {0}">Yes</span>' -f $cls)
    } else {
        return '<span class="badge no">No</span>'
    }
}

function Export-GroupInventoryCatalogReport {
    <#
    .SYNOPSIS
        Writes a B06 Group Inventory / Catalog HTML report: one row per group
        with structural and hygiene metadata (numbers-only; no account identities).

    .PARAMETER GroupResults
        Array of group result objects with shape:
        @{ Data = @{ Domain; GroupName; MemberCount; IsNested; Skipped;
                     Members = @(@{ SamAccountName; DisplayName; Email; Enabled }) };
           Errors = @() }

    .PARAMETER OutputPath
        Destination .html file path.

    .PARAMETER Title
        Optional report title override.

    .PARAMETER Theme
        'dark' (default) or 'light'. Controls the colour palette.

    .OUTPUTS
        The output path (string).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$GroupResults,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [Parameter()][string]$Title = 'Group Inventory / Catalog',

        [Parameter()][ValidateSet('dark', 'light')][string]$Theme = 'dark'
    )

    Set-StrictMode -Version 2.0

    # Hygiene threshold: a group at/below this direct count is flagged IsEmpty.
    $EmptyMemberThreshold = 0

    # -----------------------------------------------------------------------
    # Build one inventory record per group
    # -----------------------------------------------------------------------
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($g in $GroupResults) {
        $data = Get-B06Prop $g 'Data'
        if ($null -eq $data) { continue }

        $domain    = Get-B06Prop $data 'Domain'
        $groupName = Get-B06Prop $data 'GroupName'
        $isNested  = Get-B06Prop $data 'IsNested'
        $skipped   = Get-B06Prop $data 'Skipped'

        # Direct member count: prefer the recorded MemberCount, fall back to
        # the length of the Members array so the catalog stays accurate even
        # if the stored count is absent.
        $memberCount = Get-B06Prop $data 'MemberCount'
        $members     = Get-B06Prop $data 'Members'
        $directCount = $null
        if ($null -ne $memberCount) {
            $directCount = [int]$memberCount
        } elseif ($null -ne $members) {
            $directCount = @($members).Count
        } else {
            $directCount = 0
        }

        # Normalise structural fields for display.
        $isNestedDisplay = if ($null -eq $isNested) { 'Unknown' } elseif ([bool]$isNested) { 'Yes' } else { 'No' }
        $skippedBool     = if ($null -eq $skipped) { $false } else { [bool]$skipped }

        # Derived hygiene flags.
        $noMembers = ($directCount -le 0)
        $isEmpty   = ($directCount -le $EmptyMemberThreshold)

        $flagged = ($isEmpty -or $noMembers -or $skippedBool)

        $rows.Add([pscustomobject]@{
            GroupName       = [string]$groupName
            Domain          = [string]$domain
            IsNestedDisplay = $isNestedDisplay
            Skipped         = $skippedBool
            MemberCount     = $directCount
            IsEmpty         = $isEmpty
            NoMembers       = $noMembers
            Flagged         = $flagged
        })
    }

    # Stable, auditor-friendly sort: domain then group name.
    $sorted = $rows | Sort-Object Domain, GroupName

    $total        = @($sorted).Count
    $flaggedCount = @($sorted | Where-Object { $_.Flagged }).Count
    $clean        = $total - $flaggedCount

    # -----------------------------------------------------------------------
    # Colour palette
    # -----------------------------------------------------------------------
    if ($Theme -eq 'light') {
        $cssPalette = @'
:root { color-scheme: light; }
* { box-sizing: border-box; }
body { font-family: Segoe UI, Tahoma, Arial, sans-serif; margin: 0; padding: 24px;
       background: #f5f6f8; color: #1f2430; font-size: 14px; }
.title-block { background: #1f2933; color: #fff; padding: 18px 22px; border-radius: 8px 8px 0 0; }
.title-block h1 { margin: 0 0 4px 0; font-size: 20px; }
.title-block .subtitle { color: #c8d0d8; font-size: 13px; margin: 0 0 12px 0; }
.meta { display: flex; flex-wrap: wrap; gap: 8px 28px; font-size: 12.5px; color: #d7dee5; }
.meta div span.k { color: #8fa3b3; }
.panel { background: #fff; border: 1px solid #d9dee3; border-top: none;
         border-radius: 0 0 8px 8px; overflow: hidden; }
table { border-collapse: collapse; width: 100%; }
thead th { background: #eef1f4; text-align: left; padding: 9px 12px; font-size: 12px;
           text-transform: uppercase; letter-spacing: .03em; color: #44505c;
           border-bottom: 2px solid #d0d7de; white-space: nowrap; }
tbody td { padding: 8px 12px; border-bottom: 1px solid #eceff2; }
tbody tr:nth-child(even) { background: #fafbfc; }
tbody tr.flagged { background: #fff6f4; }
tbody tr.flagged:nth-child(even) { background: #fdeeea; }
.num { text-align: right; font-variant-numeric: tabular-nums; }
.col-group-headers th.struct { background: #e7ecf1; }
.col-group-headers th.metric { background: #e3eef0; }
.col-group-headers th.flag { background: #f3e8ea; }
.badge { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 11.5px;
         font-weight: 600; }
.badge.yes { background: #fde2dd; color: #9b1c0c; }
.badge.no { background: #e3efe3; color: #1e6b2c; }
.badge.neutral { background: #e6eaef; color: #45525f; }
.footer { padding: 12px 16px; background: #eef1f4; border-top: 1px solid #d0d7de;
          font-size: 13px; color: #2a323c; border-radius: 0 0 8px 8px; }
.footer strong { color: #1f2933; }
.legend { margin: 14px 2px 0; font-size: 12px; color: #5b6671; }
'@
    } else {
        # dark (default) — matches source exactly
        $cssPalette = @'
:root { color-scheme: light; }
* { box-sizing: border-box; }
body { font-family: Segoe UI, Tahoma, Arial, sans-serif; margin: 0; padding: 24px;
       background: #f5f6f8; color: #1f2430; font-size: 14px; }
.title-block { background: #1f2933; color: #fff; padding: 18px 22px; border-radius: 8px 8px 0 0; }
.title-block h1 { margin: 0 0 4px 0; font-size: 20px; }
.title-block .subtitle { color: #c8d0d8; font-size: 13px; margin: 0 0 12px 0; }
.meta { display: flex; flex-wrap: wrap; gap: 8px 28px; font-size: 12.5px; color: #d7dee5; }
.meta div span.k { color: #8fa3b3; }
.panel { background: #fff; border: 1px solid #d9dee3; border-top: none;
         border-radius: 0 0 8px 8px; overflow: hidden; }
table { border-collapse: collapse; width: 100%; }
thead th { background: #eef1f4; text-align: left; padding: 9px 12px; font-size: 12px;
           text-transform: uppercase; letter-spacing: .03em; color: #44505c;
           border-bottom: 2px solid #d0d7de; white-space: nowrap; }
tbody td { padding: 8px 12px; border-bottom: 1px solid #eceff2; }
tbody tr:nth-child(even) { background: #fafbfc; }
tbody tr.flagged { background: #fff6f4; }
tbody tr.flagged:nth-child(even) { background: #fdeeea; }
.num { text-align: right; font-variant-numeric: tabular-nums; }
.col-group-headers th.struct { background: #e7ecf1; }
.col-group-headers th.metric { background: #e3eef0; }
.col-group-headers th.flag { background: #f3e8ea; }
.badge { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 11.5px;
         font-weight: 600; }
.badge.yes { background: #fde2dd; color: #9b1c0c; }
.badge.no { background: #e3efe3; color: #1e6b2c; }
.badge.neutral { background: #e6eaef; color: #45525f; }
.footer { padding: 12px 16px; background: #eef1f4; border-top: 1px solid #d0d7de;
          font-size: 13px; color: #2a323c; border-radius: 0 0 8px 8px; }
.footer strong { color: #1f2933; }
.legend { margin: 14px 2px 0; font-size: 12px; color: #5b6671; }
'@
    }

    # -----------------------------------------------------------------------
    # Render HTML
    # -----------------------------------------------------------------------
    $asOf   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    $tEsc   = ConvertTo-B06HtmlText $Title

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine(('<title>{0}</title>' -f $tEsc))
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine($cssPalette)
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')

    # Title block
    [void]$sb.AppendLine('<div class="title-block">')
    [void]$sb.AppendLine(('<h1>{0}</h1>' -f $tEsc))
    [void]$sb.AppendLine('<p class="subtitle">Baseline directory inventory &mdash; one row per group with structural and hygiene metadata (numbers-only).</p>')
    [void]$sb.AppendLine('<div class="meta">')
    [void]$sb.AppendLine(('<div><span class="k">As of:</span> {0}</div>' -f (ConvertTo-B06HtmlText $asOf)))
    [void]$sb.AppendLine(('<div><span class="k">Threshold (IsEmpty):</span> direct members &le; {0}</div>' -f $EmptyMemberThreshold))
    [void]$sb.AppendLine('<div><span class="k">Threshold (NoMembers):</span> direct members = 0</div>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</div>')

    # Table
    [void]$sb.AppendLine('<div class="panel">')
    [void]$sb.AppendLine('<table>')
    [void]$sb.AppendLine('<thead>')
    # Grouping header row to make the identity/structural/metric/flag bands explicit.
    [void]$sb.AppendLine('<tr class="col-group-headers">')
    [void]$sb.AppendLine('<th colspan="2">Identity</th>')
    [void]$sb.AppendLine('<th colspan="2" class="struct">Structural</th>')
    [void]$sb.AppendLine('<th colspan="1" class="metric">Metric</th>')
    [void]$sb.AppendLine('<th colspan="2" class="flag">Risk / Flags</th>')
    [void]$sb.AppendLine('</tr>')
    [void]$sb.AppendLine('<tr>')
    [void]$sb.AppendLine('<th>GroupName</th>')
    [void]$sb.AppendLine('<th>Domain</th>')
    [void]$sb.AppendLine('<th>IsNested</th>')
    [void]$sb.AppendLine('<th>Skipped</th>')
    [void]$sb.AppendLine('<th class="num">MemberCount (direct)</th>')
    [void]$sb.AppendLine('<th>IsEmpty</th>')
    [void]$sb.AppendLine('<th>NoMembers</th>')
    [void]$sb.AppendLine('</tr>')
    [void]$sb.AppendLine('</thead>')
    [void]$sb.AppendLine('<tbody>')

    foreach ($r in $sorted) {
        $rowCls = if ($r.Flagged) { ' class="flagged"' } else { '' }

        $nestedBadge =
            if ($r.IsNestedDisplay -eq 'Unknown') { '<span class="badge neutral">Unknown</span>' }
            elseif ($r.IsNestedDisplay -eq 'Yes')  { '<span class="badge neutral">Yes</span>' }
            else                                    { '<span class="badge neutral">No</span>' }

        [void]$sb.AppendLine(('<tr{0}>' -f $rowCls))
        [void]$sb.AppendLine(('<td class="group-name">{0}</td>' -f (ConvertTo-B06HtmlText $r.GroupName)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-B06HtmlText $r.Domain)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f $nestedBadge))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (Get-B06BoolBadge -Value $r.Skipped -YesIsBad $true)))
        [void]$sb.AppendLine(('<td class="num">{0}</td>' -f $r.MemberCount))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (Get-B06BoolBadge -Value $r.IsEmpty -YesIsBad $true)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (Get-B06BoolBadge -Value $r.NoMembers -YesIsBad $true)))
        [void]$sb.AppendLine('</tr>')
    }

    [void]$sb.AppendLine('</tbody>')
    [void]$sb.AppendLine('</table>')

    # Row-count footer
    [void]$sb.AppendLine('<div class="footer">')
    [void]$sb.AppendLine(('<strong>Total: {0} groups</strong> | Flagged: {1} | Clean: {2}' -f $total, $flaggedCount, $clean))
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<p class="legend">Numbers-only report: member detail is reduced to direct counts and hygiene flags; no individual account identities are listed. A group is <em>Flagged</em> when IsEmpty, NoMembers, or Skipped is Yes.</p>')

    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')

    # -----------------------------------------------------------------------
    # Write output (UTF-8, no BOM)
    # -----------------------------------------------------------------------
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), $utf8NoBom)

    return $OutputPath
}

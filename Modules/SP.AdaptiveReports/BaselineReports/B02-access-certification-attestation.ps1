<#
.SYNOPSIS
    B02 - Access Certification / UAR Sign-off Sheet
    -----------------------------------------------
    Parameterized BASELINE report generator module.

    Subject ........... per-group membership rendered as a reviewer
                        attestation worksheet.
    accountTreatment .. full-list  (EVERY member is rendered as one
                        certifiable row -- no sampling, no collapsing)
    Presentation ...... attestation cover sheet (scope, review period,
                        control owner, attestation statement, signature
                        line) followed by a group-sectioned roster with
                        empty annotation columns:
                          - Reviewer Decision (Approve / Revoke / Escalate)
                          - Justification
                          - Review Date
                          - Reviewer Name
                        Account Status surfaced per row. Rows within each
                        group sorted disabled-first, then by display name.
                        Color cues for disabled members are also encoded
                        with a glyph + bold weight so they remain legible
                        when printed in greyscale.

    Objective: the formal sign-off artifact auditors sample from. One
    certifiable row per entitlement with a three-value decision column and
    a mandatory justification field, plus an attestation cover page.
    "If it is not documented, auditors treat it as never happened."

    This module dot-sources NOTHING and does not modify any existing repo file.
#>

# Auto-import SP.Shared if Get-SPObjectProperty is not yet available.
if (-not (Get-Command Get-SPObjectProperty -ErrorAction Ignore)) {
    $_spSharedPsd1 = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'SP.Shared\SP.Shared.psd1'
    if (Test-Path $_spSharedPsd1) { Import-Module $_spSharedPsd1 -Global -ErrorAction SilentlyContinue -DisableNameChecking }
}

function ConvertTo-B02PSObject {
    # Normalize the -FromCache hashtable shape (and nested members) to
    # PSCustomObjects so the PSObject-based property checks below work for both
    # cache (hashtable) and live (object) inputs.
    param([object]$InputObject)
    if ($InputObject -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($k in $InputObject.Keys) { $ht[[string]$k] = ConvertTo-B02PSObject $InputObject[$k] }
        return [pscustomobject]$ht
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        return @(foreach ($item in $InputObject) { ConvertTo-B02PSObject $item })
    }
    return $InputObject
}

function Export-AccessCertificationAttestationReport {
    <#
    .SYNOPSIS
        Writes an Access Certification / UAR Sign-off Sheet HTML report.

    .DESCRIPTION
        Renders a full-list attestation worksheet: one certifiable row per
        entitlement, with Reviewer Decision, Justification, Review Date, and
        Reviewer Name columns for manual completion. Includes an attestation
        cover sheet with scope metadata and signature lines.

    .PARAMETER GroupResults
        Array of @{ Data = @{ Domain; GroupName; MemberCount; IsNested; Skipped;
        Members = @(@{ SamAccountName; DisplayName; Email; Enabled }) }; Errors = @() }.

    .PARAMETER OutputPath
        Destination .html path. Parent directory is created if absent.

    .PARAMETER Title
        Optional report title override.

    .PARAMETER Theme
        'dark' (default) or 'light'. Note: this report uses a print-optimised
        light stylesheet regardless of theme; the parameter is accepted for
        contract compatibility.

    .OUTPUTS
        The resolved output path (string).
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

        [Parameter()][string]$Title,

        [Parameter()][ValidateSet('dark', 'light')][string]$Theme = 'dark'
    )

    # --- Helpers --------------------------------------------------------------
    function ConvertTo-B02HtmlSafe {
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

    function ConvertTo-B02Bool {
        # Tolerant coercion: $true/'true'/'True'/'1' -> true; everything else false.
        param([object]$Value)
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $Value }
        $s = ([string]$Value).Trim()
        if ($s -eq '') { return $false }
        return ($s -ieq 'true' -or $s -eq '1')
    }

    function Get-B02Prop {
        param([object]$Obj, [string]$Name, [object]$Default = $null)
        Get-SPObjectProperty -Object $Obj -Name $Name -Default $Default
    }

    # --- Build per-group certifiable rosters ----------------------------------
    # accountTreatment = full-list : EVERY member becomes exactly one row.
    $sections = New-Object System.Collections.Generic.List[object]

    $grandRows     = 0
    $grandEnabled  = 0
    $grandDisabled = 0

    foreach ($entry in $GroupResults) {
        if ($null -eq $entry) { continue }
        $entry = ConvertTo-B02PSObject $entry
        $d = $entry
        if ($entry.PSObject.Properties.Name -contains 'Data' -and $null -ne $entry.Data) { $d = $entry.Data }
        if ($null -eq $d) { continue }

        $domain    = [string](Get-B02Prop $d 'Domain'    '')
        $groupName = [string](Get-B02Prop $d 'GroupName' '')
        $isNested  = ConvertTo-B02Bool (Get-B02Prop $d 'IsNested' $false)
        $skipped   = ConvertTo-B02Bool (Get-B02Prop $d 'Skipped'  $false)

        $declaredCount = 0
        $dc = Get-B02Prop $d 'MemberCount' $null
        if ($null -ne $dc) { [int]::TryParse([string]$dc, [ref]$declaredCount) | Out-Null }

        # Materialize every member row (full-list treatment).
        $memberRows = New-Object System.Collections.Generic.List[object]
        $members = Get-B02Prop $d 'Members' $null
        if ($null -ne $members) {
            foreach ($m in $members) {
                if ($null -eq $m) { continue }
                $enabled = ConvertTo-B02Bool (Get-B02Prop $m 'Enabled' $false)
                $memberRows.Add([pscustomobject]@{
                    SamAccountName = [string](Get-B02Prop $m 'SamAccountName' '')
                    DisplayName    = [string](Get-B02Prop $m 'DisplayName'    '')
                    Email          = [string](Get-B02Prop $m 'Email'          '')
                    Enabled        = $enabled
                })
            }
        }

        # Sort within group: disabled-first, then by display name (case-insensitive),
        # falling back to SamAccountName when display name is blank.
        $sortedMembers = @($memberRows | Sort-Object `
            @{ Expression = { if ($_.Enabled) { 1 } else { 0 } }; Descending = $false }, `
            @{ Expression = { $n = $_.DisplayName; if ([string]::IsNullOrWhiteSpace($n)) { $_.SamAccountName } else { $n } }; Descending = $false })

        $secEnabled  = @($sortedMembers | Where-Object { $_.Enabled }).Count
        $secDisabled = $sortedMembers.Count - $secEnabled

        $grandRows     += $sortedMembers.Count
        $grandEnabled  += $secEnabled
        $grandDisabled += $secDisabled

        $sections.Add([pscustomobject]@{
            Domain        = $domain
            GroupName     = $groupName
            IsNested      = $isNested
            Skipped       = $skipped
            DeclaredCount = $declaredCount
            Members       = $sortedMembers
            Enabled       = $secEnabled
            Disabled      = $secDisabled
        })
    }

    # Sort sections by domain then group name for a stable, reviewer-friendly order.
    $orderedSections = @($sections | Sort-Object `
        @{ Expression = 'Domain'; Descending = $false }, `
        @{ Expression = 'GroupName'; Descending = $false })

    # --- Metadata for cover sheet -------------------------------------------
    $generatedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    $totalGroups  = $orderedSections.Count
    $distinctDoms = @($orderedSections | ForEach-Object { $_.Domain } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
    $scopeDomains = if ($distinctDoms.Count -gt 0) { ($distinctDoms -join ', ') } else { 'Not specified' }
    $reviewPeriod = 'Not available'

    # --- Render HTML ---------------------------------------------------------
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<title>Access Certification / UAR Sign-off Sheet</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine(@'
* { box-sizing: border-box; }
body {
    font-family: "Segoe UI", system-ui, -apple-system, Arial, sans-serif;
    margin: 0; padding: 28px; background:#eceef1; color:#16191d;
    -webkit-print-color-adjust: exact; print-color-adjust: exact;
}
.page {
    max-width: 1180px; margin: 0 auto 26px; background:#fff;
    border:1px solid #c9cfd6; border-radius:8px;
    box-shadow:0 1px 4px rgba(0,0,0,.08); padding: 30px 34px;
}

/* ---- Cover sheet ---- */
.cover h1 { font-size: 1.7rem; margin:0 0 2px; letter-spacing:.01em; }
.cover .docid { color:#5a6472; font-size:.82rem; margin:0 0 20px; }
.cover .grid { display:grid; grid-template-columns: 200px 1fr; gap:0; border:1px solid #c9cfd6; border-radius:6px; overflow:hidden; margin-bottom:22px; }
.cover .grid .k { background:#f3f5f7; border-bottom:1px solid #e1e5ea; border-right:1px solid #e1e5ea; padding:9px 13px; font-size:.8rem; font-weight:700; color:#2b3441; }
.cover .grid .v { border-bottom:1px solid #e1e5ea; padding:9px 13px; font-size:.85rem; color:#1c2530; }
.cover .grid .k:last-of-type, .cover .grid .v:last-of-type { border-bottom:none; }
.attest { border-left:4px solid #1f4e79; background:#f4f8fc; padding:14px 18px; border-radius:0 6px 6px 0; margin-bottom:24px; }
.attest h2 { font-size:.95rem; margin:0 0 8px; color:#1f4e79; text-transform:uppercase; letter-spacing:.05em; }
.attest p { margin:0; font-size:.88rem; line-height:1.5; color:#27313d; }
.siglines { display:grid; grid-template-columns: 1fr 1fr; gap:34px; margin-top:30px; }
.sig { border-top:1.5px solid #16191d; padding-top:6px; font-size:.78rem; color:#4a5562; }
.legend { margin-top:26px; font-size:.78rem; color:#4a5562; }
.legend .swatch { display:inline-block; width:13px; height:13px; border-radius:3px; vertical-align:-2px; margin:0 5px 0 0; border:1px solid #98742a; background:#ffe9c7; }

/* ---- Group sections ---- */
.section-head { display:flex; flex-wrap:wrap; align-items:baseline; gap:12px; margin: 6px 0 12px; padding-bottom:8px; border-bottom:2px solid #1f4e79; }
.section-head h2 { font-size:1.18rem; margin:0; color:#1f3a52; }
.section-head .dom { font-size:.82rem; color:#5a6472; }
.section-head .tags { margin-left:auto; display:flex; gap:8px; }
.tag { font-size:.72rem; padding:3px 9px; border-radius:11px; border:1px solid #c9cfd6; background:#f3f5f7; color:#34404f; }
.tag.warn { background:#fff3df; border-color:#e0b873; color:#8a5a12; font-weight:600; }
.tag.dis  { background:#ffe9c7; border-color:#c99537; color:#7a4d0a; font-weight:600; }

table { border-collapse: collapse; width:100%; }
thead th {
    background:#1f4e79; color:#fff; text-align:left; padding:8px 10px;
    font-size:.72rem; letter-spacing:.03em; text-transform:uppercase; vertical-align:bottom;
}
thead th.deccol { background:#163a5c; }
tbody td { padding:7px 10px; border-bottom:1px solid #e6e9ee; font-size:.82rem; vertical-align:top; }
tbody tr:nth-child(even) { background:#fafbfc; }
td.num { text-align:right; font-variant-numeric: tabular-nums; }
.status-en  { color:#1a7f37; font-weight:600; }
.status-dis { color:#9a3b12; font-weight:700; }

/* Disabled-member row: color cue PLUS glyph + bold so it survives greyscale. */
tr.row-disabled td { background:#fff4e2 !important; }
tr.row-disabled td:first-child { border-left:4px solid #c99537; }
.dis-mark { font-weight:700; }

/* Empty annotation cells the reviewer fills in. */
.fill { background:#fbfcfd; }
td.fill { min-width:120px; }
.decision-hint { color:#9aa3b0; font-size:.72rem; font-style:italic; }
.just-box { min-height:34px; border:1px dashed #c2c9d2; border-radius:4px; }
.date-box, .name-box { min-height:24px; border-bottom:1px solid #c2c9d2; }

.foot-note { color:#7b838f; font-size:.72rem; margin-top:18px; line-height:1.5; }

@media print {
    body { background:#fff; padding:0; }
    .page { box-shadow:none; border:none; border-radius:0; margin:0 0 12px; max-width:none; page-break-after: always; }
    .section { page-break-inside: auto; }
    tr { page-break-inside: avoid; }
    thead { display: table-header-group; }
}
'@)
    [void]$sb.AppendLine('</style></head><body>')

    # ===================== COVER SHEET =======================================
    [void]$sb.AppendLine('<div class="page cover">')
    [void]$sb.AppendLine('<h1>Access Certification &mdash; User Access Review Sign-off Sheet</h1>')
    [void]$sb.AppendLine('<p class="docid">Report B02 &middot; Access Certification / UAR Sign-off Sheet &middot; account treatment: full-list (one certifiable row per entitlement)</p>')

    [void]$sb.AppendLine('<div class="grid">')
    [void]$sb.AppendLine("<div class=""k"">Review Scope</div><div class=""v"">$(ConvertTo-B02HtmlSafe $scopeDomains) &mdash; $totalGroups group(s), $grandRows entitlement row(s)</div>")
    [void]$sb.AppendLine("<div class=""k"">Review Period</div><div class=""v"">$(ConvertTo-B02HtmlSafe $reviewPeriod)</div>")
    [void]$sb.AppendLine('<div class="k">Control Owner</div><div class="v">________________________________  (print name &amp; title)</div>')
    [void]$sb.AppendLine('<div class="k">Reviewer / Certifier</div><div class="v">________________________________  (print name &amp; title)</div>')
    [void]$sb.AppendLine("<div class=""k"">Enabled Accounts</div><div class=""v"">$grandEnabled</div>")
    [void]$sb.AppendLine("<div class=""k"">Disabled Accounts</div><div class=""v"">$grandDisabled (flagged for priority review)</div>")
    [void]$sb.AppendLine("<div class=""k"">Evidence Generated</div><div class=""v"">$(ConvertTo-B02HtmlSafe $generatedAt)</div>")
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<div class="attest">')
    [void]$sb.AppendLine('<h2>Attestation Statement</h2>')
    [void]$sb.AppendLine('<p>I, the undersigned reviewer, attest that I have examined each access entitlement listed in this worksheet for the stated review period. For every row I have recorded a decision of <b>Approve</b>, <b>Revoke</b>, or <b>Escalate</b> and provided a written justification. I certify that approved access remains appropriate to the individual&#39;s current role and business need, that access marked for revocation will be removed through the established access-management process, and that escalations have been routed to the responsible owner for resolution. I understand that access not documented in this review is treated by auditors as never having been reviewed.</p>')
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<div class="siglines">')
    [void]$sb.AppendLine('<div class="sig">Reviewer signature &amp; date</div>')
    [void]$sb.AppendLine('<div class="sig">Control owner / approver signature &amp; date</div>')
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<div class="legend"><span class="swatch"></span> Highlighted rows marked &ldquo;[DISABLED]&rdquo; denote accounts that are currently disabled in the directory and are sorted to the top of each group for priority review. Color and the bold [DISABLED] marker both encode status so the sheet remains legible in greyscale print.</div>')
    [void]$sb.AppendLine('</div>') # end cover page

    # ===================== GROUP ROSTER SECTIONS =============================
    foreach ($sec in $orderedSections) {
        [void]$sb.AppendLine('<div class="page section">')

        [void]$sb.AppendLine('<div class="section-head">')
        [void]$sb.AppendLine("<h2>$(ConvertTo-B02HtmlSafe $sec.GroupName)</h2>")
        [void]$sb.AppendLine("<span class=""dom"">$(ConvertTo-B02HtmlSafe $sec.Domain)</span>")
        [void]$sb.AppendLine('<span class="tags">')
        [void]$sb.AppendLine("<span class=""tag"">Members: $($sec.Members.Count)</span>")
        [void]$sb.AppendLine("<span class=""tag"">Enabled: $($sec.Enabled)</span>")
        if ($sec.Disabled -gt 0) {
            [void]$sb.AppendLine("<span class=""tag dis"">Disabled: $($sec.Disabled)</span>")
        } else {
            [void]$sb.AppendLine("<span class=""tag"">Disabled: 0</span>")
        }
        if ($sec.IsNested) { [void]$sb.AppendLine('<span class="tag warn">Nested</span>') }
        if ($sec.Skipped)  { [void]$sb.AppendLine('<span class="tag warn">Skipped</span>') }
        [void]$sb.AppendLine('</span>')
        [void]$sb.AppendLine('</div>')

        [void]$sb.AppendLine('<table>')
        [void]$sb.AppendLine('<thead><tr>')
        [void]$sb.AppendLine('<th class="num">#</th>')
        [void]$sb.AppendLine('<th>Display Name</th>')
        [void]$sb.AppendLine('<th>SamAccountName</th>')
        [void]$sb.AppendLine('<th>Email</th>')
        [void]$sb.AppendLine('<th>Account Status</th>')
        [void]$sb.AppendLine('<th class="deccol">Reviewer Decision<br><span class="decision-hint">Approve / Revoke / Escalate</span></th>')
        [void]$sb.AppendLine('<th class="deccol">Justification <span class="decision-hint">(required)</span></th>')
        [void]$sb.AppendLine('<th class="deccol">Review Date</th>')
        [void]$sb.AppendLine('<th class="deccol">Reviewer Name</th>')
        [void]$sb.AppendLine('</tr></thead>')
        [void]$sb.AppendLine('<tbody>')

        if ($sec.Members.Count -eq 0) {
            [void]$sb.AppendLine('<tr><td class="num">&mdash;</td><td colspan="8" style="color:#9aa3b0;font-style:italic;">No members enumerated for this group.</td></tr>')
        }
        else {
            $i = 0
            foreach ($m in $sec.Members) {
                $i++
                $rowClass = if (-not $m.Enabled) { ' class="row-disabled"' } else { '' }
                if ($m.Enabled) {
                    $statusCell = '<span class="status-en">Enabled</span>'
                } else {
                    $statusCell = '<span class="status-dis dis-mark">&#9632; [DISABLED]</span>'
                }
                [void]$sb.Append("<tr$rowClass>")
                [void]$sb.Append("<td class=""num"">$i</td>")
                [void]$sb.Append("<td>$(ConvertTo-B02HtmlSafe $m.DisplayName)</td>")
                [void]$sb.Append("<td>$(ConvertTo-B02HtmlSafe $m.SamAccountName)</td>")
                [void]$sb.Append("<td>$(ConvertTo-B02HtmlSafe $m.Email)</td>")
                [void]$sb.Append("<td>$statusCell</td>")
                [void]$sb.Append('<td class="fill"><div class="decision-hint">&#9633; Approve &nbsp; &#9633; Revoke &nbsp; &#9633; Escalate</div></td>')
                [void]$sb.Append('<td class="fill"><div class="just-box"></div></td>')
                [void]$sb.Append('<td class="fill"><div class="date-box"></div></td>')
                [void]$sb.Append('<td class="fill"><div class="name-box"></div></td>')
                [void]$sb.AppendLine('</tr>')
            }
        }

        [void]$sb.AppendLine('</tbody></table>')
        [void]$sb.AppendLine('<p class="foot-note">Every member above is rendered as a discrete certifiable entitlement (full-list treatment). Each row requires a Reviewer Decision and a written Justification before the sheet is considered complete. Disabled accounts are sorted first within the group.</p>')
        [void]$sb.AppendLine('</div>') # end section page
    }

    [void]$sb.AppendLine('</body></html>')

    # --- Write output --------------------------------------------------------
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    Write-SPHtmlFile -Path $OutputPath -Content $sb.ToString()
    return $OutputPath
}

<#
.SYNOPSIS
    B05 - Orphaned / Disabled Account Membership Report (parameterized module).

.DESCRIPTION
    Surfaces disabled accounts (Enabled = $false) that still hold group memberships,
    listing every disabled-member -> group pair (accountTreatment = full-list).
    Rows where the lingering group is privileged bubble to the top for priority action.
    Each row carries empty RemediationStatus / TicketRef cells (analyst fill) rendered
    as explicit sentinels rather than blanks.

    Parameterized product module. Operates solely on $GroupResults; loads no files
    by baked-in path. Dot-sources nothing. Writes a single self-contained HTML report.

    Spec id: B05-orphaned-disabled-members
#>

function Get-B05Prop {
    # Safe dual-mode accessor: hashtable (-FromCache) or object (live enumeration).
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Export-OrphanedDisabledMembersReport {
    <#
    .SYNOPSIS
        Writes an HTML report of disabled accounts that still hold group memberships.

    .PARAMETER GroupResults
        Array of @{ Data = @{ Domain; GroupName; MemberCount; IsNested; Skipped;
        Members = @(@{ SamAccountName; DisplayName; Email; Enabled }) }; Errors = @() }.

    .PARAMETER OutputPath
        Destination .html path.

    .PARAMETER Title
        Optional report title override.

    .PARAMETER Theme
        'dark' (default) or 'light'.

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

        [Parameter()][string]$Title = 'B05 - Orphaned / Disabled Account Membership Report',

        [Parameter()][ValidateSet('dark', 'light')][string]$Theme = 'dark'
    )

    # Sentinels for empty values (never render blank cells)
    $SENTINEL_MISSING = '(not recorded)'
    $SENTINEL_FILL    = '(pending analyst)'

    # -----------------------------------------------------------------------
    # HTML-escape helper (self-contained; dot-sources nothing)
    # -----------------------------------------------------------------------
    function ConvertTo-B05HtmlText {
        param([object]$Value)
        if ($null -eq $Value) { return $SENTINEL_MISSING }
        $s = [string]$Value
        if ([string]::IsNullOrWhiteSpace($s)) { return $SENTINEL_MISSING }
        $s = $s -replace '&', '&amp;'
        $s = $s -replace '<', '&lt;'
        $s = $s -replace '>', '&gt;'
        $s = $s -replace '"', '&quot;'
        $s = $s -replace "'", '&#39;'
        return $s
    }

    # -----------------------------------------------------------------------
    # Privileged-group heuristic
    # Token list kept readable & auditable (no encoded payloads). Case-insensitive.
    # -----------------------------------------------------------------------
    $PrivilegedTokens = @(
        'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators',
        'Account Operators', 'Backup Operators', 'Server Operators', 'Print Operators',
        'Group Policy Creator Owners', 'DnsAdmins', 'Cert Publishers', 'Key Admins',
        'Enterprise Key Admins', 'Remote Desktop Users', 'Distributed COM Users',
        'Admin', 'PrivAccess', 'Tier0', 'Tier-0', 'PAW', 'Privileged'
    )
    function Test-B05PrivilegedGroup {
        param([string]$GroupName)
        if ([string]::IsNullOrWhiteSpace($GroupName)) { return $false }
        foreach ($t in $PrivilegedTokens) {
            if ($GroupName -match [regex]::Escape($t)) { return $true }
        }
        return $false
    }

    # -----------------------------------------------------------------------
    # Build findings: one row per disabled-member -> group pair (full-list)
    # -----------------------------------------------------------------------
    $rows            = New-Object System.Collections.Generic.List[object]
    $groupsScanned   = 0
    $skippedGroups   = 0
    $totalMemberRefs = 0

    foreach ($g in $GroupResults) {
        if ($null -eq $g) { continue }
        $d = Get-B05Prop $g 'Data'
        if ($null -eq $d) { continue }

        $skVal = Get-B05Prop $d 'Skipped'
        if ($null -ne $skVal -and [bool]$skVal) { $skippedGroups++; continue }

        $groupsScanned++

        $domain    = [string](Get-B05Prop $d 'Domain')
        $groupName = [string](Get-B05Prop $d 'GroupName')
        $isPriv    = Test-B05PrivilegedGroup -GroupName $groupName

        $members = @()
        $mVal = Get-B05Prop $d 'Members'
        if ($mVal) { $members = @($mVal) }

        foreach ($m in $members) {
            $totalMemberRefs++
            # Enabled defaults to $true when absent; only act on explicit $false.
            $enVal = Get-B05Prop $m 'Enabled'
            $enabled = if ($null -ne $enVal) { [bool]$enVal } else { $true }
            if ($enabled) { continue }   # only disabled accounts are in scope

            $sam   = Get-B05Prop $m 'SamAccountName'
            $disp  = Get-B05Prop $m 'DisplayName'
            $email = Get-B05Prop $m 'Email'

            $rows.Add([pscustomobject]@{
                SamAccountName    = $sam
                DisplayName       = $disp
                Email             = $email
                Domain            = $domain
                GroupName         = $groupName
                IsPrivileged      = $isPriv
                AccountStatus     = 'Disabled'
                RemediationStatus = $null   # analyst fill
                TicketRef         = $null   # analyst fill
            })
        }
    }

    # Risk sort: privileged-group rows first, then by sam / group for stable output.
    $sorted = $rows | Sort-Object `
        @{ Expression = { -not $_.IsPrivileged } }, `
        @{ Expression = { [string]$_.SamAccountName } }, `
        @{ Expression = { [string]$_.GroupName } }

    $findingCount = $rows.Count
    $distinctSam  = @($rows | ForEach-Object { [string]$_.SamAccountName } | Sort-Object -Unique).Count
    $privRowCount = @($rows | Where-Object { $_.IsPrivileged }).Count

    # -----------------------------------------------------------------------
    # Theme palette (matches source visual design)
    # -----------------------------------------------------------------------
    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    $titleEsc    = ConvertTo-B05HtmlText $Title

    # -----------------------------------------------------------------------
    # Render HTML
    # -----------------------------------------------------------------------
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine(('<title>{0}</title>' -f $titleEsc))

    if ($Theme -eq 'light') {
        [void]$sb.AppendLine('<style>')
        [void]$sb.AppendLine(@'
:root{--bg:#f5f6f8;--card:#ffffff;--ink:#1b1f24;--muted:#6b7280;--line:#e2e5ea;
--crit:#c0392b;--critbg:#fdf2f2;--ok:#27ae60;--warn:#b7770d;--accent:#2563eb;--sent:#9ca3af;}
*{box-sizing:border-box;}
body{margin:0;background:var(--bg);color:var(--ink);
font:14px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;}
.wrap{max-width:1200px;margin:0 auto;padding:24px;}
h1{font-size:20px;margin:0 0 4px;}
.sub{color:var(--muted);margin:0 0 18px;font-size:13px;}
.cards{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:20px;}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;
padding:14px 16px;min-width:150px;}
.card .n{font-size:24px;font-weight:600;}
.card .l{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em;}
.card.crit .n{color:var(--crit);}
table{width:100%;border-collapse:collapse;background:var(--card);
border:1px solid var(--line);border-radius:8px;overflow:hidden;}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--line);
font-size:13px;vertical-align:top;}
th{background:#eef1f5;color:var(--muted);text-transform:uppercase;
font-size:11px;letter-spacing:.04em;position:sticky;top:0;}
tr:last-child td{border-bottom:none;}
tr.priv{background:var(--critbg);}
tr.priv td:first-child{border-left:3px solid var(--crit);}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;
font-weight:600;white-space:nowrap;}
.badge.dis{background:#fde8e8;color:var(--crit);border:1px solid #f5c6c6;}
.badge.priv{background:#fef3cd;color:var(--warn);border:1px solid #f0d080;}
.sentinel{color:var(--sent);font-style:italic;}
.empty{background:var(--card);border:1px solid var(--line);border-radius:8px;
padding:30px;text-align:center;}
.empty .ico{font-size:28px;color:var(--ok);}
.empty h2{margin:8px 0 4px;font-size:16px;}
.foot{color:var(--muted);font-size:12px;margin-top:20px;border-top:1px solid var(--line);
padding-top:12px;}
code{background:#eef1f5;padding:1px 5px;border-radius:4px;font-size:12px;}
'@)
    } else {
        [void]$sb.AppendLine('<style>')
        [void]$sb.AppendLine(@'
:root{--bg:#0f1419;--card:#161b22;--ink:#e6edf3;--muted:#8b949e;--line:#30363d;
--crit:#f85149;--critbg:#2d1416;--ok:#3fb950;--warn:#d29922;--accent:#58a6ff;--sent:#6e7681;}
*{box-sizing:border-box;}
body{margin:0;background:var(--bg);color:var(--ink);
font:14px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;}
.wrap{max-width:1200px;margin:0 auto;padding:24px;}
h1{font-size:20px;margin:0 0 4px;}
.sub{color:var(--muted);margin:0 0 18px;font-size:13px;}
.cards{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:20px;}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;
padding:14px 16px;min-width:150px;}
.card .n{font-size:24px;font-weight:600;}
.card .l{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em;}
.card.crit .n{color:var(--crit);}
table{width:100%;border-collapse:collapse;background:var(--card);
border:1px solid var(--line);border-radius:8px;overflow:hidden;}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--line);
font-size:13px;vertical-align:top;}
th{background:#1c2230;color:var(--muted);text-transform:uppercase;
font-size:11px;letter-spacing:.04em;position:sticky;top:0;}
tr:last-child td{border-bottom:none;}
tr.priv{background:var(--critbg);}
tr.priv td:first-child{border-left:3px solid var(--crit);}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;
font-weight:600;white-space:nowrap;}
.badge.dis{background:#3a1d1f;color:var(--crit);border:1px solid #5a2a2c;}
.badge.priv{background:#3a2a10;color:var(--warn);border:1px solid #5a431a;}
.sentinel{color:var(--sent);font-style:italic;}
.empty{background:var(--card);border:1px solid var(--line);border-radius:8px;
padding:30px;text-align:center;}
.empty .ico{font-size:28px;color:var(--ok);}
.empty h2{margin:8px 0 4px;font-size:16px;}
.foot{color:var(--muted);font-size:12px;margin-top:20px;border-top:1px solid var(--line);
padding-top:12px;}
code{background:#1c2230;padding:1px 5px;border-radius:4px;font-size:12px;}
'@)
    }

    [void]$sb.AppendLine('</style></head><body><div class="wrap">')
    [void]$sb.AppendLine(('<h1>{0}</h1>' -f $titleEsc))
    [void]$sb.AppendLine('<p class="sub">Disabled accounts (Enabled = false) that still hold group memberships, with a named remediation path per finding. Rows inside privileged groups are prioritized.</p>')

    # Summary cards
    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine(('<div class="card{0}"><div class="n">{1}</div><div class="l">Disabled-member findings</div></div>' -f $(if ($findingCount -gt 0) { ' crit' } else { '' }), $findingCount))
    [void]$sb.AppendLine(('<div class="card"><div class="n">{0}</div><div class="l">Distinct disabled accounts</div></div>' -f $distinctSam))
    [void]$sb.AppendLine(('<div class="card{0}"><div class="n">{1}</div><div class="l">In privileged groups</div></div>' -f $(if ($privRowCount -gt 0) { ' crit' } else { '' }), $privRowCount))
    [void]$sb.AppendLine(('<div class="card"><div class="n">{0}</div><div class="l">Groups scanned</div></div>' -f $groupsScanned))
    [void]$sb.AppendLine('</div>')

    if ($findingCount -eq 0) {
        [void]$sb.AppendLine('<div class="empty">')
        [void]$sb.AppendLine('<div class="ico">&#10003;</div>')
        [void]$sb.AppendLine('<h2>No disabled accounts retain group memberships</h2>')
        [void]$sb.AppendLine(('<p class="sub">Scanned {0} group(s) covering {1} member reference(s); {2} skipped group(s). Every in-scope member is Enabled = true.</p>' -f $groupsScanned, $totalMemberRefs, $skippedGroups))
        [void]$sb.AppendLine('<p class="sub">This is the desired state for the orphaned/disabled-account control: no remediation rows required.</p>')
        [void]$sb.AppendLine('</div>')
    } else {
        [void]$sb.AppendLine('<table><thead><tr>')
        foreach ($h in @('SamAccountName', 'DisplayName', 'Email', 'Group', 'Account Status', 'Remediation Status', 'Ticket Ref')) {
            [void]$sb.AppendLine(('<th>{0}</th>' -f (ConvertTo-B05HtmlText $h)))
        }
        [void]$sb.AppendLine('</tr></thead><tbody>')

        foreach ($r in $sorted) {
            $trClass = if ($r.IsPrivileged) { ' class="priv"' } else { '' }
            [void]$sb.AppendLine(('<tr{0}>' -f $trClass))
            [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-B05HtmlText $r.SamAccountName)))
            [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-B05HtmlText $r.DisplayName)))
            [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-B05HtmlText $r.Email)))

            $grpCell = ConvertTo-B05HtmlText $r.GroupName
            if ($r.IsPrivileged) { $grpCell = $grpCell + ' <span class="badge priv">PRIVILEGED</span>' }
            [void]$sb.AppendLine(('<td>{0}</td>' -f $grpCell))

            [void]$sb.AppendLine(('<td><span class="badge dis">{0}</span></td>' -f (ConvertTo-B05HtmlText $r.AccountStatus)))

            # Analyst-fill cells -> explicit sentinel, never blank
            [void]$sb.AppendLine(('<td><span class="sentinel">{0}</span></td>' -f (ConvertTo-B05HtmlText $SENTINEL_FILL)))
            [void]$sb.AppendLine(('<td><span class="sentinel">{0}</span></td>' -f (ConvertTo-B05HtmlText $SENTINEL_FILL)))
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    [void]$sb.AppendLine('<div class="foot">')
    [void]$sb.AppendLine(('Generated {0} | Report <code>B05-orphaned-disabled-members</code>' -f (ConvertTo-B05HtmlText $generatedAt)))
    [void]$sb.AppendLine('<br>Account treatment: full-list (one row per disabled-member / group pair). Empty cells shown as explicit sentinels for analyst completion.')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</div></body></html>')

    # Ensure output directory exists
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    # Write UTF-8 no BOM for clean browser rendering
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), $utf8NoBom)

    return $OutputPath
}

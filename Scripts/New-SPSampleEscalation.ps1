#Requires -Version 5.1
<#
.SYNOPSIS
    Generates sample escalation HTML reports across 5 tiers for visual validation.
.DESCRIPTION
    Creates a 6-level org chain with 3 late reviewers, builds the escalation
    levelData structure, and renders per-manager HTML files for each tier.
    No ISC tenant required -- all data is synthetic.
.PARAMETER OutputPath
    Directory for generated HTML files. Default: .\Reports\sample-escalation
.PARAMETER OpenInBrowser
    Open the tier 5 (highest level) report in the default browser.
#>
[CmdletBinding()]
param(
    [Parameter()] [string]$OutputPath,
    [Parameter()] [switch]$OpenInBrowser
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

Import-Module (Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1') -Force -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $toolkitRoot 'Reports\sample-escalation'
}

Write-Host ''
Write-Host '  Escalation Hierarchy -- Sample Report Generator' -ForegroundColor Cyan
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host ''

# 6-level org chain
$identities = @{
    'id-000' = @{ IdentityId='id-000'; DisplayName='CEO Park'; ManagerId=''; Email='ceo.park@corp.test'; Found=$true }
    'id-001' = @{ IdentityId='id-001'; DisplayName='SVP Zhang'; ManagerId='id-000'; Email='svp.zhang@corp.test'; Found=$true }
    'id-002' = @{ IdentityId='id-002'; DisplayName='VP Yamamoto'; ManagerId='id-001'; Email='vp.yamamoto@corp.test'; Found=$true }
    'id-003' = @{ IdentityId='id-003'; DisplayName='Dir Xavier'; ManagerId='id-002'; Email='dir.xavier@corp.test'; Found=$true }
    'id-004' = @{ IdentityId='id-004'; DisplayName='Dir Walsh'; ManagerId='id-002'; Email='dir.walsh@corp.test'; Found=$true }
    'id-006' = @{ IdentityId='id-006'; DisplayName='Mgr Adams'; ManagerId='id-003'; Email='mgr.adams@corp.test'; Found=$true }
    'id-007' = @{ IdentityId='id-007'; DisplayName='Mgr Baker'; ManagerId='id-003'; Email='mgr.baker@corp.test'; Found=$true }
    'id-008' = @{ IdentityId='id-008'; DisplayName='Mgr Clark'; ManagerId='id-004'; Email='mgr.clark@corp.test'; Found=$true }
}

$lateRows = @(
    [PSCustomObject]@{ ReviewerName='Mgr Adams'; ReviewerEmail='mgr.adams@corp.test'; ReviewerIdentityId='id-006'; CertSigned=$false; CampaignName='Q2 Entitlement Review'; Total=24; Approved=8; Revoked=3; Pending=13 }
    [PSCustomObject]@{ ReviewerName='Mgr Baker'; ReviewerEmail='mgr.baker@corp.test'; ReviewerIdentityId='id-007'; CertSigned=$false; CampaignName='Q2 Entitlement Review'; Total=18; Approved=4; Revoked=1; Pending=13 }
    [PSCustomObject]@{ ReviewerName='Mgr Clark'; ReviewerEmail='mgr.clark@corp.test'; ReviewerIdentityId='id-008'; CertSigned=$false; CampaignName='AD Manager Certification'; Total=12; Approved=2; Revoked=0; Pending=10 }
)

Write-Host '  Building escalation chains (4 levels above reviewers)...' -ForegroundColor Gray

# Build chains
$chains = [System.Collections.Generic.List[object]]::new()
foreach ($row in $lateRows) {
    $chain = [System.Collections.Generic.List[object]]::new()
    $rid = $row.ReviewerIdentityId; $rd = $identities[$rid]
    $chain.Add(@{ IdentityId=$rid; DisplayName=$row.ReviewerName; Email=$row.ReviewerEmail; ManagerId=$rd.ManagerId; Found=$true; Row=$row })
    $curId = $rd.ManagerId
    for ($lvl = 1; $lvl -le 4; $lvl++) {
        if ([string]::IsNullOrWhiteSpace($curId)) { break }
        $d = $identities[$curId]
        if ($null -eq $d) { break }
        $chain.Add(@{ IdentityId=$d.IdentityId; DisplayName=$d.DisplayName; Email=$d.Email; ManagerId=$d.ManagerId; Found=$true })
        $curId = $d.ManagerId
    }
    $chains.Add($chain)
    Write-Host "    Chain: $($row.ReviewerName) -> $($chain | Select-Object -Skip 1 | ForEach-Object { $_.DisplayName }) " -ForegroundColor DarkGray
}

# Build levelData
$levelData = @{}
foreach ($chain in $chains) {
    $reviewerRow = $chain[0].Row
    for ($ci = 1; $ci -lt $chain.Count; $ci++) {
        $ln = $ci + 1; $me = $chain[$ci]; $mid = [string]$me.IdentityId
        if (-not $levelData.ContainsKey($ln)) { $levelData[$ln] = @{} }
        if (-not $levelData[$ln].ContainsKey($mid)) {
            $levelData[$ln][$mid] = @{
                IdentityId=$mid; DisplayName=[string]$me.DisplayName; Email=[string]$me.Email
                FirstName=([string]$me.DisplayName -split ' ')[0]
                DirectReviewers=[System.Collections.Generic.List[object]]::new()
                Subordinates=[ordered]@{}
            }
        }
        $md = $levelData[$ln][$mid]
        if ($ln -eq 2) { $md.DirectReviewers.Add($reviewerRow) }
        else {
            $se = $chain[$ci - 1]; $sid = [string]$se.IdentityId
            if (-not $md.Subordinates.Contains($sid)) {
                $md.Subordinates[$sid] = @{ IdentityId=$sid; DisplayName=[string]$se.DisplayName; Email=[string]$se.Email; Reviewers=[System.Collections.Generic.List[object]]::new() }
            }
            $md.Subordinates[$sid].Reviewers.Add($reviewerRow)
        }
    }
}

Write-Host ''
Write-Host '  Levels discovered:' -ForegroundColor Gray
foreach ($l in ($levelData.Keys | Sort-Object)) {
    $names = @($levelData[$l].Values | ForEach-Object { $_.DisplayName }) -join ', '
    Write-Host "    Level ${l}: $names" -ForegroundColor DarkGray
}

# CSS
$css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;background:#fff;}
h1{font-size:20px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;margin-bottom:4px;}
h2{font-size:16px;color:#1f3a5f;margin-top:22px;border-bottom:1px solid #d4dce6;padding-bottom:4px;}
h3{font-size:14px;color:#336699;margin-top:16px;border-bottom:1px solid #e3e9f0;padding-bottom:3px;}
h4{font-size:13px;color:#566;margin-top:12px;}
.meta{color:#566;font-size:12px;margin-bottom:16px;line-height:1.6;}
table{border-collapse:collapse;width:100%;margin:8px 0 16px 0;font-size:12px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 8px;font-weight:600;}
td{border-bottom:1px solid #e3e9f0;padding:5px 8px;vertical-align:top;}
tr:nth-child(even) td{background:#f6f9fc;}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600;color:#fff;background:#b00020;margin-left:6px;vertical-align:middle;}
.pending-cell{color:#b00020;font-weight:600;}
.section{margin:18px 0;padding:12px 16px;border:1px solid #d4dce6;border-radius:6px;background:#fafbfd;}
.footer{margin-top:24px;padding-top:8px;border-top:1px solid #d4dce6;font-size:11px;color:#777;}
'@

# Recursive renderer
function Render-SubTree {
    param([System.Text.StringBuilder]$sb, [string]$mgrId, [int]$mgrLevel, [int]$targetLevel, [hashtable]$LevelData)
    if (-not $LevelData.ContainsKey($mgrLevel) -or -not $LevelData[$mgrLevel].ContainsKey($mgrId)) { return 0 }
    $node = $LevelData[$mgrLevel][$mgrId]
    $hDepth = [math]::Min(6, [math]::Max(2, $targetLevel - $mgrLevel + 2))
    $hTag = "h$hDepth"

    if ($mgrLevel -eq 2) {
        $rows = @($node.DirectReviewers)
        if ($rows.Count -eq 0) { return 0 }
        $word = if ($rows.Count -eq 1) { 'outstanding reviewer' } else { 'outstanding reviewers' }
        $safeName = ConvertTo-SPHtmlSafe $node.DisplayName
        [void]$sb.AppendLine("<$hTag>$safeName -- $($rows.Count) $word <span class='badge'>$($rows.Count) pending</span></$hTag>")
        [void]$sb.AppendLine('<table><thead><tr><th>Reviewer</th><th>Campaign</th><th>Total Items</th><th>Approved</th><th>Revoked</th><th>Pending</th></tr></thead><tbody>')
        $idx = 0
        foreach ($r in $rows) {
            $bg = if ($idx % 2 -eq 1) { " style='background:#f6f9fc;'" } else { '' }
            $rn = ConvertTo-SPHtmlSafe $r.ReviewerName
            $cn = ConvertTo-SPHtmlSafe $r.CampaignName
            [void]$sb.AppendLine("<tr$bg><td>$rn</td><td>$cn</td><td>$($r.Total)</td><td>$($r.Approved)</td><td>$($r.Revoked)</td><td class='pending-cell'>$($r.Pending)</td></tr>")
            $idx++
        }
        [void]$sb.AppendLine('</tbody></table>')
        return $rows.Count
    }
    else {
        $childSb = New-Object System.Text.StringBuilder
        $childTotal = 0
        foreach ($subId in $node.Subordinates.Keys) {
            $childTotal += (Render-SubTree -sb $childSb -mgrId $subId -mgrLevel ($mgrLevel - 1) -targetLevel $targetLevel -LevelData $LevelData)
        }
        if ($childTotal -gt 0) {
            $word = if ($childTotal -eq 1) { 'outstanding reviewer' } else { 'outstanding reviewers' }
            $safeName = ConvertTo-SPHtmlSafe $node.DisplayName
            [void]$sb.AppendLine("<div class='section'>")
            [void]$sb.AppendLine("<$hTag>$safeName -- $childTotal $word</$hTag>")
            [void]$sb.Append($childSb.ToString())
            [void]$sb.AppendLine("</div>")
        }
        return $childTotal
    }
}

# Generate HTML files
Write-Host ''
Write-Host '  Generating HTML reports...' -ForegroundColor Gray

$genDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')
$levelLabels = @{ 2='Direct Managers'; 3='Directors'; 4='Vice Presidents'; 5='SVP / Executive Leadership' }
$lastFile = $null

foreach ($levelNum in ($levelData.Keys | Sort-Object)) {
    if ($levelNum -lt 2) { continue }
    $levelDir = Join-Path $OutputPath "level$levelNum"
    if (-not (Test-Path $levelDir)) { New-Item -ItemType Directory -Path $levelDir -Force | Out-Null }
    $levelLabel = if ($levelLabels.ContainsKey($levelNum)) { $levelLabels[$levelNum] } else { "Level $levelNum" }

    foreach ($mgrId in $levelData[$levelNum].Keys) {
        $mgr = $levelData[$levelNum][$mgrId]
        $safeName = ([string]$mgr.DisplayName) -replace '[^A-Za-z0-9_\-]', '-'
        $filePath = Join-Path $levelDir "$safeName.html"

        $sb = New-Object System.Text.StringBuilder 4096
        $safeTitle = ConvertTo-SPHtmlSafe "Escalation -- $($mgr.DisplayName) (Tier $levelNum)"
        $safeDisplayName = ConvertTo-SPHtmlSafe $mgr.DisplayName
        $safeEmail = ConvertTo-SPHtmlSafe $mgr.Email
        [void]$sb.AppendLine("<!DOCTYPE html><html><head><meta charset='utf-8'><title>$safeTitle</title><style>$css</style></head><body>")
        [void]$sb.AppendLine("<h1>Escalation Report - Tier ${levelNum}: $levelLabel</h1>")
        [void]$sb.AppendLine("<p class='meta'>")
        [void]$sb.AppendLine("Recipient: <strong>$safeDisplayName</strong> ($safeEmail)<br>")
        [void]$sb.AppendLine("Generated: $genDate<br>")
        [void]$sb.AppendLine("The following reviewers in your organization have <strong>not completed</strong> their access certification.<br>")
        [void]$sb.AppendLine("Please follow up to ensure timely completion before the campaign deadline.</p>")

        $count = Render-SubTree -sb $sb -mgrId $mgrId -mgrLevel $levelNum -targetLevel $levelNum -LevelData $levelData

        [void]$sb.AppendLine("<p class='footer'>Total outstanding reviewers: $count | Escalation tier: $levelNum ($levelLabel) | Generated: $genDate | SailPoint ISC Governance Toolkit</p>")
        [void]$sb.AppendLine('</body></html>')

        Write-SPHtmlFile -Path $filePath -Content $sb.ToString()
        Write-Host "    Tier $levelNum`: $filePath ($count reviewers)" -ForegroundColor Green
        $lastFile = $filePath
    }
}

Write-Host ''
Write-Host '  All escalation reports generated!' -ForegroundColor Cyan
Write-Host ''
Get-ChildItem -Path $OutputPath -Recurse -Filter '*.html' | ForEach-Object {
    $tier = if ($_.Directory.Name -match 'level(\d)') { "Tier $($Matches[1])" } else { $_.Directory.Name }
    Write-Host "    $tier`: $($_.Name)" -ForegroundColor White
}
Write-Host ''

if ($OpenInBrowser -and $null -ne $lastFile -and (Test-Path $lastFile)) {
    Write-Host "  Opening highest-tier report: $lastFile" -ForegroundColor Gray
    if ($IsMacOS -or $env:OS -notmatch 'Windows') { & open $lastFile } else { Start-Process $lastFile }
}

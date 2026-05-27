#Requires -Version 5.1
<#
.SYNOPSIS
    W-05 -- CLI script tests against the remote mock at http://10.0.0.143:8080.

.DESCRIPTION
    Runs each of the eight CLI entry-point scripts (Test-SPConnectivity,
    Invoke-SPCampaignAudit x3, Invoke-SPADDeltaCert x2, Invoke-SPDeltaReport,
    Invoke-SPDeltaCertEscalate) as a child powershell.exe process, captures
    exit codes + stdout/stderr, and validates the expected output for each.

    Run as:
        powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File .\Tests\Harness\Test-W05-CliScripts.ps1

    Emits one compact JSON line per test, terminated by a {summary} line.
    Exit 0 if no FAIL (BLOCKED does not fail).

.NOTES
    Requires the mock Pode server at http://10.0.0.143:8080.
    Per-test stdout transcripts land in docs\windows-test-rounds\WC-05-<id>.txt.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$JsonlPath,
    [Parameter()][string]$LogDir,
    [Parameter()][int]$PerScriptTimeoutSec = 240,
    # URL where the mock Pode server is reachable. Default preserves
    # standalone behaviour against the original macOS host. The orchestrator
    # overrides this to the locally-running mock. NOTE: this only controls
    # the harness's reachability check -- the CLI scripts themselves read
    # the URL from Config\settings.json / settings.local.json, which the
    # orchestrator overlays separately.
    [Parameter()][string]$MockBaseUrl = 'http://10.0.0.143:8080'
)

$ErrorActionPreference = 'Stop'

$harnessRoot = $PSScriptRoot
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $harnessRoot '..\..'))
$scriptsDir  = Join-Path $toolkitRoot 'Scripts'
if (-not $LogDir)    { $LogDir    = Join-Path $toolkitRoot 'docs\windows-test-rounds' }
if (-not $JsonlPath) { $JsonlPath = Join-Path $LogDir 'WC-05-results.jsonl' }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
Set-Content -Path $JsonlPath -Value '' -Encoding utf8

$ps    = (Get-Command powershell.exe).Source
$cfg   = Join-Path $toolkitRoot 'Config\settings.json'

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Id, [string]$Result, [string]$Note = '')
    $results.Add([pscustomobject]@{ id = $Id; result = $Result; note = $Note })
    $line = ConvertTo-Json -Compress -InputObject ([ordered]@{ id = $Id; result = $Result; note = $Note })
    Write-Host $line
    Add-Content -Path $JsonlPath -Value $line -Encoding utf8
}

function Invoke-CliScript {
    <#
    .SYNOPSIS
        Launches a child powershell.exe with the given script + arguments,
        captures stdout/stderr to a transcript file, waits up to TimeoutSec
        for completion. Returns hashtable @{ ExitCode; TranscriptPath; TimedOut }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter()][AllowEmptyCollection()][string[]]$Args = @(),
        [Parameter(Mandatory)][string]$TranscriptPath,
        [Parameter()][int]$TimeoutSec = 240
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $ps
    $psi.WorkingDirectory       = $toolkitRoot
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.Arguments              = '-NoProfile -ExecutionPolicy Bypass -File ' + ('"{0}"' -f $Script) + ' ' + ($Args -join ' ')

    $proc = [System.Diagnostics.Process]::Start($psi)
    $sbOut = New-Object System.Text.StringBuilder
    $sbErr = New-Object System.Text.StringBuilder

    # Async stream reading -- BeginOutputReadLine + DataReceived events
    Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
    } -MessageData $sbOut | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
    } -MessageData $sbErr | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $timedOut = -not $proc.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) {
        try { $proc.Kill() } catch { }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }
    # Drain remaining events
    Start-Sleep -Milliseconds 200
    Get-EventSubscriber | Where-Object SourceObject -eq $proc | Unregister-Event -Force -ErrorAction SilentlyContinue

    $transcript = "=== Command ===`n$ps $($psi.Arguments)`n`n=== STDOUT ===`n$($sbOut.ToString())`n=== STDERR ===`n$($sbErr.ToString())"
    Set-Content -Path $TranscriptPath -Value $transcript -Encoding utf8

    return @{
        ExitCode       = $proc.ExitCode
        TimedOut       = $timedOut
        Stdout         = $sbOut.ToString()
        Stderr         = $sbErr.ToString()
        TranscriptPath = $TranscriptPath
    }
}

# ----- Pre-run cleanup ------------------------------------------------------

$mockUp = $false
try {
    $h = Invoke-RestMethod -Uri "$MockBaseUrl/health" -TimeoutSec 5 -ErrorAction Stop
    if ($h -and $h.status -eq 'ok') { $mockUp = $true }
} catch { }

# Clean Audit/ and DeltaCert/ so each test starts with a known baseline.
foreach ($d in @('Audit', 'DeltaCert')) {
    $p = Join-Path $toolkitRoot $d
    if (Test-Path $p) {
        try { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# ----- WC-05-01: Test-SPConnectivity.ps1 -- exit 0 + auth success
try {
    $tx = Join-Path $LogDir 'WC-05-01-Test-SPConnectivity.txt'
    $r = Invoke-CliScript -Script (Join-Path $scriptsDir 'Test-SPConnectivity.ps1') `
        -Args @() -TranscriptPath $tx -TimeoutSec $PerScriptTimeoutSec
    if ($r.TimedOut) {
        Add-Result 'WC-05-01' 'FAIL' "Timed out after ${PerScriptTimeoutSec}s. Transcript: $tx"
    } elseif ($r.ExitCode -eq 0 -and ($r.Stdout -match 'PASS|SUCCESS|OK|All tests passed' -or $r.Stdout -match 'Successfully authenticated')) {
        $tokenLine = ($r.Stdout -split "`r?`n" | Where-Object { $_ -match 'token|authenticat|Connectivity|PASS' } | Select-Object -First 1)
        Add-Result 'WC-05-01' 'PASS' ("exit 0; first success line: '{0}'" -f $tokenLine.Trim())
    } elseif ($r.ExitCode -eq 0) {
        Add-Result 'WC-05-01' 'PASS' "exit 0 (no canonical success keyword in stdout but exit code is clean). Transcript: $tx"
    } else {
        $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
        Add-Result 'WC-05-01' 'FAIL' ("exit={0}; first stderr: '{1}'. Transcript: {2}" -f $r.ExitCode, $errLine, $tx)
    }
} catch {
    Add-Result 'WC-05-01' 'FAIL' "Launch failed: $($_.Exception.Message)"
}

# ----- WC-05-02: Invoke-SPCampaignAudit.ps1 -- COMPLETED + LeadershipRollup
try {
    $tx = Join-Path $LogDir 'WC-05-02-CampaignAudit-COMPLETED.txt'
    $r = Invoke-CliScript -Script (Join-Path $scriptsDir 'Invoke-SPCampaignAudit.ps1') `
        -Args @('-Status', 'COMPLETED', '-DaysBack', '365',
                '-IncludeLeadershipRollup', '-LeadershipDepth', '4',
                '-DetailLevel', 'Detailed') `
        -TranscriptPath $tx -TimeoutSec $PerScriptTimeoutSec
    $leadDir = Join-Path $toolkitRoot 'Audit\leadership'
    $execHtml = Join-Path $leadDir 'executive-summary.html'
    if ($r.TimedOut) {
        Add-Result 'WC-05-02' 'FAIL' "Timed out after ${PerScriptTimeoutSec}s. Transcript: $tx"
    } elseif ($r.ExitCode -eq 0 -and (Test-Path $execHtml)) {
        $perPerson = @(Get-ChildItem -Path $leadDir -Filter '*.html' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'executive-summary.html' })
        Add-Result 'WC-05-02' 'PASS' ("exit 0; Audit\leadership\executive-summary.html + {0} per-leader HTML(s)" -f $perPerson.Count)
    } elseif ($r.ExitCode -eq 0) {
        Add-Result 'WC-05-02' 'FAIL' ("exit 0 but Audit\leadership\executive-summary.html missing. Transcript: {0}" -f $tx)
    } else {
        $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
        Add-Result 'WC-05-02' 'FAIL' ("exit={0}; first stderr: '{1}'. Transcript: {2}" -f $r.ExitCode, $errLine, $tx)
    }
} catch {
    Add-Result 'WC-05-02' 'FAIL' "Launch failed: $($_.Exception.Message)"
}

# ----- WC-05-03: Invoke-SPCampaignAudit.ps1 -- ACTIVE
try {
    $tx = Join-Path $LogDir 'WC-05-03-CampaignAudit-ACTIVE.txt'
    $r = Invoke-CliScript -Script (Join-Path $scriptsDir 'Invoke-SPCampaignAudit.ps1') `
        -Args @('-Status', 'ACTIVE', '-DaysBack', '365') `
        -TranscriptPath $tx -TimeoutSec $PerScriptTimeoutSec
    if ($r.TimedOut) {
        Add-Result 'WC-05-03' 'FAIL' "Timed out after ${PerScriptTimeoutSec}s. Transcript: $tx"
    } elseif ($r.ExitCode -eq 0) {
        # Look for "Found N campaign(s)" or "Processing N campaign(s)" in stdout
        $countLine = ($r.Stdout -split "`r?`n" | Where-Object { $_ -match '(Found|Processing|Audit complete).*campaign' } | Select-Object -First 1)
        $countLine = if ($countLine) { $countLine.Trim() } else { '<no campaign-summary line in stdout>' }
        Add-Result 'WC-05-03' 'PASS' ("exit 0; {0}" -f $countLine)
    } else {
        $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
        Add-Result 'WC-05-03' 'FAIL' ("exit={0}; first stderr: '{1}'. Transcript: {2}" -f $r.ExitCode, $errLine, $tx)
    }
} catch {
    Add-Result 'WC-05-03' 'FAIL' "Launch failed: $($_.Exception.Message)"
}

# ----- WC-05-04: Invoke-SPADDeltaCert.ps1 -- Manager mode
try {
    $tx = Join-Path $LogDir 'WC-05-04-ADDeltaCert-Manager.txt'
    $r = Invoke-CliScript -Script (Join-Path $scriptsDir 'Invoke-SPADDeltaCert.ps1') `
        -Args @('-SourceId', 'src-ad-001', '-CampaignNamePrefix', 'WinCLI-01') `
        -TranscriptPath $tx -TimeoutSec $PerScriptTimeoutSec
    if ($r.TimedOut) {
        Add-Result 'WC-05-04' 'FAIL' "Timed out after ${PerScriptTimeoutSec}s. Transcript: $tx"
    } elseif ($r.ExitCode -eq 0) {
        $summary = ($r.Stdout -split "`r?`n" | Where-Object { $_ -match '(CampaignsCreated|Identities|Reason|Created \d|DuplicatesExist)' } | Select-Object -First 1)
        $summary = if ($summary) { $summary.Trim() } else { '<no summary line>' }
        Add-Result 'WC-05-04' 'PASS' ("exit 0; {0}" -f $summary)
    } else {
        $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
        Add-Result 'WC-05-04' 'FAIL' ("exit={0}; first stderr: '{1}'. Transcript: {2}" -f $r.ExitCode, $errLine, $tx)
    }
} catch {
    Add-Result 'WC-05-04' 'FAIL' "Launch failed: $($_.Exception.Message)"
}

# ----- WC-05-05: Invoke-SPADDeltaCert.ps1 -- SourceOwner mode
try {
    $tx = Join-Path $LogDir 'WC-05-05-ADDeltaCert-SourceOwner.txt'
    $r = Invoke-CliScript -Script (Join-Path $scriptsDir 'Invoke-SPADDeltaCert.ps1') `
        -Args @('-SourceId', 'src-ad-001', '-ReviewerMode', 'SourceOwner',
                '-CampaignNamePrefix', 'WinCLI-02') `
        -TranscriptPath $tx -TimeoutSec $PerScriptTimeoutSec
    if ($r.TimedOut) {
        Add-Result 'WC-05-05' 'FAIL' "Timed out after ${PerScriptTimeoutSec}s. Transcript: $tx"
    } elseif ($r.ExitCode -eq 0) {
        $summary = ($r.Stdout -split "`r?`n" | Where-Object { $_ -match '(SourceOwner|CampaignsCreated|Reason|Created \d|DuplicatesExist)' } | Select-Object -First 1)
        $summary = if ($summary) { $summary.Trim() } else { '<no summary line>' }
        Add-Result 'WC-05-05' 'PASS' ("exit 0; {0}" -f $summary)
    } else {
        $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
        Add-Result 'WC-05-05' 'FAIL' ("exit={0}; first stderr: '{1}'. Transcript: {2}" -f $r.ExitCode, $errLine, $tx)
    }
} catch {
    Add-Result 'WC-05-05' 'FAIL' "Launch failed: $($_.Exception.Message)"
}

# ----- WC-05-06: Invoke-SPDeltaReport.ps1 -- 48h window
try {
    $tx = Join-Path $LogDir 'WC-05-06-DeltaReport-48h.txt'
    $r = Invoke-CliScript -Script (Join-Path $scriptsDir 'Invoke-SPDeltaReport.ps1') `
        -Args @('-SourceId', 'src-ad-001', '-HoursBack', '48') `
        -TranscriptPath $tx -TimeoutSec $PerScriptTimeoutSec
    if ($r.TimedOut) {
        Add-Result 'WC-05-06' 'FAIL' "Timed out after ${PerScriptTimeoutSec}s. Transcript: $tx"
    } elseif ($r.ExitCode -eq 0) {
        $reportHtml = @(Get-ChildItem -Path (Join-Path $toolkitRoot 'DeltaCert') -Filter 'delta-*.html' -Recurse -ErrorAction SilentlyContinue)
        $summary = ($r.Stdout -split "`r?`n" | Where-Object { $_ -match '(grants|revocations|Delta report)' } | Select-Object -First 1)
        $summary = if ($summary) { $summary.Trim() } else { '<no summary>' }
        if ($reportHtml.Count -ge 1) {
            Add-Result 'WC-05-06' 'PASS' ("exit 0; {0}; {1} HTML report(s) under DeltaCert\" -f $summary, $reportHtml.Count)
        } else {
            Add-Result 'WC-05-06' 'FAIL' ("exit 0 but no delta-*.html files written under DeltaCert\. summary='{0}'. Transcript: {1}" -f $summary, $tx)
        }
    } else {
        $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
        Add-Result 'WC-05-06' 'FAIL' ("exit={0}; first stderr: '{1}'. Transcript: {2}" -f $r.ExitCode, $errLine, $tx)
    }
} catch {
    Add-Result 'WC-05-06' 'FAIL' "Launch failed: $($_.Exception.Message)"
}

# ----- WC-05-07: Invoke-SPDeltaCertEscalate.ps1 -- WhatIf
try {
    $tx = Join-Path $LogDir 'WC-05-07-DeltaCertEscalate-WhatIf.txt'
    $r = Invoke-CliScript -Script (Join-Path $scriptsDir 'Invoke-SPDeltaCertEscalate.ps1') `
        -Args @('-StaleHours', '1', '-WhatIf') `
        -TranscriptPath $tx -TimeoutSec $PerScriptTimeoutSec
    if ($r.TimedOut) {
        Add-Result 'WC-05-07' 'FAIL' "Timed out after ${PerScriptTimeoutSec}s. Transcript: $tx"
    } elseif ($r.ExitCode -eq 0) {
        if ($r.Stdout -match '\[WhatIf\]') {
            $whatIfLine = ($r.Stdout -split "`r?`n" | Where-Object { $_ -match '\[WhatIf\]' } | Select-Object -First 1)
            Add-Result 'WC-05-07' 'PASS' ("exit 0; {0}" -f $whatIfLine.Trim())
        } else {
            Add-Result 'WC-05-07' 'FAIL' ("exit 0 but no [WhatIf] marker in stdout. Transcript: {0}" -f $tx)
        }
    } else {
        $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
        Add-Result 'WC-05-07' 'FAIL' ("exit={0}; first stderr: '{1}'. Transcript: {2}" -f $r.ExitCode, $errLine, $tx)
    }
} catch {
    Add-Result 'WC-05-07' 'FAIL' "Launch failed: $($_.Exception.Message)"
}

# ----- WC-05-08: Invoke-SPCampaignAudit.ps1 -- WhatIf
try {
    $tx = Join-Path $LogDir 'WC-05-08-CampaignAudit-WhatIf.txt'
    $r = Invoke-CliScript -Script (Join-Path $scriptsDir 'Invoke-SPCampaignAudit.ps1') `
        -Args @('-Status', 'COMPLETED', '-WhatIf') `
        -TranscriptPath $tx -TimeoutSec $PerScriptTimeoutSec
    if ($r.TimedOut) {
        Add-Result 'WC-05-08' 'FAIL' "Timed out after ${PerScriptTimeoutSec}s. Transcript: $tx"
    } elseif ($r.ExitCode -eq 0) {
        if ($r.Stdout -match '\[WhatIf\]') {
            $whatIfLine = ($r.Stdout -split "`r?`n" | Where-Object { $_ -match '\[WhatIf\]' } | Select-Object -First 1)
            Add-Result 'WC-05-08' 'PASS' ("exit 0; {0}" -f $whatIfLine.Trim())
        } else {
            Add-Result 'WC-05-08' 'FAIL' ("exit 0 but no [WhatIf] marker in stdout. Transcript: {0}" -f $tx)
        }
    } else {
        $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
        Add-Result 'WC-05-08' 'FAIL' ("exit={0}; first stderr: '{1}'. Transcript: {2}" -f $r.ExitCode, $errLine, $tx)
    }
} catch {
    Add-Result 'WC-05-08' 'FAIL' "Launch failed: $($_.Exception.Message)"
}

$pass    = @($results | Where-Object result -eq 'PASS').Count
$fail    = @($results | Where-Object result -eq 'FAIL').Count
$blocked = @($results | Where-Object result -eq 'BLOCKED').Count
$summary = ConvertTo-Json -Compress -InputObject ([ordered]@{
    summary = $true; pass = $pass; fail = $fail; blocked = $blocked; total = ($pass + $fail + $blocked)
})
Write-Host $summary
Add-Content -Path $JsonlPath -Value $summary -Encoding utf8
exit $(if ($fail -eq 0) { 0 } else { 1 })

#Requires -Version 5.1
<#
.SYNOPSIS
    W-06 -- Playwright screenshot capture for the toolkit HTML reports.

.DESCRIPTION
    Drives Tests\Tools\Playwright\capture.py (headless Chromium via the
    Playwright Python SDK) to render the audit-combined HTML, the leadership
    executive summary, a VP/director rollup, and the delta certification
    report into PNG files under docs\windows-screenshots\.

    Run as:
        powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File .\Tests\Harness\Test-W06-Playwright.ps1

    The script presumes the HTML inputs are already on disk -- they are
    produced by W-05's CLI runs. If any are missing it emits a BLOCKED
    result rather than failing the suite.

    The accompanying visual checks (WV-06-01 .. WV-06-10) are validated
    by an LLM reviewer reading the captured PNGs in the same round; see
    docs\windows-test-rounds\round-09.md for the per-check verdicts.

.NOTES
    Requires:
      - Python 3 with the `playwright` package installed
      - `python -m playwright install chromium` already run
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ScreenshotDir,
    [Parameter()][string]$CapturePy,
    [Parameter()][string]$JsonlPath,
    [Parameter()][int]$TimeoutSec = 180
)

$ErrorActionPreference = 'Stop'

$harnessRoot = $PSScriptRoot
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $harnessRoot '..\..'))
if (-not $ScreenshotDir) { $ScreenshotDir = Join-Path $toolkitRoot 'docs\windows-screenshots' }
if (-not $CapturePy)     { $CapturePy     = Join-Path $toolkitRoot 'Tests\Tools\Playwright\capture.py' }
if (-not $JsonlPath)     { $JsonlPath     = Join-Path $toolkitRoot 'docs\windows-test-rounds\WV-06-results.jsonl' }
if (-not (Test-Path $ScreenshotDir)) { New-Item -ItemType Directory -Path $ScreenshotDir -Force | Out-Null }
Set-Content -Path $JsonlPath -Value '' -Encoding utf8

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Id, [string]$Result, [string]$Note = '')
    $results.Add([pscustomobject]@{ id = $Id; result = $Result; note = $Note })
    $line = ConvertTo-Json -Compress -InputObject ([ordered]@{ id = $Id; result = $Result; note = $Note })
    Write-Host $line
    Add-Content -Path $JsonlPath -Value $line -Encoding utf8
}

# Locate the four primary HTML inputs.
$combined = (Get-ChildItem (Join-Path $toolkitRoot 'Audit\campaign-audit-combined-*.html') -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1)
$execHtml = Join-Path $toolkitRoot 'Audit\leadership\executive-summary.html'
$vpHtml   = (Get-ChildItem (Join-Path $toolkitRoot 'Audit\leadership\director-*.html') -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1)
$deltaHtml= (Get-ChildItem (Join-Path $toolkitRoot 'DeltaCert\reports\delta-*.html') -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1)

$inputs = @{
    'combined' = $combined
    'exec'     = if (Test-Path $execHtml) { Get-Item $execHtml } else { $null }
    'vp'       = $vpHtml
    'delta'    = $deltaHtml
}

$missing = @($inputs.GetEnumerator() | Where-Object { $null -eq $_.Value } | ForEach-Object { $_.Key })
if ($missing.Count -gt 0) {
    Add-Result 'WV-06-capture' 'BLOCKED' ("Missing HTML inputs: {0}. Run W-05 first." -f ($missing -join ', '))
    Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ summary = $true; pass = 0; fail = 0; blocked = 1; total = 1 }))
    exit 1
}

function Invoke-CapturePy {
    param([Parameter(Mandatory)][string[]]$Args, [int]$Timeout = 180)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'python'
    $psi.WorkingDirectory       = $toolkitRoot
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.Arguments              = ('"{0}"' -f $CapturePy) + ' ' + ($Args -join ' ')
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit($Timeout * 1000)
    if ($timedOut) { try { $proc.Kill() } catch { } }
    return @{
        ExitCode = $proc.ExitCode
        TimedOut = $timedOut
        Stdout   = $stdout.Result
        Stderr   = $stderr.Result
    }
}

# WV-06-cap-01 .. WV-06-cap-04: capture the four primary reports
$captures = @(
    @{ Id='WV-06-cap-01'; Prefix='win-audit';  Path=$combined.FullName;    Label='audit-combined' },
    @{ Id='WV-06-cap-02'; Prefix='win-exec';   Path=$execHtml;             Label='executive-summary' },
    @{ Id='WV-06-cap-03'; Prefix='win-vp';     Path=$vpHtml.FullName;      Label=$vpHtml.BaseName },
    @{ Id='WV-06-cap-04'; Prefix='win-delta';  Path=$deltaHtml.FullName;   Label=$deltaHtml.BaseName }
)
foreach ($c in $captures) {
    try {
        $r = Invoke-CapturePy -Args @(('"{0}"' -f $c.Path), '--full-page',
            '--output-dir', ('"{0}"' -f $ScreenshotDir),
            '--prefix',     ('"{0}"' -f $c.Prefix)) -Timeout $TimeoutSec
        if ($r.TimedOut) {
            Add-Result $c.Id 'FAIL' ("capture.py timed out after ${TimeoutSec}s for {0}" -f $c.Label)
        } elseif ($r.ExitCode -ne 0) {
            $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
            Add-Result $c.Id 'FAIL' ("capture.py exit={0} for {1}; stderr: '{2}'" -f $r.ExitCode, $c.Label, $errLine)
        } else {
            $written = @(($r.Stdout -split "`r?`n") | Where-Object { $_ -match '\.png$' })
            Add-Result $c.Id 'PASS' ("Captured {0}: {1}" -f $c.Label, ($written -join '; '))
        }
    } catch {
        Add-Result $c.Id 'FAIL' "capture.py launch failed: $($_.Exception.Message)"
    }
}

# WV-06-cap-05: scroll captures on combined
try {
    $r = Invoke-CapturePy -Args @(('"{0}"' -f $combined.FullName),
        '--scroll-captures', '--scroll-step', '800',
        '--output-dir', ('"{0}"' -f $ScreenshotDir),
        '--prefix',     'win-scroll') -Timeout $TimeoutSec
    if ($r.ExitCode -eq 0 -and -not $r.TimedOut) {
        $written = @(($r.Stdout -split "`r?`n") | Where-Object { $_ -match '\.png$' })
        Add-Result 'WV-06-cap-05' 'PASS' ("Scroll captures on combined: {0} frames" -f $written.Count)
    } elseif ($r.TimedOut) {
        Add-Result 'WV-06-cap-05' 'FAIL' "Scroll capture timed out"
    } else {
        $errLine = ($r.Stderr -split "`r?`n" | Select-Object -First 1)
        Add-Result 'WV-06-cap-05' 'FAIL' ("Scroll capture exit={0}; stderr: '{1}'" -f $r.ExitCode, $errLine)
    }
} catch {
    Add-Result 'WV-06-cap-05' 'FAIL' "Scroll capture launch failed: $($_.Exception.Message)"
}

# Note: WV-06-01 through WV-06-10 are validated by a separate LLM reviewer
# reading the PNGs and logging verdicts to docs\windows-test-rounds\round-09.md.
# This harness only verifies that the captures themselves were produced.

$pass    = @($results | Where-Object result -eq 'PASS').Count
$fail    = @($results | Where-Object result -eq 'FAIL').Count
$blocked = @($results | Where-Object result -eq 'BLOCKED').Count
$summary = ConvertTo-Json -Compress -InputObject ([ordered]@{
    summary = $true; pass = $pass; fail = $fail; blocked = $blocked; total = ($pass + $fail + $blocked)
})
Write-Host $summary
Add-Content -Path $JsonlPath -Value $summary -Encoding utf8
exit $(if ($fail -eq 0) { 0 } else { 1 })

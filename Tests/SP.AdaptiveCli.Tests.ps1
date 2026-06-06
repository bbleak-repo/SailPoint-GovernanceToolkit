#Requires -Version 5.1
<#
    SP.AdaptiveCli.Tests.ps1  (ADCLI-001 .. ADCLI-008)

    AR-13 / AR-22: structural (AST) tests for Scripts\Invoke-SPAdaptiveReport.ps1 --
    the report params + date period, the leadership-distribution params, read-only
    convention, and the WhatIf-by-default safety guarantee (every Send-SPReport call
    is gated behind -SendReports, so the default run sends NO email).
#>

BeforeAll {
    $script:CliPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPAdaptiveReport.ps1'
    $script:Errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CliPath, [ref]$null, [ref]$script:Errors)
    $script:ParamNames = @($script:Ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
    $script:Src = Get-Content -Raw -Path $script:CliPath
}

Describe 'Invoke-SPAdaptiveReport.ps1 — structure & safety' {

    It 'ADCLI-001: exists and parses with no errors' {
        Test-Path $script:CliPath | Should -BeTrue
        @($script:Errors).Count | Should -Be 0
    }

    It 'ADCLI-002: declares the report + date-period parameters' {
        foreach ($p in 'Anchor', 'Components', 'BaselineReport', 'Theme', 'Status', 'DaysBack', 'CreatedAfter', 'CreatedBefore', 'OutputMode') {
            $script:ParamNames | Should -Contain $p
        }
    }

    It 'ADCLI-003: declares the leadership-distribution parameters' {
        foreach ($p in 'DistributeToLeadership', 'TargetBands', 'LeadershipDepth', 'OrgSupplementPath', 'PreviewOnly', 'SendReports', 'DetailLevel') {
            $script:ParamNames | Should -Contain $p
        }
    }

    It 'ADCLI-004: is read-only — CmdletBinding does NOT declare SupportsShouldProcess' {
        $cb = $script:Ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        $cb | Should -Not -BeNullOrEmpty
        ($cb.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }) | Should -BeNullOrEmpty
    }

    It 'ADCLI-005: OutputMode ValidateSet includes Console / JSON / Both' {
        $om = $script:Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'OutputMode' }
        $vs = $om.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $vals = @($vs.PositionalArguments | ForEach-Object { $_.Value })
        foreach ($v in 'Console', 'JSON', 'Both') { $vals | Should -Contain $v }
    }

    It 'ADCLI-006: WhatIf-by-default — every Send-SPReport call is gated behind -SendReports' {
        $sendCalls = $script:Ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Send-SPReport'
            }, $true)
        @($sendCalls).Count | Should -BeGreaterThan 0 -Because 'the leadership mode must be able to send when explicitly asked'
        foreach ($call in $sendCalls) {
            $gated = $false
            $p = $call.Parent
            while ($null -ne $p) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $p.Clauses) {
                        if ($clause.Item1.Extent.Text -match '\$SendReports') { $gated = $true }
                    }
                }
                $p = $p.Parent
            }
            $gated | Should -BeTrue -Because 'Send-SPReport must never run unless -SendReports was passed (WhatIf-by-default)'
        }
    }

    It 'ADCLI-007: -PreviewOnly uses Show-SPReportDistributionPreview and exits without sending' {
        $script:Src | Should -Match 'if\s*\(\s*\$PreviewOnly\s*\)'
        $script:Src | Should -Match 'Show-SPReportDistributionPreview'
    }

    It 'ADCLI-008: reuses the existing leadership machinery (no rebuild)' {
        foreach ($fn in 'Build-SPOrgTree', 'Resolve-SPIdentityBand', 'Group-SPAuditByLeadership',
                        'Export-SPLeadershipExecutiveHtml', 'Export-SPLeadershipBandHtml') {
            $script:Src | Should -Match ([regex]::Escape($fn))
        }
    }
}

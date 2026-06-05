#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for CLI script entry points (Scripts/*.ps1)
.DESCRIPTION
    Tests: CLI-001 through CLI-005
    Covers:
        CLI-001: AST syntax validation for all entry-point scripts
        CLI-002: All scripts declare a -Help switch parameter
        CLI-003: Mutating scripts declare SupportsShouldProcess (WhatIf)
        CLI-004: Key scripts declare expected parameter names
        CLI-005: Read-only scripts do NOT declare SupportsShouldProcess
#>

BeforeAll {
    $script:ScriptsRoot = Join-Path $PSScriptRoot '..\Scripts'

    # All entry-point scripts
    $script:AllScripts = @(
        'Invoke-GovernanceTest.ps1'
        'Invoke-SPADDeltaCert.ps1'
        'Invoke-SPCampaignAudit.ps1'
        'Invoke-SPCampaignSearch.ps1'
        'Invoke-SPDailyOrchestrator.ps1'
        'Invoke-SPDeltaCertEscalate.ps1'
        'Invoke-SPDeltaReport.ps1'
        'Invoke-SPDisconnectedAppBatch.ps1'
        'Invoke-SPDisconnectedAppCert.ps1'
        'Invoke-SPDisconnectedAppRegistry.ps1'
        'Invoke-SPReportDistribution.ps1'
        'Invoke-SPRetention.ps1'
        'Invoke-SPWeeklyDigest.ps1'
        'New-SPVault.ps1'
        'Show-SPDashboard.ps1'
        'Test-SPConnectivity.ps1'
    )

    # Scripts that mutate state and should support -WhatIf
    $script:MutatingScripts = @(
        'Invoke-GovernanceTest.ps1'
        'Invoke-SPADDeltaCert.ps1'
        'Invoke-SPCampaignAudit.ps1'
        'Invoke-SPCampaignSearch.ps1'
        'Invoke-SPDailyOrchestrator.ps1'
        'Invoke-SPDeltaCertEscalate.ps1'
        'Invoke-SPDisconnectedAppBatch.ps1'
        'Invoke-SPDisconnectedAppCert.ps1'
        'Invoke-SPReportDistribution.ps1'
        'Invoke-SPRetention.ps1'
        'Invoke-SPWeeklyDigest.ps1'
        'New-SPVault.ps1'
    )

    # Scripts that are read-only (no SupportsShouldProcess expected)
    $script:ReadOnlyScripts = @(
        'Invoke-SPDeltaReport.ps1'
        'Invoke-SPDisconnectedAppRegistry.ps1'
        'Show-SPDashboard.ps1'
        'Test-SPConnectivity.ps1'
    )

    # Helper: parse a script file and return its AST + any parse errors
    function Get-ScriptAst {
        param([string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors
        )
        return @{ Ast = $ast; Errors = $errors; Tokens = $tokens }
    }

    # Helper: extract the param() block AST from a script
    function Get-ScriptParamBlock {
        param([string]$Path)
        $parsed = Get-ScriptAst -Path $Path
        return $parsed.Ast.ParamBlock
    }

    # Helper: extract CmdletBinding attribute from a script
    function Get-CmdletBindingAttribute {
        param([string]$Path)
        $paramBlock = Get-ScriptParamBlock -Path $Path
        if ($null -eq $paramBlock) { return $null }
        $cbAttr = $paramBlock.Attributes | Where-Object {
            $_.TypeName.Name -eq 'CmdletBinding'
        }
        return $cbAttr
    }
}

# Pester 5 evaluates -ForEach/-TestCases expressions during DISCOVERY, which runs
# before BeforeAll. The per-script matrices below (CLI-001..003, CLI-005) reference
# $script:ScriptsRoot / $script:AllScripts / $script:MutatingScripts /
# $script:ReadOnlyScripts, so those must exist at discovery time -- BeforeAll is too
# late and leaves them $null, which made Join-Path throw and silently dropped the
# entire parametrized matrix. Define the discovery-time copies here.
# NOTE: keep these lists in sync with the BeforeAll copies above (BeforeAll's copies
# are what the run-phase It bodies and the non-parametrized Its use).
BeforeDiscovery {
    $script:ScriptsRoot = Join-Path $PSScriptRoot '..\Scripts'

    $script:AllScripts = @(
        'Invoke-GovernanceTest.ps1'
        'Invoke-SPADDeltaCert.ps1'
        'Invoke-SPCampaignAudit.ps1'
        'Invoke-SPCampaignSearch.ps1'
        'Invoke-SPDailyOrchestrator.ps1'
        'Invoke-SPDeltaCertEscalate.ps1'
        'Invoke-SPDeltaReport.ps1'
        'Invoke-SPDisconnectedAppBatch.ps1'
        'Invoke-SPDisconnectedAppCert.ps1'
        'Invoke-SPDisconnectedAppRegistry.ps1'
        'Invoke-SPReportDistribution.ps1'
        'Invoke-SPRetention.ps1'
        'Invoke-SPWeeklyDigest.ps1'
        'New-SPVault.ps1'
        'Show-SPDashboard.ps1'
        'Test-SPConnectivity.ps1'
    )

    $script:MutatingScripts = @(
        'Invoke-GovernanceTest.ps1'
        'Invoke-SPADDeltaCert.ps1'
        'Invoke-SPCampaignAudit.ps1'
        'Invoke-SPCampaignSearch.ps1'
        'Invoke-SPDailyOrchestrator.ps1'
        'Invoke-SPDeltaCertEscalate.ps1'
        'Invoke-SPDisconnectedAppBatch.ps1'
        'Invoke-SPDisconnectedAppCert.ps1'
        'Invoke-SPReportDistribution.ps1'
        'Invoke-SPRetention.ps1'
        'Invoke-SPWeeklyDigest.ps1'
        'New-SPVault.ps1'
    )

    $script:ReadOnlyScripts = @(
        'Invoke-SPDeltaReport.ps1'
        'Invoke-SPDisconnectedAppRegistry.ps1'
        'Show-SPDashboard.ps1'
        'Test-SPConnectivity.ps1'
    )
}

Describe "CLI Script Entry Points" {

    Context "CLI-001: AST syntax validation -- all scripts parse without errors" {

        It "Scripts directory exists and contains expected scripts" {
            Test-Path $script:ScriptsRoot | Should -BeTrue
            $found = Get-ChildItem -Path $script:ScriptsRoot -Filter '*.ps1' |
                Select-Object -ExpandProperty Name
            foreach ($name in $script:AllScripts) {
                $found | Should -Contain $name -Because "$name should exist in Scripts/"
            }
        }

        It "<Name> parses without syntax errors" -ForEach @(
            $script:AllScripts | ForEach-Object { @{ Name = $_; Path = (Join-Path $script:ScriptsRoot $_) } }
        ) {
            $parsed = Get-ScriptAst -Path $Path
            $parsed.Errors.Count | Should -Be 0 -Because "$Name should have no parse errors"
        }

        It "<Name> begins with #Requires -Version 5.1" -ForEach @(
            $script:AllScripts | ForEach-Object { @{ Name = $_; Path = (Join-Path $script:ScriptsRoot $_) } }
        ) {
            $firstLine = (Get-Content -Path $Path -TotalCount 1).Trim()
            $firstLine | Should -Be '#Requires -Version 5.1' -Because "all scripts require PS 5.1"
        }
    }

    Context "CLI-002: All scripts declare a -Help switch parameter" {

        It "<Name> has a -Help switch parameter" -ForEach @(
            $script:AllScripts | ForEach-Object { @{ Name = $_; Path = (Join-Path $script:ScriptsRoot $_) } }
        ) {
            $paramBlock = Get-ScriptParamBlock -Path $Path
            $paramBlock | Should -Not -BeNullOrEmpty -Because "$Name should have a param() block"
            $helpParam = $paramBlock.Parameters | Where-Object {
                $_.Name.VariablePath.UserPath -eq 'Help'
            }
            $helpParam | Should -Not -BeNullOrEmpty -Because "$Name should declare a -Help parameter"
            $helpParam.StaticType.Name | Should -Be 'SwitchParameter' -Because "-Help should be a switch"
        }
    }

    Context "CLI-003: Mutating scripts declare SupportsShouldProcess" {

        It "<Name> has CmdletBinding(SupportsShouldProcess)" -ForEach @(
            $script:MutatingScripts | ForEach-Object { @{ Name = $_; Path = (Join-Path $script:ScriptsRoot $_) } }
        ) {
            $cbAttr = Get-CmdletBindingAttribute -Path $Path
            $cbAttr | Should -Not -BeNullOrEmpty -Because "$Name should have [CmdletBinding()]"
            $sspArg = $cbAttr.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'SupportsShouldProcess'
            }
            $sspArg | Should -Not -BeNullOrEmpty -Because "$Name should declare SupportsShouldProcess"
        }
    }

    Context "CLI-004: Key scripts declare expected parameters" {

        It "Invoke-SPCampaignAudit.ps1 has campaign filter parameters" {
            $path = Join-Path $script:ScriptsRoot 'Invoke-SPCampaignAudit.ps1'
            $paramBlock = Get-ScriptParamBlock -Path $path
            $paramNames = $paramBlock.Parameters | ForEach-Object {
                $_.Name.VariablePath.UserPath
            }
            $paramNames | Should -Contain 'ConfigPath'
            $paramNames | Should -Contain 'CampaignName'
            $paramNames | Should -Contain 'CampaignNameStartsWith'
            $paramNames | Should -Contain 'CampaignNameContains'
            $paramNames | Should -Contain 'Status'
            $paramNames | Should -Contain 'DaysBack'
            $paramNames | Should -Contain 'OutputPath'
            $paramNames | Should -Contain 'OutputMode'
            $paramNames | Should -Contain 'Token'
        }

        It "Invoke-SPRetention.ps1 has retention parameters" {
            $path = Join-Path $script:ScriptsRoot 'Invoke-SPRetention.ps1'
            $paramBlock = Get-ScriptParamBlock -Path $path
            $paramNames = $paramBlock.Parameters | ForEach-Object {
                $_.Name.VariablePath.UserPath
            }
            $paramNames | Should -Contain 'ConfigPath'
            $paramNames | Should -Contain 'ArchiveDays'
            $paramNames | Should -Contain 'DeleteDays'
            $paramNames | Should -Contain 'ArchivePath'
            $paramNames | Should -Contain 'Paths'
            $paramNames | Should -Contain 'OutputMode'
        }

        It "Invoke-SPADDeltaCert.ps1 has delta cert parameters" {
            $path = Join-Path $script:ScriptsRoot 'Invoke-SPADDeltaCert.ps1'
            $paramBlock = Get-ScriptParamBlock -Path $path
            $paramNames = $paramBlock.Parameters | ForEach-Object {
                $_.Name.VariablePath.UserPath
            }
            $paramNames | Should -Contain 'ConfigPath'
            $paramNames | Should -Contain 'Token'
            $paramNames | Should -Contain 'OutputMode'
            $paramNames | Should -Contain 'Help'
        }

        It "New-SPVault.ps1 has vault parameters" {
            $path = Join-Path $script:ScriptsRoot 'New-SPVault.ps1'
            $paramBlock = Get-ScriptParamBlock -Path $path
            $paramNames = $paramBlock.Parameters | ForEach-Object {
                $_.Name.VariablePath.UserPath
            }
            $paramNames | Should -Contain 'ConfigPath'
            $paramNames | Should -Contain 'Help'
        }

        It "Invoke-SPDailyOrchestrator.ps1 has orchestration parameters" {
            $path = Join-Path $script:ScriptsRoot 'Invoke-SPDailyOrchestrator.ps1'
            $paramBlock = Get-ScriptParamBlock -Path $path
            $paramNames = $paramBlock.Parameters | ForEach-Object {
                $_.Name.VariablePath.UserPath
            }
            $paramNames | Should -Contain 'ConfigPath'
            $paramNames | Should -Contain 'OutputMode'
            $paramNames | Should -Contain 'Help'
        }

        It "All scripts with OutputMode use ValidateSet Console/JSON/Both" {
            $scriptsWithOutputMode = $script:AllScripts | Where-Object {
                $path = Join-Path $script:ScriptsRoot $_
                $paramBlock = Get-ScriptParamBlock -Path $path
                $null -ne ($paramBlock.Parameters | Where-Object {
                    $_.Name.VariablePath.UserPath -eq 'OutputMode'
                })
            }

            foreach ($name in $scriptsWithOutputMode) {
                $path = Join-Path $script:ScriptsRoot $name
                $paramBlock = Get-ScriptParamBlock -Path $path
                $omParam = $paramBlock.Parameters | Where-Object {
                    $_.Name.VariablePath.UserPath -eq 'OutputMode'
                }
                $vsAttr = $omParam.Attributes | Where-Object {
                    $_.TypeName.Name -eq 'ValidateSet'
                }
                $vsAttr | Should -Not -BeNullOrEmpty -Because "$name OutputMode should have ValidateSet"
                $validValues = $vsAttr.PositionalArguments | ForEach-Object { $_.Value }
                $validValues | Should -Contain 'Console' -Because "$name should accept Console"
                $validValues | Should -Contain 'JSON' -Because "$name should accept JSON"
                $validValues | Should -Contain 'Both' -Because "$name should accept Both"
            }
        }
    }

    Context "CLI-005: Read-only scripts do NOT declare SupportsShouldProcess" {

        It "<Name> does not declare SupportsShouldProcess" -ForEach @(
            $script:ReadOnlyScripts | ForEach-Object { @{ Name = $_; Path = (Join-Path $script:ScriptsRoot $_) } }
        ) {
            $cbAttr = Get-CmdletBindingAttribute -Path $Path
            if ($null -eq $cbAttr) {
                # No CmdletBinding at all is fine for read-only
                $true | Should -BeTrue
            }
            else {
                $sspArg = $cbAttr.NamedArguments | Where-Object {
                    $_.ArgumentName -eq 'SupportsShouldProcess'
                }
                $sspArg | Should -BeNullOrEmpty -Because "$Name is read-only and should not support WhatIf"
            }
        }
    }
}

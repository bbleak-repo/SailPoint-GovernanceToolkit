#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Invoke-SPScheduledCampaign.ps1 (creates campaigns from templates).
.DESCRIPTION
    Tests: SC-01 through SC-08
    Covers:
        SC-01: AST syntax validation (parse without errors)
        SC-02: CmdletBinding attribute
        SC-03: Parameter validation (names, types, defaults, ValidateSet)
        SC-04: WhatIf mode shows due templates without creating campaigns
        SC-05: MinDaysSinceLastRun validation logic
        SC-06: Cadence parameter validation
        SC-07: Exit codes match documented values
        SC-08: Schedule state persistence
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPScheduledCampaign.ps1'

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

    # Helper: get a specific parameter AST by name
    function Get-ScriptParameter {
        param([string]$Path, [string]$ParameterName)
        $paramBlock = Get-ScriptParamBlock -Path $Path
        if ($null -eq $paramBlock) { return $null }
        return $paramBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq $ParameterName
        }
    }

    # Pre-parse
    $script:Parsed = Get-ScriptAst -Path $script:ScriptPath
    $script:ParamBlock = $script:Parsed.Ast.ParamBlock
}

Describe 'Invoke-SPScheduledCampaign' {

    Context 'SC-01: AST syntax validation' {

        It 'script file exists' {
            Test-Path $script:ScriptPath | Should -BeTrue
        }

        It 'parses without syntax errors' {
            $script:Parsed.Errors.Count | Should -Be 0 `
                -Because 'Invoke-SPScheduledCampaign.ps1 should have no parse errors'
        }

        It 'begins with #Requires -Version 5.1' {
            $firstLine = (Get-Content -Path $script:ScriptPath -TotalCount 1).Trim()
            $firstLine | Should -Be '#Requires -Version 5.1' `
                -Because 'all toolkit scripts require PS 5.1'
        }
    }

    Context 'SC-02: CmdletBinding attribute' {

        It 'has a [CmdletBinding()] attribute' {
            $cbAttr = Get-CmdletBindingAttribute -Path $script:ScriptPath
            $cbAttr | Should -Not -BeNullOrEmpty `
                -Because 'Invoke-SPScheduledCampaign should have [CmdletBinding()]'
        }
    }

    Context 'SC-03: Parameter validation' {

        It 'has a param() block' {
            $script:ParamBlock | Should -Not -BeNullOrEmpty
        }

        It 'declares the -ConfigPath parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'ConfigPath'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -Token parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Token'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -TokenExpiryMinutes parameter as [int] with default 10' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'TokenExpiryMinutes'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'Int32'
            $param.DefaultValue.Value | Should -Be 10
        }

        It 'declares the -TemplateName parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'TemplateName'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -Cadence parameter with ValidateSet Daily/Weekly/Monthly/Quarterly' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Cadence'
            $param | Should -Not -BeNullOrEmpty
            $vsAttr = $param.Attributes | Where-Object {
                $_.TypeName.Name -eq 'ValidateSet'
            }
            $vsAttr | Should -Not -BeNullOrEmpty `
                -Because 'Cadence should have a ValidateSet attribute'
            $validValues = $vsAttr.PositionalArguments | ForEach-Object { $_.Value }
            $validValues | Should -Contain 'Daily'
            $validValues | Should -Contain 'Weekly'
            $validValues | Should -Contain 'Monthly'
            $validValues | Should -Contain 'Quarterly'
        }

        It '-Cadence defaults to Quarterly' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Cadence'
            $param.DefaultValue | Should -Not -BeNullOrEmpty
            $param.DefaultValue.Value | Should -Be 'Quarterly'
        }

        It 'declares the -MinDaysSinceLastRun parameter as [int] with default 80' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'MinDaysSinceLastRun'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'Int32'
            $param.DefaultValue.Value | Should -Be 80
        }

        It 'declares the -ExcludeExceptions switch parameter' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'ExcludeExceptions'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'SwitchParameter'
        }

        It 'declares the -OutputMode parameter with ValidateSet Console/JSON/Both' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'OutputMode'
            $param | Should -Not -BeNullOrEmpty
            $vsAttr = $param.Attributes | Where-Object {
                $_.TypeName.Name -eq 'ValidateSet'
            }
            $vsAttr | Should -Not -BeNullOrEmpty `
                -Because 'OutputMode should have a ValidateSet attribute'
            $validValues = $vsAttr.PositionalArguments | ForEach-Object { $_.Value }
            $validValues | Should -Contain 'Console'
            $validValues | Should -Contain 'JSON'
            $validValues | Should -Contain 'Both'
        }

        It 'declares the -OutputPath parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'OutputPath'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -WhatIf switch parameter' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'WhatIf'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'SwitchParameter'
        }

        It 'declares the -Help switch parameter with ? alias' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Help'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'SwitchParameter'
            $aliasAttr = $param.Attributes | Where-Object {
                $_.TypeName.Name -eq 'Alias'
            }
            $aliasAttr | Should -Not -BeNullOrEmpty
            $aliasValues = $aliasAttr.PositionalArguments | ForEach-Object { $_.Value }
            $aliasValues | Should -Contain '?'
        }
    }

    Context 'SC-04: WhatIf mode shows due templates without creating campaigns' {

        It 'script checks $WhatIf for dry-run behavior' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match '\$WhatIf' `
                -Because 'the script should check the WhatIf switch'
        }

        It 'WhatIf mode displays DUE status but skips campaign creation' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match "WhatIf.*dry run.*no campaigns created" `
                -Because 'WhatIf should display a dry run message'
        }

        It 'WhatIf mode records Action as WhatIf in results' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match "Action\s*=\s*'WhatIf'" `
                -Because 'WhatIf results should have Action = WhatIf'
        }

        It 'WhatIf mode does not write schedule state' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            # The state write block is guarded by: if (-not $WhatIf -and ...)
            $scriptContent | Should -Match '-not\s+\$WhatIf.*scheduleState' `
                -Because 'schedule state should not be written in WhatIf mode'
        }
    }

    Context 'SC-05: MinDaysSinceLastRun validation logic' {

        It 'script compares days since last run against MinDaysSinceLastRun' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'daysSince.*MinDaysSinceLastRun' `
                -Because 'the script should compare elapsed days against the threshold'
        }

        It 'templates with recent runs are classified as SKIPPED' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match "Reason\s*=\s*'too recent'" `
                -Because 'recently-run templates should be skipped with reason'
        }

        It 'templates with no prior run are treated as DUE' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            # daysSince = -1 when no prior run, which is < MinDaysSinceLastRun so goes to else (due)
            $scriptContent | Should -Match 'daysSince\s*=\s*-1' `
                -Because 'templates with no prior run should have daysSince = -1'
        }

        It 'displays due and skipped counts' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Due:.*Skipped:' `
                -Because 'the script should show the number of due and skipped templates'
        }
    }

    Context 'SC-06: Cadence parameter and template filtering' {

        It 'script filters templates by Cadence when TemplateName is not specified' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'tplCadence.*-ne.*\$Cadence' `
                -Because 'templates should be filtered by cadence'
        }

        It 'script loads templates from Config/campaign-templates/ directory' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'campaign-templates' `
                -Because 'the script should look for templates in the campaign-templates directory'
        }

        It 'script filters by TemplateName when specified' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'tplName.*-ne.*\$TemplateName' `
                -Because 'the script should filter by template name when specified'
        }

        It 'reads schedule state from .schedule-state.json' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match '\.schedule-state\.json' `
                -Because 'schedule state should be persisted in .schedule-state.json'
        }
    }

    Context 'SC-07: Exit codes match documented values' {

        It 'exits 0 on success or no templates due' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+0' `
                -Because 'exit code 0 indicates success or no templates due'
        }

        It 'exits 3 on authentication error' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+3' `
                -Because 'exit code 3 indicates authentication error'
        }

        It 'exits 4 on configuration error' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+4' `
                -Because 'exit code 4 indicates configuration error'
        }

        It 'exits 5 on critical campaign creation failure' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match '5' `
                -Because 'exit code 5 indicates critical campaign creation failure'
        }

        It 'documents exit codes in comment-based help' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match '0\s*=\s*All due campaigns run successfully'
            $scriptContent | Should -Match '1\s*=\s*One or more campaigns had warnings'
            $scriptContent | Should -Match '2\s*=\s*Parameter error'
            $scriptContent | Should -Match '3\s*=\s*Authentication error'
            $scriptContent | Should -Match '4\s*=\s*Configuration error'
            $scriptContent | Should -Match '5\s*=\s*Critical campaign creation failure'
        }

        It 'uses exit $exitCode as the final exit mechanism' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+\$exitCode' `
                -Because 'the script should exit with the accumulated exit code'
        }
    }

    Context 'SC-08: Schedule state persistence' {

        It 'writes schedule state atomically via temp file and Move-Item' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Move-Item.*scheduleStatePath' `
                -Because 'schedule state should be written atomically'
        }

        It 'records lastRunDate, lastCorrelationId, lastResult, and runCount' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'lastRunDate'
            $scriptContent | Should -Match 'lastCorrelationId'
            $scriptContent | Should -Match 'lastResult'
            $scriptContent | Should -Match 'runCount'
        }

        It 'increments runCount on successful execution' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'runCount.*\+\s*1' `
                -Because 'runCount should be incremented on success'
        }

        It 'delegates campaign creation to Invoke-SPDeltaCertRun' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Invoke-SPDeltaCertRun' `
                -Because 'the script should delegate to the delta cert runner'
        }
    }
}

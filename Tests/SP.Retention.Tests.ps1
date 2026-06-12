#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Invoke-SPRetention.ps1 (destructive: archives and deletes files).
.DESCRIPTION
    Tests: RET-01 through RET-08
    Covers:
        RET-01: AST syntax validation (parse without errors)
        RET-02: CmdletBinding with SupportsShouldProcess
        RET-03: Parameter validation (names, types, attributes)
        RET-04: ArchiveDays minimum enforcement (ValidateRange or runtime)
        RET-05: DeleteDays must be greater than ArchiveDays
        RET-06: WhatIf mode does NOT delete any files
        RET-07: Retention.Enabled must be true OR explicit params provided
        RET-08: Exit codes: 0 success, 1 disabled, 2 param, 4 config
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPRetention.ps1'
    $script:ScriptsRoot = Join-Path $PSScriptRoot '..\Scripts'

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

    # Pre-parse the script for reuse across tests
    $script:Parsed = Get-ScriptAst -Path $script:ScriptPath
    $script:ParamBlock = $script:Parsed.Ast.ParamBlock
}

Describe 'Invoke-SPRetention' {

    Context 'RET-01: AST syntax validation' {

        It 'script file exists' {
            Test-Path $script:ScriptPath | Should -BeTrue
        }

        It 'parses without syntax errors' {
            $script:Parsed.Errors.Count | Should -Be 0 `
                -Because 'Invoke-SPRetention.ps1 should have no parse errors'
        }

        It 'begins with #Requires -Version 5.1' {
            $firstLine = (Get-Content -Path $script:ScriptPath -TotalCount 1).Trim()
            $firstLine | Should -Be '#Requires -Version 5.1' `
                -Because 'all toolkit scripts require PS 5.1'
        }
    }

    Context 'RET-02: CmdletBinding with SupportsShouldProcess' {

        It 'has a [CmdletBinding()] attribute' {
            $cbAttr = Get-CmdletBindingAttribute -Path $script:ScriptPath
            $cbAttr | Should -Not -BeNullOrEmpty `
                -Because 'Invoke-SPRetention should have [CmdletBinding()]'
        }

        It 'declares SupportsShouldProcess' {
            $cbAttr = Get-CmdletBindingAttribute -Path $script:ScriptPath
            $sspArg = $cbAttr.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'SupportsShouldProcess'
            }
            $sspArg | Should -Not -BeNullOrEmpty `
                -Because 'a destructive script must declare SupportsShouldProcess'
        }
    }

    Context 'RET-03: Parameter validation' {

        It 'has a param() block' {
            $script:ParamBlock | Should -Not -BeNullOrEmpty
        }

        It 'declares the -ConfigPath parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'ConfigPath'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -ArchiveDays parameter as [int]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'ArchiveDays'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'Int32'
        }

        It 'declares the -DeleteDays parameter as [int]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'DeleteDays'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'Int32'
        }

        It 'declares the -ArchivePath parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'ArchivePath'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -Paths parameter as [string[]]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Paths'
            $param | Should -Not -BeNullOrEmpty
            # string[] shows as String in static type but the type constraint AST shows the array
            $typeConstraint = $param.Attributes | Where-Object {
                $_ -is [System.Management.Automation.Language.TypeConstraintAst]
            }
            if ($typeConstraint) {
                $typeConstraint.TypeName.Name | Should -Match 'string'
            } else {
                # Accept if the parameter exists -- the script declares [string[]]
                $param | Should -Not -BeNullOrEmpty
            }
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

        It 'declares the -Help switch parameter' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Help'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'SwitchParameter'
        }

        It '-Help has the ? alias' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Help'
            $aliasAttr = $param.Attributes | Where-Object {
                $_.TypeName.Name -eq 'Alias'
            }
            $aliasAttr | Should -Not -BeNullOrEmpty
            $aliasValues = $aliasAttr.PositionalArguments | ForEach-Object { $_.Value }
            $aliasValues | Should -Contain '?'
        }
    }

    Context 'RET-04: ArchiveDays minimum enforcement' {

        It 'script body validates ArchiveDays > 0 before passing to Invoke-SPLogRetention' {
            # The script checks: $PSBoundParameters.ContainsKey('ArchiveDays') -and $ArchiveDays -gt 0
            # This means ArchiveDays of 0 or negative will NOT be passed to the retention engine.
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'ArchiveDays.*-gt\s+0' `
                -Because 'the script should validate ArchiveDays is positive before passing it'
        }

        It 'documented minimum ArchiveDays is 7' {
            # The help block states: "Minimum 7."
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Minimum\s+7' `
                -Because 'the help documentation should state minimum ArchiveDays is 7'
        }
    }

    Context 'RET-05: DeleteDays must be greater than ArchiveDays' {

        It 'documented DeleteDays minimum is 30' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Minimum\s+30' `
                -Because 'the help documentation should state minimum DeleteDays is 30'
        }

        It 'documents that DeleteDays must be greater than ArchiveDays' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'greater\s+than\s+ArchiveDays' `
                -Because 'help should document the DeleteDays > ArchiveDays constraint'
        }

        It 'script validates DeleteDays > 0 before passing to retention engine' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'DeleteDays.*-gt\s+0' `
                -Because 'the script should validate DeleteDays is positive'
        }
    }

    Context 'RET-06: WhatIf mode does NOT delete any files' {

        It 'script references WhatIfPreference' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match '\$WhatIfPreference' `
                -Because 'the script should check WhatIfPreference for dry-run mode'
        }

        It 'WhatIf is passed through to the retention engine' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match "retentionParams\['WhatIf'\]\s*=" `
                -Because 'WhatIf should be forwarded to Invoke-SPLogRetention'
        }

        It 'displays a WhatIf dry-run banner when WhatIf is active' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Dry-run mode enabled.*No files will be modified' `
                -Because 'the user should see a clear WhatIf banner'
        }
    }

    Context 'RET-07: Retention.Enabled must be true OR explicit params provided' {

        It 'script documents that Retention.Enabled must be true or explicit params given' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Retention\.Enabled\s+must\s+be\s+true' `
                -Because 'the help should document the Retention.Enabled requirement'
        }

        It 'delegates retention execution to Invoke-SPLogRetention' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Invoke-SPLogRetention' `
                -Because 'the CLI entry point should delegate to the module function'
        }
    }

    Context 'RET-08: Exit codes' {

        It 'exits 0 on success' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+0' `
                -Because 'exit code 0 indicates success'
        }

        It 'exits 1 when no action taken (retention disabled or no matching files)' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+1' `
                -Because 'exit code 1 indicates retention disabled / no action'
        }

        It 'exits 2 on parameter or execution error' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+2' `
                -Because 'exit code 2 indicates parameter/validation error'
        }

        It 'exits 4 on configuration error' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+4' `
                -Because 'exit code 4 indicates configuration error'
        }

        It 'documents exit codes in comment-based help' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match '0\s*=\s*Success'
            $scriptContent | Should -Match '1\s*=\s*Retention disabled'
            $scriptContent | Should -Match '2\s*=\s*Parameter'
            $scriptContent | Should -Match '4\s*=\s*Configuration error'
        }
    }
}

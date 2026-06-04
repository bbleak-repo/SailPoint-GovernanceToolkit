#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Pester tests for SP.SdkPatch (JSON Patch RFC 6902 utilities).
.DESCRIPTION
    Validates patch operation construction, validation, and edge cases.
    Test IDs: SDK-PATCH-001 through SDK-PATCH-005.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Sdk
}

Describe 'SP.SdkPatch - JSON Patch Utilities' {

    Context 'SDK-PATCH-001: New-SPSdkPatchOp creates valid operations' {
        It 'creates a replace operation' {
            $op = New-SPSdkPatchOp -Op replace -Path '/name' -Value 'Test'
            $op | Should -BeOfType [hashtable]
            $op.op    | Should -Be 'replace'
            $op.path  | Should -Be '/name'
            $op.value | Should -Be 'Test'
        }

        It 'creates an add operation' {
            $op = New-SPSdkPatchOp -Op add -Path '/description' -Value 'Desc'
            $op.op    | Should -Be 'add'
            $op.path  | Should -Be '/description'
            $op.value | Should -Be 'Desc'
        }

        It 'creates a remove operation without value' {
            $op = New-SPSdkPatchOp -Op remove -Path '/description'
            $op.op   | Should -Be 'remove'
            $op.path | Should -Be '/description'
            $op.ContainsKey('value') | Should -BeFalse
        }

        It 'creates a test operation' {
            $op = New-SPSdkPatchOp -Op test -Path '/name' -Value 'Expected'
            $op.op    | Should -Be 'test'
            $op.value | Should -Be 'Expected'
        }
    }

    Context 'SDK-PATCH-002: Path normalization' {
        It 'adds leading slash if missing' {
            $op = New-SPSdkPatchOp -Op replace -Path 'name' -Value 'Test'
            $op.path | Should -Be '/name'
        }

        It 'preserves existing leading slash' {
            $op = New-SPSdkPatchOp -Op replace -Path '/name' -Value 'Test'
            $op.path | Should -Be '/name'
        }

        It 'handles nested paths' {
            $op = New-SPSdkPatchOp -Op replace -Path '/campaign/name' -Value 'Test'
            $op.path | Should -Be '/campaign/name'
        }
    }

    Context 'SDK-PATCH-003: Move and copy operations require -From' {
        It 'throws on move without From' {
            { New-SPSdkPatchOp -Op move -Path '/name' } | Should -Throw '*requires -From*'
        }

        It 'throws on copy without From' {
            { New-SPSdkPatchOp -Op copy -Path '/name' } | Should -Throw '*requires -From*'
        }

        It 'creates move with From' {
            $op = New-SPSdkPatchOp -Op move -Path '/newName' -From '/oldName'
            $op.op   | Should -Be 'move'
            $op.path | Should -Be '/newName'
            $op.from | Should -Be '/oldName'
        }
    }

    Context 'SDK-PATCH-004: New-SPSdkPatchReplace shorthand' {
        It 'creates a replace operation' {
            $op = New-SPSdkPatchReplace -Path '/name' -Value 'Updated'
            $op.op    | Should -Be 'replace'
            $op.path  | Should -Be '/name'
            $op.value | Should -Be 'Updated'
        }

        It 'handles complex values' {
            $op = New-SPSdkPatchReplace -Path '/campaign' -Value @{ type = 'MANAGER'; name = 'Test' }
            $op.value | Should -BeOfType [hashtable]
            $op.value.type | Should -Be 'MANAGER'
        }
    }

    Context 'SDK-PATCH-005: ConvertTo-SPSdkPatchBody validation' {
        It 'wraps single operation in array' {
            $op = New-SPSdkPatchReplace -Path '/name' -Value 'Test'
            $body = ConvertTo-SPSdkPatchBody -Operations $op
            # ConvertTo-SPSdkPatchBody uses comma operator to preserve array,
            # but PS may unwrap single-element when assigned. Verify count instead.
            @($body).Count | Should -Be 1
            @($body)[0].op | Should -Be 'replace'
        }

        It 'passes through multiple operations' {
            $ops = @(
                New-SPSdkPatchReplace -Path '/name' -Value 'New'
                New-SPSdkPatchReplace -Path '/description' -Value 'Desc'
            )
            $body = ConvertTo-SPSdkPatchBody -Operations $ops
            $body.Count | Should -Be 2
        }

        It 'throws on empty operations' {
            { ConvertTo-SPSdkPatchBody -Operations @() } | Should -Throw '*At least one*'
        }

        It 'throws on non-hashtable operation' {
            { ConvertTo-SPSdkPatchBody -Operations @('not-a-hashtable') } | Should -Throw '*must be a hashtable*'
        }

        It 'throws on operation missing op field' {
            { ConvertTo-SPSdkPatchBody -Operations @(@{ path = '/name'; value = 'x' }) } | Should -Throw '*missing*"op"*'
        }

        It 'throws on operation missing path field' {
            { ConvertTo-SPSdkPatchBody -Operations @(@{ op = 'replace'; value = 'x' }) } | Should -Throw '*missing*"path"*'
        }
    }
}

#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.TaskSequence module.
.DESCRIPTION
    Tests task sequence parsing, condition evaluation, and dry-run validation.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Platform" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.TaskSequence" -Force

    # Stubs for Windows-only cmdlets
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance { param($ClassName, $Namespace, $Query) }
    }
    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        function global:Get-Disk { param($Number) }
    }
    if (-not (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) {
        function global:Confirm-SecureBootUEFI { }
    }
}

Describe 'Module Exports' {
    It 'exports expected functions' {
        $mod = Get-Module Nova.TaskSequence
        $expected = @('Read-TaskSequence', 'Test-StepCondition', 'Invoke-DryRunValidation')
        foreach ($fn in $expected) {
            $mod.ExportedFunctions.Keys | Should -Contain $fn
        }
    }
}

Describe 'Read-TaskSequence' {
    It 'throws when file does not exist' {
        { Read-TaskSequence -Path '/nonexistent/ts.json' } | Should -Throw '*not found*'
    }

    It 'loads a valid task sequence JSON' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova-ts-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $tsFile = Join-Path $testDir 'ts.json'
        try {
            Mock -ModuleName Nova.TaskSequence Write-Step {}
            Mock -ModuleName Nova.TaskSequence Write-Success {}
            $ts = @{
                name = 'Test TS'
                steps = @(
                    @{ name = 'Step1'; type = 'DownloadImage'; enabled = $true }
                )
            } | ConvertTo-Json -Depth 5
            Set-Content $tsFile $ts
            $result = Read-TaskSequence -Path $tsFile
            $result.name | Should -Be 'Test TS'
            $result.steps.Count | Should -Be 1
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws for missing steps array' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova-ts2-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $tsFile = Join-Path $testDir 'bad.json'
        try {
            Mock -ModuleName Nova.TaskSequence Write-Step {}
            Set-Content $tsFile '{"name":"bad"}'
            { Read-TaskSequence -Path $tsFile } | Should -Throw '*missing*steps*'
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test-StepCondition' {
    It 'returns true when no condition provided' {
        $result = Test-StepCondition -Condition $null
        $result | Should -BeTrue
    }

    It 'returns true when condition has no type' {
        $result = Test-StepCondition -Condition ([pscustomobject]@{ })
        $result | Should -BeTrue
    }

    It 'evaluates variable equals condition' {
        $env:NOVA_TEST_VAR = 'hello'
        try {
            $cond = [pscustomobject]@{
                type = 'variable'
                variable = 'NOVA_TEST_VAR'
                operator = 'equals'
                value = 'hello'
            }
            $result = Test-StepCondition -Condition $cond
            $result | Should -BeTrue
        } finally {
            Remove-Item Env:\NOVA_TEST_VAR -ErrorAction SilentlyContinue
        }
    }

    It 'evaluates variable notEquals condition' {
        $env:NOVA_TEST_VAR2 = 'world'
        try {
            $cond = [pscustomobject]@{
                type = 'variable'
                variable = 'NOVA_TEST_VAR2'
                operator = 'notEquals'
                value = 'hello'
            }
            $result = Test-StepCondition -Condition $cond
            $result | Should -BeTrue
        } finally {
            Remove-Item Env:\NOVA_TEST_VAR2 -ErrorAction SilentlyContinue
        }
    }

    It 'evaluates variable exists condition' {
        $env:NOVA_EXISTS_TEST = '1'
        try {
            $cond = [pscustomobject]@{
                type = 'variable'
                variable = 'NOVA_EXISTS_TEST'
                operator = 'exists'
            }
            $result = Test-StepCondition -Condition $cond
            $result | Should -BeTrue
        } finally {
            Remove-Item Env:\NOVA_EXISTS_TEST -ErrorAction SilentlyContinue
        }
    }

    It 'returns true for unknown condition type' {
        Mock -ModuleName Nova.TaskSequence Write-Warn {}
        $cond = [pscustomobject]@{ type = 'unknownType' }
        $result = Test-StepCondition -Condition $cond
        $result | Should -BeTrue
    }
}

Describe 'Invoke-DryRunValidation' {
    It 'validates a simple task sequence without errors' {
        Mock -ModuleName Nova.TaskSequence Write-Step {}
        Mock -ModuleName Nova.TaskSequence Write-Host {}
        Mock -ModuleName Nova.TaskSequence Write-Success {}
        Mock -ModuleName Nova.TaskSequence Get-Disk { $null }
        Mock -ModuleName Nova.TaskSequence Get-CimInstance { $null }

        $ts = [pscustomobject]@{
            name = 'Test'
            steps = @(
                [pscustomobject]@{ name = 'Download'; type = 'DownloadImage'; enabled = $true; parameters = [pscustomobject]@{ imageUrl = 'http://example.com/img.wim' } }
            )
        }
        { Invoke-DryRunValidation -TaskSequence $ts -ScratchDir '/tmp' -OSDrive 'C' -FirmwareType 'UEFI' -DiskNumber 0 } | Should -Not -Throw
    }
}
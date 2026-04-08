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
        $expected = @('Read-TaskSequence', 'Test-StepCondition', 'Invoke-DryRunValidation', 'Update-TaskSequenceFromConfig')
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

Describe 'Update-TaskSequenceFromConfig' {
    BeforeEach {
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova-ts-update-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $script:testDir -Force
        $script:tsFile = Join-Path $script:testDir 'ts.json'
    }

    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'does nothing when file does not exist' {
        { Update-TaskSequenceFromConfig -TaskSequencePath '/nonexistent/path.json' -Config @{} } | Should -Not -Throw
    }

    It 'updates DownloadImage step with edition, language, and architecture' {
        $ts = @{
            name = 'Test TS'
            steps = @(
                @{ name = 'Download'; type = 'DownloadImage'; enabled = $true; parameters = @{} }
            )
        } | ConvertTo-Json -Depth 5
        Set-Content $script:tsFile $ts

        Update-TaskSequenceFromConfig -TaskSequencePath $script:tsFile -Config @{
            Edition      = 'Professional'
            OsLanguage   = 'en-US'
            Architecture = 'x64'
        }

        $result = Get-Content $script:tsFile -Raw | ConvertFrom-Json
        $result.steps[0].parameters.edition | Should -Be 'Professional'
        $result.steps[0].parameters.language | Should -Be 'en-US'
        $result.steps[0].parameters.architecture | Should -Be 'x64'
    }

    It 'updates ApplyImage step with edition' {
        $ts = @{
            name = 'Test TS'
            steps = @(
                @{ name = 'Apply'; type = 'ApplyImage'; enabled = $true; parameters = @{} }
            )
        } | ConvertTo-Json -Depth 5
        Set-Content $script:tsFile $ts

        Update-TaskSequenceFromConfig -TaskSequencePath $script:tsFile -Config @{
            Edition = 'Enterprise'
        }

        $result = Get-Content $script:tsFile -Raw | ConvertFrom-Json
        $result.steps[0].parameters.edition | Should -Be 'Enterprise'
    }

    It 'updates SetComputerName step with computer name' {
        $ts = @{
            name = 'Test TS'
            steps = @(
                @{ name = 'SetName'; type = 'SetComputerName'; enabled = $true; parameters = @{} }
            )
        } | ConvertTo-Json -Depth 5
        Set-Content $script:tsFile $ts

        Update-TaskSequenceFromConfig -TaskSequencePath $script:tsFile -Config @{
            ComputerName = 'NOVA-PC-01'
        }

        $result = Get-Content $script:tsFile -Raw | ConvertFrom-Json
        $result.steps[0].parameters.computerName | Should -Be 'NOVA-PC-01'
    }

    It 'updates SetRegionalSettings step with locale values' {
        $ts = @{
            name = 'Test TS'
            steps = @(
                @{ name = 'Region'; type = 'SetRegionalSettings'; enabled = $true; parameters = @{} }
            )
        } | ConvertTo-Json -Depth 5
        Set-Content $script:tsFile $ts

        Update-TaskSequenceFromConfig -TaskSequencePath $script:tsFile -Config @{
            InputLocale  = '0409:00000409'
            SystemLocale = 'en-US'
            UserLocale   = 'en-US'
            UILanguage   = 'en-US'
        }

        $result = Get-Content $script:tsFile -Raw | ConvertFrom-Json
        $result.steps[0].parameters.inputLocale | Should -Be '0409:00000409'
        $result.steps[0].parameters.systemLocale | Should -Be 'en-US'
        $result.steps[0].parameters.userLocale | Should -Be 'en-US'
        $result.steps[0].parameters.uiLanguage | Should -Be 'en-US'
    }

    It 'updates ImportAutopilot step with group tag and user email' {
        $ts = @{
            name = 'Test TS'
            steps = @(
                @{ name = 'Autopilot'; type = 'ImportAutopilot'; enabled = $true; parameters = @{} }
            )
        } | ConvertTo-Json -Depth 5
        Set-Content $script:tsFile $ts

        Update-TaskSequenceFromConfig -TaskSequencePath $script:tsFile -Config @{
            AutopilotGroupTag  = 'TestGroup'
            AutopilotUserEmail = 'user@example.com'
        }

        $result = Get-Content $script:tsFile -Raw | ConvertFrom-Json
        $result.steps[0].parameters.groupTag | Should -Be 'TestGroup'
        $result.steps[0].parameters.userEmail | Should -Be 'user@example.com'
    }

    It 'adds parameters property when step has none' {
        $ts = @{
            name = 'Test TS'
            steps = @(
                @{ name = 'SetName'; type = 'SetComputerName'; enabled = $true }
            )
        } | ConvertTo-Json -Depth 5
        Set-Content $script:tsFile $ts

        Update-TaskSequenceFromConfig -TaskSequencePath $script:tsFile -Config @{
            ComputerName = 'TEST-PC'
        }

        $result = Get-Content $script:tsFile -Raw | ConvertFrom-Json
        $result.steps[0].parameters.computerName | Should -Be 'TEST-PC'
    }

    It 'does nothing when steps array is missing' {
        Set-Content $script:tsFile '{"name":"empty"}'
        { Update-TaskSequenceFromConfig -TaskSequencePath $script:tsFile -Config @{ Edition = 'Pro' } } | Should -Not -Throw
    }

    It 'injects ComputerName into unattendContent XML for CustomizeOOBE step' {
        $ts = @{
            name = 'Test TS'
            steps = @(
                @{
                    name = 'OOBE'; type = 'CustomizeOOBE'; enabled = $true
                    parameters = @{ unattendSource = 'default' }
                }
            )
        } | ConvertTo-Json -Depth 5
        Set-Content $script:tsFile $ts

        Update-TaskSequenceFromConfig -TaskSequencePath $script:tsFile -Config @{
            ComputerName = 'OOBE-PC'
        }

        $result = Get-Content $script:tsFile -Raw | ConvertFrom-Json
        $result.steps[0].parameters.unattendContent | Should -Match 'OOBE-PC'
        $result.steps[0].parameters.unattendContent | Should -Match 'specialize'
    }
}
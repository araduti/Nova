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
        $expected = @(
            'Read-TaskSequence', 'Test-StepCondition', 'Invoke-DryRunValidation',
            'Update-TaskSequenceFromConfig', 'Set-NovaVariable', 'Get-NovaVariable',
            'Clear-NovaVariables', 'Get-AllNovaVariables', 'Get-StepsByPhase'
        )
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

    It 'reports error when ApplyImage runs before PartitionDisk' {
        Mock -ModuleName Nova.TaskSequence Write-Step {}
        Mock -ModuleName Nova.TaskSequence Write-Host {}
        Mock -ModuleName Nova.TaskSequence Write-Success {}
        Mock -ModuleName Nova.TaskSequence Write-Warn {}
        Mock -ModuleName Nova.TaskSequence Write-Fail {}
        Mock -ModuleName Nova.TaskSequence Get-Disk { $null }
        Mock -ModuleName Nova.TaskSequence Get-CimInstance { $null }

        $ts = [pscustomobject]@{
            name = 'BadOrder'
            steps = @(
                [pscustomobject]@{ name = 'Apply'; type = 'ApplyImage'; enabled = $true; parameters = [pscustomobject]@{} }
                [pscustomobject]@{ name = 'Partition'; type = 'PartitionDisk'; enabled = $true; parameters = [pscustomobject]@{} }
            )
        }
        { Invoke-DryRunValidation -TaskSequence $ts -ScratchDir '/tmp' -OSDrive 'C' -FirmwareType 'UEFI' -DiskNumber 0 } | Should -Throw '*validation failed*'
    }

    It 'reports error when ApplyImage runs before DownloadImage without imageUrl' {
        Mock -ModuleName Nova.TaskSequence Write-Step {}
        Mock -ModuleName Nova.TaskSequence Write-Host {}
        Mock -ModuleName Nova.TaskSequence Write-Success {}
        Mock -ModuleName Nova.TaskSequence Write-Warn {}
        Mock -ModuleName Nova.TaskSequence Write-Fail {}
        Mock -ModuleName Nova.TaskSequence Get-Disk { $null }
        Mock -ModuleName Nova.TaskSequence Get-CimInstance { $null }

        $ts = [pscustomobject]@{
            name = 'BadOrder2'
            steps = @(
                [pscustomobject]@{ name = 'Apply'; type = 'ApplyImage'; enabled = $true; parameters = [pscustomobject]@{} }
                [pscustomobject]@{ name = 'Download'; type = 'DownloadImage'; enabled = $true; parameters = [pscustomobject]@{} }
            )
        }
        { Invoke-DryRunValidation -TaskSequence $ts -ScratchDir '/tmp' -OSDrive 'C' -FirmwareType 'UEFI' -DiskNumber 0 } | Should -Throw '*validation failed*'
    }

    It 'passes when steps are in correct order' {
        Mock -ModuleName Nova.TaskSequence Write-Step {}
        Mock -ModuleName Nova.TaskSequence Write-Host {}
        Mock -ModuleName Nova.TaskSequence Write-Success {}
        Mock -ModuleName Nova.TaskSequence Write-Warn {}
        Mock -ModuleName Nova.TaskSequence Get-Disk { [pscustomobject]@{ Number = 0; FriendlyName = 'TestDisk'; Size = 256GB; PartitionStyle = 'GPT' } }
        Mock -ModuleName Nova.TaskSequence Get-CimInstance { $null }
        Mock -ModuleName Nova.TaskSequence Get-FileSizeReadable { '256.00 GB' }

        $ts = [pscustomobject]@{
            name = 'GoodOrder'
            steps = @(
                [pscustomobject]@{ name = 'Partition'; type = 'PartitionDisk'; enabled = $true; parameters = [pscustomobject]@{} }
                [pscustomobject]@{ name = 'Download'; type = 'DownloadImage'; enabled = $true; parameters = [pscustomobject]@{ imageUrl = 'http://example.com/img.wim' } }
                [pscustomobject]@{ name = 'Apply'; type = 'ApplyImage'; enabled = $true; parameters = [pscustomobject]@{} }
                [pscustomobject]@{ name = 'Boot'; type = 'SetBootloader'; enabled = $true; parameters = [pscustomobject]@{} }
            )
        }
        { Invoke-DryRunValidation -TaskSequence $ts -ScratchDir '/tmp' -OSDrive 'C' -FirmwareType 'UEFI' -DiskNumber 0 } | Should -Not -Throw
    }

    It 'warns when ApplyImage has no DownloadImage step and no imageUrl' {
        Mock -ModuleName Nova.TaskSequence Write-Step {}
        Mock -ModuleName Nova.TaskSequence Write-Host {}
        Mock -ModuleName Nova.TaskSequence Write-Success {}
        Mock -ModuleName Nova.TaskSequence Write-Warn {}
        Mock -ModuleName Nova.TaskSequence Get-Disk { $null }
        Mock -ModuleName Nova.TaskSequence Get-CimInstance { $null }

        $ts = [pscustomobject]@{
            name = 'NoDownload'
            steps = @(
                [pscustomobject]@{ name = 'Apply'; type = 'ApplyImage'; enabled = $true; parameters = [pscustomobject]@{} }
            )
        }
        # Should not throw (warnings only, no errors)
        { Invoke-DryRunValidation -TaskSequence $ts -ScratchDir '/tmp' -OSDrive 'C' -FirmwareType 'UEFI' -DiskNumber 0 } | Should -Not -Throw
        # Verify that Write-Warn was called with validation warnings
        Should -Invoke Write-Warn -ModuleName Nova.TaskSequence -Times 1
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

Describe 'Set-NovaVariable / Get-NovaVariable' {
    BeforeEach {
        Clear-NovaVariables
    }

    AfterAll {
        Clear-NovaVariables
    }

    It 'stores and retrieves a variable' {
        Mock -ModuleName Nova.TaskSequence Write-Detail {}
        Set-NovaVariable -Name 'TestVar1' -Value 'Alpha'
        $result = Get-NovaVariable -Name 'TestVar1'
        $result | Should -Be 'Alpha'
    }

    It 'overwrites an existing variable' {
        Mock -ModuleName Nova.TaskSequence Write-Detail {}
        Set-NovaVariable -Name 'TestVar2' -Value 'First'
        Set-NovaVariable -Name 'TestVar2' -Value 'Second'
        $result = Get-NovaVariable -Name 'TestVar2'
        $result | Should -Be 'Second'
    }

    It 'allows empty string values' {
        Mock -ModuleName Nova.TaskSequence Write-Detail {}
        Set-NovaVariable -Name 'EmptyVar' -Value ''
        $result = Get-NovaVariable -Name 'EmptyVar'
        $result | Should -Be ''
    }

    It 'sets environment variable in sync' {
        Mock -ModuleName Nova.TaskSequence Write-Detail {}
        Set-NovaVariable -Name 'NOVA_ENV_SYNC_TEST' -Value 'EnvValue'
        try {
            $envVal = [System.Environment]::GetEnvironmentVariable('NOVA_ENV_SYNC_TEST')
            $envVal | Should -Be 'EnvValue'
        } finally {
            [System.Environment]::SetEnvironmentVariable('NOVA_ENV_SYNC_TEST', $null, 'Process')
        }
    }

    It 'falls back to environment variable when not in store' {
        [System.Environment]::SetEnvironmentVariable('NOVA_FALLBACK_TEST', 'FromEnv', 'Process')
        try {
            $result = Get-NovaVariable -Name 'NOVA_FALLBACK_TEST'
            $result | Should -Be 'FromEnv'
        } finally {
            [System.Environment]::SetEnvironmentVariable('NOVA_FALLBACK_TEST', $null, 'Process')
        }
    }

    It 'returns null for unknown variable' {
        $result = Get-NovaVariable -Name 'NOVA_DOES_NOT_EXIST_12345'
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Clear-NovaVariables' {
    It 'removes all stored variables' {
        Mock -ModuleName Nova.TaskSequence Write-Detail {}
        Set-NovaVariable -Name 'ClearTest1' -Value 'A'
        Set-NovaVariable -Name 'ClearTest2' -Value 'B'
        Clear-NovaVariables
        $all = Get-AllNovaVariables
        $all.Count | Should -Be 0
    }
}

Describe 'Get-AllNovaVariables' {
    BeforeEach {
        Clear-NovaVariables
    }

    AfterAll {
        Clear-NovaVariables
    }

    It 'returns a hashtable copy of all variables' {
        Mock -ModuleName Nova.TaskSequence Write-Detail {}
        Set-NovaVariable -Name 'AllTest1' -Value 'X'
        Set-NovaVariable -Name 'AllTest2' -Value 'Y'
        $all = Get-AllNovaVariables
        $all | Should -BeOfType [hashtable]
        $all.Count | Should -Be 2
        $all['AllTest1'] | Should -Be 'X'
        $all['AllTest2'] | Should -Be 'Y'
    }

    It 'returns a copy that does not mutate the store' {
        Mock -ModuleName Nova.TaskSequence Write-Detail {}
        Set-NovaVariable -Name 'CopyTest' -Value 'Original'
        $copy = Get-AllNovaVariables
        $copy['CopyTest'] = 'Mutated'
        $actual = Get-NovaVariable -Name 'CopyTest'
        $actual | Should -Be 'Original'
    }
}

Describe 'Test-StepCondition uses Get-NovaVariable' {
    BeforeEach {
        Clear-NovaVariables
    }

    AfterAll {
        Clear-NovaVariables
    }

    It 'resolves condition from Nova variable store' {
        Mock -ModuleName Nova.TaskSequence Write-Detail {}
        Set-NovaVariable -Name 'OSDComputerName' -Value 'NOVA-PC'
        $cond = [pscustomobject]@{
            type     = 'variable'
            variable = 'OSDComputerName'
            operator = 'equals'
            value    = 'NOVA-PC'
        }
        $result = Test-StepCondition -Condition $cond
        $result | Should -BeTrue
    }

    It 'resolves condition from env var when not in store' {
        $env:NOVA_COND_ENVONLY = 'fromenv'
        try {
            $cond = [pscustomobject]@{
                type     = 'variable'
                variable = 'NOVA_COND_ENVONLY'
                operator = 'equals'
                value    = 'fromenv'
            }
            $result = Test-StepCondition -Condition $cond
            $result | Should -BeTrue
        } finally {
            Remove-Item Env:\NOVA_COND_ENVONLY -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-StepsByPhase' {
    It 'classifies WinPE steps correctly' {
        $ts = [pscustomobject]@{
            name = 'Phase Test'
            steps = @(
                [pscustomobject]@{ name = 'Partition'; type = 'PartitionDisk'; enabled = $true }
                [pscustomobject]@{ name = 'Download';  type = 'DownloadImage'; enabled = $true }
                [pscustomobject]@{ name = 'Apply';     type = 'ApplyImage';    enabled = $true }
                [pscustomobject]@{ name = 'Boot';      type = 'SetBootloader'; enabled = $true }
            )
        }
        $result = Get-StepsByPhase -TaskSequence $ts
        $result.winpe.Count | Should -Be 4
        $result.oobe.Count  | Should -Be 0
    }

    It 'classifies OOBE steps correctly' {
        $ts = [pscustomobject]@{
            name = 'OOBE Test'
            steps = @(
                [pscustomobject]@{ name = 'BitLocker'; type = 'EnableBitLocker';    enabled = $true }
                [pscustomobject]@{ name = 'Scripts';   type = 'RunPostScripts';     enabled = $true }
                [pscustomobject]@{ name = 'Apps';      type = 'InstallApplication'; enabled = $true }
                [pscustomobject]@{ name = 'Updates';   type = 'WindowsUpdate';      enabled = $true }
            )
        }
        $result = Get-StepsByPhase -TaskSequence $ts
        $result.winpe.Count | Should -Be 0
        $result.oobe.Count  | Should -Be 4
    }

    It 'splits mixed step types into correct phases' {
        $ts = [pscustomobject]@{
            name = 'Mixed Test'
            steps = @(
                [pscustomobject]@{ name = 'Partition';  type = 'PartitionDisk';     enabled = $true }
                [pscustomobject]@{ name = 'Download';   type = 'DownloadImage';     enabled = $true }
                [pscustomobject]@{ name = 'Apply';      type = 'ApplyImage';        enabled = $true }
                [pscustomobject]@{ name = 'Drivers';    type = 'InjectDrivers';     enabled = $true }
                [pscustomobject]@{ name = 'BitLocker';  type = 'EnableBitLocker';   enabled = $true }
                [pscustomobject]@{ name = 'PostScript'; type = 'RunPostScripts';    enabled = $true }
            )
        }
        $result = Get-StepsByPhase -TaskSequence $ts
        $result.winpe.Count | Should -Be 4
        $result.oobe.Count  | Should -Be 2
        $result.winpe[0].name | Should -Be 'Partition'
        $result.oobe[0].name  | Should -Be 'BitLocker'
    }

    It 'excludes disabled steps' {
        $ts = [pscustomobject]@{
            name = 'Disabled Test'
            steps = @(
                [pscustomobject]@{ name = 'Partition'; type = 'PartitionDisk'; enabled = $true }
                [pscustomobject]@{ name = 'Skipped';   type = 'DownloadImage'; enabled = $false }
                [pscustomobject]@{ name = 'Updates';   type = 'WindowsUpdate'; enabled = $true }
            )
        }
        $result = Get-StepsByPhase -TaskSequence $ts
        $result.winpe.Count | Should -Be 1
        $result.oobe.Count  | Should -Be 1
    }

    It 'places unknown step types in winpe phase' {
        $ts = [pscustomobject]@{
            name = 'Unknown Type'
            steps = @(
                [pscustomobject]@{ name = 'Custom'; type = 'CustomStep'; enabled = $true }
            )
        }
        $result = Get-StepsByPhase -TaskSequence $ts
        $result.winpe.Count | Should -Be 1
        $result.oobe.Count  | Should -Be 0
    }

    It 'returns empty arrays for empty task sequence' {
        $ts = [pscustomobject]@{
            name = 'Empty'
            steps = @()
        }
        $result = Get-StepsByPhase -TaskSequence $ts
        $result.winpe.Count | Should -Be 0
        $result.oobe.Count  | Should -Be 0
    }
}
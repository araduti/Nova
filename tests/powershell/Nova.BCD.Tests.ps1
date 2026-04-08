#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.BCD module.
.DESCRIPTION
    Tests BCD (Boot Configuration Data) management functions.
    bcdedit.exe is stubbed for cross-platform CI.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Platform" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.BCD" -Force

    # Stub bcdedit.exe on non-Windows
    if (-not (Get-Command bcdedit.exe -ErrorAction SilentlyContinue)) {
        function global:bcdedit.exe { 'The operation completed successfully.' }
    }
    if (-not (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) {
        function global:Confirm-SecureBootUEFI { }
    }
}

Describe 'Module Exports' {
    It 'exports expected functions' {
        $mod = Get-Module Nova.BCD
        $expected = @('Invoke-Bcdedit', 'New-BcdEntry', 'New-BCDRamdiskEntry')
        foreach ($fn in $expected) {
            $mod.ExportedFunctions.Keys | Should -Contain $fn
        }
    }
}

Describe 'Invoke-Bcdedit' {
    It 'returns output from bcdedit on success' {
        Mock -ModuleName Nova.BCD bcdedit.exe { 'The operation completed successfully.' }
        $global:LASTEXITCODE = 0
        $result = Invoke-Bcdedit -Arguments @('/enum')
        $result | Should -Not -BeNullOrEmpty
    }

    It 'throws when bcdedit fails' {
        Mock -ModuleName Nova.BCD bcdedit.exe {
            $global:LASTEXITCODE = 1
            'Error'
        }
        { Invoke-Bcdedit -Arguments @('/bad') } | Should -Throw
    }
}

Describe 'New-BcdEntry' {
    It 'parses GUID from bcdedit output' {
        Mock -ModuleName Nova.BCD Invoke-Bcdedit {
            'The entry {12345678-1234-1234-1234-123456789abc} was successfully created.'
        }
        $result = New-BcdEntry -CreateArgs @('/create', '/d', 'Test') -Confirm:$false
        $result | Should -Be '{12345678-1234-1234-1234-123456789abc}'
    }

    It 'throws when GUID cannot be parsed' {
        Mock -ModuleName Nova.BCD Invoke-Bcdedit { 'No GUID here' }
        { New-BcdEntry -CreateArgs @('/create') -Confirm:$false } | Should -Throw '*Could not parse GUID*'
    }
}
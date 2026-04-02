#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Platform shared module.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Platform" -Force

    # Stub for cross-platform CI — Confirm-SecureBootUEFI only exists on Windows
    if (-not (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) {
        function global:Confirm-SecureBootUEFI { }
    }
}

Describe 'Get-FileSizeReadable' {
    It 'formats gigabytes' {
        Get-FileSizeReadable -Bytes 1073741824 | Should -Be '1.00 GB'
    }

    It 'formats fractional gigabytes' {
        Get-FileSizeReadable -Bytes 1610612736 | Should -Be '1.50 GB'
    }

    It 'formats megabytes' {
        Get-FileSizeReadable -Bytes 1048576 | Should -Be '1.00 MB'
    }

    It 'formats kilobytes' {
        Get-FileSizeReadable -Bytes 1024 | Should -Be '1.00 KB'
    }

    It 'formats bytes' {
        Get-FileSizeReadable -Bytes 42 | Should -Be '42 B'
    }

    It 'handles zero' {
        Get-FileSizeReadable -Bytes 0 | Should -Be '0 B'
    }
}

Describe 'Get-WinPEArchitecture' {
    AfterEach {
        $env:PROCESSOR_ARCHITECTURE = $script:origArch
    }

    BeforeAll {
        $script:origArch = $env:PROCESSOR_ARCHITECTURE
    }

    It 'returns amd64 for AMD64' {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        Get-WinPEArchitecture | Should -Be 'amd64'
    }

    It 'returns x86 for x86' {
        $env:PROCESSOR_ARCHITECTURE = 'x86'
        Get-WinPEArchitecture | Should -Be 'x86'
    }

    It 'throws for unsupported architecture' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'
        { Get-WinPEArchitecture } | Should -Throw '*Unsupported*ARM*'
    }
}

Describe 'Get-FirmwareType' {
    It 'returns UEFI when registry value is 2' {
        Mock -ModuleName Nova.Platform Get-ItemProperty { [pscustomobject]@{ PEFirmwareType = 2 } }
        Get-FirmwareType | Should -Be 'UEFI'
    }

    It 'returns BIOS when registry value is 1' {
        Mock -ModuleName Nova.Platform Get-ItemProperty { [pscustomobject]@{ PEFirmwareType = 1 } }
        Get-FirmwareType | Should -Be 'BIOS'
    }

    It 'falls back to UEFI when Confirm-SecureBootUEFI succeeds' {
        Mock -ModuleName Nova.Platform Get-ItemProperty { throw 'No registry' }
        Mock -ModuleName Nova.Platform Confirm-SecureBootUEFI { $true }
        Get-FirmwareType | Should -Be 'UEFI'
    }

    It 'falls back to BIOS on PlatformNotSupportedException' {
        Mock -ModuleName Nova.Platform Get-ItemProperty { throw 'No registry' }
        Mock -ModuleName Nova.Platform Confirm-SecureBootUEFI { throw [System.PlatformNotSupportedException]::new() }
        Get-FirmwareType | Should -Be 'BIOS'
    }
}

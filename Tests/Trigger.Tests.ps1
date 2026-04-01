#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for Trigger.ps1 utility functions.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force
    Import-ScriptFunctions -Path "$PSScriptRoot/../Trigger.ps1"
}

Describe 'Get-WinPEArchitecture' {
    AfterEach {
        # Restore original value
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
        Mock Get-ItemProperty { [pscustomobject]@{ PEFirmwareType = 2 } }
        Get-FirmwareType | Should -Be 'UEFI'
    }

    It 'returns BIOS when registry value is 1' {
        Mock Get-ItemProperty { [pscustomobject]@{ PEFirmwareType = 1 } }
        Get-FirmwareType | Should -Be 'BIOS'
    }

    It 'falls back to Confirm-SecureBootUEFI when registry unavailable' {
        Mock Get-ItemProperty { throw 'Not found' }
        Mock Confirm-SecureBootUEFI { $true }
        Get-FirmwareType | Should -Be 'UEFI'
    }

    It 'returns BIOS when SecureBoot throws PlatformNotSupportedException' {
        Mock Get-ItemProperty { throw 'Not found' }
        Mock Confirm-SecureBootUEFI { throw [System.PlatformNotSupportedException]::new('Not UEFI') }
        Get-FirmwareType | Should -Be 'BIOS'
    }

    It 'defaults to BIOS on unknown errors' {
        Mock Get-ItemProperty { throw 'Not found' }
        Mock Confirm-SecureBootUEFI { throw [System.InvalidOperationException]::new('Unknown') }
        Mock Write-Warn {}
        Get-FirmwareType | Should -Be 'BIOS'
    }
}

Describe 'Confirm-FileIntegrity' {
    BeforeAll {
        Mock Write-Host {}
    }

    It 'passes when hash matches' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "integrity_$(Get-Random).txt"
        Set-Content -Path $tmp -Value 'hello world' -NoNewline -Encoding UTF8
        $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
        $manifest = [pscustomobject]@{ files = [pscustomobject]@{ 'test.txt' = $hash } }
        try {
            Mock Write-Success {}
            { Confirm-FileIntegrity -Path $tmp -RelativeName 'test.txt' -HashesJson $manifest } |
                Should -Not -Throw
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws and deletes file when hash mismatches' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "integrity_$(Get-Random).txt"
        Set-Content -Path $tmp -Value 'hello world' -NoNewline -Encoding UTF8
        $manifest = [pscustomobject]@{ files = [pscustomobject]@{ 'test.txt' = 'BADHASH' } }
        { Confirm-FileIntegrity -Path $tmp -RelativeName 'test.txt' -HashesJson $manifest } |
            Should -Throw '*Integrity check FAILED*'
        Test-Path $tmp | Should -BeFalse
    }

    It 'throws when file does not exist' {
        $manifest = [pscustomobject]@{ files = [pscustomobject]@{ 'missing.txt' = 'ABC' } }
        { Confirm-FileIntegrity -Path 'C:\nonexistent\file.txt' -RelativeName 'missing.txt' -HashesJson $manifest } |
            Should -Throw '*File not found*'
    }

    It 'throws and deletes file when hash entry is missing from manifest' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "integrity_$(Get-Random).txt"
        Set-Content -Path $tmp -Value 'hello world' -NoNewline -Encoding UTF8
        $manifest = [pscustomobject]@{ files = [pscustomobject]@{} }
        { Confirm-FileIntegrity -Path $tmp -RelativeName 'unknown.txt' -HashesJson $manifest } |
            Should -Throw '*no hash entry found*'
        Test-Path $tmp | Should -BeFalse
    }
}

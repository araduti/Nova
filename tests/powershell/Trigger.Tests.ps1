#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for Trigger.ps1 utility functions.
.DESCRIPTION
    Tests functions that remain in Trigger.ps1 after modularization.
    Get-WinPEArchitecture and Get-FirmwareType tests are in
    Nova.Platform.Tests.ps1.
#>

BeforeAll {
    # Import shared modules first so Trigger.ps1 functions can reference them
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Platform" -Force
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force
    Import-ScriptFunctions -Path "$PSScriptRoot/../../src/scripts/Trigger.ps1"
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

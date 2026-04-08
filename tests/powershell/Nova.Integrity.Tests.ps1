#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Integrity module.
.DESCRIPTION
    Tests the Confirm-FileIntegrity function which verifies SHA256 hashes.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Integrity" -Force
}

Describe 'Confirm-FileIntegrity' {
    BeforeAll {
        Mock -ModuleName Nova.Integrity Write-Success {}
    }

    It 'passes when hash matches' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "integrity_$(Get-Random).txt"
        Set-Content -Path $tmp -Value 'hello world' -NoNewline -Encoding UTF8
        $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
        $manifest = [pscustomobject]@{ files = [pscustomobject]@{ 'test.txt' = $hash } }
        try {
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

    It 'has CmdletBinding attribute' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.CmdletBinding | Should -BeTrue
    }

    It 'requires Path and RelativeName parameters as mandatory' {
        $cmd = Get-Command Confirm-FileIntegrity
        $pathParam = $cmd.Parameters['Path']
        $pathParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory } |
            Should -Not -BeNullOrEmpty
        $relParam = $cmd.Parameters['RelativeName']
        $relParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory } |
            Should -Not -BeNullOrEmpty
    }

    It 'accepts optional HashesJson parameter' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.Parameters.Keys | Should -Contain 'HashesJson'
    }

    It 'has default GitHub parameters for manifest download' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.Parameters.Keys | Should -Contain 'GitHubUser'
        $cmd.Parameters.Keys | Should -Contain 'GitHubRepo'
        $cmd.Parameters.Keys | Should -Contain 'GitHubBranch'
    }

    It 'verifies SHA256 correctly for binary-equivalent content' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "integrity_$(Get-Random).bin"
        # Write known bytes
        [System.IO.File]::WriteAllBytes($tmp, [byte[]](0x48, 0x65, 0x6C, 0x6C, 0x6F))  # "Hello"
        $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
        $manifest = [pscustomobject]@{ files = [pscustomobject]@{ 'binary.bin' = $hash } }
        try {
            { Confirm-FileIntegrity -Path $tmp -RelativeName 'binary.bin' -HashesJson $manifest } |
                Should -Not -Throw
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

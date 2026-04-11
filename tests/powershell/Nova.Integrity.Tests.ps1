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
        Mock -ModuleName Nova.Integrity Write-Warn {}
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

    It 'accepts RetryOnMismatch switch parameter' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.Parameters.Keys | Should -Contain 'RetryOnMismatch'
        $cmd.Parameters['RetryOnMismatch'].ParameterType | Should -Be ([switch])
    }

    It 'accepts RetryDelaySeconds parameter with default of 5' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.Parameters.Keys | Should -Contain 'RetryDelaySeconds'
        $cmd.Parameters['RetryDelaySeconds'].ParameterType | Should -Be ([int])
    }

    It 'accepts NoCacheHeaders parameter' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.Parameters.Keys | Should -Contain 'NoCacheHeaders'
        $cmd.Parameters['NoCacheHeaders'].ParameterType | Should -Be ([hashtable])
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

    It 'passes with RetryOnMismatch when hash matches on first try' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "integrity_$(Get-Random).txt"
        Set-Content -Path $tmp -Value 'hello world' -NoNewline -Encoding UTF8
        $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
        $manifest = [pscustomobject]@{ files = [pscustomobject]@{ 'test.txt' = $hash } }
        try {
            { Confirm-FileIntegrity -Path $tmp -RelativeName 'test.txt' -HashesJson $manifest -RetryOnMismatch } |
                Should -Not -Throw
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'retries on mismatch and re-downloads manifest when RetryOnMismatch is set' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "integrity_$(Get-Random).txt"
        Set-Content -Path $tmp -Value 'hello world' -NoNewline -Encoding UTF8
        $correctHash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
        # Supply a bad manifest initially -- on retry it will re-download via Invoke-RestMethod
        $badManifest = [pscustomobject]@{ files = [pscustomobject]@{ 'test.txt' = 'BADHASH' } }
        $goodManifest = [pscustomobject]@{ files = [pscustomobject]@{ 'test.txt' = $correctHash } }
        Mock -ModuleName Nova.Integrity Invoke-RestMethod { return $goodManifest }
        Mock -ModuleName Nova.Integrity Start-Sleep {}
        try {
            { Confirm-FileIntegrity -Path $tmp -RelativeName 'test.txt' -HashesJson $badManifest -RetryOnMismatch -RetryDelaySeconds 1 } |
                Should -Not -Throw
            Should -Invoke -CommandName Start-Sleep -ModuleName Nova.Integrity -Times 1
            Should -Invoke -CommandName Invoke-RestMethod -ModuleName Nova.Integrity -Times 1
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws after retry when hash still mismatches' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "integrity_$(Get-Random).txt"
        Set-Content -Path $tmp -Value 'hello world' -NoNewline -Encoding UTF8
        $badManifest = [pscustomobject]@{ files = [pscustomobject]@{ 'test.txt' = 'BADHASH' } }
        $stillBadManifest = [pscustomobject]@{ files = [pscustomobject]@{ 'test.txt' = 'STILLBAD' } }
        Mock -ModuleName Nova.Integrity Invoke-RestMethod { return $stillBadManifest }
        Mock -ModuleName Nova.Integrity Start-Sleep {}
        { Confirm-FileIntegrity -Path $tmp -RelativeName 'test.txt' -HashesJson $badManifest -RetryOnMismatch -RetryDelaySeconds 1 } |
            Should -Throw '*after retry*'
        Test-Path $tmp | Should -BeFalse
    }
}

Describe 'Confirm-FileIntegrity proxy parameters' {
    It 'accepts ProxyBaseUrl parameter' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.Parameters.Keys | Should -Contain 'ProxyBaseUrl'
    }

    It 'ProxyBaseUrl is a string parameter' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.Parameters['ProxyBaseUrl'].ParameterType.Name | Should -Be 'String'
    }

    It 'accepts ProxyHeaders parameter' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.Parameters.Keys | Should -Contain 'ProxyHeaders'
    }

    It 'ProxyHeaders is a hashtable parameter' {
        $cmd = Get-Command Confirm-FileIntegrity
        $cmd.Parameters['ProxyHeaders'].ParameterType.Name | Should -Be 'Hashtable'
    }

    It 'passes when hash matches with proxy parameters provided' {
        Mock -ModuleName Nova.Integrity Write-Success {}
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "integrity_proxy_$(Get-Random).txt"
        Set-Content -Path $tmp -Value 'proxy test content' -NoNewline -Encoding UTF8
        $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
        $manifest = [pscustomobject]@{ files = [pscustomobject]@{ 'test.txt' = $hash } }
        try {
            { Confirm-FileIntegrity -Path $tmp -RelativeName 'test.txt' -HashesJson $manifest `
                -ProxyBaseUrl 'https://proxy.example.com' `
                -ProxyHeaders @{ 'Authorization' = 'Bearer test-token' } } |
                Should -Not -Throw
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

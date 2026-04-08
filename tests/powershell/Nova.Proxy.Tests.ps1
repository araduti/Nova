#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Proxy shared module.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Proxy" -Force
}

Describe 'Get-NovaProxy' {
    BeforeEach {
        Import-Module "$PSScriptRoot/../../src/modules/Nova.Proxy" -Force
    }

    It 'returns unconfigured state by default' {
        $result = Get-NovaProxy
        $result.IsConfigured | Should -BeFalse
        $result.ProxyUrl     | Should -BeNullOrEmpty
    }

    It 'returns a hashtable with expected keys' {
        $result = Get-NovaProxy
        $result.Keys | Should -Contain 'ProxyUrl'
        $result.Keys | Should -Contain 'BypassList'
        $result.Keys | Should -Contain 'IsConfigured'
    }
}

Describe 'Set-NovaProxy' {
    BeforeEach {
        Import-Module "$PSScriptRoot/../../src/modules/Nova.Proxy" -Force
    }

    It 'stores and applies proxy URL' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080'
        $result = Get-NovaProxy
        $result.ProxyUrl     | Should -Be 'http://proxy.corp:8080'
        $result.IsConfigured | Should -BeTrue
    }

    It 'applies default bypass list when none specified' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080'
        $result = Get-NovaProxy
        $result.BypassList | Should -Be 'localhost,127.0.0.1'
    }

    It 'stores custom bypass list' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080' -BypassList '*.local,10.0.0.0/8'
        $result = Get-NovaProxy
        $result.BypassList | Should -Be '*.local,10.0.0.0/8'
    }

    It 'sets HTTP_PROXY environment variable' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080'
        $env:HTTP_PROXY | Should -Be 'http://proxy.corp:8080'
    }

    It 'sets HTTPS_PROXY environment variable' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080'
        $env:HTTPS_PROXY | Should -Be 'http://proxy.corp:8080'
    }

    It 'sets NO_PROXY environment variable from bypass list' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080' -BypassList '*.local,10.0.0.0/8'
        $env:NO_PROXY | Should -Be '*.local,10.0.0.0/8'
    }

    It 'sets NO_PROXY to default bypass list when none specified' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080'
        $env:NO_PROXY | Should -Be 'localhost,127.0.0.1'
    }
}

Describe 'Clear-NovaProxy' {
    BeforeEach {
        Import-Module "$PSScriptRoot/../../src/modules/Nova.Proxy" -Force
    }

    It 'resets proxy state to unconfigured' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080'
        Clear-NovaProxy
        $result = Get-NovaProxy
        $result.IsConfigured | Should -BeFalse
        $result.ProxyUrl     | Should -BeNullOrEmpty
        $result.BypassList   | Should -BeNullOrEmpty
    }

    It 'clears HTTP_PROXY environment variable' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080'
        Clear-NovaProxy
        $env:HTTP_PROXY | Should -BeNullOrEmpty
    }

    It 'clears HTTPS_PROXY environment variable' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080'
        Clear-NovaProxy
        $env:HTTPS_PROXY | Should -BeNullOrEmpty
    }

    It 'clears NO_PROXY environment variable' {
        Mock -ModuleName Nova.Proxy Write-Verbose {}
        Set-NovaProxy -ProxyUrl 'http://proxy.corp:8080' -BypassList '*.local'
        Clear-NovaProxy
        $env:NO_PROXY | Should -BeNullOrEmpty
    }
}

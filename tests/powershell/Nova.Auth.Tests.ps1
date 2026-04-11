#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Auth module.
.DESCRIPTION
    Tests the authentication functions -- primarily Invoke-M365Auth
    and Update-M365Token.  Since these functions depend on external
    services (Entra ID) and Edge, tests focus on verifiable logic paths
    and mock external calls.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Auth" -Force

    # $env:TEMP may be null on Linux -- set it for cross-platform testing
    if (-not $env:TEMP) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }
}

Describe 'Invoke-M365Auth' {
    It 'returns Authenticated=$true when auth config is not available' {
        Mock -ModuleName Nova.Auth Write-Verbose {}
        # The function tries to fetch auth.json from GitHub -- with fake user/repo it will fail
        $result = Invoke-M365Auth `
            -GitHubUser 'nonexistent-user-test' `
            -GitHubRepo 'nonexistent-repo-test' `
            -GitHubBranch 'nonexistent-branch'
        $result.Authenticated | Should -BeTrue
        $result.GraphAccessToken | Should -BeNullOrEmpty
    }

    It 'returns Authenticated=$true with WriteStatus callback when auth config is not available' {
        $statusMessages = @()
        $writeStatus = { param([string]$m, [string]$c) $statusMessages += $m }.GetNewClosure()

        $result = Invoke-M365Auth `
            -GitHubUser 'nonexistent-user-test' `
            -GitHubRepo 'nonexistent-repo-test' `
            -GitHubBranch 'nonexistent-branch' `
            -WriteStatus $writeStatus

        $result.Authenticated | Should -BeTrue
        $result.GraphAccessToken | Should -BeNullOrEmpty
        $result.AuthConfig | Should -BeNullOrEmpty
    }

    It 'returns expected hashtable keys' {
        $result = Invoke-M365Auth `
            -GitHubUser 'nonexistent-user-test' `
            -GitHubRepo 'nonexistent-repo-test' `
            -GitHubBranch 'nonexistent-branch'

        $result | Should -BeOfType [hashtable]
        $result.ContainsKey('Authenticated') | Should -BeTrue
        $result.ContainsKey('GraphAccessToken') | Should -BeTrue
        $result.ContainsKey('RefreshToken') | Should -BeTrue
        $result.ContainsKey('ExpiresAt') | Should -BeTrue
        $result.ContainsKey('AuthConfig') | Should -BeTrue
    }

    It 'accepts all callback parameters without error' {
        $result = Invoke-M365Auth `
            -GitHubUser 'nonexistent-user-test' `
            -GitHubRepo 'nonexistent-repo-test' `
            -GitHubBranch 'nonexistent-branch' `
            -EdgeExePath 'C:\nonexistent\msedge.exe' `
            -WriteLog { param($m) } `
            -WriteStatus { param($m, $c) } `
            -UpdateUi { param($p) } `
            -CheckCancelled { $false } `
            -DoEvents { } `
            -PlaySound { param($f, $d) }

        $result.Authenticated | Should -BeTrue
    }
}

Describe 'Update-M365Token' {
    It 'returns null when called with empty refresh token' {
        Mock -ModuleName Nova.Auth Write-Verbose {}
        $result = Update-M365Token -TokenInfo @{
            RefreshToken = ''
            ClientId     = 'test-client-id'
            Scope        = 'openid profile'
        }
        $result | Should -BeNullOrEmpty
    }

    It 'returns null when called with missing ClientId' {
        Mock -ModuleName Nova.Auth Write-Verbose {}
        $result = Update-M365Token -TokenInfo @{
            RefreshToken = 'some-refresh-token'
            ClientId     = ''
            Scope        = 'openid profile'
        }
        $result | Should -BeNullOrEmpty
    }

    It 'returns null when called with null refresh token' {
        Mock -ModuleName Nova.Auth Write-Verbose {}
        $result = Update-M365Token -TokenInfo @{
            RefreshToken = $null
            ClientId     = 'test-client-id'
            Scope        = 'openid profile'
        }
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Module Exports' {
    It 'exports Invoke-M365Auth' {
        $mod = Get-Module Nova.Auth
        $mod.ExportedFunctions.Keys | Should -Contain 'Invoke-M365Auth'
    }

    It 'exports Update-M365Token' {
        $mod = Get-Module Nova.Auth
        $mod.ExportedFunctions.Keys | Should -Contain 'Update-M365Token'
    }

    It 'does not export removed legacy functions' {
        $mod = Get-Module Nova.Auth
        $mod.ExportedFunctions.Keys | Should -Not -Contain 'Invoke-M365DeviceCodeAuth'
        $mod.ExportedFunctions.Keys | Should -Not -Contain 'Invoke-KioskM365Auth'
        $mod.ExportedFunctions.Keys | Should -Not -Contain 'Invoke-KioskEdgeAuth'
        $mod.ExportedFunctions.Keys | Should -Not -Contain 'Invoke-KioskDeviceCodeAuth'
    }

    It 'does not export private helpers' {
        $mod = Get-Module Nova.Auth
        $mod.ExportedFunctions.Keys | Should -Not -Contain '_EdgeAppAuth'
        $mod.ExportedFunctions.Keys | Should -Not -Contain '_FetchAuthConfig'
        $mod.ExportedFunctions.Keys | Should -Not -Contain '_HasProp'
    }

    It 'does not export removed WebView2 functions' {
        $mod = Get-Module Nova.Auth
        $mod.ExportedFunctions.Keys | Should -Not -Contain 'Install-WebView2SDK'
        $mod.ExportedFunctions.Keys | Should -Not -Contain 'Show-WebView2AuthPopup'
    }
}

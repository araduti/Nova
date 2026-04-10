#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Auth module.
.DESCRIPTION
    Tests the authentication functions — primarily Install-WebView2SDK and
    Invoke-M365DeviceCodeAuth.  Since these functions depend on external
    services (NuGet, Azure AD) and GUI components (WebView2, WinForms),
    tests focus on verifiable logic paths and mock external calls.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Auth" -Force

    # $env:TEMP may be null on Linux — set it for cross-platform testing
    if (-not $env:TEMP) {
        $env:TEMP = [System.IO.Path]::GetTempPath()
    }
}

Describe 'Install-WebView2SDK' {
    It 'returns cached path when core DLL already exists' {
        $sdkDir  = Join-Path ([System.IO.Path]::GetTempPath()) 'Nova-WebView2SDK'
        $coreDll = Join-Path $sdkDir 'Microsoft.Web.WebView2.Core.dll'
        # Create a fake cached copy for the test
        $null = New-Item -ItemType Directory -Path $sdkDir -Force
        $null = New-Item -ItemType File -Path $coreDll -Force
        try {
            $result = Install-WebView2SDK
            $result | Should -Be $sdkDir
        } finally {
            Remove-Item $coreDll -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-M365DeviceCodeAuth' {
    It 'returns Authenticated=$true when auth config is not available' {
        Mock -ModuleName Nova.Auth Write-Verbose {}
        # The function tries to fetch auth.json from GitHub — with fake user/repo it will fail
        $result = Invoke-M365DeviceCodeAuth `
            -GitHubUser 'nonexistent-user-test' `
            -GitHubRepo 'nonexistent-repo-test' `
            -GitHubBranch 'nonexistent-branch'
        $result.Authenticated | Should -BeTrue
        $result.GraphAccessToken | Should -BeNullOrEmpty
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

Describe 'Module Exports - Kiosk Auth' {
    It 'exports kiosk auth functions' {
        $mod = Get-Module Nova.Auth
        $expected = @('Invoke-KioskEdgeAuth', 'Invoke-KioskDeviceCodeAuth', 'Invoke-KioskM365Auth')
        foreach ($fn in $expected) {
            $mod.ExportedFunctions.Keys | Should -Contain $fn
        }
    }
}

Describe 'Invoke-KioskEdgeAuth' {
    It 'returns failure when Edge binary does not exist' {
        $logMessages = @()
        $writeLog = { param([string]$m) $logMessages += $m }.GetNewClosure()

        $result = Invoke-KioskEdgeAuth `
            -ClientId 'test-client-id' `
            -EdgeExePath 'C:\nonexistent\msedge.exe' `
            -WriteLog $writeLog

        $result.Success | Should -BeFalse
        $result.GraphAccessToken | Should -BeNullOrEmpty
    }

    It 'returns expected hashtable keys' {
        $result = Invoke-KioskEdgeAuth `
            -ClientId 'test-client-id' `
            -EdgeExePath 'C:\nonexistent\msedge.exe'

        $result | Should -BeOfType [hashtable]
        $result.ContainsKey('Success') | Should -BeTrue
        $result.ContainsKey('GraphAccessToken') | Should -BeTrue
    }
}

Describe 'Invoke-KioskDeviceCodeAuth' {
    It 'returns failure when device code endpoint is unreachable' {
        $logMessages = @()
        $writeLog = { param([string]$m) $logMessages += $m }.GetNewClosure()

        # Mock the WebClient to simulate a failure
        Mock -ModuleName Nova.Auth -CommandName 'New-Object' -ParameterFilter {
            $TypeName -eq 'System.Net.WebClient'
        } -MockWith {
            $mock = [PSCustomObject]@{}
            $mock | Add-Member -MemberType ScriptMethod -Name 'UploadString' -Value {
                throw 'Connection refused'
            }
            $mock | Add-Member -MemberType NoteProperty -Name 'Headers' -Value @{}
            $mock.Headers | Add-Member -MemberType ScriptMethod -Name 'Add' -Value { param($k,$v) } -Force
            return $mock
        }

        $result = Invoke-KioskDeviceCodeAuth `
            -ClientId 'test-client-id' `
            -WriteLog $writeLog

        $result.Success | Should -BeFalse
        $result.GraphAccessToken | Should -BeNullOrEmpty
    }

    It 'returns expected hashtable keys' {
        Mock -ModuleName Nova.Auth -CommandName 'New-Object' -ParameterFilter {
            $TypeName -eq 'System.Net.WebClient'
        } -MockWith {
            $mock = [PSCustomObject]@{}
            $mock | Add-Member -MemberType ScriptMethod -Name 'UploadString' -Value {
                throw 'Connection refused'
            }
            $mock | Add-Member -MemberType NoteProperty -Name 'Headers' -Value @{}
            $mock.Headers | Add-Member -MemberType ScriptMethod -Name 'Add' -Value { param($k,$v) } -Force
            return $mock
        }

        $result = Invoke-KioskDeviceCodeAuth -ClientId 'test-client-id'
        $result | Should -BeOfType [hashtable]
        $result.ContainsKey('Success') | Should -BeTrue
        $result.ContainsKey('GraphAccessToken') | Should -BeTrue
    }
}

Describe 'Invoke-KioskM365Auth' {
    It 'returns Authenticated=$true when auth config is not available' {
        $statusMessages = @()
        $writeStatus = { param([string]$m, [string]$c) $statusMessages += $m }.GetNewClosure()

        $result = Invoke-KioskM365Auth `
            -GitHubUser 'nonexistent-user-test' `
            -GitHubRepo 'nonexistent-repo-test' `
            -GitHubBranch 'nonexistent-branch' `
            -WriteStatus $writeStatus

        $result.Authenticated | Should -BeTrue
        $result.GraphAccessToken | Should -BeNullOrEmpty
        $result.AuthConfig | Should -BeNullOrEmpty
    }

    It 'returns expected hashtable keys' {
        $result = Invoke-KioskM365Auth `
            -GitHubUser 'nonexistent-user-test' `
            -GitHubRepo 'nonexistent-repo-test' `
            -GitHubBranch 'nonexistent-branch'

        $result | Should -BeOfType [hashtable]
        $result.ContainsKey('Authenticated') | Should -BeTrue
        $result.ContainsKey('GraphAccessToken') | Should -BeTrue
        $result.ContainsKey('AuthConfig') | Should -BeTrue
    }

    It 'accepts all callback parameters without error' {
        $result = Invoke-KioskM365Auth `
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

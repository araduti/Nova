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

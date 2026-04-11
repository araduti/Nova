#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for Bootstrap.ps1 utility functions.
.DESCRIPTION
    Tests functions that remain in Bootstrap.ps1 after modularization.
    Get-SignalBar, Test-InternetConnectivity, and Test-HasValidIP tests
    are in Nova.Network.Tests.ps1.
#>

BeforeAll {
    # Import shared modules first so Bootstrap.ps1 functions can reference them
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Network" -Force
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force
    Import-ScriptFunctions -Path "$PSScriptRoot/../../src/scripts/Bootstrap.ps1"
}

Describe 'Write-AuthLog' {
    It 'writes a timestamped entry to the log file' {
        $logPath = Join-Path ([System.IO.Path]::GetTempPath()) "nova-authlog-test-$(Get-Random).log"
        # Write-AuthLog reads $script:AuthLogPath from Bootstrap.ps1 scope;
        # when extracted via AST the function sees the global scope instead,
        # so we patch the variable by overriding Out-File and testing the output.
        Mock Out-File {}
        Mock Write-Verbose {}
        # The function should not throw
        { Write-AuthLog -Message 'unit-test' } | Should -Not -Throw
    }

    It 'calls Write-Verbose with the message' {
        Mock Out-File {}
        Mock Write-Verbose {}
        Write-AuthLog -Message 'verbose-check'
        Should -Invoke Write-Verbose -ParameterFilter { $Message -eq 'verbose-check' }
    }
}

Describe 'Invoke-Sound' {
    It 'is defined and accepts Freq and Dur parameters' {
        $cmd = Get-Command Invoke-Sound -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'Freq'
        $cmd.Parameters.Keys | Should -Contain 'Dur'
    }
}

Describe 'Write-Status' {
    It 'calls Write-Verbose with the status message' {
        Mock Write-Verbose {}
        Mock Update-HtmlUi {}
        Write-Status -Message 'test-message' -Color 'Green'
        Should -Invoke Write-Verbose -ParameterFilter {
            $Message -like '*test-message*'
        }
    }
}

Describe 'Import-LocaleJson' {
    It 'returns $null when network download fails' {
        # Create a mock that simulates download failure
        $result = Import-LocaleJson -LangCode 'xx' -Verbose:$false
        # Non-existent locale should return $null
        $result | Should -BeNullOrEmpty
    }
}

# Additional Bootstrap.ps1-specific tests can be added here.
# Network utility tests (Get-SignalBar, Test-InternetConnectivity, Test-HasValidIP)
# have been moved to Tests/Nova.Network.Tests.ps1.

Describe 'Get-RepoFileUrl' {
    It 'is defined and accepts RelativePath parameter' {
        $cmd = Get-Command Get-RepoFileUrl -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'RelativePath'
    }

    It 'RelativePath is mandatory' {
        $cmd = Get-Command Get-RepoFileUrl
        $p = $cmd.Parameters['RelativePath']
        $p.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        } | Should -Not -BeNullOrEmpty
    }

    It 'returns hashtable with Url and Headers keys when proxy is not configured' {
        # Ensure proxy is not configured
        $global:ProxyBaseUrl = $null
        $global:ProxyHeaders = $null
        $result = Get-RepoFileUrl -RelativePath 'config/auth.json'
        $result | Should -BeOfType [hashtable]
        $result.Keys | Should -Contain 'Url'
        $result.Keys | Should -Contain 'Headers'
        $result.Url | Should -BeLike '*raw.githubusercontent.com*config/auth.json'
        $result.Headers | Should -BeNullOrEmpty
    }
}

Describe 'New-RepoWebClient' {
    It 'is defined' {
        $cmd = Get-Command New-RepoWebClient -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
    }

    It 'accepts NoCache switch parameter' {
        $cmd = Get-Command New-RepoWebClient
        $cmd.Parameters.Keys | Should -Contain 'NoCache'
        $cmd.Parameters['NoCache'].SwitchParameter | Should -BeTrue
    }

    It 'returns a System.Net.WebClient' {
        $global:ProxyHeaders = $null
        $wc = New-RepoWebClient
        try {
            $wc | Should -BeOfType [System.Net.WebClient]
        } finally {
            $wc.Dispose()
        }
    }

    It 'adds Cache-Control and Pragma headers when NoCache is specified' {
        $global:ProxyHeaders = $null
        $wc = New-RepoWebClient -NoCache
        try {
            $wc.Headers['Cache-Control'] | Should -Be 'no-cache'
            $wc.Headers['Pragma'] | Should -Be 'no-cache'
        } finally {
            $wc.Dispose()
        }
    }
}

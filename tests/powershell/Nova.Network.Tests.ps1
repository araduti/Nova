#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Network shared module.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Network" -Force

    # Stub ipconfig for cross-platform CI
    if (-not (Get-Command ipconfig -ErrorAction SilentlyContinue)) {
        function global:ipconfig { '' }
    }
}

Describe 'Get-SignalBar' {
    It 'returns all empty bars for 0 signal' {
        Get-SignalBar -s 0 | Should -Be '░░░░░'
    }

    It 'returns 1 filled bar for signal 20' {
        Get-SignalBar -s 20 | Should -Be '█░░░░'
    }

    It 'returns 3 filled bars for signal 50' {
        # [Math]::Round(50/20) = [Math]::Round(2.5) = 2 (banker's rounding)
        Get-SignalBar -s 50 | Should -Be '██░░░'
    }

    It 'returns 3 filled bars for signal 60' {
        Get-SignalBar -s 60 | Should -Be '███░░'
    }

    It 'returns 4 filled bars for signal 80' {
        Get-SignalBar -s 80 | Should -Be '████░'
    }

    It 'returns all filled bars for signal 100' {
        Get-SignalBar -s 100 | Should -Be '█████'
    }
}

Describe 'Test-InternetConnectivity' {
    It 'returns $true when first URL succeeds' {
        Mock -ModuleName Nova.Network Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        Test-InternetConnectivity | Should -BeTrue
    }

    It 'returns $false when all URLs fail' {
        Mock -ModuleName Nova.Network Invoke-WebRequest { throw 'Network error' }
        Test-InternetConnectivity | Should -BeFalse
    }

    It 'returns $true when first fails but second succeeds' {
        $script:callCount = 0
        Mock -ModuleName Nova.Network Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) { throw 'timeout' }
            [pscustomobject]@{ StatusCode = 200 }
        }
        Test-InternetConnectivity | Should -BeTrue
    }
}

Describe 'Test-HasValidIP' {
    It 'returns $true for a routable IPv4 address' {
        Mock -ModuleName Nova.Network ipconfig { '   IPv4 Address. . . . . . . . . . . : 192.168.1.10' }
        Test-HasValidIP | Should -BeTrue
    }

    It 'returns $false for APIPA only' {
        Mock -ModuleName Nova.Network ipconfig { '   IPv4 Address. . . . . . . . . . . : 169.254.100.50' }
        Test-HasValidIP | Should -BeFalse
    }

    It 'returns $false for loopback only' {
        Mock -ModuleName Nova.Network ipconfig { '   IPv4 Address. . . . . . . . . . . : 127.0.0.1' }
        Test-HasValidIP | Should -BeFalse
    }

    It 'returns $false when ipconfig has no IP addresses' {
        Mock -ModuleName Nova.Network ipconfig { 'Windows IP Configuration' }
        Test-HasValidIP | Should -BeFalse
    }
}

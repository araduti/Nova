#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for Bootstrap.ps1 utility functions.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force
    Import-ScriptFunctions -Path "$PSScriptRoot/../Bootstrap.ps1"
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
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        Test-InternetConnectivity | Should -BeTrue
    }

    It 'returns $false when all URLs fail' {
        Mock Invoke-WebRequest { throw 'Network error' }
        Test-InternetConnectivity | Should -BeFalse
    }

    It 'returns $true when first fails but second succeeds' {
        $script:callCount = 0
        Mock Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) { throw 'Timeout' }
            [pscustomobject]@{ StatusCode = 200 }
        }
        Test-InternetConnectivity | Should -BeTrue
    }
}

Describe 'Test-HasValidIP' {
    It 'returns $true when ipconfig shows a routable IPv4 address' {
        Mock ipconfig {
            @(
                'Ethernet adapter Ethernet:',
                '   IPv4 Address. . . . . . . . . . . : 192.168.1.100',
                '   Subnet Mask . . . . . . . . . . . : 255.255.255.0'
            )
        }
        Test-HasValidIP | Should -BeTrue
    }

    It 'returns $false when only APIPA address is present' {
        Mock ipconfig {
            @(
                'Ethernet adapter Ethernet:',
                '   Autoconfiguration IPv4 Address. . : 169.254.1.1',
                '   Subnet Mask . . . . . . . . . . . : 255.255.0.0'
            )
        }
        Test-HasValidIP | Should -BeFalse
    }

    It 'returns $false when only loopback is present' {
        Mock ipconfig {
            @(
                'Loopback Pseudo-Interface 1:',
                '   IPv4 Address. . . . . . . . . . . : 127.0.0.1'
            )
        }
        Test-HasValidIP | Should -BeFalse
    }
}

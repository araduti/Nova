#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Logging shared module.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
}

Describe 'Write-Step' {
    It 'writes cyan message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Step 'Installing drivers'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[>\] Installing drivers' -and $ForegroundColor -eq 'Cyan'
        }
    }
}

Describe 'Write-Success' {
    It 'writes green message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Success 'Done'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[\+\] Done' -and $ForegroundColor -eq 'Green'
        }
    }
}

Describe 'Write-Warn' {
    It 'writes yellow message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Warn 'Low disk'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[!\] Low disk' -and $ForegroundColor -eq 'Yellow'
        }
    }
}

Describe 'Write-Fail' {
    It 'writes red message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Fail 'Crash'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[X\] Crash' -and $ForegroundColor -eq 'Red'
        }
    }
}

Describe 'Set-NovaLogPrefix' {
    BeforeEach {
        # Reset to defaults
        Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    }

    It 'overrides the Write-Step prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Step '[Nova]'
        Write-Step 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[Nova\] test'
        }
    }

    It 'overrides the Write-Success prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Success '[OK]'
        Write-Success 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[OK\] test'
        }
    }

    It 'overrides the Write-Warn prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Warn '[WARN]'
        Write-Warn 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[WARN\] test'
        }
    }

    It 'overrides the Write-Fail prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Fail '[FAIL]'
        Write-Fail 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[FAIL\] test'
        }
    }
}

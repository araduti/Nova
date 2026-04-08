#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.ADK module.
.DESCRIPTION
    Tests the ADK detection and WinPE workspace creation functions.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.ADK" -Force
}

Describe 'Get-ADKRoot' {
    It 'returns $null when no ADK registry key exists' {
        Mock -ModuleName Nova.ADK Test-Path { $false } -ParameterFilter {
            $Path -like 'HKLM:\SOFTWARE*Windows Kits*'
        }
        Get-ADKRoot | Should -BeNullOrEmpty
    }

    It 'returns trimmed path when registry key exists' {
        Mock -ModuleName Nova.ADK Test-Path { $true }
        Mock -ModuleName Nova.ADK Get-ItemProperty {
            [pscustomobject]@{ KitsRoot10 = 'C:\Program Files (x86)\Windows Kits\10\' }
        }
        Get-ADKRoot | Should -Be 'C:\Program Files (x86)\Windows Kits\10'
    }

    It 'returns $null when KitsRoot10 property is empty' {
        Mock -ModuleName Nova.ADK Test-Path { $true }
        Mock -ModuleName Nova.ADK Get-ItemProperty {
            [pscustomobject]@{ KitsRoot10 = '' }
        }
        Get-ADKRoot | Should -BeNullOrEmpty
    }

    It 'checks WOW6432Node path as fallback' {
        # First reg path fails, second succeeds
        $callCount = 0
        Mock -ModuleName Nova.ADK Test-Path {
            $script:callCount++
            return $true
        }
        Mock -ModuleName Nova.ADK Get-ItemProperty {
            [pscustomobject]@{ KitsRoot10 = 'C:\Windows Kits\10\' }
        }
        $result = Get-ADKRoot
        $result | Should -Not -BeNullOrEmpty
    }

    It 'has CmdletBinding attribute' {
        $cmd = Get-Command Get-ADKRoot
        $cmd.CmdletBinding | Should -BeTrue
    }
}

Describe 'Assert-ADKInstalled' {
    It 'returns existing ADK root when already installed' {
        Mock -ModuleName Nova.ADK Write-Step {}
        Mock -ModuleName Nova.ADK Write-Success {}
        # Use a temp dir that actually exists on the CI runner
        $fakeAdkRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'FakeADKInstalled'
        Mock -ModuleName Nova.ADK Get-ADKRoot { $fakeAdkRoot }
        Mock -ModuleName Nova.ADK Test-Path { $true }
        Mock -ModuleName Nova.ADK Join-Path { '/fake/joined/path' }
        $result = Assert-ADKInstalled -Architecture 'amd64'
        $result | Should -Be $fakeAdkRoot
    }

    It 'supports ShouldProcess (has SupportsShouldProcess attribute)' {
        $cmd = Get-Command Assert-ADKInstalled
        $cmd.CmdletBinding | Should -BeTrue
        $meta = [System.Management.Automation.CommandMetadata]::new($cmd)
        $meta.SupportsShouldProcess | Should -BeTrue
    }
}

Describe 'Copy-WinPEFile' {
    It 'throws when architecture source directory does not exist' {
        Mock -ModuleName Nova.ADK Write-Step {}
        $fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'FakeADK'
        { Copy-WinPEFile -ADKRoot $fakeRoot -Destination (Join-Path ([System.IO.Path]::GetTempPath()) 'FakeDest') -Architecture 'amd64' } |
            Should -Throw '*WinPE source not found*'
    }

    It 'supports ShouldProcess (has SupportsShouldProcess attribute)' {
        $cmd = Get-Command Copy-WinPEFile
        $cmd.CmdletBinding | Should -BeTrue
        $meta = [System.Management.Automation.CommandMetadata]::new($cmd)
        $meta.SupportsShouldProcess | Should -BeTrue
    }

    It 'accepts Architecture parameter with validation set' {
        $cmd = Get-Command Copy-WinPEFile
        $archParam = $cmd.Parameters['Architecture']
        $archParam | Should -Not -BeNullOrEmpty
        $validateSet = $archParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet | Should -Not -BeNullOrEmpty
        $validateSet.ValidValues | Should -Contain 'amd64'
        $validateSet.ValidValues | Should -Contain 'x86'
    }
}

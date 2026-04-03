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
}

Describe 'Copy-WinPEFile' {
    It 'throws when architecture source directory does not exist' {
        Mock -ModuleName Nova.ADK Write-Step {}
        $fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'FakeADK'
        { Copy-WinPEFile -ADKRoot $fakeRoot -Destination (Join-Path ([System.IO.Path]::GetTempPath()) 'FakeDest') -Architecture 'amd64' } |
            Should -Throw '*WinPE source not found*'
    }
}

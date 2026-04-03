#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.BuildConfig module.
.DESCRIPTION
    Tests build configuration persistence and package path resolution.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.BuildConfig" -Force
}

Describe 'Get-BuildConfigPath' {
    It 'returns a path under APPDATA when APPDATA is set' {
        $result = Get-BuildConfigPath
        if ($env:APPDATA) {
            $result | Should -BeLike '*Nova*last-build-config.json'
        } else {
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Save-BuildConfiguration and Read-SavedBuildConfiguration' {
    BeforeAll {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova_test_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $script:testConfigPath = Join-Path $testDir 'last-build-config.json'
    }

    AfterAll {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'round-trips a configuration through save and load' {
        Mock -ModuleName Nova.BuildConfig Get-BuildConfigPath { $script:testConfigPath }

        $config = @{
            Language         = 'de-de'
            Packages         = @('WinPE-PowerShell', 'WinPE-WMI')
            InjectVirtIO     = $false
            ExtraDriverPaths = @('C:\Drivers')
        }
        Save-BuildConfiguration -Config $config

        $loaded = Read-SavedBuildConfiguration
        $loaded.Language | Should -Be 'de-de'
        $loaded.Packages | Should -Contain 'WinPE-PowerShell'
        $loaded.Packages | Should -Contain 'WinPE-WMI'
        $loaded.InjectVirtIO | Should -BeFalse
        $loaded.ExtraDriverPaths | Should -Contain 'C:\Drivers'
    }
}

Describe 'Resolve-WinPEPackagePath' {
    It 'expands package names into base cab + language cab pairs' {
        $result = Resolve-WinPEPackagePath -PackageNames @('WinPE-PowerShell') -Language 'en-us'
        $result | Should -HaveCount 2
        $result[0] | Should -Be 'WinPE-PowerShell.cab'
        $result[1] | Should -Be 'en-us\WinPE-PowerShell_en-us.cab'
    }

    It 'handles multiple packages in order' {
        $result = Resolve-WinPEPackagePath -PackageNames @('WinPE-WMI', 'WinPE-PowerShell') -Language 'de-de'
        $result | Should -HaveCount 4
        $result[0] | Should -Be 'WinPE-WMI.cab'
        $result[1] | Should -Be 'de-de\WinPE-WMI_de-de.cab'
        $result[2] | Should -Be 'WinPE-PowerShell.cab'
        $result[3] | Should -Be 'de-de\WinPE-PowerShell_de-de.cab'
    }
}

Describe 'Get-DefaultLanguage' {
    It 'returns en-us' {
        Get-DefaultLanguage | Should -Be 'en-us'
    }
}

Describe 'Get-AvailableWinPEPackages' {
    It 'returns a non-empty array of package definitions' {
        $pkgs = Get-AvailableWinPEPackages
        $pkgs.Count | Should -BeGreaterThan 0
    }

    It 'includes WinPE-PowerShell as a required package' {
        $pkgs = Get-AvailableWinPEPackages
        $ps = $pkgs | Where-Object { $_.Name -eq 'WinPE-PowerShell' }
        $ps | Should -Not -BeNullOrEmpty
        $ps.Required | Should -BeTrue
    }
}

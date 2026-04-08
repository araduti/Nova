#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Drivers module.
.DESCRIPTION
    Tests OEM driver detection and injection functions.
    Windows-only cmdlets are stubbed for cross-platform CI.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Drivers" -Force

    # Stubs for Windows-only cmdlets
    if (-not (Get-Command Add-WindowsDriver -ErrorAction SilentlyContinue)) {
        function global:Add-WindowsDriver { param($Path, $Driver, [switch]$Recurse) }
    }
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance { param($ClassName) }
    }
}

Describe 'Module Exports' {
    It 'exports expected functions' {
        $mod = Get-Module Nova.Drivers
        $expected = @(
            'Add-Driver'
            'Initialize-NuGetProvider'
            'Install-OemModule'
            'Get-SystemManufacturer'
            'Add-DellDriver'
            'Add-HpDriver'
            'Add-LenovoDriver'
            'Add-SurfaceDriver'
            'Invoke-OemDriverInjection'
        )
        foreach ($fn in $expected) {
            $mod.ExportedFunctions.Keys | Should -Contain $fn
        }
    }
}

Describe 'Add-Driver' {
    It 'skips injection when DriverPath is empty' {
        Mock -ModuleName Nova.Drivers Write-Warn {}
        Add-Driver -DriverPath '' -OSDriveLetter 'C'
        Should -Invoke -ModuleName Nova.Drivers Write-Warn -Times 1
    }

    It 'skips injection when DriverPath does not exist' {
        Mock -ModuleName Nova.Drivers Write-Warn {}
        Mock -ModuleName Nova.Drivers Test-Path { $false }
        Add-Driver -DriverPath '/nonexistent/path' -OSDriveLetter 'C'
        Should -Invoke -ModuleName Nova.Drivers Write-Warn -Times 1
    }
}

Describe 'Get-SystemManufacturer' {
    It 'returns trimmed manufacturer string' {
        Mock -ModuleName Nova.Drivers Get-CimInstance {
            [pscustomobject]@{ Manufacturer = '  Dell Inc.  ' }
        }
        $result = Get-SystemManufacturer
        $result | Should -Be 'Dell Inc.'
    }

    It 'returns empty string when CIM fails' {
        Mock -ModuleName Nova.Drivers Get-CimInstance { $null }
        $result = Get-SystemManufacturer
        $result | Should -Be ''
    }
}

Describe 'Invoke-OemDriverInjection' {
    It 'calls Add-DellDriver for Dell manufacturer' {
        Mock -ModuleName Nova.Drivers Write-Step {}
        Mock -ModuleName Nova.Drivers Write-Host {}
        Mock -ModuleName Nova.Drivers Get-SystemManufacturer { 'Dell Inc.' }
        Mock -ModuleName Nova.Drivers Add-DellDriver {}
        Invoke-OemDriverInjection -OSDriveLetter 'C' -ScratchDir '/tmp/scratch'
        Should -Invoke -ModuleName Nova.Drivers Add-DellDriver -Times 1
    }

    It 'warns for unsupported manufacturer' {
        Mock -ModuleName Nova.Drivers Write-Step {}
        Mock -ModuleName Nova.Drivers Write-Host {}
        Mock -ModuleName Nova.Drivers Write-Warn {}
        Mock -ModuleName Nova.Drivers Get-SystemManufacturer { 'Acme Corp' }
        Invoke-OemDriverInjection -OSDriveLetter 'C' -ScratchDir '/tmp/scratch'
        Should -Invoke -ModuleName Nova.Drivers Write-Warn -Times 1
    }

    It 'calls Add-HpDriver for HP manufacturer' {
        Mock -ModuleName Nova.Drivers Write-Step {}
        Mock -ModuleName Nova.Drivers Write-Host {}
        Mock -ModuleName Nova.Drivers Get-SystemManufacturer { 'HP' }
        Mock -ModuleName Nova.Drivers Add-HpDriver {}
        Invoke-OemDriverInjection -OSDriveLetter 'C' -ScratchDir '/tmp/scratch'
        Should -Invoke -ModuleName Nova.Drivers Add-HpDriver -Times 1
    }
}

Describe 'Initialize-NuGetProvider' {
    It 'does not install when NuGet is already present' {
        Mock -ModuleName Nova.Drivers Get-PackageProvider { [pscustomobject]@{ Name = 'NuGet' } }
        Mock -ModuleName Nova.Drivers Get-PSRepository { [pscustomobject]@{ Name = 'PSGallery'; InstallationPolicy = 'Trusted' } }
        Mock -ModuleName Nova.Drivers Install-PackageProvider {}
        Initialize-NuGetProvider
        Should -Invoke -ModuleName Nova.Drivers Install-PackageProvider -Times 0
    }
}

Describe 'Install-OemModule' {
    It 'installs module when not already available' {
        Mock -ModuleName Nova.Drivers Get-Module { $null }
        Mock -ModuleName Nova.Drivers Write-Host {}
        Mock -ModuleName Nova.Drivers Initialize-NuGetProvider {}
        Mock -ModuleName Nova.Drivers Install-Module {}
        Install-OemModule -Name 'TestModule'
        Should -Invoke -ModuleName Nova.Drivers Install-Module -Times 1
    }
}
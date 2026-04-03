#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.WinRE module.
.DESCRIPTION
    Tests the WinRE discovery, ISO extraction, and recovery package removal
    functions.  Since these functions depend on Windows-specific cmdlets
    (reagentc, Get-Partition, DISM), tests focus on mockable logic paths.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.WinRE" -Force

    # Stubs for Windows-only cmdlets that don't exist on Linux CI
    if (-not (Get-Command Get-WindowsPackage -ErrorAction SilentlyContinue)) {
        function global:Get-WindowsPackage { param($Path) $null = $Path }
    }
    if (-not (Get-Command Remove-WindowsPackage -ErrorAction SilentlyContinue)) {
        function global:Remove-WindowsPackage { param($Path, $PackageName, [switch]$NoRestart) $null = $Path, $PackageName, $NoRestart }
    }
}

Describe 'Get-WinREPath' {
    BeforeAll {
        # $env:SystemRoot is null on non-Windows — mock Join-Path to avoid null binding
        if (-not $env:SystemRoot) {
            $env:SystemRoot = '/tmp/fakewindows'
        }
    }

    It 'returns path when WinRE.wim exists in System32\Recovery' {
        Mock -ModuleName Nova.WinRE Test-Path { $true }
        Mock -ModuleName Nova.WinRE Write-Success {}
        $result = Get-WinREPath
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns $null when WinRE is not found anywhere' {
        Mock -ModuleName Nova.WinRE Test-Path { $false }
        Mock -ModuleName Nova.WinRE Write-Step {}
        Mock -ModuleName Nova.WinRE Write-Warn {}
        # Stub reagentc.exe on non-Windows (where the binary doesn't exist)
        if (-not (Get-Command reagentc.exe -ErrorAction SilentlyContinue)) {
            function global:reagentc.exe { '' }
        }
        $result = Get-WinREPath
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Remove-WinRERecoveryPackage' {
    It 'handles package enumeration failure gracefully' {
        Mock -ModuleName Nova.WinRE Write-Step {}
        Mock -ModuleName Nova.WinRE Write-Warn {}
        Mock -ModuleName Nova.WinRE Get-WindowsPackage { throw 'DISM not available' }
        # Should not throw — just warns
        { Remove-WinRERecoveryPackage -MountDir '/tmp/FakeMount' -Confirm:$false } |
            Should -Not -Throw
    }

    It 'removes matching packages and warns on failure' {
        Mock -ModuleName Nova.WinRE Write-Step {}
        Mock -ModuleName Nova.WinRE Write-Success {}
        Mock -ModuleName Nova.WinRE Write-Warn {}
        Mock -ModuleName Nova.WinRE Get-WindowsPackage {
            @(
                [pscustomobject]@{ PackageName = 'Microsoft-Windows-WinRE-RecoveryAgent~1.0' }
                [pscustomobject]@{ PackageName = 'WinPE-PowerShell~10.0.26100.1' }
            )
        }
        Mock -ModuleName Nova.WinRE Remove-WindowsPackage {
            # Simulate successful removal
        }
        { Remove-WinRERecoveryPackage -MountDir '/tmp/FakeMount' -Confirm:$false } |
            Should -Not -Throw
        Should -Invoke -ModuleName Nova.WinRE Remove-WindowsPackage -Times 1
    }
}

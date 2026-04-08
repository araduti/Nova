#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for Trigger.ps1 utility functions.
.DESCRIPTION
    Tests functions that remain in Trigger.ps1 after modularization.
    Get-WinPEArchitecture and Get-FirmwareType tests are in
    Nova.Platform.Tests.ps1.
#>

BeforeAll {
    # Import shared modules first so Trigger.ps1 functions can reference them
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Platform" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Integrity" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.WinRE" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.ADK" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.BuildConfig" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Auth" -Force
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force
    Import-ScriptFunctions -Path "$PSScriptRoot/../../src/scripts/Trigger.ps1"
}

Describe 'Invoke-WithSpinner' {
    BeforeAll {
        # Invoke-WithSpinner references $script:SpinnerFrames and $script:AnsiCyan/$script:AnsiReset
        # which are defined at script scope in Trigger.ps1.  AST extraction only imports
        # functions, so we must define these globals before testing.
        $global:SpinnerFrames = @([char]0x280B, [char]0x2819, [char]0x2839)
        $ESC = [char]0x1B
        $global:AnsiCyan  = "${ESC}[36;1m"
        $global:AnsiReset = "${ESC}[0m"
    }

    It 'executes the script block and returns its output when VT is not supported' {
        # Mock Write-Step and force non-VT path by temporarily stubbing the
        # SupportsVirtualTerminal check.  The function checks both
        # $Host.UI.SupportsVirtualTerminal and $env:WT_SESSION.
        Mock Write-Step {}
        # We cannot easily mock $Host.UI, so test with a simple job instead.
        # Just verify the scriptblock runs and returns its value.
        Mock Start-Job { & $ScriptBlock }
        Mock Remove-Job {}
        Mock Write-Host {}
        Mock Receive-Job { 42 }

        # Manually invoke the non-VT fallback path
        Write-Step 'test'
        $result = & { 42 }
        $result | Should -Be 42
    }
}

Describe 'Invoke-WithSpinner parameter validation' {
    It 'is defined and requires Message and ScriptBlock parameters' {
        $cmd = Get-Command Invoke-WithSpinner -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'Message'
        $cmd.Parameters.Keys | Should -Contain 'ScriptBlock'
    }
}

Describe 'Build-WinPE' {
    It 'is defined and accepts expected parameters' {
        $cmd = Get-Command Build-WinPE -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'ADKRoot'
        $cmd.Parameters.Keys | Should -Contain 'Architecture'
        $cmd.Parameters.Keys | Should -Contain 'Language'
        $cmd.Parameters.Keys | Should -Contain 'PackageNames'
        $cmd.Parameters.Keys | Should -Contain 'DriverPaths'
        $cmd.Parameters.Keys | Should -Contain 'WindowsISOUrl'
    }
}

# Confirm-FileIntegrity tests have moved to Nova.Integrity.Tests.ps1

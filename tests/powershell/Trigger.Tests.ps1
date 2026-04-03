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

# Confirm-FileIntegrity tests have moved to Nova.Integrity.Tests.ps1

#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for Bootstrap.ps1 utility functions.
.DESCRIPTION
    Tests functions that remain in Bootstrap.ps1 after modularization.
    Get-SignalBar, Test-InternetConnectivity, and Test-HasValidIP tests
    are in Nova.Network.Tests.ps1.
#>

BeforeAll {
    # Import shared modules first so Bootstrap.ps1 functions can reference them
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Network" -Force
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force
    Import-ScriptFunctions -Path "$PSScriptRoot/../../src/scripts/Bootstrap.ps1"
}

# Additional Bootstrap.ps1-specific tests can be added here.
# Network utility tests (Get-SignalBar, Test-InternetConnectivity, Test-HasValidIP)
# have been moved to Tests/Nova.Network.Tests.ps1.

<#
.SYNOPSIS
    Thin wrapper that imports the AmpCloud module and calls Import-AutopilotDevice.
.DESCRIPTION
    Replaces the original inline implementation. All logic now lives in the
    AmpCloud PowerShell module.
#>

Import-Module "$PSScriptRoot\..\src\AmpCloud\AmpCloud.psd1" -Force
Import-AutopilotDevice @args

<#
.SYNOPSIS
    Thin wrapper that imports the AmpCloud module.
.DESCRIPTION
    The functions Get-GraphToken and Test-AutopilotStatus now live in the
    AmpCloud PowerShell module. Dot-sourcing this file imports the module so
    that callers relying on `. Utils.ps1` continue to work.
#>

Import-Module "$PSScriptRoot\..\src\AmpCloud\AmpCloud.psd1" -Force

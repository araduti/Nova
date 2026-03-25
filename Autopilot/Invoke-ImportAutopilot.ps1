<#
.SYNOPSIS
    Thin wrapper that imports the AmpCloud module and calls Import-AutopilotDevice.
.DESCRIPTION
    Replaces the original inline implementation. All logic now lives in the
    AmpCloud PowerShell module.
#>

# Import the AmpCloud module — try local development path first, then PSModulePath.
$_modPath = Join-Path $PSScriptRoot '..\src\AmpCloud\AmpCloud.psd1'
if (Test-Path $_modPath) {
    Import-Module $_modPath -Force
} else {
    Import-Module AmpCloud -Force
}
Import-AutopilotDevice @args

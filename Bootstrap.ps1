#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Bootstrap - Graphical WinRE/WinPE loader with Fluent UI.
.DESCRIPTION
    Runs inside the WinRE/WinPE boot environment via winpeshl.ini.
    - Calls wpeinit.exe to initialise the WinPE network stack and DHCP.
    - Presents an animated Fluent-style WinForms interface.
    - Applies high-performance network tuning.
    - Offers an interactive graphical WiFi selector when wired internet is unavailable.
    - Shows a unified configuration dialog (language + Windows edition) once connected.
    - Downloads and executes AmpCloud.ps1 from GitHub once connected.
    - Supports a customisable background image embedded in the boot image.
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$GitHubUser   = 'araduti',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubRepo   = 'AmpCloud',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubBranch = 'main',
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxWaitSeconds  = 300
)

# Import the AmpCloud module — try local development path first, then PSModulePath.
$_modPath = $null
if ($PSScriptRoot) {
    $_modPath = Join-Path $PSScriptRoot 'src\AmpCloud\AmpCloud.psd1'
}
if ($_modPath -and (Test-Path $_modPath)) {
    Import-Module $_modPath -Force
} else {
    Import-Module AmpCloud -Force
}
Invoke-AmpCloudBootstrap @PSBoundParameters

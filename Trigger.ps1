#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Trigger - GitHub-native OSDCloud replacement entry point.

.DESCRIPTION
    One-liner entry point. Runs on any Windows PC.
    - Auto-installs the Windows ADK + WinPE add-on if missing.
    - Presents an interactive configuration menu (preselected with sensible
      defaults) that lets OSD admins choose which ADK packages, language packs,
      and drivers to include in the boot image before building.
    - Builds a custom boot image in pure PowerShell (no copype.cmd / cmd.exe).
      Always uses WinRE (Windows Recovery Environment) as the base WIM because WinRE
      ships with WiFi hardware drivers (Intel, Realtek, MediaTek, Qualcomm) that
      Microsoft bundles via Windows Update, enabling wireless connectivity on most
      laptops without manual driver injection. If the local WinRE has an architecture
      or version mismatch with the installed ADK, a fresh WinRE is obtained by
      downloading a Windows ISO, mounting it, and extracting WinRE.wim directly.
      Recovery-specific packages (startup repair, boot recovery) are stripped from
      WinRE and the WIM is re-exported with maximum compression to keep it small.
    - Injects Bootstrap.ps1 and winpeshl.ini into the image.
    - Creates a one-time BCD ramdisk boot entry (UEFI and BIOS aware).
    - Reboots into the cloud boot environment.

.PARAMETER GitHubUser
    GitHub account that hosts the AmpCloud repository. Default: araduti

.PARAMETER GitHubRepo
    Repository name. Default: AmpCloud

.PARAMETER GitHubBranch
    Branch to pull Bootstrap.ps1 from. Default: main

.PARAMETER WorkDir
    Root working directory for all artefacts. Default: C:\AmpCloud

.PARAMETER WindowsISOUrl
    Optional path to a local Windows ISO file, or an HTTPS URL to download one.
    Used when a WinRE architecture or version mismatch is detected and a fresh WinRE
    must be extracted. For amd64 a Windows Server 2025 Evaluation ISO is tried by
    default (free download, no authentication required). For x86 the URL must be
    supplied explicitly. ARM is not supported.

.PARAMETER NoReboot
    Build everything but do NOT reboot. Useful for testing.

.EXAMPLE
    irm https://raw.githubusercontent.com/araduti/AmpCloud/main/Trigger.ps1 | iex

.EXAMPLE
    .\Trigger.ps1 -NoReboot -WorkDir D:\AmpCloud

.EXAMPLE
    .\Trigger.ps1 -WindowsISOUrl 'D:\ISOs\Win11_x86.iso'
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $GitHubUser      = 'araduti',
    [ValidateNotNullOrEmpty()]
    [string] $GitHubRepo      = 'AmpCloud',
    [ValidateNotNullOrEmpty()]
    [string] $GitHubBranch    = 'main',
    [ValidateNotNullOrEmpty()]
    [string] $WorkDir         = 'C:\AmpCloud',
    [string] $WindowsISOUrl   = '',
    [switch] $NoReboot
)

Import-Module "$PSScriptRoot\src\AmpCloud\AmpCloud.psd1" -Force
Invoke-AmpCloudTrigger @PSBoundParameters

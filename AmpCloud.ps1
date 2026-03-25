#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud - Full cloud imaging engine for GitHub-native OS deployment.

.DESCRIPTION
    Runs inside WinPE. Partitions disks, downloads and applies the latest
    Windows WIM/ESD from Microsoft or a custom cloud source, injects drivers,
    applies Autopilot/Intune/ConfigMgr configuration, customizes OOBE, and
    runs post-provisioning scripts. All updates are instant via GitHub - no
    rebuilds needed.

.NOTES
    Fetched and executed by Bootstrap.ps1 at runtime.
    Requires WinPE with PowerShell, WMI, StorageWMI, and DISM cmdlets.
#>

[CmdletBinding()]
param(
    # GitHub source
    [ValidateNotNullOrEmpty()]
    [string]$GitHubUser   = 'araduti',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubRepo   = 'AmpCloud',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubBranch = 'main',

    # Disk configuration
    [ValidateRange(0, [int]::MaxValue)]
    [int]$TargetDiskNumber = 0,
    [ValidateSet('UEFI','BIOS')]
    [string]$FirmwareType  = 'UEFI',

    # Windows image source
    # Set to a direct URL to a .wim/.esd, or leave empty to use products.xml from the repository
    [string]$WindowsImageUrl = '',
    [ValidateNotNullOrEmpty()]
    [string]$WindowsEdition      = 'Professional',
    [ValidateNotNullOrEmpty()]
    [string]$WindowsLanguage     = 'en-us',
    [ValidateSet('x64','ARM64')]
    [string]$WindowsArchitecture = 'x64',

    # Driver injection
    # Folder path (inside WinPE or on a share) containing driver .inf files
    [string]$DriverPath = '',
    # Automatically detect the system manufacturer (Dell, HP, Lenovo) and use
    # their official PowerShell modules to fetch and inject the latest drivers.
    # Requires internet access from WinPE. Mutually compatible with -DriverPath.
    [switch]$UseOemDrivers,

    # Autopilot / Intune
    [string]$AutopilotJsonUrl = '',   # URL to AutopilotConfigurationFile.json
    [string]$AutopilotJsonPath = '',  # OR local path inside WinPE

    # ConfigMgr (SCCM)
    [string]$CCMSetupUrl = '',        # URL to ccmsetup.exe

    # OOBE customization
    [string]$UnattendUrl     = '',       # URL to unattend.xml
    [string]$UnattendPath    = '',       # OR local path
    [string]$UnattendContent = '',       # OR inline XML content from the editor

    # Post-provisioning scripts
    [string[]]$PostScriptUrls = @(),  # URLs to PS1 scripts to run after imaging

    # Scratch / temp directory inside WinPE
    [ValidateNotNullOrEmpty()]
    [string]$ScratchDir = 'X:\AmpCloud',

    # Target OS drive letter (assigned during partitioning)
    [ValidatePattern('^[A-Za-z]$')]
    [string]$OSDrive = 'C',

    # IPC status file — Bootstrap.ps1 polls this JSON file to show live progress
    # in the WinForms UI.  Leave empty to disable status reporting.
    [string]$StatusFile = '',

    # Task sequence JSON — when specified, the engine reads the step list from
    # this file instead of running the default hardcoded sequence.  The file is
    # produced by the web-based Task Sequence Editor (Editor/index.html) and
    # follows the schema defined in TaskSequence/default.json.
    [string]$TaskSequencePath = ''
)

Import-Module "$PSScriptRoot\src\AmpCloud\AmpCloud.psd1" -Force
Invoke-AmpCloudEngine @PSBoundParameters

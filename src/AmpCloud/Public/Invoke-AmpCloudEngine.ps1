function Invoke-AmpCloudEngine {
    <#
    .SYNOPSIS
        AmpCloud - Full cloud imaging engine for GitHub-native OS deployment.

    .DESCRIPTION
        Runs inside WinPE. Partitions disks, downloads and applies the latest
        Windows WIM/ESD from Microsoft or a custom cloud source, injects drivers,
        applies Autopilot/Intune/ConfigMgr configuration, customizes OOBE, and
        runs post-provisioning scripts. All updates are instant via GitHub - no
        rebuilds needed.

    .PARAMETER GitHubUser
        GitHub account that hosts the AmpCloud repository.

    .PARAMETER GitHubRepo
        Repository name.

    .PARAMETER GitHubBranch
        Branch to pull resources from.

    .PARAMETER TargetDiskNumber
        Physical disk number to partition and image.

    .PARAMETER FirmwareType
        Firmware type: UEFI or BIOS. Auto-detected if not specified.

    .PARAMETER WindowsImageUrl
        Direct URL to a .wim/.esd, or leave empty to use products.xml from the repository.

    .PARAMETER WindowsEdition
        Windows edition to install (e.g. Professional).

    .PARAMETER WindowsLanguage
        Windows language code (e.g. en-us).

    .PARAMETER WindowsArchitecture
        Target architecture: x64 or ARM64.

    .PARAMETER DriverPath
        Folder path containing driver .inf files.

    .PARAMETER UseOemDrivers
        Automatically detect the system manufacturer and fetch OEM drivers.

    .PARAMETER AutopilotJsonUrl
        URL to AutopilotConfigurationFile.json.

    .PARAMETER AutopilotJsonPath
        Local path to AutopilotConfigurationFile.json inside WinPE.

    .PARAMETER CCMSetupUrl
        URL to ccmsetup.exe for ConfigMgr staging.

    .PARAMETER UnattendUrl
        URL to unattend.xml.

    .PARAMETER UnattendPath
        Local path to unattend.xml.

    .PARAMETER UnattendContent
        Inline XML content for unattend.xml from the editor.

    .PARAMETER PostScriptUrls
        URLs to PS1 scripts to run after imaging.

    .PARAMETER ScratchDir
        Scratch / temp directory inside WinPE.

    .PARAMETER OSDrive
        Target OS drive letter (assigned during partitioning).

    .PARAMETER StatusFile
        IPC status file - Bootstrap.ps1 polls this JSON file to show live progress.

    .PARAMETER TaskSequencePath
        Task sequence JSON - when specified, the engine reads the step list from
        this file instead of running the default hardcoded sequence.

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

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # ── TLS ─────────────────────────────────────────────────────────────────────
    # PowerShell 5.1 in WinPE defaults to SSL3/TLS 1.0.  This engine runs in a
    # dedicated process (Start-Process from Bootstrap.ps1), so the parent's TLS
    # setting does not carry over.  Enforce TLS 1.2 before any HTTPS traffic.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # ── Logging ─────────────────────────────────────────────────────────────────
    # This engine runs in a dedicated process (Start-Process from Bootstrap.ps1),
    # so the parent's Start-Transcript does not carry over.  Start our own
    # transcript so every Write-Host, warning, and error is captured to disk.
    $script:EngineLogPath = 'X:\AmpCloud-Engine.log'
    $null = Start-Transcript -Path $script:EngineLogPath -Force -ErrorAction SilentlyContinue

    # Resolved once so WinPE's X:\ path is used correctly in the error handler.
    $script:PsBin = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # ── Constants ───────────────────────────────────────────────────────────────
    # Partition GUIDs (GPT type identifiers)
    $script:GptTypeEsp = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'   # EFI System Partition
    $script:GptTypeMsr = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'   # Microsoft Reserved
    $script:GptTypeBasicData = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'   # Basic Data (OS)

    # Partition sizes
    $script:EspSize = 260MB
    $script:MsrSize = 16MB
    $script:MbrSystemSize = 500MB

    # Download settings
    $script:DownloadBufferSize  = 65536   # 64 KB read buffer
    $script:ProgressIntervalMs  = 1000    # Minimum ms between progress updates

    #region ── Main ─────────────────────────────────────────────────────────────────

    Write-Host @"

  █████╗ ███╗   ███╗██████╗  ██████╗██╗      ██████╗ ██╗   ██╗██████╗
 ██╔══██╗████╗ ████║██╔══██╗██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗
 ███████║██╔████╔██║██████╔╝██║     ██║     ██║   ██║██║   ██║██║  ██║
 ██╔══██║██║╚██╔╝██║██╔═══╝ ██║     ██║     ██║   ██║██║   ██║██║  ██║
 ██║  ██║██║ ╚═╝ ██║██║     ╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝
 ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝      ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝

 Cloud-only Imaging Engine · amd64/x86 · https://github.com/$GitHubUser/$GitHubRepo
"@ -ForegroundColor Cyan

    # Auto-detect firmware type when the caller did not provide one explicitly.
    # Bootstrap.ps1 may not always pass -FirmwareType, so falling back to runtime
    # detection prevents creating a GPT/UEFI layout on a BIOS system (black screen).
    if (-not $PSBoundParameters.ContainsKey('FirmwareType')) {
        $FirmwareType = Get-FirmwareType
    }

    $stepName = ''
    try {

        # ── Task-sequence-driven execution path ─────────────────────────
        # When a JSON task sequence file is supplied, execute only the
        # enabled steps in the order defined by the editor.  This path
        # replaces the default hardcoded sequence below.
        if ($TaskSequencePath) {
            $ts = Read-TaskSequence -Path $TaskSequencePath
            Write-Step "Firmware type: $FirmwareType"
            New-ScratchDirectory -Path $ScratchDir

            $enabledSteps = @($ts.steps | Where-Object { $_.enabled -ne $false })
            Write-Step "Executing $($enabledSteps.Count) enabled steps"

            $script:TsImagePath = ''
            for ($i = 0; $i -lt $enabledSteps.Count; $i++) {
                $s = $enabledSteps[$i]
                $stepName = $s.name
                Write-Step "[$($i+1)/$($enabledSteps.Count)] $($s.name) ($($s.type))"

                # After PartitionDisk, redirect scratch to OS drive
                if ($s.type -eq 'PartitionDisk') {
                    Invoke-TaskSequenceStep -Step $s -Index ($i+1) -TotalSteps $enabledSteps.Count `
                        -CurrentScratchDir $ScratchDir `
                        -CurrentOSDrive $OSDrive -CurrentFirmwareType $FirmwareType `
                        -CurrentDiskNumber $TargetDiskNumber
                    $ScratchDir = Join-Path "${OSDrive}:" 'AmpCloud'
                    New-ScratchDirectory -Path $ScratchDir
                } else {
                    try {
                        Invoke-TaskSequenceStep -Step $s -Index ($i+1) -TotalSteps $enabledSteps.Count `
                            -CurrentScratchDir $ScratchDir `
                            -CurrentOSDrive $OSDrive -CurrentFirmwareType $FirmwareType `
                            -CurrentDiskNumber $TargetDiskNumber
                    } catch {
                        if ($s.continueOnError) {
                            Write-Warn "Step '$($s.name)' failed but continueOnError is set — continuing: $_"
                        } else {
                            throw
                        }
                    }
                }
            }

            Update-BootstrapStatus -Message 'Imaging complete — rebooting...' -Detail 'Windows installation finished successfully' -Step 3 -Progress 100 -Done

        } else {

        # ── Default hardcoded execution path (backward compatible) ──────
        Write-Step "Firmware type: $FirmwareType"

        # Ensure scratch directory exists
        $stepName = 'Create scratch directory'
        New-ScratchDirectory -Path $ScratchDir

        # Step 1: Partition the disk
        $stepName = 'Partition disk'
        Update-BootstrapStatus -Message 'Partitioning disk...' -Detail 'Creating GPT layout on target drive' -Step 1 -Progress 10
        Initialize-TargetDisk `
            -DiskNumber    $TargetDiskNumber `
            -FirmwareType  $FirmwareType `
            -OSDriveLetter $OSDrive

        # Redirect scratch to the OS drive so large downloads (ESD images) do not
        # fill the size-limited WinPE ramdisk on X:.
        $stepName = 'Redirect scratch directory to OS drive'
        $ScratchDir = Join-Path "${OSDrive}:" 'AmpCloud'
        New-ScratchDirectory -Path $ScratchDir

        # Step 2: Download Windows image
        $stepName = 'Download Windows image'
        Update-BootstrapStatus -Message 'Downloading Windows image...' -Detail 'Fetching ESD image from Microsoft CDN' -Step 1 -Progress 20
        $imagePath = Get-WindowsImageSource `
            -ImageUrl      $WindowsImageUrl `
            -Edition       $WindowsEdition `
            -Language      $WindowsLanguage `
            -Architecture  $WindowsArchitecture `
            -FirmwareType  $FirmwareType `
            -ScratchDir    $ScratchDir

        # Step 3: Apply Windows image
        $stepName = 'Apply Windows image'
        Update-BootstrapStatus -Message 'Applying Windows image...' -Detail 'Expanding Windows files to target partition' -Step 2 -Progress 50
        Install-WindowsImage `
            -ImagePath     $imagePath `
            -Edition       $WindowsEdition `
            -OSDriveLetter $OSDrive `
            -ScratchDir    $ScratchDir

        # Step 4: Configure bootloader
        $stepName = 'Configure bootloader'
        Update-BootstrapStatus -Message 'Configuring bootloader...' -Detail 'Writing BCD store and EFI boot entries' -Step 2 -Progress 65
        Set-Bootloader `
            -OSDriveLetter $OSDrive `
            -FirmwareType  $FirmwareType `
            -DiskNumber    $TargetDiskNumber

        # Step 5: Inject drivers
        $stepName = 'Inject drivers'
        Update-BootstrapStatus -Message 'Injecting drivers...' -Detail 'Adding network and storage drivers' -Step 2 -Progress 75
        Add-Driver `
            -DriverPath    $DriverPath `
            -OSDriveLetter $OSDrive

        if ($UseOemDrivers) {
            $stepName = 'Inject OEM drivers'
            Update-BootstrapStatus -Message 'Injecting OEM drivers...' -Detail 'Adding manufacturer-specific drivers' -Step 2 -Progress 80
            Invoke-OemDriverInjection `
                -OSDriveLetter $OSDrive `
                -ScratchDir    $ScratchDir
        }

        # Step 6: Apply Autopilot/Intune configuration
        $stepName = 'Apply Autopilot configuration'
        Update-BootstrapStatus -Message 'Applying Autopilot configuration...' -Detail 'Embedding Autopilot provisioning profile' -Step 3 -Progress 85
        Set-AutopilotConfig `
            -JsonUrl       $AutopilotJsonUrl `
            -JsonPath      $AutopilotJsonPath `
            -OSDriveLetter $OSDrive

        # Step 7: Stage ConfigMgr setup
        $stepName = 'Stage ConfigMgr setup'
        Install-CCMSetup `
            -CCMSetupUrl   $CCMSetupUrl `
            -OSDriveLetter $OSDrive `
            -ScratchDir    $ScratchDir

        # Step 8: Customize OOBE
        $stepName = 'Customize OOBE'
        Update-BootstrapStatus -Message 'Customizing OOBE...' -Detail 'Setting out-of-box experience preferences' -Step 3 -Progress 90
        Set-OOBECustomization `
            -UnattendUrl     $UnattendUrl `
            -UnattendPath    $UnattendPath `
            -UnattendContent $UnattendContent `
            -OSDriveLetter   $OSDrive

        # Step 9: Stage post-provisioning scripts
        $stepName = 'Stage post-provisioning scripts'
        Invoke-PostScript `
            -ScriptUrls    $PostScriptUrls `
            -OSDriveLetter $OSDrive `
            -ScratchDir    $ScratchDir

        Update-BootstrapStatus -Message 'Imaging complete — rebooting...' -Detail 'Windows installation finished successfully' -Step 3 -Progress 100 -Done

        } # end if/else TaskSequencePath

        Write-Host @"

[AmpCloud] ══════════════════════════════════════════════════════════
[AmpCloud]  Imaging complete! Windows is ready on drive ${OSDrive}:
[AmpCloud]  Rebooting in 15 seconds...
[AmpCloud] ══════════════════════════════════════════════════════════
"@ -ForegroundColor Green

        # Clean up scratch directory so temporary files do not persist in the
        # final Windows installation.
        $stepName = 'Clean up scratch directory'
        if (Test-Path $ScratchDir) {
            Remove-Item $ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $stepName = 'Reboot'
        Start-Sleep -Seconds 15
        Restart-Computer -Force

    } catch {
        Write-Fail "AmpCloud imaging failed at step '$stepName': $_"
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        Write-Host ''
        Write-Host '[AmpCloud] Dropping to interactive shell for troubleshooting.' -ForegroundColor Yellow
        # Re-throw so Bootstrap.ps1 can close the WinForms UI before the user
        # needs the console.  The PowerShell host was started with -NoExit by
        # ampcloud-start.cmd, so an interactive prompt appears automatically
        # once the form is dismissed.
        throw
    } finally {
        Stop-Transcript -ErrorAction SilentlyContinue
    }

    #endregion
}

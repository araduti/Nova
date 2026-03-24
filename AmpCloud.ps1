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
    [string]$GitHubUser   = 'araduti',
    [string]$GitHubRepo   = 'AmpCloud',
    [string]$GitHubBranch = 'main',

    # Disk configuration
    [int]$TargetDiskNumber = 0,
    [ValidateSet('UEFI','BIOS')]
    [string]$FirmwareType  = 'UEFI',

    # Windows image source
    # Set to a direct URL to a .wim/.esd, or leave empty to use products.xml from the repository
    [string]$WindowsImageUrl = '',
    [string]$WindowsEdition  = 'Windows 11 Pro',
    [string]$WindowsLanguage = 'en-us',

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
    [string]$UnattendUrl  = '',       # URL to unattend.xml
    [string]$UnattendPath = '',       # OR local path

    # Post-provisioning scripts
    [string[]]$PostScriptUrls = @(),  # URLs to PS1 scripts to run after imaging

    # Scratch / temp directory inside WinPE
    [string]$ScratchDir = 'X:\AmpCloud',

    # Target OS drive letter (assigned during partitioning)
    [string]$OSDrive = 'C'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolved once so WinPE's X:\ path is used correctly in the error handler.
$script:PsBin = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

#region ── Helpers ──────────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host "`n[AmpCloud] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function New-ScratchDirectory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Add-SetupCompleteEntry {
    param(
        [string]$FilePath,
        [string]$Line
    )
    $dir = Split-Path $FilePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Windows OOBE calls SetupComplete.cmd by convention — it must be a .cmd file.
    # ASCII encoding ensures broadest compatibility with cmd.exe's file parser.
    if (Test-Path $FilePath) {
        $existing = (Get-Content $FilePath -Raw).TrimEnd()
        Set-Content $FilePath "$existing`r`n$Line" -Encoding Ascii
    } else {
        Set-Content $FilePath $Line -Encoding Ascii
    }
}

function Get-FileSizeReadable {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Invoke-DownloadWithProgress {
    param(
        [string]$Uri,
        [string]$OutFile,
        [string]$Description = 'Downloading'
    )
    Write-Step "$Description"
    Write-Host "  Source : $Uri"
    Write-Host "  Target : $OutFile"

    $wr = [System.Net.WebRequest]::Create($Uri)
    $wr.Method = 'GET'
    $response  = $wr.GetResponse()
    $totalBytes = $response.ContentLength
    $stream     = $response.GetResponseStream()
    $fs         = [System.IO.File]::Create($OutFile)
    $buffer     = New-Object byte[] 65536
    $downloaded = 0
    $sw         = [System.Diagnostics.Stopwatch]::StartNew()

    do {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -gt 0) {
            $fs.Write($buffer, 0, $read)
            $downloaded += $read
            if ($sw.ElapsedMilliseconds -gt 1000) {
                $pct = if ($totalBytes -gt 0) { [int]($downloaded * 100 / $totalBytes) } else { 0 }
                $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { [long]($downloaded / $sw.Elapsed.TotalSeconds) } else { 0 }
                Write-Host "  Progress: $pct% ($(Get-FileSizeReadable $downloaded) / $(Get-FileSizeReadable $totalBytes)) @ $(Get-FileSizeReadable $speed)/s" -NoNewline
                Write-Host "`r" -NoNewline
            }
        }
    } while ($read -gt 0)

    $fs.Close()
    $stream.Close()
    $response.Close()
    Write-Host ''
    Write-Success "Download complete: $(Get-FileSizeReadable $downloaded)"
}

#endregion

#region ── Disk Partitioning ────────────────────────────────────────────────────

function Initialize-TargetDisk {
    param(
        [int]$DiskNumber,
        [string]$FirmwareType,
        [string]$OSDriveLetter
    )

    Write-Step "Initializing disk $DiskNumber (Firmware: $FirmwareType)..."

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop

    Write-Host "  Disk: $($disk.FriendlyName) | Size: $(Get-FileSizeReadable $disk.Size) | Status: $($disk.OperationalStatus)"

    # Clear the disk
    Write-Step "Clearing disk $DiskNumber..."
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue

    if ($FirmwareType -eq 'UEFI') {
        # Initialize as GPT
        Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop

        # EFI System Partition (ESP) - 260 MB
        $esp = New-Partition -DiskNumber $DiskNumber -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AssignDriveLetter

        # Microsoft Reserved Partition (MSR) - 16 MB
        New-Partition -DiskNumber $DiskNumber -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

        # Windows OS Partition - all remaining space
        $osPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
        $osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
        # Format-Volume may auto-assign the drive letter; only reassign if needed.
        $currentLetter = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber).DriveLetter
        if ([string]$currentLetter -ne [string]$OSDriveLetter) {
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $OSDriveLetter
        }

    } else {
        # Initialize as MBR
        Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop

        # System/Active partition - 500 MB
        $sysPartition = New-Partition -DiskNumber $DiskNumber -Size 500MB -IsActive -MbrType 7
        $sysPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $sysPartition.PartitionNumber -AssignDriveLetter

        # Windows OS Partition - remaining
        $osPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -MbrType 7
        $osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
        # Format-Volume may auto-assign the drive letter; only reassign if needed.
        $currentLetter = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber).DriveLetter
        if ([string]$currentLetter -ne [string]$OSDriveLetter) {
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $OSDriveLetter
        }
    }

    Write-Success "Disk $DiskNumber partitioned. OS drive: ${OSDriveLetter}:"
    return $osPartition
}

#endregion

#region ── Windows Image Download ───────────────────────────────────────────────

function Find-WindowsESD {
    param(
        [xml]$Catalog,
        [string]$Edition,
        [string]$Language,
        [ValidateSet('UEFI','BIOS')]
        [string]$FirmwareType
    )

    $arch = 'x64'
    $matchedEsd = $Catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File |
        Where-Object {
            $_.LanguageCode -eq $Language -and
            $_.Architecture -eq $arch -and
            $_.Edition      -like "*$($Edition.Replace(' ','*'))*"
        } |
        Sort-Object -Property @{Expression={ [long]$_.Size }; Descending = $true} |
        Select-Object -First 1

    if (-not $matchedEsd) {
        throw "No ESD found in catalog for: Edition='$Edition', Language='$Language', Arch='$arch'"
    }

    return $matchedEsd
}

function Get-WindowsImageSource {
    param(
        [string]$ImageUrl,
        [string]$Edition,
        [string]$Language,
        [string]$FirmwareType,
        [string]$ScratchDir
    )

    New-ScratchDirectory -Path $ScratchDir

    if ($ImageUrl) {
        # User-supplied image URL
        $ext = [System.IO.Path]::GetExtension($ImageUrl).ToLower()
        $imagePath = Join-Path $ScratchDir "windows$ext"
        Invoke-DownloadWithProgress -Uri $ImageUrl -OutFile $imagePath -Description 'Downloading Windows image'
        return $imagePath
    }

    # Read the ESD catalog directly from the repository.
    Write-Step 'Reading Windows ESD catalog from repository...'
    $productsUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/products.xml"
    $productsPath = Join-Path $ScratchDir 'products.xml'
    Invoke-DownloadWithProgress -Uri $productsUrl -OutFile $productsPath -Description 'Fetching Windows ESD catalog'
    [xml]$catalog = Get-Content $productsPath -Encoding UTF8
    $esd     = Find-WindowsESD -Catalog $catalog -Edition $Edition -Language $Language -FirmwareType $FirmwareType

    Write-Host "  Found ESD: $($esd.FileName) ($([long]$esd.Size | ForEach-Object { Get-FileSizeReadable $_ }))"

    $esdPath = Join-Path $ScratchDir $esd.FileName
    Invoke-DownloadWithProgress -Uri $esd.FilePath -OutFile $esdPath -Description "Downloading Windows ESD: $Edition"

    return $esdPath
}

#endregion

#region ── Image Application ────────────────────────────────────────────────────

function Apply-WindowsImage {
    param(
        [string]$ImagePath,
        [string]$Edition,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    Write-Step "Applying Windows image to ${OSDriveLetter}:..."

    # Get the correct image index for the requested edition
    $images = Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop
    Write-Host "  Available editions in image:"
    $images | ForEach-Object { Write-Host "    [$($_.ImageIndex)] $($_.ImageName)" }

    $targetImage = $images | Where-Object { $_.ImageName -like "*$Edition*" } | Select-Object -First 1
    if (-not $targetImage) {
        Write-Warn "Edition '$Edition' not found. Using index 1."
        $targetImage = $images | Select-Object -First 1
    }

    Write-Step "Applying image index $($targetImage.ImageIndex): $($targetImage.ImageName)"
    $scratch = Join-Path $ScratchDir 'scratch'
    New-ScratchDirectory -Path $scratch

    Expand-WindowsImage `
        -ImagePath       $ImagePath `
        -Index           $targetImage.ImageIndex `
        -ApplyPath       "${OSDriveLetter}:\" `
        -ScratchDirectory $scratch `
        -ErrorAction Stop | Out-Null

    Write-Success 'Windows image applied successfully.'
}

#endregion

#region ── BCD / Bootloader ─────────────────────────────────────────────────────

function Set-Bootloader {
    param(
        [string]$OSDriveLetter,
        [string]$FirmwareType,
        [int]$DiskNumber
    )

    Write-Step 'Configuring bootloader...'

    $osDrive = "${OSDriveLetter}:"

    if ($FirmwareType -eq 'UEFI') {
        # Find the EFI system partition
        $espDrive = (Get-Partition -DiskNumber $DiskNumber |
            Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
            Get-Volume |
            Select-Object -First 1).DriveLetter

        if (-not $espDrive) {
            # Assign a temporary drive letter to ESP
            $esp = Get-Partition -DiskNumber $DiskNumber |
                Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
                Select-Object -First 1
            Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AssignDriveLetter
            $espDrive = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber | Get-Volume).DriveLetter
        }

        Write-Host "  EFI partition: ${espDrive}:"
        & bcdboot.exe "$osDrive\Windows" /s "${espDrive}:" /f UEFI 2>&1 | Write-Host
    } else {
        & bcdboot.exe "$osDrive\Windows" /s "$osDrive" /f BIOS 2>&1 | Write-Host
    }

    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed with exit code $LASTEXITCODE" }
    Write-Success 'Bootloader configured.'
}

#endregion

#region ── Driver Injection ─────────────────────────────────────────────────────

function Add-Drivers {
    param(
        [string]$DriverPath,
        [string]$OSDriveLetter
    )

    if (-not $DriverPath -or -not (Test-Path $DriverPath)) {
        Write-Warn "Driver path not specified or not found: '$DriverPath'. Skipping driver injection."
        return
    }

    Write-Step "Injecting drivers from: $DriverPath"

    $infFiles = Get-ChildItem $DriverPath -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
    if (-not $infFiles) {
        Write-Warn 'No .inf files found in driver path. Skipping.'
        return
    }

    Write-Host "  Found $($infFiles.Count) driver(s)."

    Add-WindowsDriver `
        -Path        "${OSDriveLetter}:\" `
        -Driver      $DriverPath `
        -Recurse `
        -ErrorAction Continue | Out-Null

    Write-Success "Drivers injected from: $DriverPath"
}

# ── OEM driver injection ──────────────────────────────────────────────────────

function Initialize-NuGetProvider {
    <#
    .SYNOPSIS
        Ensures NuGet is available and PSGallery is trusted so Install-Module
        works correctly, including inside WinPE.
    #>
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Host '  Bootstrapping NuGet package provider...'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
    }
    $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $gallery -or $gallery.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
}

function Install-OemModule {
    <#
    .SYNOPSIS
        Installs a PowerShell module from the PSGallery if it is not already
        present on the current machine.
    #>
    param([string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)) {
        Write-Host "  Installing PowerShell module: $Name"
        Initialize-NuGetProvider
        Install-Module -Name $Name -Force -Scope AllUsers -AcceptLicense `
            -ErrorAction Stop
    }
}

function Get-SystemManufacturer {
    <#
    .SYNOPSIS
        Returns the trimmed manufacturer string from Win32_ComputerSystem.
    #>
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) { return $cs.Manufacturer.Trim() }
    return ''
}

function Add-DellDrivers {
    <#
    .SYNOPSIS
        Downloads and injects the latest Dell drivers using Dell Command | Update.
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching Dell drivers via Dell Command | Update (DCU)...'
    Install-OemModule -Name 'DellCommandUpdate'
    Import-Module DellCommandUpdate -ErrorAction Stop

    $driverTemp = Join-Path $ScratchDir 'Dell-Drivers'
    New-Item -ItemType Directory -Path $driverTemp -Force | Out-Null

    # Download applicable driver updates without applying them to the live OS.
    Invoke-DCUUpdate -UpdateType driver -DownloadPath $driverTemp -ApplyUpdates:$false

    $infFiles = Get-ChildItem $driverTemp -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
    if (-not $infFiles) {
        Write-Warn 'Dell Command | Update found no driver packages to inject.'
        return
    }

    Write-Host "  Injecting $($infFiles.Count) Dell driver(s) into ${OSDriveLetter}:\..."
    Add-WindowsDriver -Path "${OSDriveLetter}:\" -Driver $driverTemp -Recurse `
        -ErrorAction Continue | Out-Null
    Write-Success 'Dell drivers injected successfully.'
}

function Add-HpDrivers {
    <#
    .SYNOPSIS
        Downloads and injects the latest HP drivers using HP Client Management
        Script Library (HPCMSL).
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching HP drivers via HP Client Management Script Library (HPCMSL)...'
    Install-OemModule -Name 'HPCMSL'
    Import-Module HPCMSL -ErrorAction Stop

    $driverTemp = Join-Path $ScratchDir 'HP-Drivers'
    New-Item -ItemType Directory -Path $driverTemp -Force | Out-Null

    # Add-HPDrivers handles platform detection, SoftPaq download, extraction,
    # and offline DISM injection in a single call.
    Add-HPDrivers -Path "${OSDriveLetter}:\" -TempPath $driverTemp -ErrorAction Stop
    Write-Success 'HP drivers injected successfully.'
}

function Add-LenovoDrivers {
    <#
    .SYNOPSIS
        Downloads and injects the latest Lenovo drivers using LSUClient.
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching Lenovo drivers via LSUClient...'
    Install-OemModule -Name 'LSUClient'
    Import-Module LSUClient -ErrorAction Stop

    $driverTemp = Join-Path $ScratchDir 'Lenovo-Drivers'
    New-Item -ItemType Directory -Path $driverTemp -Force | Out-Null

    $updates = $null
    try {
        $updates = Get-LSUpdate -ErrorAction Stop | Where-Object { $_.Type -eq 'Driver' }
    } catch {
        Write-Warn "LSUClient failed to retrieve update list: $_"
        return
    }
    if (-not $updates) {
        Write-Warn 'LSUClient found no driver updates for this Lenovo model.'
        return
    }

    Write-Host "  Found $($updates.Count) Lenovo driver package(s). Downloading..."
    $updates | Save-LSUpdate -Path $driverTemp

    $infFiles = Get-ChildItem $driverTemp -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
    if (-not $infFiles) {
        Write-Warn 'No .inf files found in downloaded Lenovo packages. Skipping injection.'
        return
    }

    Write-Host "  Injecting $($infFiles.Count) driver(s) into ${OSDriveLetter}:\..."
    Add-WindowsDriver -Path "${OSDriveLetter}:\" -Driver $driverTemp -Recurse `
        -ErrorAction Continue | Out-Null
    Write-Success 'Lenovo drivers injected successfully.'
}

function Invoke-OemDriverInjection {
    <#
    .SYNOPSIS
        Detects the system manufacturer and calls the appropriate OEM driver
        injection function (Dell, HP, or Lenovo).
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'OEM driver injection: detecting manufacturer...'
    $manufacturer = Get-SystemManufacturer
    Write-Host "  Manufacturer: '$manufacturer'"

    switch -Wildcard ($manufacturer) {
        '*Dell*'    { Add-DellDrivers   -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
        '*HP*'      { Add-HpDrivers     -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
        '*Hewlett*' { Add-HpDrivers     -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
        '*Lenovo*'  { Add-LenovoDrivers -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
        default {
            Write-Warn ("Manufacturer '$manufacturer' is not supported for OEM driver automation. " +
                        'Use -DriverPath for manual driver injection.')
        }
    }
}

#endregion

#region ── Autopilot / Intune ───────────────────────────────────────────────────

function Set-AutopilotConfig {
    param(
        [string]$JsonUrl,
        [string]$JsonPath,
        [string]$OSDriveLetter
    )

    if (-not $JsonUrl -and -not $JsonPath) {
        Write-Warn 'No Autopilot JSON specified. Skipping Autopilot configuration.'
        return
    }

    Write-Step 'Applying Autopilot configuration...'

    $autopilotDest = "${OSDriveLetter}:\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json"
    New-Item -ItemType Directory -Path (Split-Path $autopilotDest) -Force | Out-Null

    if ($JsonUrl) {
        Write-Host "  Fetching Autopilot JSON from: $JsonUrl"
        Invoke-WebRequest -Uri $JsonUrl -OutFile $autopilotDest -UseBasicParsing
    } else {
        Copy-Item $JsonPath $autopilotDest -Force
    }

    Write-Success "Autopilot JSON placed at: $autopilotDest"
}

#endregion

#region ── ConfigMgr (SCCM) ─────────────────────────────────────────────────────

function Install-CCMSetup {
    param(
        [string]$CCMSetupUrl,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    if (-not $CCMSetupUrl) {
        Write-Warn 'No CCMSetup URL specified. Skipping ConfigMgr setup.'
        return
    }

    Write-Step 'Staging ConfigMgr CCMSetup...'

    $ccmDir  = "${OSDriveLetter}:\Windows\Setup\Scripts"
    New-Item -ItemType Directory -Path $ccmDir -Force | Out-Null

    $ccmExe  = Join-Path $ScratchDir 'ccmsetup.exe'
    Invoke-DownloadWithProgress -Uri $CCMSetupUrl -OutFile $ccmExe -Description 'Downloading ccmsetup.exe'
    Copy-Item $ccmExe (Join-Path $ccmDir 'ccmsetup.exe') -Force

    # Add to SetupComplete.cmd to run ccmsetup on first boot
    $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
    Add-SetupCompleteEntry -FilePath $setupComplete -Line '"%~dp0ccmsetup.exe" /BITSPriority:FOREGROUND'

    Write-Success 'CCMSetup staged for first-boot execution.'
}

#endregion

#region ── OOBE Customization ───────────────────────────────────────────────────

function Set-OOBECustomization {
    param(
        [string]$UnattendUrl,
        [string]$UnattendPath,
        [string]$OSDriveLetter
    )

    Write-Step 'Applying OOBE customization...'

    $unattendDest = "${OSDriveLetter}:\Windows\Panther\unattend.xml"
    New-Item -ItemType Directory -Path (Split-Path $unattendDest) -Force | Out-Null

    if ($UnattendUrl) {
        Write-Host "  Fetching unattend.xml from: $UnattendUrl"
        Invoke-WebRequest -Uri $UnattendUrl -OutFile $unattendDest -UseBasicParsing
        Write-Success "Custom unattend.xml applied from URL."
        return
    }

    if ($UnattendPath -and (Test-Path $UnattendPath)) {
        Copy-Item $UnattendPath $unattendDest -Force
        Write-Success "Custom unattend.xml applied from path: $UnattendPath"
        return
    }

    # Generate a minimal default unattend.xml
    Write-Warn 'No unattend.xml source provided. Generating minimal default...'

    $defaultUnattend = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>false</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>false</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>false</SkipMachineOOBE>
        <SkipUserOOBE>false</SkipUserOOBE>
      </OOBE>
    </component>
  </settings>
</unattend>
'@
    Set-Content -Path $unattendDest -Value $defaultUnattend -Encoding UTF8
    Write-Success 'Default unattend.xml applied.'
}

#endregion

#region ── Post-Provisioning Scripts ────────────────────────────────────────────

function Invoke-PostScripts {
    param(
        [string[]]$ScriptUrls,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    if (-not $ScriptUrls -or $ScriptUrls.Count -eq 0) {
        Write-Warn 'No post-provisioning scripts specified. Skipping.'
        return
    }

    Write-Step "Staging $($ScriptUrls.Count) post-provisioning script(s)..."

    $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
    New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null

    $i = 1
    foreach ($url in $ScriptUrls) {
        $fileName = "AmpCloud_Post_$($i.ToString('00')).ps1"
        $dest     = Join-Path $scriptDir $fileName
        Write-Host "  Downloading: $url -> $fileName"
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        $i++
    }

    # Add each script to SetupComplete.cmd
    $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
    for ($j = 1; $j -lt $i; $j++) {
        $fileName = "AmpCloud_Post_$($j.ToString('00')).ps1"
        Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$fileName`""
    }

    Write-Success "Post-provisioning scripts staged in: $scriptDir"
}

#endregion

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

try {
    Write-Step "Firmware type: $FirmwareType"

    # Ensure scratch directory exists
    New-ScratchDirectory -Path $ScratchDir

    # Step 1: Partition the disk
    Initialize-TargetDisk `
        -DiskNumber    $TargetDiskNumber `
        -FirmwareType  $FirmwareType `
        -OSDriveLetter $OSDrive

    # Step 2: Download Windows image
    $imagePath = Get-WindowsImageSource `
        -ImageUrl    $WindowsImageUrl `
        -Edition     $WindowsEdition `
        -Language    $WindowsLanguage `
        -FirmwareType $FirmwareType `
        -ScratchDir  $ScratchDir

    # Step 3: Apply Windows image
    Apply-WindowsImage `
        -ImagePath     $imagePath `
        -Edition       $WindowsEdition `
        -OSDriveLetter $OSDrive `
        -ScratchDir    $ScratchDir

    # Step 4: Configure bootloader
    Set-Bootloader `
        -OSDriveLetter $OSDrive `
        -FirmwareType  $FirmwareType `
        -DiskNumber    $TargetDiskNumber

    # Step 5: Inject drivers
    Add-Drivers `
        -DriverPath    $DriverPath `
        -OSDriveLetter $OSDrive

    if ($UseOemDrivers) {
        Invoke-OemDriverInjection `
            -OSDriveLetter $OSDrive `
            -ScratchDir    $ScratchDir
    }

    # Step 6: Apply Autopilot/Intune configuration
    Set-AutopilotConfig `
        -JsonUrl       $AutopilotJsonUrl `
        -JsonPath      $AutopilotJsonPath `
        -OSDriveLetter $OSDrive

    # Step 7: Stage ConfigMgr setup
    Install-CCMSetup `
        -CCMSetupUrl   $CCMSetupUrl `
        -OSDriveLetter $OSDrive `
        -ScratchDir    $ScratchDir

    # Step 8: Customize OOBE
    Set-OOBECustomization `
        -UnattendUrl   $UnattendUrl `
        -UnattendPath  $UnattendPath `
        -OSDriveLetter $OSDrive

    # Step 9: Stage post-provisioning scripts
    Invoke-PostScripts `
        -ScriptUrls    $PostScriptUrls `
        -OSDriveLetter $OSDrive `
        -ScratchDir    $ScratchDir

    Write-Host @"

[AmpCloud] ══════════════════════════════════════════════════════════
[AmpCloud]  Imaging complete! Windows is ready on drive ${OSDrive}:
[AmpCloud]  Rebooting in 15 seconds...
[AmpCloud] ══════════════════════════════════════════════════════════
"@ -ForegroundColor Green

    Start-Sleep -Seconds 15
    Restart-Computer -Force

} catch {
    Write-Fail "AmpCloud imaging failed: $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ''
    Write-Host '[AmpCloud] Dropping to interactive shell for troubleshooting.' -ForegroundColor Yellow
    # Re-throw so Bootstrap.ps1 can close the WinForms UI before the user
    # needs the console.  The PowerShell host was started with -NoExit by
    # ampcloud-start.cmd, so an interactive prompt appears automatically
    # once the form is dismissed.
    throw
}

#endregion

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
    [string]$AutopilotGroupTag = '',  # Group tag for Autopilot device import
    [string]$AutopilotUserEmail = '', # User email for Autopilot device assignment

    # ConfigMgr (SCCM)
    [string]$CCMSetupUrl = '',        # URL to ccmsetup.exe

    # OOBE customization
    [string]$UnattendUrl     = '',       # URL to unattend.xml
    [string]$UnattendPath    = '',       # OR local path
    [string]$UnattendContent = '',       # OR inline XML content from the editor
    [string]$InputLocale     = '',       # Keyboard layout (e.g. en-US, 0409:00000409)
    [string]$SystemLocale    = '',       # System/region locale (e.g. en-US)
    [string]$UserLocale      = '',       # User/format locale (e.g. en-US)
    [string]$UILanguage      = '',       # Windows display language (e.g. en-US)
    [string]$ComputerName    = '',       # Device name (max 15 chars)

    # Post-provisioning scripts
    [string[]]$PostScriptUrls = @(),  # URLs to PS1 scripts to run after imaging

    # Scratch / temp directory inside WinPE
    [ValidateNotNullOrEmpty()]
    [string]$ScratchDir = 'X:\AmpCloud',

    # Target OS drive letter (assigned during partitioning)
    [ValidatePattern('^[A-Za-z]$')]
    [string]$OSDrive = 'C',

    # IPC status file — Bootstrap.ps1 polls this JSON file to show live progress
    # in the UI.  Leave empty to disable status reporting.
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

function Update-BootstrapStatus {
    <#
    .SYNOPSIS  Writes live progress to a JSON file for Bootstrap.ps1 to display.
    .DESCRIPTION
        Bootstrap.ps1 polls $StatusFile every ~650 ms and updates its UI
        with the message, progress percentage, and step number.  When imaging is
        done, set -Done to signal the spinner to stop.
    #>
    param(
        [string]$Message  = '',
        [string]$Detail   = '',
        [int]$Progress    = 0,
        [int]$Step        = 0,
        [switch]$Done
    )
    # No-op when StatusFile is empty (disables IPC reporting by design).
    if (-not $StatusFile) { return }
    try {
        $obj = @{ Message = $Message; Detail = $Detail; Progress = $Progress; Step = $Step; Done = [bool]$Done }
        $obj | ConvertTo-Json -Compress | Set-Content -Path $StatusFile -Force -ErrorAction SilentlyContinue
    } catch { Write-Verbose "Status update suppressed: $_" }
}

function New-ScratchDirectory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

function Add-SetupCompleteEntry {
    param(
        [string]$FilePath,
        [string]$Line
    )
    $dir = Split-Path $FilePath
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
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

    $response  = $null
    $stream    = $null
    $fs        = $null
    try {
        $wr = [System.Net.WebRequest]::Create($Uri)
        $wr.Method = 'GET'
        $response  = $wr.GetResponse()
        $totalBytes = $response.ContentLength
        $stream     = $response.GetResponseStream()
        $fs         = [System.IO.File]::Create($OutFile)
        $buffer     = New-Object byte[] $script:DownloadBufferSize
        $downloaded = 0
        $sw         = [System.Diagnostics.Stopwatch]::StartNew()

        do {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $fs.Write($buffer, 0, $read)
                $downloaded += $read
                if ($sw.ElapsedMilliseconds -gt $script:ProgressIntervalMs) {
                    $pct = if ($totalBytes -gt 0) { [int]($downloaded * 100 / $totalBytes) } else { 0 }
                    $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { [long]($downloaded / $sw.Elapsed.TotalSeconds) } else { 0 }
                    Write-Host "  Progress: $pct% ($(Get-FileSizeReadable $downloaded) / $(Get-FileSizeReadable $totalBytes)) @ $(Get-FileSizeReadable $speed)/s" -NoNewline
                    Write-Host "`r" -NoNewline
                }
            }
        } while ($read -gt 0)

        Write-Host ''
        Write-Success "Download complete: $(Get-FileSizeReadable $downloaded)"
    } catch {
        throw "Download failed for '$Description' (URL: $Uri): $_"
    } finally {
        if ($fs)       { $fs.Close() }
        if ($stream)   { $stream.Close() }
        if ($response) { $response.Close() }
    }
}

#endregion

#region ── Firmware Detection ──────────────────────────────────────────────────

function Get-FirmwareType {
    <#
    .SYNOPSIS  Returns 'UEFI' or 'BIOS' using multiple detection methods.

    .NOTES
        Primary:   PEFirmwareType registry value (1 = BIOS, 2 = UEFI).
        Fallback:  Confirm-SecureBootUEFI — available on all Win8+ systems; throws
                   System.PlatformNotSupportedException on non-UEFI firmware, returns
                   $true/$false on UEFI (regardless of Secure Boot state).
    #>
    # Primary: PEFirmwareType registry value written by the kernel at boot
    try {
        $val = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' `
                                 -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
        if ($val -eq 2) { return 'UEFI' }
        if ($val -eq 1) { return 'BIOS' }
        # Any other value (e.g. 0 = unknown) — fall through to secondary check
    } catch { Write-Verbose "Registry firmware type unavailable: $_" }

    # Fallback: Confirm-SecureBootUEFI throws PlatformNotSupportedException on BIOS
    try {
        $null = Confirm-SecureBootUEFI   # $true (SB on) or $false (SB off) on UEFI
        return 'UEFI'
    } catch [System.PlatformNotSupportedException] {
        return 'BIOS'
    } catch {
        Write-Warn "Confirm-SecureBootUEFI failed ($($_.Exception.Message)) — assuming UEFI."
    }

    return 'UEFI'
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
    $clearError = $null
    try {
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    } catch {
        $clearError = $_
        Write-Warn "Clear-Disk failed on disk ${DiskNumber}: $clearError"
    }

    $stepName = ''
    try {

    if ($FirmwareType -eq 'UEFI') {
        # Initialize as GPT
        $stepName = 'Initialize-Disk (GPT)'
        Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop

        # EFI System Partition (ESP)
        $stepName = 'New-Partition (ESP)'
        $esp = New-Partition -DiskNumber $DiskNumber -Size $script:EspSize -GptType $script:GptTypeEsp
        $stepName = 'Format-Volume (ESP FAT32)'
        $null = Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false
        $stepName = 'Add-PartitionAccessPath (ESP)'
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AssignDriveLetter

        # Microsoft Reserved Partition (MSR)
        $stepName = 'New-Partition (MSR)'
        $null = New-Partition -DiskNumber $DiskNumber -Size $script:MsrSize -GptType $script:GptTypeMsr

        # Windows OS Partition - all remaining space
        $stepName = 'New-Partition (OS)'
        $osPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -GptType $script:GptTypeBasicData
        $stepName = 'Format-Volume (OS NTFS)'
        $null = $osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false
        # Format-Volume may auto-assign the drive letter; only reassign if needed.
        $stepName = 'Set-Partition (drive letter)'
        $currentLetter = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber).DriveLetter
        if ([string]$currentLetter -ne [string]$OSDriveLetter) {
            # Free the target letter if another partition already owns it
            $conflict = Get-Partition | Where-Object { $_.DriveLetter -eq $OSDriveLetter } | Select-Object -First 1
            if ($conflict) {
                Remove-PartitionAccessPath -DiskNumber $conflict.DiskNumber -PartitionNumber $conflict.PartitionNumber -AccessPath "${OSDriveLetter}:\"
            }
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $OSDriveLetter
        }

    } else {
        # Initialize as MBR
        $stepName = 'Initialize-Disk (MBR)'
        Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop

        # System/Active partition
        $stepName = 'New-Partition (System)'
        $sysPartition = New-Partition -DiskNumber $DiskNumber -Size $script:MbrSystemSize -IsActive -MbrType 7
        $stepName = 'Format-Volume (System NTFS)'
        $null = $sysPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'System' -Confirm:$false
        $stepName = 'Add-PartitionAccessPath (System)'
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $sysPartition.PartitionNumber -AssignDriveLetter

        # Windows OS Partition - remaining
        $stepName = 'New-Partition (OS)'
        $osPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -MbrType 7
        $stepName = 'Format-Volume (OS NTFS)'
        $null = $osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false
        # Format-Volume may auto-assign the drive letter; only reassign if needed.
        $stepName = 'Set-Partition (drive letter)'
        $currentLetter = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber).DriveLetter
        if ([string]$currentLetter -ne [string]$OSDriveLetter) {
            # Free the target letter if another partition already owns it
            $conflict = Get-Partition | Where-Object { $_.DriveLetter -eq $OSDriveLetter } | Select-Object -First 1
            if ($conflict) {
                Remove-PartitionAccessPath -DiskNumber $conflict.DiskNumber -PartitionNumber $conflict.PartitionNumber -AccessPath "${OSDriveLetter}:\"
            }
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $OSDriveLetter
        }
    }

    } catch {
        $msg = "Disk $DiskNumber partitioning failed at step '$stepName': $_"
        if ($clearError) {
            $msg += " (preceded by Clear-Disk error: $clearError)"
        }
        throw $msg
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
        [string]$Architecture = 'x64',
        [ValidateSet('UEFI','BIOS')]
        [string]$FirmwareType
    )

    $arch = $Architecture
    $allFiles = $Catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File
    $matchedEsd = $allFiles |
        Where-Object {
            $_.LanguageCode -eq $Language -and
            $_.Architecture -eq $arch -and
            $_.Edition      -like "*$($Edition.Replace(' ','*'))*"
        } |
        Sort-Object -Property @{Expression={ [long]$_.Size }; Descending = $true} |
        Select-Object -First 1

    if (-not $matchedEsd) {
        # Dump available entries to aid troubleshooting.
        $available = $allFiles |
            Where-Object { $_.LanguageCode -eq $Language -and $_.Architecture -eq $arch } |
            Select-Object -ExpandProperty Edition -ErrorAction SilentlyContinue |
            Sort-Object -Unique
        if ($available) {
            Write-Warn "Available editions in catalog for Language='$Language', Arch='$arch':"
            $available | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Warn "No entries found for Language='$Language', Arch='$arch'. Available architectures:"
            $allFiles | Select-Object -ExpandProperty Architecture -ErrorAction SilentlyContinue |
                Sort-Object -Unique | ForEach-Object { Write-Host "    $_" }
        }
        throw "No ESD found in catalog for: Edition='$Edition', Language='$Language', Arch='$arch'"
    }

    return $matchedEsd
}

function Get-WindowsImageSource {
    param(
        [string]$ImageUrl,
        [string]$Edition,
        [string]$Language,
        [string]$Architecture = 'x64',
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
    $stepName = ''
    try {
        $stepName = 'Download ESD catalog'
        Write-Step 'Reading Windows ESD catalog from repository...'
        $productsUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/products.xml"
        $productsPath = Join-Path $ScratchDir 'products.xml'
        Invoke-DownloadWithProgress -Uri $productsUrl -OutFile $productsPath -Description 'Fetching Windows ESD catalog'

        $stepName = 'Parse ESD catalog'
        [xml]$catalog = Get-Content $productsPath -Encoding UTF8

        $stepName = 'Find matching ESD'
        $esd     = Find-WindowsESD -Catalog $catalog -Edition $Edition -Language $Language -Architecture $Architecture -FirmwareType $FirmwareType

        Write-Host "  Found ESD: $($esd.FileName) ($([long]$esd.Size | ForEach-Object { Get-FileSizeReadable $_ }))"

        $stepName = 'Download ESD'
        $esdPath = Join-Path $ScratchDir $esd.FileName
        Invoke-DownloadWithProgress -Uri $esd.FilePath -OutFile $esdPath -Description "Downloading Windows ESD: $Edition"

        return $esdPath
    } catch {
        throw "Get-WindowsImageSource failed at step '$stepName': $_"
    }
}

#endregion

#region ── Image Application ────────────────────────────────────────────────────

# Maps Microsoft ESD catalog edition identifiers to the keywords used
# in WIM/ESD ImageName fields (e.g. 'Professional' → 'Pro').
$script:EditionNameMap = @{
    'Professional'            = 'Pro'
    'ProfessionalN'           = 'Pro N'
    'ProfessionalWorkstation' = 'Pro for Workstations'
    'HomePremium'             = 'Home'
    'HomePremiumN'            = 'Home N'
    'CoreSingleLanguage'      = 'Home Single Language'
    'Education'               = 'Education'
    'EducationN'              = 'Education N'
    'Enterprise'              = 'Enterprise'
    'EnterpriseN'             = 'Enterprise N'
}

function Install-WindowsImage {
    param(
        [string]$ImagePath,
        [string]$Edition,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    Write-Step "Applying Windows image to ${OSDriveLetter}:..."

    $stepName = ''
    try {
        # Get the correct image index for the requested edition
        $stepName = 'Get-WindowsImage (enumerate editions)'
        $images = Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop
        Write-Host "  Available editions in image:"
        $images | ForEach-Object { Write-Host "    [$($_.ImageIndex)] $($_.ImageName)" }

        $stepName = 'Find target edition'
        $targetImage = $images | Where-Object { $_.ImageName -like "*$Edition*" } | Select-Object -First 1

        # The catalog uses short IDs (e.g. 'Professional') while WIM ImageName
        # uses friendly names (e.g. 'Windows 11 Pro').  Try the mapped name.
        if (-not $targetImage -and $script:EditionNameMap.ContainsKey($Edition)) {
            $mappedName = $script:EditionNameMap[$Edition]
            $targetImage = $images | Where-Object { $_.ImageName -like "*$mappedName*" } | Select-Object -First 1
        }

        if (-not $targetImage) {
            Write-Warn "Edition '$Edition' not found. Using index 1."
            $targetImage = $images | Select-Object -First 1
        }

        $stepName = 'Expand-WindowsImage (apply)'
        Write-Step "Applying image index $($targetImage.ImageIndex): $($targetImage.ImageName)"
        $scratch = Join-Path $ScratchDir 'scratch'
        New-ScratchDirectory -Path $scratch

        $null = Expand-WindowsImage `
            -ImagePath       $ImagePath `
            -Index           $targetImage.ImageIndex `
            -ApplyPath       "${OSDriveLetter}:\" `
            -ScratchDirectory $scratch `
            -ErrorAction Stop

        Write-Success 'Windows image applied successfully.'
    } catch {
        throw "Install-WindowsImage failed at step '$stepName': $_"
    }
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

    $stepName = ''
    try {
        if ($FirmwareType -eq 'UEFI') {
            # Find the EFI system partition
            $stepName = 'Find EFI System Partition'
            $espDrive = (Get-Partition -DiskNumber $DiskNumber |
                Where-Object { $_.GptType -eq $script:GptTypeEsp } |
                Get-Volume |
                Select-Object -First 1).DriveLetter

            if (-not $espDrive) {
                # Assign a temporary drive letter to ESP
                $stepName = 'Assign ESP drive letter'
                $esp = Get-Partition -DiskNumber $DiskNumber |
                    Where-Object { $_.GptType -eq $script:GptTypeEsp } |
                    Select-Object -First 1
                Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AssignDriveLetter
                $espDrive = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber | Get-Volume).DriveLetter
            }

            $stepName = 'bcdboot (UEFI)'
            Write-Host "  EFI partition: ${espDrive}:"
            & bcdboot.exe "$osDrive\Windows" /s "${espDrive}:" /f UEFI 2>&1 | Write-Host
        } else {
            $stepName = 'bcdboot (BIOS)'
            & bcdboot.exe "$osDrive\Windows" /s "$osDrive" /f BIOS 2>&1 | Write-Host
        }

        if ($LASTEXITCODE -ne 0) { throw "bcdboot failed with exit code $LASTEXITCODE" }
        Write-Success 'Bootloader configured.'
    } catch {
        throw "Set-Bootloader failed at step '$stepName': $_"
    }
}

#endregion

#region ── Driver Injection ─────────────────────────────────────────────────────

function Add-Driver {
    param(
        [string]$DriverPath,
        [string]$OSDriveLetter
    )

    if (-not $DriverPath -or -not (Test-Path $DriverPath)) {
        Write-Warn "Driver path not specified or not found: '$DriverPath'. Skipping driver injection."
        return
    }

    Write-Step "Injecting drivers from: $DriverPath"

    $stepName = ''
    try {
        $stepName = 'Enumerate driver .inf files'
        $infFiles = Get-ChildItem $DriverPath -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
        if (-not $infFiles) {
            Write-Warn 'No .inf files found in driver path. Skipping.'
            return
        }

        Write-Host "  Found $($infFiles.Count) driver(s)."

        $stepName = 'Add-WindowsDriver'
        $null = Add-WindowsDriver `
            -Path        "${OSDriveLetter}:\" `
            -Driver      $DriverPath `
            -Recurse `
            -ErrorAction Continue

        Write-Success "Drivers injected from: $DriverPath"
    } catch {
        throw "Add-Driver failed at step '$stepName': $_"
    }
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
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop
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

function Add-DellDriver {
    <#
    .SYNOPSIS
        Downloads and injects the latest Dell drivers using Dell Command | Update.
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching Dell drivers via Dell Command | Update (DCU)...'

    $stepName = ''
    try {
        $stepName = 'Install DellCommandUpdate module'
        Install-OemModule -Name 'DellCommandUpdate'
        $stepName = 'Import DellCommandUpdate module'
        Import-Module DellCommandUpdate -ErrorAction Stop

        $stepName = 'Invoke-DCUUpdate'
        $driverTemp = Join-Path $ScratchDir 'Dell-Drivers'
        $null = New-Item -ItemType Directory -Path $driverTemp -Force

        # Download applicable driver updates without applying them to the live OS.
        Invoke-DCUUpdate -UpdateType driver -DownloadPath $driverTemp -ApplyUpdates:$false

        $stepName = 'Inject Dell drivers'
        $infFiles = Get-ChildItem $driverTemp -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
        if (-not $infFiles) {
            Write-Warn 'Dell Command | Update found no driver packages to inject.'
            return
        }

        Write-Host "  Injecting $($infFiles.Count) Dell driver(s) into ${OSDriveLetter}:\..."
        $null = Add-WindowsDriver -Path "${OSDriveLetter}:\" -Driver $driverTemp -Recurse `
            -ErrorAction Continue
        Write-Success 'Dell drivers injected successfully.'
    } catch {
        throw "Add-DellDriver failed at step '$stepName': $_"
    }
}

function Add-HpDriver {
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

    $stepName = ''
    try {
        $stepName = 'Install HPCMSL module'
        Install-OemModule -Name 'HPCMSL'
        $stepName = 'Import HPCMSL module'
        Import-Module HPCMSL -ErrorAction Stop

        $stepName = 'Add-HPDrivers'
        $driverTemp = Join-Path $ScratchDir 'HP-Drivers'
        $null = New-Item -ItemType Directory -Path $driverTemp -Force

        # Add-HPDrivers handles platform detection, SoftPaq download, extraction,
        # and offline DISM injection in a single call.
        Add-HPDrivers -Path "${OSDriveLetter}:\" -TempPath $driverTemp -ErrorAction Stop
        Write-Success 'HP drivers injected successfully.'
    } catch {
        throw "Add-HpDriver failed at step '$stepName': $_"
    }
}

function Add-LenovoDriver {
    <#
    .SYNOPSIS
        Downloads and injects the latest Lenovo drivers using LSUClient.
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching Lenovo drivers via LSUClient...'

    $stepName = ''
    try {
        $stepName = 'Install LSUClient module'
        Install-OemModule -Name 'LSUClient'
        $stepName = 'Import LSUClient module'
        Import-Module LSUClient -ErrorAction Stop

        $driverTemp = Join-Path $ScratchDir 'Lenovo-Drivers'
        $null = New-Item -ItemType Directory -Path $driverTemp -Force

        $stepName = 'Get-LSUpdate'
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

        $stepName = 'Save-LSUpdate'
        Write-Host "  Found $($updates.Count) Lenovo driver package(s). Downloading..."
        $updates | Save-LSUpdate -Path $driverTemp

        $stepName = 'Inject Lenovo drivers'
        $infFiles = Get-ChildItem $driverTemp -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
        if (-not $infFiles) {
            Write-Warn 'No .inf files found in downloaded Lenovo packages. Skipping injection.'
            return
        }

        Write-Host "  Injecting $($infFiles.Count) driver(s) into ${OSDriveLetter}:\..."
        $null = Add-WindowsDriver -Path "${OSDriveLetter}:\" -Driver $driverTemp -Recurse `
            -ErrorAction Continue
        Write-Success 'Lenovo drivers injected successfully.'
    } catch {
        throw "Add-LenovoDriver failed at step '$stepName': $_"
    }
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

    $stepName = ''
    try {
        $stepName = 'Detect manufacturer'
        $manufacturer = Get-SystemManufacturer
        Write-Host "  Manufacturer: '$manufacturer'"

        $stepName = "Inject drivers for '$manufacturer'"
        switch -Wildcard ($manufacturer) {
            '*Dell*'    { Add-DellDriver    -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*HP*'      { Add-HpDriver      -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*Hewlett*' { Add-HpDriver      -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*Lenovo*'  { Add-LenovoDriver  -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            default {
                Write-Warn "Manufacturer '$manufacturer' is not supported for OEM driver automation. Use -DriverPath for manual driver injection."
            }
        }
    } catch {
        throw "Invoke-OemDriverInjection failed at step '$stepName': $_"
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

    $stepName = ''
    try {
        $stepName = 'Create Autopilot directory'
        $autopilotDest = "${OSDriveLetter}:\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json"
        $null = New-Item -ItemType Directory -Path (Split-Path $autopilotDest) -Force

        if ($JsonUrl) {
            $stepName = 'Download Autopilot JSON'
            Write-Host "  Fetching Autopilot JSON from: $JsonUrl"
            Invoke-WebRequest -Uri $JsonUrl -OutFile $autopilotDest -UseBasicParsing
        } else {
            $stepName = 'Copy Autopilot JSON'
            Copy-Item $JsonPath $autopilotDest -Force
        }

        Write-Success "Autopilot JSON placed at: $autopilotDest"
    } catch {
        throw "Set-AutopilotConfig failed at step '$stepName': $_"
    }
}

function Invoke-AutopilotImport {
    <#
    .SYNOPSIS  Registers the current device in Windows Autopilot via Microsoft Graph API.
    .DESCRIPTION
        Dot-sources the staged Autopilot scripts from X:\OSDCloud\Config\Scripts\Custom
        and calls Import-AutopilotDevice.  The Graph access token is read from the
        AMPCLOUD_GRAPH_TOKEN environment variable set by Bootstrap.ps1.  If no group
        tag is provided or no token is available the step is skipped gracefully.
    #>
    param(
        [string]$GroupTag,
        [string]$UserEmail
    )

    if (-not $GroupTag) {
        Write-Warn 'No Autopilot GroupTag specified. Skipping Autopilot device import.'
        return
    }

    $token = $env:AMPCLOUD_GRAPH_TOKEN
    if (-not $token) {
        Write-Warn 'No Graph access token available (AMPCLOUD_GRAPH_TOKEN). Skipping Autopilot device import.'
        return
    }

    $customFolder = 'X:\OSDCloud\Config\Scripts\Custom'
    $importScript = Join-Path $customFolder 'Invoke-ImportAutopilot.ps1'
    $utilsScript  = Join-Path $customFolder 'Utils.ps1'

    if (-not (Test-Path $importScript) -or -not (Test-Path $utilsScript)) {
        Write-Warn 'Autopilot scripts not staged in WinPE. Skipping device import.'
        return
    }

    Write-Step 'Importing device into Windows Autopilot...'

    # Set the script-scoped token so Get-GraphToken (defined in Utils.ps1)
    # can return it.  This is the same contract Utils.ps1 uses when sourced
    # by Bootstrap.ps1 — see Autopilot/Utils.ps1 line 17.
    $script:GraphAccessToken = $token

    # Source the utility functions and the import script.
    . $utilsScript
    . $importScript

    $importArgs = @{ GroupTag = $GroupTag }
    if ($UserEmail) { $importArgs.UserEmail = $UserEmail }

    $result = Import-AutopilotDevice @importArgs
    if ($result.Success) {
        Write-Success "Autopilot import: $($result.Message)"
    } else {
        throw "Autopilot device import failed: $($result.Message)"
    }
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

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $ccmDir  = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $ccmDir -Force

        $stepName = 'Download ccmsetup.exe'
        $ccmExe  = Join-Path $ScratchDir 'ccmsetup.exe'
        Invoke-DownloadWithProgress -Uri $CCMSetupUrl -OutFile $ccmExe -Description 'Downloading ccmsetup.exe'

        $stepName = 'Stage ccmsetup.exe'
        Copy-Item $ccmExe (Join-Path $ccmDir 'ccmsetup.exe') -Force

        # Add to SetupComplete.cmd to run ccmsetup on first boot
        $stepName = 'Add SetupComplete entry'
        $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
        Add-SetupCompleteEntry -FilePath $setupComplete -Line '"%~dp0ccmsetup.exe" /BITSPriority:FOREGROUND'

        Write-Success 'CCMSetup staged for first-boot execution.'
    } catch {
        throw "Install-CCMSetup failed at step '$stepName': $_"
    }
}

#endregion

#region ── OOBE Customization ───────────────────────────────────────────────────

function Set-OOBECustomization {
    param(
        [string]$UnattendUrl,
        [string]$UnattendPath,
        [string]$UnattendContent,
        [string]$OSDriveLetter,
        [string]$InputLocale,
        [string]$SystemLocale,
        [string]$UserLocale,
        [string]$UILanguage,
        [string]$ComputerName
    )

    Write-Step 'Applying OOBE customization...'

    $stepName = ''
    try {
        $stepName = 'Create Panther directory'
        $unattendDest = "${OSDriveLetter}:\Windows\Panther\unattend.xml"
        $null = New-Item -ItemType Directory -Path (Split-Path $unattendDest) -Force

        if ($UnattendUrl) {
            $stepName = 'Download unattend.xml'
            Write-Host "  Fetching unattend.xml from: $UnattendUrl"
            Invoke-WebRequest -Uri $UnattendUrl -OutFile $unattendDest -UseBasicParsing
            Write-Success "Custom unattend.xml applied from URL."
            return
        }

        if ($UnattendPath -and (Test-Path $UnattendPath)) {
            $stepName = 'Copy unattend.xml'
            Copy-Item $UnattendPath $unattendDest -Force
            Write-Success "Custom unattend.xml applied from path: $UnattendPath"
            return
        }

        if ($UnattendContent) {
            $stepName = 'Apply editor unattend.xml'
            Set-Content -Path $unattendDest -Value $UnattendContent -Encoding UTF8
            Write-Success 'Custom unattend.xml applied from task sequence content.'
            return
        }

        # Generate a default unattend.xml with locale and device name settings
        $stepName = 'Generate default unattend.xml'

        # XML-encode a value to prevent XML injection / broken structure
        function EncodeXml([string]$v) {
            return [System.Security.SecurityElement]::Escape($v)
        }

        # Build the International-Core component for locale/keyboard settings
        $intlComponent = ''
        if ($InputLocale -or $SystemLocale -or $UserLocale -or $UILanguage) {
            $intlParts = @()
            if ($InputLocale)  { $intlParts += "        <InputLocale>$(EncodeXml $InputLocale)</InputLocale>" }
            if ($SystemLocale) { $intlParts += "        <SystemLocale>$(EncodeXml $SystemLocale)</SystemLocale>" }
            if ($UserLocale)   { $intlParts += "        <UserLocale>$(EncodeXml $UserLocale)</UserLocale>" }
            if ($UILanguage)   { $intlParts += "        <UILanguage>$(EncodeXml $UILanguage)</UILanguage>" }
            $intlComponent = @"
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
$($intlParts -join "`n")
    </component>
"@
        }

        # Build ComputerName element if specified
        $computerNameElement = ''
        if ($ComputerName) {
            $computerNameElement = "      <ComputerName>$(EncodeXml $ComputerName)</ComputerName>"
        }

    $defaultUnattend = @"
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
$(if ($computerNameElement) { $computerNameElement })
    </component>
$(if ($intlComponent) { $intlComponent })
  </settings>
</unattend>
"@
    Set-Content -Path $unattendDest -Value $defaultUnattend -Encoding UTF8
    if ($InputLocale -or $SystemLocale -or $UserLocale -or $UILanguage -or $ComputerName) {
        Write-Success 'Default unattend.xml applied with locale and device name settings.'
    } else {
        Write-Success 'Default unattend.xml applied.'
    }
    } catch {
        throw "Set-OOBECustomization failed at step '$stepName': $_"
    }
}

#endregion

#region ── Post-Provisioning Scripts ────────────────────────────────────────────

function Invoke-PostScript {
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

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $scriptDir -Force

        $i = 1
        foreach ($url in $ScriptUrls) {
            $fileName = "AmpCloud_Post_$($i.ToString('00')).ps1"
            $stepName = "Download post-script '$fileName'"
            $dest     = Join-Path $scriptDir $fileName
            Write-Host "  Downloading: $url -> $fileName"
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
            $i++
        }

        # Add each script to SetupComplete.cmd
        $stepName = 'Add SetupComplete entries'
        $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
        for ($j = 1; $j -lt $i; $j++) {
            $fileName = "AmpCloud_Post_$($j.ToString('00')).ps1"
            Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$fileName`""
        }

        Write-Success "Post-provisioning scripts staged in: $scriptDir"
    } catch {
        throw "Invoke-PostScript failed at step '$stepName': $_"
    }
}

#endregion

#region ── Task Sequence ────────────────────────────────────────────────────────

function Read-TaskSequence {
    <#
    .SYNOPSIS  Loads a task sequence JSON file produced by the web-based Editor.
    .DESCRIPTION
        Reads the JSON file, validates the required structure (name + steps array),
        and returns a hashtable matching the schema in TaskSequence/default.json.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path $Path)) {
        throw "Task sequence file not found: $Path"
    }
    Write-Step "Loading task sequence from $Path"
    $raw = Get-Content $Path -Raw -ErrorAction Stop
    $ts  = $raw | ConvertFrom-Json -ErrorAction Stop

    if (-not $ts.steps -or $ts.steps -isnot [System.Collections.IEnumerable]) {
        throw "Invalid task sequence file: missing 'steps' array"
    }
    foreach ($s in $ts.steps) {
        if (-not $s.type) { throw "Invalid task sequence: step '$($s.name)' is missing required 'type' property" }
        if (-not $s.name) { throw "Invalid task sequence: a step with type '$($s.type)' is missing required 'name' property" }
    }
    Write-Success "Loaded task sequence '$($ts.name)' with $($ts.steps.Count) steps"
    return $ts
}

function Invoke-TaskSequenceStep {
    <#
    .SYNOPSIS  Executes a single task sequence step by dispatching to the matching engine function.
    .DESCRIPTION
        Maps each step type string to the corresponding AmpCloud engine function,
        passing the step's parameters.  Uses the same functions that the hardcoded
        path calls, so behaviour is identical.
    #>
    param(
        [Parameter(Mandatory)]
        [psobject]$Step,
        [int]$Index,
        [int]$TotalSteps,
        # Shared state needed across steps (set by the caller)
        [string]$CurrentScratchDir,
        [string]$CurrentOSDrive,
        [string]$CurrentFirmwareType,
        [int]$CurrentDiskNumber
    )

    $pct = [math]::Min(100, [math]::Round(($Index / $TotalSteps) * 100))
    # Bootstrap.ps1 UI shows four progress steps (Network / Connect / Sign in /
    # Deploy).  During the deploy phase all four indicators should stay lit, so
    # always report Step 4 to keep the first three steps highlighted.
    $uiStep = 4
    $p = $Step.parameters

    switch ($Step.type) {
        'PartitionDisk' {
            $disk = if ($p -and $null -ne $p.diskNumber) { $p.diskNumber } else { $CurrentDiskNumber }
            $drv  = if ($p -and $p.osDriveLetter)        { $p.osDriveLetter } else { $CurrentOSDrive }
            Update-BootstrapStatus -Message "Partitioning disk..." -Detail "Creating layout on disk $disk" -Step $uiStep -Progress $pct
            Initialize-TargetDisk -DiskNumber $disk -FirmwareType $CurrentFirmwareType -OSDriveLetter $drv
        }
        'ImportAutopilot' {
            $tag   = if ($p -and $p.groupTag)  { $p.groupTag }  else { $AutopilotGroupTag }
            $email = if ($p -and $p.userEmail) { $p.userEmail } else { $AutopilotUserEmail }
            Update-BootstrapStatus -Message "Importing Autopilot device..." -Detail "Registering device in Windows Autopilot" -Step $uiStep -Progress $pct
            Invoke-AutopilotImport -GroupTag $tag -UserEmail $email
        }
        'DownloadImage' {
            $url  = if ($p -and $p.imageUrl)      { $p.imageUrl }      else { $WindowsImageUrl }
            $ed   = if ($p -and $p.edition)        { $p.edition }       else { $WindowsEdition }
            $lang = if ($p -and $p.language)        { $p.language }      else { $WindowsLanguage }
            $arch = if ($p -and $p.architecture)    { $p.architecture }  else { $WindowsArchitecture }
            Update-BootstrapStatus -Message "Downloading Windows image..." -Detail "Fetching $ed $lang $arch" -Step $uiStep -Progress $pct
            $script:TsImagePath = Get-WindowsImageSource `
                -ImageUrl $url -Edition $ed -Language $lang -Architecture $arch `
                -FirmwareType $CurrentFirmwareType -ScratchDir $CurrentScratchDir
        }
        'ApplyImage' {
            $ed = if ($p -and $p.edition) { $p.edition } else { $WindowsEdition }
            Update-BootstrapStatus -Message "Applying Windows image..." -Detail "Expanding Windows files" -Step $uiStep -Progress $pct
            Install-WindowsImage -ImagePath $script:TsImagePath -Edition $ed -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'SetBootloader' {
            Update-BootstrapStatus -Message "Configuring bootloader..." -Detail "Writing BCD store" -Step $uiStep -Progress $pct
            Set-Bootloader -OSDriveLetter $CurrentOSDrive -FirmwareType $CurrentFirmwareType -DiskNumber $CurrentDiskNumber
        }
        'InjectDrivers' {
            $dp = if ($p -and $p.driverPath) { $p.driverPath } else { $DriverPath }
            Update-BootstrapStatus -Message "Injecting drivers..." -Detail "Adding drivers" -Step $uiStep -Progress $pct
            Add-Driver -DriverPath $dp -OSDriveLetter $CurrentOSDrive
        }
        'InjectOemDrivers' {
            Update-BootstrapStatus -Message "Injecting OEM drivers..." -Detail "Fetching manufacturer drivers" -Step $uiStep -Progress $pct
            Invoke-OemDriverInjection -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'ApplyAutopilot' {
            $jUrl  = if ($p -and $p.jsonUrl)  { $p.jsonUrl }  else { $AutopilotJsonUrl }
            $jPath = if ($p -and $p.jsonPath) { $p.jsonPath } else { $AutopilotJsonPath }
            Update-BootstrapStatus -Message "Applying Autopilot configuration..." -Detail "Embedding provisioning profile" -Step $uiStep -Progress $pct
            Set-AutopilotConfig -JsonUrl $jUrl -JsonPath $jPath -OSDriveLetter $CurrentOSDrive
        }
        'StageCCMSetup' {
            $url = if ($p -and $p.ccmSetupUrl) { $p.ccmSetupUrl } else { $CCMSetupUrl }
            Update-BootstrapStatus -Message "Staging ConfigMgr setup..." -Detail "Preparing ccmsetup.exe" -Step $uiStep -Progress $pct
            Install-CCMSetup -CCMSetupUrl $url -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'CustomizeOOBE' {
            $uUrl     = if ($p -and $p.unattendUrl)  { $p.unattendUrl }  else { $UnattendUrl }
            $uPath    = if ($p -and $p.unattendPath)  { $p.unattendPath }  else { $UnattendPath }
            $uContent = if ($p -and $p.unattendSource -eq 'default' -and $p.unattendContent) { $p.unattendContent } elseif (-not $p -or $p.unattendSource -ne 'cloud') { $UnattendContent } else { '' }
            $iLocale  = if ($p -and $p.inputLocale)   { $p.inputLocale }   else { $InputLocale }
            $sLocale  = if ($p -and $p.systemLocale)   { $p.systemLocale }  else { $SystemLocale }
            $uLocale  = if ($p -and $p.userLocale)     { $p.userLocale }    else { $UserLocale }
            $uiLang   = if ($p -and $p.uiLanguage)     { $p.uiLanguage }   else { $UILanguage }
            $cName    = if ($p -and $p.computerName)    { $p.computerName }  else { $ComputerName }
            Update-BootstrapStatus -Message "Customizing OOBE..." -Detail "Applying unattend.xml" -Step $uiStep -Progress $pct
            Set-OOBECustomization -UnattendUrl $uUrl -UnattendPath $uPath -UnattendContent $uContent -OSDriveLetter $CurrentOSDrive `
                -InputLocale $iLocale -SystemLocale $sLocale -UserLocale $uLocale -UILanguage $uiLang -ComputerName $cName
        }
        'RunPostScripts' {
            $urls = if ($p -and $p.scriptUrls) { @($p.scriptUrls) } else { $PostScriptUrls }
            Update-BootstrapStatus -Message "Staging post-scripts..." -Detail "Downloading post-provisioning scripts" -Step $uiStep -Progress $pct
            Invoke-PostScript -ScriptUrls $urls -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        default {
            Write-Warn "Unknown step type '$($Step.type)' — skipping"
        }
    }
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

        Update-BootstrapStatus -Message 'Imaging complete — rebooting...' -Detail 'Windows installation finished successfully' -Step 4 -Progress 100 -Done

    } else {

    # ── Default hardcoded execution path (backward compatible) ──────
    Write-Step "Firmware type: $FirmwareType"

    # Ensure scratch directory exists
    $stepName = 'Create scratch directory'
    New-ScratchDirectory -Path $ScratchDir

    # Step 1: Partition the disk
    $stepName = 'Partition disk'
    Update-BootstrapStatus -Message 'Partitioning disk...' -Detail 'Creating GPT layout on target drive' -Step 4 -Progress 10
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
    Update-BootstrapStatus -Message 'Downloading Windows image...' -Detail 'Fetching ESD image from Microsoft CDN' -Step 4 -Progress 20
    $imagePath = Get-WindowsImageSource `
        -ImageUrl      $WindowsImageUrl `
        -Edition       $WindowsEdition `
        -Language      $WindowsLanguage `
        -Architecture  $WindowsArchitecture `
        -FirmwareType  $FirmwareType `
        -ScratchDir    $ScratchDir

    # Step 3: Apply Windows image
    $stepName = 'Apply Windows image'
    Update-BootstrapStatus -Message 'Applying Windows image...' -Detail 'Expanding Windows files to target partition' -Step 4 -Progress 50
    Install-WindowsImage `
        -ImagePath     $imagePath `
        -Edition       $WindowsEdition `
        -OSDriveLetter $OSDrive `
        -ScratchDir    $ScratchDir

    # Step 4: Configure bootloader
    $stepName = 'Configure bootloader'
    Update-BootstrapStatus -Message 'Configuring bootloader...' -Detail 'Writing BCD store and EFI boot entries' -Step 4 -Progress 65
    Set-Bootloader `
        -OSDriveLetter $OSDrive `
        -FirmwareType  $FirmwareType `
        -DiskNumber    $TargetDiskNumber

    # Step 5: Inject drivers
    $stepName = 'Inject drivers'
    Update-BootstrapStatus -Message 'Injecting drivers...' -Detail 'Adding network and storage drivers' -Step 4 -Progress 75
    Add-Driver `
        -DriverPath    $DriverPath `
        -OSDriveLetter $OSDrive

    if ($UseOemDrivers) {
        $stepName = 'Inject OEM drivers'
        Update-BootstrapStatus -Message 'Injecting OEM drivers...' -Detail 'Adding manufacturer-specific drivers' -Step 4 -Progress 80
        Invoke-OemDriverInjection `
            -OSDriveLetter $OSDrive `
            -ScratchDir    $ScratchDir
    }

    # Step 6: Apply Autopilot/Intune configuration
    $stepName = 'Apply Autopilot configuration'
    Update-BootstrapStatus -Message 'Applying Autopilot configuration...' -Detail 'Embedding Autopilot provisioning profile' -Step 4 -Progress 85
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
    Update-BootstrapStatus -Message 'Customizing OOBE...' -Detail 'Setting out-of-box experience preferences' -Step 4 -Progress 90
    Set-OOBECustomization `
        -UnattendUrl     $UnattendUrl `
        -UnattendPath    $UnattendPath `
        -UnattendContent $UnattendContent `
        -OSDriveLetter   $OSDrive `
        -InputLocale     $InputLocale `
        -SystemLocale    $SystemLocale `
        -UserLocale      $UserLocale `
        -UILanguage      $UILanguage `
        -ComputerName    $ComputerName

    # Step 9: Stage post-provisioning scripts
    $stepName = 'Stage post-provisioning scripts'
    Invoke-PostScript `
        -ScriptUrls    $PostScriptUrls `
        -OSDriveLetter $OSDrive `
        -ScratchDir    $ScratchDir

    Update-BootstrapStatus -Message 'Imaging complete — rebooting...' -Detail 'Windows installation finished successfully' -Step 4 -Progress 100 -Done

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
    # Re-throw so Bootstrap.ps1 can close the UI before the user
    # needs the console.  The PowerShell host was started with -NoExit by
    # ampcloud-start.cmd, so an interactive prompt appears automatically
    # once the form is dismissed.
    throw
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}

#endregion

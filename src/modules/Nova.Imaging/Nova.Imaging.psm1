<#
.SYNOPSIS
    Windows image download, application, and bootloader configuration for Nova.

.DESCRIPTION
    Provides functions for finding Windows ESD images in catalog XML, downloading
    Windows images (ESD or direct URL), applying images via DISM, and configuring
    the BCD bootloader for UEFI and BIOS systems.

    Extracted from Nova.ps1 to promote module-based architecture and testability.
#>

Set-StrictMode -Version Latest

# ── Module-scoped Constants ──────────────────────────────────────────────────

# Maps Microsoft ESD catalog edition identifiers to the keywords used
# in WIM/ESD ImageName fields (e.g. 'Professional' -> 'Pro').
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

# ── Public Functions ─────────────────────────────────────────────────────────

function Get-EditionNameMap {
    <#
    .SYNOPSIS  Returns the edition name mapping hashtable.
    .DESCRIPTION
        Provides read-only access to the module-scoped EditionNameMap constant,
        which maps ESD catalog edition identifiers (e.g. 'Professional') to
        their WIM/ESD ImageName counterparts (e.g. 'Pro').
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param()
    return $script:EditionNameMap
}

function Find-WindowsESD {
    <#
    .SYNOPSIS  Finds a matching ESD entry in a Windows catalog XML.
    .DESCRIPTION
        Searches the MCT catalog XML for an ESD matching the requested edition,
        language, and architecture.  Returns the largest matching entry.  When no
        match is found, dumps available editions to aid troubleshooting before
        throwing a terminating error.
    .PARAMETER Catalog
        Parsed XML content of the products.xml catalog.
    .PARAMETER Edition
        Windows edition to search for (e.g. 'Professional', 'Education').
    .PARAMETER Language
        Language code (e.g. 'en-us').
    .PARAMETER Architecture
        CPU architecture.  Defaults to 'x64'.
    .PARAMETER FirmwareType
        Firmware type ('UEFI' or 'BIOS').  Reserved for future filtering.
    .OUTPUTS
        The matching catalog File element.
    #>
    [OutputType([System.Xml.XmlElement])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [xml]$Catalog,
        [Parameter(Mandatory)]
        [string]$Edition,
        [Parameter(Mandatory)]
        [string]$Language,
        [string]$Architecture = 'x64',
        [ValidateSet('UEFI','BIOS')]
        [string]$FirmwareType
    )

    $null = $FirmwareType
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
    <#
    .SYNOPSIS  Downloads a Windows image (ESD or direct URL).
    .DESCRIPTION
        When ImageUrl is provided, downloads the image directly.  Otherwise reads
        the ESD catalog from the GitHub repository, finds the matching ESD entry,
        and downloads it.
    .PARAMETER ImageUrl
        Optional direct URL to a Windows image (ISO/WIM/ESD).
    .PARAMETER Edition
        Windows edition for ESD catalog lookup.
    .PARAMETER Language
        Language code for ESD catalog lookup.
    .PARAMETER Architecture
        CPU architecture.  Defaults to 'x64'.
    .PARAMETER FirmwareType
        Firmware type ('UEFI' or 'BIOS').
    .PARAMETER ScratchDir
        Working directory for downloaded files.
    .PARAMETER GitHubUser
        GitHub repository owner for catalog URL.
    .PARAMETER GitHubRepo
        GitHub repository name for catalog URL.
    .PARAMETER GitHubBranch
        GitHub branch name for catalog URL.
    .PARAMETER DownloadCommand
        Optional scriptblock for downloading files.  Receives parameters:
        -Uri, -OutFile, -Description, -BaseProgress, -ProgressRange.
        If not provided, falls back to Invoke-WebRequest.
    .OUTPUTS
        System.String -- full path to the downloaded image file.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [string]$ImageUrl,
        [string]$Edition,
        [string]$Language,
        [string]$Architecture = 'x64',
        [string]$FirmwareType,
        [Parameter(Mandatory)]
        [string]$ScratchDir,
        [string]$GitHubUser,
        [string]$GitHubRepo,
        [string]$GitHubBranch,
        [scriptblock]$DownloadCommand
    )

    # Create scratch dir
    if (-not (Test-Path $ScratchDir)) {
        $null = New-Item -ItemType Directory -Path $ScratchDir -Force
    }

    # Check for pre-cached image on USB/local drives before downloading
    $excludeDrives = @('X')
    $cached = Find-CachedImage -Edition $Edition -Language $Language -Architecture $Architecture -ExcludeDrives $excludeDrives
    if ($cached) {
        Write-Success "Using cached image -- skipping download: $cached"
        return $cached
    }

    if ($ImageUrl) {
        # User-supplied image URL
        $ext = [System.IO.Path]::GetExtension($ImageUrl).ToLower()
        $imagePath = Join-Path $ScratchDir "windows$ext"
        if ($DownloadCommand) {
            & $DownloadCommand -Uri $ImageUrl -OutFile $imagePath -Description 'Downloading Windows image' `
                -BaseProgress 20 -ProgressRange 30
        } else {
            Write-Step 'Downloading Windows image...'
            Invoke-WebRequest -Uri $ImageUrl -OutFile $imagePath -UseBasicParsing
        }
        return $imagePath
    }

    # Read the ESD catalog directly from the repository.
    $stepName = ''
    try {
        $stepName = 'Download ESD catalog'
        Write-Step 'Reading Windows ESD catalog from repository...'
        $productsUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/resources/products.xml"
        $productsPath = Join-Path $ScratchDir 'products.xml'
        if ($DownloadCommand) {
            & $DownloadCommand -Uri $productsUrl -OutFile $productsPath -Description 'Fetching Windows ESD catalog'
        } else {
            Invoke-WebRequest -Uri $productsUrl -OutFile $productsPath -UseBasicParsing
        }

        $stepName = 'Parse ESD catalog'
        [xml]$catalog = Get-Content $productsPath -Encoding UTF8

        $stepName = 'Find matching ESD'
        $esd     = Find-WindowsESD -Catalog $catalog -Edition $Edition -Language $Language -Architecture $Architecture -FirmwareType $FirmwareType

        Write-Host "  Found ESD: $($esd.FileName) ($([long]$esd.Size | ForEach-Object { Get-FileSizeReadable $_ }))"

        $stepName = 'Download ESD'
        $esdPath = Join-Path $ScratchDir $esd.FileName
        if ($DownloadCommand) {
            & $DownloadCommand -Uri $esd.FilePath -OutFile $esdPath -Description "Downloading Windows ESD: $Edition" `
                -BaseProgress 20 -ProgressRange 30
        } else {
            Write-Step "Downloading Windows ESD: $Edition"
            Invoke-WebRequest -Uri $esd.FilePath -OutFile $esdPath -UseBasicParsing
        }

        return $esdPath
    } catch {
        throw "Get-WindowsImageSource failed at step '$stepName': $_"
    }
}

function Install-WindowsImage {
    <#
    .SYNOPSIS  Applies a Windows image to the target OS partition.
    .DESCRIPTION
        Enumerates editions in the image file, matches the requested edition
        (using both direct name and the EditionNameMap fallback), then applies
        the image via Expand-WindowsImage.
    .PARAMETER ImagePath
        Path to the WIM or ESD image file.
    .PARAMETER Edition
        Windows edition to apply.
    .PARAMETER OSDriveLetter
        Drive letter of the target OS partition (without colon).
    .PARAMETER ScratchDir
        Working directory for DISM scratch space.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,
        [Parameter(Mandatory)]
        [string]$Edition,
        [Parameter(Mandatory)]
        [string]$OSDriveLetter,
        [Parameter(Mandatory)]
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
        if (-not (Test-Path $scratch)) {
            $null = New-Item -ItemType Directory -Path $scratch -Force
        }

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

function Set-Bootloader {
    <#
    .SYNOPSIS  Configures the BCD bootloader for UEFI or BIOS boot.
    .DESCRIPTION
        For UEFI systems, locates the EFI System Partition (by GPT type GUID),
        assigns a drive letter if needed, and runs bcdboot.exe to install the
        UEFI bootloader.  For BIOS systems, runs bcdboot.exe with /f BIOS.
    .PARAMETER OSDriveLetter
        Drive letter of the target OS partition (without colon).
    .PARAMETER FirmwareType
        Firmware type -- 'UEFI' or 'BIOS'.
    .PARAMETER DiskNumber
        Physical disk number containing the partitions.
    .PARAMETER GptTypeEsp
        GPT type GUID for the EFI System Partition.
        Defaults to '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'.
    #>
    [OutputType([void])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$OSDriveLetter,
        [Parameter(Mandatory)]
        [ValidateSet('UEFI','BIOS')]
        [string]$FirmwareType,
        [Parameter(Mandatory)]
        [int]$DiskNumber,
        [string]$GptTypeEsp = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    )

    if (-not $PSCmdlet.ShouldProcess($OSDriveLetter, 'Set-Bootloader')) { return }
    Write-Step 'Configuring bootloader...'

    $osDrive = "${OSDriveLetter}:"

    $stepName = ''
    try {
        if ($FirmwareType -eq 'UEFI') {
            # Find the EFI system partition
            $stepName = 'Find EFI System Partition'
            $espDrive = (Get-Partition -DiskNumber $DiskNumber |
                Where-Object { $_.GptType -eq $GptTypeEsp } |
                Get-Volume |
                Select-Object -First 1).DriveLetter

            if (-not $espDrive) {
                # Assign a temporary drive letter to ESP
                $stepName = 'Assign ESP drive letter'
                $esp = Get-Partition -DiskNumber $DiskNumber |
                    Where-Object { $_.GptType -eq $GptTypeEsp } |
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

function Find-CachedImage {
    <#
    .SYNOPSIS  Searches local and USB drives for a pre-cached Windows image file.
    .DESCRIPTION
        Scans removable and fixed drives (excluding the X: RAM drive and the
        target OS drive) for WIM or ESD files that match the requested edition.
        Looks in well-known cache directories: Nova\Images, Images, Sources.

        When a match is found the function returns the full path so the engine
        can skip the multi-GB download entirely.
    .PARAMETER Edition
        Windows edition to match (e.g. 'Professional', 'Enterprise').
    .PARAMETER Language
        Language code (e.g. 'en-us'). Used for filename matching hints only.
    .PARAMETER Architecture
        CPU architecture (e.g. 'x64'). Used for filename matching hints only.
    .PARAMETER ExcludeDrives
        Drive letters to exclude from the search (e.g. 'X', 'C').
    .OUTPUTS
        System.String  Full path to the cached image, or $null if not found.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [string]$Edition = 'Professional',
        [string]$Language = 'en-us',
        [string]$Architecture = 'x64',
        [string[]]$ExcludeDrives = @('X')
    )

    $null = $Language, $Architecture   # reserved for future filename-hint matching
    Write-Step "Searching for cached Windows image on local drives..."

    # Well-known subdirectories where pre-cached images are placed
    $searchDirs = @('Nova\Images', 'Nova', 'Images', 'Sources', '')

    # Build edition keywords for matching WIM ImageName
    $editionMap = Get-EditionNameMap
    $editionKeyword = if ($editionMap.ContainsKey($Edition)) { $editionMap[$Edition] } else { $Edition }

    # Get all available drive letters
    $drives = @()
    try {
        $volumes = Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter -and $_.DriveType -in @('Removable', 'Fixed') }
        foreach ($v in $volumes) {
            $letter = "$($v.DriveLetter)"
            if ($letter -and $letter -notin $ExcludeDrives) {
                $drives += $letter
            }
        }
    } catch {
        Write-Detail "Get-Volume unavailable -- falling back to filesystem scan"
        # Fallback for minimal WinPE without Storage module
        foreach ($letter in 'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','Y','Z') {
            if ($letter -notin $ExcludeDrives -and (Test-Path "${letter}:\")) {
                $drives += $letter
            }
        }
    }

    Write-Detail "Searching drives: $($drives -join ', ')"

    foreach ($drive in $drives) {
        foreach ($subDir in $searchDirs) {
            $searchPath = if ($subDir) { Join-Path "${drive}:" $subDir } else { "${drive}:" }
            if (-not (Test-Path $searchPath)) { continue }

            # Look for .wim and .esd files
            $candidates = @()
            try {
                $candidates = Get-ChildItem -Path $searchPath -Include '*.wim','*.esd' -File -ErrorAction SilentlyContinue
            } catch { continue }

            foreach ($file in $candidates) {
                Write-Detail "Checking cached image: $($file.FullName)"
                try {
                    # Verify the image contains the requested edition
                    $images = Get-WindowsImage -ImagePath $file.FullName -ErrorAction Stop
                    foreach ($img in $images) {
                        $imgName = $img.ImageName
                        if ($imgName -like "*$editionKeyword*" -or $imgName -like "*$Edition*") {
                            Write-Success "Found cached image: $($file.FullName) (edition: $imgName)"
                            return $file.FullName
                        }
                    }
                } catch {
                    Write-Detail "Could not inspect image '$($file.FullName)': $_"
                }
            }
        }
    }

    Write-Detail "No cached image found matching edition '$Edition'"
    return $null
}

# ── Module Export ────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Find-WindowsESD'
    'Get-WindowsImageSource'
    'Install-WindowsImage'
    'Set-Bootloader'
    'Get-EditionNameMap'
    'Find-CachedImage'
)

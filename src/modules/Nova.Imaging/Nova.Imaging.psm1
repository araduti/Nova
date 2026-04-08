<#
.SYNOPSIS
    Windows image download, application, and bootloader configuration for Nova.

.DESCRIPTION
    Provides functions for finding Windows ESD images in catalog XML, downloading
    Windows images (ESD or direct URL), applying images via DISM, and configuring
    the BCD bootloader for UEFI and BIOS systems.

    Extracted from Nova.ps1 to promote module-based architecture and testability.
#>

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
        $productsUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/products.xml"
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

# ── Module Export ────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Find-WindowsESD'
    'Get-WindowsImageSource'
    'Install-WindowsImage'
    'Set-Bootloader'
    'Get-EditionNameMap'
)

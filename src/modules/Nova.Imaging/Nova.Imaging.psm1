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

# ── Module Export ────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Find-WindowsESD'
    'Get-WindowsImageSource'
    'Install-WindowsImage'
    'Set-Bootloader'
    'Get-EditionNameMap'
)

# SIG # Begin signature block
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA2uHHhBGrF8PVq
# HyxITsaBNpmBZK/G7StKMm7CzLZJ26CCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAAwgfoS
# b3IaqFdWAAAAADCBMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNDExMTQzMjIxWhcNMjYwNDE0
# MTQzMjIxWjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCoDvl5pEdix75g
# sPPP+LUYM/FBro5KiOX3l29XEgZXd4FUxoXWN55ZcAMiBx6bE0shm5Jq3bsul1fk
# tKEi/S27MfMQLxJUBeT+pKylG3U2/l+H5mMemL0ZVkAdPVzg3tV1NSLQcD9nXjw/
# zK9DNhudjT65sbOXpQuzT8F9OSThrV7kTvjQTaj3BwZZpOG0N928hf7OYZF8ocpH
# RyxuNvWclGvz6P2VUHiSaWwLVWzUVKIjU0SDRWkz/kxNr153BgvKllzxP1xoM6T+
# IaWb6ilnJxZSIHdmcg3J0p+mOuBhMd41lltIW3J2tkwtCHoGHINrEsRWB1jXIPnK
# SYSJZktjjS/ZqoNiFFK98061Dk41IOFLqjcrXEI/TvCS7bwEVlAeuD22nYt+Mb/I
# XgSBZTHdwBqgZFtSFzmmXGrr/X2G9u1a2vpTV0IfB+V6DJyPpUFLmDZVA03vMghy
# lUTtgctxlGCP0moiFYHi8o1+jTdHsF2LsVbeje33CPRzGeAi0ocCAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUNfBORqLrmpv8ylfJ2reFGJPf7/gwHwYDVR0jBBgwFoAUmvFUd3UM
# hxY3RqCs3nn59H/BeOkwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwNC5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAFVIWKBhKT/vFueS1yhEdqApKn45HQp8InKXH1FtUG9UsG6DO5dQ+Ino
# W1t62LJMaWBSRFX3ME8uPK5rwrwiTQAU13zuz4kFs8D3a+dced9BPwIH8Dpadk7n
# R0lPpLLNPyr5XIMoBsbR7fZieDW3ttR5Yu/P+j9OaLhCB/11XsfLBM1hJwd6iGwG
# BkMRp16UKvdlFZrWToXVA04YA0veSKfRqpzCrJbqh84O20k8BworWczTuzfvsZ3Y
# SLcsozQ+QKI/atrB0gauZd9KbJMePNl8xsO/ilGXXN23xwE49c/0LH6ltda6uecb
# UnEqIFcwhHcznY7vLQ0socXed52Byv44oa1VtkBvffSAPxLUy8TyzxVDNwp5orws
# roko13DWmq1TCOBW6wqoiimpYiUJ2DXNOf6e4hyrLjKWrxKen1vG8Dx9M7o94yLM
# PNoE4apZ4ZqIaueqbV8kRPMW3H38lNqCEW5Jw+odLiuoudDSGckonMIRWezawMxY
# QqHjf1XWpmHH0onyNetWPeWLJmt1JySBp2E2jLDXJwFcOYPCaUx3t3fVsHETEFNr
# 4fi3pPOcMhpPMaBdczm09LHOHAn01gJJYrmyaYNsbCyCFBwuGeToqT6b1HjR/Q23
# wdAbn77KM3LF25nTjWt+9zsJgv4U2hXHEe3/AXkmc2W47Vbs5KQiMIIGyTCCBLGg
# AwIBAgITMwAAMIH6Em9yGqhXVgAAAAAwgTANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDA0MB4XDTI2MDQxMTE0
# MzIyMVoXDTI2MDQxNDE0MzIyMVowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAqA75eaRHYse+YLDzz/i1GDPxQa6OSojl95dvVxIGV3eBVMaF1jeeWXADIgce
# mxNLIZuSat27LpdX5LShIv0tuzHzEC8SVAXk/qSspRt1Nv5fh+ZjHpi9GVZAHT1c
# 4N7VdTUi0HA/Z148P8yvQzYbnY0+ubGzl6ULs0/BfTkk4a1e5E740E2o9wcGWaTh
# tDfdvIX+zmGRfKHKR0csbjb1nJRr8+j9lVB4kmlsC1Vs1FSiI1NEg0VpM/5MTa9e
# dwYLypZc8T9caDOk/iGlm+opZycWUiB3ZnINydKfpjrgYTHeNZZbSFtydrZMLQh6
# BhyDaxLEVgdY1yD5ykmEiWZLY40v2aqDYhRSvfNOtQ5ONSDhS6o3K1xCP07wku28
# BFZQHrg9tp2LfjG/yF4EgWUx3cAaoGRbUhc5plxq6/19hvbtWtr6U1dCHwflegyc
# j6VBS5g2VQNN7zIIcpVE7YHLcZRgj9JqIhWB4vKNfo03R7Bdi7FW3o3t9wj0cxng
# ItKHAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFDXwTkai65qb/MpXydq3hRiT3+/4MB8GA1Ud
# IwQYMBaAFJrxVHd1DIcWN0agrN55+fR/wXjpMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDA0LmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBVSFigYSk/7xbnktcoRHagKSp+OR0KfCJylx9R
# bVBvVLBugzuXUPiJ6FtbetiyTGlgUkRV9zBPLjyua8K8Ik0AFNd87s+JBbPA92vn
# XHnfQT8CB/A6WnZO50dJT6SyzT8q+VyDKAbG0e32Yng1t7bUeWLvz/o/Tmi4Qgf9
# dV7HywTNYScHeohsBgZDEadelCr3ZRWa1k6F1QNOGANL3kin0aqcwqyW6ofODttJ
# PAcKK1nM07s377Gd2Ei3LKM0PkCiP2rawdIGrmXfSmyTHjzZfMbDv4pRl1zdt8cB
# OPXP9Cx+pbXWurnnG1JxKiBXMIR3M52O7y0NLKHF3nedgcr+OKGtVbZAb330gD8S
# 1MvE8s8VQzcKeaK8LK6JKNdw1pqtUwjgVusKqIopqWIlCdg1zTn+nuIcqy4ylq8S
# np9bxvA8fTO6PeMizDzaBOGqWeGaiGrnqm1fJETzFtx9/JTaghFuScPqHS4rqLnQ
# 0hnJKJzCEVns2sDMWEKh439V1qZhx9KJ8jXrVj3liyZrdSckgadhNoyw1ycBXDmD
# wmlMd7d31bBxExBTa+H4t6TznDIaTzGgXXM5tPSxzhwJ9NYCSWK5smmDbGwsghQc
# Lhnk6Kk+m9R40f0Nt8HQG5++yjNyxduZ041rfvc7CYL+FNoVxxHt/wF5JnNluO1W
# 7OSkIjCCBygwggUQoAMCAQICEzMAAAAXJ0UJC4uHr8YAAAAAABcwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMzFaFw0zMTAzMjYxODExMzFaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCCx2T+Aw9mKgGVzJ+Tq0PMn49G3itIsYpb
# x7ClLSRHFe1RELdPcZ1sIqWOhsSfy6yyqEapClGH9Je9FXA1cQgZvvpQbkg+QInV
# Lr/0EPrVBCwrM96lbRI2PxNeCwXG9LsyW2hG6KQgintDmNCBo4zpDIr377plVdSl
# iZm6UB7rHwmvBnR02QT6tnrqWq2ihzB6lRJVTEzuh0OafzIMeMnYM0+x+ve5EOLH
# dfiq+HXiMf9Jb7YLHtYgyHIiJA7bTWLqFSLGaTh7ZlbxbsLXA91OOroEpv7OjzFu
# u3tkpC9FflA4Dp2Euq4+qPmxUqfGp+TX0gLRJp9NJOzzILjcTD3rkFFFbxUv1xyg
# 6avivFDLtoKBhM2Td138umE1pNOacanuSYtPHIeQHmB6haFi64avLBLwTTAm/Rbi
# t860cFXR72wq+5Qh4hSmezHqKXERWPpVBe+APrJ4Iqc+aPeMmIkoCWZQO22HnLNF
# UFSXjiwyIbgvlH/LIAJEqTafTzxDZgKhlLU7zr6gwsq3WNpcYQI6NuxWnwh3VVDD
# yF7onQqKs5Ll7bleVN0Y8VvqgE45ppyBbvwqN/Run5fMCCRz3aYMY0kZhKO92eP7
# t4zHqZ5bQMAgZ0tE2Pz/jb0wiykUF/PcoOqqk3vVLiRDYst6vd3GEMNzMpUUvQcv
# BG46+COIbwIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBSa8VR3dQyHFjdGoKzeefn0f8F46TBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQCQdVoZ/U0m38l2iKaZFlsx
# avptpoOLyaR1a9ZK2TSF1kOnFJhMDse6KkCgsveoiEjXTVc6Xt86IKHn76Nk5qZB
# 0BXv2iMRQ2giAJmYvZcmstoZqfB2M3Kd5wnJhUJOtF/b6HsqSelY6nhrF06zor1l
# DmDQixBZcLB9zR1+RKQso1jekNxYuUk+HaN3k1S57qk0O//YbkwU0mELCW04N5vI
# CMZx5T5c7Nq/7uLvbVhCdD7f2bZpA4U7vOkB1ooB4AaER3pjoJ0Mad5LFyi6Na9p
# 9Zu/hrLeOjU5FItS5YxsqvlfXxAThJ176CmkYstKRmytSHZ7JhKRfV6e9Zftk/OD
# b/CK4pGVAVqsOf4337bQGrOHHCQ3IvN9gmnUuDh8JdvbheoWPHxIN1GB5sUiY584
# tXN7xdD8LCSsRqJvQ8e7a3gZWTgViugRs1QWq+N0G9Nje6JHlN1CjJehge+H5PGk
# tJja+juGEr0P+ukSkcL6qaZxFQTh3SDI71lvW++3bl/Ezd6SO8N9Udw+reoyvRHC
# yTiSsplZQSBTVJdPmo3qCpGuyHFtPo5CBn3/FPTiqJd3M9BHoqKd0G9Kmg6fGcAv
# FwnLNXA2kov727wRljL3ypfqL7iAT/Ynpxul6RwHRlcOf9dDGg1RRvr92NP/CWVX
# Ib68geR2rvU/NsfmtjF1wDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
# AAcwDQYJKoZIhvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZl
# cmlmaWNhdGlvbiBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIx
# MDQwMTIwMDUyMFoXDTM2MDQwMTIwMTUyMFowYzELMAkGA1UEBhMCVVMxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElE
# IFZlcmlmaWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALLwwK8ZiCji3VR6TElsaQhVCbRS/3pK+MHrJSj3Zxd3
# KU3rlfL3qrZilYKJNqztA9OQacr1AwoNcHbKBLbsQAhBnIB34zxf52bDpIO3NJlf
# IaTE/xrweLoQ71lzCHkD7A4As1Bs076Iu+mA6cQzsYYH/Cbl1icwQ6C65rU4V9NQ
# hNUwgrx9rGQ//h890Q8JdjLLw0nV+ayQ2Fbkd242o9kH82RZsH3HEyqjAB5a8+Ae
# 2nPIPc8sZU6ZE7iRrRZywRmrKDp5+TcmJX9MRff241UaOBs4NmHOyke8oU1TYrkx
# h+YeHgfWo5tTgkoSMoayqoDpHOLJs+qG8Tvh8SnifW2Jj3+ii11TS8/FGngEaNAW
# rbyfNrC69oKpRQXY9bGH6jn9NEJv9weFxhTwyvx9OJLXmRGbAUXN1U9nf4lXezky
# 6Uh/cgjkVd6CGUAf0K+Jw+GE/5VpIVbcNr9rNE50Sbmy/4RTCEGvOq3GhjITbCa4
# crCzTTHgYYjHs1NbOc6brH+eKpWLtr+bGecy9CrwQyx7S/BfYJ+ozst7+yZtG2wR
# 461uckFu0t+gCwLdN0A6cFtSRtR8bvxVFyWwTtgMMFRuBa3vmUOTnfKLsLefRaQc
# VTgRnzeLzdpt32cdYKp+dhr2ogc+qM6K4CBI5/j4VFyC4QFeUP2YAidLtvpXRRo3
# AgMBAAGjggI1MIICMTAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAw
# HQYDVR0OBBYEFNlBKbAPD2Ns72nX9c0pnqRIajDmMFQGA1UdIARNMEswSQYEVR0g
# ADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L0RvY3MvUmVwb3NpdG9yeS5odG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2io
# ojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBS
# b290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBwwYIKwYB
# BQUHAQEEgbYwgbMwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0
# aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQw
# LQYIKwYBBQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20vb2NzcDAN
# BgkqhkiG9w0BAQwFAAOCAgEAfyUqnv7Uq+rdZgrbVyNMul5skONbhls5fccPlmIb
# zi+OwVdPQ4H55v7VOInnmezQEeW4LqK0wja+fBznANbXLB0KrdMCbHQpbLvG6UA/
# Xv2pfpVIE1CRFfNF4XKO8XYEa3oW8oVH+KZHgIQRIwAbyFKQ9iyj4aOWeAzwk+f9
# E5StNp5T8FG7/VEURIVWArbAzPt9ThVN3w1fAZkF7+YU9kbq1bCR2YD+MtunSQ1R
# ft6XG7b4e0ejRA7mB2IoX5hNh3UEauY0byxNRG+fT2MCEhQl9g2i2fs6VOG19CNe
# p7SquKaBjhWmirYyANb0RJSLWjinMLXNOAga10n8i9jqeprzSMU5ODmrMCJE12xS
# /NWShg/tuLjAsKP6SzYZ+1Ry358ZTFcx0FS/mx2vSoU8s8HRvy+rnXqyUJ9HBqS0
# DErVLjQwK8VtsBdekBmdTbQVoCgPCqr+PDPB3xajYnzevs7eidBsM71PINK2BoE2
# UfMwxCCX3mccFgx6UsQeRSdVVVNSyALQe6PT12418xon2iDGE81OGCreLzDcMAZn
# rUAx4XQLUz6ZTl65yPUiOh3k7Yww94lDf+8oG2oZmDh5O1Qe38E+M3vhKwmzIeoB
# 1dVLlz4i3IpaDcR+iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFI
# rmcxghqRMIIajQIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDQCEzMAADCB+hJvchqoV1YAAAAAMIEwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgJwuRIM9taZ51BMi3Np22SCQnXUVQ88aWS50iJwYJR4kw
# DQYJKoZIhvcNAQEBBQAEggGAD2hP/id4i7jdl6JjnHSQyi5q8Ur6RD4RkOGEslVO
# yXbk/nHD2QDcIvioPZBZbqgE10WmzOMHBt0mJL/Lzgpl0+twIiD0hu9YvBOz93ga
# Vj0S1gPGt87Q5vrwkMgNhDing0Z0gph8uGNhOl7knoSnVUDmehK2JFLi4mf9fJwl
# oJINWckrtu27QWzbUcASw0nJ9aS5F6mQ6MWKzBf0HRZd0lKg+5Stthi2TBtojMCb
# RLjFY+pLr26iAORO3hyw47K9lomLoZIsHVPg/t38P5NWxmPgMRn2WPb1Tj37/7zM
# K7J03TtOOmF2HmP4BgE3QCSjWcO7mrzcK4s/4c3bgxTITrkzfxFP7+3MVdRgTZSt
# j/tA6HBqxRUjRZQhXb9ChVTHz4RWHYCtpE8OLMWqHCpK1XD8Zyxy6FRIWZNlxBhg
# 5HcB/+reGhx8ZjH+pgnONK+nFuAcMzZ+s47HxhogllDZVnvqBoZEAmq4vzHhVcjI
# wtMo9xcbJB1uz6/yf2+sz7lHoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIM0wAMA4wTlNFDnaufZagNJoYRT15JguK6RidFUDNub8AgZpwmaoWsQYEzIw
# MjYwNDExMTc0MDM0LjU0MlowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAt
# RDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGlu
# ZyBBdXRob3JpdHmggg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAA
# BTANBgkqhkiG9w0BAQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVy
# aWZpY2F0aW9uIFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAx
# MTE5MjAzMjMxWhcNMzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBv
# f7KrQ5cMSqFSHGqg2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDs
# fMuIEqvGYOPURAH+Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbB
# T7uq3wx3mXhtVmtcCEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5
# EeH5KrlFnxpjKKTavwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6
# ovnUfANjIgM9JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fj
# JHrmlQ0EIXmp4DhDBieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOs
# RpeexIveR1MPTVf7gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiun
# hKbq0XbjkNoU5JhtYUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE
# 3oWsDqMX3jjv40e8KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8
# cIxLoKSDzCCBOu0hWdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMB
# AAGjggIbMIICFzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYD
# VR0OBBYEFGtpKDo1L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBB
# MD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0Rv
# Y3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGC
# NxQCBAweCgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTI
# ftJqhSobyhmYBAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHkl
# MjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHkl
# MjAyMDIwLmNybDCBlAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElk
# ZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0
# aG9yaXR5JTIwMjAyMC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXn
# THho+k7h2ESZJRWluLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC
# 2IWmtKMyS1OWIviwpnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5
# zyEh89F72u9UIw+IfvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbN
# nCKNZPmhzoa8PccOiQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqs
# t8S+w+RUdie8fXC1jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVm
# oNR/dSpRCxlot0i79dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRS
# SvijmwJwxRxLLpMQ/u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7v
# PKNMN+SZDWycU5ODIRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/2
# 6ozePQ/TWfNXKBOmkFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/
# AAxw9Sdgq/+rY7jjgs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSO
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFZ+j51YCI7p
# YAAAAAAAVjANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTFaFw0yNjEw
# MjIyMDQ2NTFaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtKWfm/ul027/d8Rlb8Mn/g0QUvvLqY2V
# sy3tI8U2tFSspTZomZOD3BHT8LkR+RrhMJgb1VjAKFNysaK9cLSXifPGSIBrPCgs
# 9P4y24lrJEmrV6Q5z4BmqMhIPrZhEvZnWpCS4HO7jYSei/nxmC7/1Er+l5Lg3PmS
# xb8d2IVcARxSw1B4mxB6XI0nkel9wa1dYb2wfGpofraFmxZOxT9eNht4LH0RBSVu
# eba6ZNpjS/0gtfm7qiIiyP6p6PRzTTbMnVqsHnV/d/rW0zHx+Q+QNZ5wUqKmTZJB
# 9hU853+2pX5rDfK32uNY9/WBOAmzbqgpEdQkbiMavUMyUDShmycIvgHdQnS207sT
# j8M+kJL3tOdahPuPqMwsaCCgdfwwQx0O9TKe7FSvbAEYs1AnldCl/KHGZCOVvUNq
# jyL10JLe0/+GD9/ynqXGWFpXOjaunvZ/cKROhjN4M5e6xx0b2miqcPii4/ii2Zhe
# KallJET7CKlpFShs3wyg6F/fojQxQvPnbWD4Nyx6lhjWjwmoLcx6w1FSCtavLCly
# 33BLRSlTU4qKUxaa8d7YN7Eqpn9XO0SY0umOvKFXrWH7rxl+9iaicitdnTTksAnR
# jvekdKT3lg7lRMfmfZU8vXNiN0UYJzT9EjqjRm0uN/h0oXxPhNfPYqeFbyPXGGxz
# aYUz6zx3qTcCAwEAAaOCAcswggHHMB0GA1UdDgQWBBS+tjPyu6tZ/h5GsyLvyz1H
# +FNIWjAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAA4DqAXEsO26j/La7Fgn/Qifit8xuZekqZ57+Ye+sH/h
# RTbEEjGYrZgsqwR/lUUfKCFpbZF8msaZPQJOR4YYUEU8XyjLrn8Y1jCSmoxh9l7t
# WiSoc/JFBw356JAmzGGxeBA2EWSxRuTr1AuZe6nYaN8/wtFkiHcs8gMadxXBs6Dx
# Vhyu5YnhLPQkfumKm3lFftwE7pieV7f1lskmlgsC6AeSGCzGPZUgCvcH5Tv/Qe9z
# 7bIImSD3SuzhOIwaP+eKQTYf67TifyJKkWQSdGfTA6Kcu41k8LB6oPK+MLk1jbxx
# K5wPqLSL62xjK04SBXHEJSEnsFt0zxWkxP/lgej1DxqUnmrYEdkxvzKSHIAqFWSZ
# ul/5hI+vJxvFPhsNQBEk4cSulDkJQpcdVi/gmf/mHFOYhDBjsa15s4L+2sBil3XV
# /T8RiR66Q8xYvTLRWxd2dVsrOoCwnsU4WIeiC0JinCv1WLHEh7Qyzr9RSr4kKJLW
# dpNYLhgjkojTmEkAjFO774t3xB7enbvIF0GOsV19xnCUzq9EGKyt0gMuaphKlNjJ
# +aTpjWMZDGo+GOKsnp93Hmftml0Syp3F9+M3y+y6WJGUZoIZJq227jDjjEndtpUr
# h9BdPdVIfVJD/Au81Rzh05UHAivorQ3Os8PELHIgiOd9TWzbdgmGzcILt/ddVQER
# MYIHQzCCBz8CAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjANBglghkgBZQME
# AgEFAKCCBJwwEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDExMTc0MDM0WjAvBgkqhkiG9w0B
# CQQxIgQgODNw7C8ZX2v7kvlaZMzxWF0qRsPAcpcbrQAwYnHj1aEwgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCC2DDMlTaTj8JV3iTg5Xnpe4CSH60143Z+X9o5N
# BgMMqDB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjCCA14GCyqGSIb3DQEJ
# EAISMYIDTTCCA0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD/c/cpFSqQWYBeXggy
# RJ2ZbvYEEaBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2En+8wIhgPMjAyNjA0
# MTExMDI0NDdaGA8yMDI2MDQxMjEwMjQ0N1owdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7YSf7wIBADAHAgEAAgIhFjAHAgEAAgISPjAKAgUA7YXxbwIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCPmIXtkEOg1sRrGqshYtqABLq4W3m1hT4nA7T7
# fI/XxO/W1SeLdZaYr0+ohwLLYYFz2DpysTxeJiZlBREVbBXaNKZmQy2f0/kY7Pcb
# SCrsl1Y7sFCSfZNarpfX7eHf1bbIby+15kuNiXUI0+ulMUtCExl976ZLqCJQHELw
# Sv01I1Qkya19AZV0JwbdIvlzr3zspRTTepKbWbTPjyNr0waZ5vuhB2Rf6R2Dg/Dz
# 3yJ/gwRl6+JpkCyHE4QFhbYTYfULK1DPdJWaVs6yBSHVPKqNxn8LA3w9HcP/GRka
# FwhFw2j0A/hp237kziP8LheDBXEiI3tlluyks1SZ6iklwYulMA0GCSqGSIb3DQEB
# AQUABIICAJgT8jzwDEMHkUuMvaogovV/A48ThyyqYh86povcGbEeQWMDOCfS+evZ
# G7G8ds77sn3pnjQqHm135VRmMAp3tPFK8FBFDaGMufnCStAGHWAEMSxcP81ZDJg0
# LzS4tPoJ9Jwup7uxpch431DVDm3tNNgP+ATwFIylvCr6U7cb4O6LfCQz9QqDF9Ua
# +7Kkebk6IjhOEMKRYwzEddwhSpcMW6osSm67CZ69XlL75kV1C+cGSgsQwDE/0IcJ
# XgNU6fol2ajTW95vXS0LzGizBnMJHZwW6PzeIMrgx3z4GkdgnM2bPRYebnJb1BGZ
# hC/fM9K/gwSNCV9TpNl5cptW6wmKgReNT1lq0hnvWJgzRikhGnxpyh8Z3BDHMv0w
# joGWITDT0UYGLjcUpdy6UxTfc3+ARpDfoavs3b8+u1DFbyXaUODrxHpGFlMPXmRT
# eZRboZgdYkux8SlqNllzbOR5F4tYF5v75s5wy22uIOhqrRzq+QL9o1Tgy9o0ijC6
# cCfpn5TbOQJPA5HiToIrFpPz9CesjW/WWtzjCmHME7O0dr5EMUCsjmdteJwWBboF
# Bm5zyOuu4GDoeiyvcshNYRksCzmFqT9sHfh8hsuOU/iItZejBAYlF3BBnpc+iuHi
# P+Ot5GsExpQ8+l1jdSqB1JNEBncreu8pVRd4r9KRm+yn2MJXMe9B
# SIG # End signature block

<#
.SYNOPSIS
    WinRE discovery, extraction, and preparation module for Nova.

.DESCRIPTION
    Provides functions to locate, download, and prepare Windows Recovery
    Environment (WinRE) images for use as WinPE boot media.  WinRE is
    preferred over plain WinPE because it ships with WiFi hardware drivers
    (Intel, Realtek, MediaTek, Qualcomm) bundled via Windows Update.
#>

Set-StrictMode -Version Latest

function Get-WinREPath {
    <#
    .SYNOPSIS  Locates a usable winre.wim on the current machine.
    .DESCRIPTION
        WinRE (Windows Recovery Environment) is built on WinPE but ships with
        real WiFi hardware drivers (Intel, Realtek, MediaTek, Qualcomm) that
        Microsoft delivers via Windows Update. Using WinRE as the boot image
        therefore enables wireless connectivity on most laptops without manually
        injecting model-specific drivers.

        Search order:
          1. %SystemRoot%\System32\Recovery\WinRE.wim  (present when WinRE is
             disabled or the machine has not moved it to a recovery partition).
          2. Active recovery partition reported by reagentc.exe, temporarily
             assigned a drive letter so the WIM can be copied out.

    .OUTPUTS  [string] Path to an accessible winre.wim, or $null when not found.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()

    # ── 1. Quick check in System32\Recovery ─────────────────────────────────
    $sysPath = Join-Path $env:SystemRoot 'System32\Recovery\WinRE.wim'
    if (Test-Path $sysPath) {
        Write-Success "WinRE.wim found: $sysPath"
        return $sysPath
    }

    # ── 2. Query reagentc for the active WinRE location ─────────────────────
    Write-Step 'Querying reagentc for WinRE location...'
    $info = & reagentc.exe /info 2>&1
    $locLine = ($info | Where-Object { $_ -match 'Windows RE location' }) -as [string]

    if ($locLine -notmatch 'harddisk(\d+)\\partition(\d+)\\(.+)') {
        Write-Warn 'reagentc did not report a usable WinRE location.'
        return $null
    }

    $diskNum = [int]$Matches[1]
    $partNum = [int]$Matches[2]
    $relPath = $Matches[3].Trim()

    $part = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum `
                          -ErrorAction SilentlyContinue
    if (-not $part) {
        Write-Warn "Could not access recovery partition (disk=$diskNum, part=$partNum)."
        return $null
    }

    # If the partition already has a drive letter, try it directly
    if ($part.DriveLetter -match '[A-Za-z]') {
        $candidate = "$($part.DriveLetter):\$relPath\WinRE.wim"
        if (Test-Path $candidate) {
            Write-Success "WinRE.wim found: $candidate"
            return $candidate
        }
    }

    # Otherwise assign a temporary drive letter, copy the WIM, then release
    $freeLetter = $null
    foreach ($code in 68..90) {
        $letter = [char]$code
        if (-not (Test-Path "${letter}:\")) {
            $freeLetter = $letter
            break
        }
    }
    if (-not $freeLetter) {
        Write-Warn 'No free drive letter available to mount recovery partition.'
        return $null
    }

    $mountPoint = "${freeLetter}:\"
    $tempWim    = Join-Path $env:TEMP "nova_winre_$([guid]::NewGuid().Guid).wim"
    $found      = $false
    try {
        $part | Add-PartitionAccessPath -AccessPath $mountPoint -ErrorAction Stop
        $candidate = "${freeLetter}:\$relPath\WinRE.wim"
        if (Test-Path $candidate) {
            Write-Step 'Copying WinRE.wim from recovery partition...'
            Copy-Item $candidate $tempWim -Force
            $found = $true
        } else {
            Write-Warn "WinRE.wim not found at expected path: $candidate"
        }
    } catch {
        Write-Warn "Could not mount recovery partition: $_"
    } finally {
        $part | Remove-PartitionAccessPath -AccessPath $mountPoint `
                                           -ErrorAction SilentlyContinue
    }

    if ($found) {
        Write-Success "WinRE.wim copied to temp: $tempWim"
        return $tempWim
    }
    return $null
}

function Get-WinREPathFromWindowsISO {
    <#
    .SYNOPSIS
        Downloads (when needed) a Windows ISO and extracts WinRE.wim from it.
    .DESCRIPTION
        When the machine's local WinRE.wim cannot be used -- because its CPU
        architecture differs from the build target, or because its Windows build
        number is incompatible with the installed ADK package set -- this function
        obtains a fresh WinRE that is guaranteed to be the correct architecture.

        Source selection order:
          1. $ISOUrl is a local file path → used directly (no download).
          2. $ISOUrl is an HTTPS URL → downloaded to a temp file, deleted afterwards.
          3. $ISOUrl is empty → a built-in default URL is tried for known
             architectures.  For amd64 the Windows Server 2025 Evaluation ISO is
             used (same build 26100 as Windows 11 24H2; free, no authentication).
             For other architectures the caller must supply $ISOUrl explicitly.

        The ISO is mounted with Mount-DiskImage, sources\install.wim (or
        install.esd) is mounted read-only at a temp path, WinRE.wim is copied
        out, then everything is dismounted and cleaned up in a finally block.

    .PARAMETER Architecture
        Target WinPE architecture string: amd64 or x86. ARM is not supported.
    .PARAMETER ISOUrl
        Path to a local Windows ISO file, or an HTTPS URL to download one.
        Optional -- a built-in default is tried for amd64 when omitted.
    .OUTPUTS  [string] Temp path to the extracted WinRE.wim.  The CALLER is
              responsible for deleting this file when it is no longer needed.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [string] $Architecture,
        [string] $ISOUrl = ''
    )

    # Suppress the default PowerShell progress bars from DISM cmdlets
    # (Mount-WindowsImage, Dismount-WindowsImage, Get-WindowsImage) so the
    # console stays clean.  The custom Write-Step / Write-Success messages
    # provide all the user feedback needed.
    $ProgressPreference = 'SilentlyContinue'

    # ── Built-in default ISO download URLs ──────────────────────────────────────
    # Windows Server 2025 Evaluation (build 26100) is freely downloadable without
    # authentication and shares the same Windows build number as Windows 11 24H2,
    # making its WinRE compatible with the Windows 11 24H2 ADK package set.
    # No publicly available evaluation ISO exists for x86 -- users must
    # supply -WindowsISOUrl for that architecture.
    $defaultISOUrls = @{
        amd64 = 'https://go.microsoft.com/fwlink/?linkid=2271125'
    }

    $isoPath       = ''
    $isoDownloaded = $false
    $isoMounted    = $false
    $wimMountDir   = ''

    try {
        # ── Step 1: Obtain the ISO file ──────────────────────────────────────────
        if ($ISOUrl -and (Test-Path -LiteralPath $ISOUrl)) {
            $isoPath = $ISOUrl
            Write-Success "Using local Windows ISO: $isoPath"
        } else {
            if (-not $ISOUrl) {
                $ISOUrl = $defaultISOUrls[$Architecture]
                if (-not $ISOUrl) {
                    throw "No Windows ISO is available for architecture '$Architecture' by default. Provide -WindowsISOUrl pointing to a Windows ISO file or download URL (e.g. the Windows 11 $Architecture ISO from https://www.microsoft.com/software-download/windows11)."
                }
                Write-Step "Using built-in default ISO URL for $Architecture..."
            }

            $isoPath = Join-Path $env:TEMP `
                "nova_win_iso_${Architecture}_$([System.Guid]::NewGuid().ToString('N')).iso"
            Write-Step "Downloading Windows ISO for $Architecture -- this file is several GB and may take a while..."
            try {
                Invoke-WebRequest -Uri $ISOUrl -OutFile $isoPath -UseBasicParsing `
                                  -TimeoutSec 7200   # 2-hour ceiling for large ISOs
            } catch {
                throw "Failed to download Windows ISO from '$ISOUrl': $_`nTip: download the ISO manually and re-run with -WindowsISOUrl '<path-to-iso>'."
            }
            Write-Success 'Windows ISO downloaded.'
            $isoDownloaded = $true
        }

        # ── Step 2: Mount the ISO ────────────────────────────────────────────────
        Write-Step 'Mounting Windows ISO...'
        $null = Mount-DiskImage -ImagePath $isoPath
        $isoMounted     = $true
        $isoDriveLetter = (Get-DiskImage -ImagePath $isoPath |
                            Get-Partition | Get-Volume |
                            Select-Object -First 1 -ExpandProperty DriveLetter)
        if (-not $isoDriveLetter) {
            throw 'Could not determine the drive letter of the mounted ISO. The file may be corrupted or not a valid Windows ISO.'
        }
        $isoDrive = "${isoDriveLetter}:\"

        # ── Step 3: Locate the Windows installation image ─────────────────────────
        $installWim = Join-Path $isoDrive 'sources\install.wim'
        $installEsd = Join-Path $isoDrive 'sources\install.esd'
        $wimPath = if     (Test-Path $installWim) { $installWim }
                   elseif (Test-Path $installEsd) { $installEsd }
                   else {
                       throw "Could not find sources\install.wim or sources\install.esd on the mounted ISO at $isoDrive"
                   }

        # ── Step 4: Mount the installation image read-only (first index) ──────────
        $wimMountDir = Join-Path $env:TEMP `
            "nova_iso_wim_$([System.Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $wimMountDir -Force
        $imageIndex = (Get-WindowsImage -ImagePath $wimPath |
                        Select-Object -First 1 -ExpandProperty ImageIndex)
        if (-not $imageIndex) {
            throw "Could not read any image index from '$wimPath' -- the file may be corrupted."
        }
        Write-Step "Mounting $(Split-Path $wimPath -Leaf) (index $imageIndex -- read-only)..."
        $null = Mount-WindowsImage -ImagePath $wimPath -Index $imageIndex `
                           -Path $wimMountDir -ReadOnly
        Write-Success "$(Split-Path $wimPath -Leaf) mounted."

        # ── Step 5: Copy WinRE.wim out of the installation image ──────────────────
        $winreSrc = Join-Path $wimMountDir 'Windows\System32\Recovery\WinRE.wim'
        if (-not (Test-Path $winreSrc)) {
            throw "WinRE.wim not found inside the mounted Windows image at: $winreSrc"
        }
        $winreDest = Join-Path $env:TEMP `
            "nova_iso_winre_$([System.Guid]::NewGuid().ToString('N')).wim"
        Write-Step 'Copying WinRE.wim from Windows installation image...'
        Copy-Item $winreSrc $winreDest -Force
        Write-Success 'WinRE.wim extracted from Windows ISO.'
        return $winreDest

    } finally {
        # Clean up in reverse order; every step is always attempted.
        if ($wimMountDir -and (Test-Path $wimMountDir)) {
            $null = Dismount-WindowsImage -Path $wimMountDir -Discard `
                                  -ErrorAction SilentlyContinue
            Remove-Item $wimMountDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($isoMounted) {
            $null = Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        }
        if ($isoDownloaded -and $isoPath -and (Test-Path $isoPath)) {
            Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-WinRERecoveryPackage {
    <#
    .SYNOPSIS
        Removes WinRE-specific recovery tools from a mounted WinRE image to
        reduce the final WIM size.
    .DESCRIPTION
        WinRE ships with startup-repair, boot-recovery, and other tools that are
        useful for OS recovery but are not needed when the image is used purely as
        a cloud deployment environment. Removing them shrinks the image by roughly
        100--200 MB before the final compression step.

        Packages matching the following name prefixes are removed:
          - Microsoft-Windows-WinRE-RecoveryAgent   (startup repair agent)
          - Microsoft-Windows-WinRE-BootRecovery    (boot recovery tools)
          - Microsoft-Windows-RecoveryDrive          (recovery drive creator)

        WiFi, networking, and scripting packages are intentionally preserved.
        Each removal is attempted individually so that dependency errors on one
        package do not block removal of the others.
    .PARAMETER MountDir  Path to the mounted WIM image.
    #>
    [OutputType([void])]
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $MountDir)

    if (-not $PSCmdlet.ShouldProcess($MountDir, 'Remove-WinRERecoveryPackage')) { return }
    Write-Step 'Removing WinRE recovery packages to reduce image size...'

    $removePrefixes = @(
        'Microsoft-Windows-WinRE-RecoveryAgent',
        'Microsoft-Windows-WinRE-BootRecovery',
        'Microsoft-Windows-RecoveryDrive'
    )

    try {
        $installed = Get-WindowsPackage -Path $MountDir -ErrorAction Stop
    } catch {
        Write-Warn "Could not enumerate packages for slimming: $_"
        return
    }

    foreach ($pkg in $installed) {
        $name        = $pkg.PackageName
        $shouldRemove = $false
        foreach ($prefix in $removePrefixes) {
            if ($name -like "$prefix*") { $shouldRemove = $true; break }
        }
        if (-not $shouldRemove) { continue }

        Write-Step "Removing recovery package: $name"
        try {
            $null = Remove-WindowsPackage -Path $MountDir -PackageName $name `
                                  -NoRestart -ErrorAction Stop
            Write-Success "Removed: $name"
        } catch {
            Write-Warn "Could not remove $name (non-fatal): $_"
        }
    }
}

Export-ModuleMember -Function Get-WinREPath, Get-WinREPathFromWindowsISO, Remove-WinRERecoveryPackage

# SIG # Begin signature block
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCARMojFqJyTIWyj
# IF+UvI1I+4N5InwR+TxgmrT0zpSBKKCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAATbzZ1
# WlQRwN+WAAAAABNvMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNDA4MTQzNTAyWhcNMjYwNDEx
# MTQzNTAyWjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCaXp6ZOAqpSGDC
# lEJL0tP6AaWlljn7+Nyx7mo3psGnxvPkngIY/lD/QHTpKOndvoq4knt04gr0kkGp
# ClfAlaI1BNcS+k6W3jy/dtA6w/k456OkCkjjGLqFEHaNXKVqnzI92GP6gCmn9ov0
# +uni4oROr5At/kLAh0zyXqTNBNQ+qd1QzQ4Y+CgIXlKnGBbi0RVx21T4tDsZ8mCX
# yxvlRHdXFNtEkEmkkGxbOziPkvav6QLRnr7/tALqWOrY1WHX6T/SGbrh5OPQivvs
# w94+JUX/m2uzHV6j0qHdfe8BJyYQ3U3NAGNFSQoshMtbV721R3XEnaXBy2U1A6TH
# zixwtXxQ5zRPrU65hNPrSTzkiK+a2VOLlOGP7+es1Eq8lKFRUVvjNFW1YgWwGf3g
# P2Z+4B2uMdml126+rmdUvTyAmEBqYeLNIfGfnTa+qlD9Lno8rqTyLrcN3bv8st+7
# Au+V47C6PDqbTyb/TjZ6BsoXsJtmLZAruTlFpCINQa4bksFN3d8CAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUYsueSbGxd9TixyeW27ISjBdBHnEwHwYDVR0jBBgwFoAUa16lNMMF
# xWJKIVqOq3NgYtSsY4UwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMy5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAELukzNfojQy7MXCmtBzdvxdxKTEvjdX3Zvu+aX5sDNMsy/q8JYeQG8u
# hingdUYeqHjwOtgenn5kqnY7Kb2C7IltAr6dZGZ/l+SSZGrAD0plWX5rUfhhTLGe
# j95/4C5Jnku01cG2FXBQbMkGaY1xe/bfnK8wn931lajOBdsbfVkhmTEIdchxu6sz
# /0UVg3tlIRqiiJtQCE71iWJVNmW8IdVOXhzy0dFOmhUHVgNelCAPqdJChaQvKwTJ
# 97SYWRT33jKI0+ylRRmKmEO1a8cMPIkn6cImafpGD9pmsquet3PLuQNGDAU5FYrm
# o5sqBW/LXTspdjbfje9obnCXKgOY/JLIiGaUZYppeRTWWwwnAHcFm6v40/CGADij
# VZhC0XiGYdEuYjbM0V4btEtcOtDr18oMVLwV27rJwxCek6wfza0ojyVYk1B0HC1k
# R6UICd3Mhrok4n0OOVn9RArCK4QrJ3oGpuHLU0H80XQdeJP95K4HsVj3Ln8S5qOV
# 0u98nFEyhg39UKnJioibO4tHeLWAY+CEpI/qoTva8SBMPc292R92mEWd5ck3xFG+
# voVEjXUwh9YbxRIVg14i4DFQSABoDbNwwuZ//uAP7e1/NaYskP8jbAjcm8AEaUeh
# 1CHYMwwA3ylB0lRP/e/Awtw4mFMKOFr0B4yLykkGvtK1hFlbWMqIMIIGyTCCBLGg
# AwIBAgITMwAAE282dVpUEcDflgAAAAATbzANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMB4XDTI2MDQwODE0
# MzUwMloXDTI2MDQxMTE0MzUwMlowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAml6emTgKqUhgwpRCS9LT+gGlpZY5+/jcse5qN6bBp8bz5J4CGP5Q/0B06Sjp
# 3b6KuJJ7dOIK9JJBqQpXwJWiNQTXEvpOlt48v3bQOsP5OOejpApI4xi6hRB2jVyl
# ap8yPdhj+oApp/aL9Prp4uKETq+QLf5CwIdM8l6kzQTUPqndUM0OGPgoCF5SpxgW
# 4tEVcdtU+LQ7GfJgl8sb5UR3VxTbRJBJpJBsWzs4j5L2r+kC0Z6+/7QC6ljq2NVh
# 1+k/0hm64eTj0Ir77MPePiVF/5trsx1eo9Kh3X3vAScmEN1NzQBjRUkKLITLW1e9
# tUd1xJ2lwctlNQOkx84scLV8UOc0T61OuYTT60k85IivmtlTi5Thj+/nrNRKvJSh
# UVFb4zRVtWIFsBn94D9mfuAdrjHZpdduvq5nVL08gJhAamHizSHxn502vqpQ/S56
# PK6k8i63Dd27/LLfuwLvleOwujw6m08m/042egbKF7CbZi2QK7k5RaQiDUGuG5LB
# Td3fAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFGLLnkmxsXfU4scnltuyEowXQR5xMB8GA1Ud
# IwQYMBaAFGtepTTDBcViSiFajqtzYGLUrGOFMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDAzLmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBC7pMzX6I0MuzFwprQc3b8XcSkxL43V92b7vml
# +bAzTLMv6vCWHkBvLoYp4HVGHqh48DrYHp5+ZKp2Oym9guyJbQK+nWRmf5fkkmRq
# wA9KZVl+a1H4YUyxno/ef+AuSZ5LtNXBthVwUGzJBmmNcXv235yvMJ/d9ZWozgXb
# G31ZIZkxCHXIcburM/9FFYN7ZSEaooibUAhO9YliVTZlvCHVTl4c8tHRTpoVB1YD
# XpQgD6nSQoWkLysEyfe0mFkU994yiNPspUUZiphDtWvHDDyJJ+nCJmn6Rg/aZrKr
# nrdzy7kDRgwFORWK5qObKgVvy107KXY2343vaG5wlyoDmPySyIhmlGWKaXkU1lsM
# JwB3BZur+NPwhgA4o1WYQtF4hmHRLmI2zNFeG7RLXDrQ69fKDFS8Fdu6ycMQnpOs
# H82tKI8lWJNQdBwtZEelCAndzIa6JOJ9DjlZ/UQKwiuEKyd6Bqbhy1NB/NF0HXiT
# /eSuB7FY9y5/EuajldLvfJxRMoYN/VCpyYqImzuLR3i1gGPghKSP6qE72vEgTD3N
# vdkfdphFneXJN8RRvr6FRI11MIfWG8USFYNeIuAxUEgAaA2zcMLmf/7gD+3tfzWm
# LJD/I2wI3JvABGlHodQh2DMMAN8pQdJUT/3vwMLcOJhTCjha9AeMi8pJBr7StYRZ
# W1jKiDCCBygwggUQoAMCAQICEzMAAAAVBT5uGY6TKdkAAAAAABUwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMjhaFw0zMTAzMjYxODExMjhaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDg9Ms9AqovDnMePvMOe+KybhCd8+lokzYO
# RlS3kBVXseecbyGwBcsenlm5bLtMGPjiIFLzBQF+ghlVV/U29q5GcdeEEBCHTTGh
# L2koIrLc4UrliMRcbv9mOMtR/l7/xAmv0Fx4BJHn1dHt37fvrBqXmKjKfGf5DpyO
# /+hnV7TEreMtS19iO+bjZ/9Hnpg3PCk0e7YSbRTFkx97FZwRWpC4s3NepRfRXQh/
# WMAj7JmsYeVZohi4TF5yW2JMrJZqwHcyzJZYtD2Hlno5ZEJkdiZcEaxHOobmwO06
# Z1J9c23ps9PGIhGaq1sKLEAz9Doc5rLkYWGteDrscKhAp2kIc/oYlH9Ij6BkOqqg
# WINEkEtC8ZNG1Mak+h3o65aj0iQKmdxW7IZaHO5cuyoMi+KtYfXeIIg3sVIbS2EL
# 8kUtsDGdEqNqAq/isqTi1jXqLe6iKp1ni1SPdvPW9G03CTsYF68b/yuIQRwbdoBC
# XemMNJCS0dorCRY4b2WAAy4ng7SANcEgrBgZf535+QfLU5hGzrKjIpbMabauWb5F
# KWUKkMsPcXFkXRWO4noKPm4KWlFypqOpbJ/KONVReIlxHQRegAOBzIhRB7gr9IDQ
# 1sc2MgOgQ+xVGW4oq4HD0mfAiwiyLskZrkaQ7JoanYjBNcR9RS26YxAVbcBtLitF
# TzCIEg5ZdQIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBRrXqU0wwXFYkohWo6rc2Bi1KxjhTBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBdbiI8zwXLX8glJEh/8Q22
# UMCUhWBO46Z9FPhwOR3mdlqRVLkYOon/MczUwrjDhx3X99SPH5PSflkGoTvnO9ZW
# HM5YFVYpO7NYuB+mfVSGAGZwiGOASWk0i2B7vn9nElJJmoiXxugfH5YdBsrUgTt0
# AFNXkzmqTgk+S1Hxb1u/0HCqEHVZPk2A/6eJXYbtpRM5Fcz00jisUl9BRZgSebOD
# V85bBzOveqyC3f0PnHCxRJNhMb8xP/sB/VI7pf2rheSV7zqUSv8vn/fIMblXeaVI
# lpqoq8SP9BJMjE/CoVXJxnkZQRM1Fa7kN9yztvReOhxSgPgpZx/Xl/jkwyEFVJTB
# fBp3sTgfIc/pmqv2ehtakL2AEj78EmOPQohxJT3wyX+P78GA25tLpAvzj3RMMHd8
# z18ZuuVi+60MAzGpOASH1L8Nlr3fZRZnQO+pyye2DCvYmHaIfdUgYJqn7noxxGVv
# 89+RaETh1tgCDvwNpFCSG7vl5A4ako+2fx409r9TWjXC7Oif1IQ5ZJzB4Rf8GvBi
# HYjvMmHpledp1FGRLdSRFVpC3/OKpZY6avIqZp7+8pP/WQP903DdgrvAT6W4xPOB
# xXPa4tGksN3SuqJaiFYHSNyeBufn8iseujW4IbBSbHD4BPqbF3qZ+7nG9d/d/G2/
# Lx4kH9cCmBfmsZdSkHmukDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
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
# UyBFT0MgQ0EgMDMCEzMAABNvNnVaVBHA35YAAAAAE28wDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgwn8VTqwuvnMXXoEVnN/njV/OM7OMavfibpqijQKIq0Qw
# DQYJKoZIhvcNAQEBBQAEggGAJEvj9TOQI93zZhjVjBC+sYqLhywXLqU1wSh/2Q1/
# 1v6zhweBw3GsJBtXNVa7l5/2B7hn/QTIg148pMWRRei0T/F7OXe1aVYJ43AqPIyb
# V2IW+aTtXQk0YIYICduNjCJNuCw76UoJp7IdllriHCVHxNa3ZZFqp+zpwvJUkNbv
# PMwdm6F8ujfSyUWvlwXaPpKaz5L5JV4Kf2XOn8amJP7N7OZEjsyRa+kW0Qt5z38o
# 42dhSGXFfE0Wnu4A5K/cSnrxKpvNiL8snUMidbHIxYUj/QwLhZTtO9wxXUx/xfPP
# YFEYHqbq7D3vI6RbftixcjicUV0zn1izxtOCIbu2hYEOjzjTYSAkMKnESGDc9njh
# 7zWTC5YsuLp6VcLOiXBAe44cHqyKJwISTU0fFT2QHwrOIcM8LEiUXKjcpeuSfOwO
# lb9RGLMhTOLT3UavQxrYZMyebTd7TLxBJFAklTu5CurFJeucUQPx73+iHwHM/dzt
# ImvYPWV268P3rdVbvpX9sgT0oYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIGQnAKW+el/KAEWN9lhkB50hMG0a3dvUIUdle44r7sZUAgZpwnLO0rwYEzIw
# MjYwNDA5MTExNjA2LjI1NFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RDAwLTA1RTAt
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
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFXZ3WkmKPn4
# 4gAAAAAAVTANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NDlaFw0yNjEw
# MjIyMDQ2NDlaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAvbkfkh5ZSLP0MCUWafaw/KZoVZu9iQx8
# r5JwhZvdrUi86UjCCFQONjQanrIxGF9hRGIZLQZ50gHrLC+4fpUEJff5t04VwByW
# C2/bWOuk6NmaTh9JpPZDcGzNR95QlryjfEjtl+gxj12zNPEdADPplVfzt8cYRWFB
# x/Fbfch08k6P9p7jX2q1jFPbUxWYJ+xOyGC1aKhDGY5b+8wL39v6qC0HFIx/v3y+
# bep+aEXooK8VoeWK+szfaFjXo8YTcvQ8UL4szu9HFTuZNv6vvoJ7Ju+o5aTj51sp
# h+0+FXW38TlL/rDBd5ia79jskLtOeHbDjkbljilwzegcxv9i49F05ZrS/5ELZCCY
# 1VaqO7EOLKVaxxdAO5oy1vb0Bx0ZRVX1mxFjYzay2EC051k6yGJHm58y1oe2IKRa
# /SM1+BTGse6vHNi5Q2d5ZnoR9AOAUDDwJIIqRI4rZz2MSinh11WrXTG9urF2uoyd
# 5Ve+8hxes9ABeP2PYQKlXYTAxvdaeanDTQ/vwmnM+yTcWzrVm84Z38XVFw4G7p/Z
# NZ2nscvv6uru2AevXcyV1t8ha7iWmhhgTWBNBrViuDlc3iPvOz2SVPbPeqhyY/NX
# wNZCAgc2H5pOztu6MwQxDIjte3XM/FkKBxHofS2abNT/0HG+xZtFqUJDaxgbJa6l
# N1zh7spjuQ8CAwEAAaOCAcswggHHMB0GA1UdDgQWBBRWBF8QbdwIA/DIv6nJFsrB
# 16xltjAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAFIe4ZJUe9qUKcWeWypchB58fXE/ZIWv2D5XP5/k/tB7
# LCN9BvmNSVKZ3VeclQM978wfEvuvdMQSUv6Y20boIM8DK1K1IU9cP21MG0ExiHxa
# qjrikf2qbfrXIip4Ef3v2bNYKQxCxN3Sczp1SX0H7uqK2L5OhfDEiXf15iou5hh+
# EPaaqp49czNQpJDOR/vfJghUc/qcslDPhoCZpZx8b2ODvywGQNXwqlbsmCS24uGm
# EkQ3UH5JUeN6c91yasVchS78riMrm6R9ZpAiO5pfNKMGU2MLm1A3pp098DcbFTAc
# 95Hh6Qvkh//28F/Xe2bMFb6DL7Sw0ZO95v0gv0ZTyJfxS/LCxfraeEII9FSFOKAM
# Ep1zNFSs2ue0GGjBt9yEEMUwvxq9ExFz0aZzYm8ivJfffpIVDnX/+rVRTYcxIkQy
# FYslIhYlWF9SjCw5r49qakjMRNh8W9O7aaoolSVZleQZjGt0K8JzMlyp6hp2lbW6
# XqRx2cOHbbxJDxmENzohGUziI13lI2g2Bf5qibfC4bKNRpJo9lbE8HUbY0qJiE8u
# 3SU8eDQaySPXOEhJjxRCQwwOvejYmBG5P7CckQNBSnnl12+FKRKgPoj0Mv+z5OMh
# j9z2MtpbnHLAkep0odQClEyyCG/uR5tK5rW6mZH5Oq56UWS0NI6NV1JGS7Jri6jF
# MYIHQzCCBz8CAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTANBglghkgBZQME
# AgEFAKCCBJwwEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDA5MTExNjA2WjAvBgkqhkiG9w0B
# CQQxIgQg9xGQMpb65GWzJ2JpVKwFJR78oG+XSxxC8zJeY/ixS1wwgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCDYuTyXZIZiu799/v4PaqsmeSzBxh0rqkYq7sYY
# avj+zTB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTCCA14GCyqGSIb3DQEJ
# EAISMYIDTTCCA0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0Qw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQAdO1QBgmW/tuBZV5EG
# jhfsV4cN6qBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2BYF0wIhgPMjAyNjA0
# MDgyMzE2NDVaGA8yMDI2MDQwOTIzMTY0NVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7YFgXQIBADAHAgEAAgIa7TAHAgEAAgIPsTAKAgUA7YKx3QIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQAAZueBQJY6FaZ86EflOxRTEgWqoLCzxGuwJG2p
# hfqL8FO64VCPHOcuROvFSCRmv0ANC4Mf4RoBlRNz/3B29ExL2e3UpriSt/lqudLm
# 9RLF68vA9GNOpvTRnRun0x/72W4ufEntpRDvTw31s0qc1N/EOmb92jsivGMEBUxv
# U5W04P8nnS1PdRbUUvCO8uSuFjvqTA440VhDAzY+wAroAmharBjmNxnfFqZkLng8
# PMr1TrFCUm9Pw+5YQlMpwDf0z4VWOWbtY+wTAVQhWxB1kP2IQQUWKn2nU/5YnI7h
# 2efIdOsJ7ZkIUJJN5ZgPaMG7gehnDsCRFBXK4L3R7gllsrH0MA0GCSqGSIb3DQEB
# AQUABIICAC+GBDcttcxqRTdtw3n/Jr5U2zUwXVOanmDL5dSy2lswk3ZMIPlP06ao
# dLruTWkJ4zzzIORAFmnmMy6bYzl8079lDSiz+pbb6vY1efJmkmOXEaeXUt5eU838
# UodingdkgWNHa22fKMRzCwcMU9ZqiQr/Ii8I4FCDcxyVIJDSxvAuumEoux81P6ux
# rTnRC5Tq8lJwsh7Vqvdp9D+2QPfQ4J3EfGxMxWUXlXEnoMELoe4M2WCCiLjgCFPe
# CFxTmKizCY/kbR39rOukZJb/mmbX2k8BdbfuyAaiKKYH1+kLX0LtPdJRoS36LS7i
# asI+vzvKPmMIgWghqRxt7EA45zqRO52bhN5yZUMd97khWtBaIRGNKNtEtqlTqbuC
# HS7VTgK2uPFxgPRh3PMfCTNIpX9iJB6hQMPIJ+hk4MKbxtD5Pxr/rFYej7d/jMP6
# IFNvY9Aic1FurGCD52oLSIaKpKC6LlSiLu9GgWMjmlZsj9Jb91sFmaSZ3JwgZQQw
# L8BlJc+2K+rW/HziUDeTjPshFUOMkOCBlUwjhi17UWM/bLtzl25B1/8UtsjhUCH1
# hpDU/w1K36pMKD3Nr+PweQhnZWIbxBESwQzmBnERUSJSqvCK6cH+87yjraX47hsk
# Ltor1Xf1eEc7jGoap4hiROlWITN3BkduIZ80NbGB0izylkDoLlZ0
# SIG # End signature block

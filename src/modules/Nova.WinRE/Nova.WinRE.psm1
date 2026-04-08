<#
.SYNOPSIS
    WinRE discovery, extraction, and preparation module for Nova.

.DESCRIPTION
    Provides functions to locate, download, and prepare Windows Recovery
    Environment (WinRE) images for use as WinPE boot media.  WinRE is
    preferred over plain WinPE because it ships with WiFi hardware drivers
    (Intel, Realtek, MediaTek, Qualcomm) bundled via Windows Update.
#>

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
# MII+MAYJKoZIhvcNAQcCoII+ITCCPh0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDAz7Ffw/Whbli5
# LmWkgSu1vwziqtVAh6/qF5qN/kVSlKCCIvIwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggcNMIIE9aADAgECAhMzAAfSanjE
# whl/hSLBAAAAB9JqMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDIwHhcNMjYwNDAzMTQ0MTQ3WhcNMjYwNDA2
# MTQ0MTQ3WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQC5BrdIk2tUVIzq
# pkGvyjpYF4Kax1oBBLqHwYRLOkhA5ZRRRqmQly3oXqYispFV1OE3D6vtPz7nTtn1
# PZ5gDZuiqztCmTkg7pHsQhdXku+GUW7QbpmhfO7+NNMxIxgrvx893fm15Qz+zA3j
# Rh+5BN+oIwuGbQtzS6A+TTliq20ZHZSfw4G8J/e15qxfYlu3tzl4k1g64qsca5jT
# CdlCJfbrOgNFzdFcZmLoYUaM0V9F9nnQzDHCAawvptOmBlajnYBI/q+p34XKsxr1
# xIny5ySJGYEvj9zk9RBAtxugYQH9qBeGf2HeTzqK45ZSvcrDSdDjb1uW4DoEHrAN
# qAY+2KWGEtwRb8yJ+r0SaQDz3a2QDea4J2nr93k0pn8HuHIY+YQsxLvXVLZOqJLd
# ObW9ufmCENr4gm5XR84UToryvfZmzDhOdqpHsfHd0A05WE6A3KVdBCuS19uNlmyb
# a3Z4Gbo11TcW5mFJwY1ng4Xrf5KEKO4OyXkzL+J7anfxCsUa+2MCAwEAAaOCAhgw
# ggIUMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQU8rX+P1O5gHfewaYF7d8+XxjH07QwHwYDVR0jBBgwFoAUZZ9RzoVo
# fy+KRYiq3acxux4NAF4wZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMi5jcmwwgaUGCCsGAQUFBwEBBIGYMIGVMGQGCCsG
# AQUFBzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDIuY3J0
# MC0GCCsGAQUFBzABhiFodHRwOi8vb25lb2NzcC5taWNyb3NvZnQuY29tL29jc3Aw
# ZgYDVR0gBF8wXTBRBgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgG
# BmeBDAEEATANBgkqhkiG9w0BAQwFAAOCAgEAWdc4t7d2NyLfCk3m/eY5PJ3S15D6
# 01lu/piFmC34jM0+cP+us5V16PVCAk8zheaiG6YCLkY+WNYMGR7IE9SmrKsDFurl
# K0113CSX+NbWXkEBWOuMV0bHvKfkKQGukyoq2ntqNp7aBElhd/K6GJ0xCufj7chF
# vAohnxtDoKi1OgyomNhNoQRHm5jHO2Co1rA6o5gQB+olZjXRZiW5S7hYTR0h/DNo
# VIu5AFQ5Oors9yonv4EcO+vOsTyjYQtnfmHJgF+tOkaxYuiH1DWHJvo6X4dDasE1
# n8hZp2/MMeSR+RHonDcR1O+Q/p5ad0VtGMTv5ypbr3YQA20Nw0Qhs5qhCl9JXXbH
# P1FBo1XI33MxfcBrAAlfq/XFyIN2DftH8fCb5WXkvAR3cJwDbJNyuRXByU+ez9CX
# hsAJDGaWNW48+s9TWH98w/c1sdQ4Bh2ptE5D+yYbuS60BGbvteS6/dCgR3B/aK8V
# csvIU+o/VPQrdbiAEZ7Cezcewu6P6c0qwDgYK3ts/Wik8+++Yv0QQ7w7P5CN3Gpr
# 4yEXgYTwfGPuvYOtH3X9XqDVi0G4xss2hAr8+DAbWj341L4SgQgpv951Baquw62U
# QPfFUWOBmXjgO2D1NBYwWBEQm6SqRSRSJfSag6CMAM/fQ24apWu5IYQ7ZCX5HTzT
# zuVWJTlLAPvgAWkwggcNMIIE9aADAgECAhMzAAfSanjEwhl/hSLBAAAAB9JqMA0G
# CSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBF
# T0MgQ0EgMDIwHhcNMjYwNDAzMTQ0MTQ3WhcNMjYwNDA2MTQ0MTQ3WjCBizEPMA0G
# A1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UECBMHSGFsbGFuZDEQMA4G
# A1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMgdmFnIDMxFjAUBgNVBAoT
# DUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3NvZnQgQUIwggGiMA0GCSqG
# SIb3DQEBAQUAA4IBjwAwggGKAoIBgQC5BrdIk2tUVIzqpkGvyjpYF4Kax1oBBLqH
# wYRLOkhA5ZRRRqmQly3oXqYispFV1OE3D6vtPz7nTtn1PZ5gDZuiqztCmTkg7pHs
# QhdXku+GUW7QbpmhfO7+NNMxIxgrvx893fm15Qz+zA3jRh+5BN+oIwuGbQtzS6A+
# TTliq20ZHZSfw4G8J/e15qxfYlu3tzl4k1g64qsca5jTCdlCJfbrOgNFzdFcZmLo
# YUaM0V9F9nnQzDHCAawvptOmBlajnYBI/q+p34XKsxr1xIny5ySJGYEvj9zk9RBA
# txugYQH9qBeGf2HeTzqK45ZSvcrDSdDjb1uW4DoEHrANqAY+2KWGEtwRb8yJ+r0S
# aQDz3a2QDea4J2nr93k0pn8HuHIY+YQsxLvXVLZOqJLdObW9ufmCENr4gm5XR84U
# ToryvfZmzDhOdqpHsfHd0A05WE6A3KVdBCuS19uNlmyba3Z4Gbo11TcW5mFJwY1n
# g4Xrf5KEKO4OyXkzL+J7anfxCsUa+2MCAwEAAaOCAhgwggIUMAwGA1UdEwEB/wQC
# MAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisGAQQBgjdhAQAGCCsGAQUF
# BwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAdBgNVHQ4EFgQU8rX+P1O5
# gHfewaYF7d8+XxjH07QwHwYDVR0jBBgwFoAUZZ9RzoVofy+KRYiq3acxux4NAF4w
# ZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0El
# MjAwMi5jcmwwgaUGCCsGAQUFBwEBBIGYMIGVMGQGCCsGAQUFBzAChlhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElEJTIw
# VmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDIuY3J0MC0GCCsGAQUFBzABhiFo
# dHRwOi8vb25lb2NzcC5taWNyb3NvZnQuY29tL29jc3AwZgYDVR0gBF8wXTBRBgwr
# BgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEATANBgkqhkiG
# 9w0BAQwFAAOCAgEAWdc4t7d2NyLfCk3m/eY5PJ3S15D601lu/piFmC34jM0+cP+u
# s5V16PVCAk8zheaiG6YCLkY+WNYMGR7IE9SmrKsDFurlK0113CSX+NbWXkEBWOuM
# V0bHvKfkKQGukyoq2ntqNp7aBElhd/K6GJ0xCufj7chFvAohnxtDoKi1OgyomNhN
# oQRHm5jHO2Co1rA6o5gQB+olZjXRZiW5S7hYTR0h/DNoVIu5AFQ5Oors9yonv4Ec
# O+vOsTyjYQtnfmHJgF+tOkaxYuiH1DWHJvo6X4dDasE1n8hZp2/MMeSR+RHonDcR
# 1O+Q/p5ad0VtGMTv5ypbr3YQA20Nw0Qhs5qhCl9JXXbHP1FBo1XI33MxfcBrAAlf
# q/XFyIN2DftH8fCb5WXkvAR3cJwDbJNyuRXByU+ez9CXhsAJDGaWNW48+s9TWH98
# w/c1sdQ4Bh2ptE5D+yYbuS60BGbvteS6/dCgR3B/aK8VcsvIU+o/VPQrdbiAEZ7C
# ezcewu6P6c0qwDgYK3ts/Wik8+++Yv0QQ7w7P5CN3Gpr4yEXgYTwfGPuvYOtH3X9
# XqDVi0G4xss2hAr8+DAbWj341L4SgQgpv951Baquw62UQPfFUWOBmXjgO2D1NBYw
# WBEQm6SqRSRSJfSag6CMAM/fQ24apWu5IYQ7ZCX5HTzTzuVWJTlLAPvgAWkwggda
# MIIFQqADAgECAhMzAAAABft6XDITYd9dAAAAAAAFMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjEwNDEzMTczMTUzWhcNMjYwNDEzMTczMTUzWjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAyMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA0hqZfD8ykKTA6CDbWvshmBpDoBf7Lv132RVuSqVwQO3a
# ALLkuRnnTIoRmMGo0fIMQrtwR6UHB06xdqOkAfqB6exubXTHu44+duHUCdE4ngjE
# LBQyluMuSOnHaEdveIbt31OhMEX/4nQkph4+Ah0eR4H2sTRrVKmKrlOoQlhia73Q
# g2dHoitcX1uT1vW3Knpt9Mt76H7ZHbLNspMZLkWBabKMl6BdaWZXYpPGdS+qY80g
# DaNCvFq0d10UMu7xHesIqXpTDT3Q3AeOxSylSTc/74P3og9j3OuemEFauFzL55t1
# MvpadEhQmD8uFMxFv/iZOjwvcdY1zhanVLLyplz13/NzSoU3QjhPdqAGhRIwh/YD
# zo3jCdVJgWQRrW83P3qWFFkxNiME2iO4IuYgj7RwseGwv7I9cxOyaHihKMdT9Neo
# SjpSNzVnKKGcYMtOdMtKFqoV7Cim2m84GmIYZTBorR/Po9iwlasTYKFpGZqdWKyY
# nJO2FV8oMmWkIK1iagLLgEt6ZaR0rk/1jUYssyTiRqWr84Qs3XL/V5KUBEtUEQfQ
# /4RtnI09uFFUIGJZV9mD/xOUksWodGrCQSem6Hy261xMJAHqTqMuDKgwi8xk/mfl
# r7yhXPL73SOULmu1Aqu4I7Gpe6QwNW2TtQBxM3vtSTmdPW6rK5y0gED51RjsyK0C
# AwEAAaOCAg4wggIKMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUZZ9RzoVofy+KRYiq3acxux4NAF4wVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMIGuBggrBgEFBQcBAQSBoTCBnjBtBggrBgEF
# BQcwAoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNy
# b3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAy
# MDIxLmNydDAtBggrBgEFBQcwAYYhaHR0cDovL29uZW9jc3AubWljcm9zb2Z0LmNv
# bS9vY3NwMA0GCSqGSIb3DQEBDAUAA4ICAQBFSWDUd08X4g5HzvVfrB1SiV8pk6XP
# HT9jPkCmvU/uvBzmZRAjYk2gKYR3pXoStRJaJ/lhjC5Dq/2R7P1YRZHCDYyK0zvS
# RMdE6YQtgGjmsdhzD0nCS6hVVcgfmNQscPJ1WHxbvG5EQgYQ0ZED1FN0MOPQzWe1
# zbH5Va0dSxtnodBVRjnyDYEm7sNEcvJHTG3eXzAyd00E5KDCsEl4z5O0mvXqwaH2
# PS0200E6P4WqLwgs/NmUu5+Aa8Lw/2En2VkIW7Pkir4Un1jG6+tj/ehuqgFyUPPC
# h6kbnvk48bisi/zPjAVkj7qErr7fSYICCzJ4s4YUNVVHgdoFn2xbW7ZfBT3QA9zf
# hq9u4ExXbrVD5rxXSTFEUg2gzQq9JHxsdHyMfcCKLFQOXODSzcYeLpCd+r6GcoDB
# ToyPdKccjC6mAq6+/hiMDnpvKUIHpyYEzWUeattyKXtMf+QrJeQ+ny5jBL+xqdOO
# PEz3dg7qn8/oprUrUbGLBv9fWm18fWXdAv1PCtLL/acMLtHoyeSVMKQYqDHb3Qm0
# uQ+NQ0YE4kUxSQa+W/cCzYAI32uN0nb9M4Mr1pj4bJZidNkM4JyYqezohILxYkgH
# bboJQISrQWrm5RYdyhKBpptJ9JJn0Z63LjdnzlOUxjlsAbQir2Wmz/OJE703BbHm
# QZRwzPx1vu7S5zCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAAAAcwDQYJ
# KoZIhvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNh
# dGlvbiBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIxMDQwMTIw
# MDUyMFoXDTM2MDQwMTIwMTUyMFowYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlm
# aWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBALLwwK8ZiCji3VR6TElsaQhVCbRS/3pK+MHrJSj3Zxd3KU3rlfL3
# qrZilYKJNqztA9OQacr1AwoNcHbKBLbsQAhBnIB34zxf52bDpIO3NJlfIaTE/xrw
# eLoQ71lzCHkD7A4As1Bs076Iu+mA6cQzsYYH/Cbl1icwQ6C65rU4V9NQhNUwgrx9
# rGQ//h890Q8JdjLLw0nV+ayQ2Fbkd242o9kH82RZsH3HEyqjAB5a8+Ae2nPIPc8s
# ZU6ZE7iRrRZywRmrKDp5+TcmJX9MRff241UaOBs4NmHOyke8oU1TYrkxh+YeHgfW
# o5tTgkoSMoayqoDpHOLJs+qG8Tvh8SnifW2Jj3+ii11TS8/FGngEaNAWrbyfNrC6
# 9oKpRQXY9bGH6jn9NEJv9weFxhTwyvx9OJLXmRGbAUXN1U9nf4lXezky6Uh/cgjk
# Vd6CGUAf0K+Jw+GE/5VpIVbcNr9rNE50Sbmy/4RTCEGvOq3GhjITbCa4crCzTTHg
# YYjHs1NbOc6brH+eKpWLtr+bGecy9CrwQyx7S/BfYJ+ozst7+yZtG2wR461uckFu
# 0t+gCwLdN0A6cFtSRtR8bvxVFyWwTtgMMFRuBa3vmUOTnfKLsLefRaQcVTgRnzeL
# zdpt32cdYKp+dhr2ogc+qM6K4CBI5/j4VFyC4QFeUP2YAidLtvpXRRo3AgMBAAGj
# ggI1MIICMTAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0O
# BBYEFNlBKbAPD2Ns72nX9c0pnqRIajDmMFQGA1UdIARNMEswSQYEVR0gADBBMD8G
# CCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3Mv
# UmVwb3NpdG9yeS5odG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDwYDVR0T
# AQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2ioojCBhAYD
# VR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9j
# cmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIw
# Q2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBwwYIKwYBBQUHAQEE
# gbYwgbMwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# b3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIw
# Um9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQwLQYIKwYB
# BQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20vb2NzcDANBgkqhkiG
# 9w0BAQwFAAOCAgEAfyUqnv7Uq+rdZgrbVyNMul5skONbhls5fccPlmIbzi+OwVdP
# Q4H55v7VOInnmezQEeW4LqK0wja+fBznANbXLB0KrdMCbHQpbLvG6UA/Xv2pfpVI
# E1CRFfNF4XKO8XYEa3oW8oVH+KZHgIQRIwAbyFKQ9iyj4aOWeAzwk+f9E5StNp5T
# 8FG7/VEURIVWArbAzPt9ThVN3w1fAZkF7+YU9kbq1bCR2YD+MtunSQ1Rft6XG7b4
# e0ejRA7mB2IoX5hNh3UEauY0byxNRG+fT2MCEhQl9g2i2fs6VOG19CNep7SquKaB
# jhWmirYyANb0RJSLWjinMLXNOAga10n8i9jqeprzSMU5ODmrMCJE12xS/NWShg/t
# uLjAsKP6SzYZ+1Ry358ZTFcx0FS/mx2vSoU8s8HRvy+rnXqyUJ9HBqS0DErVLjQw
# K8VtsBdekBmdTbQVoCgPCqr+PDPB3xajYnzevs7eidBsM71PINK2BoE2UfMwxCCX
# 3mccFgx6UsQeRSdVVVNSyALQe6PT12418xon2iDGE81OGCreLzDcMAZnrUAx4XQL
# Uz6ZTl65yPUiOh3k7Yww94lDf+8oG2oZmDh5O1Qe38E+M3vhKwmzIeoB1dVLlz4i
# 3IpaDcR+iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqU
# MIIakAIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0Mg
# Q0EgMDICEzMAB9JqeMTCGX+FIsEAAAAH0mowDQYJYIZIAWUDBAIBBQCgXjAQBgor
# BgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG
# 9w0BCQQxIgQgGSXfUsz5rWgVIon10eK9zAEXTAEsU7rWNxQYBUV0CMgwDQYJKoZI
# hvcNAQEBBQAEggGAIxnKfy07fx0U0y/tfB8RCpJ1rLyu4k3l/4EGzyBLYL3sOBam
# yLuJU9+uGvkLzRax1JFidcCtpLu4C3kGtr0kEdu90pRE4SfVFXw0pYU8ZN7p8NsH
# SNVaX6y83f2cVHlB7E9T6FUkqSEwKAvQJ8qo83oCEf6aywPaE/bWSPBn6EQEp+OE
# aKtRj0MO7wNmYzOiRIXjgsd2Ti0B4vSVM47eyzPz3pkF6FPaG7aZvoa5K3NZpBLO
# jVCWWzPtu+HWOExno37xz14K/QanNw1TMgtltVjMALSH6R5kWLak0kuQPvgPIbXd
# mrw9TYG03nBZNoo2e2wIi3TnByxQt/q4jhL9Dm6RZsvRFSwk1sPZTcnkdzkbmr5b
# EmN2cw4sJ2odcBPv4EqLvE5jLh73704KjvjBOIlGmsraeO6oX/te2Sk/7M4bgxur
# n7L3tCGDTfY/Q6s68CUlXZMAv+1kbY4pGtwfVtZyoG907i2B0hsGChpvlR14zX3h
# O5T8eojlKNF3oq89oYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJKoZIhvcN
# AQcCoIIX7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEE
# oIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIGyv
# gB0lx/gvcSTfTA+r7JFB0509fVy5yKrX0GcKeBmeAgZpwnK/CssYEzIwMjYwNDAz
# MTYzODA1LjQ4MVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJh
# dGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RDAwLTA1RTAtRDk0NzE1
# MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRo
# b3JpdHmggg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAABTANBgkq
# hkiG9w0BAQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVyaWZpY2F0
# aW9uIFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAxMTE5MjAz
# MjMxWhcNMzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJT
# QSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBvf7KrQ5cM
# SqFSHGqg2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDsfMuIEqvG
# YOPURAH+Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbBT7uq3wx3
# mXhtVmtcCEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5EeH5KrlF
# nxpjKKTavwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6ovnUfANj
# IgM9JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fjJHrmlQ0E
# IXmp4DhDBieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOsRpeexIve
# R1MPTVf7gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiunhKbq0Xbj
# kNoU5JhtYUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE3oWsDqMX
# 3jjv40e8KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8cIxLoKSD
# zCCBOu0hWdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMBAAGjggIb
# MIICFzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYE
# FGtpKDo1L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsG
# AQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVw
# b3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAwe
# CgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSob
# yhmYBAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJp
# ZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIw
# LmNybDCBlAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5
# JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5
# JTIwMjAyMC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXnTHho+k7h
# 2ESZJRWluLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC2IWmtKMy
# S1OWIviwpnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5zyEh89F7
# 2u9UIw+IfvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbNnCKNZPmh
# zoa8PccOiQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqst8S+w+RU
# die8fXC1jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVmoNR/dSpR
# Cxlot0i79dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRSSvijmwJw
# xRxLLpMQ/u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7vPKNMN+SZ
# DWycU5ODIRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/26ozePQ/T
# WfNXKBOmkFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/AAxw9Sdg
# q/+rY7jjgs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSOiUIr0Xqc
# r1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFXZ3WkmKPn44gAAAAAA
# VTANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBU
# aW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NDlaFw0yNjEwMjIyMDQ2
# NDlaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYD
# VQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hp
# ZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQ
# dWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEAvbkfkh5ZSLP0MCUWafaw/KZoVZu9iQx8r5JwhZvd
# rUi86UjCCFQONjQanrIxGF9hRGIZLQZ50gHrLC+4fpUEJff5t04VwByWC2/bWOuk
# 6NmaTh9JpPZDcGzNR95QlryjfEjtl+gxj12zNPEdADPplVfzt8cYRWFBx/Fbfch0
# 8k6P9p7jX2q1jFPbUxWYJ+xOyGC1aKhDGY5b+8wL39v6qC0HFIx/v3y+bep+aEXo
# oK8VoeWK+szfaFjXo8YTcvQ8UL4szu9HFTuZNv6vvoJ7Ju+o5aTj51sph+0+FXW3
# 8TlL/rDBd5ia79jskLtOeHbDjkbljilwzegcxv9i49F05ZrS/5ELZCCY1VaqO7EO
# LKVaxxdAO5oy1vb0Bx0ZRVX1mxFjYzay2EC051k6yGJHm58y1oe2IKRa/SM1+BTG
# se6vHNi5Q2d5ZnoR9AOAUDDwJIIqRI4rZz2MSinh11WrXTG9urF2uoyd5Ve+8hxe
# s9ABeP2PYQKlXYTAxvdaeanDTQ/vwmnM+yTcWzrVm84Z38XVFw4G7p/ZNZ2nscvv
# 6uru2AevXcyV1t8ha7iWmhhgTWBNBrViuDlc3iPvOz2SVPbPeqhyY/NXwNZCAgc2
# H5pOztu6MwQxDIjte3XM/FkKBxHofS2abNT/0HG+xZtFqUJDaxgbJa6lN1zh7spj
# uQ8CAwEAAaOCAcswggHHMB0GA1UdDgQWBBRWBF8QbdwIA/DIv6nJFsrB16xltjAf
# BgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6Bd
# hltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQl
# MjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkG
# CCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1l
# c3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/
# BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYB
# BAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcN
# AQEMBQADggIBAFIe4ZJUe9qUKcWeWypchB58fXE/ZIWv2D5XP5/k/tB7LCN9BvmN
# SVKZ3VeclQM978wfEvuvdMQSUv6Y20boIM8DK1K1IU9cP21MG0ExiHxaqjrikf2q
# bfrXIip4Ef3v2bNYKQxCxN3Sczp1SX0H7uqK2L5OhfDEiXf15iou5hh+EPaaqp49
# czNQpJDOR/vfJghUc/qcslDPhoCZpZx8b2ODvywGQNXwqlbsmCS24uGmEkQ3UH5J
# UeN6c91yasVchS78riMrm6R9ZpAiO5pfNKMGU2MLm1A3pp098DcbFTAc95Hh6Qvk
# h//28F/Xe2bMFb6DL7Sw0ZO95v0gv0ZTyJfxS/LCxfraeEII9FSFOKAMEp1zNFSs
# 2ue0GGjBt9yEEMUwvxq9ExFz0aZzYm8ivJfffpIVDnX/+rVRTYcxIkQyFYslIhYl
# WF9SjCw5r49qakjMRNh8W9O7aaoolSVZleQZjGt0K8JzMlyp6hp2lbW6XqRx2cOH
# bbxJDxmENzohGUziI13lI2g2Bf5qibfC4bKNRpJo9lbE8HUbY0qJiE8u3SU8eDQa
# ySPXOEhJjxRCQwwOvejYmBG5P7CckQNBSnnl12+FKRKgPoj0Mv+z5OMhj9z2Mtpb
# nHLAkep0odQClEyyCG/uR5tK5rW6mZH5Oq56UWS0NI6NV1JGS7Jri6jFMYIHRjCC
# B0ICAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBp
# bmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTANBglghkgBZQMEAgEFAKCC
# BJ8wEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAcBgkqhkiG9w0BCQUxDxcNMjYwNDAzMTYzODA1WjAvBgkqhkiG9w0BCQQxIgQg
# ntga9LcFvqYx29K84s9J4tqDLIYhSvbUzR0o589OS5MwgbkGCyqGSIb3DQEJEAIv
# MYGpMIGmMIGjMIGgBCDYuTyXZIZiu799/v4PaqsmeSzBxh0rqkYq7sYYavj+zTB8
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTCCA2EGCyqGSIb3DQEJEAISMYID
# UDCCA0yhggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUw
# LUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBp
# bmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQAdO1QBgmW/tuBZV5EGjhfsV4cN
# 6qBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBp
# bmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO16IB0wIhgPMjAyNjA0MDMxMTE2
# NDVaGA8yMDI2MDQwNDExMTY0NVowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7Xog
# HQIBADAKAgEAAgIa0gIB/zAHAgEAAgITkjAKAgUA7XtxnQIBADA2BgorBgEEAYRZ
# CgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0G
# CSqGSIb3DQEBCwUAA4IBAQBw4UJKQSJ7f2LCVdEtBVBGy9nMC6RgpIZ/F4qraHax
# cSwFMW7LThLn+tKMotemKfZREJh9yzlikJKTvh10JMxSpybvr1MYQqHZDKRJZaJy
# FtWCcj+BNDXwVKhsxQ2VBPh4y6dhUeZNVhNdQffeKPDClbl85bSLAWY9YIrgtmyZ
# n5FNisTS5izsK07W8xiv0BH3jhoP2whGtGG/LkId1RdlFfjtzNcpaQ5LF8g5mcxU
# U4IA0GqwrvZ2wy11a5Tc77hedSsK8PS3b5iZPA/a15z0MUt0qr0LwLoNjLKnVyeC
# Rf/EmZ6AM+OsU6JPpkytcfkzJ/kNpn6ukBrGNanUVD0NMA0GCSqGSIb3DQEBAQUA
# BIICALCFItnx3vpjotrgfhMt8vSidj6CzCz86Px9dMgoIPapZibwtYP0SiCuwqG2
# Al+NjtGA1IAweZA8fggOonT2zuM8wNCdMyS3NXyV5fvqC1e6l/tEGLnWJ/3esUKb
# nl/RyXSH+hoDpZTKemCGtqtgamCqfdHRuJaaqEQV4g/SZXRGOiPVbBjZe743xOQm
# IxfsmRQi00mA+bD//WMq91Bh1x5h7ZvY2Wx2aW3DrRvZglGOFoixm4vUXZAri9Wr
# wHkRMklIsE3jg502nxPHOYJBwKqlq/4cH7pMGoazFnsPawVmaesGod6ksiI9Et++
# +aIcfaVUeKbkNMAZ4zHVvTVoHZ2MhVnpA2G1UI0npzfv7oLDLOclZs+mqn5Zoc/r
# 2N5sNummlfYueTti+9XPFh+VpTZedikwDDUbMSdE0eYmSg59Ptf2pcz+Rs6AI71C
# oNVWYx45dz2raxdNcVKBL6UAMebPkLub/ihvzkazyGHZPcyn/oUezFG8XBCNaYsx
# MK57OB9D9JRJwAOSWwhtzEZ0nG6YxLG7snO1bLgEGhgZu9EbH+/BHDDBloGPyd4V
# HHyN8xjuV58EgGNja8HcyA+RVrVnAt+YqKvWydssWL8hVBwIeDnxFrsL5HOf0RtR
# HdloF/VzBPcvbUzj4EjZUcb1O83r4hMiUtlgcq3E9P5jt8f+
# SIG # End signature block

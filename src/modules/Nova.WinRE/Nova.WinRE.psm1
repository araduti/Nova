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
# MII6FAYJKoZIhvcNAQcCoII6BTCCOgECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCQKNSvvwIka0Dt
# NKW7ryQintocZSoS2VjQKxhI6kuhzqCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAALJYmh
# eTfl9V9mAAAAAAslMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNDEwMTQzMzI1WhcNMjYwNDEz
# MTQzMzI1WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCoRt7KuvVHrwTk
# RDxoLt3Hu8hKXs8FpKttF7I7rMUvoYB6Y8iYaGvLFDQ1XudogJ2G/5xLA4IUT3rF
# ZDdCX/bIAjAIa+7Iv12SrHm/mUWBb9JWn20ds6oPmi1lVVd2Dk3mLHJ3qWaRR7I0
# qAfT/xJ0JsSBNW6RnhKw1U+TFyrevOJHa870enc+hsCT+OOHIeq4EsOchVNFqRNw
# 7AAIj7Iq7mcOXxhYVVdLiyGGjAO7EMJDzZHJ+2DKwZKH1HdONN9NqRZ5xV9E5IU4
# 7r+iqpYwSseLtx+dzcFAFfomAWcZEmceAOTvFjTQBFe4VX+wkM8P70cfZRyE746F
# AuScjqIPo/Zny1YYmfJM/E4LPNLnROUr24nBQkhMQhBD8zWLzh5AmmzerkSnLEma
# 63OATiMxIY/aWc505QcYC/UmZK3uC2rLm7PWY5Vmaze9vuIwJjn1aNLe6lwSw8Qr
# pBOToDPpzuOySz5s0G0XowEDlsBlPov3nm5FgT3Z1zI933hy1PMCAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUyhxTM5EWAZIW8X59xk6mx808hZkwHwYDVR0jBBgwFoAUayVB3vtr
# fP0YgAotf492XapzPbgwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwQU9DJTIwQ0ElMjAwNC5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEFPQyUyMENBJTIwMDQuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAMRVo79ZYMctxbTncnYSUA+xTwTu2ZXwBOtnPsIzY746k/oBWm+ShFPX
# OE8RnWYCVr2vMWGzdgIfC3aS08P/D9kjxPYJpahD0kPKvlHVGiSNk87I+j5ljG7j
# 0a8IEi9vaMNrR0aJKKhjSqqkUpVyGYH8AZJ/TUYoGgkGbtMvqjXLHu5MS/CBvqlb
# CeQ0f3xmqzpa74NkQ06dE48j5UWaqOHfd8+v8BBkxwkdZbujVtA8EZq6SGZEo8Uz
# IYJhfzxiiYqpTTmr5JjfA/A4WryMPdY1ErcLEIvtADLp2RYZ5aPDT3DXbuLcdMvt
# L1mAsFm1tTL6F9h9EPMmUcZX+dbKiNkBkL/ghV4cC7t91t/n8mFm4L/46yqmH0uj
# fAYZRAwn7Z26mWxYe/cHrskWS6nvh8atFM7kqiD63NUJiq3LjQAp+1rmJBvVi4JE
# u8LqC88D8mxN+6Ru8zcFIj7chzlKEpwD3NAKGo0I0F4o6IisMJne5dpzSm1KXpH2
# 3Ul1nSK/P92dMA+3AnFyA/BAv+jxf9YTkV1VlMFYEZ9ROsxI/y1hYGWqv6qcsOIP
# yw9cWOfiT/0Bqwdk+pIPFrW2k0pI3Zmi8zozD0FMfLpuT924KRwqSmSM3qk4VSep
# kXUtC2b/Ar71yJUTBX/63+kyCSMciAsQe/u4NPkwcljbJ6jmeB50MIIGyTCCBLGg
# AwIBAgITMwAACyWJoXk35fVfZgAAAAALJTANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDA0MB4XDTI2MDQxMDE0
# MzMyNVoXDTI2MDQxMzE0MzMyNVowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAqEbeyrr1R68E5EQ8aC7dx7vISl7PBaSrbReyO6zFL6GAemPImGhryxQ0NV7n
# aICdhv+cSwOCFE96xWQ3Ql/2yAIwCGvuyL9dkqx5v5lFgW/SVp9tHbOqD5otZVVX
# dg5N5ixyd6lmkUeyNKgH0/8SdCbEgTVukZ4SsNVPkxcq3rziR2vO9Hp3PobAk/jj
# hyHquBLDnIVTRakTcOwACI+yKu5nDl8YWFVXS4shhowDuxDCQ82RyftgysGSh9R3
# TjTfTakWecVfROSFOO6/oqqWMErHi7cfnc3BQBX6JgFnGRJnHgDk7xY00ARXuFV/
# sJDPD+9HH2UchO+OhQLknI6iD6P2Z8tWGJnyTPxOCzzS50TlK9uJwUJITEIQQ/M1
# i84eQJps3q5EpyxJmutzgE4jMSGP2lnOdOUHGAv1JmSt7gtqy5uz1mOVZms3vb7i
# MCY59WjS3upcEsPEK6QTk6Az6c7jsks+bNBtF6MBA5bAZT6L955uRYE92dcyPd94
# ctTzAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFMocUzORFgGSFvF+fcZOpsfNPIWZMB8GA1Ud
# IwQYMBaAFGslQd77a3z9GIAKLX+Pdl2qcz24MGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEFPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBD
# QSUyMDA0LmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQDEVaO/WWDHLcW053J2ElAPsU8E7tmV8ATrZz7C
# M2O+OpP6AVpvkoRT1zhPEZ1mAla9rzFhs3YCHwt2ktPD/w/ZI8T2CaWoQ9JDyr5R
# 1RokjZPOyPo+ZYxu49GvCBIvb2jDa0dGiSioY0qqpFKVchmB/AGSf01GKBoJBm7T
# L6o1yx7uTEvwgb6pWwnkNH98Zqs6Wu+DZENOnROPI+VFmqjh33fPr/AQZMcJHWW7
# o1bQPBGaukhmRKPFMyGCYX88YomKqU05q+SY3wPwOFq8jD3WNRK3CxCL7QAy6dkW
# GeWjw09w127i3HTL7S9ZgLBZtbUy+hfYfRDzJlHGV/nWyojZAZC/4IVeHAu7fdbf
# 5/JhZuC/+Osqph9Lo3wGGUQMJ+2duplsWHv3B67JFkup74fGrRTO5Kog+tzVCYqt
# y40AKfta5iQb1YuCRLvC6gvPA/JsTfukbvM3BSI+3Ic5ShKcA9zQChqNCNBeKOiI
# rDCZ3uXac0ptSl6R9t1JdZ0ivz/dnTAPtwJxcgPwQL/o8X/WE5FdVZTBWBGfUTrM
# SP8tYWBlqr+qnLDiD8sPXFjn4k/9AasHZPqSDxa1tpNKSN2ZovM6Mw9BTHy6bk/d
# uCkcKkpkjN6pOFUnqZF1LQtm/wK+9ciVEwV/+t/pMgkjHIgLEHv7uDT5MHJY2yeo
# 5ngedDCCBygwggUQoAMCAQICEzMAAAAWMZKNkgJle5oAAAAAABYwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMjlaFw0zMTAzMjYxODExMjlaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDKVfrI2+gJMM/0bQ5OVKNdvOASzLbUUMvX
# uf+Vl7YGuofPaZHVo3gMHF5inT+GMSpIcfIZ9qtXU1UG68ry8vNbQtOL4Nm30ifX
# pqI1+ByiAWLO1YT0WnzG7XPOuoTeeWsNZv5FmjxCsReBZvyzyzCyXZbu1EQfJxWT
# H4ebUwtAiW9rqMf9eDj/wYhiEfNteJV3ZFeibD2ztCHr9JhFdd97XbnCHgQoTIqc
# 02X5xlRKtUGBa++OtHBBjiJ/uwBnzTkqu4FjpZjQeJtrmda+ur1CT2jflWIB/ypn
# 7u7V9tvW9wJbJYt/H2EtJ0GONWxJZ7TEu8jWPindOO3lzPP7UtzS/mVDV94HucWa
# ltmsra6zSG8BoEJ87IM8QSb7vfm/O41FhYkUv89WIj5ES2O4kxyiMSfe95CMivCu
# YrRP2hKvx7egPMrWgDDBkxMLgrKZO9hRNUMm8vk3w5b9SogHOyJVhxyFm8aFXfIx
# gqDF4S0g4bhbhnzljmSlCLlumMZcXFGDjpF2tNoAu3VGFGYtHtTSNVKvZpgB3b4y
# naoDkbPf+Wg4523jt4VneasBgZhC1srZI2NCnCBBfgjLq04pqEKAWEohyW2K29KS
# kkHvt5VaE1ac3Yt+oyiOzMS57tXwQDJLGvLg/OXFO0VNvczDndfIfXYExB/ab2Pu
# MSwd5VIBOwIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBRrJUHe+2t8/RiACi1/j3ZdqnM9uDBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQAG1VBeVHTVRBljlcZD3IiM
# xwPyMjQyLNaEnVu5mODm2hRBJfH8GsBLATmrHAc8F47jmk5CnpUPiIguCbw6Z/KV
# j4Dsoiq228NSLMLewFfGMri7uwNGLISC5ccp8vUdADDEIsS2dE+QI9OwkDpv3XuU
# D7d+hAgcLVcMOl1AsfEZtsZenhGvSYUrm/FuLq0BqEGL9GXM5c+Ho9q8o+Vn/S+G
# WQN2y+gkRO15s0kI05nUpq/dOD4ri9rgVs6tipEd0YZqGgD+CZNiaZWrDTOQbNPn
# cd2F9qOsUa20miYruoT5PwJAaI+QQiTE2ZJeMJOkOpzhTUgqVMZwZidEUZKCquda
# eQA08WwnkQMfKyHzaU8j48ULcU4hUwvMsv7fSurOe9GAdRQCPvF8WcSK5oDHe8VV
# JM4tv6KKCm91HqLx9JamBgRI6R2SfY3nu26EGznu0rCg/769z8xWm4PVcC2ZaL6V
# lKVqFp1NsN8YqMyf5t+bbGVb09noFKcJG/UwyGlxRmQBlfeBUQx5/ytlzZzsEnhr
# JF9fTAfje8j3OdX5lEnePTFQLRlvzZFBqUXnIeQKv3fHQjC9m2fo/Z01DII/qp3d
# 8LhGVUW0BCG04fRwHJNH8iqqCG/qofMv+kym2AxBDnHzNgRjL60JOFiBgiurvLhY
# QNhB95KWojFA6shQnggkMTCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
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
# rmcxghcyMIIXLgIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBBT0MgQ0EgMDQCEzMAAAsliaF5N+X1X2YAAAAACyUwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgL6mofwgIvXjT0EtnJDaU4PKJM7j+Uo1ZA6+VOL31q5kw
# DQYJKoZIhvcNAQEBBQAEggGACqJbeqLb95K6lu4o3Fp5Qej9yU7MfCC8jjUe5dR+
# 2Wf7mVGuHT0GByhRX3W/40HVlnqdcFCh6UTsVIfCbcKdcrzvANN866YebQxIpcfV
# 66TAqOCQl5kmWmxzY0iiKcTfEx1yY5nk9JMfLZOPP09nyZtyBIyAuyo/Mq7wrNo3
# G4J2FnJQuIIr2wLHQWoogdCVO/46LYGTZZIEBKIsdJWNba+qAISvYTW5+LdtpnOt
# Nvo1CcVjnNDYcSfpeATRx0takPggwAf/qVl9WY8krs1gwJWNI05UR0kb37cD2ynr
# jy5+Fj2Fd9UnIY2eTxqFn2tRdbNSMfDwwmH0o8PnKe/cawoE3RN31aipQe00/wc1
# 4UceHN76ALYFSNRztNbHoQ5JGy6oFuLZ/bzuEYnucKenGlVIUaKB211tDRCxJgrT
# f4EFQUbqiu9NwqPOV5utt8CvJy518daR5SeaJNbbKt3v6E+PEuL1N4bt2azq+JOn
# YfHLr9GREKqHJfwHg1ljm6N3oYIUsjCCFK4GCisGAQQBgjcDAwExghSeMIIUmgYJ
# KoZIhvcNAQcCoIIUizCCFIcCAQMxDzANBglghkgBZQMEAgEFADCCAWoGCyqGSIb3
# DQEJEAEEoIIBWQSCAVUwggFRAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIEaZR6ZsPoB2WAjoR2yOFv6nCweYXE5faJoTyEA4UXkEAgZpxm4tzD8YEzIw
# MjYwNDExMDgwNjE2LjY5OVowBIACAfSggemkgeYwgeMxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5k
# IE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjdB
# MUEtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# IFN0YW1waW5nIEF1dGhvcml0eaCCDykwggeCMIIFaqADAgECAhMzAAAABeXPD/9m
# LsmHAAAAAAAFMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDExMTkyMDMyMzFaFw0zNTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAnnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1l
# Rkd3kcFdcG9/sqtDlwxKoVIcaqDb+omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjx
# nG/eViS4sOx8y4gSq8Zg49REAf5huXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5
# hJM1xznkRsFPu6rfDHeZeG1Wa1wISvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFl
# yAKwn6yjN/kR4fkquUWfGmMopNq/B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTP
# Vi3gVErnc/qi+dR8A2MiAz0kN0nh7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKx
# Lms73KG/Z+MkeuaVDQQheangOEMGJ4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxR
# YR/JPGAaM6xGl57Ei95HUw9NV/uC3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxO
# mM2rl4uKK6eEpurRduOQ2hTkmG1hSuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cj
# RKG79+TX+sTehawOoxfeOO/jR7wo3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xT
# nD1a69w/UTxwjEugpIPMIIE67SFZ2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8F
# UXetXr0CAwEAAaOCAhswggIXMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEE
# AwIBADAdBgNVHQ4EFgQUa2koOjUvSGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJ
# BgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZ
# BgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1Ud
# IwQYMBaAFMh+0mqFKhvKGZgEByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJ
# ZGVudGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1
# dGhvcml0eSUyMDIwMjAuY3JsMIGUBggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUH
# MAKGdWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9z
# b2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNh
# dGUlMjBBdXRob3JpdHklMjAyMDIwLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2
# x35ttVoVdedMeGj6TuHYRJklFaW4sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6A
# F6ycWoEYR0LYhaa0ozJLU5Yi+LCmcrdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM
# 74LNvVzY0/nPISHz0Xva71QjD4h+8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLsl
# LKsO8F2aBs2cIo1k+aHOhrw9xw6JCWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yF
# M7Ujrhc0aqy3xL7D5FR2J7x9cLWMq7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFov
# IP7YG4ZkJWag1H91KlELGWi3SLv10o4KGag42pswjybTi4toQcC/irAodDW8HNtX
# +cbz0sMptFJK+KObAnDFHEsukxD+7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9
# TlxydiFhvu88o0w35JkNbJxTk4MhF/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWV
# ydt4ytxYP/bqjN49D9NZ81coE6aQWm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeC
# UMYmBx3PkP8ADHD1J2Cr/6tjuOOCztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdto
# SAHEUKiBhI6JQivRepyvWcl+JYbYbBh7pmgAXVswggefMIIFh6ADAgECAhMzAAAA
# W0q1jUEybdx0AAAAAABbMA0GCSqGSIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMB4XDTI2MDEwODE4NTkw
# NVoXDTI3MDEwNzE4NTkwNVowgeMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMg
# TGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjdBMUEtMDVFMC1EOTQ3
# MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5nIEF1
# dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJBUzBbbnlDX
# ee0B0KD5G4/475thFyfctCyuESTWQXvlLi4Wx/td2qUdeq4ideeg6VWhiOHfu3wJ
# V4TUGSRtqh9Ccr1BmiBKv9iuFpgHyIBu5Qx38ZsxwlFeXVS+ZqJJKnXRbDNQdcYS
# oC/6c0hQJ/PH50DBRDQkPXVwyFizLrRH9AlrJeUg7BKeT23zftS8/KOJLvEEbHOF
# 6pSOY3ZVprZUWbWjWwRTmoHaQ/E8vrWtLNyEJ+b089VW1Ikra3t4GTB5Wby3CL1K
# 2zYnAxBIvafsKMFyj9OuXHcTPKMDoFSMeamG9MKOMb6uoG1PjdnDgsLP6EOMRSzr
# LL7jED1mbB9RSd9fhty+HQr6vZgsBn6oUy+YTpNVLskwdtUM82WYAkPztlOt3AiL
# 0qyV7/U3j/uq3vHMjPM0w0340M57Nei0g4BCcMt0dbqoc91VgCb3/36sHQANontn
# 1HOF2oLk8190QRS43isHVra8H8sf5+GlqIYsYiCKX04HZiOzZW826nVI6d++8lyT
# eWmpj90Ua9uPbJhVjwE3oh6tO510ySqmSMSLEN07p3Ibe3E6BAb2w93rWzb26+dp
# SthbKF4kApofqBsWPX4MEtHKSOftPmVTCQ47tghrVuHia9jY+Hsj01m4KW4WtkmV
# m3L6hMZECMa4sjMxAXz+bX/AJhWTe6TZAgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQU
# 7/LqUlWWYhXJdXwgYKx4b8Gv0rYwHwYDVR0jBBgwFoAUa2koOjUvSGNAz3vYr0np
# Ptk92yEwbAYDVR0fBGUwYzBhoF+gXYZbaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0YW1w
# aW5nJTIwQ0ElMjAyMDIwLmNybDB5BggrBgEFBQcBAQRtMGswaQYIKwYBBQUHMAKG
# XWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwUHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAM
# BgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQE
# AwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEBDAUAA4ICAQAAH+zd+XKh4OxXYMWFmtgi
# lXAQGctOjCUB1w/uBiC/OXcH3Ia4/XbdUhKzFbaiTbIE6vYZKd1p4u7nKOLkawym
# AMVyuO7LSl6rLKttZIyLhWjTK0zXOz0u4xLq9+bRtBEKJvA6sD5nJwH1IO6z1Yiz
# yuIRoalMCnbrUixfWxQn4TAmN7t9uk+X2FUThEa3ewzRwhtG+xwaAbLMkxRmR24J
# nfXd1VxKo90+m7Wzuov96Uugx5wZdewiIIm1ZWTj4lCJHup679LcOa7tAxJMipVa
# SltQH9fm9TOKczlfxtWuBcLU4duZfqwgsILsH7PMkcX1zwQzQD0yAtPhnYz9KNG1
# 25bX+iilOe1S8RHqv2bbBpMpao4kcUvQI6dMgKRvFmm1eLbhSNOQplDMTGD1tNVd
# NGkI96jUu+troUjWMMi46TQfBAHxtDTpRhIu/87vAVQ8Z6RHhFxesz4Ed5JThaIQ
# RAy6GcO/Jk+QzDzoZ0arRIkIsGJ7rZgOVAjx9ctfw8lH9RfjcwB3wdGBYNMNVJqQ
# pUai2Taddf5pXzTZEHIqLEF53SrBjIeInoQrP7U5VlXiMQsxewLdINrAE2l2TR3K
# Bikb+RQRygbTp8jj2yiC0NCUwG+K+ndglN5RMbXjFW6aKa59Xq+b8XzK/DK+AJtg
# OpHgJv8Qrk62A+twOVLOpjGCA9QwggPQAgEBMHgwYTELMAkGA1UEBhMCVVMxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0
# IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENBIDIwMjACEzMAAABbSrWNQTJt3HQA
# AAAAAFswDQYJYIZIAWUDBAIBBQCgggEtMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQg3K1fMwxSdpsDeXTs5U+m0MNwpmnDp4dU7qSp
# lPd7WZcwgd0GCyqGSIb3DQEJEAIvMYHNMIHKMIHHMIGgBCAvMQNVXZ0b0xxlGw8X
# /3IEybObuT6a5W1d61CW+cGD7zB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMAITMwAAAFtKtY1BMm3cdAAAAAAA
# WzAiBCA7NZmN9umxnpXglUKV0mBev8L/OElF2ITojQa733WISjANBgkqhkiG9w0B
# AQsFAASCAgA4nEvwmPPhelLBih9jC/ACvcy80xt8pWINka3VWRYHGjSEUe/00DNx
# 6JlV9tT3bUkbXsPnkTHEaUTDASI3WsvxB6T999kuM8IPKHEb4gBkk0eIC3Q+gJMo
# r5J/eUxqUTO78cLKLCo97+CfN+aMMbV0YPraGWVQveFB8AipsT2/dvbJ5SrjYXl/
# pSrXarKOgd6sxkTJAfnK33KSFULFgdYn8t4Fj7D8TOiteQSOj5Ch5MsBijuR9H/H
# 3z7lyxxqXYt+tY9/eNsgL5pHVDoR9Y4CCqPmW3Y+dii5z7UwWVKeyHXdJFxqkhN+
# TgAcqZgX+oL0ewFCF+5d2yAJf8hRoN27/R9yB4FfEtGt1/PMjBLUBqPjx3vIa3Is
# IQNVPFKnRrepEhiWTPiKkbGprMDugoEyVTllWEi2EgUUwwdVkhcsUTriVDS/kcSZ
# QcYCflhkri2n6uEartxPn8Jw1hQ4Byz8g7LszX2hj4x93VH3goYyt7zOKeu/4ZOE
# H+mb6zx9j0TmfWeXFTCdNUO/ozmTPTnhZcq4LmkRKvhYELMIFTUUz15HCMxGwT9k
# RpfatsYJFT26uevEwwVGZeH/LY5cIF086fzT14dw4xB6pKN+QP0nMoIuqbqFw2g4
# SQIC2QRab1HzwunQ1nYFSU3FVM3DtI0NxQZR8HJiydnzmrQ0JBmFsA==
# SIG # End signature block

#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Trigger - GitHub-native OSDCloud replacement entry point.

.DESCRIPTION
    One-liner entry point. Runs on any Windows PC.
    - Auto-installs the Windows ADK + WinPE add-on if missing.
    - Builds a custom boot image in pure PowerShell (no copype.cmd / cmd.exe).
      Always uses WinRE (Windows Recovery Environment) as the base WIM because WinRE
      ships with WiFi hardware drivers (Intel, Realtek, MediaTek, Qualcomm) that
      Microsoft bundles via Windows Update, enabling wireless connectivity on most
      laptops without manual driver injection. If the local WinRE has an architecture
      or version mismatch with the installed ADK, a fresh WinRE is obtained by
      downloading a Windows ISO, mounting it, and extracting WinRE.wim directly.
      Recovery-specific packages (startup repair, boot recovery) are stripped from
      WinRE and the WIM is re-exported with maximum compression to keep it small.
    - Injects Bootstrap.ps1 and winpeshl.ini into the image.
    - Creates a one-time BCD ramdisk boot entry (UEFI and BIOS aware).
    - Reboots into the cloud boot environment.

.PARAMETER GitHubUser
    GitHub account that hosts the AmpCloud repository. Default: araduti

.PARAMETER GitHubRepo
    Repository name. Default: AmpCloud

.PARAMETER GitHubBranch
    Branch to pull Bootstrap.ps1 from. Default: main

.PARAMETER WorkDir
    Root working directory for all artefacts. Default: C:\AmpCloud

.PARAMETER WindowsISOUrl
    Optional path to a local Windows ISO file, or an HTTPS URL to download one.
    Used when a WinRE architecture or version mismatch is detected and a fresh WinRE
    must be extracted. For amd64 a Windows Server 2025 Evaluation ISO is tried by
    default (free download, no authentication required). For arm64 and other
    architectures the URL must be supplied explicitly.

.PARAMETER NoReboot
    Build everything but do NOT reboot. Useful for testing.

.EXAMPLE
    irm https://raw.githubusercontent.com/araduti/AmpCloud/main/Trigger.ps1 | iex

.EXAMPLE
    .\Trigger.ps1 -NoReboot -WorkDir D:\AmpCloud

.EXAMPLE
    .\Trigger.ps1 -WindowsISOUrl 'D:\ISOs\Win11_ARM64.iso'
#>

[CmdletBinding()]
param(
    [string] $GitHubUser      = 'araduti',
    [string] $GitHubRepo      = 'AmpCloud',
    [string] $GitHubBranch    = 'main',
    [string] $WorkDir         = 'C:\AmpCloud',
    [string] $WindowsISOUrl   = '',
    [switch] $NoReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Derived paths ─ kept out of params to avoid user confusion
$script:WinPEWorkDir = Join-Path $WorkDir 'WinPE'
$script:RamdiskDir   = Join-Path $WorkDir 'Boot'

# Windows Image Architecture integer → ADK folder name mapping.
# Source: MSDN — ImageArchitecture enumeration used by Get-WindowsImage
# https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism/imagearchitecture-enumeration
#   0 = x86 | 5 = arm | 9 = amd64 | 12 = arm64
$script:WimArchIntMap = @{ 0 = 'x86'; 5 = 'arm'; 9 = 'amd64'; 12 = 'arm64' }

#region ── Logging ──────────────────────────────────────────────────────────────

function Write-Step    { param([string]$Message) Write-Host "`n  [>] $Message"  -ForegroundColor Cyan    }
function Write-Success { param([string]$Message) Write-Host "  [+] $Message"    -ForegroundColor Green   }
function Write-Warn    { param([string]$Message) Write-Host "  [!] $Message"    -ForegroundColor Yellow  }
function Write-Fail    { param([string]$Message) Write-Host "  [X] $Message"    -ForegroundColor Red     }

#endregion

#region ── Architecture Detection ───────────────────────────────────────────────

function Get-WinPEArchitecture {
    <#
    .SYNOPSIS
        Maps the current OS CPU architecture to the WinPE folder/package name
        used by the ADK (amd64, arm64, x86, arm).
    #>
    $map = @{
        'AMD64' = 'amd64'
        'ARM64' = 'arm64'
        'x86'   = 'x86'
        'ARM'   = 'arm'
    }
    $proc = $env:PROCESSOR_ARCHITECTURE   # AMD64 | ARM64 | x86 | ARM
    $arch = $map[$proc]
    if (-not $arch) {
        throw "Unrecognised PROCESSOR_ARCHITECTURE '$proc'. " +
              "Set -Architecture manually (amd64 | arm64 | x86 | arm)."
    }
    return $arch
}

#endregion

#region ── WinRE Discovery ──────────────────────────────────────────────────────

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
    $freeLetter = (68..90 |
        ForEach-Object { [char]$_ } |
        Where-Object   { -not (Test-Path "${_}:\") } |
        Select-Object -First 1)
    if (-not $freeLetter) {
        Write-Warn 'No free drive letter available to mount recovery partition.'
        return $null
    }

    $mountPoint = "${freeLetter}:\"
    $tempWim    = Join-Path $env:TEMP "ampcloud_winre_$([guid]::NewGuid().Guid).wim"
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

#endregion

#region ── Windows ISO → WinRE extraction ───────────────────────────────────────

function Get-WinREPathFromWindowsISO {
    <#
    .SYNOPSIS
        Downloads (when needed) a Windows ISO and extracts WinRE.wim from it.
    .DESCRIPTION
        When the machine's local WinRE.wim cannot be used — because its CPU
        architecture differs from the build target, or because its Windows build
        number is incompatible with the installed ADK package set — this function
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
        Target WinPE architecture string: amd64, arm64, x86, or arm.
    .PARAMETER ISOUrl
        Path to a local Windows ISO file, or an HTTPS URL to download one.
        Optional — a built-in default is tried for amd64 when omitted.
    .OUTPUTS  [string] Temp path to the extracted WinRE.wim.  The CALLER is
              responsible for deleting this file when it is no longer needed.
    #>
    param(
        [string] $Architecture,
        [string] $ISOUrl = ''
    )

    # ── Built-in default ISO download URLs ──────────────────────────────────────
    # Windows Server 2025 Evaluation (build 26100) is freely downloadable without
    # authentication and shares the same Windows build number as Windows 11 24H2,
    # making its WinRE compatible with the Windows 11 24H2 ADK package set.
    # No publicly available evaluation ISO exists for arm64 or x86 — users must
    # supply -WindowsISOUrl for those architectures.
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
                    throw ("No Windows ISO is available for architecture '$Architecture' " +
                           "by default. Provide -WindowsISOUrl pointing to a Windows ISO " +
                           "file or download URL (e.g. the Windows 11 $Architecture ISO " +
                           "from https://www.microsoft.com/software-download/windows11).")
                }
                Write-Step "Using built-in default ISO URL for $Architecture..."
            }

            $isoPath = Join-Path $env:TEMP `
                "ampcloud_win_iso_${Architecture}_$([System.Guid]::NewGuid().ToString('N')).iso"
            Write-Step ('Downloading Windows ISO for ' + $Architecture +
                        ' — this file is several GB and may take a while...')
            try {
                Invoke-WebRequest -Uri $ISOUrl -OutFile $isoPath -UseBasicParsing `
                                  -TimeoutSec 7200   # 2-hour ceiling for large ISOs
            } catch {
                throw ("Failed to download Windows ISO from '$ISOUrl': $_`n" +
                       'Tip: download the ISO manually and re-run with ' +
                       "-WindowsISOUrl '<path-to-iso>'.")
            }
            Write-Success 'Windows ISO downloaded.'
            $isoDownloaded = $true
        }

        # ── Step 2: Mount the ISO ────────────────────────────────────────────────
        Write-Step 'Mounting Windows ISO...'
        Mount-DiskImage -ImagePath $isoPath | Out-Null
        $isoMounted     = $true
        $isoDriveLetter = (Get-DiskImage -ImagePath $isoPath |
                            Get-Partition | Get-Volume |
                            Select-Object -First 1 -ExpandProperty DriveLetter)
        if (-not $isoDriveLetter) {
            throw ('Could not determine the drive letter of the mounted ISO. ' +
                   'The file may be corrupted or not a valid Windows ISO.')
        }
        $isoDrive = "${isoDriveLetter}:\"

        # ── Step 3: Locate the Windows installation image ─────────────────────────
        $installWim = Join-Path $isoDrive 'sources\install.wim'
        $installEsd = Join-Path $isoDrive 'sources\install.esd'
        $wimPath = if     (Test-Path $installWim) { $installWim }
                   elseif (Test-Path $installEsd) { $installEsd }
                   else {
                       throw ('Could not find sources\install.wim or sources\install.esd ' +
                              "on the mounted ISO at $isoDrive")
                   }

        # ── Step 4: Mount the installation image read-only (first index) ──────────
        $wimMountDir = Join-Path $env:TEMP `
            "ampcloud_iso_wim_$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $wimMountDir -Force | Out-Null
        $imageIndex = (Get-WindowsImage -ImagePath $wimPath |
                        Select-Object -First 1 -ExpandProperty ImageIndex)
        if (-not $imageIndex) {
            throw "Could not read any image index from '$wimPath' — the file may be corrupted."
        }
        Write-Step ("Mounting $(Split-Path $wimPath -Leaf) " +
                    "(index $imageIndex — read-only)...")
        Mount-WindowsImage -ImagePath $wimPath -Index $imageIndex `
                           -Path $wimMountDir -ReadOnly | Out-Null

        # ── Step 5: Copy WinRE.wim out of the installation image ──────────────────
        $winreSrc = Join-Path $wimMountDir 'Windows\System32\Recovery\WinRE.wim'
        if (-not (Test-Path $winreSrc)) {
            throw "WinRE.wim not found inside the mounted Windows image at: $winreSrc"
        }
        $winreDest = Join-Path $env:TEMP `
            "ampcloud_iso_winre_$([System.Guid]::NewGuid().ToString('N')).wim"
        Write-Step 'Copying WinRE.wim from Windows installation image...'
        Copy-Item $winreSrc $winreDest -Force
        Write-Success 'WinRE.wim extracted from Windows ISO.'
        return $winreDest

    } finally {
        # Clean up in reverse order; every step is always attempted.
        if ($wimMountDir -and (Test-Path $wimMountDir)) {
            Dismount-WindowsImage -Path $wimMountDir -Discard `
                                  -ErrorAction SilentlyContinue | Out-Null
            Remove-Item $wimMountDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($isoMounted) {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
        }
        if ($isoDownloaded -and $isoPath -and (Test-Path $isoPath)) {
            Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region ── ADK Detection + Install ──────────────────────────────────────────────

function Get-ADKRoot {
    <#
    .SYNOPSIS Returns the ADK installation root from the registry, or $null.
    #>
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    )
    foreach ($rp in $regPaths) {
        if (Test-Path $rp) {
            $val = (Get-ItemProperty $rp -ErrorAction SilentlyContinue).KitsRoot10
            if ($val -and (Test-Path $val)) {
                return $val.TrimEnd('\')
            }
        }
    }
    return $null
}

function Assert-ADKInstalled {
    <#
    .SYNOPSIS Ensures ADK + WinPE add-on are present. Installs them silently if not.
    .PARAMETER Architecture  WinPE arch string (amd64, arm64, x86, arm).
    .OUTPUTS  [string] Validated ADK root path.
    #>
    param([string] $Architecture)

    Write-Step "Checking Windows ADK + WinPE add-on ($Architecture)..."

    $adkRoot  = Get-ADKRoot
    $winPEDir = if ($adkRoot) {
        Join-Path $adkRoot 'Assessment and Deployment Kit\Windows Preinstallation Environment'
    } else { $null }

    if ($adkRoot -and $winPEDir -and (Test-Path (Join-Path $winPEDir $Architecture))) {
        Write-Success "ADK found: $adkRoot"
        return $adkRoot
    }

    Write-Warn 'ADK or WinPE add-on not found — downloading installers...'

    $installRoot = "${env:ProgramFiles(x86)}\Windows Kits\10"
    $downloads   = @(
        [pscustomobject]@{
            Label = 'ADK (Deployment Tools)'
            Uri   = 'https://go.microsoft.com/fwlink/?linkid=2196127'
            Out   = (Join-Path $env:TEMP 'adksetup.exe')
            Args  = "/quiet /installpath `"$installRoot`" /features OptionId.DeploymentTools"
        }
        [pscustomobject]@{
            Label = 'WinPE add-on'
            Uri   = 'https://go.microsoft.com/fwlink/?linkid=2196224'
            Out   = (Join-Path $env:TEMP 'adkwinpesetup.exe')
            Args  = "/quiet /installpath `"$installRoot`" /features OptionId.WindowsPreinstallationEnvironment"
        }
    )

    foreach ($d in $downloads) {
        Write-Step "Downloading $($d.Label)..."
        Invoke-WebRequest -Uri $d.Uri -OutFile $d.Out -UseBasicParsing
    }

    foreach ($d in $downloads) {
        Write-Step "Installing $($d.Label)..."
        $proc = Start-Process -FilePath $d.Out -ArgumentList $d.Args -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -notin 0, 3010) {
            throw "$($d.Label) installer exited with code $($proc.ExitCode)."
        }
    }

    $adkRoot = Get-ADKRoot
    if (-not $adkRoot) {
        throw 'ADK installation succeeded but registry path was not found. Try running again.'
    }

    Write-Success "ADK installed: $adkRoot"
    return $adkRoot
}

#endregion

#region ── copype — Pure PowerShell ─────────────────────────────────────────────

function Copy-WinPEFiles {
    <#
    .SYNOPSIS
        Pure-PowerShell replacement for copype.cmd.
        Creates the standard WinPE working directory structure.
    .PARAMETER ADKRoot     ADK installation root returned by Get-ADKRoot / Assert-ADKInstalled.
    .PARAMETER Destination Target working directory (will be wiped if it exists).
    .PARAMETER Architecture  amd64 (default), x86, arm, arm64.
    .OUTPUTS   [hashtable] Keys: MediaDir, MountDir, BootWim
    #>
    param(
        [string] $ADKRoot,
        [string] $Destination,
        [ValidateSet('amd64','x86','arm','arm64')]
        [string] $Architecture = 'amd64',
        [string] $WimSource    = ''   # Optional: path to an existing WIM (e.g. winre.wim)
    )

    Write-Step "Creating WinPE workspace ($Architecture) → $Destination"

    $winPERoot  = Join-Path $ADKRoot 'Assessment and Deployment Kit\Windows Preinstallation Environment'
    $archSrcDir = Join-Path $winPERoot $Architecture
    $mediaSrc   = Join-Path $archSrcDir 'Media'

    if (-not (Test-Path $archSrcDir)) {
        throw "WinPE source not found for '$Architecture': $archSrcDir"
    }
    if (-not (Test-Path $mediaSrc)) {
        throw "WinPE Media directory not found: $mediaSrc"
    }

    # Use the provided WIM source if given (e.g. winre.wim); otherwise locate winpe.wim
    if ($WimSource -and (Test-Path $WimSource)) {
        $wimSrc = $WimSource
        Write-Step "Using provided WIM source: $(Split-Path $wimSrc -Leaf)"
    } else {
        # Locate winpe.wim — some ADK layouts store it under the arch subdir, others at the root
        $wimCandidates = @(
            (Join-Path $winPERoot "$Architecture\en-us\winpe.wim"),
            (Join-Path $winPERoot 'en-us\winpe.wim')
        )
        $wimSrc = $wimCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $wimSrc) {
            throw "winpe.wim not found. Checked:`n    $($wimCandidates -join "`n    ")"
        }
    }

    # Build directory tree
    $mediaDir   = Join-Path $Destination 'media'
    $mountDir   = Join-Path $Destination 'mount'
    $sourcesDir = Join-Path $mediaDir    'sources'

    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $mediaDir, $mountDir, $sourcesDir -Force | Out-Null

    # Mirror the arch Media tree (EFI, bootmgr, fonts, resources …)
    Write-Step 'Copying WinPE media files...'
    Copy-Item -Path "$mediaSrc\*" -Destination $mediaDir -Recurse -Force

    # Place boot.wim, strip read-only attribute set by the ADK
    $bootWim = Join-Path $sourcesDir 'boot.wim'
    Copy-Item -Path $wimSrc -Destination $bootWim -Force
    Set-ItemProperty -Path $bootWim -Name IsReadOnly -Value $false

    Write-Success 'WinPE workspace created.'
    return @{ MediaDir = $mediaDir; MountDir = $mountDir; BootWim = $bootWim }
}

#endregion

#region ── WinPE Customisation ──────────────────────────────────────────────────

# Packages to inject — order matters (language packs must follow their base cab)
$script:WinPEPackages = @(
    'WinPE-WMI.cab',             'en-us\WinPE-WMI_en-us.cab',
    'WinPE-NetFX.cab',           'en-us\WinPE-NetFX_en-us.cab',
    'WinPE-Scripting.cab',       'en-us\WinPE-Scripting_en-us.cab',
    'WinPE-PowerShell.cab',      'en-us\WinPE-PowerShell_en-us.cab',
    'WinPE-SecureStartup.cab',   'en-us\WinPE-SecureStartup_en-us.cab',
    'WinPE-Dot3Svc.cab',         'en-us\WinPE-Dot3Svc_en-us.cab',
    'WinPE-WiFi-Package.cab',    'en-us\WinPE-WiFi-Package_en-us.cab',
    'WinPE-StorageWMI.cab',      'en-us\WinPE-StorageWMI_en-us.cab',
    'WinPE-DismCmdlets.cab',     'en-us\WinPE-DismCmdlets_en-us.cab'
)

function Remove-WinRERecoveryPackages {
    <#
    .SYNOPSIS
        Removes WinRE-specific recovery tools from a mounted WinRE image to
        reduce the final WIM size.
    .DESCRIPTION
        WinRE ships with startup-repair, boot-recovery, and other tools that are
        useful for OS recovery but are not needed when the image is used purely as
        a cloud deployment environment. Removing them shrinks the image by roughly
        100–200 MB before the final compression step.

        Packages matching the following name prefixes are removed:
          - Microsoft-Windows-WinRE-RecoveryAgent   (startup repair agent)
          - Microsoft-Windows-WinRE-BootRecovery    (boot recovery tools)
          - Microsoft-Windows-RecoveryDrive          (recovery drive creator)

        WiFi, networking, and scripting packages are intentionally preserved.
        Each removal is attempted individually so that dependency errors on one
        package do not block removal of the others.
    .PARAMETER MountDir  Path to the mounted WIM image.
    #>
    param([string] $MountDir)

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
            Remove-WindowsPackage -Path $MountDir -PackageName $name `
                                  -NoRestart -ErrorAction Stop | Out-Null
            Write-Success "Removed: $name"
        } catch {
            Write-Warn "Could not remove $name (non-fatal): $_"
        }
    }
}

function Build-WinPE {
    <#
    .SYNOPSIS  Builds a fully customised WinRE boot image ready for ramdisk boot.
    .DESCRIPTION
        Always uses WinRE as the base WIM.  When the machine's local WinRE cannot
        be used (architecture mismatch or ADK package version mismatch), a fresh
        WinRE is obtained by calling Get-WinREPathFromWindowsISO, which downloads
        a Windows ISO, mounts it, and extracts WinRE.wim.
    .OUTPUTS   [hashtable] Keys: MediaDir, MountDir, BootWim
    #>
    param(
        [string] $ADKRoot,
        [string] $WorkDir,
        [string] $Architecture,
        [string] $GitHubUser,
        [string] $GitHubRepo,
        [string] $GitHubBranch,
        [string] $WindowsISOUrl  = '',   # User-supplied ISO path or URL for WinRE extraction
        [string] $_ISOWinREPath  = ''    # Internal — pre-extracted ISO WinRE path (retry only)
    )

    # Preserve the caller-supplied architecture.  On a retry the recursive call
    # always passes the original host architecture so the ISO WinRE, the ADK
    # media files, and the package set are all guaranteed to be consistent.
    $originalArchitecture = $Architecture

    # ── 0. Locate WinRE base image ────────────────────────────────────────────────
    # WinRE ships with WiFi hardware drivers (Intel, Realtek, MediaTek, Qualcomm)
    # that Microsoft delivers via Windows Update, enabling wireless on most laptops.

    # $wimSourceToDelete tracks any temp WIM file that must be removed once
    # Copy-WinPEFiles has finished (it copies the file into the workspace).
    $wimSourceToDelete = $null

    if ($_ISOWinREPath) {
        # ── Retry path: use the WinRE pre-extracted from a Windows ISO ───────────
        Write-Warn 'Using WinRE extracted from Windows ISO (fresh copy).'
        $winrePath   = $_ISOWinREPath
        $usingWinRE  = $true
        $wimSourceToDelete = $_ISOWinREPath   # clean up after Copy-WinPEFiles
    } else {
        # ── First attempt: try the machine's local WinRE ─────────────────────────
        Write-Step 'Locating WinRE.wim to use as base image (built-in WiFi drivers)...'
        $localWinRE  = Get-WinREPath
        $usingWinRE  = $false
        $winrePath   = $null

        if ($localWinRE) {
            # ── Detect the WIM's actual architecture ─────────────────────────────
            # Uses the script-level $script:WimArchIntMap (defined at the top of
            # this file) to translate the DISM Architecture integer to an ADK folder
            # name.  Applying ADK packages for arch A to a WIM built for arch B
            # fails with 0x800f081e (CBS_E_NOT_APPLICABLE).  If the WIM arch differs
            # from the target arch, discard this WinRE and fetch the correct one.
            $wimArch = $null
            try {
                $wimInfo = Get-WindowsImage -ImagePath $localWinRE -Index 1 -ErrorAction Stop
                $archInt = $wimInfo.Architecture -as [int]
                if ($null -eq $archInt) {
                    Write-Warn ("WinRE image returned a non-integer Architecture value " +
                                "('$($wimInfo.Architecture)') — skipping arch check.")
                } else {
                    $wimArch = $script:WimArchIntMap[$archInt]
                    if (-not $wimArch) {
                        Write-Warn ("Unrecognized WinRE image architecture value " +
                                    "($archInt) — skipping arch check.")
                    }
                }
            } catch {
                Write-Warn "Could not read WinRE image metadata: $_"
            }

            if ($wimArch -and $wimArch -ne $Architecture) {
                # Architecture mismatch — clean up the local temp WinRE (if any)
                # and obtain a correct-arch WinRE from a Windows ISO instead.
                Write-Warn ("Local WinRE is $wimArch but the build target is $Architecture. " +
                            'Fetching a fresh WinRE from a Windows ISO...')
                if ($localWinRE -like "$env:TEMP\*") {
                    Remove-Item $localWinRE -Force -ErrorAction SilentlyContinue
                }
                $winrePath         = Get-WinREPathFromWindowsISO -Architecture $Architecture `
                                                                  -ISOUrl $WindowsISOUrl
                $usingWinRE        = $true
                $wimSourceToDelete = $winrePath
            } else {
                # Architecture matches — use the local WinRE directly.
                Write-Success 'WinRE found — WiFi hardware drivers will be available in the boot image.'
                $winrePath = $localWinRE
                $usingWinRE = $true
                if ($localWinRE -like "$env:TEMP\*") {
                    $wimSourceToDelete = $localWinRE
                }
            }
        } else {
            Write-Warn ('WinRE.wim not found on this machine. ' +
                        'Fetching WinRE from a Windows ISO...')
            $winrePath         = Get-WinREPathFromWindowsISO -Architecture $Architecture `
                                                              -ISOUrl $WindowsISOUrl
            $usingWinRE        = $true
            $wimSourceToDelete = $winrePath
        }
    }

    # ── 1. Create workspace ──────────────────────────────────────────────────
    try {
        $paths = Copy-WinPEFiles -ADKRoot $ADKRoot -Destination $WorkDir `
                                 -Architecture $Architecture -WimSource $winrePath
    } finally {
        # Release the temp WinRE file once Copy-WinPEFiles has copied it into the
        # workspace.  This covers all temp sources: recovery-partition copies,
        # ISO-extracted WinRE files, and retry-path pre-extracted WinREs.
        if ($wimSourceToDelete -and (Test-Path $wimSourceToDelete)) {
            Remove-Item $wimSourceToDelete -Force -ErrorAction SilentlyContinue
        }
    }

    # ── 2. Mount ─────────────────────────────────────────────────────────────
    Write-Step 'Mounting boot.wim...'
    Mount-WindowsImage -ImagePath $paths.BootWim -Index 1 -Path $paths.MountDir | Out-Null

    $retryWithISOWinRE = $false   # set to $true inside the try if version mismatch detected
    try {
        # ── 3. Slim WinRE by removing recovery tools (not needed for deployment) ──
        if ($usingWinRE) {
            Remove-WinRERecoveryPackages -MountDir $paths.MountDir
        }

        # ── 4. Inject optional components ────────────────────────────────────
        $pkgRoot = Join-Path $ADKRoot `
            "Assessment and Deployment Kit\Windows Preinstallation Environment\$Architecture\WinPE_OCs"

        foreach ($pkg in $script:WinPEPackages) {
            $pkgPath = Join-Path $pkgRoot $pkg
            if (-not (Test-Path $pkgPath)) {
                Write-Warn "Package not found, skipping: $pkg"
                continue
            }
            Write-Step "Adding package: $pkg"
            try {
                Add-WindowsPackage -Path $paths.MountDir -PackagePath $pkgPath | Out-Null
            } catch {
                # Package may already be present in the WinRE base image (expected)
                # or there may be a version mismatch with the ADK (non-fatal warning).
                Write-Warn "Package $pkg skipped (already in base image or version mismatch): $_"
            }
        }

        # ── 4b. Inject VirtIO network driver (netkvm) ───────────────────────
        # QEMU-based VMs (e.g. UTM on macOS) present a VirtIO network adapter.
        # WinPE/WinRE has no VirtIO driver by default, so the adapter is invisible
        # and networking never starts.  The pre-extracted netkvm driver files live
        # in Drivers/NetKVM/w10/<arch>/ in the repo — fetched directly from GitHub,
        # no ISO download required.
        # The repo subfolder names match virtio-win convention: amd64, x86, ARM64.
        $virtioArchMap = @{ amd64 = 'amd64'; x86 = 'x86'; arm64 = 'ARM64' }
        $virtioArch    = $virtioArchMap[$Architecture]
        if ($virtioArch) {
            $driverRepoPath = "Drivers/NetKVM/w10/$virtioArch"
            $apiUrl         = "https://api.github.com/repos/$GitHubUser/$GitHubRepo/contents/$driverRepoPath`?ref=$GitHubBranch"
            $driverTmpDir   = Join-Path $env:TEMP "ampcloud_netkvm_$([System.Guid]::NewGuid().ToString('N'))"
            Write-Step "Fetching VirtIO netkvm driver from repo ($driverRepoPath)..."
            try {
                $fileList = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
                New-Item -ItemType Directory -Path $driverTmpDir -Force | Out-Null
                foreach ($entry in $fileList) {
                    if ($entry.type -eq 'file' -and $entry.download_url) {
                        $dest = Join-Path $driverTmpDir $entry.name
                        Invoke-WebRequest -Uri $entry.download_url -OutFile $dest -UseBasicParsing -ErrorAction Stop
                    }
                }
                Add-WindowsDriver -Path $paths.MountDir -Driver $driverTmpDir -Recurse | Out-Null
                Write-Success 'VirtIO network driver (netkvm) injected.'
            } catch {
                Write-Warn "Could not inject VirtIO network driver (non-fatal): $_"
            } finally {
                Remove-Item $driverTmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Warn "VirtIO network driver not available for architecture '$Architecture' — skipping."
        }

        # ── 5. Embed Bootstrap.ps1 ────────────────────────────────────────────
        $bootstrapUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/Bootstrap.ps1"
        $bootstrapDest = Join-Path $paths.MountDir 'Windows\System32\Bootstrap.ps1'
        Write-Step "Fetching Bootstrap.ps1 from $bootstrapUrl"
        Invoke-WebRequest -Uri $bootstrapUrl -OutFile $bootstrapDest -UseBasicParsing

        # ── 5b. Pre-stage AmpCloud.ps1 ──────────────────────────────────────
        # Embedding AmpCloud.ps1 eliminates the internet dependency at boot time.
        # Bootstrap.ps1 will use this local copy instead of downloading it.
        $ampCloudUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/AmpCloud.ps1"
        $ampCloudDest = Join-Path $paths.MountDir 'Windows\System32\AmpCloud.ps1'
        Write-Step "Fetching AmpCloud.ps1 from $ampCloudUrl"
        Invoke-WebRequest -Uri $ampCloudUrl -OutFile $ampCloudDest -UseBasicParsing

        # ── 6. winpeshl.ini + batch launcher → auto-launch Bootstrap.ps1 ───────
        # WinRE ships its own winpeshl.exe which does not reliably handle the
        # comma-separated "<exe>, <args>" format used for direct PowerShell
        # invocation.  Routing through cmd.exe /k avoids that parsing difference:
        # winpeshl.ini always succeeds (cmd.exe is a guaranteed WinPE binary),
        # and the helper batch file handles the PowerShell invocation directly.
        #
        # -NoExit keeps the PowerShell host alive after Bootstrap.ps1 exits
        # (normally or via error), preventing an unintended reboot.
        # -Command with & invokes Bootstrap.ps1 as a child script so that any
        # exit call inside it exits only that script, not the PowerShell host.
        # X:\ is the ramdisk root in every WinPE / WinRE environment.

        # Verify PowerShell is present in the image before committing.
        $psBinPath = Join-Path $paths.MountDir `
            'Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $psBinPath)) {
            if ($usingWinRE -and -not $_ISOWinREPath) {
                # WinPE-PowerShell.cab could not be applied to this WinRE because the
                # ADK package set targets a different Windows build.  Set a flag so
                # the catch block can discard this attempt, obtain a fresh WinRE from
                # a Windows ISO (guaranteed to be the correct build), and retry.
                # The $_ISOWinREPath guard means the retry path (where $_ISOWinREPath
                # is set) takes the hard-error branch below — one retry maximum.
                $retryWithISOWinRE = $true
                throw 'PowerShell not found in WinRE image — ADK / WinRE version mismatch.'
            }
            throw ('PowerShell executable not found in the mounted image ' +
                   '(Windows\System32\WindowsPowerShell\v1.0\powershell.exe). ' +
                   'Ensure WinPE-PowerShell.cab is compatible with the base WIM.')
        }

        $launcherPath = Join-Path $paths.MountDir 'Windows\System32\ampcloud-start.cmd'
        @'
@echo off
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& X:\Windows\System32\Bootstrap.ps1"
'@ | Set-Content -Path $launcherPath -Encoding Ascii

        $winpeshlPath = Join-Path $paths.MountDir 'Windows\System32\winpeshl.ini'
        @'
[LaunchApps]
X:\Windows\System32\cmd.exe, /k X:\Windows\System32\ampcloud-start.cmd
'@ | Set-Content -Path $winpeshlPath -Encoding Ascii

    } catch {
        # Always clean up a dangling mount on failure
        Write-Warn 'Customisation failed — discarding mounted image to avoid corruption.'
        Dismount-WindowsImage -Path $paths.MountDir -Discard -ErrorAction SilentlyContinue | Out-Null

        # ── WinRE / ADK version mismatch — fetch fresh WinRE from Windows ISO ──────
        # WinPE-PowerShell.cab could not be applied because the ADK package set
        # targets a different Windows build than the local WinRE.  Obtain a fresh
        # WinRE by downloading a Windows ISO, mounting it, and extracting WinRE.wim.
        # The ISO WinRE is always a valid WinRE; its build may still not match the
        # ADK perfectly, but since we are now on the second attempt the hard error
        # path is taken if PowerShell is still absent.
        if ($retryWithISOWinRE) {
            Write-Warn ('WinPE-PowerShell.cab is not compatible with the local WinRE image ' +
                        '(ADK / WinRE version mismatch). ' +
                        'Fetching a fresh WinRE from a Windows ISO and retrying...')
            $freshWinRE = Get-WinREPathFromWindowsISO -Architecture $originalArchitecture `
                                                       -ISOUrl $WindowsISOUrl
            if (Test-Path $WorkDir) {
                Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            return Build-WinPE -ADKRoot $ADKRoot -WorkDir $WorkDir `
                               -Architecture $originalArchitecture `
                               -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo `
                               -GitHubBranch $GitHubBranch `
                               -WindowsISOUrl $WindowsISOUrl `
                               -_ISOWinREPath $freshWinRE
        }

        throw
    }

    # ── 7. Commit & unmount ───────────────────────────────────────────────────
    Write-Step 'Committing and unmounting image...'
    Dismount-WindowsImage -Path $paths.MountDir -Save | Out-Null

    # ── 8. Re-export with maximum compression to reduce WIM size ─────────────
    # Maximum compression can shrink WinRE by 100–200 MB compared to the default
    # compression used inside winre.wim. This keeps the ramdisk footprint small.
    # Safety pattern: rename original to .bak before promoting the slim WIM so
    # that a Move-Item failure can be recovered without losing boot.wim.
    Write-Step 'Re-exporting image with maximum compression (this may take a few minutes)...'
    $slimWim = $paths.BootWim + '.slim'
    $bakWim  = $paths.BootWim + '.bak'
    try {
        Export-WindowsImage -SourceImagePath $paths.BootWim -SourceIndex 1 `
                            -DestinationImagePath $slimWim -CompressionType max | Out-Null
        # Rename original as .bak (same filesystem — atomic rename)
        Move-Item $paths.BootWim $bakWim  -Force -ErrorAction Stop
        # Promote slim WIM to final path
        Move-Item $slimWim $paths.BootWim -Force -ErrorAction Stop
        Remove-Item $bakWim -Force -ErrorAction SilentlyContinue
        Write-Success 'Image compressed and finalised.'
    } catch {
        Write-Warn "Image compression failed (non-fatal, original WIM kept): $_"
        # If the original was renamed to .bak but the slim WIM was not yet promoted,
        # restore the backup so the build remains usable.
        if ((Test-Path $bakWim) -and -not (Test-Path $paths.BootWim)) {
            Move-Item $bakWim $paths.BootWim -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $slimWim -Force -ErrorAction SilentlyContinue
        Remove-Item $bakWim  -Force -ErrorAction SilentlyContinue
    }

    Write-Success 'Boot image built successfully.'
    return $paths
}

#endregion

#region ── BCD Ramdisk ──────────────────────────────────────────────────────────

function Invoke-Bcdedit {
    <#
    .SYNOPSIS  Thin wrapper around bcdedit.exe with strict error checking.
    #>
    param([string[]] $Arguments)
    $output = & bcdedit.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit $($Arguments -join ' ') → exit $LASTEXITCODE`n$output"
    }
    return $output
}

function New-BcdEntry {
    <#
    .SYNOPSIS  Creates a BCD entry and returns its GUID string, e.g. {abc123…}.
    #>
    param([string[]] $CreateArgs)
    $output = Invoke-Bcdedit $CreateArgs
    if ($output -match '\{([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\}') {
        return "{$($Matches[1])}"
    }
    throw "Could not parse GUID from bcdedit output: $output"
}

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
    } catch { <# key or property absent — fall through #> }

    # Fallback: Confirm-SecureBootUEFI throws PlatformNotSupportedException on BIOS
    try {
        $null = Confirm-SecureBootUEFI   # $true (SB on) or $false (SB off) on UEFI
        return 'UEFI'
    } catch [System.PlatformNotSupportedException] {
        return 'BIOS'
    } catch {
        Write-Warn "Confirm-SecureBootUEFI failed ($($_.Exception.Message)) — assuming BIOS."
    }

    return 'BIOS'
}

function New-BCDRamdiskEntry {
    <#
    .SYNOPSIS  Stages boot files and creates a one-time BCD ramdisk boot entry.
    .OUTPUTS   [string] OS loader GUID.
    #>
    param(
        [string] $BootWim,
        [string] $RamdiskDir,
        [string] $MediaDir
    )

    Write-Step 'Staging ramdisk boot files...'

    # Ensure output directory
    New-Item -ItemType Directory -Path $RamdiskDir -Force | Out-Null

    # Copy boot.sdi (required by the BCD ramdisk device)
    $sdiSrc  = Join-Path $MediaDir 'boot\boot.sdi'
    $sdiDest = Join-Path $RamdiskDir 'boot.sdi'
    if (Test-Path $sdiSrc) {
        Copy-Item $sdiSrc $sdiDest -Force
        Write-Success "boot.sdi staged."
    } else {
        Write-Warn "boot.sdi not found at $sdiSrc — ramdisk boot will likely fail."
    }

    # Copy WIM
    $wimDest = Join-Path $RamdiskDir 'boot.wim'
    Copy-Item $BootWim $wimDest -Force
    Write-Success "boot.wim staged."

    # BCD path components
    $drive  = Split-Path $RamdiskDir -Qualifier          # C:
    $relDir = (Split-Path $RamdiskDir -NoQualifier).TrimEnd('\') # \AmpCloud\Boot
    $wimBcd = "$relDir\boot.wim"
    $sdiBcd = "$relDir\boot.sdi"

    Write-Step 'Writing BCD entries...'

    # ── Ramdisk device options ────────────────────────────────────────────────
    $rdGuid = New-BcdEntry '/create', '/d', 'AmpCloud Ramdisk Options', '/device'
    Invoke-Bcdedit '/set', $rdGuid, 'ramdisksdidevice', "partition=$drive" | Out-Null
    Invoke-Bcdedit '/set', $rdGuid, 'ramdisksdipath',   $sdiBcd             | Out-Null
    Write-Success "Ramdisk options: $rdGuid"

    # ── OS loader ─────────────────────────────────────────────────────────────
    $fw      = Get-FirmwareType
    $winload = if ($fw -eq 'UEFI') { '\windows\system32\winload.efi' } `
                                   else { '\windows\system32\winload.exe' }
    Write-Step "Firmware type: $fw  →  $winload"

    $ramdiskVal = "[$drive]$wimBcd,$rdGuid"
    $osGuid     = New-BcdEntry '/create', '/d', 'AmpCloud Boot', '/application', 'osloader'

    Invoke-Bcdedit '/set', $osGuid, 'device',     "ramdisk=$ramdiskVal" | Out-Null
    Invoke-Bcdedit '/set', $osGuid, 'osdevice',   "ramdisk=$ramdiskVal" | Out-Null
    Invoke-Bcdedit '/set', $osGuid, 'path',       $winload               | Out-Null
    Invoke-Bcdedit '/set', $osGuid, 'systemroot', '\windows'             | Out-Null
    Invoke-Bcdedit '/set', $osGuid, 'detecthal',  'yes'                  | Out-Null
    Invoke-Bcdedit '/set', $osGuid, 'winpe',      'yes'                  | Out-Null
    Invoke-Bcdedit '/set', $osGuid, 'nx',         'OptIn'                | Out-Null
    Invoke-Bcdedit '/set', $osGuid, 'ems',        'no'                   | Out-Null

    # Add to menu and arm as one-time next boot
    Invoke-Bcdedit '/displayorder', $osGuid, '/addlast' | Out-Null
    Invoke-Bcdedit '/bootsequence', $osGuid             | Out-Null

    Write-Success "OS loader entry: $osGuid (armed as one-time next boot)"
    return $osGuid
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

 GitHub-native OSDCloud replacement  ·  https://github.com/$GitHubUser/$GitHubRepo
"@ -ForegroundColor Cyan

try {
    # ── 0. Detect architecture ────────────────────────────────────────────────
    $arch = Get-WinPEArchitecture
    Write-Step "Host architecture: $arch"

    # ── 1. ADK ────────────────────────────────────────────────────────────────
    $adkRoot = Assert-ADKInstalled -Architecture $arch

    # ── 2. Boot image (WinRE preferred, WinPE fallback) ──────────────────────
    $paths = Build-WinPE `
        -ADKRoot        $adkRoot `
        -WorkDir        $script:WinPEWorkDir `
        -Architecture   $arch `
        -GitHubUser     $GitHubUser `
        -GitHubRepo     $GitHubRepo `
        -GitHubBranch   $GitHubBranch `
        -WindowsISOUrl  $WindowsISOUrl

    # ── 3. BCD ────────────────────────────────────────────────────────────────
    New-BCDRamdiskEntry `
        -BootWim    $paths.BootWim `
        -RamdiskDir $script:RamdiskDir `
        -MediaDir   $paths.MediaDir

    Write-Host "`n  [AmpCloud] All done — system is primed for cloud boot." -ForegroundColor Green

    if (-not $NoReboot) {
        Write-Host '  [AmpCloud] Rebooting in 10 seconds ... Press Ctrl+C to cancel.' `
            -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    } else {
        Write-Host '  [AmpCloud] -NoReboot specified. Reboot manually to enter the boot environment.' `
            -ForegroundColor Yellow
    }

} catch {
    Write-Fail "Fatal: $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    exit 1
}

#endregion

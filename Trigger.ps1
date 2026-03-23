#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Trigger - GitHub-native OSDCloud replacement entry point.

.DESCRIPTION
    One-liner entry point. Runs on any Windows PC.
    - Auto-installs the Windows ADK + WinPE add-on if missing.
    - Builds a custom WinPE image in pure PowerShell (no copype.cmd / cmd.exe).
    - Injects Bootstrap.ps1 and winpeshl.ini into the image.
    - Creates a one-time BCD ramdisk boot entry (UEFI and BIOS aware).
    - Reboots into cloud WinPE.

.PARAMETER GitHubUser
    GitHub account that hosts the AmpCloud repository. Default: araduti

.PARAMETER GitHubRepo
    Repository name. Default: AmpCloud

.PARAMETER GitHubBranch
    Branch to pull Bootstrap.ps1 from. Default: main

.PARAMETER WorkDir
    Root working directory for all artefacts. Default: C:\AmpCloud

.PARAMETER NoReboot
    Build everything but do NOT reboot. Useful for testing.

.EXAMPLE
    irm https://raw.githubusercontent.com/araduti/AmpCloud/main/Trigger.ps1 | iex

.EXAMPLE
    .\Trigger.ps1 -NoReboot -WorkDir D:\AmpCloud
#>

[CmdletBinding()]
param(
    [string] $GitHubUser   = 'araduti',
    [string] $GitHubRepo   = 'AmpCloud',
    [string] $GitHubBranch = 'main',
    [string] $WorkDir      = 'C:\AmpCloud',
    [switch] $NoReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Derived paths ─ kept out of params to avoid user confusion
$script:WinPEWorkDir = Join-Path $WorkDir 'WinPE'
$script:RamdiskDir   = Join-Path $WorkDir 'Boot'

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
        [string] $Architecture = 'amd64'
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

    # Locate winpe.wim — some ADK layouts store it under the arch subdir, others at the root
    $wimCandidates = @(
        (Join-Path $winPERoot "$Architecture\en-us\winpe.wim"),
        (Join-Path $winPERoot 'en-us\winpe.wim')
    )
    $wimSrc = $wimCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $wimSrc) {
        throw "winpe.wim not found. Checked:`n    $($wimCandidates -join "`n    ")"
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
    'WinPE-Dot3Svc.cab',         'en-us\WinPE-Dot3Svc_en-us.cab',
    'WinPE-WiFi-Package.cab',    'en-us\WinPE-WiFi-Package_en-us.cab',
    'WinPE-StorageWMI.cab',      'en-us\WinPE-StorageWMI_en-us.cab',
    'WinPE-DismCmdlets.cab',     'en-us\WinPE-DismCmdlets_en-us.cab'
)

function Build-WinPE {
    <#
    .SYNOPSIS  Builds a fully customised WinPE image ready for ramdisk boot.
    .OUTPUTS   [hashtable] Keys: MediaDir, MountDir, BootWim
    #>
    param(
        [string] $ADKRoot,
        [string] $WorkDir,
        [string] $Architecture,
        [string] $GitHubUser,
        [string] $GitHubRepo,
        [string] $GitHubBranch
    )

    # ── 1. Create workspace ──────────────────────────────────────────────────
    $paths = Copy-WinPEFiles -ADKRoot $ADKRoot -Destination $WorkDir -Architecture $Architecture

    # ── 2. Mount ─────────────────────────────────────────────────────────────
    Write-Step 'Mounting boot.wim...'
    Mount-WindowsImage -ImagePath $paths.BootWim -Index 1 -Path $paths.MountDir | Out-Null

    try {
        # ── 3. Inject optional components ────────────────────────────────────
        $pkgRoot = Join-Path $ADKRoot `
            "Assessment and Deployment Kit\Windows Preinstallation Environment\$Architecture\WinPE_OCs"

        foreach ($pkg in $script:WinPEPackages) {
            $pkgPath = Join-Path $pkgRoot $pkg
            if (Test-Path $pkgPath) {
                Write-Step "Adding package: $pkg"
                Add-WindowsPackage -Path $paths.MountDir -PackagePath $pkgPath | Out-Null
            } else {
                Write-Warn "Package not found, skipping: $pkg"
            }
        }

        # ── 3b. Inject VirtIO network driver (netkvm) ────────────────────────
        # QEMU-based VMs (e.g. UTM on macOS) present a VirtIO network adapter.
        # WinPE has no VirtIO driver by default, so the adapter is invisible and
        # networking never starts.  We download the official virtio-win ISO from
        # the Fedora People mirror, mount it, and add the netkvm driver to the image.
        # virtio-win uses 'amd64', 'x86', and 'ARM64' as subfolder names.
        $virtioArchMap = @{ amd64 = 'amd64'; x86 = 'x86'; arm64 = 'ARM64' }
        $virtioArch    = $virtioArchMap[$Architecture]
        if ($virtioArch) {
            $virtioIso = Join-Path $env:TEMP 'virtio-win.iso'
            $virtioUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'
            Write-Step 'Downloading VirtIO drivers for QEMU/UTM network support (~500 MB)...'
            try {
                Invoke-WebRequest -Uri $virtioUrl -OutFile $virtioIso -UseBasicParsing -TimeoutSec 1800
                Write-Step 'Mounting VirtIO ISO and injecting netkvm network driver...'
                $diskImage   = Mount-DiskImage -ImagePath $virtioIso -PassThru
                $driveLetter = ($diskImage | Get-Volume).DriveLetter
                try {
                    $netkvmPath = "${driveLetter}:\NetKVM\w10\$virtioArch"
                    if (Test-Path $netkvmPath) {
                        Add-WindowsDriver -Path $paths.MountDir -Driver $netkvmPath -Recurse | Out-Null
                        Write-Success 'VirtIO network driver (netkvm) injected.'
                    } else {
                        Write-Warn "VirtIO netkvm driver path not found in ISO: $netkvmPath"
                    }
                } finally {
                    Dismount-DiskImage -ImagePath $virtioIso | Out-Null
                }
            } catch {
                Write-Warn "Could not inject VirtIO network driver (non-fatal): $_"
            } finally {
                Remove-Item $virtioIso -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Warn "VirtIO network driver not available for architecture '$Architecture' — skipping."
        }

        # ── 4. Embed Bootstrap.ps1 ────────────────────────────────────────────
        $bootstrapUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/Bootstrap.ps1"
        $bootstrapDest = Join-Path $paths.MountDir 'Windows\System32\Bootstrap.ps1'
        Write-Step "Fetching Bootstrap.ps1 from $bootstrapUrl"
        Invoke-WebRequest -Uri $bootstrapUrl -OutFile $bootstrapDest -UseBasicParsing

        # ── 4b. Pre-stage AmpCloud.ps1 ───────────────────────────────────────
        # Embedding AmpCloud.ps1 eliminates the internet dependency at boot time.
        # Bootstrap.ps1 will use this local copy instead of downloading it.
        $ampCloudUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/AmpCloud.ps1"
        $ampCloudDest = Join-Path $paths.MountDir 'Windows\System32\AmpCloud.ps1'
        Write-Step "Fetching AmpCloud.ps1 from $ampCloudUrl"
        Invoke-WebRequest -Uri $ampCloudUrl -OutFile $ampCloudDest -UseBasicParsing

        # ── 5. winpeshl.ini → auto-launch Bootstrap.ps1 ───────────────────────
        # -NoExit keeps the PowerShell host alive after Bootstrap.ps1 exits
        # (normally or via error), preventing an unintended WinPE reboot.
        # -Command with & invokes Bootstrap.ps1 as a child script so that any
        # exit call inside it exits only that script, not the PowerShell host.
        $winpeshlPath = Join-Path $paths.MountDir 'Windows\System32\winpeshl.ini'
        @'
[LaunchApps]
%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe, -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& $env:SystemRoot\System32\Bootstrap.ps1"
'@ | Set-Content -Path $winpeshlPath -Encoding Ascii

    } catch {
        # Always clean up a dangling mount on failure
        Write-Warn 'Customisation failed — discarding mounted image to avoid corruption.'
        Dismount-WindowsImage -Path $paths.MountDir -Discard -ErrorAction SilentlyContinue | Out-Null
        throw
    }

    # ── 6. Commit & unmount ───────────────────────────────────────────────────
    Write-Step 'Committing and unmounting image...'
    Dismount-WindowsImage -Path $paths.MountDir -Save | Out-Null

    Write-Success 'WinPE image built successfully.'
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
    $osGuid     = New-BcdEntry '/create', '/d', 'AmpCloud WinPE', '/application', 'osloader'

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

    # ── 2. WinPE ──────────────────────────────────────────────────────────────
    $paths = Build-WinPE `
        -ADKRoot      $adkRoot `
        -WorkDir      $script:WinPEWorkDir `
        -Architecture $arch `
        -GitHubUser   $GitHubUser `
        -GitHubRepo   $GitHubRepo `
        -GitHubBranch $GitHubBranch

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
        Write-Host '  [AmpCloud] -NoReboot specified. Reboot manually to enter WinPE.' `
            -ForegroundColor Yellow
    }

} catch {
    Write-Fail "Fatal: $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    exit 1
}

#endregion

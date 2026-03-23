#Requires -RunAsAdministrator
<#
.SYNOPSIS
    AmpCloud Trigger - GitHub-native OSDCloud replacement entry point.

.DESCRIPTION
    One-liner entrypoint. Runs on any Windows PC. Auto-downloads/installs latest
    ADK + WinPE add-on if missing, builds custom WinPE, injects Bootstrap.ps1 +
    winpeshl.ini, creates BCD ramdisk entry, then reboots into cloud boot.

.EXAMPLE
    irm https://raw.githubusercontent.com/araduti/AmpCloud/main/Trigger.ps1 | iex
#>

[CmdletBinding()]
param(
    [string]$GitHubUser    = 'araduti',
    [string]$GitHubRepo    = 'AmpCloud',
    [string]$GitHubBranch  = 'main',
    [string]$WinPEWorkDir  = 'C:\AmpCloud\WinPE',
    [string]$RamdiskVHD    = 'C:\AmpCloud\boot.vhd',
    [string]$ADKInstallPath = 'C:\Program Files (x86)\Windows Kits\10',
    [switch]$NoReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Test-CommandExists {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-ADKInstallPath {
    $adkRegPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    )
    foreach ($path in $adkRegPaths) {
        if (Test-Path $path) {
            $val = (Get-ItemProperty $path -ErrorAction SilentlyContinue).KitsRoot10
            if ($val -and (Test-Path $val)) { return $val.TrimEnd('\') }
        }
    }
    return $null
}

function Install-ADKIfMissing {
    Write-Step 'Checking Windows ADK installation...'

    $adkPath = Get-ADKInstallPath
    $adkPEPath = if ($adkPath) { Join-Path $adkPath 'Assessment and Deployment Kit\Windows Preinstallation Environment' } else { $null }

    if ($adkPath -and $adkPEPath -and (Test-Path $adkPEPath)) {
        Write-Success "ADK found at: $adkPath"
        return $adkPath
    }

    Write-Warn 'ADK or WinPE add-on not found. Downloading installer...'

    $adkSetup    = Join-Path $env:TEMP 'adksetup.exe'
    $adkPESetup  = Join-Path $env:TEMP 'adkwinpesetup.exe'

    $adkUrl   = 'https://go.microsoft.com/fwlink/?linkid=2196127'
    $adkPEUrl = 'https://go.microsoft.com/fwlink/?linkid=2196224'

    Write-Step 'Downloading ADK...'
    Invoke-WebRequest -Uri $adkUrl   -OutFile $adkSetup   -UseBasicParsing
    Write-Step 'Downloading WinPE add-on...'
    Invoke-WebRequest -Uri $adkPEUrl -OutFile $adkPESetup -UseBasicParsing

    Write-Step 'Installing ADK (Deployment Tools)...'
    Start-Process -FilePath $adkSetup -ArgumentList "/quiet /installpath `"$ADKInstallPath`" /features OptionId.DeploymentTools" -Wait -NoNewWindow

    Write-Step 'Installing WinPE add-on...'
    Start-Process -FilePath $adkPESetup -ArgumentList "/quiet /installpath `"$ADKInstallPath`" /features OptionId.WindowsPreinstallationEnvironment" -Wait -NoNewWindow

    $adkPath = Get-ADKInstallPath
    if (-not $adkPath) { throw 'ADK installation failed or path not detected.' }

    Write-Success 'ADK + WinPE add-on installed successfully.'
    return $adkPath
}

#endregion

#region ── WinPE Build ──────────────────────────────────────────────────────────

function Build-WinPE {
    param(
        [string]$ADKPath,
        [string]$WorkDir,
        [string]$GitHubUser,
        [string]$GitHubRepo,
        [string]$GitHubBranch
    )

    Write-Step 'Building custom WinPE...'

    # ── Pre-flight validation ────────────────────────────────────────────────
    $adkBase  = Join-Path $ADKPath 'Assessment and Deployment Kit'
    $winPEDir = Join-Path $adkBase 'Windows Preinstallation Environment'
    $deployToolsDir = Join-Path $adkBase 'Deployment Tools'

    # Locate DandISetEnv.bat – the ADK environment initializer that sets
    # WinPERoot, DISMRoot and the Oscdimg paths copype.cmd relies on.
    $dandISetEnv = Join-Path $deployToolsDir 'DandISetEnv.bat'
    if (-not (Test-Path $dandISetEnv)) {
        throw "ADK Deployment Tools environment script not found at: $dandISetEnv`nPlease reinstall the ADK Deployment Tools feature."
    }

    # Locate copype.cmd
    $copype = Join-Path $winPEDir 'copype.cmd'
    if (-not (Test-Path $copype)) {
        throw "copype.cmd not found at: $copype`nPlease reinstall the WinPE add-on."
    }

    # Verify WinPE source files exist for the target architecture
    $winPEArch = Join-Path $winPEDir 'amd64'
    if (-not (Test-Path $winPEArch)) {
        throw "WinPE amd64 source files not found at: $winPEArch`nPlease reinstall the WinPE add-on."
    }

    # Verify oscdimg.exe is available (copype.cmd needs it for firmware files)
    $oscdimg = Join-Path $deployToolsDir 'amd64\Oscdimg\oscdimg.exe'
    if (-not (Test-Path $oscdimg)) {
        throw "oscdimg.exe not found at: $oscdimg`nPlease reinstall the ADK Deployment Tools feature."
    }

    # ── Build WinPE workspace ────────────────────────────────────────────────

    # Clean existing work directory (copype.cmd creates its own target directory)
    if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }

    # Run DandISetEnv.bat first in the same cmd session so copype.cmd inherits
    # all required ADK environment variables (WinPERoot, Oscdimg paths, etc.).
    # Use 'call' so batch files return control within the cmd chain, and so the
    # command string starts with 'call' instead of a quote character — cmd.exe /c
    # strips the first and last quote when the string begins with one, which
    # breaks paths that contain spaces (e.g. "Program Files (x86)").
    # Temporarily lower ErrorActionPreference so stderr output from batch files
    # is not converted to a terminating PowerShell error.
    Write-Step "Running copype to create WinPE workspace at: $WorkDir"
    $prevEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = & cmd.exe /c "call `"$dandISetEnv`" && call `"$copype`" amd64 `"$WorkDir`"" 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) { throw "copype.cmd failed: $result" }

    # Mount WinPE WIM
    $mountDir = Join-Path $WorkDir 'mount'
    $wimPath  = Join-Path $WorkDir 'media\sources\boot.wim'
    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

    Write-Step 'Mounting WinPE WIM...'
    Mount-WindowsImage -ImagePath $wimPath -Index 1 -Path $mountDir | Out-Null

    # Inject optional components: WMI, PowerShell
    $pkgDir = Join-Path $winPEDir 'amd64\WinPE_OCs'
    $packages = @(
        'WinPE-WMI.cab',
        'en-us\WinPE-WMI_en-us.cab',
        'WinPE-NetFX.cab',
        'en-us\WinPE-NetFX_en-us.cab',
        'WinPE-Scripting.cab',
        'en-us\WinPE-Scripting_en-us.cab',
        'WinPE-PowerShell.cab',
        'en-us\WinPE-PowerShell_en-us.cab',
        'WinPE-StorageWMI.cab',
        'en-us\WinPE-StorageWMI_en-us.cab',
        'WinPE-DismCmdlets.cab',
        'en-us\WinPE-DismCmdlets_en-us.cab'
    )

    foreach ($pkg in $packages) {
        $pkgPath = Join-Path $pkgDir $pkg
        if (Test-Path $pkgPath) {
            Write-Step "Adding package: $pkg"
            Add-WindowsPackage -Path $mountDir -PackagePath $pkgPath | Out-Null
        } else {
            Write-Warn "Package not found, skipping: $pkg"
        }
    }

    # Create Bootstrap.ps1 inside WinPE
    $bootstrapRaw = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/Bootstrap.ps1"
    $bootstrapDest = Join-Path $mountDir 'Windows\System32\Bootstrap.ps1'
    Write-Step "Embedding Bootstrap.ps1 (fetching from $bootstrapRaw)..."
    Invoke-WebRequest -Uri $bootstrapRaw -OutFile $bootstrapDest -UseBasicParsing

    # Create winpeshl.ini to auto-launch Bootstrap.ps1
    $winpeshlPath = Join-Path $mountDir 'Windows\System32\winpeshl.ini'
    $winpeshlContent = @"
[LaunchApps]
%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe, -NoProfile -ExecutionPolicy Bypass -File %SYSTEMROOT%\System32\Bootstrap.ps1
"@
    Set-Content -Path $winpeshlPath -Value $winpeshlContent -Encoding Ascii

    Write-Step 'Unmounting and committing WinPE image...'
    Dismount-WindowsImage -Path $mountDir -Save | Out-Null

    Write-Success 'WinPE image built successfully.'
    return $wimPath
}

#endregion

#region ── BCD Ramdisk ──────────────────────────────────────────────────────────

function New-BCDRamdiskEntry {
    param(
        [string]$WimPath,
        [string]$RamdiskVHD,
        [string]$WorkDir
    )

    Write-Step 'Creating BCD ramdisk boot entry...'

    $mediaDir = Join-Path $WorkDir 'media'

    # Determine destination directory from the RamdiskVHD parameter
    $ramdiskDir = Split-Path $RamdiskVHD

    # Derive the drive letter from the ramdisk directory for BCD paths
    $ramdiskDrive = Split-Path $ramdiskDir -Qualifier
    # Relative path inside the ramdisk drive (e.g. \AmpCloud)
    $ramdiskRelDir = (Split-Path $ramdiskDir -NoQualifier).TrimEnd('\')

    # Create the ramdisk BCD entry
    # 1. Create a new boot entry (ramdisk)
    $guid = [System.Guid]::NewGuid().ToString('B').ToUpper()

    # Use bcdedit to create the ramdisk entry
    $bcdeditCmds = @(
        "bcdedit /create $guid /d `"AmpCloud WinPE`" /application osloader",
        "bcdedit /set $guid device ramdisk=[$ramdiskDrive]$ramdiskRelDir\boot.wim,{ramdiskoptions}",
        "bcdedit /set $guid osdevice ramdisk=[$ramdiskDrive]$ramdiskRelDir\boot.wim,{ramdiskoptions}",
        "bcdedit /set $guid path \Windows\System32\winload.exe",
        "bcdedit /set $guid systemroot \Windows",
        "bcdedit /set $guid detecthal yes",
        "bcdedit /set $guid winpe yes",
        "bcdedit /set $guid ems no"
    )

    # Create ramdisk options entry
    $rdGuid = [System.Guid]::NewGuid().ToString('B').ToUpper()
    $rdCmds = @(
        "bcdedit /create $rdGuid /d `"AmpCloud Ramdisk`" /device",
        "bcdedit /set $rdGuid ramdisksdidevice partition=$ramdiskDrive",
        "bcdedit /set $rdGuid ramdisksdipath $ramdiskRelDir\boot.sdi"
    )

    # Ensure ramdisk directory exists
    if (-not (Test-Path $ramdiskDir)) { New-Item -ItemType Directory -Path $ramdiskDir -Force | Out-Null }

    $sdiSource = Join-Path $mediaDir 'boot\boot.sdi'
    $sdiDest   = Join-Path $ramdiskDir 'boot.sdi'
    if (Test-Path $sdiSource) {
        Copy-Item $sdiSource $sdiDest -Force
        Write-Success "Copied boot.sdi to $sdiDest"
    } else {
        Write-Warn "boot.sdi not found at $sdiSource – ramdisk boot may not work."
    }

    # Copy WIM to destination
    $wimDest = Join-Path $ramdiskDir 'boot.wim'
    Copy-Item $WimPath $wimDest -Force

    # Run BCD commands
    foreach ($cmd in $rdCmds) {
        Write-Step "Running: $cmd"
        $out = & cmd.exe /c $cmd 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warn "BCD command returned non-zero: $out" }
    }

    # Replace placeholder with real ramdisk options GUID
    $bcdeditCmds = $bcdeditCmds | ForEach-Object { $_ -replace '\{ramdiskoptions\}', $rdGuid }

    foreach ($cmd in $bcdeditCmds) {
        Write-Step "Running: $cmd"
        $out = & cmd.exe /c $cmd 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warn "BCD command returned non-zero: $out" }
    }

    # Add the entry to the boot menu and set it as next boot
    & cmd.exe /c "bcdedit /displayorder $guid /addlast" 2>&1 | Out-Null
    & cmd.exe /c "bcdedit /bootsequence $guid" 2>&1 | Out-Null

    Write-Success "BCD ramdisk entry created: $guid"
    return $guid
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

 GitHub-native OSDCloud replacement | https://github.com/$GitHubUser/$GitHubRepo
"@ -ForegroundColor Cyan

# Verify elevation
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must be run as Administrator.'
}

try {
    # Step 1: Install ADK if missing
    $adkPath = Install-ADKIfMissing

    # Step 2: Build WinPE
    $wimPath = Build-WinPE `
        -ADKPath       $adkPath `
        -WorkDir       $WinPEWorkDir `
        -GitHubUser    $GitHubUser `
        -GitHubRepo    $GitHubRepo `
        -GitHubBranch  $GitHubBranch

    # Step 3: Create BCD ramdisk entry
    New-BCDRamdiskEntry `
        -WimPath    $wimPath `
        -RamdiskVHD $RamdiskVHD `
        -WorkDir    $WinPEWorkDir

    Write-Host "`n[AmpCloud] All done! System is prepared for cloud boot." -ForegroundColor Green

    if (-not $NoReboot) {
        Write-Host '[AmpCloud] Rebooting into AmpCloud WinPE in 10 seconds... Press Ctrl+C to cancel.' -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    } else {
        Write-Host '[AmpCloud] -NoReboot specified. Reboot manually to start WinPE.' -ForegroundColor Yellow
    }
} catch {
    Write-Host "`n[AmpCloud] ERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    exit 1
}

#endregion

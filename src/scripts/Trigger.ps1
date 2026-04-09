# Scriptblock wrapper -- allows iex (irm ...) to parse [CmdletBinding()] + param().
& {
#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $GitHubUser      = 'araduti',
    [ValidateNotNullOrEmpty()]
    [string] $GitHubRepo      = 'Nova',
    [ValidateNotNullOrEmpty()]
    [string] $GitHubBranch    = 'main',
    [ValidateNotNullOrEmpty()]
    [string] $WorkDir         = 'C:\Nova',
    [string] $WindowsISOUrl   = '',
    [switch] $NoReboot,
    [switch] $AcceptDefaults
)

<#
.SYNOPSIS
    Nova Trigger - GitHub-native OSDCloud replacement entry point.

.DESCRIPTION
    One-liner entry point. Runs on any Windows PC.
    - Auto-installs the Windows ADK + WinPE add-on if missing.
    - Presents an interactive configuration menu (preselected with sensible
      defaults) that lets OSD admins choose which ADK packages, language packs,
      and drivers to include in the boot image before building.
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
    GitHub account that hosts the Nova repository. Default: araduti

.PARAMETER GitHubRepo
    Repository name. Default: Nova

.PARAMETER GitHubBranch
    Branch to pull Bootstrap.ps1 from. Default: main

.PARAMETER WorkDir
    Root working directory for all artefacts. Default: C:\Nova

.PARAMETER WindowsISOUrl
    Optional path to a local Windows ISO file, or an HTTPS URL to download one.
    Used when a WinRE architecture or version mismatch is detected and a fresh WinRE
    must be extracted. For amd64 a Windows Server 2025 Evaluation ISO is tried by
    default (free download, no authentication required). For x86 the URL must be
    supplied explicitly. ARM is not supported.

.PARAMETER NoReboot
    Build everything but do NOT reboot. Useful for testing.

.PARAMETER AcceptDefaults
    Skip all interactive menus and use default settings. Useful for CI/CD
    pipelines and scripted deployments. When set, the cloud image is
    preferred (if available), and the build configuration uses all default
    packages with en-us language.

.EXAMPLE
    irm https://raw.githubusercontent.com/araduti/Nova/main/Trigger.ps1 | iex

.EXAMPLE
    .\Trigger.ps1 -NoReboot -WorkDir D:\Nova

.EXAMPLE
    .\Trigger.ps1 -WindowsISOUrl 'D:\ISOs\Win11_x86.iso'

.EXAMPLE
    .\Trigger.ps1 -AcceptDefaults -NoReboot
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Derived paths ─ kept out of params to avoid user confusion
$script:WinPEWorkDir = Join-Path $WorkDir 'WinPE'
$script:RamdiskDir   = Join-Path $WorkDir 'Boot'

# Windows Image Architecture integer → ADK folder name mapping.
# Source: MSDN -- ImageArchitecture enumeration used by Get-WindowsImage
# https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism/imagearchitecture-enumeration
#   0 = x86 | 5 = arm | 9 = amd64 | 12 = arm64
$script:WimArchIntMap = @{ 0 = 'x86'; 5 = 'arm'; 9 = 'amd64'; 12 = 'arm64' }

# Bypass the WinINet HTTP cache for all raw.githubusercontent.com downloads.
# Without this, Invoke-WebRequest / Invoke-RestMethod may serve stale content
# from %LOCALAPPDATA%\Microsoft\Windows\INetCache for up to 300 s (the
# Cache-Control max-age returned by GitHub).  This caused failures on devices
# that had previously fetched unsigned script versions.
$script:NoCacheHeaders = @{ 'Cache-Control' = 'no-cache' }

# ── Import shared modules ──────────────────────────────────────────────────────
$script:ModulesRoot = if ($PSScriptRoot -and (Test-Path "$PSScriptRoot\..\modules")) {
    "$PSScriptRoot\..\modules"
} elseif (Test-Path 'X:\Windows\System32\Modules') {
    'X:\Windows\System32\Modules'
} elseif (-not $PSScriptRoot) {
    # iex (irm ...) scenario -- $PSScriptRoot is empty; download modules to temp dir
    $tmpModRoot = Join-Path ([System.IO.Path]::GetTempPath()) "Nova-Modules-$(Get-Random)"
    $moduleNames = @('Nova.Logging', 'Nova.Platform', 'Nova.Integrity', 'Nova.WinRE',
                     'Nova.ADK', 'Nova.BuildConfig', 'Nova.Auth',
                     'Nova.BCD', 'Nova.CloudImage')
    $moduleExts  = @('.psm1', '.psd1')

    # ── Winget-style progress display ──────────────────────────────────────
    # Characters constructed from code points to avoid problematic UTF-8 bytes
    # (0x91-0x94 map to smart quotes in Windows-1252 and break PS 5.1 parsing).
    $_barFull  = [string][char]0x2588   # Full block
    $_barEmpty = [string][char]0x2591   # Light shade
    $_barWidth = 30
    $_total    = $moduleNames.Count
    $_done     = 0
    $_esc      = [char]0x1B
    $_vtOK     = ($null -ne $Host.UI.psobject.Properties['SupportsVirtualTerminal'] -and
                  $Host.UI.SupportsVirtualTerminal) -or $env:WT_SESSION

    if ($_vtOK) {
        # Header
        Write-Host ''
        Write-Host "  ${_esc}[36;1mDownloading Nova modules${_esc}[0m"
        Write-Host ''
        # Initial empty bar
        $_line = "  $($_barEmpty * $_barWidth)  0 / $_total"
        Write-Host $_line -NoNewline
    } else {
        Write-Host '  Downloading Nova modules...'
    }

    $prevProgressPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    foreach ($mod in $moduleNames) {
        $modDir = Join-Path $tmpModRoot $mod
        $null = New-Item -Path $modDir -ItemType Directory -Force
        foreach ($ext in $moduleExts) {
            $url  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/modules/$mod/$mod$ext"
            $dest = Join-Path $modDir "$mod$ext"
            try {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop
            } catch {
                $ProgressPreference = $prevProgressPref
                if ($_vtOK) { Write-Host '' }   # newline so error is not appended to bar
                throw "Failed to download module $mod$ext from $url -- $($_.Exception.Message)"
            }
        }
        $_done++
        if ($_vtOK) {
            $_filled = [math]::Floor(($_done / $_total) * $_barWidth)
            $_empty  = $_barWidth - $_filled
            $_pct    = [math]::Floor(($_done / $_total) * 100)
            $_bar    = ($_barFull * $_filled) + ($_barEmpty * $_empty)
            $_line   = "  $_bar  $_done / $_total  (${_pct}%)"
            Write-Host "`r$_line" -NoNewline
        }
    }

    $ProgressPreference = $prevProgressPref

    if ($_vtOK) {
        # Final complete bar
        $_bar  = $_barFull * $_barWidth
        $_line = "  $_bar  $_total / $_total  (100%)"
        Write-Host "`r$_line"
        Write-Host "  ${_esc}[32;1mAll modules downloaded.${_esc}[0m"
        Write-Host ''
    } else {
        Write-Host "  All modules downloaded."
    }

    $tmpModRoot
} else {
    "$PSScriptRoot\..\modules"   # Best-effort fallback
}

# ── Pre-import integrity verification (iex scenario) ──────────────────────────
# When modules were downloaded from GitHub (not from a local repo checkout),
# verify each file's SHA256 against hashes.json BEFORE importing any module.
# This prevents potentially tampered or corrupted code from being loaded into
# memory.  The check is inline (not using Confirm-FileIntegrity) because the
# Nova.Integrity module has not been imported yet.
if (-not $PSScriptRoot) {
    $_hashesUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/hashes.json"
    try {
        $_iexHashesJson = Invoke-RestMethod -Uri $_hashesUrl -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop -TimeoutSec 15
    } catch {
        Remove-Item $script:ModulesRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw "FATAL: Could not load integrity manifest from $_hashesUrl -- cannot verify module safety. Aborting."
    }

    $_integrityFailed = $false
    foreach ($mod in $moduleNames) {
        foreach ($ext in $moduleExts) {
            $modFile = Join-Path $script:ModulesRoot "$mod\$mod$ext"
            $relName = "src/modules/$mod/$mod$ext"
            if (-not (Test-Path $modFile)) { continue }

            $_expected = if ($_iexHashesJson.files.PSObject.Properties[$relName]) { $_iexHashesJson.files.$relName } else { $null }
            if (-not $_expected) {
                Write-Host "  [X] No hash entry for $relName in manifest." -ForegroundColor Red
                $_integrityFailed = $true
                continue
            }

            $_actual = (Get-FileHash -Path $modFile -Algorithm SHA256).Hash
            if ($_actual -eq $_expected) { continue }

            # CDN propagation retry -- re-download manifest once after a short delay
            Write-Host "  [!] Hash mismatch for $relName -- retrying in 5s (CDN propagation window)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
            try {
                $_iexHashesJson = Invoke-RestMethod -Uri $_hashesUrl -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop -TimeoutSec 15
            } catch {
                Remove-Item $script:ModulesRoot -Recurse -Force -ErrorAction SilentlyContinue
                throw "FATAL: Could not reload integrity manifest on retry -- aborting."
            }
            $_expected = if ($_iexHashesJson.files.PSObject.Properties[$relName]) { $_iexHashesJson.files.$relName } else { $null }
            if (-not $_expected -or $_actual -ne $_expected) {
                Write-Host "  [X] Integrity check FAILED for $relName (after retry)" -ForegroundColor Red
                Write-Host "    Expected: $_expected" -ForegroundColor Red
                Write-Host "    Actual:   $_actual" -ForegroundColor Red
                $_integrityFailed = $true
            }
        }
    }

    if ($_integrityFailed) {
        Remove-Item $script:ModulesRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw "FATAL: One or more modules failed integrity verification. " +
              "Downloaded modules have been removed. " +
              "This may indicate the hash manifest is out of date or the download was tampered with."
    }
    Write-Host '  [+] All modules passed integrity verification.' -ForegroundColor Green
}

Import-Module "$script:ModulesRoot\Nova.Logging"     -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Platform"    -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Integrity"   -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.WinRE"       -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.ADK"         -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.BuildConfig" -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Auth"        -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.BCD"         -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.CloudImage"  -Force -ErrorAction Stop
# Trigger.ps1 uses the default prefixes (  [>], [+], [!], [X])

# Confirm-FileIntegrity is now provided by the Nova.Integrity module.
# Get-WinPEArchitecture is now provided by the Nova.Platform module.

# Get-WinREPath and Get-WinREPathFromWindowsISO are now provided by the Nova.WinRE module.

#endregion

#region ── Remaining Functions ───────────────────────────────────────────────────

# Get-ADKRoot, Assert-ADKInstalled, and Copy-WinPEFile are now provided by the Nova.ADK module.

# Build configuration (language, packages, drivers, interactive menu) is now
# provided by the Nova.BuildConfig module.  The constants $DefaultLanguage,
# $LanguageOptions, $AvailableWinPEPackages, the ANSI escape sequences, and
# the VK_* key codes all live in that module now.

# ANSI escape sequences still needed by the remaining orchestration code.
$script:ESC      = [char]0x1B
$script:AnsiCyan  = "${script:ESC}[36;1m"
$script:AnsiReset = "${script:ESC}[0m"
$script:AnsiDim   = "${script:ESC}[90m"
$script:AnsiBold  = "${script:ESC}[1m"

# Spinner frames for long-running operations (Braille dot pattern).
$script:SpinnerFrames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')

function Invoke-WithSpinner {
    <#
    .SYNOPSIS  Runs a script block while displaying an animated spinner.
    .DESCRIPTION
        Executes the given script block in a background job and displays a
        rotating Braille-dot spinner on the current console line until the
        job completes. Falls back to a simple "..." message when the host
        does not support VT/ANSI sequences (e.g. ISE, redirected output).
    #>
    param(
        [Parameter(Mandatory)] [string]      $Message,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock
    )

    $supportsVT = ($null -ne $Host.UI.psobject.Properties['SupportsVirtualTerminal'] -and
                   $Host.UI.SupportsVirtualTerminal) -or $env:WT_SESSION
    if (-not $supportsVT) {
        Write-Step $Message
        & $ScriptBlock
        return
    }

    $job = Start-Job -ScriptBlock $ScriptBlock
    $frame = 0
    try {
        while ($job.State -eq 'Running') {
            $spin = $script:SpinnerFrames[$frame % $script:SpinnerFrames.Count]
            Write-Host "`r  ${script:AnsiCyan}$spin${script:AnsiReset} $Message" -NoNewline
            Start-Sleep -Milliseconds 80
            $frame++
        }
        Write-Host "`r  ${script:AnsiCyan}[>]${script:AnsiReset} $Message"
        Receive-Job $job -ErrorAction Stop
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
}

# Remove-WinRERecoveryPackage is now provided by the Nova.WinRE module.

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
        [string]   $ADKRoot,
        [string]   $WorkDir,
        [string]   $Architecture,
        [string]   $GitHubUser,
        [string]   $GitHubRepo,
        [string]   $GitHubBranch,
        [string]   $WindowsISOUrl     = '',           # User-supplied ISO path or URL for WinRE extraction
        [string]   $_ISOWinREPath     = '',           # Internal -- pre-extracted ISO WinRE path (retry only)
        [string]   $Language          = 'en-us',
        [string[]] $PackageNames      = @(),          # Selected package base names (from Show-BuildConfiguration)
        [string[]] $DriverPaths       = @()           # Local paths or URLs to driver folders/archives
    )

    # Suppress the default PowerShell progress bars from DISM cmdlets
    # (Mount-WindowsImage, Add-WindowsPackage, Add-WindowsDriver, etc.) so the
    # console stays clean.  The custom Write-Step / Write-Success messages
    # provide all the user feedback needed.
    $ProgressPreference = 'SilentlyContinue'

    # If no packages were specified, fall back to the required defaults so that
    # a direct call to Build-WinPE without Show-BuildConfiguration still works.
    if ($PackageNames.Count -eq 0) {
        $PackageNames = @(Get-AvailableWinPEPackages |
            Where-Object { $_.Default } | ForEach-Object { $_.Name })
    }

    # Preserve the caller-supplied architecture.  On a retry the recursive call
    # always passes the original host architecture so the ISO WinRE, the ADK
    # media files, and the package set are all guaranteed to be consistent.
    $originalArchitecture = $Architecture

    # ── 0. Locate WinRE base image ────────────────────────────────────────────────
    # WinRE ships with WiFi hardware drivers (Intel, Realtek, MediaTek, Qualcomm)
    # that Microsoft delivers via Windows Update, enabling wireless on most laptops.

    # $wimSourceToDelete tracks any temp WIM file that must be removed once
    # Copy-WinPEFile has finished (it copies the file into the workspace).
    $wimSourceToDelete = $null

    if ($_ISOWinREPath) {
        # ── Retry path: use the WinRE pre-extracted from a Windows ISO ───────────
        Write-Warn 'Using WinRE extracted from Windows ISO (fresh copy).'
        $winrePath   = $_ISOWinREPath
        $usingWinRE  = $true
        $wimSourceToDelete = $_ISOWinREPath   # clean up after Copy-WinPEFile
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
                    Write-Warn "WinRE image returned a non-integer Architecture value ('$($wimInfo.Architecture)') -- skipping arch check."
                } else {
                    $wimArch = $script:WimArchIntMap[$archInt]
                    if (-not $wimArch) {
                        Write-Warn "Unrecognized WinRE image architecture value ($archInt) -- skipping arch check."
                    }
                }
            } catch {
                Write-Warn "Could not read WinRE image metadata: $_"
            }

            if ($wimArch -and $wimArch -ne $Architecture) {
                # Architecture mismatch -- clean up the local temp WinRE (if any)
                # and obtain a correct-arch WinRE from a Windows ISO instead.
                Write-Warn "Local WinRE is $wimArch but the build target is $Architecture. Fetching a fresh WinRE from a Windows ISO..."
                if ($localWinRE -like "$env:TEMP\*") {
                    Remove-Item $localWinRE -Force -ErrorAction SilentlyContinue
                }
                $winrePath         = Get-WinREPathFromWindowsISO -Architecture $Architecture `
                                                                  -ISOUrl $WindowsISOUrl
                $usingWinRE        = $true
                $wimSourceToDelete = $winrePath
            } else {
                # Architecture matches -- use the local WinRE directly.
                Write-Success 'WinRE found -- WiFi hardware drivers will be available in the boot image.'
                $winrePath = $localWinRE
                $usingWinRE = $true
                if ($localWinRE -like "$env:TEMP\*") {
                    $wimSourceToDelete = $localWinRE
                }
            }
        } else {
            Write-Warn 'WinRE.wim not found on this machine. Fetching WinRE from a Windows ISO...'
            $winrePath         = Get-WinREPathFromWindowsISO -Architecture $Architecture `
                                                              -ISOUrl $WindowsISOUrl
            $usingWinRE        = $true
            $wimSourceToDelete = $winrePath
        }
    }

    # ── 1. Create workspace ──────────────────────────────────────────────────
    try {
        $paths = Copy-WinPEFile -ADKRoot $ADKRoot -Destination $WorkDir `
                                 -Architecture $Architecture -WimSource $winrePath
    } finally {
        # Release the temp WinRE file once Copy-WinPEFile has copied it into the
        # workspace.  This covers all temp sources: recovery-partition copies,
        # ISO-extracted WinRE files, and retry-path pre-extracted WinREs.
        if ($wimSourceToDelete -and (Test-Path $wimSourceToDelete)) {
            Remove-Item $wimSourceToDelete -Force -ErrorAction SilentlyContinue
        }
    }

    # ── 2. Mount ─────────────────────────────────────────────────────────────
    Write-Step 'Mounting boot.wim...'
    $null = Mount-WindowsImage -ImagePath $paths.BootWim -Index 1 -Path $paths.MountDir
    Write-Success 'boot.wim mounted.'

    $retryWithISOWinRE = $false   # set to $true inside the try if version mismatch detected
    try {
        # ── 3. Slim WinRE by removing recovery tools (not needed for deployment) ──
        if ($usingWinRE) {
            Remove-WinRERecoveryPackage -MountDir $paths.MountDir
        }

        # ── 4. Inject optional components ────────────────────────────────────
        $pkgRoot = Join-Path $ADKRoot `
            "Assessment and Deployment Kit\Windows Preinstallation Environment\$Architecture\WinPE_OCs"

        $resolvedPkgPaths = Resolve-WinPEPackagePath -PackageNames $PackageNames -Language $Language
        foreach ($pkg in $resolvedPkgPaths) {
            $pkgPath = Join-Path $pkgRoot $pkg
            if (-not (Test-Path $pkgPath)) {
                Write-Warn "Package not found, skipping: $pkgPath"
                continue
            }
            Write-Step "Adding package: $pkg"
            try {
                $null = Add-WindowsPackage -Path $paths.MountDir -PackagePath $pkgPath
                Write-Success "Package added: $pkg"
            } catch {
                # Package may already be present in the WinRE base image (expected)
                # or there may be a version mismatch with the ADK (non-fatal warning).
                Write-Warn "Package $pkg skipped (already in base image or version mismatch): $_"
            }
        }

        # ── 4b. Inject user-supplied WinPE drivers (local paths and URLs) ───
        foreach ($drvEntry in $DriverPaths) {
            if ($drvEntry -match '^https?://') {
                # Download driver archive from URL
                $driverTmpDir = Join-Path $env:TEMP "nova_drv_$([System.Guid]::NewGuid().ToString('N'))"
                Write-Step "Downloading drivers from: $drvEntry"
                try {
                    $null = New-Item -ItemType Directory -Path $driverTmpDir -Force
                    $fileName = [System.IO.Path]::GetFileName(([System.Uri]$drvEntry).LocalPath)
                    if (-not $fileName) { $fileName = 'driver_download' }
                    $downloadPath = Join-Path $driverTmpDir $fileName
                    Invoke-WebRequest -Uri $drvEntry -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop

                    # Extract if the download is a zip or cab archive
                    $extractDir = $driverTmpDir
                    if ($downloadPath -match '\.(zip)$') {
                        $extractDir = Join-Path $driverTmpDir 'extracted'
                        $null = New-Item -ItemType Directory -Path $extractDir -Force
                        Expand-Archive -Path $downloadPath -DestinationPath $extractDir -Force
                    } elseif ($downloadPath -match '\.(cab)$') {
                        $extractDir = Join-Path $driverTmpDir 'extracted'
                        $null = New-Item -ItemType Directory -Path $extractDir -Force
                        $null = & expand.exe $downloadPath -F:* $extractDir
                    }

                    $null = Add-WindowsDriver -Path $paths.MountDir -Driver $extractDir -Recurse
                    Write-Success "Drivers injected from URL: $drvEntry"
                } catch {
                    Write-Warn "Could not inject drivers from URL '$drvEntry' (non-fatal): $_"
                } finally {
                    Remove-Item $driverTmpDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                # Local or UNC path
                Write-Step "Injecting drivers from: $drvEntry"
                if (-not (Test-Path $drvEntry)) {
                    Write-Warn "Driver path not found, skipping: $drvEntry"
                    continue
                }
                try {
                    $null = Add-WindowsDriver -Path $paths.MountDir -Driver $drvEntry -Recurse
                    Write-Success "Drivers injected from: $drvEntry"
                } catch {
                    Write-Warn "Could not inject drivers from '$drvEntry' (non-fatal): $_"
                }
            }
        }

        # ── 4c. Inject Segoe MDL2 Assets font for UI icons ─────────────────
        # WinPE does not ship Segoe MDL2 Assets, so icons render as garbled text.
        # Copy the font from the local system (any Win 10/11 machine has it) into
        # the offline image and register it in the offline SOFTWARE hive so GDI+
        # can use it at boot time.  If the local file is missing, download the
        # official Segoe font package from Microsoft as a fallback.
        $mdl2Name     = 'segmdl2.ttf'
        $mdl2Local    = Join-Path $env:SystemRoot "Fonts\$mdl2Name"
        $mdl2FontDest = Join-Path $paths.MountDir "Windows\Fonts\$mdl2Name"
        $fontInjected = $false
        if (Test-Path $mdl2Local) {
            Write-Step "Copying Segoe MDL2 Assets from local system..."
            try {
                $fontDir = Split-Path $mdl2FontDest
                if (-not (Test-Path $fontDir)) {
                    $null = New-Item -ItemType Directory -Path $fontDir -Force
                }
                # The mounted WinPE image may have restrictive ACLs on
                # Windows\Fonts.  Grant the current user full control so
                # the copy succeeds without "Access is denied" errors.
                try {
                    $null = & takeown.exe /F $fontDir /A 2>&1
                    $null = & icacls.exe $fontDir /grant "${env:USERNAME}:(OI)(CI)F" /T /Q 2>&1
                } catch {
                    # ACL failures are non-fatal; the outer catch handles any real copy error.
                    $null = $_.Exception
                }
                Copy-Item -Path $mdl2Local -Destination $mdl2FontDest -Force -ErrorAction Stop
                $fontInjected = $true
            } catch {
                Write-Warn "Local font copy failed (non-fatal -- icons will use GDI+ shapes): $_"
            }
        } else {
            Write-Step 'Segoe MDL2 Assets not found locally; downloading from https://aka.ms/SegoeFonts...'
            $fontGuid = [System.Guid]::NewGuid().ToString('N')
            $fontZip = Join-Path $env:TEMP "SegoeFont_${fontGuid}.zip"
            $fontTmp = Join-Path $env:TEMP "SegoeFont_${fontGuid}"
            try {
                Invoke-WebRequest -Uri 'https://aka.ms/SegoeFonts' -OutFile $fontZip -UseBasicParsing -ErrorAction Stop
                Expand-Archive -Path $fontZip -DestinationPath $fontTmp -Force
                $mdl2File = Get-ChildItem -Path $fontTmp -Filter $mdl2Name -Recurse -File | Select-Object -First 1
                if ($mdl2File) {
                    $fontDir = Split-Path $mdl2FontDest
                    if (-not (Test-Path $fontDir)) {
                        $null = New-Item -ItemType Directory -Path $fontDir -Force
                    }
                    Copy-Item -Path $mdl2File.FullName -Destination $mdl2FontDest -Force
                    $fontInjected = $true
                } else {
                    Write-Warn "segmdl2.ttf not found inside the downloaded Segoe font package."
                }
            } catch {
                Write-Warn "Font download failed (non-fatal -- icons will use GDI+ shapes): $_"
            } finally {
                Remove-Item $fontZip -Force -ErrorAction SilentlyContinue
                Remove-Item $fontTmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($fontInjected) {
            # Register font in the offline registry so GDI+ resolves the family name.
            $hivePath = Join-Path $paths.MountDir 'Windows\System32\config\SOFTWARE'
            $hiveKey  = 'PE_FONTS'
            try {
                $null = & reg.exe load "HKLM\$hiveKey" $hivePath 2>&1
                $null = & reg.exe add  "HKLM\$hiveKey\Microsoft\Windows NT\CurrentVersion\Fonts" `
                             /v 'Segoe MDL2 Assets (TrueType)' /t REG_SZ /d $mdl2Name /f 2>&1
                Write-Success 'Segoe MDL2 Assets font injected and registered.'
            } catch {
                Write-Warn "Font registry update failed (non-fatal): $_"
            } finally {
                $null = & reg.exe unload "HKLM\$hiveKey" 2>&1
            }
        }

        # ── 4e. Embed Edge browser for M365 sign-in ───────────────────────────
        # Bootstrap.ps1 launches msedge.exe directly in WinPE for interactive
        # Microsoft 365 sign-in (Authorization Code Flow with PKCE).  This
        # step copies the Edge browser from the build machine into the WinPE
        # image at X:\WebView2\Edge.  If Edge is not available, Bootstrap.ps1
        # falls back to Device Code Flow at boot time.
        $wv2Dest = Join-Path $paths.MountDir 'WebView2'
        $null = New-Item -Path $wv2Dest -ItemType Directory -Force
        $edgeOk = $false

        # Copy the Edge browser from the build machine.
        # Check both 64-bit and 32-bit Program Files locations.
        $edgeBrowserSrc = $null
        foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $pf) { continue }
            $candidate = Join-Path $pf 'Microsoft\Edge\Application'
            if (Test-Path $candidate) { $edgeBrowserSrc = $candidate; break }
        }

        if ($edgeBrowserSrc) {
            $edgeVersion = Get-ChildItem $edgeBrowserSrc -Directory |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
                Select-Object -First 1
            if ($edgeVersion) {
                $edgeDest = Join-Path $wv2Dest 'Edge'
                Write-Step "Copying Edge browser ($($edgeVersion.Name)) for WinPE sign-in..."
                Copy-Item $edgeVersion.FullName -Destination $edgeDest -Recurse -Force

                # Also copy the top-level msedge.exe launcher if present.
                $topLevelExe = Join-Path $edgeBrowserSrc 'msedge.exe'
                $edgeDestExe = Join-Path $edgeDest 'msedge.exe'
                if ((Test-Path $topLevelExe) -and -not (Test-Path $edgeDestExe)) {
                    Copy-Item $topLevelExe -Destination $edgeDest -Force
                }
                $edgeOk = $true
                Write-Success "Edge browser ($($edgeVersion.Name)) embedded for WinPE sign-in."
            }
        }

        if (-not $edgeOk) {
            Write-Warn 'Edge browser not found on build machine -- sign-in will use Device Code Flow.'
        }

        # ── 4f. Stage Autopilot tools for API-based device import ─────────────
        # When autopilotImport is enabled in config/auth.json, the Autopilot
        # tools (oa3tool.exe, PCPKsp.dll, OA3.cfg, Invoke-ImportAutopilot.ps1,
        # Utils.ps1) are staged into the WinPE image so that Bootstrap.ps1 can
        # register the device in Autopilot via the Microsoft Graph API using
        # delegated permissions from the M365 sign-in token (no client secret).
        $autopilotFiles = @('oa3tool.exe', 'PCPKsp.dll', 'OA3.cfg',
                            'Invoke-ImportAutopilot.ps1', 'Utils.ps1')
        $customDest = Join-Path $paths.MountDir 'OSDCloud\Config\Scripts\Custom'
        $staged = 0

        # When running from a local clone, $PSScriptRoot points to the repo root
        # and the Autopilot directory is available on disk.
        $autopilotSrc = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Autopilot' } else { '' }
        if ($autopilotSrc -and (Test-Path $autopilotSrc)) {
            $null = New-Item -Path $customDest -ItemType Directory -Force
            foreach ($f in $autopilotFiles) {
                $src = Join-Path $autopilotSrc $f
                if (Test-Path $src) {
                    Copy-Item $src -Destination $customDest -Force
                    $staged++
                }
            }
        } else {
            # iex (irm ...) scenario -- $PSScriptRoot is empty and local files are
            # unavailable.  Download Autopilot tools directly from the GitHub repo,
            # matching the pattern used for Bootstrap.ps1 and Nova.ps1 above.
            $null = New-Item -Path $customDest -ItemType Directory -Force
            foreach ($f in $autopilotFiles) {
                $url  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/resources/autopilot/$f"
                $dest = Join-Path $customDest $f
                try {
                    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop
                    $staged++
                } catch {
                    Write-Verbose "Autopilot file '$f' not available from GitHub: $_"
                }
            }
        }

        if ($staged -gt 0) {
            Write-Success "Autopilot tools staged ($staged files) for API-based device import."
        } elseif ($autopilotSrc -and (Test-Path $autopilotSrc)) {
            Write-Warn 'Autopilot directory found but no tool files present.'
        }

        # ── 5. Download scripts and modules, then verify integrity ────────────
        # Download ALL files first, then load the manifest last to minimise the
        # window for CDN split-brain (file vs manifest out of sync).  If any
        # hash check fails, retry once after a short delay to handle propagation.

        # ── 5a. Embed Bootstrap.ps1 ───────────────────────────────────────────
        $bootstrapUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/scripts/Bootstrap.ps1"
        $bootstrapDest = Join-Path $paths.MountDir 'Windows\System32\Bootstrap.ps1'
        Write-Step "Fetching Bootstrap.ps1 from $bootstrapUrl"
        Invoke-WebRequest -Uri $bootstrapUrl -OutFile $bootstrapDest -UseBasicParsing -Headers $script:NoCacheHeaders

        # ── 5b. Pre-stage Nova.ps1 ──────────────────────────────────────
        # Embedding Nova.ps1 eliminates the internet dependency at boot time.
        # Bootstrap.ps1 will use this local copy instead of downloading it.
        $novaUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/scripts/Nova.ps1"
        $novaDest = Join-Path $paths.MountDir 'Windows\System32\Nova.ps1'
        Write-Step "Fetching Nova.ps1 from $novaUrl"
        Invoke-WebRequest -Uri $novaUrl -OutFile $novaDest -UseBasicParsing -Headers $script:NoCacheHeaders

        # ── 5c. Stage shared PowerShell modules ────────────────────────────────
        # Copy the src/modules/ directory so that Bootstrap.ps1 and Nova.ps1 can
        # Import-Module from $PSScriptRoot\Modules\ inside WinPE.
        $modulesDest = Join-Path $paths.MountDir 'Windows\System32\Modules'
        $modulesSrc  = if ($PSScriptRoot) { Join-Path $PSScriptRoot '..\modules' } else { '' }
        if ($modulesSrc -and (Test-Path $modulesSrc)) {
            Copy-Item $modulesSrc -Destination $modulesDest -Recurse -Force
            Write-Success "Staged modules directory from local repo"
        } else {
            # iex (irm ...) scenario -- download modules from GitHub
            $moduleNames = @('Nova.Logging', 'Nova.Platform', 'Nova.Network',
                             'Nova.Reporting', 'Nova.Disk', 'Nova.Imaging',
                             'Nova.Drivers', 'Nova.Provisioning', 'Nova.TaskSequence',
                             'Nova.Auth', 'Nova.Proxy')
            $moduleFiles = @('.psm1', '.psd1')
            $null = New-Item -Path $modulesDest -ItemType Directory -Force
            foreach ($mod in $moduleNames) {
                $modDir = Join-Path $modulesDest $mod
                $null = New-Item -Path $modDir -ItemType Directory -Force
                foreach ($ext in $moduleFiles) {
                    $url  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/modules/$mod/$mod$ext"
                    $dest = Join-Path $modDir "$mod$ext"
                    try {
                        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop
                    } catch {
                        Write-Warn "Failed to download module file $mod$ext -- $($_.Exception.Message)"
                    }
                }
            }
            Write-Success "Staged modules directory from GitHub"
        }

        # ── 5d. Load integrity manifest AFTER all downloads ───────────────────
        # NOTE: The manifest comes from the same repo/branch as the scripts.
        # Loading it after all downloads minimises the CDN propagation window.
        # This detects corruption and CDN inconsistencies but does not protect
        # against a compromised repository.  For tamper protection, the manifest
        # would need to be cryptographically signed or hosted separately.
        $hashesUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/hashes.json"
        $hashesJson = $null
        try {
            $hashesJson = Invoke-RestMethod -Uri $hashesUrl -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop -TimeoutSec 15
            Write-Success 'Integrity manifest loaded.'
        } catch {
            throw "Could not load integrity manifest from $hashesUrl -- aborting build: $_"
        }

        # ── 5e. Verify script integrity (with CDN retry) ─────────────────────
        Confirm-FileIntegrity -Path $bootstrapDest -RelativeName 'src/scripts/Bootstrap.ps1' `
            -HashesJson $hashesJson -RetryOnMismatch -NoCacheHeaders $script:NoCacheHeaders
        Confirm-FileIntegrity -Path $novaDest -RelativeName 'src/scripts/Nova.ps1' `
            -HashesJson $hashesJson -RetryOnMismatch -NoCacheHeaders $script:NoCacheHeaders

        # ── 5f. Verify module integrity (iex scenario) ────────────────────────
        if (-not ($modulesSrc -and (Test-Path $modulesSrc))) {
            $verifyExts = @('.psm1', '.psd1')
            foreach ($mod in $moduleNames) {
                foreach ($ext in $verifyExts) {
                    $modFile = Join-Path $modulesDest "$mod\$mod$ext"
                    $relName = "src/modules/$mod/$mod$ext"
                    if (Test-Path $modFile) {
                        Confirm-FileIntegrity -Path $modFile -RelativeName $relName `
                            -HashesJson $hashesJson -RetryOnMismatch -NoCacheHeaders $script:NoCacheHeaders
                    }
                }
            }
        }

        # ── 5d. Generate default background image ──────────────────────────────
        # Create a 1920x1080 gradient PNG matching the Bootstrap.ps1 OOBE theme
        # and embed it as X:\Windows\System32\Nova-bg.png.  Administrators
        # can replace this file in the mounted WIM with custom branding before
        # the image is finalised.  Bootstrap.ps1 loads it at startup and paints
        # it as the form background when present.
        $bgDest = Join-Path $paths.MountDir 'Windows\System32\Nova-bg.png'
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $bgW = 1920; $bgH = 1080
            $bgBmp  = New-Object System.Drawing.Bitmap($bgW, $bgH)
            $bgG    = [System.Drawing.Graphics]::FromImage($bgBmp)
            $bgTop  = [System.Drawing.Color]::FromArgb(218, 232, 252)
            $bgBot  = [System.Drawing.Color]::FromArgb(234, 240, 250)
            $bgRect = New-Object System.Drawing.Rectangle(0, 0, $bgW, $bgH)
            $bgBr   = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                          $bgRect, $bgTop, $bgBot,
                          [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            $bgG.FillRectangle($bgBr, $bgRect)
            $bgBr.Dispose(); $bgG.Dispose()
            $bgBmp.Save($bgDest, [System.Drawing.Imaging.ImageFormat]::Png)
            $bgBmp.Dispose()
            Write-Success 'Default background image (Nova-bg.png) embedded.'
        } catch {
            Write-Warn "Background image generation failed (non-fatal): $_"
        }

        # ── 5e. Embed HTML Progress UI ─────────────────────────────────────────
        # Stage src/web/progress/index.html into the WinPE image so the batch launcher
        # can open it in Edge kiosk mode before PowerShell starts.  This covers
        # the screen immediately and prevents any command-prompt flash.
        $progressDest = Join-Path $paths.MountDir 'Nova\Progress'
        $null = New-Item -Path $progressDest -ItemType Directory -Force

        $progressSrc = if ($PSScriptRoot) { Join-Path $PSScriptRoot '..\web\progress' } else { '' }
        if ($progressSrc -and (Test-Path (Join-Path $progressSrc 'index.html'))) {
            Copy-Item -Path "$progressSrc\*" -Destination $progressDest -Recurse -Force
            Write-Success 'HTML Progress UI embedded from local repo.'
        } else {
            $progressUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/web/progress/index.html"
            $progressFile = Join-Path $progressDest 'index.html'
            try {
                Invoke-WebRequest -Uri $progressUrl -OutFile $progressFile -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop
                Write-Success 'HTML Progress UI downloaded and embedded.'
            } catch {
                Write-Warn "HTML Progress UI not available (non-fatal): $_"
            }
        }

        # ── 5f. Embed Nova-UI (main HTML UI) ──────────────────────────────
        # Stage src/web/nova-ui/index.html into the WinPE image so the batch
        # launcher (nova-start.cmd) can open it in Edge kiosk mode at
        # boot, covering the screen before any console window is visible.
        $uiDest = Join-Path $paths.MountDir 'Nova-UI'
        $null = New-Item -Path $uiDest -ItemType Directory -Force

        $uiSrc = if ($PSScriptRoot) { Join-Path $PSScriptRoot '..\web\nova-ui' } else { '' }
        if ($uiSrc -and (Test-Path (Join-Path $uiSrc 'index.html'))) {
            Copy-Item -Path "$uiSrc\*" -Destination $uiDest -Recurse -Force
            Write-Success 'Nova-UI embedded from local repo.'
        } else {
            $uiUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/web/nova-ui/index.html"
            $uiFile = Join-Path $uiDest 'index.html'
            try {
                Invoke-WebRequest -Uri $uiUrl -OutFile $uiFile -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop
                Write-Success 'Nova-UI downloaded and embedded.'
            } catch {
                Write-Warn "Nova-UI not available (non-fatal): $_"
            }
        }

        # ── 6. winpeshl.ini + batch launcher → auto-launch Bootstrap.ps1 ───────
        # WinRE ships its own winpeshl.exe which does not reliably handle the
        # comma-separated "<exe>, <args>" format used for direct PowerShell
        # invocation.  Routing through cmd.exe /k avoids that parsing difference:
        # winpeshl.ini always succeeds (cmd.exe is a guaranteed WinPE binary),
        # and the helper batch file handles the PowerShell invocation directly.
        #
        # The batch file first launches the HTML Progress UI in Edge
        # kiosk mode (if both Edge and the HTML file are present), covering the
        # screen immediately so no command-prompt window is visible at boot.
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
                # is set) takes the hard-error branch below -- one retry maximum.
                $retryWithISOWinRE = $true
                throw 'PowerShell not found in WinRE image -- ADK / WinRE version mismatch.'
            }
            throw 'PowerShell executable not found in the mounted image (Windows\System32\WindowsPowerShell\v1.0\powershell.exe). Ensure WinPE-PowerShell.cab is compatible with the base WIM.'
        }

        $launcherPath = Join-Path $paths.MountDir 'Windows\System32\nova-start.cmd'
        @'
@echo off
title Nova Bootstrap

REM ── Launch the new HTML UI in Edge kiosk mode ─────────────────────────
REM Covers the screen before any console window is visible at boot.
if exist "X:\WebView2\Edge\msedge.exe" if exist "X:\Nova-UI\index.html" (
    start "" "X:\WebView2\Edge\msedge.exe" ^
        --kiosk "file:///X:/Nova-UI/index.html" ^
        --kiosk-type=fullscreen ^
        --allow-run-as-system ^
        --user-data-dir="X:\Temp\EdgeKiosk" ^
        --disable-gpu ^
        --disable-gpu-compositing ^
        --disable-direct-composition ^
        --use-angle=swiftshader ^
        --enable-unsafe-swiftshader ^
        --in-process-gpu ^
        --no-first-run ^
        --disable-fre ^
        --disable-features=msWebOOBE,PasswordManager ^
        --password-store=basic ^
        --guest ^
        --disable-save-password-bubble ^
        --allow-file-access-from-files ^
        --disable-popup-blocking ^
        --disable-renderer-backgrounding ^
        --disable-background-timer-throttling ^
        --disable-backgrounding-occluded-windows ^
        --disable-hang-monitor
)

REM Give Edge time to render the initial UI before PowerShell starts.
REM Use ping instead of timeout because timeout.exe is not available in WinPE.
ping -n 3 127.0.0.1 >nul

REM ── Launch Bootstrap (no WinForms visible UI) ────────────────────────
REM Bootstrap.ps1 stays running via its internal DoEvents message pump.
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "X:\Windows\System32\Bootstrap.ps1"
'@ | Set-Content -Path $launcherPath -Encoding Ascii

        $winpeshlPath = Join-Path $paths.MountDir 'Windows\System32\winpeshl.ini'
        @'
[LaunchApps]
X:\Windows\System32\cmd.exe, /k X:\Windows\System32\nova-start.cmd
'@ | Set-Content -Path $winpeshlPath -Encoding Ascii

    } catch {
        # Always clean up a dangling mount on failure
        Write-Warn 'Customisation failed -- discarding mounted image to avoid corruption.'
        $null = Dismount-WindowsImage -Path $paths.MountDir -Discard -ErrorAction SilentlyContinue

        # ── WinRE / ADK version mismatch -- fetch fresh WinRE from Windows ISO ──────
        # WinPE-PowerShell.cab could not be applied because the ADK package set
        # targets a different Windows build than the local WinRE.  Obtain a fresh
        # WinRE by downloading a Windows ISO, mounting it, and extracting WinRE.wim.
        # The ISO WinRE is always a valid WinRE; its build may still not match the
        # ADK perfectly, but since we are now on the second attempt the hard error
        # path is taken if PowerShell is still absent.
        if ($retryWithISOWinRE) {
            Write-Warn 'WinPE-PowerShell.cab is not compatible with the local WinRE image (ADK / WinRE version mismatch). Fetching a fresh WinRE from a Windows ISO and retrying...'
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
                               -_ISOWinREPath $freshWinRE `
                               -Language $Language `
                               -PackageNames $PackageNames `
                               -DriverPaths $DriverPaths
        }

        throw
    }

    # ── 7. Commit & unmount ───────────────────────────────────────────────────
    Write-Step 'Committing and unmounting image...'
    $null = Dismount-WindowsImage -Path $paths.MountDir -Save
    Write-Success 'Image committed and unmounted.'

    # ── 8. Re-export with maximum compression to reduce WIM size ─────────────
    # Maximum compression can shrink WinRE by 100–200 MB compared to the default
    # compression used inside winre.wim. This keeps the ramdisk footprint small.
    # Safety pattern: rename original to .bak before promoting the slim WIM so
    # that a Move-Item failure can be recovered without losing boot.wim.
    Write-Step 'Re-exporting image with maximum compression (this may take a few minutes)...'
    $slimWim = $paths.BootWim + '.slim'
    $bakWim  = $paths.BootWim + '.bak'
    try {
        $null = Export-WindowsImage -SourceImagePath $paths.BootWim -SourceIndex 1 `
                            -DestinationImagePath $slimWim -CompressionType max
        # Rename original as .bak (same filesystem -- atomic rename)
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

# Invoke-Bcdedit, New-BcdEntry, and New-BCDRamdiskEntry are now provided
# by the Nova.BCD module.

# Get-FirmwareType is now provided by the Nova.Platform module.

#endregion

#region ── Cloud Boot Image ─────────────────────────────────────────────────────

# Get-CloudBootImage and Publish-BootImage are now provided by the
# Nova.CloudImage module.

#endregion

# Install-WebView2SDK, Show-WebView2AuthPopup, and Invoke-M365DeviceCodeAuth
# are now provided by the Nova.Auth module.

#region ── Main ─────────────────────────────────────────────────────────────────

Write-Host @"

 ███╗   ██╗ ██████╗ ██╗   ██╗ █████╗
 ████╗  ██║██╔═══██╗██║   ██║██╔══██╗
 ██╔██╗ ██║██║   ██║██║   ██║███████║
 ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║
 ██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║
 ╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝

 Cloud-only OSDCloud replacement · amd64/x86 · https://github.com/$GitHubUser/$GitHubRepo
"@ -ForegroundColor Cyan

try {
    # ── 0. M365 authentication gate ──────────────────────────────────────────
    $authResult = Invoke-M365DeviceCodeAuth `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
    if (-not $authResult.Authenticated) {
        Write-Fail 'Authentication is required. Exiting.'
        exit 1
    }
    if ($authResult.GraphAccessToken) {
        $script:GraphAccessToken = $authResult.GraphAccessToken
    }

    # ── 1. Detect architecture ────────────────────────────────────────────────
    $arch = Get-WinPEArchitecture
    Write-Step "Host architecture: $arch"

    # ── 1b. Check for a pre-built cloud boot image ──────────────────────────
    Write-Step 'Checking for pre-built boot image on GitHub...'
    $cloudImage = Get-CloudBootImage -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo
    $useCloud   = $false

    if ($cloudImage) {
        $cloudSizeMB = '{0:N0}' -f ($cloudImage.BootWimSize / 1MB)
        Write-Host ''
        Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
        Write-Host '  ║         Cloud Boot Image Available                       ║' -ForegroundColor Cyan
        Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
        Write-Host ''
        Write-Host "    Published : $($cloudImage.PublishedAt)"  -ForegroundColor White
        Write-Host "    Size      : $cloudSizeMB MB"            -ForegroundColor White
        Write-Host "    Source    : $GitHubUser/$GitHubRepo"     -ForegroundColor White
        Write-Host ''
        Write-Host '    [1] Use the cloud image (faster -- skips ADK install and image build)' -ForegroundColor Green
        Write-Host '    [2] Rebuild locally'                                                  -ForegroundColor DarkGray
        Write-Host ''
        if ($AcceptDefaults) {
            $choice = '1'
            Write-Step 'AcceptDefaults: using cloud image.'
        } else {
            $choice = Read-Host "  ${script:AnsiCyan}›${script:AnsiReset} Enter choice (1 or 2) [default: 1]"
        }
        if ($choice -ne '2') { $useCloud = $true }
    }

    if ($useCloud) {
        # ── Cloud path: download pre-built boot image ─────────────────────────
        $cloudDir   = Join-Path $WorkDir 'Cloud'
        $bootSubDir = Join-Path $cloudDir 'boot'
        $null = New-Item -ItemType Directory -Path $bootSubDir -Force

        $bootWimPath = Join-Path $cloudDir 'boot.wim'
        Write-Step "Downloading boot.wim ($cloudSizeMB MB) -- this may take a few minutes..."
        $prevPref = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try     { Invoke-WebRequest -Uri $cloudImage.BootWimUrl -OutFile $bootWimPath -UseBasicParsing }
        finally { $ProgressPreference = $prevPref }
        Write-Success 'boot.wim downloaded.'

        if ($cloudImage.BootSdiUrl) {
            $bootSdiPath = Join-Path $bootSubDir 'boot.sdi'
            Write-Step 'Downloading boot.sdi...'
            $prevPref = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try     { Invoke-WebRequest -Uri $cloudImage.BootSdiUrl -OutFile $bootSdiPath -UseBasicParsing }
            finally { $ProgressPreference = $prevPref }
            Write-Success 'boot.sdi downloaded.'
        } else {
            # boot.sdi was not in the release -- fall back to the local ADK copy
            Write-Warn 'boot.sdi not found in cloud release; obtaining from ADK...'
            $adkRoot  = Assert-ADKInstalled -Architecture $arch
            $sdiSrc   = Join-Path $adkRoot `
                "Assessment and Deployment Kit\Windows Preinstallation Environment\$arch\Media\boot\boot.sdi"
            if (Test-Path $sdiSrc) {
                Copy-Item $sdiSrc (Join-Path $bootSubDir 'boot.sdi') -Force
                Write-Success 'boot.sdi obtained from ADK.'
            } else {
                Write-Warn "boot.sdi not found at $sdiSrc -- ramdisk boot will likely fail."
            }
        }

        # ── BCD ───────────────────────────────────────────────────────────────
        New-BCDRamdiskEntry `
            -BootWim    $bootWimPath `
            -RamdiskDir $script:RamdiskDir `
            -MediaDir   $cloudDir

    } else {
        # ── Local build path ──────────────────────────────────────────────────
        # ── 1. ADK ────────────────────────────────────────────────────────────
        $adkRoot = Assert-ADKInstalled -Architecture $arch

        # ── 1b. Show configuration menu (preselected defaults) ────────────────
        if ($AcceptDefaults) {
            Write-Step 'AcceptDefaults: using default build configuration.'
            $availablePkgs = Get-AvailableWinPEPackages
            $selectedPkgs = @()
            foreach ($pkg in $availablePkgs) {
                if ($pkg.Default) { $selectedPkgs += $pkg.Name }
            }
            $buildConfig = @{
                Language    = Get-DefaultLanguage
                Packages    = $selectedPkgs
                DriverPaths = @()
            }
        } else {
            $buildConfig = Show-BuildConfiguration -Architecture $arch
        }

        # ── 2. Boot image (WinRE preferred, WinPE fallback) ──────────────────
        $paths = Build-WinPE `
            -ADKRoot           $adkRoot `
            -WorkDir           $script:WinPEWorkDir `
            -Architecture      $arch `
            -GitHubUser        $GitHubUser `
            -GitHubRepo        $GitHubRepo `
            -GitHubBranch      $GitHubBranch `
            -WindowsISOUrl     $WindowsISOUrl `
            -Language          $buildConfig.Language `
            -PackageNames      $buildConfig.Packages `
            -DriverPaths       $buildConfig.DriverPaths

        # ── 2b. Offer to upload boot image to GitHub ─────────────────────────
        if (-not $AcceptDefaults) {
            $wimSize = if (Test-Path $paths.BootWim) {
                '{0:N0} MB' -f ((Get-Item $paths.BootWim).Length / 1MB)
            } else { 'unknown' }

            # Try to obtain a GitHub token via the Entra ID token exchange
            # (same mechanism used by Nova.Reporting) so the user doesn't
            # need to supply a PAT manually.
            $entraGitHubToken = $null
            if ($script:GraphAccessToken -and $authResult.AuthConfig) {
                $proxyUrl = $null
                if ($authResult.AuthConfig.PSObject.Properties['githubOAuthProxy']) {
                    $proxyUrl = $authResult.AuthConfig.githubOAuthProxy
                }
                if ($proxyUrl) {
                    try {
                        $exchangeUrl = "$proxyUrl/api/token-exchange"
                        $req = [System.Net.HttpWebRequest]::Create($exchangeUrl)
                        $req.Method      = 'POST'
                        $req.ContentType = 'application/json'
                        $req.Headers.Add('Authorization', "Bearer $($script:GraphAccessToken)")
                        $req.UserAgent       = 'Nova-Trigger'
                        $req.Timeout         = 15000
                        $req.ReadWriteTimeout = 15000

                        $statusCode = 0
                        $resp = $null
                        try {
                            $resp       = $req.GetResponse()
                            $statusCode = [int]$resp.StatusCode
                        } catch [System.Net.WebException] {
                            $resp       = $_.Exception.Response
                            $statusCode = if ($resp) { [int]$resp.StatusCode } else { 0 }
                        }

                        if ($statusCode -eq 200 -and $resp) {
                            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                            try {
                                $body = $reader.ReadToEnd()
                            } finally {
                                $reader.Close()
                            }
                            $result = $body | ConvertFrom-Json
                            if ($result.token) {
                                $entraGitHubToken = $result.token
                                Write-Step "GitHub token obtained via Entra ID (user: $($result.user))"
                            }
                        }
                        if ($resp) { $resp.Close() }
                    } catch {
                        Write-Verbose "Entra->GitHub token exchange failed: $_"
                    }
                }
            }

            $authMethod = if ($entraGitHubToken) { 'Entra ID (automatic)' } else { 'PAT required (repo scope)' }
            Write-Host ''
            Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
            Write-Host '  ║         Publish Boot Image                               ║' -ForegroundColor Cyan
            Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
            Write-Host ''
            Write-Host "    File   : $($paths.BootWim)" -ForegroundColor White
            Write-Host "    Size   : $wimSize" -ForegroundColor White
            Write-Host "    Target : $GitHubUser/$GitHubRepo (GitHub Releases)" -ForegroundColor White
            Write-Host "    Auth   : $authMethod" -ForegroundColor $(if ($entraGitHubToken) { 'Green' } else { 'DarkGray' })
            Write-Host ''
            $uploadChoice = Read-Host "  ${script:AnsiCyan}›${script:AnsiReset} Upload this boot image for future use? (y/N)"
            if ($uploadChoice -match '^[Yy]') {
                $tokenPlain = $null
                $bstr       = $null
                try {
                    if ($entraGitHubToken) {
                        $tokenPlain = $entraGitHubToken
                    } else {
                        $tokenSecure = Read-Host '  GitHub Personal Access Token' -AsSecureString
                        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenSecure)
                        $tokenPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                    }
                    $sdiPath = Join-Path $paths.MediaDir 'boot\boot.sdi'
                    Publish-BootImage `
                        -GitHubUser  $GitHubUser `
                        -GitHubRepo  $GitHubRepo `
                        -GitHubToken $tokenPlain `
                        -BootWimPath $paths.BootWim `
                        -BootSdiPath $sdiPath
                    Write-Success 'Boot image published to GitHub Releases.'
                } catch {
                    Write-Warn "Upload failed (non-fatal): $_"
                } finally {
                    $tokenPlain = $null
                    $entraGitHubToken = $null
                    if ($bstr) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                }
            }
        }

        # ── 3. BCD ────────────────────────────────────────────────────────────
        New-BCDRamdiskEntry `
            -BootWim    $paths.BootWim `
            -RamdiskDir $script:RamdiskDir `
            -MediaDir   $paths.MediaDir
    }

    Write-Host "`n  [Nova] All done -- system is primed for cloud boot." -ForegroundColor Green

    if (-not $NoReboot) {
        Write-Host '  [Nova] Press Ctrl+C to cancel reboot.' -ForegroundColor Yellow
        10..1 | ForEach-Object {
            Write-Host "`r  [Nova] Rebooting in $_ ... " -NoNewline -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
        Write-Host ''
        Restart-Computer -Force
    } else {
        Write-Host '  [Nova] -NoReboot specified. Reboot manually to enter the boot environment.' `
            -ForegroundColor Yellow
    }

} catch {
    Write-Fail "Fatal: $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    exit 1
}

#endregion
}


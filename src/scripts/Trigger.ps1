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
    foreach ($mod in $moduleNames) {
        $modDir = Join-Path $tmpModRoot $mod
        $null = New-Item -Path $modDir -ItemType Directory -Force
        foreach ($ext in $moduleExts) {
            $url  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/modules/$mod/$mod$ext"
            $dest = Join-Path $modDir "$mod$ext"
            try {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
            } catch {
                throw "Failed to download module $mod$ext from $url -- $($_.Exception.Message)"
            }
        }
    }
    $tmpModRoot
} else {
    "$PSScriptRoot\..\modules"   # Best-effort fallback
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
                    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
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

        # ── 5. Load integrity manifest ─────────────────────────────────────────
        # NOTE: The manifest comes from the same repo/branch as the scripts.
        # This detects corruption and CDN inconsistencies but does not protect
        # against a compromised repository.  For tamper protection, the manifest
        # would need to be cryptographically signed or hosted separately.
        $hashesUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/hashes.json"
        $hashesJson = $null
        try {
            $hashesJson = Invoke-RestMethod -Uri $hashesUrl -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
            Write-Success 'Integrity manifest loaded.'
        } catch {
            throw "Could not load integrity manifest from $hashesUrl -- aborting build: $_"
        }

        # ── 5a. Embed Bootstrap.ps1 ───────────────────────────────────────────
        $bootstrapUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/scripts/Bootstrap.ps1"
        $bootstrapDest = Join-Path $paths.MountDir 'Windows\System32\Bootstrap.ps1'
        Write-Step "Fetching Bootstrap.ps1 from $bootstrapUrl"
        Invoke-WebRequest -Uri $bootstrapUrl -OutFile $bootstrapDest -UseBasicParsing
        Confirm-FileIntegrity -Path $bootstrapDest -RelativeName 'src/scripts/Bootstrap.ps1' -HashesJson $hashesJson

        # ── 5b. Pre-stage Nova.ps1 ──────────────────────────────────────
        # Embedding Nova.ps1 eliminates the internet dependency at boot time.
        # Bootstrap.ps1 will use this local copy instead of downloading it.
        $novaUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/scripts/Nova.ps1"
        $novaDest = Join-Path $paths.MountDir 'Windows\System32\Nova.ps1'
        Write-Step "Fetching Nova.ps1 from $novaUrl"
        Invoke-WebRequest -Uri $novaUrl -OutFile $novaDest -UseBasicParsing
        Confirm-FileIntegrity -Path $novaDest -RelativeName 'src/scripts/Nova.ps1' -HashesJson $hashesJson

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
                        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
                    } catch {
                        Write-Warn "Failed to download module file $mod$ext -- $($_.Exception.Message)"
                    }
                }
            }
            Write-Success "Staged modules directory from GitHub"
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
                Invoke-WebRequest -Uri $progressUrl -OutFile $progressFile -UseBasicParsing -ErrorAction Stop
                Confirm-FileIntegrity -Path $progressFile -RelativeName 'src/web/progress/index.html' -HashesJson $hashesJson
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
                Invoke-WebRequest -Uri $uiUrl -OutFile $uiFile -UseBasicParsing -ErrorAction Stop
                Confirm-FileIntegrity -Path $uiFile -RelativeName 'src/web/nova-ui/index.html' -HashesJson $hashesJson
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
        --disable-popup-blocking
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
            Write-Host ''
            Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
            Write-Host '  ║         Publish Boot Image                               ║' -ForegroundColor Cyan
            Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
            Write-Host ''
            Write-Host "    File   : $($paths.BootWim)" -ForegroundColor White
            Write-Host "    Size   : $wimSize" -ForegroundColor White
            Write-Host "    Target : $GitHubUser/$GitHubRepo (GitHub Releases)" -ForegroundColor White
            Write-Host "    Scope  : PAT requires ${script:AnsiBold}repo${script:AnsiReset} scope" -ForegroundColor DarkGray
            Write-Host ''
            $uploadChoice = Read-Host "  ${script:AnsiCyan}›${script:AnsiReset} Upload this boot image for future use? (y/N)"
            if ($uploadChoice -match '^[Yy]') {
                $tokenSecure = Read-Host '  GitHub Personal Access Token' -AsSecureString
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenSecure)
                try {
                    $tokenPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
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
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
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

# SIG # Begin signature block
# MII9dQYJKoZIhvcNAQcCoII9ZjCCPWICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB/hV4pYZ6gnYgk
# W64NypuIqrn7XW06ftg6cdktruo27qCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# rmcxghqTMIIajwIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDMCEzMAABNvNnVaVBHA35YAAAAAE28wDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgNSXGOFzUkjvddYwBOoZyaaPlgX5OD6Z0bEQ3tvwGiDkw
# DQYJKoZIhvcNAQEBBQAEggGACq3SThUrkgbj6jN315KGdZoYSY+Ii8e/S0eorL9S
# 9F2wjGptB3TlxkdDxpvi0ID1KG5AKE1CobXjba0A/LyzZR5BpWW5l2JB+KTdpHZZ
# mEpY4XwbkGnHlBVX4zABEbx1xQ/GfdA8WgK4IBz8GSmlessD4vgU5c+Mm3I55h3j
# oEdXg+MiHEhJVoW+rRrt+sN40XGQh5awC5b8UasfHSKqKbigkKtHw4aE3CvtOvO+
# o8ZOTL2slHFYLMiLWCcK14wv1ZImi5ZN5CNAo5YP3LnpGfGnqZG4mgjgoKklkFUR
# k23jj+Gbn3QiAPPR+nRDMsIcViNdOLt0aKt6YqeygGaMdIztqZ0K6D6ekFaqZXj6
# tjq6GXWPLAsBqwe31cFKJNqzbgfD876PuGACw64lwS2C+gnA+B9SEIaTHusgNfar
# nX20GinjczQ/gu4wjvsQqUjq1oA0E5uwefaRK7PjkjiCYO1nqlsyry8iCxCBqifv
# VuxWC79zHeDxaoXHXqNCbA+OoYIYEzCCGA8GCisGAQQBgjcDAwExghf/MIIX+wYJ
# KoZIhvcNAQcCoIIX7DCCF+gCAQMxDzANBglghkgBZQMEAgEFADCCAWEGCyqGSIb3
# DQEJEAEEoIIBUASCAUwwggFIAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIC1wm/0gefeYV5Bsi9GBd8DahmRscFRI9uUzHDUl8JxJAgZp1AZ82KoYEjIw
# MjYwNDA4MjMwMzU4LjI0WjAEgAIB9KCB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaCCDyEwggeCMIIFaqADAgECAhMzAAAABeXPD/9mLsmHAAAAAAAF
# MA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJp
# ZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMDEx
# MTkyMDMyMzFaFw0zNTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAnnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1lRkd3kcFdcG9/
# sqtDlwxKoVIcaqDb+omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjxnG/eViS4sOx8
# y4gSq8Zg49REAf5huXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5hJM1xznkRsFP
# u6rfDHeZeG1Wa1wISvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFlyAKwn6yjN/kR
# 4fkquUWfGmMopNq/B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTPVi3gVErnc/qi
# +dR8A2MiAz0kN0nh7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKxLms73KG/Z+Mk
# euaVDQQheangOEMGJ4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxRYR/JPGAaM6xG
# l57Ei95HUw9NV/uC3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxOmM2rl4uKK6eE
# purRduOQ2hTkmG1hSuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cjRKG79+TX+sTe
# hawOoxfeOO/jR7wo3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xTnD1a69w/UTxw
# jEugpIPMIIE67SFZ2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8FUXetXr0CAwEA
# AaOCAhswggIXMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNV
# HQ4EFgQUa2koOjUvSGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJBgRVHSAAMEEw
# PwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9j
# cy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFMh+
# 0mqFKhvKGZgEByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3JsMIGUBggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUHMAKGdWh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSWRl
# bnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRo
# b3JpdHklMjAyMDIwLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2x35ttVoVdedM
# eGj6TuHYRJklFaW4sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6AF6ycWoEYR0LY
# haa0ozJLU5Yi+LCmcrdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM74LNvVzY0/nP
# ISHz0Xva71QjD4h+8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLslLKsO8F2aBs2c
# Io1k+aHOhrw9xw6JCWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yFM7Ujrhc0aqy3
# xL7D5FR2J7x9cLWMq7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFovIP7YG4ZkJWag
# 1H91KlELGWi3SLv10o4KGag42pswjybTi4toQcC/irAodDW8HNtX+cbz0sMptFJK
# +KObAnDFHEsukxD+7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9TlxydiFhvu88
# o0w35JkNbJxTk4MhF/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWVydt4ytxYP/bq
# jN49D9NZ81coE6aQWm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeCUMYmBx3PkP8A
# DHD1J2Cr/6tjuOOCztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdtoSAHEUKiBhI6J
# QivRepyvWcl+JYbYbBh7pmgAXVswggeXMIIFf6ADAgECAhMzAAAAVyTTleCi6ckx
# AAAAAABXMA0GCSqGSIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMB4XDTI1MTAyMzIwNDY1M1oXDTI2MTAy
# MjIwNDY1M1owgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsT
# Hm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9z
# b2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHkwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCxbKUKkwh9uLMktjWQ9c7ZyZfYdFa9FsCZ
# 4pJnl7Hv+MLKZ1XsRqn4hzaKpG1YOQop7mAvolXzTC2fkLaocks/FRgUo0bdSQeQ
# AjbUygI35haeFPwr9i4+Jvr7r3vSN1t4UoiJkxbB3mGelf0neN6164R1dun8N8UE
# rXkm4Pck7Na4Xay5AI+CpiNA+T+Cmr7coIq1clFtdIJIn1i0hNTYgfCZ90TuXY99
# nXnjDTjWmj58N5OPSAk7NxX8m/npDQz7DX2MAqj8jk8TOstXUg9CeY/iivVfhFsl
# eTw41fI459c7ErZUuk3GCSUrXIB7NsU/a7OqKFpeRbWH0ZAsYQ0oRKd7PCB1Fos0
# 1pi2bwBP+lkdgnfmZlWqRl0whySlAcmT8XV9IvIMp4q0fhMLhxzcRIpQyAi2rTtl
# mbvgkKx+GatDWKNU0OLVKWf5AFqaALta+JluRCdx5BGr0Nj7qEA3A6tqwBlSJWva
# Q+6PWMcM5fNQbg71BMrvQ/+hdKpkA3WhO/dR8XwlMaYDGD6XVk87PnQxj3ocEPD/
# dsj/AEY28uTp8tWevEY3kHm6cX+Vi+ONZshR3IE9VCc84pe7TxJEdtjX0zUehZfo
# 81m/6/NJ6pV5ZYcp0qMLcaNWNtsamL4ktuLJopFLASqjj20ku+7r1xDt1axuSxqL
# hNRGdWPaYwIDAQABo4IByzCCAccwHQYDVR0OBBYEFI6DyV4tNQ4CCUhn5uNemIPt
# EpKnMB8GA1UdIwQYMBaAFGtpKDo1L0hjQM972K9J6T7ZPdshMGwGA1UdHwRlMGMw
# YaBfoF2GW2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jv
# c29mdCUyMFB1YmxpYyUyMFJTQSUyMFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5j
# cmwweQYIKwYBBQUHAQEEbTBrMGkGCCsGAQUFBzAChl1odHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUy
# MFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5jcnQwDAYDVR0TAQH/BAIwADAWBgNV
# HSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwZgYDVR0gBF8wXTBR
# BgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEAjANBgkq
# hkiG9w0BAQwFAAOCAgEAcnXAdjzpmTlJQEM9jbl3+71glVpo1rvW7GNfhzI79cni
# 48Q0JI7CRFOc2iA8vFMPQWDfPhMV//ZP/QgVLF21ZW1OOHOuf5YsifN5FrBSFMIV
# Ws8EkoRZWyGb4iDv+cHslsk3zz6W0iYFsvmRPVK0Et8bpSSwBwNs1JDDD3QJReEa
# 54HGWdK+OQBfWiGI3XrLVsHazSu9DHwKx6mXYK4F59N8OswbNb+3M3HlhorYPw5b
# B6pNZlwaUk7hiNk0jzdxOtCCF8eX/wBc4ePxxYvfAQWW1BCzbF5FgBvcp2eXughY
# opdZoFgljk/dA+yIL4NMynt6N1gpOtvf3p/eCv7Av8yzn9ne8hZk8km/Xyo3DjR9
# Q295GfDMxCfHx0zZsa5ddBnnLs/xpdPgckyjfj2pm2fhdDCJQT8MOn74xQvSSCO9
# 38N6jtevfvU8U89hvhNuhmGNXXH37AIcOg6k0IG35W5dTvzK0l0rNDUm/ZwQ/UX0
# f3/BIuwwNS9YwTu72YYSU48Nk8xWvwC4ES4t1tNIR1ovCxkGmXPEsFyDGFn8KzfT
# IGG4TdCGpPVgNnalrnpF7E8DZJqw9xOhPqAmAnoTToGZnbNBM29Y6OzldCodti5d
# yh4NzB7ZRoLsQM4YPwaYsT0uKq1Cy5AIzu/sjbFH6w9lPYDH/zkeMiQz7czNMrUx
# ggdGMIIHQgIBATB4MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwAhMzAAAAVyTTleCi6ckxAAAAAABXMA0GCWCGSAFlAwQC
# AQUAoIIEnzARBgsqhkiG9w0BCRACDzECBQAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3
# DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjA0MDgyMzAzNThaMC8GCSqGSIb3DQEJ
# BDEiBCC2DjrDpmPezgZmoId/pGty8ryhP16MuMkSTVSZqkpyZTCBuQYLKoZIhvcN
# AQkQAi8xgakwgaYwgaMwgaAEIPU8n2S1BW5MZYhsos7h/VVQ6VRTb0BEISkNmYVM
# eNtSMHwwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFt
# cGluZyBDQSAyMDIwAhMzAAAAVyTTleCi6ckxAAAAAABXMIIDYQYLKoZIhvcNAQkQ
# AhIxggNQMIIDTKGCA0gwggNEMIICLAIBATCCAQmhgeGkgd4wgdsxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBB
# bWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAw
# LTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBT
# dGFtcGluZyBBdXRob3JpdHmiIwoBATAHBgUrDgMCGgMVAP0vMTmcQlEBQTZKzfFo
# oo9cecvDoGcwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwMA0GCSqGSIb3DQEBCwUAAgUA7YEn/DAiGA8yMDI2MDQw
# ODE5MTYxMloYDzIwMjYwNDA5MTkxNjEyWjB3MD0GCisGAQQBhFkKBAExLzAtMAoC
# BQDtgSf8AgEAMAoCAQACAgL9AgH/MAcCAQACAhKYMAoCBQDtgnl8AgEAMDYGCisG
# AQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMB
# hqAwDQYJKoZIhvcNAQELBQADggEBAJpT2wuko8KTCyYxRPR9XIa357FTsIAir579
# bg1MUaf8hthV8teiAuNfFHUJFfgA2Gu/CKNBZ/f9mJvF5rYM9tNAzAJBtY64k9yJ
# +2LOZtzw69UWHXGifrJnhJwts4ssy7YjwXAtNMdNihryiOWq9nMYb2x/zr0/RYjk
# L4kj6VGB+6/sv2eSZyZ2s3wypQ1j5fbfpcu5hF1tytz9ChOdfvUfavqCC3NONOCV
# YoZBsWfFXogunOwTqP5gX9gQVmIU4PNozFmGT8zkUzctTkNFj0j+rkhhZ/BRBVc4
# +AjXbw95GXINiUI9NEbuTDlWyQu1jp5/ZzS4+djdqGFAUL+Hf0swDQYJKoZIhvcN
# AQEBBQAEggIAMTYy+RD70c1rIDJsRF/85oZzR/+Ae13fyhk1XXZ47w0rYbeBcDuB
# 9SETs4+rYXh29kwuB9aTYlEYMcecBTJBhsTFv67UcQD0WATAat8WiKKEda4c38L5
# 2siwIOAIOGtkMWH4iRx8xXKX9adiXgUHc1eQDd4NBL52RLiomFNf1ib61m5yS3sa
# f3/12lTASIUm4gpetE32RwWoG79AddCZlb6ED5dpA1su+uu3mlMqL9fRLIdtEkYs
# 0K/9Kcmpq7ZWSGgYEKLvbyC1EeMXIhYJXrRTqotUT/YmmH5Cv4FCZq5DkYGRP4+N
# V3ubdO2IrxNWI8hvCnlTs2ytHnMgFhiRkyTNfyXtQ2nzc17aMh2C0tWi0rltWmwX
# TShfrUNsa30ToTZSvplQeByl2LYt9+O8O1c3N8pKWAPSSpVlRAz7CjNJSX/9FofP
# ygCqOX8+b9eNKH58k9hfYfZIa8SBkAAo9VkAcre9MC4HfMyS/tE0MaSkn6XtOU69
# p+RMKAdFrLiwGYavBteSfMXKkfSMIEyF6cPORDe4t66466+gTNUZXrrI8Kfmtlvx
# EuxRSGpye0VCkQHzpSy8vvcOzNKACqfdn1KccspYnTx7e7OXoiKNiMxO3grrUwV+
# 4JaEFOUG7h6AG62Mt6/m1ouJeFCIoPPe5c2TfPB8JpqLZEXoJGAECbc=
# SIG # End signature block

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
                             'Nova.Drivers', 'Nova.Provisioning', 'Nova.TaskSequence')
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
# MII+LQYJKoZIhvcNAQcCoII+HjCCPhoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAOYaYTws+EgDjt
# M71YP3STBtxM4QXqcBrlDXxAGEhGyqCCIvIwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 3IpaDcR+iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqR
# MIIajQIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0Mg
# Q0EgMDICEzMAB9JqeMTCGX+FIsEAAAAH0mowDQYJYIZIAWUDBAIBBQCgXjAQBgor
# BgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG
# 9w0BCQQxIgQg+jDG00iWAhS1jrX0tfxrc8XwPVnwaWCPdOsstKsoURAwDQYJKoZI
# hvcNAQEBBQAEggGAFCrwIkUByWJP9tk4qeDKIaXRG6EtTfaNTTAoa0Yem0/21mKM
# 2/DMPT2xKkvzWEWqmsQ2IIalGqP573TtNOobD28yuZBz24v3LwCZ9NLmBYP7i2jV
# w7emzSwNa9ZYBwqyKkf2gvULNfWBF4sX6tBfGCdOE1FvLp++pBgw9OnSnmkP/EOe
# b6TLqpXxyhGCuinhBEc4m+hMOPQTS4bM7jJQrs1bH9i/7dOAYRJ/pc0IlmE8U0Uj
# b5xHoTzD3MUwL4bhlzTpWVXPv1K1rAPfsPiqCKv9VN3IyFBNfZYz6r/eD8ETJhmx
# SLQx5BJ76sFUfNthkX3MJ9lXYoPfEwSe9qmsDKY+G01mFI471zu9qXdanus2LXw8
# 6q+mBtLV7aahhrEBuziQYShNC07P+o//UdLbDYSQODFT/QuK9cgteuZG0TaA0x1S
# 84E3E+HC0twT3tMygabnJHAbZK9GUk6P71ksegsT6kXtaKnHaweYchdMyE2oRGAo
# dCfwlWIehtibtWO4oYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJKoZIhvcN
# AQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEE
# oIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIPgv
# GryH7WS4vmQXBSKTn6N1YfbM8LQSre9L+FrZ51ajAgZpwmaT9esYEzIwMjYwNDA0
# MDczNTE4LjA2NFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJh
# dGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAtRDk0NzE1
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
# r1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFZ+j51YCI7pYAAAAAAA
# VjANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBU
# aW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTFaFw0yNjEwMjIyMDQ2
# NTFaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYD
# VQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hp
# ZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQ
# dWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEAtKWfm/ul027/d8Rlb8Mn/g0QUvvLqY2Vsy3tI8U2
# tFSspTZomZOD3BHT8LkR+RrhMJgb1VjAKFNysaK9cLSXifPGSIBrPCgs9P4y24lr
# JEmrV6Q5z4BmqMhIPrZhEvZnWpCS4HO7jYSei/nxmC7/1Er+l5Lg3PmSxb8d2IVc
# ARxSw1B4mxB6XI0nkel9wa1dYb2wfGpofraFmxZOxT9eNht4LH0RBSVueba6ZNpj
# S/0gtfm7qiIiyP6p6PRzTTbMnVqsHnV/d/rW0zHx+Q+QNZ5wUqKmTZJB9hU853+2
# pX5rDfK32uNY9/WBOAmzbqgpEdQkbiMavUMyUDShmycIvgHdQnS207sTj8M+kJL3
# tOdahPuPqMwsaCCgdfwwQx0O9TKe7FSvbAEYs1AnldCl/KHGZCOVvUNqjyL10JLe
# 0/+GD9/ynqXGWFpXOjaunvZ/cKROhjN4M5e6xx0b2miqcPii4/ii2ZheKallJET7
# CKlpFShs3wyg6F/fojQxQvPnbWD4Nyx6lhjWjwmoLcx6w1FSCtavLCly33BLRSlT
# U4qKUxaa8d7YN7Eqpn9XO0SY0umOvKFXrWH7rxl+9iaicitdnTTksAnRjvekdKT3
# lg7lRMfmfZU8vXNiN0UYJzT9EjqjRm0uN/h0oXxPhNfPYqeFbyPXGGxzaYUz6zx3
# qTcCAwEAAaOCAcswggHHMB0GA1UdDgQWBBS+tjPyu6tZ/h5GsyLvyz1H+FNIWjAf
# BgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6Bd
# hltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQl
# MjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkG
# CCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1l
# c3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/
# BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYB
# BAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcN
# AQEMBQADggIBAA4DqAXEsO26j/La7Fgn/Qifit8xuZekqZ57+Ye+sH/hRTbEEjGY
# rZgsqwR/lUUfKCFpbZF8msaZPQJOR4YYUEU8XyjLrn8Y1jCSmoxh9l7tWiSoc/JF
# Bw356JAmzGGxeBA2EWSxRuTr1AuZe6nYaN8/wtFkiHcs8gMadxXBs6DxVhyu5Ynh
# LPQkfumKm3lFftwE7pieV7f1lskmlgsC6AeSGCzGPZUgCvcH5Tv/Qe9z7bIImSD3
# SuzhOIwaP+eKQTYf67TifyJKkWQSdGfTA6Kcu41k8LB6oPK+MLk1jbxxK5wPqLSL
# 62xjK04SBXHEJSEnsFt0zxWkxP/lgej1DxqUnmrYEdkxvzKSHIAqFWSZul/5hI+v
# JxvFPhsNQBEk4cSulDkJQpcdVi/gmf/mHFOYhDBjsa15s4L+2sBil3XV/T8RiR66
# Q8xYvTLRWxd2dVsrOoCwnsU4WIeiC0JinCv1WLHEh7Qyzr9RSr4kKJLWdpNYLhgj
# kojTmEkAjFO774t3xB7enbvIF0GOsV19xnCUzq9EGKyt0gMuaphKlNjJ+aTpjWMZ
# DGo+GOKsnp93Hmftml0Syp3F9+M3y+y6WJGUZoIZJq227jDjjEndtpUrh9BdPdVI
# fVJD/Au81Rzh05UHAivorQ3Os8PELHIgiOd9TWzbdgmGzcILt/ddVQERMYIHQzCC
# Bz8CAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBp
# bmcgQ0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjANBglghkgBZQMEAgEFAKCC
# BJwwEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAcBgkqhkiG9w0BCQUxDxcNMjYwNDA0MDczNTE4WjAvBgkqhkiG9w0BCQQxIgQg
# c/wn8hqkkzh6gvpJQC03LFyUVLOTaCzcC6r6OTE3vBAwgbkGCyqGSIb3DQEJEAIv
# MYGpMIGmMIGjMIGgBCC2DDMlTaTj8JV3iTg5Xnpe4CSH60143Z+X9o5NBgMMqDB8
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjCCA14GCyqGSIb3DQEJEAISMYID
# TTCCA0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUw
# LUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBp
# bmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD/c/cpFSqQWYBeXggyRJ2ZbvYE
# EaBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBp
# bmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO16vK4wIhgPMjAyNjA0MDMyMjI0
# NDZaGA8yMDI2MDQwNDIyMjQ0NlowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA7Xq8
# rgIBADAHAgEAAgIIWDAHAgEAAgISTDAKAgUA7XwOLgIBADA2BgorBgEEAYRZCgQC
# MSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqG
# SIb3DQEBCwUAA4IBAQAlfiEkzzc/IRYqvewBK8dpR1U1JcCsogNK9WxgY0GgHsFa
# NA4WkG2WKedZDdvK2TpYBiidMft9TwaM6g7J/Ll8bKPWXssg4XfNIhFu7Kgz4XCV
# yukQCO4gBcROOwimi2A/RPNlZyQ8qgH+0/4Ekd85RjD1D+drtiAY0gKP7wUH1NYi
# pK7+tonFXHjKgPYqXinXxtnCbW2oxl/YKIeZxL4fctablo6BvQY1UUz/MSD5TVm3
# S9PBwU6zzfHOPMdYIeX33/qnPVsQoLYcYxcfj5ShKJQcjEPII6/jWBo1UJpDJdAW
# pa6O5zsS1Br8HPnMVmjIdin4okxSmtaq4q2XkvkEMA0GCSqGSIb3DQEBAQUABIIC
# AIWg5thY7hONU3Cod7p85ZhbbPiRxqsPL6NZPSWAb9EELMnktl904bx8GlRtU+mJ
# XlNfUgsd9oYgrCbNmKDeCQe5nw5sJPNtFqN9siKl6CGnfrTeMCP8kAbBjWQI83h0
# aPTojwbiMQL9HLDxeI7iL1J13f142VDf8d0ZjLHimJO+D/NAoc6mF1qRWzuw3ScD
# zdmF5coIZvlf4qGTbbFk8OID8TCujYoPzDfPXS083mSntkDJLOISj6llLmo1ZVSt
# avRVPVZCx17xEAWWL4CR0OsdMKrwt9tcWR2PH0i/f8tB/DD9ayr4nPS62RVKsvLl
# GYg6bGVCQqzRpN8hTOWWpCOIKWS+r804daWOp+0YgL026mJ4odVA25ZnSDuadJ+D
# U5ubetN2GVm6qAs3lFnfKPvAH+wcVMS63VqX+H5NvGiFE/eb7VaroGr3XL02G4NV
# 3VTkDkTIJk2weO7fs+6ncWFP8+DnhYeBQrSrxAoT6TXZg67mtjuvWJbzYYLtYatb
# aDu+V3IUnnGlWa2aHSCvNjnPW86cQ5ZJnotV3S7w5EE/L3ZXwvvmpgnP89DsbM3L
# XfSj4+nA2PWN6jja0VrlZbAIb5mUJ05X8A1rJmFkROnt2GXyPdfgaQZkWPV2eWIi
# y5DidFiCXZvZNjoYQDPmS2kzxAVztYRlw98lb9AwwwHE
# SIG # End signature block

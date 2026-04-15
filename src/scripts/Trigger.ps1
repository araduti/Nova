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
    [string] $ProxyBaseUrl    = '',
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

# Content-proxy state (populated after authentication when $ProxyBaseUrl is set).
$script:ProxyBaseUrl  = $null
$script:ProxyHeaders  = $null

# ── Repo download helpers ──────────────────────────────────────────────────────
function Invoke-RepoDownload {
    <#
    .SYNOPSIS  Downloads a repo-relative file from GitHub or the content proxy.
    .DESCRIPTION
        When $script:ProxyBaseUrl is set and $script:ProxyHeaders is available,
        downloads via the authenticated content proxy (GET /api/repo/{path}).
        Otherwise falls back to raw.githubusercontent.com (public repo path).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,   # e.g. 'src/scripts/Bootstrap.ps1'

        [Parameter(Mandatory)]
        [string]$OutFile,

        [switch]$AllowFallback   # If proxy fails, fall back to public URL
    )

    # Try proxy first when configured
    if ($script:ProxyBaseUrl -and $script:ProxyHeaders) {
        $proxyUrl = "$($script:ProxyBaseUrl.TrimEnd('/'))/api/repo/$RelativePath"
        try {
            # 30s timeout -- file downloads may be larger than JSON payloads
            Invoke-WebRequest -Uri $proxyUrl -OutFile $OutFile -UseBasicParsing `
                -Headers $script:ProxyHeaders -ErrorAction Stop -TimeoutSec 30
            return
        } catch {
            if (-not $AllowFallback) {
                throw "Content proxy download failed for $RelativePath from ${proxyUrl}: $_"
            }
            Write-Verbose "Proxy download failed for $RelativePath, falling back to public URL: $_"
        }
    }

    # Public GitHub fallback
    $url = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/$RelativePath"
    Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop -TimeoutSec 30
}

function Invoke-RepoRestMethod {
    <#
    .SYNOPSIS  Fetches a repo-relative JSON file from GitHub or the content proxy.
    .DESCRIPTION
        Like Invoke-RepoDownload but returns parsed content (for JSON endpoints).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [switch]$AllowFallback
    )

    if ($script:ProxyBaseUrl -and $script:ProxyHeaders) {
        $proxyUrl = "$($script:ProxyBaseUrl.TrimEnd('/'))/api/repo/$RelativePath"
        try {
            # 15s timeout -- JSON metadata responses are small
            return (Invoke-RestMethod -Uri $proxyUrl -UseBasicParsing `
                -Headers $script:ProxyHeaders -ErrorAction Stop -TimeoutSec 15)
        } catch {
            if (-not $AllowFallback) {
                throw "Content proxy request failed for $RelativePath from ${proxyUrl}: $_"
            }
            Write-Verbose "Proxy request failed for $RelativePath, falling back to public URL: $_"
        }
    }

    $url = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/$RelativePath"
    return (Invoke-RestMethod -Uri $url -UseBasicParsing -Headers $script:NoCacheHeaders -ErrorAction Stop -TimeoutSec 15)
}

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

# ── Nova file logging ───────────────────────────────────────────────────────
# Start structured file logging for the build phase.
Start-NovaLog -Path (Join-Path $WorkDir 'Nova-Build.log')
Write-Section 'Nova Trigger -- Build Phase'
Write-Data -Label 'Build Parameters' -Data @{
    GitHubUser   = $GitHubUser
    GitHubRepo   = $GitHubRepo
    GitHubBranch = $GitHubBranch
    WorkDir      = $WorkDir
    NoReboot     = "$NoReboot"
    AcceptDefaults = "$AcceptDefaults"
}
Write-Detail "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Detail "OS: $([System.Environment]::OSVersion.VersionString)"

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
        Write-Section 'Locating WinRE Base Image'
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
    Write-Section 'Mounting Boot Image'
    Write-Step 'Mounting boot.wim...'
    Write-Detail "Image path: $($paths.BootWim)"
    Write-Detail "Mount directory: $($paths.MountDir)"
    $null = Mount-WindowsImage -ImagePath $paths.BootWim -Index 1 -Path $paths.MountDir
    Write-Success 'boot.wim mounted.'

    $retryWithISOWinRE = $false   # set to $true inside the try if version mismatch detected
    try {
        # ── 3. Slim WinRE by removing recovery tools (not needed for deployment) ──
        if ($usingWinRE) {
            Remove-WinRERecoveryPackage -MountDir $paths.MountDir
        }

        # ── 4. Inject optional components ────────────────────────────────────
        Write-Section 'Injecting WinPE Components'
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
                $dest = Join-Path $customDest $f
                try {
                    Invoke-RepoDownload -RelativePath "resources/autopilot/$f" -OutFile $dest
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
        Write-Section 'Staging Scripts and Modules'
        # Download ALL files first, then load the manifest last to minimise the
        # window for CDN split-brain (file vs manifest out of sync).  If any
        # hash check fails, retry once after a short delay to handle propagation.

        # ── 5a. Embed Bootstrap.ps1 ───────────────────────────────────────────
        $bootstrapDest = Join-Path $paths.MountDir 'Windows\System32\Bootstrap.ps1'
        Write-Step 'Fetching Bootstrap.ps1'
        Invoke-RepoDownload -RelativePath 'src/scripts/Bootstrap.ps1' -OutFile $bootstrapDest

        # ── 5b. Pre-stage Nova.ps1 ──────────────────────────────────────
        # Embedding Nova.ps1 eliminates the internet dependency at boot time.
        # Bootstrap.ps1 will use this local copy instead of downloading it.
        $novaDest = Join-Path $paths.MountDir 'Windows\System32\Nova.ps1'
        Write-Step 'Fetching Nova.ps1'
        Invoke-RepoDownload -RelativePath 'src/scripts/Nova.ps1' -OutFile $novaDest

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
                    $dest = Join-Path $modDir "$mod$ext"
                    try {
                        Invoke-RepoDownload -RelativePath "src/modules/$mod/$mod$ext" -OutFile $dest
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
        $hashesJson = $null
        try {
            $hashesJson = Invoke-RepoRestMethod -RelativePath 'config/hashes.json'
            Write-Success 'Integrity manifest loaded.'
        } catch {
            throw "Could not load integrity manifest -- aborting build: $_"
        }

        # ── 5e. Verify script integrity (with CDN retry) ─────────────────────
        $integrityParams = @{
            HashesJson      = $hashesJson
            RetryOnMismatch = $true
            NoCacheHeaders  = $script:NoCacheHeaders
        }
        if ($script:ProxyBaseUrl -and $script:ProxyHeaders) {
            $integrityParams['ProxyBaseUrl']  = $script:ProxyBaseUrl
            $integrityParams['ProxyHeaders']  = $script:ProxyHeaders
        }
        Confirm-FileIntegrity -Path $bootstrapDest -RelativeName 'src/scripts/Bootstrap.ps1' @integrityParams
        Confirm-FileIntegrity -Path $novaDest -RelativeName 'src/scripts/Nova.ps1' @integrityParams

        # ── 5f. Verify module integrity (iex scenario) ────────────────────────
        if (-not ($modulesSrc -and (Test-Path $modulesSrc))) {
            $verifyExts = @('.psm1', '.psd1')
            foreach ($mod in $moduleNames) {
                foreach ($ext in $verifyExts) {
                    $modFile = Join-Path $modulesDest "$mod\$mod$ext"
                    $relName = "src/modules/$mod/$mod$ext"
                    if (Test-Path $modFile) {
                        Confirm-FileIntegrity -Path $modFile -RelativeName $relName @integrityParams
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
            $progressFile = Join-Path $progressDest 'index.html'
            try {
                Invoke-RepoDownload -RelativePath 'src/web/progress/index.html' -OutFile $progressFile
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
            $uiFile = Join-Path $uiDest 'index.html'
            try {
                Invoke-RepoDownload -RelativePath 'src/web/nova-ui/index.html' -OutFile $uiFile
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
        --disable-web-security ^
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
    Write-Section 'Finalizing Boot Image'
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

# Invoke-M365Auth is now provided by the Nova.Auth module.

#region ── Main ─────────────────────────────────────────────────────────────────

Write-Host @"

 ███╗   ██╗ ██████╗ ██╗   ██╗ █████╗
 ████╗  ██║██╔═══██╗██║   ██║██╔══██╗
 ██╔██╗ ██║██║   ██║██║   ██║███████║
 ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║
 ██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║
 ╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝

 Cloud-only Imaging Engine · amd64/x86 · https://github.com/$GitHubUser/$GitHubRepo
"@ -ForegroundColor Cyan

try {
    # ── 0. M365 authentication gate ──────────────────────────────────────────
    Write-Section 'Authentication'
    Write-Info 'Checking M365 authentication requirements...'
    $authResult = Invoke-M365Auth `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
    if (-not $authResult.Authenticated) {
        Write-Fail 'Authentication is required. Exiting.'
        exit 1
    }
    Write-Success 'Authentication passed'
    if ($authResult.GraphAccessToken) {
        $script:GraphAccessToken = $authResult.GraphAccessToken
        Write-Detail 'Graph access token acquired'
    }

    # ── Configure content proxy (private repo support) ───────────────────
    # If $ProxyBaseUrl was not explicitly provided, auto-detect from auth config.
    if (-not $ProxyBaseUrl -and $authResult.AuthConfig -and
        $authResult.AuthConfig.PSObject.Properties['githubOAuthProxy'] -and
        $authResult.AuthConfig.githubOAuthProxy) {
        $ProxyBaseUrl = $authResult.AuthConfig.githubOAuthProxy
    }
    if ($ProxyBaseUrl) {
        $script:ProxyBaseUrl = $ProxyBaseUrl.TrimEnd('/')
        if ($script:GraphAccessToken) {
            $script:ProxyHeaders = @{
                'Authorization' = "Bearer $($script:GraphAccessToken)"
            }
            Write-Detail "Content proxy configured: $script:ProxyBaseUrl"
        } else {
            Write-Detail 'Content proxy URL set but no access token available -- using public downloads'
            $script:ProxyBaseUrl = $null
        }
    }

    # ── 1. Detect architecture ────────────────────────────────────────────────
    Write-Section 'System Detection'
    $arch = Get-WinPEArchitecture
    Write-Step "Host architecture: $arch"
    Write-Detail "Firmware type: $(Get-FirmwareType)"

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
        Write-Section 'Creating BCD Boot Entry'
        Write-Info 'Creating ramdisk BCD entry for WinPE boot'
        New-BCDRamdiskEntry `
            -BootWim    $paths.BootWim `
            -RamdiskDir $script:RamdiskDir `
            -MediaDir   $paths.MediaDir
    }

    Write-Section 'Build Complete'
    Write-Host "`n  [Nova] All done -- system is primed for cloud boot." -ForegroundColor Green
    Stop-NovaLog

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
    Write-Section 'Build Failed'
    Write-Fail "Fatal: $_"
    Write-Detail "Stack trace: $($_.ScriptStackTrace)"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Stop-NovaLog
    exit 1
}

#endregion
}

# SIG # Begin signature block
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBEUWUCdIKBHyx6
# eCadcrd2q7hd4Fww9XfE6L9l4iyXyKCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAABSQY7l
# 84XZvuWtAAAAAFJBMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNDE0MTQyMDU2WhcNMjYwNDE3
# MTQyMDU2WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQDiaaDsBkHK33PY
# y2N3c9H0WYuaS6zfCnNxJyAXwLl5/5IT5aCUSfXRZlopdexI3LGzdGlKPNTVpHMZ
# QES4+lybTKWuS1TBovX1yNXcFZL69YENBSPI+KtqIsPVevodOeWfzezWUYFlD6B0
# fP4mhQT4XUtF7V1+ULJ5O4f1vlHugoXtpYs2t2Gv2hU4kRtA4MGh3fsJcyifb751
# 4Q96Vo4ADMWsr1DNNIkdO/+3F/Gn2Q+Iq3UknXFT8PD4yl25OaEsMQe1tk9sPupo
# Z8RIkXWdqbfTWvIJvw/EREIqAQ8jTCMTZpb352JoH9f9DeOAUDb8PTIgGUyekZxK
# ZazRrgF3Uj/Ffb29viRKTCBgVaw1/ouPVsJ3ZMZgVaQoQiEYHfu+jRP0Jk3ve+Y4
# O5FMzBVh1qPh48akw41SNpZiZNNhg3cQ/SUHbkFaoRQ2IRbLSZnryEXjZloC2RO5
# mj1Do2BN4ib1qsiIUWVoa70Fy/sdNW2HswU2RNB82Gxk73sfft8CAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUuIt05EZ/8gwAGTL+u0c6lJfmskQwHwYDVR0jBBgwFoAUa16lNMMF
# xWJKIVqOq3NgYtSsY4UwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMy5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAGhA2xIUuTvm6OOZjzD9zV83DdPaQDYV3on1pi4Dho+ne+Rd6huJVA+X
# h+uWEyglV1cZ4scWfl+2JerD6SyFQSpBR8NKcCFjsDh4qlQjegPPq1iYPubmCGsd
# xXV1k+8nF6RCRhQNsD0EN2yWosjFkKV4ksB1za9yKTpo4MY+RyD4PVUxBKkDr/FT
# e+MDK1oB6OwQwYD+DC1ApwBdAbfY4A5XY6NLpQLjo5bz6L5vXanejrwxKjzQXob5
# aXnjCz27AGCNddicZmJ+3pyocUUB3DnVo6xeG5iPnPb/3oT77AghHJ+EmNxJWjc8
# MKjZskbZiC47pt/HXGEilWZ7RH/8WBiydlY4sQIOIBmZy53G+Ed53l7kyO6iTx0n
# fR5r66/iyeXNmU7jfcn0eMHtNR5X1ZOYENsF/v1xyRwyjJcRyJgQdmzfUNJQhKqJ
# J5QIN1d5aprYLvjmsQRU9Maz9K1afjGu+Y4T/tJM9mO4KdNwC0VM81pwO6l4gGw3
# o7xRNcud74cZRYyt7X0W9z1Mf/ZDobF1IchSiKfpTZ2p2vHwxZ10GIYLjUAQPPIw
# Df+6EQFXYoASJJjcmwlg5GOHFmEM6YQ2bPle9X7ilNDRtPclWV4N59CS3ovAokYn
# W1CgY3T34Y2V96NMn/Qk1Ov+zL/4AnO2ds+9KjXiRn0se5mm6JevMIIGyTCCBLGg
# AwIBAgITMwAAUkGO5fOF2b7lrQAAAABSQTANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMB4XDTI2MDQxNDE0
# MjA1NloXDTI2MDQxNzE0MjA1NlowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEA4mmg7AZByt9z2Mtjd3PR9FmLmkus3wpzcScgF8C5ef+SE+WglEn10WZaKXXs
# SNyxs3RpSjzU1aRzGUBEuPpcm0ylrktUwaL19cjV3BWS+vWBDQUjyPiraiLD1Xr6
# HTnln83s1lGBZQ+gdHz+JoUE+F1LRe1dflCyeTuH9b5R7oKF7aWLNrdhr9oVOJEb
# QODBod37CXMon2++deEPelaOAAzFrK9QzTSJHTv/txfxp9kPiKt1JJ1xU/Dw+Mpd
# uTmhLDEHtbZPbD7qaGfESJF1nam301ryCb8PxERCKgEPI0wjE2aW9+diaB/X/Q3j
# gFA2/D0yIBlMnpGcSmWs0a4Bd1I/xX29vb4kSkwgYFWsNf6Lj1bCd2TGYFWkKEIh
# GB37vo0T9CZN73vmODuRTMwVYdaj4ePGpMONUjaWYmTTYYN3EP0lB25BWqEUNiEW
# y0mZ68hF42ZaAtkTuZo9Q6NgTeIm9arIiFFlaGu9Bcv7HTVth7MFNkTQfNhsZO97
# H37fAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFLiLdORGf/IMABky/rtHOpSX5rJEMB8GA1Ud
# IwQYMBaAFGtepTTDBcViSiFajqtzYGLUrGOFMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDAzLmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBoQNsSFLk75ujjmY8w/c1fNw3T2kA2Fd6J9aYu
# A4aPp3vkXeobiVQPl4frlhMoJVdXGeLHFn5ftiXqw+kshUEqQUfDSnAhY7A4eKpU
# I3oDz6tYmD7m5ghrHcV1dZPvJxekQkYUDbA9BDdslqLIxZCleJLAdc2vcik6aODG
# Pkcg+D1VMQSpA6/xU3vjAytaAejsEMGA/gwtQKcAXQG32OAOV2OjS6UC46OW8+i+
# b12p3o68MSo80F6G+Wl54ws9uwBgjXXYnGZift6cqHFFAdw51aOsXhuYj5z2/96E
# ++wIIRyfhJjcSVo3PDCo2bJG2YguO6bfx1xhIpVme0R//FgYsnZWOLECDiAZmcud
# xvhHed5e5Mjuok8dJ30ea+uv4snlzZlO433J9HjB7TUeV9WTmBDbBf79cckcMoyX
# EciYEHZs31DSUISqiSeUCDdXeWqa2C745rEEVPTGs/StWn4xrvmOE/7STPZjuCnT
# cAtFTPNacDupeIBsN6O8UTXLne+HGUWMre19Fvc9TH/2Q6GxdSHIUoin6U2dqdrx
# 8MWddBiGC41AEDzyMA3/uhEBV2KAEiSY3JsJYORjhxZhDOmENmz5XvV+4pTQ0bT3
# JVleDefQkt6LwKJGJ1tQoGN09+GNlfejTJ/0JNTr/sy/+AJztnbPvSo14kZ9LHuZ
# puiXrzCCBygwggUQoAMCAQICEzMAAAAVBT5uGY6TKdkAAAAAABUwDQYJKoZIhvcN
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
# UyBFT0MgQ0EgMDMCEzMAAFJBjuXzhdm+5a0AAAAAUkEwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgavCLWHa80wpmomc3cdwgWFNEifwHSjpE6w2faMmZWiEw
# DQYJKoZIhvcNAQEBBQAEggGAnuZiKe76OzBWpEbrDMlu8PjdJf25g5azi7oointz
# mknDB5Ro8KL1MRiUbQpMOAaGnvSwnJrfBQRUFnsW0qXPWSPw7FCVRJetidxHgfPt
# oicISHslQCk5Hfb+oXOvwvEXQeym0z14nftWIZ9fC3r27OXzgr5yONfEVjnlerp1
# kTu6LF8hsM4HobFITwuIhP19jTfg/C1jjceTq7Qi4y1hJ/aCz5t5S0tiUToiOOPi
# lOVS6lo6JAAWHBQZ6xGXe7Zs05k58E0kJL7xeaIWCz7qFstyyzBB2ss0bllglYNl
# bmlWJpq1nOTYzKlzZBXlKA5o5C9YnWz36zGThR7YXM4UMwxhnjKQdeTXUiNVsd+S
# 5QeYsxgl/Y3GKTmP0J9+RUtypnF8JDUZ3Ml2FBmlQidVIgtJ3t7AqrKlR0TzWNvH
# ufcA/SKkCGuSZ8nFXRXWMdMk7YpS8zFImA7D5KQHGoZ9aPtaaAE3ECK6OVJV73vD
# +omfq0Xh+PssILj/NQYTTgkzoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIH5qwVXtW9MMb/dJ7dzzz58J046+cW4OA4mxjg7Q/+QuAgZpwnLdeS8YEzIw
# MjYwNDE1MDgxMjQ1LjE2NFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
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
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDE1MDgxMjQ1WjAvBgkqhkiG9w0B
# CQQxIgQgZmFcCuJLG4YLf0xtAENkM9BDUr60XXQrzWjencScvz0wgbkGCyqGSIb3
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
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2JSV0wIhgPMjAyNjA0
# MTQyMzE2NDVaGA8yMDI2MDQxNTIzMTY0NVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7YlJXQIBADAHAgEAAgIBgTAHAgEAAgIS5DAKAgUA7Yqa3QIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCo7N1LD1wTXtWi98e/AP60M73mKNO2JykanfEa
# 0xwy9w/MR3ht5hAsjfCZCPm8j+5sDOZY6Kav+05iHju74g9F9IDT50MQm1TKTvjx
# UsZaBQ8Av23i0f85TedPt9NBQQBLfPmMqTNsfTJ1SEZncxqSc8MO3vZ3IC8iN8Rp
# QrBObK+kY2+knH7gL4GhM8e1z9vJnxyX1AK++GIxNxZlK5GRjQ1F4du/4t71e8xg
# r4at7pj/v6Z7pn9tNfLiuuIid3i/GXfkCfyLaxzn5FQGFnUIId2oGsKuMuyrOrac
# KnvCEbNt8NebwNu8TFtAnixEno8rVbk8RNFMiN+jyiR9x/vuMA0GCSqGSIb3DQEB
# AQUABIICAJxhN/Vo41Y+PtsHln0fp8e+037rkE6bldNuLHpqHzIrLsvtHPykAeJk
# J9Ddt1OhZlcpjMUxd7ZHqRK4JIJInGMYL3cuV1Egtiyx7nyKDf2w7cLDKMDCSrFO
# MZLg2C1Bro/dKcn33zivdAAwSj6mALH/2tTwIaHrnS4ESrIAa7y9CpXX0PtQefxB
# q5LINuB4UmnOBwzwFtE0Cr4vEVsAsUfAvtM3rhrsEQxXrtEpqH7yWrPd45ijcrEY
# KB+xly4By2u1vVA/7ZTH6rxu/VGF7sK9MJoXLJtsI5Sh+fLPRSbnHghUAqHapsr6
# PehnMVwNP+RNkQ3xi7zXp2TXp9VPc2TOsnaV2MdFplNPMxrgjz5U7qsBdCwbIvft
# qoePKh2KlMkOESBRjAEIZy/5GScMF3e3IZV3DXf+XLaqmyYuYG7C20bSNXNjkMx0
# m/Eo5o4Q675hxT42WHSP0kbCt3gMYKb+2wNxEDlvIPUZb6hMKAYCoxFkVXqSxyap
# eoMBhkbLShgdEb89INOiqfM/PWOo2Y9r5zhAWhdotZc+CQtM0C5nyXcGO2gT/jgT
# SvDxpco65+cjv4WgYNg51EDIxrfLo4tzRHrfPFBeQvsfJV7uHRrJpjDIih88MpCV
# zI+27op9mOZWQERLXhNjqzTSD8kgCr/m38D8JP5tT38U8Tyfsmxg
# SIG # End signature block

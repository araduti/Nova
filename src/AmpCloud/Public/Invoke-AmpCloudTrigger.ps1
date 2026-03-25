function Invoke-AmpCloudTrigger {
    <#
    .SYNOPSIS
        AmpCloud Trigger - GitHub-native OSDCloud replacement entry point.

    .DESCRIPTION
        One-liner entry point. Runs on any Windows PC.
        - Auto-installs the Windows ADK + WinPE add-on if missing.
        - Presents an interactive configuration menu (preselected with sensible
          defaults) that lets OSD admins choose which ADK packages, language packs,
          and drivers to include in the boot image before building.
        - Builds a custom boot image in pure PowerShell (no copype.cmd / cmd.exe).
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
        must be extracted.

    .PARAMETER NoReboot
        Build everything but do NOT reboot. Useful for testing.

    .EXAMPLE
        Invoke-AmpCloudTrigger

    .EXAMPLE
        Invoke-AmpCloudTrigger -NoReboot -WorkDir D:\AmpCloud

    .EXAMPLE
        Invoke-AmpCloudTrigger -WindowsISOUrl 'D:\ISOs\Win11_x86.iso'
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $GitHubUser      = 'araduti',
        [ValidateNotNullOrEmpty()]
        [string] $GitHubRepo      = 'AmpCloud',
        [ValidateNotNullOrEmpty()]
        [string] $GitHubBranch    = 'main',
        [ValidateNotNullOrEmpty()]
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

    #region ── Main ─────────────────────────────────────────────────────────────────

    Write-Host @"

  █████╗ ███╗   ███╗██████╗  ██████╗██╗      ██████╗ ██╗   ██╗██████╗
 ██╔══██╗████╗ ████║██╔══██╗██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗
 ███████║██╔████╔██║██████╔╝██║     ██║     ██║   ██║██║   ██║██║  ██║
 ██╔══██║██║╚██╔╝██║██╔═══╝ ██║     ██║     ██║   ██║██║   ██║██║  ██║
 ██║  ██║██║ ╚═╝ ██║██║     ╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝
 ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝      ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝

 Cloud-only OSDCloud replacement · amd64/x86 · https://github.com/$GitHubUser/$GitHubRepo
"@ -ForegroundColor Cyan

    try {
        # ── 0. M365 authentication gate ──────────────────────────────────────────
        $authPassed = Invoke-TriggerM365Auth
        if (-not $authPassed) {
            Write-Fail -Message 'Authentication is required. Exiting.' -Prefix '  [X]'
            exit 1
        }

        # ── 1. Detect architecture ────────────────────────────────────────────────
        $arch = Get-WinPEArchitecture
        Write-Step -Message "Host architecture: $arch" -Prefix '  [>]'

        # ── 1b. Check for a pre-built cloud boot image ──────────────────────────
        Write-Step -Message 'Checking for pre-built boot image on GitHub...' -Prefix '  [>]'
        $cloudImage = Get-CloudBootImage -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo
        $useCloud   = $false

        if ($cloudImage) {
            $cloudSizeMB = '{0:N0}' -f ($cloudImage.BootWimSize / 1MB)
            Write-Host ''
            Write-Host '  A pre-built boot image is available on GitHub.' -ForegroundColor Green
            Write-Host "  Published : $($cloudImage.PublishedAt)"         -ForegroundColor Gray
            Write-Host "  Size      : $cloudSizeMB MB"                   -ForegroundColor Gray
            Write-Host ''
            Write-Host '  [1] Use the cloud image (faster — skips ADK install and image build)' -ForegroundColor White
            Write-Host '  [2] Rebuild locally'                                                  -ForegroundColor White
            $choice = Read-Host "`n  Enter choice (1 or 2) [default: 1]"
            if ($choice -ne '2') { $useCloud = $true }
        }

        if ($useCloud) {
            # ── Cloud path: download pre-built boot image ─────────────────────────
            $cloudDir   = Join-Path $WorkDir 'Cloud'
            $bootSubDir = Join-Path $cloudDir 'boot'
            $null = New-Item -ItemType Directory -Path $bootSubDir -Force

            $bootWimPath = Join-Path $cloudDir 'boot.wim'
            Write-Step -Message "Downloading boot.wim ($cloudSizeMB MB) — this may take a few minutes..." -Prefix '  [>]'
            $prevPref = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try     { Invoke-WebRequest -Uri $cloudImage.BootWimUrl -OutFile $bootWimPath -UseBasicParsing }
            finally { $ProgressPreference = $prevPref }
            Write-Success -Message 'boot.wim downloaded.' -Prefix '  [+]'

            if ($cloudImage.BootSdiUrl) {
                $bootSdiPath = Join-Path $bootSubDir 'boot.sdi'
                Write-Step -Message 'Downloading boot.sdi...' -Prefix '  [>]'
                $prevPref = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                try     { Invoke-WebRequest -Uri $cloudImage.BootSdiUrl -OutFile $bootSdiPath -UseBasicParsing }
                finally { $ProgressPreference = $prevPref }
                Write-Success -Message 'boot.sdi downloaded.' -Prefix '  [+]'
            } else {
                # boot.sdi was not in the release — fall back to the local ADK copy
                Write-Warn -Message 'boot.sdi not found in cloud release; obtaining from ADK...' -Prefix '  [!]'
                $adkRoot  = Assert-ADKInstalled -Architecture $arch
                $sdiSrc   = Join-Path $adkRoot `
                    "Assessment and Deployment Kit\Windows Preinstallation Environment\$arch\Media\boot\boot.sdi"
                if (Test-Path $sdiSrc) {
                    Copy-Item $sdiSrc (Join-Path $bootSubDir 'boot.sdi') -Force
                    Write-Success -Message 'boot.sdi obtained from ADK.' -Prefix '  [+]'
                } else {
                    Write-Warn -Message "boot.sdi not found at $sdiSrc — ramdisk boot will likely fail." -Prefix '  [!]'
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
            $buildConfig = Show-BuildConfiguration -Architecture $arch

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
                -InjectVirtIO      $buildConfig.InjectVirtIO `
                -ExtraDriverPaths  $buildConfig.ExtraDriverPaths

            # ── 2b. Offer to upload boot image to GitHub ─────────────────────────
            Write-Host ''
            $uploadChoice = Read-Host '  Upload this boot image to GitHub for future use? (y/N)'
            if ($uploadChoice -match '^[Yy]') {
                $tokenSecure = Read-Host '  GitHub Personal Access Token (repo scope)' -AsSecureString
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
                    Write-Success -Message 'Boot image published to GitHub Releases.' -Prefix '  [+]'
                } catch {
                    Write-Warn -Message "Upload failed (non-fatal): $_" -Prefix '  [!]'
                } finally {
                    $tokenPlain = $null
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }

            # ── 3. BCD ────────────────────────────────────────────────────────────
            New-BCDRamdiskEntry `
                -BootWim    $paths.BootWim `
                -RamdiskDir $script:RamdiskDir `
                -MediaDir   $paths.MediaDir
        }

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
        Write-Fail -Message "Fatal: $_" -Prefix '  [X]'
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        exit 1
    }

    #endregion
}

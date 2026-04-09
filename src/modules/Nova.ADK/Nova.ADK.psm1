<#
.SYNOPSIS
    Windows ADK detection, installation, and WinPE workspace setup for Nova.

.DESCRIPTION
    Provides functions to detect the Windows Assessment and Deployment Kit (ADK),
    install it if missing, and create WinPE working directory structures (pure
    PowerShell replacement for copype.cmd).
#>

Set-StrictMode -Version Latest

function Get-ADKRoot {
    <#
    .SYNOPSIS Returns the ADK installation root from the registry, or $null.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
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
    .PARAMETER Architecture  WinPE arch string (amd64 or x86). ARM is not supported.
    .OUTPUTS  [string] Validated ADK root path.
    #>
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('amd64', 'x86')]
        [string] $Architecture
    )

    Write-Step "Checking Windows ADK + WinPE add-on ($Architecture)..."

    $adkRoot  = Get-ADKRoot
    $winPEDir = if ($adkRoot) {
        Join-Path $adkRoot 'Assessment and Deployment Kit\Windows Preinstallation Environment'
    } else { $null }

    if ($adkRoot -and $winPEDir -and (Test-Path (Join-Path $winPEDir $Architecture))) {
        Write-Success "ADK found: $adkRoot"
        return $adkRoot
    }

    if (-not $PSCmdlet.ShouldProcess('Windows ADK + WinPE add-on', 'Download and install')) {
        return $null
    }

    Write-Warn 'ADK or WinPE add-on not found -- downloading installers...'

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

function Copy-WinPEFile {
    <#
    .SYNOPSIS
        Pure-PowerShell replacement for copype.cmd.
        Creates the standard WinPE working directory structure.
    .PARAMETER ADKRoot     ADK installation root returned by Get-ADKRoot / Assert-ADKInstalled.
    .PARAMETER Destination Target working directory (will be wiped if it exists).
    .PARAMETER Architecture  amd64 (default) or x86. ARM is not supported.
    .OUTPUTS   [hashtable] Keys: MediaDir, MountDir, BootWim
    #>
    [OutputType([hashtable])]
    [CmdletBinding(SupportsShouldProcess)]
    param(        [string] $ADKRoot,
        [string] $Destination,
        [ValidateSet('amd64','x86')]
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
        # Locate winpe.wim -- some ADK layouts store it under the arch subdir, others at the root
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

    if (-not $PSCmdlet.ShouldProcess($Destination, 'Create WinPE workspace')) {
        return $null
    }

    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $mediaDir, $mountDir, $sourcesDir -Force

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

Export-ModuleMember -Function Get-ADKRoot, Assert-ADKInstalled, Copy-WinPEFile

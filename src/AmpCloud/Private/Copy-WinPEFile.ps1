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
    param(
        [string] $ADKRoot,
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

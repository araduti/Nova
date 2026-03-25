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
    $null = New-Item -ItemType Directory -Path $RamdiskDir -Force

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
    $null = Invoke-Bcdedit '/set', $rdGuid, 'ramdisksdidevice', "partition=$drive"
    $null = Invoke-Bcdedit '/set', $rdGuid, 'ramdisksdipath',   $sdiBcd
    Write-Success "Ramdisk options: $rdGuid"

    # ── OS loader ─────────────────────────────────────────────────────────────
    $fw      = Get-FirmwareType
    $winload = if ($fw -eq 'UEFI') { '\windows\system32\winload.efi' } `
                                   else { '\windows\system32\winload.exe' }
    Write-Step "Firmware type: $fw  →  $winload"

    $ramdiskVal = "[$drive]$wimBcd,$rdGuid"
    $osGuid     = New-BcdEntry '/create', '/d', 'AmpCloud Boot', '/application', 'osloader'

    $null = Invoke-Bcdedit '/set', $osGuid, 'device',     "ramdisk=$ramdiskVal"
    $null = Invoke-Bcdedit '/set', $osGuid, 'osdevice',   "ramdisk=$ramdiskVal"
    $null = Invoke-Bcdedit '/set', $osGuid, 'path',       $winload
    $null = Invoke-Bcdedit '/set', $osGuid, 'systemroot', '\windows'
    $null = Invoke-Bcdedit '/set', $osGuid, 'detecthal',  'yes'
    $null = Invoke-Bcdedit '/set', $osGuid, 'winpe',      'yes'
    $null = Invoke-Bcdedit '/set', $osGuid, 'nx',         'OptIn'
    $null = Invoke-Bcdedit '/set', $osGuid, 'ems',        'no'

    # Add to menu and arm as one-time next boot
    $null = Invoke-Bcdedit '/displayorder', $osGuid, '/addlast'
    $null = Invoke-Bcdedit '/bootsequence', $osGuid

    Write-Success "OS loader entry: $osGuid (armed as one-time next boot)"
    return $osGuid
}

<#
.SYNOPSIS
    BCD (Boot Configuration Data) management module for Nova.
.DESCRIPTION
    Provides functions for creating and managing BCD ramdisk boot entries
    used to boot into WinPE from a full Windows installation.
#>

Set-StrictMode -Version Latest
function Invoke-Bcdedit {
    <#
    .SYNOPSIS  Thin wrapper around bcdedit.exe with strict error checking.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([string[]] $Arguments)
    $output = & bcdedit.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit $($Arguments -join ' ') -> exit $LASTEXITCODE`n$output"
    }
    return $output
}
function New-BcdEntry {
    <#
    .SYNOPSIS  Creates a BCD entry and returns its GUID string, e.g. {abc123...}.
    #>
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]] $CreateArgs)
    if (-not $PSCmdlet.ShouldProcess($CreateArgs, 'New-BcdEntry')) { return }
    $output = Invoke-Bcdedit $CreateArgs
    if ($output -match '\{([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\}') {
        return "{$($Matches[1])}"
    }
    throw "Could not parse GUID from bcdedit output: $output"
}
function New-BCDRamdiskEntry {
    <#
    .SYNOPSIS  Stages boot files and creates a one-time BCD ramdisk boot entry.
    .OUTPUTS   [string] OS loader GUID.
    #>
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess)]
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
        Write-Warn "boot.sdi not found at $sdiSrc -- ramdisk boot will likely fail."
    }
    # Copy WIM
    $wimDest = Join-Path $RamdiskDir 'boot.wim'
    Copy-Item $BootWim $wimDest -Force
    Write-Success "boot.wim staged."
    # BCD path components
    $drive  = Split-Path $RamdiskDir -Qualifier          # C:
    $relDir = (Split-Path $RamdiskDir -NoQualifier).TrimEnd('\') # \Nova\Boot
    $wimBcd = "$relDir\boot.wim"
    $sdiBcd = "$relDir\boot.sdi"
    Write-Step 'Writing BCD entries...'
    # -- Ramdisk device options ------------------------------------------------
    $rdGuid = New-BcdEntry '/create', '/d', 'Nova Ramdisk Options', '/device'
    $null = Invoke-Bcdedit '/set', $rdGuid, 'ramdisksdidevice', "partition=$drive"
    $null = Invoke-Bcdedit '/set', $rdGuid, 'ramdisksdipath',   $sdiBcd
    Write-Success "Ramdisk options: $rdGuid"
    # -- OS loader -------------------------------------------------------------
    $fw      = Get-FirmwareType
    $winload = if ($fw -eq 'UEFI') { '\windows\system32\winload.efi' } `
                                   else { '\windows\system32\winload.exe' }
    Write-Step "Firmware type: $fw  ->  $winload"
    $ramdiskVal = "[$drive]$wimBcd,$rdGuid"
    $osGuid     = New-BcdEntry '/create', '/d', 'Nova Boot', '/application', 'osloader'
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
Export-ModuleMember -Function @(
    'Invoke-Bcdedit'
    'New-BcdEntry'
    'New-BCDRamdiskEntry'
)

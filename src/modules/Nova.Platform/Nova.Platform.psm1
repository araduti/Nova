<#
.SYNOPSIS
    Platform detection and file utility module for Nova scripts.

.DESCRIPTION
    Provides functions shared across Nova.ps1 and Trigger.ps1 for firmware
    detection, CPU architecture mapping, and human-readable file size formatting.
    These pure utility functions have no external module dependencies.
#>

function Get-FirmwareType {
    <#
    .SYNOPSIS  Returns 'UEFI' or 'BIOS' using multiple detection methods.

    .NOTES
        Primary:   PEFirmwareType registry value (1 = BIOS, 2 = UEFI).
        Fallback:  Confirm-SecureBootUEFI — available on all Win8+ systems; throws
                   System.PlatformNotSupportedException on non-UEFI firmware, returns
                   $true/$false on UEFI (regardless of Secure Boot state).
    #>
    # Primary: PEFirmwareType registry value written by the kernel at boot
    try {
        $val = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' `
                                 -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
        if ($val -eq 2) { return 'UEFI' }
        if ($val -eq 1) { return 'BIOS' }
        # Any other value (e.g. 0 = unknown) — fall through to secondary check
    } catch { Write-Verbose "Registry firmware type unavailable: $_" }

    # Fallback: Confirm-SecureBootUEFI throws PlatformNotSupportedException on BIOS
    try {
        $null = Confirm-SecureBootUEFI   # $true (SB on) or $false (SB off) on UEFI
        return 'UEFI'
    } catch [System.PlatformNotSupportedException] {
        return 'BIOS'
    } catch {
        Write-Warning "Confirm-SecureBootUEFI failed ($($_.Exception.Message)) — assuming UEFI."
    }

    return 'UEFI'
}

function Get-WinPEArchitecture {
    <#
    .SYNOPSIS
        Maps the current OS CPU architecture to the WinPE folder/package name
        used by the ADK. Nova supports amd64 and x86 only — ARM is not
        supported because Nova is a cloud-only deployment engine targeting
        x86-64 enterprise hardware.
    #>
    $map = @{
        'AMD64' = 'amd64'
        'x86'   = 'x86'
    }
    $proc = $env:PROCESSOR_ARCHITECTURE   # AMD64 | x86
    $arch = $map[$proc]
    if (-not $arch) {
        throw "Unsupported processor architecture '$proc'. Nova supports amd64 and x86 only. ARM is not supported."
    }
    return $arch
}

function Get-FileSizeReadable {
    <#
    .SYNOPSIS  Converts a byte count to a human-readable string (GB / MB / KB / B).
    #>
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

Export-ModuleMember -Function Get-FirmwareType, Get-WinPEArchitecture, Get-FileSizeReadable

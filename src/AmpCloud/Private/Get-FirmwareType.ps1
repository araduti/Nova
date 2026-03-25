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
        Write-Warn "Confirm-SecureBootUEFI failed ($($_.Exception.Message)) — assuming UEFI."
    }

    return 'UEFI'
}

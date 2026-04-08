<#
.SYNOPSIS
    Disk partitioning module for Nova deployment engine.

.DESCRIPTION
    Provides functions for target disk selection and partitioning (GPT/UEFI
    and MBR/BIOS layouts) including EFI System Partition, Microsoft Reserved,
    OS, and optional Recovery partitions.
#>

# ── Constants ────────────────────────────────────────────────────────────────

# Partition GUIDs (GPT type identifiers)
$script:GptTypeEsp = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'   # EFI System Partition
$script:GptTypeMsr = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'   # Microsoft Reserved
$script:GptTypeBasicData = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'   # Basic Data (OS)
$script:GptTypeRecovery = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'   # Windows Recovery (WinRE)

# Partition sizes
$script:EspSize = 260MB
$script:MsrSize = 16MB
$script:MbrSystemSize = 500MB
$script:DefaultRecoverySize = 990MB
$script:MinimumOsPartitionSize = 20GB

# ── Public Functions ─────────────────────────────────────────────────────────

function Get-PartitionGuid {
    <#
    .SYNOPSIS  Returns the GPT type GUID constants used by Nova for partitioning.
    #>
    [CmdletBinding()]
    param()
    return @{
        Esp       = $script:GptTypeEsp
        Msr       = $script:GptTypeMsr
        BasicData = $script:GptTypeBasicData
        Recovery  = $script:GptTypeRecovery
    }
}

function Get-TargetDisk {
    <#
    .SYNOPSIS  Resolves and validates the target disk for imaging.
    .DESCRIPTION
        When DiskNumber is -1 (auto-select), picks the largest non-removable
        disk.  Otherwise validates the specified disk number exists.
    #>
    [CmdletBinding()]
    param(
        [int]$DiskNumber
    )

    if ($DiskNumber -eq -1) {
        # Auto-select: pick the largest non-removable, non-USB disk
        $disk = Get-Disk | Where-Object {
            $_.BusType -ne 'USB' -and
            -not $_.IsReadOnly -and
            $_.OperationalStatus -eq 'Online'
        } | Sort-Object Size -Descending | Select-Object -First 1

        if (-not $disk) {
            throw 'Auto-select failed: no eligible disks found (excluding USB and read-only)'
        }
        Write-Step "Auto-selected disk $($disk.Number): $($disk.FriendlyName) ($(Get-FileSizeReadable $disk.Size))"
        return $disk.Number
    }

    # Validate specified disk exists
    $null = Get-Disk -Number $DiskNumber -ErrorAction Stop
    return $DiskNumber
}

function Initialize-TargetDisk {
    <#
    .SYNOPSIS  Clears and partitions a target disk for Windows deployment.
    .DESCRIPTION
        Wipes the specified disk, creates the required partition layout for the
        given firmware type (GPT for UEFI, MBR for BIOS), and optionally adds
        a recovery partition.
    .PARAMETER DiskNumber
        Physical disk number to initialise (e.g. 0).
    .PARAMETER FirmwareType
        Firmware type: 'UEFI' creates a GPT layout, 'BIOS' creates MBR.
    .PARAMETER OSDriveLetter
        Drive letter to assign to the Windows (OS) partition.
    .PARAMETER CreateRecoveryPartition
        When set, appends a recovery partition at the end of the disk.
    .PARAMETER RecoveryPartitionSize
        Size of the recovery partition in bytes. Defaults to the module default.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$DiskNumber,
        [string]$FirmwareType,
        [string]$OSDriveLetter,
        [switch]$CreateRecoveryPartition,
        [long]$RecoveryPartitionSize = $script:DefaultRecoverySize
    )

    if (-not $PSCmdlet.ShouldProcess("Disk $DiskNumber", 'Clear and partition for Windows deployment')) {
        return
    }

    Write-Step "Initializing disk $DiskNumber (Firmware: $FirmwareType)..."

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop

    Write-Host "  Disk: $($disk.FriendlyName) | Size: $(Get-FileSizeReadable $disk.Size) | Status: $($disk.OperationalStatus)"

    # Clear the disk
    Write-Step "Clearing disk $DiskNumber..."
    $clearError = $null
    try {
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    } catch {
        $clearError = $_
        Write-Warn "Clear-Disk failed on disk ${DiskNumber}: $clearError"
    }

    $stepName = ''
    try {

    if ($FirmwareType -eq 'UEFI') {
        # Initialize as GPT
        $stepName = 'Initialize-Disk (GPT)'
        Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop

        # EFI System Partition (ESP)
        $stepName = 'New-Partition (ESP)'
        $esp = New-Partition -DiskNumber $DiskNumber -Size $script:EspSize -GptType $script:GptTypeEsp
        $stepName = 'Format-Volume (ESP FAT32)'
        $null = Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false
        $stepName = 'Add-PartitionAccessPath (ESP)'
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AssignDriveLetter

        # Microsoft Reserved Partition (MSR)
        $stepName = 'New-Partition (MSR)'
        $null = New-Partition -DiskNumber $DiskNumber -Size $script:MsrSize -GptType $script:GptTypeMsr

        # Windows OS Partition
        $stepName = 'New-Partition (OS)'
        if ($CreateRecoveryPartition) {
            # Reserve space for the recovery partition at the end of the disk
            $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
            $usedSpace = $script:EspSize + $script:MsrSize + $RecoveryPartitionSize
            # Additional overhead for GPT metadata (~1 MB each side)
            $osSize = $disk.Size - $usedSpace - 2MB
            if ($osSize -lt $script:MinimumOsPartitionSize) {
                throw "Insufficient disk space for OS partition with recovery. Available: $(Get-FileSizeReadable $osSize)"
            }
            $osPartition = New-Partition -DiskNumber $DiskNumber -Size $osSize -GptType $script:GptTypeBasicData
        } else {
            $osPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -GptType $script:GptTypeBasicData
        }
        $stepName = 'Format-Volume (OS NTFS)'
        $null = $osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false
        # Format-Volume may auto-assign the drive letter; only reassign if needed.
        $stepName = 'Set-Partition (drive letter)'
        $currentLetter = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber).DriveLetter
        if ([string]$currentLetter -ne [string]$OSDriveLetter) {
            # Free the target letter if another partition already owns it
            $conflict = Get-Partition | Where-Object { $_.DriveLetter -eq $OSDriveLetter } | Select-Object -First 1
            if ($conflict) {
                Remove-PartitionAccessPath -DiskNumber $conflict.DiskNumber -PartitionNumber $conflict.PartitionNumber -AccessPath "${OSDriveLetter}:\"
            }
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $OSDriveLetter
        }

        # Recovery Partition (optional, UEFI only)
        if ($CreateRecoveryPartition) {
            $stepName = 'New-Partition (Recovery)'
            $recPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -GptType $script:GptTypeRecovery
            $stepName = 'Format-Volume (Recovery NTFS)'
            $null = $recPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false
            # Set GPT attributes: bit 0 (required) + bit 60 (read-only) +
            # bit 62 (hidden) + bit 63 (no drive letter) = 0x8000000000000001
            $stepName = 'Set-Partition (Recovery attributes)'
            $recPartArgs = @{
                DiskNumber      = $DiskNumber
                PartitionNumber = $recPartition.PartitionNumber
                GptType         = $script:GptTypeRecovery
            }
            Set-Partition @recPartArgs
            Write-Host "  Recovery partition created: $(Get-FileSizeReadable $RecoveryPartitionSize)"
        }

    } else {
        # Initialize as MBR
        $stepName = 'Initialize-Disk (MBR)'
        Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop

        # System/Active partition
        $stepName = 'New-Partition (System)'
        $sysPartition = New-Partition -DiskNumber $DiskNumber -Size $script:MbrSystemSize -IsActive -MbrType 7
        $stepName = 'Format-Volume (System NTFS)'
        $null = $sysPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'System' -Confirm:$false
        $stepName = 'Add-PartitionAccessPath (System)'
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $sysPartition.PartitionNumber -AssignDriveLetter

        # Windows OS Partition - remaining
        $stepName = 'New-Partition (OS)'
        $osPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -MbrType 7
        $stepName = 'Format-Volume (OS NTFS)'
        $null = $osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false
        # Format-Volume may auto-assign the drive letter; only reassign if needed.
        $stepName = 'Set-Partition (drive letter)'
        $currentLetter = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber).DriveLetter
        if ([string]$currentLetter -ne [string]$OSDriveLetter) {
            # Free the target letter if another partition already owns it
            $conflict = Get-Partition | Where-Object { $_.DriveLetter -eq $OSDriveLetter } | Select-Object -First 1
            if ($conflict) {
                Remove-PartitionAccessPath -DiskNumber $conflict.DiskNumber -PartitionNumber $conflict.PartitionNumber -AccessPath "${OSDriveLetter}:\"
            }
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $OSDriveLetter
        }
    }

    } catch {
        $msg = "Disk $DiskNumber partitioning failed at step '$stepName': $_"
        if ($clearError) {
            $msg += " (preceded by Clear-Disk error: $clearError)"
        }
        throw $msg
    }

    Write-Success "Disk $DiskNumber partitioned. OS drive: ${OSDriveLetter}:"
    return $osPartition
}

# ── Module Export ────────────────────────────────────────────────────────────

Export-ModuleMember -Function Get-TargetDisk, Initialize-TargetDisk, Get-PartitionGuid

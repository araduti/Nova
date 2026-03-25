function Initialize-TargetDisk {
    param(
        [int]$DiskNumber,
        [string]$FirmwareType,
        [string]$OSDriveLetter
    )

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

        # Windows OS Partition - all remaining space
        $stepName = 'New-Partition (OS)'
        $osPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -GptType $script:GptTypeBasicData
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

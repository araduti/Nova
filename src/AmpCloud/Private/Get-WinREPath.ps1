function Get-WinREPath {
    <#
    .SYNOPSIS  Locates a usable winre.wim on the current machine.
    .DESCRIPTION
        WinRE (Windows Recovery Environment) is built on WinPE but ships with
        real WiFi hardware drivers (Intel, Realtek, MediaTek, Qualcomm) that
        Microsoft delivers via Windows Update. Using WinRE as the boot image
        therefore enables wireless connectivity on most laptops without manually
        injecting model-specific drivers.

        Search order:
          1. %SystemRoot%\System32\Recovery\WinRE.wim  (present when WinRE is
             disabled or the machine has not moved it to a recovery partition).
          2. Active recovery partition reported by reagentc.exe, temporarily
             assigned a drive letter so the WIM can be copied out.

    .OUTPUTS  [string] Path to an accessible winre.wim, or $null when not found.
    #>

    # ── 1. Quick check in System32\Recovery ─────────────────────────────────
    $sysPath = Join-Path $env:SystemRoot 'System32\Recovery\WinRE.wim'
    if (Test-Path $sysPath) {
        Write-Success "WinRE.wim found: $sysPath"
        return $sysPath
    }

    # ── 2. Query reagentc for the active WinRE location ─────────────────────
    Write-Step 'Querying reagentc for WinRE location...'
    $info = & reagentc.exe /info 2>&1
    $locLine = ($info | Where-Object { $_ -match 'Windows RE location' }) -as [string]

    if ($locLine -notmatch 'harddisk(\d+)\\partition(\d+)\\(.+)') {
        Write-Warn 'reagentc did not report a usable WinRE location.'
        return $null
    }

    $diskNum = [int]$Matches[1]
    $partNum = [int]$Matches[2]
    $relPath = $Matches[3].Trim()

    $part = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum `
                          -ErrorAction SilentlyContinue
    if (-not $part) {
        Write-Warn "Could not access recovery partition (disk=$diskNum, part=$partNum)."
        return $null
    }

    # If the partition already has a drive letter, try it directly
    if ($part.DriveLetter -match '[A-Za-z]') {
        $candidate = "$($part.DriveLetter):\$relPath\WinRE.wim"
        if (Test-Path $candidate) {
            Write-Success "WinRE.wim found: $candidate"
            return $candidate
        }
    }

    # Otherwise assign a temporary drive letter, copy the WIM, then release
    $freeLetter = $null
    foreach ($code in 68..90) {
        $letter = [char]$code
        if (-not (Test-Path "${letter}:\")) {
            $freeLetter = $letter
            break
        }
    }
    if (-not $freeLetter) {
        Write-Warn 'No free drive letter available to mount recovery partition.'
        return $null
    }

    $mountPoint = "${freeLetter}:\"
    $tempWim    = Join-Path $env:TEMP "ampcloud_winre_$([guid]::NewGuid().Guid).wim"
    $found      = $false
    try {
        $part | Add-PartitionAccessPath -AccessPath $mountPoint -ErrorAction Stop
        $candidate = "${freeLetter}:\$relPath\WinRE.wim"
        if (Test-Path $candidate) {
            Write-Step 'Copying WinRE.wim from recovery partition...'
            Copy-Item $candidate $tempWim -Force
            $found = $true
        } else {
            Write-Warn "WinRE.wim not found at expected path: $candidate"
        }
    } catch {
        Write-Warn "Could not mount recovery partition: $_"
    } finally {
        $part | Remove-PartitionAccessPath -AccessPath $mountPoint `
                                           -ErrorAction SilentlyContinue
    }

    if ($found) {
        Write-Success "WinRE.wim copied to temp: $tempWim"
        return $tempWim
    }
    return $null
}

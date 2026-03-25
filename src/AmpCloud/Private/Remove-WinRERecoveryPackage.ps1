function Remove-WinRERecoveryPackage {
    <#
    .SYNOPSIS
        Removes WinRE-specific recovery tools from a mounted WinRE image to
        reduce the final WIM size.
    .DESCRIPTION
        WinRE ships with startup-repair, boot-recovery, and other tools that are
        useful for OS recovery but are not needed when the image is used purely as
        a cloud deployment environment. Removing them shrinks the image by roughly
        100–200 MB before the final compression step.

        Packages matching the following name prefixes are removed:
          - Microsoft-Windows-WinRE-RecoveryAgent   (startup repair agent)
          - Microsoft-Windows-WinRE-BootRecovery    (boot recovery tools)
          - Microsoft-Windows-RecoveryDrive          (recovery drive creator)

        WiFi, networking, and scripting packages are intentionally preserved.
        Each removal is attempted individually so that dependency errors on one
        package do not block removal of the others.
    .PARAMETER MountDir  Path to the mounted WIM image.
    #>
    param([string] $MountDir)

    Write-Step 'Removing WinRE recovery packages to reduce image size...'

    $removePrefixes = @(
        'Microsoft-Windows-WinRE-RecoveryAgent',
        'Microsoft-Windows-WinRE-BootRecovery',
        'Microsoft-Windows-RecoveryDrive'
    )

    try {
        $installed = Get-WindowsPackage -Path $MountDir -ErrorAction Stop
    } catch {
        Write-Warn "Could not enumerate packages for slimming: $_"
        return
    }

    foreach ($pkg in $installed) {
        $name        = $pkg.PackageName
        $shouldRemove = $false
        foreach ($prefix in $removePrefixes) {
            if ($name -like "$prefix*") { $shouldRemove = $true; break }
        }
        if (-not $shouldRemove) { continue }

        Write-Step "Removing recovery package: $name"
        try {
            $null = Remove-WindowsPackage -Path $MountDir -PackageName $name `
                                  -NoRestart -ErrorAction Stop
            Write-Success "Removed: $name"
        } catch {
            Write-Warn "Could not remove $name (non-fatal): $_"
        }
    }
}

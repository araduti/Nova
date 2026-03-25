function Show-BuildConfiguration {
    <#
    .SYNOPSIS  Interactive menu that lets OSD admins customise the boot image before
               building.  All items are pre-selected with sensible defaults.
    .OUTPUTS   [hashtable] Keys: Language, Packages, InjectVirtIO, ExtraDriverPaths
    #>
    param([string] $Architecture)

    $language         = $script:DefaultLanguage
    $injectVirtIO     = $true
    $extraDriverPaths = [System.Collections.Generic.List[string]]::new()

    # Pre-select defaults
    $pkgCount = $script:AvailableWinPEPackages.Count
    $selected = [bool[]]::new($pkgCount)
    for ($i = 0; $i -lt $pkgCount; $i++) {
        $selected[$i] = $script:AvailableWinPEPackages[$i].Default
    }

    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
        Write-Host '  ║         Boot Image Configuration                         ║' -ForegroundColor Cyan
        Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
        Write-Host ''
        Write-Host "    Architecture  $Architecture" -ForegroundColor White
        Write-Host "    Language      $language" -ForegroundColor White
        Write-Host ''
        Write-Host '  WinPE Optional Components' -ForegroundColor White
        Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray

        for ($i = 0; $i -lt $pkgCount; $i++) {
            $pkg  = $script:AvailableWinPEPackages[$i]
            $mark = if ($selected[$i]) { '■' } else { ' ' }
            $tag  = if ($pkg.Required) { ' (required)' } else { '' }
            $num  = '{0,2}' -f ($i + 1)
            $padName = $pkg.Name.PadRight(24)
            $color   = if ($selected[$i]) { 'Green' } else { 'DarkGray' }
            Write-Host "    [$mark] $num. $padName $($pkg.Description)$tag" -ForegroundColor $color
        }

        Write-Host ''
        Write-Host '  Drivers' -ForegroundColor White
        Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
        $vMark  = if ($injectVirtIO) { '■' } else { ' ' }
        $vColor = if ($injectVirtIO) { 'Green' } else { 'DarkGray' }
        Write-Host "    [$vMark]  V. VirtIO network driver (netkvm)" -ForegroundColor $vColor

        if ($extraDriverPaths.Count -gt 0) {
            for ($i = 0; $i -lt $extraDriverPaths.Count; $i++) {
                Write-Host "    [+] D$($i + 1). $($extraDriverPaths[$i])" -ForegroundColor Green
            }
        }

        Write-Host ''
        Write-Host '  ┌──────────────────────────────────────────────────────────┐' -ForegroundColor DarkGray
        Write-Host '  │  1-9  toggle package    L  change language              │' -ForegroundColor DarkGray
        Write-Host '  │  V    toggle VirtIO     D  add driver path              │' -ForegroundColor DarkGray
        Write-Host '  │  A    select all pkgs   N  deselect optional pkgs       │' -ForegroundColor DarkGray
        Write-Host '  │  R    remove driver     Enter  continue with settings ⏎ │' -ForegroundColor DarkGray
        Write-Host '  └──────────────────────────────────────────────────────────┘' -ForegroundColor DarkGray
        Write-Host ''

        $menuChoice = Read-Host '  >'
        $cmd = $menuChoice.Trim()

        # Enter — accept current configuration
        if ($cmd -eq '') {
            # Re-enable required packages that were somehow deselected
            for ($i = 0; $i -lt $pkgCount; $i++) {
                if ($script:AvailableWinPEPackages[$i].Required -and -not $selected[$i]) {
                    $selected[$i] = $true
                    Write-Warn "$($script:AvailableWinPEPackages[$i].Name) is required and has been re-enabled."
                }
            }
            break
        }

        # Toggle package by number (1-9)
        if ($cmd -match '^\d+$') {
            $idx = [int]$cmd - 1
            if ($idx -ge 0 -and $idx -lt $pkgCount) {
                if ($script:AvailableWinPEPackages[$idx].Required -and $selected[$idx]) {
                    Write-Warn "$($script:AvailableWinPEPackages[$idx].Name) is required and cannot be deselected."
                } else {
                    $selected[$idx] = -not $selected[$idx]
                }
            }
            continue
        }

        switch ($cmd.ToUpper()) {
            'V' { $injectVirtIO = -not $injectVirtIO }
            'L' {
                $newLang = Read-Host '  Enter language code (e.g. en-us, de-de, fr-fr, ja-jp)'
                $newLang = $newLang.Trim().ToLower()
                if ($newLang -match '^[a-z]{2,3}-[a-z]{2}$') {
                    $language = $newLang
                } else {
                    Write-Warn "Invalid language code format. Expected pattern: xx-xx (e.g. en-us)"
                }
            }
            'D' {
                $driverPath = Read-Host '  Enter driver folder path (local or UNC)'
                $driverPath = $driverPath.Trim().TrimEnd('\')
                if ($driverPath) {
                    if (-not (Test-Path $driverPath)) {
                        Write-Warn "Path not found: $driverPath (will be re-checked at build time)"
                    }
                    $extraDriverPaths.Add($driverPath)
                    Write-Success "Added driver path: $driverPath"
                }
            }
            'R' {
                if ($extraDriverPaths.Count -eq 0) {
                    Write-Warn 'No extra driver paths to remove.'
                } else {
                    for ($j = 0; $j -lt $extraDriverPaths.Count; $j++) {
                        Write-Host "    $($j + 1). $($extraDriverPaths[$j])"
                    }
                    $removeIdx = Read-Host '  Enter number to remove'
                    if ($removeIdx -match '^\d+$') {
                        $ri = [int]$removeIdx - 1
                        if ($ri -ge 0 -and $ri -lt $extraDriverPaths.Count) {
                            $removed = $extraDriverPaths[$ri]
                            $extraDriverPaths.RemoveAt($ri)
                            Write-Success "Removed: $removed"
                        }
                    }
                }
            }
            'A' {
                for ($i = 0; $i -lt $pkgCount; $i++) { $selected[$i] = $true }
            }
            'N' {
                for ($i = 0; $i -lt $pkgCount; $i++) {
                    if (-not $script:AvailableWinPEPackages[$i].Required) { $selected[$i] = $false }
                }
            }
        }
    }

    # Build the selected package name list (preserves dependency order)
    $selectedPkgs = @()
    for ($i = 0; $i -lt $pkgCount; $i++) {
        if ($selected[$i]) { $selectedPkgs += $script:AvailableWinPEPackages[$i].Name }
    }

    return @{
        Language         = $language
        Packages         = $selectedPkgs
        InjectVirtIO     = $injectVirtIO
        ExtraDriverPaths = @($extraDriverPaths)
    }
}

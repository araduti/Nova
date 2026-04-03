<#
.SYNOPSIS
    Build configuration management module for Nova boot image creation.

.DESCRIPTION
    Provides functions for managing WinPE boot image build configuration:
    persistence (save/load), package path resolution, and the interactive
    configuration menu that lets OSD admins customise language, packages,
    and driver injection before building.
#>

# ── Configuration data ─────────────────────────────────────────────────────────

# Default language for WinPE optional-component language packs.
$script:DefaultLanguage = 'en-us'

# Common WinPE language codes for the quick-pick list.
$script:LanguageOptions = @(
    @{ Code = 'en-us'; Label = 'English (United States)' }
    @{ Code = 'en-gb'; Label = 'English (United Kingdom)' }
    @{ Code = 'de-de'; Label = 'German (Germany)' }
    @{ Code = 'fr-fr'; Label = 'French (France)' }
    @{ Code = 'es-es'; Label = 'Spanish (Spain)' }
    @{ Code = 'it-it'; Label = 'Italian (Italy)' }
    @{ Code = 'pt-br'; Label = 'Portuguese (Brazil)' }
    @{ Code = 'ja-jp'; Label = 'Japanese (Japan)' }
    @{ Code = 'zh-cn'; Label = 'Chinese (Simplified)' }
    @{ Code = 'ko-kr'; Label = 'Korean (Korea)' }
    @{ Code = 'nl-nl'; Label = 'Dutch (Netherlands)' }
    @{ Code = 'sv-se'; Label = 'Swedish (Sweden)' }
)

# ANSI escape sequences for styled prompt (PS 5.1+ with VT support).
$script:ESC              = [char]0x1B
$script:AnsiCyan         = "${script:ESC}[36;1m"
$script:AnsiReset        = "${script:ESC}[0m"
$script:AnsiDim          = "${script:ESC}[90m"
$script:AnsiBold         = "${script:ESC}[1m"
$script:AnsiReverse      = "${script:ESC}[7m"
$script:AnsiCursorHome   = "${script:ESC}[H"
$script:AnsiClearScreen  = "${script:ESC}[2J"

# Virtual-key codes used by ReadKey-based navigation.
$script:VK_ENTER = 13
$script:VK_SPACE = 32
$script:VK_UP    = 38
$script:VK_DOWN  = 40

# Available WinPE optional components — order matters (dependency chain).
# Name        : base cab name (without .cab extension or language prefix)
# Description : human-readable label shown in the configuration menu
# Default     : $true = pre-selected in the menu
# Required    : $true = cannot be deselected (needed for Bootstrap.ps1)
$script:AvailableWinPEPackages = @(
    @{ Name = 'WinPE-WMI';           Description = 'Windows Management Instrumentation'; Default = $true;  Required = $false }
    @{ Name = 'WinPE-NetFX';         Description = '.NET Framework';                     Default = $true;  Required = $false }
    @{ Name = 'WinPE-Scripting';     Description = 'Windows Script Host';                Default = $true;  Required = $false }
    @{ Name = 'WinPE-PowerShell';    Description = 'PowerShell';                         Default = $true;  Required = $true  }
    @{ Name = 'WinPE-SecureStartup'; Description = 'BitLocker and TPM support';          Default = $true;  Required = $false }
    @{ Name = 'WinPE-Dot3Svc';       Description = '802.1X wired authentication';        Default = $true;  Required = $false }
    @{ Name = 'WinPE-WiFi-Package';  Description = 'Wireless networking';                Default = $true;  Required = $false }
    @{ Name = 'WinPE-StorageWMI';    Description = 'Storage management cmdlets';         Default = $true;  Required = $false }
    @{ Name = 'WinPE-DismCmdlets';   Description = 'DISM PowerShell cmdlets';            Default = $true;  Required = $false }
)

function Get-BuildConfigPath {
    <#
    .SYNOPSIS  Returns the path to the persisted build configuration file.
    #>
    if ($env:APPDATA) {
        return Join-Path $env:APPDATA 'Nova\last-build-config.json'
    }
    return $null
}

function Save-BuildConfiguration {
    <#
    .SYNOPSIS  Persists the build configuration to disk for future reuse.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Saving a JSON config file — no system side-effects beyond a small user-data file')]
    [CmdletBinding()]
    param([hashtable] $Config)
    $path = Get-BuildConfigPath
    if (-not $path) { return }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    $Config | ConvertTo-Json -Depth 3 | Set-Content -Path $path -Encoding UTF8
}

function Read-SavedBuildConfiguration {
    <#
    .SYNOPSIS  Loads a previously saved build configuration, if one exists.
    .OUTPUTS   [hashtable] or $null if no saved configuration exists.
    #>
    $path = Get-BuildConfigPath
    if (-not $path -or -not (Test-Path $path)) { return $null }
    try {
        $json = Get-Content $path -Raw | ConvertFrom-Json
        return @{
            Language         = $json.Language
            Packages         = @($json.Packages)
            InjectVirtIO     = [bool]$json.InjectVirtIO
            ExtraDriverPaths = @($json.ExtraDriverPaths)
        }
    } catch {
        return $null
    }
}

function Resolve-WinPEPackagePath {
    <#
    .SYNOPSIS  Expands package names + language into the ordered cab-path list that
               Add-WindowsPackage expects (base cab first, then its language pack).
    #>
    param(
        [string[]] $PackageNames,
        [string]   $Language
    )
    $paths = @()
    foreach ($name in $PackageNames) {
        $paths += "$name.cab"
        $paths += "$Language\${name}_$Language.cab"
    }
    return $paths
}

function Show-BuildConfiguration {
    <#
    .SYNOPSIS  Interactive menu that lets OSD admins customise the boot image before
               building.  All items are pre-selected with sensible defaults.
    .OUTPUTS   [hashtable] Keys: Language, Packages, InjectVirtIO, ExtraDriverPaths
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for interactive menu UI')]
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

    # ── Offer to reload last saved configuration ─────────────────────────────
    $savedConfig = Read-SavedBuildConfiguration
    if ($savedConfig) {
        Write-Host ''
        Write-Host "  ${script:AnsiDim}Previous configuration found.${script:AnsiReset}"
        $reuse = Read-Host '  Use previous configuration? (Y/n)'
        if ($reuse -notmatch '^[Nn]') {
            $language     = $savedConfig.Language
            $injectVirtIO = $savedConfig.InjectVirtIO
            if ($savedConfig.ExtraDriverPaths) {
                foreach ($dp in $savedConfig.ExtraDriverPaths) { $extraDriverPaths.Add($dp) }
            }
            # Re-apply saved package selection
            for ($i = 0; $i -lt $pkgCount; $i++) {
                $pkgName = $script:AvailableWinPEPackages[$i].Name
                $selected[$i] = $pkgName -in $savedConfig.Packages
                # Enforce required packages
                if ($script:AvailableWinPEPackages[$i].Required) { $selected[$i] = $true }
            }
        }
    }

    # ── Detect VT/ANSI support for single-keypress input ─────────────────────
    $supportsVT = ($null -ne $Host.UI.psobject.Properties['SupportsVirtualTerminal'] -and
                   $Host.UI.SupportsVirtualTerminal) -or $env:WT_SESSION
    # ReadKey requires a RawUI host — exclude known non-console hosts
    $supportsRawKey = $Host.UI.RawUI -and ($Host.Name -notin @(
        'Visual Studio Code Host', 'Windows PowerShell ISE Host'
    ))

    # Cursor index for arrow-key navigation (0-based over all navigable items).
    # Items: 0..(pkgCount-1) = packages, pkgCount = VirtIO
    $totalItems  = $pkgCount + 1
    $cursorIndex = 0

    while ($true) {
        # ── Draw menu ────────────────────────────────────────────────────────
        if ($supportsVT) {
            # Move cursor to top-left and clear screen without flicker
            Write-Host "${script:AnsiCursorHome}${script:AnsiClearScreen}" -NoNewline
        } else {
            Clear-Host
        }
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
            $isHighlighted = ($i -eq $cursorIndex)
            if ($isHighlighted -and $supportsVT) {
                $color = if ($selected[$i]) { 'Green' } else { 'DarkGray' }
                Write-Host "  ${script:AnsiReverse}  [$mark] $num. $padName $($pkg.Description)$tag  ${script:AnsiReset}" -ForegroundColor $color
            } else {
                $color = if ($selected[$i]) { 'Green' } else { 'DarkGray' }
                Write-Host "    [$mark] $num. $padName $($pkg.Description)$tag" -ForegroundColor $color
            }
        }

        Write-Host ''
        Write-Host '  Drivers' -ForegroundColor White
        Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
        $vMark  = if ($injectVirtIO) { '■' } else { ' ' }
        $vColor = if ($injectVirtIO) { 'Green' } else { 'DarkGray' }
        $isHighlighted = ($cursorIndex -eq $pkgCount)
        if ($isHighlighted -and $supportsVT) {
            Write-Host "  ${script:AnsiReverse}  [$vMark]  V. VirtIO network driver (netkvm)  ${script:AnsiReset}" -ForegroundColor $vColor
        } else {
            Write-Host "    [$vMark]  V. VirtIO network driver (netkvm)" -ForegroundColor $vColor
        }

        if ($extraDriverPaths.Count -gt 0) {
            for ($i = 0; $i -lt $extraDriverPaths.Count; $i++) {
                Write-Host "    [+] D$($i + 1). $($extraDriverPaths[$i])" -ForegroundColor Green
            }
        }

        Write-Host ''
        Write-Host '  ┌──────────────────────────────────────────────────────────┐' -ForegroundColor DarkGray
        Write-Host '  │  ↑/↓  navigate          Space  toggle item             │' -ForegroundColor DarkGray
        Write-Host '  │  1-9  toggle package     L  change language            │' -ForegroundColor DarkGray
        Write-Host '  │  V    toggle VirtIO      D  add driver path            │' -ForegroundColor DarkGray
        Write-Host '  │  A    select all pkgs    N  deselect optional pkgs     │' -ForegroundColor DarkGray
        Write-Host '  │  R    remove driver      Enter  continue with build  ⏎ │' -ForegroundColor DarkGray
        Write-Host '  └──────────────────────────────────────────────────────────┘' -ForegroundColor DarkGray
        Write-Host ''

        # ── Read input ───────────────────────────────────────────────────────
        if ($supportsRawKey) {
            Write-Host "  ${script:AnsiCyan}›${script:AnsiReset} " -NoNewline
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            $vk  = $key.VirtualKeyCode
            $ch  = $key.Character

            # Arrow keys
            if ($vk -eq $script:VK_UP)   { $cursorIndex = [Math]::Max(0, $cursorIndex - 1); continue }
            if ($vk -eq $script:VK_DOWN) { $cursorIndex = [Math]::Min($totalItems - 1, $cursorIndex + 1); continue }
            if ($vk -eq $script:VK_SPACE) {
                # Space — toggle highlighted item
                if ($cursorIndex -lt $pkgCount) {
                    if ($script:AvailableWinPEPackages[$cursorIndex].Required -and $selected[$cursorIndex]) {
                        Write-Warn "$($script:AvailableWinPEPackages[$cursorIndex].Name) is required and cannot be deselected."
                        Start-Sleep -Milliseconds 800
                    } else {
                        $selected[$cursorIndex] = -not $selected[$cursorIndex]
                    }
                } elseif ($cursorIndex -eq $pkgCount) {
                    $injectVirtIO = -not $injectVirtIO
                }
                continue
            }

            # Enter — accept
            if ($vk -eq $script:VK_ENTER) { $cmd = '' }
            else { $cmd = "$ch".Trim() }
        } else {
            $menuChoice = Read-Host "  ${script:AnsiCyan}›${script:AnsiReset}"
            $cmd = $menuChoice.Trim()
        }

        # Enter — show confirmation summary and accept
        if ($cmd -eq '') {
            # Re-enable required packages that were somehow deselected
            for ($i = 0; $i -lt $pkgCount; $i++) {
                if ($script:AvailableWinPEPackages[$i].Required -and -not $selected[$i]) {
                    $selected[$i] = $true
                    Write-Warn "$($script:AvailableWinPEPackages[$i].Name) is required and has been re-enabled."
                }
            }

            # Confirmation summary
            $selCount = ($selected | Where-Object { $_ }).Count
            $virtLabel = if ($injectVirtIO) { 'Yes' } else { 'No' }
            $drvCount  = $extraDriverPaths.Count
            Write-Host ''
            Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
            Write-Host '  ║         Build Summary                                    ║' -ForegroundColor Cyan
            Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
            Write-Host "    Packages : $selCount selected" -ForegroundColor White
            Write-Host "    VirtIO   : $virtLabel" -ForegroundColor White
            Write-Host "    Language : $language" -ForegroundColor White
            if ($drvCount -gt 0) {
                Write-Host "    Drivers  : $drvCount custom path(s)" -ForegroundColor White
            }
            Write-Host ''
            $confirm = Read-Host "  Press Enter to build, or ${script:AnsiDim}B${script:AnsiReset} to go back"
            if ($confirm -match '^[Bb]') { continue }
            break
        }

        # Toggle package by number (1-9)
        if ($cmd -match '^\d+$') {
            $idx = [int]$cmd - 1
            if ($idx -ge 0 -and $idx -lt $pkgCount) {
                if ($script:AvailableWinPEPackages[$idx].Required -and $selected[$idx]) {
                    Write-Warn "$($script:AvailableWinPEPackages[$idx].Name) is required and cannot be deselected."
                    if ($supportsRawKey) { Start-Sleep -Milliseconds 800 }
                } else {
                    $selected[$idx] = -not $selected[$idx]
                }
            }
            continue
        }

        switch ($cmd.ToUpper()) {
            'V' { $injectVirtIO = -not $injectVirtIO }
            'L' {
                Write-Host ''
                Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
                Write-Host '  ║         Language Selection                                ║' -ForegroundColor Cyan
                Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
                for ($li = 0; $li -lt $script:LanguageOptions.Count; $li++) {
                    $lo = $script:LanguageOptions[$li]
                    $num = '{0,3}' -f ($li + 1)
                    $indicator = if ($lo.Code -eq $language) { ' ◄' } else { '' }
                    Write-Host "   $num. $($lo.Code.PadRight(8)) $($lo.Label)$indicator" -ForegroundColor White
                }
                Write-Host "     O. Other (enter manually)" -ForegroundColor DarkGray
                Write-Host ''
                $langChoice = Read-Host "  ${script:AnsiCyan}›${script:AnsiReset} Enter number or O"
                $langChoice = $langChoice.Trim()
                if ($langChoice -match '^[Oo]$') {
                    $newLang = Read-Host '  Enter language code (e.g. pt-pt, ar-sa, th-th)'
                    $newLang = $newLang.Trim().ToLower()
                    if ($newLang -match '^[a-z]{2,3}-[a-z]{2}$') {
                        $language = $newLang
                    } else {
                        Write-Warn "Invalid language code format. Expected pattern: xx-xx (e.g. en-us)"
                        if ($supportsRawKey) { Start-Sleep -Milliseconds 800 }
                    }
                } elseif ($langChoice -match '^\d+$') {
                    $langIdx = [int]$langChoice - 1
                    if ($langIdx -ge 0 -and $langIdx -lt $script:LanguageOptions.Count) {
                        $language = $script:LanguageOptions[$langIdx].Code
                    } else {
                        Write-Warn "Invalid selection. Enter 1-$($script:LanguageOptions.Count) or O."
                        if ($supportsRawKey) { Start-Sleep -Milliseconds 800 }
                    }
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
                    if ($supportsRawKey) { Start-Sleep -Milliseconds 800 }
                }
            }
            'R' {
                if ($extraDriverPaths.Count -eq 0) {
                    Write-Warn 'No extra driver paths to remove.'
                    if ($supportsRawKey) { Start-Sleep -Milliseconds 800 }
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

    $result = @{
        Language         = $language
        Packages         = $selectedPkgs
        InjectVirtIO     = $injectVirtIO
        ExtraDriverPaths = @($extraDriverPaths)
    }

    # Persist the configuration for next time
    Save-BuildConfiguration -Config $result

    return $result
}

function Get-DefaultLanguage {
    <#
    .SYNOPSIS  Returns the default WinPE language code.
    #>
    return $script:DefaultLanguage
}

function Get-AvailableWinPEPackages {
    <#
    .SYNOPSIS  Returns the list of available WinPE optional components.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Returns a collection of packages — plural noun is intentional')]
    [CmdletBinding()]
    param()
    return $script:AvailableWinPEPackages
}

Export-ModuleMember -Function Get-BuildConfigPath, Save-BuildConfiguration, Read-SavedBuildConfiguration,
                              Resolve-WinPEPackagePath, Show-BuildConfiguration,
                              Get-DefaultLanguage, Get-AvailableWinPEPackages

<#
.SYNOPSIS
    Build configuration management module for Nova boot image creation.

.DESCRIPTION
    Provides functions for managing WinPE boot image build configuration:
    persistence (save/load), package path resolution, and the interactive
    configuration menu that lets OSD admins customise language, packages,
    and driver injection before building.
#>

Set-StrictMode -Version Latest

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
$script:AnsiClearToEnd   = "${script:ESC}[0J"
$script:AnsiHideCursor   = "${script:ESC}[?25l"
$script:AnsiShowCursor   = "${script:ESC}[?25h"
$script:AnsiAltBufferOn  = "${script:ESC}[?1049h"
$script:AnsiAltBufferOff = "${script:ESC}[?1049l"

# Virtual-key codes used by ReadKey-based navigation.
$script:VK_ENTER = 13
$script:VK_SPACE = 32
$script:VK_UP    = 38
$script:VK_DOWN  = 40

# Available WinPE optional components -- order matters (dependency chain).
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
    [OutputType([string])]
    [CmdletBinding()]
    param()
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
        Justification = 'Saving a JSON config file -- no system side-effects beyond a small user-data file')]
    [OutputType([void])]
    [CmdletBinding()]
    param([hashtable] $Config)
    $path = Get-BuildConfigPath
    if (-not $path) { return }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    $Config | ConvertTo-Json -Depth 4 | Set-Content -Path $path -Encoding UTF8
}

function Read-SavedBuildConfiguration {
    <#
    .SYNOPSIS  Loads a previously saved build configuration, if one exists.
    .OUTPUTS   [hashtable] or $null if no saved configuration exists.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param()
    $path = Get-BuildConfigPath
    if (-not $path -or -not (Test-Path $path)) { return $null }
    try {
        $json = Get-Content $path -Raw | ConvertFrom-Json
        # Migrate legacy configs that used InjectVirtIO + ExtraDriverPaths
        if ($null -ne $json.PSObject.Properties['DriverPaths']) {
            $drivers = @($json.DriverPaths)
        } else {
            $drivers = @()
            if ($json.PSObject.Properties['ExtraDriverPaths']) {
                $drivers += @($json.ExtraDriverPaths)
            }
        }
        return @{
            Language    = $json.Language
            Packages    = @($json.Packages)
            DriverPaths = $drivers
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
    [OutputType([string])]
    [CmdletBinding()]
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
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([string] $Architecture)

    $language    = $script:DefaultLanguage
    $driverPaths = [System.Collections.Generic.List[string]]::new()

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
            $language = $savedConfig.Language
            if ($savedConfig.DriverPaths) {
                foreach ($dp in $savedConfig.DriverPaths) { $driverPaths.Add($dp) }
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
    # ReadKey requires a RawUI host -- exclude known non-console hosts
    $supportsRawKey = $Host.UI.RawUI -and ($Host.Name -notin @(
        'Visual Studio Code Host', 'Windows PowerShell ISE Host'
    ))

    # Cursor index for arrow-key navigation (0-based over all navigable items).
    # Items: 0..(pkgCount-1) = packages
    $totalItems  = $pkgCount
    $cursorIndex = 0

    $statusMessage = $null
    if ($supportsVT) {
        Write-Host "${script:AnsiAltBufferOn}${script:AnsiHideCursor}${script:AnsiCursorHome}${script:AnsiClearScreen}" -NoNewline
    }

    try {
        while ($true) {
            # ── Draw menu ────────────────────────────────────────────────────
            if ($supportsVT) {
                Write-Host "${script:AnsiCursorHome}" -NoNewline
            } else {
                Clear-Host
            }
            Write-Host ''
            Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
            Write-Host '  ║                     Nova Build Console                     ║' -ForegroundColor Cyan
            Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
            Write-Host ''
            Write-Host "    Architecture  $Architecture" -ForegroundColor White
            Write-Host "    Language      $language" -ForegroundColor White
            Write-Host ''
            Write-Host '  WinPE Optional Components' -ForegroundColor White
            Write-Host '  ──────────────────────────────────────────────────────────────' -ForegroundColor DarkGray

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
            Write-Host '  WinPE Drivers' -ForegroundColor White
            Write-Host '  ──────────────────────────────────────────────────────────────' -ForegroundColor DarkGray

            if ($driverPaths.Count -gt 0) {
                for ($i = 0; $i -lt $driverPaths.Count; $i++) {
                    $drvEntry = $driverPaths[$i]
                    $isUrl = $drvEntry -match '^https?://'
                    $icon  = if ($isUrl) { '↓' } else { '+' }
                    Write-Host "    [$icon] $($i + 1). $drvEntry" -ForegroundColor Green
                }
            } else {
                Write-Host "    ${script:AnsiDim}(none -- use D to add a local path or U to add a URL)${script:AnsiReset}" -ForegroundColor DarkGray
            }

            Write-Host ''
            if ($statusMessage) {
                Write-Host "  ${script:AnsiDim}Status:${script:AnsiReset} $statusMessage" -ForegroundColor Yellow
            } else {
                Write-Host '  Status: Ready' -ForegroundColor DarkGray
            }
            Write-Host '  ┌────────────────────────────────────────────────────────────┐' -ForegroundColor DarkGray
            Write-Host '  │  ↑/↓  navigate          Space  toggle item                 │' -ForegroundColor DarkGray
            Write-Host '  │  1-9  toggle package     L  change language                │' -ForegroundColor DarkGray
            Write-Host '  │  D    add driver path    U  add driver URL                 │' -ForegroundColor DarkGray
            Write-Host '  │  A    select all pkgs    N  deselect optional pkgs         │' -ForegroundColor DarkGray
            Write-Host '  │  R    remove driver      Enter  continue with build  ⏎     │' -ForegroundColor DarkGray
            Write-Host '  └────────────────────────────────────────────────────────────┘' -ForegroundColor DarkGray
            if ($supportsVT) {
                Write-Host "${script:AnsiClearToEnd}" -NoNewline
            }
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
                # Space -- toggle highlighted item
                if ($cursorIndex -lt $pkgCount) {
                    if ($script:AvailableWinPEPackages[$cursorIndex].Required -and $selected[$cursorIndex]) {
                        $statusMessage = "$($script:AvailableWinPEPackages[$cursorIndex].Name) is required and cannot be deselected."
                    } else {
                        $selected[$cursorIndex] = -not $selected[$cursorIndex]
                        $statusMessage = $null
                    }
                }
                continue
            }

            # Enter -- accept
            if ($vk -eq $script:VK_ENTER) { $cmd = '' }
            else { $cmd = "$ch".Trim() }
        } else {
            $menuChoice = Read-Host "  ${script:AnsiCyan}›${script:AnsiReset}"
            $cmd = $menuChoice.Trim()
        }

        # Enter -- show confirmation summary and accept
        if ($cmd -eq '') {
            # Re-enable required packages that were somehow deselected
            for ($i = 0; $i -lt $pkgCount; $i++) {
                if ($script:AvailableWinPEPackages[$i].Required -and -not $selected[$i]) {
                    $selected[$i] = $true
                    $statusMessage = "$($script:AvailableWinPEPackages[$i].Name) is required and has been re-enabled."
                }
            }

            # Confirmation summary
            $selCount = ($selected | Where-Object { $_ }).Count
            $drvCount  = $driverPaths.Count
            Write-Host ''
            Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
            Write-Host '  ║         Build Summary                                    ║' -ForegroundColor Cyan
            Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
            Write-Host "    Packages : $selCount selected" -ForegroundColor White
            Write-Host "    Language : $language" -ForegroundColor White
            if ($drvCount -gt 0) {
                Write-Host "    Drivers  : $drvCount path(s)" -ForegroundColor White
            } else {
                Write-Host "    Drivers  : none" -ForegroundColor White
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
                    $statusMessage = "$($script:AvailableWinPEPackages[$idx].Name) is required and cannot be deselected."
                } else {
                    $selected[$idx] = -not $selected[$idx]
                    $statusMessage = $null
                }
            }
            continue
        }

        switch ($cmd.ToUpper()) {
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
                        $statusMessage = "Language updated to $language."
                    } else {
                        $statusMessage = 'Invalid language code format. Expected pattern: xx-xx (e.g. en-us).'
                    }
                } elseif ($langChoice -match '^\d+$') {
                    $langIdx = [int]$langChoice - 1
                    if ($langIdx -ge 0 -and $langIdx -lt $script:LanguageOptions.Count) {
                        $language = $script:LanguageOptions[$langIdx].Code
                        $statusMessage = "Language updated to $language."
                    } else {
                        $statusMessage = "Invalid selection. Enter 1-$($script:LanguageOptions.Count) or O."
                    }
                }
            }
            'D' {
                $driverPath = Read-Host '  Enter local or UNC driver folder path'
                $driverPath = $driverPath.Trim().TrimEnd('\')
                if ($driverPath) {
                    if (-not (Test-Path $driverPath)) {
                        $statusMessage = "Path not found: $driverPath (will be re-checked at build time)."
                    }
                    $driverPaths.Add($driverPath)
                    $statusMessage = "Added driver path: $driverPath"
                }
            }
            'U' {
                $driverUrl = Read-Host '  Enter driver download URL (zip/cab with .inf drivers)'
                $driverUrl = $driverUrl.Trim()
                if ($driverUrl -match '^https?://') {
                    $driverPaths.Add($driverUrl)
                    $statusMessage = "Added driver URL: $driverUrl"
                } else {
                    $statusMessage = 'Invalid URL. Must start with http:// or https://.'
                }
            }
            'R' {
                if ($driverPaths.Count -eq 0) {
                    $statusMessage = 'No driver paths to remove.'
                } else {
                    for ($j = 0; $j -lt $driverPaths.Count; $j++) {
                        Write-Host "    $($j + 1). $($driverPaths[$j])"
                    }
                    $removeIdx = Read-Host '  Enter number to remove'
                    if ($removeIdx -match '^\d+$') {
                        $ri = [int]$removeIdx - 1
                        if ($ri -ge 0 -and $ri -lt $driverPaths.Count) {
                            $removed = $driverPaths[$ri]
                            $driverPaths.RemoveAt($ri)
                            $statusMessage = "Removed: $removed"
                        }
                    }
                }
            }
            'A' {
                for ($i = 0; $i -lt $pkgCount; $i++) { $selected[$i] = $true }
                $statusMessage = 'All WinPE packages selected.'
            }
            'N' {
                for ($i = 0; $i -lt $pkgCount; $i++) {
                    if (-not $script:AvailableWinPEPackages[$i].Required) { $selected[$i] = $false }
                }
                $statusMessage = 'Optional WinPE packages deselected.'
            }
        }
    }
    } finally {
        if ($supportsVT) {
            Write-Host "${script:AnsiShowCursor}${script:AnsiAltBufferOff}" -NoNewline
        }
    }

    # Build the selected package name list (preserves dependency order)
    $selectedPkgs = @()
    for ($i = 0; $i -lt $pkgCount; $i++) {
        if ($selected[$i]) { $selectedPkgs += $script:AvailableWinPEPackages[$i].Name }
    }

    $result = @{
        Language    = $language
        Packages    = $selectedPkgs
        DriverPaths = @($driverPaths)
    }

    # Persist the configuration for next time
    Save-BuildConfiguration -Config $result

    return $result
}

function Get-DefaultLanguage {
    <#
    .SYNOPSIS  Returns the default WinPE language code.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    return $script:DefaultLanguage
}

function Get-AvailableWinPEPackages {
    <#
    .SYNOPSIS  Returns the list of available WinPE optional components.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Returns a collection of packages -- plural noun is intentional')]
    [OutputType([string[]])]
    [CmdletBinding()]
    param()
    return $script:AvailableWinPEPackages
}

Export-ModuleMember -Function Get-BuildConfigPath, Save-BuildConfiguration, Read-SavedBuildConfiguration,
                              Resolve-WinPEPackagePath, Show-BuildConfiguration,
                              Get-DefaultLanguage, Get-AvailableWinPEPackages
# SIG # Begin signature block
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAVBuIiJo7asb4t
# YwVoTmSWuUsCQgorZaoPWVie/nX9ZKCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAAf9F8I
# 9dTWl3i0AAAAAB/0MA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNDA5MTQzNDE0WhcNMjYwNDEy
# MTQzNDE0WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCx/g++XtnJK7rE
# 0KdajcoolJBoDDfdRpmQNC9/GzA0HV9OF7JqGRzyetOdvFwuoeSs/WTySDN6LfUl
# RShMrxqthSBnxKizrV6QwIshT8R8DhNlq3GlGyoaozQsFR8qUdVd5HGjEuXgea1d
# cUEEKFOEOGveUCJoNioZsCpLPqKz8kqQKDKedUXt4BEOq0ZIx8u4VWOUd/8a8+BH
# hRAmqZ2MneNYz5M3R8pjQ/LOgLWZi4HLyqvVRWE+blYB1X4sf4sZ6vY+WMgeg1IF
# 0kRJqe3z8hV0sJQ/Z8df8q3qtKwCTwW69P2jzdW5Yvv6MOgad33QAE6FWiccuxle
# t/b+4Pcj2Oq0Ewsxi8EXlg2S089n696X8EepMvOdDqd61nA7ANY3NC9UuYObLABR
# bF+N+co+Ul+JCvY5ICxRlLCh+X+EyRQ2Vt1m5zlUur2wbQZq+jkXlxB5VA3533oJ
# 5eIFvUzgPpr6VtPzY4rGAyVAxIXrG4P7n73LXg5L/ab+Nmx7jqUCAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQU4D7TdnNsaAKxOOGcp1Ym6JlRKBAwHwYDVR0jBBgwFoAUmvFUd3UM
# hxY3RqCs3nn59H/BeOkwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwNC5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBABQEzS1JWIQaoIhs/bao1+zhOP2dOlgv/XPjH/5pwAK2oUJmMOvrt2Vi
# XGXNGE4j5E21vjtuvpE0atkpqXx9rErkl7psFTWvXb2z3YNlzhjuvFoK5hUXnuYK
# 9GAmtd1ZtTJVSgnKW6NKyFLwLHGCfQnl5t0XcsbOh8gJEl/iBZBfbsWvnHNUwF8r
# L4ZCcXAQMDaEFUlyOaMqFFu/ogHc5n5Z1lXkx8Jho5Kkk41atBCMm/QZX5HAZROO
# eEpyc55dzpzlGHo2Zus/+OCo6gdFBCTge5ymPnvvQwCZphfzmZMKIdrIPgJ3Wj8p
# 8exq7dVTFdG/+DsGZeyRvGUl1noUYfFIEYjONE6A4rzxut1//ItktHlgxlwNhwdI
# qW3QyeAhrJ36x6tIMq/liCTYxXsnmc5CFj7dN583kB5fR8BsFbwiAa1aX3hbrJeX
# W14uKxPLW3tYLsE0ioGcLJ2kqp07hGhLfZXtC2TTLMf0ha6xFGRt8HcWB/x1YwC0
# Xjxk0a8bcw4A/ry9r1zgdUiGqKipuSNGKSX5g9I8/C23eeMcDSu5jQe2un6CeFYe
# iLFwuX2so0mOpWFpPRxuEGx5sg3DV8dmkGsurr+cQZqusJc3V1s/OeVTuA/PQY0D
# 2b4RVTA6lOOli2FZGLKTpuZVWTOR7UL8106eVxYVGcj7dwsXd1TNMIIGyTCCBLGg
# AwIBAgITMwAAH/RfCPXU1pd4tAAAAAAf9DANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDA0MB4XDTI2MDQwOTE0
# MzQxNFoXDTI2MDQxMjE0MzQxNFowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAsf4Pvl7ZySu6xNCnWo3KKJSQaAw33UaZkDQvfxswNB1fTheyahkc8nrTnbxc
# LqHkrP1k8kgzei31JUUoTK8arYUgZ8Sos61ekMCLIU/EfA4TZatxpRsqGqM0LBUf
# KlHVXeRxoxLl4HmtXXFBBChThDhr3lAiaDYqGbAqSz6is/JKkCgynnVF7eARDqtG
# SMfLuFVjlHf/GvPgR4UQJqmdjJ3jWM+TN0fKY0PyzoC1mYuBy8qr1UVhPm5WAdV+
# LH+LGer2PljIHoNSBdJESant8/IVdLCUP2fHX/Kt6rSsAk8FuvT9o83VuWL7+jDo
# Gnd90ABOhVonHLsZXrf2/uD3I9jqtBMLMYvBF5YNktPPZ+vel/BHqTLznQ6netZw
# OwDWNzQvVLmDmywAUWxfjfnKPlJfiQr2OSAsUZSwofl/hMkUNlbdZuc5VLq9sG0G
# avo5F5cQeVQN+d96CeXiBb1M4D6a+lbT82OKxgMlQMSF6xuD+5+9y14OS/2m/jZs
# e46lAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFOA+03ZzbGgCsTjhnKdWJuiZUSgQMB8GA1Ud
# IwQYMBaAFJrxVHd1DIcWN0agrN55+fR/wXjpMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDA0LmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQAUBM0tSViEGqCIbP22qNfs4Tj9nTpYL/1z4x/+
# acACtqFCZjDr67dlYlxlzRhOI+RNtb47br6RNGrZKal8faxK5Je6bBU1r129s92D
# Zc4Y7rxaCuYVF57mCvRgJrXdWbUyVUoJylujSshS8Cxxgn0J5ebdF3LGzofICRJf
# 4gWQX27Fr5xzVMBfKy+GQnFwEDA2hBVJcjmjKhRbv6IB3OZ+WdZV5MfCYaOSpJON
# WrQQjJv0GV+RwGUTjnhKcnOeXc6c5Rh6NmbrP/jgqOoHRQQk4Hucpj5770MAmaYX
# 85mTCiHayD4Cd1o/KfHsau3VUxXRv/g7BmXskbxlJdZ6FGHxSBGIzjROgOK88brd
# f/yLZLR5YMZcDYcHSKlt0MngIayd+serSDKv5Ygk2MV7J5nOQhY+3TefN5AeX0fA
# bBW8IgGtWl94W6yXl1teLisTy1t7WC7BNIqBnCydpKqdO4RoS32V7Qtk0yzH9IWu
# sRRkbfB3Fgf8dWMAtF48ZNGvG3MOAP68va9c4HVIhqioqbkjRikl+YPSPPwtt3nj
# HA0ruY0Htrp+gnhWHoixcLl9rKNJjqVhaT0cbhBsebINw1fHZpBrLq6/nEGarrCX
# N1dbPznlU7gPz0GNA9m+EVUwOpTjpYthWRiyk6bmVVkzke1C/NdOnlcWFRnI+3cL
# F3dUzTCCBygwggUQoAMCAQICEzMAAAAXJ0UJC4uHr8YAAAAAABcwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMzFaFw0zMTAzMjYxODExMzFaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCCx2T+Aw9mKgGVzJ+Tq0PMn49G3itIsYpb
# x7ClLSRHFe1RELdPcZ1sIqWOhsSfy6yyqEapClGH9Je9FXA1cQgZvvpQbkg+QInV
# Lr/0EPrVBCwrM96lbRI2PxNeCwXG9LsyW2hG6KQgintDmNCBo4zpDIr377plVdSl
# iZm6UB7rHwmvBnR02QT6tnrqWq2ihzB6lRJVTEzuh0OafzIMeMnYM0+x+ve5EOLH
# dfiq+HXiMf9Jb7YLHtYgyHIiJA7bTWLqFSLGaTh7ZlbxbsLXA91OOroEpv7OjzFu
# u3tkpC9FflA4Dp2Euq4+qPmxUqfGp+TX0gLRJp9NJOzzILjcTD3rkFFFbxUv1xyg
# 6avivFDLtoKBhM2Td138umE1pNOacanuSYtPHIeQHmB6haFi64avLBLwTTAm/Rbi
# t860cFXR72wq+5Qh4hSmezHqKXERWPpVBe+APrJ4Iqc+aPeMmIkoCWZQO22HnLNF
# UFSXjiwyIbgvlH/LIAJEqTafTzxDZgKhlLU7zr6gwsq3WNpcYQI6NuxWnwh3VVDD
# yF7onQqKs5Ll7bleVN0Y8VvqgE45ppyBbvwqN/Run5fMCCRz3aYMY0kZhKO92eP7
# t4zHqZ5bQMAgZ0tE2Pz/jb0wiykUF/PcoOqqk3vVLiRDYst6vd3GEMNzMpUUvQcv
# BG46+COIbwIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBSa8VR3dQyHFjdGoKzeefn0f8F46TBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQCQdVoZ/U0m38l2iKaZFlsx
# avptpoOLyaR1a9ZK2TSF1kOnFJhMDse6KkCgsveoiEjXTVc6Xt86IKHn76Nk5qZB
# 0BXv2iMRQ2giAJmYvZcmstoZqfB2M3Kd5wnJhUJOtF/b6HsqSelY6nhrF06zor1l
# DmDQixBZcLB9zR1+RKQso1jekNxYuUk+HaN3k1S57qk0O//YbkwU0mELCW04N5vI
# CMZx5T5c7Nq/7uLvbVhCdD7f2bZpA4U7vOkB1ooB4AaER3pjoJ0Mad5LFyi6Na9p
# 9Zu/hrLeOjU5FItS5YxsqvlfXxAThJ176CmkYstKRmytSHZ7JhKRfV6e9Zftk/OD
# b/CK4pGVAVqsOf4337bQGrOHHCQ3IvN9gmnUuDh8JdvbheoWPHxIN1GB5sUiY584
# tXN7xdD8LCSsRqJvQ8e7a3gZWTgViugRs1QWq+N0G9Nje6JHlN1CjJehge+H5PGk
# tJja+juGEr0P+ukSkcL6qaZxFQTh3SDI71lvW++3bl/Ezd6SO8N9Udw+reoyvRHC
# yTiSsplZQSBTVJdPmo3qCpGuyHFtPo5CBn3/FPTiqJd3M9BHoqKd0G9Kmg6fGcAv
# FwnLNXA2kov727wRljL3ypfqL7iAT/Ynpxul6RwHRlcOf9dDGg1RRvr92NP/CWVX
# Ib68geR2rvU/NsfmtjF1wDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
# AAcwDQYJKoZIhvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZl
# cmlmaWNhdGlvbiBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIx
# MDQwMTIwMDUyMFoXDTM2MDQwMTIwMTUyMFowYzELMAkGA1UEBhMCVVMxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElE
# IFZlcmlmaWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALLwwK8ZiCji3VR6TElsaQhVCbRS/3pK+MHrJSj3Zxd3
# KU3rlfL3qrZilYKJNqztA9OQacr1AwoNcHbKBLbsQAhBnIB34zxf52bDpIO3NJlf
# IaTE/xrweLoQ71lzCHkD7A4As1Bs076Iu+mA6cQzsYYH/Cbl1icwQ6C65rU4V9NQ
# hNUwgrx9rGQ//h890Q8JdjLLw0nV+ayQ2Fbkd242o9kH82RZsH3HEyqjAB5a8+Ae
# 2nPIPc8sZU6ZE7iRrRZywRmrKDp5+TcmJX9MRff241UaOBs4NmHOyke8oU1TYrkx
# h+YeHgfWo5tTgkoSMoayqoDpHOLJs+qG8Tvh8SnifW2Jj3+ii11TS8/FGngEaNAW
# rbyfNrC69oKpRQXY9bGH6jn9NEJv9weFxhTwyvx9OJLXmRGbAUXN1U9nf4lXezky
# 6Uh/cgjkVd6CGUAf0K+Jw+GE/5VpIVbcNr9rNE50Sbmy/4RTCEGvOq3GhjITbCa4
# crCzTTHgYYjHs1NbOc6brH+eKpWLtr+bGecy9CrwQyx7S/BfYJ+ozst7+yZtG2wR
# 461uckFu0t+gCwLdN0A6cFtSRtR8bvxVFyWwTtgMMFRuBa3vmUOTnfKLsLefRaQc
# VTgRnzeLzdpt32cdYKp+dhr2ogc+qM6K4CBI5/j4VFyC4QFeUP2YAidLtvpXRRo3
# AgMBAAGjggI1MIICMTAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAw
# HQYDVR0OBBYEFNlBKbAPD2Ns72nX9c0pnqRIajDmMFQGA1UdIARNMEswSQYEVR0g
# ADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L0RvY3MvUmVwb3NpdG9yeS5odG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2io
# ojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBS
# b290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBwwYIKwYB
# BQUHAQEEgbYwgbMwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0
# aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQw
# LQYIKwYBBQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20vb2NzcDAN
# BgkqhkiG9w0BAQwFAAOCAgEAfyUqnv7Uq+rdZgrbVyNMul5skONbhls5fccPlmIb
# zi+OwVdPQ4H55v7VOInnmezQEeW4LqK0wja+fBznANbXLB0KrdMCbHQpbLvG6UA/
# Xv2pfpVIE1CRFfNF4XKO8XYEa3oW8oVH+KZHgIQRIwAbyFKQ9iyj4aOWeAzwk+f9
# E5StNp5T8FG7/VEURIVWArbAzPt9ThVN3w1fAZkF7+YU9kbq1bCR2YD+MtunSQ1R
# ft6XG7b4e0ejRA7mB2IoX5hNh3UEauY0byxNRG+fT2MCEhQl9g2i2fs6VOG19CNe
# p7SquKaBjhWmirYyANb0RJSLWjinMLXNOAga10n8i9jqeprzSMU5ODmrMCJE12xS
# /NWShg/tuLjAsKP6SzYZ+1Ry358ZTFcx0FS/mx2vSoU8s8HRvy+rnXqyUJ9HBqS0
# DErVLjQwK8VtsBdekBmdTbQVoCgPCqr+PDPB3xajYnzevs7eidBsM71PINK2BoE2
# UfMwxCCX3mccFgx6UsQeRSdVVVNSyALQe6PT12418xon2iDGE81OGCreLzDcMAZn
# rUAx4XQLUz6ZTl65yPUiOh3k7Yww94lDf+8oG2oZmDh5O1Qe38E+M3vhKwmzIeoB
# 1dVLlz4i3IpaDcR+iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFI
# rmcxghqRMIIajQIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDQCEzMAAB/0Xwj11NaXeLQAAAAAH/QwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgNwcsVwQpX3iiiVKdah08YFkG0kGLSiANlOdXi7D8cm0w
# DQYJKoZIhvcNAQEBBQAEggGAp9RlcVuaQLIx2LG1YXQV/Kq5hTIP7pHobQ9DcI5n
# tkPFyiPlDNJfu5mrJLhlDsL8ikAvpoDnhftjOoCxJd4dyHstmAmVBSZJTKHrUmwR
# xKKifTWoAUB6bO6Rj+fpDDvIMQWRTCmeFiLbLPjuMwa1/n99Qhpkpgesphsg5iSb
# Dp6ga+gxtzg00O06s1GjOguB85ab2Q3mBdBpX5z+ARQ6obz5WAQ0bQ5DVJaWMiGT
# cWAFqhk/hzHyHsod76ignEq9FMNk4cO7YRJ2JGJDfntgUGr1V57jnzjD8/VX8ZQt
# tsD3hrqiiwqHx7Loy1BWNIVcDq+MMLFWl1pq92punPh6FTCbDjCFZrOL0zE5Q8fv
# tO/bNoNQEzWfFB+IKKjTpt5x3JU12Bfr5BuT7qVIIDe09XEtb16P2vKFckKVgo4c
# qTbpyY0GN2muwIxlbf14xMZEuibBSaUwJoV2DA9XJhtoWE1W9s6fYDc0c7sjMNVG
# l/XMzSKvp7FK7pgMU2DXg+fdoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIK3skFWxmQg4nKcV+ylP8cuTNiFXAmwocR1e+7iqVYo6AgZpwnLQKB8YEzIw
# MjYwNDA5MTg1NjQ5LjExMlowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RDAwLTA1RTAt
# RDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGlu
# ZyBBdXRob3JpdHmggg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAA
# BTANBgkqhkiG9w0BAQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVy
# aWZpY2F0aW9uIFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAx
# MTE5MjAzMjMxWhcNMzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBv
# f7KrQ5cMSqFSHGqg2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDs
# fMuIEqvGYOPURAH+Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbB
# T7uq3wx3mXhtVmtcCEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5
# EeH5KrlFnxpjKKTavwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6
# ovnUfANjIgM9JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fj
# JHrmlQ0EIXmp4DhDBieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOs
# RpeexIveR1MPTVf7gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiun
# hKbq0XbjkNoU5JhtYUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE
# 3oWsDqMX3jjv40e8KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8
# cIxLoKSDzCCBOu0hWdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMB
# AAGjggIbMIICFzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYD
# VR0OBBYEFGtpKDo1L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBB
# MD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0Rv
# Y3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGC
# NxQCBAweCgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTI
# ftJqhSobyhmYBAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHkl
# MjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHkl
# MjAyMDIwLmNybDCBlAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElk
# ZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0
# aG9yaXR5JTIwMjAyMC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXn
# THho+k7h2ESZJRWluLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC
# 2IWmtKMyS1OWIviwpnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5
# zyEh89F72u9UIw+IfvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbN
# nCKNZPmhzoa8PccOiQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqs
# t8S+w+RUdie8fXC1jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVm
# oNR/dSpRCxlot0i79dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRS
# SvijmwJwxRxLLpMQ/u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7v
# PKNMN+SZDWycU5ODIRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/2
# 6ozePQ/TWfNXKBOmkFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/
# AAxw9Sdgq/+rY7jjgs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSO
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFXZ3WkmKPn4
# 4gAAAAAAVTANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NDlaFw0yNjEw
# MjIyMDQ2NDlaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAvbkfkh5ZSLP0MCUWafaw/KZoVZu9iQx8
# r5JwhZvdrUi86UjCCFQONjQanrIxGF9hRGIZLQZ50gHrLC+4fpUEJff5t04VwByW
# C2/bWOuk6NmaTh9JpPZDcGzNR95QlryjfEjtl+gxj12zNPEdADPplVfzt8cYRWFB
# x/Fbfch08k6P9p7jX2q1jFPbUxWYJ+xOyGC1aKhDGY5b+8wL39v6qC0HFIx/v3y+
# bep+aEXooK8VoeWK+szfaFjXo8YTcvQ8UL4szu9HFTuZNv6vvoJ7Ju+o5aTj51sp
# h+0+FXW38TlL/rDBd5ia79jskLtOeHbDjkbljilwzegcxv9i49F05ZrS/5ELZCCY
# 1VaqO7EOLKVaxxdAO5oy1vb0Bx0ZRVX1mxFjYzay2EC051k6yGJHm58y1oe2IKRa
# /SM1+BTGse6vHNi5Q2d5ZnoR9AOAUDDwJIIqRI4rZz2MSinh11WrXTG9urF2uoyd
# 5Ve+8hxes9ABeP2PYQKlXYTAxvdaeanDTQ/vwmnM+yTcWzrVm84Z38XVFw4G7p/Z
# NZ2nscvv6uru2AevXcyV1t8ha7iWmhhgTWBNBrViuDlc3iPvOz2SVPbPeqhyY/NX
# wNZCAgc2H5pOztu6MwQxDIjte3XM/FkKBxHofS2abNT/0HG+xZtFqUJDaxgbJa6l
# N1zh7spjuQ8CAwEAAaOCAcswggHHMB0GA1UdDgQWBBRWBF8QbdwIA/DIv6nJFsrB
# 16xltjAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAFIe4ZJUe9qUKcWeWypchB58fXE/ZIWv2D5XP5/k/tB7
# LCN9BvmNSVKZ3VeclQM978wfEvuvdMQSUv6Y20boIM8DK1K1IU9cP21MG0ExiHxa
# qjrikf2qbfrXIip4Ef3v2bNYKQxCxN3Sczp1SX0H7uqK2L5OhfDEiXf15iou5hh+
# EPaaqp49czNQpJDOR/vfJghUc/qcslDPhoCZpZx8b2ODvywGQNXwqlbsmCS24uGm
# EkQ3UH5JUeN6c91yasVchS78riMrm6R9ZpAiO5pfNKMGU2MLm1A3pp098DcbFTAc
# 95Hh6Qvkh//28F/Xe2bMFb6DL7Sw0ZO95v0gv0ZTyJfxS/LCxfraeEII9FSFOKAM
# Ep1zNFSs2ue0GGjBt9yEEMUwvxq9ExFz0aZzYm8ivJfffpIVDnX/+rVRTYcxIkQy
# FYslIhYlWF9SjCw5r49qakjMRNh8W9O7aaoolSVZleQZjGt0K8JzMlyp6hp2lbW6
# XqRx2cOHbbxJDxmENzohGUziI13lI2g2Bf5qibfC4bKNRpJo9lbE8HUbY0qJiE8u
# 3SU8eDQaySPXOEhJjxRCQwwOvejYmBG5P7CckQNBSnnl12+FKRKgPoj0Mv+z5OMh
# j9z2MtpbnHLAkep0odQClEyyCG/uR5tK5rW6mZH5Oq56UWS0NI6NV1JGS7Jri6jF
# MYIHQzCCBz8CAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTANBglghkgBZQME
# AgEFAKCCBJwwEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDA5MTg1NjQ5WjAvBgkqhkiG9w0B
# CQQxIgQgOJocR5JE8+6ln2O/EtiBlRyvhnnbV8+QPwd8UuZltfAwgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCDYuTyXZIZiu799/v4PaqsmeSzBxh0rqkYq7sYY
# avj+zTB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTCCA14GCyqGSIb3DQEJ
# EAISMYIDTTCCA0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0Qw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQAdO1QBgmW/tuBZV5EG
# jhfsV4cN6qBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2CCR0wIhgPMjAyNjA0
# MDkxMTE2NDVaGA8yMDI2MDQxMDExMTY0NVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7YIJHQIBADAHAgEAAgI5STAHAgEAAgIXkTAKAgUA7YNanQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCmQByR+XzJkONpGAedVVXxRSvgki09KgTvaB9K
# raNaMgGfBJVIdTjxw1cnX+X/4nq9H8xilTSUTHOw4SeW4i6pgxLz8j+PdEmWf3Mq
# UiiudsSXBCXlDx4/U1x7LkhBtyrSX6c+PWqcKXYbTMVr3i7rgIdWWPQbJq6DRH4I
# MEcYi+ECce2vy71KlFBPhaKeYhQs4SgZeU1qeyGCu/Iq5R+D7A5BY0Nj04FRTW/u
# 82LNwDcEA/UMvtzp6un/yp1wjTAfNZA+V9SNn4/aOg8rjXA4vT/HnU/uRceo7TvY
# dcK+EbxpVnylBSwEgj93TpkAvI/fHXFlh956pjiBbNdzT1jUMA0GCSqGSIb3DQEB
# AQUABIICALNAVbCVOSS4zeexxUBPq3+bjRn8RabflO6LvROftfq8wPDXBvn7sk2d
# bN3SPYKU33tNDfrcMwpKQeqWDyAZnRypPOpsHCV6/KngT/vVxytFVetfIFs2BmSV
# vsWI7zRFY0i/6fHavfLI+NHQs6iwpXIYdQkpHcNVTyQyupFRiCkD0XeJQeUpqb4f
# i1YT1+BgOlQoKgK3QtWkWfoNJLeWl0XXCfZhkpS2Pp0gqexuV+6D52ik+kliOWG1
# 3h4aItZQtolS0vSmDxO5tSsyMfAl59iQnZ0WkRzqkFwn77AjGNgi2jt7Y2Lce0kL
# zZhbgzevhXJO775yZy88cOvS+/CFYJBVCzvcYrYhcPSVf7ed1DZWjDTOO2yjuHA4
# E3P/9Q4ykhl3S+N61EQPXCGbHGwdvi4PL3leVVJzn982+lRXY9x35E3i2OAmYi92
# 0+D8u92TWO2lL8CiDoGbtXXB5Q2WyMlGktlrfKSUYoo8UhOTm4dXJDCe8B8vcy78
# 17zFGXM5WmUZvApkbinCGYRMlSL9Rq3SDQNZ51KUCPXa67oSvcw9R/mgcRRuXekE
# QISiDZ55Wbq3keXg9cp7MPdLzhgtsF6Dttx8I66cGZW7ZPxDv9lYTG4hEMG9LwqC
# fZ4USCgGlp7CH7p+bOQ2kUcg6iuU7yeMIOemnU1OfZjYBItYC01s
# SIG # End signature block

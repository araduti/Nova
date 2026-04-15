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
# MII9cgYJKoZIhvcNAQcCoII9YzCCPV8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC3Ca4OMZrmPtwf
# OhAVi5o06vFYU4tVwKXA4bD1RWi7Q6CCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAABSQY7l
# 84XZvuWtAAAAAFJBMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNDE0MTQyMDU2WhcNMjYwNDE3
# MTQyMDU2WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQDiaaDsBkHK33PY
# y2N3c9H0WYuaS6zfCnNxJyAXwLl5/5IT5aCUSfXRZlopdexI3LGzdGlKPNTVpHMZ
# QES4+lybTKWuS1TBovX1yNXcFZL69YENBSPI+KtqIsPVevodOeWfzezWUYFlD6B0
# fP4mhQT4XUtF7V1+ULJ5O4f1vlHugoXtpYs2t2Gv2hU4kRtA4MGh3fsJcyifb751
# 4Q96Vo4ADMWsr1DNNIkdO/+3F/Gn2Q+Iq3UknXFT8PD4yl25OaEsMQe1tk9sPupo
# Z8RIkXWdqbfTWvIJvw/EREIqAQ8jTCMTZpb352JoH9f9DeOAUDb8PTIgGUyekZxK
# ZazRrgF3Uj/Ffb29viRKTCBgVaw1/ouPVsJ3ZMZgVaQoQiEYHfu+jRP0Jk3ve+Y4
# O5FMzBVh1qPh48akw41SNpZiZNNhg3cQ/SUHbkFaoRQ2IRbLSZnryEXjZloC2RO5
# mj1Do2BN4ib1qsiIUWVoa70Fy/sdNW2HswU2RNB82Gxk73sfft8CAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUuIt05EZ/8gwAGTL+u0c6lJfmskQwHwYDVR0jBBgwFoAUa16lNMMF
# xWJKIVqOq3NgYtSsY4UwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMy5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAGhA2xIUuTvm6OOZjzD9zV83DdPaQDYV3on1pi4Dho+ne+Rd6huJVA+X
# h+uWEyglV1cZ4scWfl+2JerD6SyFQSpBR8NKcCFjsDh4qlQjegPPq1iYPubmCGsd
# xXV1k+8nF6RCRhQNsD0EN2yWosjFkKV4ksB1za9yKTpo4MY+RyD4PVUxBKkDr/FT
# e+MDK1oB6OwQwYD+DC1ApwBdAbfY4A5XY6NLpQLjo5bz6L5vXanejrwxKjzQXob5
# aXnjCz27AGCNddicZmJ+3pyocUUB3DnVo6xeG5iPnPb/3oT77AghHJ+EmNxJWjc8
# MKjZskbZiC47pt/HXGEilWZ7RH/8WBiydlY4sQIOIBmZy53G+Ed53l7kyO6iTx0n
# fR5r66/iyeXNmU7jfcn0eMHtNR5X1ZOYENsF/v1xyRwyjJcRyJgQdmzfUNJQhKqJ
# J5QIN1d5aprYLvjmsQRU9Maz9K1afjGu+Y4T/tJM9mO4KdNwC0VM81pwO6l4gGw3
# o7xRNcud74cZRYyt7X0W9z1Mf/ZDobF1IchSiKfpTZ2p2vHwxZ10GIYLjUAQPPIw
# Df+6EQFXYoASJJjcmwlg5GOHFmEM6YQ2bPle9X7ilNDRtPclWV4N59CS3ovAokYn
# W1CgY3T34Y2V96NMn/Qk1Ov+zL/4AnO2ds+9KjXiRn0se5mm6JevMIIGyTCCBLGg
# AwIBAgITMwAAUkGO5fOF2b7lrQAAAABSQTANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMB4XDTI2MDQxNDE0
# MjA1NloXDTI2MDQxNzE0MjA1NlowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEA4mmg7AZByt9z2Mtjd3PR9FmLmkus3wpzcScgF8C5ef+SE+WglEn10WZaKXXs
# SNyxs3RpSjzU1aRzGUBEuPpcm0ylrktUwaL19cjV3BWS+vWBDQUjyPiraiLD1Xr6
# HTnln83s1lGBZQ+gdHz+JoUE+F1LRe1dflCyeTuH9b5R7oKF7aWLNrdhr9oVOJEb
# QODBod37CXMon2++deEPelaOAAzFrK9QzTSJHTv/txfxp9kPiKt1JJ1xU/Dw+Mpd
# uTmhLDEHtbZPbD7qaGfESJF1nam301ryCb8PxERCKgEPI0wjE2aW9+diaB/X/Q3j
# gFA2/D0yIBlMnpGcSmWs0a4Bd1I/xX29vb4kSkwgYFWsNf6Lj1bCd2TGYFWkKEIh
# GB37vo0T9CZN73vmODuRTMwVYdaj4ePGpMONUjaWYmTTYYN3EP0lB25BWqEUNiEW
# y0mZ68hF42ZaAtkTuZo9Q6NgTeIm9arIiFFlaGu9Bcv7HTVth7MFNkTQfNhsZO97
# H37fAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFLiLdORGf/IMABky/rtHOpSX5rJEMB8GA1Ud
# IwQYMBaAFGtepTTDBcViSiFajqtzYGLUrGOFMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDAzLmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBoQNsSFLk75ujjmY8w/c1fNw3T2kA2Fd6J9aYu
# A4aPp3vkXeobiVQPl4frlhMoJVdXGeLHFn5ftiXqw+kshUEqQUfDSnAhY7A4eKpU
# I3oDz6tYmD7m5ghrHcV1dZPvJxekQkYUDbA9BDdslqLIxZCleJLAdc2vcik6aODG
# Pkcg+D1VMQSpA6/xU3vjAytaAejsEMGA/gwtQKcAXQG32OAOV2OjS6UC46OW8+i+
# b12p3o68MSo80F6G+Wl54ws9uwBgjXXYnGZift6cqHFFAdw51aOsXhuYj5z2/96E
# ++wIIRyfhJjcSVo3PDCo2bJG2YguO6bfx1xhIpVme0R//FgYsnZWOLECDiAZmcud
# xvhHed5e5Mjuok8dJ30ea+uv4snlzZlO433J9HjB7TUeV9WTmBDbBf79cckcMoyX
# EciYEHZs31DSUISqiSeUCDdXeWqa2C745rEEVPTGs/StWn4xrvmOE/7STPZjuCnT
# cAtFTPNacDupeIBsN6O8UTXLne+HGUWMre19Fvc9TH/2Q6GxdSHIUoin6U2dqdrx
# 8MWddBiGC41AEDzyMA3/uhEBV2KAEiSY3JsJYORjhxZhDOmENmz5XvV+4pTQ0bT3
# JVleDefQkt6LwKJGJ1tQoGN09+GNlfejTJ/0JNTr/sy/+AJztnbPvSo14kZ9LHuZ
# puiXrzCCBygwggUQoAMCAQICEzMAAAAVBT5uGY6TKdkAAAAAABUwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMjhaFw0zMTAzMjYxODExMjhaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDg9Ms9AqovDnMePvMOe+KybhCd8+lokzYO
# RlS3kBVXseecbyGwBcsenlm5bLtMGPjiIFLzBQF+ghlVV/U29q5GcdeEEBCHTTGh
# L2koIrLc4UrliMRcbv9mOMtR/l7/xAmv0Fx4BJHn1dHt37fvrBqXmKjKfGf5DpyO
# /+hnV7TEreMtS19iO+bjZ/9Hnpg3PCk0e7YSbRTFkx97FZwRWpC4s3NepRfRXQh/
# WMAj7JmsYeVZohi4TF5yW2JMrJZqwHcyzJZYtD2Hlno5ZEJkdiZcEaxHOobmwO06
# Z1J9c23ps9PGIhGaq1sKLEAz9Doc5rLkYWGteDrscKhAp2kIc/oYlH9Ij6BkOqqg
# WINEkEtC8ZNG1Mak+h3o65aj0iQKmdxW7IZaHO5cuyoMi+KtYfXeIIg3sVIbS2EL
# 8kUtsDGdEqNqAq/isqTi1jXqLe6iKp1ni1SPdvPW9G03CTsYF68b/yuIQRwbdoBC
# XemMNJCS0dorCRY4b2WAAy4ng7SANcEgrBgZf535+QfLU5hGzrKjIpbMabauWb5F
# KWUKkMsPcXFkXRWO4noKPm4KWlFypqOpbJ/KONVReIlxHQRegAOBzIhRB7gr9IDQ
# 1sc2MgOgQ+xVGW4oq4HD0mfAiwiyLskZrkaQ7JoanYjBNcR9RS26YxAVbcBtLitF
# TzCIEg5ZdQIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBRrXqU0wwXFYkohWo6rc2Bi1KxjhTBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBdbiI8zwXLX8glJEh/8Q22
# UMCUhWBO46Z9FPhwOR3mdlqRVLkYOon/MczUwrjDhx3X99SPH5PSflkGoTvnO9ZW
# HM5YFVYpO7NYuB+mfVSGAGZwiGOASWk0i2B7vn9nElJJmoiXxugfH5YdBsrUgTt0
# AFNXkzmqTgk+S1Hxb1u/0HCqEHVZPk2A/6eJXYbtpRM5Fcz00jisUl9BRZgSebOD
# V85bBzOveqyC3f0PnHCxRJNhMb8xP/sB/VI7pf2rheSV7zqUSv8vn/fIMblXeaVI
# lpqoq8SP9BJMjE/CoVXJxnkZQRM1Fa7kN9yztvReOhxSgPgpZx/Xl/jkwyEFVJTB
# fBp3sTgfIc/pmqv2ehtakL2AEj78EmOPQohxJT3wyX+P78GA25tLpAvzj3RMMHd8
# z18ZuuVi+60MAzGpOASH1L8Nlr3fZRZnQO+pyye2DCvYmHaIfdUgYJqn7noxxGVv
# 89+RaETh1tgCDvwNpFCSG7vl5A4ako+2fx409r9TWjXC7Oif1IQ5ZJzB4Rf8GvBi
# HYjvMmHpledp1FGRLdSRFVpC3/OKpZY6avIqZp7+8pP/WQP903DdgrvAT6W4xPOB
# xXPa4tGksN3SuqJaiFYHSNyeBufn8iseujW4IbBSbHD4BPqbF3qZ+7nG9d/d/G2/
# Lx4kH9cCmBfmsZdSkHmukDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
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
# rmcxghqQMIIajAIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDMCEzMAAFJBjuXzhdm+5a0AAAAAUkEwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgLNlUGROFsWRKg6M2wV2bgwuFSzhUD0ZQK7GEz/BUSLIw
# DQYJKoZIhvcNAQEBBQAEggGAxBTQSuCKE3OEe5qTlHom3y7JdCGTBndy6ttmJuDi
# pRqCVOqijPK2yhsGpXaZxBDk9c+NEctLRo5WNGeoai1AOha6XclNrovYzYicmg0A
# Sf8eXkteCME8+ReeAgsBGoDPla/fqgYmDdIWXEGxfseH3tpCNQ5r66KvFabKg1jJ
# l5ExESHPzKX07XoY69cJwZEOIumFSTnCp1/84tc1+XZD5MJg5ZYRF4gmv8GACHU9
# hiZlJ6skMqPaloGGml+zjlLGAO45WYWAxZdg+BmOXVGE9raYockUwFx95yJcrblB
# QA0sbE/rKHuT5zEtt1cQFDizzAAmOdIcAXu+DwrsWYVlFSi5RejMIr8cqncg9qgG
# N9rcU293ITFrWuqffDRfRJvCqT8HY8OcgvwOKIJdpvMXFJP00U3RtIwDvCoKKteI
# nmujnyX6r2XEPdYLXeLn/TuiNIR+qpS/cPnQ+SuWhPoulNsTmgg1cIX2gNEIZnTK
# 7ZMAXtG/RuJ1v0s9uJ+ur3lGoYIYEDCCGAwGCisGAQQBgjcDAwExghf8MIIX+AYJ
# KoZIhvcNAQcCoIIX6TCCF+UCAQMxDzANBglghkgBZQMEAgEFADCCAWEGCyqGSIb3
# DQEJEAEEoIIBUASCAUwwggFIAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEILKK377ttkvIY/QwVJE3eCGxVgcyynRWI87kF80ubp0SAgZp1AaM5r0YEjIw
# MjYwNDE1MDczOTUwLjYxWjAEgAIB9KCB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaCCDyEwggeCMIIFaqADAgECAhMzAAAABeXPD/9mLsmHAAAAAAAF
# MA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJp
# ZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMDEx
# MTkyMDMyMzFaFw0zNTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAnnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1lRkd3kcFdcG9/
# sqtDlwxKoVIcaqDb+omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjxnG/eViS4sOx8
# y4gSq8Zg49REAf5huXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5hJM1xznkRsFP
# u6rfDHeZeG1Wa1wISvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFlyAKwn6yjN/kR
# 4fkquUWfGmMopNq/B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTPVi3gVErnc/qi
# +dR8A2MiAz0kN0nh7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKxLms73KG/Z+Mk
# euaVDQQheangOEMGJ4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxRYR/JPGAaM6xG
# l57Ei95HUw9NV/uC3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxOmM2rl4uKK6eE
# purRduOQ2hTkmG1hSuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cjRKG79+TX+sTe
# hawOoxfeOO/jR7wo3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xTnD1a69w/UTxw
# jEugpIPMIIE67SFZ2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8FUXetXr0CAwEA
# AaOCAhswggIXMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNV
# HQ4EFgQUa2koOjUvSGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJBgRVHSAAMEEw
# PwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9j
# cy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFMh+
# 0mqFKhvKGZgEByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3JsMIGUBggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUHMAKGdWh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSWRl
# bnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRo
# b3JpdHklMjAyMDIwLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2x35ttVoVdedM
# eGj6TuHYRJklFaW4sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6AF6ycWoEYR0LY
# haa0ozJLU5Yi+LCmcrdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM74LNvVzY0/nP
# ISHz0Xva71QjD4h+8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLslLKsO8F2aBs2c
# Io1k+aHOhrw9xw6JCWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yFM7Ujrhc0aqy3
# xL7D5FR2J7x9cLWMq7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFovIP7YG4ZkJWag
# 1H91KlELGWi3SLv10o4KGag42pswjybTi4toQcC/irAodDW8HNtX+cbz0sMptFJK
# +KObAnDFHEsukxD+7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9TlxydiFhvu88
# o0w35JkNbJxTk4MhF/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWVydt4ytxYP/bq
# jN49D9NZ81coE6aQWm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeCUMYmBx3PkP8A
# DHD1J2Cr/6tjuOOCztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdtoSAHEUKiBhI6J
# QivRepyvWcl+JYbYbBh7pmgAXVswggeXMIIFf6ADAgECAhMzAAAAVyTTleCi6ckx
# AAAAAABXMA0GCSqGSIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMB4XDTI1MTAyMzIwNDY1M1oXDTI2MTAy
# MjIwNDY1M1owgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsT
# Hm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9z
# b2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHkwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCxbKUKkwh9uLMktjWQ9c7ZyZfYdFa9FsCZ
# 4pJnl7Hv+MLKZ1XsRqn4hzaKpG1YOQop7mAvolXzTC2fkLaocks/FRgUo0bdSQeQ
# AjbUygI35haeFPwr9i4+Jvr7r3vSN1t4UoiJkxbB3mGelf0neN6164R1dun8N8UE
# rXkm4Pck7Na4Xay5AI+CpiNA+T+Cmr7coIq1clFtdIJIn1i0hNTYgfCZ90TuXY99
# nXnjDTjWmj58N5OPSAk7NxX8m/npDQz7DX2MAqj8jk8TOstXUg9CeY/iivVfhFsl
# eTw41fI459c7ErZUuk3GCSUrXIB7NsU/a7OqKFpeRbWH0ZAsYQ0oRKd7PCB1Fos0
# 1pi2bwBP+lkdgnfmZlWqRl0whySlAcmT8XV9IvIMp4q0fhMLhxzcRIpQyAi2rTtl
# mbvgkKx+GatDWKNU0OLVKWf5AFqaALta+JluRCdx5BGr0Nj7qEA3A6tqwBlSJWva
# Q+6PWMcM5fNQbg71BMrvQ/+hdKpkA3WhO/dR8XwlMaYDGD6XVk87PnQxj3ocEPD/
# dsj/AEY28uTp8tWevEY3kHm6cX+Vi+ONZshR3IE9VCc84pe7TxJEdtjX0zUehZfo
# 81m/6/NJ6pV5ZYcp0qMLcaNWNtsamL4ktuLJopFLASqjj20ku+7r1xDt1axuSxqL
# hNRGdWPaYwIDAQABo4IByzCCAccwHQYDVR0OBBYEFI6DyV4tNQ4CCUhn5uNemIPt
# EpKnMB8GA1UdIwQYMBaAFGtpKDo1L0hjQM972K9J6T7ZPdshMGwGA1UdHwRlMGMw
# YaBfoF2GW2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jv
# c29mdCUyMFB1YmxpYyUyMFJTQSUyMFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5j
# cmwweQYIKwYBBQUHAQEEbTBrMGkGCCsGAQUFBzAChl1odHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUy
# MFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5jcnQwDAYDVR0TAQH/BAIwADAWBgNV
# HSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwZgYDVR0gBF8wXTBR
# BgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEAjANBgkq
# hkiG9w0BAQwFAAOCAgEAcnXAdjzpmTlJQEM9jbl3+71glVpo1rvW7GNfhzI79cni
# 48Q0JI7CRFOc2iA8vFMPQWDfPhMV//ZP/QgVLF21ZW1OOHOuf5YsifN5FrBSFMIV
# Ws8EkoRZWyGb4iDv+cHslsk3zz6W0iYFsvmRPVK0Et8bpSSwBwNs1JDDD3QJReEa
# 54HGWdK+OQBfWiGI3XrLVsHazSu9DHwKx6mXYK4F59N8OswbNb+3M3HlhorYPw5b
# B6pNZlwaUk7hiNk0jzdxOtCCF8eX/wBc4ePxxYvfAQWW1BCzbF5FgBvcp2eXughY
# opdZoFgljk/dA+yIL4NMynt6N1gpOtvf3p/eCv7Av8yzn9ne8hZk8km/Xyo3DjR9
# Q295GfDMxCfHx0zZsa5ddBnnLs/xpdPgckyjfj2pm2fhdDCJQT8MOn74xQvSSCO9
# 38N6jtevfvU8U89hvhNuhmGNXXH37AIcOg6k0IG35W5dTvzK0l0rNDUm/ZwQ/UX0
# f3/BIuwwNS9YwTu72YYSU48Nk8xWvwC4ES4t1tNIR1ovCxkGmXPEsFyDGFn8KzfT
# IGG4TdCGpPVgNnalrnpF7E8DZJqw9xOhPqAmAnoTToGZnbNBM29Y6OzldCodti5d
# yh4NzB7ZRoLsQM4YPwaYsT0uKq1Cy5AIzu/sjbFH6w9lPYDH/zkeMiQz7czNMrUx
# ggdDMIIHPwIBATB4MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwAhMzAAAAVyTTleCi6ckxAAAAAABXMA0GCWCGSAFlAwQC
# AQUAoIIEnDARBgsqhkiG9w0BCRACDzECBQAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3
# DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjA0MTUwNzM5NTBaMC8GCSqGSIb3DQEJ
# BDEiBCAJSqJqyqi4jxm4JELs30zKsHXlgDHlw8eP++fnA/E25jCBuQYLKoZIhvcN
# AQkQAi8xgakwgaYwgaMwgaAEIPU8n2S1BW5MZYhsos7h/VVQ6VRTb0BEISkNmYVM
# eNtSMHwwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFt
# cGluZyBDQSAyMDIwAhMzAAAAVyTTleCi6ckxAAAAAABXMIIDXgYLKoZIhvcNAQkQ
# AhIxggNNMIIDSaGCA0UwggNBMIICKQIBATCCAQmhgeGkgd4wgdsxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBB
# bWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAw
# LTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBT
# dGFtcGluZyBBdXRob3JpdHmiIwoBATAHBgUrDgMCGgMVAP0vMTmcQlEBQTZKzfFo
# oo9cecvDoGcwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwMA0GCSqGSIb3DQEBCwUAAgUA7Ym5uzAiGA8yMDI2MDQx
# NTA3MTYxMVoYDzIwMjYwNDE2MDcxNjExWjB0MDoGCisGAQQBhFkKBAExLDAqMAoC
# BQDtibm7AgEAMAcCAQACAimyMAcCAQACAhLAMAoCBQDtiws7AgEAMDYGCisGAQQB
# hFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAw
# DQYJKoZIhvcNAQELBQADggEBAGy29Lf780+oCGLNmAhvGaGq9qzqmX5ky5ZICoyx
# irUbNlS4luqYth9gwGEwvhOxq5ftj2HzrWYsfUt6YcDGhUeaAhgfFhIjMoBuzyd1
# MaNlcEPuaDM0d6OHPNZc2S/i1cDSTTIUrf1PcOw95Ret6vXqX4GuTqWXcVQSVW37
# AuPwtL3nZ/P7jJ0x/Y4qdKiPlYs6RfTuZvDfgnSsmCqqkj+zj8UDX/4QlI48KS19
# RtgJ5/zGmVBytQ4pTwsNQZpSv6+4UGNSVwZthZ+TKNKTgrA2pokjzDMS/OmmueHJ
# gMNleJbUkkJ7N92+vgE4GgVkm8LoIV4qdHMeA8Jd9MCojvUwDQYJKoZIhvcNAQEB
# BQAEggIAkzEBRwQXbbDhiZCMU9mzNoN1p+wZ+DZSKs53ACDeVwAzgS1BkNdOs9Ae
# dxzCsRMe7mpz0Ep5nfy3p47IKRXnT6cAO5k3pjlf7HrUogDFOWx+iMDFwA9Acde2
# L8cXtvIGCREEE28B8oR1cEiSS1qsl4gOiJtuJcmGmyvPCC1r1sa9GJdwPOUyr0vW
# /Eih4bFWLuQB1Njc3DSz/FfJFpmi+4G79XDlDFoL2kGaHjSV63tP5iZXDjpeXGw6
# h5soFKCRDPFVjux81E1GbuxW6z+YZwLFFZBpjOgHnrzzXEIyrPsW3bpngHxJob+3
# UU7cTHrIF9p5Bb4sHWpA0KdWnkfKtYIfo0bKuH/gzyLcGw2xq4hNWqQ84eAq34sB
# IUuj5V+x5hrsHm1hy7b660W7E5JqQuw7ns8I/xhRbMFhu6g/kaGg7XksZ0UCABL7
# hBaUoekc2ZxD/3LShNUVtx8ozWca+J1CitQtBOdnKOG2I85E2FZ1s5arrnWpk5Su
# r1vQGU299uKlFdJWxbVsLyzG8M+hHJftykTTkb8LQMdy9gjj1ylTboQhALBTwrU0
# mlcUSutn9cz0uebNhfSMZWwmO3o0hJTR4hcibgl+hub7xA40X8ReVokFqay9HmXM
# taJCgBr6aobfTJkWCf0CwUUAtvwFmvkTcsnq6FmRvc8ZHcMdG4A=
# SIG # End signature block

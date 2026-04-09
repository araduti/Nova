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
$script:AnsiYellow       = "${script:ESC}[33;1m"
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
                Write-Host "${script:AnsiCursorHome}${script:AnsiClearToEnd}" -NoNewline
            } else {
                Clear-Host
            }
            Write-Host ''
            Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
            Write-Host '  ║       Nova Build Console · Premium Interactive Mode      ║' -ForegroundColor Cyan
            Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
            Write-Host ''
            Write-Host "    ${script:AnsiDim}Architecture${script:AnsiReset}  ${script:AnsiBold}$Architecture${script:AnsiReset}" -ForegroundColor White
            Write-Host "    ${script:AnsiDim}Language${script:AnsiReset}      ${script:AnsiBold}$language${script:AnsiReset}" -ForegroundColor White
            Write-Host ''
            $selCountDisplay = ($selected | Where-Object { $_ }).Count
            Write-Host "  WinPE Optional Components  ${script:AnsiDim}($selCountDisplay/$pkgCount selected)${script:AnsiReset}" -ForegroundColor White
            Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray

            for ($i = 0; $i -lt $pkgCount; $i++) {
                $pkg  = $script:AvailableWinPEPackages[$i]
                $mark = if ($selected[$i]) { '■' } else { '□' }
                $num  = '{0,2}' -f ($i + 1)
                $padName = $pkg.Name.PadRight(24)
                $isHighlighted = ($i -eq $cursorIndex)
                if ($isHighlighted -and $supportsVT) {
                    $color = if ($selected[$i]) { 'Green' } else { 'DarkGray' }
                    $reqTag = if ($pkg.Required) { " ${script:AnsiReset}${script:AnsiYellow}(required)${script:AnsiReverse}" } else { '' }
                    Write-Host "  ${script:AnsiReverse}  [$mark] $num. $padName $($pkg.Description)$reqTag  ${script:AnsiReset}" -ForegroundColor $color
                } else {
                    $color = if ($selected[$i]) { 'Green' } else { 'DarkGray' }
                    if ($pkg.Required -and $supportsVT) {
                        Write-Host "    [$mark] $num. $padName $($pkg.Description) ${script:AnsiYellow}(required)${script:AnsiReset}" -ForegroundColor $color
                    } else {
                        $tag = if ($pkg.Required) { ' (required)' } else { '' }
                        Write-Host "    [$mark] $num. $padName $($pkg.Description)$tag" -ForegroundColor $color
                    }
                }
            }

            Write-Host ''
            Write-Host "  WinPE Drivers  ${script:AnsiDim}($($driverPaths.Count) added)${script:AnsiReset}" -ForegroundColor White
            Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray

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
                Write-Host "  ${script:AnsiCyan}Status:${script:AnsiReset} $statusMessage" -ForegroundColor Yellow
            } else {
                Write-Host "  ${script:AnsiDim}Status: Ready${script:AnsiReset}" -ForegroundColor DarkGray
            }
            # Key shortcut hints -- highlight keys when terminal supports ANSI
            $kc = if ($supportsVT) { $script:AnsiCyan } else { '' }
            $kr = if ($supportsVT) { $script:AnsiReset + $script:AnsiDim } else { '' }
            $dr = if ($supportsVT) { $script:AnsiReset } else { '' }
            $dp = if ($supportsVT) { $script:AnsiDim }  else { '' }
            Write-Host "  ${dp}┌──────────────────────────────────────────────────────────┐${dr}" -ForegroundColor DarkGray
            Write-Host "  ${dp}│  ${kc}↑/↓${kr}  navigate          ${kc}Space${kr}  toggle item             ${dr}│" -ForegroundColor DarkGray
            Write-Host "  ${dp}│  ${kc}1-9${kr}  toggle package     ${kc}L${kr}  change language            ${dr}│" -ForegroundColor DarkGray
            Write-Host "  ${dp}│  ${kc}D${kr}    add driver path    ${kc}U${kr}  add driver URL             ${dr}│" -ForegroundColor DarkGray
            Write-Host "  ${dp}│  ${kc}A${kr}    select all pkgs    ${kc}N${kr}  deselect optional pkgs     ${dr}│" -ForegroundColor DarkGray
            Write-Host "  ${dp}│  ${kc}R${kr}    remove driver      ${kc}Enter${kr}  continue with build  ⏎ ${dr}│" -ForegroundColor DarkGray
            Write-Host "  ${dp}└──────────────────────────────────────────────────────────┘${dr}" -ForegroundColor DarkGray
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
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDFENzSaTnBOAuv
# b5zi/ztCu4FdSB9iDbLIIuEIAKhY9KCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAATbzZ1
# WlQRwN+WAAAAABNvMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNDA4MTQzNTAyWhcNMjYwNDEx
# MTQzNTAyWjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCaXp6ZOAqpSGDC
# lEJL0tP6AaWlljn7+Nyx7mo3psGnxvPkngIY/lD/QHTpKOndvoq4knt04gr0kkGp
# ClfAlaI1BNcS+k6W3jy/dtA6w/k456OkCkjjGLqFEHaNXKVqnzI92GP6gCmn9ov0
# +uni4oROr5At/kLAh0zyXqTNBNQ+qd1QzQ4Y+CgIXlKnGBbi0RVx21T4tDsZ8mCX
# yxvlRHdXFNtEkEmkkGxbOziPkvav6QLRnr7/tALqWOrY1WHX6T/SGbrh5OPQivvs
# w94+JUX/m2uzHV6j0qHdfe8BJyYQ3U3NAGNFSQoshMtbV721R3XEnaXBy2U1A6TH
# zixwtXxQ5zRPrU65hNPrSTzkiK+a2VOLlOGP7+es1Eq8lKFRUVvjNFW1YgWwGf3g
# P2Z+4B2uMdml126+rmdUvTyAmEBqYeLNIfGfnTa+qlD9Lno8rqTyLrcN3bv8st+7
# Au+V47C6PDqbTyb/TjZ6BsoXsJtmLZAruTlFpCINQa4bksFN3d8CAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUYsueSbGxd9TixyeW27ISjBdBHnEwHwYDVR0jBBgwFoAUa16lNMMF
# xWJKIVqOq3NgYtSsY4UwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMy5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAELukzNfojQy7MXCmtBzdvxdxKTEvjdX3Zvu+aX5sDNMsy/q8JYeQG8u
# hingdUYeqHjwOtgenn5kqnY7Kb2C7IltAr6dZGZ/l+SSZGrAD0plWX5rUfhhTLGe
# j95/4C5Jnku01cG2FXBQbMkGaY1xe/bfnK8wn931lajOBdsbfVkhmTEIdchxu6sz
# /0UVg3tlIRqiiJtQCE71iWJVNmW8IdVOXhzy0dFOmhUHVgNelCAPqdJChaQvKwTJ
# 97SYWRT33jKI0+ylRRmKmEO1a8cMPIkn6cImafpGD9pmsquet3PLuQNGDAU5FYrm
# o5sqBW/LXTspdjbfje9obnCXKgOY/JLIiGaUZYppeRTWWwwnAHcFm6v40/CGADij
# VZhC0XiGYdEuYjbM0V4btEtcOtDr18oMVLwV27rJwxCek6wfza0ojyVYk1B0HC1k
# R6UICd3Mhrok4n0OOVn9RArCK4QrJ3oGpuHLU0H80XQdeJP95K4HsVj3Ln8S5qOV
# 0u98nFEyhg39UKnJioibO4tHeLWAY+CEpI/qoTva8SBMPc292R92mEWd5ck3xFG+
# voVEjXUwh9YbxRIVg14i4DFQSABoDbNwwuZ//uAP7e1/NaYskP8jbAjcm8AEaUeh
# 1CHYMwwA3ylB0lRP/e/Awtw4mFMKOFr0B4yLykkGvtK1hFlbWMqIMIIGyTCCBLGg
# AwIBAgITMwAAE282dVpUEcDflgAAAAATbzANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMB4XDTI2MDQwODE0
# MzUwMloXDTI2MDQxMTE0MzUwMlowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAml6emTgKqUhgwpRCS9LT+gGlpZY5+/jcse5qN6bBp8bz5J4CGP5Q/0B06Sjp
# 3b6KuJJ7dOIK9JJBqQpXwJWiNQTXEvpOlt48v3bQOsP5OOejpApI4xi6hRB2jVyl
# ap8yPdhj+oApp/aL9Prp4uKETq+QLf5CwIdM8l6kzQTUPqndUM0OGPgoCF5SpxgW
# 4tEVcdtU+LQ7GfJgl8sb5UR3VxTbRJBJpJBsWzs4j5L2r+kC0Z6+/7QC6ljq2NVh
# 1+k/0hm64eTj0Ir77MPePiVF/5trsx1eo9Kh3X3vAScmEN1NzQBjRUkKLITLW1e9
# tUd1xJ2lwctlNQOkx84scLV8UOc0T61OuYTT60k85IivmtlTi5Thj+/nrNRKvJSh
# UVFb4zRVtWIFsBn94D9mfuAdrjHZpdduvq5nVL08gJhAamHizSHxn502vqpQ/S56
# PK6k8i63Dd27/LLfuwLvleOwujw6m08m/042egbKF7CbZi2QK7k5RaQiDUGuG5LB
# Td3fAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFGLLnkmxsXfU4scnltuyEowXQR5xMB8GA1Ud
# IwQYMBaAFGtepTTDBcViSiFajqtzYGLUrGOFMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDAzLmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBC7pMzX6I0MuzFwprQc3b8XcSkxL43V92b7vml
# +bAzTLMv6vCWHkBvLoYp4HVGHqh48DrYHp5+ZKp2Oym9guyJbQK+nWRmf5fkkmRq
# wA9KZVl+a1H4YUyxno/ef+AuSZ5LtNXBthVwUGzJBmmNcXv235yvMJ/d9ZWozgXb
# G31ZIZkxCHXIcburM/9FFYN7ZSEaooibUAhO9YliVTZlvCHVTl4c8tHRTpoVB1YD
# XpQgD6nSQoWkLysEyfe0mFkU994yiNPspUUZiphDtWvHDDyJJ+nCJmn6Rg/aZrKr
# nrdzy7kDRgwFORWK5qObKgVvy107KXY2343vaG5wlyoDmPySyIhmlGWKaXkU1lsM
# JwB3BZur+NPwhgA4o1WYQtF4hmHRLmI2zNFeG7RLXDrQ69fKDFS8Fdu6ycMQnpOs
# H82tKI8lWJNQdBwtZEelCAndzIa6JOJ9DjlZ/UQKwiuEKyd6Bqbhy1NB/NF0HXiT
# /eSuB7FY9y5/EuajldLvfJxRMoYN/VCpyYqImzuLR3i1gGPghKSP6qE72vEgTD3N
# vdkfdphFneXJN8RRvr6FRI11MIfWG8USFYNeIuAxUEgAaA2zcMLmf/7gD+3tfzWm
# LJD/I2wI3JvABGlHodQh2DMMAN8pQdJUT/3vwMLcOJhTCjha9AeMi8pJBr7StYRZ
# W1jKiDCCBygwggUQoAMCAQICEzMAAAAVBT5uGY6TKdkAAAAAABUwDQYJKoZIhvcN
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
# rmcxghqRMIIajQIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDMCEzMAABNvNnVaVBHA35YAAAAAE28wDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQg3UgmzSWV41qWsapFiETp7UQhKUzExuDtKmrqJXS8VkMw
# DQYJKoZIhvcNAQEBBQAEggGAG/Y5wr2j1l/BnCMmxZxdy/UvcVtN4GdUwue7Eoeb
# +fA1Q6NAnKKakkfkrb2FpBQnZ0wyuE3+dWQ+JgARDVj2Q3gr8E/8SMhWxGyqRbOU
# 77AEZlvylilsB3WGqdU+OFl/tDWuAI7GbHETBIydhGfBATza50LJ+cun25xYJpgm
# mN6vA+CMpct+Bm+oKhNo/CQkqqetOvOXixOSHMICPhrweqe4r1bTbON4wMxET1Gd
# VCTe+uhBLQ8H+YpNd4k2wv5obx8JK7nCt6UPjxGYmXp/pP32ApS80pXbTmGN9oeq
# Vyf60+RP/bT0Q+xkxu+85AU+aC1Zf3QXIyywFcbM+jEf2pM3OW4QcTj6O3VJdxNe
# tPNawNKJIDsxUud1AoSW7S+LSNHQJre+2QsXHpXFaRvVfWux6YPvdXhtkLtJjrSQ
# SGlh1lJIQ/N6/4C1ae4Gt4HiVA6kh4jFXRJBrI2ID2Gy8jol+hOvcZCng+Ef5e+N
# PFtKg4IhwNzGvvE8dfs6l5G+oYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIF4CaunIzPzZ/m4r5lrzYVjw2cS/Tin61jSL8ovniUSKAgZpwmahtwoYEzIw
# MjYwNDA5MDczNTI5LjMxM1owBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAt
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
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFZ+j51YCI7p
# YAAAAAAAVjANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTFaFw0yNjEw
# MjIyMDQ2NTFaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtKWfm/ul027/d8Rlb8Mn/g0QUvvLqY2V
# sy3tI8U2tFSspTZomZOD3BHT8LkR+RrhMJgb1VjAKFNysaK9cLSXifPGSIBrPCgs
# 9P4y24lrJEmrV6Q5z4BmqMhIPrZhEvZnWpCS4HO7jYSei/nxmC7/1Er+l5Lg3PmS
# xb8d2IVcARxSw1B4mxB6XI0nkel9wa1dYb2wfGpofraFmxZOxT9eNht4LH0RBSVu
# eba6ZNpjS/0gtfm7qiIiyP6p6PRzTTbMnVqsHnV/d/rW0zHx+Q+QNZ5wUqKmTZJB
# 9hU853+2pX5rDfK32uNY9/WBOAmzbqgpEdQkbiMavUMyUDShmycIvgHdQnS207sT
# j8M+kJL3tOdahPuPqMwsaCCgdfwwQx0O9TKe7FSvbAEYs1AnldCl/KHGZCOVvUNq
# jyL10JLe0/+GD9/ynqXGWFpXOjaunvZ/cKROhjN4M5e6xx0b2miqcPii4/ii2Zhe
# KallJET7CKlpFShs3wyg6F/fojQxQvPnbWD4Nyx6lhjWjwmoLcx6w1FSCtavLCly
# 33BLRSlTU4qKUxaa8d7YN7Eqpn9XO0SY0umOvKFXrWH7rxl+9iaicitdnTTksAnR
# jvekdKT3lg7lRMfmfZU8vXNiN0UYJzT9EjqjRm0uN/h0oXxPhNfPYqeFbyPXGGxz
# aYUz6zx3qTcCAwEAAaOCAcswggHHMB0GA1UdDgQWBBS+tjPyu6tZ/h5GsyLvyz1H
# +FNIWjAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAA4DqAXEsO26j/La7Fgn/Qifit8xuZekqZ57+Ye+sH/h
# RTbEEjGYrZgsqwR/lUUfKCFpbZF8msaZPQJOR4YYUEU8XyjLrn8Y1jCSmoxh9l7t
# WiSoc/JFBw356JAmzGGxeBA2EWSxRuTr1AuZe6nYaN8/wtFkiHcs8gMadxXBs6Dx
# Vhyu5YnhLPQkfumKm3lFftwE7pieV7f1lskmlgsC6AeSGCzGPZUgCvcH5Tv/Qe9z
# 7bIImSD3SuzhOIwaP+eKQTYf67TifyJKkWQSdGfTA6Kcu41k8LB6oPK+MLk1jbxx
# K5wPqLSL62xjK04SBXHEJSEnsFt0zxWkxP/lgej1DxqUnmrYEdkxvzKSHIAqFWSZ
# ul/5hI+vJxvFPhsNQBEk4cSulDkJQpcdVi/gmf/mHFOYhDBjsa15s4L+2sBil3XV
# /T8RiR66Q8xYvTLRWxd2dVsrOoCwnsU4WIeiC0JinCv1WLHEh7Qyzr9RSr4kKJLW
# dpNYLhgjkojTmEkAjFO774t3xB7enbvIF0GOsV19xnCUzq9EGKyt0gMuaphKlNjJ
# +aTpjWMZDGo+GOKsnp93Hmftml0Syp3F9+M3y+y6WJGUZoIZJq227jDjjEndtpUr
# h9BdPdVIfVJD/Au81Rzh05UHAivorQ3Os8PELHIgiOd9TWzbdgmGzcILt/ddVQER
# MYIHQzCCBz8CAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjANBglghkgBZQME
# AgEFAKCCBJwwEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDA5MDczNTI5WjAvBgkqhkiG9w0B
# CQQxIgQg/Avgj3muWGvthjYXlE07lgAgVwKzKn6GeYkHsF/Qe8YwgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCC2DDMlTaTj8JV3iTg5Xnpe4CSH60143Z+X9o5N
# BgMMqDB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjCCA14GCyqGSIb3DQEJ
# EAISMYIDTTCCA0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD/c/cpFSqQWYBeXggy
# RJ2ZbvYEEaBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2BVC8wIhgPMjAyNjA0
# MDgyMjI0NDdaGA8yMDI2MDQwOTIyMjQ0N1owdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7YFULwIBADAHAgEAAgIQdjAHAgEAAgIThjAKAgUA7YKlrwIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQAAXXuWOrEj9f1EAMMwOPSqgqIKBf984q6KsY3S
# 3esyXwfABYevIzhVynWRuxZQi/XqpVT6HltRtkT1B5o+RJzPhWJbE8K5Vegpvwvt
# 8nAjNLtaGpsOU/Y6aiQqgqSk8vigzgffAzz4Zzikb6G2uoxfKdlagtnES4Puz9pM
# yXU22DWX3SIcwkhg3i+rP+BsPU2oOeMA+ODcANGYG2jeBvlAM2251VzyeoQFnvSv
# zJRvKAdwp2Cym6eFNjR5NCgFat05de/ahV7uqBujaenye4KAmdEA6ZzzhmxF9H8K
# i8oBfWXFJJLILDyXfALnHfctBmO5jM81oIQFUizsFgUuKGAvMA0GCSqGSIb3DQEB
# AQUABIICAHO3Bv8vtcMS4ltsi+2crWM//P5/rImTqFPX414LXdyD8pI07rb5aGF9
# /4Hf5isKGkFM9R0z0Qg5ebGxJwI10qr7fKxRyUK9tE4/1amRVfPWjah3OywvRjPO
# KsQYzxchdp9eIeeKqAAgSINofV31Np8iVr9CjUAdyE+1fEXYhwDl0PCUcWhR5Ho/
# oh51slnkM5WzqogI2Q+egM8fFhlNEIquyLwTvFV6UVDO9VYUtE2dxcS8dyBsFK95
# aV5ECgYWM/903CmckhPqpN/SFxxoHVnxL6pojihr9LbaVgGvR+W+6rGZ1Pt3sMaS
# xxJsjJSdWek9JnpDpFOguDJY+NXw3XrpOIQXLSnVEJpk4+QIJYuUmuF0vwjjEVmk
# z8GusiwXq1LfTrAGcxn9FJjbOCTIgATJg8eeFxlz/bEDmaHJmV+YUGh+ZWVZrOR4
# PWLNv4JYLPFVuu3PoQnZlFoNG68wjhCMLJ8P/Q1wtvw/ZutW0BLSakLAiAszCOcF
# +sM8TCdat9X5vOxnId93TtETsRMPEpvuMBGGahUT4pokT8fovINw6x/CG5MQm+Ie
# b2Y9wCy0CbKfLZVyPmvocHgSM7SR8UATXMbl/ykqblE5DpQQwo1TdlqPDhzscvSn
# g6Mxahl87LK0U+dTGONwX8c6+9fEIqY45nU3XdeHh9ngdiOmmNtX
# SIG # End signature block

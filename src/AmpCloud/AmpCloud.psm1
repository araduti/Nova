#Requires -Version 5.1
<#
.SYNOPSIS
    Root module for AmpCloud.

.DESCRIPTION
    Dot-sources all public and private function files following the standard
    PowerShell module layout convention (Public/ and Private/ directories).
    Public functions are exported via the module manifest (AmpCloud.psd1).
#>

# ── Dot-source all function files ───────────────────────────────────────────
$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public  = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1"  -ErrorAction SilentlyContinue)

foreach ($file in @($Private + $Public)) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to import $($file.FullName): $_"
    }
}

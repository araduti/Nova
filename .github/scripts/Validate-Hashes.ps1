<#
.SYNOPSIS
    Validates that config/hashes.json matches the actual SHA256 hashes of tracked files.

.DESCRIPTION
    Computes SHA256 hashes for all tracked PowerShell files and compares them against
    config/hashes.json. Exits with code 1 if any mismatches, missing, or extra entries
    are found.

    This script is used as a CI gate to ensure hashes.json is always in sync.

    Tracked paths:
      - src/scripts/*.ps1
      - resources/autopilot/*.ps1
      - src/modules/**/*.psm1
      - src/modules/**/*.psd1

.PARAMETER RepoRoot
    Root of the repository. Defaults to the current working directory.
#>
param(
    [string]$RepoRoot = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dynamically discover all tracked files
$trackedFiles = @(
    (Get-ChildItem -Path (Join-Path $RepoRoot 'src/scripts')        -Filter '*.ps1'  -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    (Get-ChildItem -Path (Join-Path $RepoRoot 'resources/autopilot') -Filter '*.ps1'  -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    (Get-ChildItem -Path (Join-Path $RepoRoot 'src/modules')        -Include '*.psm1','*.psd1' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
)

$repoRootNormalized = ($RepoRoot -replace '\\', '/').TrimEnd('/') + '/'

# Compute actual hashes
$computed = [ordered]@{}
foreach ($fullPath in ($trackedFiles | Sort-Object)) {
    $relative = ($fullPath -replace '\\', '/').Replace($repoRootNormalized, '')
    $hash = (Get-FileHash -Path $fullPath -Algorithm SHA256).Hash
    $computed[$relative] = $hash
}

# Load existing hashes.json
$hashesPath = Join-Path $RepoRoot 'config/hashes.json'
if (-not (Test-Path $hashesPath)) {
    Write-Error "config/hashes.json not found at: $hashesPath"
    exit 1
}

$manifest = Get-Content $hashesPath -Raw | ConvertFrom-Json
$existing = @{}
foreach ($prop in $manifest.files.PSObject.Properties) {
    $existing[$prop.Name] = $prop.Value
}

# Compare
$mismatches = @()
$missing = @()
$extra = @()

foreach ($key in $computed.Keys) {
    if (-not $existing.Contains($key)) {
        $missing += $key
    } elseif ($existing[$key] -ne $computed[$key]) {
        $mismatches += @{
            File     = $key
            Expected = $computed[$key]
            Actual   = $existing[$key]
        }
    }
}

foreach ($key in $existing.Keys) {
    if (-not $computed.Contains($key)) {
        $extra += $key
    }
}

# Report results
$hasErrors = $false

if ($mismatches.Count -gt 0) {
    $hasErrors = $true
    Write-Host "`nHash mismatches ($($mismatches.Count)):" -ForegroundColor Red
    foreach ($m in $mismatches) {
        Write-Host "  $($m.File)" -ForegroundColor Red
        Write-Host "    computed: $($m.Expected)"
        Write-Host "    manifest: $($m.Actual)"
    }
}

if ($missing.Count -gt 0) {
    $hasErrors = $true
    Write-Host "`nFiles missing from hashes.json ($($missing.Count)):" -ForegroundColor Red
    foreach ($f in $missing) {
        Write-Host "  $f" -ForegroundColor Red
    }
}

if ($extra.Count -gt 0) {
    $hasErrors = $true
    Write-Host "`nExtra entries in hashes.json ($($extra.Count)):" -ForegroundColor Red
    foreach ($f in $extra) {
        Write-Host "  $f" -ForegroundColor Red
    }
}

if ($hasErrors) {
    Write-Host "`nconfig/hashes.json is out of sync with tracked files." -ForegroundColor Red
    Write-Host "Run '.github/scripts/Regenerate-Hashes.ps1' locally and commit the updated hashes.json." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "`nAll $($computed.Count) file hashes match config/hashes.json." -ForegroundColor Green
}

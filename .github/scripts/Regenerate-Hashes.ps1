<#
.SYNOPSIS
    Regenerates config/hashes.json by computing SHA256 hashes of all tracked files.

.DESCRIPTION
    Discovers all tracked PowerShell files (.ps1, .psm1, .psd1) and updates the
    hash manifest. Used by CI/CD workflows for integrity verification.

    Tracked paths:
      - src/scripts/*.ps1
      - resources/autopilot/*.ps1
      - src/modules/**/*.psm1
      - src/modules/**/*.psd1

.PARAMETER RepoRoot
    Root of the repository. Defaults to the current working directory.

.PARAMETER Force
    Always write hashes.json even if no changes are detected.
    Use after code signing since file contents will have changed.
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compute SHA256 of file content after normalizing CRLF to LF.
# This ensures hashes match what git stores (LF-normalized via .gitattributes)
# and what raw.githubusercontent.com serves, regardless of the OS line endings.
function Get-LFNormalizedFileHash {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $stream = [System.IO.MemoryStream]::new()
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0D -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 0x0A) {
            continue  # skip CR before LF
        }
        $stream.WriteByte($bytes[$i])
    }
    $stream.Position = 0
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($stream)
    $stream.Dispose()
    $sha256.Dispose()
    return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToUpper()
}

# Dynamically discover all tracked files
$trackedFiles = @(
    (Get-ChildItem -Path (Join-Path $RepoRoot 'src/scripts')        -Filter '*.ps1'  -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    (Get-ChildItem -Path (Join-Path $RepoRoot 'resources/autopilot') -Filter '*.ps1'  -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    (Get-ChildItem -Path (Join-Path $RepoRoot 'src/modules')        -Include '*.psm1','*.psd1' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
)

# Normalize to forward slashes so the prefix strip works on Windows and Linux
$repoRootNormalized = ($RepoRoot -replace '\\', '/').TrimEnd('/') + '/'
$newFiles = [ordered]@{}
foreach ($fullPath in ($trackedFiles | Sort-Object)) {
    $relative = ($fullPath -replace '\\', '/').Replace($repoRootNormalized, '')
    $hash = Get-LFNormalizedFileHash -Path $fullPath
    $newFiles[$relative] = $hash
    Write-Host "Hashed: $relative"
}

$hashesPath = Join-Path $RepoRoot 'config/hashes.json'
$manifest = Get-Content $hashesPath -Raw | ConvertFrom-Json

if (-not $Force) {
    # Compare existing hashes to detect changes
    $oldFiles = @{}
    foreach ($prop in $manifest.files.PSObject.Properties) { $oldFiles[$prop.Name] = $prop.Value }
    $changed = $false
    if ($oldFiles.Count -ne $newFiles.Count) { $changed = $true }
    if (-not $changed) {
        foreach ($key in $newFiles.Keys) {
            if (-not $oldFiles.ContainsKey($key) -or $oldFiles[$key] -ne $newFiles[$key]) {
                $changed = $true
                break
            }
        }
    }
    if (-not $changed) {
        Write-Host "`nAll hashes already up to date."
        return
    }
}

$manifest.files = [PSCustomObject]$newFiles
$manifest.generated = (Get-Date -Format 'yyyy-MM-dd')
$manifest | ConvertTo-Json -Depth 5 | Set-Content $hashesPath -NoNewline -Encoding utf8NoBOM
Write-Host "`nHashes updated in config/hashes.json."

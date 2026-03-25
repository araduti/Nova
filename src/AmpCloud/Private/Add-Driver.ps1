function Add-Driver {
    param(
        [string]$DriverPath,
        [string]$OSDriveLetter
    )

    if (-not $DriverPath -or -not (Test-Path $DriverPath)) {
        Write-Warn "Driver path not specified or not found: '$DriverPath'. Skipping driver injection."
        return
    }

    Write-Step "Injecting drivers from: $DriverPath"

    $stepName = ''
    try {
        $stepName = 'Enumerate driver .inf files'
        $infFiles = Get-ChildItem $DriverPath -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
        if (-not $infFiles) {
            Write-Warn 'No .inf files found in driver path. Skipping.'
            return
        }

        Write-Host "  Found $($infFiles.Count) driver(s)."

        $stepName = 'Add-WindowsDriver'
        $null = Add-WindowsDriver `
            -Path        "${OSDriveLetter}:\" `
            -Driver      $DriverPath `
            -Recurse `
            -ErrorAction Continue

        Write-Success "Drivers injected from: $DriverPath"
    } catch {
        throw "Add-Driver failed at step '$stepName': $_"
    }
}

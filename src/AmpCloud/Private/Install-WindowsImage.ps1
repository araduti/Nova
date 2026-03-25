function Install-WindowsImage {
    param(
        [string]$ImagePath,
        [string]$Edition,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    Write-Step "Applying Windows image to ${OSDriveLetter}:..."

    $stepName = ''
    try {
        # Get the correct image index for the requested edition
        $stepName = 'Get-WindowsImage (enumerate editions)'
        $images = Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop
        Write-Host "  Available editions in image:"
        $images | ForEach-Object { Write-Host "    [$($_.ImageIndex)] $($_.ImageName)" }

        $stepName = 'Find target edition'
        $targetImage = $images | Where-Object { $_.ImageName -like "*$Edition*" } | Select-Object -First 1

        # The catalog uses short IDs (e.g. 'Professional') while WIM ImageName
        # uses friendly names (e.g. 'Windows 11 Pro').  Try the mapped name.
        if (-not $targetImage -and $script:EditionNameMap.ContainsKey($Edition)) {
            $mappedName = $script:EditionNameMap[$Edition]
            $targetImage = $images | Where-Object { $_.ImageName -like "*$mappedName*" } | Select-Object -First 1
        }

        if (-not $targetImage) {
            Write-Warn "Edition '$Edition' not found. Using index 1."
            $targetImage = $images | Select-Object -First 1
        }

        $stepName = 'Expand-WindowsImage (apply)'
        Write-Step "Applying image index $($targetImage.ImageIndex): $($targetImage.ImageName)"
        $scratch = Join-Path $ScratchDir 'scratch'
        New-ScratchDirectory -Path $scratch

        $null = Expand-WindowsImage `
            -ImagePath       $ImagePath `
            -Index           $targetImage.ImageIndex `
            -ApplyPath       "${OSDriveLetter}:\" `
            -ScratchDirectory $scratch `
            -ErrorAction Stop

        Write-Success 'Windows image applied successfully.'
    } catch {
        throw "Install-WindowsImage failed at step '$stepName': $_"
    }
}

function Get-WindowsImageSource {
    param(
        [string]$ImageUrl,
        [string]$Edition,
        [string]$Language,
        [string]$Architecture = 'x64',
        [string]$FirmwareType,
        [string]$ScratchDir
    )

    New-ScratchDirectory -Path $ScratchDir

    if ($ImageUrl) {
        # User-supplied image URL
        $ext = [System.IO.Path]::GetExtension($ImageUrl).ToLower()
        $imagePath = Join-Path $ScratchDir "windows$ext"
        Invoke-DownloadWithProgress -Uri $ImageUrl -OutFile $imagePath -Description 'Downloading Windows image'
        return $imagePath
    }

    # Read the ESD catalog directly from the repository.
    $stepName = ''
    try {
        $stepName = 'Download ESD catalog'
        Write-Step 'Reading Windows ESD catalog from repository...'
        $productsUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/products.xml"
        $productsPath = Join-Path $ScratchDir 'products.xml'
        Invoke-DownloadWithProgress -Uri $productsUrl -OutFile $productsPath -Description 'Fetching Windows ESD catalog'

        $stepName = 'Parse ESD catalog'
        [xml]$catalog = Get-Content $productsPath -Encoding UTF8

        $stepName = 'Find matching ESD'
        $esd     = Find-WindowsESD -Catalog $catalog -Edition $Edition -Language $Language -Architecture $Architecture -FirmwareType $FirmwareType

        Write-Host "  Found ESD: $($esd.FileName) ($([long]$esd.Size | ForEach-Object { Get-FileSizeReadable $_ }))"

        $stepName = 'Download ESD'
        $esdPath = Join-Path $ScratchDir $esd.FileName
        Invoke-DownloadWithProgress -Uri $esd.FilePath -OutFile $esdPath -Description "Downloading Windows ESD: $Edition"

        return $esdPath
    } catch {
        throw "Get-WindowsImageSource failed at step '$stepName': $_"
    }
}

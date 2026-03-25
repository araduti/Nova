function Find-WindowsESD {
    param(
        [xml]$Catalog,
        [string]$Edition,
        [string]$Language,
        [string]$Architecture = 'x64',
        [ValidateSet('UEFI','BIOS')]
        [string]$FirmwareType
    )

    $arch = $Architecture
    $allFiles = $Catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File
    $matchedEsd = $allFiles |
        Where-Object {
            $_.LanguageCode -eq $Language -and
            $_.Architecture -eq $arch -and
            $_.Edition      -like "*$($Edition.Replace(' ','*'))*"
        } |
        Sort-Object -Property @{Expression={ [long]$_.Size }; Descending = $true} |
        Select-Object -First 1

    if (-not $matchedEsd) {
        # Dump available entries to aid troubleshooting.
        $available = $allFiles |
            Where-Object { $_.LanguageCode -eq $Language -and $_.Architecture -eq $arch } |
            Select-Object -ExpandProperty Edition -ErrorAction SilentlyContinue |
            Sort-Object -Unique
        if ($available) {
            Write-Warn "Available editions in catalog for Language='$Language', Arch='$arch':"
            $available | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Warn "No entries found for Language='$Language', Arch='$arch'. Available architectures:"
            $allFiles | Select-Object -ExpandProperty Architecture -ErrorAction SilentlyContinue |
                Sort-Object -Unique | ForEach-Object { Write-Host "    $_" }
        }
        throw "No ESD found in catalog for: Edition='$Edition', Language='$Language', Arch='$arch'"
    }

    return $matchedEsd
}

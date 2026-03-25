function Initialize-NuGetProvider {
    <#
    .SYNOPSIS
        Ensures NuGet is available and PSGallery is trusted so Install-Module
        works correctly, including inside WinPE.
    #>
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Host '  Bootstrapping NuGet package provider...'
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop
    }
    $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $gallery -or $gallery.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
}

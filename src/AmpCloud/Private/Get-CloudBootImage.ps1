function Get-CloudBootImage {
    <#
    .SYNOPSIS  Checks GitHub Releases for a pre-built boot image.
    .DESCRIPTION
        Queries the GitHub Releases API for a release tagged 'boot-image'.
        If found and it contains a boot.wim asset, returns a hashtable with
        download URLs and metadata.  Returns $null when no cloud image is
        available.
    .OUTPUTS   [hashtable] with BootWimUrl, BootSdiUrl, BootWimSize, PublishedAt — or $null.
    #>
    param(
        [string] $GitHubUser,
        [string] $GitHubRepo,
        [string] $Tag = 'boot-image'
    )

    $releaseUrl = "https://api.github.com/repos/$GitHubUser/$GitHubRepo/releases/tags/$Tag"
    try {
        $release = Invoke-RestMethod -Uri $releaseUrl -ErrorAction Stop
    } catch {
        return $null
    }

    $wimAsset = $release.assets | Where-Object { $_.name -eq 'boot.wim' }
    if (-not $wimAsset) { return $null }

    $sdiAsset = $release.assets | Where-Object { $_.name -eq 'boot.sdi' }

    return @{
        BootWimUrl  = $wimAsset.browser_download_url
        BootSdiUrl  = if ($sdiAsset) { $sdiAsset.browser_download_url } else { $null }
        BootWimSize = $wimAsset.size
        PublishedAt = $release.published_at
    }
}

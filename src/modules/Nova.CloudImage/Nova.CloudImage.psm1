<#
.SYNOPSIS
    Cloud boot image management module for Nova.
.DESCRIPTION
    Provides functions for checking GitHub Releases for pre-built WinPE
    boot images and uploading new boot images to GitHub Releases.
#>
function Get-CloudBootImage {
    <#
    .SYNOPSIS  Checks GitHub Releases for a pre-built boot image.
    .DESCRIPTION
        Queries the GitHub Releases API for a release tagged 'boot-image'.
        If found and it contains a boot.wim asset, returns a hashtable with
        download URLs and metadata.  Returns $null when no cloud image is
        available.
    .OUTPUTS   [hashtable] with BootWimUrl, BootSdiUrl, BootWimSize, PublishedAt -- or $null.
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
function Publish-BootImage {
    <#
    .SYNOPSIS  Uploads the boot image to a GitHub Release.
    .DESCRIPTION
        Creates (or updates) a GitHub Release tagged 'boot-image' and uploads
        boot.wim and boot.sdi as release assets.  Requires a Personal Access
        Token (PAT) with 'repo' scope.
    #>
    param(
        [string] $GitHubUser,
        [string] $GitHubRepo,
        [string] $GitHubToken,
        [string] $BootWimPath,
        [string] $BootSdiPath,
        [string] $Tag = 'boot-image'
    )
    $headers = @{
        Authorization = "token $GitHubToken"
        Accept        = 'application/vnd.github+json'
    }
    # Check for existing release
    $releaseUrl = "https://api.github.com/repos/$GitHubUser/$GitHubRepo/releases/tags/$Tag"
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers -ErrorAction Stop
    } catch {
        Write-Verbose "No existing release for tag '$Tag' -- will create a new one."
    }
    if ($release) {
        # Delete existing assets so they can be replaced
        foreach ($asset in $release.assets) {
            $deleteUrl = "https://api.github.com/repos/$GitHubUser/$GitHubRepo/releases/assets/$($asset.id)"
            try {
                $null = Invoke-RestMethod -Uri $deleteUrl -Method Delete -Headers $headers -ErrorAction Stop
            } catch {
                Write-Warn "Could not delete existing asset '$($asset.name)': $_"
            }
        }
    } else {
        # Create a new release
        $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
        $body = @{
            tag_name   = $Tag
            name       = 'Nova Boot Image'
            body       = "Pre-built WinPE boot image for Nova deployment.`nGenerated: $timestamp UTC"
            draft      = $false
            prerelease = $false
        } | ConvertTo-Json
        $createUrl = "https://api.github.com/repos/$GitHubUser/$GitHubRepo/releases"
        $release   = Invoke-RestMethod -Uri $createUrl -Method Post -Headers $headers `
                                       -Body $body -ContentType 'application/json' -ErrorAction Stop
        Write-Success "GitHub Release '$Tag' created."
    }
    # Upload assets using streaming HttpWebRequest -- avoids the massive
    # overhead of Invoke-WebRequest's built-in progress bar on large files.
    $uploadUrlBase = $release.upload_url -replace '\{[^}]*\}', ''
    $bufferSize    = 4 * 1MB          # 4 MB upload chunks
    $progressMs    = 1000             # minimum ms between progress updates
    $connectTimeMs = [int]([TimeSpan]::FromHours(2).TotalMilliseconds)    # generous for slow links
    $ioTimeMs      = [int]([TimeSpan]::FromMinutes(10).TotalMilliseconds) # per read/write op
    foreach ($file in @(
        @{ Path = $BootWimPath; Name = 'boot.wim' },
        @{ Path = $BootSdiPath; Name = 'boot.sdi' }
    )) {
        if (-not $file.Path -or -not (Test-Path $file.Path)) {
            Write-Warn "File not found, skipping upload: $($file.Name)"
            continue
        }
        $uploadUrl  = "${uploadUrlBase}?name=$($file.Name)"
        $fileLength = (Get-Item $file.Path).Length
        $fileSizeMB = $fileLength / 1MB
        Write-Step "Uploading $($file.Name) ($('{0:N0}' -f $fileSizeMB) MB)..."
        $fs        = $null
        $reqStream = $null
        $response  = $null
        try {
            $wr             = [System.Net.HttpWebRequest]::Create($uploadUrl)
            $wr.Method      = 'POST'
            $wr.ContentType = 'application/octet-stream'
            $wr.Headers['Authorization'] = "token $GitHubToken"
            $wr.ContentLength = $fileLength
            $wr.AllowWriteStreamBuffering = $false   # stream directly, no RAM copy
            $wr.SendChunked   = $false
            $wr.Timeout       = $connectTimeMs
            $wr.ReadWriteTimeout = $ioTimeMs
            $reqStream = $wr.GetRequestStream()
            $fs        = [System.IO.FileStream]::new(
                             $file.Path,
                             [System.IO.FileMode]::Open,
                             [System.IO.FileAccess]::Read,
                             [System.IO.FileShare]::Read,
                             $bufferSize)
            $buffer   = New-Object byte[] $bufferSize
            $uploaded = [long]0
            $sw       = [System.Diagnostics.Stopwatch]::StartNew()
            do {
                $read = $fs.Read($buffer, 0, $buffer.Length)
                if ($read -gt 0) {
                    $reqStream.Write($buffer, 0, $read)
                    $uploaded += $read
                    if ($sw.ElapsedMilliseconds -gt $progressMs) {
                        $pct   = [int]($uploaded * 100 / $fileLength)
                        $speed = if ($sw.Elapsed.TotalSeconds -gt 0) {
                                     '{0:N1} MB/s' -f ($uploaded / 1MB / $sw.Elapsed.TotalSeconds)
                                 } else { '--' }
                        Write-Host ("  Progress: {0}% ({1:N0} / {2:N0} MB) @ {3}" -f
                            $pct, ($uploaded / 1MB), $fileSizeMB, $speed) -NoNewline
                        Write-Host "`r" -NoNewline
                    }
                }
            } while ($read -gt 0)
            Write-Host ''
            $response = $wr.GetResponse()
            Write-Success "$($file.Name) uploaded."
        } catch {
            throw "Upload failed for '$($file.Name)' to ${uploadUrl}: $_"
        } finally {
            if ($fs)        { $fs.Close() }
            if ($reqStream) { $reqStream.Close() }
            if ($response)  { $response.Close() }
        }
    }
}
Export-ModuleMember -Function @(
    'Get-CloudBootImage'
    'Publish-BootImage'
)
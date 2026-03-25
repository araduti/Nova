function Invoke-DownloadWithProgress {
    param(
        [string]$Uri,
        [string]$OutFile,
        [string]$Description = 'Downloading'
    )
    Write-Step "$Description"
    Write-Host "  Source : $Uri"
    Write-Host "  Target : $OutFile"

    $response  = $null
    $stream    = $null
    $fs        = $null
    try {
        $wr = [System.Net.WebRequest]::Create($Uri)
        $wr.Method = 'GET'
        $response  = $wr.GetResponse()
        $totalBytes = $response.ContentLength
        $stream     = $response.GetResponseStream()
        $fs         = [System.IO.File]::Create($OutFile)
        $buffer     = New-Object byte[] $script:DownloadBufferSize
        $downloaded = 0
        $sw         = [System.Diagnostics.Stopwatch]::StartNew()

        do {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $fs.Write($buffer, 0, $read)
                $downloaded += $read
                if ($sw.ElapsedMilliseconds -gt $script:ProgressIntervalMs) {
                    $pct = if ($totalBytes -gt 0) { [int]($downloaded * 100 / $totalBytes) } else { 0 }
                    $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { [long]($downloaded / $sw.Elapsed.TotalSeconds) } else { 0 }
                    Write-Host "  Progress: $pct% ($(Get-FileSizeReadable $downloaded) / $(Get-FileSizeReadable $totalBytes)) @ $(Get-FileSizeReadable $speed)/s" -NoNewline
                    Write-Host "`r" -NoNewline
                }
            }
        } while ($read -gt 0)

        Write-Host ''
        Write-Success "Download complete: $(Get-FileSizeReadable $downloaded)"
    } catch {
        throw "Download failed for '$Description' (URL: $Uri): $_"
    } finally {
        if ($fs)       { $fs.Close() }
        if ($stream)   { $stream.Close() }
        if ($response) { $response.Close() }
    }
}

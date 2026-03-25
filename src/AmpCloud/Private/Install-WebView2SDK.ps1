function Install-WebView2SDK {
    <#
    .SYNOPSIS  Download the WebView2 SDK NuGet package (cached).
    .DESCRIPTION
        Downloads the Microsoft.Web.WebView2 NuGet package to a temporary
        directory and extracts the managed DLLs needed for PowerShell.
        A cached copy is reused on subsequent calls.
    .OUTPUTS
        Path to the directory containing the WebView2 DLLs, or $null on failure.
    #>
    $sdkDir  = Join-Path $env:TEMP 'AmpCloud-WebView2SDK'
    $coreDll = Join-Path $sdkDir 'Microsoft.Web.WebView2.Core.dll'

    # Reuse cached copy.
    if (Test-Path $coreDll) { return $sdkDir }

    $null = New-Item -Path $sdkDir -ItemType Directory -Force

    # Download the NuGet package (latest stable).
    $zipPath = Join-Path $sdkDir 'Microsoft.Web.WebView2.nupkg'
    try {
        $prevPref = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try     { Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile $zipPath -UseBasicParsing }
        finally { $ProgressPreference = $prevPref }
    } catch {
        Write-Verbose "WebView2 NuGet download failed: $_"
        return $null
    }

    # Extract the required DLLs from the package.
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $arch = if ([System.IntPtr]::Size -eq 8) { 'win-x64' } else { 'win-x86' }
        $zip  = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $zip.Entries) {
                $extract = $false
                if ($entry.FullName -like 'lib/net45/*.dll') { $extract = $true }
                if ($entry.FullName -eq "runtimes/$arch/native/WebView2Loader.dll") { $extract = $true }
                if ($extract -and $entry.Name) {
                    $dest = Join-Path $sdkDir $entry.Name
                    $s = $entry.Open()
                    try {
                        $fs = [System.IO.File]::Create($dest)
                        try   { $s.CopyTo($fs) }
                        finally { $fs.Close() }
                    } finally { $s.Close() }
                }
            }
        } finally { $zip.Dispose() }
    } catch {
        Write-Verbose "WebView2 NuGet extraction failed: $_"
        return $null
    }

    if (Test-Path $coreDll) { return $sdkDir }
    return $null
}

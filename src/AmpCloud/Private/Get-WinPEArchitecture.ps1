function Get-WinPEArchitecture {
    <#
    .SYNOPSIS
        Maps the current OS CPU architecture to the WinPE folder/package name
        used by the ADK. AmpCloud supports amd64 and x86 only — ARM is not
        supported because AmpCloud is a cloud-only deployment engine targeting
        x86-64 enterprise hardware.
    #>
    $map = @{
        'AMD64' = 'amd64'
        'x86'   = 'x86'
    }
    $proc = $env:PROCESSOR_ARCHITECTURE   # AMD64 | x86
    $arch = $map[$proc]
    if (-not $arch) {
        throw "Unsupported processor architecture '$proc'. AmpCloud supports amd64 and x86 only. ARM is not supported."
    }
    return $arch
}

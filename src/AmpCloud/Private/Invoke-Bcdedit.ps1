function Invoke-Bcdedit {
    <#
    .SYNOPSIS  Thin wrapper around bcdedit.exe with strict error checking.
    #>
    param([string[]] $Arguments)
    $output = & bcdedit.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit $($Arguments -join ' ') → exit $LASTEXITCODE`n$output"
    }
    return $output
}

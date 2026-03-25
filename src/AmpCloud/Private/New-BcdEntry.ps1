function New-BcdEntry {
    <#
    .SYNOPSIS  Creates a BCD entry and returns its GUID string, e.g. {abc123…}.
    #>
    param([string[]] $CreateArgs)
    $output = Invoke-Bcdedit $CreateArgs
    if ($output -match '\{([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\}') {
        return "{$($Matches[1])}"
    }
    throw "Could not parse GUID from bcdedit output: $output"
}

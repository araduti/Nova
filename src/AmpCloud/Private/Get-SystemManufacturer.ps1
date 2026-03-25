function Get-SystemManufacturer {
    <#
    .SYNOPSIS
        Returns the trimmed manufacturer string from Win32_ComputerSystem.
    #>
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) { return $cs.Manufacturer.Trim() }
    return ''
}

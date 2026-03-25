function Invoke-OemDriverInjection {
    <#
    .SYNOPSIS
        Detects the system manufacturer and calls the appropriate OEM driver
        injection function (Dell, HP, or Lenovo).
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'OEM driver injection: detecting manufacturer...'

    $stepName = ''
    try {
        $stepName = 'Detect manufacturer'
        $manufacturer = Get-SystemManufacturer
        Write-Host "  Manufacturer: '$manufacturer'"

        $stepName = "Inject drivers for '$manufacturer'"
        switch -Wildcard ($manufacturer) {
            '*Dell*'    { Add-DellDriver    -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*HP*'      { Add-HpDriver      -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*Hewlett*' { Add-HpDriver      -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*Lenovo*'  { Add-LenovoDriver  -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            default {
                Write-Warn "Manufacturer '$manufacturer' is not supported for OEM driver automation. Use -DriverPath for manual driver injection."
            }
        }
    } catch {
        throw "Invoke-OemDriverInjection failed at step '$stepName': $_"
    }
}

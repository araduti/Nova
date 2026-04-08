@{
    RootModule        = 'Nova.Drivers.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1001-4000-8000-000000000010'
    Author            = 'Nova Contributors'
    Description       = 'OEM driver injection functions for Nova deployment engine.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Add-Driver'
        'Initialize-NuGetProvider'
        'Install-OemModule'
        'Get-SystemManufacturer'
        'Add-DellDriver'
        'Add-HpDriver'
        'Add-LenovoDriver'
        'Add-SurfaceDriver'
        'Invoke-OemDriverInjection'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}
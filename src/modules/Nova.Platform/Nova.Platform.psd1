@{
    RootModule        = 'Nova.Platform.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1002-4000-8000-000000000002'
    Author            = 'Nova Contributors'
    Description       = 'Platform detection and file utility functions for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-FirmwareType'
        'Get-WinPEArchitecture'
        'Get-FileSizeReadable'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

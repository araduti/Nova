@{
    RootModule        = 'Nova.BCD.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1001-4000-8000-000000000016'
    Author            = 'Nova Contributors'
    Description       = 'BCD (Boot Configuration Data) management functions for Nova.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Invoke-Bcdedit'
        'New-BcdEntry'
        'New-BCDRamdiskEntry'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}
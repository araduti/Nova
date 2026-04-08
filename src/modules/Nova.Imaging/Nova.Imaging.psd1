@{
    RootModule        = 'Nova.Imaging.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1001-4000-8000-000000000015'
    Author            = 'Nova Contributors'
    Description       = 'Windows image download, application, and bootloader configuration for Nova.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Find-WindowsESD'
        'Get-WindowsImageSource'
        'Install-WindowsImage'
        'Set-Bootloader'
        'Get-EditionNameMap'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

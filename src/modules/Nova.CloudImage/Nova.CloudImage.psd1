@{
    RootModule        = 'Nova.CloudImage.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1001-4000-8000-000000000017'
    Author            = 'Nova Contributors'
    Description       = 'Cloud boot image management via GitHub Releases for Nova.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-CloudBootImage'
        'Publish-BootImage'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}
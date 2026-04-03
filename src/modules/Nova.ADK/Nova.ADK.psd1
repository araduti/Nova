@{
    RootModule        = 'Nova.ADK.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1004-4000-8000-000000000004'
    Author            = 'Nova Contributors'
    Description       = 'Windows ADK detection, installation, and WinPE workspace setup for Nova.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @(
        'Get-ADKRoot'
        'Assert-ADKInstalled'
        'Copy-WinPEFile'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

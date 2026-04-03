@{
    RootModule        = 'Nova.Integrity.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1005-4000-8000-000000000005'
    Author            = 'Nova Contributors'
    Description       = 'File integrity verification (SHA256) for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @(
        'Confirm-FileIntegrity'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

@{
    RootModule        = 'Nova.WinRE.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1003-4000-8000-000000000003'
    Author            = 'Nova Contributors'
    Description       = 'WinRE discovery, extraction, and preparation for Nova boot image building.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @(
        'Get-WinREPath'
        'Get-WinREPathFromWindowsISO'
        'Remove-WinRERecoveryPackage'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

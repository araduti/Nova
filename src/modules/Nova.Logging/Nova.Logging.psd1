@{
    RootModule        = 'Nova.Logging.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1001-4000-8000-000000000001'
    Author            = 'Nova Contributors'
    Description       = 'Colour-coded console logging functions for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Set-NovaLogPrefix'
        'Write-Step'
        'Write-Success'
        'Write-Warn'
        'Write-Fail'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

@{
    RootModule        = 'Nova.Proxy.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1009-4000-8000-000000000009'
    Author            = 'Nova Contributors'
    Description       = 'Corporate proxy configuration for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Set-NovaProxy'
        'Get-NovaProxy'
        'Clear-NovaProxy'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

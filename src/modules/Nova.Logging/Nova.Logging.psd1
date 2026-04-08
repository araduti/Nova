@{
    RootModule        = 'Nova.Logging.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '19027ff3-98ac-405d-b482-70593fbc416d'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Colour-coded console logging functions for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
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
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Logging', 'Console', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

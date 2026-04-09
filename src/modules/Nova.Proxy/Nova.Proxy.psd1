@{
    RootModule        = 'Nova.Proxy.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '48b3a0bb-93df-423f-8a2f-e29c4bf2ab2f'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Corporate proxy configuration for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @('Set-NovaProxy', 'Get-NovaProxy', 'Clear-NovaProxy')
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Proxy', 'Network', 'Corporate', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

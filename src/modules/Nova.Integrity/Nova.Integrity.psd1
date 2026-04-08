@{
    RootModule        = 'Nova.Integrity.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '22a5ffaa-bfe8-476a-8d42-4afc5fed3339'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'File integrity verification (SHA256) for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @('Confirm-FileIntegrity')
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Integrity', 'SHA256', 'Hash', 'Security', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

@{
    RootModule        = 'Nova.ADK.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'dc9ddc96-f088-4b1b-b0e6-4f68e3a5b977'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Windows ADK detection, installation, and WinPE workspace setup for Nova.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @('Get-ADKRoot', 'Assert-ADKInstalled', 'Copy-WinPEFile')
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'ADK', 'WinPE', 'Deployment', 'Windows')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

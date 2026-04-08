@{
    RootModule        = 'Nova.CloudImage.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '879e9020-65f2-46b8-af32-d6ce1746557f'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Cloud boot image management via GitHub Releases for Nova.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @('Get-CloudBootImage', 'Publish-BootImage')
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'CloudImage', 'GitHub', 'WinPE', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

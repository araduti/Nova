@{
    RootModule        = 'Nova.Imaging.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'cd0a25aa-63fb-46d2-ab01-a2aad269badc'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Windows image download, application, and bootloader configuration for Nova.'
    PowerShellVersion = '5.1'
    RequiredModules   = @(
        'Nova.Logging'
        'Nova.Platform'
    )
    FunctionsToExport = @(
        'Find-WindowsESD'
        'Get-WindowsImageSource'
        'Install-WindowsImage'
        'Set-Bootloader'
        'Get-EditionNameMap'
        'Find-CachedImage'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Imaging', 'WIM', 'ESD', 'WindowsImage', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

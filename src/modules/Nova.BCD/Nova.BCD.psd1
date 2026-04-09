@{
    RootModule        = 'Nova.BCD.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '019db21b-a157-4d79-8be6-5a4b887f0622'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'BCD (Boot Configuration Data) management functions for Nova.'
    PowerShellVersion = '5.1'
    RequiredModules   = @(
        'Nova.Logging'
        'Nova.Platform'
    )
    FunctionsToExport = @('Invoke-Bcdedit', 'New-BcdEntry', 'New-BCDRamdiskEntry')
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'BCD', 'Boot', 'WinPE', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

@{
    RootModule        = 'Nova.Platform.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'e115e2dc-7ad0-457d-b39d-f3e75a0a886a'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Platform detection and file utility functions for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @('Get-FirmwareType', 'Get-WinPEArchitecture', 'Get-FileSizeReadable')
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Platform', 'Firmware', 'UEFI', 'BIOS', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

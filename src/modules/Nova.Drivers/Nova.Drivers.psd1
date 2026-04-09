@{
    RootModule        = 'Nova.Drivers.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '14b5f97e-b3e5-45c2-bf76-8e88431826da'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'OEM driver injection functions for Nova deployment engine.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @(
        'Add-Driver'
        'Initialize-NuGetProvider'
        'Install-OemModule'
        'Get-SystemManufacturer'
        'Add-DellDriver'
        'Add-HpDriver'
        'Add-LenovoDriver'
        'Add-SurfaceDriver'
        'Invoke-OemDriverInjection'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Drivers', 'OEM', 'Dell', 'HP', 'Lenovo', 'Surface', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

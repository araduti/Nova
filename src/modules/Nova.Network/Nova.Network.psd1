@{
    RootModule        = 'Nova.Network.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '48094b7e-7d40-4efb-ba16-2efadbd20df8'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Network utility functions for Nova WinPE bootstrap (TCP tuning, WiFi, connectivity probing).'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @(
        'Invoke-NetworkTuning'
        'Test-HasValidIP'
        'Test-InternetConnectivity'
        'Start-WlanService'
        'Get-WiFiNetwork'
        'Get-SignalBar'
        'Connect-WiFiNetwork'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Network', 'WiFi', 'WinPE', 'TCP', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

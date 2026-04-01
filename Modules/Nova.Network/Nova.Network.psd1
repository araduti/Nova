@{
    RootModule        = 'Nova.Network.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1003-4000-8000-000000000003'
    Author            = 'Nova Contributors'
    Description       = 'Network utility functions for Nova WinPE bootstrap (TCP tuning, WiFi, connectivity probing).'
    PowerShellVersion = '5.1'
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
}

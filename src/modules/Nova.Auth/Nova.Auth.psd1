@{
    RootModule        = 'Nova.Auth.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '78eb49b1-7735-4399-a39c-5495deca93c5'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Microsoft 365 / Azure AD OAuth2 authentication for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @(
        'Install-WebView2SDK'
        'Show-WebView2AuthPopup'
        'Invoke-M365DeviceCodeAuth'
        'Update-M365Token'
        'Invoke-KioskEdgeAuth'
        'Invoke-KioskDeviceCodeAuth'
        'Invoke-KioskM365Auth'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Auth', 'OAuth2', 'AzureAD', 'M365', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

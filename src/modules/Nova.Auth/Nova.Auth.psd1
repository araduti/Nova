@{
    RootModule        = 'Nova.Auth.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1007-4000-8000-000000000007'
    Author            = 'Nova Contributors'
    Description       = 'Microsoft 365 / Azure AD OAuth2 authentication for Nova deployment scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @(
        'Install-WebView2SDK'
        'Show-WebView2AuthPopup'
        'Invoke-M365DeviceCodeAuth'
        'Update-M365Token'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

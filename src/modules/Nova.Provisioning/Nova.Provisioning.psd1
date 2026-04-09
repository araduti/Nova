@{
    RootModule        = 'Nova.Provisioning.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '456bea79-7a7e-4882-95a1-dbea1b0ebe1d'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'First-boot provisioning and staging functions for Nova deployment engine.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @(
        'Add-SetupCompleteEntry'
        'Set-AutopilotConfig'
        'Invoke-AutopilotImport'
        'Install-CCMSetup'
        'Set-OOBECustomization'
        'Enable-BitLockerProtection'
        'Invoke-PostScript'
        'Install-Application'
        'Invoke-WindowsUpdateStaging'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Provisioning', 'Autopilot', 'OOBE', 'BitLocker', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

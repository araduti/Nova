@{
    RootModule        = 'Nova.Provisioning.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1001-4000-8000-000000000011'
    Author            = 'Nova Contributors'
    Description       = 'First-boot provisioning and staging functions for Nova deployment engine.'
    PowerShellVersion = '5.1'
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
}

@{
    RootModule        = 'Nova.WinRE.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'c503e644-d302-47a8-b0a4-b3f3cc14152e'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'WinRE discovery, extraction, and preparation for Nova boot image building.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @('Get-WinREPath', 'Get-WinREPathFromWindowsISO', 'Remove-WinRERecoveryPackage')
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'WinRE', 'Recovery', 'WinPE', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

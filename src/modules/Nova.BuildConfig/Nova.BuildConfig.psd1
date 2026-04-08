@{
    RootModule        = 'Nova.BuildConfig.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7539b5fc-3164-4277-ac7a-d9e26b021c47'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'WinPE boot image build configuration management for Nova.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @(
        'Get-BuildConfigPath'
        'Save-BuildConfiguration'
        'Read-SavedBuildConfiguration'
        'Resolve-WinPEPackagePath'
        'Show-BuildConfiguration'
        'Get-DefaultLanguage'
        'Get-AvailableWinPEPackages'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'BuildConfig', 'WinPE', 'Configuration', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

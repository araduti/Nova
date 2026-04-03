@{
    RootModule        = 'Nova.BuildConfig.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1006-4000-8000-000000000006'
    Author            = 'Nova Contributors'
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
}

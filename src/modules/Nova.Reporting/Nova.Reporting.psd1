@{
    RootModule        = 'Nova.Reporting.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b219a474-8826-47fb-b37f-9983c07fe524'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Deployment reporting, alerting, and log export functions for Nova.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Nova.Logging')
    FunctionsToExport = @(
        'Save-DeploymentReport'
        'Save-AssetInventory'
        'Update-ActiveDeploymentReport'
        'Send-DeploymentAlert'
        'Get-GitHubTokenViaEntra'
        'Push-ReportToGitHub'
        'Export-DeploymentLogs'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Reporting', 'Alerts', 'Logs', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

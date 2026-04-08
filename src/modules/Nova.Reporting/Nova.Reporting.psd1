@{
    RootModule        = 'Nova.Reporting.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1001-4000-8000-000000000012'
    Author            = 'Nova Contributors'
    Description       = 'Deployment reporting, alerting, and log export functions for Nova.'
    PowerShellVersion = '5.1'
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
}

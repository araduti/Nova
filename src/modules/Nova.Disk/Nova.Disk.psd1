@{
    RootModule        = 'Nova.Disk.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '07689fb2-329b-4165-baca-89c45298c9a6'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Disk partitioning functions for Nova deployment engine.'
    PowerShellVersion = '5.1'
    RequiredModules   = @(
        'Nova.Logging'
        'Nova.Platform'
    )
    FunctionsToExport = @('Get-TargetDisk', 'Initialize-TargetDisk', 'Get-PartitionGuid')
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'Disk', 'Partition', 'GPT', 'MBR', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

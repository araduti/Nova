@{
    RootModule        = 'Nova.Disk.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1001-4000-8000-000000000014'
    Author            = 'Nova Contributors'
    Description       = 'Disk partitioning functions for Nova deployment engine.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-TargetDisk'
        'Initialize-TargetDisk'
        'Get-PartitionGuid'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

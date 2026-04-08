@{
    RootModule        = 'Nova.TaskSequence.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-1001-4000-8000-000000000013'
    Author            = 'Nova Contributors'
    Description       = 'Task sequence parsing, condition evaluation, and dry-run validation for Nova.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Read-TaskSequence'
        'Test-StepCondition'
        'Invoke-DryRunValidation'
        'Update-TaskSequenceFromConfig'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}

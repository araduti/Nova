@{
    RootModule        = 'Nova.TaskSequence.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '09c1a50b-1f58-473a-a0f9-b2594bdfab03'
    Author            = 'Nova Contributors'
    CompanyName       = 'Ampliosoft'
    Copyright         = '(c) 2026 Ampliosoft. All rights reserved.'
    Description       = 'Task sequence parsing, condition evaluation, and dry-run validation for Nova.'
    PowerShellVersion = '5.1'
    RequiredModules   = @(
        'Nova.Logging'
        'Nova.Platform'
    )
    FunctionsToExport = @(
        'Read-TaskSequence'
        'Test-StepCondition'
        'Invoke-DryRunValidation'
        'Update-TaskSequenceFromConfig'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Nova', 'TaskSequence', 'Automation', 'Deployment')
            LicenseUri = 'https://github.com/araduti/Nova/blob/main/LICENSE'
            ProjectUri = 'https://github.com/araduti/Nova'
        }
    }
}

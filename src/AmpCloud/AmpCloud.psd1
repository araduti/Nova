#
# Module manifest for AmpCloud
#
# Generated on: 2026-03-25
#

@{

    # Script module file associated with this manifest.
    RootModule        = 'AmpCloud.psm1'

    # Version number of this module.
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module.
    GUID              = 'a3b1c4d5-e6f7-4a8b-9c0d-1e2f3a4b5c6d'

    # Author of this module.
    Author            = 'araduti'

    # Description of the functionality provided by this module.
    Description       = 'AmpCloud - Full cloud imaging engine for GitHub-native OS deployment. Builds custom WinPE/WinRE boot images, provides a graphical Bootstrap UI, and runs the imaging engine to partition, deploy, and configure Windows.'

    # Minimum version of the PowerShell engine required by this module.
    PowerShellVersion = '5.1'

    # Functions to export from this module — only Public/ functions are exported.
    FunctionsToExport = @(
        'Invoke-AmpCloudTrigger'
        'Invoke-AmpCloudBootstrap'
        'Invoke-AmpCloudEngine'
        'Import-AutopilotDevice'
    )

    # Cmdlets to export from this module.
    CmdletsToExport   = @()

    # Variables to export from this module.
    VariablesToExport = @()

    # Aliases to export from this module.
    AliasesToExport   = @()

    # Private data to pass to the module specified in RootModule.
    PrivateData       = @{
        PSData = @{
            # Tags applied to this module for discoverability.
            Tags       = @('OSD', 'WinPE', 'Imaging', 'Deployment', 'Windows', 'Autopilot')

            # A URL to the license for this module.
            LicenseUri = 'https://github.com/araduti/AmpCloud/blob/main/LICENSE'

            # A URL to the main website for this project.
            ProjectUri = 'https://github.com/araduti/AmpCloud'
        }
    }
}

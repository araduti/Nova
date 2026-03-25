function Install-CCMSetup {
    param(
        [string]$CCMSetupUrl,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    if (-not $CCMSetupUrl) {
        Write-Warn 'No CCMSetup URL specified. Skipping ConfigMgr setup.'
        return
    }

    Write-Step 'Staging ConfigMgr CCMSetup...'

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $ccmDir  = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $ccmDir -Force

        $stepName = 'Download ccmsetup.exe'
        $ccmExe  = Join-Path $ScratchDir 'ccmsetup.exe'
        Invoke-DownloadWithProgress -Uri $CCMSetupUrl -OutFile $ccmExe -Description 'Downloading ccmsetup.exe'

        $stepName = 'Stage ccmsetup.exe'
        Copy-Item $ccmExe (Join-Path $ccmDir 'ccmsetup.exe') -Force

        # Add to SetupComplete.cmd to run ccmsetup on first boot
        $stepName = 'Add SetupComplete entry'
        $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
        Add-SetupCompleteEntry -FilePath $setupComplete -Line '"%~dp0ccmsetup.exe" /BITSPriority:FOREGROUND'

        Write-Success 'CCMSetup staged for first-boot execution.'
    } catch {
        throw "Install-CCMSetup failed at step '$stepName': $_"
    }
}

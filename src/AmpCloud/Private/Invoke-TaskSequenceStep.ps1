function Invoke-TaskSequenceStep {
    <#
    .SYNOPSIS  Executes a single task sequence step by dispatching to the matching engine function.
    .DESCRIPTION
        Maps each step type string to the corresponding AmpCloud engine function,
        passing the step's parameters.  Uses the same functions that the hardcoded
        path calls, so behaviour is identical.
    #>
    param(
        [Parameter(Mandatory)]
        [psobject]$Step,
        [int]$Index,
        [int]$TotalSteps,
        # Shared state needed across steps (set by the caller)
        [string]$CurrentScratchDir,
        [string]$CurrentOSDrive,
        [string]$CurrentFirmwareType,
        [int]$CurrentDiskNumber
    )

    $pct = [math]::Min(100, [math]::Round(($Index / $TotalSteps) * 100))
    # Bootstrap.ps1 UI shows four progress steps (Network / Connect / Sign in /
    # Deploy).  During the deploy phase all four indicators should stay lit, so
    # always report Step 4 to keep the first three steps highlighted.
    $uiStep = 4
    $p = $Step.parameters

    switch ($Step.type) {
        'PartitionDisk' {
            $disk = if ($p -and $null -ne $p.diskNumber) { $p.diskNumber } else { $CurrentDiskNumber }
            $drv  = if ($p -and $p.osDriveLetter)        { $p.osDriveLetter } else { $CurrentOSDrive }
            Update-BootstrapStatus -Message "Partitioning disk..." -Detail "Creating layout on disk $disk" -Step $uiStep -Progress $pct
            Initialize-TargetDisk -DiskNumber $disk -FirmwareType $CurrentFirmwareType -OSDriveLetter $drv
        }
        'DownloadImage' {
            $url  = if ($p -and $p.imageUrl)      { $p.imageUrl }      else { $WindowsImageUrl }
            $ed   = if ($p -and $p.edition)        { $p.edition }       else { $WindowsEdition }
            $lang = if ($p -and $p.language)        { $p.language }      else { $WindowsLanguage }
            $arch = if ($p -and $p.architecture)    { $p.architecture }  else { $WindowsArchitecture }
            Update-BootstrapStatus -Message "Downloading Windows image..." -Detail "Fetching $ed $lang $arch" -Step $uiStep -Progress $pct
            $script:TsImagePath = Get-WindowsImageSource `
                -ImageUrl $url -Edition $ed -Language $lang -Architecture $arch `
                -FirmwareType $CurrentFirmwareType -ScratchDir $CurrentScratchDir
        }
        'ApplyImage' {
            $ed = if ($p -and $p.edition) { $p.edition } else { $WindowsEdition }
            Update-BootstrapStatus -Message "Applying Windows image..." -Detail "Expanding Windows files" -Step $uiStep -Progress $pct
            Install-WindowsImage -ImagePath $script:TsImagePath -Edition $ed -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'SetBootloader' {
            Update-BootstrapStatus -Message "Configuring bootloader..." -Detail "Writing BCD store" -Step $uiStep -Progress $pct
            Set-Bootloader -OSDriveLetter $CurrentOSDrive -FirmwareType $CurrentFirmwareType -DiskNumber $CurrentDiskNumber
        }
        'InjectDrivers' {
            $dp = if ($p -and $p.driverPath) { $p.driverPath } else { $DriverPath }
            Update-BootstrapStatus -Message "Injecting drivers..." -Detail "Adding drivers" -Step $uiStep -Progress $pct
            Add-Driver -DriverPath $dp -OSDriveLetter $CurrentOSDrive
        }
        'InjectOemDrivers' {
            Update-BootstrapStatus -Message "Injecting OEM drivers..." -Detail "Fetching manufacturer drivers" -Step $uiStep -Progress $pct
            Invoke-OemDriverInjection -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'ApplyAutopilot' {
            $jUrl  = if ($p -and $p.jsonUrl)  { $p.jsonUrl }  else { $AutopilotJsonUrl }
            $jPath = if ($p -and $p.jsonPath) { $p.jsonPath } else { $AutopilotJsonPath }
            Update-BootstrapStatus -Message "Applying Autopilot configuration..." -Detail "Embedding provisioning profile" -Step $uiStep -Progress $pct
            Set-AutopilotConfig -JsonUrl $jUrl -JsonPath $jPath -OSDriveLetter $CurrentOSDrive
        }
        'StageCCMSetup' {
            $url = if ($p -and $p.ccmSetupUrl) { $p.ccmSetupUrl } else { $CCMSetupUrl }
            Update-BootstrapStatus -Message "Staging ConfigMgr setup..." -Detail "Preparing ccmsetup.exe" -Step $uiStep -Progress $pct
            Install-CCMSetup -CCMSetupUrl $url -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'CustomizeOOBE' {
            $uUrl     = if ($p -and $p.unattendUrl)  { $p.unattendUrl }  else { $UnattendUrl }
            $uPath    = if ($p -and $p.unattendPath)  { $p.unattendPath }  else { $UnattendPath }
            $uContent = if ($p -and $p.unattendSource -eq 'default' -and $p.unattendContent) { $p.unattendContent } elseif (-not $p -or $p.unattendSource -ne 'cloud') { $UnattendContent } else { '' }
            Update-BootstrapStatus -Message "Customizing OOBE..." -Detail "Applying unattend.xml" -Step $uiStep -Progress $pct
            Set-OOBECustomization -UnattendUrl $uUrl -UnattendPath $uPath -UnattendContent $uContent -OSDriveLetter $CurrentOSDrive
        }
        'RunPostScripts' {
            $urls = if ($p -and $p.scriptUrls) { @($p.scriptUrls) } else { $PostScriptUrls }
            Update-BootstrapStatus -Message "Staging post-scripts..." -Detail "Downloading post-provisioning scripts" -Step $uiStep -Progress $pct
            Invoke-PostScript -ScriptUrls $urls -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        default {
            Write-Warn "Unknown step type '$($Step.type)' — skipping"
        }
    }
}

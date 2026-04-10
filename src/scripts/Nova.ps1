#Requires -Version 5.1
<#
.SYNOPSIS
    Nova - Full cloud imaging engine for GitHub-native OS deployment.

.DESCRIPTION
    Runs inside WinPE. Reads a task sequence JSON file produced by the
    web-based Editor, then executes each enabled step in order: partitions
    disks, downloads and applies Windows, injects drivers, applies
    Autopilot/Intune/ConfigMgr configuration, customizes OOBE, and runs
    post-provisioning scripts. All updates are instant via GitHub - no
    rebuilds needed.

.NOTES
    Fetched and executed by Bootstrap.ps1 at runtime.
    Requires WinPE with PowerShell, WMI, StorageWMI, and DISM cmdlets.
#>

[CmdletBinding()]
param(
    # GitHub source
    [ValidateNotNullOrEmpty()]
    [string]$GitHubUser   = 'araduti',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubRepo   = 'Nova',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubBranch = 'main',

    # Disk configuration
    [ValidateRange(0, [int]::MaxValue)]
    [int]$TargetDiskNumber = 0,
    [ValidateSet('UEFI','BIOS')]
    [string]$FirmwareType  = 'UEFI',

    # Scratch / temp directory inside WinPE
    [ValidateNotNullOrEmpty()]
    [string]$ScratchDir = 'X:\Nova',

    # Target OS drive letter (assigned during partitioning)
    [ValidatePattern('^[A-Za-z]$')]
    [string]$OSDrive = 'C',

    # IPC status file -- Bootstrap.ps1 polls this JSON file to show live progress
    # in the UI.  Leave empty to disable status reporting.
    [string]$StatusFile = '',

    # Task sequence JSON -- the engine reads the step list from this file and
    # executes each enabled step in order.  The file is produced by the
    # web-based Task Sequence Editor (src/web/editor/index.html) and follows the
    # schema defined in resources/task-sequence/default.json.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskSequencePath,

    # When set, validates the task sequence without performing any destructive
    # operations (no partitioning, no imaging, no driver injection).
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── TLS ─────────────────────────────────────────────────────────────────────
# PowerShell 5.1 in WinPE defaults to SSL3/TLS 1.0.  This engine runs in a
# dedicated process (Start-Process from Bootstrap.ps1), so the parent's TLS
# setting does not carry over.  Enforce TLS 1.2 before any HTTPS traffic.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Logging ─────────────────────────────────────────────────────────────────
# This engine runs in a dedicated process (Start-Process from Bootstrap.ps1),
# so the parent's Start-Transcript does not carry over.  Start our own
# transcript so every Write-Host, warning, and error is captured to disk.
$script:EngineLogPath = 'X:\Nova-Engine.log'
$null = Start-Transcript -Path $script:EngineLogPath -Force -ErrorAction SilentlyContinue

# Resolved once so WinPE's X:\ path is used correctly in the error handler.
$script:PsBin = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ── Constants ───────────────────────────────────────────────────────────────
# Partition GUIDs and sizes are now in Nova.Disk module.
# Cached GitHub token state is now in Nova.Reporting module.

# Download settings (used by Invoke-DownloadWithProgress which stays here)
$script:DownloadBufferSize      = 65536   # 64 KB read buffer
$script:RetryBackoffBaseSeconds = 5
$script:ProgressIntervalMs  = 1000    # Minimum ms between progress updates

# ── Import shared modules ──────────────────────────────────────────────────────
# Resolve module path: repo layout ($PSScriptRoot/../modules) or WinPE staging
# (X:\Windows\System32\Modules -- copied by Trigger.ps1 during image build).
$script:ModulesRoot = if (Test-Path "$PSScriptRoot\..\modules") {
    "$PSScriptRoot\..\modules"
} elseif (Test-Path 'X:\Windows\System32\Modules') {
    'X:\Windows\System32\Modules'
} else {
    "$PSScriptRoot\..\modules"   # Best-effort fallback
}
Import-Module "$script:ModulesRoot\Nova.Logging"      -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Platform"     -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Reporting"    -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Disk"         -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Imaging"      -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Drivers"      -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Provisioning" -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.TaskSequence" -Force -ErrorAction Stop
Set-NovaLogPrefix -Step "`n[Nova]" -Success '[OK]' -Warn '[WARN]' -Fail '[FAIL]'

#region ── Helpers ──────────────────────────────────────────────────────────────

function Update-BootstrapStatus {
    <#
    .SYNOPSIS  Writes live progress to a JSON file for Bootstrap.ps1 to display.
    .DESCRIPTION
        Bootstrap.ps1 polls $StatusFile every ~650 ms and updates its UI
        with the message, progress percentage, and step number.  When imaging is
        done, set -Done to signal the spinner to stop.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Message  = '',
        [string]$Detail   = '',
        [int]$Progress    = 0,
        [int]$Step        = 0,
        [switch]$Done
    )
    # No-op when StatusFile is empty (disables IPC reporting by design).
    if (-not $StatusFile) { return }
    try {
        $obj = @{ Message = $Message; Detail = $Detail; Progress = $Progress; Step = $Step; Done = [bool]$Done }
        $obj | ConvertTo-Json -Compress | Set-Content -Path $StatusFile -Force -ErrorAction SilentlyContinue
    } catch { Write-Verbose "Status update suppressed: $_" }
}

function New-ScratchDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

# Get-FileSizeReadable is now provided by the Nova.Platform module.

function Invoke-DownloadWithProgress {
    param(
        [string]$Uri,
        [string]$OutFile,
        [string]$Description = 'Downloading',
        [int]$BaseProgress   = 0,
        [int]$ProgressRange  = 0,
        [int]$MaxRetries     = 3
    )
    Write-Step "$Description"
    Write-Host "  Source : $Uri"
    Write-Host "  Target : $OutFile"

    $attempt = 0
    while ($true) {
        $attempt++
        $response  = $null
        $stream    = $null
        $fs        = $null
        try {
            # Check for partial file to support resume
            $existingSize = if (Test-Path $OutFile) { (Get-Item $OutFile).Length } else { 0 }

            $wr = [System.Net.WebRequest]::Create($Uri)
            $wr.Method  = 'GET'
            $wr.Timeout = 30000   # 30-second connection timeout (ms)

            if ($existingSize -gt 0) {
                $wr.AddRange([long]$existingSize)
                Write-Host "  Resuming from $(Get-FileSizeReadable $existingSize)..."
            }

            $response  = $wr.GetResponse()
            $totalBytes = $response.ContentLength + $existingSize
            $stream     = $response.GetResponseStream()
            $stream.ReadTimeout = 30000   # 30-second read timeout (ms)

            if ($existingSize -gt 0) {
                $fs = [System.IO.FileStream]::new($OutFile, [System.IO.FileMode]::Append)
            } else {
                $fs = [System.IO.File]::Create($OutFile)
            }

            $buffer     = New-Object byte[] $script:DownloadBufferSize
            $downloaded = $existingSize
            $sw         = [System.Diagnostics.Stopwatch]::StartNew()

            do {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -gt 0) {
                    $fs.Write($buffer, 0, $read)
                    $downloaded += $read
                    if ($sw.ElapsedMilliseconds -gt $script:ProgressIntervalMs) {
                        $pct = if ($totalBytes -gt 0) { [int]($downloaded * 100 / $totalBytes) } else { 0 }
                        $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { [long]($downloaded / $sw.Elapsed.TotalSeconds) } else { 0 }
                        $detail = "$pct% -- $(Get-FileSizeReadable $downloaded) of $(Get-FileSizeReadable $totalBytes) @ $(Get-FileSizeReadable $speed)/s"
                        Write-Host "  Progress: $detail" -NoNewline
                        Write-Host "`r" -NoNewline
                        if ($ProgressRange -gt 0) {
                            $overallPct = [Math]::Min($BaseProgress + $ProgressRange, $BaseProgress + [int]($pct * $ProgressRange / 100))
                            Update-BootstrapStatus -Message $Description -Detail $detail -Step 4 -Progress $overallPct
                        }
                        $sw.Restart()
                    }
                }
            } while ($read -gt 0)

            Write-Host ''
            Write-Success "Download complete: $(Get-FileSizeReadable $downloaded)"
            break   # Success -- exit retry loop
        } catch {
            if ($attempt -ge $MaxRetries) {
                throw "Download failed for '$Description' after $MaxRetries attempt(s) (URL: $Uri): $_"
            }
            $backoff = [math]::Pow(2, $attempt - 1) * $script:RetryBackoffBaseSeconds
            Write-Warn "Download attempt $attempt/$MaxRetries failed: $_"
            Write-Warn "Retrying in $backoff seconds..."
            Start-Sleep -Seconds $backoff
        } finally {
            if ($fs)       { $fs.Close() }
            if ($stream)   { $stream.Close() }
            if ($response) { $response.Close() }
        }
    }
}

#endregion

# Get-FirmwareType is now provided by the Nova.Platform module.

# Get-TargetDisk, Initialize-TargetDisk, and partition constants are now
# provided by the Nova.Disk module.

# Find-WindowsESD, Get-WindowsImageSource, Install-WindowsImage,
# Set-Bootloader, and EditionNameMap are now provided by the Nova.Imaging module.

# Add-Driver, Initialize-NuGetProvider, Install-OemModule, Get-SystemManufacturer,
# Add-DellDriver, Add-HpDriver, Add-LenovoDriver, Add-SurfaceDriver, and
# Invoke-OemDriverInjection are now provided by the Nova.Drivers module.

# Add-SetupCompleteEntry, Set-AutopilotConfig, Invoke-AutopilotImport,
# Install-CCMSetup, Set-OOBECustomization, Enable-BitLockerProtection,
# Invoke-PostScript, Install-Application, Invoke-WindowsUpdateStaging,
# and DefaultUnattendXml are now provided by the Nova.Provisioning module.

# Read-TaskSequence, Test-StepCondition, and Invoke-DryRunValidation are
# now provided by the Nova.TaskSequence module.

#region ── Task Sequence ────────────────────────────────────────────────────────

function Invoke-TaskSequenceStep {
    <#
    .SYNOPSIS  Executes a single task sequence step by dispatching to the matching engine function.
    .DESCRIPTION
        Maps each step type string to the corresponding Nova engine function,
        passing the step's parameters.  All parameter values come from the task
        sequence JSON -- no script-level fallbacks.
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

    # Build a scriptblock reference to the local download helper so module
    # functions (Nova.Imaging, Nova.Drivers, Nova.Provisioning) can use it
    # without a hard dependency on a script-scoped function.
    $dlCmd = { param($Uri, $OutFile, $Description, $BaseProgress, $ProgressRange)
        $splat = @{ Uri = $Uri; OutFile = $OutFile; Description = $Description }
        if ($BaseProgress)  { $splat.BaseProgress  = $BaseProgress }
        if ($ProgressRange) { $splat.ProgressRange = $ProgressRange }
        Invoke-DownloadWithProgress @splat
    }

    switch ($Step.type) {
        'PartitionDisk' {
            $disk = if ($p -and $p.PSObject.Properties['diskNumber'] -and $null -ne $p.diskNumber) { $p.diskNumber } else { $CurrentDiskNumber }
            # Auto-select disk when -1 or not specified
            if ($disk -eq -1) {
                $disk = Get-TargetDisk -DiskNumber -1
            }
            $drv  = if ($p -and $p.PSObject.Properties['osDriveLetter'] -and $p.osDriveLetter) { $p.osDriveLetter } else { $CurrentOSDrive }
            $createRecovery = if ($p -and $p.PSObject.Properties['createRecoveryPartition'] -and $p.createRecoveryPartition) { $true } else { $false }
            $recoverySize = if ($p -and $p.PSObject.Properties['recoveryPartitionSize'] -and $p.recoveryPartitionSize -gt 0) { [long]$p.recoveryPartitionSize } else { 990MB }
            Update-BootstrapStatus -Message "Partitioning disk..." -Detail "Creating layout on disk $disk" -Step $uiStep -Progress $pct
            Initialize-TargetDisk -DiskNumber $disk -FirmwareType $CurrentFirmwareType -OSDriveLetter $drv `
                -CreateRecoveryPartition:$createRecovery -RecoveryPartitionSize $recoverySize
        }
        'ImportAutopilot' {
            $tag   = if ($p -and $p.PSObject.Properties['groupTag']  -and $p.groupTag)  { $p.groupTag }  else { '' }
            $email = if ($p -and $p.PSObject.Properties['userEmail'] -and $p.userEmail) { $p.userEmail } else { '' }
            Update-BootstrapStatus -Message "Importing Autopilot device..." -Detail "Registering device in Windows Autopilot" -Step $uiStep -Progress $pct
            Invoke-AutopilotImport -GroupTag $tag -UserEmail $email
        }
        'DownloadImage' {
            $url  = if ($p -and $p.PSObject.Properties['imageUrl']      -and $p.imageUrl)      { $p.imageUrl }      else { '' }
            $ed   = if ($p -and $p.PSObject.Properties['edition']       -and $p.edition)       { $p.edition }       else { 'Professional' }
            $lang = if ($p -and $p.PSObject.Properties['language']      -and $p.language)      { $p.language }      else { 'en-us' }
            $arch = if ($p -and $p.PSObject.Properties['architecture']  -and $p.architecture)  { $p.architecture }  else { 'x64' }
            Update-BootstrapStatus -Message "Downloading Windows image..." -Detail "Fetching $ed $lang $arch" -Step $uiStep -Progress $pct
            $script:TsImagePath = Get-WindowsImageSource `
                -ImageUrl $url -Edition $ed -Language $lang -Architecture $arch `
                -FirmwareType $CurrentFirmwareType -ScratchDir $CurrentScratchDir `
                -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch `
                -DownloadCommand $dlCmd
        }
        'ApplyImage' {
            $ed   = if ($p -and $p.PSObject.Properties['edition']       -and $p.edition)       { $p.edition }       else { 'Professional' }
            $lang = if ($p -and $p.PSObject.Properties['language']      -and $p.language)      { $p.language }      else { 'en-us' }
            $arch = if ($p -and $p.PSObject.Properties['architecture']  -and $p.architecture)  { $p.architecture }  else { 'x64' }
            if (-not $script:TsImagePath) {
                $url = if ($p -and $p.PSObject.Properties['imageUrl'] -and $p.imageUrl) { $p.imageUrl } else { '' }
                Update-BootstrapStatus -Message "Downloading Windows image..." -Detail "Fetching $ed $lang $arch" -Step $uiStep -Progress $pct
                $script:TsImagePath = Get-WindowsImageSource `
                    -ImageUrl $url -Edition $ed -Language $lang -Architecture $arch `
                    -FirmwareType $CurrentFirmwareType -ScratchDir $CurrentScratchDir `
                    -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch `
                    -DownloadCommand $dlCmd
            }
            Update-BootstrapStatus -Message "Applying Windows image..." -Detail "Expanding Windows files" -Step $uiStep -Progress $pct
            Install-WindowsImage -ImagePath $script:TsImagePath -Edition $ed -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'SetBootloader' {
            Update-BootstrapStatus -Message "Configuring bootloader..." -Detail "Writing BCD store" -Step $uiStep -Progress $pct
            Set-Bootloader -OSDriveLetter $CurrentOSDrive -FirmwareType $CurrentFirmwareType -DiskNumber $CurrentDiskNumber
        }
        'InjectDrivers' {
            $dp = if ($p -and $p.PSObject.Properties['driverPath'] -and $p.driverPath) { $p.driverPath } else { '' }
            Update-BootstrapStatus -Message "Injecting drivers..." -Detail "Adding drivers" -Step $uiStep -Progress $pct
            Add-Driver -DriverPath $dp -OSDriveLetter $CurrentOSDrive
        }
        'InjectOemDrivers' {
            Update-BootstrapStatus -Message "Injecting OEM drivers..." -Detail "Fetching manufacturer drivers" -Step $uiStep -Progress $pct
            Invoke-OemDriverInjection -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir -DownloadCommand $dlCmd
        }
        'ApplyAutopilot' {
            $jUrl  = if ($p -and $p.PSObject.Properties['jsonUrl']  -and $p.jsonUrl)  { $p.jsonUrl }  else { '' }
            $jPath = if ($p -and $p.PSObject.Properties['jsonPath'] -and $p.jsonPath) { $p.jsonPath } else { '' }
            Update-BootstrapStatus -Message "Applying Autopilot configuration..." -Detail "Embedding provisioning profile" -Step $uiStep -Progress $pct
            Set-AutopilotConfig -JsonUrl $jUrl -JsonPath $jPath -OSDriveLetter $CurrentOSDrive
        }
        'StageCCMSetup' {
            $url = if ($p -and $p.PSObject.Properties['ccmSetupUrl'] -and $p.ccmSetupUrl) { $p.ccmSetupUrl } else { '' }
            Update-BootstrapStatus -Message "Staging ConfigMgr setup..." -Detail "Preparing ccmsetup.exe" -Step $uiStep -Progress $pct
            Install-CCMSetup -CCMSetupUrl $url -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir -DownloadCommand $dlCmd
        }
        'SetComputerName' {
            # Resolve computer name from naming rules or use the static value.
            # The Task Sequence Editor and Bootstrap config modal handle syncing
            # names into unattendContent -- the engine just resolves and logs.
            $cName = if ($p -and $p.PSObject.Properties['computerName'] -and $p.computerName) { $p.computerName } else { '' }
            if (-not $cName -and $p) {
                # Determine naming source (backward compat: useSerialNumber → serialNumber)
                $source = if ($p.PSObject.Properties['namingSource'] -and $p.namingSource) { $p.namingSource }
                          elseif ($p.PSObject.Properties['useSerialNumber'] -and $p.useSerialNumber) { 'serialNumber' }
                          else { 'randomDigits' }
                $base = ''
                switch ($source) {
                    'serialNumber' {
                        try { $base = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber -replace '[^A-Za-z0-9]','' } catch { $null = $_ }
                    }
                    'assetTag' {
                        try { $base = (Get-CimInstance -ClassName Win32_SystemEnclosure).SMBIOSAssetTag -replace '[^A-Za-z0-9]','' } catch { $null = $_ }
                    }
                    'macAddress' {
                        try {
                            $mac = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.MACAddress } | Select-Object -First 1).MACAddress
                            $mac = if ($mac) { $mac -replace '[:\-]','' } else { '' }
                            if ($mac.Length -ge 12) { $base = $mac.Substring(6) }
                        } catch { $null = $_ }
                    }
                    'deviceModel' {
                        try { $base = (Get-CimInstance -ClassName Win32_ComputerSystem).Model -replace '[^A-Za-z0-9]','' } catch { $null = $_ }
                    }
                    'randomDigits' {
                        $count = if ($p.PSObject.Properties['randomDigitCount'] -and $p.randomDigitCount -gt 0) { [math]::Min($p.randomDigitCount, 10) } else { 4 }
                        $min = [int][math]::Pow(10, $count - 1)
                        $max = [int][math]::Pow(10, $count)
                        $base = (Get-Random -Minimum ([int]$min) -Maximum ([int]$max)).ToString()
                    }
                }
                if (-not $base) { $base = 'PC' + (Get-Random -Minimum 1000 -Maximum 9999).ToString() }
                $pfx = if ($p.PSObject.Properties['prefix'] -and $p.prefix) { $p.prefix } else { '' }
                $sfx = if ($p.PSObject.Properties['suffix'] -and $p.suffix) { $p.suffix } else { '' }
                $cName = $pfx + $base + $sfx
            }
            # Enforce max length (NetBIOS limit is 15)
            $maxLen = if ($p -and $p.PSObject.Properties['maxLength'] -and $p.maxLength -gt 0) { [math]::Min($p.maxLength, 15) } else { 15 }
            if ($cName.Length -gt $maxLen) { $cName = $cName.Substring(0, $maxLen) }
            # Strip invalid characters (letters, digits, hyphens only; no leading/trailing hyphens)
            $cName = ($cName -replace '[^A-Za-z0-9\-]','').Trim('-')
            if ($cName) {
                Update-BootstrapStatus -Message "Setting computer name..." -Detail "Name: $cName" -Step $uiStep -Progress $pct
                Write-Success "Computer name resolved: $cName"
            } else {
                Update-BootstrapStatus -Message "Setting computer name..." -Detail "No name specified -- Windows will assign a random name" -Step $uiStep -Progress $pct
                Write-Warn "No computer name resolved -- Windows will assign a random name"
            }
        }
        'SetRegionalSettings' {
            # Log the regional settings.  The Editor and Bootstrap config
            # modal already synced locale values into unattendContent -- no
            # engine-level XML update needed.
            $iLocale = if ($p -and $p.PSObject.Properties['inputLocale']  -and $p.inputLocale)  { $p.inputLocale }  else { '' }
            $sLocale = if ($p -and $p.PSObject.Properties['systemLocale'] -and $p.systemLocale) { $p.systemLocale } else { '' }
            $uiLang  = if ($p -and $p.PSObject.Properties['uiLanguage']   -and $p.uiLanguage)   { $p.uiLanguage }   else { '' }
            $detail = @()
            if ($iLocale) { $detail += "Keyboard: $iLocale" }
            if ($sLocale) { $detail += "Region: $sLocale" }
            if ($uiLang)  { $detail += "Language: $uiLang" }
            $detailStr = if ($detail.Count -gt 0) { $detail -join ', ' } else { 'No regional settings specified' }
            Update-BootstrapStatus -Message "Setting regional settings..." -Detail $detailStr -Step $uiStep -Progress $pct
            Write-Success "Regional settings applied: $detailStr"
        }
        'CustomizeOOBE' {
            # The unattendContent is already the final XML -- the Editor syncs
            # step values at design time and Bootstrap syncs config-modal
            # values at runtime.  Just write it to disk.
            $uUrl     = if ($p -and $p.PSObject.Properties['unattendUrl']     -and $p.unattendUrl)     { $p.unattendUrl }     else { '' }
            $uPath    = if ($p -and $p.PSObject.Properties['unattendPath']    -and $p.unattendPath)    { $p.unattendPath }    else { '' }
            $uSrc     = if ($p -and $p.PSObject.Properties['unattendSource']  -and $p.unattendSource)  { $p.unattendSource }  else { '' }
            $uContent = if ($uSrc -eq 'default' -and $p.PSObject.Properties['unattendContent'] -and $p.unattendContent) { $p.unattendContent } else { '' }
            Update-BootstrapStatus -Message "Customizing OOBE..." -Detail "Applying unattend.xml" -Step $uiStep -Progress $pct
            Set-OOBECustomization -UnattendUrl $uUrl -UnattendPath $uPath -UnattendContent $uContent -OSDriveLetter $CurrentOSDrive
        }
        'RunPostScripts' {
            $urls = if ($p -and $p.PSObject.Properties['scriptUrls'] -and $p.scriptUrls) { @($p.scriptUrls) } else { @() }
            Update-BootstrapStatus -Message "Staging post-scripts..." -Detail "Downloading post-provisioning scripts" -Step $uiStep -Progress $pct
            Invoke-PostScript -ScriptUrls $urls -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'EnableBitLocker' {
            $method = if ($p -and $p.PSObject.Properties['encryptionMethod'] -and $p.encryptionMethod) { $p.encryptionMethod } else { 'XtsAes256' }
            $skipHw = if ($p -and $p.PSObject.Properties['skipHardwareTest'] -and $p.skipHardwareTest) { $true } else { $false }
            Update-BootstrapStatus -Message "Enabling BitLocker..." -Detail "Staging encryption for first boot" -Step $uiStep -Progress $pct
            Enable-BitLockerProtection -OSDriveLetter $CurrentOSDrive -EncryptionMethod $method -SkipHardwareTest:$skipHw
        }
        'InstallApplication' {
            $mode     = if ($p -and $p.PSObject.Properties['installMode'] -and $p.installMode) { $p.installMode } else { 'url' }
            $pkgId    = if ($p -and $p.PSObject.Properties['packageId']   -and $p.packageId)   { $p.packageId }   else { '' }
            $url      = if ($p -and $p.PSObject.Properties['installerUrl'] -and $p.installerUrl) { $p.installerUrl } else { '' }
            $silArgs  = if ($p -and $p.PSObject.Properties['silentArgs']  -and $p.silentArgs)  { $p.silentArgs }  else { '/qn /norestart' }
            $sUrl     = if ($p -and $p.PSObject.Properties['scriptUrl']   -and $p.scriptUrl)   { $p.scriptUrl }   else { '' }
            Update-BootstrapStatus -Message "Installing application..." -Detail "Mode: $mode" -Step $uiStep -Progress $pct
            Install-Application -InstallMode $mode -PackageId $pkgId -InstallerUrl $url -SilentArgs $silArgs -ScriptUrl $sUrl -OSDriveLetter $CurrentOSDrive -DownloadCommand $dlCmd
        }
        'WindowsUpdate' {
            $cats = if ($p -and $p.PSObject.Properties['categories'] -and $p.categories) { @($p.categories) } else { @('SecurityUpdates', 'CriticalUpdates') }
            Update-BootstrapStatus -Message "Staging Windows Update..." -Detail "Preparing first-boot updates" -Step $uiStep -Progress $pct
            Invoke-WindowsUpdateStaging -OSDriveLetter $CurrentOSDrive -Categories $cats
        }
        default {
            Write-Warn "Unknown step type '$($Step.type)' -- skipping"
        }
    }
}

#endregion

# Export-DeploymentLogs is now provided by the Nova.Reporting module.
# Invoke-DryRunValidation is now provided by the Nova.TaskSequence module.

#region ── Main ─────────────────────────────────────────────────────────────────

Write-Host @"

  █████╗ ███╗   ███╗██████╗  ██████╗██╗      ██████╗ ██╗   ██╗██████╗
 ██╔══██╗████╗ ████║██╔══██╗██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗
 ███████║██╔████╔██║██████╔╝██║     ██║     ██║   ██║██║   ██║██║  ██║
 ██╔══██║██║╚██╔╝██║██╔═══╝ ██║     ██║     ██║   ██║██║   ██║██║  ██║
 ██║  ██║██║ ╚═╝ ██║██║     ╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝
 ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝      ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝

 Cloud-only Imaging Engine · amd64/x86 · https://github.com/$GitHubUser/$GitHubRepo
"@ -ForegroundColor Cyan

# Auto-detect firmware type when the caller did not provide one explicitly.
# Bootstrap.ps1 may not always pass -FirmwareType, so falling back to runtime
# detection prevents creating a GPT/UEFI layout on a BIOS system (black screen).
if (-not $PSBoundParameters.ContainsKey('FirmwareType')) {
    $FirmwareType = Get-FirmwareType
}

$stepName = ''
$script:DeploymentStartTime = Get-Date
$script:CompletedStepCount  = 0
try {

    # ── Task-sequence-driven execution ──────────────────────────────
    # Read the step list from the JSON task sequence file and execute
    # each enabled step in the order defined by the editor.
    $ts = Read-TaskSequence -Path $TaskSequencePath

    if ($DryRun) {
        Invoke-DryRunValidation -TaskSequence $ts -ScratchDir $ScratchDir -OSDrive $OSDrive -FirmwareType $FirmwareType -DiskNumber $TargetDiskNumber
        Write-Step 'DRY RUN complete -- no destructive operations performed.'
        return
    }

    Write-Step "Firmware type: $FirmwareType"
    New-ScratchDirectory -Path $ScratchDir

    $enabledSteps = @($ts.steps | Where-Object { $_.enabled -ne $false })
    Write-Step "Executing $($enabledSteps.Count) enabled steps"

    # Inter-step state: DownloadImage stores the resolved image path for
    # ApplyImage to consume.  ComputerName and locale settings are synced
    # into unattendContent by the Editor and Bootstrap config modal -- the
    # engine just writes what's in the task sequence.
    $script:TsImagePath = ''
    $tsName = if ($ts.name) { $ts.name } else { 'Unknown' }

    for ($i = 0; $i -lt $enabledSteps.Count; $i++) {
        $s = $enabledSteps[$i]
        $stepName = $s.name

        # Evaluate step condition (if any) before execution
        if ($s.PSObject.Properties['condition'] -and $s.condition -and $s.condition.type) {
            if (-not (Test-StepCondition -Condition $s.condition)) {
                Write-Step "[$($i+1)/$($enabledSteps.Count)] $($s.name) ($($s.type)) -- condition not met, skipping"
                continue
            }
        }

        Write-Step "[$($i+1)/$($enabledSteps.Count)] $($s.name) ($($s.type))"

        # Update active deployment report so the Monitoring dashboard can
        # display in-progress status for this device.
        # Wrapped in try/catch so a failed status update never blocks imaging.
        $stepPct = if ($enabledSteps.Count -gt 0) { [math]::Min(100, [math]::Round(($i / $enabledSteps.Count) * 100)) } else { 0 }
        try {
            Update-ActiveDeploymentReport -TaskSequence $tsName `
                -CurrentStep "$($s.name)..." -Progress $stepPct `
                -StartTime $script:DeploymentStartTime `
                -ScratchDir $ScratchDir `
                -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
        } catch {
            Write-Verbose "Non-blocking: active deployment report update failed for step '$($s.name)': $_"
        }

        # After PartitionDisk, redirect scratch to OS drive
        if ($s.type -eq 'PartitionDisk') {
            Invoke-TaskSequenceStep -Step $s -Index ($i+1) -TotalSteps $enabledSteps.Count `
                -CurrentScratchDir $ScratchDir `
                -CurrentOSDrive $OSDrive -CurrentFirmwareType $FirmwareType `
                -CurrentDiskNumber $TargetDiskNumber
            $ScratchDir = Join-Path "${OSDrive}:" 'Nova'
            New-ScratchDirectory -Path $ScratchDir
        } else {
            try {
                Invoke-TaskSequenceStep -Step $s -Index ($i+1) -TotalSteps $enabledSteps.Count `
                    -CurrentScratchDir $ScratchDir `
                    -CurrentOSDrive $OSDrive -CurrentFirmwareType $FirmwareType `
                    -CurrentDiskNumber $TargetDiskNumber
            } catch {
                if ($s.PSObject.Properties['continueOnError'] -and $s.continueOnError) {
                    Write-Warn "Step '$($s.name)' failed but continueOnError is set -- continuing: $_"
                } else {
                    throw
                }
            }
        }
        $script:CompletedStepCount = $i + 1
    }

    # ── Deployment reporting & alerting ─────────────────────────────
    $elapsed   = (Get-Date) - $script:DeploymentStartTime
    $durString = '{0}m {1}s' -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

    # Clear active deployment file -- device is no longer deploying
    try { Update-ActiveDeploymentReport -Clear -ScratchDir $ScratchDir -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch }
    catch { Write-Warning "Non-blocking: failed to clear active deployment report for '$($env:COMPUTERNAME)': $_" }

    Save-DeploymentReport -Status 'success' -TaskSequence $tsName `
        -StepsCompleted $enabledSteps.Count -StepsTotal $enabledSteps.Count `
        -StartTime $script:DeploymentStartTime `
        -ScratchDir $ScratchDir `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch

    # Record asset inventory for fleet tracking
    Save-AssetInventory -TaskSequence $tsName -ComputerName $env:COMPUTERNAME -ReportDir $ScratchDir `
        -ScratchDir $ScratchDir `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch

    Send-DeploymentAlert -Status 'success' -TaskSequence $tsName `
        -Duration $durString `
        -StepsCompleted $enabledSteps.Count -StepsTotal $enabledSteps.Count `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch

    Update-BootstrapStatus -Message 'Imaging complete -- rebooting...' -Detail 'Windows installation finished successfully' -Step 4 -Progress 100 -Done

    Write-Host @"

[Nova] ══════════════════════════════════════════════════════════
[Nova]  Imaging complete! Windows is ready on drive ${OSDrive}:
[Nova]  Rebooting in 15 seconds...
[Nova] ══════════════════════════════════════════════════════════
"@ -ForegroundColor Green

    # Clean up scratch directory so temporary files do not persist in the
    # final Windows installation.
    $stepName = 'Clean up scratch directory'
    if (Test-Path $ScratchDir) {
        Remove-Item $ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Export WinPE logs to OS drive for post-reboot troubleshooting
    Export-DeploymentLogs -OSDriveLetter $OSDrive -EngineLogPath $script:EngineLogPath

    $stepName = 'Reboot'
    Start-Sleep -Seconds 15
    Restart-Computer -Force

} catch {
    Write-Fail "Nova imaging failed at step '$stepName': $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ''

    # ── Failure reporting & alerting ────────────────────────────────
    $tsName    = if ($ts -and $ts.name) { $ts.name } else { 'Unknown' }
    $totalSteps = if ($enabledSteps) { $enabledSteps.Count } else { 0 }
    $elapsed   = (Get-Date) - $script:DeploymentStartTime
    $durString = '{0}m {1}s' -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

    # Clear active deployment file -- device is no longer deploying
    try { Update-ActiveDeploymentReport -Clear -ScratchDir $ScratchDir -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch }
    catch { Write-Warning "Non-blocking: failed to clear active deployment report for '$($env:COMPUTERNAME)': $_" }

    Save-DeploymentReport -Status 'failed' -TaskSequence $tsName `
        -StepsCompleted $script:CompletedStepCount -StepsTotal $totalSteps `
        -StartTime $script:DeploymentStartTime `
        -ErrorMessage "$_" -FailedStep $stepName `
        -ScratchDir $ScratchDir `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch

    Send-DeploymentAlert -Status 'failed' -TaskSequence $tsName `
        -Duration $durString `
        -StepsCompleted $script:CompletedStepCount -StepsTotal $totalSteps `
        -ErrorMessage "$_" -FailedStep $stepName `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch

    # Update the HTML UI status file so the deployment page shows the
    # failure instead of staying stuck at the last progress state.
    Update-BootstrapStatus -Message "Imaging failed at step '$stepName'" `
        -Detail "$_" -Step 4

    # Export logs even on failure for troubleshooting
    try { Export-DeploymentLogs -OSDriveLetter $OSDrive -EngineLogPath $script:EngineLogPath } catch { $null = $_ }

    Write-Host '[Nova] Dropping to interactive shell for troubleshooting.' -ForegroundColor Yellow
    # Re-throw so Bootstrap.ps1 can close the UI before the user
    # needs the console.  The PowerShell host was started with -NoExit by
    # nova-start.cmd, so an interactive prompt appears automatically
    # once the form is dismissed.
    throw
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}

#endregion
# SIG # Begin signature block
# MII9dgYJKoZIhvcNAQcCoII9ZzCCPWMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBFnKBQ5vhOZv4x
# sA3as3iMVHIyhqTijbaaowc4KAztl6CCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAAf9F8I
# 9dTWl3i0AAAAAB/0MA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNDA5MTQzNDE0WhcNMjYwNDEy
# MTQzNDE0WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCx/g++XtnJK7rE
# 0KdajcoolJBoDDfdRpmQNC9/GzA0HV9OF7JqGRzyetOdvFwuoeSs/WTySDN6LfUl
# RShMrxqthSBnxKizrV6QwIshT8R8DhNlq3GlGyoaozQsFR8qUdVd5HGjEuXgea1d
# cUEEKFOEOGveUCJoNioZsCpLPqKz8kqQKDKedUXt4BEOq0ZIx8u4VWOUd/8a8+BH
# hRAmqZ2MneNYz5M3R8pjQ/LOgLWZi4HLyqvVRWE+blYB1X4sf4sZ6vY+WMgeg1IF
# 0kRJqe3z8hV0sJQ/Z8df8q3qtKwCTwW69P2jzdW5Yvv6MOgad33QAE6FWiccuxle
# t/b+4Pcj2Oq0Ewsxi8EXlg2S089n696X8EepMvOdDqd61nA7ANY3NC9UuYObLABR
# bF+N+co+Ul+JCvY5ICxRlLCh+X+EyRQ2Vt1m5zlUur2wbQZq+jkXlxB5VA3533oJ
# 5eIFvUzgPpr6VtPzY4rGAyVAxIXrG4P7n73LXg5L/ab+Nmx7jqUCAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQU4D7TdnNsaAKxOOGcp1Ym6JlRKBAwHwYDVR0jBBgwFoAUmvFUd3UM
# hxY3RqCs3nn59H/BeOkwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwNC5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBABQEzS1JWIQaoIhs/bao1+zhOP2dOlgv/XPjH/5pwAK2oUJmMOvrt2Vi
# XGXNGE4j5E21vjtuvpE0atkpqXx9rErkl7psFTWvXb2z3YNlzhjuvFoK5hUXnuYK
# 9GAmtd1ZtTJVSgnKW6NKyFLwLHGCfQnl5t0XcsbOh8gJEl/iBZBfbsWvnHNUwF8r
# L4ZCcXAQMDaEFUlyOaMqFFu/ogHc5n5Z1lXkx8Jho5Kkk41atBCMm/QZX5HAZROO
# eEpyc55dzpzlGHo2Zus/+OCo6gdFBCTge5ymPnvvQwCZphfzmZMKIdrIPgJ3Wj8p
# 8exq7dVTFdG/+DsGZeyRvGUl1noUYfFIEYjONE6A4rzxut1//ItktHlgxlwNhwdI
# qW3QyeAhrJ36x6tIMq/liCTYxXsnmc5CFj7dN583kB5fR8BsFbwiAa1aX3hbrJeX
# W14uKxPLW3tYLsE0ioGcLJ2kqp07hGhLfZXtC2TTLMf0ha6xFGRt8HcWB/x1YwC0
# Xjxk0a8bcw4A/ry9r1zgdUiGqKipuSNGKSX5g9I8/C23eeMcDSu5jQe2un6CeFYe
# iLFwuX2so0mOpWFpPRxuEGx5sg3DV8dmkGsurr+cQZqusJc3V1s/OeVTuA/PQY0D
# 2b4RVTA6lOOli2FZGLKTpuZVWTOR7UL8106eVxYVGcj7dwsXd1TNMIIGyTCCBLGg
# AwIBAgITMwAAH/RfCPXU1pd4tAAAAAAf9DANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDA0MB4XDTI2MDQwOTE0
# MzQxNFoXDTI2MDQxMjE0MzQxNFowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAsf4Pvl7ZySu6xNCnWo3KKJSQaAw33UaZkDQvfxswNB1fTheyahkc8nrTnbxc
# LqHkrP1k8kgzei31JUUoTK8arYUgZ8Sos61ekMCLIU/EfA4TZatxpRsqGqM0LBUf
# KlHVXeRxoxLl4HmtXXFBBChThDhr3lAiaDYqGbAqSz6is/JKkCgynnVF7eARDqtG
# SMfLuFVjlHf/GvPgR4UQJqmdjJ3jWM+TN0fKY0PyzoC1mYuBy8qr1UVhPm5WAdV+
# LH+LGer2PljIHoNSBdJESant8/IVdLCUP2fHX/Kt6rSsAk8FuvT9o83VuWL7+jDo
# Gnd90ABOhVonHLsZXrf2/uD3I9jqtBMLMYvBF5YNktPPZ+vel/BHqTLznQ6netZw
# OwDWNzQvVLmDmywAUWxfjfnKPlJfiQr2OSAsUZSwofl/hMkUNlbdZuc5VLq9sG0G
# avo5F5cQeVQN+d96CeXiBb1M4D6a+lbT82OKxgMlQMSF6xuD+5+9y14OS/2m/jZs
# e46lAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFOA+03ZzbGgCsTjhnKdWJuiZUSgQMB8GA1Ud
# IwQYMBaAFJrxVHd1DIcWN0agrN55+fR/wXjpMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDA0LmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQAUBM0tSViEGqCIbP22qNfs4Tj9nTpYL/1z4x/+
# acACtqFCZjDr67dlYlxlzRhOI+RNtb47br6RNGrZKal8faxK5Je6bBU1r129s92D
# Zc4Y7rxaCuYVF57mCvRgJrXdWbUyVUoJylujSshS8Cxxgn0J5ebdF3LGzofICRJf
# 4gWQX27Fr5xzVMBfKy+GQnFwEDA2hBVJcjmjKhRbv6IB3OZ+WdZV5MfCYaOSpJON
# WrQQjJv0GV+RwGUTjnhKcnOeXc6c5Rh6NmbrP/jgqOoHRQQk4Hucpj5770MAmaYX
# 85mTCiHayD4Cd1o/KfHsau3VUxXRv/g7BmXskbxlJdZ6FGHxSBGIzjROgOK88brd
# f/yLZLR5YMZcDYcHSKlt0MngIayd+serSDKv5Ygk2MV7J5nOQhY+3TefN5AeX0fA
# bBW8IgGtWl94W6yXl1teLisTy1t7WC7BNIqBnCydpKqdO4RoS32V7Qtk0yzH9IWu
# sRRkbfB3Fgf8dWMAtF48ZNGvG3MOAP68va9c4HVIhqioqbkjRikl+YPSPPwtt3nj
# HA0ruY0Htrp+gnhWHoixcLl9rKNJjqVhaT0cbhBsebINw1fHZpBrLq6/nEGarrCX
# N1dbPznlU7gPz0GNA9m+EVUwOpTjpYthWRiyk6bmVVkzke1C/NdOnlcWFRnI+3cL
# F3dUzTCCBygwggUQoAMCAQICEzMAAAAXJ0UJC4uHr8YAAAAAABcwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMzFaFw0zMTAzMjYxODExMzFaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCCx2T+Aw9mKgGVzJ+Tq0PMn49G3itIsYpb
# x7ClLSRHFe1RELdPcZ1sIqWOhsSfy6yyqEapClGH9Je9FXA1cQgZvvpQbkg+QInV
# Lr/0EPrVBCwrM96lbRI2PxNeCwXG9LsyW2hG6KQgintDmNCBo4zpDIr377plVdSl
# iZm6UB7rHwmvBnR02QT6tnrqWq2ihzB6lRJVTEzuh0OafzIMeMnYM0+x+ve5EOLH
# dfiq+HXiMf9Jb7YLHtYgyHIiJA7bTWLqFSLGaTh7ZlbxbsLXA91OOroEpv7OjzFu
# u3tkpC9FflA4Dp2Euq4+qPmxUqfGp+TX0gLRJp9NJOzzILjcTD3rkFFFbxUv1xyg
# 6avivFDLtoKBhM2Td138umE1pNOacanuSYtPHIeQHmB6haFi64avLBLwTTAm/Rbi
# t860cFXR72wq+5Qh4hSmezHqKXERWPpVBe+APrJ4Iqc+aPeMmIkoCWZQO22HnLNF
# UFSXjiwyIbgvlH/LIAJEqTafTzxDZgKhlLU7zr6gwsq3WNpcYQI6NuxWnwh3VVDD
# yF7onQqKs5Ll7bleVN0Y8VvqgE45ppyBbvwqN/Run5fMCCRz3aYMY0kZhKO92eP7
# t4zHqZ5bQMAgZ0tE2Pz/jb0wiykUF/PcoOqqk3vVLiRDYst6vd3GEMNzMpUUvQcv
# BG46+COIbwIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBSa8VR3dQyHFjdGoKzeefn0f8F46TBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQCQdVoZ/U0m38l2iKaZFlsx
# avptpoOLyaR1a9ZK2TSF1kOnFJhMDse6KkCgsveoiEjXTVc6Xt86IKHn76Nk5qZB
# 0BXv2iMRQ2giAJmYvZcmstoZqfB2M3Kd5wnJhUJOtF/b6HsqSelY6nhrF06zor1l
# DmDQixBZcLB9zR1+RKQso1jekNxYuUk+HaN3k1S57qk0O//YbkwU0mELCW04N5vI
# CMZx5T5c7Nq/7uLvbVhCdD7f2bZpA4U7vOkB1ooB4AaER3pjoJ0Mad5LFyi6Na9p
# 9Zu/hrLeOjU5FItS5YxsqvlfXxAThJ176CmkYstKRmytSHZ7JhKRfV6e9Zftk/OD
# b/CK4pGVAVqsOf4337bQGrOHHCQ3IvN9gmnUuDh8JdvbheoWPHxIN1GB5sUiY584
# tXN7xdD8LCSsRqJvQ8e7a3gZWTgViugRs1QWq+N0G9Nje6JHlN1CjJehge+H5PGk
# tJja+juGEr0P+ukSkcL6qaZxFQTh3SDI71lvW++3bl/Ezd6SO8N9Udw+reoyvRHC
# yTiSsplZQSBTVJdPmo3qCpGuyHFtPo5CBn3/FPTiqJd3M9BHoqKd0G9Kmg6fGcAv
# FwnLNXA2kov727wRljL3ypfqL7iAT/Ynpxul6RwHRlcOf9dDGg1RRvr92NP/CWVX
# Ib68geR2rvU/NsfmtjF1wDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
# AAcwDQYJKoZIhvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZl
# cmlmaWNhdGlvbiBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIx
# MDQwMTIwMDUyMFoXDTM2MDQwMTIwMTUyMFowYzELMAkGA1UEBhMCVVMxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElE
# IFZlcmlmaWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALLwwK8ZiCji3VR6TElsaQhVCbRS/3pK+MHrJSj3Zxd3
# KU3rlfL3qrZilYKJNqztA9OQacr1AwoNcHbKBLbsQAhBnIB34zxf52bDpIO3NJlf
# IaTE/xrweLoQ71lzCHkD7A4As1Bs076Iu+mA6cQzsYYH/Cbl1icwQ6C65rU4V9NQ
# hNUwgrx9rGQ//h890Q8JdjLLw0nV+ayQ2Fbkd242o9kH82RZsH3HEyqjAB5a8+Ae
# 2nPIPc8sZU6ZE7iRrRZywRmrKDp5+TcmJX9MRff241UaOBs4NmHOyke8oU1TYrkx
# h+YeHgfWo5tTgkoSMoayqoDpHOLJs+qG8Tvh8SnifW2Jj3+ii11TS8/FGngEaNAW
# rbyfNrC69oKpRQXY9bGH6jn9NEJv9weFxhTwyvx9OJLXmRGbAUXN1U9nf4lXezky
# 6Uh/cgjkVd6CGUAf0K+Jw+GE/5VpIVbcNr9rNE50Sbmy/4RTCEGvOq3GhjITbCa4
# crCzTTHgYYjHs1NbOc6brH+eKpWLtr+bGecy9CrwQyx7S/BfYJ+ozst7+yZtG2wR
# 461uckFu0t+gCwLdN0A6cFtSRtR8bvxVFyWwTtgMMFRuBa3vmUOTnfKLsLefRaQc
# VTgRnzeLzdpt32cdYKp+dhr2ogc+qM6K4CBI5/j4VFyC4QFeUP2YAidLtvpXRRo3
# AgMBAAGjggI1MIICMTAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAw
# HQYDVR0OBBYEFNlBKbAPD2Ns72nX9c0pnqRIajDmMFQGA1UdIARNMEswSQYEVR0g
# ADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L0RvY3MvUmVwb3NpdG9yeS5odG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2io
# ojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBS
# b290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBwwYIKwYB
# BQUHAQEEgbYwgbMwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0
# aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQw
# LQYIKwYBBQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20vb2NzcDAN
# BgkqhkiG9w0BAQwFAAOCAgEAfyUqnv7Uq+rdZgrbVyNMul5skONbhls5fccPlmIb
# zi+OwVdPQ4H55v7VOInnmezQEeW4LqK0wja+fBznANbXLB0KrdMCbHQpbLvG6UA/
# Xv2pfpVIE1CRFfNF4XKO8XYEa3oW8oVH+KZHgIQRIwAbyFKQ9iyj4aOWeAzwk+f9
# E5StNp5T8FG7/VEURIVWArbAzPt9ThVN3w1fAZkF7+YU9kbq1bCR2YD+MtunSQ1R
# ft6XG7b4e0ejRA7mB2IoX5hNh3UEauY0byxNRG+fT2MCEhQl9g2i2fs6VOG19CNe
# p7SquKaBjhWmirYyANb0RJSLWjinMLXNOAga10n8i9jqeprzSMU5ODmrMCJE12xS
# /NWShg/tuLjAsKP6SzYZ+1Ry358ZTFcx0FS/mx2vSoU8s8HRvy+rnXqyUJ9HBqS0
# DErVLjQwK8VtsBdekBmdTbQVoCgPCqr+PDPB3xajYnzevs7eidBsM71PINK2BoE2
# UfMwxCCX3mccFgx6UsQeRSdVVVNSyALQe6PT12418xon2iDGE81OGCreLzDcMAZn
# rUAx4XQLUz6ZTl65yPUiOh3k7Yww94lDf+8oG2oZmDh5O1Qe38E+M3vhKwmzIeoB
# 1dVLlz4i3IpaDcR+iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFI
# rmcxghqUMIIakAIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDQCEzMAAB/0Xwj11NaXeLQAAAAAH/QwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgUh7hDErGH2AYyHXq+sZOMgTNTYRruRe63lJkxsV4Dzkw
# DQYJKoZIhvcNAQEBBQAEggGAQUm5AKvbhcxmR5b+LeBUbInmX6fA6zlio00p4mgc
# 1PPuSKSG05BydbWqIYOPouVQAZZyi1Vs4X4O4xo+wYtpFwi0/GuwhZMxD2Z/+nKj
# PkxOQCk9c5f8RCiJRrNKf3pN0wUuXR6DahBF5tbg0sxroEOE0DQSaC24mnNW+M7o
# 7k3YnW00xDL0fok2RNd85Mp5dGnTk0U6hLho1VUd1+WuDDP4Pb6OyW8fVM03rKCc
# N7EJhS9vU8Hf9AZ5SY/IX1Gg6fob2L53q1lNyKarhWq+li1Maj+YncDkkrMapJTM
# q9p+/NXIVzypNBXKkl9jAu09TOS4xk7YyUw3SEvPwMMwFuE/Umk2/m16LqgDxByC
# wPS68eFBrlFNyW6cf+7cLJGUCZiozh0zV6K/O6NtC45Vn5yE4fiFHoObGgA0FQja
# l5NRzIvYDJKJ3EzxgdbqbblK1WUyc1ZA47k71x+HoNYyttd1B6rwANTTY8moUK8U
# dzkBIVC2gado6A5FUJ/hN8fDoYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJ
# KoZIhvcNAQcCoIIX7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIM7DKmZuVShwJqREN7/yRaFRuDiXjcFt4jmvYKxyC743AgZpwmak5DEYEzIw
# MjYwNDEwMDY0NjQyLjk3MlowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAt
# RDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGlu
# ZyBBdXRob3JpdHmggg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAA
# BTANBgkqhkiG9w0BAQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVy
# aWZpY2F0aW9uIFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAx
# MTE5MjAzMjMxWhcNMzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBv
# f7KrQ5cMSqFSHGqg2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDs
# fMuIEqvGYOPURAH+Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbB
# T7uq3wx3mXhtVmtcCEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5
# EeH5KrlFnxpjKKTavwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6
# ovnUfANjIgM9JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fj
# JHrmlQ0EIXmp4DhDBieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOs
# RpeexIveR1MPTVf7gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiun
# hKbq0XbjkNoU5JhtYUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE
# 3oWsDqMX3jjv40e8KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8
# cIxLoKSDzCCBOu0hWdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMB
# AAGjggIbMIICFzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYD
# VR0OBBYEFGtpKDo1L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBB
# MD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0Rv
# Y3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGC
# NxQCBAweCgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTI
# ftJqhSobyhmYBAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHkl
# MjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHkl
# MjAyMDIwLmNybDCBlAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElk
# ZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0
# aG9yaXR5JTIwMjAyMC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXn
# THho+k7h2ESZJRWluLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC
# 2IWmtKMyS1OWIviwpnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5
# zyEh89F72u9UIw+IfvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbN
# nCKNZPmhzoa8PccOiQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqs
# t8S+w+RUdie8fXC1jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVm
# oNR/dSpRCxlot0i79dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRS
# SvijmwJwxRxLLpMQ/u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7v
# PKNMN+SZDWycU5ODIRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/2
# 6ozePQ/TWfNXKBOmkFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/
# AAxw9Sdgq/+rY7jjgs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSO
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFZ+j51YCI7p
# YAAAAAAAVjANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTFaFw0yNjEw
# MjIyMDQ2NTFaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtKWfm/ul027/d8Rlb8Mn/g0QUvvLqY2V
# sy3tI8U2tFSspTZomZOD3BHT8LkR+RrhMJgb1VjAKFNysaK9cLSXifPGSIBrPCgs
# 9P4y24lrJEmrV6Q5z4BmqMhIPrZhEvZnWpCS4HO7jYSei/nxmC7/1Er+l5Lg3PmS
# xb8d2IVcARxSw1B4mxB6XI0nkel9wa1dYb2wfGpofraFmxZOxT9eNht4LH0RBSVu
# eba6ZNpjS/0gtfm7qiIiyP6p6PRzTTbMnVqsHnV/d/rW0zHx+Q+QNZ5wUqKmTZJB
# 9hU853+2pX5rDfK32uNY9/WBOAmzbqgpEdQkbiMavUMyUDShmycIvgHdQnS207sT
# j8M+kJL3tOdahPuPqMwsaCCgdfwwQx0O9TKe7FSvbAEYs1AnldCl/KHGZCOVvUNq
# jyL10JLe0/+GD9/ynqXGWFpXOjaunvZ/cKROhjN4M5e6xx0b2miqcPii4/ii2Zhe
# KallJET7CKlpFShs3wyg6F/fojQxQvPnbWD4Nyx6lhjWjwmoLcx6w1FSCtavLCly
# 33BLRSlTU4qKUxaa8d7YN7Eqpn9XO0SY0umOvKFXrWH7rxl+9iaicitdnTTksAnR
# jvekdKT3lg7lRMfmfZU8vXNiN0UYJzT9EjqjRm0uN/h0oXxPhNfPYqeFbyPXGGxz
# aYUz6zx3qTcCAwEAAaOCAcswggHHMB0GA1UdDgQWBBS+tjPyu6tZ/h5GsyLvyz1H
# +FNIWjAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAA4DqAXEsO26j/La7Fgn/Qifit8xuZekqZ57+Ye+sH/h
# RTbEEjGYrZgsqwR/lUUfKCFpbZF8msaZPQJOR4YYUEU8XyjLrn8Y1jCSmoxh9l7t
# WiSoc/JFBw356JAmzGGxeBA2EWSxRuTr1AuZe6nYaN8/wtFkiHcs8gMadxXBs6Dx
# Vhyu5YnhLPQkfumKm3lFftwE7pieV7f1lskmlgsC6AeSGCzGPZUgCvcH5Tv/Qe9z
# 7bIImSD3SuzhOIwaP+eKQTYf67TifyJKkWQSdGfTA6Kcu41k8LB6oPK+MLk1jbxx
# K5wPqLSL62xjK04SBXHEJSEnsFt0zxWkxP/lgej1DxqUnmrYEdkxvzKSHIAqFWSZ
# ul/5hI+vJxvFPhsNQBEk4cSulDkJQpcdVi/gmf/mHFOYhDBjsa15s4L+2sBil3XV
# /T8RiR66Q8xYvTLRWxd2dVsrOoCwnsU4WIeiC0JinCv1WLHEh7Qyzr9RSr4kKJLW
# dpNYLhgjkojTmEkAjFO774t3xB7enbvIF0GOsV19xnCUzq9EGKyt0gMuaphKlNjJ
# +aTpjWMZDGo+GOKsnp93Hmftml0Syp3F9+M3y+y6WJGUZoIZJq227jDjjEndtpUr
# h9BdPdVIfVJD/Au81Rzh05UHAivorQ3Os8PELHIgiOd9TWzbdgmGzcILt/ddVQER
# MYIHRjCCB0ICAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjANBglghkgBZQME
# AgEFAKCCBJ8wEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDEwMDY0NjQyWjAvBgkqhkiG9w0B
# CQQxIgQg3jFGomh3DZpsRzPamKUFR8VyuwI8BChX7UFYm5PhyBswgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCC2DDMlTaTj8JV3iTg5Xnpe4CSH60143Z+X9o5N
# BgMMqDB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjCCA2EGCyqGSIb3DQEJ
# EAISMYIDUDCCA0yhggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD/c/cpFSqQWYBeXggy
# RJ2ZbvYEEaBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2Cpa8wIhgPMjAyNjA0
# MDkyMjI0NDdaGA8yMDI2MDQxMDIyMjQ0N1owdzA9BgorBgEEAYRZCgQBMS8wLTAK
# AgUA7YKlrwIBADAKAgEAAgILCAIB/zAHAgEAAgISmDAKAgUA7YP3LwIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQAqxGj23r7t+Cug2UPyVkKpnNkRpSQ/rbQM
# 4KpWKVOpEFXfJpq/EfnaESOnILbcxONmJ1bGOgfrdVCtZFw/hLr858AkZfnqRDme
# OWAw/nbRC1TcYoomX0mEfC9rK006SK6TOK1dJcjdngxNus6c5XDcig9OUxlQH17m
# FlSLTFaVxQMj/aKtwN/9ongoG7Prq+gpvm3XjJAcgdN8fZuL5HeSLjHgomGgXI/R
# sKrpl1JCLKCkFFKRKF2ZWA/f7R/6sytrzbg8eiZZfDHGiChfc3xtJPRXDxQunHTT
# uYgLiqEAa0hSYdujQqOZt4qV41cr1c6VgpNMIXo4wiyFCPJdCKf5MA0GCSqGSIb3
# DQEBAQUABIICAG8bR4DWCr6DgiQ1kN9RiFubZVEV1/9umpAVSgp08+2Pfz9LoynB
# FJBFlf2g6ER+b8H5hKbcSfECvQTIHoY01HJd+VTX8jWAOgSFE8l5YZz1tCk9ZTns
# NtaYRBcGfmkcrqhOdnO02BG+dlaksEFi8c1HfX+jVH+5GQ6PZYez+pSvNiCzYWb/
# Lh18ZBbzYURiWXhdBRyYeL2DvWIAxht20ULC2kzvhl2bhN8XXkT6X9/rbeUgOKAn
# nBQs6z+aiHIDRxdoSaeut05PR5ZorAMp5oYgNmq8vtaqS1XqcboGuZaE/q/m+Jyt
# xAI7jrwOCzZXJdecE2Qx7fWZ9vagKIIn4YaFz+XlTRvVZvG6ibaUSwXAFoZZi3aD
# L2no2k8hkS1U6LnxxDpmtKJCBgIOuJgh8NC9b8uRZ2ho/JaQ+JuDSMQbhU3ZViQp
# 4ZuziV9kcWTDPTgbt/MlVMJvcSyF8mHPfbaJb8UAE+X6VZpSaCOVuhkrgyU1MFAA
# Yr5+6CN6XA3eyHqiSkDo4IkJdDJdeuHq/S3GJ0Zia/Tm1ymFn7DcmDLj/YMFdrjf
# g7avRCiydxcTIKH3/ylHd9smfDOf1jgYVsHnyYQxN/5QR8IwCeD/xn7kLqjvWKQL
# OlAyziM/xjN4hOmeQ8PVQc9T2BC9DUMPfjVSL6gioj9upwsAhvWQz49W
# SIG # End signature block

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
Set-NovaLogPrefix -Step "`n[Nova]" -Success '[OK]' -Warn '[WARN]' -Fail '[FAIL]' -Info '[Nova]' -Detail '[Nova]'

# ── Nova file logging ───────────────────────────────────────────────────────
# Start structured file logging alongside the existing Start-Transcript.
# The Nova log captures timestamped, level-tagged entries that are easier to
# parse than raw transcript output.
Start-NovaLog -Path 'X:\Nova-Detailed.log'

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
    Write-Info "Source : $Uri"
    Write-Info "Target : $OutFile"

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
                Write-Info "Resuming from $(Get-FileSizeReadable $existingSize)..."
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
    # Bootstrap.ps1 UI shows four progress steps (Initialize / Network /
    # Authenticate / Deploy).  During the deploy phase all four indicators
    # should stay lit, so always report Step 4 to keep the first three
    # steps highlighted.
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
                Write-Detail "Auto-selected target disk: $disk"
            }
            $drv  = if ($p -and $p.PSObject.Properties['osDriveLetter'] -and $p.osDriveLetter) { $p.osDriveLetter } else { $CurrentOSDrive }
            $createRecovery = if ($p -and $p.PSObject.Properties['createRecoveryPartition'] -and $p.createRecoveryPartition) { $true } else { $false }
            $recoverySize = if ($p -and $p.PSObject.Properties['recoveryPartitionSize'] -and $p.recoveryPartitionSize -gt 0) { [long]$p.recoveryPartitionSize } else { 990MB }
            Write-Data -Label 'Partition Configuration' -Data @{
                DiskNumber      = "$disk"
                FirmwareType    = $CurrentFirmwareType
                OSDriveLetter   = $drv
                RecoveryPartition = "$createRecovery"
                RecoverySize    = "$(Get-FileSizeReadable $recoverySize)"
            }
            Update-BootstrapStatus -Message "Partitioning disk..." -Detail "Creating layout on disk $disk" -Step $uiStep -Progress $pct
            Initialize-TargetDisk -DiskNumber $disk -FirmwareType $CurrentFirmwareType -OSDriveLetter $drv `
                -CreateRecoveryPartition:$createRecovery -RecoveryPartitionSize $recoverySize -Confirm:$false
        }
        'ImportAutopilot' {
            $tag   = if ($p -and $p.PSObject.Properties['groupTag']  -and $p.groupTag)  { $p.groupTag }  else { '' }
            $email = if ($p -and $p.PSObject.Properties['userEmail'] -and $p.userEmail) { $p.userEmail } else { '' }
            Write-Info "Autopilot import -- GroupTag: '$tag', UserEmail: '$email'"
            Update-BootstrapStatus -Message "Importing Autopilot device..." -Detail "Registering device in Windows Autopilot" -Step $uiStep -Progress $pct
            Invoke-AutopilotImport -GroupTag $tag -UserEmail $email
        }
        'DownloadImage' {
            $url  = if ($p -and $p.PSObject.Properties['imageUrl']      -and $p.imageUrl)      { $p.imageUrl }      else { '' }
            $ed   = if ($p -and $p.PSObject.Properties['edition']       -and $p.edition)       { $p.edition }       else { 'Professional' }
            $lang = if ($p -and $p.PSObject.Properties['language']      -and $p.language)      { $p.language }      else { 'en-us' }
            $arch = if ($p -and $p.PSObject.Properties['architecture']  -and $p.architecture)  { $p.architecture }  else { 'x64' }
            Write-Data -Label 'Image Download' -Data @{
                Edition      = $ed
                Language     = $lang
                Architecture = $arch
                ImageUrl     = $(if ($url) { $url } else { '(auto-detect ESD)' })
            }
            Update-BootstrapStatus -Message "Downloading Windows image..." -Detail "Fetching $ed $lang $arch" -Step $uiStep -Progress $pct
            $script:TsImagePath = Get-WindowsImageSource `
                -ImageUrl $url -Edition $ed -Language $lang -Architecture $arch `
                -FirmwareType $CurrentFirmwareType -ScratchDir $CurrentScratchDir `
                -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch `
                -DownloadCommand $dlCmd
            Write-Info "Image resolved: $($script:TsImagePath)"
        }
        'ApplyImage' {
            $ed   = if ($p -and $p.PSObject.Properties['edition']       -and $p.edition)       { $p.edition }       else { 'Professional' }
            $lang = if ($p -and $p.PSObject.Properties['language']      -and $p.language)      { $p.language }      else { 'en-us' }
            $arch = if ($p -and $p.PSObject.Properties['architecture']  -and $p.architecture)  { $p.architecture }  else { 'x64' }
            if (-not $script:TsImagePath) {
                $url = if ($p -and $p.PSObject.Properties['imageUrl'] -and $p.imageUrl) { $p.imageUrl } else { '' }
                Write-Info "No cached image path -- downloading image for ApplyImage step"
                Update-BootstrapStatus -Message "Downloading Windows image..." -Detail "Fetching $ed $lang $arch" -Step $uiStep -Progress $pct
                $script:TsImagePath = Get-WindowsImageSource `
                    -ImageUrl $url -Edition $ed -Language $lang -Architecture $arch `
                    -FirmwareType $CurrentFirmwareType -ScratchDir $CurrentScratchDir `
                    -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch `
                    -DownloadCommand $dlCmd
            }
            Write-Info "Applying image: $($script:TsImagePath) (edition: $ed)"
            Update-BootstrapStatus -Message "Applying Windows image..." -Detail "Expanding Windows files" -Step $uiStep -Progress $pct
            Install-WindowsImage -ImagePath $script:TsImagePath -Edition $ed -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'SetBootloader' {
            Write-Info "Configuring bootloader: $CurrentFirmwareType on disk $CurrentDiskNumber"
            Update-BootstrapStatus -Message "Configuring bootloader..." -Detail "Writing BCD store" -Step $uiStep -Progress $pct
            Set-Bootloader -OSDriveLetter $CurrentOSDrive -FirmwareType $CurrentFirmwareType -DiskNumber $CurrentDiskNumber
        }
        'InjectDrivers' {
            $dp = if ($p -and $p.PSObject.Properties['driverPath'] -and $p.driverPath) { $p.driverPath } else { '' }
            Write-Info "Driver path: $(if ($dp) { $dp } else { '(none specified)' })"
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

Write-Section 'Nova Imaging Engine Initializing'
Write-Data -Label 'Engine Configuration' -Data @{
    GitHubUser    = $GitHubUser
    GitHubRepo    = $GitHubRepo
    GitHubBranch  = $GitHubBranch
    FirmwareType  = $FirmwareType
    TargetDisk    = $TargetDiskNumber
    OSDrive       = $OSDrive
    ScratchDir    = $ScratchDir
    TaskSequence  = $TaskSequencePath
    DryRun        = "$DryRun"
    ModulesRoot   = $script:ModulesRoot
}
Write-Detail "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Detail "Computer name: $($env:COMPUTERNAME)"
Write-Detail "OS: $([System.Environment]::OSVersion.VersionString)"

$stepName = ''
$script:DeploymentStartTime = Get-Date
$script:CompletedStepCount  = 0
try {

    # ── Task-sequence-driven execution ──────────────────────────────
    # Read the step list from the JSON task sequence file and execute
    # each enabled step in the order defined by the editor.
    $ts = Read-TaskSequence -Path $TaskSequencePath
    Write-Info "Task sequence loaded: $($ts.name)"
    Write-Detail "Schema version: $(if ($ts.PSObject.Properties['schemaVersion']) { $ts.schemaVersion } else { '1.0' })"

    if ($DryRun) {
        Invoke-DryRunValidation -TaskSequence $ts -ScratchDir $ScratchDir -OSDrive $OSDrive -FirmwareType $FirmwareType -DiskNumber $TargetDiskNumber
        Write-Step 'DRY RUN complete -- no destructive operations performed.'
        return
    }

    Write-Step "Firmware type: $FirmwareType"
    New-ScratchDirectory -Path $ScratchDir

    $enabledSteps = @($ts.steps | Where-Object { $_.enabled -ne $false })
    $disabledCount = @($ts.steps | Where-Object { $_.enabled -eq $false }).Count
    Write-Section "Task Sequence Execution"
    Write-Step "Executing $($enabledSteps.Count) enabled steps ($disabledCount disabled/skipped)"

    # Inter-step state: DownloadImage stores the resolved image path for
    # ApplyImage to consume.  ComputerName and locale settings are synced
    # into unattendContent by the Editor and Bootstrap config modal -- the
    # engine just writes what's in the task sequence.
    $script:TsImagePath = ''
    $tsName = if ($ts.name) { $ts.name } else { 'Unknown' }

    for ($i = 0; $i -lt $enabledSteps.Count; $i++) {
        $s = $enabledSteps[$i]
        $stepName = $s.name
        $stepStartTime = Get-Date

        # Evaluate step condition (if any) before execution
        if ($s.PSObject.Properties['condition'] -and $s.condition -and $s.condition.type) {
            Write-Detail "Evaluating condition for step '$($s.name)': type=$($s.condition.type)"
            if (-not (Test-StepCondition -Condition $s.condition)) {
                Write-Step "[$($i+1)/$($enabledSteps.Count)] $($s.name) ($($s.type)) -- condition not met, skipping"
                continue
            }
        }

        Write-Step "[$($i+1)/$($enabledSteps.Count)] $($s.name) ($($s.type))"
        Write-Detail "Step parameters: $(if ($s.parameters) { ($s.parameters | ConvertTo-Json -Compress -Depth 3) } else { 'none' })"
        if ($s.PSObject.Properties['continueOnError'] -and $s.continueOnError) {
            Write-Detail "continueOnError is enabled for this step"
        }

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
            Write-Detail "Non-blocking: active deployment report update failed for step '$($s.name)': $_"
        }

        # After PartitionDisk, redirect scratch to OS drive
        if ($s.type -eq 'PartitionDisk') {
            Invoke-TaskSequenceStep -Step $s -Index ($i+1) -TotalSteps $enabledSteps.Count `
                -CurrentScratchDir $ScratchDir `
                -CurrentOSDrive $OSDrive -CurrentFirmwareType $FirmwareType `
                -CurrentDiskNumber $TargetDiskNumber
            $ScratchDir = Join-Path "${OSDrive}:" 'Nova'
            New-ScratchDirectory -Path $ScratchDir
            Write-Detail "Scratch directory redirected to OS drive: $ScratchDir"
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
        $stepDuration = (Get-Date) - $stepStartTime
        Write-Info "Step '$($s.name)' completed in $([math]::Round($stepDuration.TotalSeconds, 1))s"
        $script:CompletedStepCount = $i + 1
    }

    # ── Deployment reporting & alerting ─────────────────────────────
    Write-Section 'Deployment Complete'
    $elapsed   = (Get-Date) - $script:DeploymentStartTime
    $durString = '{0}m {1}s' -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
    Write-Data -Label 'Deployment Summary' -Data @{
        Status         = 'Success'
        TaskSequence   = $tsName
        StepsCompleted = "$($enabledSteps.Count) / $($enabledSteps.Count)"
        Duration       = $durString
        ComputerName   = "$($env:COMPUTERNAME)"
        OSDrive        = "${OSDrive}:"
    }

    # Clear active deployment file -- device is no longer deploying
    try { Update-ActiveDeploymentReport -Clear -ScratchDir $ScratchDir -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch }
    catch { Write-Detail "Non-blocking: failed to clear active deployment report for '$($env:COMPUTERNAME)': $_" }

    Save-DeploymentReport -Status 'success' -TaskSequence $tsName `
        -StepsCompleted $enabledSteps.Count -StepsTotal $enabledSteps.Count `
        -StartTime $script:DeploymentStartTime `
        -ScratchDir $ScratchDir `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
    Write-Detail 'Deployment report saved'

    # Record asset inventory for fleet tracking
    Save-AssetInventory -TaskSequence $tsName -ComputerName $env:COMPUTERNAME -ReportDir $ScratchDir `
        -ScratchDir $ScratchDir `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
    Write-Detail 'Asset inventory recorded'

    Send-DeploymentAlert -Status 'success' -TaskSequence $tsName `
        -Duration $durString `
        -StepsCompleted $enabledSteps.Count -StepsTotal $enabledSteps.Count `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
    Write-Detail 'Deployment alert sent'

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

    # Finalize Nova file logging before exporting logs to OS drive
    Stop-NovaLog

    # Export WinPE logs to OS drive for post-reboot troubleshooting
    Export-DeploymentLogs -OSDriveLetter $OSDrive -EngineLogPath $script:EngineLogPath

    $stepName = 'Reboot'
    Start-Sleep -Seconds 15
    Restart-Computer -Force

} catch {
    Write-Section 'Deployment Failed'
    Write-Fail "Nova imaging failed at step '$stepName': $_"
    Write-Detail "Stack trace: $($_.ScriptStackTrace)"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ''

    # ── Failure reporting & alerting ────────────────────────────────
    $tsName    = if ($ts -and $ts.name) { $ts.name } else { 'Unknown' }
    $totalSteps = if ($enabledSteps) { $enabledSteps.Count } else { 0 }
    $elapsed   = (Get-Date) - $script:DeploymentStartTime
    $durString = '{0}m {1}s' -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

    Write-Data -Label 'Failure Details' -Data @{
        Status         = 'Failed'
        TaskSequence   = $tsName
        FailedStep     = $stepName
        StepsCompleted = "$($script:CompletedStepCount) / $totalSteps"
        Duration       = $durString
        Error          = "$_"
    }

    # Clear active deployment file -- device is no longer deploying
    try { Update-ActiveDeploymentReport -Clear -ScratchDir $ScratchDir -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch }
    catch { Write-Detail "Non-blocking: failed to clear active deployment report for '$($env:COMPUTERNAME)': $_" }

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

    # Finalize Nova file logging before exporting
    Stop-NovaLog

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
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCadnvemd89mLMl
# DrxKsfeASU9CUbqsWCItLV6mkRcvyKCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAALJYmh
# eTfl9V9mAAAAAAslMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNDEwMTQzMzI1WhcNMjYwNDEz
# MTQzMzI1WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCoRt7KuvVHrwTk
# RDxoLt3Hu8hKXs8FpKttF7I7rMUvoYB6Y8iYaGvLFDQ1XudogJ2G/5xLA4IUT3rF
# ZDdCX/bIAjAIa+7Iv12SrHm/mUWBb9JWn20ds6oPmi1lVVd2Dk3mLHJ3qWaRR7I0
# qAfT/xJ0JsSBNW6RnhKw1U+TFyrevOJHa870enc+hsCT+OOHIeq4EsOchVNFqRNw
# 7AAIj7Iq7mcOXxhYVVdLiyGGjAO7EMJDzZHJ+2DKwZKH1HdONN9NqRZ5xV9E5IU4
# 7r+iqpYwSseLtx+dzcFAFfomAWcZEmceAOTvFjTQBFe4VX+wkM8P70cfZRyE746F
# AuScjqIPo/Zny1YYmfJM/E4LPNLnROUr24nBQkhMQhBD8zWLzh5AmmzerkSnLEma
# 63OATiMxIY/aWc505QcYC/UmZK3uC2rLm7PWY5Vmaze9vuIwJjn1aNLe6lwSw8Qr
# pBOToDPpzuOySz5s0G0XowEDlsBlPov3nm5FgT3Z1zI933hy1PMCAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUyhxTM5EWAZIW8X59xk6mx808hZkwHwYDVR0jBBgwFoAUayVB3vtr
# fP0YgAotf492XapzPbgwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwQU9DJTIwQ0ElMjAwNC5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEFPQyUyMENBJTIwMDQuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAMRVo79ZYMctxbTncnYSUA+xTwTu2ZXwBOtnPsIzY746k/oBWm+ShFPX
# OE8RnWYCVr2vMWGzdgIfC3aS08P/D9kjxPYJpahD0kPKvlHVGiSNk87I+j5ljG7j
# 0a8IEi9vaMNrR0aJKKhjSqqkUpVyGYH8AZJ/TUYoGgkGbtMvqjXLHu5MS/CBvqlb
# CeQ0f3xmqzpa74NkQ06dE48j5UWaqOHfd8+v8BBkxwkdZbujVtA8EZq6SGZEo8Uz
# IYJhfzxiiYqpTTmr5JjfA/A4WryMPdY1ErcLEIvtADLp2RYZ5aPDT3DXbuLcdMvt
# L1mAsFm1tTL6F9h9EPMmUcZX+dbKiNkBkL/ghV4cC7t91t/n8mFm4L/46yqmH0uj
# fAYZRAwn7Z26mWxYe/cHrskWS6nvh8atFM7kqiD63NUJiq3LjQAp+1rmJBvVi4JE
# u8LqC88D8mxN+6Ru8zcFIj7chzlKEpwD3NAKGo0I0F4o6IisMJne5dpzSm1KXpH2
# 3Ul1nSK/P92dMA+3AnFyA/BAv+jxf9YTkV1VlMFYEZ9ROsxI/y1hYGWqv6qcsOIP
# yw9cWOfiT/0Bqwdk+pIPFrW2k0pI3Zmi8zozD0FMfLpuT924KRwqSmSM3qk4VSep
# kXUtC2b/Ar71yJUTBX/63+kyCSMciAsQe/u4NPkwcljbJ6jmeB50MIIGyTCCBLGg
# AwIBAgITMwAACyWJoXk35fVfZgAAAAALJTANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDA0MB4XDTI2MDQxMDE0
# MzMyNVoXDTI2MDQxMzE0MzMyNVowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAqEbeyrr1R68E5EQ8aC7dx7vISl7PBaSrbReyO6zFL6GAemPImGhryxQ0NV7n
# aICdhv+cSwOCFE96xWQ3Ql/2yAIwCGvuyL9dkqx5v5lFgW/SVp9tHbOqD5otZVVX
# dg5N5ixyd6lmkUeyNKgH0/8SdCbEgTVukZ4SsNVPkxcq3rziR2vO9Hp3PobAk/jj
# hyHquBLDnIVTRakTcOwACI+yKu5nDl8YWFVXS4shhowDuxDCQ82RyftgysGSh9R3
# TjTfTakWecVfROSFOO6/oqqWMErHi7cfnc3BQBX6JgFnGRJnHgDk7xY00ARXuFV/
# sJDPD+9HH2UchO+OhQLknI6iD6P2Z8tWGJnyTPxOCzzS50TlK9uJwUJITEIQQ/M1
# i84eQJps3q5EpyxJmutzgE4jMSGP2lnOdOUHGAv1JmSt7gtqy5uz1mOVZms3vb7i
# MCY59WjS3upcEsPEK6QTk6Az6c7jsks+bNBtF6MBA5bAZT6L955uRYE92dcyPd94
# ctTzAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFMocUzORFgGSFvF+fcZOpsfNPIWZMB8GA1Ud
# IwQYMBaAFGslQd77a3z9GIAKLX+Pdl2qcz24MGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEFPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBD
# QSUyMDA0LmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQDEVaO/WWDHLcW053J2ElAPsU8E7tmV8ATrZz7C
# M2O+OpP6AVpvkoRT1zhPEZ1mAla9rzFhs3YCHwt2ktPD/w/ZI8T2CaWoQ9JDyr5R
# 1RokjZPOyPo+ZYxu49GvCBIvb2jDa0dGiSioY0qqpFKVchmB/AGSf01GKBoJBm7T
# L6o1yx7uTEvwgb6pWwnkNH98Zqs6Wu+DZENOnROPI+VFmqjh33fPr/AQZMcJHWW7
# o1bQPBGaukhmRKPFMyGCYX88YomKqU05q+SY3wPwOFq8jD3WNRK3CxCL7QAy6dkW
# GeWjw09w127i3HTL7S9ZgLBZtbUy+hfYfRDzJlHGV/nWyojZAZC/4IVeHAu7fdbf
# 5/JhZuC/+Osqph9Lo3wGGUQMJ+2duplsWHv3B67JFkup74fGrRTO5Kog+tzVCYqt
# y40AKfta5iQb1YuCRLvC6gvPA/JsTfukbvM3BSI+3Ic5ShKcA9zQChqNCNBeKOiI
# rDCZ3uXac0ptSl6R9t1JdZ0ivz/dnTAPtwJxcgPwQL/o8X/WE5FdVZTBWBGfUTrM
# SP8tYWBlqr+qnLDiD8sPXFjn4k/9AasHZPqSDxa1tpNKSN2ZovM6Mw9BTHy6bk/d
# uCkcKkpkjN6pOFUnqZF1LQtm/wK+9ciVEwV/+t/pMgkjHIgLEHv7uDT5MHJY2yeo
# 5ngedDCCBygwggUQoAMCAQICEzMAAAAWMZKNkgJle5oAAAAAABYwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMjlaFw0zMTAzMjYxODExMjlaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDKVfrI2+gJMM/0bQ5OVKNdvOASzLbUUMvX
# uf+Vl7YGuofPaZHVo3gMHF5inT+GMSpIcfIZ9qtXU1UG68ry8vNbQtOL4Nm30ifX
# pqI1+ByiAWLO1YT0WnzG7XPOuoTeeWsNZv5FmjxCsReBZvyzyzCyXZbu1EQfJxWT
# H4ebUwtAiW9rqMf9eDj/wYhiEfNteJV3ZFeibD2ztCHr9JhFdd97XbnCHgQoTIqc
# 02X5xlRKtUGBa++OtHBBjiJ/uwBnzTkqu4FjpZjQeJtrmda+ur1CT2jflWIB/ypn
# 7u7V9tvW9wJbJYt/H2EtJ0GONWxJZ7TEu8jWPindOO3lzPP7UtzS/mVDV94HucWa
# ltmsra6zSG8BoEJ87IM8QSb7vfm/O41FhYkUv89WIj5ES2O4kxyiMSfe95CMivCu
# YrRP2hKvx7egPMrWgDDBkxMLgrKZO9hRNUMm8vk3w5b9SogHOyJVhxyFm8aFXfIx
# gqDF4S0g4bhbhnzljmSlCLlumMZcXFGDjpF2tNoAu3VGFGYtHtTSNVKvZpgB3b4y
# naoDkbPf+Wg4523jt4VneasBgZhC1srZI2NCnCBBfgjLq04pqEKAWEohyW2K29KS
# kkHvt5VaE1ac3Yt+oyiOzMS57tXwQDJLGvLg/OXFO0VNvczDndfIfXYExB/ab2Pu
# MSwd5VIBOwIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBRrJUHe+2t8/RiACi1/j3ZdqnM9uDBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQAG1VBeVHTVRBljlcZD3IiM
# xwPyMjQyLNaEnVu5mODm2hRBJfH8GsBLATmrHAc8F47jmk5CnpUPiIguCbw6Z/KV
# j4Dsoiq228NSLMLewFfGMri7uwNGLISC5ccp8vUdADDEIsS2dE+QI9OwkDpv3XuU
# D7d+hAgcLVcMOl1AsfEZtsZenhGvSYUrm/FuLq0BqEGL9GXM5c+Ho9q8o+Vn/S+G
# WQN2y+gkRO15s0kI05nUpq/dOD4ri9rgVs6tipEd0YZqGgD+CZNiaZWrDTOQbNPn
# cd2F9qOsUa20miYruoT5PwJAaI+QQiTE2ZJeMJOkOpzhTUgqVMZwZidEUZKCquda
# eQA08WwnkQMfKyHzaU8j48ULcU4hUwvMsv7fSurOe9GAdRQCPvF8WcSK5oDHe8VV
# JM4tv6KKCm91HqLx9JamBgRI6R2SfY3nu26EGznu0rCg/769z8xWm4PVcC2ZaL6V
# lKVqFp1NsN8YqMyf5t+bbGVb09noFKcJG/UwyGlxRmQBlfeBUQx5/ytlzZzsEnhr
# JF9fTAfje8j3OdX5lEnePTFQLRlvzZFBqUXnIeQKv3fHQjC9m2fo/Z01DII/qp3d
# 8LhGVUW0BCG04fRwHJNH8iqqCG/qofMv+kym2AxBDnHzNgRjL60JOFiBgiurvLhY
# QNhB95KWojFA6shQnggkMTCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
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
# UyBBT0MgQ0EgMDQCEzMAAAsliaF5N+X1X2YAAAAACyUwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgSVz8ucIkxgXM1CoeLUx6io5gq31SI1aUw1zqHVDlrmkw
# DQYJKoZIhvcNAQEBBQAEggGAVg9VqXqyDa21dvDpjMITYY8Uaea6B6IsVE5fhV0c
# QRbChT2BKh1VZP6BdbRHmYkVU4sG+IZczulCN0R6qQMAb9l/u+3HXeGronZ43Z4T
# lMp7cxxqVjTvNEllPiTd9dLAJHQqz4GN4LSYqzruFfqslgtpBA7yIDd6r7rr8F8B
# oGIFdxz8kHO3+T2gf7SNe/WGSefDXdo8vpQ1LiSe/8XvFuMrxdO/vmy0Ifu8bdoQ
# 6uYKqMRIu1YRD+F1US3TXRbmk9T4JTa0J2z2pu6LRJkr3yjaeo6PtZOtf4Dw+Hj+
# XqSE7uOzKFCGmtbS3KUQwJYFVdEUwPYUfPO42CH7F9nvqUbH57LvLQnwd8ddS380
# tZkN+0rPEiZtVzqWiNP0tCr+IHgcPJYBYjnLYYFsxWul/B2nR5X+IQPEVud1duXJ
# nrL3Ds9MIm+vaAPGqyAXYoF9+0oNDSO5tc4C2OG71FsYzNSjvU+zwGMfvMDK5RGG
# JcZy6z/La3+BEvCU8TG/1Eg7oYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJ
# KoZIhvcNAQcCoIIX7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIIqjMpuqV3rnC4shHTPkYvCjP4sdRzAjrPsdnjbyIc8aAgZp1AaEVjYYEzIw
# MjYwNDExMTMwMzQ5LjEwN1owBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAt
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
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFck05XgounJ
# MQAAAAAAVzANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTNaFw0yNjEw
# MjIyMDQ2NTNaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsWylCpMIfbizJLY1kPXO2cmX2HRWvRbA
# meKSZ5ex7/jCymdV7Eap+Ic2iqRtWDkKKe5gL6JV80wtn5C2qHJLPxUYFKNG3UkH
# kAI21MoCN+YWnhT8K/YuPib6+6970jdbeFKIiZMWwd5hnpX9J3jeteuEdXbp/DfF
# BK15JuD3JOzWuF2suQCPgqYjQPk/gpq+3KCKtXJRbXSCSJ9YtITU2IHwmfdE7l2P
# fZ154w041po+fDeTj0gJOzcV/Jv56Q0M+w19jAKo/I5PEzrLV1IPQnmP4or1X4Rb
# JXk8ONXyOOfXOxK2VLpNxgklK1yAezbFP2uzqihaXkW1h9GQLGENKESnezwgdRaL
# NNaYtm8AT/pZHYJ35mZVqkZdMIckpQHJk/F1fSLyDKeKtH4TC4cc3ESKUMgItq07
# ZZm74JCsfhmrQ1ijVNDi1Sln+QBamgC7WviZbkQnceQRq9DY+6hANwOrasAZUiVr
# 2kPuj1jHDOXzUG4O9QTK70P/oXSqZAN1oTv3UfF8JTGmAxg+l1ZPOz50MY96HBDw
# /3bI/wBGNvLk6fLVnrxGN5B5unF/lYvjjWbIUdyBPVQnPOKXu08SRHbY19M1HoWX
# 6PNZv+vzSeqVeWWHKdKjC3GjVjbbGpi+JLbiyaKRSwEqo49tJLvu69cQ7dWsbksa
# i4TURnVj2mMCAwEAAaOCAcswggHHMB0GA1UdDgQWBBSOg8leLTUOAglIZ+bjXpiD
# 7RKSpzAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAHJ1wHY86Zk5SUBDPY25d/u9YJVaaNa71uxjX4cyO/XJ
# 4uPENCSOwkRTnNogPLxTD0Fg3z4TFf/2T/0IFSxdtWVtTjhzrn+WLInzeRawUhTC
# FVrPBJKEWVshm+Ig7/nB7JbJN88+ltImBbL5kT1StBLfG6UksAcDbNSQww90CUXh
# GueBxlnSvjkAX1ohiN16y1bB2s0rvQx8Csepl2CuBefTfDrMGzW/tzNx5YaK2D8O
# WweqTWZcGlJO4YjZNI83cTrQghfHl/8AXOHj8cWL3wEFltQQs2xeRYAb3Kdnl7oI
# WKKXWaBYJY5P3QPsiC+DTMp7ejdYKTrb396f3gr+wL/Ms5/Z3vIWZPJJv18qNw40
# fUNveRnwzMQnx8dM2bGuXXQZ5y7P8aXT4HJMo349qZtn4XQwiUE/DDp++MUL0kgj
# vd/Deo7Xr371PFPPYb4TboZhjV1x9+wCHDoOpNCBt+VuXU78ytJdKzQ1Jv2cEP1F
# 9H9/wSLsMDUvWME7u9mGElOPDZPMVr8AuBEuLdbTSEdaLwsZBplzxLBcgxhZ/Cs3
# 0yBhuE3QhqT1YDZ2pa56RexPA2SasPcToT6gJgJ6E06BmZ2zQTNvWOjs5XQqHbYu
# XcoeDcwe2UaC7EDOGD8GmLE9LiqtQsuQCM7v7I2xR+sPZT2Ax/85HjIkM+3MzTK1
# MYIHRjCCB0ICAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFck05XgounJMQAAAAAAVzANBglghkgBZQME
# AgEFAKCCBJ8wEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDExMTMwMzQ5WjAvBgkqhkiG9w0B
# CQQxIgQgplgT1NBVSoieBbOGZluGvIjurNX16WS/7CHApEh2pA8wgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCD1PJ9ktQVuTGWIbKLO4f1VUOlUU29ARCEpDZmF
# THjbUjB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFck05XgounJMQAAAAAAVzCCA2EGCyqGSIb3DQEJ
# EAISMYIDUDCCA0yhggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046Nzgw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD9LzE5nEJRAUE2Ss3x
# aKKPXHnLw6BnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2Ec7wwIhgPMjAyNjA0
# MTEwNzE2MTJaGA8yMDI2MDQxMjA3MTYxMlowdzA9BgorBgEEAYRZCgQBMS8wLTAK
# AgUA7YRzvAIBADAKAgEAAgISaQIB/zAHAgEAAgISaTAKAgUA7YXFPAIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQCUi7VZ6Zm3b7XsO77xLVtX1vmUR5Favfww
# h4zXbMFpTjn2PWUPw4L9ksv/NPNbGhGxCWyaIQu7TPa2mxEYxcEkr+rfK/l7I3s8
# z8MBzmjQkx5orFok2a7whYpr5XvaGE+DCp63wxS1JI6bNCAvsM5ajb69OYUNHAhv
# j7zwYybOjTM2GZRLJ/i1dEycdKjajB40q631n3NJZkw81SNjHqKz6JmpVEhHOF0S
# b9gpfiIkXdUdBfpA7BHmvh9UqqqNOSL/tfYqrDCqzuJgGAF+V+TWDbcBzIHjKWb6
# s5kI0gDtA9bkDsI+6VYSMpXKsvCysQn+81pqPauGMotbQBg4VvxfMA0GCSqGSIb3
# DQEBAQUABIICAKylWDIA+BZ71CRQVGxiwdythe3xDAa9Cacsrbv+7mdBZmN0mruW
# vckg60jLm9tjdiSfJ6+Ehsa99W3hy2/EtECBqCM9MIQpHegz8jvafS1VwbkuAQy9
# FAfyve5qJ5PmvREiGuGyJjQsb0PAKXa+nms2RVIhkaMtgQjwICDfJjYXhEjPWzpA
# qnVXnitKoq+B9oYAJByM2v/zf9AhdRt4IniD+aa5VA2BR3aCAC50CEUP2OvPoEgg
# zw4Fgo631GRUTPdwffncAot3SKQ9HnOnl+gFzhAWWqzq1PZBqKJDNdkKKAGKlgUx
# 7U8eGCWeiDIJnggKxlacZ+ennzAxxnISQNWciMZN5wAxF49GDZd/GI0PpUqunYvT
# Dk1M1V5msmZBzqjxTBRJAFgtzTlvPilgvg1dpjKvP1djC1oGrMSBeiUhN+rtshja
# ALfxBZjSDIZSSnNXCl22YHiD9DfLUBi9bMFqiL1iZuwj2mHjhI0Ur0xiEX9JesjL
# YHzBXfFdQ+un5+/bpwUjjhmICUcfv4W27uJafnrpSUGO8va7URODR2bcfoY/EuV6
# JMFtbOWqfLcpfIgj2Jo7BDCdqK1dhvtTpunDO9K3AE4x20mKThKgWaRqdntF0wdZ
# 2iZf4Fm4uTAXTofAtJPxElMhjQHENV64S7o/ukFE+kOVgNQCEOuDbHH8
# SIG # End signature block

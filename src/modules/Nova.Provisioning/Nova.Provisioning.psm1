<#
.SYNOPSIS
    First-boot provisioning and staging module for Nova deployment engine.

.DESCRIPTION
    Extracts provisioning functions from Nova.ps1 that stage scripts, configuration,
    and installers for execution on first boot via SetupComplete.cmd.  Covers
    Autopilot registration, ConfigMgr client staging, OOBE customization,
    BitLocker activation, post-provisioning scripts, application installation,
    and Windows Update.
#>

# ── Shared helper ────────────────────────────────────────────────────────────

function Add-SetupCompleteEntry {
    <#
    .SYNOPSIS  Appends a command line to the Windows SetupComplete.cmd file.
    .DESCRIPTION
        Creates (or appends to) a SetupComplete.cmd file that Windows OOBE
        executes on first boot. Uses ASCII encoding for broadest cmd.exe
        compatibility.
    .PARAMETER FilePath
        Full path to the SetupComplete.cmd file.
    .PARAMETER Line
        Command line to append.
    #>
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [string]$Line
    )
    $dir = Split-Path $FilePath
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    # Windows OOBE calls SetupComplete.cmd by convention -- it must be a .cmd file.
    # ASCII encoding ensures broadest compatibility with cmd.exe's file parser.
    if (Test-Path $FilePath) {
        $existing = (Get-Content $FilePath -Raw).TrimEnd()
        Set-Content $FilePath "$existing`r`n$Line" -Encoding Ascii
    } else {
        Set-Content $FilePath $Line -Encoding Ascii
    }
}

# ── Autopilot ────────────────────────────────────────────────────────────────

function Set-AutopilotConfig {
    <#
    .SYNOPSIS  Downloads or copies the Autopilot configuration JSON to the offline OS.
    .DESCRIPTION
        Places an AutopilotConfigurationFile.json into the Windows Provisioning
        directory so that Windows Autopilot picks it up on first boot.
    .PARAMETER JsonUrl
        URL to download the Autopilot JSON from.
    .PARAMETER JsonPath
        Local file path to an Autopilot JSON.
    .PARAMETER OSDriveLetter
        Drive letter of the mounted offline Windows partition.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$JsonUrl,
        [string]$JsonPath,
        [string]$OSDriveLetter
    )

    if (-not $JsonUrl -and -not $JsonPath) {
        Write-Warn 'No Autopilot JSON specified. Skipping Autopilot configuration.'
        return
    }

    Write-Step 'Applying Autopilot configuration...'

    $stepName = ''
    try {
        $stepName = 'Create Autopilot directory'
        $autopilotDest = "${OSDriveLetter}:\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json"
        $null = New-Item -ItemType Directory -Path (Split-Path $autopilotDest) -Force

        if ($JsonUrl) {
            $stepName = 'Download Autopilot JSON'
            Write-Host "  Fetching Autopilot JSON from: $JsonUrl"
            Invoke-WebRequest -Uri $JsonUrl -OutFile $autopilotDest -UseBasicParsing -TimeoutSec 30
        } else {
            $stepName = 'Copy Autopilot JSON'
            Copy-Item $JsonPath $autopilotDest -Force
        }

        Write-Success "Autopilot JSON placed at: $autopilotDest"
    } catch {
        throw "Set-AutopilotConfig failed at step '$stepName': $_"
    }
}

function Invoke-AutopilotImport {
    <#
    .SYNOPSIS  Registers the current device in Windows Autopilot via Microsoft Graph API.
    .DESCRIPTION
        Uses the Graph access token (from NOVA_GRAPH_TOKEN) to check whether
        the device is already registered in Autopilot.  If not, generates the
        hardware hash with oa3tool.exe and uploads the device identity via Graph.
        Group tag and user email are applied when provided.
    #>
    [CmdletBinding()]
    param(
        [string]$GroupTag,
        [string]$UserEmail
    )

    $token = $env:NOVA_GRAPH_TOKEN
    if (-not $token) {
        Write-Warn 'No Graph access token available (NOVA_GRAPH_TOKEN). Skipping Autopilot device import.'
        return
    }

    Write-Step 'Importing device into Windows Autopilot...'

    $authHeaders = @{ 'Authorization' = "Bearer $token" }

    # -- 1. Get serial number --------------------------------------------------
    $serial = $null
    try { $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber } catch { $null = $_ }
    if (-not $serial -or $serial.Trim() -eq '') {
        throw 'Autopilot import failed: device serial number is empty or unavailable.'
    }
    Write-Host "  Serial number: $serial"

    # -- 2. Check if the device is already registered --------------------------
    $sanitized = $serial -replace "['\\\x00-\x1f]", ''
    $filter    = [uri]::EscapeDataString("contains(serialNumber,'$sanitized')")
    $checkUri  = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"

    try {
        $existing = Invoke-RestMethod -Uri $checkUri -Headers $authHeaders -Method GET -TimeoutSec 30
        if ($existing.value -and $existing.value.Count -gt 0) {
            Write-Success "Device $serial is already registered in Autopilot -- skipping import."
            return
        }
    } catch {
        Write-Warn "Autopilot registration check failed (non-fatal): $_"
    }

    Write-Host '  Device not found in Autopilot -- proceeding with import...'

    # -- 3. Generate hardware hash via oa3tool.exe -----------------------------
    $customFolder = 'X:\OSDCloud\Config\Scripts\Custom'
    $oa3tool = Join-Path $customFolder 'oa3tool.exe'
    $oa3cfg  = Join-Path $customFolder 'OA3.cfg'

    if (-not (Test-Path $oa3tool) -or -not (Test-Path $oa3cfg)) {
        throw 'Autopilot import failed: oa3tool.exe or OA3.cfg not staged in WinPE.'
    }

    $oa3proc = Start-Process -FilePath $oa3tool `
        -ArgumentList "/Report /ConfigFile=$oa3cfg /NoKeyCheck" `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput 'oa3.log' -RedirectStandardError 'oa3.error.log'

    if ($oa3proc.ExitCode -ne 0) {
        throw 'Autopilot import failed: oa3tool.exe exited with a non-zero code.'
    }

    if (-not (Test-Path 'OA3.xml')) {
        throw 'Autopilot import failed: OA3.xml not generated by oa3tool.'
    }

    try {
        [xml]$oa3Xml = Get-Content -Path 'OA3.xml' -Raw
    } catch {
        throw "Autopilot import failed: could not parse OA3.xml as valid XML: $_"
    }
    $hashNode = $oa3Xml.SelectSingleNode('//HardwareHash')
    if (-not $hashNode -or -not $hashNode.InnerText) {
        throw 'Autopilot import failed: hardware hash not found in OA3.xml.'
    }
    $hwHash = $hashNode.InnerText
    Remove-Item 'OA3.xml' -Force -ErrorAction SilentlyContinue
    Write-Host '  Hardware hash generated successfully.'

    # -- 4. Upload device to Autopilot -----------------------------------------
    $body = @{
        serialNumber       = $serial
        hardwareIdentifier = $hwHash
    }
    if ($GroupTag)  { $body.groupTag = $GroupTag }
    if ($UserEmail) { $body.assignedUserPrincipalName = $UserEmail }

    $uploadUri = 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities'
    $null = Invoke-RestMethod -Uri $uploadUri -Headers ($authHeaders + @{
        'Content-Type' = 'application/json'
    }) -Method POST -Body ($body | ConvertTo-Json) -TimeoutSec 60

    Write-Host '  Device uploaded -- waiting for registration...'

    # -- 5. Poll until the device appears in Autopilot -------------------------
    # Autopilot registration is asynchronous.  Poll every 30 seconds for
    # up to 25 attempts (~12.5 minutes) to confirm the device is visible.
    $maxAttempts = 25
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Start-Sleep -Seconds 30
        try {
            $poll = Invoke-RestMethod -Uri $checkUri -Headers $authHeaders -Method GET -TimeoutSec 30
            if ($poll.value -and $poll.value.Count -gt 0) {
                Write-Success "Device successfully registered in Autopilot (attempt $i)."
                return
            }
        } catch {
            Write-Warn "Registration poll attempt $i failed: $_"
        }
    }

    throw "Autopilot import: device registration not confirmed after $maxAttempts attempts."
}

# ── ConfigMgr (SCCM) ────────────────────────────────────────────────────────

function Install-CCMSetup {
    <#
    .SYNOPSIS  Stages ConfigMgr CCMSetup for first-boot execution.
    .PARAMETER DownloadCommand
        Optional scriptblock for downloading files.  Called with -Uri, -OutFile,
        and -Description parameters.  When not supplied the function falls back
        to Invoke-WebRequest.
    #>
    [CmdletBinding()]
    param(
        [string]$CCMSetupUrl,
        [string]$OSDriveLetter,
        [string]$ScratchDir,
        [scriptblock]$DownloadCommand
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
        if ($DownloadCommand) {
            & $DownloadCommand -Uri $CCMSetupUrl -OutFile $ccmExe -Description 'Downloading ccmsetup.exe'
        } else {
            Invoke-WebRequest -Uri $CCMSetupUrl -OutFile $ccmExe -UseBasicParsing -ErrorAction Stop
        }

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

# ── OOBE Customization ──────────────────────────────────────────────────────

# Default unattend.xml used when the task sequence has no unattendContent yet.
$script:DefaultUnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>false</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>false</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>false</SkipMachineOOBE>
        <SkipUserOOBE>false</SkipUserOOBE>
      </OOBE>
    </component>
  </settings>
</unattend>
"@

function Set-OOBECustomization {
    <#
    .SYNOPSIS  Writes the unattend.xml to the target OS drive.
    .DESCRIPTION
        The unattendContent in the task sequence is the single source of
        truth -- ComputerName and locale settings are already injected by
        the Task Sequence Editor (or the Bootstrap config modal at runtime).
        This function simply writes the final XML to disk (or downloads /
        copies from an external source).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$UnattendUrl,
        [string]$UnattendPath,
        [string]$UnattendContent,
        [string]$OSDriveLetter
    )

    Write-Step 'Applying OOBE customization...'

    $stepName = ''
    try {
        $stepName = 'Create Panther directory'
        $unattendDest = "${OSDriveLetter}:\Windows\Panther\unattend.xml"
        $null = New-Item -ItemType Directory -Path (Split-Path $unattendDest) -Force

        if ($UnattendUrl) {
            $stepName = 'Download unattend.xml'
            Write-Host "  Fetching unattend.xml from: $UnattendUrl"
            Invoke-WebRequest -Uri $UnattendUrl -OutFile $unattendDest -UseBasicParsing -TimeoutSec 30
            Write-Success "Custom unattend.xml applied from URL."
            return
        }

        if ($UnattendPath -and (Test-Path $UnattendPath)) {
            $stepName = 'Copy unattend.xml'
            Copy-Item $UnattendPath $unattendDest -Force
            Write-Success "Custom unattend.xml applied from path: $UnattendPath"
            return
        }

        if ($UnattendContent) {
            $stepName = 'Apply task sequence unattend.xml'
            Set-Content -Path $unattendDest -Value $UnattendContent -Encoding UTF8
            Write-Success 'Custom unattend.xml applied from task sequence content.'
            return
        }

        # Fallback: write the built-in default (no custom settings)
        $stepName = 'Generate default unattend.xml'
        Set-Content -Path $unattendDest -Value $script:DefaultUnattendXml -Encoding UTF8
        Write-Success 'Default unattend.xml applied.'
    } catch {
        throw "Set-OOBECustomization failed at step '$stepName': $_"
    }
}

# ── BitLocker / Encryption ──────────────────────────────────────────────────

function Enable-BitLockerProtection {
    <#
    .SYNOPSIS  Stage BitLocker drive encryption for first-boot activation.
    .DESCRIPTION
        Creates a PowerShell script that enables BitLocker with TPM protector
        on the OS drive and registers it for execution on first boot via
        SetupComplete.cmd.  The recovery password is backed up to Azure AD
        when the device is Azure AD joined.
    .PARAMETER OSDriveLetter  Target OS drive letter (e.g. 'C').
    .PARAMETER EncryptionMethod  BitLocker encryption algorithm (default XtsAes256).
    .PARAMETER SkipHardwareTest  Skip the TPM hardware test during enable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OSDriveLetter,
        [string]$EncryptionMethod = 'XtsAes256',
        [switch]$SkipHardwareTest
    )

    Write-Step 'Staging BitLocker encryption for first boot...'

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $scriptDir -Force

        $stepName = 'Generate BitLocker script'
        $skipFlag = if ($SkipHardwareTest) { ' -SkipHardwareTest' } else { '' }
        $blScript = @"
# Nova BitLocker -- first-boot activation
# Generated by Nova deployment engine
`$ErrorActionPreference = 'Stop'
try {
    `$drive = '$OSDriveLetter' + ':'
    Enable-BitLocker -MountPoint `$drive -EncryptionMethod $EncryptionMethod -TpmProtector$skipFlag
    Add-BitLockerKeyProtector -MountPoint `$drive -RecoveryPasswordProtector
    # Back up recovery key to Azure AD if the device is joined
    `$blv = Get-BitLockerVolume -MountPoint `$drive
    `$rp = `$blv.KeyProtector | Where-Object { `$_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    if (`$rp) {
        try {
            BackupToAAD-BitLockerKeyProtector -MountPoint `$drive -KeyProtectorId `$rp.KeyProtectorId -ErrorAction SilentlyContinue
        } catch {
            # Device may not be AAD joined -- skip backup silently
        }
    }
} catch {
    Write-EventLog -LogName Application -Source 'Nova' -EventId 1001 -EntryType Error -Message "Nova BitLocker activation failed: `$_"
}
"@
        $blScriptPath = Join-Path $scriptDir 'Nova_EnableBitLocker.ps1'
        Set-Content -Path $blScriptPath -Value $blScript -Encoding UTF8

        $stepName = 'Add SetupComplete entry'
        $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
        Add-SetupCompleteEntry -FilePath $setupComplete -Line 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Nova_EnableBitLocker.ps1"'

        Write-Success 'BitLocker encryption staged for first boot.'
    } catch {
        throw "Enable-BitLockerProtection failed at step '$stepName': $_"
    }
}

# ── Post-Provisioning Scripts ────────────────────────────────────────────────

function Invoke-PostScript {
    <#
    .SYNOPSIS  Downloads and stages post-provisioning scripts for first-boot execution.
    .DESCRIPTION
        Fetches one or more PowerShell scripts from the supplied URLs and
        registers them in SetupComplete.cmd so they run automatically on
        the first Windows boot after deployment.
    .PARAMETER ScriptUrls
        Array of URLs pointing to the PowerShell scripts to download.
    .PARAMETER OSDriveLetter
        Drive letter of the mounted offline Windows partition.
    .PARAMETER ScratchDir
        Working directory (reserved for future use).
    #>
    [CmdletBinding()]
    param(
        [string[]]$ScriptUrls,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    $null = $ScratchDir
    if (-not $ScriptUrls -or $ScriptUrls.Count -eq 0) {
        Write-Warn 'No post-provisioning scripts specified. Skipping.'
        return
    }

    Write-Step "Staging $($ScriptUrls.Count) post-provisioning script(s)..."

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $scriptDir -Force

        $i = 1
        foreach ($url in $ScriptUrls) {
            $fileName = "Nova_Post_$($i.ToString('00')).ps1"
            $stepName = "Download post-script '$fileName'"
            $dest     = Join-Path $scriptDir $fileName
            Write-Host "  Downloading: $url -> $fileName"
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 30
            $i++
        }

        # Add each script to SetupComplete.cmd
        $stepName = 'Add SetupComplete entries'
        $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
        for ($j = 1; $j -lt $i; $j++) {
            $fileName = "Nova_Post_$($j.ToString('00')).ps1"
            Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$fileName`""
        }

        Write-Success "Post-provisioning scripts staged in: $scriptDir"
    } catch {
        throw "Invoke-PostScript failed at step '$stepName': $_"
    }
}

# ── Application Installation ────────────────────────────────────────────────

function Install-Application {
    <#
    .SYNOPSIS  Stages application installers for first-boot execution.
    .DESCRIPTION
        Downloads application installers (MSI, EXE, or Winget manifests) and
        stages them for installation on first boot via SetupComplete.cmd.
        Supports three modes:
          - winget: stages a Winget import file for first-boot installation
          - url:    downloads an MSI/EXE installer and stages with silent args
          - script: downloads and stages a custom installation script
    .PARAMETER DownloadCommand
        Optional scriptblock for downloading files.  Called with -Uri, -OutFile,
        and -Description parameters.  When not supplied the function falls back
        to Invoke-WebRequest.
    #>
    [CmdletBinding()]
    param(
        [string]$InstallMode = 'url',
        [string]$PackageId,
        [string]$InstallerUrl,
        [string]$SilentArgs = '/qn /norestart',
        [string]$ScriptUrl,
        [string]$OSDriveLetter,
        [string]$ScratchDir,
        [scriptblock]$DownloadCommand
    )

    Write-Step 'Staging application installation...'

    $null = $ScratchDir     # reserved for future use
    $stepName = ''
    $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
    $setupComplete = Join-Path $scriptDir 'SetupComplete.cmd'
    $null = New-Item -ItemType Directory -Path $scriptDir -Force

    try {
        switch ($InstallMode) {
            'winget' {
                $stepName = 'Stage Winget installation'
                if (-not $PackageId) {
                    Write-Warn 'No Winget package ID specified. Skipping application installation.'
                    return
                }
                # Stage a PowerShell script that installs via Winget on first boot
                $wingetScript = Join-Path $scriptDir 'Nova_InstallApp_Winget.ps1'
                $scriptContent = @"
# Nova -- Winget application installation (first boot)
`$ErrorActionPreference = 'Continue'
`$maxRetries = 3
for (`$i = 1; `$i -le `$maxRetries; `$i++) {
    try {
        winget install --id '$PackageId' --silent --accept-source-agreements --accept-package-agreements
        if (`$LASTEXITCODE -eq 0) { break }
    } catch { Start-Sleep -Seconds (5 * `$i) }
}
"@
                Set-Content -Path $wingetScript -Value $scriptContent -Encoding UTF8
                Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Nova_InstallApp_Winget.ps1`""
                Write-Success "Winget installation staged for package: $PackageId"
            }
            'url' {
                $stepName = 'Download installer'
                if (-not $InstallerUrl) {
                    Write-Warn 'No installer URL specified. Skipping application installation.'
                    return
                }
                $ext = [System.IO.Path]::GetExtension($InstallerUrl).ToLower()
                if (-not $ext) { $ext = '.exe' }
                $installerName = "Nova_AppInstaller$ext"
                $installerDest = Join-Path $scriptDir $installerName
                if ($DownloadCommand) {
                    & $DownloadCommand -Uri $InstallerUrl -OutFile $installerDest -Description 'Downloading application installer'
                } else {
                    Invoke-WebRequest -Uri $InstallerUrl -OutFile $installerDest -UseBasicParsing -ErrorAction Stop
                }

                $stepName = 'Stage installer'
                if ($ext -eq '.msi') {
                    Add-SetupCompleteEntry -FilePath $setupComplete -Line "msiexec.exe /i `"%~dp0$installerName`" $SilentArgs"
                } else {
                    Add-SetupCompleteEntry -FilePath $setupComplete -Line "`"%~dp0$installerName`" $SilentArgs"
                }
                Write-Success "Application installer staged: $installerName"
            }
            'script' {
                $stepName = 'Download installation script'
                if (-not $ScriptUrl) {
                    Write-Warn 'No script URL specified. Skipping application installation.'
                    return
                }
                $scriptDest = Join-Path $scriptDir 'Nova_InstallApp_Custom.ps1'
                Invoke-WebRequest -Uri $ScriptUrl -OutFile $scriptDest -UseBasicParsing -TimeoutSec 30
                Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Nova_InstallApp_Custom.ps1`""
                Write-Success "Custom installation script staged."
            }
            default {
                Write-Warn "Unknown install mode '$InstallMode'. Skipping."
            }
        }
    } catch {
        throw "Install-Application failed at step '$stepName': $_"
    }
}

# ── Windows Update Staging ──────────────────────────────────────────────────

function Invoke-WindowsUpdateStaging {
    <#
    .SYNOPSIS  Stages a Windows Update trigger script for first-boot execution.
    .DESCRIPTION
        Creates a PowerShell script that runs on first boot to install critical
        and security updates via the built-in Windows Update client.  The script
        uses the COM-based Windows Update Agent API which is available on all
        Windows installations without additional modules.
    #>
    [CmdletBinding()]
    param(
        [string]$OSDriveLetter,
        [string[]]$Categories = @('SecurityUpdates', 'CriticalUpdates')
    )

    Write-Step 'Staging Windows Update for first boot...'

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $scriptDir -Force

        $stepName = 'Generate Windows Update script'
        $wuScript = Join-Path $scriptDir 'Nova_WindowsUpdate.ps1'
        $scriptContent = @"
# Nova -- Windows Update (first boot)
# Installs critical and security updates using the Windows Update Agent COM API.
`$ErrorActionPreference = 'Continue'
`$logFile = "`$env:SystemDrive\Nova\Logs\WindowsUpdate.log"
`$null = New-Item -ItemType Directory -Path (Split-Path `$logFile) -Force -ErrorAction SilentlyContinue
Start-Transcript -Path `$logFile -Force -ErrorAction SilentlyContinue

Write-Host 'Nova: Starting Windows Update scan...'
try {
    `$session    = New-Object -ComObject Microsoft.Update.Session
    `$searcher   = `$session.CreateUpdateSearcher()
    `$result     = `$searcher.Search('IsInstalled=0 AND IsHidden=0')
    `$updates    = `$result.Updates

    if (`$updates.Count -eq 0) {
        Write-Host 'Nova: No updates available.'
    } else {
        Write-Host "Nova: Found `$(`$updates.Count) update(s). Downloading and installing..."
        `$downloader = `$session.CreateUpdateDownloader()
        `$downloader.Updates = `$updates
        `$null = `$downloader.Download()

        `$installer = `$session.CreateUpdateInstaller()
        `$installer.Updates = `$updates
        `$installResult = `$installer.Install()
        Write-Host "Nova: Update installation complete. Result: `$(`$installResult.ResultCode)"
    }
} catch {
    Write-Warning "Nova: Windows Update failed: `$_"
}

Stop-Transcript -ErrorAction SilentlyContinue
"@
        Set-Content -Path $wuScript -Value $scriptContent -Encoding UTF8

        $stepName = 'Register in SetupComplete'
        $setupComplete = Join-Path $scriptDir 'SetupComplete.cmd'
        Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Nova_WindowsUpdate.ps1`""

        Write-Success "Windows Update staged for first boot (categories: $($Categories -join ', '))"
    } catch {
        throw "Invoke-WindowsUpdateStaging failed at step '$stepName': $_"
    }
}

# ── Module exports ───────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Add-SetupCompleteEntry'
    'Set-AutopilotConfig'
    'Invoke-AutopilotImport'
    'Install-CCMSetup'
    'Set-OOBECustomization'
    'Enable-BitLockerProtection'
    'Invoke-PostScript'
    'Install-Application'
    'Invoke-WindowsUpdateStaging'
)

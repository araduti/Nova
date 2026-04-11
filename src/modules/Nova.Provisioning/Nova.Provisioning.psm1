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

Set-StrictMode -Version Latest

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
    [OutputType([void])]
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
    [OutputType([void])]
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
    [OutputType([void])]
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
    [OutputType([void])]
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
    [OutputType([void])]
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
    [OutputType([void])]
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
    [OutputType([void])]
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
    [OutputType([void])]
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
    [OutputType([void])]
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

# SIG # Begin signature block
# MII6FAYJKoZIhvcNAQcCoII6BTCCOgECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCA7aj6KB3uJrRI
# UoqQ/v4xd4efrPbYwZwqlC0JTpXuhqCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# rmcxghcyMIIXLgIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBBT0MgQ0EgMDQCEzMAAAsliaF5N+X1X2YAAAAACyUwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgI4NDREiuQiVkae2Tvg9tsbnRtI7j6YacDlUwGLSuI54w
# DQYJKoZIhvcNAQEBBQAEggGAX9VtfLyuj4zoUaJ/tDlQ0SGebzscsYWvDfl6pjzY
# U9lFK+Ttjcl/5S/slOwFyeIxS57AliCF8u1znQUo18nTcO1AHHOG3WRbMhMLAdpM
# 5Ys4zuL5MALU3NJhmxysKK1tvaGvkLVkMtUVLchCZP6vDRqOJdXCWE2skSN+8ADy
# am8uNszfsKeztPbU5KzC8WWxZHohEc0cM+Fal9wkEzmPR6Q9XeJiwepFh2A+8umn
# T//EOZ8V9iatfRQJtpP2P1ykE729uTm9V/Z3Vo8nZzi6jY0+BVX6NoLu6yYxaH28
# FJMWRIQ+od2jFw+xTIwl9Q3s8eFYbChynQXwHaArHYow0IzJBwP/JSok83oYrsgD
# ycaLnC6z37mtKnxAZ+8dHXFGwtU0Z22Rf72Dw4QXAzcbaG+a6/hqzJXFRAKdKi+K
# OOb69ofH7FlBf394NsHE6eI7es1b8iMX/fbPP1ic6D3aSVp29qY4jHN7VWcjwtQc
# 3SEb9G0RHBZNFlbkLQeoCjRSoYIUsjCCFK4GCisGAQQBgjcDAwExghSeMIIUmgYJ
# KoZIhvcNAQcCoIIUizCCFIcCAQMxDzANBglghkgBZQMEAgEFADCCAWoGCyqGSIb3
# DQEJEAEEoIIBWQSCAVUwggFRAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEINUhGRtH7QngrP2yGdOyN5asq84Cm9adNySKtIDTO6dBAgZpxlxrJZkYEzIw
# MjYwNDExMTMyNjI0LjM4NVowBIACAfSggemkgeYwgeMxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5k
# IE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjQ1
# MUEtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# IFN0YW1waW5nIEF1dGhvcml0eaCCDykwggeCMIIFaqADAgECAhMzAAAABeXPD/9m
# LsmHAAAAAAAFMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDExMTkyMDMyMzFaFw0zNTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAnnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1l
# Rkd3kcFdcG9/sqtDlwxKoVIcaqDb+omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjx
# nG/eViS4sOx8y4gSq8Zg49REAf5huXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5
# hJM1xznkRsFPu6rfDHeZeG1Wa1wISvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFl
# yAKwn6yjN/kR4fkquUWfGmMopNq/B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTP
# Vi3gVErnc/qi+dR8A2MiAz0kN0nh7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKx
# Lms73KG/Z+MkeuaVDQQheangOEMGJ4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxR
# YR/JPGAaM6xGl57Ei95HUw9NV/uC3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxO
# mM2rl4uKK6eEpurRduOQ2hTkmG1hSuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cj
# RKG79+TX+sTehawOoxfeOO/jR7wo3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xT
# nD1a69w/UTxwjEugpIPMIIE67SFZ2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8F
# UXetXr0CAwEAAaOCAhswggIXMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEE
# AwIBADAdBgNVHQ4EFgQUa2koOjUvSGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJ
# BgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZ
# BgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1Ud
# IwQYMBaAFMh+0mqFKhvKGZgEByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJ
# ZGVudGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1
# dGhvcml0eSUyMDIwMjAuY3JsMIGUBggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUH
# MAKGdWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9z
# b2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNh
# dGUlMjBBdXRob3JpdHklMjAyMDIwLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2
# x35ttVoVdedMeGj6TuHYRJklFaW4sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6A
# F6ycWoEYR0LYhaa0ozJLU5Yi+LCmcrdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM
# 74LNvVzY0/nPISHz0Xva71QjD4h+8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLsl
# LKsO8F2aBs2cIo1k+aHOhrw9xw6JCWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yF
# M7Ujrhc0aqy3xL7D5FR2J7x9cLWMq7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFov
# IP7YG4ZkJWag1H91KlELGWi3SLv10o4KGag42pswjybTi4toQcC/irAodDW8HNtX
# +cbz0sMptFJK+KObAnDFHEsukxD+7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9
# TlxydiFhvu88o0w35JkNbJxTk4MhF/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWV
# ydt4ytxYP/bqjN49D9NZ81coE6aQWm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeC
# UMYmBx3PkP8ADHD1J2Cr/6tjuOOCztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdto
# SAHEUKiBhI6JQivRepyvWcl+JYbYbBh7pmgAXVswggefMIIFh6ADAgECAhMzAAAA
# XGFMAKan8ukjAAAAAABcMA0GCSqGSIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMB4XDTI2MDEwODE4NTkw
# NloXDTI3MDEwNzE4NTkwNlowgeMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMg
# TGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjQ1MUEtMDVFMC1EOTQ3
# MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5nIEF1
# dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK41jM5VeZNH
# d4NtVlUxNoOHqf6e/TgnDjNbq/s5M3WhNLEEiHKrpAowFqcDZ5ek7KpDRW9xeBwL
# lLPdoyCV1fIpHv1swh4tU9C1dIKyOusuN32al13lVCrgd8qBqKw8sW/rKenXHaDW
# 94g2HlX5ssQWnVcKpZYIR3UpExCmRSQtIVEFloWZvo3PcwatECZTifG3TAhX/bTB
# KXOFoUpqWk/SFLAj7WxULE3wfyuWCH7SMY1mAIkSdcrDdI7/AkSNGFkw9pRIYRft
# zAKvOqP/LWGcD5rwZvB9nSUJA+YyuNty/HePVUvpV5wWel2F/I/kCksfkJKRe01i
# GIWLuYbzz34yLP4JyvtrA+IU/Uu8BH0JMNkfPi5r8DmviM56Ef0BTt4Q/G6UDDLQ
# EHLA6Xu2kreAox7HBDKAcWll7l3tM+K5XMrCS1uH2ujgKQPByl1QcJGDKw065mvx
# Z3rR/0MuSKihAVGH+aJxnHzYNRMOUzkK1yXg2zgd6Nk1Eav4a93tX2Qq5kXpeZba
# 132ohkYvh5vnXkjQVQ9HJwfe+J+09lUpgNuSHwb/gjzi2Z8+Hg9pwe7okJ2QLQGw
# 5TQRkw/xK7aH02aDBXOTzo1Uft/UmEVxbCzFnGFGAjcr0RwfnGFaIyyrF5uZmSsW
# KCF2o7v7LOjNlneWSSoFaKRhODuKRjw/AgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQU
# rvsyHJEYZEQ5bnTgWgMSJ7ok52kwHwYDVR0jBBgwFoAUa2koOjUvSGNAz3vYr0np
# Ptk92yEwbAYDVR0fBGUwYzBhoF+gXYZbaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0YW1w
# aW5nJTIwQ0ElMjAyMDIwLmNybDB5BggrBgEFBQcBAQRtMGswaQYIKwYBBQUHMAKG
# XWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwUHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAM
# BgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQE
# AwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEBDAUAA4ICAQCFdtA33LEkhAWdgIW55V5n
# T1ZG/VaQ4M2yBBDuIKUf20fPW0PqluLQtPcodrXGZDeCiON3Op3kUTXAYwBpm+7Y
# PMrJbRlZgMQPsFtbSdHC9bET0NJV8oXDGEWBOQe7lwwH05+Pa17xB2/mmVenWWtr
# ZX11I8BoFjcP2DwZSJ5X1G6TTe6GYJl99H58ihs7Tv/TEZP7c8mj6eVeOCsiyKGX
# pRTYJL9yltt6cKKccmcraVSjMTv43bmpLLL1WCq+y/T3HEtjXizKXRo5m3TE69Ug
# iosqZ66LeH0dvFB9u1+B7EtDjTPvCyc4n83+W3vm9BqzBmvf3ESgwt4J5KHK+Coy
# KieaRBdP3rVOLouk3MaFkAFHthWlf6rzh/0DopuXxqYby3Eot1c530MqQJ31v72x
# JMSe5Qs+zK55qsKg22vck6b2mwhD/ZNh66YeBsVY2kS9ahkGMtR+OgPz0DnDi+Oe
# R60bwiZHJifwyHMTcGuT9pUnp7nCt6e0vIhhtmJ1tlEIMurW4SYtUKiULzP6SLdq
# 8ys1+BUohCht/tgi+ibWfTSno7veBC7xaJi6JskqA/E8PdEzUOWHabwYiSHXlZMb
# obOTR0Dk3IzaqgUUX+E2xsfmVj2outhvWZ55c1/PfLK1p4yzRe9+rY3V4Ni0ORGU
# QWhefgkNYspB1jZiXDq8gzGCA9QwggPQAgEBMHgwYTELMAkGA1UEBhMCVVMxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0
# IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENBIDIwMjACEzMAAABcYUwApqfy6SMA
# AAAAAFwwDQYJYIZIAWUDBAIBBQCgggEtMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQg1uiY+3udEnMOXqqcXW1M2NU/Uv13Vdcx4mmD
# 9TQa8ukwgd0GCyqGSIb3DQEJEAIvMYHNMIHKMIHHMIGgBCD3umpBh3duMPkt6Itk
# JtOzRwBRt1Q8I513q8lrfqDu3DB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMAITMwAAAFxhTACmp/LpIwAAAAAA
# XDAiBCBhIFszEbhzdiNPK5PtZk5m8HUUPUUO0TNTuqTcFubT6zANBgkqhkiG9w0B
# AQsFAASCAgCMB06sbryCRe/uo3juSETL3Cq3N390n+4ff4ll7mKjDtW6EzHkPXdx
# h9wDgNxQGWgoBeTGhTg2gP/h2GspSHPeh2LDPhbVAY+O2q9Z/FHxb1wJr4IzflUE
# Grzsb53ukxK4CIUwV2BQtGFtUL/4b2aKmmVGEnXfMbZyzNPudjwpMUstgnTMQky6
# lZKa4NoV0j5W5QEAAZkCDZKyRE9chRVJNEv2rwa7YpyP+D6TNovotQprmosdA1ay
# dCCVjyldWwYDhBmBMBrJTLyRPMMDbqy5Os6DGEfPtCX9Dpt2YtyHpgJvRQDvs6dh
# QspaIPPIPf1E1IkCirfF0a0AUcL4bKtJGoLkKxncCgj8e6kMTlwYLTXEfBZQtBqQ
# N8u3E9aszE+Q9wU7vybrcky4m4gWDgnag/ID3qSZ+hulUlHsMm44kHWy6DTUfZ6j
# LBBZ1atgQoo4Na1ECcCbD4thxxaQqAsNae31UhdcWFnx7rkibREo/ip/TYKdl1qW
# ABDal3S3/bM5gwcOsv8ngLT2ROJZmM3ckytIpgcjR7/BvP95t7/4BbwgPVtUB9ju
# yORycpU/IUXxrogcyTCzs7SEYs+oTJ+2xeuVxO6+hDx7by87D3DPu4gZSOkw7xkl
# IzBHfBU0r1GoLIMFgFmhRa5d3PeHEX7Adq426ySj/Fli+2u1pvkRTw==
# SIG # End signature block

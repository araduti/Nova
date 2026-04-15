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
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAABSQY7l
# 84XZvuWtAAAAAFJBMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNDE0MTQyMDU2WhcNMjYwNDE3
# MTQyMDU2WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQDiaaDsBkHK33PY
# y2N3c9H0WYuaS6zfCnNxJyAXwLl5/5IT5aCUSfXRZlopdexI3LGzdGlKPNTVpHMZ
# QES4+lybTKWuS1TBovX1yNXcFZL69YENBSPI+KtqIsPVevodOeWfzezWUYFlD6B0
# fP4mhQT4XUtF7V1+ULJ5O4f1vlHugoXtpYs2t2Gv2hU4kRtA4MGh3fsJcyifb751
# 4Q96Vo4ADMWsr1DNNIkdO/+3F/Gn2Q+Iq3UknXFT8PD4yl25OaEsMQe1tk9sPupo
# Z8RIkXWdqbfTWvIJvw/EREIqAQ8jTCMTZpb352JoH9f9DeOAUDb8PTIgGUyekZxK
# ZazRrgF3Uj/Ffb29viRKTCBgVaw1/ouPVsJ3ZMZgVaQoQiEYHfu+jRP0Jk3ve+Y4
# O5FMzBVh1qPh48akw41SNpZiZNNhg3cQ/SUHbkFaoRQ2IRbLSZnryEXjZloC2RO5
# mj1Do2BN4ib1qsiIUWVoa70Fy/sdNW2HswU2RNB82Gxk73sfft8CAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUuIt05EZ/8gwAGTL+u0c6lJfmskQwHwYDVR0jBBgwFoAUa16lNMMF
# xWJKIVqOq3NgYtSsY4UwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMy5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAGhA2xIUuTvm6OOZjzD9zV83DdPaQDYV3on1pi4Dho+ne+Rd6huJVA+X
# h+uWEyglV1cZ4scWfl+2JerD6SyFQSpBR8NKcCFjsDh4qlQjegPPq1iYPubmCGsd
# xXV1k+8nF6RCRhQNsD0EN2yWosjFkKV4ksB1za9yKTpo4MY+RyD4PVUxBKkDr/FT
# e+MDK1oB6OwQwYD+DC1ApwBdAbfY4A5XY6NLpQLjo5bz6L5vXanejrwxKjzQXob5
# aXnjCz27AGCNddicZmJ+3pyocUUB3DnVo6xeG5iPnPb/3oT77AghHJ+EmNxJWjc8
# MKjZskbZiC47pt/HXGEilWZ7RH/8WBiydlY4sQIOIBmZy53G+Ed53l7kyO6iTx0n
# fR5r66/iyeXNmU7jfcn0eMHtNR5X1ZOYENsF/v1xyRwyjJcRyJgQdmzfUNJQhKqJ
# J5QIN1d5aprYLvjmsQRU9Maz9K1afjGu+Y4T/tJM9mO4KdNwC0VM81pwO6l4gGw3
# o7xRNcud74cZRYyt7X0W9z1Mf/ZDobF1IchSiKfpTZ2p2vHwxZ10GIYLjUAQPPIw
# Df+6EQFXYoASJJjcmwlg5GOHFmEM6YQ2bPle9X7ilNDRtPclWV4N59CS3ovAokYn
# W1CgY3T34Y2V96NMn/Qk1Ov+zL/4AnO2ds+9KjXiRn0se5mm6JevMIIGyTCCBLGg
# AwIBAgITMwAAUkGO5fOF2b7lrQAAAABSQTANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMB4XDTI2MDQxNDE0
# MjA1NloXDTI2MDQxNzE0MjA1NlowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEA4mmg7AZByt9z2Mtjd3PR9FmLmkus3wpzcScgF8C5ef+SE+WglEn10WZaKXXs
# SNyxs3RpSjzU1aRzGUBEuPpcm0ylrktUwaL19cjV3BWS+vWBDQUjyPiraiLD1Xr6
# HTnln83s1lGBZQ+gdHz+JoUE+F1LRe1dflCyeTuH9b5R7oKF7aWLNrdhr9oVOJEb
# QODBod37CXMon2++deEPelaOAAzFrK9QzTSJHTv/txfxp9kPiKt1JJ1xU/Dw+Mpd
# uTmhLDEHtbZPbD7qaGfESJF1nam301ryCb8PxERCKgEPI0wjE2aW9+diaB/X/Q3j
# gFA2/D0yIBlMnpGcSmWs0a4Bd1I/xX29vb4kSkwgYFWsNf6Lj1bCd2TGYFWkKEIh
# GB37vo0T9CZN73vmODuRTMwVYdaj4ePGpMONUjaWYmTTYYN3EP0lB25BWqEUNiEW
# y0mZ68hF42ZaAtkTuZo9Q6NgTeIm9arIiFFlaGu9Bcv7HTVth7MFNkTQfNhsZO97
# H37fAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFLiLdORGf/IMABky/rtHOpSX5rJEMB8GA1Ud
# IwQYMBaAFGtepTTDBcViSiFajqtzYGLUrGOFMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDAzLmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBoQNsSFLk75ujjmY8w/c1fNw3T2kA2Fd6J9aYu
# A4aPp3vkXeobiVQPl4frlhMoJVdXGeLHFn5ftiXqw+kshUEqQUfDSnAhY7A4eKpU
# I3oDz6tYmD7m5ghrHcV1dZPvJxekQkYUDbA9BDdslqLIxZCleJLAdc2vcik6aODG
# Pkcg+D1VMQSpA6/xU3vjAytaAejsEMGA/gwtQKcAXQG32OAOV2OjS6UC46OW8+i+
# b12p3o68MSo80F6G+Wl54ws9uwBgjXXYnGZift6cqHFFAdw51aOsXhuYj5z2/96E
# ++wIIRyfhJjcSVo3PDCo2bJG2YguO6bfx1xhIpVme0R//FgYsnZWOLECDiAZmcud
# xvhHed5e5Mjuok8dJ30ea+uv4snlzZlO433J9HjB7TUeV9WTmBDbBf79cckcMoyX
# EciYEHZs31DSUISqiSeUCDdXeWqa2C745rEEVPTGs/StWn4xrvmOE/7STPZjuCnT
# cAtFTPNacDupeIBsN6O8UTXLne+HGUWMre19Fvc9TH/2Q6GxdSHIUoin6U2dqdrx
# 8MWddBiGC41AEDzyMA3/uhEBV2KAEiSY3JsJYORjhxZhDOmENmz5XvV+4pTQ0bT3
# JVleDefQkt6LwKJGJ1tQoGN09+GNlfejTJ/0JNTr/sy/+AJztnbPvSo14kZ9LHuZ
# puiXrzCCBygwggUQoAMCAQICEzMAAAAVBT5uGY6TKdkAAAAAABUwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMjhaFw0zMTAzMjYxODExMjhaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDg9Ms9AqovDnMePvMOe+KybhCd8+lokzYO
# RlS3kBVXseecbyGwBcsenlm5bLtMGPjiIFLzBQF+ghlVV/U29q5GcdeEEBCHTTGh
# L2koIrLc4UrliMRcbv9mOMtR/l7/xAmv0Fx4BJHn1dHt37fvrBqXmKjKfGf5DpyO
# /+hnV7TEreMtS19iO+bjZ/9Hnpg3PCk0e7YSbRTFkx97FZwRWpC4s3NepRfRXQh/
# WMAj7JmsYeVZohi4TF5yW2JMrJZqwHcyzJZYtD2Hlno5ZEJkdiZcEaxHOobmwO06
# Z1J9c23ps9PGIhGaq1sKLEAz9Doc5rLkYWGteDrscKhAp2kIc/oYlH9Ij6BkOqqg
# WINEkEtC8ZNG1Mak+h3o65aj0iQKmdxW7IZaHO5cuyoMi+KtYfXeIIg3sVIbS2EL
# 8kUtsDGdEqNqAq/isqTi1jXqLe6iKp1ni1SPdvPW9G03CTsYF68b/yuIQRwbdoBC
# XemMNJCS0dorCRY4b2WAAy4ng7SANcEgrBgZf535+QfLU5hGzrKjIpbMabauWb5F
# KWUKkMsPcXFkXRWO4noKPm4KWlFypqOpbJ/KONVReIlxHQRegAOBzIhRB7gr9IDQ
# 1sc2MgOgQ+xVGW4oq4HD0mfAiwiyLskZrkaQ7JoanYjBNcR9RS26YxAVbcBtLitF
# TzCIEg5ZdQIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBRrXqU0wwXFYkohWo6rc2Bi1KxjhTBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBdbiI8zwXLX8glJEh/8Q22
# UMCUhWBO46Z9FPhwOR3mdlqRVLkYOon/MczUwrjDhx3X99SPH5PSflkGoTvnO9ZW
# HM5YFVYpO7NYuB+mfVSGAGZwiGOASWk0i2B7vn9nElJJmoiXxugfH5YdBsrUgTt0
# AFNXkzmqTgk+S1Hxb1u/0HCqEHVZPk2A/6eJXYbtpRM5Fcz00jisUl9BRZgSebOD
# V85bBzOveqyC3f0PnHCxRJNhMb8xP/sB/VI7pf2rheSV7zqUSv8vn/fIMblXeaVI
# lpqoq8SP9BJMjE/CoVXJxnkZQRM1Fa7kN9yztvReOhxSgPgpZx/Xl/jkwyEFVJTB
# fBp3sTgfIc/pmqv2ehtakL2AEj78EmOPQohxJT3wyX+P78GA25tLpAvzj3RMMHd8
# z18ZuuVi+60MAzGpOASH1L8Nlr3fZRZnQO+pyye2DCvYmHaIfdUgYJqn7noxxGVv
# 89+RaETh1tgCDvwNpFCSG7vl5A4ako+2fx409r9TWjXC7Oif1IQ5ZJzB4Rf8GvBi
# HYjvMmHpledp1FGRLdSRFVpC3/OKpZY6avIqZp7+8pP/WQP903DdgrvAT6W4xPOB
# xXPa4tGksN3SuqJaiFYHSNyeBufn8iseujW4IbBSbHD4BPqbF3qZ+7nG9d/d/G2/
# Lx4kH9cCmBfmsZdSkHmukDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
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
# rmcxghqRMIIajQIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDMCEzMAAFJBjuXzhdm+5a0AAAAAUkEwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgI4NDREiuQiVkae2Tvg9tsbnRtI7j6YacDlUwGLSuI54w
# DQYJKoZIhvcNAQEBBQAEggGA3NyfIdJOtJm2Igm0Ki7YhjLkMAxn9HLd1l4j/iOQ
# 8mfzbbUB7jVLysnn8zg+riYBpVlKrMyugVEJ1bSWDe6WHPlij6KFHaObS1SKjbV8
# 86I5Q4NzAWFyZ00QHS9taZGvlIzWCkIeoaHUMcxgOoleC/wQMdSz6yaxS+itOEu+
# GdCXvbPupYSsa8Pw3YGHJTyWJLRzGInx/h9hLMzUHTEATsvqnrKM8QL3KOufvCd1
# 4V0kV60m2RRKrWWOJ5sc+rP9rZGnruvegv3OMsdKKEWh6H+atwxZRPYfrpxh02VB
# TmTtf6SS09NTqvAE2GoT03WcwCrZgp8jCB+0Y9QXMFJHF207B5F8JPqgUVZZwGN/
# z5yKHffLIpn15De4o7v2wvsJXEEWuzvMIeb8UfbYkrsh3Cft2FJDZyI+pAURxue1
# MBE1iOtstut1bEobcAQ3vmmPm9r7zyt3AiGlEaAqIjkIpnttXHsZuee6D+z/PucI
# hbm8h/5dIMqeCnQHdL5X1glVoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIMgOat56HgAuV1rIEDVQi6GrQkXQxnVM3E/e70rFSpjYAgZpwnLdbdcYEzIw
# MjYwNDE1MDc0MDM4LjY5MVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RDAwLTA1RTAt
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
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFXZ3WkmKPn4
# 4gAAAAAAVTANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NDlaFw0yNjEw
# MjIyMDQ2NDlaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAvbkfkh5ZSLP0MCUWafaw/KZoVZu9iQx8
# r5JwhZvdrUi86UjCCFQONjQanrIxGF9hRGIZLQZ50gHrLC+4fpUEJff5t04VwByW
# C2/bWOuk6NmaTh9JpPZDcGzNR95QlryjfEjtl+gxj12zNPEdADPplVfzt8cYRWFB
# x/Fbfch08k6P9p7jX2q1jFPbUxWYJ+xOyGC1aKhDGY5b+8wL39v6qC0HFIx/v3y+
# bep+aEXooK8VoeWK+szfaFjXo8YTcvQ8UL4szu9HFTuZNv6vvoJ7Ju+o5aTj51sp
# h+0+FXW38TlL/rDBd5ia79jskLtOeHbDjkbljilwzegcxv9i49F05ZrS/5ELZCCY
# 1VaqO7EOLKVaxxdAO5oy1vb0Bx0ZRVX1mxFjYzay2EC051k6yGJHm58y1oe2IKRa
# /SM1+BTGse6vHNi5Q2d5ZnoR9AOAUDDwJIIqRI4rZz2MSinh11WrXTG9urF2uoyd
# 5Ve+8hxes9ABeP2PYQKlXYTAxvdaeanDTQ/vwmnM+yTcWzrVm84Z38XVFw4G7p/Z
# NZ2nscvv6uru2AevXcyV1t8ha7iWmhhgTWBNBrViuDlc3iPvOz2SVPbPeqhyY/NX
# wNZCAgc2H5pOztu6MwQxDIjte3XM/FkKBxHofS2abNT/0HG+xZtFqUJDaxgbJa6l
# N1zh7spjuQ8CAwEAAaOCAcswggHHMB0GA1UdDgQWBBRWBF8QbdwIA/DIv6nJFsrB
# 16xltjAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAFIe4ZJUe9qUKcWeWypchB58fXE/ZIWv2D5XP5/k/tB7
# LCN9BvmNSVKZ3VeclQM978wfEvuvdMQSUv6Y20boIM8DK1K1IU9cP21MG0ExiHxa
# qjrikf2qbfrXIip4Ef3v2bNYKQxCxN3Sczp1SX0H7uqK2L5OhfDEiXf15iou5hh+
# EPaaqp49czNQpJDOR/vfJghUc/qcslDPhoCZpZx8b2ODvywGQNXwqlbsmCS24uGm
# EkQ3UH5JUeN6c91yasVchS78riMrm6R9ZpAiO5pfNKMGU2MLm1A3pp098DcbFTAc
# 95Hh6Qvkh//28F/Xe2bMFb6DL7Sw0ZO95v0gv0ZTyJfxS/LCxfraeEII9FSFOKAM
# Ep1zNFSs2ue0GGjBt9yEEMUwvxq9ExFz0aZzYm8ivJfffpIVDnX/+rVRTYcxIkQy
# FYslIhYlWF9SjCw5r49qakjMRNh8W9O7aaoolSVZleQZjGt0K8JzMlyp6hp2lbW6
# XqRx2cOHbbxJDxmENzohGUziI13lI2g2Bf5qibfC4bKNRpJo9lbE8HUbY0qJiE8u
# 3SU8eDQaySPXOEhJjxRCQwwOvejYmBG5P7CckQNBSnnl12+FKRKgPoj0Mv+z5OMh
# j9z2MtpbnHLAkep0odQClEyyCG/uR5tK5rW6mZH5Oq56UWS0NI6NV1JGS7Jri6jF
# MYIHQzCCBz8CAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTANBglghkgBZQME
# AgEFAKCCBJwwEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDE1MDc0MDM4WjAvBgkqhkiG9w0B
# CQQxIgQgwWFrRpclYbABAb187X8Q9IFnT6O/GyN/V5X4hbLIqkowgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCDYuTyXZIZiu799/v4PaqsmeSzBxh0rqkYq7sYY
# avj+zTB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTCCA14GCyqGSIb3DQEJ
# EAISMYIDTTCCA0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0Qw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQAdO1QBgmW/tuBZV5EG
# jhfsV4cN6qBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2JSV0wIhgPMjAyNjA0
# MTQyMzE2NDVaGA8yMDI2MDQxNTIzMTY0NVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7YlJXQIBADAHAgEAAgIBgTAHAgEAAgIS5DAKAgUA7Yqa3QIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCo7N1LD1wTXtWi98e/AP60M73mKNO2JykanfEa
# 0xwy9w/MR3ht5hAsjfCZCPm8j+5sDOZY6Kav+05iHju74g9F9IDT50MQm1TKTvjx
# UsZaBQ8Av23i0f85TedPt9NBQQBLfPmMqTNsfTJ1SEZncxqSc8MO3vZ3IC8iN8Rp
# QrBObK+kY2+knH7gL4GhM8e1z9vJnxyX1AK++GIxNxZlK5GRjQ1F4du/4t71e8xg
# r4at7pj/v6Z7pn9tNfLiuuIid3i/GXfkCfyLaxzn5FQGFnUIId2oGsKuMuyrOrac
# KnvCEbNt8NebwNu8TFtAnixEno8rVbk8RNFMiN+jyiR9x/vuMA0GCSqGSIb3DQEB
# AQUABIICAB84J9Lr5mCEm4d5nknUXRLfS99Sh2LBdEnaSLHRW7UMGSz9lvF/w2be
# ZYXdEDr2HZhsucXgVBnl4XOLuOG0NQw04sDTDPFN+0N0Lo3Sloww8/dhJBCsTpFn
# X9LHQDZebinRqTSQVngGGTnij7c6XfSglEG8tvieseYsTjuQ9JGy72FxtidI94ZZ
# ejJMuRJYaMizn8lhHVa5g4bE3/qYZQTXht/QGMPLM6Zj3bhuGOMmJCUS5T5f/MJf
# UN8ps95rdxzrHDOit2V/MCxlI7iMFkL912RuAW1/3dF9NxwMHk0a+zLbf8kxLuU3
# TsSJmgfhsYA8c4ggwrd2PrtmxSx/9OZmITlR5q59W9UNahuxXuWXzgR+m78wl6Rq
# /2GRNstmVSJ2kiPxHzs9aodOmWLBq90NmhLt12TsFL1alnzKpgk1Nn/45I/kA92u
# 80bZELMzxU0DW73wI7VXMxXhrYEwGzC9YU9gqucwdgO+iCY9tSFP4YCcKed4HE2K
# /zylO/t50a26EG5iIkjrOzdUte1n9456OIl3uGE3cimYYa5tiFB1WEE0I9VHzxxN
# iKsuqqsclQ6oHtpXeZbcvXFk4bMUtHpM3Kh0TXBqD7I4UJ0BgasF803f9w59NLGs
# VGEQyxRcdk03zAYdm+wvEld/mWs/5s9xg7clOHXaxH/xFMV+XT+T
# SIG # End signature block

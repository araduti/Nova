function Start-AmpCloudEngineProcess {
    # Guard: prevent double invocation from both timer and WiFi click handler.
    if ($script:EngineStarted) { return }
    $script:EngineStarted = $true
    if ($script:connectCheckTimer) { $script:connectCheckTimer.Stop() }

    Update-Step 3
    Write-Status $S.Connected 'Green'
    Invoke-Sound 900 300
    $ringPanel.Visible = $true
    $ringTimer.Start()

    # ── M365 authentication gate ────────────────────────────────────────────
    # When Config/auth.json has requireAuth = true, the operator must sign in
    # with a Microsoft 365 account from an allowed Entra ID tenant.
    # Tenant restrictions are enforced at the app registration level.
    # Uses a standalone Edge browser with Auth Code + PKCE as
    # the primary method; falls back to Device Code Flow if the Edge
    # browser is not present in the WinPE image.
    $authPassed = Invoke-M365Auth
    if (-not $authPassed) {
        $script:EngineStarted = $false   # allow retry after WiFi reconnect
        $ringTimer.Stop()
        $ringPanel.Visible = $false
        return
    }

    # ── Autopilot device import ─────────────────────────────────────────────
    # When autopilotImport is enabled in auth.json and a Graph access token
    # was obtained during sign-in, register the device in Autopilot via
    # the Microsoft Graph API (delegated permissions — no client secret).
    # The device is only imported if it is not already registered.
    if ($script:AuthConfig -and $script:AuthConfig.autopilotImport -and $script:GraphAccessToken) {
        Write-AuthLog "Autopilot import enabled — checking device registration..."
        try {
            $serial = $null
            try { $serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber } catch {}
            if ($serial -and $serial.Trim() -ne '') {
                $sanitized = $serial -replace "['\\\x00-\x1f]", ''
                $filter = [uri]::EscapeDataString("contains(serialNumber,'$sanitized')")
                $uri    = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"
                $check  = Invoke-RestMethod -Uri $uri -Headers @{
                    'Authorization' = "Bearer $($script:GraphAccessToken)"
                } -Method GET

                if ($check.value -and $check.value.Count -gt 0) {
                    Write-AuthLog "Device $serial is already registered in Autopilot — skipping import."
                } else {
                    Write-AuthLog "Device $serial not found in Autopilot — this device can be imported after OS deployment using the Autopilot tools."
                }
            } else {
                Write-AuthLog "Could not determine device serial number — skipping Autopilot check."
            }
        } catch {
            Write-AuthLog "Autopilot check failed (non-fatal): $_"
        }
    }

    Update-Step 4

    # Unified configuration dialog: language + all Windows options in one step.
    $config = Show-ConfigurationMenu
    $script:Lang = $config.Language
    $script:S    = $Strings[$script:Lang]
    $script:SelectedEdition  = $config.Edition
    $script:SelectedOsLang   = $config.OsLanguage
    $script:SelectedArch     = $config.Architecture
    $script:SelectedActivation = $config.Activation

    # Clean up any stale status file from a previous run.
    if (Test-Path $script:StatusFile) { Remove-Item $script:StatusFile -Force }

    # Prefer the pre-staged copy embedded in the WinPE image by Trigger.ps1.
    # Fall back to downloading from GitHub when the local copy is absent.
    $engineFailed = $false
    try {
        $localAmpCloud = Join-Path $env:SystemRoot 'System32\AmpCloud.ps1'
        if (-not (Test-Path $localAmpCloud)) {
            $url    = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/AmpCloud.ps1"
            $localAmpCloud = 'X:\AmpCloud.ps1'
            Write-Status ($S.Download -f 0)
            $web = New-Object System.Net.WebClient
            $web.add_DownloadProgressChanged({
                param($eventSender, $e)
                $null = $eventSender  # Required by .NET delegate signature
                Write-Status ($S.Download -f $e.ProgressPercentage)
            })
            $task = $web.DownloadFileTaskAsync($url, $localAmpCloud)
            while (-not $task.IsCompleted) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            if ($task.IsFaulted) { throw $task.Exception.InnerException }
        }

        # Run AmpCloud.ps1 in a dedicated process so the WinForms UI thread
        # stays responsive and the spinner keeps animating.
        # Detect firmware type so AmpCloud partitions and configures the
        # bootloader correctly (UEFI → GPT + bcdboot /f UEFI,
        # BIOS → MBR + bcdboot /f BIOS).  wpeutil UpdateBootInfo already
        # populated the PEFirmwareType registry value during WinPE init.
        $detectedFirmware = 'UEFI'
        try {
            $fwVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' `
                                       -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
            if ($fwVal -eq 1) { $detectedFirmware = 'BIOS' }
        } catch { Write-Verbose "PEFirmwareType unavailable: $_" }

        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $localAmpCloud,
                    '-StatusFile', $script:StatusFile,
                    '-FirmwareType', $detectedFirmware)
        if ($script:SelectedEdition)  { $psArgs += @('-WindowsEdition',      $script:SelectedEdition)  }
        if ($script:SelectedOsLang)   { $psArgs += @('-WindowsLanguage',     $script:SelectedOsLang)   }
        if ($script:SelectedArch)     { $psArgs += @('-WindowsArchitecture', $script:SelectedArch)     }
        $engineProc = Start-Process -FilePath $script:PsBin -ArgumentList $psArgs -WindowStyle Hidden -PassThru

        # Start polling the status file so the UI shows real-time progress.
        $script:uiUpdateTimer.Start()

        Write-Status $S.Imaging 'Cyan'
        while (-not $engineProc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
        if ($engineProc.ExitCode -ne 0) { $engineFailed = $true }
    } catch {
        # Engine already printed diagnostics; close the UI so the console
        # is usable.  The -NoExit PowerShell host from ampcloud-start.cmd
        # provides the interactive prompt for troubleshooting.
        $engineFailed = $true
    }

    $script:uiUpdateTimer.Stop()
    $ringTimer.Stop()
    Stop-Transcript -ErrorAction SilentlyContinue
    $form.Close()

    if (-not $engineFailed) {
        Show-CompletionScreen
    }
}

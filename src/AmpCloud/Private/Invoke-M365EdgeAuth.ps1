function Invoke-M365EdgeAuth {
    <#
    .SYNOPSIS  Authenticate the operator via a standalone Edge browser (Auth Code + PKCE).
    .DESCRIPTION
        Launches msedge.exe directly in WinPE with GPU-disabled flags and
        navigates to the Azure AD authorization endpoint.  The user signs in
        inside the standalone Edge browser window.  A temporary localhost
        HTTP listener captures the redirect carrying the authorization code,
        then exchanges it for tokens using PKCE.
        Requires the Edge browser to be pre-staged in the WinPE image at
        X:\WebView2\Edge (done by Trigger.ps1 Build-WinPE step 4e).
        WinPE-safe Chromium flags (--disable-gpu, SwiftShader, etc.) are
        used to ensure rendering works without GPU hardware.
    .PARAMETER ClientId
        Azure AD application (client) ID.
    .OUTPUTS
        $true on success, $false on failure or cancellation.
    #>
    param(
        [string] $ClientId,
        [string] $Scope = 'openid profile'
    )

    $edgePath = 'X:\WebView2\Edge\msedge.exe'

    # ── Log environment diagnostics ─────────────────────────────────────────
    Write-AuthLog "Edge auth starting — checking prerequisites"
    Write-AuthLog "  msedge.exe exists : $(Test-Path $edgePath)  ($edgePath)"

    # ── Verify Edge browser prerequisite ────────────────────────────────────
    if (-not (Test-Path $edgePath)) {
        Write-AuthLog "msedge.exe not found at $edgePath — skipping Edge auth."
        return $false
    }

    # ── PKCE code verifier and challenge (RFC 7636) ─────────────────────────
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $codeVerifier  = [Convert]::ToBase64String($bytes) -replace '\+','-' -replace '/','_' -replace '='

    $sha256        = [System.Security.Cryptography.SHA256]::Create()
    $challengeHash = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
    $codeChallenge = [Convert]::ToBase64String($challengeHash) -replace '\+','-' -replace '/','_' -replace '='

    # ── Start a temporary localhost HTTP listener ───────────────────────────
    # A random high port is used to avoid conflicts.  The listener captures
    # the OAuth redirect after the user completes sign-in in Edge.
    $listener    = New-Object System.Net.HttpListener
    $redirectUri = $null
    foreach ($attempt in 1..5) {
        $port        = Get-Random -Minimum 49152 -Maximum 65535
        $redirectUri = "http://localhost:$port/"
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add($redirectUri)
        try {
            $listener.Start()
            Write-AuthLog "HTTP listener started on port $port"
            break
        } catch {
            Write-AuthLog "Listener port $port failed (attempt $attempt of 5): $_"
            if ($attempt -eq 5) {
                Write-AuthLog "Could not start HTTP listener after $attempt attempts."
                return $false
            }
        }
    }

    try {

    # ── Build the authorize URL ─────────────────────────────────────────────
    $authorizeUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?' +
        "client_id=$([uri]::EscapeDataString($ClientId))" +
        '&response_type=code' +
        "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
        "&scope=$([uri]::EscapeDataString($Scope))" +
        "&code_challenge=$codeChallenge" +
        '&code_challenge_method=S256' +
        '&prompt=select_account'

    # ── Launch Edge with WinPE-safe Chromium flags ──────────────────────────
    # WinPE has no GPU hardware or driver stack.  These flags force Chromium
    # to use SwiftShader (software OpenGL ES implementation) for rendering.
    # --allow-run-as-system permits Chromium to run under the SYSTEM account
    # (WinPE always runs as SYSTEM).
    # --user-data-dir avoids writing to the default profile path, which may
    # not be writable in WinPE.
    # --no-first-run / --disable-fre suppress Edge first-run experience
    # screens (welcome wizard, default-browser prompt, etc.).
    # --disable-features=msWebOOBE suppresses the Edge out-of-box setup.
    # WebAuthentication is left enabled so that the cross-device / hybrid
    # (caBLE v2) flow works — the user can scan a QR code with a phone
    # (e.g. iPhone or Android) to complete FIDO2 / passkey authentication.
    # Platform authenticators (TPM, Windows Hello, biometrics) are
    # unavailable in WinPE, but Edge automatically skips them when the
    # hardware is absent and offers the QR-code option instead.
    # --enable-features=WebAuthenticationCableSecondFactor explicitly
    # enables the cross-device QR code authenticator flow.
    $userDataDir = 'X:\Temp\EdgeAuthData'
    if (-not (Test-Path $userDataDir)) {
        $null = New-Item -Path $userDataDir -ItemType Directory -Force
    }

    $edgeArgs = @(
        '--allow-run-as-system'
        "--user-data-dir=`"$userDataDir`""
        '--disable-gpu'
        '--disable-gpu-compositing'
        '--disable-direct-composition'
        '--use-angle=swiftshader'
        '--enable-unsafe-swiftshader'
        '--in-process-gpu'
        '--no-first-run'
        '--disable-fre'
        '--disable-features=msWebOOBE'
        '--enable-features=WebAuthenticationCableSecondFactor'
        $authorizeUrl
    )

    Write-AuthLog "Launching Edge: $edgePath $($edgeArgs -join ' ')"
    $edgeProcess = $null
    try {
        $edgeProcess = Start-Process -FilePath $edgePath -ArgumentList $edgeArgs -PassThru
        Write-AuthLog "Edge launched (PID $($edgeProcess.Id))"
    } catch {
        Write-AuthLog "Failed to launch Edge: $_"
        return $false
    }

    # ── Show a WinForms status dialog while waiting for sign-in ─────────────
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'AmpCloud — Sign In'
    $dlg.Size            = New-Object System.Drawing.Size(480, 220)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = [System.Drawing.Color]::White
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.TopMost         = $false

    $msLabel = New-Object System.Windows.Forms.Label
    $msLabel.Text      = 'Microsoft 365'
    $msLabel.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
    $msLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $msLabel.Location  = New-Object System.Drawing.Point(30, 20)
    $msLabel.AutoSize  = $true
    $dlg.Controls.Add($msLabel)

    $promptLabel = New-Object System.Windows.Forms.Label
    $promptLabel.Text     = $S.AuthEdgePrompt
    $promptLabel.Location = New-Object System.Drawing.Point(30, 65)
    $promptLabel.Size     = New-Object System.Drawing.Size(410, 50)
    $promptLabel.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.Controls.Add($promptLabel)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text         = 'Cancel'
    $cancelBtn.Size         = New-Object System.Drawing.Size(120, 36)
    $cancelBtn.Location     = New-Object System.Drawing.Point(330, 135)
    $cancelBtn.DialogResult = 'Cancel'
    $cancelBtn.FlatStyle    = 'Flat'
    $dlg.Controls.Add($cancelBtn)
    $dlg.CancelButton = $cancelBtn

    # ── Poll the HTTP listener for the redirect in a timer ──────────────────
    $script:_edgeAuthCode  = $null
    $script:_edgeAuthError = $null
    $script:_edgeListener  = $listener
    $script:_edgeDlg       = $dlg
    $script:_edgeAsyncResult = $listener.BeginGetContext($null, $null)

    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 500
    $pollTimer.Add_Tick({
        if ($script:_edgeAsyncResult.IsCompleted -or $script:_edgeAsyncResult.AsyncWaitHandle.WaitOne(0)) {
            $pollTimer.Stop()
            try {
                $context = $script:_edgeListener.EndGetContext($script:_edgeAsyncResult)

                # Parse authorization code (or error) from the query string.
                foreach ($pair in $context.Request.Url.Query.TrimStart('?').Split('&')) {
                    $kv = $pair.Split('=', 2)
                    if ($kv.Count -eq 2) {
                        if ($kv[0] -eq 'code')  { $script:_edgeAuthCode  = [uri]::UnescapeDataString($kv[1]) }
                        if ($kv[0] -eq 'error') { $script:_edgeAuthError = [uri]::UnescapeDataString($kv[1]) }
                    }
                }

                # Send a friendly response page to the browser.
                $html = if ($script:_edgeAuthCode) {
                    '<html><body style="font-family:Segoe UI,sans-serif;text-align:center;padding:60px">' +
                    '<h2 style="color:#107c10">&#10004; Sign-in complete</h2>' +
                    '<p>You can close this window and return to AmpCloud.</p>' +
                    '<script>setTimeout(function(){window.close()},2000)</script></body></html>'
                } else {
                    '<html><body style="font-family:Segoe UI,sans-serif;text-align:center;padding:60px">' +
                    '<h2 style="color:#d13438">&#10008; Sign-in failed</h2>' +
                    '<p>Please close this window and try again.</p></body></html>'
                }
                $buf = [System.Text.Encoding]::UTF8.GetBytes($html)
                $context.Response.ContentType     = 'text/html; charset=utf-8'
                $context.Response.ContentLength64 = $buf.Length
                $context.Response.OutputStream.Write($buf, 0, $buf.Length)
                $context.Response.OutputStream.Close()
            } catch {
                Write-AuthLog "Listener callback error: $_"
            }

            if ($script:_edgeAuthCode) {
                $script:_edgeDlg.DialogResult = 'OK'
            } else {
                $script:_edgeDlg.DialogResult = 'Abort'
            }
            $script:_edgeDlg.Close()
        }
    })
    $pollTimer.Start()
    $dialogResult = $dlg.ShowDialog()
    $pollTimer.Stop()
    $pollTimer.Dispose()
    try { $dlg.Dispose() } catch {}

    # ── Stop the Edge process ───────────────────────────────────────────────
    if ($edgeProcess -and -not $edgeProcess.HasExited) {
        try {
            $edgeProcess.CloseMainWindow() | Out-Null
            if (-not $edgeProcess.WaitForExit(3000)) {
                $edgeProcess.Kill()
                $edgeProcess.WaitForExit(2000)
            }
            Write-AuthLog "Edge process stopped."
        } catch { Write-AuthLog "Edge process cleanup: $_" }
    }

    # Clean up Edge user data (cookies, cache) to prevent credential leakage.
    if (Test-Path $userDataDir) {
        try { Remove-Item $userDataDir -Recurse -Force } catch {}
    }

    } finally {
        try { $listener.Stop(); $listener.Close() } catch {}
    }

    if ($dialogResult -ne 'OK' -or -not $script:_edgeAuthCode) {
        $codeStatus = if ($script:_edgeAuthCode) { 'present' } else { 'missing' }
        Write-AuthLog "Edge auth dialog closed without auth code. DialogResult=$dialogResult, AuthCode=$codeStatus"
        if ($script:_edgeAuthError) {
            Write-AuthLog "Edge auth error: $($script:_edgeAuthError)"
        }
        return $false
    }

    # ── Exchange authorization code for tokens ──────────────────────────────
    $tokenUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token'
    try {
        $body = "client_id=$([uri]::EscapeDataString($ClientId))" +
                "&scope=$([uri]::EscapeDataString($Scope))" +
                "&code=$([uri]::EscapeDataString($script:_edgeAuthCode))" +
                "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
                '&grant_type=authorization_code' +
                "&code_verifier=$([uri]::EscapeDataString($codeVerifier))"
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
        $raw = $wc.UploadString($tokenUrl, 'POST', $body)
        $tokenResponse = $raw | ConvertFrom-Json
        if ($tokenResponse.id_token) {
            if ($tokenResponse.access_token) {
                $script:GraphAccessToken = $tokenResponse.access_token
            }
            Write-AuthLog "Edge auth succeeded — token obtained."
            return $true
        }
    } catch {
        Write-AuthLog "Token exchange failed: $_"
    }

    return $false
}

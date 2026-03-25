function Invoke-BootstrapM365DeviceCodeAuth {
    <#
    .SYNOPSIS  Authenticate the operator via Device Code Flow (fallback).
    .DESCRIPTION
        Fallback authentication path used when the Edge browser is not
        available in the WinPE image.  Initiates the Device Code Flow and
        shows a WinForms dialog with the one-time code and verification URL.
    .PARAMETER ClientId
        Azure AD application (client) ID.
    .PARAMETER Scope
        OAuth 2.0 scopes to request (space-separated).
    .OUTPUTS
        $true on success, $false on failure or cancellation.
    #>
    param(
        [string] $ClientId,
        [string] $Scope = 'openid profile'
    )

    $deviceCodeUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode'
    $tokenUrl      = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token'
    $grantType     = 'urn:ietf:params:oauth:grant-type:device_code'

    $deviceResponse = $null
    try {
        $body = "client_id=$([uri]::EscapeDataString($ClientId))&scope=$([uri]::EscapeDataString($Scope))"
        $wc   = New-Object System.Net.WebClient
        $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
        $raw  = $wc.UploadString($deviceCodeUrl, 'POST', $body)
        $deviceResponse = $raw | ConvertFrom-Json
    } catch {
        Write-AuthLog "Device code request failed: $_"
        return $false
    }

    $userCode   = $deviceResponse.user_code
    $deviceCode = $deviceResponse.device_code
    $expiresIn  = if ($deviceResponse.expires_in) { [int]$deviceResponse.expires_in } else { 900 }
    $interval   = if ($deviceResponse.interval)   { [int]$deviceResponse.interval   } else { 5   }

    # ── Device Code dialog ──────────────────────────────────────────────────
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'AmpCloud — Sign In'
    $dlg.Size            = New-Object System.Drawing.Size(520, 380)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = [System.Drawing.Color]::White
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 10)

    $msLabel = New-Object System.Windows.Forms.Label
    $msLabel.Text      = 'Microsoft 365'
    $msLabel.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
    $msLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $msLabel.Location  = New-Object System.Drawing.Point(30, 25)
    $msLabel.AutoSize  = $true
    $dlg.Controls.Add($msLabel)

    $promptLabel = New-Object System.Windows.Forms.Label
    $promptLabel.Text     = $S.AuthDeviceCodePrompt
    $promptLabel.Location = New-Object System.Drawing.Point(30, 75)
    $promptLabel.Size     = New-Object System.Drawing.Size(450, 50)
    $promptLabel.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.Controls.Add($promptLabel)

    $codeBox = New-Object System.Windows.Forms.TextBox
    $codeBox.Text      = $userCode
    $codeBox.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 26)
    $codeBox.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $codeBox.TextAlign = 'Center'
    $codeBox.ReadOnly  = $true
    $codeBox.BorderStyle = 'None'
    $codeBox.BackColor = [System.Drawing.Color]::FromArgb(243, 243, 243)
    $codeBox.Location  = New-Object System.Drawing.Point(60, 135)
    $codeBox.Size      = New-Object System.Drawing.Size(380, 55)
    $dlg.Controls.Add($codeBox)

    $urlLabel = New-Object System.Windows.Forms.Label
    $urlLabel.Text      = $S.AuthUrl
    $urlLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Underline)
    $urlLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $urlLabel.Location  = New-Object System.Drawing.Point(30, 210)
    $urlLabel.AutoSize  = $true
    $dlg.Controls.Add($urlLabel)

    $authStatusLabel = New-Object System.Windows.Forms.Label
    $authStatusLabel.Text      = $S.AuthWaiting
    $authStatusLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
    $authStatusLabel.ForeColor = [System.Drawing.Color]::Gray
    $authStatusLabel.Location  = New-Object System.Drawing.Point(30, 250)
    $authStatusLabel.Size      = New-Object System.Drawing.Size(450, 25)
    $dlg.Controls.Add($authStatusLabel)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text         = 'Cancel'
    $cancelBtn.Size         = New-Object System.Drawing.Size(120, 40)
    $cancelBtn.Location     = New-Object System.Drawing.Point(370, 290)
    $cancelBtn.DialogResult = 'Cancel'
    $cancelBtn.FlatStyle    = 'Flat'
    $dlg.Controls.Add($cancelBtn)
    $dlg.CancelButton = $cancelBtn

    # ── Poll for token in a timer ───────────────────────────────────────────
    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = $interval * 1000
    $script:_authExpiry   = [datetime]::UtcNow.AddSeconds($expiresIn)
    $script:_authResult   = $null
    $script:_deviceCode   = $deviceCode
    $script:_clientId     = $ClientId
    $script:_tokenUrl     = $tokenUrl
    $script:_grantType    = $grantType

    $pollTimer.Add_Tick({
        if ([datetime]::UtcNow -ge $script:_authExpiry) {
            $pollTimer.Stop()
            $authStatusLabel.Text = $S.AuthFailed
            $authStatusLabel.ForeColor = [System.Drawing.Color]::Red
            return
        }
        try {
            $body = "grant_type=$([uri]::EscapeDataString($script:_grantType))" +
                    "&client_id=$([uri]::EscapeDataString($script:_clientId))" +
                    "&device_code=$([uri]::EscapeDataString($script:_deviceCode))"
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
            $raw = $wc.UploadString($script:_tokenUrl, 'POST', $body)
            $tokenResponse = $raw | ConvertFrom-Json
            if ($tokenResponse.id_token) {
                $script:_authResult = $tokenResponse
                if ($tokenResponse.access_token) {
                    $script:GraphAccessToken = $tokenResponse.access_token
                }
                $pollTimer.Stop()
                $dlg.DialogResult = 'OK'
                $dlg.Close()
            }
        } catch {
            $msg = $_.ToString()
            if ($msg -notmatch 'authorization_pending' -and $msg -notmatch 'slow_down') {
                Write-AuthLog "Token poll error: $msg"
            }
        }
    })
    $pollTimer.Start()
    $dialogResult = $dlg.ShowDialog()
    $pollTimer.Stop()
    $pollTimer.Dispose()

    if ($dialogResult -ne 'OK' -or -not $script:_authResult) {
        return $false
    }

    return $true
}

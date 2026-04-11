<#
.SYNOPSIS
    Microsoft 365 / Entra ID authentication module for Nova.

.DESCRIPTION
    Provides OAuth2 Authorization Code Flow with PKCE for authenticating
    OSD operators.  A single Invoke-M365Auth entry point auto-detects the
    environment (full Windows vs WinPE) and sets appropriate Edge flags
    and grace periods.
    Also includes token refresh via Update-M365Token.
#>

Set-StrictMode -Version Latest

#region ── Private helpers ──────────────────────────────────────────────────────

function _HasProp {
    <# Safely check if a PSCustomObject has a named property. #>
    param([psobject]$Obj, [string]$Name)
    return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name])
}

function _FetchAuthConfig {
    <#
    .SYNOPSIS  Download and validate config/auth.json from GitHub.
    .OUTPUTS
        [hashtable] with keys:
          Required   [bool]   $true when auth is required and config is valid.
          AuthConfig [object] The parsed auth.json, or $null.
          ClientId   [string] The validated client ID, or $null.
          Scope      [string] The resolved OAuth scope string, or $null.
    #>
    param(
        [string]$GitHubUser,
        [string]$GitHubRepo,
        [string]$GitHubBranch,
        [scriptblock]$WriteLog
    )

    $skip = @{ Required = $false; AuthConfig = $null; ClientId = $null; Scope = $null }

    $authConfigUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/auth.json"
    $authConfig    = $null
    try {
        $wc      = New-Object System.Net.WebClient
        $rawJson = $wc.DownloadString($authConfigUrl)
        $authConfig = $rawJson | ConvertFrom-Json
    } catch {
        if ($WriteLog) { & $WriteLog "Could not fetch auth config: $_" }
    }

    if (-not $authConfig -or -not ((_HasProp $authConfig 'requireAuth') -and $authConfig.requireAuth)) {
        return $skip
    }

    if (-not ((_HasProp $authConfig 'clientId') -and $authConfig.clientId)) {
        if ($WriteLog) { & $WriteLog "Auth config incomplete -- skipping authentication." }
        return $skip
    }

    $scope = 'openid profile'
    if ((_HasProp $authConfig 'graphScopes') -and $authConfig.graphScopes) {
        $trimmed = ($authConfig.graphScopes).Trim()
        if ($trimmed) { $scope = "openid profile $trimmed" }
    }

    return @{
        Required   = $true
        AuthConfig = $authConfig
        ClientId   = $authConfig.clientId
        Scope      = $scope
    }
}

function _EdgeAppAuth {
    <#
    .SYNOPSIS  Authenticate via Edge --app popup (Auth Code + PKCE).
    .DESCRIPTION
        Generates PKCE codes, starts a localhost HTTP listener, launches Edge
        in --app mode pointing at the Entra ID authorization endpoint, waits
        for the redirect callback, and exchanges the authorization code for
        tokens.

        Environment differences are handled through parameters:
          - ExtraEdgeArgs: WinPE passes GPU-related flags.
          - EdgeExitGracePeriod: full Windows allows a grace period because
            Edge may hand off window creation to an existing process.
          - WaitForDns: WinPE waits for DNS readiness after WiFi connects.
    .OUTPUTS
        [hashtable] with keys:
          Success          [bool]     $true if auth succeeded.
          GraphAccessToken [string]   Microsoft Graph access token, or $null.
          RefreshToken     [string]   Refresh token, or $null.
          ExpiresAt        [datetime] Token expiration time, or $null.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClientId,
        [string]$Scope = 'openid profile',
        [Parameter(Mandatory)]
        [string]$EdgeExePath,
        [Parameter(Mandatory)]
        [string]$EdgeDataDir,
        [string[]]$ExtraEdgeArgs = @(),
        [int]$EdgeExitGracePeriod = 0,
        [switch]$WaitForDns,
        [scriptblock]$WriteLog,
        [scriptblock]$UpdateUi,
        [scriptblock]$CheckCancelled,
        [scriptblock]$DoEvents
    )

    $fail = @{ Success = $false; GraphAccessToken = $null; RefreshToken = $null; ExpiresAt = $null }

    # ── Verify Edge binary exists ───────────────────────────────────────────
    if (-not (Test-Path $EdgeExePath)) {
        if ($WriteLog) { & $WriteLog "Edge not found at $EdgeExePath -- cannot open auth window." }
        return $fail
    }

    if ($WriteLog) { & $WriteLog "Edge app auth starting" }

    # ── PKCE code verifier and challenge (RFC 7636) ─────────────────────────────
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $codeVerifier  = [Convert]::ToBase64String($bytes) -replace '\+','-' -replace '/','_' -replace '='

    $sha256        = [System.Security.Cryptography.SHA256]::Create()
    $challengeHash = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
    $codeChallenge = [Convert]::ToBase64String($challengeHash) -replace '\+','-' -replace '/','_' -replace '='

    # ── Start a temporary localhost HTTP listener ───────────────────────────────
    $listener    = New-Object System.Net.HttpListener
    $redirectUri = $null
    foreach ($attempt in 1..5) {
        $port        = Get-Random -Minimum 49152 -Maximum 65535
        $redirectUri = "http://localhost:$port/"
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add($redirectUri)
        try {
            $listener.Start()
            if ($WriteLog) { & $WriteLog "HTTP listener started on port $port" }
            break
        } catch {
            if ($WriteLog) { & $WriteLog "Listener port $port failed (attempt $attempt of 5): $_" }
            if ($attempt -eq 5) {
                if ($WriteLog) { & $WriteLog "Could not start HTTP listener after $attempt attempts." }
                return $fail
            }
        }
    }

    $authCode  = $null
    $authError = $null
    $edgeProc  = $null

    try {

    # ── Build the authorize URL ───────────────────────────────────────────
    $authorizeUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?' +
        "client_id=$([uri]::EscapeDataString($ClientId))" +
        '&response_type=code' +
        "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
        "&scope=$([uri]::EscapeDataString($Scope))" +
        "&code_challenge=$codeChallenge" +
        '&code_challenge_method=S256' +
        '&prompt=select_account'

    # ── Optionally wait for DNS readiness ──────────────────────────────────────
    if ($WaitForDns) {
        $loginHost = 'login.microsoftonline.com'
        $dnsReady  = $false
        for ($dnsAttempt = 1; $dnsAttempt -le 10; $dnsAttempt++) {
            try {
                $null = [System.Net.Dns]::GetHostAddresses($loginHost)
                $dnsReady = $true
                break
            } catch {
                if ($WriteLog) { & $WriteLog "DNS lookup for $loginHost failed (attempt $dnsAttempt of 10)" }
                Start-Sleep -Milliseconds 500
            }
        }
        if (-not $dnsReady) {
            if ($WriteLog) { & $WriteLog "Cannot resolve $loginHost -- proceeding anyway" }
        }
    }

    # ── Clean up stale singleton files to prevent hand-off to a zombie instance ──
    if (Test-Path $EdgeDataDir) {
        foreach ($f in @('lockfile', 'SingletonLock', 'SingletonSocket', 'SingletonCookie')) {
            try { Remove-Item (Join-Path $EdgeDataDir $f) -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        }
    }

    # ── Launch Edge in --app mode ──────────────────────────────────────────
    if ($WriteLog) { & $WriteLog "Launching Edge --app for auth popup" }
    $edgeArgs = @(
        "--app=$authorizeUrl",
        "--user-data-dir=$EdgeDataDir",
        '--window-size=520,700',
        '--no-first-run',
        '--disable-fre',
        '--inprivate',
        '--disable-features=msWebOOBE,PasswordManager',
        '--password-store=basic',
        '--disable-save-password-bubble'
    ) + $ExtraEdgeArgs
    $edgeProc = Start-Process -FilePath $EdgeExePath -ArgumentList $edgeArgs -PassThru
    $edgeLaunchPid = if ($edgeProc) { $edgeProc.Id } else { $null }

    if ($UpdateUi) { & $UpdateUi @{ AuthInProgress = $true } }

    # ── Wait for the redirect callback ──────────────────────────────────────
    $asyncResult = $listener.BeginGetContext($null, $null)
    $cancelled = $false

    while (-not $authCode -and -not $authError `
           -and -not $cancelled) {

        if ($CheckCancelled) { $cancelled = (& $CheckCancelled) -eq $true }

        if ($edgeProc -and $edgeProc.HasExited) {
            if ($EdgeExitGracePeriod -gt 0) {
                # Full Windows: Edge may hand off to an existing browser
                # process, causing the launched process to exit immediately
                # while the sign-in window stays open in the existing browser.
                # Stop monitoring the process and keep waiting for the HTTP
                # listener callback, which will fire when the user completes
                # sign-in regardless of which Edge process renders the window.
                if ($WriteLog) { & $WriteLog "Edge process exited (likely handed off to existing browser). Waiting for sign-in callback..." }
                $edgeProc = $null
            } else {
                if ($WriteLog) { & $WriteLog "Edge auth window was closed by user." }
                $cancelled = $true
                break
            }
        }

        if ($asyncResult.IsCompleted -or $asyncResult.AsyncWaitHandle.WaitOne(0)) {
            try {
                $context = $listener.EndGetContext($asyncResult)

                foreach ($pair in $context.Request.Url.Query.TrimStart('?').Split('&')) {
                    $kv = $pair.Split('=', 2)
                    if ($kv.Count -eq 2) {
                        if ($kv[0] -eq 'code')  { $authCode  = [uri]::UnescapeDataString($kv[1]) }
                        if ($kv[0] -eq 'error') { $authError = [uri]::UnescapeDataString($kv[1]) }
                    }
                }

                # Send a response page that shows result and closes.
                $html = if ($authCode) {
                    '<html><body style="background:#1a1a2e;color:#e0e0e0;font-family:Segoe UI,sans-serif;' +
                    'display:flex;align-items:center;justify-content:center;height:100vh;margin:0">' +
                    '<div style="text-align:center"><h2 style="color:#107c10">&#10004; Sign-in complete</h2>' +
                    '<p>This window will close automatically...</p></div>' +
                    '<script>setTimeout(function(){window.close()},1500)</script></body></html>'
                } else {
                    '<html><body style="background:#1a1a2e;color:#e0e0e0;font-family:Segoe UI,sans-serif;' +
                    'display:flex;align-items:center;justify-content:center;height:100vh;margin:0">' +
                    '<div style="text-align:center"><h2 style="color:#d13438">&#10008; Sign-in failed</h2>' +
                    '<p>This window will close automatically...</p></div>' +
                    '<script>setTimeout(function(){window.close()},2500)</script></body></html>'
                }
                $buf = [System.Text.Encoding]::UTF8.GetBytes($html)
                $context.Response.ContentType     = 'text/html; charset=utf-8'
                $context.Response.ContentLength64 = $buf.Length
                $context.Response.OutputStream.Write($buf, 0, $buf.Length)
                $context.Response.OutputStream.Close()
            } catch {
                if ($WriteLog) { & $WriteLog "Listener callback error: $_" }
            }
        }

        if ($DoEvents) { & $DoEvents }
        Start-Sleep -Milliseconds 200
    }

    } finally {
        # ── Clean up: stop listener and kill the Edge --app process ──────────────
        try { $listener.Stop(); $listener.Close() } catch { $null = $_ }

        # Brief pause so the user can see the sign-in result before the window disappears.
        if ($authCode -or $authError) { Start-Sleep -Milliseconds 600 }

        if ($edgeProc -and -not $edgeProc.HasExited) {
            if ($WriteLog) { & $WriteLog "Closing Edge auth window (PID $($edgeProc.Id))" }
            try { $edgeProc.Kill() } catch { $null = $_ }
        }

        # When Edge handed off to an existing browser process, $edgeProc is
        # null or already exited.  Use taskkill /T on the original launch PID
        # to kill only that process tree -- this is safe because it targets
        # the exact PID we started and its children, not other Edge instances.
        # If the PID already exited, taskkill simply returns a non-zero exit
        # code which we ignore.
        if ($edgeLaunchPid) {
            try {
                $null = & taskkill /PID $edgeLaunchPid /T /F 2>&1
            } catch { $null = $_ }
        }

        # Remove stale lock files so the auth data dir can be reused.
        try { Remove-Item (Join-Path $EdgeDataDir 'lockfile')      -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        try { Remove-Item (Join-Path $EdgeDataDir 'SingletonLock') -Force -ErrorAction SilentlyContinue } catch { $null = $_ }

        if ($UpdateUi) { & $UpdateUi @{ ClearAuth = $true } }
    }

    if ($cancelled -or -not $authCode) {
        $codeStatus = if ($authCode) { 'present' } else { 'missing' }
        if ($WriteLog) { & $WriteLog "Edge app auth ended without auth code. Cancelled=$cancelled, AuthCode=$codeStatus" }
        if ($authError -and $WriteLog) {
            & $WriteLog "Auth error: $authError"
        }
        return $fail
    }

    # ── Exchange authorization code for tokens ────────────────────────────────
    $tokenUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token'
    try {
        $body = "client_id=$([uri]::EscapeDataString($ClientId))" +
                "&scope=$([uri]::EscapeDataString($Scope))" +
                "&code=$([uri]::EscapeDataString($authCode))" +
                "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
                '&grant_type=authorization_code' +
                "&code_verifier=$([uri]::EscapeDataString($codeVerifier))"
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
        $raw = $wc.UploadString($tokenUrl, 'POST', $body)
        $tokenResponse = $raw | ConvertFrom-Json
        if ((_HasProp $tokenResponse 'id_token') -and $tokenResponse.id_token) {
            $graphToken   = if ((_HasProp $tokenResponse 'access_token')  -and $tokenResponse.access_token)  { $tokenResponse.access_token }  else { $null }
            $refreshToken = if ((_HasProp $tokenResponse 'refresh_token') -and $tokenResponse.refresh_token) { $tokenResponse.refresh_token } else { $null }
            $expiresIn    = if ((_HasProp $tokenResponse 'expires_in')    -and $tokenResponse.expires_in)    { [int]$tokenResponse.expires_in } else { 3600 }
            $expiresAt    = (Get-Date).AddSeconds($expiresIn)
            if ($WriteLog) { & $WriteLog "Edge app auth succeeded -- token obtained." }
            return @{ Success = $true; GraphAccessToken = $graphToken; RefreshToken = $refreshToken; ExpiresAt = $expiresAt }
        }
    } catch {
        if ($WriteLog) { & $WriteLog "Token exchange failed: $_" }
    }

    return $fail
}

#endregion

#region ── Public functions ─────────────────────────────────────────────────────

function Invoke-M365Auth {
    <#
    .SYNOPSIS  Authenticate the operator via Edge --app sign-in (Auth Code + PKCE).
    .DESCRIPTION
        Downloads config/auth.json from the GitHub repository.  When
        requireAuth is true and a clientId is configured, the function
        launches Edge in --app mode for an interactive Entra ID sign-in
        using the Authorization Code Flow with PKCE.  A temporary
        localhost HTTP listener captures the redirect.

        Auto-detects the environment (full Windows vs WinPE) and applies
        the appropriate Edge flags and grace period:
          - Full Windows: 15 s edge-exit grace period, no extra Edge
            flags.
          - WinPE: 0 s grace period, GPU/SwiftShader flags, DNS wait.

        Tenant restrictions are enforced at the Entra ID app registration
        level -- only tenants explicitly allowed in the app's
        "Supported account types" configuration can complete sign-in.
    .PARAMETER GitHubUser   GitHub account that hosts the Nova repository.
    .PARAMETER GitHubRepo   Repository name.
    .PARAMETER GitHubBranch Branch to fetch auth config from.
    .PARAMETER EdgeExePath
        Full path to msedge.exe.  When omitted the function searches the
        standard Program Files locations (full OS) or X:\WebView2\Edge
        (WinPE).
    .PARAMETER WriteLog
        Scriptblock for writing auth log entries.  Receives a single
        string parameter.  Falls back to Write-Verbose when not supplied.
    .PARAMETER WriteStatus
        Scriptblock for writing user-visible status messages.  Receives
        (message, color).  Falls back to Write-Step / Write-Success /
        Write-Fail from Nova.Logging when not supplied.
    .PARAMETER UpdateUi     Scriptblock for updating the HTML UI.
    .PARAMETER CheckCancelled Scriptblock that returns $true when auth
        has been cancelled.
    .PARAMETER DoEvents     Scriptblock that pumps the WinForms message loop.
    .PARAMETER PlaySound    Scriptblock for playing sound feedback.
        Receives (frequency, duration).
    .NOTES
        The Entra ID app registration must include http://localhost as a
        redirect URI under the "Mobile and desktop applications" platform.
    .OUTPUTS
        [hashtable] with keys:
          Authenticated    [bool]     $true if auth succeeded or was not required.
          GraphAccessToken [string]   Microsoft Graph access token, or $null.
          RefreshToken     [string]   Refresh token, or $null.
          ExpiresAt        [datetime] Token expiration time, or $null.
          AuthConfig       [object]   The parsed auth.json config, or $null.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [string]$GitHubUser   = 'araduti',
        [string]$GitHubRepo   = 'Nova',
        [string]$GitHubBranch = 'main',
        [string]$EdgeExePath,
        [scriptblock]$WriteLog,
        [scriptblock]$WriteStatus,
        [scriptblock]$UpdateUi,
        [scriptblock]$CheckCancelled,
        [scriptblock]$DoEvents,
        [scriptblock]$PlaySound
    )

    $isWinPE = ($env:SystemDrive -eq 'X:')
    $skip    = @{ Authenticated = $true; GraphAccessToken = $null; RefreshToken = $null; ExpiresAt = $null; AuthConfig = $null }

    # ── Resolve logging callback ──────────────────────────────────────────
    $logFn = if ($WriteLog) { $WriteLog } else { { param([string]$m) Write-Verbose $m } }

    # ── Fetch and validate auth config ────────────────────────────────────
    $cfg = _FetchAuthConfig -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo `
                            -GitHubBranch $GitHubBranch -WriteLog $logFn
    if (-not $cfg.Required) {
        if ($WriteStatus) { & $WriteStatus 'Authentication not required' 'Green' }
        return $skip
    }

    # ── Status: signing in ────────────────────────────────────────────────
    if ($WriteStatus) {
        & $WriteStatus 'Signing in with Microsoft 365...' 'Cyan'
    } else {
        Write-Step 'Signing in with Microsoft 365...'
    }
    if ($DoEvents) { & $DoEvents }

    # ── Locate Edge ───────────────────────────────────────────────────────
    if (-not $EdgeExePath) {
        if ($isWinPE) {
            $EdgeExePath = 'X:\WebView2\Edge\msedge.exe'
        } else {
            foreach ($candidate in @(
                "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
            )) {
                if ($candidate -and (Test-Path $candidate)) {
                    $EdgeExePath = $candidate
                    break
                }
            }
        }
    }

    if (-not $EdgeExePath) {
        if ($WriteStatus) {
            & $WriteStatus 'Microsoft Edge is required but was not found.' 'Red'
        } else {
            Write-Fail 'Microsoft Edge is required but was not found.'
        }
        return @{ Authenticated = $false; GraphAccessToken = $null; RefreshToken = $null; ExpiresAt = $null; AuthConfig = $cfg.AuthConfig }
    }

    # ── Environment-specific Edge settings ────────────────────────────────
    if ($isWinPE) {
        $edgeDataDir   = 'X:\Temp\EdgeAuth'
        $extraEdgeArgs = @(
            '--allow-run-as-system',
            '--disable-gpu',
            '--disable-gpu-compositing',
            '--disable-direct-composition',
            '--use-angle=swiftshader',
            '--enable-unsafe-swiftshader',
            '--in-process-gpu'
        )
        $gracePeriod = 0
        $waitForDns  = $true
    } else {
        $edgeDataDir   = Join-Path $env:TEMP 'Nova-EdgeAuth'
        $extraEdgeArgs = @()
        $gracePeriod   = 15
        $waitForDns    = $false
    }

    # ── Run the PKCE auth flow ────────────────────────────────────────────
    $edgeResult = @{ Success = $false; GraphAccessToken = $null; RefreshToken = $null; ExpiresAt = $null }
    $authParams = @{
        ClientId            = $cfg.ClientId
        Scope               = $cfg.Scope
        EdgeExePath         = $EdgeExePath
        EdgeDataDir         = $edgeDataDir
        ExtraEdgeArgs       = $extraEdgeArgs
        EdgeExitGracePeriod = $gracePeriod
        WriteLog            = $logFn
    }
    if ($waitForDns)     { $authParams['WaitForDns']     = $true }
    if ($UpdateUi)       { $authParams['UpdateUi']       = $UpdateUi }
    if ($CheckCancelled) { $authParams['CheckCancelled'] = $CheckCancelled }
    if ($DoEvents)       { $authParams['DoEvents']       = $DoEvents }

    try {
        $edgeResult = _EdgeAppAuth @authParams
    } catch {
        & $logFn "Edge app auth failed: $_"
    }

    # ── Return result ─────────────────────────────────────────────────────
    if ($edgeResult.Success) {
        if ($WriteStatus) {
            & $WriteStatus 'Identity verified' 'Green'
        } else {
            Write-Success 'Identity verified.'
        }
        if ($PlaySound) { & $PlaySound 1000 200 }
        if ($isWinPE) { Start-Sleep -Seconds 1 }
        return @{
            Authenticated    = $true
            GraphAccessToken = $edgeResult.GraphAccessToken
            RefreshToken     = $edgeResult.RefreshToken
            ExpiresAt        = $edgeResult.ExpiresAt
            AuthConfig       = $cfg.AuthConfig
        }
    }

    $failMsg = if ($isWinPE) { 'Authentication failed. Please try again.' } else { 'Sign-in was not completed.' }
    if ($WriteStatus) {
        & $WriteStatus $failMsg 'Red'
    } else {
        Write-Fail $failMsg
    }
    if ($isWinPE) { Start-Sleep -Seconds 3 }
    return @{ Authenticated = $false; GraphAccessToken = $null; RefreshToken = $null; ExpiresAt = $null; AuthConfig = $cfg.AuthConfig }
}

function Update-M365Token {
    <#
    .SYNOPSIS  Refresh an expired Microsoft 365 access token.
    .DESCRIPTION
        Exchanges a refresh token for a new access/refresh token pair via
        the Entra ID token endpoint.  Designed for long-running deployments
        where the original token may expire before completion.
    .PARAMETER TokenInfo
        Hashtable with keys: RefreshToken, ClientId, Scope.
    .OUTPUTS
        Hashtable with AccessToken, RefreshToken, ExpiresAt on success;
        $null on failure.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Token refresh is a read-only HTTP call with no system side-effects')]
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$TokenInfo
    )

    $refreshToken = if ($TokenInfo.RefreshToken) { $TokenInfo.RefreshToken } else { $null }
    $clientId     = if ($TokenInfo.ClientId)     { $TokenInfo.ClientId }     else { $null }
    $scope        = if ($TokenInfo.Scope)        { $TokenInfo.Scope }        else { 'openid profile' }

    if (-not $refreshToken -or -not $clientId) {
        Write-Verbose 'Update-M365Token: missing RefreshToken or ClientId -- returning null.'
        return $null
    }

    $tokenUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token'
    try {
        $body = "client_id=$([uri]::EscapeDataString($clientId))" +
                "&scope=$([uri]::EscapeDataString($scope))" +
                "&refresh_token=$([uri]::EscapeDataString($refreshToken))" +
                '&grant_type=refresh_token'
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
        $raw = $wc.UploadString($tokenUrl, 'POST', $body)
        $tokenResponse = $raw | ConvertFrom-Json

        if ((_HasProp $tokenResponse 'access_token') -and $tokenResponse.access_token) {
            $newRefresh = if ((_HasProp $tokenResponse 'refresh_token') -and $tokenResponse.refresh_token) { $tokenResponse.refresh_token } else { $refreshToken }
            $expiresIn  = if ((_HasProp $tokenResponse 'expires_in')    -and $tokenResponse.expires_in)    { [int]$tokenResponse.expires_in } else { 3600 }
            $expiresAt  = (Get-Date).AddSeconds($expiresIn)
            return @{
                AccessToken  = $tokenResponse.access_token
                RefreshToken = $newRefresh
                ExpiresAt    = $expiresAt
            }
        }
    } catch {
        Write-Verbose "Token refresh failed: $_"
    }

    return $null
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-M365Auth'
    'Update-M365Token'
)

# SIG # Begin signature block
# MII9dgYJKoZIhvcNAQcCoII9ZzCCPWMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC7ewxsY/BD9kqV
# tyWgRsaYFnxiPVvXNiA0qbljolNanaCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAAwgfoS
# b3IaqFdWAAAAADCBMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNDExMTQzMjIxWhcNMjYwNDE0
# MTQzMjIxWjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCoDvl5pEdix75g
# sPPP+LUYM/FBro5KiOX3l29XEgZXd4FUxoXWN55ZcAMiBx6bE0shm5Jq3bsul1fk
# tKEi/S27MfMQLxJUBeT+pKylG3U2/l+H5mMemL0ZVkAdPVzg3tV1NSLQcD9nXjw/
# zK9DNhudjT65sbOXpQuzT8F9OSThrV7kTvjQTaj3BwZZpOG0N928hf7OYZF8ocpH
# RyxuNvWclGvz6P2VUHiSaWwLVWzUVKIjU0SDRWkz/kxNr153BgvKllzxP1xoM6T+
# IaWb6ilnJxZSIHdmcg3J0p+mOuBhMd41lltIW3J2tkwtCHoGHINrEsRWB1jXIPnK
# SYSJZktjjS/ZqoNiFFK98061Dk41IOFLqjcrXEI/TvCS7bwEVlAeuD22nYt+Mb/I
# XgSBZTHdwBqgZFtSFzmmXGrr/X2G9u1a2vpTV0IfB+V6DJyPpUFLmDZVA03vMghy
# lUTtgctxlGCP0moiFYHi8o1+jTdHsF2LsVbeje33CPRzGeAi0ocCAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUNfBORqLrmpv8ylfJ2reFGJPf7/gwHwYDVR0jBBgwFoAUmvFUd3UM
# hxY3RqCs3nn59H/BeOkwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwNC5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAFVIWKBhKT/vFueS1yhEdqApKn45HQp8InKXH1FtUG9UsG6DO5dQ+Ino
# W1t62LJMaWBSRFX3ME8uPK5rwrwiTQAU13zuz4kFs8D3a+dced9BPwIH8Dpadk7n
# R0lPpLLNPyr5XIMoBsbR7fZieDW3ttR5Yu/P+j9OaLhCB/11XsfLBM1hJwd6iGwG
# BkMRp16UKvdlFZrWToXVA04YA0veSKfRqpzCrJbqh84O20k8BworWczTuzfvsZ3Y
# SLcsozQ+QKI/atrB0gauZd9KbJMePNl8xsO/ilGXXN23xwE49c/0LH6ltda6uecb
# UnEqIFcwhHcznY7vLQ0socXed52Byv44oa1VtkBvffSAPxLUy8TyzxVDNwp5orws
# roko13DWmq1TCOBW6wqoiimpYiUJ2DXNOf6e4hyrLjKWrxKen1vG8Dx9M7o94yLM
# PNoE4apZ4ZqIaueqbV8kRPMW3H38lNqCEW5Jw+odLiuoudDSGckonMIRWezawMxY
# QqHjf1XWpmHH0onyNetWPeWLJmt1JySBp2E2jLDXJwFcOYPCaUx3t3fVsHETEFNr
# 4fi3pPOcMhpPMaBdczm09LHOHAn01gJJYrmyaYNsbCyCFBwuGeToqT6b1HjR/Q23
# wdAbn77KM3LF25nTjWt+9zsJgv4U2hXHEe3/AXkmc2W47Vbs5KQiMIIGyTCCBLGg
# AwIBAgITMwAAMIH6Em9yGqhXVgAAAAAwgTANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDA0MB4XDTI2MDQxMTE0
# MzIyMVoXDTI2MDQxNDE0MzIyMVowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAqA75eaRHYse+YLDzz/i1GDPxQa6OSojl95dvVxIGV3eBVMaF1jeeWXADIgce
# mxNLIZuSat27LpdX5LShIv0tuzHzEC8SVAXk/qSspRt1Nv5fh+ZjHpi9GVZAHT1c
# 4N7VdTUi0HA/Z148P8yvQzYbnY0+ubGzl6ULs0/BfTkk4a1e5E740E2o9wcGWaTh
# tDfdvIX+zmGRfKHKR0csbjb1nJRr8+j9lVB4kmlsC1Vs1FSiI1NEg0VpM/5MTa9e
# dwYLypZc8T9caDOk/iGlm+opZycWUiB3ZnINydKfpjrgYTHeNZZbSFtydrZMLQh6
# BhyDaxLEVgdY1yD5ykmEiWZLY40v2aqDYhRSvfNOtQ5ONSDhS6o3K1xCP07wku28
# BFZQHrg9tp2LfjG/yF4EgWUx3cAaoGRbUhc5plxq6/19hvbtWtr6U1dCHwflegyc
# j6VBS5g2VQNN7zIIcpVE7YHLcZRgj9JqIhWB4vKNfo03R7Bdi7FW3o3t9wj0cxng
# ItKHAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFDXwTkai65qb/MpXydq3hRiT3+/4MB8GA1Ud
# IwQYMBaAFJrxVHd1DIcWN0agrN55+fR/wXjpMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDA0LmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBVSFigYSk/7xbnktcoRHagKSp+OR0KfCJylx9R
# bVBvVLBugzuXUPiJ6FtbetiyTGlgUkRV9zBPLjyua8K8Ik0AFNd87s+JBbPA92vn
# XHnfQT8CB/A6WnZO50dJT6SyzT8q+VyDKAbG0e32Yng1t7bUeWLvz/o/Tmi4Qgf9
# dV7HywTNYScHeohsBgZDEadelCr3ZRWa1k6F1QNOGANL3kin0aqcwqyW6ofODttJ
# PAcKK1nM07s377Gd2Ei3LKM0PkCiP2rawdIGrmXfSmyTHjzZfMbDv4pRl1zdt8cB
# OPXP9Cx+pbXWurnnG1JxKiBXMIR3M52O7y0NLKHF3nedgcr+OKGtVbZAb330gD8S
# 1MvE8s8VQzcKeaK8LK6JKNdw1pqtUwjgVusKqIopqWIlCdg1zTn+nuIcqy4ylq8S
# np9bxvA8fTO6PeMizDzaBOGqWeGaiGrnqm1fJETzFtx9/JTaghFuScPqHS4rqLnQ
# 0hnJKJzCEVns2sDMWEKh439V1qZhx9KJ8jXrVj3liyZrdSckgadhNoyw1ycBXDmD
# wmlMd7d31bBxExBTa+H4t6TznDIaTzGgXXM5tPSxzhwJ9NYCSWK5smmDbGwsghQc
# Lhnk6Kk+m9R40f0Nt8HQG5++yjNyxduZ041rfvc7CYL+FNoVxxHt/wF5JnNluO1W
# 7OSkIjCCBygwggUQoAMCAQICEzMAAAAXJ0UJC4uHr8YAAAAAABcwDQYJKoZIhvcN
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
# UyBFT0MgQ0EgMDQCEzMAADCB+hJvchqoV1YAAAAAMIEwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgOiI5eX4EzWgO2fP56jhN6OIY5MFtm3hrPcLA2d88G1sw
# DQYJKoZIhvcNAQEBBQAEggGAZojvTfRzyB1ELVZThWNYOvjCpbdB0YBbl39mlobY
# CEdmz1kqYKv8Bdnvt4gCnvZ9cnoX9PI5HA0GOiS8LwqVvKyvCUi0Y+E2FjJSYNNl
# uIBm6pNVFEEdwC9cdyS/ODMvVt4FrW3nHe4KmuxlH7HcrC/80hQW6PrfW78hZarB
# IdxqoE4YuNeBpdT7rTsWhcvoeWGtaIWdb2uXJcQXXWjw51TixaTjhz/e4+ohoNEk
# fL070DagWE/t5qK8Fn6smLcyAzPXtiA+Hh0r+GWr8Owi1CKlWf45RHpnTlJXeiQa
# MMdo2VGMOW7Nr9krYs9FSOfuLu9f6XHpgbrUFBVr5lRTPr0N7317omH1uqvVDt0S
# 5B3/QLWa2naD74uk84jjbajTjIidgve0LIP4O5MCzvKRINKc2+QOPOlPbo0z/RrY
# rweJaQQmxd9Qn128h8+FduhB8xbIRjhI62jtu7E2pAy51eKgEKwBzlNvk614pXUx
# IHT1pqkwz1Qv6K7gYYW0SajVoYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJ
# KoZIhvcNAQcCoIIX7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEICqB3XbYxFAwim5Aov159SQeMpfpssbcnVB9dazrkSdYAgZp1AaEjjYYEzIw
# MjYwNDExMTc0MDAzLjg0OFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
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
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDExMTc0MDAzWjAvBgkqhkiG9w0B
# CQQxIgQgy+bSJJQjWdi8pzAFX9bvOQRJZeLz+bcOavrkKZv8ZsowgbkGCyqGSIb3
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
# DQEBAQUABIICAF9qlM1RgX2wquuQB6lakB4clVOeKrMBbziKEbQWbLuXBtyzOv1Y
# T1P6ayBdhrRkTNoJTxBpgDZdtIPLmyKUtC0UENnNKG00vfLvakmfAuQdUZ8ET9IX
# m0RmAYr4UTxRWgDja+C7nUg9WhrvdSqrJiplvwA5qdQ0lT4JTGJIT77tjoPAbkIy
# YEOKhiC56DcgF5ruIyEYPprDZZqulc4XjPZ7yX1889U5XTZV4qTcElaTDpWjNjTE
# B4GO7EdNsuPJgAPTG1cuxbZO7X/dBrBEooIf1z+5+YS7Ow/Bdgx7c24ht2jCTgCY
# LzBpFRvzk3Ju7x+K421hI2r/BcJEH1jedwB5o+8Fhav6TfxqWDdFSst/ZIVFC7LR
# KsU7kc0HNbmF7HdbzaStEIQyYcvf/O/QzSLIGTKstd5Urb5kq2kVJjWd8mWM5n1w
# TKMnatm1qBMVbNi27m0bcWgTnZ+y8RtjFrNn8aU6u5VhcvHkA+MbNz0FiWzpNQ5K
# 8riX6NIMxqwThV+0wBlyfUrLnEUAZXcw+X+/AvcaVixe04vyjs9mLL+RcjX9KeVq
# bb2RlXmDlYN4p+oq8Z3IjrUJVPftfztVyCIdhpek1pv9BWvFlk71Y/xtDCxlW8Gn
# PwaZkCGw7N9GA2+WHtB9eB4leaTqPWfL1vM+s1aMLK80CS3YCUUQgmNW
# SIG # End signature block

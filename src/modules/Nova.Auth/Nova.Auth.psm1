<#
.SYNOPSIS
    Microsoft 365 / Azure AD authentication module for Nova.

.DESCRIPTION
    Provides OAuth2 Authorization Code Flow with PKCE for authenticating
    OSD operators.  Supports two runtime environments:
      1. Trigger.ps1 (full Windows): WebView2 popup or system browser fallback
      2. Bootstrap.ps1 (WinPE kiosk): Edge --app mode (always available in boot image)
    Also includes WebView2 SDK download/caching and token refresh.
#>

Set-StrictMode -Version Latest

# ── Private helper: safely check if a PSCustomObject has a property ─────────
function _HasProp {
    param([psobject]$Obj, [string]$Name)
    return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name])
}

function Install-WebView2SDK {
    <#
    .SYNOPSIS  Download the WebView2 SDK NuGet package (cached).
    .DESCRIPTION
        Downloads the Microsoft.Web.WebView2 NuGet package to a temporary
        directory and extracts the managed DLLs needed for PowerShell.
        A cached copy is reused on subsequent calls.
    .OUTPUTS
        Path to the directory containing the WebView2 DLLs, or $null on failure.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param()
    $sdkDir  = Join-Path $env:TEMP 'Nova-WebView2SDK'
    $coreDll = Join-Path $sdkDir 'Microsoft.Web.WebView2.Core.dll'

    # Reuse cached copy.
    if (Test-Path $coreDll) { return $sdkDir }

    $null = New-Item -Path $sdkDir -ItemType Directory -Force

    # Download the NuGet package (latest stable).
    $zipPath = Join-Path $sdkDir 'Microsoft.Web.WebView2.nupkg'
    try {
        $prevPref = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try     { Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile $zipPath -UseBasicParsing }
        finally { $ProgressPreference = $prevPref }
    } catch {
        Write-Verbose "WebView2 NuGet download failed: $_"
        return $null
    }

    # Extract the required DLLs from the package.
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $arch = if ([System.IntPtr]::Size -eq 8) { 'win-x64' } else { 'win-x86' }
        $zip  = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $zip.Entries) {
                $extract = $false
                if ($entry.FullName -like 'lib/net45/*.dll') { $extract = $true }
                if ($entry.FullName -eq "runtimes/$arch/native/WebView2Loader.dll") { $extract = $true }
                if ($extract -and $entry.Name) {
                    $dest = Join-Path $sdkDir $entry.Name
                    $s = $entry.Open()
                    try {
                        $fs = [System.IO.File]::Create($dest)
                        try   { $s.CopyTo($fs) }
                        finally { $fs.Close() }
                    } finally { $s.Close() }
                }
            }
        } finally { $zip.Dispose() }
    } catch {
        Write-Verbose "WebView2 NuGet extraction failed: $_"
        return $null
    }

    if (Test-Path $coreDll) { return $sdkDir }
    return $null
}

function Show-WebView2AuthPopup {
    <#
    .SYNOPSIS  Show an embedded WebView2 popup for Azure AD sign-in.
    .DESCRIPTION
        Creates a WinForms dialog with an embedded WebView2 control that
        navigates to the Azure AD authorization endpoint.  The redirect is
        intercepted via the NavigationStarting event -- no HTTP listener is
        needed.  Returns the authorization code on success, or $null if
        the user closed the window or an error occurred.
        Throws if the WebView2 Runtime is not installed or initialisation
        fails, allowing the caller to fall back to a browser-based flow.
    .PARAMETER AuthorizeUrl
        Full Azure AD /authorize URL including all query parameters.
    .PARAMETER RedirectUriBase
        The redirect URI registered with Azure AD (e.g. http://localhost:PORT/).
        The NavigationStarting handler matches URLs starting with this value.
    .PARAMETER WebView2SDKPath
        Path to the directory containing the WebView2 managed DLLs.
    .OUTPUTS
        Authorization code string, or $null.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [string] $AuthorizeUrl,
        [string] $RedirectUriBase,
        [string] $WebView2SDKPath
    )

    # ── Load assemblies ────────────────────────────────────────────────────
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
    Add-Type -Path (Join-Path $WebView2SDKPath 'Microsoft.Web.WebView2.Core.dll')     -ErrorAction Stop
    Add-Type -Path (Join-Path $WebView2SDKPath 'Microsoft.Web.WebView2.WinForms.dll') -ErrorAction Stop

    # ── Create the WebView2 environment ────────────────────────────────────
    # Use a temporary user-data directory to isolate cookies and cache.
    $userDataDir = Join-Path $env:TEMP 'Nova-WebView2Auth'
    if (-not (Test-Path $userDataDir)) {
        $null = New-Item -Path $userDataDir -ItemType Directory -Force
    }

    $envOptions = [Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions]::new()
    $envTask    = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync(
                      $null, $userDataDir, $envOptions)

    # Poll for completion -- do NOT use .GetAwaiter().GetResult() as it
    # deadlocks the WinForms message pump.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $envTask.IsCompleted -and $sw.ElapsedMilliseconds -lt 30000) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    if (-not $envTask.IsCompleted -or $envTask.IsFaulted) {
        $ex = if ($envTask.Exception) { $envTask.Exception.InnerException } else { $null }
        throw "WebView2 environment creation failed: $ex"
    }
    $wv2Env = $envTask.Result

    # ── Build the form ─────────────────────────────────────────────────────
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Nova - Sign In'
    $form.Size            = New-Object System.Drawing.Size(520, 680)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.BackColor       = [System.Drawing.Color]::White
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 10)

    $wv2 = [Microsoft.Web.WebView2.WinForms.WebView2]::new()
    $wv2.Dock = [System.Windows.Forms.DockStyle]::Fill
    $form.Controls.Add($wv2)

    # ── Initialize the WebView2 control ────────────────────────────────────
    $initTask = $wv2.EnsureCoreWebView2Async($wv2Env)
    $sw.Restart()
    while (-not $initTask.IsCompleted -and $sw.ElapsedMilliseconds -lt 30000) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    if (-not $initTask.IsCompleted -or $initTask.IsFaulted) {
        try { $wv2.Dispose() } catch { $null = $_ }
        try { $form.Dispose() } catch { $null = $_ }
        $ex = if ($initTask.Exception) { $initTask.Exception.InnerException } else { $null }
        throw "WebView2 control initialisation failed: $ex"
    }

    # ── Intercept the redirect to capture the authorization code ───────────
    $script:_wv2PopupCode     = $null
    $script:_wv2PopupError    = $null
    $script:_wv2PopupForm     = $form
    $script:_wv2RedirectBase  = $RedirectUriBase

    $wv2.CoreWebView2.add_NavigationStarting({
        param($eventSender, $e)
        $null = $eventSender
        if ($e.Uri.StartsWith($script:_wv2RedirectBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            $e.Cancel = $true
            try {
                $parsed = [System.Uri]::new($e.Uri)
                foreach ($pair in $parsed.Query.TrimStart('?').Split('&')) {
                    $kv = $pair.Split('=', 2)
                    if ($kv.Count -eq 2) {
                        if ($kv[0] -eq 'code')  { $script:_wv2PopupCode  = [uri]::UnescapeDataString($kv[1]) }
                        if ($kv[0] -eq 'error') { $script:_wv2PopupError = [uri]::UnescapeDataString($kv[1]) }
                    }
                }
            } catch { $null = $_ }
            $script:_wv2PopupForm.DialogResult = if ($script:_wv2PopupCode) { 'OK' } else { 'Abort' }
            $script:_wv2PopupForm.Close()
        }
    })

    # ── Navigate and show the form ─────────────────────────────────────────
    $wv2.CoreWebView2.Navigate($AuthorizeUrl)
    $dialogResult = $form.ShowDialog()

    # ── Clean up ───────────────────────────────────────────────────────────
    try { $wv2.Dispose() } catch { $null = $_ }
    try { $form.Dispose() } catch { $null = $_ }

    # Remove cached cookies/data to prevent credential leakage.
    if (Test-Path $userDataDir) {
        try { Remove-Item $userDataDir -Recurse -Force }
        catch { Write-Verbose "WebView2 user-data cleanup failed (credentials may persist): $_" }
    }

    if ($dialogResult -eq 'OK' -and $script:_wv2PopupCode) {
        return $script:_wv2PopupCode
    }

    return $null
}

function Invoke-M365DeviceCodeAuth {
    <#
    .SYNOPSIS  Authenticate the operator via an embedded WebView2 sign-in popup.
    .DESCRIPTION
        Downloads config/auth.json from the GitHub repository.  When
        requireAuth is true and a clientId is configured, the function
        shows an embedded WebView2 popup with the Azure AD login page
        using the Authorization Code Flow with PKCE.  The redirect is
        intercepted inside the popup -- no external browser is needed.
        If the WebView2 Runtime is not installed, the function falls
        back to opening the default system browser with a temporary
        localhost HTTP listener to capture the redirect.
        Tenant restrictions are enforced at the Entra ID app registration
        level -- only tenants explicitly allowed in the app's
        "Supported account types" configuration can complete sign-in.
    .PARAMETER GitHubUser   GitHub account that hosts the Nova repository.
    .PARAMETER GitHubRepo   Repository name.
    .PARAMETER GitHubBranch Branch to fetch auth config from.
    .NOTES
        The Azure AD app registration must include http://localhost as a
        redirect URI under the "Mobile and desktop applications" platform.
    .OUTPUTS
        [hashtable] with keys:
          Authenticated    [bool]   $true if auth succeeded or was not required.
          GraphAccessToken [string] Microsoft Graph access token, or $null.
          AuthConfig       [object] The parsed auth.json config, or $null.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [string] $GitHubUser  = 'araduti',
        [string] $GitHubRepo  = 'Nova',
        [string] $GitHubBranch = 'main'
    )

    # ── Fetch auth configuration from the repository ────────────────────────
    $authConfigUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/auth.json"
    $authConfig    = $null
    try {
        $wc      = New-Object System.Net.WebClient
        $rawJson = $wc.DownloadString($authConfigUrl)
        $authConfig = $rawJson | ConvertFrom-Json
    } catch {
        Write-Verbose "Could not fetch auth config: $_"
    }

    # If auth is not configured or not required, skip silently.
    if (-not $authConfig -or -not ((_HasProp $authConfig 'requireAuth') -and $authConfig.requireAuth)) {
        return @{ Authenticated = $true; GraphAccessToken = $null; AuthConfig = $null }
    }

    # Validate that the config has the minimum required fields.
    if (-not ((_HasProp $authConfig 'clientId') -and $authConfig.clientId)) {
        Write-Verbose "Auth config incomplete -- skipping authentication."
        return @{ Authenticated = $true; GraphAccessToken = $null; AuthConfig = $null }
    }

    $clientId = $authConfig.clientId

    # ── Build scope string ──────────────────────────────────────────────────
    # Always include openid profile; append Graph API scopes when configured
    # (e.g. DeviceManagementServiceConfig.ReadWrite.All for Autopilot import).
    # Delegated permissions -- no client secret required.
    $scope = 'openid profile'
    if ((_HasProp $authConfig 'graphScopes') -and $authConfig.graphScopes) {
        $trimmed = ($authConfig.graphScopes).Trim()
        if ($trimmed) { $scope = "openid profile $trimmed" }
    }

    # ── Step 1: Generate PKCE code verifier and challenge (RFC 7636) ────────
    Write-Step 'Signing in with Microsoft 365...'

    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $codeVerifier  = [Convert]::ToBase64String($bytes) -replace '\+','-' -replace '/','_' -replace '='

    $sha256        = [System.Security.Cryptography.SHA256]::Create()
    $challengeHash = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
    $codeChallenge = [Convert]::ToBase64String($challengeHash) -replace '\+','-' -replace '/','_' -replace '='

    # ── Step 2: Try WebView2 embedded sign-in popup ────────────────────────
    # WebView2 displays the Azure AD login page directly inside a WinForms
    # popup -- no external browser window needed.  The redirect is intercepted
    # by a NavigationStarting handler so no HTTP listener is required either.
    # If the WebView2 Runtime is not installed or the SDK cannot be obtained,
    # the function falls back to opening the default system browser.
    $code        = $null
    $authError   = $null
    $redirectUri = $null
    $tryBrowserFallback = $true

    try {
        $wv2SdkPath = Install-WebView2SDK
        if ($wv2SdkPath) {
            $port        = Get-Random -Minimum 49152 -Maximum 65535
            $redirectUri = "http://localhost:$port/"
            $authorizeUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?' +
                "client_id=$([uri]::EscapeDataString($clientId))" +
                '&response_type=code' +
                "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
                "&scope=$([uri]::EscapeDataString($scope))" +
                "&code_challenge=$codeChallenge" +
                '&code_challenge_method=S256' +
                '&prompt=select_account'

            $code = Show-WebView2AuthPopup `
                        -AuthorizeUrl    $authorizeUrl `
                        -RedirectUriBase $redirectUri `
                        -WebView2SDKPath $wv2SdkPath

            # If we reach here the popup was displayed.  Don't fall back to
            # the system browser -- the user deliberately closed the popup or
            # an Azure AD error occurred.
            $tryBrowserFallback = $false
        }
    } catch {
        Write-Verbose "WebView2 sign-in unavailable: $_"
    }

    # ── Step 2b: Fallback -- open default browser + localhost listener ──────
    if (-not $code -and $tryBrowserFallback) {
        $listener = New-Object System.Net.HttpListener
        $redirectUri = $null
        foreach ($attempt in 1..5) {
            $port        = Get-Random -Minimum 49152 -Maximum 65535
            $redirectUri = "http://localhost:$port/"
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add($redirectUri)
            try {
                $listener.Start()
                break
            } catch {
                if ($attempt -eq 5) {
                    Write-Fail "Could not start local HTTP listener after $attempt attempts: $_"
                    return @{ Authenticated = $false; GraphAccessToken = $null; AuthConfig = $authConfig }
                }
            }
        }

        try {

        $authorizeUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?' +
            "client_id=$([uri]::EscapeDataString($clientId))" +
            '&response_type=code' +
            "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
            "&scope=$([uri]::EscapeDataString($scope))" +
            "&code_challenge=$codeChallenge" +
            '&code_challenge_method=S256' +
            '&prompt=select_account'

        Write-Host ''
        Write-Host '  A browser window will open for sign-in.' -ForegroundColor White
        Write-Host '  Complete the sign-in in your browser.'    -ForegroundColor Gray
        Write-Host ''

        Start-Process $authorizeUrl

        $timeoutMs   = 120000   # 2 minutes
        $asyncResult = $listener.BeginGetContext($null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($timeoutMs)) {
            Write-Fail 'Sign-in timed out.'
            return @{ Authenticated = $false; GraphAccessToken = $null; AuthConfig = $authConfig }
        }

        $context = $listener.EndGetContext($asyncResult)

        foreach ($pair in $context.Request.Url.Query.TrimStart('?').Split('&')) {
            $kv = $pair.Split('=', 2)
            if ($kv.Count -eq 2) {
                if ($kv[0] -eq 'code')  { $code      = [uri]::UnescapeDataString($kv[1]) }
                if ($kv[0] -eq 'error') { $authError  = [uri]::UnescapeDataString($kv[1]) }
            }
        }

        $html = if ($code) {
            '<html><body style="font-family:Segoe UI,sans-serif;text-align:center;padding:60px">' +
            '<h2 style="color:#107c10">&#10004; Sign-in complete</h2>' +
            '<p>You can close this window and return to Nova.</p>' +
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

        } finally {
            $listener.Stop(); $listener.Close()
        }
    }

    if (-not $code) {
        $msg = if ($authError) { "Sign-in was not completed: $authError" } else { 'Sign-in was not completed.' }
        Write-Fail $msg
        return @{ Authenticated = $false; GraphAccessToken = $null; AuthConfig = $authConfig }
    }

    # ── Step 5: Exchange authorization code for tokens ──────────────────────
    $tokenUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token'
    try {
        $body = "client_id=$([uri]::EscapeDataString($clientId))" +
                "&scope=$([uri]::EscapeDataString($scope))" +
                "&code=$([uri]::EscapeDataString($code))" +
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
            Write-Success 'Identity verified.'
            return @{
                Authenticated    = $true
                GraphAccessToken = $graphToken
                RefreshToken     = $refreshToken
                ExpiresAt        = $expiresAt
                AuthConfig       = $authConfig
            }
        }
    } catch {
        Write-Verbose "Token exchange failed: $_"
    }

    Write-Fail 'Token exchange failed.'
    return @{ Authenticated = $false; GraphAccessToken = $null; AuthConfig = $authConfig }
}

function Update-M365Token {
    <#
    .SYNOPSIS  Refresh an expired Microsoft 365 access token.
    .DESCRIPTION
        Exchanges a refresh token for a new access/refresh token pair via
        the Azure AD token endpoint.  Designed for long-running deployments
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

#region ── WinPE Kiosk Auth ────────────────────────────────────────────────────
# Used by Bootstrap.ps1 inside the WinPE kiosk environment.
# Edge is always present in the WinPE boot image, so the only interactive
# auth method is Edge --app mode (Auth Code + PKCE).
# _KioskEdgeAuth is a private helper; Invoke-KioskM365Auth is the public
# orchestrator that accepts scriptblock callbacks for UI decoupling.

function _KioskEdgeAuth {
    <#
    .SYNOPSIS  Authenticate the operator via Edge --app popup (Auth Code + PKCE).
    .DESCRIPTION
        Launches Microsoft Edge in --app mode as a separate process, pointing at
        the Azure AD authorization endpoint.  This opens a clean, chromeless
        browser window dedicated to the login flow -- independent of the kiosk
        UI running in Edge --kiosk mode.

        A temporary localhost HTTP listener captures the redirect carrying the
        authorization code, then exchanges it for tokens using PKCE.
        After authentication completes (or fails), the Edge --app process is
        terminated automatically.

        WinPE-safe -- uses the same msedge.exe binary already staged in the
        boot image.
    .PARAMETER ClientId
        Azure AD application (client) ID.
    .PARAMETER Scope
        OAuth 2.0 scopes to request (space-separated).
    .PARAMETER EdgeExePath
        Full path to msedge.exe.  Defaults to the WinPE staging path.
    .PARAMETER WriteLog
        Scriptblock for writing auth log entries.  Called with a single string argument.
    .PARAMETER UpdateUi
        Scriptblock for updating the HTML UI.  Called with a hashtable of parameters.
    .PARAMETER CheckCancelled
        Scriptblock that returns $true when auth has been cancelled (e.g. via /cancelauth HTTP API).
    .PARAMETER DoEvents
        Scriptblock that pumps the WinForms message loop.
    .OUTPUTS
        [hashtable] with keys:
          Success          [bool]   $true if auth succeeded.
          GraphAccessToken [string] Microsoft Graph access token, or $null.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClientId,
        [string]$Scope = 'openid profile',
        [string]$EdgeExePath = 'X:\WebView2\Edge\msedge.exe',
        [scriptblock]$WriteLog,
        [scriptblock]$UpdateUi,
        [scriptblock]$CheckCancelled,
        [scriptblock]$DoEvents
    )

    $fail = @{ Success = $false; GraphAccessToken = $null }

    # ── Verify Edge binary exists ───────────────────────────────────────────
    if (-not (Test-Path $EdgeExePath)) {
        if ($WriteLog) { & $WriteLog "Edge not found at $EdgeExePath -- cannot open auth window." }
        return $fail
    }

    # ── Log environment diagnostics ─────────────────────────────────────────
    if ($WriteLog) { & $WriteLog "Edge app auth starting" }

    # ── PKCE code verifier and challenge (RFC 7636) ─────────────────────────
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $codeVerifier  = [Convert]::ToBase64String($bytes) -replace '\+','-' -replace '/','_' -replace '='

    $sha256        = [System.Security.Cryptography.SHA256]::Create()
    $challengeHash = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
    $codeChallenge = [Convert]::ToBase64String($challengeHash) -replace '\+','-' -replace '/','_' -replace '='

    # ── Start a temporary localhost HTTP listener ───────────────────────────
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

    # ── Build the authorize URL ─────────────────────────────────────────────
    $authorizeUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?' +
        "client_id=$([uri]::EscapeDataString($ClientId))" +
        '&response_type=code' +
        "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
        "&scope=$([uri]::EscapeDataString($Scope))" +
        "&code_challenge=$codeChallenge" +
        '&code_challenge_method=S256' +
        '&prompt=select_account'

    # ── Launch Edge in --app mode for the login window ──────────────────────
    # --app opens a chromeless window (no tabs, no address bar) ideal for
    # a sign-in form.  A separate user-data-dir avoids conflicts with
    # the kiosk Edge instance.
    if ($WriteLog) { & $WriteLog "Launching Edge --app for auth popup" }
    $edgeAuthDataDir = 'X:\Temp\EdgeAuth'
    $edgeAuthArgs = @(
        "--app=$authorizeUrl",
        '--allow-run-as-system',
        "--user-data-dir=$edgeAuthDataDir",
        '--window-size=520,700',
        '--disable-gpu',
        '--disable-gpu-compositing',
        '--disable-direct-composition',
        '--use-angle=swiftshader',
        '--enable-unsafe-swiftshader',
        '--in-process-gpu',
        '--no-first-run',
        '--disable-fre',
        '--disable-features=msWebOOBE,PasswordManager',
        '--password-store=basic',
        '--disable-save-password-bubble'
    )
    $edgeProc = Start-Process -FilePath $EdgeExePath -ArgumentList $edgeAuthArgs -PassThru

    # Notify the UI that auth is in progress (but no URL -- the Edge
    # --app window handles the login page directly).
    if ($UpdateUi) { & $UpdateUi @{ AuthInProgress = $true } }

    # ── Wait for the redirect callback ──────────────────────────────────────
    $asyncResult = $listener.BeginGetContext($null, $null)

    # 5-minute timeout -- Azure AD sessions are valid for 10 minutes,
    # 5 minutes gives enough time without leaving the kiosk unattended.
    $timeout = [datetime]::UtcNow.AddMinutes(5)
    $cancelled = $false

    while (-not $authCode -and -not $authError `
           -and -not $cancelled -and [datetime]::UtcNow -lt $timeout) {

        if ($CheckCancelled) { $cancelled = (& $CheckCancelled) -eq $true }

        # If the user closed the Edge window, treat as cancellation.
        if ($edgeProc -and $edgeProc.HasExited) {
            if ($WriteLog) { & $WriteLog "Edge auth window was closed by user." }
            $cancelled = $true
            break
        }

        if ($asyncResult.IsCompleted -or $asyncResult.AsyncWaitHandle.WaitOne(0)) {
            try {
                $context = $listener.EndGetContext($asyncResult)

                # Parse authorization code (or error) from the query string.
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
        # ── Clean up: stop listener and kill the Edge --app process ──────────
        try { $listener.Stop(); $listener.Close() } catch { $null = $_ }

        if ($edgeProc -and -not $edgeProc.HasExited) {
            if ($WriteLog) { & $WriteLog "Closing Edge auth window (PID $($edgeProc.Id))" }
            try { $edgeProc.Kill() } catch { $null = $_ }
        }
        # Remove stale lock files so the auth data dir can be reused
        try { Remove-Item (Join-Path $edgeAuthDataDir 'lockfile')     -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        try { Remove-Item (Join-Path $edgeAuthDataDir 'SingletonLock') -Force -ErrorAction SilentlyContinue } catch { $null = $_ }

        # Clear auth-in-progress signal
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

    # ── Exchange authorization code for tokens ──────────────────────────────
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
            $graphToken = if ((_HasProp $tokenResponse 'access_token') -and $tokenResponse.access_token) { $tokenResponse.access_token } else { $null }
            if ($WriteLog) { & $WriteLog "Edge app auth succeeded -- token obtained." }
            return @{ Success = $true; GraphAccessToken = $graphToken }
        }
    } catch {
        if ($WriteLog) { & $WriteLog "Token exchange failed: $_" }
    }

    return $fail
}

function Invoke-KioskM365Auth {
    <#
    .SYNOPSIS  Authenticate the operator via M365 (Edge --app popup with Auth Code + PKCE).
    .DESCRIPTION
        Downloads config/auth.json from the GitHub repository.  When
        requireAuth is true and a clientId is configured, the function
        launches Edge in --app mode for interactive sign-in using the
        Authorization Code Flow with PKCE.  Edge is always present in
        the WinPE boot image.
        Tenant restrictions are enforced at the Entra ID app registration
        level -- only tenants explicitly allowed in the app's
        "Supported account types" configuration can complete sign-in.
    .PARAMETER GitHubUser   GitHub account that hosts the Nova repository.
    .PARAMETER GitHubRepo   Repository name.
    .PARAMETER GitHubBranch Branch to fetch auth config from.
    .PARAMETER EdgeExePath  Full path to msedge.exe for the --app auth window.
    .PARAMETER WriteLog     Scriptblock for writing auth log entries.
    .PARAMETER WriteStatus  Scriptblock for writing status messages. Called with (message, color).
    .PARAMETER UpdateUi     Scriptblock for updating the HTML UI.
    .PARAMETER CheckCancelled Scriptblock that returns $true when auth has been cancelled.
    .PARAMETER DoEvents     Scriptblock that pumps the WinForms message loop.
    .PARAMETER PlaySound    Scriptblock for playing sound feedback. Called with (frequency, duration).
    .OUTPUTS
        [hashtable] with keys:
          Authenticated    [bool]     $true if auth succeeded or was not required.
          GraphAccessToken [string]   Microsoft Graph access token, or $null.
          AuthConfig       [object]   The parsed auth.json config, or $null.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [string]$GitHubUser   = 'araduti',
        [string]$GitHubRepo   = 'Nova',
        [string]$GitHubBranch = 'main',
        [string]$EdgeExePath  = 'X:\WebView2\Edge\msedge.exe',
        [scriptblock]$WriteLog,
        [scriptblock]$WriteStatus,
        [scriptblock]$UpdateUi,
        [scriptblock]$CheckCancelled,
        [scriptblock]$DoEvents,
        [scriptblock]$PlaySound
    )

    $skip = @{ Authenticated = $true; GraphAccessToken = $null; AuthConfig = $null }

    # ── Fetch auth configuration from the repository ────────────────────────
    $authConfigUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/auth.json"
    $authConfig    = $null
    try {
        $wc      = New-Object System.Net.WebClient
        $rawJson = $wc.DownloadString($authConfigUrl)
        $authConfig = $rawJson | ConvertFrom-Json
    } catch {
        if ($WriteLog) { & $WriteLog "Could not fetch auth config: $_" }
    }

    # If auth is not configured or not required, skip silently.
    if (-not $authConfig -or -not ((_HasProp $authConfig 'requireAuth') -and $authConfig.requireAuth)) {
        if ($WriteStatus) { & $WriteStatus 'Authentication not required' 'Green' }
        return $skip
    }

    # Validate that the config has the minimum required fields.
    if (-not ((_HasProp $authConfig 'clientId') -and $authConfig.clientId)) {
        if ($WriteLog) { & $WriteLog "Auth config incomplete -- skipping authentication." }
        if ($WriteStatus) { & $WriteStatus 'Authentication not required' 'Green' }
        return $skip
    }

    $clientId = $authConfig.clientId

    # ── Build scope string ──────────────────────────────────────────────────
    $scope = 'openid profile'
    if ((_HasProp $authConfig 'graphScopes') -and $authConfig.graphScopes) {
        $trimmed = ($authConfig.graphScopes).Trim()
        if ($trimmed) { $scope = "openid profile $trimmed" }
    }

    if ($WriteStatus) { & $WriteStatus 'Signing in with Microsoft 365...' 'Cyan' }
    if ($DoEvents) { & $DoEvents }

    # ── Authenticate via Edge --app popup ──────────────────────────────────
    $edgeResult = @{ Success = $false; GraphAccessToken = $null }
    try {
        $edgeResult = _KioskEdgeAuth `
            -ClientId $clientId -Scope $scope `
            -EdgeExePath $EdgeExePath `
            -WriteLog $WriteLog -UpdateUi $UpdateUi `
            -CheckCancelled $CheckCancelled -DoEvents $DoEvents
    } catch {
        if ($WriteLog) { & $WriteLog "Edge app auth failed: $_" }
    }

    if ($edgeResult.Success) {
        if ($WriteStatus) { & $WriteStatus 'Identity verified' 'Green' }
        if ($PlaySound)   { & $PlaySound 1000 200 }
        Start-Sleep -Seconds 1
        return @{ Authenticated = $true; GraphAccessToken = $edgeResult.GraphAccessToken; AuthConfig = $authConfig }
    }

    if ($WriteStatus) { & $WriteStatus 'Authentication failed. Please try again.' 'Red' }
    Start-Sleep -Seconds 3
    return @{ Authenticated = $false; GraphAccessToken = $null; AuthConfig = $authConfig }
}

#endregion

Export-ModuleMember -Function @(
    'Install-WebView2SDK'
    'Show-WebView2AuthPopup'
    'Invoke-M365DeviceCodeAuth'
    'Update-M365Token'
    'Invoke-KioskM365Auth'
)

# SIG # Begin signature block
# MII9dQYJKoZIhvcNAQcCoII9ZjCCPWICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBxjRco/c0qFOr7
# SYVZXEpictIkERdBwwbw0Dga1h4cyaCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# rmcxghqTMIIajwIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBBT0MgQ0EgMDQCEzMAAAsliaF5N+X1X2YAAAAACyUwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgMJqinhbRhzC7BjmmawBwBnYTVtOMI1G3RnFnwNS+dYow
# DQYJKoZIhvcNAQEBBQAEggGAYrgm6XUXmNQPcFOY9lt8YpL8ExAxil61cm/CesiR
# YR/3Prnnzr4EMsU2JDpvvOSuy4h6mX9AIkDHB4AgmLtKSCELKw+VTwZQfZHnK9SQ
# VMSul4SR5sJtQnD3L2lS52udcYekrgjqS/YLRLJNIGa6RnnmUZBNnA4J7Jf6nbfx
# zofCVZvL8TSXCV8M+HyZO0QYmza5o9l8Csb+KI/Je8k9DdqjHHj1xYODo/k8ntvi
# W6Olboj+IHQgh/1b0kRv/JoU3m7EzRGIuGAaOQYXK86SOrCkCOyrCoBbgGLSvybI
# 7c/X5drQ3Fwpm9uBChJxrCimG2Qc98VCXHrnwBzA9Uvg+F/VvosIMRVSJjAJ/WZ/
# B9P4rLuVZCocNkqQ6rA7Tma1ai+spHEC5KqlLcLuKn1Svz+KwiMDTZUWCwZvvW1u
# ycXp6+2D4yiCvneBGyWrSQxfFUx+IS8NwSRI8M47Xseh2ElX8wNpA49EwwjCDXxA
# 8M+VBrO1gK+sI4gU2Dt6TnBjoYIYEzCCGA8GCisGAQQBgjcDAwExghf/MIIX+wYJ
# KoZIhvcNAQcCoIIX7DCCF+gCAQMxDzANBglghkgBZQMEAgEFADCCAWEGCyqGSIb3
# DQEJEAEEoIIBUASCAUwwggFIAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIHxlYZb8wmiS4q4Gdj+uFkgLkVmeC8HkRPAv4MZrHKwHAgZp1AaDJQQYEjIw
# MjYwNDEwMjEzOTU1LjAzWjAEgAIB9KCB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaCCDyEwggeCMIIFaqADAgECAhMzAAAABeXPD/9mLsmHAAAAAAAF
# MA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJp
# ZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMDEx
# MTkyMDMyMzFaFw0zNTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAnnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1lRkd3kcFdcG9/
# sqtDlwxKoVIcaqDb+omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjxnG/eViS4sOx8
# y4gSq8Zg49REAf5huXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5hJM1xznkRsFP
# u6rfDHeZeG1Wa1wISvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFlyAKwn6yjN/kR
# 4fkquUWfGmMopNq/B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTPVi3gVErnc/qi
# +dR8A2MiAz0kN0nh7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKxLms73KG/Z+Mk
# euaVDQQheangOEMGJ4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxRYR/JPGAaM6xG
# l57Ei95HUw9NV/uC3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxOmM2rl4uKK6eE
# purRduOQ2hTkmG1hSuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cjRKG79+TX+sTe
# hawOoxfeOO/jR7wo3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xTnD1a69w/UTxw
# jEugpIPMIIE67SFZ2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8FUXetXr0CAwEA
# AaOCAhswggIXMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNV
# HQ4EFgQUa2koOjUvSGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJBgRVHSAAMEEw
# PwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9j
# cy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFMh+
# 0mqFKhvKGZgEByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3JsMIGUBggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUHMAKGdWh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSWRl
# bnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRo
# b3JpdHklMjAyMDIwLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2x35ttVoVdedM
# eGj6TuHYRJklFaW4sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6AF6ycWoEYR0LY
# haa0ozJLU5Yi+LCmcrdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM74LNvVzY0/nP
# ISHz0Xva71QjD4h+8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLslLKsO8F2aBs2c
# Io1k+aHOhrw9xw6JCWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yFM7Ujrhc0aqy3
# xL7D5FR2J7x9cLWMq7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFovIP7YG4ZkJWag
# 1H91KlELGWi3SLv10o4KGag42pswjybTi4toQcC/irAodDW8HNtX+cbz0sMptFJK
# +KObAnDFHEsukxD+7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9TlxydiFhvu88
# o0w35JkNbJxTk4MhF/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWVydt4ytxYP/bq
# jN49D9NZ81coE6aQWm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeCUMYmBx3PkP8A
# DHD1J2Cr/6tjuOOCztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdtoSAHEUKiBhI6J
# QivRepyvWcl+JYbYbBh7pmgAXVswggeXMIIFf6ADAgECAhMzAAAAVyTTleCi6ckx
# AAAAAABXMA0GCSqGSIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMB4XDTI1MTAyMzIwNDY1M1oXDTI2MTAy
# MjIwNDY1M1owgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsT
# Hm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9z
# b2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHkwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCxbKUKkwh9uLMktjWQ9c7ZyZfYdFa9FsCZ
# 4pJnl7Hv+MLKZ1XsRqn4hzaKpG1YOQop7mAvolXzTC2fkLaocks/FRgUo0bdSQeQ
# AjbUygI35haeFPwr9i4+Jvr7r3vSN1t4UoiJkxbB3mGelf0neN6164R1dun8N8UE
# rXkm4Pck7Na4Xay5AI+CpiNA+T+Cmr7coIq1clFtdIJIn1i0hNTYgfCZ90TuXY99
# nXnjDTjWmj58N5OPSAk7NxX8m/npDQz7DX2MAqj8jk8TOstXUg9CeY/iivVfhFsl
# eTw41fI459c7ErZUuk3GCSUrXIB7NsU/a7OqKFpeRbWH0ZAsYQ0oRKd7PCB1Fos0
# 1pi2bwBP+lkdgnfmZlWqRl0whySlAcmT8XV9IvIMp4q0fhMLhxzcRIpQyAi2rTtl
# mbvgkKx+GatDWKNU0OLVKWf5AFqaALta+JluRCdx5BGr0Nj7qEA3A6tqwBlSJWva
# Q+6PWMcM5fNQbg71BMrvQ/+hdKpkA3WhO/dR8XwlMaYDGD6XVk87PnQxj3ocEPD/
# dsj/AEY28uTp8tWevEY3kHm6cX+Vi+ONZshR3IE9VCc84pe7TxJEdtjX0zUehZfo
# 81m/6/NJ6pV5ZYcp0qMLcaNWNtsamL4ktuLJopFLASqjj20ku+7r1xDt1axuSxqL
# hNRGdWPaYwIDAQABo4IByzCCAccwHQYDVR0OBBYEFI6DyV4tNQ4CCUhn5uNemIPt
# EpKnMB8GA1UdIwQYMBaAFGtpKDo1L0hjQM972K9J6T7ZPdshMGwGA1UdHwRlMGMw
# YaBfoF2GW2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jv
# c29mdCUyMFB1YmxpYyUyMFJTQSUyMFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5j
# cmwweQYIKwYBBQUHAQEEbTBrMGkGCCsGAQUFBzAChl1odHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUy
# MFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5jcnQwDAYDVR0TAQH/BAIwADAWBgNV
# HSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwZgYDVR0gBF8wXTBR
# BgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEAjANBgkq
# hkiG9w0BAQwFAAOCAgEAcnXAdjzpmTlJQEM9jbl3+71glVpo1rvW7GNfhzI79cni
# 48Q0JI7CRFOc2iA8vFMPQWDfPhMV//ZP/QgVLF21ZW1OOHOuf5YsifN5FrBSFMIV
# Ws8EkoRZWyGb4iDv+cHslsk3zz6W0iYFsvmRPVK0Et8bpSSwBwNs1JDDD3QJReEa
# 54HGWdK+OQBfWiGI3XrLVsHazSu9DHwKx6mXYK4F59N8OswbNb+3M3HlhorYPw5b
# B6pNZlwaUk7hiNk0jzdxOtCCF8eX/wBc4ePxxYvfAQWW1BCzbF5FgBvcp2eXughY
# opdZoFgljk/dA+yIL4NMynt6N1gpOtvf3p/eCv7Av8yzn9ne8hZk8km/Xyo3DjR9
# Q295GfDMxCfHx0zZsa5ddBnnLs/xpdPgckyjfj2pm2fhdDCJQT8MOn74xQvSSCO9
# 38N6jtevfvU8U89hvhNuhmGNXXH37AIcOg6k0IG35W5dTvzK0l0rNDUm/ZwQ/UX0
# f3/BIuwwNS9YwTu72YYSU48Nk8xWvwC4ES4t1tNIR1ovCxkGmXPEsFyDGFn8KzfT
# IGG4TdCGpPVgNnalrnpF7E8DZJqw9xOhPqAmAnoTToGZnbNBM29Y6OzldCodti5d
# yh4NzB7ZRoLsQM4YPwaYsT0uKq1Cy5AIzu/sjbFH6w9lPYDH/zkeMiQz7czNMrUx
# ggdGMIIHQgIBATB4MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwAhMzAAAAVyTTleCi6ckxAAAAAABXMA0GCWCGSAFlAwQC
# AQUAoIIEnzARBgsqhkiG9w0BCRACDzECBQAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3
# DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjA0MTAyMTM5NTVaMC8GCSqGSIb3DQEJ
# BDEiBCCCSUBJsrmTbpGH0/n5x/OruCWAXKhseSPvVN8k9at2yzCBuQYLKoZIhvcN
# AQkQAi8xgakwgaYwgaMwgaAEIPU8n2S1BW5MZYhsos7h/VVQ6VRTb0BEISkNmYVM
# eNtSMHwwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFt
# cGluZyBDQSAyMDIwAhMzAAAAVyTTleCi6ckxAAAAAABXMIIDYQYLKoZIhvcNAQkQ
# AhIxggNQMIIDTKGCA0gwggNEMIICLAIBATCCAQmhgeGkgd4wgdsxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBB
# bWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAw
# LTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBT
# dGFtcGluZyBBdXRob3JpdHmiIwoBATAHBgUrDgMCGgMVAP0vMTmcQlEBQTZKzfFo
# oo9cecvDoGcwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwMA0GCSqGSIb3DQEBCwUAAgUA7YPK/DAiGA8yMDI2MDQx
# MDE5MTYxMloYDzIwMjYwNDExMTkxNjEyWjB3MD0GCisGAQQBhFkKBAExLzAtMAoC
# BQDtg8r8AgEAMAoCAQACAgkBAgH/MAcCAQACAhKBMAoCBQDthRx8AgEAMDYGCisG
# AQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMB
# hqAwDQYJKoZIhvcNAQELBQADggEBALLA/PBqHhS6mK+QE64tMKMD3UvqK1AZ9aS0
# 35lRF4UeNMOaL3+BvE+Xbq0bTJptZXKiYQ4wEJpzLwrzotgxCA2qwuTYvciTP1kF
# JHWUd7+ZLb6uV9JnKZ/DPVrhc8G8VPKF4GujvUZZClnnqU+uzy8ho/E7r3YOmUpe
# mkF3GKtOOK30p83J4JOhAAKZY6hmZHnGHnv7J6SOtGEetW4KfspVPKalaaBLUPBe
# ilCgysdZHKyV/gi/VNpehlanpOlp6tzAMxMJ0Zdr6+BpIw9C+KPFz0dz5BzQAFZJ
# 2tuOPYdewfXxPcvxG+5yBH7b4EP50HuQ/3ez0jvm7pvmN28ioDEwDQYJKoZIhvcN
# AQEBBQAEggIAal9qw7qcDKrJyqF2tFWlaDu6Y+64JTGQo90+YSldUGIJbte1SUAw
# Dkun5oI+Xe+Qw/pNXPfpgT3Vpvnb6UExztP4Z292e5yThCEV6T3MLkS+lpy9y383
# qUm4rg8t4RBYeEH7VmXnmNBtVzc/vbryG4rDsZpcc/WUR3vuV9Ea7i3vKtN19aPc
# XjJElQ8NxxwiSAuYybnZVtC44NrN+Mtofk8u2jicOgscID/3G0R86xlCSZIQJLhM
# Cw2ot7MCnL1AiQ7ilVYf5vuOxYEhHYkwejK7keguq0VO5EH/vxOHiQT3Bphrxif9
# HVLVgCJorCU7zAIGq0CmR/k07fZFcQq7Bt7m7lzDDa8dCiwW4A6dyPkfYgbnIPLx
# rW88PbkodYLRudwE4+EfprsxkXi1Btm7hVJ9dKtky6TT1EZqfCmopcKoMdEf/KPH
# VLkXwjTtdowed7EwDnE3B2RM+ejCSJuUlf0sI0cjx0K4T9ZK2qnklUZSgHGp10mw
# YNKawVH2XMXXoNtvqfhEQ04arfcNMwzBSqffReyFoJRuC2emKAspzzmhHdPDOUpr
# lX/8I9qRx6/dGujsiS80eR/TOmo/nHrEdxqrx/By1U60sk8sA6Gs1h5ken84g7tM
# KWo3e4WF73/nb53DcsWgRCRI4qXySoZsHk0psayAQAqn9i0iPf/Za5Y=
# SIG # End signature block

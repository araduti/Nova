<#
.SYNOPSIS
    Microsoft 365 / Azure AD authentication module for Nova.

.DESCRIPTION
    Provides OAuth2 Authorization Code Flow with PKCE for authenticating
    OSD operators.  Supports two modes:
      1. Embedded WebView2 popup (preferred -- no external browser needed)
      2. Default system browser + localhost HTTP listener (fallback)
    Also includes WebView2 SDK download/caching.
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
          Authenticated  [bool]  $true if auth succeeded or was not required.
          GraphAccessToken [string] Microsoft Graph access token, or $null.
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
        return @{ Authenticated = $true; GraphAccessToken = $null }
    }

    # Validate that the config has the minimum required fields.
    if (-not ((_HasProp $authConfig 'clientId') -and $authConfig.clientId)) {
        Write-Verbose "Auth config incomplete -- skipping authentication."
        return @{ Authenticated = $true; GraphAccessToken = $null }
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
                    return @{ Authenticated = $false; GraphAccessToken = $null }
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
            return @{ Authenticated = $false; GraphAccessToken = $null }
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
        return @{ Authenticated = $false; GraphAccessToken = $null }
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
            }
        }
    } catch {
        Write-Verbose "Token exchange failed: $_"
    }

    Write-Fail 'Token exchange failed.'
    return @{ Authenticated = $false; GraphAccessToken = $null }
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

#region ── WinPE Kiosk Auth Functions ──────────────────────────────────────────
# These functions are used by Bootstrap.ps1 inside the WinPE kiosk environment.
# They accept scriptblock parameters for UI callbacks so the module stays
# decoupled from the Bootstrap UI layer.

function Invoke-KioskEdgeAuth {
    <#
    .SYNOPSIS  Authenticate the operator via the kiosk Edge browser (Auth Code + PKCE).
    .DESCRIPTION
        Navigates the existing Edge kiosk browser to the Azure AD authorization
        endpoint.  The user signs in directly in the kiosk browser window.
        A temporary localhost HTTP listener captures the redirect carrying the
        authorization code, then exchanges it for tokens using PKCE.
        After authentication completes (or fails), the listener redirects the
        browser back to the Nova-UI page.
        WinPE-safe -- no separate Edge process or WinForms dialog is created.
    .PARAMETER ClientId
        Azure AD application (client) ID.
    .PARAMETER Scope
        OAuth 2.0 scopes to request (space-separated).
    .PARAMETER HtmlUiActive
        Whether the kiosk HTML UI is currently running.
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
        [bool]$HtmlUiActive = $false,
        [scriptblock]$WriteLog,
        [scriptblock]$UpdateUi,
        [scriptblock]$CheckCancelled,
        [scriptblock]$DoEvents
    )

    $fail = @{ Success = $false; GraphAccessToken = $null }

    # ── Verify the HTML UI is active (kiosk Edge must be running) ───────────
    if (-not $HtmlUiActive) {
        if ($WriteLog) { & $WriteLog "HTML UI not active -- cannot use in-kiosk auth." }
        return $fail
    }

    # ── Log environment diagnostics ─────────────────────────────────────────
    if ($WriteLog) { & $WriteLog "Kiosk auth starting" }

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

    # ── Signal the HTML UI to open the login page in a popup ───────────────
    if ($WriteLog) { & $WriteLog "Opening auth popup via kiosk UI" }
    if ($UpdateUi) { & $UpdateUi @{ AuthUrl = $authorizeUrl } }

    # ── Wait for the redirect callback ──────────────────────────────────────
    $asyncResult = $listener.BeginGetContext($null, $null)

    # 5-minute timeout -- Azure AD sessions are valid for 10 minutes,
    # 5 minutes gives enough time without leaving the kiosk unattended.
    $timeout = [datetime]::UtcNow.AddMinutes(5)
    $cancelled = $false

    while (-not $authCode -and -not $authError `
           -and -not $cancelled -and [datetime]::UtcNow -lt $timeout) {

        if ($CheckCancelled) { $cancelled = (& $CheckCancelled) -eq $true }

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

                # Clear the auth signal before the popup closes.
                if ($UpdateUi) { & $UpdateUi @{ ClearAuth = $true } }

                # Send a response page that closes the auth popup window.
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

    # ── Always clear auth signal ────────────────────────────────────────────
    if ($UpdateUi) { & $UpdateUi @{ ClearAuth = $true } }

    } finally {
        try { $listener.Stop(); $listener.Close() } catch { $null = $_ }
    }

    if ($cancelled -or -not $authCode) {
        $codeStatus = if ($authCode) { 'present' } else { 'missing' }
        if ($WriteLog) { & $WriteLog "Kiosk auth ended without auth code. Cancelled=$cancelled, AuthCode=$codeStatus" }
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
            if ($WriteLog) { & $WriteLog "Kiosk auth succeeded -- token obtained." }
            return @{ Success = $true; GraphAccessToken = $graphToken }
        }
    } catch {
        if ($WriteLog) { & $WriteLog "Token exchange failed: $_" }
    }

    return $fail
}

function Invoke-KioskDeviceCodeAuth {
    <#
    .SYNOPSIS  Authenticate the operator via Device Code Flow (WinPE kiosk fallback).
    .DESCRIPTION
        Fallback authentication path used when the kiosk Edge auth is not
        available.  Initiates the Device Code Flow and shows the one-time
        code and verification URL in the HTML UI as a modal overlay.
    .PARAMETER ClientId
        Azure AD application (client) ID.
    .PARAMETER Scope
        OAuth 2.0 scopes to request (space-separated).
    .PARAMETER WriteLog
        Scriptblock for writing auth log entries.  Called with a single string argument.
    .PARAMETER UpdateUi
        Scriptblock for updating the HTML UI.  Called with a hashtable of parameters.
    .PARAMETER CheckCancelled
        Scriptblock that returns $true when auth has been cancelled.
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
        [scriptblock]$WriteLog,
        [scriptblock]$UpdateUi,
        [scriptblock]$CheckCancelled,
        [scriptblock]$DoEvents
    )

    $fail = @{ Success = $false; GraphAccessToken = $null }

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
        if ($WriteLog) { & $WriteLog "Device code request failed: $_" }
        return $fail
    }

    $userCode   = $deviceResponse.user_code
    $deviceCode = $deviceResponse.device_code
    $expiresIn  = if ((_HasProp $deviceResponse 'expires_in') -and $deviceResponse.expires_in) { [int]$deviceResponse.expires_in } else { 900 }
    $interval   = if ((_HasProp $deviceResponse 'interval')   -and $deviceResponse.interval)   { [int]$deviceResponse.interval   } else { 5   }

    # ── Show device code in the HTML UI modal ───────────────────────────────
    if ($UpdateUi) { & $UpdateUi @{ ShowDeviceCode = $true; DeviceCode = $userCode } }

    # ── Poll for token ──────────────────────────────────────────────────────
    $expiry   = [datetime]::UtcNow.AddSeconds($expiresIn)
    $nextPoll = [datetime]::UtcNow.AddSeconds($interval)
    $tokenResponse = $null
    $cancelled = $false

    while (-not $cancelled -and [datetime]::UtcNow -lt $expiry) {
        if ($CheckCancelled) { $cancelled = (& $CheckCancelled) -eq $true }
        if ($cancelled) { break }

        if ([datetime]::UtcNow -ge $nextPoll) {
            try {
                $body = "grant_type=$([uri]::EscapeDataString($grantType))" +
                        "&client_id=$([uri]::EscapeDataString($ClientId))" +
                        "&device_code=$([uri]::EscapeDataString($deviceCode))"
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
                $raw = $wc.UploadString($tokenUrl, 'POST', $body)
                $tr = $raw | ConvertFrom-Json
                if ((_HasProp $tr 'id_token') -and $tr.id_token) {
                    $tokenResponse = $tr
                    break
                }
            } catch {
                $msg = $_.ToString()
                if ($msg -notmatch 'authorization_pending' -and $msg -notmatch 'slow_down') {
                    if ($WriteLog) { & $WriteLog "Token poll error: $msg" }
                }
            }
            $nextPoll = [datetime]::UtcNow.AddSeconds($interval)
        }

        if ($DoEvents) { & $DoEvents }
        Start-Sleep -Milliseconds 200
    }

    # ── Clear the device code modal ─────────────────────────────────────────
    if ($UpdateUi) { & $UpdateUi @{ ClearAuth = $true } }

    if (-not $tokenResponse) {
        return $fail
    }

    $graphToken = if ((_HasProp $tokenResponse 'access_token') -and $tokenResponse.access_token) { $tokenResponse.access_token } else { $null }    if ($WriteLog) { & $WriteLog "Device code auth succeeded -- token obtained." }
    return @{ Success = $true; GraphAccessToken = $graphToken }
}

function Invoke-KioskM365Auth {
    <#
    .SYNOPSIS  Authenticate the operator via M365 (kiosk browser, Device Code fallback).
    .DESCRIPTION
        Downloads config/auth.json from the GitHub repository.  When
        requireAuth is true and a clientId is configured, the function
        first attempts interactive sign-in by navigating the existing
        kiosk Edge browser to Azure AD (Authorization Code Flow with
        PKCE).  If the kiosk UI is not active or fails, it falls back
        to Device Code Flow, showing the code in an HTML modal.
        Tenant restrictions are enforced at the Entra ID app registration
        level -- only tenants explicitly allowed in the app's
        "Supported account types" configuration can complete sign-in.
    .PARAMETER GitHubUser   GitHub account that hosts the Nova repository.
    .PARAMETER GitHubRepo   Repository name.
    .PARAMETER GitHubBranch Branch to fetch auth config from.
    .PARAMETER HtmlUiActive Whether the kiosk HTML UI is currently running.
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
        [bool]$HtmlUiActive   = $false,
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

    # ── Try kiosk Edge browser auth first ──────────────────────────────────
    $edgeResult = @{ Success = $false; GraphAccessToken = $null }
    try {
        $edgeResult = Invoke-KioskEdgeAuth `
            -ClientId $clientId -Scope $scope `
            -HtmlUiActive $HtmlUiActive `
            -WriteLog $WriteLog -UpdateUi $UpdateUi `
            -CheckCancelled $CheckCancelled -DoEvents $DoEvents
    } catch {
        if ($WriteLog) { & $WriteLog "Kiosk auth failed, will fall back to Device Code Flow: $_" }
    }

    if ($edgeResult.Success) {
        if ($WriteStatus) { & $WriteStatus 'Identity verified' 'Green' }
        if ($PlaySound)   { & $PlaySound 1000 200 }
        Start-Sleep -Seconds 1
        return @{ Authenticated = $true; GraphAccessToken = $edgeResult.GraphAccessToken; AuthConfig = $authConfig }
    }

    # ── Fallback: Device Code Flow ──────────────────────────────────────────
    if ($WriteLog) { & $WriteLog "Falling back to Device Code Flow..." }
    $dcResult = @{ Success = $false; GraphAccessToken = $null }
    try {
        $dcResult = Invoke-KioskDeviceCodeAuth `
            -ClientId $clientId -Scope $scope `
            -WriteLog $WriteLog -UpdateUi $UpdateUi `
            -CheckCancelled $CheckCancelled -DoEvents $DoEvents
    } catch {
        if ($WriteLog) { & $WriteLog "Device Code Flow failed: $_" }
    }

    if ($dcResult.Success) {
        if ($WriteStatus) { & $WriteStatus 'Identity verified' 'Green' }
        if ($PlaySound)   { & $PlaySound 1000 200 }
        Start-Sleep -Seconds 1
        return @{ Authenticated = $true; GraphAccessToken = $dcResult.GraphAccessToken; AuthConfig = $authConfig }
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
    'Invoke-KioskEdgeAuth'
    'Invoke-KioskDeviceCodeAuth'
    'Invoke-KioskM365Auth'
)

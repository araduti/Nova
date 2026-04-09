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

# SIG # Begin signature block
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCADmDHcel5k160l
# YZAqXWdzZyrCrawlPDYzNm0kSWqUJKCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAATbzZ1
# WlQRwN+WAAAAABNvMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNDA4MTQzNTAyWhcNMjYwNDEx
# MTQzNTAyWjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCaXp6ZOAqpSGDC
# lEJL0tP6AaWlljn7+Nyx7mo3psGnxvPkngIY/lD/QHTpKOndvoq4knt04gr0kkGp
# ClfAlaI1BNcS+k6W3jy/dtA6w/k456OkCkjjGLqFEHaNXKVqnzI92GP6gCmn9ov0
# +uni4oROr5At/kLAh0zyXqTNBNQ+qd1QzQ4Y+CgIXlKnGBbi0RVx21T4tDsZ8mCX
# yxvlRHdXFNtEkEmkkGxbOziPkvav6QLRnr7/tALqWOrY1WHX6T/SGbrh5OPQivvs
# w94+JUX/m2uzHV6j0qHdfe8BJyYQ3U3NAGNFSQoshMtbV721R3XEnaXBy2U1A6TH
# zixwtXxQ5zRPrU65hNPrSTzkiK+a2VOLlOGP7+es1Eq8lKFRUVvjNFW1YgWwGf3g
# P2Z+4B2uMdml126+rmdUvTyAmEBqYeLNIfGfnTa+qlD9Lno8rqTyLrcN3bv8st+7
# Au+V47C6PDqbTyb/TjZ6BsoXsJtmLZAruTlFpCINQa4bksFN3d8CAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUYsueSbGxd9TixyeW27ISjBdBHnEwHwYDVR0jBBgwFoAUa16lNMMF
# xWJKIVqOq3NgYtSsY4UwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMy5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAELukzNfojQy7MXCmtBzdvxdxKTEvjdX3Zvu+aX5sDNMsy/q8JYeQG8u
# hingdUYeqHjwOtgenn5kqnY7Kb2C7IltAr6dZGZ/l+SSZGrAD0plWX5rUfhhTLGe
# j95/4C5Jnku01cG2FXBQbMkGaY1xe/bfnK8wn931lajOBdsbfVkhmTEIdchxu6sz
# /0UVg3tlIRqiiJtQCE71iWJVNmW8IdVOXhzy0dFOmhUHVgNelCAPqdJChaQvKwTJ
# 97SYWRT33jKI0+ylRRmKmEO1a8cMPIkn6cImafpGD9pmsquet3PLuQNGDAU5FYrm
# o5sqBW/LXTspdjbfje9obnCXKgOY/JLIiGaUZYppeRTWWwwnAHcFm6v40/CGADij
# VZhC0XiGYdEuYjbM0V4btEtcOtDr18oMVLwV27rJwxCek6wfza0ojyVYk1B0HC1k
# R6UICd3Mhrok4n0OOVn9RArCK4QrJ3oGpuHLU0H80XQdeJP95K4HsVj3Ln8S5qOV
# 0u98nFEyhg39UKnJioibO4tHeLWAY+CEpI/qoTva8SBMPc292R92mEWd5ck3xFG+
# voVEjXUwh9YbxRIVg14i4DFQSABoDbNwwuZ//uAP7e1/NaYskP8jbAjcm8AEaUeh
# 1CHYMwwA3ylB0lRP/e/Awtw4mFMKOFr0B4yLykkGvtK1hFlbWMqIMIIGyTCCBLGg
# AwIBAgITMwAAE282dVpUEcDflgAAAAATbzANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMB4XDTI2MDQwODE0
# MzUwMloXDTI2MDQxMTE0MzUwMlowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAml6emTgKqUhgwpRCS9LT+gGlpZY5+/jcse5qN6bBp8bz5J4CGP5Q/0B06Sjp
# 3b6KuJJ7dOIK9JJBqQpXwJWiNQTXEvpOlt48v3bQOsP5OOejpApI4xi6hRB2jVyl
# ap8yPdhj+oApp/aL9Prp4uKETq+QLf5CwIdM8l6kzQTUPqndUM0OGPgoCF5SpxgW
# 4tEVcdtU+LQ7GfJgl8sb5UR3VxTbRJBJpJBsWzs4j5L2r+kC0Z6+/7QC6ljq2NVh
# 1+k/0hm64eTj0Ir77MPePiVF/5trsx1eo9Kh3X3vAScmEN1NzQBjRUkKLITLW1e9
# tUd1xJ2lwctlNQOkx84scLV8UOc0T61OuYTT60k85IivmtlTi5Thj+/nrNRKvJSh
# UVFb4zRVtWIFsBn94D9mfuAdrjHZpdduvq5nVL08gJhAamHizSHxn502vqpQ/S56
# PK6k8i63Dd27/LLfuwLvleOwujw6m08m/042egbKF7CbZi2QK7k5RaQiDUGuG5LB
# Td3fAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFGLLnkmxsXfU4scnltuyEowXQR5xMB8GA1Ud
# IwQYMBaAFGtepTTDBcViSiFajqtzYGLUrGOFMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDAzLmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBC7pMzX6I0MuzFwprQc3b8XcSkxL43V92b7vml
# +bAzTLMv6vCWHkBvLoYp4HVGHqh48DrYHp5+ZKp2Oym9guyJbQK+nWRmf5fkkmRq
# wA9KZVl+a1H4YUyxno/ef+AuSZ5LtNXBthVwUGzJBmmNcXv235yvMJ/d9ZWozgXb
# G31ZIZkxCHXIcburM/9FFYN7ZSEaooibUAhO9YliVTZlvCHVTl4c8tHRTpoVB1YD
# XpQgD6nSQoWkLysEyfe0mFkU994yiNPspUUZiphDtWvHDDyJJ+nCJmn6Rg/aZrKr
# nrdzy7kDRgwFORWK5qObKgVvy107KXY2343vaG5wlyoDmPySyIhmlGWKaXkU1lsM
# JwB3BZur+NPwhgA4o1WYQtF4hmHRLmI2zNFeG7RLXDrQ69fKDFS8Fdu6ycMQnpOs
# H82tKI8lWJNQdBwtZEelCAndzIa6JOJ9DjlZ/UQKwiuEKyd6Bqbhy1NB/NF0HXiT
# /eSuB7FY9y5/EuajldLvfJxRMoYN/VCpyYqImzuLR3i1gGPghKSP6qE72vEgTD3N
# vdkfdphFneXJN8RRvr6FRI11MIfWG8USFYNeIuAxUEgAaA2zcMLmf/7gD+3tfzWm
# LJD/I2wI3JvABGlHodQh2DMMAN8pQdJUT/3vwMLcOJhTCjha9AeMi8pJBr7StYRZ
# W1jKiDCCBygwggUQoAMCAQICEzMAAAAVBT5uGY6TKdkAAAAAABUwDQYJKoZIhvcN
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
# UyBFT0MgQ0EgMDMCEzMAABNvNnVaVBHA35YAAAAAE28wDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgSfPjZLzl5eoVl57JbNeneZbhVGVVSPKm8r4O0GtWct4w
# DQYJKoZIhvcNAQEBBQAEggGAXeRerYRQLXoW2weaD6B7VHPRKHgvCfi0M5ik4rTQ
# kj/p7ilZagCMv12dI+H7fDjlsXOYx+yEzbfjwi/iiu1e5Vq5MIGqba9dWFjj4ylO
# dl8fIebm03B4j4jtBsfB8CU0h/8ZVQFac+Omv77kPcTGnXCh48KH3YY65wkQ77nd
# 7EiIIKdNmt/xeOWzonU7X4jauSih/V8a3cj92b4BcMjwmGDANg69H/WLaeyCOr/X
# 9pVkI7zYtYSd71QvKRY7QlxVX/nnMFRqKNMh0X+9QBFwl0F+h/C/o/tUBCK6pbFB
# GxqCdUOLFGLBlBAYRL2F40ToueA4A/hlzXgYXMpx2vl0h++TnWDO848aroaXAED+
# Y4U0xwXaqHzdIPwfvhiGEBhLrycXdEKC5y+nP5ZQlkziKeuJzWo4UFdvdBLAq3GI
# set+gkZvkokB9YBqr5pgagPdgSOkvvtDyQCwSyGjoEKoPexyrPe2nxFn0EtCcEPo
# lUAmDVfMwRrlV2T+gGB2MwypoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEII91YxnZN41/4V/6BvUFjg1QTPXqUOOPP+yYLzR29Vk8AgZpwnLO8fMYEzIw
# MjYwNDA5MTIxMzU3LjMwNVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
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
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDA5MTIxMzU3WjAvBgkqhkiG9w0B
# CQQxIgQgfs2nbZDG7+BHA7sB2glRaTorMWWiTGNv3jsfoGnwJHcwgbkGCyqGSIb3
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
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2CCR0wIhgPMjAyNjA0
# MDkxMTE2NDVaGA8yMDI2MDQxMDExMTY0NVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7YIJHQIBADAHAgEAAgI5STAHAgEAAgIXkTAKAgUA7YNanQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCmQByR+XzJkONpGAedVVXxRSvgki09KgTvaB9K
# raNaMgGfBJVIdTjxw1cnX+X/4nq9H8xilTSUTHOw4SeW4i6pgxLz8j+PdEmWf3Mq
# UiiudsSXBCXlDx4/U1x7LkhBtyrSX6c+PWqcKXYbTMVr3i7rgIdWWPQbJq6DRH4I
# MEcYi+ECce2vy71KlFBPhaKeYhQs4SgZeU1qeyGCu/Iq5R+D7A5BY0Nj04FRTW/u
# 82LNwDcEA/UMvtzp6un/yp1wjTAfNZA+V9SNn4/aOg8rjXA4vT/HnU/uRceo7TvY
# dcK+EbxpVnylBSwEgj93TpkAvI/fHXFlh956pjiBbNdzT1jUMA0GCSqGSIb3DQEB
# AQUABIICAF0kJZtxDi2w+NQ2ShXoVw8TnpwAmoIAh66r+hyWgg9rKJIjg699hGFz
# oQPplgdDdJzcQFIhuQhMnagjVD1N+SG1h0aUalrgF7GqXoUnf89vLaT6lSsIoXMC
# 2TOtlPK+FpTJZkkrctLW7OuWdigX73szhnyBv5Cn3gjxXFzN6DQqE0x0QlNNvQk0
# ObRCsSxhWHNyFDLovIqLOPcBvSMIZoM/CW6IRY1fdHTgUVG59WUWnmjUCa8czxnm
# o8SvzyeWoY45fVHH3LdodffpBQ1EoDp/xsx/4JNRJn1yj3G/cAPG0Vyef5ac7cRd
# SnVB8ujfKAnSYc12Gz1YMglGtisdS/3aVgOr4+iASMOPj66sqAKRa/8EOdH+7jXv
# UfqmF7q0VHErja2Xabdv3mYuoZ7WGlzCew/Nr+KjTp7E4ha0uJCl4EdhNMc3irSz
# AF3/5ZRbQ2f6f+M10FGF5PXqcboX08UGTC5oa3oBZC1pVkKHRwV2topf1Z2pG3Vg
# ZEizmY4cbvKywJGQi3FNzYrmAvpN7W2OGC3jDZuvt9y2XnswkT9NY+yUXnHfM4XD
# llidxvkBq4Yzq6qZVVXlL4CWdwbuMnd8ZaZKkpnv/4ybQNAuEghZwLv6TbY7BYTK
# zz/WLr+ofhJDjDPqaWXxYSeg83K9XTAneQr871edKSmMsZ1YxH/N
# SIG # End signature block

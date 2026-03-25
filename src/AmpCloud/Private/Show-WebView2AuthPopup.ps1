function Show-WebView2AuthPopup {
    <#
    .SYNOPSIS  Show an embedded WebView2 popup for Azure AD sign-in.
    .DESCRIPTION
        Creates a WinForms dialog with an embedded WebView2 control that
        navigates to the Azure AD authorization endpoint.  The redirect is
        intercepted via the NavigationStarting event — no HTTP listener is
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
    $userDataDir = Join-Path $env:TEMP 'AmpCloud-WebView2Auth'
    if (-not (Test-Path $userDataDir)) {
        $null = New-Item -Path $userDataDir -ItemType Directory -Force
    }

    $envOptions = [Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions]::new()
    $envTask    = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync(
                      $null, $userDataDir, $envOptions)

    # Poll for completion — do NOT use .GetAwaiter().GetResult() as it
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
    $form.Text            = 'AmpCloud — Sign In'
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
        try { $wv2.Dispose() } catch {}
        try { $form.Dispose() } catch {}
        $ex = if ($initTask.Exception) { $initTask.Exception.InnerException } else { $null }
        throw "WebView2 control initialisation failed: $ex"
    }

    # ── Intercept the redirect to capture the authorization code ───────────
    $script:_wv2PopupCode     = $null
    $script:_wv2PopupError    = $null
    $script:_wv2PopupForm     = $form
    $script:_wv2RedirectBase  = $RedirectUriBase

    $wv2.CoreWebView2.add_NavigationStarting({
        param($sender, $e)
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
            } catch {}
            $script:_wv2PopupForm.DialogResult = if ($script:_wv2PopupCode) { 'OK' } else { 'Abort' }
            $script:_wv2PopupForm.Close()
        }
    })

    # ── Navigate and show the form ─────────────────────────────────────────
    $wv2.CoreWebView2.Navigate($AuthorizeUrl)
    $dialogResult = $form.ShowDialog()

    # ── Clean up ───────────────────────────────────────────────────────────
    try { $wv2.Dispose() } catch {}
    try { $form.Dispose() } catch {}

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

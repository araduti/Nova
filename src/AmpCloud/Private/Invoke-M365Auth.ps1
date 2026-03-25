function Invoke-M365Auth {
    <#
    .SYNOPSIS  Authenticate the operator via M365 (Edge browser, Device Code fallback).
    .DESCRIPTION
        Downloads Config/auth.json from the GitHub repository.  When
        requireAuth is true and a clientId is configured, the function
        first attempts interactive sign-in by launching a standalone
        Edge browser (Authorization Code Flow with PKCE).  If the Edge
        browser is not present or fails, it falls back to Device Code
        Flow.
        Tenant restrictions are enforced at the Entra ID app registration
        level — only tenants explicitly allowed in the app's
        "Supported account types" configuration can complete sign-in.
    .OUTPUTS
        $true  if authentication succeeded or was not required.
        $false if authentication failed.
    #>

    # ── Fetch auth configuration from the repository ────────────────────────
    $authConfigUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/Config/auth.json"
    $authConfig    = $null
    try {
        $wc      = New-Object System.Net.WebClient
        $rawJson = $wc.DownloadString($authConfigUrl)
        $authConfig = $rawJson | ConvertFrom-Json
    } catch {
        Write-AuthLog "Could not fetch auth config: $_"
    }

    # If auth is not configured or not required, skip silently.
    if (-not $authConfig -or -not $authConfig.requireAuth) {
        Write-Status $S.AuthSkipped 'Green'
        return $true
    }

    # Validate that the config has the minimum required fields.
    if (-not $authConfig.clientId) {
        Write-AuthLog "Auth config incomplete — skipping authentication."
        Write-Status $S.AuthSkipped 'Green'
        return $true
    }

    $clientId = $authConfig.clientId

    # ── Build scope string ──────────────────────────────────────────────────
    # Always include openid profile; append Graph API scopes when configured
    # (e.g. DeviceManagementServiceConfig.ReadWrite.All for Autopilot import).
    # Delegated permissions — no client secret required.
    $scope = 'openid profile'
    if ($authConfig.graphScopes) {
        $trimmed = ($authConfig.graphScopes).Trim()
        if ($trimmed) { $scope = "openid profile $trimmed" }
    }

    # Expose the auth config for post-auth integration (Autopilot import).
    $script:AuthConfig = $authConfig

    Write-Status $S.AuthSigning 'Cyan'
    [System.Windows.Forms.Application]::DoEvents()

    # ── Try standalone Edge browser first ───────────────────────────────────
    # Edge is launched directly with WinPE-safe Chromium flags.  A localhost
    # HTTP listener captures the OAuth redirect.  Requires the Edge browser
    # to be embedded during Build-WinPE (step 4e).  If Edge is not present
    # or fails, fall back to Device Code Flow transparently.
    $browserOk = $false
    try {
        $browserOk = Invoke-M365EdgeAuth -ClientId $clientId -Scope $scope
    } catch {
        Write-AuthLog "Edge auth failed, will fall back to Device Code Flow: $_"
    }

    if ($browserOk) {
        Write-Status $S.AuthSuccess 'Green'
        Invoke-Sound 1000 200
        Start-Sleep -Seconds 1
        return $true
    }

    # ── Fallback: Device Code Flow ──────────────────────────────────────────
    Write-AuthLog "Falling back to Device Code Flow... (see $script:AuthLogPath for details)"
    $deviceOk = $false
    try {
        $deviceOk = Invoke-M365DeviceCodeAuth -ClientId $clientId -Scope $scope
    } catch {
        Write-AuthLog "Device Code Flow failed: $_"
    }

    if ($deviceOk) {
        Write-Status $S.AuthSuccess 'Green'
        Invoke-Sound 1000 200
        Start-Sleep -Seconds 1
        return $true
    }

    Write-Status $S.AuthFailed 'Red'
    Start-Sleep -Seconds 3
    return $false
}

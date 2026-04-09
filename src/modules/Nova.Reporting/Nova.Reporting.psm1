<#
.SYNOPSIS
    Deployment reporting, alerting, and log export module for Nova.

.DESCRIPTION
    Provides functions for saving deployment reports, asset inventory,
    sending deployment alerts (Teams, Slack, email), pushing reports to
    GitHub, and exporting WinPE logs to the target OS drive.
#>

Set-StrictMode -Version Latest

# ── Module-scoped state ────────────────────────────────────────────────────────
# Cached GitHub token obtained via Entra ID exchange so we don't re-fetch
# on every status update call.
$script:CachedEntraGitHubToken = $null
$script:CachedEntraGitHubTokenTime = [datetime]::MinValue
# Negative cache: avoid retrying a recently-failed token exchange.
$script:EntraExchangeLastFailure = $null
# One-shot flag: warn once when no GitHub token can be resolved so the user
# knows status reporting is disabled without flooding the log on every step.
$script:GitHubTokenWarningShown = $false

# ── Public Functions ───────────────────────────────────────────────────────────

function Get-GitHubTokenViaEntra {
    <#
    .SYNOPSIS  Exchanges an Entra ID token for a GitHub installation token.
    .DESCRIPTION
        Calls the Nova OAuth proxy's /api/token-exchange endpoint to
        convert the Entra ID access token (already obtained during sign-in
        by Bootstrap.ps1 and stored in $env:NOVA_GRAPH_TOKEN) into a
        short-lived GitHub App installation access token scoped to
        contents:write.

        This eliminates the need for a separate $env:GITHUB_TOKEN.  The
        proxy validates the Entra token against Microsoft Graph and only
        issues a GitHub token to authenticated users.

        Returns $null if the exchange is not available (no Entra token,
        no proxy configured, or proxy returns an error).
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [string]$GitHubUser,
        [string]$GitHubRepo,
        [string]$GitHubBranch
    )
    # Return the cached token when available and not expired (GitHub App
    # installation tokens are valid for 1 hour; re-fetch after 55 min).
    if ($script:CachedEntraGitHubToken -and ((Get-Date) - $script:CachedEntraGitHubTokenTime).TotalMinutes -lt 55) {
        return $script:CachedEntraGitHubToken
    }

    # Don't retry a recently failed exchange (wait at least 5 min).
    if ($script:EntraExchangeLastFailure -and ((Get-Date) - $script:EntraExchangeLastFailure).TotalMinutes -lt 5) {
        Write-Verbose "Skipping Entra->GitHub exchange: last attempt failed less than 5 minutes ago"
        return $null
    }

    $entraToken = $env:NOVA_GRAPH_TOKEN
    if (-not $entraToken) {
        if (-not $script:GitHubTokenWarningShown) {
            Write-Warning "NOVA_GRAPH_TOKEN is not set -- Entra->GitHub token exchange unavailable. Set GITHUB_TOKEN or sign in via Entra ID to enable deployment status reporting."
            $script:GitHubTokenWarningShown = $true
        }
        return $null
    }

    # ── Resolve the OAuth proxy URL from config/auth.json ──────────
    $proxyUrl = $null
    try {
        $cfgUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/auth.json"
        $cfg = Invoke-RestMethod -Uri $cfgUrl -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
        $proxyUrl = $cfg.githubOAuthProxy
    } catch {
        Write-Warning "Could not load auth config for Entra exchange: $_"
    }
    if (-not $proxyUrl) {
        Write-Warning "No githubOAuthProxy URL in config/auth.json -- cannot exchange Entra token for GitHub token."
        return $null
    }

    # ── Call the proxy's token exchange endpoint ───────────────────
    # Uses .NET HttpWebRequest instead of Invoke-RestMethod so that HTTP
    # error responses (e.g. 401 for an expired Entra token) do not produce
    # PS>TerminatingError transcript entries that look like unhandled errors.
    $resp = $null
    try {
        $exchangeUrl = "$proxyUrl/api/token-exchange"
        $req = [System.Net.HttpWebRequest]::Create($exchangeUrl)
        $req.Method      = 'POST'
        $req.ContentType = 'application/json'
        $req.Headers.Add('Authorization', "Bearer $entraToken")
        $req.UserAgent   = 'Nova-Engine'
        $req.Timeout         = 15000
        $req.ReadWriteTimeout = 15000

        $statusCode = 0
        try {
            $resp       = $req.GetResponse()
            $statusCode = [int]$resp.StatusCode
        } catch [System.Net.WebException] {
            $resp       = $_.Exception.Response
            $statusCode = if ($resp) { [int]$resp.StatusCode } else { 0 }
        }

        if ($statusCode -eq 200 -and $resp) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            try {
                $body   = $reader.ReadToEnd()
            } finally {
                $reader.Close()
            }
            $result = $body | ConvertFrom-Json
            if ($result.token) {
                Write-Verbose "GitHub token obtained via Entra ID exchange (user: $($result.user))"
                $script:CachedEntraGitHubToken     = $result.token
                $script:CachedEntraGitHubTokenTime = Get-Date
                return $result.token
            }
        } else {
            $errBody = ''
            if ($resp) {
                try {
                    $reader  = New-Object System.IO.StreamReader($resp.GetResponseStream())
                    $errBody = $reader.ReadToEnd()
                    $reader.Close()
                } catch { $null = $_ }
            }
            Write-Warning "Entra->GitHub token exchange failed (HTTP $statusCode): $(if ($errBody) { $errBody.Substring(0, [math]::Min($errBody.Length, 200)) } else { '(no response body)' })"
            $script:EntraExchangeLastFailure = Get-Date
        }
    } catch {
        Write-Warning "Entra->GitHub token exchange failed: $_"
        $script:EntraExchangeLastFailure = Get-Date
    } finally {
        if ($resp) { $resp.Close() }
    }
    return $null
}

function Push-ReportToGitHub {
    <#
    .SYNOPSIS  Pushes a deployment JSON file to the GitHub repo via the Contents API.
    .DESCRIPTION
        Uses the GitHub REST API (PUT /repos/{owner}/{repo}/contents/{path}) to
        write a per-device JSON file into the deployments/ directory.  Each file
        is named after the device, so concurrent deployments never collide.

        The API call is atomic -- there is no git clone/push, so it cannot
        conflict with the .github/ workflows or block other pushes.

        Token resolution order:
          1. -Token parameter (explicit)
          2. $env:GITHUB_TOKEN (classic PAT -- backward compatible)
          3. Entra ID exchange -- if $env:NOVA_GRAPH_TOKEN is set and the
             OAuth proxy (from config/auth.json) is configured, the Entra
             token is exchanged for a short-lived GitHub installation token.
             This is the recommended path: no separate GitHub PAT required.

        If no token can be resolved the function silently returns so that
        deployments still succeed without any token configured.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [hashtable]$Content,
        [string]$Token  = $env:GITHUB_TOKEN,
        [switch]$Delete,
        [string]$GitHubUser,
        [string]$GitHubRepo,
        [string]$GitHubBranch
    )

    # ── Token resolution: try Entra exchange when no explicit token ──
    if (-not $Token) {
        $Token = Get-GitHubTokenViaEntra -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
    }
    if (-not $Token) {
        if (-not $script:GitHubTokenWarningShown) {
            Write-Warning "No GitHub token available (GITHUB_TOKEN not set, Entra exchange unavailable). Deployment status will NOT be reported to GitHub."
            $script:GitHubTokenWarningShown = $true
        }
        return
    }

    $maxRetries = 3

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $apiUrl = "https://api.github.com/repos/$GitHubUser/$GitHubRepo/contents/$FilePath"
            $headers = @{
                Authorization  = "Bearer $Token"
                Accept         = 'application/vnd.github.v3+json'
                'User-Agent'   = 'Nova-Engine'
            }

            # Get the current file SHA (required for updates/deletes)
            $sha = $null
            try {
                $existing = Invoke-RestMethod -Uri $apiUrl -Headers $headers `
                    -Method Get -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
                $sha = $existing.sha
            } catch {
                # File does not exist yet -- that is fine for creates.
                # For deletes, file is already gone -- nothing to do.
                if ($Delete) { return }
            }

            if ($Delete) {
                $body = @{
                    message = "Remove active deployment: $(Split-Path $FilePath -Leaf)"
                    sha     = $sha
                    branch  = $GitHubBranch
                } | ConvertTo-Json
                Invoke-RestMethod -Uri $apiUrl -Headers $headers `
                    -Method Delete -Body $body -ContentType 'application/json' `
                    -UseBasicParsing -ErrorAction Stop -TimeoutSec 15 | Out-Null
            } else {
                $jsonBytes  = [System.Text.Encoding]::UTF8.GetBytes(($Content | ConvertTo-Json))
                $b64Content = [Convert]::ToBase64String($jsonBytes)
                $body = @{
                    message = "Deployment report: $(Split-Path $FilePath -Leaf)"
                    content = $b64Content
                    branch  = $GitHubBranch
                }
                if ($sha) { $body.sha = $sha }
                $body = $body | ConvertTo-Json
                Invoke-RestMethod -Uri $apiUrl -Headers $headers `
                    -Method Put -Body $body -ContentType 'application/json' `
                    -UseBasicParsing -ErrorAction Stop -TimeoutSec 15 | Out-Null
            }

            # Success -- exit retry loop
            return
        } catch {
            $verb = if ($Delete) { 'DELETE' } else { 'PUT' }
            if ($attempt -lt $maxRetries) {
                Write-Warning "GitHub $verb attempt $attempt/$maxRetries failed for '$FilePath': $_ -- retrying in $($attempt * 2)s..."
                Start-Sleep -Seconds ($attempt * 2)
            } else {
                Write-Warning "GitHub $verb failed after $maxRetries attempts for '$FilePath': $_"
            }
        }
    }
}

function Save-DeploymentReport {
    <#
    .SYNOPSIS  Writes a deployment result report to a JSON file.
    .DESCRIPTION
        Records the outcome of a deployment (success or failure) along with
        timing, device, and error details.  The report is saved to the scratch
        directory so it can be collected by downstream tooling or the monitoring
        dashboard.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [ValidateSet('success','failed')]
        [string]$Status,
        [string]$DeviceName     = $env:COMPUTERNAME,
        [string]$TaskSequence   = '',
        [int]$StepsCompleted    = 0,
        [int]$StepsTotal        = 0,
        [datetime]$StartTime    = (Get-Date),
        [string]$ErrorMessage   = '',
        [string]$FailedStep     = '',
        [string]$ReportPath     = '',
        [string]$ScratchDir     = '',
        [string]$GitHubUser     = '',
        [string]$GitHubRepo     = '',
        [string]$GitHubBranch   = ''
    )
    if (-not $ReportPath) {
        $safeName = ($DeviceName -replace '[\\/:*?"<>|]', '-')
        $ReportPath = Join-Path $ScratchDir "deployment-report-$safeName.json"
    }
    try {
        $duration = [math]::Round(((Get-Date) - $StartTime).TotalMilliseconds)
        $report = @{
            id             = 'dep_' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            deviceName     = $DeviceName
            taskSequence   = $TaskSequence
            status         = $Status
            duration       = $duration
            stepsTotal     = $StepsTotal
            stepsCompleted = $StepsCompleted
            startedAt      = [DateTimeOffset]::new($StartTime).ToUnixTimeMilliseconds()
            completedAt    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            error          = $ErrorMessage
            failedStep     = $FailedStep
        }
        $dir = Split-Path $ReportPath
        if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $report | ConvertTo-Json | Set-Content -Path $ReportPath -Force
        Write-Success "Deployment report saved to $ReportPath"

        # Push to GitHub so the Monitoring dashboard can read it
        $safeName = ($DeviceName -replace '[\\/:*?"<>|]', '-')
        Push-ReportToGitHub -FilePath "deployments/reports/deployment-report-$safeName.json" -Content $report `
            -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
    } catch {
        Write-Warn "Failed to save deployment report: $_"
    }
}

function Save-AssetInventory {
    <#
    .SYNOPSIS  Records hardware inventory for the deployed device.
    .DESCRIPTION
        Collects hardware details (serial, model, manufacturer, RAM, disk,
        TPM, etc.) and saves them alongside the deployment report for
        fleet tracking in the monitoring dashboard.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [string]$TaskSequence   = '',
        [string]$Edition        = '',
        [string]$Language       = '',
        [string]$ComputerName   = $env:COMPUTERNAME,
        [string]$ReportDir      = '',
        [string]$ScratchDir     = '',
        [int]$TargetDiskNumber  = 0,
        [string]$GitHubUser     = '',
        [string]$GitHubRepo     = '',
        [string]$GitHubBranch   = ''
    )

    if (-not $ReportDir) { $ReportDir = $ScratchDir }

    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $cs   = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $disk = Get-Disk -Number $TargetDiskNumber -ErrorAction SilentlyContinue

        $inventory = @{
            deviceName     = $ComputerName
            serialNumber   = if ($bios) { $bios.SerialNumber } else { '' }
            manufacturer   = if ($cs) { $cs.Manufacturer } else { '' }
            model          = if ($cs) { $cs.Model } else { '' }
            totalMemoryGB  = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { 0 }
            diskSizeGB     = if ($disk) { [math]::Round($disk.Size / 1GB, 0) } else { 0 }
            diskModel      = if ($disk) { $disk.FriendlyName } else { '' }
            processorArch  = $env:PROCESSOR_ARCHITECTURE
            taskSequence   = $TaskSequence
            windowsEdition = $Edition
            language       = $Language
            deployedAt     = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }

        $safeName = ($ComputerName -replace '[\\/:*?"<>|]', '-')
        $inventoryPath = Join-Path $ReportDir "asset-inventory-$safeName.json"
        $dir = Split-Path $inventoryPath
        if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $inventory | ConvertTo-Json | Set-Content -Path $inventoryPath -Force

        # Push to GitHub for the monitoring dashboard
        Push-ReportToGitHub -FilePath "deployments/inventory/asset-inventory-$safeName.json" -Content $inventory `
            -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch

        Write-Success "Asset inventory saved to $inventoryPath"
    } catch {
        Write-Warn "Failed to save asset inventory: $_"
    }
}

function Update-ActiveDeploymentReport {
    <#
    .SYNOPSIS  Writes or clears an active-deployment progress file.
    .DESCRIPTION
        Maintains a JSON file that mirrors the schema expected by the
        Monitoring dashboard's "Active Deployments" panel (id, deviceName,
        taskSequence, status, progress, currentStep, startedAt).

        Call with -Clear to remove the file after the deployment finishes or
        fails, signalling that the device is no longer actively deploying.
    #>
    [OutputType([void])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$DeviceName     = $env:COMPUTERNAME,
        [string]$TaskSequence   = '',
        [string]$CurrentStep    = '',
        [int]$Progress          = 0,
        [datetime]$StartTime    = (Get-Date),
        [string]$ReportPath     = '',
        [switch]$Clear,
        [string]$ScratchDir     = '',
        [string]$GitHubUser     = '',
        [string]$GitHubRepo     = '',
        [string]$GitHubBranch   = ''
    )
    if (-not $ReportPath) {
        $safeName = ($DeviceName -replace '[\\/:*?"<>|]', '-')
        $ReportPath = Join-Path $ScratchDir "active-deployment-$safeName.json"
    }
    $safeName = ($DeviceName -replace '[\\/:*?"<>|]', '-')
    $ghPath   = "deployments/active/active-deployment-$safeName.json"
    try {
        if ($Clear) {
            if (Test-Path $ReportPath) { Remove-Item $ReportPath -Force -ErrorAction SilentlyContinue }
            Push-ReportToGitHub -FilePath $ghPath -Content @{} -Delete `
                -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
            return
        }
        $report = @{
            id            = 'active_' + $DeviceName
            deviceName    = $DeviceName
            taskSequence  = $TaskSequence
            status        = 'running'
            progress      = $Progress
            currentStep   = $CurrentStep
            startedAt     = [DateTimeOffset]::new($StartTime).ToUnixTimeMilliseconds()
        }
        $dir = Split-Path $ReportPath
        if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $report | ConvertTo-Json -Compress | Set-Content -Path $ReportPath -Force -ErrorAction SilentlyContinue

        Push-ReportToGitHub -FilePath $ghPath -Content $report `
            -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
    } catch {
        Write-Warning "Active deployment report update failed: $_"
    }
}

function Send-DeploymentAlert {
    <#
    .SYNOPSIS  Sends deployment notifications via Teams, Slack, or email.
    .DESCRIPTION
        Reads config/alerts.json from the GitHub repository (or local path)
        and sends a notification for the given deployment event.  Supports
        Microsoft Teams (Incoming Webhook), Slack (Incoming Webhook), and
        email via SMTP (Send-MailMessage).

        Silently skips channels that are disabled or misconfigured so that
        a notification failure never blocks the imaging pipeline.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [ValidateSet('success','failed')]
        [string]$Status,
        [string]$DeviceName      = $env:COMPUTERNAME,
        [string]$TaskSequence    = '',
        [string]$Duration        = '',
        [int]$StepsCompleted     = 0,
        [int]$StepsTotal         = 0,
        [string]$ErrorMessage    = '',
        [string]$FailedStep      = '',
        [string]$AlertConfigPath = '',
        [string]$GitHubUser      = '',
        [string]$GitHubRepo      = '',
        [string]$GitHubBranch    = ''
    )

    # ── Resolve alert config ────────────────────────────────────────
    $cfg = $null
    try {
        if ($AlertConfigPath -and (Test-Path $AlertConfigPath)) {
            $cfg = Get-Content $AlertConfigPath -Raw | ConvertFrom-Json
        } else {
            # Try fetching from GitHub repo
            $cfgUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/alerts.json"
            $cfgJson = Invoke-RestMethod -Uri $cfgUrl -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
            $cfg = $cfgJson
        }
    } catch {
        Write-Verbose "Alert config not available -- skipping notifications: $_"
        return
    }
    if (-not $cfg) { return }

    $eventType = if ($Status -eq 'success') { 'onSuccess' } else { 'onFailure' }
    $emoji     = if ($Status -eq 'success') { '✅' } else { '❌' }
    $color     = if ($Status -eq 'success') { '2b8a3e' } else { 'e03e3e' }
    $title     = "$emoji Nova Deployment $(if ($Status -eq 'success') { 'Succeeded' } else { 'Failed' })"

    $details = "**Device:** $DeviceName`n**Task Sequence:** $TaskSequence`n**Status:** $Status`n**Steps:** $StepsCompleted/$StepsTotal"
    if ($Duration) { $details += "`n**Duration:** $Duration" }
    if ($ErrorMessage) { $details += "`n**Error:** $ErrorMessage" }
    if ($FailedStep)   { $details += "`n**Failed Step:** $FailedStep" }

    # ── Microsoft Teams ─────────────────────────────────────────────
    if ($cfg.teams -and $cfg.teams.enabled -and $cfg.teams.webhook -and $cfg.teams.$eventType) {
        try {
            $teamsBody = @{
                '@type'      = 'MessageCard'
                '@context'   = 'https://schema.org/extensions'
                themeColor   = $color
                summary      = $title
                sections     = @(@{
                    activityTitle = $title
                    text          = $details.Replace("`n", "<br>")
                    markdown      = $true
                })
            } | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri $cfg.teams.webhook -Method Post -ContentType 'application/json' -Body $teamsBody -ErrorAction Stop -TimeoutSec 15 | Out-Null
            Write-Success "Teams notification sent"
        } catch {
            Write-Warn "Teams notification failed: $_"
        }
    }

    # ── Slack ───────────────────────────────────────────────────────
    if ($cfg.slack -and $cfg.slack.enabled -and $cfg.slack.webhook -and $cfg.slack.$eventType) {
        try {
            $slackText = $details.Replace('**', '*').Replace("`n", "\n")
            $slackBody = @{
                text        = $title
                attachments = @(@{
                    color = '#' + $color
                    text  = $slackText
                })
            } | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri $cfg.slack.webhook -Method Post -ContentType 'application/json' -Body $slackBody -ErrorAction Stop -TimeoutSec 15 | Out-Null
            Write-Success "Slack notification sent"
        } catch {
            Write-Warn "Slack notification failed: $_"
        }
    }

    # ── Email (SMTP) ────────────────────────────────────────────────
    if ($cfg.email -and $cfg.email.enabled -and $cfg.email.smtp -and $cfg.email.from -and $cfg.email.to -and $cfg.email.$eventType) {
        try {
            $toList  = ($cfg.email.to -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            $subject = $title
            $body    = $details.Replace('**', '').Replace("`n", "`r`n")
            $port    = if ($cfg.email.port) { $cfg.email.port } else { 587 }
            # Note: Send-MailMessage is considered obsolete in newer PowerShell
            # versions.  For production use, consider MailKit or a direct
            # System.Net.Mail.SmtpClient implementation instead.
            Send-MailMessage -From $cfg.email.from -To $toList -Subject $subject -Body $body `
                -SmtpServer $cfg.email.smtp -Port $port -UseSsl -ErrorAction Stop
            Write-Success "Email notification sent"
        } catch {
            Write-Warn "Email notification failed: $_"
        }
    }
}

function Export-DeploymentLogs {
    <#
    .SYNOPSIS  Copies WinPE deployment logs to the target OS drive before reboot.
    .DESCRIPTION
        WinPE runs in RAM -- all logs are lost on reboot unless explicitly copied.
        This function copies Nova's log files from X:\ to the target OS drive so
        they survive the reboot and are available for troubleshooting.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Exports multiple log files as a batch operation')]
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [string]$OSDriveLetter,
        [string]$EngineLogPath = ''
    )

    $logDir = "${OSDriveLetter}:\Nova\Logs"
    try {
        $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
        $logFiles = @(
            'X:\Nova-Bootstrap.log',
            'X:\Nova-Engine.log',
            'X:\Nova-Auth.log',
            'X:\Nova-Status.json'
        )
        foreach ($src in $logFiles) {
            if (Test-Path $src) {
                $dest = Join-Path $logDir (Split-Path $src -Leaf)
                Copy-Item $src $dest -Force -ErrorAction SilentlyContinue
                Write-Verbose "Copied $src -> $dest"
            }
        }
        # Also copy the transcript if it's still running
        try { Stop-Transcript -ErrorAction SilentlyContinue } catch { $null = $_ }
        if ($EngineLogPath -and (Test-Path $EngineLogPath)) {
            Copy-Item $EngineLogPath (Join-Path $logDir 'Nova-Engine.log') -Force -ErrorAction SilentlyContinue
        }
        Write-Success "Deployment logs exported to $logDir"
    } catch {
        Write-Warn "Log export failed (non-fatal): $_"
    }
}

# ── Module Exports ─────────────────────────────────────────────────────────────
Export-ModuleMember -Function @(
    'Save-DeploymentReport'
    'Save-AssetInventory'
    'Update-ActiveDeploymentReport'
    'Send-DeploymentAlert'
    'Get-GitHubTokenViaEntra'
    'Push-ReportToGitHub'
    'Export-DeploymentLogs'
)

# SIG # Begin signature block
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAOYoUxK5uF5ZPq
# OYFu5pO/vsoIc1S8AyU6LfEzA674kaCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# BgkqhkiG9w0BCQQxIgQg1ubYZEO6EQWuLMC2A0LvyPu2C+1M6XwirDIToTJIWEIw
# DQYJKoZIhvcNAQEBBQAEggGAQyy6HngtU+/Q+a/vhjJAjaFxb7jNUk6J74oYaFtQ
# g9Rhv3yzAJkcYA8+7oET6qd6l6ClngcdPOWIlKDwLwKftSZ+t+Hz6Mq1fnH+tHan
# u6sS2Y1g1VJ7x7o6rtogvd/Jaap3Jvqfm39JcjUwmVxQVuqBPfMejmJQE1TwdXIS
# sMfyJSnc6tj2J/Y0I5fZY2E6vSWq9244aN1CR2bT13t4rBVB70/rY2N90ssoVfwz
# MUtCIa4tx+duCbju6a9tZE6bSgFqGHZblVnL7EEpuxkG7HGy8Ub2qId0TcC0lbca
# zKcRtgFZLL/ZnJMPHLhQrLhB1OmVorvYWOXUTURrhgpMAz2U3+3zLzZ9lhOAzYA5
# 5vpRDxnjhJ/5ZcFhlMggbnQX6BMEdCPYHUc6a8i5IPrytyMsyyPzKu3xbnD5FyYx
# q9N8sySP1WcYtHyeMOMhBj12Vx4iJMNOQ2gXgwM0N3AKEDTQDHNQWRD3s3eEyZVS
# q1qzUIAmqG0illoGTu2EuyrpoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIIK+GOVDJiJXRTFo67Cz0v3cftQKe5Verkz7ED+vawIcAgZpwnLO8mYYEzIw
# MjYwNDA5MTIxNTAzLjg3MVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
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
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDA5MTIxNTAzWjAvBgkqhkiG9w0B
# CQQxIgQgq350WgqmRaDBxK6hR/gTG2oedRsJ94EesILLW0unm1UwgbkGCyqGSIb3
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
# AQUABIICAFBK3M6VUQjM6Owp9MqXVIPF8sjWpjhTd56ZKY8H50jaef7MNDxgBA2s
# +v4w6MQn84ELlYauQ+876NOEbjAPe+YpQLP76m7jZj3Rhg6pghk0vUprNoo+kVfW
# A08TpDNgjBmdB6hy99ooekGoqDSITZlHMr7ez6TqxZ9LdSt9iLgtirIj9cxFSrcp
# NWIK9wayTZzKSEgesjh/Do7YkXPcACyM3kKh5i2WXEJJL/5GzX5gaLXOGdwZ0Nao
# fcgVQvlFvhR3kljXggoYytTzntQhYV82bohZLoLWHP+ULREWlPKIW071b/elbl9r
# 1Mzi8eBVgIWxB/mWiLOEBPTCugGs1fTTSfo3L5DTD9Z7uRh6iUJg/UIoYZST5hYH
# ULCLArQsoI3tWpqD7AOm84nrhTNuLpTWI7r+fo92FySyvZVQBUo1cTfopUgOAd9K
# dW6b0BPmU5TZwBKRiJfanXSafc/OgRr3R3jew80WgvNKhBfizJbe9CSqAAH1Mbf5
# fGNAZa4loU4mUpTY0yx6zzIIcgVr4zePvjNJ5jC1ccDowLNxxMaF2OfvtzG7skKX
# lMc0dYd9ohh8F1S7hrfdCZUZFC0xj3+0rfJio1Ygy19J32Wq8Lj2a7FXostSRVl8
# aU4bzdyam5871UVgyWFuclNpPeBdnyiDGTIvTMFTm+Ihx6vYqgMy
# SIG # End signature block

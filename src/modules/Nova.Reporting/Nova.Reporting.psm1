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
            'X:\Nova-Detailed.log',
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
# MII9dAYJKoZIhvcNAQcCoII9ZTCCPWECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBwQ7NfpkeD+25V
# oBWYCUJGn8byibnnpr/r4tJhQNIykKCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# rmcxghqSMIIajgIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBBT0MgQ0EgMDQCEzMAAAsliaF5N+X1X2YAAAAACyUwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgkwEWlAtB9wYacIrD6I5qSZg1eUSaskmyn/Lu4E4zxjcw
# DQYJKoZIhvcNAQEBBQAEggGAO5k8Q9lqoZhTFY2JBvJaUPS/gUi+nvHIkXLv3wI9
# 0Q57IA3CjLhOmpzo/jLghj/nZiQDjfip+4HZfpV1d881MpOa3CJNsBSSrf6GNqbe
# m+LsQZX67IW+nAm7UbMhPunSXxTZT3sGuaSeZhOHaRuUkWVVMdVtcyTKHGFXlty2
# ubq/1dnH06lsan1MQsap9/xI27KlEhACW/jel1nEtgUaqpxzfKEO/eJcN+j1tzu6
# bMAc4Tx41S7NTJKIo5stLdYVDxTyt+nKTdPXWBhHF2bZnOfFrD/9huUph4dRl8JC
# oyp9XNB+fbezCRuEk/dohERa9QpBeK8YS51KvATEJ4TUxzGYerKtHEt1U+yPkGXB
# ADPL+fBOnlgNIrT8Nmqb4nLTDurMvJCDuAZjo06eCRi3on6X1aeQYhInBOjqMOWS
# vEJHjkTKLBtKccB9ws2TW9trj7jVGJobuCt2wVyIe4l7sG0PHg5u+GdP2peBMSbe
# Q7BoQYbBhvslLu7RWc2HFEFSoYIYEjCCGA4GCisGAQQBgjcDAwExghf+MIIX+gYJ
# KoZIhvcNAQcCoIIX6zCCF+cCAQMxDzANBglghkgBZQMEAgEFADCCAWAGCyqGSIb3
# DQEJEAEEoIIBTwSCAUswggFHAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEICEHeJe4i8jzKZLwFbb38QTGZUZPoeT9/SEglD+xXvlNAgZp1AaEOyoYETIw
# MjYwNDExMTAwNDMzLjVaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5
# NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcg
# QXV0aG9yaXR5oIIPITCCB4IwggVqoAMCAQICEzMAAAAF5c8P/2YuyYcAAAAAAAUw
# DQYJKoZIhvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlm
# aWNhdGlvbiBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIwMTEx
# OTIwMzIzMVoXDTM1MTExOTIwNDIzMVowYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1Ymxp
# YyBSU0EgVGltZXN0YW1waW5nIENBIDIwMjAwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQCefOdSY/3gxZ8FfWO1BiKjHB7X55cz0RMFvWVGR3eRwV1wb3+y
# q0OXDEqhUhxqoNv6iYWKjkMcLhEFxvJAeNcLAyT+XdM5i2CgGPGcb95WJLiw7HzL
# iBKrxmDj1EQB/mG5eEiRBEp7dDGzxKCnTYocDOcRr9KxqHydajmEkzXHOeRGwU+7
# qt8Md5l4bVZrXAhK+WSk5CihNQsWbzT1nRliVDwunuLkX1hyIWXIArCfrKM3+RHh
# +Sq5RZ8aYyik2r8HxT+l2hmRllBvE2Wok6IEaAJanHr24qoqFM9WLeBUSudz+qL5
# 1HwDYyIDPSQ3SeHtKog0ZubDk4hELQSxnfVYXdTGncaBnB60QrEuazvcob9n4yR6
# 5pUNBCF5qeA4QwYnilBkfnmeAjRN3LVuLr0g0FXkqfYdUmj1fFFhH8k8YBozrEaX
# nsSL3kdTD01X+4LfIWOuFzTzuoslBrBILfHNj8RfOxPgjuwNvE6YzauXi4orp4Sm
# 6tF245DaFOSYbWFK5ZgG6cUY2/bUq3g3bQAqZt65KcaewEJ3ZyNEobv35Nf6xN6F
# rA6jF9447+NHvCjeWLCQZ3M8lgeCcnnhTFtyQX3XgCoc6IRXvFOcPVrr3D9RPHCM
# S6Ckg8wggTrtIVnY8yjbvGOUsAdZbeXUIQAWMs0d3cRDv09SvwVRd61evQIDAQAB
# o4ICGzCCAhcwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1Ud
# DgQWBBRraSg6NS9IY0DPe9ivSek+2T3bITBUBgNVHSAETTBLMEkGBFUdIAAwQTA/
# BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2Nz
# L1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcU
# AgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7S
# aoUqG8oZmAQHJ89QEE9oqKIwgYQGA1UdHwR9MHsweaB3oHWGc2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElkZW50aXR5JTIw
# VmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIw
# MjAyMC5jcmwwgZQGCCsGAQUFBwEBBIGHMIGEMIGBBggrBgEFBQcwAoZ1aHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVu
# dGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhv
# cml0eSUyMDIwMjAuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBfiHbHfm21WhV150x4
# aPpO4dhEmSUVpbixNDmv6TvuIHv1xIs174bNGO/ilWMm+Jx5boAXrJxagRhHQtiF
# prSjMktTliL4sKZyt2i+SXncM23gRezzsoOiBhv14YSd1Klnlkzvgs29XNjT+c8h
# IfPRe9rvVCMPiH7zPZcw5nNjthDQ+zD563I1nUJ6y59TbXWsuyUsqw7wXZoGzZwi
# jWT5oc6GvD3HDokJY401uhnj3ubBhbkR83RbfMvmzdp3he2bvIUztSOuFzRqrLfE
# vsPkVHYnvH1wtYyrt5vShiKheGpXa2AWpsod4OJyT4/y0dggWi8g/tgbhmQlZqDU
# f3UqUQsZaLdIu/XSjgoZqDjamzCPJtOLi2hBwL+KsCh0Nbwc21f5xvPSwym0Ukr4
# o5sCcMUcSy6TEP7uMV8RX0eH/4JLEpGyae6Ki8JYg5v4fsNGif1OXHJ2IWG+7zyj
# TDfkmQ1snFOTgyEX8qBpefQbF0fx6URrYiarjmBprwP6ZObwtZXJ23jK3Fg/9uqM
# 3j0P01nzVygTppBabzxPAh/hHhhls6kwo3QLJ6No803jUsZcd4JQxiYHHc+Q/wAM
# cPUnYKv/q2O444LO1+n6j01z5mggCSlRwD9faBIySAcA9S8h22hIAcRQqIGEjolC
# K9F6nK9ZyX4lhthsGHumaABdWzCCB5cwggV/oAMCAQICEzMAAABXJNOV4KLpyTEA
# AAAAAFcwDQYJKoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBS
# U0EgVGltZXN0YW1waW5nIENBIDIwMjAwHhcNMjUxMDIzMjA0NjUzWhcNMjYxMDIy
# MjA0NjUzWjCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEl
# MCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMe
# blNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3Nv
# ZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBALFspQqTCH24syS2NZD1ztnJl9h0Vr0WwJni
# kmeXse/4wspnVexGqfiHNoqkbVg5CinuYC+iVfNMLZ+QtqhySz8VGBSjRt1JB5AC
# NtTKAjfmFp4U/Cv2Lj4m+vuve9I3W3hSiImTFsHeYZ6V/Sd43rXrhHV26fw3xQSt
# eSbg9yTs1rhdrLkAj4KmI0D5P4KavtygirVyUW10gkifWLSE1NiB8Jn3RO5dj32d
# eeMNONaaPnw3k49ICTs3Ffyb+ekNDPsNfYwCqPyOTxM6y1dSD0J5j+KK9V+EWyV5
# PDjV8jjn1zsStlS6TcYJJStcgHs2xT9rs6ooWl5FtYfRkCxhDShEp3s8IHUWizTW
# mLZvAE/6WR2Cd+ZmVapGXTCHJKUByZPxdX0i8gynirR+EwuHHNxEilDICLatO2WZ
# u+CQrH4Zq0NYo1TQ4tUpZ/kAWpoAu1r4mW5EJ3HkEavQ2PuoQDcDq2rAGVIla9pD
# 7o9Yxwzl81BuDvUEyu9D/6F0qmQDdaE791HxfCUxpgMYPpdWTzs+dDGPehwQ8P92
# yP8ARjby5Ony1Z68RjeQebpxf5WL441myFHcgT1UJzzil7tPEkR22NfTNR6Fl+jz
# Wb/r80nqlXllhynSowtxo1Y22xqYviS24smikUsBKqOPbSS77uvXEO3VrG5LGouE
# 1EZ1Y9pjAgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQUjoPJXi01DgIJSGfm416Yg+0S
# kqcwHwYDVR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBh
# oF+gXYZbaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9z
# b2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNy
# bDB5BggrBgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIw
# VGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1Ud
# JQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEG
# DCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqG
# SIb3DQEBDAUAA4ICAQBydcB2POmZOUlAQz2NuXf7vWCVWmjWu9bsY1+HMjv1yeLj
# xDQkjsJEU5zaIDy8Uw9BYN8+ExX/9k/9CBUsXbVlbU44c65/liyJ83kWsFIUwhVa
# zwSShFlbIZviIO/5weyWyTfPPpbSJgWy+ZE9UrQS3xulJLAHA2zUkMMPdAlF4Rrn
# gcZZ0r45AF9aIYjdestWwdrNK70MfArHqZdgrgXn03w6zBs1v7czceWGitg/DlsH
# qk1mXBpSTuGI2TSPN3E60IIXx5f/AFzh4/HFi98BBZbUELNsXkWAG9ynZ5e6CFii
# l1mgWCWOT90D7Igvg0zKe3o3WCk629/en94K/sC/zLOf2d7yFmTySb9fKjcONH1D
# b3kZ8MzEJ8fHTNmxrl10Gecuz/Gl0+ByTKN+PambZ+F0MIlBPww6fvjFC9JII73f
# w3qO169+9TxTz2G+E26GYY1dcffsAhw6DqTQgbflbl1O/MrSXSs0NSb9nBD9RfR/
# f8Ei7DA1L1jBO7vZhhJTjw2TzFa/ALgRLi3W00hHWi8LGQaZc8SwXIMYWfwrN9Mg
# YbhN0Iak9WA2dqWuekXsTwNkmrD3E6E+oCYCehNOgZmds0Ezb1jo7OV0Kh22Ll3K
# Hg3MHtlGguxAzhg/BpixPS4qrULLkAjO7+yNsUfrD2U9gMf/OR4yJDPtzM0ytTGC
# B0YwggdCAgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0
# YW1waW5nIENBIDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwDQYJYIZIAWUDBAIB
# BQCgggSfMBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MDQxMTEwMDQzM1owLwYJKoZIhvcNAQkE
# MSIEINXAI2eel+3dLKXjFEsiUUU9LVJAXsUJDA2AKwxb2tJXMIG5BgsqhkiG9w0B
# CRACLzGBqTCBpjCBozCBoAQg9TyfZLUFbkxliGyizuH9VVDpVFNvQEQhKQ2ZhUx4
# 21IwfDBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1w
# aW5nIENBIDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwggNhBgsqhkiG9w0BCRAC
# EjGCA1AwggNMoYIDSDCCA0QwggIsAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFt
# ZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAt
# MDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0
# YW1waW5nIEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUA/S8xOZxCUQFBNkrN8Wii
# j1x5y8OgZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0
# YW1waW5nIENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDthHO8MCIYDzIwMjYwNDEx
# MDcxNjEyWhgPMjAyNjA0MTIwNzE2MTJaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIF
# AO2Ec7wCAQAwCgIBAAICEmkCAf8wBwIBAAICEmkwCgIFAO2FxTwCAQAwNgYKKwYB
# BAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGG
# oDANBgkqhkiG9w0BAQsFAAOCAQEAlIu1WemZt2+17Du+8S1bV9b5lEeRWr38MIeM
# 12zBaU459j1lD8OC/ZLL/zTzWxoRsQlsmiELu0z2tpsRGMXBJK/q3yv5eyN7PM/D
# Ac5o0JMeaKxaJNmu8IWKa+V72hhPgwqet8MUtSSOmzQgL7DOWo2+vTmFDRwIb4+8
# 8GMmzo0zNhmUSyf4tXRMnHSo2oweNKut9Z9zSWZMPNUjYx6is+iZqVRIRzhdEm/Y
# KX4iJF3VHQX6QOwR5r4fVKqqjTki/7X2Kqwwqs7iYBgBflfk1g23AcyB4ylm+rOZ
# CNIA7QPW5A7CPulWEjKVyrLwsrEJ/vNaaj2rhjKLW0AYOFb8XzANBgkqhkiG9w0B
# AQEFAASCAgB9v4subAEeIkGAlff9y6T008Gdgu+v6s3tf0dT5jP82SffGuoSXf/R
# 2N52hgao9mn0ygG7lGaS6hJXphfj8qmSQ1Lx2LDoSH1YrrngrwtA91WDat/BFlZv
# /jALHdVhdItnsADTlceX/YWBEQqwlJvR+7kWQE4m3Xar7VtNqzX5rsMfNvflN4rG
# Mv+8wkwiG6Dg6YMvDXeZW2/f/pFmpzu+sW8QlGvW5XRP6n01p3yw5NKmN6/xtKnF
# sIrJT6CIrK+a2Sbr7HiSzQnwEmj18TUT9XpeRYlYUrRZ1iy8XEYYLydAoSPgUPZZ
# 8bNxidW79tc4IqCCxaKJYE6EGPxTR0bZ6wbWad4xmfP0GS/1VFFF7QwBawbHTYB6
# fYCvhg+bN5ELGmW0sLoOlR7f1iSJpGGmvhxQ6Z9z45VJIkhHo5GpIENm45peViMX
# chKxUrkL4PLdq5ta9MixMWpAcZ4d4VMgw/02cduh42UJeTs60XMyGMmGTb4FSzyg
# p7kbdS5wPPHjfbIe7022njPAWul2+LIaChDc5z2KMdYIYptKPKkWsVYRkW+N9GrX
# TfweAauG9ApiZdk9Qp6VIypAn8znjB9E7efnTZ1ooXnnG8CzxzN2XyfFdlp6LGnI
# mRNzAbiqT4cVE/7EmyRsfndXTVldBhg4D0tL2wyaCeQt7ckyF9q5ng==
# SIG # End signature block

<#
.SYNOPSIS
    Deployment reporting, alerting, and log export module for Nova.

.DESCRIPTION
    Provides functions for saving deployment reports, asset inventory,
    sending deployment alerts (Teams, Slack, email), pushing reports to
    GitHub, and exporting WinPE logs to the target OS drive.
#>

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
            $body   = $reader.ReadToEnd()
            $reader.Close()
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

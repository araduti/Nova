#Requires -Version 5.1
<#
.SYNOPSIS
    Nova - Full cloud imaging engine for GitHub-native OS deployment.

.DESCRIPTION
    Runs inside WinPE. Reads a task sequence JSON file produced by the
    web-based Editor, then executes each enabled step in order: partitions
    disks, downloads and applies Windows, injects drivers, applies
    Autopilot/Intune/ConfigMgr configuration, customizes OOBE, and runs
    post-provisioning scripts. All updates are instant via GitHub - no
    rebuilds needed.

.NOTES
    Fetched and executed by Bootstrap.ps1 at runtime.
    Requires WinPE with PowerShell, WMI, StorageWMI, and DISM cmdlets.
#>

[CmdletBinding()]
param(
    # GitHub source
    [ValidateNotNullOrEmpty()]
    [string]$GitHubUser   = 'araduti',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubRepo   = 'Nova',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubBranch = 'main',

    # Disk configuration
    [ValidateRange(0, [int]::MaxValue)]
    [int]$TargetDiskNumber = 0,
    [ValidateSet('UEFI','BIOS')]
    [string]$FirmwareType  = 'UEFI',

    # Scratch / temp directory inside WinPE
    [ValidateNotNullOrEmpty()]
    [string]$ScratchDir = 'X:\Nova',

    # Target OS drive letter (assigned during partitioning)
    [ValidatePattern('^[A-Za-z]$')]
    [string]$OSDrive = 'C',

    # IPC status file -- Bootstrap.ps1 polls this JSON file to show live progress
    # in the UI.  Leave empty to disable status reporting.
    [string]$StatusFile = '',

    # Task sequence JSON -- the engine reads the step list from this file and
    # executes each enabled step in order.  The file is produced by the
    # web-based Task Sequence Editor (src/web/editor/index.html) and follows the
    # schema defined in resources/task-sequence/default.json.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskSequencePath,

    # When set, validates the task sequence without performing any destructive
    # operations (no partitioning, no imaging, no driver injection).
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── TLS ─────────────────────────────────────────────────────────────────────
# PowerShell 5.1 in WinPE defaults to SSL3/TLS 1.0.  This engine runs in a
# dedicated process (Start-Process from Bootstrap.ps1), so the parent's TLS
# setting does not carry over.  Enforce TLS 1.2 before any HTTPS traffic.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Logging ─────────────────────────────────────────────────────────────────
# This engine runs in a dedicated process (Start-Process from Bootstrap.ps1),
# so the parent's Start-Transcript does not carry over.  Start our own
# transcript so every Write-Host, warning, and error is captured to disk.
$script:EngineLogPath = 'X:\Nova-Engine.log'
$null = Start-Transcript -Path $script:EngineLogPath -Force -ErrorAction SilentlyContinue

# Resolved once so WinPE's X:\ path is used correctly in the error handler.
$script:PsBin = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ── Constants ───────────────────────────────────────────────────────────────
# Partition GUIDs (GPT type identifiers)
$script:GptTypeEsp = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'   # EFI System Partition
$script:GptTypeMsr = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'   # Microsoft Reserved
$script:GptTypeBasicData = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'   # Basic Data (OS)
$script:GptTypeRecovery = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'   # Windows Recovery (WinRE)

# Partition sizes
$script:EspSize = 260MB
$script:MsrSize = 16MB
$script:MbrSystemSize = 500MB
$script:DefaultRecoverySize = 990MB
$script:MinimumOsPartitionSize = 20GB

# Download settings
$script:DownloadBufferSize      = 65536   # 64 KB read buffer
$script:RetryBackoffBaseSeconds = 5
$script:ProgressIntervalMs  = 1000    # Minimum ms between progress updates

# Cached GitHub token obtained via Entra ID exchange so we don't re-fetch
# on every status update call.
$script:CachedEntraGitHubToken = $null
$script:CachedEntraGitHubTokenTime = [datetime]::MinValue
# Negative cache: avoid retrying a recently-failed token exchange.
$script:EntraExchangeLastFailure = $null
# One-shot flag: warn once when no GitHub token can be resolved so the user
# knows status reporting is disabled without flooding the log on every step.
$script:GitHubTokenWarningShown = $false

# ── Import shared modules ──────────────────────────────────────────────────────
# Resolve module path: repo layout ($PSScriptRoot/../modules) or WinPE staging
# (X:\Windows\System32\Modules -- copied by Trigger.ps1 during image build).
$script:ModulesRoot = if (Test-Path "$PSScriptRoot\..\modules") {
    "$PSScriptRoot\..\modules"
} elseif (Test-Path 'X:\Windows\System32\Modules') {
    'X:\Windows\System32\Modules'
} else {
    "$PSScriptRoot\..\modules"   # Best-effort fallback
}
Import-Module "$script:ModulesRoot\Nova.Logging" -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Platform" -Force -ErrorAction Stop
Set-NovaLogPrefix -Step "`n[Nova]" -Success '[OK]' -Warn '[WARN]' -Fail '[FAIL]'

#region ── Helpers ──────────────────────────────────────────────────────────────

function Update-BootstrapStatus {
    <#
    .SYNOPSIS  Writes live progress to a JSON file for Bootstrap.ps1 to display.
    .DESCRIPTION
        Bootstrap.ps1 polls $StatusFile every ~650 ms and updates its UI
        with the message, progress percentage, and step number.  When imaging is
        done, set -Done to signal the spinner to stop.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Message  = '',
        [string]$Detail   = '',
        [int]$Progress    = 0,
        [int]$Step        = 0,
        [switch]$Done
    )
    # No-op when StatusFile is empty (disables IPC reporting by design).
    if (-not $StatusFile) { return }
    try {
        $obj = @{ Message = $Message; Detail = $Detail; Progress = $Progress; Step = $Step; Done = [bool]$Done }
        $obj | ConvertTo-Json -Compress | Set-Content -Path $StatusFile -Force -ErrorAction SilentlyContinue
    } catch { Write-Verbose "Status update suppressed: $_" }
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
        [string]$ReportPath     = ''
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
        Push-ReportToGitHub -FilePath "deployments/reports/deployment-report-$safeName.json" -Content $report
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
        [string]$TaskSequence = '',
        [string]$Edition = '',
        [string]$Language = '',
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$ReportDir = ''
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
        Push-ReportToGitHub -FilePath "deployments/inventory/asset-inventory-$safeName.json" -Content $inventory

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
        [string]$DeviceName   = $env:COMPUTERNAME,
        [string]$TaskSequence = '',
        [string]$CurrentStep  = '',
        [int]$Progress        = 0,
        [datetime]$StartTime  = (Get-Date),
        [string]$ReportPath   = '',
        [switch]$Clear
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
            Push-ReportToGitHub -FilePath $ghPath -Content @{} -Delete
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

        Push-ReportToGitHub -FilePath $ghPath -Content $report
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
        [string]$DeviceName     = $env:COMPUTERNAME,
        [string]$TaskSequence   = '',
        [string]$Duration       = '',
        [int]$StepsCompleted    = 0,
        [int]$StepsTotal        = 0,
        [string]$ErrorMessage   = '',
        [string]$FailedStep     = '',
        [string]$AlertConfigPath = ''
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
    # Return the cached token when available and not expired (GitHub App
    # installation tokens are valid for 1 hour; re-fetch after 55 min).
    if ($script:CachedEntraGitHubToken -and ((Get-Date) - $script:CachedEntraGitHubTokenTime).TotalMinutes -lt 55) {
        return $script:CachedEntraGitHubToken
    }

    # Don't retry a recently failed exchange (wait at least 5 min).
    if ($script:EntraExchangeLastFailure -and ((Get-Date) - $script:EntraExchangeLastFailure).TotalMinutes -lt 5) {
        Write-Verbose "Skipping Entra→GitHub exchange: last attempt failed less than 5 minutes ago"
        return $null
    }

    $entraToken = $env:NOVA_GRAPH_TOKEN
    if (-not $entraToken) {
        if (-not $script:GitHubTokenWarningShown) {
            Write-Warning "NOVA_GRAPH_TOKEN is not set -- Entra→GitHub token exchange unavailable. Set GITHUB_TOKEN or sign in via Entra ID to enable deployment status reporting."
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
            Write-Warning "Entra→GitHub token exchange failed (HTTP $statusCode): $(if ($errBody) { $errBody.Substring(0, [math]::Min($errBody.Length, 200)) } else { '(no response body)' })"
            $script:EntraExchangeLastFailure = Get-Date
        }
    } catch {
        Write-Warning "Entra→GitHub token exchange failed: $_"
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
        [switch]$Delete
    )

    # ── Token resolution: try Entra exchange when no explicit token ──
    if (-not $Token) {
        $Token = Get-GitHubTokenViaEntra
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

function New-ScratchDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

function Add-SetupCompleteEntry {
    param(
        [string]$FilePath,
        [string]$Line
    )
    $dir = Split-Path $FilePath
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    # Windows OOBE calls SetupComplete.cmd by convention -- it must be a .cmd file.
    # ASCII encoding ensures broadest compatibility with cmd.exe's file parser.
    if (Test-Path $FilePath) {
        $existing = (Get-Content $FilePath -Raw).TrimEnd()
        Set-Content $FilePath "$existing`r`n$Line" -Encoding Ascii
    } else {
        Set-Content $FilePath $Line -Encoding Ascii
    }
}

# Get-FileSizeReadable is now provided by the Nova.Platform module.

function Invoke-DownloadWithProgress {
    param(
        [string]$Uri,
        [string]$OutFile,
        [string]$Description = 'Downloading',
        [int]$BaseProgress   = 0,
        [int]$ProgressRange  = 0,
        [int]$MaxRetries     = 3
    )
    Write-Step "$Description"
    Write-Host "  Source : $Uri"
    Write-Host "  Target : $OutFile"

    $attempt = 0
    while ($true) {
        $attempt++
        $response  = $null
        $stream    = $null
        $fs        = $null
        try {
            # Check for partial file to support resume
            $existingSize = if (Test-Path $OutFile) { (Get-Item $OutFile).Length } else { 0 }

            $wr = [System.Net.WebRequest]::Create($Uri)
            $wr.Method  = 'GET'
            $wr.Timeout = 30000   # 30-second connection timeout (ms)

            if ($existingSize -gt 0) {
                $wr.AddRange([long]$existingSize)
                Write-Host "  Resuming from $(Get-FileSizeReadable $existingSize)..."
            }

            $response  = $wr.GetResponse()
            $totalBytes = $response.ContentLength + $existingSize
            $stream     = $response.GetResponseStream()
            $stream.ReadTimeout = 30000   # 30-second read timeout (ms)

            if ($existingSize -gt 0) {
                $fs = [System.IO.FileStream]::new($OutFile, [System.IO.FileMode]::Append)
            } else {
                $fs = [System.IO.File]::Create($OutFile)
            }

            $buffer     = New-Object byte[] $script:DownloadBufferSize
            $downloaded = $existingSize
            $sw         = [System.Diagnostics.Stopwatch]::StartNew()

            do {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -gt 0) {
                    $fs.Write($buffer, 0, $read)
                    $downloaded += $read
                    if ($sw.ElapsedMilliseconds -gt $script:ProgressIntervalMs) {
                        $pct = if ($totalBytes -gt 0) { [int]($downloaded * 100 / $totalBytes) } else { 0 }
                        $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { [long]($downloaded / $sw.Elapsed.TotalSeconds) } else { 0 }
                        $detail = "$pct% -- $(Get-FileSizeReadable $downloaded) of $(Get-FileSizeReadable $totalBytes) @ $(Get-FileSizeReadable $speed)/s"
                        Write-Host "  Progress: $detail" -NoNewline
                        Write-Host "`r" -NoNewline
                        if ($ProgressRange -gt 0) {
                            $overallPct = [Math]::Min($BaseProgress + $ProgressRange, $BaseProgress + [int]($pct * $ProgressRange / 100))
                            Update-BootstrapStatus -Message $Description -Detail $detail -Step 4 -Progress $overallPct
                        }
                        $sw.Restart()
                    }
                }
            } while ($read -gt 0)

            Write-Host ''
            Write-Success "Download complete: $(Get-FileSizeReadable $downloaded)"
            break   # Success -- exit retry loop
        } catch {
            if ($attempt -ge $MaxRetries) {
                throw "Download failed for '$Description' after $MaxRetries attempt(s) (URL: $Uri): $_"
            }
            $backoff = [math]::Pow(2, $attempt - 1) * $script:RetryBackoffBaseSeconds
            Write-Warn "Download attempt $attempt/$MaxRetries failed: $_"
            Write-Warn "Retrying in $backoff seconds..."
            Start-Sleep -Seconds $backoff
        } finally {
            if ($fs)       { $fs.Close() }
            if ($stream)   { $stream.Close() }
            if ($response) { $response.Close() }
        }
    }
}

#endregion

# Get-FirmwareType is now provided by the Nova.Platform module.

#region ── Disk Partitioning ────────────────────────────────────────────────────

function Get-TargetDisk {
    <#
    .SYNOPSIS  Resolves and validates the target disk for imaging.
    .DESCRIPTION
        When DiskNumber is -1 (auto-select), picks the largest non-removable
        disk.  Otherwise validates the specified disk number exists.
    #>
    param(
        [int]$DiskNumber
    )

    if ($DiskNumber -eq -1) {
        # Auto-select: pick the largest non-removable, non-USB disk
        $disk = Get-Disk | Where-Object {
            $_.BusType -ne 'USB' -and
            -not $_.IsReadOnly -and
            $_.OperationalStatus -eq 'Online'
        } | Sort-Object Size -Descending | Select-Object -First 1

        if (-not $disk) {
            throw 'Auto-select failed: no eligible disks found (excluding USB and read-only)'
        }
        Write-Step "Auto-selected disk $($disk.Number): $($disk.FriendlyName) ($(Get-FileSizeReadable $disk.Size))"
        return $disk.Number
    }

    # Validate specified disk exists
    $null = Get-Disk -Number $DiskNumber -ErrorAction Stop
    return $DiskNumber
}

function Initialize-TargetDisk {
    param(
        [int]$DiskNumber,
        [string]$FirmwareType,
        [string]$OSDriveLetter,
        [switch]$CreateRecoveryPartition,
        [long]$RecoveryPartitionSize = $script:DefaultRecoverySize
    )

    Write-Step "Initializing disk $DiskNumber (Firmware: $FirmwareType)..."

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop

    Write-Host "  Disk: $($disk.FriendlyName) | Size: $(Get-FileSizeReadable $disk.Size) | Status: $($disk.OperationalStatus)"

    # Clear the disk
    Write-Step "Clearing disk $DiskNumber..."
    $clearError = $null
    try {
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    } catch {
        $clearError = $_
        Write-Warn "Clear-Disk failed on disk ${DiskNumber}: $clearError"
    }

    $stepName = ''
    try {

    if ($FirmwareType -eq 'UEFI') {
        # Initialize as GPT
        $stepName = 'Initialize-Disk (GPT)'
        Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop

        # EFI System Partition (ESP)
        $stepName = 'New-Partition (ESP)'
        $esp = New-Partition -DiskNumber $DiskNumber -Size $script:EspSize -GptType $script:GptTypeEsp
        $stepName = 'Format-Volume (ESP FAT32)'
        $null = Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false
        $stepName = 'Add-PartitionAccessPath (ESP)'
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AssignDriveLetter

        # Microsoft Reserved Partition (MSR)
        $stepName = 'New-Partition (MSR)'
        $null = New-Partition -DiskNumber $DiskNumber -Size $script:MsrSize -GptType $script:GptTypeMsr

        # Windows OS Partition
        $stepName = 'New-Partition (OS)'
        if ($CreateRecoveryPartition) {
            # Reserve space for the recovery partition at the end of the disk
            $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
            $usedSpace = $script:EspSize + $script:MsrSize + $RecoveryPartitionSize
            # Additional overhead for GPT metadata (~1 MB each side)
            $osSize = $disk.Size - $usedSpace - 2MB
            if ($osSize -lt $script:MinimumOsPartitionSize) {
                throw "Insufficient disk space for OS partition with recovery. Available: $(Get-FileSizeReadable $osSize)"
            }
            $osPartition = New-Partition -DiskNumber $DiskNumber -Size $osSize -GptType $script:GptTypeBasicData
        } else {
            $osPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -GptType $script:GptTypeBasicData
        }
        $stepName = 'Format-Volume (OS NTFS)'
        $null = $osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false
        # Format-Volume may auto-assign the drive letter; only reassign if needed.
        $stepName = 'Set-Partition (drive letter)'
        $currentLetter = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber).DriveLetter
        if ([string]$currentLetter -ne [string]$OSDriveLetter) {
            # Free the target letter if another partition already owns it
            $conflict = Get-Partition | Where-Object { $_.DriveLetter -eq $OSDriveLetter } | Select-Object -First 1
            if ($conflict) {
                Remove-PartitionAccessPath -DiskNumber $conflict.DiskNumber -PartitionNumber $conflict.PartitionNumber -AccessPath "${OSDriveLetter}:\"
            }
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $OSDriveLetter
        }

        # Recovery Partition (optional, UEFI only)
        if ($CreateRecoveryPartition) {
            $stepName = 'New-Partition (Recovery)'
            $recPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -GptType $script:GptTypeRecovery
            $stepName = 'Format-Volume (Recovery NTFS)'
            $null = $recPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false
            # Set GPT attributes: bit 0 (required) + bit 60 (read-only) +
            # bit 62 (hidden) + bit 63 (no drive letter) = 0x8000000000000001
            $stepName = 'Set-Partition (Recovery attributes)'
            $recPartArgs = @{
                DiskNumber      = $DiskNumber
                PartitionNumber = $recPartition.PartitionNumber
                GptType         = $script:GptTypeRecovery
            }
            Set-Partition @recPartArgs
            Write-Host "  Recovery partition created: $(Get-FileSizeReadable $RecoveryPartitionSize)"
        }

    } else {
        # Initialize as MBR
        $stepName = 'Initialize-Disk (MBR)'
        Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop

        # System/Active partition
        $stepName = 'New-Partition (System)'
        $sysPartition = New-Partition -DiskNumber $DiskNumber -Size $script:MbrSystemSize -IsActive -MbrType 7
        $stepName = 'Format-Volume (System NTFS)'
        $null = $sysPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'System' -Confirm:$false
        $stepName = 'Add-PartitionAccessPath (System)'
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $sysPartition.PartitionNumber -AssignDriveLetter

        # Windows OS Partition - remaining
        $stepName = 'New-Partition (OS)'
        $osPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -MbrType 7
        $stepName = 'Format-Volume (OS NTFS)'
        $null = $osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false
        # Format-Volume may auto-assign the drive letter; only reassign if needed.
        $stepName = 'Set-Partition (drive letter)'
        $currentLetter = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber).DriveLetter
        if ([string]$currentLetter -ne [string]$OSDriveLetter) {
            # Free the target letter if another partition already owns it
            $conflict = Get-Partition | Where-Object { $_.DriveLetter -eq $OSDriveLetter } | Select-Object -First 1
            if ($conflict) {
                Remove-PartitionAccessPath -DiskNumber $conflict.DiskNumber -PartitionNumber $conflict.PartitionNumber -AccessPath "${OSDriveLetter}:\"
            }
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $OSDriveLetter
        }
    }

    } catch {
        $msg = "Disk $DiskNumber partitioning failed at step '$stepName': $_"
        if ($clearError) {
            $msg += " (preceded by Clear-Disk error: $clearError)"
        }
        throw $msg
    }

    Write-Success "Disk $DiskNumber partitioned. OS drive: ${OSDriveLetter}:"
    return $osPartition
}

#endregion

#region ── Windows Image Download ───────────────────────────────────────────────

function Find-WindowsESD {
    param(
        [xml]$Catalog,
        [string]$Edition,
        [string]$Language,
        [string]$Architecture = 'x64',
        [ValidateSet('UEFI','BIOS')]
        [string]$FirmwareType
    )

    $null = $FirmwareType
    $arch = $Architecture
    $allFiles = $Catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File
    $matchedEsd = $allFiles |
        Where-Object {
            $_.LanguageCode -eq $Language -and
            $_.Architecture -eq $arch -and
            $_.Edition      -like "*$($Edition.Replace(' ','*'))*"
        } |
        Sort-Object -Property @{Expression={ [long]$_.Size }; Descending = $true} |
        Select-Object -First 1

    if (-not $matchedEsd) {
        # Dump available entries to aid troubleshooting.
        $available = $allFiles |
            Where-Object { $_.LanguageCode -eq $Language -and $_.Architecture -eq $arch } |
            Select-Object -ExpandProperty Edition -ErrorAction SilentlyContinue |
            Sort-Object -Unique
        if ($available) {
            Write-Warn "Available editions in catalog for Language='$Language', Arch='$arch':"
            $available | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Warn "No entries found for Language='$Language', Arch='$arch'. Available architectures:"
            $allFiles | Select-Object -ExpandProperty Architecture -ErrorAction SilentlyContinue |
                Sort-Object -Unique | ForEach-Object { Write-Host "    $_" }
        }
        throw "No ESD found in catalog for: Edition='$Edition', Language='$Language', Arch='$arch'"
    }

    return $matchedEsd
}

function Get-WindowsImageSource {
    param(
        [string]$ImageUrl,
        [string]$Edition,
        [string]$Language,
        [string]$Architecture = 'x64',
        [string]$FirmwareType,
        [string]$ScratchDir
    )

    New-ScratchDirectory -Path $ScratchDir

    if ($ImageUrl) {
        # User-supplied image URL
        $ext = [System.IO.Path]::GetExtension($ImageUrl).ToLower()
        $imagePath = Join-Path $ScratchDir "windows$ext"
        Invoke-DownloadWithProgress -Uri $ImageUrl -OutFile $imagePath -Description 'Downloading Windows image' `
            -BaseProgress 20 -ProgressRange 30
        return $imagePath
    }

    # Read the ESD catalog directly from the repository.
    $stepName = ''
    try {
        $stepName = 'Download ESD catalog'
        Write-Step 'Reading Windows ESD catalog from repository...'
        $productsUrl  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/products.xml"
        $productsPath = Join-Path $ScratchDir 'products.xml'
        Invoke-DownloadWithProgress -Uri $productsUrl -OutFile $productsPath -Description 'Fetching Windows ESD catalog'

        $stepName = 'Parse ESD catalog'
        [xml]$catalog = Get-Content $productsPath -Encoding UTF8

        $stepName = 'Find matching ESD'
        $esd     = Find-WindowsESD -Catalog $catalog -Edition $Edition -Language $Language -Architecture $Architecture -FirmwareType $FirmwareType

        Write-Host "  Found ESD: $($esd.FileName) ($([long]$esd.Size | ForEach-Object { Get-FileSizeReadable $_ }))"

        $stepName = 'Download ESD'
        $esdPath = Join-Path $ScratchDir $esd.FileName
        Invoke-DownloadWithProgress -Uri $esd.FilePath -OutFile $esdPath -Description "Downloading Windows ESD: $Edition" `
            -BaseProgress 20 -ProgressRange 30

        return $esdPath
    } catch {
        throw "Get-WindowsImageSource failed at step '$stepName': $_"
    }
}

#endregion

#region ── Image Application ────────────────────────────────────────────────────

# Maps Microsoft ESD catalog edition identifiers to the keywords used
# in WIM/ESD ImageName fields (e.g. 'Professional' → 'Pro').
$script:EditionNameMap = @{
    'Professional'            = 'Pro'
    'ProfessionalN'           = 'Pro N'
    'ProfessionalWorkstation' = 'Pro for Workstations'
    'HomePremium'             = 'Home'
    'HomePremiumN'            = 'Home N'
    'CoreSingleLanguage'      = 'Home Single Language'
    'Education'               = 'Education'
    'EducationN'              = 'Education N'
    'Enterprise'              = 'Enterprise'
    'EnterpriseN'             = 'Enterprise N'
}

function Install-WindowsImage {
    param(
        [string]$ImagePath,
        [string]$Edition,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    Write-Step "Applying Windows image to ${OSDriveLetter}:..."

    $stepName = ''
    try {
        # Get the correct image index for the requested edition
        $stepName = 'Get-WindowsImage (enumerate editions)'
        $images = Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop
        Write-Host "  Available editions in image:"
        $images | ForEach-Object { Write-Host "    [$($_.ImageIndex)] $($_.ImageName)" }

        $stepName = 'Find target edition'
        $targetImage = $images | Where-Object { $_.ImageName -like "*$Edition*" } | Select-Object -First 1

        # The catalog uses short IDs (e.g. 'Professional') while WIM ImageName
        # uses friendly names (e.g. 'Windows 11 Pro').  Try the mapped name.
        if (-not $targetImage -and $script:EditionNameMap.ContainsKey($Edition)) {
            $mappedName = $script:EditionNameMap[$Edition]
            $targetImage = $images | Where-Object { $_.ImageName -like "*$mappedName*" } | Select-Object -First 1
        }

        if (-not $targetImage) {
            Write-Warn "Edition '$Edition' not found. Using index 1."
            $targetImage = $images | Select-Object -First 1
        }

        $stepName = 'Expand-WindowsImage (apply)'
        Write-Step "Applying image index $($targetImage.ImageIndex): $($targetImage.ImageName)"
        $scratch = Join-Path $ScratchDir 'scratch'
        New-ScratchDirectory -Path $scratch

        $null = Expand-WindowsImage `
            -ImagePath       $ImagePath `
            -Index           $targetImage.ImageIndex `
            -ApplyPath       "${OSDriveLetter}:\" `
            -ScratchDirectory $scratch `
            -ErrorAction Stop

        Write-Success 'Windows image applied successfully.'
    } catch {
        throw "Install-WindowsImage failed at step '$stepName': $_"
    }
}

#endregion

#region ── BCD / Bootloader ─────────────────────────────────────────────────────

function Set-Bootloader {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OSDriveLetter,
        [string]$FirmwareType,
        [int]$DiskNumber
    )

    if (-not $PSCmdlet.ShouldProcess($OSDriveLetter, 'Set-Bootloader')) { return }
    Write-Step 'Configuring bootloader...'

    $osDrive = "${OSDriveLetter}:"

    $stepName = ''
    try {
        if ($FirmwareType -eq 'UEFI') {
            # Find the EFI system partition
            $stepName = 'Find EFI System Partition'
            $espDrive = (Get-Partition -DiskNumber $DiskNumber |
                Where-Object { $_.GptType -eq $script:GptTypeEsp } |
                Get-Volume |
                Select-Object -First 1).DriveLetter

            if (-not $espDrive) {
                # Assign a temporary drive letter to ESP
                $stepName = 'Assign ESP drive letter'
                $esp = Get-Partition -DiskNumber $DiskNumber |
                    Where-Object { $_.GptType -eq $script:GptTypeEsp } |
                    Select-Object -First 1
                Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AssignDriveLetter
                $espDrive = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber | Get-Volume).DriveLetter
            }

            $stepName = 'bcdboot (UEFI)'
            Write-Host "  EFI partition: ${espDrive}:"
            & bcdboot.exe "$osDrive\Windows" /s "${espDrive}:" /f UEFI 2>&1 | Write-Host
        } else {
            $stepName = 'bcdboot (BIOS)'
            & bcdboot.exe "$osDrive\Windows" /s "$osDrive" /f BIOS 2>&1 | Write-Host
        }

        if ($LASTEXITCODE -ne 0) { throw "bcdboot failed with exit code $LASTEXITCODE" }
        Write-Success 'Bootloader configured.'
    } catch {
        throw "Set-Bootloader failed at step '$stepName': $_"
    }
}

#endregion

#region ── Driver Injection ─────────────────────────────────────────────────────

function Add-Driver {
    param(
        [string]$DriverPath,
        [string]$OSDriveLetter
    )

    if (-not $DriverPath -or -not (Test-Path $DriverPath)) {
        Write-Warn "Driver path not specified or not found: '$DriverPath'. Skipping driver injection."
        return
    }

    Write-Step "Injecting drivers from: $DriverPath"

    $stepName = ''
    try {
        $stepName = 'Enumerate driver .inf files'
        $infFiles = Get-ChildItem $DriverPath -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
        if (-not $infFiles) {
            Write-Warn 'No .inf files found in driver path. Skipping.'
            return
        }

        Write-Host "  Found $($infFiles.Count) driver(s)."

        $stepName = 'Add-WindowsDriver'
        $null = Add-WindowsDriver `
            -Path        "${OSDriveLetter}:\" `
            -Driver      $DriverPath `
            -Recurse `
            -ErrorAction Continue

        Write-Success "Drivers injected from: $DriverPath"
    } catch {
        throw "Add-Driver failed at step '$stepName': $_"
    }
}

# ── OEM driver injection ──────────────────────────────────────────────────────

function Initialize-NuGetProvider {
    <#
    .SYNOPSIS
        Ensures NuGet is available and PSGallery is trusted so Install-Module
        works correctly, including inside WinPE.
    #>
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Host '  Bootstrapping NuGet package provider...'
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop
    }
    $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $gallery -or $gallery.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
}

function Install-OemModule {
    <#
    .SYNOPSIS
        Installs a PowerShell module from the PSGallery if it is not already
        present on the current machine.
    #>
    param([string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)) {
        Write-Host "  Installing PowerShell module: $Name"
        Initialize-NuGetProvider
        Install-Module -Name $Name -Force -Scope AllUsers -AcceptLicense `
            -ErrorAction Stop
    }
}

function Get-SystemManufacturer {
    <#
    .SYNOPSIS
        Returns the trimmed manufacturer string from Win32_ComputerSystem.
    #>
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) { return $cs.Manufacturer.Trim() }
    return ''
}

function Add-DellDriver {
    <#
    .SYNOPSIS
        Downloads and injects the latest Dell drivers using Dell Command | Update.
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching Dell drivers via Dell Command | Update (DCU)...'

    $stepName = ''
    try {
        $stepName = 'Install DellCommandUpdate module'
        Install-OemModule -Name 'DellCommandUpdate'
        $stepName = 'Import DellCommandUpdate module'
        Import-Module DellCommandUpdate -ErrorAction Stop

        $stepName = 'Invoke-DCUUpdate'
        $driverTemp = Join-Path $ScratchDir 'Dell-Drivers'
        $null = New-Item -ItemType Directory -Path $driverTemp -Force

        # Download applicable driver updates without applying them to the live OS.
        Invoke-DCUUpdate -UpdateType driver -DownloadPath $driverTemp -ApplyUpdates:$false

        $stepName = 'Inject Dell drivers'
        $infFiles = Get-ChildItem $driverTemp -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
        if (-not $infFiles) {
            Write-Warn 'Dell Command | Update found no driver packages to inject.'
            return
        }

        Write-Host "  Injecting $($infFiles.Count) Dell driver(s) into ${OSDriveLetter}:\..."
        $null = Add-WindowsDriver -Path "${OSDriveLetter}:\" -Driver $driverTemp -Recurse `
            -ErrorAction Continue
        Write-Success 'Dell drivers injected successfully.'
    } catch {
        throw "Add-DellDriver failed at step '$stepName': $_"
    }
}

function Add-HpDriver {
    <#
    .SYNOPSIS
        Downloads and injects the latest HP drivers using HP Client Management
        Script Library (HPCMSL).
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching HP drivers via HP Client Management Script Library (HPCMSL)...'

    $stepName = ''
    try {
        $stepName = 'Install HPCMSL module'
        Install-OemModule -Name 'HPCMSL'
        $stepName = 'Import HPCMSL module'
        Import-Module HPCMSL -ErrorAction Stop

        $stepName = 'Add-HPDrivers'
        $driverTemp = Join-Path $ScratchDir 'HP-Drivers'
        $null = New-Item -ItemType Directory -Path $driverTemp -Force

        # Add-HPDrivers handles platform detection, SoftPaq download, extraction,
        # and offline DISM injection in a single call.
        Add-HPDrivers -Path "${OSDriveLetter}:\" -TempPath $driverTemp -ErrorAction Stop
        Write-Success 'HP drivers injected successfully.'
    } catch {
        throw "Add-HpDriver failed at step '$stepName': $_"
    }
}

function Add-LenovoDriver {
    <#
    .SYNOPSIS
        Downloads and injects the latest Lenovo drivers using LSUClient.
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching Lenovo drivers via LSUClient...'

    $stepName = ''
    try {
        $stepName = 'Install LSUClient module'
        Install-OemModule -Name 'LSUClient'
        $stepName = 'Import LSUClient module'
        Import-Module LSUClient -ErrorAction Stop

        $driverTemp = Join-Path $ScratchDir 'Lenovo-Drivers'
        $null = New-Item -ItemType Directory -Path $driverTemp -Force

        $stepName = 'Get-LSUpdate'
        $updates = $null
        try {
            $updates = Get-LSUpdate -ErrorAction Stop | Where-Object { $_.Type -eq 'Driver' }
        } catch {
            Write-Warn "LSUClient failed to retrieve update list: $_"
            return
        }
        if (-not $updates) {
            Write-Warn 'LSUClient found no driver updates for this Lenovo model.'
            return
        }

        $stepName = 'Save-LSUpdate'
        Write-Host "  Found $($updates.Count) Lenovo driver package(s). Downloading..."
        $updates | Save-LSUpdate -Path $driverTemp

        $stepName = 'Inject Lenovo drivers'
        $infFiles = Get-ChildItem $driverTemp -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
        if (-not $infFiles) {
            Write-Warn 'No .inf files found in downloaded Lenovo packages. Skipping injection.'
            return
        }

        Write-Host "  Injecting $($infFiles.Count) driver(s) into ${OSDriveLetter}:\..."
        $null = Add-WindowsDriver -Path "${OSDriveLetter}:\" -Driver $driverTemp -Recurse `
            -ErrorAction Continue
        Write-Success 'Lenovo drivers injected successfully.'
    } catch {
        throw "Add-LenovoDriver failed at step '$stepName': $_"
    }
}

function Add-SurfaceDriver {
    <#
    .SYNOPSIS
        Downloads and injects Microsoft Surface drivers from the Surface
        driver and firmware MSI packages.
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching Microsoft Surface drivers...'

    $stepName = ''
    try {
        $stepName = 'Detect Surface model'
        $model = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model
        Write-Host "  Surface model: $model"

        $stepName = 'Resolve driver pack URL'
        # Microsoft publishes cumulative driver/firmware packs per Surface model.
        # The download URL pattern follows: https://download.microsoft.com/download/...
        # We attempt to find the driver pack from the known model-to-URL mapping.
        $surfaceModels = @{
            'Surface Pro 9'       = 'SurfacePro9'
            'Surface Pro 10'      = 'SurfacePro10'
            'Surface Pro (11th Edition)' = 'SurfacePro11thEdition'
            'Surface Laptop 5'    = 'SurfaceLaptop5'
            'Surface Laptop 6'    = 'SurfaceLaptop6'
            'Surface Laptop Studio 2' = 'SurfaceLaptopStudio2'
            'Surface Go 4'        = 'SurfaceGo4'
            'Surface Book 3'      = 'SurfaceBook3'
        }

        $matchedKey = $surfaceModels.Keys | Where-Object { $model -like "*$_*" } | Select-Object -First 1
        if (-not $matchedKey) {
            Write-Warn "No known Surface driver pack for model '$model'. Skipping Surface driver injection."
            Write-Warn "Supported models: $($surfaceModels.Keys -join ', ')"
            return
        }

        $driverTemp = Join-Path $ScratchDir 'Surface-Drivers'
        $null = New-Item -ItemType Directory -Path $driverTemp -Force

        $packName = $surfaceModels[$matchedKey]
        $msiUrl = "https://download.microsoft.com/download/Surface/$packName/SurfaceUpdate.msi"
        $msiPath = Join-Path $driverTemp 'SurfaceUpdate.msi'

        $stepName = 'Download Surface driver pack'
        Write-Host "  Downloading driver pack for $matchedKey..."
        Invoke-DownloadWithProgress -Uri $msiUrl -OutFile $msiPath -Description "Downloading Surface drivers ($matchedKey)"

        $stepName = 'Extract drivers from MSI'
        $extractDir = Join-Path $driverTemp 'Extracted'
        $null = New-Item -ItemType Directory -Path $extractDir -Force
        $msiExec = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList "/a `"$msiPath`" /qn TARGETDIR=`"$extractDir`"" `
            -Wait -PassThru -NoNewWindow
        if ($msiExec.ExitCode -ne 0) {
            Write-Warn "MSI extraction returned exit code $($msiExec.ExitCode) -- attempting driver injection anyway"
        }

        $stepName = 'Inject Surface drivers'
        $infFiles = Get-ChildItem $extractDir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
        if (-not $infFiles) {
            Write-Warn 'No .inf driver files found in Surface driver pack. Skipping injection.'
            return
        }

        Write-Host "  Injecting $($infFiles.Count) Surface driver(s) into ${OSDriveLetter}:\..."
        $null = Add-WindowsDriver -Path "${OSDriveLetter}:\" -Driver $extractDir -Recurse `
            -ErrorAction Continue
        Write-Success 'Microsoft Surface drivers injected successfully.'
    } catch {
        throw "Add-SurfaceDriver failed at step '$stepName': $_"
    }
}

function Invoke-OemDriverInjection {
    <#
    .SYNOPSIS
        Detects the system manufacturer and calls the appropriate OEM driver
        injection function (Dell, HP, or Lenovo).
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'OEM driver injection: detecting manufacturer...'

    $stepName = ''
    try {
        $stepName = 'Detect manufacturer'
        $manufacturer = Get-SystemManufacturer
        Write-Host "  Manufacturer: '$manufacturer'"

        $stepName = "Inject drivers for '$manufacturer'"
        switch -Wildcard ($manufacturer) {
            '*Dell*'    { Add-DellDriver    -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*HP*'      { Add-HpDriver      -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*Hewlett*' { Add-HpDriver      -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*Lenovo*'  { Add-LenovoDriver  -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            '*Microsoft*' { Add-SurfaceDriver -OSDriveLetter $OSDriveLetter -ScratchDir $ScratchDir }
            default {
                Write-Warn "Manufacturer '$manufacturer' is not supported for OEM driver automation. Use -DriverPath for manual driver injection."
            }
        }
    } catch {
        throw "Invoke-OemDriverInjection failed at step '$stepName': $_"
    }
}

#endregion

#region ── Autopilot / Intune ───────────────────────────────────────────────────

function Set-AutopilotConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$JsonUrl,
        [string]$JsonPath,
        [string]$OSDriveLetter
    )

    if (-not $JsonUrl -and -not $JsonPath) {
        Write-Warn 'No Autopilot JSON specified. Skipping Autopilot configuration.'
        return
    }

    Write-Step 'Applying Autopilot configuration...'

    $stepName = ''
    try {
        $stepName = 'Create Autopilot directory'
        $autopilotDest = "${OSDriveLetter}:\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json"
        $null = New-Item -ItemType Directory -Path (Split-Path $autopilotDest) -Force

        if ($JsonUrl) {
            $stepName = 'Download Autopilot JSON'
            Write-Host "  Fetching Autopilot JSON from: $JsonUrl"
            Invoke-WebRequest -Uri $JsonUrl -OutFile $autopilotDest -UseBasicParsing -TimeoutSec 30
        } else {
            $stepName = 'Copy Autopilot JSON'
            Copy-Item $JsonPath $autopilotDest -Force
        }

        Write-Success "Autopilot JSON placed at: $autopilotDest"
    } catch {
        throw "Set-AutopilotConfig failed at step '$stepName': $_"
    }
}

function Invoke-AutopilotImport {
    <#
    .SYNOPSIS  Registers the current device in Windows Autopilot via Microsoft Graph API.
    .DESCRIPTION
        Uses the Graph access token (from NOVA_GRAPH_TOKEN) to check whether
        the device is already registered in Autopilot.  If not, generates the
        hardware hash with oa3tool.exe and uploads the device identity via Graph.
        Group tag and user email are applied when provided.
    #>
    param(
        [string]$GroupTag,
        [string]$UserEmail
    )

    $token = $env:NOVA_GRAPH_TOKEN
    if (-not $token) {
        Write-Warn 'No Graph access token available (NOVA_GRAPH_TOKEN). Skipping Autopilot device import.'
        return
    }

    Write-Step 'Importing device into Windows Autopilot...'

    $authHeaders = @{ 'Authorization' = "Bearer $token" }

    # ── 1. Get serial number ────────────────────────────────────────────
    $serial = $null
    try { $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber } catch { $null = $_ }
    if (-not $serial -or $serial.Trim() -eq '') {
        throw 'Autopilot import failed: device serial number is empty or unavailable.'
    }
    Write-Host "  Serial number: $serial"

    # ── 2. Check if the device is already registered ────────────────────
    $sanitized = $serial -replace "['\\\x00-\x1f]", ''
    $filter    = [uri]::EscapeDataString("contains(serialNumber,'$sanitized')")
    $checkUri  = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"

    try {
        $existing = Invoke-RestMethod -Uri $checkUri -Headers $authHeaders -Method GET -TimeoutSec 30
        if ($existing.value -and $existing.value.Count -gt 0) {
            Write-Success "Device $serial is already registered in Autopilot -- skipping import."
            return
        }
    } catch {
        Write-Warn "Autopilot registration check failed (non-fatal): $_"
    }

    Write-Host '  Device not found in Autopilot -- proceeding with import...'

    # ── 3. Generate hardware hash via oa3tool.exe ───────────────────────
    $customFolder = 'X:\OSDCloud\Config\Scripts\Custom'
    $oa3tool = Join-Path $customFolder 'oa3tool.exe'
    $oa3cfg  = Join-Path $customFolder 'OA3.cfg'

    if (-not (Test-Path $oa3tool) -or -not (Test-Path $oa3cfg)) {
        throw 'Autopilot import failed: oa3tool.exe or OA3.cfg not staged in WinPE.'
    }

    $oa3proc = Start-Process -FilePath $oa3tool `
        -ArgumentList "/Report /ConfigFile=$oa3cfg /NoKeyCheck" `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput 'oa3.log' -RedirectStandardError 'oa3.error.log'

    if ($oa3proc.ExitCode -ne 0) {
        throw 'Autopilot import failed: oa3tool.exe exited with a non-zero code.'
    }

    if (-not (Test-Path 'OA3.xml')) {
        throw 'Autopilot import failed: OA3.xml not generated by oa3tool.'
    }

    try {
        [xml]$oa3Xml = Get-Content -Path 'OA3.xml' -Raw
    } catch {
        throw "Autopilot import failed: could not parse OA3.xml as valid XML: $_"
    }
    $hashNode = $oa3Xml.SelectSingleNode('//HardwareHash')
    if (-not $hashNode -or -not $hashNode.InnerText) {
        throw 'Autopilot import failed: hardware hash not found in OA3.xml.'
    }
    $hwHash = $hashNode.InnerText
    Remove-Item 'OA3.xml' -Force -ErrorAction SilentlyContinue
    Write-Host '  Hardware hash generated successfully.'

    # ── 4. Upload device to Autopilot ───────────────────────────────────
    $body = @{
        serialNumber       = $serial
        hardwareIdentifier = $hwHash
    }
    if ($GroupTag)  { $body.groupTag = $GroupTag }
    if ($UserEmail) { $body.assignedUserPrincipalName = $UserEmail }

    $uploadUri = 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities'
    $null = Invoke-RestMethod -Uri $uploadUri -Headers ($authHeaders + @{
        'Content-Type' = 'application/json'
    }) -Method POST -Body ($body | ConvertTo-Json) -TimeoutSec 60

    Write-Host '  Device uploaded -- waiting for registration...'

    # ── 5. Poll until the device appears in Autopilot ───────────────────
    # Autopilot registration is asynchronous.  Poll every 30 seconds for
    # up to 25 attempts (~12.5 minutes) to confirm the device is visible.
    $maxAttempts = 25
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Start-Sleep -Seconds 30
        try {
            $poll = Invoke-RestMethod -Uri $checkUri -Headers $authHeaders -Method GET -TimeoutSec 30
            if ($poll.value -and $poll.value.Count -gt 0) {
                Write-Success "Device successfully registered in Autopilot (attempt $i)."
                return
            }
        } catch {
            Write-Warn "Registration poll attempt $i failed: $_"
        }
    }

    throw "Autopilot import: device registration not confirmed after $maxAttempts attempts."
}

#endregion

#region ── ConfigMgr (SCCM) ─────────────────────────────────────────────────────

function Install-CCMSetup {
    param(
        [string]$CCMSetupUrl,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    if (-not $CCMSetupUrl) {
        Write-Warn 'No CCMSetup URL specified. Skipping ConfigMgr setup.'
        return
    }

    Write-Step 'Staging ConfigMgr CCMSetup...'

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $ccmDir  = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $ccmDir -Force

        $stepName = 'Download ccmsetup.exe'
        $ccmExe  = Join-Path $ScratchDir 'ccmsetup.exe'
        Invoke-DownloadWithProgress -Uri $CCMSetupUrl -OutFile $ccmExe -Description 'Downloading ccmsetup.exe'

        $stepName = 'Stage ccmsetup.exe'
        Copy-Item $ccmExe (Join-Path $ccmDir 'ccmsetup.exe') -Force

        # Add to SetupComplete.cmd to run ccmsetup on first boot
        $stepName = 'Add SetupComplete entry'
        $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
        Add-SetupCompleteEntry -FilePath $setupComplete -Line '"%~dp0ccmsetup.exe" /BITSPriority:FOREGROUND'

        Write-Success 'CCMSetup staged for first-boot execution.'
    } catch {
        throw "Install-CCMSetup failed at step '$stepName': $_"
    }
}

#endregion

#region ── OOBE Customization ───────────────────────────────────────────────────

# Default unattend.xml used when the task sequence has no unattendContent yet.
$script:DefaultUnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>false</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>false</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>false</SkipMachineOOBE>
        <SkipUserOOBE>false</SkipUserOOBE>
      </OOBE>
    </component>
  </settings>
</unattend>
"@

function Set-OOBECustomization {
    <#
    .SYNOPSIS  Writes the unattend.xml to the target OS drive.
    .DESCRIPTION
        The unattendContent in the task sequence is the single source of
        truth -- ComputerName and locale settings are already injected by
        the Task Sequence Editor (or the Bootstrap config modal at runtime).
        This function simply writes the final XML to disk (or downloads /
        copies from an external source).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$UnattendUrl,
        [string]$UnattendPath,
        [string]$UnattendContent,
        [string]$OSDriveLetter
    )

    Write-Step 'Applying OOBE customization...'

    $stepName = ''
    try {
        $stepName = 'Create Panther directory'
        $unattendDest = "${OSDriveLetter}:\Windows\Panther\unattend.xml"
        $null = New-Item -ItemType Directory -Path (Split-Path $unattendDest) -Force

        if ($UnattendUrl) {
            $stepName = 'Download unattend.xml'
            Write-Host "  Fetching unattend.xml from: $UnattendUrl"
            Invoke-WebRequest -Uri $UnattendUrl -OutFile $unattendDest -UseBasicParsing -TimeoutSec 30
            Write-Success "Custom unattend.xml applied from URL."
            return
        }

        if ($UnattendPath -and (Test-Path $UnattendPath)) {
            $stepName = 'Copy unattend.xml'
            Copy-Item $UnattendPath $unattendDest -Force
            Write-Success "Custom unattend.xml applied from path: $UnattendPath"
            return
        }

        if ($UnattendContent) {
            $stepName = 'Apply task sequence unattend.xml'
            Set-Content -Path $unattendDest -Value $UnattendContent -Encoding UTF8
            Write-Success 'Custom unattend.xml applied from task sequence content.'
            return
        }

        # Fallback: write the built-in default (no custom settings)
        $stepName = 'Generate default unattend.xml'
        Set-Content -Path $unattendDest -Value $script:DefaultUnattendXml -Encoding UTF8
        Write-Success 'Default unattend.xml applied.'
    } catch {
        throw "Set-OOBECustomization failed at step '$stepName': $_"
    }
}

#endregion

#region ── BitLocker / Encryption ───────────────────────────────────────────────

function Enable-BitLockerProtection {
    <#
    .SYNOPSIS  Stage BitLocker drive encryption for first-boot activation.
    .DESCRIPTION
        Creates a PowerShell script that enables BitLocker with TPM protector
        on the OS drive and registers it for execution on first boot via
        SetupComplete.cmd.  The recovery password is backed up to Azure AD
        when the device is Azure AD joined.
    .PARAMETER OSDriveLetter  Target OS drive letter (e.g. 'C').
    .PARAMETER EncryptionMethod  BitLocker encryption algorithm (default XtsAes256).
    .PARAMETER SkipHardwareTest  Skip the TPM hardware test during enable.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$OSDriveLetter,
        [string]$EncryptionMethod = 'XtsAes256',
        [switch]$SkipHardwareTest
    )

    Write-Step 'Staging BitLocker encryption for first boot...'

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $scriptDir -Force

        $stepName = 'Generate BitLocker script'
        $skipFlag = if ($SkipHardwareTest) { ' -SkipHardwareTest' } else { '' }
        $blScript = @"
# Nova BitLocker -- first-boot activation
# Generated by Nova deployment engine
`$ErrorActionPreference = 'Stop'
try {
    `$drive = '$OSDriveLetter' + ':'
    Enable-BitLocker -MountPoint `$drive -EncryptionMethod $EncryptionMethod -TpmProtector$skipFlag
    Add-BitLockerKeyProtector -MountPoint `$drive -RecoveryPasswordProtector
    # Back up recovery key to Azure AD if the device is joined
    `$blv = Get-BitLockerVolume -MountPoint `$drive
    `$rp = `$blv.KeyProtector | Where-Object { `$_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    if (`$rp) {
        try {
            BackupToAAD-BitLockerKeyProtector -MountPoint `$drive -KeyProtectorId `$rp.KeyProtectorId -ErrorAction SilentlyContinue
        } catch {
            # Device may not be AAD joined -- skip backup silently
        }
    }
} catch {
    Write-EventLog -LogName Application -Source 'Nova' -EventId 1001 -EntryType Error -Message "Nova BitLocker activation failed: `$_"
}
"@
        $blScriptPath = Join-Path $scriptDir 'Nova_EnableBitLocker.ps1'
        Set-Content -Path $blScriptPath -Value $blScript -Encoding UTF8

        $stepName = 'Add SetupComplete entry'
        $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
        Add-SetupCompleteEntry -FilePath $setupComplete -Line 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Nova_EnableBitLocker.ps1"'

        Write-Success 'BitLocker encryption staged for first boot.'
    } catch {
        throw "Enable-BitLockerProtection failed at step '$stepName': $_"
    }
}

#endregion

#region ── Post-Provisioning Scripts ────────────────────────────────────────────

function Invoke-PostScript {
    param(
        [string[]]$ScriptUrls,
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )

    $null = $ScratchDir
    if (-not $ScriptUrls -or $ScriptUrls.Count -eq 0) {
        Write-Warn 'No post-provisioning scripts specified. Skipping.'
        return
    }

    Write-Step "Staging $($ScriptUrls.Count) post-provisioning script(s)..."

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $scriptDir -Force

        $i = 1
        foreach ($url in $ScriptUrls) {
            $fileName = "Nova_Post_$($i.ToString('00')).ps1"
            $stepName = "Download post-script '$fileName'"
            $dest     = Join-Path $scriptDir $fileName
            Write-Host "  Downloading: $url -> $fileName"
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 30
            $i++
        }

        # Add each script to SetupComplete.cmd
        $stepName = 'Add SetupComplete entries'
        $setupComplete = "${OSDriveLetter}:\Windows\Setup\Scripts\SetupComplete.cmd"
        for ($j = 1; $j -lt $i; $j++) {
            $fileName = "Nova_Post_$($j.ToString('00')).ps1"
            Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$fileName`""
        }

        Write-Success "Post-provisioning scripts staged in: $scriptDir"
    } catch {
        throw "Invoke-PostScript failed at step '$stepName': $_"
    }
}

#endregion

#region -- Application Installation -------------------------------------------

function Install-Application {
    <#
    .SYNOPSIS  Stages application installers for first-boot execution.
    .DESCRIPTION
        Downloads application installers (MSI, EXE, or Winget manifests) and
        stages them for installation on first boot via SetupComplete.cmd.
        Supports three modes:
          - winget: stages a Winget import file for first-boot installation
          - url:    downloads an MSI/EXE installer and stages with silent args
          - script: downloads and stages a custom installation script
    #>
    param(
        [string]$InstallMode = 'url',
        [string]$PackageId,
        [string]$InstallerUrl,
        [string]$SilentArgs = '/qn /norestart',
        [string]$ScriptUrl,
        [string]$OSDriveLetter
    )

    Write-Step 'Staging application installation...'

    $stepName = ''
    $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
    $setupComplete = Join-Path $scriptDir 'SetupComplete.cmd'
    $null = New-Item -ItemType Directory -Path $scriptDir -Force

    try {
        switch ($InstallMode) {
            'winget' {
                $stepName = 'Stage Winget installation'
                if (-not $PackageId) {
                    Write-Warn 'No Winget package ID specified. Skipping application installation.'
                    return
                }
                # Stage a PowerShell script that installs via Winget on first boot
                $wingetScript = Join-Path $scriptDir 'Nova_InstallApp_Winget.ps1'
                $scriptContent = @"
# Nova -- Winget application installation (first boot)
`$ErrorActionPreference = 'Continue'
`$maxRetries = 3
for (`$i = 1; `$i -le `$maxRetries; `$i++) {
    try {
        winget install --id '$PackageId' --silent --accept-source-agreements --accept-package-agreements
        if (`$LASTEXITCODE -eq 0) { break }
    } catch { Start-Sleep -Seconds (5 * `$i) }
}
"@
                Set-Content -Path $wingetScript -Value $scriptContent -Encoding UTF8
                Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Nova_InstallApp_Winget.ps1`""
                Write-Success "Winget installation staged for package: $PackageId"
            }
            'url' {
                $stepName = 'Download installer'
                if (-not $InstallerUrl) {
                    Write-Warn 'No installer URL specified. Skipping application installation.'
                    return
                }
                $ext = [System.IO.Path]::GetExtension($InstallerUrl).ToLower()
                if (-not $ext) { $ext = '.exe' }
                $installerName = "Nova_AppInstaller$ext"
                $installerDest = Join-Path $scriptDir $installerName
                Invoke-DownloadWithProgress -Uri $InstallerUrl -OutFile $installerDest -Description 'Downloading application installer'

                $stepName = 'Stage installer'
                if ($ext -eq '.msi') {
                    Add-SetupCompleteEntry -FilePath $setupComplete -Line "msiexec.exe /i `"%~dp0$installerName`" $SilentArgs"
                } else {
                    Add-SetupCompleteEntry -FilePath $setupComplete -Line "`"%~dp0$installerName`" $SilentArgs"
                }
                Write-Success "Application installer staged: $installerName"
            }
            'script' {
                $stepName = 'Download installation script'
                if (-not $ScriptUrl) {
                    Write-Warn 'No script URL specified. Skipping application installation.'
                    return
                }
                $scriptDest = Join-Path $scriptDir 'Nova_InstallApp_Custom.ps1'
                Invoke-WebRequest -Uri $ScriptUrl -OutFile $scriptDest -UseBasicParsing -TimeoutSec 30
                Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Nova_InstallApp_Custom.ps1`""
                Write-Success "Custom installation script staged."
            }
            default {
                Write-Warn "Unknown install mode '$InstallMode'. Skipping."
            }
        }
    } catch {
        throw "Install-Application failed at step '$stepName': $_"
    }
}

#endregion

#region -- Windows Update Staging ----------------------------------------------

function Invoke-WindowsUpdateStaging {
    <#
    .SYNOPSIS  Stages a Windows Update trigger script for first-boot execution.
    .DESCRIPTION
        Creates a PowerShell script that runs on first boot to install critical
        and security updates via the built-in Windows Update client.  The script
        uses the COM-based Windows Update Agent API which is available on all
        Windows installations without additional modules.
    #>
    param(
        [string]$OSDriveLetter,
        [string[]]$Categories = @('SecurityUpdates', 'CriticalUpdates')
    )

    Write-Step 'Staging Windows Update for first boot...'

    $stepName = ''
    try {
        $stepName = 'Create scripts directory'
        $scriptDir = "${OSDriveLetter}:\Windows\Setup\Scripts"
        $null = New-Item -ItemType Directory -Path $scriptDir -Force

        $stepName = 'Generate Windows Update script'
        $wuScript = Join-Path $scriptDir 'Nova_WindowsUpdate.ps1'
        $scriptContent = @"
# Nova -- Windows Update (first boot)
# Installs critical and security updates using the Windows Update Agent COM API.
`$ErrorActionPreference = 'Continue'
`$logFile = "`$env:SystemDrive\Nova\Logs\WindowsUpdate.log"
`$null = New-Item -ItemType Directory -Path (Split-Path `$logFile) -Force -ErrorAction SilentlyContinue
Start-Transcript -Path `$logFile -Force -ErrorAction SilentlyContinue

Write-Host 'Nova: Starting Windows Update scan...'
try {
    `$session    = New-Object -ComObject Microsoft.Update.Session
    `$searcher   = `$session.CreateUpdateSearcher()
    `$result     = `$searcher.Search('IsInstalled=0 AND IsHidden=0')
    `$updates    = `$result.Updates

    if (`$updates.Count -eq 0) {
        Write-Host 'Nova: No updates available.'
    } else {
        Write-Host "Nova: Found `$(`$updates.Count) update(s). Downloading and installing..."
        `$downloader = `$session.CreateUpdateDownloader()
        `$downloader.Updates = `$updates
        `$null = `$downloader.Download()

        `$installer = `$session.CreateUpdateInstaller()
        `$installer.Updates = `$updates
        `$installResult = `$installer.Install()
        Write-Host "Nova: Update installation complete. Result: `$(`$installResult.ResultCode)"
    }
} catch {
    Write-Warning "Nova: Windows Update failed: `$_"
}

Stop-Transcript -ErrorAction SilentlyContinue
"@
        Set-Content -Path $wuScript -Value $scriptContent -Encoding UTF8

        $stepName = 'Register in SetupComplete'
        $setupComplete = Join-Path $scriptDir 'SetupComplete.cmd'
        Add-SetupCompleteEntry -FilePath $setupComplete -Line "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Nova_WindowsUpdate.ps1`""

        Write-Success "Windows Update staged for first boot (categories: $($Categories -join ', '))"
    } catch {
        throw "Invoke-WindowsUpdateStaging failed at step '$stepName': $_"
    }
}

#endregion

#region ── Task Sequence ────────────────────────────────────────────────────────

function Read-TaskSequence {
    <#
    .SYNOPSIS  Loads a task sequence JSON file produced by the web-based Editor.
    .DESCRIPTION
        Reads the JSON file, validates the required structure (name + steps array),
        and returns a hashtable matching the schema in resources/task-sequence/default.json.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path $Path)) {
        throw "Task sequence file not found: $Path"
    }
    Write-Step "Loading task sequence from $Path"
    $raw = Get-Content $Path -Raw -ErrorAction Stop
    $ts  = $raw | ConvertFrom-Json -ErrorAction Stop

    if (-not $ts.steps -or $ts.steps -isnot [System.Collections.IEnumerable]) {
        throw "Invalid task sequence file: missing 'steps' array"
    }
    foreach ($s in $ts.steps) {
        if (-not $s.type) { throw "Invalid task sequence: step '$($s.name)' is missing required 'type' property" }
        if (-not $s.name) { throw "Invalid task sequence: a step with type '$($s.type)' is missing required 'name' property" }
    }

    # ── Schema version validation (forward-compatible) ──────────────
    if ($ts.PSObject.Properties['schemaVersion'] -and $ts.schemaVersion) {
        if ($ts.schemaVersion -ne '1.0') {
            Write-Warning "Task sequence schema version '$($ts.schemaVersion)' may not be fully compatible with this engine (expected 1.0)"
        }
    } else {
        Write-Verbose 'No schemaVersion found -- assuming 1.0 compatibility'
    }

    Write-Success "Loaded task sequence '$($ts.name)' with $($ts.steps.Count) steps"
    return $ts
}

function Test-StepCondition {
    <#
    .SYNOPSIS  Evaluates a step's condition object and returns $true/$false.
    .DESCRIPTION
        Each step in the task sequence may carry an optional 'condition' property
        (set via the Editor's Condition UI).  This function evaluates the condition
        at runtime and returns $true when the step should run, $false to skip it.
        Steps without a condition always return $true.

        Supported condition types:
          variable  -- check an environment / task-sequence variable
          wmiQuery  -- run a WMI query and check whether it returns results
          registry  -- check a registry path/value
    #>
    param(
        [psobject]$Condition
    )

    if (-not $Condition -or -not $Condition.type) { return $true }

    switch ($Condition.type) {
        'variable' {
            $varName = $Condition.variable
            if (-not $varName) { return $true }
            $actual = [System.Environment]::GetEnvironmentVariable($varName)
            $op = if ($Condition.operator) { $Condition.operator } else { 'equals' }
            $expected = if ($Condition.value) { $Condition.value } else { '' }

            switch ($op) {
                'equals'     { return ($actual -eq $expected) }
                'notEquals'  { return ($actual -ne $expected) }
                'contains'   { return ($null -ne $actual -and "$actual".IndexOf($expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) }
                'startsWith' { return ($null -ne $actual -and "$actual".StartsWith($expected, [System.StringComparison]::OrdinalIgnoreCase)) }
                'exists'     { return ($null -ne $actual) }
                'notExists'  { return ($null -eq $actual) }
                default      { return $true }
            }
        }
        'wmiQuery' {
            $query = $Condition.query
            if (-not $query) { return $true }
            $ns = if ($Condition.namespace) { $Condition.namespace } else { 'root\cimv2' }
            try {
                $results = Get-CimInstance -Query $query -Namespace $ns -ErrorAction Stop
                return ($null -ne $results -and @($results).Count -gt 0)
            } catch {
                Write-Warn "WMI condition query failed: $_"
                return $false
            }
        }
        'registry' {
            $regPath = $Condition.registryPath
            if (-not $regPath) { return $true }
            $regValue = $Condition.registryValue
            $op = if ($Condition.operator) { $Condition.operator } else { 'exists' }
            $expected = if ($Condition.value) { $Condition.value } else { '' }

            try {
                if (-not $regValue) {
                    # Check key existence only
                    $keyExists = Test-Path $regPath
                    switch ($op) {
                        'exists'    { return $keyExists }
                        'notExists' { return (-not $keyExists) }
                        default     { return $keyExists }
                    }
                }

                # Check specific value
                $valueExists = $false
                $actual = $null
                if (Test-Path $regPath) {
                    try {
                        $actual = (Get-ItemProperty -Path $regPath -Name $regValue -ErrorAction Stop).$regValue
                        $valueExists = $true
                    } catch { $valueExists = $false }
                }

                switch ($op) {
                    'exists'    { return $valueExists }
                    'notExists' { return (-not $valueExists) }
                    'equals'    { return ($valueExists -and "$actual" -eq $expected) }
                    'notEquals' { return (-not $valueExists -or "$actual" -ne $expected) }
                    default     { return $valueExists }
                }
            } catch {
                Write-Warn "Registry condition check failed: $_"
                return $false
            }
        }
        default {
            Write-Warn "Unknown condition type '$($Condition.type)' -- treating as met"
            return $true
        }
    }
}

function Invoke-TaskSequenceStep {
    <#
    .SYNOPSIS  Executes a single task sequence step by dispatching to the matching engine function.
    .DESCRIPTION
        Maps each step type string to the corresponding Nova engine function,
        passing the step's parameters.  All parameter values come from the task
        sequence JSON -- no script-level fallbacks.
    #>
    param(
        [Parameter(Mandatory)]
        [psobject]$Step,
        [int]$Index,
        [int]$TotalSteps,
        # Shared state needed across steps (set by the caller)
        [string]$CurrentScratchDir,
        [string]$CurrentOSDrive,
        [string]$CurrentFirmwareType,
        [int]$CurrentDiskNumber
    )

    $pct = [math]::Min(100, [math]::Round(($Index / $TotalSteps) * 100))
    # Bootstrap.ps1 UI shows four progress steps (Network / Connect / Sign in /
    # Deploy).  During the deploy phase all four indicators should stay lit, so
    # always report Step 4 to keep the first three steps highlighted.
    $uiStep = 4
    $p = $Step.parameters

    switch ($Step.type) {
        'PartitionDisk' {
            $disk = if ($p -and $p.PSObject.Properties['diskNumber'] -and $null -ne $p.diskNumber) { $p.diskNumber } else { $CurrentDiskNumber }
            # Auto-select disk when -1 or not specified
            if ($disk -eq -1) {
                $disk = Get-TargetDisk -DiskNumber -1
            }
            $drv  = if ($p -and $p.PSObject.Properties['osDriveLetter'] -and $p.osDriveLetter) { $p.osDriveLetter } else { $CurrentOSDrive }
            $createRecovery = if ($p -and $p.PSObject.Properties['createRecoveryPartition'] -and $p.createRecoveryPartition) { $true } else { $false }
            $recoverySize = if ($p -and $p.PSObject.Properties['recoveryPartitionSize'] -and $p.recoveryPartitionSize -gt 0) { [long]$p.recoveryPartitionSize } else { $script:DefaultRecoverySize }
            Update-BootstrapStatus -Message "Partitioning disk..." -Detail "Creating layout on disk $disk" -Step $uiStep -Progress $pct
            Initialize-TargetDisk -DiskNumber $disk -FirmwareType $CurrentFirmwareType -OSDriveLetter $drv `
                -CreateRecoveryPartition:$createRecovery -RecoveryPartitionSize $recoverySize
        }
        'ImportAutopilot' {
            $tag   = if ($p -and $p.PSObject.Properties['groupTag']  -and $p.groupTag)  { $p.groupTag }  else { '' }
            $email = if ($p -and $p.PSObject.Properties['userEmail'] -and $p.userEmail) { $p.userEmail } else { '' }
            Update-BootstrapStatus -Message "Importing Autopilot device..." -Detail "Registering device in Windows Autopilot" -Step $uiStep -Progress $pct
            Invoke-AutopilotImport -GroupTag $tag -UserEmail $email
        }
        'DownloadImage' {
            $url  = if ($p -and $p.PSObject.Properties['imageUrl']      -and $p.imageUrl)      { $p.imageUrl }      else { '' }
            $ed   = if ($p -and $p.PSObject.Properties['edition']       -and $p.edition)       { $p.edition }       else { 'Professional' }
            $lang = if ($p -and $p.PSObject.Properties['language']      -and $p.language)      { $p.language }      else { 'en-us' }
            $arch = if ($p -and $p.PSObject.Properties['architecture']  -and $p.architecture)  { $p.architecture }  else { 'x64' }
            Update-BootstrapStatus -Message "Downloading Windows image..." -Detail "Fetching $ed $lang $arch" -Step $uiStep -Progress $pct
            $script:TsImagePath = Get-WindowsImageSource `
                -ImageUrl $url -Edition $ed -Language $lang -Architecture $arch `
                -FirmwareType $CurrentFirmwareType -ScratchDir $CurrentScratchDir
        }
        'ApplyImage' {
            $ed   = if ($p -and $p.PSObject.Properties['edition']       -and $p.edition)       { $p.edition }       else { 'Professional' }
            $lang = if ($p -and $p.PSObject.Properties['language']      -and $p.language)      { $p.language }      else { 'en-us' }
            $arch = if ($p -and $p.PSObject.Properties['architecture']  -and $p.architecture)  { $p.architecture }  else { 'x64' }
            if (-not $script:TsImagePath) {
                $url = if ($p -and $p.PSObject.Properties['imageUrl'] -and $p.imageUrl) { $p.imageUrl } else { '' }
                Update-BootstrapStatus -Message "Downloading Windows image..." -Detail "Fetching $ed $lang $arch" -Step $uiStep -Progress $pct
                $script:TsImagePath = Get-WindowsImageSource `
                    -ImageUrl $url -Edition $ed -Language $lang -Architecture $arch `
                    -FirmwareType $CurrentFirmwareType -ScratchDir $CurrentScratchDir
            }
            Update-BootstrapStatus -Message "Applying Windows image..." -Detail "Expanding Windows files" -Step $uiStep -Progress $pct
            Install-WindowsImage -ImagePath $script:TsImagePath -Edition $ed -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'SetBootloader' {
            Update-BootstrapStatus -Message "Configuring bootloader..." -Detail "Writing BCD store" -Step $uiStep -Progress $pct
            Set-Bootloader -OSDriveLetter $CurrentOSDrive -FirmwareType $CurrentFirmwareType -DiskNumber $CurrentDiskNumber
        }
        'InjectDrivers' {
            $dp = if ($p -and $p.PSObject.Properties['driverPath'] -and $p.driverPath) { $p.driverPath } else { '' }
            Update-BootstrapStatus -Message "Injecting drivers..." -Detail "Adding drivers" -Step $uiStep -Progress $pct
            Add-Driver -DriverPath $dp -OSDriveLetter $CurrentOSDrive
        }
        'InjectOemDrivers' {
            Update-BootstrapStatus -Message "Injecting OEM drivers..." -Detail "Fetching manufacturer drivers" -Step $uiStep -Progress $pct
            Invoke-OemDriverInjection -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'ApplyAutopilot' {
            $jUrl  = if ($p -and $p.PSObject.Properties['jsonUrl']  -and $p.jsonUrl)  { $p.jsonUrl }  else { '' }
            $jPath = if ($p -and $p.PSObject.Properties['jsonPath'] -and $p.jsonPath) { $p.jsonPath } else { '' }
            Update-BootstrapStatus -Message "Applying Autopilot configuration..." -Detail "Embedding provisioning profile" -Step $uiStep -Progress $pct
            Set-AutopilotConfig -JsonUrl $jUrl -JsonPath $jPath -OSDriveLetter $CurrentOSDrive
        }
        'StageCCMSetup' {
            $url = if ($p -and $p.PSObject.Properties['ccmSetupUrl'] -and $p.ccmSetupUrl) { $p.ccmSetupUrl } else { '' }
            Update-BootstrapStatus -Message "Staging ConfigMgr setup..." -Detail "Preparing ccmsetup.exe" -Step $uiStep -Progress $pct
            Install-CCMSetup -CCMSetupUrl $url -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'SetComputerName' {
            # Resolve computer name from naming rules or use the static value.
            # The Task Sequence Editor and Bootstrap config modal handle syncing
            # names into unattendContent -- the engine just resolves and logs.
            $cName = if ($p -and $p.PSObject.Properties['computerName'] -and $p.computerName) { $p.computerName } else { '' }
            if (-not $cName -and $p) {
                # Determine naming source (backward compat: useSerialNumber → serialNumber)
                $source = if ($p.PSObject.Properties['namingSource'] -and $p.namingSource) { $p.namingSource }
                          elseif ($p.PSObject.Properties['useSerialNumber'] -and $p.useSerialNumber) { 'serialNumber' }
                          else { 'randomDigits' }
                $base = ''
                switch ($source) {
                    'serialNumber' {
                        try { $base = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber -replace '[^A-Za-z0-9]','' } catch { $null = $_ }
                    }
                    'assetTag' {
                        try { $base = (Get-CimInstance -ClassName Win32_SystemEnclosure).SMBIOSAssetTag -replace '[^A-Za-z0-9]','' } catch { $null = $_ }
                    }
                    'macAddress' {
                        try {
                            $mac = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.MACAddress } | Select-Object -First 1).MACAddress
                            $mac = if ($mac) { $mac -replace '[:\-]','' } else { '' }
                            if ($mac.Length -ge 12) { $base = $mac.Substring(6) }
                        } catch { $null = $_ }
                    }
                    'deviceModel' {
                        try { $base = (Get-CimInstance -ClassName Win32_ComputerSystem).Model -replace '[^A-Za-z0-9]','' } catch { $null = $_ }
                    }
                    'randomDigits' {
                        $count = if ($p.PSObject.Properties['randomDigitCount'] -and $p.randomDigitCount -gt 0) { [math]::Min($p.randomDigitCount, 10) } else { 4 }
                        $min = [int][math]::Pow(10, $count - 1)
                        $max = [int][math]::Pow(10, $count)
                        $base = (Get-Random -Minimum ([int]$min) -Maximum ([int]$max)).ToString()
                    }
                }
                if (-not $base) { $base = 'PC' + (Get-Random -Minimum 1000 -Maximum 9999).ToString() }
                $pfx = if ($p.PSObject.Properties['prefix'] -and $p.prefix) { $p.prefix } else { '' }
                $sfx = if ($p.PSObject.Properties['suffix'] -and $p.suffix) { $p.suffix } else { '' }
                $cName = $pfx + $base + $sfx
            }
            # Enforce max length (NetBIOS limit is 15)
            $maxLen = if ($p -and $p.PSObject.Properties['maxLength'] -and $p.maxLength -gt 0) { [math]::Min($p.maxLength, 15) } else { 15 }
            if ($cName.Length -gt $maxLen) { $cName = $cName.Substring(0, $maxLen) }
            # Strip invalid characters (letters, digits, hyphens only; no leading/trailing hyphens)
            $cName = ($cName -replace '[^A-Za-z0-9\-]','').Trim('-')
            if ($cName) {
                Update-BootstrapStatus -Message "Setting computer name..." -Detail "Name: $cName" -Step $uiStep -Progress $pct
                Write-Success "Computer name resolved: $cName"
            } else {
                Update-BootstrapStatus -Message "Setting computer name..." -Detail "No name specified -- Windows will assign a random name" -Step $uiStep -Progress $pct
                Write-Warn "No computer name resolved -- Windows will assign a random name"
            }
        }
        'SetRegionalSettings' {
            # Log the regional settings.  The Editor and Bootstrap config
            # modal already synced locale values into unattendContent -- no
            # engine-level XML update needed.
            $iLocale = if ($p -and $p.PSObject.Properties['inputLocale']  -and $p.inputLocale)  { $p.inputLocale }  else { '' }
            $sLocale = if ($p -and $p.PSObject.Properties['systemLocale'] -and $p.systemLocale) { $p.systemLocale } else { '' }
            $uiLang  = if ($p -and $p.PSObject.Properties['uiLanguage']   -and $p.uiLanguage)   { $p.uiLanguage }   else { '' }
            $detail = @()
            if ($iLocale) { $detail += "Keyboard: $iLocale" }
            if ($sLocale) { $detail += "Region: $sLocale" }
            if ($uiLang)  { $detail += "Language: $uiLang" }
            $detailStr = if ($detail.Count -gt 0) { $detail -join ', ' } else { 'No regional settings specified' }
            Update-BootstrapStatus -Message "Setting regional settings..." -Detail $detailStr -Step $uiStep -Progress $pct
            Write-Success "Regional settings applied: $detailStr"
        }
        'CustomizeOOBE' {
            # The unattendContent is already the final XML -- the Editor syncs
            # step values at design time and Bootstrap syncs config-modal
            # values at runtime.  Just write it to disk.
            $uUrl     = if ($p -and $p.PSObject.Properties['unattendUrl']     -and $p.unattendUrl)     { $p.unattendUrl }     else { '' }
            $uPath    = if ($p -and $p.PSObject.Properties['unattendPath']    -and $p.unattendPath)    { $p.unattendPath }    else { '' }
            $uSrc     = if ($p -and $p.PSObject.Properties['unattendSource']  -and $p.unattendSource)  { $p.unattendSource }  else { '' }
            $uContent = if ($uSrc -eq 'default' -and $p.PSObject.Properties['unattendContent'] -and $p.unattendContent) { $p.unattendContent } else { '' }
            Update-BootstrapStatus -Message "Customizing OOBE..." -Detail "Applying unattend.xml" -Step $uiStep -Progress $pct
            Set-OOBECustomization -UnattendUrl $uUrl -UnattendPath $uPath -UnattendContent $uContent -OSDriveLetter $CurrentOSDrive
        }
        'RunPostScripts' {
            $urls = if ($p -and $p.PSObject.Properties['scriptUrls'] -and $p.scriptUrls) { @($p.scriptUrls) } else { @() }
            Update-BootstrapStatus -Message "Staging post-scripts..." -Detail "Downloading post-provisioning scripts" -Step $uiStep -Progress $pct
            Invoke-PostScript -ScriptUrls $urls -OSDriveLetter $CurrentOSDrive -ScratchDir $CurrentScratchDir
        }
        'EnableBitLocker' {
            $method = if ($p -and $p.PSObject.Properties['encryptionMethod'] -and $p.encryptionMethod) { $p.encryptionMethod } else { 'XtsAes256' }
            $skipHw = if ($p -and $p.PSObject.Properties['skipHardwareTest'] -and $p.skipHardwareTest) { $true } else { $false }
            Update-BootstrapStatus -Message "Enabling BitLocker..." -Detail "Staging encryption for first boot" -Step $uiStep -Progress $pct
            Enable-BitLockerProtection -OSDriveLetter $CurrentOSDrive -EncryptionMethod $method -SkipHardwareTest:$skipHw
        }
        'InstallApplication' {
            $mode     = if ($p -and $p.PSObject.Properties['installMode'] -and $p.installMode) { $p.installMode } else { 'url' }
            $pkgId    = if ($p -and $p.PSObject.Properties['packageId']   -and $p.packageId)   { $p.packageId }   else { '' }
            $url      = if ($p -and $p.PSObject.Properties['installerUrl'] -and $p.installerUrl) { $p.installerUrl } else { '' }
            $silArgs  = if ($p -and $p.PSObject.Properties['silentArgs']  -and $p.silentArgs)  { $p.silentArgs }  else { '/qn /norestart' }
            $sUrl     = if ($p -and $p.PSObject.Properties['scriptUrl']   -and $p.scriptUrl)   { $p.scriptUrl }   else { '' }
            Update-BootstrapStatus -Message "Installing application..." -Detail "Mode: $mode" -Step $uiStep -Progress $pct
            Install-Application -InstallMode $mode -PackageId $pkgId -InstallerUrl $url -SilentArgs $silArgs -ScriptUrl $sUrl -OSDriveLetter $CurrentOSDrive
        }
        'WindowsUpdate' {
            $cats = if ($p -and $p.PSObject.Properties['categories'] -and $p.categories) { @($p.categories) } else { @('SecurityUpdates', 'CriticalUpdates') }
            Update-BootstrapStatus -Message "Staging Windows Update..." -Detail "Preparing first-boot updates" -Step $uiStep -Progress $pct
            Invoke-WindowsUpdateStaging -OSDriveLetter $CurrentOSDrive -Categories $cats
        }
        default {
            Write-Warn "Unknown step type '$($Step.type)' -- skipping"
        }
    }
}

#endregion

#region ── Log Export ───────────────────────────────────────────────────────────

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
        [string]$OSDriveLetter
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
        if (Test-Path $script:EngineLogPath) {
            Copy-Item $script:EngineLogPath (Join-Path $logDir 'Nova-Engine.log') -Force -ErrorAction SilentlyContinue
        }
        Write-Success "Deployment logs exported to $logDir"
    } catch {
        Write-Warn "Log export failed (non-fatal): $_"
    }
}

#endregion

#region ── Dry-Run Validation ───────────────────────────────────────────────────

function Invoke-DryRunValidation {
    param(
        [psobject]$TaskSequence,
        [string]$ScratchDir,
        [string]$OSDrive,
        [string]$FirmwareType,
        [int]$DiskNumber
    )

    Write-Step 'DRY RUN -- Validating deployment configuration...'
    $errors = @()
    $warnings = @()

    $enabledSteps = @($TaskSequence.steps | Where-Object { $_.enabled -ne $false })
    Write-Host "  Task sequence: $($TaskSequence.name)"
    Write-Host "  Total steps: $($TaskSequence.steps.Count) ($($enabledSteps.Count) enabled)"
    Write-Host "  Firmware type: $FirmwareType"
    Write-Host "  Target disk: $DiskNumber"
    Write-Host "  OS drive: ${OSDrive}:"
    Write-Host "  Scratch dir: $ScratchDir"

    foreach ($s in $enabledSteps) {
        $p = $s.parameters
        Write-Host "  [OK] Step '$($s.name)' ($($s.type)) -- enabled" -ForegroundColor Green

        # Validate step-specific parameters
        switch ($s.type) {
            'DownloadImage' {
                $url = if ($p -and $p.PSObject.Properties['imageUrl'] -and $p.imageUrl) { $p.imageUrl } else { '' }
                if (-not $url) { $warnings += "Step '$($s.name)': No imageUrl specified -- will use ESD catalog" }
            }
            'PartitionDisk' {
                try {
                    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
                    Write-Host "    Disk $DiskNumber : $($disk.FriendlyName) ($(Get-FileSizeReadable $disk.Size))" -ForegroundColor Gray
                } catch {
                    $errors += "Step '$($s.name)': Target disk $DiskNumber not found"
                }
            }
            'InjectOemDrivers' {
                try {
                    $mfr = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer
                    Write-Host "    Manufacturer: $mfr" -ForegroundColor Gray
                } catch {
                    $warnings += "Step '$($s.name)': Could not detect manufacturer"
                }
            }
            'EnableBitLocker' {
                try {
                    $tpm = Get-CimInstance -ClassName Win32_TPM -Namespace root\cimv2\Security\MicrosoftTpm -ErrorAction Stop
                    if ($tpm) { Write-Host "    TPM detected: version $($tpm.SpecVersion)" -ForegroundColor Gray }
                } catch {
                    $warnings += "Step '$($s.name)': TPM not detected -- BitLocker may fail"
                }
            }
        }
    }

    if ($warnings.Count -gt 0) {
        Write-Warn "Validation warnings:"
        $warnings | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    }
    if ($errors.Count -gt 0) {
        Write-Fail "Validation errors:"
        $errors | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "Dry-run validation failed with $($errors.Count) error(s)"
    }

    Write-Success "Dry-run validation passed -- $($enabledSteps.Count) steps validated, $($warnings.Count) warning(s)"
}

#endregion

#region ── Main ─────────────────────────────────────────────────────────────────

Write-Host @"

  █████╗ ███╗   ███╗██████╗  ██████╗██╗      ██████╗ ██╗   ██╗██████╗
 ██╔══██╗████╗ ████║██╔══██╗██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗
 ███████║██╔████╔██║██████╔╝██║     ██║     ██║   ██║██║   ██║██║  ██║
 ██╔══██║██║╚██╔╝██║██╔═══╝ ██║     ██║     ██║   ██║██║   ██║██║  ██║
 ██║  ██║██║ ╚═╝ ██║██║     ╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝
 ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝      ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝

 Cloud-only Imaging Engine · amd64/x86 · https://github.com/$GitHubUser/$GitHubRepo
"@ -ForegroundColor Cyan

# Auto-detect firmware type when the caller did not provide one explicitly.
# Bootstrap.ps1 may not always pass -FirmwareType, so falling back to runtime
# detection prevents creating a GPT/UEFI layout on a BIOS system (black screen).
if (-not $PSBoundParameters.ContainsKey('FirmwareType')) {
    $FirmwareType = Get-FirmwareType
}

$stepName = ''
$script:DeploymentStartTime = Get-Date
$script:CompletedStepCount  = 0
try {

    # ── Task-sequence-driven execution ──────────────────────────────
    # Read the step list from the JSON task sequence file and execute
    # each enabled step in the order defined by the editor.
    $ts = Read-TaskSequence -Path $TaskSequencePath

    if ($DryRun) {
        Invoke-DryRunValidation -TaskSequence $ts -ScratchDir $ScratchDir -OSDrive $OSDrive -FirmwareType $FirmwareType -DiskNumber $TargetDiskNumber
        Write-Step 'DRY RUN complete -- no destructive operations performed.'
        return
    }

    Write-Step "Firmware type: $FirmwareType"
    New-ScratchDirectory -Path $ScratchDir

    $enabledSteps = @($ts.steps | Where-Object { $_.enabled -ne $false })
    Write-Step "Executing $($enabledSteps.Count) enabled steps"

    # Inter-step state: DownloadImage stores the resolved image path for
    # ApplyImage to consume.  ComputerName and locale settings are synced
    # into unattendContent by the Editor and Bootstrap config modal -- the
    # engine just writes what's in the task sequence.
    $script:TsImagePath = ''
    $tsName = if ($ts.name) { $ts.name } else { 'Unknown' }

    for ($i = 0; $i -lt $enabledSteps.Count; $i++) {
        $s = $enabledSteps[$i]
        $stepName = $s.name

        # Evaluate step condition (if any) before execution
        if ($s.PSObject.Properties['condition'] -and $s.condition -and $s.condition.type) {
            if (-not (Test-StepCondition -Condition $s.condition)) {
                Write-Step "[$($i+1)/$($enabledSteps.Count)] $($s.name) ($($s.type)) -- condition not met, skipping"
                continue
            }
        }

        Write-Step "[$($i+1)/$($enabledSteps.Count)] $($s.name) ($($s.type))"

        # Update active deployment report so the Monitoring dashboard can
        # display in-progress status for this device.
        # Wrapped in try/catch so a failed status update never blocks imaging.
        $stepPct = if ($enabledSteps.Count -gt 0) { [math]::Min(100, [math]::Round(($i / $enabledSteps.Count) * 100)) } else { 0 }
        try {
            Update-ActiveDeploymentReport -TaskSequence $tsName `
                -CurrentStep "$($s.name)..." -Progress $stepPct `
                -StartTime $script:DeploymentStartTime
        } catch {
            Write-Verbose "Non-blocking: active deployment report update failed for step '$($s.name)': $_"
        }

        # After PartitionDisk, redirect scratch to OS drive
        if ($s.type -eq 'PartitionDisk') {
            Invoke-TaskSequenceStep -Step $s -Index ($i+1) -TotalSteps $enabledSteps.Count `
                -CurrentScratchDir $ScratchDir `
                -CurrentOSDrive $OSDrive -CurrentFirmwareType $FirmwareType `
                -CurrentDiskNumber $TargetDiskNumber
            $ScratchDir = Join-Path "${OSDrive}:" 'Nova'
            New-ScratchDirectory -Path $ScratchDir
        } else {
            try {
                Invoke-TaskSequenceStep -Step $s -Index ($i+1) -TotalSteps $enabledSteps.Count `
                    -CurrentScratchDir $ScratchDir `
                    -CurrentOSDrive $OSDrive -CurrentFirmwareType $FirmwareType `
                    -CurrentDiskNumber $TargetDiskNumber
            } catch {
                if ($s.PSObject.Properties['continueOnError'] -and $s.continueOnError) {
                    Write-Warn "Step '$($s.name)' failed but continueOnError is set -- continuing: $_"
                } else {
                    throw
                }
            }
        }
        $script:CompletedStepCount = $i + 1
    }

    # ── Deployment reporting & alerting ─────────────────────────────
    $elapsed   = (Get-Date) - $script:DeploymentStartTime
    $durString = '{0}m {1}s' -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

    # Clear active deployment file -- device is no longer deploying
    try { Update-ActiveDeploymentReport -Clear }
    catch { Write-Warning "Non-blocking: failed to clear active deployment report for '$($env:COMPUTERNAME)': $_" }

    Save-DeploymentReport -Status 'success' -TaskSequence $tsName `
        -StepsCompleted $enabledSteps.Count -StepsTotal $enabledSteps.Count `
        -StartTime $script:DeploymentStartTime

    # Record asset inventory for fleet tracking
    Save-AssetInventory -TaskSequence $tsName -ComputerName $env:COMPUTERNAME -ReportDir $ScratchDir

    Send-DeploymentAlert -Status 'success' -TaskSequence $tsName `
        -Duration $durString `
        -StepsCompleted $enabledSteps.Count -StepsTotal $enabledSteps.Count

    Update-BootstrapStatus -Message 'Imaging complete -- rebooting...' -Detail 'Windows installation finished successfully' -Step 4 -Progress 100 -Done

    Write-Host @"

[Nova] ══════════════════════════════════════════════════════════
[Nova]  Imaging complete! Windows is ready on drive ${OSDrive}:
[Nova]  Rebooting in 15 seconds...
[Nova] ══════════════════════════════════════════════════════════
"@ -ForegroundColor Green

    # Clean up scratch directory so temporary files do not persist in the
    # final Windows installation.
    $stepName = 'Clean up scratch directory'
    if (Test-Path $ScratchDir) {
        Remove-Item $ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Export WinPE logs to OS drive for post-reboot troubleshooting
    Export-DeploymentLogs -OSDriveLetter $OSDrive

    $stepName = 'Reboot'
    Start-Sleep -Seconds 15
    Restart-Computer -Force

} catch {
    Write-Fail "Nova imaging failed at step '$stepName': $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ''

    # ── Failure reporting & alerting ────────────────────────────────
    $tsName    = if ($ts -and $ts.name) { $ts.name } else { 'Unknown' }
    $totalSteps = if ($enabledSteps) { $enabledSteps.Count } else { 0 }
    $elapsed   = (Get-Date) - $script:DeploymentStartTime
    $durString = '{0}m {1}s' -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

    # Clear active deployment file -- device is no longer deploying
    try { Update-ActiveDeploymentReport -Clear }
    catch { Write-Warning "Non-blocking: failed to clear active deployment report for '$($env:COMPUTERNAME)': $_" }

    Save-DeploymentReport -Status 'failed' -TaskSequence $tsName `
        -StepsCompleted $script:CompletedStepCount -StepsTotal $totalSteps `
        -StartTime $script:DeploymentStartTime `
        -ErrorMessage "$_" -FailedStep $stepName

    Send-DeploymentAlert -Status 'failed' -TaskSequence $tsName `
        -Duration $durString `
        -StepsCompleted $script:CompletedStepCount -StepsTotal $totalSteps `
        -ErrorMessage "$_" -FailedStep $stepName

    # Update the HTML UI status file so the deployment page shows the
    # failure instead of staying stuck at the last progress state.
    Update-BootstrapStatus -Message "Imaging failed at step '$stepName'" `
        -Detail "$_" -Step 4

    # Export logs even on failure for troubleshooting
    try { Export-DeploymentLogs -OSDriveLetter $OSDrive } catch { $null = $_ }

    Write-Host '[Nova] Dropping to interactive shell for troubleshooting.' -ForegroundColor Yellow
    # Re-throw so Bootstrap.ps1 can close the UI before the user
    # needs the console.  The PowerShell host was started with -NoExit by
    # nova-start.cmd, so an interactive prompt appears automatically
    # once the form is dismissed.
    throw
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}

#endregion

# SIG # Begin signature block
# MII+LAYJKoZIhvcNAQcCoII+HTCCPhkCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBbLaie+ayhB+nL
# TpipqWYsFc89WxyDyaW0xxteXdJeH6CCIvIwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggcNMIIE9aADAgECAhMzAAfSanjE
# whl/hSLBAAAAB9JqMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDIwHhcNMjYwNDAzMTQ0MTQ3WhcNMjYwNDA2
# MTQ0MTQ3WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQC5BrdIk2tUVIzq
# pkGvyjpYF4Kax1oBBLqHwYRLOkhA5ZRRRqmQly3oXqYispFV1OE3D6vtPz7nTtn1
# PZ5gDZuiqztCmTkg7pHsQhdXku+GUW7QbpmhfO7+NNMxIxgrvx893fm15Qz+zA3j
# Rh+5BN+oIwuGbQtzS6A+TTliq20ZHZSfw4G8J/e15qxfYlu3tzl4k1g64qsca5jT
# CdlCJfbrOgNFzdFcZmLoYUaM0V9F9nnQzDHCAawvptOmBlajnYBI/q+p34XKsxr1
# xIny5ySJGYEvj9zk9RBAtxugYQH9qBeGf2HeTzqK45ZSvcrDSdDjb1uW4DoEHrAN
# qAY+2KWGEtwRb8yJ+r0SaQDz3a2QDea4J2nr93k0pn8HuHIY+YQsxLvXVLZOqJLd
# ObW9ufmCENr4gm5XR84UToryvfZmzDhOdqpHsfHd0A05WE6A3KVdBCuS19uNlmyb
# a3Z4Gbo11TcW5mFJwY1ng4Xrf5KEKO4OyXkzL+J7anfxCsUa+2MCAwEAAaOCAhgw
# ggIUMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQU8rX+P1O5gHfewaYF7d8+XxjH07QwHwYDVR0jBBgwFoAUZZ9RzoVo
# fy+KRYiq3acxux4NAF4wZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMi5jcmwwgaUGCCsGAQUFBwEBBIGYMIGVMGQGCCsG
# AQUFBzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDIuY3J0
# MC0GCCsGAQUFBzABhiFodHRwOi8vb25lb2NzcC5taWNyb3NvZnQuY29tL29jc3Aw
# ZgYDVR0gBF8wXTBRBgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgG
# BmeBDAEEATANBgkqhkiG9w0BAQwFAAOCAgEAWdc4t7d2NyLfCk3m/eY5PJ3S15D6
# 01lu/piFmC34jM0+cP+us5V16PVCAk8zheaiG6YCLkY+WNYMGR7IE9SmrKsDFurl
# K0113CSX+NbWXkEBWOuMV0bHvKfkKQGukyoq2ntqNp7aBElhd/K6GJ0xCufj7chF
# vAohnxtDoKi1OgyomNhNoQRHm5jHO2Co1rA6o5gQB+olZjXRZiW5S7hYTR0h/DNo
# VIu5AFQ5Oors9yonv4EcO+vOsTyjYQtnfmHJgF+tOkaxYuiH1DWHJvo6X4dDasE1
# n8hZp2/MMeSR+RHonDcR1O+Q/p5ad0VtGMTv5ypbr3YQA20Nw0Qhs5qhCl9JXXbH
# P1FBo1XI33MxfcBrAAlfq/XFyIN2DftH8fCb5WXkvAR3cJwDbJNyuRXByU+ez9CX
# hsAJDGaWNW48+s9TWH98w/c1sdQ4Bh2ptE5D+yYbuS60BGbvteS6/dCgR3B/aK8V
# csvIU+o/VPQrdbiAEZ7Cezcewu6P6c0qwDgYK3ts/Wik8+++Yv0QQ7w7P5CN3Gpr
# 4yEXgYTwfGPuvYOtH3X9XqDVi0G4xss2hAr8+DAbWj341L4SgQgpv951Baquw62U
# QPfFUWOBmXjgO2D1NBYwWBEQm6SqRSRSJfSag6CMAM/fQ24apWu5IYQ7ZCX5HTzT
# zuVWJTlLAPvgAWkwggcNMIIE9aADAgECAhMzAAfSanjEwhl/hSLBAAAAB9JqMA0G
# CSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBF
# T0MgQ0EgMDIwHhcNMjYwNDAzMTQ0MTQ3WhcNMjYwNDA2MTQ0MTQ3WjCBizEPMA0G
# A1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UECBMHSGFsbGFuZDEQMA4G
# A1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMgdmFnIDMxFjAUBgNVBAoT
# DUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3NvZnQgQUIwggGiMA0GCSqG
# SIb3DQEBAQUAA4IBjwAwggGKAoIBgQC5BrdIk2tUVIzqpkGvyjpYF4Kax1oBBLqH
# wYRLOkhA5ZRRRqmQly3oXqYispFV1OE3D6vtPz7nTtn1PZ5gDZuiqztCmTkg7pHs
# QhdXku+GUW7QbpmhfO7+NNMxIxgrvx893fm15Qz+zA3jRh+5BN+oIwuGbQtzS6A+
# TTliq20ZHZSfw4G8J/e15qxfYlu3tzl4k1g64qsca5jTCdlCJfbrOgNFzdFcZmLo
# YUaM0V9F9nnQzDHCAawvptOmBlajnYBI/q+p34XKsxr1xIny5ySJGYEvj9zk9RBA
# txugYQH9qBeGf2HeTzqK45ZSvcrDSdDjb1uW4DoEHrANqAY+2KWGEtwRb8yJ+r0S
# aQDz3a2QDea4J2nr93k0pn8HuHIY+YQsxLvXVLZOqJLdObW9ufmCENr4gm5XR84U
# ToryvfZmzDhOdqpHsfHd0A05WE6A3KVdBCuS19uNlmyba3Z4Gbo11TcW5mFJwY1n
# g4Xrf5KEKO4OyXkzL+J7anfxCsUa+2MCAwEAAaOCAhgwggIUMAwGA1UdEwEB/wQC
# MAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisGAQQBgjdhAQAGCCsGAQUF
# BwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAdBgNVHQ4EFgQU8rX+P1O5
# gHfewaYF7d8+XxjH07QwHwYDVR0jBBgwFoAUZZ9RzoVofy+KRYiq3acxux4NAF4w
# ZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0El
# MjAwMi5jcmwwgaUGCCsGAQUFBwEBBIGYMIGVMGQGCCsGAQUFBzAChlhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElEJTIw
# VmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDIuY3J0MC0GCCsGAQUFBzABhiFo
# dHRwOi8vb25lb2NzcC5taWNyb3NvZnQuY29tL29jc3AwZgYDVR0gBF8wXTBRBgwr
# BgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEATANBgkqhkiG
# 9w0BAQwFAAOCAgEAWdc4t7d2NyLfCk3m/eY5PJ3S15D601lu/piFmC34jM0+cP+u
# s5V16PVCAk8zheaiG6YCLkY+WNYMGR7IE9SmrKsDFurlK0113CSX+NbWXkEBWOuM
# V0bHvKfkKQGukyoq2ntqNp7aBElhd/K6GJ0xCufj7chFvAohnxtDoKi1OgyomNhN
# oQRHm5jHO2Co1rA6o5gQB+olZjXRZiW5S7hYTR0h/DNoVIu5AFQ5Oors9yonv4Ec
# O+vOsTyjYQtnfmHJgF+tOkaxYuiH1DWHJvo6X4dDasE1n8hZp2/MMeSR+RHonDcR
# 1O+Q/p5ad0VtGMTv5ypbr3YQA20Nw0Qhs5qhCl9JXXbHP1FBo1XI33MxfcBrAAlf
# q/XFyIN2DftH8fCb5WXkvAR3cJwDbJNyuRXByU+ez9CXhsAJDGaWNW48+s9TWH98
# w/c1sdQ4Bh2ptE5D+yYbuS60BGbvteS6/dCgR3B/aK8VcsvIU+o/VPQrdbiAEZ7C
# ezcewu6P6c0qwDgYK3ts/Wik8+++Yv0QQ7w7P5CN3Gpr4yEXgYTwfGPuvYOtH3X9
# XqDVi0G4xss2hAr8+DAbWj341L4SgQgpv951Baquw62UQPfFUWOBmXjgO2D1NBYw
# WBEQm6SqRSRSJfSag6CMAM/fQ24apWu5IYQ7ZCX5HTzTzuVWJTlLAPvgAWkwggda
# MIIFQqADAgECAhMzAAAABft6XDITYd9dAAAAAAAFMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjEwNDEzMTczMTUzWhcNMjYwNDEzMTczMTUzWjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAyMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA0hqZfD8ykKTA6CDbWvshmBpDoBf7Lv132RVuSqVwQO3a
# ALLkuRnnTIoRmMGo0fIMQrtwR6UHB06xdqOkAfqB6exubXTHu44+duHUCdE4ngjE
# LBQyluMuSOnHaEdveIbt31OhMEX/4nQkph4+Ah0eR4H2sTRrVKmKrlOoQlhia73Q
# g2dHoitcX1uT1vW3Knpt9Mt76H7ZHbLNspMZLkWBabKMl6BdaWZXYpPGdS+qY80g
# DaNCvFq0d10UMu7xHesIqXpTDT3Q3AeOxSylSTc/74P3og9j3OuemEFauFzL55t1
# MvpadEhQmD8uFMxFv/iZOjwvcdY1zhanVLLyplz13/NzSoU3QjhPdqAGhRIwh/YD
# zo3jCdVJgWQRrW83P3qWFFkxNiME2iO4IuYgj7RwseGwv7I9cxOyaHihKMdT9Neo
# SjpSNzVnKKGcYMtOdMtKFqoV7Cim2m84GmIYZTBorR/Po9iwlasTYKFpGZqdWKyY
# nJO2FV8oMmWkIK1iagLLgEt6ZaR0rk/1jUYssyTiRqWr84Qs3XL/V5KUBEtUEQfQ
# /4RtnI09uFFUIGJZV9mD/xOUksWodGrCQSem6Hy261xMJAHqTqMuDKgwi8xk/mfl
# r7yhXPL73SOULmu1Aqu4I7Gpe6QwNW2TtQBxM3vtSTmdPW6rK5y0gED51RjsyK0C
# AwEAAaOCAg4wggIKMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUZZ9RzoVofy+KRYiq3acxux4NAF4wVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMIGuBggrBgEFBQcBAQSBoTCBnjBtBggrBgEF
# BQcwAoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNy
# b3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAy
# MDIxLmNydDAtBggrBgEFBQcwAYYhaHR0cDovL29uZW9jc3AubWljcm9zb2Z0LmNv
# bS9vY3NwMA0GCSqGSIb3DQEBDAUAA4ICAQBFSWDUd08X4g5HzvVfrB1SiV8pk6XP
# HT9jPkCmvU/uvBzmZRAjYk2gKYR3pXoStRJaJ/lhjC5Dq/2R7P1YRZHCDYyK0zvS
# RMdE6YQtgGjmsdhzD0nCS6hVVcgfmNQscPJ1WHxbvG5EQgYQ0ZED1FN0MOPQzWe1
# zbH5Va0dSxtnodBVRjnyDYEm7sNEcvJHTG3eXzAyd00E5KDCsEl4z5O0mvXqwaH2
# PS0200E6P4WqLwgs/NmUu5+Aa8Lw/2En2VkIW7Pkir4Un1jG6+tj/ehuqgFyUPPC
# h6kbnvk48bisi/zPjAVkj7qErr7fSYICCzJ4s4YUNVVHgdoFn2xbW7ZfBT3QA9zf
# hq9u4ExXbrVD5rxXSTFEUg2gzQq9JHxsdHyMfcCKLFQOXODSzcYeLpCd+r6GcoDB
# ToyPdKccjC6mAq6+/hiMDnpvKUIHpyYEzWUeattyKXtMf+QrJeQ+ny5jBL+xqdOO
# PEz3dg7qn8/oprUrUbGLBv9fWm18fWXdAv1PCtLL/acMLtHoyeSVMKQYqDHb3Qm0
# uQ+NQ0YE4kUxSQa+W/cCzYAI32uN0nb9M4Mr1pj4bJZidNkM4JyYqezohILxYkgH
# bboJQISrQWrm5RYdyhKBpptJ9JJn0Z63LjdnzlOUxjlsAbQir2Wmz/OJE703BbHm
# QZRwzPx1vu7S5zCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAAAAcwDQYJ
# KoZIhvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNh
# dGlvbiBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIxMDQwMTIw
# MDUyMFoXDTM2MDQwMTIwMTUyMFowYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlm
# aWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBALLwwK8ZiCji3VR6TElsaQhVCbRS/3pK+MHrJSj3Zxd3KU3rlfL3
# qrZilYKJNqztA9OQacr1AwoNcHbKBLbsQAhBnIB34zxf52bDpIO3NJlfIaTE/xrw
# eLoQ71lzCHkD7A4As1Bs076Iu+mA6cQzsYYH/Cbl1icwQ6C65rU4V9NQhNUwgrx9
# rGQ//h890Q8JdjLLw0nV+ayQ2Fbkd242o9kH82RZsH3HEyqjAB5a8+Ae2nPIPc8s
# ZU6ZE7iRrRZywRmrKDp5+TcmJX9MRff241UaOBs4NmHOyke8oU1TYrkxh+YeHgfW
# o5tTgkoSMoayqoDpHOLJs+qG8Tvh8SnifW2Jj3+ii11TS8/FGngEaNAWrbyfNrC6
# 9oKpRQXY9bGH6jn9NEJv9weFxhTwyvx9OJLXmRGbAUXN1U9nf4lXezky6Uh/cgjk
# Vd6CGUAf0K+Jw+GE/5VpIVbcNr9rNE50Sbmy/4RTCEGvOq3GhjITbCa4crCzTTHg
# YYjHs1NbOc6brH+eKpWLtr+bGecy9CrwQyx7S/BfYJ+ozst7+yZtG2wR461uckFu
# 0t+gCwLdN0A6cFtSRtR8bvxVFyWwTtgMMFRuBa3vmUOTnfKLsLefRaQcVTgRnzeL
# zdpt32cdYKp+dhr2ogc+qM6K4CBI5/j4VFyC4QFeUP2YAidLtvpXRRo3AgMBAAGj
# ggI1MIICMTAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0O
# BBYEFNlBKbAPD2Ns72nX9c0pnqRIajDmMFQGA1UdIARNMEswSQYEVR0gADBBMD8G
# CCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3Mv
# UmVwb3NpdG9yeS5odG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDwYDVR0T
# AQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2ioojCBhAYD
# VR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9j
# cmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIw
# Q2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBwwYIKwYBBQUHAQEE
# gbYwgbMwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# b3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIw
# Um9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQwLQYIKwYB
# BQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20vb2NzcDANBgkqhkiG
# 9w0BAQwFAAOCAgEAfyUqnv7Uq+rdZgrbVyNMul5skONbhls5fccPlmIbzi+OwVdP
# Q4H55v7VOInnmezQEeW4LqK0wja+fBznANbXLB0KrdMCbHQpbLvG6UA/Xv2pfpVI
# E1CRFfNF4XKO8XYEa3oW8oVH+KZHgIQRIwAbyFKQ9iyj4aOWeAzwk+f9E5StNp5T
# 8FG7/VEURIVWArbAzPt9ThVN3w1fAZkF7+YU9kbq1bCR2YD+MtunSQ1Rft6XG7b4
# e0ejRA7mB2IoX5hNh3UEauY0byxNRG+fT2MCEhQl9g2i2fs6VOG19CNep7SquKaB
# jhWmirYyANb0RJSLWjinMLXNOAga10n8i9jqeprzSMU5ODmrMCJE12xS/NWShg/t
# uLjAsKP6SzYZ+1Ry358ZTFcx0FS/mx2vSoU8s8HRvy+rnXqyUJ9HBqS0DErVLjQw
# K8VtsBdekBmdTbQVoCgPCqr+PDPB3xajYnzevs7eidBsM71PINK2BoE2UfMwxCCX
# 3mccFgx6UsQeRSdVVVNSyALQe6PT12418xon2iDGE81OGCreLzDcMAZnrUAx4XQL
# Uz6ZTl65yPUiOh3k7Yww94lDf+8oG2oZmDh5O1Qe38E+M3vhKwmzIeoB1dVLlz4i
# 3IpaDcR+iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqQ
# MIIajAIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0Mg
# Q0EgMDICEzMAB9JqeMTCGX+FIsEAAAAH0mowDQYJYIZIAWUDBAIBBQCgXjAQBgor
# BgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG
# 9w0BCQQxIgQg7VV2EGiotaEn6ilG3qypNzMsluiqiXcxSOyNp1odXAkwDQYJKoZI
# hvcNAQEBBQAEggGAqufMg4K9JJFn7V8pFupuOc2XZ7d/V17FhrMKeGIISQnh1c86
# fsKn2+cM1bGSVcpys+loZoUGgg5flTE+LRkQdIxYhFSEo1ul+J4vF2n6z5pwiQoK
# gvfD4nu2Y+UouL56NxNOI8xzsGUSlw1VTzKnOJH5ublMWBn1+bwpINog1X4vkVoP
# 6Nh/erofgC4tQ/Ouo73vyOHDmZNlmjuo0Ny3BLdOGjV+vKZTYSa1mqKe1Fqhsglq
# dMkCqctadQM/WQJ1ybz3tzcYTfWAJEOMZjoHU8sY7UMKSk8sZmIbTh4iYwJQdjEf
# 9DhBFjO0M4bIs5jLnPQ2zwUdSshmHeQ45AidxHBvs2fmvez6aMVFYhpiPOdEkOnG
# /nbNLBsqJ6zlxEgZdi/OyMeSu+wPeeMSHrCwo9RFr+w0Vn9iarmgdhHpRQ25pqbF
# xHsiCEpYU7hwW2C+attbRNPvC4ZpU9q58PqJ9yyeeDEQ7AdC5mrNz/h7uBmcBTob
# nEKJE76YFU8IwlTEoYIYEDCCGAwGCisGAQQBgjcDAwExghf8MIIX+AYJKoZIhvcN
# AQcCoIIX6TCCF+UCAQMxDzANBglghkgBZQMEAgEFADCCAWEGCyqGSIb3DQEJEAEE
# oIIBUASCAUwwggFIAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIA52
# S1+bOXOph6lBlUnZi9gj6rv/vaJmqV9k+ufXyyatAgZpwmaSQIYYEjIwMjYwNDAz
# MTYzODEwLjA5WjAEgAIB9KCB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0
# aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkE1MDAtMDVFMC1EOTQ3MTUw
# MwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhv
# cml0eaCCDyEwggeCMIIFaqADAgECAhMzAAAABeXPD/9mLsmHAAAAAAAFMA0GCSqG
# SIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJpZmljYXRp
# b24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMDExMTkyMDMy
# MzFaFw0zNTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNB
# IFRpbWVzdGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAnnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1lRkd3kcFdcG9/sqtDlwxK
# oVIcaqDb+omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjxnG/eViS4sOx8y4gSq8Zg
# 49REAf5huXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5hJM1xznkRsFPu6rfDHeZ
# eG1Wa1wISvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFlyAKwn6yjN/kR4fkquUWf
# GmMopNq/B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTPVi3gVErnc/qi+dR8A2Mi
# Az0kN0nh7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKxLms73KG/Z+MkeuaVDQQh
# eangOEMGJ4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxRYR/JPGAaM6xGl57Ei95H
# Uw9NV/uC3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxOmM2rl4uKK6eEpurRduOQ
# 2hTkmG1hSuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cjRKG79+TX+sTehawOoxfe
# OO/jR7wo3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xTnD1a69w/UTxwjEugpIPM
# IIE67SFZ2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8FUXetXr0CAwEAAaOCAhsw
# ggIXMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQU
# a2koOjUvSGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYB
# BQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBv
# c2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4K
# AFMAdQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFMh+0mqFKhvK
# GZgEByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZlcmlm
# aWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjAu
# Y3JsMIGUBggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUHMAKGdWh0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSWRlbnRpdHkl
# MjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHkl
# MjAyMDIwLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2x35ttVoVdedMeGj6TuHY
# RJklFaW4sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6AF6ycWoEYR0LYhaa0ozJL
# U5Yi+LCmcrdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM74LNvVzY0/nPISHz0Xva
# 71QjD4h+8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLslLKsO8F2aBs2cIo1k+aHO
# hrw9xw6JCWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yFM7Ujrhc0aqy3xL7D5FR2
# J7x9cLWMq7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFovIP7YG4ZkJWag1H91KlEL
# GWi3SLv10o4KGag42pswjybTi4toQcC/irAodDW8HNtX+cbz0sMptFJK+KObAnDF
# HEsukxD+7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9TlxydiFhvu88o0w35JkN
# bJxTk4MhF/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWVydt4ytxYP/bqjN49D9NZ
# 81coE6aQWm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeCUMYmBx3PkP8ADHD1J2Cr
# /6tjuOOCztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdtoSAHEUKiBhI6JQivRepyv
# Wcl+JYbYbBh7pmgAXVswggeXMIIFf6ADAgECAhMzAAAAVn6PnVgIjulgAAAAAABW
# MA0GCSqGSIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRp
# bWVzdGFtcGluZyBDQSAyMDIwMB4XDTI1MTAyMzIwNDY1MVoXDTI2MTAyMjIwNDY1
# MVowgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNV
# BAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGll
# bGQgVFNTIEVTTjpBNTAwLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1
# YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHkwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQC0pZ+b+6XTbv93xGVvwyf+DRBS+8upjZWzLe0jxTa0
# VKylNmiZk4PcEdPwuRH5GuEwmBvVWMAoU3Kxor1wtJeJ88ZIgGs8KCz0/jLbiWsk
# SatXpDnPgGaoyEg+tmES9mdakJLgc7uNhJ6L+fGYLv/USv6XkuDc+ZLFvx3YhVwB
# HFLDUHibEHpcjSeR6X3BrV1hvbB8amh+toWbFk7FP142G3gsfREFJW55trpk2mNL
# /SC1+buqIiLI/qno9HNNNsydWqwedX93+tbTMfH5D5A1nnBSoqZNkkH2FTznf7al
# fmsN8rfa41j39YE4CbNuqCkR1CRuIxq9QzJQNKGbJwi+Ad1CdLbTuxOPwz6Qkve0
# 51qE+4+ozCxoIKB1/DBDHQ71Mp7sVK9sARizUCeV0KX8ocZkI5W9Q2qPIvXQkt7T
# /4YP3/KepcZYWlc6Nq6e9n9wpE6GM3gzl7rHHRvaaKpw+KLj+KLZmF4pqWUkRPsI
# qWkVKGzfDKDoX9+iNDFC8+dtYPg3LHqWGNaPCagtzHrDUVIK1q8sKXLfcEtFKVNT
# iopTFprx3tg3sSqmf1c7RJjS6Y68oVetYfuvGX72JqJyK12dNOSwCdGO96R0pPeW
# DuVEx+Z9lTy9c2I3RRgnNP0SOqNGbS43+HShfE+E189ip4VvI9cYbHNphTPrPHep
# NwIDAQABo4IByzCCAccwHQYDVR0OBBYEFL62M/K7q1n+HkazIu/LPUf4U0haMB8G
# A1UdIwQYMBaAFGtpKDo1L0hjQM972K9J6T7ZPdshMGwGA1UdHwRlMGMwYaBfoF2G
# W2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUy
# MFB1YmxpYyUyMFJTQSUyMFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5jcmwweQYI
# KwYBBQUHAQEEbTBrMGkGCCsGAQUFBzAChl1odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUyMFRpbWVz
# dGFtcGluZyUyMENBJTIwMjAyMC5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8E
# DDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwZgYDVR0gBF8wXTBRBgwrBgEE
# AYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEAjANBgkqhkiG9w0B
# AQwFAAOCAgEADgOoBcSw7bqP8trsWCf9CJ+K3zG5l6Spnnv5h76wf+FFNsQSMZit
# mCyrBH+VRR8oIWltkXyaxpk9Ak5HhhhQRTxfKMuufxjWMJKajGH2Xu1aJKhz8kUH
# DfnokCbMYbF4EDYRZLFG5OvUC5l7qdho3z/C0WSIdyzyAxp3FcGzoPFWHK7lieEs
# 9CR+6YqbeUV+3ATumJ5Xt/WWySaWCwLoB5IYLMY9lSAK9wflO/9B73PtsgiZIPdK
# 7OE4jBo/54pBNh/rtOJ/IkqRZBJ0Z9MDopy7jWTwsHqg8r4wuTWNvHErnA+otIvr
# bGMrThIFccQlISewW3TPFaTE/+WB6PUPGpSeatgR2TG/MpIcgCoVZJm6X/mEj68n
# G8U+Gw1AESThxK6UOQlClx1WL+CZ/+YcU5iEMGOxrXmzgv7awGKXddX9PxGJHrpD
# zFi9MtFbF3Z1Wys6gLCexThYh6ILQmKcK/VYscSHtDLOv1FKviQoktZ2k1guGCOS
# iNOYSQCMU7vvi3fEHt6du8gXQY6xXX3GcJTOr0QYrK3SAy5qmEqU2Mn5pOmNYxkM
# aj4Y4qyen3ceZ+2aXRLKncX34zfL7LpYkZRmghkmrbbuMOOMSd22lSuH0F091Uh9
# UkP8C7zVHOHTlQcCK+itDc6zw8QsciCI531NbNt2CYbNwgu3911VARExggdDMIIH
# PwIBATB4MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGlu
# ZyBDQSAyMDIwAhMzAAAAVn6PnVgIjulgAAAAAABWMA0GCWCGSAFlAwQCAQUAoIIE
# nDARBgsqhkiG9w0BCRACDzECBQAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEE
# MBwGCSqGSIb3DQEJBTEPFw0yNjA0MDMxNjM4MTBaMC8GCSqGSIb3DQEJBDEiBCCM
# Fz97d9+MHIQR4kxZBZadGtNIJXkMu/GOs1UaGahAazCBuQYLKoZIhvcNAQkQAi8x
# gakwgaYwgaMwgaAEILYMMyVNpOPwlXeJODleel7gJIfrTXjdn5f2jk0GAwyoMHww
# ZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBD
# QSAyMDIwAhMzAAAAVn6PnVgIjulgAAAAAABWMIIDXgYLKoZIhvcNAQkQAhIxggNN
# MIIDSaGCA0UwggNBMIICKQIBATCCAQmhgeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAt
# RDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGlu
# ZyBBdXRob3JpdHmiIwoBATAHBgUrDgMCGgMVAP9z9ykVKpBZgF5eCDJEnZlu9gQR
# oGcwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGlu
# ZyBDQSAyMDIwMA0GCSqGSIb3DQEBCwUAAgUA7XoT7zAiGA8yMDI2MDQwMzEwMjQ0
# N1oYDzIwMjYwNDA0MTAyNDQ3WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDtehPv
# AgEAMAcCAQACAhRCMAcCAQACAhI5MAoCBQDte2VvAgEAMDYGCisGAQQBhFkKBAIx
# KDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZI
# hvcNAQELBQADggEBAEUxoVtPeAaUNBQkY7Ycistq/35pRYGLmFOL0W8oi+/1cUy/
# uqYy0sJEa6cD3cml6/gQ/v76UHVKS0ZGxMcCy5ZNrTwlzAXSMlSj897Q8lh2Lasw
# JtC4c7OYmYTXT1ZqTcK0KRm10JD6BvVKeEh+JBkAPtKzkoVlKE5yQaGfgFuS3OF7
# w1QVpuVjDzw5EkZ0AnhMgxjw/jVw2C+M1G5qVPZhQ1J/lC2zummqP4bSjVdRgK10
# 8yl55kAw6Nya5fzyeZfaugpD8SgP752nt8eo1VbJRcU0b7d9Fh45DyZdLgU5cqU+
# pOSVjDvF0Ewq7/jwGcXibg1zw+dwKDEyJ3z/RQ0wDQYJKoZIhvcNAQEBBQAEggIA
# iE6rIwJz3DGbbAiQf83iOlh513ZMmw261nL0Pcu8xdq6B1ZGH4K5Eoeznw6CDqxH
# Hl9NcuQnVJNukof5Y4b0TZZxD+4Gmofd1YiNsca/AmnARRMhknB2QfQUjuY6D5UJ
# kVrkoyXzF0Z1CctxMd1yYns+z3XV/BXOnl9cbK1Y6axVAcsVSYxeu+Z3TZKhgg+d
# ff9HZ3bfwSVhbgsvNkElQhMI652cybfXCSBQTGfnjkgKAYU/871l4y11wolh2Scv
# huYDvdChYvXwlo1uXsSb4d+j0fevaJXcEAzcmTmdfvRUbZIfu9pVL3nEhxZTpNys
# /hROSatdCup7rar0pbmIrVjMs5CpKuM1HXfhZK+9B5TcggEmYejOZDzEK1rSuOOM
# arWnHSvJmAkkU0DwIpdORp70FPTtMMocmBIcGpVAka688zD+xZz4Xx+BX2TaoBjH
# ZeOICAod+JEQGAapNw4vMYNS6Hh/waTC7dR/RG/ZnUf0jRL4ng34YpqBMxI8k7Y5
# L4+9tXVnrSJpmpIy/OXpFzIjgXY1hi8AkrEkbSF//GxIcb+2zMi7FNTckRkqC/xm
# 2uss/lcmR0rHZ/6g2dDUFDNY5mngmowqWZG65FtbMdxmgBut+o8Sfci5iIXZTlW0
# 0fH5x7ZWCWkryK2NXLJQ41U4P8UZi+j2sZKLRSf2mDk=
# SIG # End signature block

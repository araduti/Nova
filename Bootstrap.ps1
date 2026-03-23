#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Bootstrap - Minimal WinPE network waiter and AmpCloud loader.

.DESCRIPTION
    Runs inside WinPE via winpeshl.ini. Waits for internet connectivity, then
    downloads and executes AmpCloud.ps1 directly from GitHub raw URLs.
    No local files beyond this script are needed.
#>

[CmdletBinding()]
param(
    [string]$GitHubUser   = 'araduti',
    [string]$GitHubRepo   = 'AmpCloud',
    [string]$GitHubBranch = 'main',
    [int]$MaxWaitSeconds  = 600,
    [int]$RetryInterval   = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helpers ──────────────────────────────────────────────────────────────

function Write-Status {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "[Bootstrap] $Message" -ForegroundColor $Color
}

function Test-InternetConnectivity {
    $testUrls = @(
        'https://raw.githubusercontent.com',
        'https://www.msftconnecttest.com/connecttest.txt',
        'https://clients3.google.com/generate_204'
    )
    foreach ($url in $testUrls) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($response.StatusCode -lt 400) { return $true }
        } catch {
            # Try next URL
        }
    }
    return $false
}

function Initialize-Network {
    Write-Status 'Initializing network...'
    # Start DHCP on all adapters
    try {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        foreach ($adapter in $adapters) {
            try {
                Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue
                Write-Status "DHCP enabled on: $($adapter.Name)"
            } catch {
                # Some adapters may not support this; continue
            }
        }
    } catch {
        Write-Status 'Could not enumerate adapters; relying on existing network config.' 'Yellow'
    }

    # Start DHCP client service if available
    try {
        $dhcpService = Get-Service -Name 'Dhcp' -ErrorAction SilentlyContinue
        if ($dhcpService -and $dhcpService.Status -ne 'Running') {
            Start-Service -Name 'Dhcp' -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Wait-ForInternet {
    param([int]$MaxWaitSeconds, [int]$RetryInterval)

    Write-Status 'Waiting for internet connectivity...'
    $elapsed = 0

    while ($elapsed -lt $MaxWaitSeconds) {
        if (Test-InternetConnectivity) {
            Write-Status 'Internet connectivity confirmed.' 'Green'
            return $true
        }
        Write-Status "No internet yet. Retrying in ${RetryInterval}s... ($elapsed/$MaxWaitSeconds s elapsed)" 'Yellow'
        Start-Sleep -Seconds $RetryInterval
        $elapsed += $RetryInterval
    }

    Write-Status "Internet not available after ${MaxWaitSeconds}s." 'Red'
    return $false
}

#endregion

#region ── Main ─────────────────────────────────────────────────────────────────

Write-Host @"

 [AmpCloud Bootstrap]
 GitHub: https://github.com/$GitHubUser/$GitHubRepo
 Loading cloud imaging engine...

"@ -ForegroundColor Cyan

# Initialize networking
Initialize-Network

# Wait for internet
if (-not (Wait-ForInternet -MaxWaitSeconds $MaxWaitSeconds -RetryInterval $RetryInterval)) {
    Write-Status 'ERROR: Cannot reach internet. Dropping to shell for manual troubleshooting.' 'Red'
    # Drop to interactive shell so the user can debug
    & cmd.exe /k
    exit 1
}

# Fetch and execute AmpCloud.ps1 from GitHub
$ampCloudUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/AmpCloud.ps1"
Write-Status "Fetching AmpCloud.ps1 from: $ampCloudUrl"

try {
    $script = Invoke-RestMethod -Uri $ampCloudUrl -UseBasicParsing -ErrorAction Stop
    Write-Status 'AmpCloud.ps1 downloaded. Executing...' 'Green'
    Invoke-Expression $script
} catch {
    Write-Status "ERROR: Failed to fetch AmpCloud.ps1: $_" 'Red'
    Write-Status 'Dropping to interactive shell for manual recovery.' 'Yellow'
    & cmd.exe /k
    exit 1
}

#endregion

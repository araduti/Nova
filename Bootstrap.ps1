#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Bootstrap - WinPE network setup and AmpCloud loader.

.DESCRIPTION
    Runs inside WinPE via winpeshl.ini.
    - Calls wpeinit.exe to initialise the WinPE network stack and DHCP.
    - Presents an Autopilot-style welcome screen.
    - Offers an interactive WiFi selector when wired internet is unavailable.
    - Downloads and executes AmpCloud.ps1 from GitHub once connected.
#>

[CmdletBinding()]
param(
    [string]$GitHubUser   = 'araduti',
    [string]$GitHubRepo   = 'AmpCloud',
    [string]$GitHubBranch = 'main',
    [int]$MaxWaitSeconds  = 300,
    [int]$RetryInterval   = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── UI ────────────────────────────────────────────────────────────────────

function Show-WelcomeBanner {
    try { $Host.UI.RawUI.BackgroundColor = 'DarkBlue' } catch { }
    Clear-Host
    Write-Host ''
    Write-Host '  ╔══════════════════════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '  ║                                                                              ║' -ForegroundColor Cyan
    Write-Host '  ║                           A M P C L O U D                                   ║' -ForegroundColor White
    Write-Host '  ║                         Cloud Imaging Engine                                 ║' -ForegroundColor Cyan
    Write-Host '  ║                                                                              ║' -ForegroundColor Cyan
    Write-Host '  ╠══════════════════════════════════════════════════════════════════════════════╣' -ForegroundColor Cyan
    Write-Host "  ║                                                                              ║" -ForegroundColor Cyan
    Write-Host "  ║    Hi there!  Let's get this device set up for cloud imaging.               ║" -ForegroundColor White
    Write-Host "  ║    Connecting to the internet to load the imaging engine...                  ║" -ForegroundColor Gray
    Write-Host "  ║                                                                              ║" -ForegroundColor Cyan
    Write-Host '  ╚══════════════════════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Status {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "  » $Message" -ForegroundColor $Color
}

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ''
    Write-Host "  ── $Title " -NoNewline -ForegroundColor Yellow
    Write-Host ('─' * [Math]::Max(0, 72 - $Title.Length)) -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region ── Network ───────────────────────────────────────────────────────────────

function Invoke-WpeInit {
    <#
    .SYNOPSIS
        Calls wpeinit.exe to initialise the WinPE network stack and start DHCP
        on all wired adapters.  Must be called before any network operations.
    #>
    Write-Status 'Initialising network stack (wpeinit.exe)...'
    try {
        $proc = Start-Process -FilePath 'wpeinit.exe' -Wait -NoNewWindow -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-Status 'Network stack initialised.' 'Green'
        } else {
            Write-Status "wpeinit.exe exited with code $($proc.ExitCode)." 'Yellow'
        }
    } catch {
        Write-Status "wpeinit.exe unavailable: $_" 'Yellow'
    }
    # Give DHCP a moment to acquire an address before the first connectivity test
    Start-Sleep -Seconds 4
}

function Test-InternetConnectivity {
    $urls = @(
        'https://www.msftconnecttest.com/connecttest.txt',
        'https://raw.githubusercontent.com',
        'https://clients3.google.com/generate_204'
    )
    foreach ($url in $urls) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($r.StatusCode -lt 400) { return $true }
        } catch { }
    }
    return $false
}

function Wait-ForInternet {
    param([int]$MaxWaitSeconds, [int]$RetryInterval)
    $elapsed = 0
    while ($elapsed -lt $MaxWaitSeconds) {
        if (Test-InternetConnectivity) {
            Write-Status 'Internet connectivity confirmed.' 'Green'
            return $true
        }
        Write-Status "Waiting for internet... ($elapsed / $MaxWaitSeconds s)" 'Yellow'
        Start-Sleep -Seconds $RetryInterval
        $elapsed += $RetryInterval
    }
    Write-Status "No internet after $MaxWaitSeconds s." 'Red'
    return $false
}

#endregion

#region ── WiFi ──────────────────────────────────────────────────────────────────

function ConvertTo-XmlSafe {
    param([string]$Value)
    $Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
}

function Start-WlanService {
    try {
        $svc = Get-Service -Name 'wlansvc' -ErrorAction SilentlyContinue
        if ($null -eq $svc) { return $false }
        if ($svc.Status -ne 'Running') {
            Start-Service 'wlansvc' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        return $true
    } catch { return $false }
}

function Get-WiFiNetworks {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & netsh wlan show networks mode=bssid 2>&1
    } finally {
        $ErrorActionPreference = $prev
    }

    $networks = [System.Collections.Generic.List[pscustomobject]]::new()
    $cur = $null
    foreach ($line in $raw) {
        if ($line -match '^SSID\s+\d+\s*:\s*(.+)$') {
            if ($cur) { $networks.Add($cur) }
            $cur = [pscustomobject]@{ SSID = $Matches[1].Trim(); Auth = ''; Signal = 0 }
        } elseif ($cur -and $line -match 'Authentication\s*:\s*(.+)') {
            $cur.Auth = $Matches[1].Trim()
        } elseif ($cur -and $line -match 'Signal\s*:\s*(\d+)%') {
            $cur.Signal = [int]$Matches[1]
        }
    }
    if ($cur) { $networks.Add($cur) }
    return @($networks | Where-Object { $_.SSID -ne '' } | Sort-Object Signal -Descending)
}

function Get-SignalBars {
    param([int]$Signal)
    $filled = [Math]::Round($Signal / 20)
    return ('█' * $filled) + ('░' * (5 - $filled))
}

function Connect-WiFiNetwork {
    param([string]$SSID, [string]$Password, [string]$Auth)

    $safeSsid = ConvertTo-XmlSafe $SSID
    $safePwd  = ConvertTo-XmlSafe $Password

    if ($Auth -match 'Open') {
        $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$safeSsid</name>
  <SSIDConfig><SSID><name>$safeSsid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security><authEncryption>
    <authentication>open</authentication>
    <encryption>none</encryption>
    <useOneX>false</useOneX>
  </authEncryption></security></MSM>
</WLANProfile>
"@
    } else {
        $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$safeSsid</name>
  <SSIDConfig><SSID><name>$safeSsid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security><authEncryption>
    <authentication>WPA2PSK</authentication>
    <encryption>AES</encryption>
    <useOneX>false</useOneX>
  </authEncryption>
  <sharedKey>
    <keyType>passPhrase</keyType>
    <protected>false</protected>
    <keyMaterial>$safePwd</keyMaterial>
  </sharedKey></security></MSM>
</WLANProfile>
"@
    }

    $tmpXml = Join-Path $env:TEMP "ampcloud_wifi_$([System.Guid]::NewGuid().ToString('N')).xml"
    try {
        $xml | Set-Content -Path $tmpXml -Encoding UTF8
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & netsh wlan add profile filename="`"$tmpXml`"" 2>&1 | Out-Null
        & netsh wlan connect  name="`"$SSID`"" ssid="`"$SSID`"" 2>&1 | Out-Null
        $ErrorActionPreference = $prev
    } finally {
        Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue
    }
}

function Show-WiFiSelector {
    <#
    .SYNOPSIS
        Interactive WiFi network selector. Returns $true when internet is available.
    #>
    if (-not (Start-WlanService)) {
        Write-Status 'WLAN service unavailable — wireless not supported on this device.' 'Yellow'
        return $false
    }

    while ($true) {
        Write-Status 'Scanning for WiFi networks...'
        $networks = Get-WiFiNetworks
        Write-Host ''

        if ($networks.Count -eq 0) {
            Write-Host '    No WiFi networks found.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '    [R] Refresh    [S] Skip' -ForegroundColor Gray
        } else {
            Write-Host '    #    Network Name                    Signal    Security' -ForegroundColor DarkGray
            Write-Host '    ──   ──────────────────────────────  ────────  ────────' -ForegroundColor DarkGray
            $i = 1
            foreach ($net in $networks) {
                $bars    = Get-SignalBars -Signal $net.Signal
                $ssidStr = if ($net.SSID.Length -gt 30) { $net.SSID.Substring(0,27) + '...' } else { $net.SSID }
                Write-Host ("    [{0,2}]  {1,-30}  {2}  {3,3}%  {4}" -f `
                    $i, $ssidStr, $bars, $net.Signal, $net.Auth) -ForegroundColor White
                $i++
            }
            Write-Host ''
            Write-Host '    [R] Refresh networks    [S] Skip WiFi' -ForegroundColor Gray
        }

        Write-Host ''
        Write-Host '  Select: ' -ForegroundColor Yellow -NoNewline
        $choice = (Read-Host).Trim().ToUpper()

        if ($choice -eq 'S') { return $false }
        if ($choice -eq 'R') { Write-Host ''; continue }

        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $networks.Count) {
            $net = $networks[$idx - 1]
            Write-Host ''

            $password = ''
            if ($net.Auth -notmatch 'Open') {
                Write-Host "  Password for '$($net.SSID)': " -ForegroundColor Yellow -NoNewline
                $bstr = [IntPtr]::Zero
                try {
                    $sec      = Read-Host -AsSecureString
                    $bstr     = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
                    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                } finally {
                    if ($bstr -ne [IntPtr]::Zero) {
                        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                    }
                }
            }

            Write-Host ''
            Write-Status "Connecting to '$($net.SSID)'..."
            Connect-WiFiNetwork -SSID $net.SSID -Password $password -Auth $net.Auth
            $password = $null

            Write-Status 'Waiting for IP address...' 'Yellow'
            Start-Sleep -Seconds 6

            if (Test-InternetConnectivity) {
                Write-Status "Connected via WiFi ('$($net.SSID)')." 'Green'
                return $true
            }

            Write-Status "No internet via '$($net.SSID)'. Check password or network." 'Red'
            Write-Host ''
            Write-Host '    [R] Try another network    [S] Skip' -ForegroundColor Gray
            Write-Host '  Select: ' -ForegroundColor Yellow -NoNewline
            $retry = (Read-Host).Trim().ToUpper()
            if ($retry -eq 'S') { return $false }
            Write-Host ''
        }
    }
}

#endregion

#region ── Main ──────────────────────────────────────────────────────────────────

# ── Welcome screen ────────────────────────────────────────────────────────────
Show-WelcomeBanner

# ── Step 1: Initialise WinPE network stack ────────────────────────────────────
# wpeinit.exe is normally called by startnet.cmd, but winpeshl.ini bypasses
# startnet.cmd when it launches PowerShell directly.  We must call it ourselves.
Write-SectionHeader 'Network Initialisation'
Invoke-WpeInit

# ── Step 2: Fast path — wired DHCP already gave us internet ──────────────────
$hasInternet = Test-InternetConnectivity

if (-not $hasInternet) {
    # ── Step 3: Offer WiFi ────────────────────────────────────────────────────
    Write-SectionHeader 'Network Connection'
    Write-Status 'No internet on wired connection.' 'Yellow'
    Write-Host ''
    Write-Host "  Would you like to connect via WiFi?  [Y/N] " -ForegroundColor Yellow -NoNewline
    $ans = (Read-Host).Trim().ToUpper()

    if ($ans -eq 'Y') {
        Write-Host ''
        Write-SectionHeader 'WiFi Setup'
        $hasInternet = Show-WiFiSelector
    }

    # ── Step 4: Short retry loop in case DHCP is still settling ──────────────
    if (-not $hasInternet) {
        $hasInternet = Wait-ForInternet -MaxWaitSeconds $MaxWaitSeconds -RetryInterval $RetryInterval
    }
}

if (-not $hasInternet) {
    Write-Host ''
    Write-Status 'ERROR: No internet connection available.' 'Red'
    Write-Status 'Dropping to shell. Fix networking then run Bootstrap.ps1 again.' 'Yellow'
    & cmd.exe /k
    exit 1
}

# ── Step 5: Download and execute AmpCloud.ps1 ─────────────────────────────────
Write-SectionHeader 'Loading AmpCloud'
$url = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/AmpCloud.ps1"
Write-Status "Fetching AmpCloud.ps1 from: $url"

try {
    $script = Invoke-RestMethod -Uri $url -UseBasicParsing -ErrorAction Stop
    Write-Status 'AmpCloud.ps1 downloaded. Starting imaging engine...' 'Green'
    Write-Host ''
    Invoke-Expression $script
} catch {
    Write-Status "Failed to download AmpCloud.ps1: $_" 'Red'
    Write-Status 'Dropping to interactive shell for manual recovery.' 'Yellow'
    & cmd.exe /k
    exit 1
}

#endregion

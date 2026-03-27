#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Bootstrap - WinRE/WinPE loader with HTML UI.
.DESCRIPTION
    Runs inside the WinRE/WinPE boot environment via winpeshl.ini.
    - Calls wpeinit.exe to initialise the WinPE network stack and DHCP.
    - The main visible UI runs in Edge kiosk mode (AmpCloud-UI/index.html).
    - Communicates with the HTML UI via a JSON status file and HTTP API.
    - Applies high-performance network tuning.
    - Offers an interactive graphical WiFi selector when wired internet is unavailable.
    - Shows a unified configuration dialog (language + Windows edition) once connected.
    - Downloads and executes AmpCloud.ps1 from GitHub once connected.
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$GitHubUser   = 'araduti',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubRepo   = 'AmpCloud',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubBranch = 'main',
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxWaitSeconds  = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Shell path ───────────────────────────────────────────────────────────────
# Resolved once at startup so WinPE's fixed X:\ path is used reliably.
$script:PsBin = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ── Logging ─────────────────────────────────────────────────────────────────
$LogPath = "X:\AmpCloud-Bootstrap.log"
$null = Start-Transcript -Path $LogPath -Append -Force -ErrorAction SilentlyContinue

$script:AuthLogPath = "X:\AmpCloud-Auth.log"
function Write-AuthLog {
    <#
    .SYNOPSIS  Write a timestamped entry to the dedicated auth log file.
    .DESCRIPTION
        Always writes to X:\AmpCloud-Auth.log regardless of the Verbose
        preference.  This ensures authentication diagnostics are captured
        even when the script is not run with -Verbose.
    #>
    param([string] $Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] $Message"
    try { $entry | Out-File -FilePath $script:AuthLogPath -Append -Encoding utf8 -Force }
    catch { Write-Warning "Auth log write failed: $_" }
    Write-Verbose $Message
}

# ── Assemblies ──────────────────────────────────────────────────────────────
# WinForms and Drawing are still required for interactive dialogs
# (WiFi selector, M365 auth) and for the timer-based message pump.
# The main visible UI is now the HTML page in Edge kiosk mode.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── TLS ─────────────────────────────────────────────────────────────────────
# PowerShell 5.1 in WinPE defaults to SSL3/TLS 1.0.  Modern HTTPS endpoints
# (msftconnecttest, GitHub, etc.) require TLS 1.2, so enforce it up front.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── WinPE Environment ──────────────────────────────────────────────────────
# Set standard user-profile paths that PowerShell modules expect.  Must run
# before any module or profile code that references these variables.
if (-not $env:APPDATA)      { $env:APPDATA      = "$env:USERPROFILE\AppData\Roaming" }
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA  = "$env:USERPROFILE\AppData\Local"   }
if (-not $env:HOMEDRIVE)    { $env:HOMEDRIVE     = 'X:'  }
if (-not $env:HOMEPATH)     { $env:HOMEPATH      = '\' }

# ── Constants ───────────────────────────────────────────────────────────────
# State machine timer interval (ms) and timeout thresholds (tick counts).
$script:TimerIntervalMs        = 500
$script:WpeInitTimeoutTicks    = 120   # 60 seconds  (120 × 500 ms)
$script:DhcpTimeoutTicks       = 60    # 30 seconds  (60  × 500 ms)
$script:SettlePauseTicks       = 10    # 5  seconds  (10  × 500 ms)
$script:DhcpWaitPauseTicks     = 10    # 5  seconds  (10  × 500 ms)
$script:MaxDhcpAttempts        = 5
$script:ConnectCheckIntervalMs = 5000  # 5  seconds
$script:BulletChar             = [char]0x2022  # '•' used in progress text

# ── HTML UI IPC ─────────────────────────────────────────────────────────────
# When the HTML Progress UI is running (launched by ampcloud-start.cmd
# before PowerShell), Bootstrap.ps1 writes status to the same JSON file that
# AmpCloud.ps1 uses.  This flag is cleared once AmpCloud.ps1 starts so that
# Bootstrap.ps1 stops writing and only reads (avoiding write conflicts).
$script:HtmlUiActive = $true

function Update-HtmlUi {
    <#
    .SYNOPSIS  Write status to the JSON IPC file for the HTML UI.
    .DESCRIPTION
        Mirrors status updates to X:\AmpCloud-Status.json so the HTML UI
        (running in Edge kiosk mode) can display real-time progress during the
        bootstrap phase before AmpCloud.ps1 takes over.
    #>
    param(
        [string]$Message  = '',
        [string]$Detail   = '',
        [int]$Step        = 0,
        [switch]$Done,
        [switch]$ShowWiFi,
        [switch]$ShowRetry,
        [string]$AuthUrl  = '',
        [switch]$ShowDeviceCode,
        [string]$DeviceCode = '',
        [string]$DeviceCodeUrl = '',
        [switch]$ShowConfig,
        $ConfigData = $null
    )
    if (-not $script:HtmlUiActive) { return }
    try {
        $obj = @{
            Message        = $Message
            Detail         = $Detail
            Progress       = 0
            Step           = $Step
            Done           = [bool]$Done
            ShowWiFi       = [bool]$ShowWiFi
            ShowRetry      = [bool]$ShowRetry
            AuthUrl        = $AuthUrl
            ShowDeviceCode = [bool]$ShowDeviceCode
            DeviceCode     = $DeviceCode
            DeviceCodeUrl  = $DeviceCodeUrl
            ShowConfig     = [bool]$ShowConfig
        }
        if ($ConfigData) { $obj['ConfigData'] = $ConfigData }
        $obj | ConvertTo-Json -Depth 4 -Compress |
            Set-Content -Path $script:StatusFile -Force -ErrorAction SilentlyContinue
    } catch {}
}

#region ── Language System ───────────────────────────────────────────────────
$script:Lang = 'EN'

# Locale strings are loaded from Config/locale/<lang>.json.  The function
# below downloads a locale file from the GitHub repository (same pattern used
# for auth.json), converts it to a hashtable, and normalizes \n escape
# sequences into real newlines so WinForms labels render them correctly.
function Import-LocaleJson {
    param([string]$LangCode)
    $code = $LangCode.ToLower()
    $url  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/Config/locale/$code.json"
    try {
        $wc   = New-Object System.Net.WebClient
        try {
            $raw  = $wc.DownloadString($url)
        } finally {
            $wc.Dispose()
        }
        $obj  = $raw | ConvertFrom-Json
        $ht   = @{}
        $obj.PSObject.Properties | ForEach-Object {
            $ht[$_.Name] = $_.Value -replace '\\n', "`n"
        }
        return $ht
    } catch {
        Write-Verbose "Failed to download locale $code from $url — $_"
        return $null
    }
}

# Pre-load locale files.  English is the required fallback; if it cannot be
# loaded the script embeds a minimal inline default so the UI is never blank.
$Strings = @{}
foreach ($lc in @('EN', 'FR', 'ES')) {
    $loaded = Import-LocaleJson -LangCode $lc
    if ($loaded) { $Strings[$lc] = $loaded }
}

if (-not $Strings.ContainsKey('EN')) {
    # Minimal inline fallback — only used when the network fetch fails for EN.
    $Strings['EN'] = @{
        Header="A M P C L O U D"; Subtitle="Cloud Imaging Engine";
        Step1="Network"; Step2="Connect"; Step3="Sign in"; Step4="Deploy";
        StatusInit="Initialising network stack...";
        StatusNoNet="No wired connection detected`nTap below to join Wi-Fi";
        Connected="Connected — verifying identity";
        Download="Downloading AmpCloud.ps1  ({0}%)";
        Complete="Ready to deploy";
        Reboot="Restart now"; PowerOff="Shut down"; Shell="Command prompt";
        Imaging="Imaging in progress...";
        CatalogFetch="Loading Windows catalog...";
        CatalogFail="Could not load catalog — using default edition.";
        EditionTitle="Choose edition";
        EditionLabel="Select the Windows edition to install:";
        EditionBtn="Continue";
        ConfigSubtitle="Configure your deployment";
        ConfigLang="Language"; ConfigOsLang="OS Language";
        ConfigArch="Architecture"; ConfigActivation="Activation";
        ConfigEdition="Windows Edition";
        ConfigRegion="Region"; ConfigKeyboard="Keyboard layout";
        ConfigDeviceName="Device name";
        ConfigBtn="Start deployment";
        AuthSigning="Signing in with Microsoft 365...";
        AuthPrompt="Sign in with your Microsoft 365 account to continue.";
        AuthUrl="https://microsoft.com/devicelogin";
        AuthWaiting="Waiting for sign-in...";
        AuthSuccess="Identity verified";
        AuthFailed="Authentication failed. Please try again.";
        AuthSkipped="Authentication not required";
        AuthEdgePrompt="Microsoft Edge has opened for sign-in.`nComplete the sign-in in the browser window, then this dialog will close automatically.";
        AuthDeviceCodePrompt="To sign in, use a web browser on another device`nand enter this code:"
    }
}

$script:S = $Strings[$script:Lang]
#endregion

#region ── Sound Effects ─────────────────────────────────────────────────────
function Invoke-Sound {
    param([int]$Freq = 800, [int]$Dur = 200)
    [console]::beep($Freq, $Dur)
}
#endregion

#region ── Fluent Theme (dialog essentials) ──────────────────────────────────
# Colours and fonts retained for interactive WinForms dialogs (WiFi selector,
# configuration menu, M365 auth).  The main visible form is now in HTML.
$LightBlue   = [System.Drawing.Color]::FromArgb(0, 120, 212)
$DarkBg      = [System.Drawing.Color]::FromArgb(32, 32, 32)
$LightCard   = [System.Drawing.Color]::White
$DarkCard    = [System.Drawing.Color]::FromArgb(45, 45, 45)
$TextLight   = [System.Drawing.Color]::FromArgb(32, 32, 32)
$TextDark    = [System.Drawing.Color]::White

$script:IsDarkMode  = $false
$TitleFont   = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$BodyFont    = New-Object System.Drawing.Font("Segoe UI", 11)
$SmallFont   = New-Object System.Drawing.Font("Segoe UI", 9.5)
$InfoFont    = New-Object System.Drawing.Font("Segoe UI", 9)
#endregion

#region ── Network + WiFi Functions ─────────────────────────────────────────

function Invoke-NetworkTuning {
    <#
    .SYNOPSIS  Fast synchronous TCP / firewall / IPv6 tuning.
    .DESCRIPTION
        All netsh commands complete in milliseconds and never sleep.  Safe to
        call from a WinForms timer tick without freezing the UI.
    #>
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = powercfg -s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        $null = netsh int tcp set global autotuninglevel=normal 2>$null
        $null = netsh int tcp set global congestionprovider=ctcp 2>$null
        $null = netsh int tcp set global chimney=enabled 2>$null
        $null = netsh int tcp set global rss=enabled 2>$null
        $null = netsh int tcp set global rsc=enabled 2>$null
        $null = netsh advfirewall set allprofiles state off 2>$null
        $ifLines = netsh interface show interface 2>$null
        foreach ($line in $ifLines) {
            if ($line -match '^\s*(Enabled|Disabled)\s+\S+\s+\S+\s+(.+)$') {
                $null = netsh interface ipv6 set interface "$($matches[2].Trim())" admin=disabled 2>$null
            }
        }
    } catch { Write-Verbose "Network tuning failed: $_" } finally { $ErrorActionPreference = $prev }
}

function Test-HasValidIP {
    <# Returns $true when ipconfig reports at least one non-APIPA IPv4 address. #>
    $ipOut = ipconfig 2>$null | Out-String
    foreach ($m in [regex]::Matches($ipOut, '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})')) {
        $ip = $m.Groups[1].Value
        if ($ip -notmatch '^(169\.254\.|127\.|0\.0\.0\.0|255\.)') { return $true }
    }
    return $false
}

function Test-InternetConnectivity {
    $urls = @(
        'https://www.msftconnecttest.com/connecttest.txt',
        'https://clients3.google.com/generate_204',
        'http://www.msftconnecttest.com/connecttest.txt'   # HTTP fallback (Windows NCSI endpoint)
    )
    foreach ($url in $urls) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
        } catch { Write-Verbose "Connectivity probe failed for ${url}: $_" }
    }
    return $false
}

function Start-WlanService {
    if (-not (Get-Service -Name wlansvc -ErrorAction SilentlyContinue)) { return $false }
    if ((Get-Service wlansvc).Status -ne 'Running') {
        Start-Service wlansvc -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    return $true
}

function Get-WiFiNetwork {
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
        } elseif ($cur) {
            if ($line -match 'Authentication\s*:\s*(.+)') { $cur.Auth = $Matches[1].Trim() }
            elseif ($line -match 'Signal\s*:\s*(\d+)%') { $cur.Signal = [int]$Matches[1] }
        }
    }
    if ($cur) { $networks.Add($cur) }
    $unique = @{}
    foreach ($n in $networks) {
        if (-not $unique.ContainsKey($n.SSID) -or $n.Signal -gt $unique[$n.SSID].Signal) {
            $unique[$n.SSID] = $n
        }
    }
    return @($unique.Values | Sort-Object Signal -Descending)
}

function Get-SignalBar { param([int]$s) ('█' * [Math]::Round($s/20)) + ('░' * (5-[Math]::Round($s/20))) }

function Connect-WiFiNetwork {
    param([string]$SSID, [string]$WiFiKey, [string]$Auth)
    $safeSsid = [System.Security.SecurityElement]::Escape($SSID)
    $isOpen   = $Auth -match 'Open'

    $ns = 'http://www.microsoft.com/networking/WLAN/profile/v1'
    if ($isOpen) {
        $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="$ns">
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
        $safePwd  = if ($WiFiKey) { [System.Security.SecurityElement]::Escape($WiFiKey) } else { '' }
        $authType = if ($Auth -match 'WPA3') { 'WPA3SAE' } else { 'WPA2PSK' }
        $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="$ns">
  <name>$safeSsid</name>
  <SSIDConfig><SSID><name>$safeSsid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security><authEncryption>
    <authentication>$authType</authentication>
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

    $tmp = Join-Path $env:TEMP "ampcloud_wifi_$([guid]::NewGuid().Guid).xml"
    try {
        $xml | Set-Content -Path $tmp -Encoding UTF8 -Force
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $null = & netsh wlan add profile filename="`"$tmp`"" 2>&1
        $null = & netsh wlan connect  name="`"$SSID`"" ssid="`"$SSID`"" 2>&1
        $ErrorActionPreference = $prev
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Show-WiFiSelector {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Select WiFi Network"
    $dlg.Size = New-Object System.Drawing.Size(720, 620)
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = if ($script:IsDarkMode) { $DarkCard } else { $LightCard }
    $dlg.Font = $BodyFont

    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = "Fill"
    $list.View = "Details"
    $list.FullRowSelect = $true
    $list.Columns.Add("Network", 380)
    $list.Columns.Add("Signal", 140)
    $list.Columns.Add("Security", 160)
    $dlg.Controls.Add($list)

    function RefreshNetworks {
        $list.Items.Clear()
        Get-WiFiNetwork | ForEach-Object {
            $item = New-Object System.Windows.Forms.ListViewItem($_.SSID)
            $item.SubItems.Add((Get-SignalBar $_.Signal))
            $item.SubItems.Add($_.Auth)
            $list.Items.Add($item)
        }
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "🔄 Refresh"
    $btnRefresh.Dock = "Bottom"
    $btnRefresh.Height = 50
    $dlg.Controls.Add($btnRefresh)
    $btnRefresh.Add_Click({ RefreshNetworks })

    RefreshNetworks

    $null = $dlg.ShowDialog()
    if ($list.SelectedItems.Count -gt 0) {
        $selected = $list.SelectedItems[0]
        $netSSID = $selected.Text
        $netAuth = $selected.SubItems[2].Text
        $password = ''
        if ($netAuth -notmatch 'Open') {
            $bstr = [IntPtr]::Zero
            try {
                $sec      = Read-Host -Prompt "Password for '$netSSID'" -AsSecureString
                $bstr     = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
                $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                if ($bstr -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }
        }
        Connect-WiFiNetwork -SSID $netSSID -WiFiKey $password -Auth $netAuth
        $password = $null
        Write-Status 'Waiting for IP address...' 'Yellow'
        Start-Sleep -Seconds 6
        return (Test-InternetConnectivity)
    }
    return $false
}
#endregion


#region ── HTTP API for HTML UI two-way communication ────────────────────────
# The HTML UI (AmpCloud-UI/index.html running in Edge kiosk mode) sends user
# actions via HTTP to this listener.  Bootstrap.ps1 processes them on the
# WinForms message pump thread to safely interact with modal dialogs.

$script:HttpListener = New-Object System.Net.HttpListener
$script:HttpListener.Prefixes.Add("http://localhost:8080/")
try { $script:HttpListener.Start() }
catch { Write-Verbose "HTTP listener failed to start: $_" }

$script:PendingAction = $null
$script:_httpAsync    = $null
if ($script:HttpListener.IsListening) {
    $script:_httpAsync = $script:HttpListener.BeginGetContext($null, $null)
}

# ── Status file path (shared with AmpCloud.ps1) ────────────────────────────
$script:StatusFile = "X:\AmpCloud-Status.json"

# ── Helper functions (route through HTML UI) ────────────────────────────────
function Write-Status {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Verbose "Status: $Message ($Color)"
    Update-HtmlUi -Message $Message
}

function Update-Step { param([int]$s)
    Update-HtmlUi -Step $s
}

function Show-Failure {
    Invoke-Sound 400 600
    Update-HtmlUi -Message "Could not connect to the internet.`nPlease check your network." `
                  -Step 2 -ShowWiFi -ShowRetry
}

# ── Action timer (polls HTTP requests + processes pending actions) ──────────
# Replaces the old WinForms Timer-based approach with async HTTP polling.
$script:actionTimer = New-Object System.Windows.Forms.Timer
$script:actionTimer.Interval = 500
$script:actionTimer.Add_Tick({
    # ── Check for incoming HTTP requests ────────────────────────────────
    if ($script:_httpAsync -and $script:_httpAsync.IsCompleted) {
        try {
            $context = $script:HttpListener.EndGetContext($script:_httpAsync)
            $path = $context.Request.Url.LocalPath.ToLower()
            $msg  = 'unknown'

            $handled = $false
            switch ($path) {
                '/wifi'       { $script:PendingAction = 'SHOW_WIFI'; $msg = 'ok' }
                '/retry'      { $script:PendingAction = 'RETRY'; $msg = 'ok' }
                '/cancelauth' { $script:_authCancelled = $true; $msg = 'ok' }
                '/configsubmit' {
                    # Read the JSON body posted by the HTML config modal
                    try {
                        $reader = New-Object System.IO.StreamReader($context.Request.InputStream, $context.Request.ContentEncoding)
                        $body   = $reader.ReadToEnd()
                        $reader.Close()
                        $script:_configResult = $body | ConvertFrom-Json
                    } catch {
                        Write-Verbose "Config submit parse error: $_"
                    }
                    $msg = 'ok'
                }
                '/ui' {
                    # Serve AmpCloud-UI/index.html so the browser can return
                    # from an HTTP context (e.g. after OAuth redirect) without
                    # requiring a blocked http→file:// navigation.
                    $handled = $true
                    $uiFile  = 'X:\AmpCloud-UI\index.html'
                    if (Test-Path $uiFile) {
                        $uiBytes = [System.IO.File]::ReadAllBytes($uiFile)
                        $context.Response.ContentType     = 'text/html; charset=utf-8'
                        $context.Response.ContentLength64 = $uiBytes.Length
                        $context.Response.OutputStream.Write($uiBytes, 0, $uiBytes.Length)
                    } else {
                        $context.Response.StatusCode = 404
                        $nb = [Text.Encoding]::UTF8.GetBytes('UI not found')
                        $context.Response.OutputStream.Write($nb, 0, $nb.Length)
                    }
                    $context.Response.Close()
                }
                '/status' {
                    # Serve AmpCloud-Status.json for pages loaded via HTTP
                    # (file:// pages read it directly via XHR).
                    $handled = $true
                    if (Test-Path $script:StatusFile) {
                        $sjBytes = [System.IO.File]::ReadAllBytes($script:StatusFile)
                        $context.Response.ContentType     = 'application/json; charset=utf-8'
                        $context.Response.ContentLength64 = $sjBytes.Length
                        $context.Response.OutputStream.Write($sjBytes, 0, $sjBytes.Length)
                    } else {
                        $context.Response.StatusCode = 404
                        $nb = [Text.Encoding]::UTF8.GetBytes('{}')
                        $context.Response.OutputStream.Write($nb, 0, $nb.Length)
                    }
                    $context.Response.Close()
                }
                '/reboot'     { Restart-Computer -Force; $msg = 'rebooting' }
                '/shutdown'   { Stop-Computer -Force; $msg = 'shutting down' }
                '/shell'      { Start-Process $script:PsBin -ArgumentList '-NoProfile','-NoExit'; $msg = 'shell opened' }
                '/heartbeat'  { $script:_lastHeartbeat = [DateTime]::UtcNow; $msg = 'ok' }
            }

            if (-not $handled) {
                $context.Response.StatusCode = 200
                $buffer = [Text.Encoding]::UTF8.GetBytes($msg)
                $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
                $context.Response.Close()
            }
        } catch { Write-Verbose "HTTP handler error: $_" }

        # Start waiting for next request
        try { $script:_httpAsync = $script:HttpListener.BeginGetContext($null, $null) }
        catch { Write-Verbose "HTTP listener restart error: $_" }
    }

    # ── Process pending actions from the HTML UI ────────────────────────
    if ($script:PendingAction) {
        $a = $script:PendingAction
        $script:PendingAction = $null

        switch ($a) {
            'SHOW_WIFI' {
                $wifiConnected = Show-WiFiSelector
                if ($wifiConnected) { ProceedToEngine } else { Show-Failure }
            }
            'RETRY' {
                if (Test-InternetConnectivity) { ProceedToEngine } else { Show-Failure }
            }
        }
    }
})
$script:actionTimer.Start()
#endregion


#region ── Global F8 hotkey (works even when Edge has crashed) ────────────────
# Register F8 as a system-wide hotkey via Win32 RegisterHotKey so users can
# open a PowerShell troubleshooting console at any time — regardless of whether
# Edge is responsive.  The WM_HOTKEY message is delivered to a hidden
# NativeWindow and processed by the existing DoEvents message pump.
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class AmpCloudHotkeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int WM_HOTKEY = 0x0312;
    private const uint VK_F8    = 0x77;
    private const int  HOTKEY_ID = 1;

    public event Action HotkeyPressed;

    public AmpCloudHotkeyWindow() {
        CreateHandle(new CreateParams());
        RegisterHotKey(Handle, HOTKEY_ID, 0, VK_F8);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HOTKEY_ID) {
            var handler = HotkeyPressed;
            if (handler != null) handler();
        }
        base.WndProc(ref m);
    }

    public void Dispose() {
        UnregisterHotKey(Handle, HOTKEY_ID);
        DestroyHandle();
    }
}
'@ -ReferencedAssemblies System.Windows.Forms -ErrorAction Stop

    $script:hotkeyWindow = New-Object AmpCloudHotkeyWindow
    $script:hotkeyWindow.add_HotkeyPressed({
        Write-Verbose 'F8 hotkey pressed — opening PowerShell'
        Start-Process $script:PsBin -ArgumentList '-NoProfile', '-NoExit'
    })
    Write-Verbose 'Global F8 hotkey registered'
} catch {
    Write-Verbose "Failed to register global F8 hotkey: $_"
}
#endregion


#region ── Edge watchdog (auto-restart on crash) ─────────────────────────────
# Edge with SwiftShader in WinPE can crash with Error code 39 (renderer
# process terminated).  When this happens the user is stranded on Edge's
# error page with no way to interact with the deployment.
#
# The watchdog tracks two signals:
#   1. Process exit  — all msedge.exe processes have terminated.
#   2. Heartbeat loss — the HTML UI sends a /heartbeat every 10 s.
#      If no heartbeat arrives for 30+ seconds the renderer has likely
#      crashed while the browser chrome process may still be alive.
#
# On either signal the watchdog kills any remaining Edge processes, clears
# the user-data dir lock files, and relaunches Edge with the original args.

$script:EdgeExe  = 'X:\WebView2\Edge\msedge.exe'
$script:EdgeArgs = @(
    '--kiosk',           'file:///X:/AmpCloud-UI/index.html',
    '--kiosk-type=fullscreen',
    '--allow-run-as-system',
    '--user-data-dir=X:\Temp\EdgeKiosk',
    '--disable-gpu',
    '--disable-gpu-compositing',
    '--disable-direct-composition',
    '--use-angle=swiftshader',
    '--enable-unsafe-swiftshader',
    '--in-process-gpu',
    '--no-first-run',
    '--disable-fre',
    '--disable-features=msWebOOBE',
    '--allow-file-access-from-files',
    '--disable-popup-blocking'
)

$script:_lastHeartbeat       = [DateTime]::UtcNow
$script:_edgeWatchdogStarted = $false

function Restart-Edge {
    <#
    .SYNOPSIS  Kill all Edge processes and relaunch the kiosk UI.
    #>
    Write-Verbose 'Edge watchdog — restarting Edge'
    # Terminate every msedge process
    Get-Process -Name 'msedge' -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.Kill() } catch {} }
    Start-Sleep -Seconds 2
    # Remove stale lock files so Edge starts cleanly
    Remove-Item 'X:\Temp\EdgeKiosk\lockfile'   -Force -ErrorAction SilentlyContinue
    Remove-Item 'X:\Temp\EdgeKiosk\SingletonLock' -Force -ErrorAction SilentlyContinue
    if (Test-Path $script:EdgeExe) {
        Start-Process -FilePath $script:EdgeExe -ArgumentList $script:EdgeArgs
    }
    $script:_lastHeartbeat = [DateTime]::UtcNow
}

$script:edgeWatchdogTimer = New-Object System.Windows.Forms.Timer
$script:edgeWatchdogTimer.Interval = 10000   # check every 10 seconds

$script:edgeWatchdogTimer.Add_Tick({
    # Skip watchdog until at least one heartbeat has been received, giving
    # Edge enough time to start on first boot.
    if (-not $script:_edgeWatchdogStarted) {
        if (([DateTime]::UtcNow - $script:_lastHeartbeat).TotalSeconds -lt 60) {
            # Still in grace period — check if we have received an actual
            # heartbeat (timestamp updated by /heartbeat route).
            $edgeRunning = Get-Process -Name 'msedge' -ErrorAction SilentlyContinue
            if ($edgeRunning) { return }
        }
        $script:_edgeWatchdogStarted = $true
    }

    $edgeRunning = Get-Process -Name 'msedge' -ErrorAction SilentlyContinue

    if (-not $edgeRunning) {
        # Edge process has exited entirely — restart it.
        Write-Verbose 'Edge watchdog — Edge process not found'
        Restart-Edge
        return
    }

    # Edge is running but the UI may be unresponsive (Error code 39 scenario).
    $heartbeatAge = ([DateTime]::UtcNow - $script:_lastHeartbeat).TotalSeconds
    if ($heartbeatAge -gt 30) {
        Write-Verbose "Edge watchdog — heartbeat lost (${heartbeatAge}s ago)"
        Restart-Edge
    }
})
$script:edgeWatchdogTimer.Start()
#endregion


#region ── Main Flow ─────────────────────────────────────────────────────────
$script:EngineStarted = $false

function Show-ConfigurationMenu {
    <#
    .SYNOPSIS  Unified pre-deployment configuration via HTML modal.
    .DESCRIPTION
        Downloads the Microsoft ESD catalog and shows a configuration modal
        in the HTML UI where the user configures all deployment options
        before imaging begins: UI language, OS language, architecture,
        activation channel (Retail / Volume), Windows edition, region,
        keyboard layout, and device name.
        The modal communicates the user's choices back via the HTTP API
        (/configsubmit) instead of using a blocking WinForms dialog.
    .OUTPUTS   A hashtable with Language, OsLanguage, Architecture, Activation,
               Edition, InputLocale, SystemLocale, UserLocale, UILanguage,
               ComputerName, and TaskSequencePath keys.
    #>
    $defaultResult = @{ Language = 'EN'; OsLanguage = 'en-us';
                        Architecture = 'x64'; Activation = 'Retail';
                        Edition = ''; InputLocale = ''; SystemLocale = '';
                        UserLocale = ''; UILanguage = ''; ComputerName = '' }

    # ── Download products.xml ─────────────────────────────────────────────
    Write-Status $S.CatalogFetch 'Cyan'
    [System.Windows.Forms.Application]::DoEvents()

    $scratchPath = 'X:\AmpCloud'
    if (-not (Test-Path $scratchPath)) {
        $null = New-Item -ItemType Directory -Path $scratchPath -Force
    }
    $productsXml = Join-Path $scratchPath 'products.xml'

    try {
        $productsUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/products.xml"
        $wc   = New-Object System.Net.WebClient
        $task = $wc.DownloadFileTaskAsync($productsUrl, $productsXml)
        while (-not $task.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        if ($task.IsFaulted) { throw $task.Exception.InnerException }
    } catch {
        Write-Status $S.CatalogFail 'Yellow'
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 2
        return $defaultResult
    }

    if (-not (Test-Path $productsXml)) {
        Write-Status $S.CatalogFail 'Yellow'
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 2
        return $defaultResult
    }

    # Parse the catalog XML once — downstream combos filter dynamically.
    $catalog = $null
    try {
        [xml]$catalog = Get-Content $productsXml -ErrorAction Stop
    } catch {
        Write-Status $S.CatalogFail 'Yellow'
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 2
        return $defaultResult
    }

    # Map Windows build numbers to friendly version names.
    # The first segment of the ESD FileName (e.g. "26100") is the build number.
    $buildVersionMap = @{
        '17763' = 'Windows 10 1809'
        '18362' = 'Windows 10 1903'
        '18363' = 'Windows 10 1909'
        '19041' = 'Windows 10 2004'
        '19042' = 'Windows 10 20H2'
        '19043' = 'Windows 10 21H1'
        '19044' = 'Windows 10 21H2'
        '19045' = 'Windows 10 22H2'
        '22000' = 'Windows 11 21H2'
        '22621' = 'Windows 11 22H2'
        '22631' = 'Windows 11 23H2'
        '26100' = 'Windows 11 24H2'
        '26200' = 'Windows 11 25H1'
    }

    # Pre-process every catalog file once into a flat list with a derived
    # Activation field (Retail or Volume) parsed from the ESD FileName,
    # and a WindowsVersion derived from the build number prefix.
    $allFiles = @(
        $catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File | ForEach-Object {
            $activation = if ($_.FileName -match 'CLIENTBUSINESS_VOL') { 'Volume' } else { 'Retail' }
            $buildNum = if ($_.FileName -match '^(\d+)\.') { $Matches[1] } else { '' }
            $winVer = if ($buildNum -and $buildVersionMap.ContainsKey($buildNum)) {
                $buildVersionMap[$buildNum]
            } else {
                'Windows'
            }
            [PSCustomObject]@{
                LanguageCode   = $_.LanguageCode
                Language       = $_.Language
                Architecture   = $_.Architecture
                Activation     = $activation
                Edition        = $_.Edition
                WindowsVersion = $winVer
            }
        }
    )

    # ── Read task sequence defaults for config modal pre-population ───────
    $tsDefaults = @{}
    try {
        $tsPath = Join-Path $scratchPath 'tasksequence.json'
        if (-not (Test-Path $tsPath)) {
            $tsUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/TaskSequence/default.json"
            $wc2 = New-Object System.Net.WebClient
            $wc2.DownloadFile($tsUrl, $tsPath)
        }
        if (Test-Path $tsPath) {
            $tsJson = Get-Content $tsPath -Raw | ConvertFrom-Json
            foreach ($step in $tsJson.steps) {
                if ($step.type -eq 'SetComputerName' -and $step.enabled -ne $false -and $step.parameters) {
                    $sp = $step.parameters
                    if ($sp.computerName) {
                        $tsDefaults.ComputerName = $sp.computerName
                    } elseif ($sp.prefix -or $sp.suffix -or $sp.useSerialNumber) {
                        # Generate a preview name from naming rules
                        $base = ''
                        if ($sp.useSerialNumber) {
                            try { $base = (Get-WmiObject Win32_BIOS).SerialNumber -replace '[^A-Za-z0-9]','' } catch { $base = '' }
                        }
                        if (-not $base) { $base = 'PC' + (Get-Random -Minimum 1000 -Maximum 9999).ToString() }
                        $pfx = if ($sp.prefix) { $sp.prefix } else { '' }
                        $sfx = if ($sp.suffix) { $sp.suffix } else { '' }
                        $preview = $pfx + $base + $sfx
                        $maxLen = if ($sp.maxLength -gt 0) { [math]::Min($sp.maxLength, 15) } else { 15 }
                        if ($preview.Length -gt $maxLen) { $preview = $preview.Substring(0, $maxLen) }
                        $preview = ($preview -replace '[^A-Za-z0-9\-]','').Trim('-')
                        if ($preview) { $tsDefaults.ComputerName = $preview }
                    }
                }
                if ($step.type -eq 'SetRegionalSettings' -and $step.enabled -ne $false -and $step.parameters) {
                    $sp = $step.parameters
                    if ($sp.inputLocale)  { $tsDefaults.InputLocale  = $sp.inputLocale }
                    if ($sp.systemLocale) { $tsDefaults.SystemLocale = $sp.systemLocale }
                    if ($sp.userLocale)   { $tsDefaults.UserLocale   = $sp.userLocale }
                    if ($sp.uiLanguage)   { $tsDefaults.UILanguage   = $sp.uiLanguage }
                }
                # Legacy: also read from CustomizeOOBE for backward compatibility
                if ($step.type -eq 'CustomizeOOBE' -and $step.enabled -ne $false -and $step.parameters) {
                    $sp = $step.parameters
                    if ($sp.inputLocale -and -not $tsDefaults.InputLocale)   { $tsDefaults.InputLocale  = $sp.inputLocale }
                    if ($sp.systemLocale -and -not $tsDefaults.SystemLocale) { $tsDefaults.SystemLocale = $sp.systemLocale }
                    if ($sp.userLocale -and -not $tsDefaults.UserLocale)     { $tsDefaults.UserLocale   = $sp.userLocale }
                    if ($sp.uiLanguage -and -not $tsDefaults.UILanguage)     { $tsDefaults.UILanguage   = $sp.uiLanguage }
                    if ($sp.computerName -and -not $tsDefaults.ComputerName) { $tsDefaults.ComputerName = $sp.computerName }
                }
                if ($step.type -eq 'ImportAutopilot' -and $step.enabled -ne $false) {
                    $tsDefaults.HasAutopilotStep = $true
                    if ($step.parameters) {
                        $sp = $step.parameters
                        if ($sp.groupTag)  { $tsDefaults.AutopilotGroupTag = $sp.groupTag }
                        if ($sp.userEmail) { $tsDefaults.AutopilotUserEmail = $sp.userEmail }
                    }
                }
            }
        }
    } catch {
        Write-Verbose "Could not load task sequence defaults: $_"
    }

    # ── Send catalog data to HTML UI ─────────────────────────────────────
    $configData = @{
        CatalogEntries = $allFiles
        Defaults       = $tsDefaults
        Labels         = @{
            ConfigSubtitle   = $S.ConfigSubtitle
            ConfigLang       = $S.ConfigLang
            ConfigOsLang     = $S.ConfigOsLang
            ConfigArch       = $S.ConfigArch
            ConfigActivation = $S.ConfigActivation
            ConfigEdition    = $S.ConfigEdition
            ConfigRegion     = $S.ConfigRegion
            ConfigKeyboard   = $S.ConfigKeyboard
            ConfigDeviceName = $S.ConfigDeviceName
            ConfigBtn        = $S.ConfigBtn
        }
    }

    $script:_configResult = $null
    Update-HtmlUi -Message $S.ConfigSubtitle -Step 4 -ShowConfig -ConfigData $configData

    # Wait for the user to submit the configuration from the HTML UI.
    # The HTTP API handler for /configsubmit sets $script:_configResult.
    while ($null -eq $script:_configResult) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }

    # Clear the config modal from the status file
    Update-HtmlUi -Message $S.ConfigSubtitle -Step 4

    $r = $script:_configResult
    $script:_configResult = $null

    return @{
        Language     = if ($r.Language)     { $r.Language }     else { 'EN' }
        OsLanguage   = if ($r.OsLanguage)   { $r.OsLanguage }   else { 'en-us' }
        Architecture = if ($r.Architecture) { $r.Architecture } else { 'x64' }
        Activation   = if ($r.Activation)   { $r.Activation }   else { 'Retail' }
        Edition      = if ($r.Edition)      { $r.Edition }      else { '' }
        InputLocale  = if ($r.InputLocale)  { $r.InputLocale }  else { '' }
        SystemLocale = if ($r.SystemLocale) { $r.SystemLocale } else { '' }
        UserLocale   = if ($r.UserLocale)   { $r.UserLocale }   else { '' }
        UILanguage   = if ($r.UILanguage)   { $r.UILanguage }   else { '' }
        ComputerName = if ($r.ComputerName) { $r.ComputerName } else { '' }
        AutopilotGroupTag  = if ($r.AutopilotGroupTag)  { $r.AutopilotGroupTag }  else { '' }
        AutopilotUserEmail = if ($r.AutopilotUserEmail) { $r.AutopilotUserEmail } else { '' }
        TaskSequencePath = if (Test-Path $tsPath) { $tsPath } else { '' }
    }
}

function Update-TaskSequenceFromConfig {
    <#
    .SYNOPSIS  Writes user configuration choices into the task sequence JSON.
    .DESCRIPTION
        After the user submits the configuration modal, this function updates
        the relevant step parameters in the task sequence JSON file so that
        the engine reads all values from the task sequence — no separate
        command-line parameters needed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TaskSequencePath,
        [hashtable]$Config
    )

    if (-not (Test-Path $TaskSequencePath)) { return }

    $raw = Get-Content $TaskSequencePath -Raw -ErrorAction Stop
    $ts  = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $ts.steps) { return }

    foreach ($step in $ts.steps) {
        if (-not $step.parameters) {
            $step | Add-Member -NotePropertyName parameters -NotePropertyValue ([pscustomobject]@{}) -Force
        }

        switch ($step.type) {
            'DownloadImage' {
                if ($Config.Edition)      { $step.parameters | Add-Member -NotePropertyName edition      -NotePropertyValue $Config.Edition      -Force }
                if ($Config.OsLanguage)   { $step.parameters | Add-Member -NotePropertyName language     -NotePropertyValue $Config.OsLanguage   -Force }
                if ($Config.Architecture) { $step.parameters | Add-Member -NotePropertyName architecture -NotePropertyValue $Config.Architecture -Force }
            }
            'ApplyImage' {
                if ($Config.Edition) { $step.parameters | Add-Member -NotePropertyName edition -NotePropertyValue $Config.Edition -Force }
            }
            'SetComputerName' {
                if ($Config.ComputerName) { $step.parameters | Add-Member -NotePropertyName computerName -NotePropertyValue $Config.ComputerName -Force }
            }
            'SetRegionalSettings' {
                if ($Config.InputLocale)  { $step.parameters | Add-Member -NotePropertyName inputLocale  -NotePropertyValue $Config.InputLocale  -Force }
                if ($Config.SystemLocale) { $step.parameters | Add-Member -NotePropertyName systemLocale -NotePropertyValue $Config.SystemLocale -Force }
                if ($Config.UserLocale)   { $step.parameters | Add-Member -NotePropertyName userLocale   -NotePropertyValue $Config.UserLocale   -Force }
                if ($Config.UILanguage)   { $step.parameters | Add-Member -NotePropertyName uiLanguage   -NotePropertyValue $Config.UILanguage   -Force }
            }
            'ImportAutopilot' {
                if ($Config.ContainsKey('AutopilotGroupTag'))  { $step.parameters | Add-Member -NotePropertyName groupTag  -NotePropertyValue $Config.AutopilotGroupTag  -Force }
                if ($Config.ContainsKey('AutopilotUserEmail')) { $step.parameters | Add-Member -NotePropertyName userEmail -NotePropertyValue $Config.AutopilotUserEmail -Force }
            }
        }
    }

    $ts | ConvertTo-Json -Depth 20 | Set-Content $TaskSequencePath -Encoding UTF8 -Force
}

#region ── M365 Authentication ────────────────────────────────────────────────

function Invoke-M365EdgeAuth {
    <#
    .SYNOPSIS  Authenticate the operator via the kiosk Edge browser (Auth Code + PKCE).
    .DESCRIPTION
        Navigates the existing Edge kiosk browser to the Azure AD authorization
        endpoint.  The user signs in directly in the kiosk browser window.
        A temporary localhost HTTP listener captures the redirect carrying the
        authorization code, then exchanges it for tokens using PKCE.
        After authentication completes (or fails), the listener redirects the
        browser back to the AmpCloud-UI page.
        WinPE-safe — no separate Edge process or WinForms dialog is created.
    .PARAMETER ClientId
        Azure AD application (client) ID.
    .OUTPUTS
        $true on success, $false on failure or cancellation.
    #>
    param(
        [string] $ClientId,
        [string] $Scope = 'openid profile'
    )

    # ── Verify the HTML UI is active (kiosk Edge must be running) ───────────
    if (-not $script:HtmlUiActive) {
        Write-AuthLog "HTML UI not active — cannot use in-kiosk auth."
        return $false
    }

    # ── Log environment diagnostics ─────────────────────────────────────────
    Write-AuthLog "Kiosk auth starting"

    # ── PKCE code verifier and challenge (RFC 7636) ─────────────────────────
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $codeVerifier  = [Convert]::ToBase64String($bytes) -replace '\+','-' -replace '/','_' -replace '='

    $sha256        = [System.Security.Cryptography.SHA256]::Create()
    $challengeHash = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
    $codeChallenge = [Convert]::ToBase64String($challengeHash) -replace '\+','-' -replace '/','_' -replace '='

    # ── Start a temporary localhost HTTP listener ───────────────────────────
    # A random high port is used to avoid conflicts.  The listener captures
    # the OAuth redirect after the user completes sign-in in Edge.
    $listener    = New-Object System.Net.HttpListener
    $redirectUri = $null
    foreach ($attempt in 1..5) {
        $port        = Get-Random -Minimum 49152 -Maximum 65535
        $redirectUri = "http://localhost:$port/"
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add($redirectUri)
        try {
            $listener.Start()
            Write-AuthLog "HTTP listener started on port $port"
            break
        } catch {
            Write-AuthLog "Listener port $port failed (attempt $attempt of 5): $_"
            if ($attempt -eq 5) {
                Write-AuthLog "Could not start HTTP listener after $attempt attempts."
                return $false
            }
        }
    }

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
    # The kiosk Edge browser opens a popup window for Azure AD sign-in.
    # After the user signs in, Azure AD redirects to the localhost listener
    # which captures the auth code and closes the popup via window.close().
    Write-AuthLog "Opening auth popup via kiosk UI"
    Update-HtmlUi -Message $S.AuthSigning -Step 3 -AuthUrl $authorizeUrl

    # ── Wait for the redirect callback ──────────────────────────────────────
    $script:_edgeAuthCode   = $null
    $script:_edgeAuthError  = $null
    $script:_authCancelled  = $false
    $asyncResult = $listener.BeginGetContext($null, $null)

    # 5-minute timeout — Azure AD sessions are valid for 10 minutes,
    # 5 minutes gives enough time without leaving the kiosk unattended.
    $timeout = [datetime]::UtcNow.AddMinutes(5)

    while (-not $script:_edgeAuthCode -and -not $script:_edgeAuthError `
           -and -not $script:_authCancelled -and [datetime]::UtcNow -lt $timeout) {

        if ($asyncResult.IsCompleted -or $asyncResult.AsyncWaitHandle.WaitOne(0)) {
            try {
                $context = $listener.EndGetContext($asyncResult)

                # Parse authorization code (or error) from the query string.
                foreach ($pair in $context.Request.Url.Query.TrimStart('?').Split('&')) {
                    $kv = $pair.Split('=', 2)
                    if ($kv.Count -eq 2) {
                        if ($kv[0] -eq 'code')  { $script:_edgeAuthCode  = [uri]::UnescapeDataString($kv[1]) }
                        if ($kv[0] -eq 'error') { $script:_edgeAuthError = [uri]::UnescapeDataString($kv[1]) }
                    }
                }

                # Clear the auth signal before the popup closes.
                Update-HtmlUi -Message $S.AuthSigning -Step 3

                # Send a response page that closes the auth popup window.
                $html = if ($script:_edgeAuthCode) {
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
                Write-AuthLog "Listener callback error: $_"
            }
        }

        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
    }

    # ── Always clear auth signal ────────────────────────────────────────────
    # Prevents the UI from re-opening the auth popup on the next poll
    # (e.g. if auth timed out or was cancelled before the listener fired).
    Update-HtmlUi -Message $S.AuthSigning -Step 3

    } finally {
        try { $listener.Stop(); $listener.Close() } catch {}
    }

    if ($script:_authCancelled -or -not $script:_edgeAuthCode) {
        $codeStatus = if ($script:_edgeAuthCode) { 'present' } else { 'missing' }
        Write-AuthLog "Kiosk auth ended without auth code. Cancelled=$($script:_authCancelled), AuthCode=$codeStatus"
        if ($script:_edgeAuthError) {
            Write-AuthLog "Auth error: $($script:_edgeAuthError)"
        }
        return $false
    }

    # ── Exchange authorization code for tokens ──────────────────────────────
    $tokenUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token'
    try {
        $body = "client_id=$([uri]::EscapeDataString($ClientId))" +
                "&scope=$([uri]::EscapeDataString($Scope))" +
                "&code=$([uri]::EscapeDataString($script:_edgeAuthCode))" +
                "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
                '&grant_type=authorization_code' +
                "&code_verifier=$([uri]::EscapeDataString($codeVerifier))"
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
        $raw = $wc.UploadString($tokenUrl, 'POST', $body)
        $tokenResponse = $raw | ConvertFrom-Json
        if ($tokenResponse.id_token) {
            if ($tokenResponse.access_token) {
                $script:GraphAccessToken = $tokenResponse.access_token
            }
            Write-AuthLog "Kiosk auth succeeded — token obtained."
            return $true
        }
    } catch {
        Write-AuthLog "Token exchange failed: $_"
    }

    return $false
}

function Invoke-M365DeviceCodeAuth {
    <#
    .SYNOPSIS  Authenticate the operator via Device Code Flow (fallback).
    .DESCRIPTION
        Fallback authentication path used when the kiosk Edge auth is not
        available.  Initiates the Device Code Flow and shows the one-time
        code and verification URL in the HTML UI as a modal overlay.
    .PARAMETER ClientId
        Azure AD application (client) ID.
    .PARAMETER Scope
        OAuth 2.0 scopes to request (space-separated).
    .OUTPUTS
        $true on success, $false on failure or cancellation.
    #>
    param(
        [string] $ClientId,
        [string] $Scope = 'openid profile'
    )

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
        Write-AuthLog "Device code request failed: $_"
        return $false
    }

    $userCode   = $deviceResponse.user_code
    $deviceCode = $deviceResponse.device_code
    $expiresIn  = if ($deviceResponse.expires_in) { [int]$deviceResponse.expires_in } else { 900 }
    $interval   = if ($deviceResponse.interval)   { [int]$deviceResponse.interval   } else { 5   }

    # ── Show device code in the HTML UI modal ───────────────────────────────
    $script:_authCancelled = $false
    Update-HtmlUi -Message $S.AuthDeviceCodePrompt -Step 3 `
                  -ShowDeviceCode -DeviceCode $userCode -DeviceCodeUrl $S.AuthUrl

    # ── Poll for token ──────────────────────────────────────────────────────
    $expiry   = [datetime]::UtcNow.AddSeconds($expiresIn)
    $nextPoll = [datetime]::UtcNow.AddSeconds($interval)
    $tokenResponse = $null

    while (-not $script:_authCancelled -and [datetime]::UtcNow -lt $expiry) {
        if ([datetime]::UtcNow -ge $nextPoll) {
            try {
                $body = "grant_type=$([uri]::EscapeDataString($grantType))" +
                        "&client_id=$([uri]::EscapeDataString($ClientId))" +
                        "&device_code=$([uri]::EscapeDataString($deviceCode))"
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
                $raw = $wc.UploadString($tokenUrl, 'POST', $body)
                $tr = $raw | ConvertFrom-Json
                if ($tr.id_token) {
                    $tokenResponse = $tr
                    if ($tr.access_token) {
                        $script:GraphAccessToken = $tr.access_token
                    }
                    break
                }
            } catch {
                $msg = $_.ToString()
                if ($msg -notmatch 'authorization_pending' -and $msg -notmatch 'slow_down') {
                    Write-AuthLog "Token poll error: $msg"
                }
            }
            $nextPoll = [datetime]::UtcNow.AddSeconds($interval)
        }

        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
    }

    # ── Clear the device code modal ─────────────────────────────────────────
    Update-HtmlUi -Message $S.AuthSigning -Step 3

    if (-not $tokenResponse) {
        return $false
    }

    Write-AuthLog "Device code auth succeeded — token obtained."
    return $true
}

function Invoke-M365Auth {
    <#
    .SYNOPSIS  Authenticate the operator via M365 (kiosk browser, Device Code fallback).
    .DESCRIPTION
        Downloads Config/auth.json from the GitHub repository.  When
        requireAuth is true and a clientId is configured, the function
        first attempts interactive sign-in by navigating the existing
        kiosk Edge browser to Azure AD (Authorization Code Flow with
        PKCE).  If the kiosk UI is not active or fails, it falls back
        to Device Code Flow, showing the code in an HTML modal.
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

    # ── Try kiosk Edge browser auth first ──────────────────────────────────
    # Navigates the existing kiosk Edge to Azure AD for interactive sign-in.
    # A localhost HTTP listener captures the OAuth redirect.  If the kiosk
    # UI is not active or auth fails, fall back to Device Code Flow, which
    # shows the one-time code in an HTML modal overlay.
    $browserOk = $false
    try {
        $browserOk = Invoke-M365EdgeAuth -ClientId $clientId -Scope $scope
    } catch {
        Write-AuthLog "Kiosk auth failed, will fall back to Device Code Flow: $_"
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
#endregion

function ProceedToEngine {
    # Guard: prevent double invocation from both timer and WiFi click handler.
    if ($script:EngineStarted) { return }
    $script:EngineStarted = $true
    if ($script:connectCheckTimer) { $script:connectCheckTimer.Stop() }

    Update-Step 3
    Write-Status $S.Connected 'Green'
    Update-HtmlUi -Message $S.Connected -Step 3
    Invoke-Sound 900 300

    # ── M365 authentication gate ────────────────────────────────────────────
    # When Config/auth.json has requireAuth = true, the operator must sign in
    # with a Microsoft 365 account from an allowed Entra ID tenant.
    # Tenant restrictions are enforced at the app registration level.
    # Navigates the kiosk Edge to Azure AD (Auth Code + PKCE) as
    # the primary method; falls back to Device Code Flow shown in
    # an HTML modal overlay if the kiosk auth is unavailable.
    $authPassed = Invoke-M365Auth
    if (-not $authPassed) {
        $script:EngineStarted = $false   # allow retry after WiFi reconnect
        return
    }

    Update-Step 4

    # Unified configuration dialog: language + all Windows options in one step.
    $config = Show-ConfigurationMenu
    $script:Lang = $config.Language
    $script:S    = $Strings[$script:Lang]
    $script:TaskSequencePath = $config.TaskSequencePath

    # Write user configuration choices into the task sequence JSON so the
    # engine reads everything from a single source of truth.
    if ($script:TaskSequencePath) {
        Update-TaskSequenceFromConfig -TaskSequencePath $script:TaskSequencePath -Config $config
    }

    # Clean up any stale status file from a previous run.
    if (Test-Path $script:StatusFile) { Remove-Item $script:StatusFile -Force }

    # Prefer the pre-staged copy embedded in the WinPE image by Trigger.ps1.
    # Fall back to downloading from GitHub when the local copy is absent.
    $engineFailed = $false
    try {
        $localAmpCloud = Join-Path $env:SystemRoot 'System32\AmpCloud.ps1'
        if (-not (Test-Path $localAmpCloud)) {
            $url    = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/AmpCloud.ps1"
            $localAmpCloud = 'X:\AmpCloud.ps1'
            Write-Status ($S.Download -f 0)
            $web = New-Object System.Net.WebClient
            $web.add_DownloadProgressChanged({
                param($eventSender, $e)
                $null = $eventSender  # Required by .NET delegate signature
                Write-Status ($S.Download -f $e.ProgressPercentage)
            })
            $task = $web.DownloadFileTaskAsync($url, $localAmpCloud)
            while (-not $task.IsCompleted) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            if ($task.IsFaulted) { throw $task.Exception.InnerException }
        }

        # Run AmpCloud.ps1 in a dedicated process so the UI thread
        # stays responsive and the spinner keeps animating.
        # Detect firmware type so AmpCloud partitions and configures the
        # bootloader correctly (UEFI → GPT + bcdboot /f UEFI,
        # BIOS → MBR + bcdboot /f BIOS).  wpeutil UpdateBootInfo already
        # populated the PEFirmwareType registry value during WinPE init.
        $detectedFirmware = 'UEFI'
        try {
            $fwVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' `
                                       -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
            if ($fwVal -eq 1) { $detectedFirmware = 'BIOS' }
        } catch { Write-Verbose "PEFirmwareType unavailable: $_" }

        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $localAmpCloud,
                    '-StatusFile', $script:StatusFile,
                    '-FirmwareType', $detectedFirmware,
                    '-TaskSequencePath', $script:TaskSequencePath)

        # Pass the Graph access token to the engine via an environment variable
        # so the ImportAutopilot task sequence step can register the device in
        # Autopilot before downloading or applying Windows.  In WinPE only the
        # SYSTEM account runs and no other user processes exist, so environment
        # variable exposure is acceptable.
        if ($script:GraphAccessToken) {
            $env:AMPCLOUD_GRAPH_TOKEN = $script:GraphAccessToken
        }

        Update-HtmlUi -Message $S.Imaging -Step 4

        # Stop writing to the status JSON from Bootstrap — AmpCloud.ps1 takes
        # over the file from this point to avoid write conflicts.
        $script:HtmlUiActive = $false

        $engineProc = Start-Process -FilePath $script:PsBin -ArgumentList $psArgs -WindowStyle Hidden -PassThru

        Write-Status $S.Imaging 'Cyan'
        while (-not $engineProc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
        if ($engineProc.ExitCode -ne 0) { $engineFailed = $true }
    } catch {
        # Engine already printed diagnostics.  The Bootstrap message pump
        # keeps running so interactive troubleshooting is possible.
        $engineFailed = $true
    }

    Stop-Transcript -ErrorAction SilentlyContinue

    if (-not $engineFailed) {
        Invoke-Sound 1200 400
        Update-HtmlUi -Message $S.Complete -Step 4 -Done
    }
}

$script:connectCheckTimer = New-Object System.Windows.Forms.Timer

# ── Non-blocking initialisation state machine ──────────────────────────────
# Replaces the previous blocking Invoke-WpeInit / Optimize-WinPENetwork calls
# that froze the UI thread for 20-30 seconds, preventing F8, ring animation,
# and all user interaction.
#
# States:
#   INIT          – launch wpeinit.exe (non-blocking)
#   WPEINIT_POLL  – wait for wpeinit to exit, then run quick sync tuning
#   SETTLE        – wait for NIC drivers and DHCP Client service to start
#   DHCP          – launch ipconfig /renew (hidden window, non-blocking)
#   DHCP_POLL     – wait for ipconfig to exit, check for valid IP
#   DHCP_WAIT     – 5-second pause between DHCP retries (up to 5 attempts)
#   CHECK         – test internet connectivity, decide next step

$script:_initState = 'INIT'
$script:_proc      = $null
$script:_dhcp      = 0
$script:_wait      = 0

$script:initTimer = New-Object System.Windows.Forms.Timer
$script:initTimer.Interval = $script:TimerIntervalMs

$script:initTimer.Add_Tick({
    switch ($script:_initState) {

        'INIT' {
            $script:_wait = 0
            Update-HtmlUi -Message $S.StatusInit -Step 1
            try {
                $script:_proc = Start-Process -FilePath 'wpeinit.exe' `
                    -NoNewWindow -PassThru -ErrorAction Stop
            } catch { $script:_proc = $null }
            $script:_initState = 'WPEINIT_POLL'
        }

        'WPEINIT_POLL' {
            if ($null -eq $script:_proc -or $script:_proc.HasExited -or
                ++$script:_wait -ge $script:WpeInitTimeoutTicks) {
                if ($script:_proc -and -not $script:_proc.HasExited) {
                    try { $script:_proc.Kill() } catch { Write-Verbose "Process already exited: $_" }
                }
                # wpeutil UpdateBootInfo populates PEFirmwareType in the
                # registry — needed by downstream partitioning logic.
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    Start-Process -FilePath 'wpeutil' -ArgumentList 'UpdateBootInfo' `
                        -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
                } catch { Write-Verbose "wpeutil UpdateBootInfo failed: $_" } finally { $ErrorActionPreference = $prev }

                Invoke-NetworkTuning
                Write-Status 'Acquiring network address...' 'Cyan'
                Update-HtmlUi -Message 'Acquiring network address...' -Step 2
                $script:_wait = 0
                $script:_initState = 'SETTLE'
            }
        }

        'SETTLE' {
            # Let NIC drivers and the DHCP Client service finish starting
            # after wpeinit before attempting ipconfig /renew.  The service
            # needs several seconds to initialise its RPC endpoint; calling
            # ipconfig too early produces "RPC server is unavailable" errors.
            if (++$script:_wait -ge $script:SettlePauseTicks) {
                # Ensure the DHCP Client service is running (idempotent).
                try {
                    Start-Process -FilePath 'net.exe' -ArgumentList 'start', 'dhcp' `
                        -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
                } catch { Write-Verbose "DHCP service start failed: $_" }
                $script:_dhcp = 0
                $script:_initState = 'DHCP'
            }
        }

        'DHCP' {
            $script:_dhcp++
            $script:_wait = 0
            try {
                $script:_proc = Start-Process -FilePath 'ipconfig.exe' `
                    -ArgumentList '/renew' -WindowStyle Hidden -PassThru `
                    -ErrorAction SilentlyContinue
            } catch { $script:_proc = $null }
            $script:_initState = 'DHCP_POLL'
        }

        'DHCP_POLL' {
            if ($null -eq $script:_proc -or $script:_proc.HasExited -or
                ++$script:_wait -ge $script:DhcpTimeoutTicks) {
                if ($script:_proc -and -not $script:_proc.HasExited) {
                    try { $script:_proc.Kill() } catch { Write-Verbose "Process already exited: $_" }
                }
                if (Test-HasValidIP) {
                    $script:_initState = 'CHECK'
                } elseif ($script:_dhcp -ge $script:MaxDhcpAttempts) {
                    $script:_initState = 'CHECK'
                } else {
                    $script:_wait = 0
                    $script:_initState = 'DHCP_WAIT'
                }
            }
        }

        'DHCP_WAIT' {
            if (++$script:_wait -ge $script:DhcpWaitPauseTicks) {
                $script:_initState = 'DHCP'
            }
        }

        'CHECK' {
            $script:initTimer.Stop()
            if (Test-InternetConnectivity) {
                Update-HtmlUi -Message $S.Connected -Step 3
                ProceedToEngine
            } else {
                Update-Step 2
                Write-Status $S.StatusNoNet 'Yellow'
                Update-HtmlUi -Message $S.StatusNoNet -Step 2 -ShowWiFi -ShowRetry

                # Periodically re-check wired connectivity so a late DHCP
                # lease or cable plug-in proceeds without manual action.
                $script:connectCheckTimer.Interval = $script:ConnectCheckIntervalMs
                $script:connectCheckTimer.Add_Tick({
                    if (Test-InternetConnectivity) {
                        $script:connectCheckTimer.Stop()
                        ProceedToEngine
                    }
                })
                $script:connectCheckTimer.Start()
            }
        }
    }
})

# ── Start the init state machine ────────────────────────────────────────────
Update-Step 1
Write-Status $S.StatusInit 'Cyan'
Update-HtmlUi -Message $S.StatusInit -Step 1
$script:initTimer.Start()

# ── Main message pump ──────────────────────────────────────────────────────
# Replaces the old $form.ShowDialog().  The DoEvents loop keeps WinForms
# timers and modal dialogs functional without a visible form.
# The loop exits when $script:ExitMainLoop is set (e.g. after imaging
# completes or a fatal error occurs).
$script:ExitMainLoop = $false
[System.Windows.Forms.Application]::EnableVisualStyles()
while (-not $script:ExitMainLoop) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 50
}
try { $script:HttpListener.Stop() } catch {}
try { $script:edgeWatchdogTimer.Stop() } catch {}
try { if ($script:hotkeyWindow) { $script:hotkeyWindow.Dispose() } } catch {}
Stop-Transcript -ErrorAction SilentlyContinue
#endregion

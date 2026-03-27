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
# (WiFi selector, configuration menu, M365 auth) and for the timer-based
# message pump.  The main visible UI is now the HTML page in Edge kiosk mode.
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
        [switch]$ShowRetry
    )
    if (-not $script:HtmlUiActive) { return }
    try {
        $obj = @{
            Message   = $Message
            Detail    = $Detail
            Progress  = 0
            Step      = $Step
            Done      = [bool]$Done
            ShowWiFi  = [bool]$ShowWiFi
            ShowRetry = [bool]$ShowRetry
        }
        $obj | ConvertTo-Json -Compress |
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

            switch ($path) {
                '/wifi'     { $script:PendingAction = 'SHOW_WIFI'; $msg = 'ok' }
                '/retry'    { $script:PendingAction = 'RETRY'; $msg = 'ok' }
                '/reboot'   { Restart-Computer -Force; $msg = 'rebooting' }
                '/shutdown' { Stop-Computer -Force; $msg = 'shutting down' }
                '/shell'    { Start-Process $script:PsBin -ArgumentList '-NoProfile','-NoExit'; $msg = 'shell opened' }
            }

            $context.Response.StatusCode = 200
            $buffer = [Text.Encoding]::UTF8.GetBytes($msg)
            $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
            $context.Response.Close()
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


#region ── Main Flow ─────────────────────────────────────────────────────────
$script:EngineStarted = $false

function Show-ConfigurationMenu {
    <#
    .SYNOPSIS  Unified pre-deployment configuration dialog.
    .DESCRIPTION
        Downloads the Microsoft ESD catalog and shows a single OOBE-style
        dialog where the user configures all deployment options before imaging
        begins: UI language, OS language, architecture, activation channel
        (Retail / Volume), and Windows edition.  Combos cascade — changing an
        upstream selection re-populates all downstream combos with valid
        entries from the catalog.
    .OUTPUTS   A hashtable with Language (EN/FR/ES), OsLanguage (catalog code
               e.g. en-us), Architecture (x64/ARM64), Activation (Retail/Volume),
               and Edition (string) keys.
    #>
    $defaultResult = @{ Language = 'EN'; OsLanguage = 'en-us';
                        Architecture = 'x64'; Activation = 'Retail';
                        Edition = '' }

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

    # Pre-process every catalog file once into a flat list with a derived
    # Activation field (Retail or Volume) parsed from the ESD FileName.
    # Known Microsoft ESD naming patterns:
    #   CLIENTCONSUMER_RET  → Retail  (Home, Pro, Education consumer editions)
    #   CLIENTBUSINESS_VOL  → Volume  (Enterprise and volume-licensed editions)
    $allFiles = @(
        $catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File | ForEach-Object {
            $activation = if ($_.FileName -match 'CLIENTBUSINESS_VOL') { 'Volume' } else { 'Retail' }
            [PSCustomObject]@{
                LanguageCode = $_.LanguageCode
                Language     = $_.Language
                Architecture = $_.Architecture
                Activation   = $activation
                Edition      = $_.Edition
            }
        }
    )

    $langMap   = @{ 'EN' = 'en-us'; 'FR' = 'fr-fr'; 'ES' = 'es-es' }
    $langCodes = @('EN', 'FR', 'ES')   # maps combo index → language code

    # ── Build the unified dialog ─────────────────────────────────────────────
    $accentBlue = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $edGradTop  = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(25, 25, 30) }    else { [System.Drawing.Color]::FromArgb(218, 232, 252) }
    $edGradBot  = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(38, 38, 44) } else { [System.Drawing.Color]::FromArgb(234, 240, 250) }
    $edCardBg   = if ($script:IsDarkMode) { $DarkCard }     else { $LightCard }
    $edFg       = if ($script:IsDarkMode) { $TextDark }     else { [System.Drawing.Color]::FromArgb(32, 32, 32) }
    $edSubtle   = if ($script:IsDarkMode) { [System.Drawing.Color]::Silver } else { [System.Drawing.Color]::FromArgb(100, 100, 100) }
    $edInputBg  = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(60, 60, 60) } else { [System.Drawing.Color]::FromArgb(245, 247, 250) }

    # Layout constants — left column (Language, Architecture) and right column
    # (OS Language, Activation) sit side-by-side; Edition spans the full width.
    $lx = 30;  $rx = 270;  $cw = 220   # left-x, right-x, combo width
    $lblFont = New-Object System.Drawing.Font('Segoe UI', 9)
    $cmbFont = New-Object System.Drawing.Font('Segoe UI', 10)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'AmpCloud'
    $dlg.Size            = New-Object System.Drawing.Size(580, 600)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'None'
    $dlg.BackColor       = $edGradTop
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.ShowInTaskbar   = $true

    try {
        $edType = $dlg.GetType()
        $edDb   = $edType.GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($edDb) { $edDb.SetValue($dlg, $true, $null) }
    } catch { Write-Verbose "Config dialog double-buffering unavailable: $_" }

    $dlg.Add_Paint({
        $g = $_.Graphics
        $dw = $dlg.ClientSize.Width;  $dh = $dlg.ClientSize.Height
        if ($dw -le 0 -or $dh -le 0) { return }
        $gr = New-Object System.Drawing.Rectangle(0, 0, $dw, $dh)
        $gb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                  $gr, $edGradTop, $edGradBot,
                  [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
        $g.FillRectangle($gb, $gr)
        $gb.Dispose()
    })

    # ── Card panel ──────────────────────────────────────────────────────────
    $card = New-Object System.Windows.Forms.Panel
    $card.Location  = New-Object System.Drawing.Point(30, 30)
    $card.Size      = New-Object System.Drawing.Size(520, 540)
    $card.BackColor = $edCardBg
    $dlg.Controls.Add($card)

    $card.Add_SizeChanged({
        if ($card.Width -le 0 -or $card.Height -le 0) { return }
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $rr = 12
        $p.AddArc(0, 0, $rr * 2, $rr * 2, 180, 90)
        $p.AddArc($card.Width - $rr * 2, 0, $rr * 2, $rr * 2, 270, 90)
        $p.AddArc($card.Width - $rr * 2, $card.Height - $rr * 2, $rr * 2, $rr * 2, 0, 90)
        $p.AddArc(0, $card.Height - $rr * 2, $rr * 2, $rr * 2, 90, 90)
        $p.CloseFigure()
        if ($card.Region) { $card.Region.Dispose() }
        $card.Region = New-Object System.Drawing.Region($p)
        $p.Dispose()
    })

    # ── Title ───────────────────────────────────────────────────────────────
    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text      = 'A M P C L O U D'
    $titleLbl.Location  = New-Object System.Drawing.Point(0, 22)
    $titleLbl.Size      = New-Object System.Drawing.Size(520, 36)
    $titleLbl.Font      = New-Object System.Drawing.Font('Segoe UI Light', 20)
    $titleLbl.ForeColor = $accentBlue
    $titleLbl.TextAlign = 'MiddleCenter'
    $card.Controls.Add($titleLbl)

    # ── Subtitle ────────────────────────────────────────────────────────────
    $subLbl = New-Object System.Windows.Forms.Label
    $subLbl.Text      = $S.ConfigSubtitle
    $subLbl.Location  = New-Object System.Drawing.Point(0, 62)
    $subLbl.Size      = New-Object System.Drawing.Size(520, 22)
    $subLbl.ForeColor = $edSubtle
    $subLbl.TextAlign = 'MiddleCenter'
    $card.Controls.Add($subLbl)

    # ── Row 1: Language (left) + OS Language (right) ─────────────────────────
    $langLabel = New-Object System.Windows.Forms.Label
    $langLabel.Text      = $S.ConfigLang
    $langLabel.Location  = New-Object System.Drawing.Point($lx, 105)
    $langLabel.Size      = New-Object System.Drawing.Size($cw, 20)
    $langLabel.ForeColor = $edFg
    $langLabel.Font      = $lblFont
    $card.Controls.Add($langLabel)

    $langCombo = New-Object System.Windows.Forms.ComboBox
    $langCombo.Items.AddRange(@('English (EN)', "Fran$([char]0xE7)ais (FR)", "Espa$([char]0xF1)ol (ES)"))
    $langCombo.SelectedIndex  = 0
    $langCombo.Location       = New-Object System.Drawing.Point($lx, 127)
    $langCombo.Width          = $cw
    $langCombo.DropDownStyle  = 'DropDownList'
    $langCombo.FlatStyle      = 'Flat'
    $langCombo.BackColor      = $edInputBg
    $langCombo.ForeColor      = $edFg
    $langCombo.Font           = $cmbFont
    $card.Controls.Add($langCombo)

    $osLangLabel = New-Object System.Windows.Forms.Label
    $osLangLabel.Text      = $S.ConfigOsLang
    $osLangLabel.Location  = New-Object System.Drawing.Point($rx, 105)
    $osLangLabel.Size      = New-Object System.Drawing.Size($cw, 20)
    $osLangLabel.ForeColor = $edFg
    $osLangLabel.Font      = $lblFont
    $card.Controls.Add($osLangLabel)

    $osLangCombo = New-Object System.Windows.Forms.ComboBox
    $osLangCombo.DropDownStyle = 'DropDownList'
    $osLangCombo.FlatStyle     = 'Flat'
    $osLangCombo.Location      = New-Object System.Drawing.Point($rx, 127)
    $osLangCombo.Width         = $cw
    $osLangCombo.BackColor     = $edInputBg
    $osLangCombo.ForeColor     = $edFg
    $osLangCombo.Font          = $cmbFont
    $card.Controls.Add($osLangCombo)

    # ── Row 2: Architecture (left) + Activation (right) ─────────────────────
    $archLabel = New-Object System.Windows.Forms.Label
    $archLabel.Text      = $S.ConfigArch
    $archLabel.Location  = New-Object System.Drawing.Point($lx, 178)
    $archLabel.Size      = New-Object System.Drawing.Size($cw, 20)
    $archLabel.ForeColor = $edFg
    $archLabel.Font      = $lblFont
    $card.Controls.Add($archLabel)

    $archCombo = New-Object System.Windows.Forms.ComboBox
    $archCombo.DropDownStyle = 'DropDownList'
    $archCombo.FlatStyle     = 'Flat'
    $archCombo.Location      = New-Object System.Drawing.Point($lx, 200)
    $archCombo.Width         = $cw
    $archCombo.BackColor     = $edInputBg
    $archCombo.ForeColor     = $edFg
    $archCombo.Font          = $cmbFont
    $card.Controls.Add($archCombo)

    $actLabel = New-Object System.Windows.Forms.Label
    $actLabel.Text      = $S.ConfigActivation
    $actLabel.Location  = New-Object System.Drawing.Point($rx, 178)
    $actLabel.Size      = New-Object System.Drawing.Size($cw, 20)
    $actLabel.ForeColor = $edFg
    $actLabel.Font      = $lblFont
    $card.Controls.Add($actLabel)

    $actCombo = New-Object System.Windows.Forms.ComboBox
    $actCombo.DropDownStyle = 'DropDownList'
    $actCombo.FlatStyle     = 'Flat'
    $actCombo.Location      = New-Object System.Drawing.Point($rx, 200)
    $actCombo.Width         = $cw
    $actCombo.BackColor     = $edInputBg
    $actCombo.ForeColor     = $edFg
    $actCombo.Font          = $cmbFont
    $card.Controls.Add($actCombo)

    # ── Row 3: Edition (full-width) ─────────────────────────────────────────
    $edLabel = New-Object System.Windows.Forms.Label
    $edLabel.Text      = $S.ConfigEdition
    $edLabel.Location  = New-Object System.Drawing.Point($lx, 253)
    $edLabel.Size      = New-Object System.Drawing.Size(460, 20)
    $edLabel.ForeColor = $edFg
    $edLabel.Font      = $lblFont
    $card.Controls.Add($edLabel)

    $edCombo = New-Object System.Windows.Forms.ComboBox
    $edCombo.DropDownStyle = 'DropDownList'
    $edCombo.FlatStyle     = 'Flat'
    $edCombo.Location      = New-Object System.Drawing.Point($lx, 275)
    $edCombo.Width         = 460
    $edCombo.BackColor     = $edInputBg
    $edCombo.ForeColor     = $edFg
    $edCombo.Font          = $cmbFont
    $card.Controls.Add($edCombo)

    # ── Cascading population helpers ────────────────────────────────────────
    # Each helper repopulates its combo from the catalog, filtered by the
    # current upstream selections, then triggers the next downstream helper.

    $populateEditions = {
        $selLang = if ($null -ne $osLangCombo.SelectedItem) { $osLangCombo.SelectedItem.ToString().Split(' ')[0] } else { 'en-us' }
        $selArch = if ($null -ne $archCombo.SelectedItem)   { $archCombo.SelectedItem.ToString() } else { 'x64' }
        $selAct  = if ($null -ne $actCombo.SelectedItem)    { $actCombo.SelectedItem.ToString()  } else { 'Retail' }
        $editions = @(
            $allFiles | Where-Object {
                $_.LanguageCode -eq $selLang -and
                $_.Architecture -eq $selArch -and
                $_.Activation   -eq $selAct
            } | Select-Object -ExpandProperty Edition | Sort-Object -Unique
        )
        $prev = if ($null -ne $edCombo.SelectedItem) { $edCombo.SelectedItem.ToString() } else { '' }
        $edCombo.Items.Clear()
        if ($editions -and $editions.Count -gt 0) {
            $edCombo.Items.AddRange($editions)
            $idx = [Array]::IndexOf($editions, $prev)
            if ($idx -lt 0) {
                # Prefer Professional > any Pro-like > first item
                $idx = 0
                for ($i = 0; $i -lt $editions.Count; $i++) {
                    if ($editions[$i] -eq 'Professional') { $idx = $i; break }
                }
                if ($editions[$idx] -ne 'Professional') {
                    for ($i = 0; $i -lt $editions.Count; $i++) {
                        if ($editions[$i] -like '*Pro*' -and
                            $editions[$i] -notlike '*Education*' -and
                            $editions[$i] -notlike '*Workstation*') {
                            $idx = $i; break
                        }
                    }
                }
            }
            $edCombo.SelectedIndex = $idx
        }
    }

    $populateActivations = {
        $selLang = if ($null -ne $osLangCombo.SelectedItem) { $osLangCombo.SelectedItem.ToString().Split(' ')[0] } else { 'en-us' }
        $selArch = if ($null -ne $archCombo.SelectedItem)   { $archCombo.SelectedItem.ToString() } else { 'x64' }
        $acts = @(
            $allFiles | Where-Object {
                $_.LanguageCode -eq $selLang -and
                $_.Architecture -eq $selArch
            } | Select-Object -ExpandProperty Activation | Sort-Object -Unique
        )
        $prev = if ($null -ne $actCombo.SelectedItem) { $actCombo.SelectedItem.ToString() } else { '' }
        $actCombo.Items.Clear()
        if ($acts -and $acts.Count -gt 0) {
            $actCombo.Items.AddRange($acts)
            $idx = [Array]::IndexOf($acts, $prev)
            if ($idx -lt 0) { $idx = 0 }
            $actCombo.SelectedIndex = $idx
        }
        & $populateEditions
    }

    $populateArchitectures = {
        $selLang = if ($null -ne $osLangCombo.SelectedItem) { $osLangCombo.SelectedItem.ToString().Split(' ')[0] } else { 'en-us' }
        $archs = @(
            $allFiles | Where-Object { $_.LanguageCode -eq $selLang } |
                Select-Object -ExpandProperty Architecture | Sort-Object -Unique
        )
        $prev = if ($null -ne $archCombo.SelectedItem) { $archCombo.SelectedItem.ToString() } else { '' }
        $archCombo.Items.Clear()
        if ($archs -and $archs.Count -gt 0) {
            $archCombo.Items.AddRange($archs)
            $idx = [Array]::IndexOf($archs, $prev)
            if ($idx -lt 0) {
                # Prefer x64 as default
                $idx = [Array]::IndexOf($archs, 'x64')
                if ($idx -lt 0) { $idx = 0 }
            }
            $archCombo.SelectedIndex = $idx
        }
        & $populateActivations
    }

    $populateOsLanguages = {
        $osLangs = @(
            $allFiles | Group-Object LanguageCode | Sort-Object Name |
                ForEach-Object { "$($_.Name) — $($_.Group[0].Language)" }
        )
        $prev = if ($null -ne $osLangCombo.SelectedItem) { $osLangCombo.SelectedItem.ToString() } else { '' }
        $osLangCombo.Items.Clear()
        if ($osLangs -and $osLangs.Count -gt 0) {
            $osLangCombo.Items.AddRange($osLangs)
            $idx = -1
            if ($prev) {
                for ($i = 0; $i -lt $osLangs.Count; $i++) {
                    if ($osLangs[$i] -eq $prev) { $idx = $i; break }
                }
            }
            if ($idx -lt 0) {
                # Match UI language → OS language default
                $uiIdx      = $langCombo.SelectedIndex
                $uiLangCode = if ($uiIdx -ge 0 -and $uiIdx -lt $langCodes.Count) { $langCodes[$uiIdx] } else { 'EN' }
                $prefLang   = if ($langMap.ContainsKey($uiLangCode)) { $langMap[$uiLangCode] } else { 'en-us' }
                for ($i = 0; $i -lt $osLangs.Count; $i++) {
                    if ($osLangs[$i].StartsWith($prefLang)) { $idx = $i; break }
                }
                if ($idx -lt 0) { $idx = 0 }
            }
            $osLangCombo.SelectedIndex = $idx
        }
        & $populateArchitectures
    }

    # Initial population.
    & $populateOsLanguages

    # ── Wire cascade events ─────────────────────────────────────────────────
    $osLangCombo.Add_SelectedIndexChanged({ & $populateArchitectures })
    $archCombo.Add_SelectedIndexChanged({ & $populateActivations })
    $actCombo.Add_SelectedIndexChanged({ & $populateEditions })

    # ── Continue button ─────────────────────────────────────────────────────
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text                      = "$($S.ConfigBtn)  $([char]0x2192)"
    $btn.Location                  = New-Object System.Drawing.Point(160, 340)
    $btn.Size                      = New-Object System.Drawing.Size(200, 46)
    $btn.BackColor                 = $accentBlue
    $btn.ForeColor                 = [System.Drawing.Color]::White
    $btn.FlatStyle                 = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.Font                      = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor                    = [System.Windows.Forms.Cursors]::Hand
    $btn.DialogResult              = 'OK'
    $card.Controls.Add($btn)
    $dlg.AcceptButton = $btn

    # When the UI language changes, update labels + sync OS language default.
    $langCombo.Add_SelectedIndexChanged({
        $lCode = if ($langCombo.SelectedIndex -ge 0 -and $langCombo.SelectedIndex -lt $langCodes.Count) { $langCodes[$langCombo.SelectedIndex] } else { 'EN' }
        $tmpS  = $Strings[$lCode]
        $subLbl.Text     = $tmpS.ConfigSubtitle
        $langLabel.Text  = $tmpS.ConfigLang
        $osLangLabel.Text = $tmpS.ConfigOsLang
        $archLabel.Text  = $tmpS.ConfigArch
        $actLabel.Text   = $tmpS.ConfigActivation
        $edLabel.Text    = $tmpS.ConfigEdition
        $btn.Text        = "$($tmpS.ConfigBtn)  $([char]0x2192)"
        & $populateOsLanguages
    })

    # ── Company logo (bottom-right of card) ─────────────────────────────────
    $cfgBrand = New-Object System.Windows.Forms.Label
    $cfgBrand.Text      = 'ampliosoft'
    $cfgBrand.Location  = New-Object System.Drawing.Point(400, 505)
    $cfgBrand.Size      = New-Object System.Drawing.Size(110, 20)
    $cfgBrand.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $cfgBrand.ForeColor = $edSubtle
    $cfgBrand.TextAlign = 'MiddleRight'
    $cfgBrand.BackColor = $edCardBg
    $card.Controls.Add($cfgBrand)

    if ($dlg.ShowDialog() -eq 'OK') {
        $langCode   = if ($langCombo.SelectedIndex -ge 0 -and $langCombo.SelectedIndex -lt $langCodes.Count) { $langCodes[$langCombo.SelectedIndex] } else { 'EN' }
        $osLang     = if ($null -ne $osLangCombo.SelectedItem) { $osLangCombo.SelectedItem.ToString().Split(' ')[0] } else { 'en-us' }
        $arch       = if ($null -ne $archCombo.SelectedItem)   { $archCombo.SelectedItem.ToString() } else { 'x64' }
        $activation = if ($null -ne $actCombo.SelectedItem)    { $actCombo.SelectedItem.ToString()  } else { 'Retail' }
        $edition    = if ($null -ne $edCombo.SelectedItem)     { $edCombo.SelectedItem.ToString()   } else { '' }
        return @{ Language = $langCode; OsLanguage = $osLang;
                  Architecture = $arch; Activation = $activation;
                  Edition = $edition }
    }
    return $defaultResult
}

#region ── M365 Authentication ────────────────────────────────────────────────

function Invoke-M365EdgeAuth {
    <#
    .SYNOPSIS  Authenticate the operator via a standalone Edge browser (Auth Code + PKCE).
    .DESCRIPTION
        Launches msedge.exe directly in WinPE with GPU-disabled flags and
        navigates to the Azure AD authorization endpoint.  The user signs in
        inside the standalone Edge browser window.  A temporary localhost
        HTTP listener captures the redirect carrying the authorization code,
        then exchanges it for tokens using PKCE.
        Requires the Edge browser to be pre-staged in the WinPE image at
        X:\WebView2\Edge (done by Trigger.ps1 Build-WinPE step 4e).
        WinPE-safe Chromium flags (--disable-gpu, SwiftShader, etc.) are
        used to ensure rendering works without GPU hardware.
    .PARAMETER ClientId
        Azure AD application (client) ID.
    .OUTPUTS
        $true on success, $false on failure or cancellation.
    #>
    param(
        [string] $ClientId,
        [string] $Scope = 'openid profile'
    )

    $edgePath = 'X:\WebView2\Edge\msedge.exe'

    # ── Log environment diagnostics ─────────────────────────────────────────
    Write-AuthLog "Edge auth starting — checking prerequisites"
    Write-AuthLog "  msedge.exe exists : $(Test-Path $edgePath)  ($edgePath)"

    # ── Verify Edge browser prerequisite ────────────────────────────────────
    if (-not (Test-Path $edgePath)) {
        Write-AuthLog "msedge.exe not found at $edgePath — skipping Edge auth."
        return $false
    }

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

    # ── Launch Edge with WinPE-safe Chromium flags ──────────────────────────
    # WinPE has no GPU hardware or driver stack.  These flags force Chromium
    # to use SwiftShader (software OpenGL ES implementation) for rendering.
    # --allow-run-as-system permits Chromium to run under the SYSTEM account
    # (WinPE always runs as SYSTEM).
    # --user-data-dir avoids writing to the default profile path, which may
    # not be writable in WinPE.
    # --no-first-run / --disable-fre suppress Edge first-run experience
    # screens (welcome wizard, default-browser prompt, etc.).
    # --disable-features=msWebOOBE suppresses the Edge out-of-box setup.
    # WebAuthentication is left enabled so that the cross-device / hybrid
    # (caBLE v2) flow works — the user can scan a QR code with a phone
    # (e.g. iPhone or Android) to complete FIDO2 / passkey authentication.
    # Platform authenticators (TPM, Windows Hello, biometrics) are
    # unavailable in WinPE, but Edge automatically skips them when the
    # hardware is absent and offers the QR-code option instead.
    # --enable-features=WebAuthenticationCableSecondFactor explicitly
    # enables the cross-device QR code authenticator flow.
    $userDataDir = 'X:\Temp\EdgeAuthData'
    if (-not (Test-Path $userDataDir)) {
        $null = New-Item -Path $userDataDir -ItemType Directory -Force
    }

    $edgeArgs = @(
        '--allow-run-as-system'
        "--user-data-dir=`"$userDataDir`""
        '--disable-gpu'
        '--disable-gpu-compositing'
        '--disable-direct-composition'
        '--use-angle=swiftshader'
        '--enable-unsafe-swiftshader'
        '--in-process-gpu'
        '--no-first-run'
        '--disable-fre'
        '--disable-features=msWebOOBE'
        '--enable-features=WebAuthenticationCableSecondFactor'
        $authorizeUrl
    )

    Write-AuthLog "Launching Edge: $edgePath $($edgeArgs -join ' ')"
    $edgeProcess = $null
    try {
        $edgeProcess = Start-Process -FilePath $edgePath -ArgumentList $edgeArgs -PassThru
        Write-AuthLog "Edge launched (PID $($edgeProcess.Id))"
    } catch {
        Write-AuthLog "Failed to launch Edge: $_"
        return $false
    }

    # ── Show a WinForms status dialog while waiting for sign-in ─────────────
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'AmpCloud — Sign In'
    $dlg.Size            = New-Object System.Drawing.Size(480, 220)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = [System.Drawing.Color]::White
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.TopMost         = $false

    $msLabel = New-Object System.Windows.Forms.Label
    $msLabel.Text      = 'Microsoft 365'
    $msLabel.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
    $msLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $msLabel.Location  = New-Object System.Drawing.Point(30, 20)
    $msLabel.AutoSize  = $true
    $dlg.Controls.Add($msLabel)

    $promptLabel = New-Object System.Windows.Forms.Label
    $promptLabel.Text     = $S.AuthEdgePrompt
    $promptLabel.Location = New-Object System.Drawing.Point(30, 65)
    $promptLabel.Size     = New-Object System.Drawing.Size(410, 50)
    $promptLabel.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.Controls.Add($promptLabel)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text         = 'Cancel'
    $cancelBtn.Size         = New-Object System.Drawing.Size(120, 36)
    $cancelBtn.Location     = New-Object System.Drawing.Point(330, 135)
    $cancelBtn.DialogResult = 'Cancel'
    $cancelBtn.FlatStyle    = 'Flat'
    $dlg.Controls.Add($cancelBtn)
    $dlg.CancelButton = $cancelBtn

    # ── Poll the HTTP listener for the redirect in a timer ──────────────────
    $script:_edgeAuthCode  = $null
    $script:_edgeAuthError = $null
    $script:_edgeListener  = $listener
    $script:_edgeDlg       = $dlg
    $script:_edgeAsyncResult = $listener.BeginGetContext($null, $null)

    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 500
    $pollTimer.Add_Tick({
        if ($script:_edgeAsyncResult.IsCompleted -or $script:_edgeAsyncResult.AsyncWaitHandle.WaitOne(0)) {
            $pollTimer.Stop()
            try {
                $context = $script:_edgeListener.EndGetContext($script:_edgeAsyncResult)

                # Parse authorization code (or error) from the query string.
                foreach ($pair in $context.Request.Url.Query.TrimStart('?').Split('&')) {
                    $kv = $pair.Split('=', 2)
                    if ($kv.Count -eq 2) {
                        if ($kv[0] -eq 'code')  { $script:_edgeAuthCode  = [uri]::UnescapeDataString($kv[1]) }
                        if ($kv[0] -eq 'error') { $script:_edgeAuthError = [uri]::UnescapeDataString($kv[1]) }
                    }
                }

                # Send a friendly response page to the browser.
                $html = if ($script:_edgeAuthCode) {
                    '<html><body style="font-family:Segoe UI,sans-serif;text-align:center;padding:60px">' +
                    '<h2 style="color:#107c10">&#10004; Sign-in complete</h2>' +
                    '<p>You can close this window and return to AmpCloud.</p>' +
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
            } catch {
                Write-AuthLog "Listener callback error: $_"
            }

            if ($script:_edgeAuthCode) {
                $script:_edgeDlg.DialogResult = 'OK'
            } else {
                $script:_edgeDlg.DialogResult = 'Abort'
            }
            $script:_edgeDlg.Close()
        }
    })
    $pollTimer.Start()
    $dialogResult = $dlg.ShowDialog()
    $pollTimer.Stop()
    $pollTimer.Dispose()
    try { $dlg.Dispose() } catch {}

    # ── Stop the Edge process ───────────────────────────────────────────────
    if ($edgeProcess -and -not $edgeProcess.HasExited) {
        try {
            $edgeProcess.CloseMainWindow() | Out-Null
            if (-not $edgeProcess.WaitForExit(3000)) {
                $edgeProcess.Kill()
                $edgeProcess.WaitForExit(2000)
            }
            Write-AuthLog "Edge process stopped."
        } catch { Write-AuthLog "Edge process cleanup: $_" }
    }

    # Clean up Edge user data (cookies, cache) to prevent credential leakage.
    if (Test-Path $userDataDir) {
        try { Remove-Item $userDataDir -Recurse -Force } catch {}
    }

    } finally {
        try { $listener.Stop(); $listener.Close() } catch {}
    }

    if ($dialogResult -ne 'OK' -or -not $script:_edgeAuthCode) {
        $codeStatus = if ($script:_edgeAuthCode) { 'present' } else { 'missing' }
        Write-AuthLog "Edge auth dialog closed without auth code. DialogResult=$dialogResult, AuthCode=$codeStatus"
        if ($script:_edgeAuthError) {
            Write-AuthLog "Edge auth error: $($script:_edgeAuthError)"
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
            Write-AuthLog "Edge auth succeeded — token obtained."
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
        Fallback authentication path used when the Edge browser is not
        available in the WinPE image.  Initiates the Device Code Flow and
        shows a WinForms dialog with the one-time code and verification URL.
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

    # ── Device Code dialog ──────────────────────────────────────────────────
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'AmpCloud — Sign In'
    $dlg.Size            = New-Object System.Drawing.Size(520, 380)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = [System.Drawing.Color]::White
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 10)

    $msLabel = New-Object System.Windows.Forms.Label
    $msLabel.Text      = 'Microsoft 365'
    $msLabel.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
    $msLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $msLabel.Location  = New-Object System.Drawing.Point(30, 25)
    $msLabel.AutoSize  = $true
    $dlg.Controls.Add($msLabel)

    $promptLabel = New-Object System.Windows.Forms.Label
    $promptLabel.Text     = $S.AuthDeviceCodePrompt
    $promptLabel.Location = New-Object System.Drawing.Point(30, 75)
    $promptLabel.Size     = New-Object System.Drawing.Size(450, 50)
    $promptLabel.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.Controls.Add($promptLabel)

    $codeBox = New-Object System.Windows.Forms.TextBox
    $codeBox.Text      = $userCode
    $codeBox.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 26)
    $codeBox.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $codeBox.TextAlign = 'Center'
    $codeBox.ReadOnly  = $true
    $codeBox.BorderStyle = 'None'
    $codeBox.BackColor = [System.Drawing.Color]::FromArgb(243, 243, 243)
    $codeBox.Location  = New-Object System.Drawing.Point(60, 135)
    $codeBox.Size      = New-Object System.Drawing.Size(380, 55)
    $dlg.Controls.Add($codeBox)

    $urlLabel = New-Object System.Windows.Forms.Label
    $urlLabel.Text      = $S.AuthUrl
    $urlLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Underline)
    $urlLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $urlLabel.Location  = New-Object System.Drawing.Point(30, 210)
    $urlLabel.AutoSize  = $true
    $dlg.Controls.Add($urlLabel)

    $authStatusLabel = New-Object System.Windows.Forms.Label
    $authStatusLabel.Text      = $S.AuthWaiting
    $authStatusLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
    $authStatusLabel.ForeColor = [System.Drawing.Color]::Gray
    $authStatusLabel.Location  = New-Object System.Drawing.Point(30, 250)
    $authStatusLabel.Size      = New-Object System.Drawing.Size(450, 25)
    $dlg.Controls.Add($authStatusLabel)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text         = 'Cancel'
    $cancelBtn.Size         = New-Object System.Drawing.Size(120, 40)
    $cancelBtn.Location     = New-Object System.Drawing.Point(370, 290)
    $cancelBtn.DialogResult = 'Cancel'
    $cancelBtn.FlatStyle    = 'Flat'
    $dlg.Controls.Add($cancelBtn)
    $dlg.CancelButton = $cancelBtn

    # ── Poll for token in a timer ───────────────────────────────────────────
    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = $interval * 1000
    $script:_authExpiry   = [datetime]::UtcNow.AddSeconds($expiresIn)
    $script:_authResult   = $null
    $script:_deviceCode   = $deviceCode
    $script:_clientId     = $ClientId
    $script:_tokenUrl     = $tokenUrl
    $script:_grantType    = $grantType

    $pollTimer.Add_Tick({
        if ([datetime]::UtcNow -ge $script:_authExpiry) {
            $pollTimer.Stop()
            $authStatusLabel.Text = $S.AuthFailed
            $authStatusLabel.ForeColor = [System.Drawing.Color]::Red
            return
        }
        try {
            $body = "grant_type=$([uri]::EscapeDataString($script:_grantType))" +
                    "&client_id=$([uri]::EscapeDataString($script:_clientId))" +
                    "&device_code=$([uri]::EscapeDataString($script:_deviceCode))"
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
            $raw = $wc.UploadString($script:_tokenUrl, 'POST', $body)
            $tokenResponse = $raw | ConvertFrom-Json
            if ($tokenResponse.id_token) {
                $script:_authResult = $tokenResponse
                if ($tokenResponse.access_token) {
                    $script:GraphAccessToken = $tokenResponse.access_token
                }
                $pollTimer.Stop()
                $dlg.DialogResult = 'OK'
                $dlg.Close()
            }
        } catch {
            $msg = $_.ToString()
            if ($msg -notmatch 'authorization_pending' -and $msg -notmatch 'slow_down') {
                Write-AuthLog "Token poll error: $msg"
            }
        }
    })
    $pollTimer.Start()
    $dialogResult = $dlg.ShowDialog()
    $pollTimer.Stop()
    $pollTimer.Dispose()

    if ($dialogResult -ne 'OK' -or -not $script:_authResult) {
        return $false
    }

    return $true
}

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
    # Uses a standalone Edge browser with Auth Code + PKCE as
    # the primary method; falls back to Device Code Flow if the Edge
    # browser is not present in the WinPE image.
    $authPassed = Invoke-M365Auth
    if (-not $authPassed) {
        $script:EngineStarted = $false   # allow retry after WiFi reconnect
        return
    }

    # ── Autopilot device import ─────────────────────────────────────────────
    # When autopilotImport is enabled in auth.json and a Graph access token
    # was obtained during sign-in, register the device in Autopilot via
    # the Microsoft Graph API (delegated permissions — no client secret).
    # The device is only imported if it is not already registered.
    if ($script:AuthConfig -and $script:AuthConfig.autopilotImport -and $script:GraphAccessToken) {
        Write-AuthLog "Autopilot import enabled — checking device registration..."
        try {
            $serial = $null
            try { $serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber } catch {}
            if ($serial -and $serial.Trim() -ne '') {
                $sanitized = $serial -replace "['\\\x00-\x1f]", ''
                $filter = [uri]::EscapeDataString("contains(serialNumber,'$sanitized')")
                $uri    = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"
                $check  = Invoke-RestMethod -Uri $uri -Headers @{
                    'Authorization' = "Bearer $($script:GraphAccessToken)"
                } -Method GET

                if ($check.value -and $check.value.Count -gt 0) {
                    Write-AuthLog "Device $serial is already registered in Autopilot — skipping import."
                } else {
                    Write-AuthLog "Device $serial not found in Autopilot — it will be imported during the task sequence."
                }
            } else {
                Write-AuthLog "Could not determine device serial number — skipping Autopilot check."
            }
        } catch {
            Write-AuthLog "Autopilot check failed (non-fatal): $_"
        }
    }

    Update-Step 4

    # Unified configuration dialog: language + all Windows options in one step.
    $config = Show-ConfigurationMenu
    $script:Lang = $config.Language
    $script:S    = $Strings[$script:Lang]
    $script:SelectedEdition  = $config.Edition
    $script:SelectedOsLang   = $config.OsLanguage
    $script:SelectedArch     = $config.Architecture
    $script:SelectedActivation = $config.Activation

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
                    '-FirmwareType', $detectedFirmware)
        if ($script:SelectedEdition)  { $psArgs += @('-WindowsEdition',      $script:SelectedEdition)  }
        if ($script:SelectedOsLang)   { $psArgs += @('-WindowsLanguage',     $script:SelectedOsLang)   }
        if ($script:SelectedArch)     { $psArgs += @('-WindowsArchitecture', $script:SelectedArch)     }

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
        # Engine already printed diagnostics; the -NoExit PowerShell host
        # from ampcloud-start.cmd provides the interactive prompt for
        # troubleshooting.
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
[System.Windows.Forms.Application]::EnableVisualStyles()
while ($true) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 50
}
Stop-Transcript -ErrorAction SilentlyContinue
#endregion

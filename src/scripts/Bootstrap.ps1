#Requires -Version 5.1
<#
.SYNOPSIS
    Nova Bootstrap - WinRE/WinPE loader with HTML UI.
.DESCRIPTION
    Runs inside the WinRE/WinPE boot environment via winpeshl.ini.
    - Calls wpeinit.exe to initialise the WinPE network stack and DHCP.
    - The main visible UI runs in Edge kiosk mode (Nova-UI/index.html).
    - Communicates with the HTML UI via a JSON status file and HTTP API.
    - Applies high-performance network tuning.
    - Offers an interactive graphical WiFi selector when wired internet is unavailable.
    - Shows a unified configuration dialog (language + Windows edition) once connected.
    - Downloads and executes Nova.ps1 from GitHub once connected.
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$GitHubUser   = 'araduti',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubRepo   = 'Nova',
    [ValidateNotNullOrEmpty()]
    [string]$GitHubBranch = 'main',
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxWaitSeconds  = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Referenced in nested functions via closure (Resolve-LocaleStrings, Show-WinPEConfiguration, etc.)
$null = $GitHubUser, $GitHubRepo, $GitHubBranch, $MaxWaitSeconds

# ── Shell path───────────────────────────────────────────────────────────────
# Resolved once at startup so WinPE's fixed X:\ path is used reliably.
$script:PsBin = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ── Logging ─────────────────────────────────────────────────────────────────
$LogPath = "X:\Nova-Bootstrap.log"
$null = Start-Transcript -Path $LogPath -Append -Force -ErrorAction SilentlyContinue

$script:AuthLogPath = "X:\Nova-Auth.log"

# ── Import shared modules ──────────────────────────────────────────────────────
$script:ModulesRoot = if (Test-Path "$PSScriptRoot\..\modules") {
    "$PSScriptRoot\..\modules"
} elseif (Test-Path 'X:\Windows\System32\Modules') {
    'X:\Windows\System32\Modules'
} else {
    "$PSScriptRoot\..\modules"   # Best-effort fallback
}
Import-Module "$script:ModulesRoot\Nova.Network" -Force -ErrorAction Stop

function Write-AuthLog {
    <#
    .SYNOPSIS  Write a timestamped entry to the dedicated auth log file.
    .DESCRIPTION
        Always writes to X:\Nova-Auth.log regardless of the Verbose
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
# When the HTML Progress UI is running (launched by nova-start.cmd
# before PowerShell), Bootstrap.ps1 writes status to the same JSON file that
# Nova.ps1 uses.  This flag is cleared once Nova.ps1 starts so that
# Bootstrap.ps1 stops writing and only reads (avoiding write conflicts).
$script:HtmlUiActive = $true

function Update-HtmlUi {
    <#
    .SYNOPSIS  Write status to the JSON IPC file for the HTML UI.
    .DESCRIPTION
        Mirrors status updates to X:\Nova-Status.json so the HTML UI
        (running in Edge kiosk mode) can display real-time progress during the
        bootstrap phase before Nova.ps1 takes over.
    #>
    [CmdletBinding(SupportsShouldProcess)]
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
    } catch { $null = $_ }
}

#region ── Language System───────────────────────────────────────────────────
$script:Lang = 'EN'

# Locale strings are loaded from config/locale/<lang>.json.  The function
# below downloads a locale file from the GitHub repository (same pattern used
# for auth.json), converts it to a hashtable, and normalizes \n escape
# sequences into real newlines so WinForms labels render them correctly.
function Import-LocaleJson {
    param([string]$LangCode)
    $code = $LangCode.ToLower()
    $url  = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/locale/$code.json"
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
        Header="N O V A"; Subtitle="Cloud Imaging Engine";
        Step1="Network"; Step2="Connect"; Step3="Sign in"; Step4="Deploy";
        StatusInit="Initialising network stack...";
        StatusNoNet="No wired connection detected`nTap below to join Wi-Fi";
        Connected="Connected - verifying identity";
        Download="Downloading Nova.ps1  ({0}%)";
        Complete="Ready to deploy";
        Reboot="Restart now"; PowerOff="Shut down"; Shell="Command prompt";
        Imaging="Imaging in progress...";
        CatalogFetch="Loading Windows catalog...";
        CatalogFail="Could not load catalog - using default edition.";
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
$LightCard   = [System.Drawing.Color]::White
$DarkCard    = [System.Drawing.Color]::FromArgb(45, 45, 45)

$script:IsDarkMode  = $false
$BodyFont    = New-Object System.Drawing.Font("Segoe UI", 11)
#endregion

#region ── Network + WiFi Functions ─────────────────────────────────────────

# Invoke-NetworkTuning, Test-HasValidIP, Test-InternetConnectivity,
# Start-WlanService, Get-WiFiNetwork, Get-SignalBar, and Connect-WiFiNetwork
# are now provided by the Nova.Network module (imported above).

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
# The HTML UI (Nova-UI/index.html running in Edge kiosk mode) sends user
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

# ── Status file path (shared with Nova.ps1) ─────────────────────────────────
$script:StatusFile = "X:\Nova-Status.json"

# ── Helper functions (route through HTML UI) ────────────────────────────────
function Write-Status {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Verbose "Status: $Message ($Color)"
    Update-HtmlUi -Message $Message
}

function Update-Step { [CmdletBinding(SupportsShouldProcess)] param([int]$s)
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
                    # Serve Nova-UI/index.html so the browser can return
                    # from an HTTP context (e.g. after OAuth redirect) without
                    # requiring a blocked http→file:// navigation.
                    $handled = $true
                    $uiFile  = 'X:\Nova-UI\index.html'
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
                    # Serve Nova-Status.json for pages loaded via HTTP
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

public class NovaHotkeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int WM_HOTKEY = 0x0312;
    private const uint VK_F8    = 0x77;
    private const int  HOTKEY_ID = 1;

    public event Action HotkeyPressed;

    public NovaHotkeyWindow() {
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

    $script:hotkeyWindow = New-Object NovaHotkeyWindow
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
# Prevention:
#   --disable-renderer-backgrounding      Keeps the renderer process active
#   --disable-background-timer-throttling  Prevents JS timer throttling
#   --disable-backgrounding-occluded-windows  No backgrounding for hidden windows
#   --disable-hang-monitor                 Stops the browser from killing
#                                          "unresponsive" renderers during
#                                          long operations (ESD downloads)
#   The HTML UI also runs a requestAnimationFrame keep-alive loop that
#   forces continuous compositor repaints.
#
# Recovery (if crash still occurs):
#   The watchdog tracks two signals:
#   1. Process exit  — all msedge.exe processes have terminated.
#   2. Heartbeat loss — the HTML UI sends a /heartbeat every 10 s.
#      If no heartbeat arrives for 30+ seconds the renderer has likely
#      crashed while the browser chrome process may still be alive.
#
# On either signal the watchdog kills any remaining Edge processes, clears
# the user-data dir lock files, and relaunches Edge with the original args.

$script:EdgeExe  = 'X:\WebView2\Edge\msedge.exe'
$script:EdgeUserDataDir = 'X:\Temp\EdgeKiosk'
$script:EdgeArgs = @(
    '--kiosk',           'file:///X:/Nova-UI/index.html',
    '--kiosk-type=fullscreen',
    '--allow-run-as-system',
    "--user-data-dir=$($script:EdgeUserDataDir)",
    '--disable-gpu',
    '--disable-gpu-compositing',
    '--disable-direct-composition',
    '--use-angle=swiftshader',
    '--enable-unsafe-swiftshader',
    '--in-process-gpu',
    '--no-first-run',
    '--disable-fre',
    '--disable-features=msWebOOBE,PasswordManager',
    '--password-store=basic',
    '--guest',
    '--disable-save-password-bubble',
    '--allow-file-access-from-files',
    '--disable-popup-blocking',
    '--disable-renderer-backgrounding',
    '--disable-background-timer-throttling',
    '--disable-backgrounding-occluded-windows',
    '--disable-hang-monitor'
)

$script:_lastHeartbeat        = [DateTime]::UtcNow
$script:_edgeWatchdogGraceEnd = ([DateTime]::UtcNow).AddSeconds(60)

function Restart-Edge {
    <#
    .SYNOPSIS  Kill all Edge processes and relaunch the kiosk UI.
    #>
    [CmdletBinding(SupportsShouldProcess)] param()
    Write-Verbose 'Edge watchdog — restarting Edge'
    # Terminate every msedge process
    Get-Process -Name 'msedge' -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.Kill() } catch { $null = $_ } }
    Start-Sleep -Seconds 2
    # Remove stale lock files so Edge starts cleanly
    Remove-Item (Join-Path $script:EdgeUserDataDir 'lockfile')     -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $script:EdgeUserDataDir 'SingletonLock') -Force -ErrorAction SilentlyContinue
    if (Test-Path $script:EdgeExe) {
        Start-Process -FilePath $script:EdgeExe -ArgumentList $script:EdgeArgs
    }
    $script:_lastHeartbeat = [DateTime]::UtcNow
}

$script:edgeWatchdogTimer = New-Object System.Windows.Forms.Timer
$script:edgeWatchdogTimer.Interval = 10000   # check every 10 seconds

$script:edgeWatchdogTimer.Add_Tick({
    # Grace period: give Edge enough time to start on first boot before
    # the watchdog begins monitoring heartbeats.
    if ([DateTime]::UtcNow -lt $script:_edgeWatchdogGraceEnd) { return }

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
                        UserLocale = ''; UILanguage = ''; ComputerName = '';
                        TaskSequencePath = '' }

    # ── Download products.xml ─────────────────────────────────────────────
    Write-Status $S.CatalogFetch 'Cyan'
    [System.Windows.Forms.Application]::DoEvents()

    $scratchPath = 'X:\Nova'
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
            $tsUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/resources/task-sequence/default.json"
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
                    } elseif ($sp.namingSource -or $sp.prefix -or $sp.suffix -or $sp.useSerialNumber) {
                        # Generate a preview name from naming rules
                        $source = if ($sp.namingSource) { $sp.namingSource }
                                  elseif ($sp.useSerialNumber) { 'serialNumber' }
                                  else { 'randomDigits' }
                        $base = ''
                        switch ($source) {
                            'serialNumber' {
                                try { $base = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber -replace '[^A-Za-z0-9]','' } catch { $base = '' }
                            }
                            'assetTag' {
                                try { $base = (Get-CimInstance -ClassName Win32_SystemEnclosure).SMBIOSAssetTag -replace '[^A-Za-z0-9]','' } catch { $base = '' }
                            }
                            'macAddress' {
                                try {
                                    $mac = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.MACAddress } | Select-Object -First 1).MACAddress
                                    $mac = if ($mac) { $mac -replace '[:\-]','' } else { '' }
                                    if ($mac.Length -ge 12) { $base = $mac.Substring(6) }
                                } catch { $base = '' }
                            }
                            'deviceModel' {
                                try { $base = (Get-CimInstance -ClassName Win32_ComputerSystem).Model -replace '[^A-Za-z0-9]','' } catch { $base = '' }
                            }
                            'randomDigits' {
                                $count = if ($sp.randomDigitCount -gt 0) { [math]::Min($sp.randomDigitCount, 10) } else { 4 }
                                $min = [int][math]::Pow(10, $count - 1)
                                $max = [int][math]::Pow(10, $count)
                                $base = (Get-Random -Minimum ([int]$min) -Maximum ([int]$max)).ToString()
                            }
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

        ComputerName and locale settings are also injected into the
        CustomizeOOBE step's unattendContent XML, keeping the task sequence
        as the single source of truth for unattend.xml content.
    #>
    [CmdletBinding(SupportsShouldProcess)]
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

    # ── Update unattendContent in CustomizeOOBE with ComputerName / locale ──
    # This connects the config-modal choices directly to the unattend.xml
    # stored in the task sequence so the engine writes it as-is.
    $hasUnattendChanges = $Config.ComputerName -or $Config.InputLocale -or
                          $Config.SystemLocale -or $Config.UserLocale -or
                          $Config.UILanguage
    if ($hasUnattendChanges) {
        $oobeStep = $ts.steps | Where-Object { $_.type -eq 'CustomizeOOBE' } | Select-Object -First 1
        if ($oobeStep -and $oobeStep.parameters) {
            $src = $oobeStep.parameters.unattendSource
            if (-not $src -or $src -eq 'default') {
                $defaultXml = @"
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
                $xml = if ($oobeStep.parameters.unattendContent) { $oobeStep.parameters.unattendContent } else { $defaultXml }
                try {
                    [xml]$xd = $xml
                    $nsMgr = New-Object System.Xml.XmlNamespaceManager($xd.NameTable)
                    $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')

                    # ComputerName → specialize pass
                    if ($Config.ComputerName) {
                        $specSetting = $xd.SelectSingleNode('//u:settings[@pass="specialize"]', $nsMgr)
                        if (-not $specSetting) {
                            $specSetting = $xd.CreateElement('settings', 'urn:schemas-microsoft-com:unattend')
                            $specSetting.SetAttribute('pass', 'specialize')
                            $xd.DocumentElement.AppendChild($specSetting) | Out-Null
                        }
                        $shellComp = $specSetting.SelectSingleNode('u:component[@name="Microsoft-Windows-Shell-Setup"]', $nsMgr)
                        if (-not $shellComp) {
                            $shellComp = $xd.CreateElement('component', 'urn:schemas-microsoft-com:unattend')
                            $shellComp.SetAttribute('name', 'Microsoft-Windows-Shell-Setup')
                            $shellComp.SetAttribute('processorArchitecture', 'amd64')
                            $shellComp.SetAttribute('publicKeyToken', '31bf3856ad364e35')
                            $shellComp.SetAttribute('language', 'neutral')
                            $shellComp.SetAttribute('versionScope', 'nonSxS')
                            $specSetting.AppendChild($shellComp) | Out-Null
                        }
                        $cnNode = $shellComp.SelectSingleNode('u:ComputerName', $nsMgr)
                        if ($cnNode) { $cnNode.InnerText = $Config.ComputerName }
                        else {
                            $cnNode = $xd.CreateElement('ComputerName', 'urn:schemas-microsoft-com:unattend')
                            $cnNode.InnerText = $Config.ComputerName
                            $shellComp.AppendChild($cnNode) | Out-Null
                        }
                    }

                    # Locale → oobeSystem pass
                    $iL = $Config.InputLocale; $sL = $Config.SystemLocale
                    $uL = $Config.UserLocale;  $uiL = $Config.UILanguage
                    if ($iL -or $sL -or $uL -or $uiL) {
                        $oobeSetting = $xd.SelectSingleNode('//u:settings[@pass="oobeSystem"]', $nsMgr)
                        if (-not $oobeSetting) {
                            $oobeSetting = $xd.CreateElement('settings', 'urn:schemas-microsoft-com:unattend')
                            $oobeSetting.SetAttribute('pass', 'oobeSystem')
                            $xd.DocumentElement.AppendChild($oobeSetting) | Out-Null
                        }
                        $intlComp = $oobeSetting.SelectSingleNode('u:component[@name="Microsoft-Windows-International-Core"]', $nsMgr)
                        if (-not $intlComp) {
                            $intlComp = $xd.CreateElement('component', 'urn:schemas-microsoft-com:unattend')
                            $intlComp.SetAttribute('name', 'Microsoft-Windows-International-Core')
                            $intlComp.SetAttribute('processorArchitecture', 'amd64')
                            $intlComp.SetAttribute('publicKeyToken', '31bf3856ad364e35')
                            $intlComp.SetAttribute('language', 'neutral')
                            $intlComp.SetAttribute('versionScope', 'nonSxS')
                            $oobeSetting.AppendChild($intlComp) | Out-Null
                        }
                        foreach ($pair in @(
                            @('InputLocale',  $iL),
                            @('SystemLocale', $sL),
                            @('UserLocale',   $uL),
                            @('UILanguage',   $uiL)
                        )) {
                            if ($pair[1]) {
                                $node = $intlComp.SelectSingleNode("u:$($pair[0])", $nsMgr)
                                if ($node) { $node.InnerText = $pair[1] }
                                else {
                                    $node = $xd.CreateElement($pair[0], 'urn:schemas-microsoft-com:unattend')
                                    $node.InnerText = $pair[1]
                                    $intlComp.AppendChild($node) | Out-Null
                                }
                            }
                        }
                    }

                    $sw = New-Object System.IO.StringWriter
                    $xw = [System.Xml.XmlTextWriter]::new($sw)
                    $xw.Formatting = [System.Xml.Formatting]::Indented
                    $xw.Indentation = 2
                    $xd.WriteTo($xw); $xw.Flush()
                    $oobeStep.parameters | Add-Member -NotePropertyName unattendContent -NotePropertyValue $sw.ToString() -Force
                } catch {
                    Write-Warning "Could not update unattendContent from config: $_"
                }
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
        browser back to the Nova-UI page.
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
        try { $listener.Stop(); $listener.Close() } catch { $null = $_ }
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
        Downloads config/auth.json from the GitHub repository.  When
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
    $authConfigUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/auth.json"
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
    # When config/auth.json has requireAuth = true, the operator must sign in
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
        $localNova = Join-Path $env:SystemRoot 'System32\Nova.ps1'
        if (-not (Test-Path $localNova)) {
            $url    = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/scripts/Nova.ps1"
            $localNova = 'X:\Nova.ps1'
            Write-Status ($S.Download -f 0)
            $web = New-Object System.Net.WebClient
            $web.add_DownloadProgressChanged({
                param($eventSender, $e)
                $null = $eventSender  # Required by .NET delegate signature
                Write-Status ($S.Download -f $e.ProgressPercentage)
            })
            $task = $web.DownloadFileTaskAsync($url, $localNova)
            while (-not $task.IsCompleted) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            if ($task.IsFaulted) { throw $task.Exception.InnerException }

            # ── Verify downloaded Nova.ps1 integrity ──────────────────
            # NOTE: The manifest comes from the same repo/branch as the script.
            # This detects corruption and CDN inconsistencies but does not protect
            # against a compromised repository.  For tamper protection, the manifest
            # would need to be cryptographically signed or hosted separately.
            $hashesUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/hashes.json"
            try {
                $manifest = Invoke-RestMethod -Uri $hashesUrl -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
            } catch {
                Remove-Item $localNova -Force -ErrorAction SilentlyContinue
                throw "Integrity check FAILED — could not download hash manifest from $hashesUrl : $_"
            }
            $expected = $manifest.files.'src/scripts/Nova.ps1'
            if (-not $expected) {
                Remove-Item $localNova -Force -ErrorAction SilentlyContinue
                throw "Integrity check FAILED — no src/scripts/Nova.ps1 entry in hash manifest"
            }
            $actual = [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.IO.File]::ReadAllBytes($localNova)
                )
            ) -replace '-', ''
            if ($actual -ne $expected) {
                Remove-Item $localNova -Force -ErrorAction SilentlyContinue
                throw "Integrity check FAILED for Nova.ps1 — Expected: $expected, Got: $actual"
            }
            Write-AuthLog 'Nova.ps1 integrity verified (SHA256 match).'
        }

        # Run Nova.ps1 in a dedicated process so the UI thread
        # stays responsive and the spinner keeps animating.
        # Detect firmware type so Nova partitions and configures the
        # bootloader correctly (UEFI → GPT + bcdboot /f UEFI,
        # BIOS → MBR + bcdboot /f BIOS).  wpeutil UpdateBootInfo already
        # populated the PEFirmwareType registry value during WinPE init.
        $detectedFirmware = 'UEFI'
        try {
            $fwVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' `
                                       -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
            if ($fwVal -eq 1) { $detectedFirmware = 'BIOS' }
        } catch { Write-Verbose "PEFirmwareType unavailable: $_" }

        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $localNova,
                    '-StatusFile', $script:StatusFile,
                    '-FirmwareType', $detectedFirmware,
                    '-TaskSequencePath', $script:TaskSequencePath)

        # Pass the Graph access token to the engine via an environment variable
        # so the ImportAutopilot task sequence step can register the device in
        # Autopilot before downloading or applying Windows.  In WinPE only the
        # SYSTEM account runs and no other user processes exist, so environment
        # variable exposure is acceptable.
        if ($script:GraphAccessToken) {
            $env:NOVA_GRAPH_TOKEN = $script:GraphAccessToken
        }

        Update-HtmlUi -Message $S.Imaging -Step 4

        # Stop writing to the status JSON from Bootstrap — Nova.ps1 takes
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
    } else {
        # Re-enable UI updates so the error state is shown to the user
        # and the Retry button works.
        $script:HtmlUiActive = $true
        Invoke-Sound 400 600
        Update-HtmlUi -Message 'Imaging failed — press Retry or F8 for a shell.' -Step 4 -ShowRetry
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
try { $script:HttpListener.Stop() } catch { $null = $_ }
try { $script:edgeWatchdogTimer.Stop() } catch { $null = $_ }
try { if ($script:hotkeyWindow) { $script:hotkeyWindow.Dispose() } } catch { $null = $_ }
Stop-Transcript -ErrorAction SilentlyContinue
#endregion

# SIG # Begin signature block
# MII+MAYJKoZIhvcNAQcCoII+ITCCPh0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCF38ZNIRsmgtkM
# pZOKze11GCrVtX08JFSO0YdhJF+jZ6CCIvIwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 3IpaDcR+iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqU
# MIIakAIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0Mg
# Q0EgMDICEzMAB9JqeMTCGX+FIsEAAAAH0mowDQYJYIZIAWUDBAIBBQCgXjAQBgor
# BgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG
# 9w0BCQQxIgQgSlcx2J2NgVU7nW26d4YuZC2lMRzOq4nptj4INE4yueIwDQYJKoZI
# hvcNAQEBBQAEggGAV5NQHYKGW009RMoZDtLtv2PVRNRyp5Ybn0DUdjSrsWoKBBlX
# y37bn16mnAJQW3PzWPKY7mlKvooN5S9sYy76hoNSVRfVP+Go9W39RUZi4tp3PSwn
# j30QhM8jpaECVK4CLdeGoWeDZ6X/EmY2H9HO5CuAqwzoGyLAQuMm1Rcu2KmoJXEK
# KpvDG4MQbOHtWhA7aJ9gZcIYWCxUe+VL5TAF4PoCaKCgbxyFZ4VUhDt3/mhwVq2v
# I/ZO72cxuJ7kLXt18pDUvksI1ERlHGqOa6wRPL+zgrxW5P3WygB/sOVjhZc7y2zh
# gKX6PqgiYeBSw+5UncC28Hyac6UHa5qHcYY5d+CPj4iHcBTHgMv2hnsa/7NOu4uZ
# NqVgJNJTHXvGtSErWJNG32qR7S1fm8ZwbuNO7coP/1vuNIgGYIlYkIMrABJx2d6T
# 2kE7CQRqENwZtyKV8dN0tpETvvBDEu5/YDMx4FXPiru9xtic65igTkogxe3mI7jM
# IKSTHA8Mx8y+AiLyoYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJKoZIhvcN
# AQcCoIIX7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEE
# oIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEICX/
# 62rI9h9AWPH4PoWm/BnBkTXmMEN2pp7yImD+Lot0AgZpwnK+9UMYEzIwMjYwNDAz
# MTYwNjA5LjQ0N1owBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJh
# dGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RDAwLTA1RTAtRDk0NzE1
# MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRo
# b3JpdHmggg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAABTANBgkq
# hkiG9w0BAQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVyaWZpY2F0
# aW9uIFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAxMTE5MjAz
# MjMxWhcNMzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJT
# QSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBvf7KrQ5cM
# SqFSHGqg2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDsfMuIEqvG
# YOPURAH+Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbBT7uq3wx3
# mXhtVmtcCEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5EeH5KrlF
# nxpjKKTavwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6ovnUfANj
# IgM9JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fjJHrmlQ0E
# IXmp4DhDBieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOsRpeexIve
# R1MPTVf7gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiunhKbq0Xbj
# kNoU5JhtYUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE3oWsDqMX
# 3jjv40e8KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8cIxLoKSD
# zCCBOu0hWdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMBAAGjggIb
# MIICFzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYE
# FGtpKDo1L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsG
# AQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVw
# b3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAwe
# CgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSob
# yhmYBAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJp
# ZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIw
# LmNybDCBlAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5
# JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5
# JTIwMjAyMC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXnTHho+k7h
# 2ESZJRWluLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC2IWmtKMy
# S1OWIviwpnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5zyEh89F7
# 2u9UIw+IfvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbNnCKNZPmh
# zoa8PccOiQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqst8S+w+RU
# die8fXC1jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVmoNR/dSpR
# Cxlot0i79dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRSSvijmwJw
# xRxLLpMQ/u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7vPKNMN+SZ
# DWycU5ODIRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/26ozePQ/T
# WfNXKBOmkFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/AAxw9Sdg
# q/+rY7jjgs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSOiUIr0Xqc
# r1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFXZ3WkmKPn44gAAAAAA
# VTANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBU
# aW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NDlaFw0yNjEwMjIyMDQ2
# NDlaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYD
# VQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hp
# ZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQ
# dWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEAvbkfkh5ZSLP0MCUWafaw/KZoVZu9iQx8r5JwhZvd
# rUi86UjCCFQONjQanrIxGF9hRGIZLQZ50gHrLC+4fpUEJff5t04VwByWC2/bWOuk
# 6NmaTh9JpPZDcGzNR95QlryjfEjtl+gxj12zNPEdADPplVfzt8cYRWFBx/Fbfch0
# 8k6P9p7jX2q1jFPbUxWYJ+xOyGC1aKhDGY5b+8wL39v6qC0HFIx/v3y+bep+aEXo
# oK8VoeWK+szfaFjXo8YTcvQ8UL4szu9HFTuZNv6vvoJ7Ju+o5aTj51sph+0+FXW3
# 8TlL/rDBd5ia79jskLtOeHbDjkbljilwzegcxv9i49F05ZrS/5ELZCCY1VaqO7EO
# LKVaxxdAO5oy1vb0Bx0ZRVX1mxFjYzay2EC051k6yGJHm58y1oe2IKRa/SM1+BTG
# se6vHNi5Q2d5ZnoR9AOAUDDwJIIqRI4rZz2MSinh11WrXTG9urF2uoyd5Ve+8hxe
# s9ABeP2PYQKlXYTAxvdaeanDTQ/vwmnM+yTcWzrVm84Z38XVFw4G7p/ZNZ2nscvv
# 6uru2AevXcyV1t8ha7iWmhhgTWBNBrViuDlc3iPvOz2SVPbPeqhyY/NXwNZCAgc2
# H5pOztu6MwQxDIjte3XM/FkKBxHofS2abNT/0HG+xZtFqUJDaxgbJa6lN1zh7spj
# uQ8CAwEAAaOCAcswggHHMB0GA1UdDgQWBBRWBF8QbdwIA/DIv6nJFsrB16xltjAf
# BgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6Bd
# hltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQl
# MjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkG
# CCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1l
# c3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/
# BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYB
# BAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcN
# AQEMBQADggIBAFIe4ZJUe9qUKcWeWypchB58fXE/ZIWv2D5XP5/k/tB7LCN9BvmN
# SVKZ3VeclQM978wfEvuvdMQSUv6Y20boIM8DK1K1IU9cP21MG0ExiHxaqjrikf2q
# bfrXIip4Ef3v2bNYKQxCxN3Sczp1SX0H7uqK2L5OhfDEiXf15iou5hh+EPaaqp49
# czNQpJDOR/vfJghUc/qcslDPhoCZpZx8b2ODvywGQNXwqlbsmCS24uGmEkQ3UH5J
# UeN6c91yasVchS78riMrm6R9ZpAiO5pfNKMGU2MLm1A3pp098DcbFTAc95Hh6Qvk
# h//28F/Xe2bMFb6DL7Sw0ZO95v0gv0ZTyJfxS/LCxfraeEII9FSFOKAMEp1zNFSs
# 2ue0GGjBt9yEEMUwvxq9ExFz0aZzYm8ivJfffpIVDnX/+rVRTYcxIkQyFYslIhYl
# WF9SjCw5r49qakjMRNh8W9O7aaoolSVZleQZjGt0K8JzMlyp6hp2lbW6XqRx2cOH
# bbxJDxmENzohGUziI13lI2g2Bf5qibfC4bKNRpJo9lbE8HUbY0qJiE8u3SU8eDQa
# ySPXOEhJjxRCQwwOvejYmBG5P7CckQNBSnnl12+FKRKgPoj0Mv+z5OMhj9z2Mtpb
# nHLAkep0odQClEyyCG/uR5tK5rW6mZH5Oq56UWS0NI6NV1JGS7Jri6jFMYIHRjCC
# B0ICAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBp
# bmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTANBglghkgBZQMEAgEFAKCC
# BJ8wEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAcBgkqhkiG9w0BCQUxDxcNMjYwNDAzMTYwNjA5WjAvBgkqhkiG9w0BCQQxIgQg
# bEe3/llyQBYLqtCgXnRTn20cFQiX3bARFyrwtwpliQwwgbkGCyqGSIb3DQEJEAIv
# MYGpMIGmMIGjMIGgBCDYuTyXZIZiu799/v4PaqsmeSzBxh0rqkYq7sYYavj+zTB8
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTCCA2EGCyqGSIb3DQEJEAISMYID
# UDCCA0yhggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUw
# LUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBp
# bmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQAdO1QBgmW/tuBZV5EGjhfsV4cN
# 6qBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBp
# bmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO16IB0wIhgPMjAyNjA0MDMxMTE2
# NDVaGA8yMDI2MDQwNDExMTY0NVowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7Xog
# HQIBADAKAgEAAgIa0gIB/zAHAgEAAgITkjAKAgUA7XtxnQIBADA2BgorBgEEAYRZ
# CgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0G
# CSqGSIb3DQEBCwUAA4IBAQBw4UJKQSJ7f2LCVdEtBVBGy9nMC6RgpIZ/F4qraHax
# cSwFMW7LThLn+tKMotemKfZREJh9yzlikJKTvh10JMxSpybvr1MYQqHZDKRJZaJy
# FtWCcj+BNDXwVKhsxQ2VBPh4y6dhUeZNVhNdQffeKPDClbl85bSLAWY9YIrgtmyZ
# n5FNisTS5izsK07W8xiv0BH3jhoP2whGtGG/LkId1RdlFfjtzNcpaQ5LF8g5mcxU
# U4IA0GqwrvZ2wy11a5Tc77hedSsK8PS3b5iZPA/a15z0MUt0qr0LwLoNjLKnVyeC
# Rf/EmZ6AM+OsU6JPpkytcfkzJ/kNpn6ukBrGNanUVD0NMA0GCSqGSIb3DQEBAQUA
# BIICABjhq+ENNY4gGh5ca6+7kGaxrfif2V0XaNhoKTiVZGcSVmM2sqkcot/xjC/1
# VGo/15E21U89cCaYK9K3SrOX9kKXy4u1C8+wm+SrFpEBVcBTkbpDTrm6wNjgnIfB
# nGnrFm/ppqH7uzXNuVa8oFRQ2aAACbAhVWJcZPd443OY0np1HHrbpp8iqm2Gb38c
# E21yhzC7VM71UqWsrlnnE5QadqDxS/g1uD1iP9PRknfhuHjl/FByBNllptLRtexe
# 5Q2HvsGqgn6wf4ACfQn+9XXU3WLYYh3VI951Ig9pmSL7kRRykiRid0kkQF6xTulg
# FTzBaI4fnQPl4XkfUWaCtfzplQo4xaqKBs5Qpaqx4tM6hUhnos2cODbcih04XeB1
# 9IR5kIwv1yss9O45tH7DdIblXWc3X6z8i1Ubk9BbQyYszqiXisJnV3lZmLZ6Yv1k
# PNG9iNOuog/VYlDzAkmoRZakvpm44E9/3GQ3aT/xputQkohmrw4lpzBjBk9N7wkf
# 54/4Zeb2kjUUsoHC1PnEwP+HEDuaUWtbSH/QZAWZ/x7HF8oYFFT3Ve9QL3nUm+na
# m6OoC4wnJ/gMhfandz+w3sJGhecwRyoJAQk9C8VoiQUrgbNRJFUttHjcfSKapApe
# EuEhMud+Qp8+7LZiqIWM1jzkfsk4ph/QX5QJanqvkazL9Zln
# SIG # End signature block

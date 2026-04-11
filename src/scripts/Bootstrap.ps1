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
# Import dependency-free modules first -- Nova.TaskSequence and Nova.Auth
# declare RequiredModules in their manifests, so Nova.Logging and Nova.Platform
# must be loaded before them.
Import-Module "$script:ModulesRoot\Nova.Logging"      -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Platform"     -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Network"      -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.TaskSequence" -Force -ErrorAction Stop
Import-Module "$script:ModulesRoot\Nova.Auth"         -Force -ErrorAction Stop
# Nova.Proxy is optional -- only loaded when the module is staged in the image.
# Corporate environments can pre-configure proxy settings before network calls.
Import-Module "$script:ModulesRoot\Nova.Proxy"        -Force -ErrorAction SilentlyContinue

# ── Nova file logging ───────────────────────────────────────────────────────
# Start structured file logging for Bootstrap phase.
Start-NovaLog -Path 'X:\Nova-Detailed.log'
Write-Section 'Bootstrap Initializing'
Write-Data -Label 'Bootstrap Configuration' -Data @{
    GitHubUser   = $GitHubUser
    GitHubRepo   = $GitHubRepo
    GitHubBranch = $GitHubBranch
    MaxWait      = "${MaxWaitSeconds}s"
    ModulesRoot  = $script:ModulesRoot
}
Write-Detail "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Detail "Architecture: $(if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' })"

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
$script:HtmlUiActive     = $true
$script:GraphAccessToken = $null
$script:AuthConfig       = $null

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
        [switch]$ShowRetryAuth,
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
            ShowRetryAuth  = [bool]$ShowRetryAuth
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
        Write-Verbose "Failed to download locale $code from $url -- $_"
        return $null
    }
}

# Use inline EN strings at boot.  Locale files are downloaded later once
# internet connectivity is confirmed (inside ProceedToEngine), avoiding
# blocking WebClient calls before the network stack is initialised.
# Without this deferral the three DownloadString calls block the script
# for up to several minutes (waiting for DNS/TCP timeouts on a NIC with
# no connectivity), which prevents the HTTP listener, F8 hotkey, and init
# state machine from starting -- hanging the UI and disabling F8.
$Strings = @{}
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
        AuthRetryBtn="Retry authentication";
        AuthSkipped="Authentication not required";
        AuthEdgePrompt="Microsoft Edge has opened for sign-in.`nComplete the sign-in in the browser window, then this dialog will close automatically.";
        AuthDeviceCodePrompt="To sign in, use a web browser on another device`nand enter this code:"
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
            # ── CORS: allow the file:// page to call the HTTP API ────────
            $context.Response.Headers.Add('Access-Control-Allow-Origin', '*')
            $context.Response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            $context.Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')

            switch ($path) {
                '/wifi'       { $script:PendingAction = 'SHOW_WIFI'; $msg = 'ok' }
                '/retry'      { $script:PendingAction = 'RETRY'; $msg = 'ok' }
                '/retryauth'  { $script:PendingAction = 'RETRY_AUTH'; $msg = 'ok' }
                '/cancelauth' { $script:_authCancelled = $true; $msg = 'ok' }
                '/ping' {
                    # Returns a 1x1 transparent GIF so the HTML UI can detect
                    # server readiness from a file:// origin via an <img> tag
                    # (img requests bypass CORS restrictions).
                    $handled = $true
                    $gifBytes = [Convert]::FromBase64String('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7')
                    $context.Response.ContentType     = 'image/gif'
                    $context.Response.ContentLength64 = $gifBytes.Length
                    $context.Response.OutputStream.Write($gifBytes, 0, $gifBytes.Length)
                    $context.Response.Close()
                }
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
                '/shell'      { Open-NovaShell; $msg = 'shell opened' }
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
            'RETRY_AUTH' {
                $script:_authCancelled = $false
                ProceedToEngine
            }
        }
    }
})
$script:actionTimer.Start()
#endregion


#region ── Global F8 hotkey (works even when Edge has crashed) ────────────────
# Register F8 as a system-wide hotkey via Win32 RegisterHotKey so users can
# open a PowerShell troubleshooting console at any time -- regardless of whether
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

public static class NovaWindow {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    public const int SW_FORCEMINIMIZE = 11;
    public const int SW_RESTORE       = 9;
}
'@ -ReferencedAssemblies System.Windows.Forms -ErrorAction Stop

    $script:hotkeyWindow = New-Object NovaHotkeyWindow
    $script:hotkeyWindow.add_HotkeyPressed({
        Write-Verbose 'F8 hotkey pressed -- opening PowerShell'
        Open-NovaShell
    })
    Write-Verbose 'Global F8 hotkey registered'
} catch {
    Write-Verbose "Failed to register global F8 hotkey: $_"
}

function Open-NovaShell {
    <#
    .SYNOPSIS  Minimize Edge and open a PowerShell troubleshooting console.
    .DESCRIPTION
        In WinPE kiosk mode Edge occupies the full screen with no taskbar.
        A plain Start-Process creates the PowerShell window behind Edge where
        the user cannot see it.  This helper minimizes every Edge window first
        so the new console is visible, then brings it to the foreground.
    #>
    [CmdletBinding()] param()
    # Minimise every Edge window so the new console is visible
    try {
        Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | ForEach-Object {
            $h = $_.MainWindowHandle
            if ($h -ne [IntPtr]::Zero) {
                [NovaWindow]::ShowWindow($h, [NovaWindow]::SW_FORCEMINIMIZE) | Out-Null
            }
        }
    } catch { Write-Verbose "Could not minimise Edge: $_" }

    $p = Start-Process -FilePath $script:PsBin -ArgumentList '-NoProfile', '-NoExit' -PassThru
    # Give the window time to appear, then bring it to the foreground
    Start-Sleep -Milliseconds 500
    try {
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
            [NovaWindow]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
        }
    } catch { Write-Verbose "SetForegroundWindow failed: $_" }
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
#   1. Process exit  -- all msedge.exe processes have terminated.
#   2. Heartbeat loss -- the HTML UI sends a /heartbeat every 10 s.
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
    '--disable-web-security',
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
    Write-Verbose 'Edge watchdog -- restarting Edge'
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
        # Edge process has exited entirely -- restart it.
        Write-Verbose 'Edge watchdog -- Edge process not found'
        Restart-Edge
        return
    }

    # Edge is running but the UI may be unresponsive (Error code 39 scenario).
    $heartbeatAge = ([DateTime]::UtcNow - $script:_lastHeartbeat).TotalSeconds
    if ($heartbeatAge -gt 30) {
        Write-Verbose "Edge watchdog -- heartbeat lost (${heartbeatAge}s ago)"
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
        $productsUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/resources/products.xml"
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

    # Parse the catalog XML once -- downstream combos filter dynamically.
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

#region ── M365 Authentication ────────────────────────────────────────────────
# This wrapper bridges the Nova.Auth module's Invoke-M365Auth callback
# parameters to Bootstrap.ps1's UI layer.

function Invoke-BootstrapM365Auth {
    <#
    .SYNOPSIS  Authenticate the operator via the Nova.Auth module.
    .DESCRIPTION
        Delegates to Invoke-M365Auth from the Nova.Auth module, passing
        Bootstrap.ps1's UI functions as scriptblock callbacks.  Returns $true
        when auth succeeded or was not required, $false on failure.
    .OUTPUTS
        $true  if authentication succeeded or was not required.
        $false if authentication failed.
    #>

    # ── Callback scriptblocks bridge the module to Bootstrap.ps1's UI ──────
    # Ensure the cancellation flag exists before the callbacks reference it.
    # Without this, Set-StrictMode -Version Latest throws on first read.
    if (-not (Test-Path variable:script:_authCancelled)) {
        $script:_authCancelled = $false
    }

    $writeLog = {
        param([string]$Message)
        Write-AuthLog $Message
    }
    $writeStatus = {
        param([string]$Message, [string]$Color)
        Write-Status $Message $Color
    }
    # NOTE: Use hashtable indexer ($Params['Key']) instead of dot-notation
    # ($Params.Key) because Set-StrictMode -Version Latest throws when
    # accessing a non-existent key via dot-notation on a hashtable.
    $updateUi = {
        param([hashtable]$Params)
        if ($Params['AuthInProgress']) {
            Update-HtmlUi -Message $script:S.AuthSigning -Step 3
        } elseif ($Params['ShowDeviceCode']) {
            Update-HtmlUi -Message $script:S.AuthDeviceCodePrompt -Step 3 `
                          -ShowDeviceCode -DeviceCode $Params['DeviceCode'] -DeviceCodeUrl $script:S.AuthUrl
        } elseif ($Params['ClearAuth']) {
            Update-HtmlUi -Message $script:S.AuthSigning -Step 3
        }
    }
    $checkCancelled = {
        $script:_authCancelled
    }
    $doEvents = {
        [System.Windows.Forms.Application]::DoEvents()
    }
    $playSound = {
        param([int]$Freq, [int]$Duration)
        Invoke-Sound $Freq $Duration
    }

    $result = Invoke-M365Auth `
        -GitHubUser $GitHubUser -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch `
        -EdgeExePath $script:EdgeExe `
        -WriteLog $writeLog -WriteStatus $writeStatus -UpdateUi $updateUi `
        -CheckCancelled $checkCancelled -DoEvents $doEvents -PlaySound $playSound

    # ── Expose results in Bootstrap.ps1 script scope ────────────────────────
    if ($result.GraphAccessToken) {
        $script:GraphAccessToken = $result.GraphAccessToken
    }
    if ($result.AuthConfig) {
        $script:AuthConfig = $result.AuthConfig
    }

    return $result.Authenticated
}
#endregion

function ProceedToEngine {
    # Guard: prevent double invocation from both timer and WiFi click handler.
    if ($script:EngineStarted) { return }
    $script:EngineStarted = $true
    if ($script:connectCheckTimer) { $script:connectCheckTimer.Stop() }

    Write-Section 'Network Connected'
    Write-Info 'Internet connectivity confirmed -- proceeding to engine setup'

    Update-Step 3
    Write-Status $S.Connected 'Green'
    Update-HtmlUi -Message $S.Connected -Step 3
    Invoke-Sound 900 300

    # ── M365 authentication gate ────────────────────────────────────────────
    # When config/auth.json has requireAuth = true, the operator must sign in
    # with a Microsoft 365 account from an allowed Entra ID tenant.
    # Tenant restrictions are enforced at the app registration level.
    # Launches Edge in --app mode for a clean login popup (Auth Code + PKCE)
    # as the primary method; falls back to Device Code Flow shown in
    # an HTML modal overlay if Edge is not available.
    Write-Section 'M365 Authentication'
    Write-Info 'Checking authentication requirements...'
    $authPassed = Invoke-BootstrapM365Auth
    if (-not $authPassed) {
        Write-Warn 'M365 authentication failed -- allowing retry'
        $script:EngineStarted = $false   # allow retry after WiFi reconnect
        Update-HtmlUi -Message $S.AuthFailed -Step 2 -ShowRetryAuth
        return
    }
    Write-Success 'Authentication gate passed'

    Update-Step 4

    # ── Download locale files now that internet is available ─────────────
    # Deferred from startup to avoid blocking WebClient calls before the
    # network stack is initialised.
    foreach ($lc in @('EN', 'FR', 'ES')) {
        $loaded = Import-LocaleJson -LangCode $lc
        if ($loaded) { $Strings[$lc] = $loaded }
    }
    $script:S = $Strings[$script:Lang]

    # Unified configuration dialog: language + all Windows options in one step.
    Write-Section 'Deployment Configuration'
    $config = Show-ConfigurationMenu
    $script:Lang = $config.Language
    $script:S    = $Strings[$script:Lang]
    $script:TaskSequencePath = $config.TaskSequencePath
    Write-Data -Label 'User Configuration' -Data @{
        Language      = $config.Language
        TaskSequence  = "$($config.TaskSequencePath)"
    }

    # Write user configuration choices into the task sequence JSON so the
    # engine reads everything from a single source of truth.
    if ($script:TaskSequencePath) {
        Update-TaskSequenceFromConfig -TaskSequencePath $script:TaskSequencePath -Config $config
        Write-Info "Task sequence updated with user configuration choices"
    }

    # Clean up any stale status file from a previous run.
    if (Test-Path $script:StatusFile) { Remove-Item $script:StatusFile -Force }

    Write-Section 'Launching Nova Engine'
    # Prefer the pre-staged copy embedded in the WinPE image by Trigger.ps1.
    # Fall back to downloading from GitHub when the local copy is absent.
    $engineFailed = $false
    try {
        $localNova = Join-Path $env:SystemRoot 'System32\Nova.ps1'
        if (-not (Test-Path $localNova)) {
            Write-Info "Pre-staged Nova.ps1 not found -- downloading from GitHub"
            $url    = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/src/scripts/Nova.ps1"
            $localNova = 'X:\Nova.ps1'
            Write-Detail "Download URL: $url"
            Write-Status ($S.Download -f 0)
            $web = New-Object System.Net.WebClient
            # Add cache-busting headers to avoid WinINet serving stale content
            $web.Headers.Add('Cache-Control', 'no-cache')
            $web.Headers.Add('Pragma', 'no-cache')
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
            # Loading the manifest AFTER the download minimises the CDN
            # propagation window.  If the hash mismatches, we retry once
            # after a short delay to handle CDN propagation delays.
            $noCacheHeaders = @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
            $hashesUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/hashes.json"

            for ($attempt = 1; $attempt -le 2; $attempt++) {
                try {
                    $manifest = Invoke-RestMethod -Uri $hashesUrl -UseBasicParsing -Headers $noCacheHeaders -ErrorAction Stop -TimeoutSec 15
                } catch {
                    Remove-Item $localNova -Force -ErrorAction SilentlyContinue
                    throw "Integrity check FAILED -- could not download hash manifest from $hashesUrl : $_"
                }
                $expected = $manifest.files.'src/scripts/Nova.ps1'
                if (-not $expected) {
                    Remove-Item $localNova -Force -ErrorAction SilentlyContinue
                    throw "Integrity check FAILED -- no src/scripts/Nova.ps1 entry in hash manifest"
                }
                $actual = [System.BitConverter]::ToString(
                    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                        [System.IO.File]::ReadAllBytes($localNova)
                    )
                ) -replace '-', ''
                if ($actual -eq $expected) {
                    Write-AuthLog 'Nova.ps1 integrity verified (SHA256 match).'
                    break
                }
                if ($attempt -eq 1) {
                    Write-AuthLog 'Hash mismatch for Nova.ps1 -- retrying in 5s (CDN propagation window)...'
                    Start-Sleep -Seconds 5
                } else {
                    Remove-Item $localNova -Force -ErrorAction SilentlyContinue
                    throw "Integrity check FAILED for Nova.ps1 (after retry) -- Expected: $expected, Got: $actual"
                }
            }
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

        # Stop writing to the status JSON from Bootstrap -- Nova.ps1 takes
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
        Update-HtmlUi -Message 'Imaging failed -- press Retry or F8 for a shell.' -Step 4 -ShowRetry
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
                # registry -- needed by downstream partitioning logic.
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
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBg/LqNF7x/wtOt
# SdJnTYxEOAOSc8c69eRAOyCqaEgrtKCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# rmcxghqRMIIajQIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBBT0MgQ0EgMDQCEzMAAAsliaF5N+X1X2YAAAAACyUwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQg2Bxbs8SfbZe31v5y+aazyDU/WlnTMzL9UurFnKPdGPUw
# DQYJKoZIhvcNAQEBBQAEggGAJd8cisnu9rnqbY357PQ7FtOJKbvjR/x6q1+f9NTI
# kGsYZbic8iaOm9Jr2jpbtkLKO54GbiWurmDc733APCqKGrTTQtuTCYcHakX4gpEw
# GVR4aOFwr+uQhxS6LPc6kuGaj7Vz92bItXY1QHVYS57+UOYKJ1TMFj/htS9hGOU3
# kPitQaWEltTqPmAxK2kYSTfPJGL/+rEVREQhdEwya5dffY67pZtrMghbJpbK0Y7J
# CyryPph2HRO6jUd9UgsVt2dfihNyGwJawSfvvSuLvExF8Wpp2mWsxo9/yY3jhy1E
# VR4OIMQ+5l3drdK9Q/MrPHRsyMY2tLckr530nVtbwj3rQ56QiWjqOglq02oudR3R
# MB5rRzqT4tqquJW3QExY4GWh2LTrH1B950btgdzjgtD6bpZxSwOlmGPnkxAicvRC
# UOs4WmXUS3CLIIp/EyXeuybX8v4MG6uQR+cqCl1tcqZjlaqpy28zOKOeTcAdSAmi
# LLO8qKQaDCKMh6mJJfcbYcEkoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIHDrBiYOAvjpgJ/XHkFu1x4PCs6ofciFuvA23YXSr8tVAgZpwmaoCi0YEzIw
# MjYwNDExMTAyMjE3LjU0OVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAt
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
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFZ+j51YCI7p
# YAAAAAAAVjANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTFaFw0yNjEw
# MjIyMDQ2NTFaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtKWfm/ul027/d8Rlb8Mn/g0QUvvLqY2V
# sy3tI8U2tFSspTZomZOD3BHT8LkR+RrhMJgb1VjAKFNysaK9cLSXifPGSIBrPCgs
# 9P4y24lrJEmrV6Q5z4BmqMhIPrZhEvZnWpCS4HO7jYSei/nxmC7/1Er+l5Lg3PmS
# xb8d2IVcARxSw1B4mxB6XI0nkel9wa1dYb2wfGpofraFmxZOxT9eNht4LH0RBSVu
# eba6ZNpjS/0gtfm7qiIiyP6p6PRzTTbMnVqsHnV/d/rW0zHx+Q+QNZ5wUqKmTZJB
# 9hU853+2pX5rDfK32uNY9/WBOAmzbqgpEdQkbiMavUMyUDShmycIvgHdQnS207sT
# j8M+kJL3tOdahPuPqMwsaCCgdfwwQx0O9TKe7FSvbAEYs1AnldCl/KHGZCOVvUNq
# jyL10JLe0/+GD9/ynqXGWFpXOjaunvZ/cKROhjN4M5e6xx0b2miqcPii4/ii2Zhe
# KallJET7CKlpFShs3wyg6F/fojQxQvPnbWD4Nyx6lhjWjwmoLcx6w1FSCtavLCly
# 33BLRSlTU4qKUxaa8d7YN7Eqpn9XO0SY0umOvKFXrWH7rxl+9iaicitdnTTksAnR
# jvekdKT3lg7lRMfmfZU8vXNiN0UYJzT9EjqjRm0uN/h0oXxPhNfPYqeFbyPXGGxz
# aYUz6zx3qTcCAwEAAaOCAcswggHHMB0GA1UdDgQWBBS+tjPyu6tZ/h5GsyLvyz1H
# +FNIWjAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAA4DqAXEsO26j/La7Fgn/Qifit8xuZekqZ57+Ye+sH/h
# RTbEEjGYrZgsqwR/lUUfKCFpbZF8msaZPQJOR4YYUEU8XyjLrn8Y1jCSmoxh9l7t
# WiSoc/JFBw356JAmzGGxeBA2EWSxRuTr1AuZe6nYaN8/wtFkiHcs8gMadxXBs6Dx
# Vhyu5YnhLPQkfumKm3lFftwE7pieV7f1lskmlgsC6AeSGCzGPZUgCvcH5Tv/Qe9z
# 7bIImSD3SuzhOIwaP+eKQTYf67TifyJKkWQSdGfTA6Kcu41k8LB6oPK+MLk1jbxx
# K5wPqLSL62xjK04SBXHEJSEnsFt0zxWkxP/lgej1DxqUnmrYEdkxvzKSHIAqFWSZ
# ul/5hI+vJxvFPhsNQBEk4cSulDkJQpcdVi/gmf/mHFOYhDBjsa15s4L+2sBil3XV
# /T8RiR66Q8xYvTLRWxd2dVsrOoCwnsU4WIeiC0JinCv1WLHEh7Qyzr9RSr4kKJLW
# dpNYLhgjkojTmEkAjFO774t3xB7enbvIF0GOsV19xnCUzq9EGKyt0gMuaphKlNjJ
# +aTpjWMZDGo+GOKsnp93Hmftml0Syp3F9+M3y+y6WJGUZoIZJq227jDjjEndtpUr
# h9BdPdVIfVJD/Au81Rzh05UHAivorQ3Os8PELHIgiOd9TWzbdgmGzcILt/ddVQER
# MYIHQzCCBz8CAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjANBglghkgBZQME
# AgEFAKCCBJwwEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDExMTAyMjE3WjAvBgkqhkiG9w0B
# CQQxIgQgLAmBdF2mSNsY8XeP6J0udV3TRL2kaNVc/m4fU4P6pOwwgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCC2DDMlTaTj8JV3iTg5Xnpe4CSH60143Z+X9o5N
# BgMMqDB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjCCA14GCyqGSIb3DQEJ
# EAISMYIDTTCCA0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD/c/cpFSqQWYBeXggy
# RJ2ZbvYEEaBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2D9y8wIhgPMjAyNjA0
# MTAyMjI0NDdaGA8yMDI2MDQxMTIyMjQ0N1owdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7YP3LwIBADAHAgEAAgILvjAHAgEAAgIS7DAKAgUA7YVIrwIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQBaQcb9WCVUFGxEfjiJxGCHKzG7Lp0Cm2HUGvQ9
# /6dBcJ4YbuW79O562qsneyHrVaNf42uEvaem/JJbRrUca6HaCs4xIRwEVUB+3yWk
# ooWuCRdHW1Dv2QGfTAfGFnw0wpNgKBC6Pitce3QJpB/N/96SnTM+8JIzbo33GuNF
# r9oPYwKjKaqBbXk5QD8mLXlr76bFI1xXEI522a5l2eo6+DleUx4w/mhbesFf6vb9
# Z+7BHMXGpD0rVci2cFnHDP+RUz5jVCGJqEDwbbl3RkkzZz4iVPb0NloAwgrAHET9
# QXTxFI8p/quCmPlYvhuLnOA7pI51qM7dOwxZywlGlFozqeDmMA0GCSqGSIb3DQEB
# AQUABIICAD3Mv7BsFgPKEfY00qcNIv5sa9/s1Ed0+9VmJF+K3ceQlo+eqIRd84z9
# V9ykj/0wc1SNC2msaz2dJC28n5wIh1pqxuUznKCLIBtsOheKmcvQ5j1JcSPdIfa3
# WuRyO783vVC93Xub7Kpc21nXrVZ13mXCwxXrwxPMc10zu9dciTHfZ00VWQREAjSk
# PfRPskMX2rmyAr2ERDkvzY2zFXE2m1PMoFlXH1g1T2oZFyeixi2/HbYY8MeKO+hI
# IKanifAHVgn5ubRvrVQJcdomWb7a+t5xYGVFSc7VVg8e/ppwswoq5wEbRQkAhvHj
# c8kTF1au6EEMFjsA8+vu4R/IG7eBks8VSNYX17841Zh0bn1cN88KBdFGKHp/YDRR
# Q0+yV+8M3eHigicrdXtv8ZxkQw613Paz36NnLmd2XbNdrthqkYLy1gI4IoyvKwFr
# UXHyQzfbj1gHY9iEH7bIo4vTbZbM6YPdtObQ3UJGsB8LsKgWN4JFz60xnGfWBtzv
# /HSCGb5y+euGQDWj2UvzEHI6lQ8MUZKN8Pz9S2IkdAj+te44eShw0ec6wG2+FKSq
# 88a1D+qYGOo5N8b1Hr1CnVSl2o/CdfeeHkAJqJaXkX/Z68GmRvojkRkNeQwxWKvw
# 4d92fZyXOlGm5ZhUqfeNO7M+xRMVHi2drUvb0dFcoE6k1Bcf44p/
# SIG # End signature block

#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Bootstrap - Graphical WinRE/WinPE loader with Fluent UI.
.DESCRIPTION
    Runs inside the WinRE/WinPE boot environment via winpeshl.ini.
    - Calls wpeinit.exe to initialise the WinPE network stack and DHCP.
    - Presents an animated Fluent-style WinForms interface.
    - Applies high-performance network tuning.
    - Offers an interactive graphical WiFi selector when wired internet is unavailable.
    - Shows a unified configuration dialog (language + Windows edition) once connected.
    - Downloads and executes AmpCloud.ps1 from GitHub once connected.
    - Supports a customisable background image embedded in the boot image.
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
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Hide console window ────────────────────────────────────────────────────
# WinPE boots into cmd.exe → powershell.exe via winpeshl.ini.  The parent
# console window is visible behind the WinForms UI and looks unprofessional,
# so hide it immediately before any dialog is shown.
$null = Add-Type -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -Name ConsoleWindow -Namespace Win32 -PassThru
$consoleHandle = [Win32.ConsoleWindow]::GetConsoleWindow()
if ($consoleHandle -ne [IntPtr]::Zero) {
    $null = [Win32.ConsoleWindow]::ShowWindow($consoleHandle, 0)  # SW_HIDE
}

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

#region ── Language System ───────────────────────────────────────────────────
$script:Lang = 'EN'

$Strings = @{
    EN = @{ Header="A M P C L O U D"; Subtitle="Cloud Imaging Engine";
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
            AuthDeviceCodePrompt="To sign in, use a web browser on another device`nand enter this code:" }
    FR = @{ Header="A M P C L O U D"; Subtitle="Moteur d'imagerie cloud";
            Step1="Réseau"; Step2="Connexion"; Step3="Identification"; Step4="Déploiement";
            StatusInit="Initialisation de la pile réseau...";
            StatusNoNet="Pas de connexion filaire détectée`nAppuyez ci-dessous pour le Wi-Fi";
            Connected="Connecté — vérification de l'identité";
            Download="Téléchargement AmpCloud.ps1  ({0}%)";
            Complete="Prêt à déployer";
            Reboot="Redémarrer maintenant"; PowerOff="Éteindre"; Shell="Invite de commandes";
            Imaging="Imagerie en cours...";
            CatalogFetch="Chargement du catalogue Windows...";
            CatalogFail="Impossible de charger le catalogue — édition par défaut utilisée.";
            EditionTitle="Choisir l'édition";
            EditionLabel="Sélectionnez l'édition Windows à installer :";
            EditionBtn="Continuer";
            ConfigSubtitle="Configurez votre déploiement";
            ConfigLang="Langue"; ConfigOsLang="Langue du SE";
            ConfigArch="Architecture"; ConfigActivation="Activation";
            ConfigEdition="Édition Windows";
            ConfigBtn="Démarrer le déploiement";
            AuthSigning="Connexion avec Microsoft 365...";
            AuthPrompt="Connectez-vous avec votre compte Microsoft 365 pour continuer.";
            AuthUrl="https://microsoft.com/devicelogin";
            AuthWaiting="En attente de connexion...";
            AuthSuccess="Identité vérifiée";
            AuthFailed="Échec de l'authentification. Veuillez réessayer.";
            AuthSkipped="Authentification non requise";
            AuthEdgePrompt="Microsoft Edge s'est ouvert pour la connexion.`nTerminez la connexion dans la fenêtre du navigateur, cette boîte se fermera automatiquement.";
            AuthDeviceCodePrompt="Pour vous connecter, utilisez un navigateur web sur un autre appareil`net entrez ce code :" }
    ES = @{ Header="A M P C L O U D"; Subtitle="Motor de imágenes en la nube";
            Step1="Red"; Step2="Conectar"; Step3="Iniciar sesión"; Step4="Desplegar";
            StatusInit="Inicializando pila de red...";
            StatusNoNet="Sin conexión cableada detectada`nToque abajo para Wi-Fi";
            Connected="Conectado — verificando identidad";
            Download="Descargando AmpCloud.ps1  ({0}%)";
            Complete="Listo para desplegar";
            Reboot="Reiniciar ahora"; PowerOff="Apagar"; Shell="Símbolo del sistema";
            Imaging="Creación de imagen en curso...";
            CatalogFetch="Cargando catálogo de Windows...";
            CatalogFail="No se pudo cargar el catálogo — usando edición predeterminada.";
            EditionTitle="Elegir edición";
            EditionLabel="Seleccione la edición de Windows a instalar:";
            EditionBtn="Continuar";
            ConfigSubtitle="Configure su implementación";
            ConfigLang="Idioma"; ConfigOsLang="Idioma del SO";
            ConfigArch="Arquitectura"; ConfigActivation="Activación";
            ConfigEdition="Edición de Windows";
            ConfigBtn="Iniciar implementación";
            AuthSigning="Iniciando sesión con Microsoft 365...";
            AuthPrompt="Inicie sesión con su cuenta de Microsoft 365 para continuar.";
            AuthUrl="https://microsoft.com/devicelogin";
            AuthWaiting="Esperando inicio de sesión...";
            AuthSuccess="Identidad verificada";
            AuthFailed="Error de autenticación. Por favor, inténtelo de nuevo.";
            AuthSkipped="Autenticación no requerida";
            AuthEdgePrompt="Microsoft Edge se ha abierto para iniciar sesión.`nComplete el inicio de sesión en la ventana del navegador, este cuadro se cerrará automáticamente.";
            AuthDeviceCodePrompt="Para iniciar sesión, use un navegador web en otro dispositivo`ne ingrese este código:" }
}
$script:S = $Strings[$script:Lang]
#endregion

#region ── Sound Effects ─────────────────────────────────────────────────────
function Invoke-Sound {
    param([int]$Freq = 800, [int]$Dur = 200)
    [console]::beep($Freq, $Dur)
}
#endregion

#region ── Customisable Background Image ─────────────────────────────────────
# If a background image was embedded in the boot image during Build-WinPE,
# load it once so the form Paint handler can render it instead of the default
# procedural gradient.  This file is placed by Trigger.ps1 and can be
# replaced by administrators with custom branding.
$script:BackgroundImage = $null
$bgPath = Join-Path $env:SystemRoot 'System32\AmpCloud-bg.png'
if (Test-Path $bgPath) {
    try   { $script:BackgroundImage = [System.Drawing.Image]::FromFile($bgPath) }
    catch { Write-Verbose "Background image load failed — falling back to gradient: $_" }
}
#endregion

#region ── Fluent Theme ──────────────────────────────────────────────────────
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
$HeroFont    = New-Object System.Drawing.Font("Segoe UI Light", 32)
$InfoFont    = New-Object System.Drawing.Font("Segoe UI", 9)

# ── Gradient & OOBE-style card constants ────────────────────────────────────
$script:GradientTop        = [System.Drawing.Color]::FromArgb(218, 232, 252)
$script:GradientBottom     = [System.Drawing.Color]::FromArgb(234, 240, 250)
$script:DarkGradientTop    = [System.Drawing.Color]::FromArgb(25, 25, 30)
$script:DarkGradientBottom = [System.Drawing.Color]::FromArgb(38, 38, 44)
$script:CardRadius         = 16
$script:CardShadowColor    = [System.Drawing.Color]::FromArgb(30, 0, 0, 0)
$script:CardMaxW           = 820
$script:CardPadTop         = 40
$script:CardPadBottom      = 36
$script:IllustH            = 110      # space reserved for the illustration

# Illustration circle sizes (used by the card Paint handler)
$script:IllustBig          = 58       # centre circle diameter
$script:IllustSmall        = 46       # side circle diameter
$script:IllustGap          = 10       # overlap offset between circles

# Illustration circle colours (Azure · Teal · Violet — matching the OOBE palette)
$script:IllustBlue   = [System.Drawing.Color]::FromArgb(0, 120, 212)
$script:IllustGreen  = [System.Drawing.Color]::FromArgb(16, 137, 62)
$script:IllustViolet = [System.Drawing.Color]::FromArgb(135, 100, 184)

# ── Icon font + GDI+ fallback helpers ───────────────────────────────────────
# Segoe MDL2 Assets provides Fluent icons when available (injected during
# WinPE build via Build-WinPE).  If the font is missing, pure GDI+ shapes
# are drawn instead — no garbage glyphs.
$script:IconFont = $null
try { $script:IconFont = New-Object System.Drawing.Font("Segoe MDL2 Assets", 18) }
catch { Write-Verbose "Segoe MDL2 Assets font not available — using GDI+ shapes: $_" }

function Invoke-GlobeIcon {
    <# Draws a simple globe (circle + crosshairs + equator arc) inside a rect. #>
    param($Graphics, $Rect, $Pen)
    $g = $Graphics; $r = $Rect
    $cx = $r.X + $r.Width / 2;  $cy = $r.Y + $r.Height / 2
    $inset = [int]($r.Width * 0.22)
    $ir = New-Object System.Drawing.Rectangle(
        ($r.X + $inset), ($r.Y + $inset),
        ($r.Width - $inset * 2), ($r.Height - $inset * 2))
    $g.DrawEllipse($Pen, $ir)                                   # outer circle
    $g.DrawLine($Pen, $cx, $ir.Top, $cx, $ir.Bottom)            # vertical line
    $g.DrawLine($Pen, $ir.Left, $cy, $ir.Right, $cy)            # horizontal line
    $g.DrawArc($Pen, ($cx - $ir.Width / 4), $ir.Top,
        ($ir.Width / 2), $ir.Height, 0, 180)                    # longitude arc
}

function Invoke-CloudIcon {
    <# Draws a simple cloud silhouette inside a rect. #>
    param($Graphics, $Rect, $Pen)
    $g = $Graphics; $r = $Rect
    $inset = [int]($r.Width * 0.18)
    $bx = $r.X + $inset;  $by = $r.Y + $r.Height * 0.40
    $bw = $r.Width - $inset * 2;  $bh = $r.Height * 0.35
    # Base rounded rect
    $g.DrawArc($Pen, $bx, $by, $bh, $bh, 90, 180)
    $g.DrawLine($Pen, ($bx + $bh / 2), ($by + $bh), ($bx + $bw - $bh / 2), ($by + $bh))
    $g.DrawArc($Pen, ($bx + $bw - $bh), $by, $bh, $bh, 270, 180)
    # Top bump
    $topW = $bw * 0.50;  $topH = $bh * 1.1
    $g.DrawArc($Pen, ($bx + $bw * 0.25), ($by - $topH * 0.50), $topW, $topH, 180, 180)
}

function Invoke-DownloadIcon {
    <# Draws a downward arrow with a base-line inside a rect. #>
    param($Graphics, $Rect, $Pen)
    $g = $Graphics; $r = $Rect
    $cx = $r.X + $r.Width / 2
    $inset = [int]($r.Width * 0.28)
    $top = $r.Y + $inset;  $bot = $r.Y + $r.Height - $inset
    $aw = [int]($r.Width * 0.18)  # arrow-head half-width
    $g.DrawLine($Pen, $cx, $top, $cx, $bot)                     # shaft
    $g.DrawLine($Pen, ($cx - $aw), ($bot - $aw), $cx, $bot)     # left barb
    $g.DrawLine($Pen, ($cx + $aw), ($bot - $aw), $cx, $bot)     # right barb
    $basY = $r.Y + $r.Height - $inset + 3
    $g.DrawLine($Pen, ($r.X + $inset), $basY,
        ($r.X + $r.Width - $inset), $basY)                      # base line
}

function Invoke-CheckmarkIcon {
    <# Draws a checkmark (tick) inside a rect. #>
    param($Graphics, $Rect, $Pen)
    $g = $Graphics; $r = $Rect
    $ix = [int]($r.Width * 0.25);  $iy = [int]($r.Height * 0.25)
    # Three points: left-mid, bottom-centre, top-right
    $p1 = New-Object System.Drawing.PointF(($r.X + $ix),               ($r.Y + $r.Height * 0.52))
    $p2 = New-Object System.Drawing.PointF(($r.X + $r.Width * 0.42),   ($r.Y + $r.Height - $iy))
    $p3 = New-Object System.Drawing.PointF(($r.X + $r.Width - $ix),    ($r.Y + $iy))
    $g.DrawLine($Pen, $p1, $p2)
    $g.DrawLine($Pen, $p2, $p3)
}

# ── Helper: rounded-rectangle GraphicsPath ──────────────────────────────────
# Returns a new GraphicsPath outlining a rounded rectangle.  Callers must
# Dispose() the returned path when done.
function New-RoundedRectPath {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $p.AddArc($X,          $Y,          $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y,          $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d,   0, 90)
    $p.AddArc($X,          $Y + $H - $d, $d, $d,  90, 90)
    $p.CloseFigure()
    return $p
}

# Reusable pen for ring (performance win — avoids per-frame GDI allocation).
# Width is updated in-place by the breathing-pulse timer tick.
$RingPen = New-Object System.Drawing.Pen($LightBlue, 6)
$RingPen.StartCap = "Round"
$RingPen.EndCap = "Round"

# ── Layout spacing constants ────────────────────────────────────────────────
# Named offsets keep Set-ControlLayout readable and easy to tweak.
$Spacing = @{
    IllustH      = 110; IllustGap    = 0      # illustration area + gap
    LogoH        = 50;  LogoGap      = 4      # logo height + gap below
    SubH         = 25;  SubGap       = 6      # subtitle height + gap
    DeviceH      = 60;  DeviceGap    = 20     # device-info card height + gap
    RingH        = 80;  RingGap      = 16     # ring panel height + gap
    StatusH      = 55;  StatusGap    = 3      # status label height + gap
    ProgressH    = 24;  ProgressGap  = 12     # progress text height + gap
    StepH        = 28;  StepGap      = 18     # step panel height + gap
    WiFiBtnH     = 48;  WiFiBtnGap   = 10     # WiFi button height + gap
    RetryBtnH    = 42                          # Retry button height
}
# Total content block height (used to vertically centre the UI).
$script:BlockH = $Spacing.IllustH   + $Spacing.IllustGap   +
                 $Spacing.LogoH   + $Spacing.LogoGap    +
                 $Spacing.SubH    + $Spacing.SubGap      +
                 $Spacing.DeviceH + $Spacing.DeviceGap   +
                 $Spacing.RingH   + $Spacing.RingGap     +
                 $Spacing.StatusH + $Spacing.StatusGap   +
                 $Spacing.ProgressH + $Spacing.ProgressGap +
                 $Spacing.StepH   + $Spacing.StepGap     +
                 $Spacing.WiFiBtnH + $Spacing.WiFiBtnGap +
                 $Spacing.RetryBtnH

# ── Animation state ─────────────────────────────────────────────────────────
$script:fadeOpacity = 0.0          # fade-in: 0 → 1
$script:ringPulse   = 0.0          # breathing ring: sine-wave pulse factor
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

#region ── Main Form ── Fullscreen Autopilot-style UI ─────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = "AmpCloud - Cloud Imaging Engine"
$form.FormBorderStyle = "None"
$form.WindowState = "Maximized"
$form.BackColor = $script:GradientTop   # gradient base colour; Paint handler overlays
$form.Font = $BodyFont
$form.Opacity = 0.0   # start transparent for fade-in animation

# Enable double-buffering so the gradient + card paint are flicker-free.
try {
    $formType = $form.GetType()
    $dbProp = $formType.GetProperty('DoubleBuffered',
        [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($dbProp) { $dbProp.SetValue($form, $true, $null) }
} catch { Write-Verbose "Form double-buffering unavailable: $_" }

# ── Card panel (centred white rounded-corner surface) ───────────────────────
# All content controls live inside this panel so they inherit its white
# BackColor.  The panel gets a rounded Region for OOBE-style rounded corners.
$cardPanel = New-Object System.Windows.Forms.Panel
$cardPanel.BackColor = $LightCard
try {
    $cpType  = $cardPanel.GetType()
    $cpDbProp = $cpType.GetProperty('DoubleBuffered',
        [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($cpDbProp) { $cpDbProp.SetValue($cardPanel, $true, $null) }
} catch { Write-Verbose "Card double-buffering unavailable: $_" }
$form.Controls.Add($cardPanel)

$script:_cardW = 0; $script:_cardH = 0
$cardPanel.Add_SizeChanged({
    if ($cardPanel.Width -le 0 -or $cardPanel.Height -le 0) { return }
    if ($cardPanel.Width -eq $script:_cardW -and $cardPanel.Height -eq $script:_cardH) { return }
    $script:_cardW = $cardPanel.Width
    $script:_cardH = $cardPanel.Height
    $path = New-RoundedRectPath -X 0 -Y 0 -W $script:_cardW -H $script:_cardH -Radius $script:CardRadius
    if ($cardPanel.Region) { $cardPanel.Region.Dispose() }
    $cardPanel.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
})

# ── Form Paint — gradient background + card shadow ──────────────────────────
$form.Add_Paint({
    $g  = $_.Graphics
    $cw = $form.ClientSize.Width
    $ch = $form.ClientSize.Height
    if ($cw -le 0 -or $ch -le 0) { return }

    # Use embedded background image when available; fall back to gradient.
    if ($null -ne $script:BackgroundImage -and -not $script:IsDarkMode) {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($script:BackgroundImage, 0, 0, $cw, $ch)
    } else {
        $gTop = if ($script:IsDarkMode) { $script:DarkGradientTop }    else { $script:GradientTop }
        $gBot = if ($script:IsDarkMode) { $script:DarkGradientBottom } else { $script:GradientBottom }
        $gRect  = New-Object System.Drawing.Rectangle(0, 0, $cw, $ch)
        $gBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                      $gRect, $gTop, $gBot,
                      [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
        $g.FillRectangle($gBrush, $gRect)
        $gBrush.Dispose()
    }

    # Soft shadow behind the card panel
    if ($cardPanel.Width -gt 0 -and $cardPanel.Height -gt 0) {
        $g.SmoothingMode = 'AntiAlias'
        $sp = New-RoundedRectPath -X ($cardPanel.Left + 4) -Y ($cardPanel.Top + 4) `
                                   -W $cardPanel.Width -H $cardPanel.Height -Radius $script:CardRadius
        $sBrush = New-Object System.Drawing.SolidBrush($script:CardShadowColor)
        $g.FillPath($sBrush, $sp)
        $sBrush.Dispose();  $sp.Dispose()
    }
})

# ── Card Paint — OOBE illustration (three overlapping icon circles) ─────────
$cardPanel.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $pw = $cardPanel.Width
    if ($pw -le 0) { return }
    $cx    = [int]($pw / 2)
    $cy    = [int]($script:IllustH / 2)
    $big   = $script:IllustBig
    $small = $script:IllustSmall
    $gap   = $script:IllustGap

    # Left circle — blue (network / globe)
    $b1 = New-Object System.Drawing.SolidBrush($script:IllustBlue)
    $g.FillEllipse($b1,
        ($cx - $big / 2 - $small + $gap), ($cy - $small / 2),
        $small, $small)
    $b1.Dispose()

    # Centre circle — white with light-blue border (cloud)
    $g.FillEllipse([System.Drawing.Brushes]::White,
        ($cx - $big / 2), ($cy - $big / 2), $big, $big)
    $borderPen = New-Object System.Drawing.Pen($script:IllustBlue, 2)
    $g.DrawEllipse($borderPen,
        ($cx - $big / 2), ($cy - $big / 2), $big, $big)
    $borderPen.Dispose()

    # Right circle — violet (deploy / download)
    $b3 = New-Object System.Drawing.SolidBrush($script:IllustViolet)
    $g.FillEllipse($b3,
        ($cx + $big / 2 - $gap), ($cy - $small / 2),
        $small, $small)
    $b3.Dispose()

    # Draw icons inside the circles
    if ($null -ne $script:IconFont) {
        # Segoe MDL2 Assets available — use crisp font glyphs
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment     = 'Center'
        $sf.LineAlignment = 'Center'

        # Globe (E774) in blue circle
        $r1 = New-Object System.Drawing.RectangleF(
            ($cx - $big / 2 - $small + $gap), ($cy - $small / 2), $small, $small)
        $g.DrawString([string][char]0xE774, $script:IconFont,
            [System.Drawing.Brushes]::White, $r1, $sf)

        # Cloud (E753) in centre circle
        $r2 = New-Object System.Drawing.RectangleF(
            ($cx - $big / 2), ($cy - $big / 2), $big, $big)
        $cloudBr = New-Object System.Drawing.SolidBrush($script:IllustBlue)
        $g.DrawString([string][char]0xE753, $script:IconFont, $cloudBr, $r2, $sf)
        $cloudBr.Dispose()

        # Download (E896) in violet circle
        $r3 = New-Object System.Drawing.RectangleF(
            ($cx + $big / 2 - $gap), ($cy - $small / 2), $small, $small)
        $g.DrawString([string][char]0xE896, $script:IconFont,
            [System.Drawing.Brushes]::White, $r3, $sf)

        $sf.Dispose()
    } else {
        # Fallback — draw GDI+ shapes (no font dependency)
        $iconPenW = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)
        $iconPenB = New-Object System.Drawing.Pen($script:IllustBlue, 2)

        $r1 = New-Object System.Drawing.Rectangle(
            ($cx - $big / 2 - $small + $gap), ($cy - $small / 2), $small, $small)
        Invoke-GlobeIcon -Graphics $g -Rect $r1 -Pen $iconPenW

        $r2 = New-Object System.Drawing.Rectangle(
            ($cx - $big / 2), ($cy - $big / 2), $big, $big)
        Invoke-CloudIcon -Graphics $g -Rect $r2 -Pen $iconPenB

        $r3 = New-Object System.Drawing.Rectangle(
            ($cx + $big / 2 - $gap), ($cy - $small / 2), $small, $small)
        Invoke-DownloadIcon -Graphics $g -Rect $r3 -Pen $iconPenW

        $iconPenW.Dispose()
        $iconPenB.Dispose()
    }
})

# ── F8 command prompt shortcut ──────────────────────────────────────────────
# Enable KeyPreview so the form sees key events before child controls.
# F8 opens a new PowerShell console for diagnostics (similar to Shift+F10
# in Windows Setup).  cmd.exe could be used, but PowerShell is more useful
# in WinPE and is already the engine behind AmpCloud.
$form.KeyPreview = $true
$form.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F8) {
        Start-Process $script:PsBin -ArgumentList '-NoProfile', '-NoExit'
    }
})

# ── Dark mode toggle (top-right corner) ─────────────────────────────────────
$btnDark = New-Object System.Windows.Forms.Button
$btnDark.Size = New-Object System.Drawing.Size(44, 44)
$btnDark.FlatStyle = "Flat"
$btnDark.FlatAppearance.BorderSize = 0
$btnDark.Font = New-Object System.Drawing.Font("Segoe UI", 14)
$btnDark.Text = [char]0x263D          # crescent moon ☽
$btnDark.ForeColor = [System.Drawing.Color]::Gray
$btnDark.BackColor = $script:GradientTop
$btnDark.Anchor = [System.Windows.Forms.AnchorStyles]::None
$form.Controls.Add($btnDark)

# ── Logo ────────────────────────────────────────────────────────────────────
$logo = New-Object System.Windows.Forms.Label
$logo.Text = $S.Header
$logo.Font = $HeroFont
$logo.ForeColor = $LightBlue
$logo.TextAlign = "MiddleCenter"
$logo.AutoSize = $false
$cardPanel.Controls.Add($logo)

# ── Subtitle ────────────────────────────────────────────────────────────────
$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = $S.Subtitle
$subtitleLabel.Font = $BodyFont
$subtitleLabel.ForeColor = [System.Drawing.Color]::Gray
$subtitleLabel.TextAlign = "MiddleCenter"
$subtitleLabel.AutoSize = $false
$cardPanel.Controls.Add($subtitleLabel)

# ── Device info (enhanced — CPU, RAM, Disk alongside model & serial) ────────
$deviceLabel = New-Object System.Windows.Forms.Label
try {
    $model  = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
    $serial = (Get-CimInstance Win32_Bios -ErrorAction SilentlyContinue).SerialNumber
    $cpuRaw = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue |
                   Select-Object -First 1).Name
    $cpu    = if ($cpuRaw) { ($cpuRaw -replace '\s+', ' ').Trim() } else { 'Unknown CPU' }
    $ramObj = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $ramGB  = if ($ramObj -and $ramObj.TotalPhysicalMemory) {
                  [Math]::Round($ramObj.TotalPhysicalMemory / 1GB, 1)
              } else { '?' }
    $diskObj = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
                   Select-Object -First 1
    $diskGB  = if ($diskObj -and $diskObj.Size) { [Math]::Round($diskObj.Size / 1GB) } else { '?' }
    $dot     = "  $([char]0x2022)  "
    $deviceLabel.Text = "$model${dot}S/N $serial`n$cpu${dot}${ramGB} GB RAM${dot}${diskGB} GB Disk"
} catch {
    $deviceLabel.Text = "Device: Unknown"
}
$deviceLabel.Font      = $InfoFont
$deviceLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$deviceLabel.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$deviceLabel.TextAlign = "MiddleCenter"
$deviceLabel.AutoSize  = $false
$deviceLabel.Padding   = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
$cardPanel.Controls.Add($deviceLabel)

# ── Animated Progress Ring ──────────────────────────────────────────────────
$ringPanel = New-Object System.Windows.Forms.Panel
$ringPanel.Size = New-Object System.Drawing.Size(80, 80)
$ringPanel.BackColor = [System.Drawing.Color]::Transparent
$ringPanel.Visible = $false

# DoubleBuffered and SetStyle are protected members; use reflection so WinPE
# doesn't throw a PropertyAssignmentException that kills the script.
try {
    $panelType = $ringPanel.GetType()
    $dbProp = $panelType.GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($dbProp) { $dbProp.SetValue($ringPanel, $true, $null) }
    $setStyleMethod = $panelType.GetMethod('SetStyle', [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($setStyleMethod) {
        $styles = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor
                  [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor
                  [System.Windows.Forms.ControlStyles]::UserPaint
        $setStyleMethod.Invoke($ringPanel, @($styles, $true))
    }
    $ringPanel.UpdateStyles()
} catch {
    Write-Verbose "Double-buffering unavailable: $_"
}
$cardPanel.Controls.Add($ringPanel)

$script:ringAngle = 0
$ringTimer = New-Object System.Windows.Forms.Timer
$ringTimer.Interval = 48
$ringTimer.Add_Tick({
    $script:ringAngle = ($script:ringAngle + 8) % 360
    # Breathing pulse: pen width oscillates between ~4.5 and ~7.5 via a sine wave.
    $script:ringPulse = [Math]::Sin($script:ringAngle * [Math]::PI / 180)
    $RingPen.Width    = 6 + $script:ringPulse * 1.5
    $ringPanel.Invalidate()
})
$ringPanel.Add_Paint({
    try {
        $g = $_.Graphics
        $g.SmoothingMode = "AntiAlias"
        $g.DrawArc($RingPen, 6, 6, 66, 66, $script:ringAngle, 280)
    } catch { Write-Verbose "Ring paint error: $_" }
})

# ── Status label ────────────────────────────────────────────────────────────
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Font = $TitleFont
$statusLabel.ForeColor = $TextLight
$statusLabel.TextAlign = "MiddleCenter"
$statusLabel.AutoSize = $false
$cardPanel.Controls.Add($statusLabel)

# ── Progress / download text ────────────────────────────────────────────────
$progressText = New-Object System.Windows.Forms.Label
$progressText.Font = $SmallFont
$progressText.ForeColor = [System.Drawing.Color]::Gray
$progressText.TextAlign = "MiddleCenter"
$progressText.AutoSize = $false
$cardPanel.Controls.Add($progressText)

# ── Step indicators ─────────────────────────────────────────────────────────
$stepPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$stepPanel.FlowDirection = "LeftToRight"
$stepPanel.AutoSize = $true
$stepPanel.WrapContents = $false
$stepPanel.BackColor = [System.Drawing.Color]::Transparent
$cardPanel.Controls.Add($stepPanel)

$stepLabels = [System.Collections.Generic.List[System.Windows.Forms.Label]]::new()
$stepNum = 0
foreach ($stepText in @($S.Step1, $S.Step2, $S.Step3, $S.Step4)) {
    $stepNum++
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$([char]0x25CF) $stepNum $stepText"
    $lbl.Font = $SmallFont
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.AutoSize = $true
    $lbl.Margin = New-Object System.Windows.Forms.Padding(20, 0, 20, 0)
    $stepLabels.Add($lbl)
    $stepPanel.Controls.Add($lbl)
}

# ── Buttons ─────────────────────────────────────────────────────────────────
$btnWiFi = New-Object System.Windows.Forms.Button
$btnWiFi.Text = "Connect via WiFi"
$btnWiFi.Size = New-Object System.Drawing.Size(260, 48)
$btnWiFi.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$btnWiFi.BackColor = $LightBlue
$btnWiFi.ForeColor = [System.Drawing.Color]::White
$btnWiFi.FlatStyle = "Flat"
$btnWiFi.FlatAppearance.BorderSize = 0
$btnWiFi.Visible = $false
$cardPanel.Controls.Add($btnWiFi)

$btnRetry = New-Object System.Windows.Forms.Button
$btnRetry.Text = "Retry"
$btnRetry.Size = New-Object System.Drawing.Size(160, 42)
$btnRetry.Font = $BodyFont
$btnRetry.BackColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$btnRetry.ForeColor = $TextLight
$btnRetry.FlatStyle = "Flat"
$btnRetry.FlatAppearance.BorderSize = 0
$btnRetry.Visible = $false
$cardPanel.Controls.Add($btnRetry)

# ── F8 hint (bottom-left) ───────────────────────────────────────────────────
$f8Hint = New-Object System.Windows.Forms.Label
$f8Hint.Text = "Press F8 for command prompt"
$f8Hint.Font = $SmallFont
$f8Hint.ForeColor = [System.Drawing.Color]::FromArgb(120, 130, 150)
$f8Hint.BackColor = $script:GradientBottom
$f8Hint.AutoSize = $true
$form.Controls.Add($f8Hint)

# ── Company logo (bottom-right) ─────────────────────────────────────────────
$brandLabel = New-Object System.Windows.Forms.Label
$brandLabel.Text      = 'ampliosoft'
$brandLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
$brandLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 130, 150)
$brandLabel.BackColor = $script:GradientBottom
$brandLabel.AutoSize  = $true
$form.Controls.Add($brandLabel)

# ── Dynamic centering ───────────────────────────────────────────────────────
# Positions the card panel centred on the form, then lays out all child
# controls within the card.
$contentW = 600
function Set-ControlLayout {
    $cw = $form.ClientSize.Width
    $ch = $form.ClientSize.Height

    # ── Card panel position + size ──────────────────────────────────────────
    $cardW = [Math]::Min($script:CardMaxW, $cw - 100)
    $cardH = [Math]::Min($ch - 80, $script:BlockH + $script:CardPadTop + $script:CardPadBottom)
    $cardX = [int](($cw - $cardW) / 2)
    $cardY = [int](($ch - $cardH) / 2)
    $cardPanel.SetBounds($cardX, $cardY, $cardW, $cardH)

    # ── Content within card ─────────────────────────────────────────────────
    $cpw = $cardPanel.Width
    $cx  = [int]($cpw / 2)
    $cntW = [Math]::Min($contentW, $cpw - 60)

    $y = $script:CardPadTop + $Spacing.IllustH + $Spacing.IllustGap

    $logo.SetBounds(($cx - $cntW / 2), $y, $cntW, $Spacing.LogoH)
    $y += $Spacing.LogoH + $Spacing.LogoGap

    $subtitleLabel.SetBounds(($cx - $cntW / 2), $y, $cntW, $Spacing.SubH)
    $y += $Spacing.SubH + $Spacing.SubGap

    $deviceLabel.SetBounds(30, $y, ($cpw - 60), $Spacing.DeviceH)
    $y += $Spacing.DeviceH + $Spacing.DeviceGap

    $ringPanel.Location = New-Object System.Drawing.Point(($cx - 40), $y)
    $y += $Spacing.RingH + $Spacing.RingGap

    $statusLabel.SetBounds(($cx - $cntW / 2), $y, $cntW, $Spacing.StatusH)
    $y += $Spacing.StatusH + $Spacing.StatusGap

    $progressText.SetBounds(($cx - $cntW / 2), $y, $cntW, $Spacing.ProgressH)
    $y += $Spacing.ProgressH + $Spacing.ProgressGap

    $stepPanel.Location = New-Object System.Drawing.Point(
        [int]($cx - $stepPanel.Width / 2), $y)
    $y += $Spacing.StepH + $Spacing.StepGap

    $btnWiFi.Location  = New-Object System.Drawing.Point(($cx - 130), $y)
    $y += $Spacing.WiFiBtnH + $Spacing.WiFiBtnGap

    $btnRetry.Location = New-Object System.Drawing.Point(($cx - 80), $y)

    # Dark mode button stays top-right of form (outside card)
    $btnDark.Location = New-Object System.Drawing.Point(($cw - 60), 16)

    # F8 hint anchored to bottom-left of form
    $f8Hint.Location = New-Object System.Drawing.Point(16, ($ch - 30))

    # Company logo anchored to bottom-right of form
    $brandLabel.Location = New-Object System.Drawing.Point(($cw - $brandLabel.Width - 16), ($ch - 30))
}

$form.Add_Resize({ Set-ControlLayout })

# ── Helper functions ────────────────────────────────────────────────────────
function Write-Status {
    param([string]$Message, [string]$Color = 'Black')
    $statusLabel.ForeColor = switch ($Color) {
        'Green'  { [System.Drawing.Color]::DarkGreen; break }
        'Red'    { [System.Drawing.Color]::Red; break }
        'Yellow' { [System.Drawing.Color]::OrangeRed; break }
        'Cyan'   { $LightBlue; break }
        default  { if ($script:IsDarkMode) { $TextDark } else { $TextLight } }
    }
    $statusLabel.Text = $Message
    $form.Refresh()
}

function Update-Step { param([int]$s)
    for ($i = 0; $i -lt $stepLabels.Count; $i++) {
        $stepLabels[$i].ForeColor = if ($i -lt $s) { $LightBlue } else { [System.Drawing.Color]::Gray }
    }
}

function Switch-DarkMode {
    $script:IsDarkMode = -not $script:IsDarkMode
    $bg  = if ($script:IsDarkMode) { $script:DarkGradientTop } else { $script:GradientTop }
    $fg  = if ($script:IsDarkMode) { $TextDark }  else { $TextLight }
    $form.BackColor          = $bg
    $cardPanel.BackColor     = if ($script:IsDarkMode) { $DarkCard } else { $LightCard }
    $btnDark.BackColor       = $bg
    $btnDark.ForeColor       = $fg
    $statusLabel.ForeColor   = $fg
    $logo.ForeColor          = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(100, 180, 255) } else { $LightBlue }
    $subtitleLabel.ForeColor = if ($script:IsDarkMode) { [System.Drawing.Color]::Silver } else { [System.Drawing.Color]::Gray }
    $deviceLabel.ForeColor   = if ($script:IsDarkMode) { [System.Drawing.Color]::Silver } else { [System.Drawing.Color]::FromArgb(100, 100, 100) }
    $deviceLabel.BackColor   = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(50, 50, 55) } else { [System.Drawing.Color]::FromArgb(245, 247, 250) }
    $f8Hint.BackColor        = if ($script:IsDarkMode) { $script:DarkGradientBottom } else { $script:GradientBottom }
    $f8Hint.ForeColor        = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(120, 120, 130) } else { [System.Drawing.Color]::FromArgb(120, 130, 150) }
    $brandLabel.BackColor    = if ($script:IsDarkMode) { $script:DarkGradientBottom } else { $script:GradientBottom }
    $brandLabel.ForeColor    = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(120, 120, 130) } else { [System.Drawing.Color]::FromArgb(120, 130, 150) }
    $btnDark.Text            = if ($script:IsDarkMode) { [char]0x2600 } else { [char]0x263D }
    $form.Invalidate()
    $form.Refresh()
}
$btnDark.Add_Click({ Switch-DarkMode })

# ── Fade-in timer ───────────────────────────────────────────────────────────
# Smoothly ramps form opacity from 0 → 1 over ~1 second.  Started in the
# Form.Shown handler, runs only once at startup.
$script:fadeInTimer = New-Object System.Windows.Forms.Timer
$script:fadeInTimer.Interval = 16          # ~60 fps
$script:fadeInTimer.Add_Tick({
    $script:fadeOpacity = [Math]::Min(1.0, $script:fadeOpacity + 0.06)
    $form.Opacity = $script:fadeOpacity
    if ($script:fadeOpacity -ge 1.0) { $script:fadeInTimer.Stop() }
})

# ── Live status IPC from AmpCloud.ps1 ──────────────────────────────────────
# AmpCloud.ps1 writes progress to a JSON file; we poll it to update the UI
# so the user sees real-time imaging status instead of a static spinner.
$script:StatusFile = "X:\AmpCloud-Status.json"

$script:uiUpdateTimer = New-Object System.Windows.Forms.Timer
$script:uiUpdateTimer.Interval = 650
$script:uiUpdateTimer.Add_Tick({
    if (-not (Test-Path $script:StatusFile)) { return }
    try {
        $status = Get-Content $script:StatusFile -Raw -ErrorAction SilentlyContinue |
                  ConvertFrom-Json
        if ($status) {
            if ($status.Message) {
                Write-Status $status.Message 'Cyan'
            }
            if ($status.Progress -gt 0) {
                $detail = if ($status.Detail) { $status.Detail } else { $status.Message }
                $progressText.Text = "$detail  $($script:BulletChar)  $($status.Progress)%"
            }
            if ($status.Step -gt 0) {
                Update-Step $status.Step
            }
            if ($status.Done) {
                $ringTimer.Stop()
            }
        }
    } catch { Write-Verbose "Status JSON parse error: $_" }
})
#endregion

#region ── Final Completion Screen (fullscreen) ─────────────────────────────
function Show-CompletionScreen {
    Invoke-Sound 1200 400
    $finalForm = New-Object System.Windows.Forms.Form
    $finalForm.Text = $S.Complete
    $finalForm.FormBorderStyle = "None"
    $finalForm.WindowState = "Maximized"
    $fBg = if ($script:IsDarkMode) { $script:DarkGradientTop } else { $script:GradientTop }
    $finalForm.BackColor = $fBg
    $finalForm.Font = $BodyFont

    # Double-buffer the final form for gradient painting
    try {
        $fType = $finalForm.GetType()
        $fDb   = $fType.GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($fDb) { $fDb.SetValue($finalForm, $true, $null) }
    } catch { Write-Verbose "Final form double-buffering unavailable: $_" }

    # F8 command prompt shortcut (same as main form)
    $finalForm.KeyPreview = $true
    $finalForm.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F8) {
            Start-Process $script:PsBin -ArgumentList '-NoProfile', '-NoExit'
        }
    })

    # ── Card panel for completion content ────────────────────────────────────
    $fCard = New-Object System.Windows.Forms.Panel
    $fCard.BackColor = if ($script:IsDarkMode) { $DarkCard } else { $LightCard }
    try {
        $fcType = $fCard.GetType()
        $fcDb   = $fcType.GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($fcDb) { $fcDb.SetValue($fCard, $true, $null) }
    } catch { Write-Verbose "Card double-buffering unavailable: $_" }
    $finalForm.Controls.Add($fCard)

    # Rounded corners
    $fCard.Add_SizeChanged({
        if ($fCard.Width -le 0 -or $fCard.Height -le 0) { return }
        $p = New-RoundedRectPath -X 0 -Y 0 -W $fCard.Width -H $fCard.Height -Radius $script:CardRadius
        if ($fCard.Region) { $fCard.Region.Dispose() }
        $fCard.Region = New-Object System.Drawing.Region($p)
        $p.Dispose()
    })

    # Gradient / background-image + shadow Paint handler
    $finalForm.Add_Paint({
        $g  = $_.Graphics
        $fw = $finalForm.ClientSize.Width
        $fh = $finalForm.ClientSize.Height
        if ($fw -le 0 -or $fh -le 0) { return }
        if ($null -ne $script:BackgroundImage -and -not $script:IsDarkMode) {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($script:BackgroundImage, 0, 0, $fw, $fh)
        } else {
            $gt = if ($script:IsDarkMode) { $script:DarkGradientTop }    else { $script:GradientTop }
            $gb = if ($script:IsDarkMode) { $script:DarkGradientBottom } else { $script:GradientBottom }
            $gr = New-Object System.Drawing.Rectangle(0, 0, $fw, $fh)
            $gBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                       $gr, $gt, $gb,
                       [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            $g.FillRectangle($gBrush, $gr)
            $gBrush.Dispose()
        }
        if ($fCard.Width -gt 0 -and $fCard.Height -gt 0) {
            $g.SmoothingMode = 'AntiAlias'
            $sp = New-RoundedRectPath -X ($fCard.Left + 4) -Y ($fCard.Top + 4) `
                                       -W $fCard.Width -H $fCard.Height -Radius $script:CardRadius
            $sb = New-Object System.Drawing.SolidBrush($script:CardShadowColor)
            $g.FillPath($sb, $sp)
            $sb.Dispose(); $sp.Dispose()
        }
    })

    # ── Checkmark illustration on card ──────────────────────────────────────
    $fCard.Add_Paint({
        $g = $_.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $fcx = [int]($fCard.Width / 2)
        $fcy = 50
        $circBrush = New-Object System.Drawing.SolidBrush($script:IllustGreen)
        $g.FillEllipse($circBrush, ($fcx - 30), ($fcy - 30), 60, 60)
        $circBrush.Dispose()
        if ($null -ne $script:IconFont) {
            $isf = New-Object System.Drawing.StringFormat
            $isf.Alignment     = 'Center'
            $isf.LineAlignment = 'Center'
            $ir = New-Object System.Drawing.RectangleF(($fcx - 30), ($fcy - 30), 60, 60)
            $g.DrawString([string][char]0xE73E, $script:IconFont,
                [System.Drawing.Brushes]::White, $ir, $isf)
            $isf.Dispose()
        } else {
            $checkPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3)
            $checkPen.StartCap = 'Round'; $checkPen.EndCap = 'Round'
            $ir = New-Object System.Drawing.Rectangle(($fcx - 30), ($fcy - 30), 60, 60)
            Invoke-CheckmarkIcon -Graphics $g -Rect $ir -Pen $checkPen
            $checkPen.Dispose()
        }
    })

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$($S.Complete)`n`nAmpCloud imaging engine is ready."
    $lbl.Font = $HeroFont
    $lbl.ForeColor = if ($script:IsDarkMode) { $TextDark } else { $TextLight }
    $lbl.TextAlign = "MiddleCenter"
    $lbl.AutoSize = $false
    $fCard.Controls.Add($lbl)

    $btnReboot = New-Object System.Windows.Forms.Button
    $btnReboot.Text      = $S.Reboot
    $btnReboot.Size      = New-Object System.Drawing.Size(200, 52)
    $btnReboot.BackColor = [System.Drawing.Color]::FromArgb(16, 124, 16)
    $btnReboot.ForeColor = [System.Drawing.Color]::White
    $btnReboot.FlatStyle = "Flat"
    $btnReboot.FlatAppearance.BorderSize = 0
    $btnReboot.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $fCard.Controls.Add($btnReboot)

    $btnPower = New-Object System.Windows.Forms.Button
    $btnPower.Text      = $S.PowerOff
    $btnPower.Size      = New-Object System.Drawing.Size(200, 52)
    $btnPower.BackColor = [System.Drawing.Color]::FromArgb(196, 43, 28)
    $btnPower.ForeColor = [System.Drawing.Color]::White
    $btnPower.FlatStyle = "Flat"
    $btnPower.FlatAppearance.BorderSize = 0
    $btnPower.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $fCard.Controls.Add($btnPower)

    $btnShell = New-Object System.Windows.Forms.Button
    $btnShell.Text     = $S.Shell
    $btnShell.Size     = New-Object System.Drawing.Size(200, 52)
    $btnShell.BackColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
    $btnShell.ForeColor = $TextLight
    $btnShell.FlatStyle = "Flat"
    $btnShell.FlatAppearance.BorderSize = 0
    $btnShell.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $fCard.Controls.Add($btnShell)

    $btnReboot.Add_Click({ Restart-Computer -Force })
    $btnPower.Add_Click({ Stop-Computer -Force })
    $btnShell.Add_Click({
        $finalForm.Close()
        & $script:PsBin -NoProfile -NoExit
    })

    $f8HintFinal = New-Object System.Windows.Forms.Label
    $f8HintFinal.Text = "Press F8 for command prompt"
    $f8HintFinal.Font = $SmallFont
    $f8HintFinal.ForeColor = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(120, 120, 130) } else { [System.Drawing.Color]::FromArgb(120, 130, 150) }
    $f8HintFinal.BackColor = if ($script:IsDarkMode) { $script:DarkGradientBottom } else { $script:GradientBottom }
    $f8HintFinal.AutoSize = $true
    $finalForm.Controls.Add($f8HintFinal)

    # Company logo (bottom-right)
    $brandFinal = New-Object System.Windows.Forms.Label
    $brandFinal.Text      = 'ampliosoft'
    $brandFinal.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
    $brandFinal.ForeColor = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(120, 120, 130) } else { [System.Drawing.Color]::FromArgb(120, 130, 150) }
    $brandFinal.BackColor = if ($script:IsDarkMode) { $script:DarkGradientBottom } else { $script:GradientBottom }
    $brandFinal.AutoSize  = $true
    $finalForm.Controls.Add($brandFinal)

    # Centre card + controls on resize
    $finalForm.Add_Resize({
        $fw = $finalForm.ClientSize.Width
        $fh = $finalForm.ClientSize.Height
        $cW = [Math]::Min(720, $fw - 100)
        $cH = 320
        $fCard.SetBounds([int](($fw - $cW) / 2), [int](($fh - $cH) / 2), $cW, $cH)
        $ccx = [int]($fCard.Width / 2)
        $lbl.SetBounds(($ccx - 300), 90, 600, 100)
        $gap = 16
        $totalBtnW = 200 * 3 + $gap * 2
        $bx = [int]($ccx - $totalBtnW / 2)
        $by = 220
        $btnReboot.Location = New-Object System.Drawing.Point($bx, $by)
        $btnPower.Location  = New-Object System.Drawing.Point(($bx + 200 + $gap), $by)
        $btnShell.Location  = New-Object System.Drawing.Point(($bx + 400 + $gap * 2), $by)
        $f8HintFinal.Location = New-Object System.Drawing.Point(16, ($fh - 30))
        $brandFinal.Location  = New-Object System.Drawing.Point(($fw - $brandFinal.Width - 16), ($fh - 30))
    })

    $null = $finalForm.ShowDialog()
}
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
    $edGradTop  = if ($script:IsDarkMode) { $script:DarkGradientTop }    else { $script:GradientTop }
    $edGradBot  = if ($script:IsDarkMode) { $script:DarkGradientBottom } else { $script:GradientBottom }
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
    param([string] $ClientId)

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
            Write-AuthLog "Listener port $port failed (attempt $attempt): $_"
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
        "&scope=$([uri]::EscapeDataString('openid profile'))" +
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
    $asyncResult = $listener.BeginGetContext($null, $null)

    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 500
    $pollTimer.Add_Tick({
        if ($asyncResult.IsCompleted -or $asyncResult.AsyncWaitHandle.WaitOne(0)) {
            $pollTimer.Stop()
            try {
                $context = $script:_edgeListener.EndGetContext($asyncResult)

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
            $edgeProcess.Kill()
            $edgeProcess.WaitForExit(5000)
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
                "&scope=$([uri]::EscapeDataString('openid profile'))" +
                "&code=$([uri]::EscapeDataString($script:_edgeAuthCode))" +
                "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
                '&grant_type=authorization_code' +
                "&code_verifier=$([uri]::EscapeDataString($codeVerifier))"
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
        $raw = $wc.UploadString($tokenUrl, 'POST', $body)
        $tokenResponse = $raw | ConvertFrom-Json
        if ($tokenResponse.id_token) {
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
    .OUTPUTS
        $true on success, $false on failure or cancellation.
    #>
    param([string] $ClientId)

    $deviceCodeUrl = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode'
    $tokenUrl      = 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token'
    $scope         = 'openid profile'
    $grantType     = 'urn:ietf:params:oauth:grant-type:device_code'

    $deviceResponse = $null
    try {
        $body = "client_id=$([uri]::EscapeDataString($ClientId))&scope=$([uri]::EscapeDataString($scope))"
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

    Write-Status $S.AuthSigning 'Cyan'
    [System.Windows.Forms.Application]::DoEvents()

    # ── Try standalone Edge browser first ───────────────────────────────────
    # Edge is launched directly with WinPE-safe Chromium flags.  A localhost
    # HTTP listener captures the OAuth redirect.  Requires the Edge browser
    # to be embedded during Build-WinPE (step 4e).  If Edge is not present
    # or fails, fall back to Device Code Flow transparently.
    $browserOk = $false
    try {
        $browserOk = Invoke-M365EdgeAuth -ClientId $clientId
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
        $deviceOk = Invoke-M365DeviceCodeAuth -ClientId $clientId
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
    Invoke-Sound 900 300
    $ringPanel.Visible = $true
    $ringTimer.Start()

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
        $ringTimer.Stop()
        $ringPanel.Visible = $false
        return
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

        # Run AmpCloud.ps1 in a dedicated process so the WinForms UI thread
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
        $engineProc = Start-Process -FilePath $script:PsBin -ArgumentList $psArgs -WindowStyle Hidden -PassThru

        # Start polling the status file so the UI shows real-time progress.
        $script:uiUpdateTimer.Start()

        Write-Status $S.Imaging 'Cyan'
        while (-not $engineProc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
        if ($engineProc.ExitCode -ne 0) { $engineFailed = $true }
    } catch {
        # Engine already printed diagnostics; close the UI so the console
        # is usable.  The -NoExit PowerShell host from ampcloud-start.cmd
        # provides the interactive prompt for troubleshooting.
        $engineFailed = $true
    }

    $script:uiUpdateTimer.Stop()
    $ringTimer.Stop()
    Stop-Transcript -ErrorAction SilentlyContinue
    $form.Close()

    if (-not $engineFailed) {
        Show-CompletionScreen
    }
}

function Show-Failure {
    Invoke-Sound 400 600
    Write-Status "Could not connect to the internet.`nPlease check your network." 'Red'
    $btnRetry.Visible = $true
    $btnRetry.Add_Click({
        $btnRetry.Visible = $false
        $hasInternet = Test-InternetConnectivity
        if ($hasInternet) {
            ProceedToEngine
        } else {
            # Close the form; the -NoExit PowerShell host from
            # ampcloud-start.cmd provides the interactive prompt.
            $form.Close()
        }
    })
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
                ProceedToEngine
            } else {
                Update-Step 2
                $ringTimer.Stop()
                $ringPanel.Visible = $false
                Write-Status $S.StatusNoNet 'Yellow'
                $btnWiFi.Visible = $true
                $btnWiFi.Add_Click({
                    $script:connectCheckTimer.Stop()
                    $btnWiFi.Visible = $false
                    $ringPanel.Visible = $true
                    $ringTimer.Start()
                    $wifiConnected = Show-WiFiSelector
                    $ringTimer.Stop()
                    $ringPanel.Visible = $false
                    if ($wifiConnected) { ProceedToEngine } else { Show-Failure }
                })

                # Periodically re-check wired connectivity so a late DHCP
                # lease or cable plug-in proceeds without manual action.
                $script:connectCheckTimer.Interval = $script:ConnectCheckIntervalMs
                $script:connectCheckTimer.Add_Tick({
                    if (Test-InternetConnectivity) {
                        $script:connectCheckTimer.Stop()
                        $btnWiFi.Visible = $false
                        ProceedToEngine
                    }
                })
                $script:connectCheckTimer.Start()
            }
        }
    }
})

$form.Add_Shown({
    Set-ControlLayout
    Update-Step 1
    Write-Status $S.StatusInit 'Cyan'
    $ringPanel.Visible = $true
    $ringTimer.Start()
    $script:initTimer.Start()
    $script:fadeInTimer.Start()
})

# Launch
[System.Windows.Forms.Application]::EnableVisualStyles()
$null = $form.ShowDialog()
Stop-Transcript -ErrorAction SilentlyContinue
#endregion

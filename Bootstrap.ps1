#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Bootstrap - Graphical WinRE/WinPE loader with Fluent UI.
.DESCRIPTION
    Runs inside the WinRE/WinPE boot environment via winpeshl.ini.
    - Calls wpeinit.exe to initialise the WinPE network stack and DHCP.
    - Shows a language selection prompt (EN / FR / ES).
    - Presents an animated Fluent-style WinForms interface.
    - Applies high-performance network tuning.
    - Offers an interactive graphical WiFi selector when wired internet is unavailable.
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

# ── Assemblies ──────────────────────────────────────────────────────────────
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

#region ── Language System ───────────────────────────────────────────────────
$script:Lang = 'EN'
function Select-Language {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "AmpCloud — Language / Langue / Idioma"
    $dlg.Size            = New-Object System.Drawing.Size(480, 300)
    $dlg.StartPosition   = "CenterScreen"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.Font            = New-Object System.Drawing.Font("Segoe UI", 10)
    $dlg.BackColor       = [System.Drawing.Color]::White

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = "Choose your language / Choisissez votre langue / Elija su idioma"
    $lbl.Location  = New-Object System.Drawing.Point(30, 30)
    $lbl.Size      = New-Object System.Drawing.Size(400, 40)
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $dlg.Controls.Add($lbl)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Items.AddRange(@("English (EN)", "Français (FR)", "Español (ES)"))
    $combo.SelectedIndex  = 0
    $combo.Location       = New-Object System.Drawing.Point(30, 80)
    $combo.Width          = 400
    $combo.Height         = 32
    $combo.DropDownStyle  = "DropDownList"
    $combo.FlatStyle      = "Flat"
    $dlg.Controls.Add($combo)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text             = "Continue →"
    $btn.Location         = New-Object System.Drawing.Point(160, 180)
    $btn.Size             = New-Object System.Drawing.Size(150, 42)
    $btn.BackColor        = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btn.ForeColor        = [System.Drawing.Color]::White
    $btn.FlatStyle        = "Flat"
    $btn.FlatAppearance.BorderSize = 0
    $btn.Font             = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btn.DialogResult     = "OK"
    $dlg.Controls.Add($btn)
    $dlg.AcceptButton     = $btn

    if ($dlg.ShowDialog() -eq "OK") {
        switch ($combo.SelectedIndex) {
            0 { $script:Lang = 'EN' }
            1 { $script:Lang = 'FR' }
            2 { $script:Lang = 'ES' }
        }
    }
}
Select-Language

$Strings = @{
    EN = @{ Header="A M P C L O U D"; Subtitle="Cloud Imaging Engine";
            Step1="Network"; Step2="Connect"; Step3="Deploy";
            StatusInit="Initialising network stack...";
            StatusNoNet="No wired connection detected`nTap below to join Wi-Fi";
            Connected="Connected — launching imaging engine";
            Download="Downloading AmpCloud.ps1  ({0}%)";
            Complete="Ready to deploy";
            Reboot="Restart now"; PowerOff="Shut down"; Shell="Command prompt";
            Imaging="Imaging in progress...";
            CatalogFetch="Loading Windows editions...";
            CatalogFail="Could not load catalog — using default edition.";
            EditionTitle="Choose edition";
            EditionLabel="Select the Windows edition to install:";
            EditionBtn="Continue" }
    FR = @{ Header="A M P C L O U D"; Subtitle="Moteur d'imagerie cloud";
            Step1="Réseau"; Step2="Connexion"; Step3="Déploiement";
            StatusInit="Initialisation de la pile réseau...";
            StatusNoNet="Pas de connexion filaire détectée`nAppuyez ci-dessous pour le Wi-Fi";
            Connected="Connecté — lancement du moteur d'imagerie";
            Download="Téléchargement AmpCloud.ps1  ({0}%)";
            Complete="Prêt à déployer";
            Reboot="Redémarrer maintenant"; PowerOff="Éteindre"; Shell="Invite de commandes";
            Imaging="Imagerie en cours...";
            CatalogFetch="Chargement des éditions Windows...";
            CatalogFail="Impossible de charger le catalogue — édition par défaut utilisée.";
            EditionTitle="Choisir l'édition";
            EditionLabel="Sélectionnez l'édition Windows à installer :";
            EditionBtn="Continuer" }
    ES = @{ Header="A M P C L O U D"; Subtitle="Motor de imágenes en la nube";
            Step1="Red"; Step2="Conectar"; Step3="Desplegar";
            StatusInit="Inicializando pila de red...";
            StatusNoNet="Sin conexión cableada detectada`nToque abajo para Wi-Fi";
            Connected="Conectado — iniciando motor de imagen";
            Download="Descargando AmpCloud.ps1  ({0}%)";
            Complete="Listo para desplegar";
            Reboot="Reiniciar ahora"; PowerOff="Apagar"; Shell="Símbolo del sistema";
            Imaging="Creación de imagen en curso...";
            CatalogFetch="Cargando ediciones de Windows...";
            CatalogFail="No se pudo cargar el catálogo — usando edición predeterminada.";
            EditionTitle="Elegir edición";
            EditionLabel="Seleccione la edición de Windows a instalar:";
            EditionBtn="Continuar" }
}
$script:S = $Strings[$script:Lang]
#endregion

#region ── Sound Effects ─────────────────────────────────────────────────────
function Play-Sound {
    param([int]$Freq = 800, [int]$Dur = 200)
    [console]::beep($Freq, $Dur)
}
#endregion

#region ── Fluent Theme ──────────────────────────────────────────────────────
$LightBlue   = [System.Drawing.Color]::FromArgb(0, 120, 212)
$DarkBlue    = [System.Drawing.Color]::FromArgb(0, 80, 160)
$LightBg     = [System.Drawing.Color]::FromArgb(243, 243, 243)
$DarkBg      = [System.Drawing.Color]::FromArgb(32, 32, 32)
$LightCard   = [System.Drawing.Color]::White
$DarkCard    = [System.Drawing.Color]::FromArgb(45, 45, 45)
$TextLight   = [System.Drawing.Color]::FromArgb(32, 32, 32)
$TextDark    = [System.Drawing.Color]::White

$script:IsDarkMode  = $false
$HeaderFont  = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold)
$TitleFont   = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$BodyFont    = New-Object System.Drawing.Font("Segoe UI", 11)
$SmallFont   = New-Object System.Drawing.Font("Segoe UI", 9.5)

# Reusable pen for ring (performance win — avoids per-frame GDI allocation).
# Width is updated in-place by the breathing-pulse timer tick.
$RingPen = New-Object System.Drawing.Pen($LightBlue, 6)
$RingPen.StartCap = "Round"
$RingPen.EndCap = "Round"

# ── Layout spacing constants ────────────────────────────────────────────────
# Named offsets keep Center-AllControls readable and easy to tweak.
$Spacing = @{
    LogoH        = 50;  LogoGap      = 4      # logo height + gap below
    SubH         = 25;  SubGap       = 3      # subtitle height + gap
    DeviceH      = 22;  DeviceGap    = 28     # device label height + gap
    RingH        = 80;  RingGap      = 16     # ring panel height + gap
    StatusH      = 55;  StatusGap    = 3      # status label height + gap
    ProgressH    = 24;  ProgressGap  = 12     # progress text height + gap
    StepH        = 28;  StepGap      = 18     # step panel height + gap
    WiFiBtnH     = 48;  WiFiBtnGap   = 10     # WiFi button height + gap
    RetryBtnH    = 42                          # Retry button height
}
# Total content block height (used to vertically centre the UI).
$script:BlockH = $Spacing.LogoH   + $Spacing.LogoGap    +
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
    } catch {} finally { $ErrorActionPreference = $prev }
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
        } catch {}
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

function Get-SignalBars { param([int]$s) ('█' * [Math]::Round($s/20)) + ('░' * (5-[Math]::Round($s/20))) }

function Connect-WiFiNetwork {
    param([string]$SSID, [string]$Password, [string]$Auth)
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
        $safePwd  = if ($Password) { [System.Security.SecurityElement]::Escape($Password) } else { '' }
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
        Get-WiFiNetworks | ForEach-Object {
            $item = New-Object System.Windows.Forms.ListViewItem($_.SSID)
            $item.SubItems.Add((Get-SignalBars $_.Signal))
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
        Connect-WiFiNetwork -SSID $netSSID -Password $password -Auth $netAuth
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
$form.BackColor = $LightCard
$form.Font = $BodyFont
$form.Opacity = 0.0   # start transparent for fade-in animation

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
$btnDark.Text = [char]0x263D          # crescent moon (safe in WinPE fonts)
$btnDark.ForeColor = [System.Drawing.Color]::Gray
$btnDark.BackColor = $LightCard
$btnDark.Anchor = [System.Windows.Forms.AnchorStyles]::None
$form.Controls.Add($btnDark)

# ── Logo ────────────────────────────────────────────────────────────────────
$logo = New-Object System.Windows.Forms.Label
$logo.Text = $S.Header
$logo.Font = New-Object System.Drawing.Font("Segoe UI", 28, [System.Drawing.FontStyle]::Bold)
$logo.ForeColor = $LightBlue
$logo.TextAlign = "MiddleCenter"
$logo.AutoSize = $false
$form.Controls.Add($logo)

# ── Subtitle ────────────────────────────────────────────────────────────────
$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = $S.Subtitle
$subtitleLabel.Font = $BodyFont
$subtitleLabel.ForeColor = [System.Drawing.Color]::Gray
$subtitleLabel.TextAlign = "MiddleCenter"
$subtitleLabel.AutoSize = $false
$form.Controls.Add($subtitleLabel)

# ── Device info ─────────────────────────────────────────────────────────────
$deviceLabel = New-Object System.Windows.Forms.Label
try {
    $model  = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
    $serial = (Get-CimInstance Win32_Bios -ErrorAction SilentlyContinue).SerialNumber
    $deviceLabel.Text = "Device: $model  -  $serial"
} catch {
    $deviceLabel.Text = "Device: Unknown"
}
$deviceLabel.Font = $SmallFont
$deviceLabel.ForeColor = [System.Drawing.Color]::DarkGray
$deviceLabel.TextAlign = "MiddleCenter"
$deviceLabel.AutoSize = $false
$form.Controls.Add($deviceLabel)

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
$form.Controls.Add($ringPanel)

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
    } catch { }
})

# ── Status label ────────────────────────────────────────────────────────────
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Font = $TitleFont
$statusLabel.ForeColor = $TextLight
$statusLabel.TextAlign = "MiddleCenter"
$statusLabel.AutoSize = $false
$form.Controls.Add($statusLabel)

# ── Progress / download text ────────────────────────────────────────────────
$progressText = New-Object System.Windows.Forms.Label
$progressText.Font = $SmallFont
$progressText.ForeColor = [System.Drawing.Color]::Gray
$progressText.TextAlign = "MiddleCenter"
$progressText.AutoSize = $false
$form.Controls.Add($progressText)

# ── Step indicators ─────────────────────────────────────────────────────────
$stepPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$stepPanel.FlowDirection = "LeftToRight"
$stepPanel.AutoSize = $true
$stepPanel.WrapContents = $false
$stepPanel.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($stepPanel)

$stepLabels = [System.Collections.Generic.List[System.Windows.Forms.Label]]::new()
$stepNum = 0
foreach ($stepText in @($S.Step1, $S.Step2, $S.Step3)) {
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
$form.Controls.Add($btnWiFi)

$btnRetry = New-Object System.Windows.Forms.Button
$btnRetry.Text = "Retry"
$btnRetry.Size = New-Object System.Drawing.Size(160, 42)
$btnRetry.Font = $BodyFont
$btnRetry.BackColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$btnRetry.ForeColor = $TextLight
$btnRetry.FlatStyle = "Flat"
$btnRetry.FlatAppearance.BorderSize = 0
$btnRetry.Visible = $false
$form.Controls.Add($btnRetry)

# ── F8 hint (bottom-left) ───────────────────────────────────────────────────
$f8Hint = New-Object System.Windows.Forms.Label
$f8Hint.Text = "Press F8 for command prompt"
$f8Hint.Font = $SmallFont
$f8Hint.ForeColor = [System.Drawing.Color]::Gray
$f8Hint.AutoSize = $true
$form.Controls.Add($f8Hint)

# ── Dynamic centering ───────────────────────────────────────────────────────
# Positions all controls relative to the form centre on every resize.
$contentW = 600
function Center-AllControls {
    $cw = $form.ClientSize.Width
    $ch = $form.ClientSize.Height
    $cx = [int]($cw / 2)

    $y = [int][Math]::Max(40, ($ch - $script:BlockH) / 2)

    $logo.SetBounds(($cx - $contentW / 2), $y, $contentW, $Spacing.LogoH)
    $y += $Spacing.LogoH + $Spacing.LogoGap
    $subtitleLabel.SetBounds(($cx - $contentW / 2), $y, $contentW, $Spacing.SubH)
    $y += $Spacing.SubH + $Spacing.SubGap
    $deviceLabel.SetBounds(($cx - $contentW / 2), $y, $contentW, $Spacing.DeviceH)
    $y += $Spacing.DeviceH + $Spacing.DeviceGap
    $ringPanel.Location = New-Object System.Drawing.Point(($cx - 40), $y)
    $y += $Spacing.RingH + $Spacing.RingGap
    $statusLabel.SetBounds(($cx - $contentW / 2), $y, $contentW, $Spacing.StatusH)
    $y += $Spacing.StatusH + $Spacing.StatusGap
    $progressText.SetBounds(($cx - $contentW / 2), $y, $contentW, $Spacing.ProgressH)
    $y += $Spacing.ProgressH + $Spacing.ProgressGap
    $stepPanel.Location = New-Object System.Drawing.Point([int]($cx - $stepPanel.Width / 2), $y)
    $y += $Spacing.StepH + $Spacing.StepGap
    $btnWiFi.Location = New-Object System.Drawing.Point(($cx - 130), $y)
    $y += $Spacing.WiFiBtnH + $Spacing.WiFiBtnGap
    $btnRetry.Location = New-Object System.Drawing.Point(($cx - 80), $y)

    # Dark mode button stays top-right
    $btnDark.Location = New-Object System.Drawing.Point(($cw - 60), 16)

    # F8 hint anchored to bottom-left
    $f8Hint.Location = New-Object System.Drawing.Point(16, ($ch - 30))
}

$form.Add_Resize({ Center-AllControls })

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

function Toggle-DarkMode {
    $script:IsDarkMode = -not $script:IsDarkMode
    $bg  = if ($script:IsDarkMode) { $DarkBg }   else { $LightCard }
    $fg  = if ($script:IsDarkMode) { $TextDark }  else { $TextLight }
    $form.BackColor          = $bg
    $btnDark.BackColor       = $bg
    $btnDark.ForeColor       = $fg
    $statusLabel.ForeColor   = $fg
    $logo.ForeColor          = if ($script:IsDarkMode) { [System.Drawing.Color]::FromArgb(100, 180, 255) } else { $LightBlue }
    $subtitleLabel.ForeColor = if ($script:IsDarkMode) { [System.Drawing.Color]::Silver } else { [System.Drawing.Color]::Gray }
    $deviceLabel.ForeColor   = if ($script:IsDarkMode) { [System.Drawing.Color]::Silver } else { [System.Drawing.Color]::DarkGray }
    $btnDark.Text            = if ($script:IsDarkMode) { [char]0x2600 } else { [char]0x263D }
    $form.Refresh()
}
$btnDark.Add_Click({ Toggle-DarkMode })

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
                $progressText.Text = "$($status.Message)  $($script:BulletChar)  $($status.Progress)%"
            }
            if ($status.Step -gt 0) {
                Update-Step $status.Step
            }
            if ($status.Done) {
                $ringTimer.Stop()
            }
        }
    } catch { }
})
#endregion

#region ── Final Completion Screen (fullscreen) ─────────────────────────────
function Show-CompletionScreen {
    Play-Sound 1200 400
    $finalForm = New-Object System.Windows.Forms.Form
    $finalForm.Text = $S.Complete
    $finalForm.FormBorderStyle = "None"
    $finalForm.WindowState = "Maximized"
    $finalForm.BackColor = if ($script:IsDarkMode) { $DarkBg } else { $LightCard }
    $finalForm.Font = $BodyFont

    # F8 command prompt shortcut (same as main form)
    $finalForm.KeyPreview = $true
    $finalForm.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F8) {
            Start-Process $script:PsBin -ArgumentList '-NoProfile', '-NoExit'
        }
    })

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$($S.Complete)`n`nAmpCloud imaging engine is ready."
    $lbl.Font = $TitleFont
    $lbl.ForeColor = if ($script:IsDarkMode) { $TextDark } else { $TextLight }
    $lbl.TextAlign = "MiddleCenter"
    $lbl.AutoSize = $false
    $finalForm.Controls.Add($lbl)

    $btnReboot = New-Object System.Windows.Forms.Button
    $btnReboot.Text      = $S.Reboot
    $btnReboot.Size      = New-Object System.Drawing.Size(200, 52)
    $btnReboot.BackColor = [System.Drawing.Color]::FromArgb(16, 124, 16)
    $btnReboot.ForeColor = [System.Drawing.Color]::White
    $btnReboot.FlatStyle = "Flat"
    $btnReboot.FlatAppearance.BorderSize = 0
    $btnReboot.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $finalForm.Controls.Add($btnReboot)

    $btnPower = New-Object System.Windows.Forms.Button
    $btnPower.Text      = $S.PowerOff
    $btnPower.Size      = New-Object System.Drawing.Size(200, 52)
    $btnPower.BackColor = [System.Drawing.Color]::FromArgb(196, 43, 28)
    $btnPower.ForeColor = [System.Drawing.Color]::White
    $btnPower.FlatStyle = "Flat"
    $btnPower.FlatAppearance.BorderSize = 0
    $btnPower.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $finalForm.Controls.Add($btnPower)

    $btnShell = New-Object System.Windows.Forms.Button
    $btnShell.Text     = $S.Shell
    $btnShell.Size     = New-Object System.Drawing.Size(200, 52)
    $btnShell.BackColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
    $btnShell.ForeColor = $TextLight
    $btnShell.FlatStyle = "Flat"
    $btnShell.FlatAppearance.BorderSize = 0
    $btnShell.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $finalForm.Controls.Add($btnShell)

    $btnReboot.Add_Click({ Restart-Computer -Force })
    $btnPower.Add_Click({ Stop-Computer -Force })
    $btnShell.Add_Click({
        $finalForm.Close()
        & $script:PsBin -NoProfile -NoExit
    })

    $f8HintFinal = New-Object System.Windows.Forms.Label
    $f8HintFinal.Text = "Press F8 for command prompt"
    $f8HintFinal.Font = $SmallFont
    $f8HintFinal.ForeColor = [System.Drawing.Color]::Gray
    $f8HintFinal.AutoSize = $true
    $finalForm.Controls.Add($f8HintFinal)

    # Center controls on resize
    $finalForm.Add_Resize({
        $cw = $finalForm.ClientSize.Width
        $ch = $finalForm.ClientSize.Height
        $cx = [int]($cw / 2)
        $lbl.SetBounds(($cx - 300), [int](($ch / 2) - 80), 600, 100)
        $gap = 16
        $totalBtnW = 200 * 3 + $gap * 2
        $bx = [int]($cx - $totalBtnW / 2)
        $by = [int]($ch / 2) + 50
        $btnReboot.Location = New-Object System.Drawing.Point($bx, $by)
        $btnPower.Location  = New-Object System.Drawing.Point(($bx + 200 + $gap), $by)
        $btnShell.Location  = New-Object System.Drawing.Point(($bx + 400 + $gap * 2), $by)
        $f8HintFinal.Location = New-Object System.Drawing.Point(16, ($ch - 30))
    })

    $null = $finalForm.ShowDialog()
}
#endregion

#region ── Main Flow ─────────────────────────────────────────────────────────
$script:EngineStarted = $false

function Select-WindowsEdition {
    <#
    .SYNOPSIS  Downloads the Microsoft ESD catalog and shows a ComboBox so the
               user can pick the exact Windows edition to install.
    .OUTPUTS   The chosen edition string (e.g. "Windows 11 Pro"), or '' when
               the catalog cannot be fetched or the dialog is cancelled.
    #>

    # Map Bootstrap language codes to catalog LanguageCode values.
    $langMap     = @{ 'EN' = 'en-us'; 'FR' = 'fr-fr'; 'ES' = 'es-es' }
    $catalogLang = if ($langMap.ContainsKey($script:Lang)) { $langMap[$script:Lang] } else { 'en-us' }

    Write-Status $S.CatalogFetch 'Cyan'
    [System.Windows.Forms.Application]::DoEvents()

    # Ensure scratch directory exists (same path AmpCloud.ps1 will use).
    $scratchPath = 'X:\AmpCloud'
    if (-not (Test-Path $scratchPath)) {
        $null = New-Item -ItemType Directory -Path $scratchPath -Force
    }
    $productsXml = Join-Path $scratchPath 'products.xml'

    # Download products.xml directly from the repository — no CAB extraction needed.
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
        return ''
    }

    if (-not (Test-Path $productsXml)) {
        Write-Status $S.CatalogFail 'Yellow'
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 2
        return ''
    }

    # Parse the catalog XML and collect unique edition names (x64 only).
    try {
        [xml]$catalog = Get-Content $productsXml -ErrorAction Stop
        $editions = @(
            $catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File |
                Where-Object { $_.LanguageCode -eq $catalogLang -and $_.Architecture -eq 'x64' } |
                Select-Object -ExpandProperty Edition |
                Sort-Object -Unique
        )
        # Fall back to English if the selected language has no entries.
        if (-not $editions -or $editions.Count -eq 0) {
            $editions = @(
                $catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File |
                    Where-Object { $_.LanguageCode -eq 'en-us' -and $_.Architecture -eq 'x64' } |
                    Select-Object -ExpandProperty Edition |
                    Sort-Object -Unique
            )
        }
    } catch {
        Write-Status $S.CatalogFail 'Yellow'
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 2
        return ''
    }

    if (-not $editions -or $editions.Count -eq 0) {
        Write-Status $S.CatalogFail 'Yellow'
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 2
        return ''
    }

    # ── Edition selector dialog (same Fluent style as Select-Language) ──────
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = $S.EditionTitle
    $dlg.Size            = New-Object System.Drawing.Size(520, 280)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.BackColor       = [System.Drawing.Color]::White

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $S.EditionLabel
    $lbl.Location  = New-Object System.Drawing.Point(30, 30)
    $lbl.Size      = New-Object System.Drawing.Size(440, 30)
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $dlg.Controls.Add($lbl)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Items.AddRange($editions)
    $combo.DropDownStyle = 'DropDownList'
    $combo.FlatStyle     = 'Flat'
    $combo.Location      = New-Object System.Drawing.Point(30, 72)
    $combo.Width         = 440

    # Pre-select Professional if available; fall back to any Pro-like edition.
    $defaultIdx = 0
    $foundPref  = $false
    for ($i = 0; $i -lt $editions.Count; $i++) {
        if ($editions[$i] -eq 'Professional') { $defaultIdx = $i; $foundPref = $true; break }
    }
    if (-not $foundPref) {
        for ($i = 0; $i -lt $editions.Count; $i++) {
            if ($editions[$i] -like '*Pro*' -and
                $editions[$i] -notlike '*Education*' -and
                $editions[$i] -notlike '*Workstation*') {
                $defaultIdx = $i; break
            }
        }
    }
    $combo.SelectedIndex = $defaultIdx
    $dlg.Controls.Add($combo)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text                        = $S.EditionBtn
    $btn.Location                    = New-Object System.Drawing.Point(175, 170)
    $btn.Size                        = New-Object System.Drawing.Size(150, 42)
    $btn.BackColor                   = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btn.ForeColor                   = [System.Drawing.Color]::White
    $btn.FlatStyle                   = 'Flat'
    $btn.FlatAppearance.BorderSize   = 0
    $btn.Font                        = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btn.DialogResult                = 'OK'
    $dlg.Controls.Add($btn)
    $dlg.AcceptButton = $btn

    if ($dlg.ShowDialog() -eq 'OK' -and $null -ne $combo.SelectedItem) {
        return $combo.SelectedItem.ToString()
    }
    return ''
}

function ProceedToEngine {
    # Guard: prevent double invocation from both timer and WiFi click handler.
    if ($script:EngineStarted) { return }
    $script:EngineStarted = $true
    if ($script:connectCheckTimer) { $script:connectCheckTimer.Stop() }

    Update-Step 3
    Write-Status $S.Connected 'Green'
    Play-Sound 900 300
    $ringPanel.Visible = $true
    $ringTimer.Start()

    # Download the ESD catalog and let the user pick a Windows edition.
    $script:SelectedEdition = Select-WindowsEdition

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
                param($sender, $e)
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
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $localAmpCloud,
                    '-StatusFile', $script:StatusFile)
        if ($script:SelectedEdition) { $psArgs += @('-WindowsEdition', $script:SelectedEdition) }
        $engineProc = Start-Process -FilePath $script:PsBin -ArgumentList $psArgs -PassThru

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
    Play-Sound 400 600
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
                    try { $script:_proc.Kill() } catch {}
                }
                # wpeutil UpdateBootInfo populates PEFirmwareType in the
                # registry — needed by downstream partitioning logic.
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    Start-Process -FilePath 'wpeutil' -ArgumentList 'UpdateBootInfo' `
                        -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
                } catch {} finally { $ErrorActionPreference = $prev }

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
                } catch {}
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
                    try { $script:_proc.Kill() } catch {}
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
    Center-AllControls
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

#Requires -Version 5.1
<#
.SYNOPSIS
    AmpCloud Bootstrap v7.3 - SUPER-FLUENT WinForms (UI Animations OPTIMIZED)
.DESCRIPTION
    Full graphical Autopilot-style experience with language selection,
    sound effects, animated ring, rounded card, dark mode, download progress,
    and final completion screen. Animations optimized for WinPE (zero lag).
#>

[CmdletBinding()]
param(
    [string]$GitHubUser   = 'araduti',
    [string]$GitHubRepo   = 'AmpCloud',
    [string]$GitHubBranch = 'main',
    [int]$MaxWaitSeconds  = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging ─────────────────────────────────────────────────────────────────
$LogPath = "X:\AmpCloud-Bootstrap.log"
Start-Transcript -Path $LogPath -Append -Force -ErrorAction SilentlyContinue | Out-Null

# ── Assemblies ──────────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region ── Language System ───────────────────────────────────────────────────
$Lang = 'EN'
function Select-Language {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Select Language / Choisir la langue / Seleccionar idioma"
    $dlg.Size = New-Object System.Drawing.Size(460, 280)
    $dlg.StartPosition = "CenterScreen"
    $dlg.FormBorderStyle = "FixedDialog"

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Choose your language:"
    $lbl.Location = New-Object System.Drawing.Point(40, 40)
    $dlg.Controls.Add($lbl)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Items.AddRange(@("English (EN)", "Français (FR)", "Español (ES)"))
    $combo.SelectedIndex = 0
    $combo.Location = New-Object System.Drawing.Point(40, 80)
    $combo.Width = 360
    $dlg.Controls.Add($combo)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Continue"
    $btn.Location = New-Object System.Drawing.Point(160, 160)
    $btn.DialogResult = "OK"
    $dlg.Controls.Add($btn)

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
    EN = @{ Header="A M P C L O U D"; Step1="Network"; Step2="Connect"; Step3="Load Engine";
            StatusInit="🌐 Initialising network stack..."; StatusNoNet="No wired internet detected`nTap below to connect via WiFi";
            Connected="✅ Connected! Loading imaging engine..."; Download="📥 Downloading AmpCloud.ps1 ({0}%)";
            Complete="🎉 Setup complete!"; Reboot="Reboot Now"; PowerOff="Power Off"; Shell="Drop to Shell" }
    FR = @{ Header="A M P C L O U D"; Step1="Réseau"; Step2="Connexion"; Step3="Chargement";
            StatusInit="🌐 Initialisation du réseau..."; StatusNoNet="Pas de connexion filaire`nAppuyez ci-dessous pour le WiFi";
            Connected="✅ Connecté ! Lancement du moteur..."; Download="📥 Téléchargement AmpCloud.ps1 ({0}%)";
            Complete="🎉 Configuration terminée !"; Reboot="Redémarrer maintenant"; PowerOff="Éteindre"; Shell="Ouvrir le shell" }
    ES = @{ Header="A M P C L O U D"; Step1="Red"; Step2="Conectar"; Step3="Cargar";
            StatusInit="🌐 Inicializando red..."; StatusNoNet="Sin internet cableado`nToque abajo para WiFi";
            Connected="✅ ¡Conectado! Cargando motor..."; Download="📥 Descargando AmpCloud.ps1 ({0}%)";
            Complete="🎉 ¡Configuración completa!"; Reboot="Reiniciar ahora"; PowerOff="Apagar"; Shell="Abrir shell" }
}
$S = $Strings[$Lang]
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

$IsDarkMode  = $false
$HeaderFont  = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold)
$TitleFont   = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$BodyFont    = New-Object System.Drawing.Font("Segoe UI", 11)
$SmallFont   = New-Object System.Drawing.Font("Segoe UI", 9.5)

# Reusable pen for ring (performance win)
$RingPen = New-Object System.Drawing.Pen($LightBlue, 12)
$RingPen.StartCap = "Round"
$RingPen.EndCap = "Round"
#endregion

#region ── Network + WiFi Functions ─────────────────────────────────────────
function Optimize-WinPENetwork {
    Write-Status "🚀 Applying high-performance network tuning..." 'Cyan'
    powercfg -s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
    netsh int tcp set global autotuninglevel=normal | Out-Null
    netsh int tcp set global congestionprovider=ctcp | Out-Null
    netsh int tcp set global chimney=enabled | Out-Null
    netsh int tcp set global rss=enabled | Out-Null
    netsh int tcp set global rsc=enabled | Out-Null
    $ifLines = netsh interface show interface 2>$null
    foreach ($line in $ifLines) {
        if ($line -match '^\s*(Enabled|Disabled)\s+\S+\s+\S+\s+(.+)$') {
            $ifName = $matches[2].Trim()
            netsh interface ipv6 set interface "$ifName" admin=disabled 2>$null | Out-Null
        }
    }
    ipconfig /renew | Out-Null
}

function Invoke-WpeInit {
    Write-Status "🌐 Initialising WinPE network stack..." 'Cyan'
    Start-Process wpeinit.exe -Wait -NoNewWindow
    Start-Sleep -Seconds 4
}

function Test-InternetConnectivity {
    $urls = @('https://www.msftconnecttest.com/connecttest.txt', 'https://clients3.google.com/generate_204')
    foreach ($url in $urls) {
        try { if ((Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 6).StatusCode -eq 200) { return $true } } catch {}
    }
    return $false
}

function Wait-ForConnection {
    param([int]$Timeout = 45)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Timeout) {
        if (Test-InternetConnectivity) { return $true }
        Start-Sleep -Seconds 3
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
    $raw = & netsh wlan show networks mode=bssid 2>&1
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
    $safeSSID = [System.Security.SecurityElement]::Escape($SSID)
    $safePwd  = if ($Password) { [System.Security.SecurityElement]::Escape($Password) } else { '' }
    $isOpen = $Auth -match 'Open'
    $authType = if ($isOpen) { 'open' } elseif ($Auth -match 'WPA3') { 'WPA3SAE' } else { 'WPA2PSK' }
    $enc = if ($isOpen) { 'none' } else { 'AES' }

    $xml = if ($isOpen) {
@"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$safeSSID</name>
  <SSIDConfig><SSID><name>$safeSSID</name></SSID></SSIDConfig>
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
@"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$safeSSID</name>
  <SSIDConfig><SSID><name>$safeSSID</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security><authEncryption>
    <authentication>$authType</authentication>
    <encryption>$enc</encryption>
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
        & netsh wlan add profile filename="$tmp" | Out-Null
        & netsh wlan connect name="$SSID" ssid="$SSID" | Out-Null
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Show-WiFiSelector {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Select WiFi Network"
    $dlg.Size = New-Object System.Drawing.Size(720, 620)
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = if ($IsDarkMode) { $DarkCard } else { $LightCard }
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

    RefreshNetworks()

    $dlg.ShowDialog() | Out-Null
    if ($list.SelectedItems.Count -gt 0) {
        $selected = $list.SelectedItems[0]
        $netSSID = $selected.Text
        $netAuth = $selected.SubItems[2].Text
        $pwd = ''
        if ($netAuth -notmatch 'Open') {
            $pwd = Read-Host -Prompt "Password for '$netSSID'" -AsSecureString
            $pwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd))
        }
        Connect-WiFiNetwork -SSID $netSSID -Password $pwd -Auth $netAuth
        return (Wait-ForConnection -Timeout 40)
    }
    return $false
}
#endregion

#region ── Main Form with OPTIMIZED Animations ───────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = "AmpCloud - Cloud Imaging Engine"
$form.Size = New-Object System.Drawing.Size(900, 680)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.BackColor = $LightBg
$form.Font = $BodyFont

# Header
$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 100
$header.BackColor = $LightBlue
$form.Controls.Add($header)

$logo = New-Object System.Windows.Forms.Label
$logo.Text = $S.Header
$logo.Font = $HeaderFont
$logo.ForeColor = [System.Drawing.Color]::White
$logo.TextAlign = "MiddleCenter"
$logo.Dock = "Fill"
$header.Controls.Add($logo)

# Dark mode toggle
$btnDark = New-Object System.Windows.Forms.Button
$btnDark.Text = "🌙"
$btnDark.Size = New-Object System.Drawing.Size(50, 50)
$btnDark.Location = New-Object System.Drawing.Point(820, 25)
$btnDark.FlatStyle = "Flat"
$btnDark.FlatAppearance.BorderSize = 0
$btnDark.ForeColor = [System.Drawing.Color]::White
$btnDark.BackColor = $LightBlue
$header.Controls.Add($btnDark)

# Content card (cached path)
$content = New-Object System.Windows.Forms.Panel
$content.Dock = "Fill"
$content.BackColor = $LightCard
$content.Padding = New-Object System.Windows.Forms.Padding(60, 40, 60, 40)
$form.Controls.Add($content)

$CachedPath = $null
$content.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = "AntiAlias"
    if (-not $CachedPath) {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $content.Width-1, $content.Height-1)
        $CachedPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $radius = 20
        $CachedPath.AddArc(0, 0, $radius*2, $radius*2, 180, 90)
        $CachedPath.AddArc($rect.Width - $radius*2, 0, $radius*2, $radius*2, 270, 90)
        $CachedPath.AddArc($rect.Width - $radius*2, $rect.Height - $radius*2, $radius*2, $radius*2, 0, 90)
        $CachedPath.AddArc(0, $rect.Height - $radius*2, $radius*2, $radius*2, 90, 90)
        $CachedPath.CloseFigure()
    }
    $g.FillPath((New-Object System.Drawing.SolidBrush($content.BackColor)), $CachedPath)
    $g.DrawPath((New-Object System.Drawing.Pen([System.Drawing.Color]::LightGray, 2)), $CachedPath)
})

# Step indicators
$stepPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$stepPanel.Dock = "Top"
$stepPanel.Height = 50
$stepPanel.FlowDirection = "LeftToRight"
$content.Controls.Add($stepPanel)

$stepLabels = @()
@($S.Step1, $S.Step2, $S.Step3) | ForEach-Object {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "● $($stepLabels.Count + 1) $_"
    $lbl.Font = $SmallFont
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.AutoSize = $true
    $lbl.Margin = New-Object System.Windows.Forms.Padding(30, 0, 30, 0)
    $stepLabels += $lbl
    $stepPanel.Controls.Add($lbl)
}

# Device info
$deviceLabel = New-Object System.Windows.Forms.Label
$deviceLabel.Text = "Device: $((Get-CimInstance Win32_ComputerSystem).Model) • $((Get-CimInstance Win32_Bios).SerialNumber)"
$deviceLabel.Font = $SmallFont
$deviceLabel.ForeColor = [System.Drawing.Color]::Gray
$deviceLabel.Dock = "Top"
$deviceLabel.Height = 30
$content.Controls.Add($deviceLabel)

# Status
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Font = $TitleFont
$statusLabel.ForeColor = $TextLight
$statusLabel.Dock = "Top"
$statusLabel.Height = 90
$statusLabel.TextAlign = "MiddleLeft"
$content.Controls.Add($statusLabel)

# OPTIMIZED Animated Progress Ring
$ringPanel = New-Object System.Windows.Forms.Panel
$ringPanel.Size = New-Object System.Drawing.Size(120, 120)
$ringPanel.Location = New-Object System.Drawing.Point(370, 280)
$ringPanel.Visible = $false

# ── PERFORMANCE OPTIMIZATIONS ───────────────────────────────────────────────
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

$content.Controls.Add($ringPanel)

$ringAngle = 0
$ringTimer = New-Object System.Windows.Forms.Timer
$ringTimer.Interval = 48
$ringTimer.Add_Tick({
    $ringAngle = ($ringAngle + 8) % 360
    $ringPanel.Invalidate()
})
$ringPanel.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = "AntiAlias"
    $g.DrawArc($RingPen, 10, 10, 100, 100, $ringAngle, 280)
})

# Progress text
$progressText = New-Object System.Windows.Forms.Label
$progressText.Font = $SmallFont
$progressText.ForeColor = [System.Drawing.Color]::Gray
$progressText.Dock = "Top"
$progressText.Height = 30
$content.Controls.Add($progressText)

# Buttons
$btnWiFi = New-Object System.Windows.Forms.Button
$btnWiFi.Text = "🌐 Connect via WiFi"
$btnWiFi.Size = New-Object System.Drawing.Size(300, 60)
$btnWiFi.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$btnWiFi.BackColor = $LightBlue
$btnWiFi.ForeColor = [System.Drawing.Color]::White
$btnWiFi.FlatStyle = "Flat"
$btnWiFi.FlatAppearance.BorderSize = 0
$btnWiFi.Location = New-Object System.Drawing.Point(300, 420)
$btnWiFi.Visible = $false
$content.Controls.Add($btnWiFi)

$btnRetry = New-Object System.Windows.Forms.Button
$btnRetry.Text = "🔄 Retry"
$btnRetry.Size = New-Object System.Drawing.Size(180, 50)
$btnRetry.Font = $BodyFont
$btnRetry.BackColor = [System.Drawing.Color]::Orange
$btnRetry.ForeColor = [System.Drawing.Color]::White
$btnRetry.FlatStyle = "Flat"
$btnRetry.Visible = $false
$btnRetry.Location = New-Object System.Drawing.Point(360, 500)
$content.Controls.Add($btnRetry)

function Write-Status {
    param([string]$Message, [string]$Color = 'Black')
    $statusLabel.ForeColor = switch ($Color) {
        'Green'  { [System.Drawing.Color]::DarkGreen }
        'Red'    { [System.Drawing.Color]::Red }
        'Yellow' { [System.Drawing.Color]::OrangeRed }
        default  { if ($IsDarkMode) { $TextDark } else { $TextLight } }
    }
    $statusLabel.Text = $Message
    $form.Refresh()
}

function Update-Step { param([int]$s)
    for ($i = 0; $i -lt 3; $i++) {
        $stepLabels[$i].ForeColor = if ($i -lt $s) { $LightBlue } else { [System.Drawing.Color]::Gray }
    }
}

function Toggle-DarkMode {
    $script:IsDarkMode = -not $IsDarkMode
    $form.BackColor = if ($IsDarkMode) { $DarkBg } else { $LightBg }
    $content.BackColor = if ($IsDarkMode) { $DarkCard } else { $LightCard }
    $header.BackColor = if ($IsDarkMode) { $DarkBlue } else { $LightBlue }
    $statusLabel.ForeColor = if ($IsDarkMode) { $TextDark } else { $TextLight }
    $btnDark.Text = if ($IsDarkMode) { "☀️" } else { "🌙" }
    $form.Refresh()
}
$btnDark.Add_Click({ Toggle-DarkMode })
#endregion

#region ── Final Completion Screen ──────────────────────────────────────────
function Show-CompletionScreen {
    Play-Sound 1200 400
    $finalForm = New-Object System.Windows.Forms.Form
    $finalForm.Text = $S.Complete
    $finalForm.Size = New-Object System.Drawing.Size(620, 380)
    $finalForm.StartPosition = "CenterScreen"
    $finalForm.BackColor = if ($IsDarkMode) { $DarkCard } else { $LightCard }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $S.Complete + "`n`nAmpCloud imaging engine is ready."
    $lbl.Font = $TitleFont
    $lbl.TextAlign = "MiddleCenter"
    $lbl.Dock = "Fill"
    $finalForm.Controls.Add($lbl)

    $btnReboot = New-Object System.Windows.Forms.Button; $btnReboot.Text = $S.Reboot; $btnReboot.Size = New-Object System.Drawing.Size(180, 60); $btnReboot.Location = New-Object System.Drawing.Point(50, 260); $btnReboot.BackColor = [System.Drawing.Color]::DarkGreen; $btnReboot.ForeColor = "White"; $finalForm.Controls.Add($btnReboot)
    $btnPower = New-Object System.Windows.Forms.Button; $btnPower.Text = $S.PowerOff; $btnPower.Size = New-Object System.Drawing.Size(180, 60); $btnPower.Location = New-Object System.Drawing.Point(240, 260); $btnPower.BackColor = [System.Drawing.Color]::DarkRed; $btnPower.ForeColor = "White"; $finalForm.Controls.Add($btnPower)
    $btnShell = New-Object System.Windows.Forms.Button; $btnShell.Text = $S.Shell; $btnShell.Size = New-Object System.Drawing.Size(180, 60); $btnShell.Location = New-Object System.Drawing.Point(430, 260); $finalForm.Controls.Add($btnShell)

    $btnReboot.Add_Click({ shutdown /r /t 0 })
    $btnPower.Add_Click({ shutdown /s /t 0 })
    $btnShell.Add_Click({ $finalForm.Close(); & cmd.exe /k })

    $finalForm.ShowDialog() | Out-Null
}
#endregion

#region ── Main Flow ─────────────────────────────────────────────────────────
function ProceedToEngine {
    Update-Step 3
    Write-Status $S.Connected 'Green'
    Play-Sound 900 300
    $ringPanel.Visible = $true
    $ringTimer.Start()

    $local = Join-Path $env:SystemRoot 'System32\AmpCloud.ps1'
    if (Test-Path $local) {
        & $local
    } else {
        $url = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/AmpCloud.ps1"
        $dlPath = 'X:\AmpCloud.ps1'
        Write-Status ($S.Download -f 0)
        $web = New-Object System.Net.WebClient
        $web.DownloadFile($url, $dlPath)
        for ($p = 10; $p -le 100; $p += 10) {
            Start-Sleep -Milliseconds 80
            Write-Status ($S.Download -f $p)
        }
        & $dlPath
    }

    $ringTimer.Stop()
    Stop-Transcript -ErrorAction SilentlyContinue
    $form.Close()
    Show-CompletionScreen
}

function Show-Failure {
    Play-Sound 400 600
    Write-Status "❌ Could not connect to the internet.`nPlease check your network." 'Red'
    $btnRetry.Visible = $true
    $btnRetry.Add_Click({
        $btnRetry.Visible = $false
        $hasInternet = Test-InternetConnectivity
        if ($hasInternet) { ProceedToEngine } else { $form.Close(); & cmd.exe /k }
    })
}

$form.Add_Shown({
    Update-Step 1
    Write-Status $S.StatusInit 'Cyan'
    Invoke-WpeInit
    Optimize-WinPENetwork

    $hasInternet = Test-InternetConnectivity

    if (-not $hasInternet) {
        Update-Step 2
        Write-Status $S.StatusNoNet 'Yellow'
        $btnWiFi.Visible = $true
        $btnWiFi.Add_Click({
            $btnWiFi.Visible = $false
            $ringPanel.Visible = $true
            $ringTimer.Start()
            $hasInternet = Show-WiFiSelector
            $ringTimer.Stop()
            $ringPanel.Visible = $false
            if ($hasInternet) { ProceedToEngine } else { Show-Failure }
        })
        if (-not $hasInternet) { $hasInternet = Wait-ForConnection -Timeout $MaxWaitSeconds }
    }

    if ($hasInternet) { ProceedToEngine } else { Show-Failure }
})

# Launch
$form.ShowDialog() | Out-Null
Stop-Transcript -ErrorAction SilentlyContinue
#endregion

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
    [string]$GitHubUser   = 'araduti',
    [string]$GitHubRepo   = 'AmpCloud',
    [string]$GitHubBranch = 'main',
    [int]$MaxWaitSeconds  = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Shell path ───────────────────────────────────────────────────────────────
# Resolved once at startup so WinPE's fixed X:\ path is used reliably.
$script:PsBin = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ── Logging ─────────────────────────────────────────────────────────────────
$LogPath = "X:\AmpCloud-Bootstrap.log"
Start-Transcript -Path $LogPath -Append -Force -ErrorAction SilentlyContinue | Out-Null

# ── Assemblies ──────────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── WinPE Environment ──────────────────────────────────────────────────────
# Set standard user-profile paths that PowerShell modules expect.  Must run
# before any module or profile code that references these variables.
if (-not $env:APPDATA)      { $env:APPDATA      = "$env:USERPROFILE\AppData\Roaming" }
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA  = "$env:USERPROFILE\AppData\Local"   }
if (-not $env:HOMEDRIVE)    { $env:HOMEDRIVE     = 'X:'  }
if (-not $env:HOMEPATH)     { $env:HOMEPATH      = '\' }

#region ── Language System ───────────────────────────────────────────────────
$Lang = 'EN'
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
    EN = @{ Header="A M P C L O U D"; Step1="Network"; Step2="Connect"; Step3="Load Engine";
            StatusInit="🌐 Initialising network stack..."; StatusNoNet="No wired internet detected`nTap below to connect via WiFi";
            Connected="✅ Connected! Loading imaging engine..."; Download="📥 Downloading AmpCloud.ps1 ({0}%)";
            Complete="🎉 Setup complete!"; Reboot="Reboot Now"; PowerOff="Power Off"; Shell="Drop to Shell";
            CatalogFetch="📋 Fetching available Windows editions...";
            CatalogFail="⚠️ Could not fetch edition catalog. Using default edition.";
            EditionTitle="Select Windows Edition";
            EditionLabel="Choose the Windows edition to install:";
            EditionBtn="Install →" }
    FR = @{ Header="A M P C L O U D"; Step1="Réseau"; Step2="Connexion"; Step3="Chargement";
            StatusInit="🌐 Initialisation du réseau..."; StatusNoNet="Pas de connexion filaire`nAppuyez ci-dessous pour le WiFi";
            Connected="✅ Connecté ! Lancement du moteur..."; Download="📥 Téléchargement AmpCloud.ps1 ({0}%)";
            Complete="🎉 Configuration terminée !"; Reboot="Redémarrer maintenant"; PowerOff="Éteindre"; Shell="Ouvrir le shell";
            CatalogFetch="📋 Récupération des éditions Windows disponibles...";
            CatalogFail="⚠️ Impossible de récupérer le catalogue. Édition par défaut utilisée.";
            EditionTitle="Sélectionner l'édition Windows";
            EditionLabel="Choisissez l'édition Windows à installer :";
            EditionBtn="Installer →" }
    ES = @{ Header="A M P C L O U D"; Step1="Red"; Step2="Conectar"; Step3="Cargar";
            StatusInit="🌐 Inicializando red..."; StatusNoNet="Sin internet cableado`nToque abajo para WiFi";
            Connected="✅ ¡Conectado! Cargando motor..."; Download="📥 Descargando AmpCloud.ps1 ({0}%)";
            Complete="🎉 ¡Configuración completa!"; Reboot="Reiniciar ahora"; PowerOff="Apagar"; Shell="Abrir shell";
            CatalogFetch="📋 Obteniendo ediciones de Windows disponibles...";
            CatalogFail="⚠️ No se pudo obtener el catálogo. Usando edición predeterminada.";
            EditionTitle="Seleccionar edición de Windows";
            EditionLabel="Elija la edición de Windows a instalar:";
            EditionBtn="Instalar →" }
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
        powercfg -s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null | Out-Null
        netsh int tcp set global autotuninglevel=normal 2>$null | Out-Null
        netsh int tcp set global congestionprovider=ctcp 2>$null | Out-Null
        netsh int tcp set global chimney=enabled 2>$null | Out-Null
        netsh int tcp set global rss=enabled 2>$null | Out-Null
        netsh int tcp set global rsc=enabled 2>$null | Out-Null
        netsh advfirewall set allprofiles state off 2>$null | Out-Null
        $ifLines = netsh interface show interface 2>$null
        foreach ($line in $ifLines) {
            if ($line -match '^\s*(Enabled|Disabled)\s+\S+\s+\S+\s+(.+)$') {
                netsh interface ipv6 set interface "$($matches[2].Trim())" admin=disabled 2>$null | Out-Null
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
    $urls = @('https://www.msftconnecttest.com/connecttest.txt', 'https://clients3.google.com/generate_204')
    foreach ($url in $urls) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
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
        & netsh wlan add profile filename="`"$tmp`"" 2>&1 | Out-Null
        & netsh wlan connect  name="`"$SSID`"" ssid="`"$SSID`"" 2>&1 | Out-Null
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

    $dlg.ShowDialog() | Out-Null
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
$subtitleLabel.Text = "Cloud Imaging Engine"
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
    $ringPanel.Invalidate()
})
$ringPenSmall = New-Object System.Drawing.Pen($LightBlue, 6)
$ringPenSmall.StartCap = "Round"
$ringPenSmall.EndCap = "Round"
$ringPanel.Add_Paint({
    try {
        $g = $_.Graphics
        $g.SmoothingMode = "AntiAlias"
        $g.DrawArc($ringPenSmall, 6, 6, 66, 66, $script:ringAngle, 280)
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

    # Vertical block: logo(50) + subtitle(25) + device(22) + gap(30) + ring(80) +
    #   gap(18) + status(55) + progress(24) + gap(12) + steps(28) + gap(18) +
    #   wifibtn(48) + gap(10) + retrybtn(42) = ~462
    $blockH = 462
    $y = [int][Math]::Max(40, ($ch - $blockH) / 2)

    $logo.SetBounds(($cx - $contentW / 2), $y, $contentW, 50)
    $y += 54
    $subtitleLabel.SetBounds(($cx - $contentW / 2), $y, $contentW, 25)
    $y += 28
    $deviceLabel.SetBounds(($cx - $contentW / 2), $y, $contentW, 22)
    $y += 50
    $ringPanel.Location = New-Object System.Drawing.Point(($cx - 40), $y)
    $y += 96
    $statusLabel.SetBounds(($cx - $contentW / 2), $y, $contentW, 55)
    $y += 58
    $progressText.SetBounds(($cx - $contentW / 2), $y, $contentW, 24)
    $y += 36
    $stepPanel.Location = New-Object System.Drawing.Point([int]($cx - $stepPanel.Width / 2), $y)
    $y += 46
    $btnWiFi.Location = New-Object System.Drawing.Point(($cx - 130), $y)
    $y += 58
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
    $lbl.Text = $S.Complete + "`n`nAmpCloud imaging engine is ready."
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

    $finalForm.ShowDialog() | Out-Null
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
        New-Item -ItemType Directory -Path $scratchPath -Force | Out-Null
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

    # Pre-select Windows 11 Pro if available; fall back to any plain Pro edition.
    $defaultIdx = 0
    $foundPref  = $false
    for ($i = 0; $i -lt $editions.Count; $i++) {
        if ($editions[$i] -eq 'Windows 11 Pro') { $defaultIdx = $i; $foundPref = $true; break }
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
    $editionArgs = if ($script:SelectedEdition) { @('-WindowsEdition', $script:SelectedEdition) } else { @() }

    # Prefer the pre-staged copy embedded in the WinPE image by Trigger.ps1.
    # Fall back to downloading from GitHub when the local copy is absent.
    $engineFailed = $false
    try {
        $localAmpCloud = Join-Path $env:SystemRoot 'System32\AmpCloud.ps1'
        if (Test-Path $localAmpCloud) {
            & $localAmpCloud @editionArgs
        } else {
            $url    = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/AmpCloud.ps1"
            $dlPath = 'X:\AmpCloud.ps1'
            Write-Status ($S.Download -f 0)
            $web = New-Object System.Net.WebClient
            $web.add_DownloadProgressChanged({
                param($sender, $e)
                Write-Status ($S.Download -f $e.ProgressPercentage)
            })
            $task = $web.DownloadFileTaskAsync($url, $dlPath)
            while (-not $task.IsCompleted) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            if ($task.IsFaulted) { throw $task.Exception.InnerException }
            & $dlPath @editionArgs
        }
    } catch {
        # Engine already printed diagnostics; close the UI so the console
        # is usable.  The -NoExit PowerShell host from ampcloud-start.cmd
        # provides the interactive prompt for troubleshooting.
        $engineFailed = $true
    }

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
#   SETTLE        – brief delay for NIC drivers to finish binding after wpeinit
#   DHCP          – launch ipconfig /renew (non-blocking)
#   DHCP_POLL     – wait for ipconfig to exit, check for valid IP
#   DHCP_WAIT     – 5-second pause between DHCP retries (up to 3 attempts)
#   CHECK         – test internet connectivity, decide next step

$script:_initState = 'INIT'
$script:_proc      = $null
$script:_dhcp      = 0
$script:_wait      = 0

$script:initTimer = New-Object System.Windows.Forms.Timer
$script:initTimer.Interval = 500

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
                ++$script:_wait -ge 120) {       # 60-second timeout (120 × 500 ms)
                if ($script:_proc -and -not $script:_proc.HasExited) {
                    try { $script:_proc.Kill() } catch {}
                }
                # wpeutil UpdateBootInfo populates PEFirmwareType in the
                # registry — needed by downstream partitioning logic.
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    Start-Process -FilePath 'wpeutil' -ArgumentList 'UpdateBootInfo' `
                        -Wait -NoNewWindow -ErrorAction SilentlyContinue
                } catch {} finally { $ErrorActionPreference = $prev }

                Invoke-NetworkTuning
                Write-Status '🔧 Acquiring network address...' 'Cyan'
                $script:_wait = 0
                $script:_initState = 'SETTLE'
            }
        }

        'SETTLE' {
            # Let NIC drivers finish binding after wpeinit before DHCP.
            if (++$script:_wait -ge 4) {        # 2-second pause (4 × 500 ms)
                $script:_dhcp = 0
                $script:_initState = 'DHCP'
            }
        }

        'DHCP' {
            $script:_dhcp++
            $script:_wait = 0
            try {
                $script:_proc = Start-Process -FilePath 'ipconfig.exe' `
                    -ArgumentList '/renew' -NoNewWindow -PassThru `
                    -ErrorAction SilentlyContinue
            } catch { $script:_proc = $null }
            $script:_initState = 'DHCP_POLL'
        }

        'DHCP_POLL' {
            if ($null -eq $script:_proc -or $script:_proc.HasExited -or
                ++$script:_wait -ge 60) {        # 30-second timeout (60 × 500 ms)
                if ($script:_proc -and -not $script:_proc.HasExited) {
                    try { $script:_proc.Kill() } catch {}
                }
                if (Test-HasValidIP) {
                    $script:_initState = 'CHECK'
                } elseif ($script:_dhcp -ge 3) {
                    $script:_initState = 'CHECK'
                } else {
                    $script:_wait = 0
                    $script:_initState = 'DHCP_WAIT'
                }
            }
        }

        'DHCP_WAIT' {
            if (++$script:_wait -ge 10) {       # 5-second pause (10 × 500 ms)
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
                $script:connectCheckTimer.Interval = 5000
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
})

# Launch
[System.Windows.Forms.Application]::EnableVisualStyles()
$form.ShowDialog() | Out-Null
Stop-Transcript -ErrorAction SilentlyContinue
#endregion

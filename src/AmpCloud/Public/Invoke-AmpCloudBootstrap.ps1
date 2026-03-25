function Invoke-AmpCloudBootstrap {
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

    .PARAMETER GitHubUser
        GitHub account that hosts the AmpCloud repository. Default: araduti

    .PARAMETER GitHubRepo
        Repository name. Default: AmpCloud

    .PARAMETER GitHubBranch
        Branch to pull from. Default: main

    .PARAMETER MaxWaitSeconds
        Maximum seconds to wait for network connectivity. Default: 300

    .EXAMPLE
        Invoke-AmpCloudBootstrap

    .EXAMPLE
        Invoke-AmpCloudBootstrap -GitHubBranch 'dev'

    .NOTES
        Requires WinPE/WinRE with PowerShell, System.Windows.Forms, and
        System.Drawing assemblies.
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
    $contentW = 600
    $form.Add_Resize({ Set-ControlLayout })

    # ── Dark mode toggle click handler ──────────────────────────────────────────
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

    #region ── Main Flow ─────────────────────────────────────────────────────────
    $script:EngineStarted = $false

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
                    Start-AmpCloudEngineProcess
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
                        if ($wifiConnected) { Start-AmpCloudEngineProcess } else { Show-Failure }
                    })

                    # Periodically re-check wired connectivity so a late DHCP
                    # lease or cable plug-in proceeds without manual action.
                    $script:connectCheckTimer.Interval = $script:ConnectCheckIntervalMs
                    $script:connectCheckTimer.Add_Tick({
                        if (Test-InternetConnectivity) {
                            $script:connectCheckTimer.Stop()
                            $btnWiFi.Visible = $false
                            Start-AmpCloudEngineProcess
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
}

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

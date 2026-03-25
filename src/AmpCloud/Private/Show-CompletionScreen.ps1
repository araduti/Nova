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

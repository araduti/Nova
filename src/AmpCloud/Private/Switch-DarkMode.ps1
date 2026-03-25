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

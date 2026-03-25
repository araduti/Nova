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

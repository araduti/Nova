function Update-Step { param([int]$s)
    for ($i = 0; $i -lt $stepLabels.Count; $i++) {
        $stepLabels[$i].ForeColor = if ($i -lt $s) { $LightBlue } else { [System.Drawing.Color]::Gray }
    }
}

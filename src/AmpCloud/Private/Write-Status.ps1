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

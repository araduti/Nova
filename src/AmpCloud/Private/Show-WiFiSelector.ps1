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
        Get-WiFiNetwork | ForEach-Object {
            $item = New-Object System.Windows.Forms.ListViewItem($_.SSID)
            $item.SubItems.Add((Get-SignalBar $_.Signal))
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
        Connect-WiFiNetwork -SSID $netSSID -WiFiKey $password -Auth $netAuth
        $password = $null
        Write-Status 'Waiting for IP address...' 'Yellow'
        Start-Sleep -Seconds 6
        return (Test-InternetConnectivity)
    }
    return $false
}

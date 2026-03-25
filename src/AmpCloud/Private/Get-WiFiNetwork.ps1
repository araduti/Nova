function Get-WiFiNetwork {
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

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
        $null = powercfg -s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        $null = netsh int tcp set global autotuninglevel=normal 2>$null
        $null = netsh int tcp set global congestionprovider=ctcp 2>$null
        $null = netsh int tcp set global chimney=enabled 2>$null
        $null = netsh int tcp set global rss=enabled 2>$null
        $null = netsh int tcp set global rsc=enabled 2>$null
        $null = netsh advfirewall set allprofiles state off 2>$null
        $ifLines = netsh interface show interface 2>$null
        foreach ($line in $ifLines) {
            if ($line -match '^\s*(Enabled|Disabled)\s+\S+\s+\S+\s+(.+)$') {
                $null = netsh interface ipv6 set interface "$($matches[2].Trim())" admin=disabled 2>$null
            }
        }
    } catch { Write-Verbose "Network tuning failed: $_" } finally { $ErrorActionPreference = $prev }
}

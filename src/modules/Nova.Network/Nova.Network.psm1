<#
.SYNOPSIS
    Network utility module for Nova WinPE bootstrap.

.DESCRIPTION
    Provides TCP tuning, connectivity probing, WiFi scanning, and WiFi
    connection functions used by Bootstrap.ps1 in the WinPE environment.
    All functions are safe to call from a WinForms timer tick (they do not
    block indefinitely or display UI).
#>

Set-StrictMode -Version Latest

function Invoke-NetworkTuning {
    <#
    .SYNOPSIS  Fast synchronous TCP / firewall / IPv6 tuning.
    .DESCRIPTION
        All netsh commands complete in milliseconds and never sleep.  Safe to
        call from a WinForms timer tick without freezing the UI.
    #>
    [OutputType([void])]
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($PSCmdlet.ShouldProcess('Power plan', 'Set High Performance')) {
            $null = powercfg -s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        }
        if ($PSCmdlet.ShouldProcess('TCP settings', 'Optimise')) {
            $null = netsh int tcp set global autotuninglevel=normal 2>$null
            $null = netsh int tcp set global congestionprovider=ctcp 2>$null
            $null = netsh int tcp set global chimney=enabled 2>$null
            $null = netsh int tcp set global rss=enabled 2>$null
            $null = netsh int tcp set global rsc=enabled 2>$null
        }
        if ($PSCmdlet.ShouldProcess('Firewall', 'Disable all profiles')) {
            $null = netsh advfirewall set allprofiles state off 2>$null
        }
        if ($PSCmdlet.ShouldProcess('IPv6', 'Disable on all interfaces')) {
            $ifLines = netsh interface show interface 2>$null
            foreach ($line in $ifLines) {
                if ($line -match '^\s*(Enabled|Disabled)\s+\S+\s+\S+\s+(.+)$') {
                    $null = netsh interface ipv6 set interface "$($matches[2].Trim())" admin=disabled 2>$null
                }
            }
        }
    } catch { Write-Verbose "Network tuning failed: $_" } finally { $ErrorActionPreference = $prev }
}

function Test-HasValidIP {
    <#
    .SYNOPSIS  Returns $true when ipconfig reports at least one non-APIPA IPv4 address.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'No console output -- name follows Test- verb convention')]
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    $ipOut = ipconfig 2>$null | Out-String
    foreach ($m in [regex]::Matches($ipOut, '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})')) {
        $ip = $m.Groups[1].Value
        if ($ip -notmatch '^(169\.254\.|127\.|0\.0\.0\.0|255\.)') { return $true }
    }
    return $false
}

function Test-InternetConnectivity {
    <#
    .SYNOPSIS  Probes well-known URLs and returns $true when at least one responds.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    $urls = @(
        'https://api.github.com',                          # GitHub API (deployment reporting)
        'https://www.msftconnecttest.com/connecttest.txt',
        'https://clients3.google.com/generate_204',
        'http://www.msftconnecttest.com/connecttest.txt'   # HTTP fallback (Windows NCSI endpoint)
    )
    foreach ($url in $urls) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
        } catch { Write-Verbose "Connectivity probe failed for ${url}: $_" }
    }
    return $false
}

function Start-WlanService {
    <#
    .SYNOPSIS  Ensures the WLAN service is running (WinPE WiFi support).
    #>
    [OutputType([void])]
    [CmdletBinding(SupportsShouldProcess)] param()
    if (-not (Get-Service -Name wlansvc -ErrorAction SilentlyContinue)) { return $false }
    if ((Get-Service wlansvc).Status -ne 'Running') {
        if ($PSCmdlet.ShouldProcess('wlansvc', 'Start-Service')) {
            Start-Service wlansvc -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 3
    }
    return $true
}

function Get-WiFiNetwork {
    <#
    .SYNOPSIS  Returns available WiFi networks sorted by signal strength (descending).
    #>
    [OutputType([psobject[]])]
    [CmdletBinding()]
    param()
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

function Get-SignalBar {
    <#
    .SYNOPSIS  Renders a 5-character signal strength bar using filled/empty block characters.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([int]$s)
    ('█' * [Math]::Round($s/20)) + ('░' * (5-[Math]::Round($s/20)))
}

function Connect-WiFiNetwork {
    <#
    .SYNOPSIS  Connects to a WiFi network using a temporary netsh XML profile.
    .PARAMETER SSID     Network name.
    .PARAMETER WiFiKey  Pre-shared key (passphrase).  Ignored for open networks.
    .PARAMETER Auth     Authentication type string from netsh (e.g. 'WPA2-Personal', 'Open').
    #>
    [OutputType([void])]
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$SSID, [string]$WiFiKey, [string]$Auth)

    if (-not $PSCmdlet.ShouldProcess($SSID, 'Connect-WiFiNetwork')) { return }

    $safeSsid = [System.Security.SecurityElement]::Escape($SSID)
    $isOpen   = $Auth -match 'Open'

    $ns = 'http://www.microsoft.com/networking/WLAN/profile/v1'
    if ($isOpen) {
        $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="$ns">
  <name>$safeSsid</name>
  <SSIDConfig><SSID><name>$safeSsid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security><authEncryption>
    <authentication>open</authentication>
    <encryption>none</encryption>
    <useOneX>false</useOneX>
  </authEncryption></security></MSM>
</WLANProfile>
"@
    } else {
        $safePwd  = if ($WiFiKey) { [System.Security.SecurityElement]::Escape($WiFiKey) } else { '' }
        $authType = if ($Auth -match 'WPA3') { 'WPA3SAE' } else { 'WPA2PSK' }
        $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="$ns">
  <name>$safeSsid</name>
  <SSIDConfig><SSID><name>$safeSsid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security><authEncryption>
    <authentication>$authType</authentication>
    <encryption>AES</encryption>
    <useOneX>false</useOneX>
  </authEncryption>
  <sharedKey>
    <keyType>passPhrase</keyType>
    <protected>false</protected>
    <keyMaterial>$safePwd</keyMaterial>
  </sharedKey></security></MSM>
</WLANProfile>
"@
    }

    $tmp = Join-Path $env:TEMP "nova_wifi_$([guid]::NewGuid().Guid).xml"
    try {
        $xml | Set-Content -Path $tmp -Encoding UTF8 -Force
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $null = & netsh wlan add profile filename="`"$tmp`"" 2>&1
        $null = & netsh wlan connect  name="`"$SSID`"" ssid="`"$SSID`"" 2>&1
        $ErrorActionPreference = $prev
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-NetworkTuning, Test-HasValidIP, Test-InternetConnectivity,
    Start-WlanService, Get-WiFiNetwork, Get-SignalBar, Connect-WiFiNetwork

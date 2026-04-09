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

# SIG # Begin signature block
# MII9dAYJKoZIhvcNAQcCoII9ZTCCPWECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAWrARO1fB9gIdZ
# raug+xgpMTsU+++lzy8Iwch9dDl1m6CCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAAf9F8I
# 9dTWl3i0AAAAAB/0MA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNDA5MTQzNDE0WhcNMjYwNDEy
# MTQzNDE0WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCx/g++XtnJK7rE
# 0KdajcoolJBoDDfdRpmQNC9/GzA0HV9OF7JqGRzyetOdvFwuoeSs/WTySDN6LfUl
# RShMrxqthSBnxKizrV6QwIshT8R8DhNlq3GlGyoaozQsFR8qUdVd5HGjEuXgea1d
# cUEEKFOEOGveUCJoNioZsCpLPqKz8kqQKDKedUXt4BEOq0ZIx8u4VWOUd/8a8+BH
# hRAmqZ2MneNYz5M3R8pjQ/LOgLWZi4HLyqvVRWE+blYB1X4sf4sZ6vY+WMgeg1IF
# 0kRJqe3z8hV0sJQ/Z8df8q3qtKwCTwW69P2jzdW5Yvv6MOgad33QAE6FWiccuxle
# t/b+4Pcj2Oq0Ewsxi8EXlg2S089n696X8EepMvOdDqd61nA7ANY3NC9UuYObLABR
# bF+N+co+Ul+JCvY5ICxRlLCh+X+EyRQ2Vt1m5zlUur2wbQZq+jkXlxB5VA3533oJ
# 5eIFvUzgPpr6VtPzY4rGAyVAxIXrG4P7n73LXg5L/ab+Nmx7jqUCAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQU4D7TdnNsaAKxOOGcp1Ym6JlRKBAwHwYDVR0jBBgwFoAUmvFUd3UM
# hxY3RqCs3nn59H/BeOkwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwNC5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBABQEzS1JWIQaoIhs/bao1+zhOP2dOlgv/XPjH/5pwAK2oUJmMOvrt2Vi
# XGXNGE4j5E21vjtuvpE0atkpqXx9rErkl7psFTWvXb2z3YNlzhjuvFoK5hUXnuYK
# 9GAmtd1ZtTJVSgnKW6NKyFLwLHGCfQnl5t0XcsbOh8gJEl/iBZBfbsWvnHNUwF8r
# L4ZCcXAQMDaEFUlyOaMqFFu/ogHc5n5Z1lXkx8Jho5Kkk41atBCMm/QZX5HAZROO
# eEpyc55dzpzlGHo2Zus/+OCo6gdFBCTge5ymPnvvQwCZphfzmZMKIdrIPgJ3Wj8p
# 8exq7dVTFdG/+DsGZeyRvGUl1noUYfFIEYjONE6A4rzxut1//ItktHlgxlwNhwdI
# qW3QyeAhrJ36x6tIMq/liCTYxXsnmc5CFj7dN583kB5fR8BsFbwiAa1aX3hbrJeX
# W14uKxPLW3tYLsE0ioGcLJ2kqp07hGhLfZXtC2TTLMf0ha6xFGRt8HcWB/x1YwC0
# Xjxk0a8bcw4A/ry9r1zgdUiGqKipuSNGKSX5g9I8/C23eeMcDSu5jQe2un6CeFYe
# iLFwuX2so0mOpWFpPRxuEGx5sg3DV8dmkGsurr+cQZqusJc3V1s/OeVTuA/PQY0D
# 2b4RVTA6lOOli2FZGLKTpuZVWTOR7UL8106eVxYVGcj7dwsXd1TNMIIGyTCCBLGg
# AwIBAgITMwAAH/RfCPXU1pd4tAAAAAAf9DANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDA0MB4XDTI2MDQwOTE0
# MzQxNFoXDTI2MDQxMjE0MzQxNFowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAsf4Pvl7ZySu6xNCnWo3KKJSQaAw33UaZkDQvfxswNB1fTheyahkc8nrTnbxc
# LqHkrP1k8kgzei31JUUoTK8arYUgZ8Sos61ekMCLIU/EfA4TZatxpRsqGqM0LBUf
# KlHVXeRxoxLl4HmtXXFBBChThDhr3lAiaDYqGbAqSz6is/JKkCgynnVF7eARDqtG
# SMfLuFVjlHf/GvPgR4UQJqmdjJ3jWM+TN0fKY0PyzoC1mYuBy8qr1UVhPm5WAdV+
# LH+LGer2PljIHoNSBdJESant8/IVdLCUP2fHX/Kt6rSsAk8FuvT9o83VuWL7+jDo
# Gnd90ABOhVonHLsZXrf2/uD3I9jqtBMLMYvBF5YNktPPZ+vel/BHqTLznQ6netZw
# OwDWNzQvVLmDmywAUWxfjfnKPlJfiQr2OSAsUZSwofl/hMkUNlbdZuc5VLq9sG0G
# avo5F5cQeVQN+d96CeXiBb1M4D6a+lbT82OKxgMlQMSF6xuD+5+9y14OS/2m/jZs
# e46lAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFOA+03ZzbGgCsTjhnKdWJuiZUSgQMB8GA1Ud
# IwQYMBaAFJrxVHd1DIcWN0agrN55+fR/wXjpMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDA0LmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQAUBM0tSViEGqCIbP22qNfs4Tj9nTpYL/1z4x/+
# acACtqFCZjDr67dlYlxlzRhOI+RNtb47br6RNGrZKal8faxK5Je6bBU1r129s92D
# Zc4Y7rxaCuYVF57mCvRgJrXdWbUyVUoJylujSshS8Cxxgn0J5ebdF3LGzofICRJf
# 4gWQX27Fr5xzVMBfKy+GQnFwEDA2hBVJcjmjKhRbv6IB3OZ+WdZV5MfCYaOSpJON
# WrQQjJv0GV+RwGUTjnhKcnOeXc6c5Rh6NmbrP/jgqOoHRQQk4Hucpj5770MAmaYX
# 85mTCiHayD4Cd1o/KfHsau3VUxXRv/g7BmXskbxlJdZ6FGHxSBGIzjROgOK88brd
# f/yLZLR5YMZcDYcHSKlt0MngIayd+serSDKv5Ygk2MV7J5nOQhY+3TefN5AeX0fA
# bBW8IgGtWl94W6yXl1teLisTy1t7WC7BNIqBnCydpKqdO4RoS32V7Qtk0yzH9IWu
# sRRkbfB3Fgf8dWMAtF48ZNGvG3MOAP68va9c4HVIhqioqbkjRikl+YPSPPwtt3nj
# HA0ruY0Htrp+gnhWHoixcLl9rKNJjqVhaT0cbhBsebINw1fHZpBrLq6/nEGarrCX
# N1dbPznlU7gPz0GNA9m+EVUwOpTjpYthWRiyk6bmVVkzke1C/NdOnlcWFRnI+3cL
# F3dUzTCCBygwggUQoAMCAQICEzMAAAAXJ0UJC4uHr8YAAAAAABcwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMzFaFw0zMTAzMjYxODExMzFaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCCx2T+Aw9mKgGVzJ+Tq0PMn49G3itIsYpb
# x7ClLSRHFe1RELdPcZ1sIqWOhsSfy6yyqEapClGH9Je9FXA1cQgZvvpQbkg+QInV
# Lr/0EPrVBCwrM96lbRI2PxNeCwXG9LsyW2hG6KQgintDmNCBo4zpDIr377plVdSl
# iZm6UB7rHwmvBnR02QT6tnrqWq2ihzB6lRJVTEzuh0OafzIMeMnYM0+x+ve5EOLH
# dfiq+HXiMf9Jb7YLHtYgyHIiJA7bTWLqFSLGaTh7ZlbxbsLXA91OOroEpv7OjzFu
# u3tkpC9FflA4Dp2Euq4+qPmxUqfGp+TX0gLRJp9NJOzzILjcTD3rkFFFbxUv1xyg
# 6avivFDLtoKBhM2Td138umE1pNOacanuSYtPHIeQHmB6haFi64avLBLwTTAm/Rbi
# t860cFXR72wq+5Qh4hSmezHqKXERWPpVBe+APrJ4Iqc+aPeMmIkoCWZQO22HnLNF
# UFSXjiwyIbgvlH/LIAJEqTafTzxDZgKhlLU7zr6gwsq3WNpcYQI6NuxWnwh3VVDD
# yF7onQqKs5Ll7bleVN0Y8VvqgE45ppyBbvwqN/Run5fMCCRz3aYMY0kZhKO92eP7
# t4zHqZ5bQMAgZ0tE2Pz/jb0wiykUF/PcoOqqk3vVLiRDYst6vd3GEMNzMpUUvQcv
# BG46+COIbwIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBSa8VR3dQyHFjdGoKzeefn0f8F46TBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQCQdVoZ/U0m38l2iKaZFlsx
# avptpoOLyaR1a9ZK2TSF1kOnFJhMDse6KkCgsveoiEjXTVc6Xt86IKHn76Nk5qZB
# 0BXv2iMRQ2giAJmYvZcmstoZqfB2M3Kd5wnJhUJOtF/b6HsqSelY6nhrF06zor1l
# DmDQixBZcLB9zR1+RKQso1jekNxYuUk+HaN3k1S57qk0O//YbkwU0mELCW04N5vI
# CMZx5T5c7Nq/7uLvbVhCdD7f2bZpA4U7vOkB1ooB4AaER3pjoJ0Mad5LFyi6Na9p
# 9Zu/hrLeOjU5FItS5YxsqvlfXxAThJ176CmkYstKRmytSHZ7JhKRfV6e9Zftk/OD
# b/CK4pGVAVqsOf4337bQGrOHHCQ3IvN9gmnUuDh8JdvbheoWPHxIN1GB5sUiY584
# tXN7xdD8LCSsRqJvQ8e7a3gZWTgViugRs1QWq+N0G9Nje6JHlN1CjJehge+H5PGk
# tJja+juGEr0P+ukSkcL6qaZxFQTh3SDI71lvW++3bl/Ezd6SO8N9Udw+reoyvRHC
# yTiSsplZQSBTVJdPmo3qCpGuyHFtPo5CBn3/FPTiqJd3M9BHoqKd0G9Kmg6fGcAv
# FwnLNXA2kov727wRljL3ypfqL7iAT/Ynpxul6RwHRlcOf9dDGg1RRvr92NP/CWVX
# Ib68geR2rvU/NsfmtjF1wDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
# AAcwDQYJKoZIhvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZl
# cmlmaWNhdGlvbiBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIx
# MDQwMTIwMDUyMFoXDTM2MDQwMTIwMTUyMFowYzELMAkGA1UEBhMCVVMxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElE
# IFZlcmlmaWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALLwwK8ZiCji3VR6TElsaQhVCbRS/3pK+MHrJSj3Zxd3
# KU3rlfL3qrZilYKJNqztA9OQacr1AwoNcHbKBLbsQAhBnIB34zxf52bDpIO3NJlf
# IaTE/xrweLoQ71lzCHkD7A4As1Bs076Iu+mA6cQzsYYH/Cbl1icwQ6C65rU4V9NQ
# hNUwgrx9rGQ//h890Q8JdjLLw0nV+ayQ2Fbkd242o9kH82RZsH3HEyqjAB5a8+Ae
# 2nPIPc8sZU6ZE7iRrRZywRmrKDp5+TcmJX9MRff241UaOBs4NmHOyke8oU1TYrkx
# h+YeHgfWo5tTgkoSMoayqoDpHOLJs+qG8Tvh8SnifW2Jj3+ii11TS8/FGngEaNAW
# rbyfNrC69oKpRQXY9bGH6jn9NEJv9weFxhTwyvx9OJLXmRGbAUXN1U9nf4lXezky
# 6Uh/cgjkVd6CGUAf0K+Jw+GE/5VpIVbcNr9rNE50Sbmy/4RTCEGvOq3GhjITbCa4
# crCzTTHgYYjHs1NbOc6brH+eKpWLtr+bGecy9CrwQyx7S/BfYJ+ozst7+yZtG2wR
# 461uckFu0t+gCwLdN0A6cFtSRtR8bvxVFyWwTtgMMFRuBa3vmUOTnfKLsLefRaQc
# VTgRnzeLzdpt32cdYKp+dhr2ogc+qM6K4CBI5/j4VFyC4QFeUP2YAidLtvpXRRo3
# AgMBAAGjggI1MIICMTAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAw
# HQYDVR0OBBYEFNlBKbAPD2Ns72nX9c0pnqRIajDmMFQGA1UdIARNMEswSQYEVR0g
# ADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L0RvY3MvUmVwb3NpdG9yeS5odG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2io
# ojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBS
# b290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBwwYIKwYB
# BQUHAQEEgbYwgbMwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0
# aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQw
# LQYIKwYBBQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20vb2NzcDAN
# BgkqhkiG9w0BAQwFAAOCAgEAfyUqnv7Uq+rdZgrbVyNMul5skONbhls5fccPlmIb
# zi+OwVdPQ4H55v7VOInnmezQEeW4LqK0wja+fBznANbXLB0KrdMCbHQpbLvG6UA/
# Xv2pfpVIE1CRFfNF4XKO8XYEa3oW8oVH+KZHgIQRIwAbyFKQ9iyj4aOWeAzwk+f9
# E5StNp5T8FG7/VEURIVWArbAzPt9ThVN3w1fAZkF7+YU9kbq1bCR2YD+MtunSQ1R
# ft6XG7b4e0ejRA7mB2IoX5hNh3UEauY0byxNRG+fT2MCEhQl9g2i2fs6VOG19CNe
# p7SquKaBjhWmirYyANb0RJSLWjinMLXNOAga10n8i9jqeprzSMU5ODmrMCJE12xS
# /NWShg/tuLjAsKP6SzYZ+1Ry358ZTFcx0FS/mx2vSoU8s8HRvy+rnXqyUJ9HBqS0
# DErVLjQwK8VtsBdekBmdTbQVoCgPCqr+PDPB3xajYnzevs7eidBsM71PINK2BoE2
# UfMwxCCX3mccFgx6UsQeRSdVVVNSyALQe6PT12418xon2iDGE81OGCreLzDcMAZn
# rUAx4XQLUz6ZTl65yPUiOh3k7Yww94lDf+8oG2oZmDh5O1Qe38E+M3vhKwmzIeoB
# 1dVLlz4i3IpaDcR+iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFI
# rmcxghqSMIIajgIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDQCEzMAAB/0Xwj11NaXeLQAAAAAH/QwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgEFvzRFuugSUE8NhOiZIIPAdx0vk79BEDfszgshuckdcw
# DQYJKoZIhvcNAQEBBQAEggGAm/ID0kCZ13wFWrvj44vaX5qf4i5Wdck1iuPIUJT0
# kzSzhENc6XSbUnJbVgbJitr1caV9337gcIxEbNi978KuZRmKlSFiArXkH2QNW0zX
# k/IXdLZtNQonkFytpGAAuLdOwycXyD0e6FHnX/qArpb2RuU/iXefu416ZsEjsiyF
# spnhtayBGOllUySXXeav8DOM9+KZHUPLKwbR4QqGuLn2p1bZtgfv0JuUqp5c++RZ
# PCVO6jMSa7Oz4U7KyNX3LkbWMZyA7Pz9qJ/frR47tsfMwf4G2wzfr1W+rcvSxwQK
# 3ZYKVikfV3kp+ULLy+ODqDCwCokihqAOvBes0H6E7CP7DNqBjlhbocOnvHcMGV8f
# +D2m+hQiWwb/PwakhyDSb/bKM+7t9JfMK2SGRWwWmQ5zMF5pLCcQKWrBQxi+Ab9S
# jZO9KPXrA8wceppj0GeXRxjQyQPGXn+239d/0LFNb7GjIJQte3jYYmZFaAGOzXTv
# jivDEGHx6IE2ZlDk4XapL763oYIYEjCCGA4GCisGAQQBgjcDAwExghf+MIIX+gYJ
# KoZIhvcNAQcCoIIX6zCCF+cCAQMxDzANBglghkgBZQMEAgEFADCCAWAGCyqGSIb3
# DQEJEAEEoIIBTwSCAUswggFHAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIIwSa4h467PlEpj4tclWAWu44AED7jgClwXK6eEMf++XAgZp1AZ/h5UYETIw
# MjYwNDA5MTgzNzEyLjRaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5
# NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcg
# QXV0aG9yaXR5oIIPITCCB4IwggVqoAMCAQICEzMAAAAF5c8P/2YuyYcAAAAAAAUw
# DQYJKoZIhvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlm
# aWNhdGlvbiBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIwMTEx
# OTIwMzIzMVoXDTM1MTExOTIwNDIzMVowYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1Ymxp
# YyBSU0EgVGltZXN0YW1waW5nIENBIDIwMjAwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQCefOdSY/3gxZ8FfWO1BiKjHB7X55cz0RMFvWVGR3eRwV1wb3+y
# q0OXDEqhUhxqoNv6iYWKjkMcLhEFxvJAeNcLAyT+XdM5i2CgGPGcb95WJLiw7HzL
# iBKrxmDj1EQB/mG5eEiRBEp7dDGzxKCnTYocDOcRr9KxqHydajmEkzXHOeRGwU+7
# qt8Md5l4bVZrXAhK+WSk5CihNQsWbzT1nRliVDwunuLkX1hyIWXIArCfrKM3+RHh
# +Sq5RZ8aYyik2r8HxT+l2hmRllBvE2Wok6IEaAJanHr24qoqFM9WLeBUSudz+qL5
# 1HwDYyIDPSQ3SeHtKog0ZubDk4hELQSxnfVYXdTGncaBnB60QrEuazvcob9n4yR6
# 5pUNBCF5qeA4QwYnilBkfnmeAjRN3LVuLr0g0FXkqfYdUmj1fFFhH8k8YBozrEaX
# nsSL3kdTD01X+4LfIWOuFzTzuoslBrBILfHNj8RfOxPgjuwNvE6YzauXi4orp4Sm
# 6tF245DaFOSYbWFK5ZgG6cUY2/bUq3g3bQAqZt65KcaewEJ3ZyNEobv35Nf6xN6F
# rA6jF9447+NHvCjeWLCQZ3M8lgeCcnnhTFtyQX3XgCoc6IRXvFOcPVrr3D9RPHCM
# S6Ckg8wggTrtIVnY8yjbvGOUsAdZbeXUIQAWMs0d3cRDv09SvwVRd61evQIDAQAB
# o4ICGzCCAhcwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1Ud
# DgQWBBRraSg6NS9IY0DPe9ivSek+2T3bITBUBgNVHSAETTBLMEkGBFUdIAAwQTA/
# BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2Nz
# L1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcU
# AgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7S
# aoUqG8oZmAQHJ89QEE9oqKIwgYQGA1UdHwR9MHsweaB3oHWGc2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElkZW50aXR5JTIw
# VmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIw
# MjAyMC5jcmwwgZQGCCsGAQUFBwEBBIGHMIGEMIGBBggrBgEFBQcwAoZ1aHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVu
# dGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhv
# cml0eSUyMDIwMjAuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBfiHbHfm21WhV150x4
# aPpO4dhEmSUVpbixNDmv6TvuIHv1xIs174bNGO/ilWMm+Jx5boAXrJxagRhHQtiF
# prSjMktTliL4sKZyt2i+SXncM23gRezzsoOiBhv14YSd1Klnlkzvgs29XNjT+c8h
# IfPRe9rvVCMPiH7zPZcw5nNjthDQ+zD563I1nUJ6y59TbXWsuyUsqw7wXZoGzZwi
# jWT5oc6GvD3HDokJY401uhnj3ubBhbkR83RbfMvmzdp3he2bvIUztSOuFzRqrLfE
# vsPkVHYnvH1wtYyrt5vShiKheGpXa2AWpsod4OJyT4/y0dggWi8g/tgbhmQlZqDU
# f3UqUQsZaLdIu/XSjgoZqDjamzCPJtOLi2hBwL+KsCh0Nbwc21f5xvPSwym0Ukr4
# o5sCcMUcSy6TEP7uMV8RX0eH/4JLEpGyae6Ki8JYg5v4fsNGif1OXHJ2IWG+7zyj
# TDfkmQ1snFOTgyEX8qBpefQbF0fx6URrYiarjmBprwP6ZObwtZXJ23jK3Fg/9uqM
# 3j0P01nzVygTppBabzxPAh/hHhhls6kwo3QLJ6No803jUsZcd4JQxiYHHc+Q/wAM
# cPUnYKv/q2O444LO1+n6j01z5mggCSlRwD9faBIySAcA9S8h22hIAcRQqIGEjolC
# K9F6nK9ZyX4lhthsGHumaABdWzCCB5cwggV/oAMCAQICEzMAAABXJNOV4KLpyTEA
# AAAAAFcwDQYJKoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBS
# U0EgVGltZXN0YW1waW5nIENBIDIwMjAwHhcNMjUxMDIzMjA0NjUzWhcNMjYxMDIy
# MjA0NjUzWjCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEl
# MCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMe
# blNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3Nv
# ZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBALFspQqTCH24syS2NZD1ztnJl9h0Vr0WwJni
# kmeXse/4wspnVexGqfiHNoqkbVg5CinuYC+iVfNMLZ+QtqhySz8VGBSjRt1JB5AC
# NtTKAjfmFp4U/Cv2Lj4m+vuve9I3W3hSiImTFsHeYZ6V/Sd43rXrhHV26fw3xQSt
# eSbg9yTs1rhdrLkAj4KmI0D5P4KavtygirVyUW10gkifWLSE1NiB8Jn3RO5dj32d
# eeMNONaaPnw3k49ICTs3Ffyb+ekNDPsNfYwCqPyOTxM6y1dSD0J5j+KK9V+EWyV5
# PDjV8jjn1zsStlS6TcYJJStcgHs2xT9rs6ooWl5FtYfRkCxhDShEp3s8IHUWizTW
# mLZvAE/6WR2Cd+ZmVapGXTCHJKUByZPxdX0i8gynirR+EwuHHNxEilDICLatO2WZ
# u+CQrH4Zq0NYo1TQ4tUpZ/kAWpoAu1r4mW5EJ3HkEavQ2PuoQDcDq2rAGVIla9pD
# 7o9Yxwzl81BuDvUEyu9D/6F0qmQDdaE791HxfCUxpgMYPpdWTzs+dDGPehwQ8P92
# yP8ARjby5Ony1Z68RjeQebpxf5WL441myFHcgT1UJzzil7tPEkR22NfTNR6Fl+jz
# Wb/r80nqlXllhynSowtxo1Y22xqYviS24smikUsBKqOPbSS77uvXEO3VrG5LGouE
# 1EZ1Y9pjAgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQUjoPJXi01DgIJSGfm416Yg+0S
# kqcwHwYDVR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBh
# oF+gXYZbaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9z
# b2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNy
# bDB5BggrBgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIw
# VGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1Ud
# JQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEG
# DCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqG
# SIb3DQEBDAUAA4ICAQBydcB2POmZOUlAQz2NuXf7vWCVWmjWu9bsY1+HMjv1yeLj
# xDQkjsJEU5zaIDy8Uw9BYN8+ExX/9k/9CBUsXbVlbU44c65/liyJ83kWsFIUwhVa
# zwSShFlbIZviIO/5weyWyTfPPpbSJgWy+ZE9UrQS3xulJLAHA2zUkMMPdAlF4Rrn
# gcZZ0r45AF9aIYjdestWwdrNK70MfArHqZdgrgXn03w6zBs1v7czceWGitg/DlsH
# qk1mXBpSTuGI2TSPN3E60IIXx5f/AFzh4/HFi98BBZbUELNsXkWAG9ynZ5e6CFii
# l1mgWCWOT90D7Igvg0zKe3o3WCk629/en94K/sC/zLOf2d7yFmTySb9fKjcONH1D
# b3kZ8MzEJ8fHTNmxrl10Gecuz/Gl0+ByTKN+PambZ+F0MIlBPww6fvjFC9JII73f
# w3qO169+9TxTz2G+E26GYY1dcffsAhw6DqTQgbflbl1O/MrSXSs0NSb9nBD9RfR/
# f8Ei7DA1L1jBO7vZhhJTjw2TzFa/ALgRLi3W00hHWi8LGQaZc8SwXIMYWfwrN9Mg
# YbhN0Iak9WA2dqWuekXsTwNkmrD3E6E+oCYCehNOgZmds0Ezb1jo7OV0Kh22Ll3K
# Hg3MHtlGguxAzhg/BpixPS4qrULLkAjO7+yNsUfrD2U9gMf/OR4yJDPtzM0ytTGC
# B0YwggdCAgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0
# YW1waW5nIENBIDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwDQYJYIZIAWUDBAIB
# BQCgggSfMBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwOTE4MzcxMlowLwYJKoZIhvcNAQkE
# MSIEIKUr5xdXr349A0qlqb05kgfSJBd5kHziiT9mpfpeqte5MIG5BgsqhkiG9w0B
# CRACLzGBqTCBpjCBozCBoAQg9TyfZLUFbkxliGyizuH9VVDpVFNvQEQhKQ2ZhUx4
# 21IwfDBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1w
# aW5nIENBIDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwggNhBgsqhkiG9w0BCRAC
# EjGCA1AwggNMoYIDSDCCA0QwggIsAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFt
# ZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAt
# MDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0
# YW1waW5nIEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUA/S8xOZxCUQFBNkrN8Wii
# j1x5y8OgZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0
# YW1waW5nIENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDtgdC7MCIYDzIwMjYwNDA5
# MDcxNjExWhgPMjAyNjA0MTAwNzE2MTFaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIF
# AO2B0LsCAQAwCgIBAAICCBICAf8wBwIBAAICEmEwCgIFAO2DIjsCAQAwNgYKKwYB
# BAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGG
# oDANBgkqhkiG9w0BAQsFAAOCAQEAlKBdOYICOlfYkadkZpEIUsVg9wbOzVzBghx9
# 1VyrQoRYJZaaqNwBsR3LLiK1naod6g96mu6HSs8hQE5RcCIWLq/WB4qL1B5D0B28
# mMOT3qn64EBhA5XSthsBuYeg16q9/7bCpUAHhgvkOSHK90TPTra47A5R59iUQv0O
# pIIesfoZyTLoA1FVCU6g8cgLOh46FMoZHpe5CQfq4VCFEgSaUXktBjDwrVe5ZXJD
# +zfyEgDsQBph6qhniV+KuojzbQAZRJglXBJFP1V8VUlQQLl1IGwXVIAMrUiypJS3
# PQeLVEX7vPtPqpfiAWV7SJ8IDneRCRaIb0knbk8Vpm+LTzurjDANBgkqhkiG9w0B
# AQEFAASCAgCEmUZbtTbOjZw5PUZMx6eDC7nasjV9U9J7wJ5UyKzvWTh1o0VfXZRK
# tTE2OUpSJ7NCDI5zLBcfAkQnPbbNW+QdXinNZCaLmJ1ggSNTvMmNXppUwZJEjNLc
# ppQRIkT/KfBCTHghVAIW26TbZJxpcTVxaVv6Ia7cTeKGyhuS7EVJhLBfTx6ym3kP
# M9mEmJx9RBx+ZNue4O6fEt+FOCHJGdFaIwTi8ZnW8IXJu81aAQK0cSSwwbZi7JW6
# nf8H29YCtw0shtAkqM/ZbQUE3cf72fViQldKJaYMio0GXmw5ipoErGKJDEbTyB+U
# EAyMleZTzr+fOUKum60Nf7qxzq9/2oNtxGlfqiExfYlAJVVe80vz1ixpk3al3vJ2
# adeu4nckmenQB+cNPfxPDKk7ZywKszvgxJlPqkmzaAD6LX+ADBm40xFAOT0zST3v
# rK9Z10OVqQH3rSu8u/yr8m3HKerVT6sQ5mGiDd/aUS2uxqEuJrkzb3vXN3zT4zxn
# SmRgDe21qp2YWvlkAxRUjzV2ktk7vGttDQudp9wGAAneSEmZAa1hc7pZkzQtcnIE
# WQ3GphbyU7H7v19VPMNeMaUcOi3WeD6srLMwF4KlUuEJgCLoGpd6Y+5enZSRMcFx
# tc3DPecP8Ezr7x78qxS8LZjyNDk+S0N5PYAjZkiarr30U3HrA3jzVA==
# SIG # End signature block

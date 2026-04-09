<#
.SYNOPSIS
    Corporate proxy configuration module for Nova deployment scripts.

.DESCRIPTION
    Provides functions to configure, query, and clear HTTP/HTTPS proxy settings
    used during WinPE-based Windows deployments.  Supports authenticated proxies
    via PSCredential and sets both .NET and environment-variable-based proxies
    so that Invoke-WebRequest, Invoke-RestMethod, and external tools all honour
    the configuration.
#>

Set-StrictMode -Version Latest

# -- Module-scoped proxy state --------------------------------------------------
$script:ProxyUrl    = ''
$script:BypassList  = ''
$script:IsConfigured = $false

function Set-NovaProxy {
    <#
    .SYNOPSIS  Configures corporate proxy settings for the current session.
    .PARAMETER ProxyUrl    Proxy URL (e.g. http://proxy.corp:8080).
    .PARAMETER BypassList  Comma-separated list of hosts to bypass (default: localhost,127.0.0.1).
    .PARAMETER Credential  Optional PSCredential for authenticated proxies.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Setting in-memory proxy state and environment variables -- no persistent system side-effects')]
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProxyUrl,

        [string]$BypassList = 'localhost,127.0.0.1',

        [System.Management.Automation.PSCredential]$Credential
    )

    # Store in module scope
    $script:ProxyUrl    = $ProxyUrl
    $script:BypassList  = $BypassList
    $script:IsConfigured = $true

    # Configure .NET default web proxy
    $proxy = New-Object System.Net.WebProxy($ProxyUrl)
    $proxy.BypassProxyOnLocal = $true
    if ($BypassList) {
        $proxy.BypassList = $BypassList -split ',' | ForEach-Object {
            # WebProxy.BypassList requires regex patterns; convert wildcard entries
            $entry = [regex]::Escape($_.Trim())
            $entry -replace '\\\*', '.*'
        }
    }
    if ($Credential) {
        $proxy.Credentials = $Credential.GetNetworkCredential()
    }
    [System.Net.WebRequest]::DefaultWebProxy = $proxy

    # Set environment variables so external tools (curl, git, etc.) also use the proxy
    $env:HTTP_PROXY  = $ProxyUrl
    $env:HTTPS_PROXY = $ProxyUrl
    $env:NO_PROXY    = $BypassList

    Write-Verbose "Nova proxy configured: $ProxyUrl (bypass: $BypassList)"
}

function Get-NovaProxy {
    <#
    .SYNOPSIS  Returns the current proxy configuration as a hashtable.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param()

    return @{
        ProxyUrl     = $script:ProxyUrl
        BypassList   = $script:BypassList
        IsConfigured = $script:IsConfigured
    }
}

function Clear-NovaProxy {
    <#
    .SYNOPSIS  Resets proxy configuration to default (no proxy).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Clearing in-memory proxy state and environment variables -- no persistent system side-effects')]
    [OutputType([void])]
    [CmdletBinding()]
    param()

    $script:ProxyUrl    = ''
    $script:BypassList  = ''
    $script:IsConfigured = $false

    [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebRequest]::GetSystemWebProxy()

    # Clear environment variables
    $env:HTTP_PROXY  = $null
    $env:HTTPS_PROXY = $null
    $env:NO_PROXY    = $null

    Write-Verbose 'Nova proxy configuration cleared.'
}

Export-ModuleMember -Function Set-NovaProxy, Get-NovaProxy, Clear-NovaProxy

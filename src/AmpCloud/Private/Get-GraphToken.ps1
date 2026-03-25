function Get-GraphToken {
    <#
    .SYNOPSIS  Returns the Microsoft Graph access token obtained during M365 sign-in.
    .OUTPUTS   The bearer access token string, or $null when unavailable.
    #>
    if ($script:GraphAccessToken) {
        return $script:GraphAccessToken
    }
    Write-Host 'Status: No Graph access token available — ensure M365 sign-in completed successfully.'
    return $null
}

<#
.SYNOPSIS
    Utility functions for Autopilot device import.
.DESCRIPTION
    Provides Get-GraphToken and Test-AutopilotStatus used by
    Invoke-ImportAutopilot.ps1.  The access token is obtained from the
    $script:GraphAccessToken variable set by the M365 auth flow in
    Bootstrap.ps1 or Trigger.ps1 (delegated permissions — no client
    secret required).
#>

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

function Test-AutopilotStatus {
    <#
    .SYNOPSIS  Checks whether a device is already registered in Windows Autopilot.
    .PARAMETER SerialNumber
        The serial number of the device to look up.
    .PARAMETER Token
        A valid Microsoft Graph bearer token with
        DeviceManagementServiceConfig.ReadWrite.All permission.
    .OUTPUTS
        Hashtable with keys: Success, IsRegistered, GroupTag, Profile.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SerialNumber,
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    try {
        $sanitized = $SerialNumber -replace "['\\\x00-\x1f]", ''
        $filter = [uri]::EscapeDataString("contains(serialNumber,'$sanitized')")
        $uri    = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"

        $response = Invoke-RestMethod -Uri $uri `
            -Headers @{
                'Authorization' = "Bearer $Token"
                'Content-Type'  = 'application/json'
            } -Method GET

        if ($response.value -and $response.value.Count -gt 0) {
            $device = $response.value[0]
            return @{
                Success      = $true
                IsRegistered = $true
                GroupTag     = $device.groupTag
                Profile      = $device.deploymentProfileAssignmentStatus
            }
        }

        return @{ Success = $true; IsRegistered = $false }
    }
    catch {
        Write-Host "Status: Error checking Autopilot status: $($_.Exception.Message)"
        return @{ Success = $false; IsRegistered = $false }
    }
}

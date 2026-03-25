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

# Import utility functions (provides Get-GraphToken, Test-AutopilotStatus)
. "$PSScriptRoot\Utils.ps1"

Start-Transcript -Path "X:\OSDCloud\Logs\Invoke-ImportAutopilot.log" -Force

function Import-AutopilotDevice {
    <#
    .SYNOPSIS  Imports the current device into Windows Autopilot via the Microsoft Graph API.
    .DESCRIPTION
        Generates a hardware hash using oa3tool.exe, checks whether the device
        is already registered in Autopilot, and if not, uploads the device
        identity via the Graph API.  Uses delegated permissions — no app
        registration secret is required.  The access token comes from the
        M365 sign-in flow (Get-GraphToken).
    .PARAMETER GroupTag
        Autopilot group tag to assign to the device (alphanumeric, hyphens,
        underscores; max 100 characters).
    .PARAMETER UserEmail
        Optional user principal name to assign to the device.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupTag,
        [string]$UserEmail
    )

    # Validate GroupTag — alphanumeric, hyphens, underscores only; max 100 characters
    if ($GroupTag -notmatch '^[a-zA-Z0-9\-_]{1,100}$') {
        Write-Error "GroupTag must be 1-100 characters and contain only letters, digits, hyphens, or underscores."
        return @{ Success = $false; Message = "Invalid GroupTag format" }
    }

    # Validate UserEmail format if provided
    if ($UserEmail -and $UserEmail -notmatch '^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$') {
        Write-Error "Invalid email address format: $UserEmail"
        return @{ Success = $false; Message = "Invalid email address format" }
    }

    try {
        $CustomFolder = "X:\OSDCloud\Config\Scripts\Custom"
        Write-Host "Status: Using Custom folder path: $CustomFolder"
        $PcpkspPath = Join-Path $CustomFolder "PCPKsp.dll"
        $Oa3toolPath = Join-Path $CustomFolder "oa3tool.exe"
        $Oa3cfgPath = Join-Path $CustomFolder "OA3.cfg"

        Write-Host "Status: Checking for required files..."
        if (-not (Test-Path $PcpkspPath)) { Write-Host "Status: Missing PCPKsp.dll" }
        if (-not (Test-Path $Oa3toolPath)) { Write-Host "Status: Missing oa3tool.exe" }
        if (-not (Test-Path $Oa3cfgPath)) { Write-Host "Status: Missing OA3.cfg" }
        if (-not (Test-Path $PcpkspPath) -or -not (Test-Path $Oa3toolPath) -or -not (Test-Path $Oa3cfgPath)) {
            Write-Error "Required files missing from Custom folder"
            return @{ Success = $false; Message = "Required files missing" }
        }
        Write-Host "Status: All required files found"

        Write-Host "Status: Generating hardware hash..."
        $Oa3Process = Start-Process -FilePath $Oa3toolPath `
            -ArgumentList "/Report /ConfigFile=$Oa3cfgPath /NoKeyCheck" `
            -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput "oa3.log" -RedirectStandardError "oa3.error.log"
        if ($Oa3Process.ExitCode -ne 0) {
            Write-Host "Status: Failed to generate hardware hash"
            return @{ Success = $false; Message = "Failed to generate hardware hash" }
        }

        if (-not (Test-Path "OA3.xml")) {
            Write-Host "Status: Hardware hash file not found"
            return @{ Success = $false; Message = "Hardware hash file not found" }
        }

        Write-Host "Status: Reading hardware hash..."
        [xml]$XmlHash = Get-Content -Path "OA3.xml" -Raw
        $hashNode = $XmlHash.SelectSingleNode("//HardwareHash")
        if (-not $hashNode -or -not $hashNode.InnerText) {
            Write-Host "Status: Hardware hash node not found or empty in OA3.xml"
            return @{ Success = $false; Message = "Hardware hash not found in OA3.xml" }
        }
        $Hash = $hashNode.InnerText
        Write-Host "Status: Successfully extracted hardware hash"
        Remove-Item "OA3.xml" -Force

        Write-Host "Status: Getting device serial number..."
        $SerialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
        if (-not $SerialNumber -or $SerialNumber.Trim() -eq '') {
            Write-Host "Status: Failed to retrieve device serial number"
            return @{ Success = $false; Message = "Device serial number is empty or unavailable" }
        }
        Write-Host "Status: Device serial number: $SerialNumber"

        Write-Host "Status: Preparing device registration data..."
        $RequestBodyObj = @{
            groupTag           = $GroupTag
            serialNumber       = $SerialNumber
            hardwareIdentifier = $Hash
        }
        if ($UserEmail) {
            Write-Host "Status: Including user assignment: $UserEmail"
            $RequestBodyObj.assignedUserPrincipalName = $UserEmail
        }
        $RequestBody = $RequestBodyObj | ConvertTo-Json

        Write-Host "Status: Getting Graph API token..."
        $GraphToken = Get-GraphToken
        if (-not $GraphToken) {
            Write-Host "Status: Failed to get Graph token"
            return @{ Success = $false; Message = "Failed to get Graph token" }
        }

        # ── Check if the device is already registered in Autopilot ──────────
        Write-Host "Status: Checking if device is already registered in Autopilot..."
        $existingStatus = Test-AutopilotStatus -SerialNumber $SerialNumber -Token $GraphToken
        if ($existingStatus.Success -and $existingStatus.IsRegistered) {
            Write-Host "Status: Device is already registered in Autopilot — skipping import"
            Write-Host "Status: Group Tag: $($existingStatus.GroupTag)"
            Write-Host "Status: Profile: $($existingStatus.Profile)"
            return @{
                Success  = $true
                Message  = "Device is already registered in Autopilot"
                GroupTag = $existingStatus.GroupTag
                Profile  = $existingStatus.Profile
            }
        }
        Write-Host "Status: Device not found in Autopilot — proceeding with import"

        Write-Host "Status: Uploading device information to Intune..."
        $null = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities" `
            -Headers @{
            'Authorization' = "Bearer $GraphToken"
            'Content-Type'  = 'application/json'
        } -Method POST -Body $RequestBody

        Write-Host "Status: Device information uploaded successfully"
        Write-Host "Status: Waiting for registration to complete..."

        $MaxAttempts = 25
        $Attempt = 0
        $Registered = $false
        do {
            $Attempt++
            Write-Host "Status: Verifying registration (Attempt $Attempt of $MaxAttempts)..."
            $AutopilotStatus = Test-AutopilotStatus -SerialNumber $SerialNumber -Token $GraphToken
            if ($AutopilotStatus.Success -and $AutopilotStatus.IsRegistered) {
                $Registered = $true
                Write-Host "Status: Device successfully registered"
                Write-Host "Status: Group Tag: $($AutopilotStatus.GroupTag)"
                Write-Host "Status: Profile: $($AutopilotStatus.Profile)"
                break
            }
            Write-Host "Status: Device not yet visible in Autopilot, waiting 30 seconds..."
            Start-Sleep -Seconds 30
        } while ($Attempt -lt $MaxAttempts)

        if (-not $Registered) {
            Write-Host "Status: Registration verification timed out"
            return @{ Success = $false; Message = "Device registration verification failed after $MaxAttempts attempts" }
        }

        return @{ 
            Success  = $true
            Message  = "Device successfully registered and verified in Autopilot"
            GroupTag = $AutopilotStatus.GroupTag
            Profile  = $AutopilotStatus.Profile
        }
    }
    catch {
        Write-Host "Status: Error during registration: $($_.Exception.Message)"
        return @{ Success = $false; Message = "Error during registration: $($_.Exception.Message)" }
    }
}


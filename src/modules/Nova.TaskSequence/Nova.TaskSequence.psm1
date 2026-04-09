<#
.SYNOPSIS
    Task sequence parsing, condition evaluation, and validation module for Nova.

.DESCRIPTION
    Provides functions for loading task sequence JSON files, evaluating
    step conditions (variable, WMI, registry), and performing dry-run
    validation of deployment configurations.
#>

Set-StrictMode -Version Latest

# ── Private helper: safely check if a PSCustomObject has a property ─────────
function _HasProp {
    [CmdletBinding()]
    param([psobject]$Obj, [string]$Name)
    return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name])
}

function Read-TaskSequence {
    <#
    .SYNOPSIS  Loads a task sequence JSON file produced by the web-based Editor.
    .DESCRIPTION
        Reads the JSON file, validates the required structure (name + steps array),
        and returns a hashtable matching the schema in resources/task-sequence/default.json.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path $Path)) {
        throw "Task sequence file not found: $Path"
    }
    Write-Step "Loading task sequence from $Path"
    $raw = Get-Content $Path -Raw -ErrorAction Stop
    $ts  = $raw | ConvertFrom-Json -ErrorAction Stop

    if (-not (_HasProp $ts 'steps') -or $ts.steps -isnot [System.Collections.IEnumerable]) {
        throw "Invalid task sequence file: missing 'steps' array"
    }
    foreach ($s in $ts.steps) {
        if (-not (_HasProp $s 'type')) { throw "Invalid task sequence: step '$($s.name)' is missing required 'type' property" }
        if (-not (_HasProp $s 'name')) { throw "Invalid task sequence: a step with type '$($s.type)' is missing required 'name' property" }
    }

    # ── Schema version validation (forward-compatible) ──────────────
    if ($ts.PSObject.Properties['schemaVersion'] -and $ts.schemaVersion) {
        if ($ts.schemaVersion -ne '1.0') {
            Write-Warning "Task sequence schema version '$($ts.schemaVersion)' may not be fully compatible with this engine (expected 1.0)"
        }
    } else {
        Write-Verbose 'No schemaVersion found -- assuming 1.0 compatibility'
    }

    Write-Success "Loaded task sequence '$($ts.name)' with $($ts.steps.Count) steps"
    return $ts
}

function Test-StepCondition {
    <#
    .SYNOPSIS  Evaluates a step's condition object and returns $true/$false.
    .DESCRIPTION
        Each step in the task sequence may carry an optional 'condition' property
        (set via the Editor's Condition UI).  This function evaluates the condition
        at runtime and returns $true when the step should run, $false to skip it.
        Steps without a condition always return $true.

        Supported condition types:
          variable  -- check an environment / task-sequence variable
          wmiQuery  -- run a WMI query and check whether it returns results
          registry  -- check a registry path/value
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [psobject]$Condition
    )

    if (-not $Condition -or -not (_HasProp $Condition 'type')) { return $true }

    switch ($Condition.type) {
        'variable' {
            $varName = if (_HasProp $Condition 'variable') { $Condition.variable } else { $null }
            if (-not $varName) { return $true }
            $actual = [System.Environment]::GetEnvironmentVariable($varName)
            $op = if ((_HasProp $Condition 'operator') -and $Condition.operator) { $Condition.operator } else { 'equals' }
            $expected = if ((_HasProp $Condition 'value') -and $Condition.value) { $Condition.value } else { '' }

            switch ($op) {
                'equals'     { return ($actual -eq $expected) }
                'notEquals'  { return ($actual -ne $expected) }
                'contains'   { return ($null -ne $actual -and "$actual".IndexOf($expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) }
                'startsWith' { return ($null -ne $actual -and "$actual".StartsWith($expected, [System.StringComparison]::OrdinalIgnoreCase)) }
                'exists'     { return ($null -ne $actual) }
                'notExists'  { return ($null -eq $actual) }
                default      { return $true }
            }
        }
        'wmiQuery' {
            $query = if (_HasProp $Condition 'query') { $Condition.query } else { $null }
            if (-not $query) { return $true }
            $ns = if ((_HasProp $Condition 'namespace') -and $Condition.namespace) { $Condition.namespace } else { 'root\cimv2' }
            try {
                $results = Get-CimInstance -Query $query -Namespace $ns -ErrorAction Stop
                return ($null -ne $results -and @($results).Count -gt 0)
            } catch {
                Write-Warn "WMI condition query failed: $_"
                return $false
            }
        }
        'registry' {
            $regPath = if (_HasProp $Condition 'registryPath') { $Condition.registryPath } else { $null }
            if (-not $regPath) { return $true }
            $regValue = if (_HasProp $Condition 'registryValue') { $Condition.registryValue } else { $null }
            $op = if ((_HasProp $Condition 'operator') -and $Condition.operator) { $Condition.operator } else { 'exists' }
            $expected = if ((_HasProp $Condition 'value') -and $Condition.value) { $Condition.value } else { '' }

            try {
                if (-not $regValue) {
                    # Check key existence only
                    $keyExists = Test-Path $regPath
                    switch ($op) {
                        'exists'    { return $keyExists }
                        'notExists' { return (-not $keyExists) }
                        default     { return $keyExists }
                    }
                }

                # Check specific value
                $valueExists = $false
                $actual = $null
                if (Test-Path $regPath) {
                    try {
                        $actual = (Get-ItemProperty -Path $regPath -Name $regValue -ErrorAction Stop).$regValue
                        $valueExists = $true
                    } catch { $valueExists = $false }
                }

                switch ($op) {
                    'exists'    { return $valueExists }
                    'notExists' { return (-not $valueExists) }
                    'equals'    { return ($valueExists -and "$actual" -eq $expected) }
                    'notEquals' { return (-not $valueExists -or "$actual" -ne $expected) }
                    default     { return $valueExists }
                }
            } catch {
                Write-Warn "Registry condition check failed: $_"
                return $false
            }
        }
        default {
            Write-Warn "Unknown condition type '$($Condition.type)' -- treating as met"
            return $true
        }
    }
}

function Invoke-DryRunValidation {
    <#
    .SYNOPSIS  Validates the deployment configuration without making any changes.
    .DESCRIPTION
        Walks through all enabled task-sequence steps and checks that required
        resources (disks, TPM, network) are available. Reports warnings and
        errors without modifying the system.
    .PARAMETER TaskSequence
        The parsed task-sequence object (from Read-TaskSequence).
    .PARAMETER ScratchDir
        Working directory for temporary files.
    .PARAMETER OSDrive
        Target OS drive letter (e.g. 'W').
    .PARAMETER FirmwareType
        Firmware type: 'UEFI' or 'BIOS'.
    .PARAMETER DiskNumber
        Physical disk number targeted for deployment.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [psobject]$TaskSequence,
        [string]$ScratchDir,
        [string]$OSDrive,
        [string]$FirmwareType,
        [int]$DiskNumber
    )

    Write-Step 'DRY RUN -- Validating deployment configuration...'
    $errors = @()
    $warnings = @()

    $enabledSteps = @($TaskSequence.steps | Where-Object { $_.enabled -ne $false })
    Write-Host "  Task sequence: $($TaskSequence.name)"
    Write-Host "  Total steps: $($TaskSequence.steps.Count) ($($enabledSteps.Count) enabled)"
    Write-Host "  Firmware type: $FirmwareType"
    Write-Host "  Target disk: $DiskNumber"
    Write-Host "  OS drive: ${OSDrive}:"
    Write-Host "  Scratch dir: $ScratchDir"

    foreach ($s in $enabledSteps) {
        $p = $s.parameters
        Write-Host "  [OK] Step '$($s.name)' ($($s.type)) -- enabled" -ForegroundColor Green

        # Validate step-specific parameters
        switch ($s.type) {
            'DownloadImage' {
                $url = if ($p -and $p.PSObject.Properties['imageUrl'] -and $p.imageUrl) { $p.imageUrl } else { '' }
                if (-not $url) { $warnings += "Step '$($s.name)': No imageUrl specified -- will use ESD catalog" }
            }
            'PartitionDisk' {
                try {
                    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
                    Write-Host "    Disk $DiskNumber : $($disk.FriendlyName) ($(Get-FileSizeReadable $disk.Size))" -ForegroundColor Gray
                } catch {
                    $errors += "Step '$($s.name)': Target disk $DiskNumber not found"
                }
            }
            'InjectOemDrivers' {
                try {
                    $mfr = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer
                    Write-Host "    Manufacturer: $mfr" -ForegroundColor Gray
                } catch {
                    $warnings += "Step '$($s.name)': Could not detect manufacturer"
                }
            }
            'EnableBitLocker' {
                try {
                    $tpm = Get-CimInstance -ClassName Win32_TPM -Namespace root\cimv2\Security\MicrosoftTpm -ErrorAction Stop
                    if ($tpm) { Write-Host "    TPM detected: version $($tpm.SpecVersion)" -ForegroundColor Gray }
                } catch {
                    $warnings += "Step '$($s.name)': TPM not detected -- BitLocker may fail"
                }
            }
        }
    }

    if ($warnings.Count -gt 0) {
        Write-Warn "Validation warnings:"
        $warnings | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    }
    if ($errors.Count -gt 0) {
        Write-Fail "Validation errors:"
        $errors | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "Dry-run validation failed with $($errors.Count) error(s)"
    }

    Write-Success "Dry-run validation passed -- $($enabledSteps.Count) steps validated, $($warnings.Count) warning(s)"
}

function Update-TaskSequenceFromConfig {
    <#
    .SYNOPSIS  Writes user configuration choices into the task sequence JSON.
    .DESCRIPTION
        After the user submits the configuration modal, this function updates
        the relevant step parameters in the task sequence JSON file so that
        the engine reads all values from the task sequence -- no separate
        command-line parameters needed.

        ComputerName and locale settings are also injected into the
        CustomizeOOBE step's unattendContent XML, keeping the task sequence
        as the single source of truth for unattend.xml content.
    #>
    [OutputType([void])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$TaskSequencePath,
        [hashtable]$Config
    )

    if (-not (Test-Path $TaskSequencePath)) { return }

    $raw = Get-Content $TaskSequencePath -Raw -ErrorAction Stop
    $ts  = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not (_HasProp $ts 'steps')) { return }

    foreach ($step in $ts.steps) {
        if (-not (_HasProp $step 'parameters')) {
            $step | Add-Member -NotePropertyName parameters -NotePropertyValue ([pscustomobject]@{}) -Force
        }

        switch ($step.type) {
            'DownloadImage' {
                if ($Config['Edition'])      { $step.parameters | Add-Member -NotePropertyName edition      -NotePropertyValue $Config['Edition']      -Force }
                if ($Config['OsLanguage'])   { $step.parameters | Add-Member -NotePropertyName language     -NotePropertyValue $Config['OsLanguage']   -Force }
                if ($Config['Architecture']) { $step.parameters | Add-Member -NotePropertyName architecture -NotePropertyValue $Config['Architecture'] -Force }
            }
            'ApplyImage' {
                if ($Config['Edition']) { $step.parameters | Add-Member -NotePropertyName edition -NotePropertyValue $Config['Edition'] -Force }
            }
            'SetComputerName' {
                if ($Config['ComputerName']) { $step.parameters | Add-Member -NotePropertyName computerName -NotePropertyValue $Config['ComputerName'] -Force }
            }
            'SetRegionalSettings' {
                if ($Config['InputLocale'])  { $step.parameters | Add-Member -NotePropertyName inputLocale  -NotePropertyValue $Config['InputLocale']  -Force }
                if ($Config['SystemLocale']) { $step.parameters | Add-Member -NotePropertyName systemLocale -NotePropertyValue $Config['SystemLocale'] -Force }
                if ($Config['UserLocale'])   { $step.parameters | Add-Member -NotePropertyName userLocale   -NotePropertyValue $Config['UserLocale']   -Force }
                if ($Config['UILanguage'])   { $step.parameters | Add-Member -NotePropertyName uiLanguage   -NotePropertyValue $Config['UILanguage']   -Force }
            }
            'ImportAutopilot' {
                if ($Config.ContainsKey('AutopilotGroupTag'))  { $step.parameters | Add-Member -NotePropertyName groupTag  -NotePropertyValue $Config['AutopilotGroupTag']  -Force }
                if ($Config.ContainsKey('AutopilotUserEmail')) { $step.parameters | Add-Member -NotePropertyName userEmail -NotePropertyValue $Config['AutopilotUserEmail'] -Force }
            }
        }
    }

    # ── Update unattendContent in CustomizeOOBE with ComputerName / locale ──
    # This connects the config-modal choices directly to the unattend.xml
    # stored in the task sequence so the engine writes it as-is.
    $hasUnattendChanges = $Config['ComputerName'] -or $Config['InputLocale'] -or
                          $Config['SystemLocale'] -or $Config['UserLocale'] -or
                          $Config['UILanguage']
    if ($hasUnattendChanges) {
        $oobeStep = $ts.steps | Where-Object { $_.type -eq 'CustomizeOOBE' } | Select-Object -First 1
        if ($oobeStep -and (_HasProp $oobeStep 'parameters')) {
            $src = if (_HasProp $oobeStep.parameters 'unattendSource') { $oobeStep.parameters.unattendSource } else { $null }
            if (-not $src -or $src -eq 'default') {
                $defaultXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>false</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>false</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>false</SkipMachineOOBE>
        <SkipUserOOBE>false</SkipUserOOBE>
      </OOBE>
    </component>
  </settings>
</unattend>
"@
                $xml = if ((_HasProp $oobeStep.parameters 'unattendContent') -and $oobeStep.parameters.unattendContent) { $oobeStep.parameters.unattendContent } else { $defaultXml }
                try {
                    [xml]$xd = $xml
                    $nsMgr = New-Object System.Xml.XmlNamespaceManager($xd.NameTable)
                    $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')

                    # ComputerName -> specialize pass
                    if ($Config['ComputerName']) {
                        $specSetting = $xd.SelectSingleNode('//u:settings[@pass="specialize"]', $nsMgr)
                        if (-not $specSetting) {
                            $specSetting = $xd.CreateElement('settings', 'urn:schemas-microsoft-com:unattend')
                            $specSetting.SetAttribute('pass', 'specialize')
                            $xd.DocumentElement.AppendChild($specSetting) | Out-Null
                        }
                        $shellComp = $specSetting.SelectSingleNode('u:component[@name="Microsoft-Windows-Shell-Setup"]', $nsMgr)
                        if (-not $shellComp) {
                            $shellComp = $xd.CreateElement('component', 'urn:schemas-microsoft-com:unattend')
                            $shellComp.SetAttribute('name', 'Microsoft-Windows-Shell-Setup')
                            $shellComp.SetAttribute('processorArchitecture', 'amd64')
                            $shellComp.SetAttribute('publicKeyToken', '31bf3856ad364e35')
                            $shellComp.SetAttribute('language', 'neutral')
                            $shellComp.SetAttribute('versionScope', 'nonSxS')
                            $specSetting.AppendChild($shellComp) | Out-Null
                        }
                        $cnNode = $shellComp.SelectSingleNode('u:ComputerName', $nsMgr)
                        if ($cnNode) { $cnNode.InnerText = $Config['ComputerName'] }
                        else {
                            $cnNode = $xd.CreateElement('ComputerName', 'urn:schemas-microsoft-com:unattend')
                            $cnNode.InnerText = $Config['ComputerName']
                            $shellComp.AppendChild($cnNode) | Out-Null
                        }
                    }

                    # Locale -> oobeSystem pass
                    $iL = $Config['InputLocale']; $sL = $Config['SystemLocale']
                    $uL = $Config['UserLocale'];  $uiL = $Config['UILanguage']
                    if ($iL -or $sL -or $uL -or $uiL) {
                        $oobeSetting = $xd.SelectSingleNode('//u:settings[@pass="oobeSystem"]', $nsMgr)
                        if (-not $oobeSetting) {
                            $oobeSetting = $xd.CreateElement('settings', 'urn:schemas-microsoft-com:unattend')
                            $oobeSetting.SetAttribute('pass', 'oobeSystem')
                            $xd.DocumentElement.AppendChild($oobeSetting) | Out-Null
                        }
                        $intlComp = $oobeSetting.SelectSingleNode('u:component[@name="Microsoft-Windows-International-Core"]', $nsMgr)
                        if (-not $intlComp) {
                            $intlComp = $xd.CreateElement('component', 'urn:schemas-microsoft-com:unattend')
                            $intlComp.SetAttribute('name', 'Microsoft-Windows-International-Core')
                            $intlComp.SetAttribute('processorArchitecture', 'amd64')
                            $intlComp.SetAttribute('publicKeyToken', '31bf3856ad364e35')
                            $intlComp.SetAttribute('language', 'neutral')
                            $intlComp.SetAttribute('versionScope', 'nonSxS')
                            $oobeSetting.AppendChild($intlComp) | Out-Null
                        }
                        foreach ($pair in @(
                            @('InputLocale',  $iL),
                            @('SystemLocale', $sL),
                            @('UserLocale',   $uL),
                            @('UILanguage',   $uiL)
                        )) {
                            if ($pair[1]) {
                                $node = $intlComp.SelectSingleNode("u:$($pair[0])", $nsMgr)
                                if ($node) { $node.InnerText = $pair[1] }
                                else {
                                    $node = $xd.CreateElement($pair[0], 'urn:schemas-microsoft-com:unattend')
                                    $node.InnerText = $pair[1]
                                    $intlComp.AppendChild($node) | Out-Null
                                }
                            }
                        }
                    }

                    $sw = New-Object System.IO.StringWriter
                    $xw = [System.Xml.XmlTextWriter]::new($sw)
                    $xw.Formatting = [System.Xml.Formatting]::Indented
                    $xw.Indentation = 2
                    $xd.WriteTo($xw); $xw.Flush()
                    $oobeStep.parameters | Add-Member -NotePropertyName unattendContent -NotePropertyValue $sw.ToString() -Force
                } catch {
                    Write-Warning "Could not update unattendContent from config: $_"
                }
            }
        }
    }

    if ($PSCmdlet.ShouldProcess($TaskSequencePath, 'Update task sequence with configuration')) {
        $ts | ConvertTo-Json -Depth 20 | Set-Content $TaskSequencePath -Encoding UTF8 -Force
    }
}

Export-ModuleMember -Function @(
    'Read-TaskSequence'
    'Test-StepCondition'
    'Invoke-DryRunValidation'
    'Update-TaskSequenceFromConfig'
)

# SIG # Begin signature block
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD6ODfDOQaJ3ME2
# izg614dcDTKiZzHEbI1lc3nA1jdIkqCCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# rmcxghqRMIIajQIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDQCEzMAAB/0Xwj11NaXeLQAAAAAH/QwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgpnXg4f7oVufWsRHksJ+rIpW45sDDNn3ZR/Ehh92wMwcw
# DQYJKoZIhvcNAQEBBQAEggGARLJNEet7u3fMxGDpf3qCd0Z/J0FUoHunZNOWLQWA
# gdwgNjOAeZ6hcYQz0rGBGTqegk3qMczBmLIqLwCgE2qlWEra1q7Y0HCL3GqHyKTS
# Ilw1p8TLQysm8hN1zN6dchdzOWGvUmG7x+y45/rXpkZ0JU3Rn7/wXiKEJCf8c/Dl
# A+jbPHXl2J91I++9tjGnzPo4SybzPDoPSGPOnE5C/mHz5/fnsKtD14D35FEAf0JT
# 9sulGUybRWwoqvQbNtPQ1k//lEdvPa193w9/GqJ3yN48S/kI0FfmGcKE/ZFWp8G7
# 4gbWy92tMgGpyg8Udr98re5gyBQYU6t8OepG1jNy+z29L7+n8QSuTQORtrFt0p9+
# s8eXdeor16oyCVqUKPB0muEFRsuX+t65eV6T9voDTz77cfsCkC2aOwH7+OxFmX+G
# DW7ErkB14xfjNxBsIEjHuvyRb0MbuxF6+YidW0f2gIcw3UHazg4jTmQWf1WduAak
# IQlSjwpfdB/oDL+OmI+rrGKGoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEILSo976PXDfsMFeuGuXgKFlFo5ifUsFGnPUt+oH2unH9AgZpwnLP0u8YEzIw
# MjYwNDA5MTcyOTU5LjM2NlowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RDAwLTA1RTAt
# RDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGlu
# ZyBBdXRob3JpdHmggg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAA
# BTANBgkqhkiG9w0BAQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVy
# aWZpY2F0aW9uIFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAx
# MTE5MjAzMjMxWhcNMzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBv
# f7KrQ5cMSqFSHGqg2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDs
# fMuIEqvGYOPURAH+Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbB
# T7uq3wx3mXhtVmtcCEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5
# EeH5KrlFnxpjKKTavwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6
# ovnUfANjIgM9JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fj
# JHrmlQ0EIXmp4DhDBieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOs
# RpeexIveR1MPTVf7gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiun
# hKbq0XbjkNoU5JhtYUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE
# 3oWsDqMX3jjv40e8KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8
# cIxLoKSDzCCBOu0hWdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMB
# AAGjggIbMIICFzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYD
# VR0OBBYEFGtpKDo1L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBB
# MD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0Rv
# Y3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGC
# NxQCBAweCgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTI
# ftJqhSobyhmYBAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHkl
# MjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHkl
# MjAyMDIwLmNybDCBlAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElk
# ZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0
# aG9yaXR5JTIwMjAyMC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXn
# THho+k7h2ESZJRWluLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC
# 2IWmtKMyS1OWIviwpnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5
# zyEh89F72u9UIw+IfvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbN
# nCKNZPmhzoa8PccOiQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqs
# t8S+w+RUdie8fXC1jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVm
# oNR/dSpRCxlot0i79dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRS
# SvijmwJwxRxLLpMQ/u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7v
# PKNMN+SZDWycU5ODIRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/2
# 6ozePQ/TWfNXKBOmkFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/
# AAxw9Sdgq/+rY7jjgs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSO
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFXZ3WkmKPn4
# 4gAAAAAAVTANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NDlaFw0yNjEw
# MjIyMDQ2NDlaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAvbkfkh5ZSLP0MCUWafaw/KZoVZu9iQx8
# r5JwhZvdrUi86UjCCFQONjQanrIxGF9hRGIZLQZ50gHrLC+4fpUEJff5t04VwByW
# C2/bWOuk6NmaTh9JpPZDcGzNR95QlryjfEjtl+gxj12zNPEdADPplVfzt8cYRWFB
# x/Fbfch08k6P9p7jX2q1jFPbUxWYJ+xOyGC1aKhDGY5b+8wL39v6qC0HFIx/v3y+
# bep+aEXooK8VoeWK+szfaFjXo8YTcvQ8UL4szu9HFTuZNv6vvoJ7Ju+o5aTj51sp
# h+0+FXW38TlL/rDBd5ia79jskLtOeHbDjkbljilwzegcxv9i49F05ZrS/5ELZCCY
# 1VaqO7EOLKVaxxdAO5oy1vb0Bx0ZRVX1mxFjYzay2EC051k6yGJHm58y1oe2IKRa
# /SM1+BTGse6vHNi5Q2d5ZnoR9AOAUDDwJIIqRI4rZz2MSinh11WrXTG9urF2uoyd
# 5Ve+8hxes9ABeP2PYQKlXYTAxvdaeanDTQ/vwmnM+yTcWzrVm84Z38XVFw4G7p/Z
# NZ2nscvv6uru2AevXcyV1t8ha7iWmhhgTWBNBrViuDlc3iPvOz2SVPbPeqhyY/NX
# wNZCAgc2H5pOztu6MwQxDIjte3XM/FkKBxHofS2abNT/0HG+xZtFqUJDaxgbJa6l
# N1zh7spjuQ8CAwEAAaOCAcswggHHMB0GA1UdDgQWBBRWBF8QbdwIA/DIv6nJFsrB
# 16xltjAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAFIe4ZJUe9qUKcWeWypchB58fXE/ZIWv2D5XP5/k/tB7
# LCN9BvmNSVKZ3VeclQM978wfEvuvdMQSUv6Y20boIM8DK1K1IU9cP21MG0ExiHxa
# qjrikf2qbfrXIip4Ef3v2bNYKQxCxN3Sczp1SX0H7uqK2L5OhfDEiXf15iou5hh+
# EPaaqp49czNQpJDOR/vfJghUc/qcslDPhoCZpZx8b2ODvywGQNXwqlbsmCS24uGm
# EkQ3UH5JUeN6c91yasVchS78riMrm6R9ZpAiO5pfNKMGU2MLm1A3pp098DcbFTAc
# 95Hh6Qvkh//28F/Xe2bMFb6DL7Sw0ZO95v0gv0ZTyJfxS/LCxfraeEII9FSFOKAM
# Ep1zNFSs2ue0GGjBt9yEEMUwvxq9ExFz0aZzYm8ivJfffpIVDnX/+rVRTYcxIkQy
# FYslIhYlWF9SjCw5r49qakjMRNh8W9O7aaoolSVZleQZjGt0K8JzMlyp6hp2lbW6
# XqRx2cOHbbxJDxmENzohGUziI13lI2g2Bf5qibfC4bKNRpJo9lbE8HUbY0qJiE8u
# 3SU8eDQaySPXOEhJjxRCQwwOvejYmBG5P7CckQNBSnnl12+FKRKgPoj0Mv+z5OMh
# j9z2MtpbnHLAkep0odQClEyyCG/uR5tK5rW6mZH5Oq56UWS0NI6NV1JGS7Jri6jF
# MYIHQzCCBz8CAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTANBglghkgBZQME
# AgEFAKCCBJwwEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDA5MTcyOTU5WjAvBgkqhkiG9w0B
# CQQxIgQgNIlDkU6iZkyjMclLMiLRPUe1ly0SSIGk/9U/S66aeM0wgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCDYuTyXZIZiu799/v4PaqsmeSzBxh0rqkYq7sYY
# avj+zTB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTCCA14GCyqGSIb3DQEJ
# EAISMYIDTTCCA0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0Qw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQAdO1QBgmW/tuBZV5EG
# jhfsV4cN6qBnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2CCR0wIhgPMjAyNjA0
# MDkxMTE2NDVaGA8yMDI2MDQxMDExMTY0NVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7YIJHQIBADAHAgEAAgI5STAHAgEAAgIXkTAKAgUA7YNanQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCmQByR+XzJkONpGAedVVXxRSvgki09KgTvaB9K
# raNaMgGfBJVIdTjxw1cnX+X/4nq9H8xilTSUTHOw4SeW4i6pgxLz8j+PdEmWf3Mq
# UiiudsSXBCXlDx4/U1x7LkhBtyrSX6c+PWqcKXYbTMVr3i7rgIdWWPQbJq6DRH4I
# MEcYi+ECce2vy71KlFBPhaKeYhQs4SgZeU1qeyGCu/Iq5R+D7A5BY0Nj04FRTW/u
# 82LNwDcEA/UMvtzp6un/yp1wjTAfNZA+V9SNn4/aOg8rjXA4vT/HnU/uRceo7TvY
# dcK+EbxpVnylBSwEgj93TpkAvI/fHXFlh956pjiBbNdzT1jUMA0GCSqGSIb3DQEB
# AQUABIICAFV+98k5+aOtpu1gD7HUK1/aqXCN4grsedL6YA9luI2kVJPaxtDfbn44
# za9nwWGt+QOPprbWLj3CbVKnFXyXunWpuDgcNMiVdeSX4NdcD9o9r6JANpKjBS2E
# qafGY0KmvwQueJIGntIWXCPxPsdvEYYCWXYf0rpU5faHmbCGZGoXKSuomM368+wc
# /nEV7TkfZYNX3Eikesa/9CUriI4p8V3aIO6AFik3te4wcSqbjHJKAXWIPt3ISNQF
# f7gz5PqJ/aC2IZh1SwYGr4IfEqHgAacXMHgu8ilJo7xd6+FP9V7O01+PRTqbx0Cq
# zjZOnF3zcxIsnQ0gLKT8O6nbKAf/jeaXnkiGARhbVTDCsYYt0jcuSxDvUAzOtaBd
# 3HsucNoLr/CLtILo19+2f5D9kBgomkJlUPoBr+8FYTujI8gBObXZoRxLHmPIFtLv
# CBtVmFA3L4sBk+bkpdGL5vnZ58rPPDPw0eqJFcqm7Zox47iz/7rbg2xHuJ94hEDI
# I2d4QxWr5gKuyyX2OuiDuZKLGTTmHPtX+HlYjrFpD0v3kF1FWQToqOsKt3PSiKhw
# qKiffXR39mx8nd9mEuCsuntnhsXsoN9o0ZU+NU01nMA0KpI1qDoiMuSn7AlM4iCj
# E5+1zMjhHEzMW0+eYDVGGodcm/gLpWS2xavnWAMOjLsbDrWYo0tj
# SIG # End signature block

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
# MII9dgYJKoZIhvcNAQcCoII9ZzCCPWMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAATbzZ1
# WlQRwN+WAAAAABNvMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNDA4MTQzNTAyWhcNMjYwNDEx
# MTQzNTAyWjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCaXp6ZOAqpSGDC
# lEJL0tP6AaWlljn7+Nyx7mo3psGnxvPkngIY/lD/QHTpKOndvoq4knt04gr0kkGp
# ClfAlaI1BNcS+k6W3jy/dtA6w/k456OkCkjjGLqFEHaNXKVqnzI92GP6gCmn9ov0
# +uni4oROr5At/kLAh0zyXqTNBNQ+qd1QzQ4Y+CgIXlKnGBbi0RVx21T4tDsZ8mCX
# yxvlRHdXFNtEkEmkkGxbOziPkvav6QLRnr7/tALqWOrY1WHX6T/SGbrh5OPQivvs
# w94+JUX/m2uzHV6j0qHdfe8BJyYQ3U3NAGNFSQoshMtbV721R3XEnaXBy2U1A6TH
# zixwtXxQ5zRPrU65hNPrSTzkiK+a2VOLlOGP7+es1Eq8lKFRUVvjNFW1YgWwGf3g
# P2Z+4B2uMdml126+rmdUvTyAmEBqYeLNIfGfnTa+qlD9Lno8rqTyLrcN3bv8st+7
# Au+V47C6PDqbTyb/TjZ6BsoXsJtmLZAruTlFpCINQa4bksFN3d8CAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUYsueSbGxd9TixyeW27ISjBdBHnEwHwYDVR0jBBgwFoAUa16lNMMF
# xWJKIVqOq3NgYtSsY4UwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMy5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAELukzNfojQy7MXCmtBzdvxdxKTEvjdX3Zvu+aX5sDNMsy/q8JYeQG8u
# hingdUYeqHjwOtgenn5kqnY7Kb2C7IltAr6dZGZ/l+SSZGrAD0plWX5rUfhhTLGe
# j95/4C5Jnku01cG2FXBQbMkGaY1xe/bfnK8wn931lajOBdsbfVkhmTEIdchxu6sz
# /0UVg3tlIRqiiJtQCE71iWJVNmW8IdVOXhzy0dFOmhUHVgNelCAPqdJChaQvKwTJ
# 97SYWRT33jKI0+ylRRmKmEO1a8cMPIkn6cImafpGD9pmsquet3PLuQNGDAU5FYrm
# o5sqBW/LXTspdjbfje9obnCXKgOY/JLIiGaUZYppeRTWWwwnAHcFm6v40/CGADij
# VZhC0XiGYdEuYjbM0V4btEtcOtDr18oMVLwV27rJwxCek6wfza0ojyVYk1B0HC1k
# R6UICd3Mhrok4n0OOVn9RArCK4QrJ3oGpuHLU0H80XQdeJP95K4HsVj3Ln8S5qOV
# 0u98nFEyhg39UKnJioibO4tHeLWAY+CEpI/qoTva8SBMPc292R92mEWd5ck3xFG+
# voVEjXUwh9YbxRIVg14i4DFQSABoDbNwwuZ//uAP7e1/NaYskP8jbAjcm8AEaUeh
# 1CHYMwwA3ylB0lRP/e/Awtw4mFMKOFr0B4yLykkGvtK1hFlbWMqIMIIGyTCCBLGg
# AwIBAgITMwAAE282dVpUEcDflgAAAAATbzANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMB4XDTI2MDQwODE0
# MzUwMloXDTI2MDQxMTE0MzUwMlowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAml6emTgKqUhgwpRCS9LT+gGlpZY5+/jcse5qN6bBp8bz5J4CGP5Q/0B06Sjp
# 3b6KuJJ7dOIK9JJBqQpXwJWiNQTXEvpOlt48v3bQOsP5OOejpApI4xi6hRB2jVyl
# ap8yPdhj+oApp/aL9Prp4uKETq+QLf5CwIdM8l6kzQTUPqndUM0OGPgoCF5SpxgW
# 4tEVcdtU+LQ7GfJgl8sb5UR3VxTbRJBJpJBsWzs4j5L2r+kC0Z6+/7QC6ljq2NVh
# 1+k/0hm64eTj0Ir77MPePiVF/5trsx1eo9Kh3X3vAScmEN1NzQBjRUkKLITLW1e9
# tUd1xJ2lwctlNQOkx84scLV8UOc0T61OuYTT60k85IivmtlTi5Thj+/nrNRKvJSh
# UVFb4zRVtWIFsBn94D9mfuAdrjHZpdduvq5nVL08gJhAamHizSHxn502vqpQ/S56
# PK6k8i63Dd27/LLfuwLvleOwujw6m08m/042egbKF7CbZi2QK7k5RaQiDUGuG5LB
# Td3fAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFGLLnkmxsXfU4scnltuyEowXQR5xMB8GA1Ud
# IwQYMBaAFGtepTTDBcViSiFajqtzYGLUrGOFMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDAzLmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBC7pMzX6I0MuzFwprQc3b8XcSkxL43V92b7vml
# +bAzTLMv6vCWHkBvLoYp4HVGHqh48DrYHp5+ZKp2Oym9guyJbQK+nWRmf5fkkmRq
# wA9KZVl+a1H4YUyxno/ef+AuSZ5LtNXBthVwUGzJBmmNcXv235yvMJ/d9ZWozgXb
# G31ZIZkxCHXIcburM/9FFYN7ZSEaooibUAhO9YliVTZlvCHVTl4c8tHRTpoVB1YD
# XpQgD6nSQoWkLysEyfe0mFkU994yiNPspUUZiphDtWvHDDyJJ+nCJmn6Rg/aZrKr
# nrdzy7kDRgwFORWK5qObKgVvy107KXY2343vaG5wlyoDmPySyIhmlGWKaXkU1lsM
# JwB3BZur+NPwhgA4o1WYQtF4hmHRLmI2zNFeG7RLXDrQ69fKDFS8Fdu6ycMQnpOs
# H82tKI8lWJNQdBwtZEelCAndzIa6JOJ9DjlZ/UQKwiuEKyd6Bqbhy1NB/NF0HXiT
# /eSuB7FY9y5/EuajldLvfJxRMoYN/VCpyYqImzuLR3i1gGPghKSP6qE72vEgTD3N
# vdkfdphFneXJN8RRvr6FRI11MIfWG8USFYNeIuAxUEgAaA2zcMLmf/7gD+3tfzWm
# LJD/I2wI3JvABGlHodQh2DMMAN8pQdJUT/3vwMLcOJhTCjha9AeMi8pJBr7StYRZ
# W1jKiDCCBygwggUQoAMCAQICEzMAAAAVBT5uGY6TKdkAAAAAABUwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMjhaFw0zMTAzMjYxODExMjhaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDg9Ms9AqovDnMePvMOe+KybhCd8+lokzYO
# RlS3kBVXseecbyGwBcsenlm5bLtMGPjiIFLzBQF+ghlVV/U29q5GcdeEEBCHTTGh
# L2koIrLc4UrliMRcbv9mOMtR/l7/xAmv0Fx4BJHn1dHt37fvrBqXmKjKfGf5DpyO
# /+hnV7TEreMtS19iO+bjZ/9Hnpg3PCk0e7YSbRTFkx97FZwRWpC4s3NepRfRXQh/
# WMAj7JmsYeVZohi4TF5yW2JMrJZqwHcyzJZYtD2Hlno5ZEJkdiZcEaxHOobmwO06
# Z1J9c23ps9PGIhGaq1sKLEAz9Doc5rLkYWGteDrscKhAp2kIc/oYlH9Ij6BkOqqg
# WINEkEtC8ZNG1Mak+h3o65aj0iQKmdxW7IZaHO5cuyoMi+KtYfXeIIg3sVIbS2EL
# 8kUtsDGdEqNqAq/isqTi1jXqLe6iKp1ni1SPdvPW9G03CTsYF68b/yuIQRwbdoBC
# XemMNJCS0dorCRY4b2WAAy4ng7SANcEgrBgZf535+QfLU5hGzrKjIpbMabauWb5F
# KWUKkMsPcXFkXRWO4noKPm4KWlFypqOpbJ/KONVReIlxHQRegAOBzIhRB7gr9IDQ
# 1sc2MgOgQ+xVGW4oq4HD0mfAiwiyLskZrkaQ7JoanYjBNcR9RS26YxAVbcBtLitF
# TzCIEg5ZdQIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBRrXqU0wwXFYkohWo6rc2Bi1KxjhTBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBdbiI8zwXLX8glJEh/8Q22
# UMCUhWBO46Z9FPhwOR3mdlqRVLkYOon/MczUwrjDhx3X99SPH5PSflkGoTvnO9ZW
# HM5YFVYpO7NYuB+mfVSGAGZwiGOASWk0i2B7vn9nElJJmoiXxugfH5YdBsrUgTt0
# AFNXkzmqTgk+S1Hxb1u/0HCqEHVZPk2A/6eJXYbtpRM5Fcz00jisUl9BRZgSebOD
# V85bBzOveqyC3f0PnHCxRJNhMb8xP/sB/VI7pf2rheSV7zqUSv8vn/fIMblXeaVI
# lpqoq8SP9BJMjE/CoVXJxnkZQRM1Fa7kN9yztvReOhxSgPgpZx/Xl/jkwyEFVJTB
# fBp3sTgfIc/pmqv2ehtakL2AEj78EmOPQohxJT3wyX+P78GA25tLpAvzj3RMMHd8
# z18ZuuVi+60MAzGpOASH1L8Nlr3fZRZnQO+pyye2DCvYmHaIfdUgYJqn7noxxGVv
# 89+RaETh1tgCDvwNpFCSG7vl5A4ako+2fx409r9TWjXC7Oif1IQ5ZJzB4Rf8GvBi
# HYjvMmHpledp1FGRLdSRFVpC3/OKpZY6avIqZp7+8pP/WQP903DdgrvAT6W4xPOB
# xXPa4tGksN3SuqJaiFYHSNyeBufn8iseujW4IbBSbHD4BPqbF3qZ+7nG9d/d/G2/
# Lx4kH9cCmBfmsZdSkHmukDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
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
# rmcxghqUMIIakAIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDMCEzMAABNvNnVaVBHA35YAAAAAE28wDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQgpnXg4f7oVufWsRHksJ+rIpW45sDDNn3ZR/Ehh92wMwcw
# DQYJKoZIhvcNAQEBBQAEggGAkPnWJUHxpJfZfMfmfrCmnHI0UInEkdyFi6DI/v56
# TYuKq1EVPVR+KZeib4AtjnmsTu9vFJ2xX3mA/kJ3IID/YU/OlTStV5PmbRhHOmXU
# 7G2a7vdVJntqoYja5LNbl+mzYo1eJ8apM2GEkAeCF/ioxtEg+yGiqX6hTj6sosWp
# lhbdIdkcqlKUEDeDndt4krlG+QLhw63O18Gim1DIlcSBGFD/Wvg1owGpgaUWPCL8
# MidmZ2r9NMKuhyQ3JYbqMK3LyHeYiAg1oa2CTPlHb/xFRy9sXNXmT0M/dLJbZeAW
# rlFSA/p7CRDYLMn2puA/3N6L3/ixZy/N0zB35n8Rj01wTHHqG6pStAFtg9swO7kB
# m++dZ+p7P5dUpdOFzU6SpGHurTj6PNAw5RHj+pMPRXw3GMfm1d8FMdPAfV5UN4OI
# f7CwgJxvJJ152vXlQNNwcyf16KnGmUboq//PzjrVizmL9R1FOqVsm6oOgNhqYDMJ
# VD4/Q8MxCNj22R62jXBHO8gxoYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJ
# KoZIhvcNAQcCoIIX7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIG/dMFu54tAS0e3/m4dxjrLAwiNVhfGRhBngeplVZC8aAgZp1AZ82DEYEzIw
# MjYwNDA4MjMwMzA5LjIzM1owBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAt
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
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFck05XgounJ
# MQAAAAAAVzANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTNaFw0yNjEw
# MjIyMDQ2NTNaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsWylCpMIfbizJLY1kPXO2cmX2HRWvRbA
# meKSZ5ex7/jCymdV7Eap+Ic2iqRtWDkKKe5gL6JV80wtn5C2qHJLPxUYFKNG3UkH
# kAI21MoCN+YWnhT8K/YuPib6+6970jdbeFKIiZMWwd5hnpX9J3jeteuEdXbp/DfF
# BK15JuD3JOzWuF2suQCPgqYjQPk/gpq+3KCKtXJRbXSCSJ9YtITU2IHwmfdE7l2P
# fZ154w041po+fDeTj0gJOzcV/Jv56Q0M+w19jAKo/I5PEzrLV1IPQnmP4or1X4Rb
# JXk8ONXyOOfXOxK2VLpNxgklK1yAezbFP2uzqihaXkW1h9GQLGENKESnezwgdRaL
# NNaYtm8AT/pZHYJ35mZVqkZdMIckpQHJk/F1fSLyDKeKtH4TC4cc3ESKUMgItq07
# ZZm74JCsfhmrQ1ijVNDi1Sln+QBamgC7WviZbkQnceQRq9DY+6hANwOrasAZUiVr
# 2kPuj1jHDOXzUG4O9QTK70P/oXSqZAN1oTv3UfF8JTGmAxg+l1ZPOz50MY96HBDw
# /3bI/wBGNvLk6fLVnrxGN5B5unF/lYvjjWbIUdyBPVQnPOKXu08SRHbY19M1HoWX
# 6PNZv+vzSeqVeWWHKdKjC3GjVjbbGpi+JLbiyaKRSwEqo49tJLvu69cQ7dWsbksa
# i4TURnVj2mMCAwEAAaOCAcswggHHMB0GA1UdDgQWBBSOg8leLTUOAglIZ+bjXpiD
# 7RKSpzAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAHJ1wHY86Zk5SUBDPY25d/u9YJVaaNa71uxjX4cyO/XJ
# 4uPENCSOwkRTnNogPLxTD0Fg3z4TFf/2T/0IFSxdtWVtTjhzrn+WLInzeRawUhTC
# FVrPBJKEWVshm+Ig7/nB7JbJN88+ltImBbL5kT1StBLfG6UksAcDbNSQww90CUXh
# GueBxlnSvjkAX1ohiN16y1bB2s0rvQx8Csepl2CuBefTfDrMGzW/tzNx5YaK2D8O
# WweqTWZcGlJO4YjZNI83cTrQghfHl/8AXOHj8cWL3wEFltQQs2xeRYAb3Kdnl7oI
# WKKXWaBYJY5P3QPsiC+DTMp7ejdYKTrb396f3gr+wL/Ms5/Z3vIWZPJJv18qNw40
# fUNveRnwzMQnx8dM2bGuXXQZ5y7P8aXT4HJMo349qZtn4XQwiUE/DDp++MUL0kgj
# vd/Deo7Xr371PFPPYb4TboZhjV1x9+wCHDoOpNCBt+VuXU78ytJdKzQ1Jv2cEP1F
# 9H9/wSLsMDUvWME7u9mGElOPDZPMVr8AuBEuLdbTSEdaLwsZBplzxLBcgxhZ/Cs3
# 0yBhuE3QhqT1YDZ2pa56RexPA2SasPcToT6gJgJ6E06BmZ2zQTNvWOjs5XQqHbYu
# XcoeDcwe2UaC7EDOGD8GmLE9LiqtQsuQCM7v7I2xR+sPZT2Ax/85HjIkM+3MzTK1
# MYIHRjCCB0ICAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFck05XgounJMQAAAAAAVzANBglghkgBZQME
# AgEFAKCCBJ8wEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDA4MjMwMzA5WjAvBgkqhkiG9w0B
# CQQxIgQgk/EruHGibMhDZV0Bh4mab8eCrOhIQVAgP/ximBh+j68wgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCD1PJ9ktQVuTGWIbKLO4f1VUOlUU29ARCEpDZmF
# THjbUjB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFck05XgounJMQAAAAAAVzCCA2EGCyqGSIb3DQEJ
# EAISMYIDUDCCA0yhggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046Nzgw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD9LzE5nEJRAUE2Ss3x
# aKKPXHnLw6BnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2BJ/wwIhgPMjAyNjA0
# MDgxOTE2MTJaGA8yMDI2MDQwOTE5MTYxMlowdzA9BgorBgEEAYRZCgQBMS8wLTAK
# AgUA7YEn/AIBADAKAgEAAgIC/QIB/zAHAgEAAgISmDAKAgUA7YJ5fAIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQCaU9sLpKPCkwsmMUT0fVyGt+exU7CAIq+e
# /W4NTFGn/IbYVfLXogLjXxR1CRX4ANhrvwijQWf3/Zibxea2DPbTQMwCQbWOuJPc
# iftizmbc8OvVFh1xon6yZ4ScLbOLLMu2I8FwLTTHTYoa8ojlqvZzGG9sf869P0WI
# 5C+JI+lRgfuv7L9nkmcmdrN8MqUNY+X236XLuYRdbcrc/QoTnX71H2r6ggtzTjTg
# lWKGQbFnxV6ILpzsE6j+YF/YEFZiFODzaMxZhk/M5FM3LU5DRY9I/q5IYWfwUQVX
# OPgI128PeRlyDYlCPTRG7kw5VskLtY6ef2c0uPnY3ahhQFC/h39LMA0GCSqGSIb3
# DQEBAQUABIICABVkMrpwC1xuX5Bu/LeiYqz7YdhwHQd0vZSexV3Hm0eaNYklTaFx
# 9ojIN/4EYjS4BkxN3nl+lPNuTFoteGjLJe0sNl/CYwINq4gNvhSFbITn8K9ecJKH
# ZmJ6p6leWvWocaEkBrIx99+jaPpSfyPb/7J8/4MC64CoaHE5OjfxHUlHtBQflICG
# nsfuC4ufeloe/MleQLNLn5ASXEgXGyc8qv1FO6IFuqLZqHlF37f4SSCzFUDXEGwG
# EPbgmOrv2jFAQfjf+p1P4DROBt1Ugoq/KEMMgWxRwMy6XANgRwcFgq918dqi9ywa
# ED/USRoWsqP8CLFgQZs6lDf8s8vRxLukG5Vk3u3JrYjn9/6mSh4kFeh2A//N55bD
# HtqQQnnhIlHBGvgUIF89LY0S7G/g5gfttmAG4plOBQuwUNw+9weVg87YyPGQ/gTh
# tJtadO5JpiQ5X7YJlOidhwmNP4nTk4oona/2wufxtmb44djBf9plJjLKVLgmlGZO
# 1bkAFcU8THhSUIorByAvODuXQX1HC/wxf9wAsWB51Bcd1K0jvoTjzOfYvdYrkYQc
# I+pznMJECg3Awk5PTFJqB+ra+rWK2xuqzL60Q59e8q0ZNfsKP6Hgj3oF4a4hIWew
# hVADTK1gTf/0eaXBZHkNmwGNfb1qcMXCpG5naKhZpcaw0UJ8VhvxfXO2
# SIG # End signature block

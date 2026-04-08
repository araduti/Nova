<#
.SYNOPSIS
    Task sequence parsing, condition evaluation, and validation module for Nova.

.DESCRIPTION
    Provides functions for loading task sequence JSON files, evaluating
    step conditions (variable, WMI, registry), and performing dry-run
    validation of deployment configurations.
#>

function Read-TaskSequence {
    <#
    .SYNOPSIS  Loads a task sequence JSON file produced by the web-based Editor.
    .DESCRIPTION
        Reads the JSON file, validates the required structure (name + steps array),
        and returns a hashtable matching the schema in resources/task-sequence/default.json.
    #>
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

    if (-not $ts.steps -or $ts.steps -isnot [System.Collections.IEnumerable]) {
        throw "Invalid task sequence file: missing 'steps' array"
    }
    foreach ($s in $ts.steps) {
        if (-not $s.type) { throw "Invalid task sequence: step '$($s.name)' is missing required 'type' property" }
        if (-not $s.name) { throw "Invalid task sequence: a step with type '$($s.type)' is missing required 'name' property" }
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
    [CmdletBinding()]
    param(
        [psobject]$Condition
    )

    if (-not $Condition -or -not $Condition.type) { return $true }

    switch ($Condition.type) {
        'variable' {
            $varName = $Condition.variable
            if (-not $varName) { return $true }
            $actual = [System.Environment]::GetEnvironmentVariable($varName)
            $op = if ($Condition.operator) { $Condition.operator } else { 'equals' }
            $expected = if ($Condition.value) { $Condition.value } else { '' }

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
            $query = $Condition.query
            if (-not $query) { return $true }
            $ns = if ($Condition.namespace) { $Condition.namespace } else { 'root\cimv2' }
            try {
                $results = Get-CimInstance -Query $query -Namespace $ns -ErrorAction Stop
                return ($null -ne $results -and @($results).Count -gt 0)
            } catch {
                Write-Warn "WMI condition query failed: $_"
                return $false
            }
        }
        'registry' {
            $regPath = $Condition.registryPath
            if (-not $regPath) { return $true }
            $regValue = $Condition.registryValue
            $op = if ($Condition.operator) { $Condition.operator } else { 'exists' }
            $expected = if ($Condition.value) { $Condition.value } else { '' }

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
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$TaskSequencePath,
        [hashtable]$Config
    )

    if (-not (Test-Path $TaskSequencePath)) { return }

    $raw = Get-Content $TaskSequencePath -Raw -ErrorAction Stop
    $ts  = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $ts.steps) { return }

    foreach ($step in $ts.steps) {
        if (-not $step.parameters) {
            $step | Add-Member -NotePropertyName parameters -NotePropertyValue ([pscustomobject]@{}) -Force
        }

        switch ($step.type) {
            'DownloadImage' {
                if ($Config.Edition)      { $step.parameters | Add-Member -NotePropertyName edition      -NotePropertyValue $Config.Edition      -Force }
                if ($Config.OsLanguage)   { $step.parameters | Add-Member -NotePropertyName language     -NotePropertyValue $Config.OsLanguage   -Force }
                if ($Config.Architecture) { $step.parameters | Add-Member -NotePropertyName architecture -NotePropertyValue $Config.Architecture -Force }
            }
            'ApplyImage' {
                if ($Config.Edition) { $step.parameters | Add-Member -NotePropertyName edition -NotePropertyValue $Config.Edition -Force }
            }
            'SetComputerName' {
                if ($Config.ComputerName) { $step.parameters | Add-Member -NotePropertyName computerName -NotePropertyValue $Config.ComputerName -Force }
            }
            'SetRegionalSettings' {
                if ($Config.InputLocale)  { $step.parameters | Add-Member -NotePropertyName inputLocale  -NotePropertyValue $Config.InputLocale  -Force }
                if ($Config.SystemLocale) { $step.parameters | Add-Member -NotePropertyName systemLocale -NotePropertyValue $Config.SystemLocale -Force }
                if ($Config.UserLocale)   { $step.parameters | Add-Member -NotePropertyName userLocale   -NotePropertyValue $Config.UserLocale   -Force }
                if ($Config.UILanguage)   { $step.parameters | Add-Member -NotePropertyName uiLanguage   -NotePropertyValue $Config.UILanguage   -Force }
            }
            'ImportAutopilot' {
                if ($Config.ContainsKey('AutopilotGroupTag'))  { $step.parameters | Add-Member -NotePropertyName groupTag  -NotePropertyValue $Config.AutopilotGroupTag  -Force }
                if ($Config.ContainsKey('AutopilotUserEmail')) { $step.parameters | Add-Member -NotePropertyName userEmail -NotePropertyValue $Config.AutopilotUserEmail -Force }
            }
        }
    }

    # ── Update unattendContent in CustomizeOOBE with ComputerName / locale ──
    # This connects the config-modal choices directly to the unattend.xml
    # stored in the task sequence so the engine writes it as-is.
    $hasUnattendChanges = $Config.ComputerName -or $Config.InputLocale -or
                          $Config.SystemLocale -or $Config.UserLocale -or
                          $Config.UILanguage
    if ($hasUnattendChanges) {
        $oobeStep = $ts.steps | Where-Object { $_.type -eq 'CustomizeOOBE' } | Select-Object -First 1
        if ($oobeStep -and $oobeStep.parameters) {
            $src = $oobeStep.parameters.unattendSource
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
                $xml = if ($oobeStep.parameters.unattendContent) { $oobeStep.parameters.unattendContent } else { $defaultXml }
                try {
                    [xml]$xd = $xml
                    $nsMgr = New-Object System.Xml.XmlNamespaceManager($xd.NameTable)
                    $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')

                    # ComputerName -> specialize pass
                    if ($Config.ComputerName) {
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
                        if ($cnNode) { $cnNode.InnerText = $Config.ComputerName }
                        else {
                            $cnNode = $xd.CreateElement('ComputerName', 'urn:schemas-microsoft-com:unattend')
                            $cnNode.InnerText = $Config.ComputerName
                            $shellComp.AppendChild($cnNode) | Out-Null
                        }
                    }

                    # Locale -> oobeSystem pass
                    $iL = $Config.InputLocale; $sL = $Config.SystemLocale
                    $uL = $Config.UserLocale;  $uiL = $Config.UILanguage
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

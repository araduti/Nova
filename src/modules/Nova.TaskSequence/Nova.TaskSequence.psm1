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

Export-ModuleMember -Function @(
    'Read-TaskSequence'
    'Test-StepCondition'
    'Invoke-DryRunValidation'
)

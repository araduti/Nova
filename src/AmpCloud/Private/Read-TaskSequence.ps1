function Read-TaskSequence {
    <#
    .SYNOPSIS  Loads a task sequence JSON file produced by the web-based Editor.
    .DESCRIPTION
        Reads the JSON file, validates the required structure (name + steps array),
        and returns a hashtable matching the schema in TaskSequence/default.json.
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
    Write-Success "Loaded task sequence '$($ts.name)' with $($ts.steps.Count) steps"
    return $ts
}

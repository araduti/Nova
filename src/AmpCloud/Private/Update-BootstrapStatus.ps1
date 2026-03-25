function Update-BootstrapStatus {
    <#
    .SYNOPSIS  Writes live progress to a JSON file for Bootstrap.ps1 to display.
    .DESCRIPTION
        Bootstrap.ps1 polls $StatusFile every ~650 ms and updates its WinForms UI
        with the message, progress percentage, and step number.  When imaging is
        done, set -Done to signal the spinner to stop.
    #>
    param(
        [string]$Message  = '',
        [string]$Detail   = '',
        [int]$Progress    = 0,
        [int]$Step        = 0,
        [switch]$Done
    )
    # No-op when StatusFile is empty (disables IPC reporting by design).
    if (-not $StatusFile) { return }
    try {
        $obj = @{ Message = $Message; Detail = $Detail; Progress = $Progress; Step = $Step; Done = [bool]$Done }
        $obj | ConvertTo-Json -Compress | Set-Content -Path $StatusFile -Force -ErrorAction SilentlyContinue
    } catch { Write-Verbose "Status update suppressed: $_" }
}

function Write-Step {
    <#
    .SYNOPSIS  Write a step message to the console.
    .PARAMETER Message  The message text.
    .PARAMETER Prefix   Optional prefix (default: '[AmpCloud]').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Prefix = '[AmpCloud]'
    )
    Write-Host "`n$Prefix $Message" -ForegroundColor Cyan
}

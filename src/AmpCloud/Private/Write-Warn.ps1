function Write-Warn {
    <#
    .SYNOPSIS  Write a warning message to the console.
    .PARAMETER Message  The message text.
    .PARAMETER Prefix   Optional prefix (default: '[WARN]').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Prefix = '[WARN]'
    )
    Write-Host "$Prefix $Message" -ForegroundColor Yellow
}

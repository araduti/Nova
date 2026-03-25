function Write-Success {
    <#
    .SYNOPSIS  Write a success message to the console.
    .PARAMETER Message  The message text.
    .PARAMETER Prefix   Optional prefix (default: '[OK]').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Prefix = '[OK]'
    )
    Write-Host "$Prefix $Message" -ForegroundColor Green
}

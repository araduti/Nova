function Write-Fail {
    <#
    .SYNOPSIS  Write a failure message to the console.
    .PARAMETER Message  The message text.
    .PARAMETER Prefix   Optional prefix (default: '[FAIL]').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Prefix = '[FAIL]'
    )
    Write-Host "$Prefix $Message" -ForegroundColor Red
}

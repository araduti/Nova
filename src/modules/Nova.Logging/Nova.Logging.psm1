<#
.SYNOPSIS
    Shared logging module for Nova scripts.

.DESCRIPTION
    Provides colour-coded console output functions used by Nova.ps1, Bootstrap.ps1,
    and Trigger.ps1.  Prefixes are configurable via Set-NovaLogPrefix so each
    script can retain its own visual identity while sharing a single implementation.

    Default prefixes (Trigger style):
        Write-Step    →  "  [>] …"   Cyan
        Write-Success →  "  [+] …"   Green
        Write-Warn    →  "  [!] …"   Yellow
        Write-Fail    →  "  [X] …"   Red
#>

# ── Module-scoped prefix variables ──────────────────────────────────────────
$script:StepPrefix    = '  [>]'
$script:SuccessPrefix = '  [+]'
$script:WarnPrefix    = '  [!]'
$script:FailPrefix    = '  [X]'

function Set-NovaLogPrefix {
    <#
    .SYNOPSIS  Configures the message prefix used by Write-Step / Success / Warn / Fail.
    .PARAMETER Step     Prefix for Write-Step (informational progress).
    .PARAMETER Success  Prefix for Write-Success (completion).
    .PARAMETER Warn     Prefix for Write-Warn (non-fatal warning).
    .PARAMETER Fail     Prefix for Write-Fail (error).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Setting in-memory module state only — no system side-effects')]
    [CmdletBinding()]
    param(
        [string]$Step,
        [string]$Success,
        [string]$Warn,
        [string]$Fail
    )
    if ($PSBoundParameters.ContainsKey('Step'))    { $script:StepPrefix    = $Step    }
    if ($PSBoundParameters.ContainsKey('Success')) { $script:SuccessPrefix = $Success }
    if ($PSBoundParameters.ContainsKey('Warn'))    { $script:WarnPrefix    = $Warn    }
    if ($PSBoundParameters.ContainsKey('Fail'))    { $script:FailPrefix    = $Fail    }
}

function Write-Step {
    <#
    .SYNOPSIS  Writes a cyan progress message to the console.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    param([string]$Message)
    Write-Host "`n$($script:StepPrefix) $Message" -ForegroundColor Cyan
}

function Write-Success {
    <#
    .SYNOPSIS  Writes a green success message to the console.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    param([string]$Message)
    Write-Host "$($script:SuccessPrefix) $Message" -ForegroundColor Green
}

function Write-Warn {
    <#
    .SYNOPSIS  Writes a yellow warning message to the console.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    param([string]$Message)
    Write-Host "$($script:WarnPrefix) $Message" -ForegroundColor Yellow
}

function Write-Fail {
    <#
    .SYNOPSIS  Writes a red error message to the console.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    param([string]$Message)
    Write-Host "$($script:FailPrefix) $Message" -ForegroundColor Red
}

Export-ModuleMember -Function Set-NovaLogPrefix, Write-Step, Write-Success, Write-Warn, Write-Fail

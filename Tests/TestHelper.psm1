<#
.SYNOPSIS
    Test helper module — imports function definitions from a script file
    without executing the script body.

.DESCRIPTION
    Uses the PowerShell AST parser to extract all function definitions from a
    .ps1 script and defines them in the caller's scope.  This allows Pester
    tests to exercise individual functions without triggering the full script
    execution (which may depend on WinPE, administrative privileges, or
    external services).
#>

function Import-ScriptFunctions {
    <#
    .SYNOPSIS  Imports all function definitions from a .ps1 script.
    .PARAMETER Path  Full path to the script file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Imports multiple function definitions from a script file')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Script not found: $Path"
    }

    $content = Get-Content $Path -Raw
    $tokens  = $null
    $errors  = $null
    $ast     = [System.Management.Automation.Language.Parser]::ParseInput(
        $content, [ref]$tokens, [ref]$errors
    )

    # Find every top-level function definition
    $functions = $ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $false   # $false = do not recurse into nested functions
    )

    foreach ($fn in $functions) {
        # Define the function in the global scope so Pester tests can access it.
        # Use GetScriptBlock() to get the function body without enclosing braces.
        Set-Item -Path "Function:global:$($fn.Name)" -Value $fn.Body.GetScriptBlock()
    }
}

Export-ModuleMember -Function Import-ScriptFunctions

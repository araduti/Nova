function Assert-ADKInstalled {
    <#
    .SYNOPSIS Ensures ADK + WinPE add-on are present. Installs them silently if not.
    .PARAMETER Architecture  WinPE arch string (amd64 or x86). ARM is not supported.
    .OUTPUTS  [string] Validated ADK root path.
    #>
    param([string] $Architecture)

    Write-Step "Checking Windows ADK + WinPE add-on ($Architecture)..."

    $adkRoot  = Get-ADKRoot
    $winPEDir = if ($adkRoot) {
        Join-Path $adkRoot 'Assessment and Deployment Kit\Windows Preinstallation Environment'
    } else { $null }

    if ($adkRoot -and $winPEDir -and (Test-Path (Join-Path $winPEDir $Architecture))) {
        Write-Success "ADK found: $adkRoot"
        return $adkRoot
    }

    Write-Warn 'ADK or WinPE add-on not found — downloading installers...'

    $installRoot = "${env:ProgramFiles(x86)}\Windows Kits\10"
    $downloads   = @(
        [pscustomobject]@{
            Label = 'ADK (Deployment Tools)'
            Uri   = 'https://go.microsoft.com/fwlink/?linkid=2196127'
            Out   = (Join-Path $env:TEMP 'adksetup.exe')
            Args  = "/quiet /installpath `"$installRoot`" /features OptionId.DeploymentTools"
        }
        [pscustomobject]@{
            Label = 'WinPE add-on'
            Uri   = 'https://go.microsoft.com/fwlink/?linkid=2196224'
            Out   = (Join-Path $env:TEMP 'adkwinpesetup.exe')
            Args  = "/quiet /installpath `"$installRoot`" /features OptionId.WindowsPreinstallationEnvironment"
        }
    )

    foreach ($d in $downloads) {
        Write-Step "Downloading $($d.Label)..."
        Invoke-WebRequest -Uri $d.Uri -OutFile $d.Out -UseBasicParsing
    }

    foreach ($d in $downloads) {
        Write-Step "Installing $($d.Label)..."
        $proc = Start-Process -FilePath $d.Out -ArgumentList $d.Args -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -notin 0, 3010) {
            throw "$($d.Label) installer exited with code $($proc.ExitCode)."
        }
    }

    $adkRoot = Get-ADKRoot
    if (-not $adkRoot) {
        throw 'ADK installation succeeded but registry path was not found. Try running again.'
    }

    Write-Success "ADK installed: $adkRoot"
    return $adkRoot
}

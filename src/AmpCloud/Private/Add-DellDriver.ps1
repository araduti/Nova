function Add-DellDriver {
    <#
    .SYNOPSIS
        Downloads and injects the latest Dell drivers using Dell Command | Update.
    #>
    param(
        [string]$OSDriveLetter,
        [string]$ScratchDir
    )
    Write-Step 'Fetching Dell drivers via Dell Command | Update (DCU)...'

    $stepName = ''
    try {
        $stepName = 'Install DellCommandUpdate module'
        Install-OemModule -Name 'DellCommandUpdate'
        $stepName = 'Import DellCommandUpdate module'
        Import-Module DellCommandUpdate -ErrorAction Stop

        $stepName = 'Invoke-DCUUpdate'
        $driverTemp = Join-Path $ScratchDir 'Dell-Drivers'
        $null = New-Item -ItemType Directory -Path $driverTemp -Force

        # Download applicable driver updates without applying them to the live OS.
        Invoke-DCUUpdate -UpdateType driver -DownloadPath $driverTemp -ApplyUpdates:$false

        $stepName = 'Inject Dell drivers'
        $infFiles = Get-ChildItem $driverTemp -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
        if (-not $infFiles) {
            Write-Warn 'Dell Command | Update found no driver packages to inject.'
            return
        }

        Write-Host "  Injecting $($infFiles.Count) Dell driver(s) into ${OSDriveLetter}:\..."
        $null = Add-WindowsDriver -Path "${OSDriveLetter}:\" -Driver $driverTemp -Recurse `
            -ErrorAction Continue
        Write-Success 'Dell drivers injected successfully.'
    } catch {
        throw "Add-DellDriver failed at step '$stepName': $_"
    }
}

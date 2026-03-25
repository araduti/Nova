function Show-Failure {
    Invoke-Sound 400 600
    Write-Status "Could not connect to the internet.`nPlease check your network." 'Red'
    $btnRetry.Visible = $true
    $btnRetry.Add_Click({
        $btnRetry.Visible = $false
        $hasInternet = Test-InternetConnectivity
        if ($hasInternet) {
            Start-AmpCloudEngineProcess
        } else {
            # Close the form; the -NoExit PowerShell host from
            # ampcloud-start.cmd provides the interactive prompt.
            $form.Close()
        }
    })
}

function Start-WlanService {
    if (-not (Get-Service -Name wlansvc -ErrorAction SilentlyContinue)) { return $false }
    if ((Get-Service wlansvc).Status -ne 'Running') {
        Start-Service wlansvc -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    return $true
}

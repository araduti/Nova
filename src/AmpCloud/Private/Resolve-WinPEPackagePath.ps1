function Resolve-WinPEPackagePath {
    <#
    .SYNOPSIS  Expands package names + language into the ordered cab-path list that
               Add-WindowsPackage expects (base cab first, then its language pack).
    #>
    param(
        [string[]] $PackageNames,
        [string]   $Language
    )
    $paths = @()
    foreach ($name in $PackageNames) {
        $paths += "$name.cab"
        $paths += "$Language\${name}_$Language.cab"
    }
    return $paths
}

<#
.SYNOPSIS
    File integrity verification module for Nova scripts.

.DESCRIPTION
    Provides SHA256 hash verification against config/hashes.json.
    Used by Trigger.ps1, Bootstrap.ps1, and Nova.ps1 to verify
    downloaded files have not been corrupted or tampered with.
#>

Set-StrictMode -Version Latest

function Confirm-FileIntegrity {
    <#
    .SYNOPSIS  Verifies a downloaded file against its expected SHA256 hash.
    .DESCRIPTION
        Compares the SHA256 hash of the specified local file against the expected
        value from the hash manifest (config/hashes.json).  On mismatch the file
        is deleted and an exception is thrown.  If the manifest cannot be loaded
        or the file has no hash entry, the check fails closed (throws) to prevent
        execution of unverified code.

        When RetryOnMismatch is set and the hash does not match, the function
        waits RetryDelaySeconds then re-downloads the manifest and re-checks
        once.  This handles CDN propagation delays where the file and manifest
        are updated non-atomically on raw.githubusercontent.com.

        SECURITY NOTE -- The manifest is fetched from the same GitHub repository
        and branch as the scripts themselves.  This means integrity verification
        detects accidental corruption and CDN/cache inconsistencies, but it does
        NOT protect against a compromised repository (an attacker who can modify
        the scripts can also update hashes.json).  For true tamper protection,
        the manifest would need to be cryptographically signed with a key held
        outside the repository, or hosted on a separate trust boundary.

    .PARAMETER Path         Local path of the file to verify.
    .PARAMETER RelativeName Repository-relative filename as it appears in hashes.json
                            (e.g. 'Bootstrap.ps1', 'Nova.ps1').
    .PARAMETER HashesJson   Optionally pass a pre-loaded hashes object to avoid
                            re-downloading the manifest for every file.
    .PARAMETER RetryOnMismatch  When set, re-downloads the manifest after a
                                delay and retries the check once.
    .PARAMETER RetryDelaySeconds  Seconds to wait before the retry (default 5).
    .PARAMETER NoCacheHeaders     Headers hashtable for cache-busting CDN requests.
    .PARAMETER GitHubUser   GitHub account that hosts the Nova repository.
    .PARAMETER GitHubRepo   Repository name.
    .PARAMETER GitHubBranch Branch to fetch the hash manifest from.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$RelativeName,

        [psobject]$HashesJson,

        [switch]$RetryOnMismatch,

        [ValidateRange(1, 60)]
        [int]$RetryDelaySeconds = 5,

        [hashtable]$NoCacheHeaders,

        [string]$GitHubUser = 'araduti',
        [string]$GitHubRepo = 'Nova',
        [string]$GitHubBranch = 'main'
    )

    if (-not (Test-Path $Path)) {
        throw "File not found for integrity check: $Path"
    }

    $hashesUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/config/hashes.json"
    $restParams = @{ Uri = $hashesUrl; UseBasicParsing = $true; ErrorAction = 'Stop'; TimeoutSec = 15 }
    if ($NoCacheHeaders) { $restParams['Headers'] = $NoCacheHeaders }

    # Load manifest if not supplied -- fail closed if unavailable
    if (-not $HashesJson) {
        try {
            $HashesJson = Invoke-RestMethod @restParams
        } catch {
            Remove-Item $Path -Force -ErrorAction SilentlyContinue
            throw "Integrity check FAILED for $RelativeName -- could not load hash manifest ($hashesUrl): $_"
        }
    }

    $filesObj = $HashesJson.files
    $expected = if ($filesObj.PSObject.Properties[$RelativeName]) { $filesObj.$RelativeName } else { $null }
    if (-not $expected) {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
        throw "Integrity check FAILED for $RelativeName -- no hash entry found in manifest. " +
              "Ensure config/hashes.json contains an entry for '$RelativeName'."
    }

    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($actual -ne $expected) {
        if ($RetryOnMismatch) {
            Write-Warn "Hash mismatch for $RelativeName -- retrying in ${RetryDelaySeconds}s (CDN propagation window)..."
            Start-Sleep -Seconds $RetryDelaySeconds
            # Re-download manifest to get potentially updated hashes
            try {
                $HashesJson = Invoke-RestMethod @restParams
            } catch {
                Remove-Item $Path -Force -ErrorAction SilentlyContinue
                throw "Integrity check FAILED for $RelativeName -- could not reload hash manifest on retry ($hashesUrl): $_"
            }
            $filesObj  = $HashesJson.files
            $expected  = if ($filesObj.PSObject.Properties[$RelativeName]) { $filesObj.$RelativeName } else { $null }
            if (-not $expected) {
                Remove-Item $Path -Force -ErrorAction SilentlyContinue
                throw "Integrity check FAILED for $RelativeName -- no hash entry found in manifest after retry."
            }
            $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
            if ($actual -ne $expected) {
                Remove-Item $Path -Force -ErrorAction SilentlyContinue
                throw ("Integrity check FAILED for {0} (after retry)`n  Expected: {1}`n  Actual:   {2}`n" -f $RelativeName, $expected, $actual) +
                      "The file has been removed. This may indicate the manifest is out of date or the download was tampered with."
            }
            Write-Success "Integrity verified on retry: $RelativeName (SHA256 match)"
            return
        }
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
        throw ("Integrity check FAILED for {0}`n  Expected: {1}`n  Actual:   {2}`n" -f $RelativeName, $expected, $actual) +
              "The file has been removed. This may indicate the manifest is out of date or the download was tampered with."
    }

    Write-Success "Integrity verified: $RelativeName (SHA256 match)"
}

Export-ModuleMember -Function Confirm-FileIntegrity

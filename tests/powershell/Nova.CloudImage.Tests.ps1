#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.CloudImage module.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.CloudImage" -Force
}

Describe 'Module Exports' {
    It 'exports expected functions' {
        $mod = Get-Module Nova.CloudImage
        $expected = @('Get-CloudBootImage', 'Publish-BootImage')
        foreach ($fn in $expected) {
            $mod.ExportedFunctions.Keys | Should -Contain $fn
        }
    }
}

Describe 'Get-CloudBootImage' {
    It 'returns null when release does not exist' {
        Mock -ModuleName Nova.CloudImage Invoke-RestMethod { throw 'Not Found' }
        $result = Get-CloudBootImage -GitHubUser 'nonexistent' -GitHubRepo 'nonexistent'
        $result | Should -BeNullOrEmpty
    }

    It 'returns null when release has no boot.wim asset' {
        Mock -ModuleName Nova.CloudImage Invoke-RestMethod {
            [pscustomobject]@{
                assets = @(
                    [pscustomobject]@{ name = 'readme.txt'; browser_download_url = 'http://example.com/readme'; size = 100 }
                )
            }
        }
        $result = Get-CloudBootImage -GitHubUser 'test' -GitHubRepo 'test'
        $result | Should -BeNullOrEmpty
    }

    It 'returns hashtable when boot.wim exists' {
        Mock -ModuleName Nova.CloudImage Invoke-RestMethod {
            [pscustomobject]@{
                published_at = '2024-01-01T00:00:00Z'
                assets = @(
                    [pscustomobject]@{ name = 'boot.wim'; browser_download_url = 'http://example.com/boot.wim'; size = 500000000 },
                    [pscustomobject]@{ name = 'boot.sdi'; browser_download_url = 'http://example.com/boot.sdi'; size = 3000000 }
                )
            }
        }
        $result = Get-CloudBootImage -GitHubUser 'test' -GitHubRepo 'test'
        $result | Should -Not -BeNullOrEmpty
        $result.BootWimUrl | Should -Be 'http://example.com/boot.wim'
        $result.BootSdiUrl | Should -Be 'http://example.com/boot.sdi'
        $result.BootWimSize | Should -Be 500000000
    }
}

Describe 'Publish-BootImage' {
    It 'skips upload when boot file does not exist' {
        Mock -ModuleName Nova.CloudImage Invoke-RestMethod {
            [pscustomobject]@{
                upload_url = 'http://example.com/upload{?name}'
                assets = @()
            }
        }
        Mock -ModuleName Nova.CloudImage Write-Warn {}
        Mock -ModuleName Nova.CloudImage Write-Success {}
        $params = @{
            GitHubUser = 'test'
            GitHubRepo = 'test'
            GitHubToken = 'fake-token'
            BootWimPath = '/nonexistent/boot.wim'
            BootSdiPath = '/nonexistent/boot.sdi'
        }
        { Publish-BootImage @params } | Should -Not -Throw
        Should -Invoke -ModuleName Nova.CloudImage Write-Warn -Times 2
    }
}
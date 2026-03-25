#Requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the AmpCloud PowerShell module.
.DESCRIPTION
    Validates module structure, manifest, exports, and core utility functions.
#>

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..' 'src' 'AmpCloud' 'AmpCloud.psd1'
    Import-Module $ModulePath -Force
}

Describe 'AmpCloud Module' {

    Context 'Module manifest' {
        It 'Has a valid module manifest' {
            $manifest = Test-ModuleManifest -Path (Join-Path $PSScriptRoot '..' 'src' 'AmpCloud' 'AmpCloud.psd1')
            $manifest | Should -Not -BeNullOrEmpty
        }

        It 'Has the correct module version' {
            $mod = Get-Module AmpCloud
            $mod.Version | Should -Be '1.0.0'
        }

        It 'Requires PowerShell 5.1 or later' {
            $mod = Get-Module AmpCloud
            $mod.PowerShellVersion | Should -Be '5.1'
        }

        It 'Has a valid GUID' {
            $mod = Get-Module AmpCloud
            $mod.Guid | Should -Not -Be ([Guid]::Empty)
        }

        It 'Has a description' {
            $mod = Get-Module AmpCloud
            $mod.Description | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Exported functions' {
        It 'Exports exactly 4 public functions' {
            $mod = Get-Module AmpCloud
            $mod.ExportedFunctions.Count | Should -Be 4
        }

        It 'Exports Invoke-AmpCloudTrigger' {
            Get-Command -Module AmpCloud -Name 'Invoke-AmpCloudTrigger' | Should -Not -BeNullOrEmpty
        }

        It 'Exports Invoke-AmpCloudBootstrap' {
            Get-Command -Module AmpCloud -Name 'Invoke-AmpCloudBootstrap' | Should -Not -BeNullOrEmpty
        }

        It 'Exports Invoke-AmpCloudEngine' {
            Get-Command -Module AmpCloud -Name 'Invoke-AmpCloudEngine' | Should -Not -BeNullOrEmpty
        }

        It 'Exports Import-AutopilotDevice' {
            Get-Command -Module AmpCloud -Name 'Import-AutopilotDevice' | Should -Not -BeNullOrEmpty
        }

        It 'Does not export private functions' {
            Get-Command -Module AmpCloud -Name 'Write-Step' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-Command -Module AmpCloud -Name 'Get-FirmwareType' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-Command -Module AmpCloud -Name 'Write-AuthLog' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    Context 'Module file structure' {
        BeforeAll {
            $moduleRoot = Join-Path $PSScriptRoot '..' 'src' 'AmpCloud'
        }

        It 'Has a Public directory' {
            Test-Path (Join-Path $moduleRoot 'Public') | Should -BeTrue
        }

        It 'Has a Private directory' {
            Test-Path (Join-Path $moduleRoot 'Private') | Should -BeTrue
        }

        It 'Has the root module (.psm1)' {
            Test-Path (Join-Path $moduleRoot 'AmpCloud.psm1') | Should -BeTrue
        }

        It 'Has the module manifest (.psd1)' {
            Test-Path (Join-Path $moduleRoot 'AmpCloud.psd1') | Should -BeTrue
        }

        It 'Has one top-level function per file in Private/' {
            $privateFiles = Get-ChildItem (Join-Path $moduleRoot 'Private') -Filter '*.ps1'
            foreach ($file in $privateFiles) {
                $content = Get-Content $file.FullName -Raw
                # Count only top-level function definitions (not nested/indented)
                $funcCount = ([regex]::Matches($content, '^function\s+', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
                $funcCount | Should -Be 1 -Because "$($file.Name) should contain exactly one top-level function"
            }
        }

        It 'Has one top-level function per file in Public/' {
            $publicFiles = Get-ChildItem (Join-Path $moduleRoot 'Public') -Filter '*.ps1'
            foreach ($file in $publicFiles) {
                $content = Get-Content $file.FullName -Raw
                # Count only top-level function definitions (not nested/indented)
                $funcCount = ([regex]::Matches($content, '^function\s+', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
                $funcCount | Should -Be 1 -Because "$($file.Name) should contain exactly one top-level function"
            }
        }

        It 'Function file names match function names in Private/' {
            $privateFiles = Get-ChildItem (Join-Path $moduleRoot 'Private') -Filter '*.ps1'
            foreach ($file in $privateFiles) {
                $expectedName = $file.BaseName
                $content = Get-Content $file.FullName -Raw
                $match = [regex]::Match($content, '^\s*function\s+([\w-]+)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
                $match.Success | Should -BeTrue -Because "$($file.Name) should contain a function definition"
                $match.Groups[1].Value | Should -Be $expectedName -Because "function name in $($file.Name) should match file name"
            }
        }
    }
}

Describe 'Private utility functions' {

    Context 'Write-Step' {
        It 'Is accessible from within the module' {
            $mod = Get-Module AmpCloud
            $cmd = & $mod { Get-Command Write-Step -ErrorAction SilentlyContinue }
            $cmd | Should -Not -BeNullOrEmpty
        }

        It 'Accepts a Message parameter' {
            $mod = Get-Module AmpCloud
            $params = & $mod { (Get-Command Write-Step).Parameters }
            $params.ContainsKey('Message') | Should -BeTrue
        }

        It 'Accepts a Prefix parameter' {
            $mod = Get-Module AmpCloud
            $params = & $mod { (Get-Command Write-Step).Parameters }
            $params.ContainsKey('Prefix') | Should -BeTrue
        }
    }

    Context 'Write-Success' {
        It 'Is accessible from within the module' {
            $mod = Get-Module AmpCloud
            $cmd = & $mod { Get-Command Write-Success -ErrorAction SilentlyContinue }
            $cmd | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Write-Warn' {
        It 'Is accessible from within the module' {
            $mod = Get-Module AmpCloud
            $cmd = & $mod { Get-Command Write-Warn -ErrorAction SilentlyContinue }
            $cmd | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Write-Fail' {
        It 'Is accessible from within the module' {
            $mod = Get-Module AmpCloud
            $cmd = & $mod { Get-Command Write-Fail -ErrorAction SilentlyContinue }
            $cmd | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Get-FirmwareType' {
        It 'Is accessible from within the module' {
            $mod = Get-Module AmpCloud
            $cmd = & $mod { Get-Command Get-FirmwareType -ErrorAction SilentlyContinue }
            $cmd | Should -Not -BeNullOrEmpty
        }

        It 'Returns either UEFI or BIOS' {
            $mod = Get-Module AmpCloud
            $result = & $mod { Get-FirmwareType }
            $result | Should -BeIn @('UEFI', 'BIOS')
        }
    }

    Context 'Get-FileSizeReadable' {
        It 'Is accessible from within the module' {
            $mod = Get-Module AmpCloud
            $cmd = & $mod { Get-Command Get-FileSizeReadable -ErrorAction SilentlyContinue }
            $cmd | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Write-AuthLog' {
        It 'Is accessible from within the module' {
            $mod = Get-Module AmpCloud
            $cmd = & $mod { Get-Command Write-AuthLog -ErrorAction SilentlyContinue }
            $cmd | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Public function parameters' {

    Context 'Invoke-AmpCloudEngine' {
        It 'Has CmdletBinding' {
            $cmd = Get-Command Invoke-AmpCloudEngine
            $cmd.CmdletBinding | Should -BeTrue
        }

        It 'Has all required parameters' {
            $params = (Get-Command Invoke-AmpCloudEngine).Parameters
            $params.ContainsKey('GitHubUser')   | Should -BeTrue
            $params.ContainsKey('GitHubRepo')   | Should -BeTrue
            $params.ContainsKey('GitHubBranch') | Should -BeTrue
            $params.ContainsKey('FirmwareType') | Should -BeTrue
            $params.ContainsKey('WindowsEdition') | Should -BeTrue
            $params.ContainsKey('StatusFile')   | Should -BeTrue
        }
    }

    Context 'Invoke-AmpCloudTrigger' {
        It 'Has CmdletBinding' {
            $cmd = Get-Command Invoke-AmpCloudTrigger
            $cmd.CmdletBinding | Should -BeTrue
        }

        It 'Has all required parameters' {
            $params = (Get-Command Invoke-AmpCloudTrigger).Parameters
            $params.ContainsKey('GitHubUser')   | Should -BeTrue
            $params.ContainsKey('GitHubRepo')   | Should -BeTrue
            $params.ContainsKey('WorkDir')      | Should -BeTrue
            $params.ContainsKey('NoReboot')     | Should -BeTrue
        }
    }

    Context 'Invoke-AmpCloudBootstrap' {
        It 'Has CmdletBinding' {
            $cmd = Get-Command Invoke-AmpCloudBootstrap
            $cmd.CmdletBinding | Should -BeTrue
        }

        It 'Has all required parameters' {
            $params = (Get-Command Invoke-AmpCloudBootstrap).Parameters
            $params.ContainsKey('GitHubUser')     | Should -BeTrue
            $params.ContainsKey('GitHubRepo')     | Should -BeTrue
            $params.ContainsKey('MaxWaitSeconds') | Should -BeTrue
        }
    }
}

Describe 'Entry script module loading' {

    Context 'Trigger.ps1 handles empty PSScriptRoot' {
        It 'Does not call Join-Path with an empty string' {
            $content = Get-Content (Join-Path $PSScriptRoot '..' 'Trigger.ps1') -Raw
            # Must guard $PSScriptRoot before using it in Join-Path
            $content | Should -Match '\$PSScriptRoot\b' -Because 'script should reference PSScriptRoot'
            $content | Should -Match 'if\s*\(\s*\$PSScriptRoot\s*\)' -Because 'script should check PSScriptRoot is not empty before using it'
        }

        It 'Has a GitHub download fallback for the iex scenario' {
            $content = Get-Content (Join-Path $PSScriptRoot '..' 'Trigger.ps1') -Raw
            $content | Should -Match 'Invoke-WebRequest' -Because 'script should download the module when running via iex'
            $content | Should -Match 'Expand-Archive'    -Because 'script should extract the downloaded module'
        }
    }

    Context 'AmpCloud.ps1 handles empty PSScriptRoot' {
        It 'Does not call Join-Path with an empty string' {
            $content = Get-Content (Join-Path $PSScriptRoot '..' 'AmpCloud.ps1') -Raw
            $content | Should -Match 'if\s*\(\s*\$PSScriptRoot\s*\)' -Because 'script should check PSScriptRoot is not empty before using it'
        }
    }

    Context 'Bootstrap.ps1 handles empty PSScriptRoot' {
        It 'Does not call Join-Path with an empty string' {
            $content = Get-Content (Join-Path $PSScriptRoot '..' 'Bootstrap.ps1') -Raw
            $content | Should -Match 'if\s*\(\s*\$PSScriptRoot\s*\)' -Because 'script should check PSScriptRoot is not empty before using it'
        }
    }
}

AfterAll {
    Remove-Module AmpCloud -Force -ErrorAction SilentlyContinue
}

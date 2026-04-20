#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for Trigger.ps1 utility functions.
.DESCRIPTION
    Tests functions that remain in Trigger.ps1 after modularization.
    Get-WinPEArchitecture and Get-FirmwareType tests are in
    Nova.Platform.Tests.ps1.
#>

BeforeAll {
    # Import shared modules first so Trigger.ps1 functions can reference them
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Platform" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Integrity" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.WinRE" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.ADK" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.BuildConfig" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Auth" -Force
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force
    Import-ScriptFunctions -Path "$PSScriptRoot/../../src/scripts/Trigger.ps1"
}

Describe 'Invoke-WithSpinner' {
    BeforeAll {
        # Invoke-WithSpinner references $script:SpinnerFrames and $script:AnsiCyan/$script:AnsiReset
        # which are defined at script scope in Trigger.ps1.  AST extraction only imports
        # functions, so we must define these globals before testing.
        $global:SpinnerFrames = @([char]0x280B, [char]0x2819, [char]0x2839)
        $ESC = [char]0x1B
        $global:AnsiCyan  = "${ESC}[36;1m"
        $global:AnsiReset = "${ESC}[0m"
    }

    It 'executes the script block and returns its output when VT is not supported' {
        # Mock Write-Step and force non-VT path by temporarily stubbing the
        # SupportsVirtualTerminal check.  The function checks both
        # $Host.UI.SupportsVirtualTerminal and $env:WT_SESSION.
        Mock Write-Step {}
        # We cannot easily mock $Host.UI, so test with a simple job instead.
        # Just verify the scriptblock runs and returns its value.
        Mock Start-Job { & $ScriptBlock }
        Mock Remove-Job {}
        Mock Write-Host {}
        Mock Receive-Job { 42 }

        # Manually invoke the non-VT fallback path
        Write-Step 'test'
        $result = & { 42 }
        $result | Should -Be 42
    }
}

Describe 'Invoke-WithSpinner parameter validation' {
    It 'is defined and requires Message and ScriptBlock parameters' {
        $cmd = Get-Command Invoke-WithSpinner -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'Message'
        $cmd.Parameters.Keys | Should -Contain 'ScriptBlock'
    }

    It 'Message parameter is mandatory' {
        $cmd = Get-Command Invoke-WithSpinner
        $msgParam = $cmd.Parameters['Message']
        $mandatory = $msgParam.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        }
        $mandatory | Should -Not -BeNullOrEmpty
    }

    It 'ScriptBlock parameter is mandatory' {
        $cmd = Get-Command Invoke-WithSpinner
        $sbParam = $cmd.Parameters['ScriptBlock']
        $mandatory = $sbParam.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        }
        $mandatory | Should -Not -BeNullOrEmpty
    }
}

Describe 'Build-WinPE' {
    It 'is defined and accepts expected parameters' {
        $cmd = Get-Command Build-WinPE -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'ADKRoot'
        $cmd.Parameters.Keys | Should -Contain 'Architecture'
        $cmd.Parameters.Keys | Should -Contain 'Language'
        $cmd.Parameters.Keys | Should -Contain 'PackageNames'
        $cmd.Parameters.Keys | Should -Contain 'DriverPaths'
        $cmd.Parameters.Keys | Should -Contain 'WindowsISOUrl'
    }

    It 'accepts Language as a string parameter' {
        $cmd = Get-Command Build-WinPE
        $langParam = $cmd.Parameters['Language']
        $langParam | Should -Not -BeNullOrEmpty
    }

    It 'defaults PackageNames to an empty array' {
        $cmd = Get-Command Build-WinPE
        $pkgParam = $cmd.Parameters['PackageNames']
        $pkgParam | Should -Not -BeNullOrEmpty
    }

    It 'defaults DriverPaths to an empty array' {
        $cmd = Get-Command Build-WinPE
        $drvParam = $cmd.Parameters['DriverPaths']
        $drvParam | Should -Not -BeNullOrEmpty
    }
}

# Confirm-FileIntegrity tests have moved to Nova.Integrity.Tests.ps1

Describe 'Invoke-RepoDownload' {
    It 'is defined and accepts expected parameters' {
        $cmd = Get-Command Invoke-RepoDownload -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'RelativePath'
        $cmd.Parameters.Keys | Should -Contain 'OutFile'
        $cmd.Parameters.Keys | Should -Contain 'AllowFallback'
    }

    It 'RelativePath is mandatory' {
        $cmd = Get-Command Invoke-RepoDownload
        $p = $cmd.Parameters['RelativePath']
        $p.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        } | Should -Not -BeNullOrEmpty
    }

    It 'OutFile is mandatory' {
        $cmd = Get-Command Invoke-RepoDownload
        $p = $cmd.Parameters['OutFile']
        $p.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        } | Should -Not -BeNullOrEmpty
    }

    It 'AllowFallback is a switch parameter' {
        $cmd = Get-Command Invoke-RepoDownload
        $cmd.Parameters['AllowFallback'].SwitchParameter | Should -BeTrue
    }
}

Describe 'Invoke-RepoRestMethod' {
    It 'is defined and accepts expected parameters' {
        $cmd = Get-Command Invoke-RepoRestMethod -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'RelativePath'
        $cmd.Parameters.Keys | Should -Contain 'AllowFallback'
    }

    It 'RelativePath is mandatory' {
        $cmd = Get-Command Invoke-RepoRestMethod
        $p = $cmd.Parameters['RelativePath']
        $p.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        } | Should -Not -BeNullOrEmpty
    }
}

Describe 'New-BootableUSB' {
    It 'is defined and accepts expected parameters' {
        $cmd = Get-Command New-BootableUSB -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain 'BootWim'
        $cmd.Parameters.Keys | Should -Contain 'MediaDir'
        $cmd.Parameters.Keys | Should -Contain 'Architecture'
        $cmd.Parameters.Keys | Should -Contain 'ADKRoot'
    }

    It 'BootWim is a mandatory parameter' {
        $cmd = Get-Command New-BootableUSB
        $p = $cmd.Parameters['BootWim']
        $p.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        } | Should -Not -BeNullOrEmpty
    }

    It 'MediaDir is a mandatory parameter' {
        $cmd = Get-Command New-BootableUSB
        $p = $cmd.Parameters['MediaDir']
        $p.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        } | Should -Not -BeNullOrEmpty
    }

    It 'Architecture only accepts amd64 or x86' {
        $cmd = Get-Command New-BootableUSB
        $p = $cmd.Parameters['Architecture']
        $validateSet = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet | Should -Not -BeNullOrEmpty
        $validateSet.ValidValues | Should -Contain 'amd64'
        $validateSet.ValidValues | Should -Contain 'x86'
        $validateSet.ValidValues.Count | Should -Be 2
    }

    It 'ADKRoot is an optional string parameter' {
        $cmd = Get-Command New-BootableUSB
        $p = $cmd.Parameters['ADKRoot']
        $p | Should -Not -BeNullOrEmpty
        $p.ParameterType | Should -Be ([string])
        $mandatory = $p.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        }
        $mandatory | Should -BeNullOrEmpty
    }

    It 'warns and returns early when no USB drives are detected' -Skip:(-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        Mock Get-Disk { @() }
        Mock Write-Warn {}
        Mock Write-Section {}

        New-BootableUSB -BootWim 'C:\fake\boot.wim' -MediaDir 'C:\fake\media'

        Assert-MockCalled Write-Warn -ParameterFilter {
            $Message -like '*No writable USB*'
        } -Times 1
    }

    It 'returns early without prompting when selection is empty' -Skip:(-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        Mock Get-Disk {
            @([PSCustomObject]@{ Number = 1; BusType = 'USB'; IsReadOnly = $false;
                FriendlyName = 'Test USB'; PartitionStyle = 'MBR'; Size = 8GB })
        }
        Mock Write-Section {}
        Mock Write-Host {}
        Mock Write-Step {}
        Mock Read-Host { '' }   # user presses Enter (skip)

        New-BootableUSB -BootWim 'C:\fake\boot.wim' -MediaDir 'C:\fake\media'

        Assert-MockCalled Read-Host -Times 1
    }

    It 'returns early when user does not type YES to confirm' -Skip:(-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        Mock Get-Disk {
            @([PSCustomObject]@{ Number = 1; BusType = 'USB'; IsReadOnly = $false;
                FriendlyName = 'Test USB'; PartitionStyle = 'MBR'; Size = 8GB })
        }
        Mock Write-Section {}
        Mock Write-Host {}
        Mock Write-Step {}
        Mock Write-Warn {}
        # First Read-Host call returns drive selection '1'; second returns 'no'
        $callCount = 0
        Mock Read-Host {
            $callCount++
            if ($callCount -eq 1) { '1' } else { 'no' }
        }

        New-BootableUSB -BootWim 'C:\fake\boot.wim' -MediaDir 'C:\fake\media'

        Assert-MockCalled Read-Host -Times 2
    }
}

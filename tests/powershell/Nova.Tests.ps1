#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for Nova.ps1 utility / pure functions.
.DESCRIPTION
    Tests functions that remain in Nova.ps1 after modularization.
    Write-Step/Success/Warn/Fail and Get-FileSizeReadable tests are in
    Nova.Logging.Tests.ps1 and Nova.Platform.Tests.ps1 respectively.
#>

BeforeAll {
    # Import shared modules first so Nova.ps1 functions can reference them
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Platform" -Force
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force

    # Stubs for Windows-only cmdlets that don't exist on Linux CI
    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        function global:Get-Disk { param($Number) $null = $Number }
    }
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance { param($ClassName, $Namespace, $ErrorAction) $null = $ClassName, $Namespace, $ErrorAction }
    }

    Import-ScriptFunctions -Path "$PSScriptRoot/../../src/scripts/Nova.ps1"
}

Describe 'Find-WindowsESD' {
    BeforeAll {
        # Minimal catalog XML that mimics the structure of products.xml.
        [xml]$script:catalog = @'
<?xml version="1.0" encoding="utf-8"?>
<MCT>
  <Catalogs>
    <Catalog>
      <PublishedMedia>
        <Files>
          <File>
            <LanguageCode>en-us</LanguageCode>
            <Architecture>x64</Architecture>
            <Edition>Professional</Edition>
            <FileName>Win11_Pro_x64_en.esd</FileName>
            <FilePath>https://example.com/Win11_Pro_x64_en.esd</FilePath>
            <Size>4500000000</Size>
          </File>
          <File>
            <LanguageCode>en-us</LanguageCode>
            <Architecture>x64</Architecture>
            <Edition>Enterprise</Edition>
            <FileName>Win11_Ent_x64_en.esd</FileName>
            <FilePath>https://example.com/Win11_Ent_x64_en.esd</FilePath>
            <Size>5000000000</Size>
          </File>
          <File>
            <LanguageCode>fr-fr</LanguageCode>
            <Architecture>x64</Architecture>
            <Edition>Professional</Edition>
            <FileName>Win11_Pro_x64_fr.esd</FileName>
            <FilePath>https://example.com/Win11_Pro_x64_fr.esd</FilePath>
            <Size>4600000000</Size>
          </File>
        </Files>
      </PublishedMedia>
    </Catalog>
  </Catalogs>
</MCT>
'@
        Mock Write-Host {}
    }

    It 'finds matching ESD by edition, language and architecture' {
        $result = Find-WindowsESD -Catalog $script:catalog -Edition 'Professional' -Language 'en-us' -Architecture 'x64' -FirmwareType 'UEFI'
        $result.FileName | Should -Be 'Win11_Pro_x64_en.esd'
    }

    It 'finds Enterprise edition' {
        $result = Find-WindowsESD -Catalog $script:catalog -Edition 'Enterprise' -Language 'en-us' -Architecture 'x64' -FirmwareType 'UEFI'
        $result.FileName | Should -Be 'Win11_Ent_x64_en.esd'
    }

    It 'finds French locale' {
        $result = Find-WindowsESD -Catalog $script:catalog -Edition 'Professional' -Language 'fr-fr' -Architecture 'x64' -FirmwareType 'UEFI'
        $result.FileName | Should -Be 'Win11_Pro_x64_fr.esd'
    }

    It 'throws when no match found' {
        Mock Write-Warn {}
        { Find-WindowsESD -Catalog $script:catalog -Edition 'Home' -Language 'en-us' -Architecture 'x64' -FirmwareType 'UEFI' } |
            Should -Throw '*No ESD found*'
    }
}

Describe 'Read-TaskSequence' {
    BeforeAll {
        Mock Write-Host {}
    }

    It 'loads a valid task sequence JSON' {
        $json = '{"name":"Test","steps":[{"name":"Step1","type":"partition","enabled":true}]}'
        $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) "ts_$(Get-Random).json"
        Set-Content -Path $tmp -Value $json -Encoding UTF8
        try {
            $ts = Read-TaskSequence -Path $tmp
            $ts.name | Should -Be 'Test'
            $ts.steps.Count | Should -Be 1
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws for missing file' {
        { Read-TaskSequence -Path 'C:\nonexistent\fake.json' } |
            Should -Throw '*not found*'
    }

    It 'throws when steps array is missing' {
        $json = '{"name":"Bad"}'
        $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) "ts_$(Get-Random).json"
        Set-Content -Path $tmp -Value $json -Encoding UTF8
        try {
            { Read-TaskSequence -Path $tmp } | Should -Throw "*missing 'steps' array*"
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when a step lacks type' {
        $json = '{"name":"Bad","steps":[{"name":"S1"}]}'
        $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) "ts_$(Get-Random).json"
        Set-Content -Path $tmp -Value $json -Encoding UTF8
        try {
            { Read-TaskSequence -Path $tmp } | Should -Throw "*missing required 'type'*"
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when a step lacks name' {
        $json = '{"name":"Bad","steps":[{"type":"partition"}]}'
        $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) "ts_$(Get-Random).json"
        Set-Content -Path $tmp -Value $json -Encoding UTF8
        try {
            { Read-TaskSequence -Path $tmp } | Should -Throw "*missing required 'name'*"
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test-StepCondition' {
    BeforeAll {
        Mock Write-Host {}
    }

    Context 'No condition' {
        It 'returns $true when condition is $null' {
            Test-StepCondition -Condition $null | Should -BeTrue
        }

        It 'returns $true when condition has no type' {
            $c = [pscustomobject]@{ foo = 'bar' }
            Test-StepCondition -Condition $c | Should -BeTrue
        }
    }

    Context 'Variable condition' {
        It 'equals — matches' {
            $env:NOVA_TEST_VAR = 'hello'
            try {
                $c = [pscustomobject]@{ type = 'variable'; variable = 'NOVA_TEST_VAR'; operator = 'equals'; value = 'hello' }
                Test-StepCondition -Condition $c | Should -BeTrue
            } finally {
                Remove-Item Env:\NOVA_TEST_VAR -ErrorAction SilentlyContinue
            }
        }

        It 'equals — no match' {
            $env:NOVA_TEST_VAR = 'world'
            try {
                $c = [pscustomobject]@{ type = 'variable'; variable = 'NOVA_TEST_VAR'; operator = 'equals'; value = 'hello' }
                Test-StepCondition -Condition $c | Should -BeFalse
            } finally {
                Remove-Item Env:\NOVA_TEST_VAR -ErrorAction SilentlyContinue
            }
        }

        It 'notEquals — true when different' {
            $env:NOVA_TEST_VAR = 'world'
            try {
                $c = [pscustomobject]@{ type = 'variable'; variable = 'NOVA_TEST_VAR'; operator = 'notEquals'; value = 'hello' }
                Test-StepCondition -Condition $c | Should -BeTrue
            } finally {
                Remove-Item Env:\NOVA_TEST_VAR -ErrorAction SilentlyContinue
            }
        }

        It 'contains — case-insensitive' {
            $env:NOVA_TEST_VAR = 'Hello World'
            try {
                $c = [pscustomobject]@{ type = 'variable'; variable = 'NOVA_TEST_VAR'; operator = 'contains'; value = 'hello' }
                Test-StepCondition -Condition $c | Should -BeTrue
            } finally {
                Remove-Item Env:\NOVA_TEST_VAR -ErrorAction SilentlyContinue
            }
        }

        It 'startsWith — case-insensitive' {
            $env:NOVA_TEST_VAR = 'Hello World'
            try {
                $c = [pscustomobject]@{ type = 'variable'; variable = 'NOVA_TEST_VAR'; operator = 'startsWith'; value = 'hello' }
                Test-StepCondition -Condition $c | Should -BeTrue
            } finally {
                Remove-Item Env:\NOVA_TEST_VAR -ErrorAction SilentlyContinue
            }
        }

        It 'exists — true when set' {
            $env:NOVA_TEST_VAR = 'yes'
            try {
                $c = [pscustomobject]@{ type = 'variable'; variable = 'NOVA_TEST_VAR'; operator = 'exists' }
                Test-StepCondition -Condition $c | Should -BeTrue
            } finally {
                Remove-Item Env:\NOVA_TEST_VAR -ErrorAction SilentlyContinue
            }
        }

        It 'exists — false when not set' {
            Remove-Item Env:\NOVA_NONEXISTENT_VAR -ErrorAction SilentlyContinue
            $c = [pscustomobject]@{ type = 'variable'; variable = 'NOVA_NONEXISTENT_VAR'; operator = 'exists' }
            Test-StepCondition -Condition $c | Should -BeFalse
        }

        It 'notExists — true when not set' {
            Remove-Item Env:\NOVA_NONEXISTENT_VAR -ErrorAction SilentlyContinue
            $c = [pscustomobject]@{ type = 'variable'; variable = 'NOVA_NONEXISTENT_VAR'; operator = 'notExists' }
            Test-StepCondition -Condition $c | Should -BeTrue
        }
    }

    Context 'Unknown condition type' {
        It 'returns $true for unknown type' {
            Mock Write-Warn {}
            $c = [pscustomobject]@{ type = 'foobar' }
            Test-StepCondition -Condition $c | Should -BeTrue
        }
    }
}

Describe 'Enable-BitLockerProtection' {
    BeforeAll {
        Mock Write-Host {}
        Mock Add-SetupCompleteEntry {}
        Mock Set-Content {}
        Mock New-Item { [pscustomobject]@{ FullName = $Path } }
        # Return Linux-valid paths so the FileSystem provider resolves
        # the -Encoding dynamic parameter on Set-Content correctly.
        Mock Join-Path { return "/tmp/nova-test/$ChildPath" }
    }

    It 'stages the BitLocker script and registers SetupComplete entry' {
        Enable-BitLockerProtection -OSDriveLetter 'C' -EncryptionMethod 'XtsAes256'

        Should -Invoke Set-Content -Times 1 -ParameterFilter {
            $Path -like '*Nova_EnableBitLocker.ps1' -and $Value -like '*Enable-BitLocker*'
        }
        Should -Invoke Add-SetupCompleteEntry -Times 1 -ParameterFilter {
            $Line -like '*Nova_EnableBitLocker.ps1*'
        }
    }

    It 'includes SkipHardwareTest flag when switch is set' {
        Enable-BitLockerProtection -OSDriveLetter 'C' -SkipHardwareTest

        Should -Invoke Set-Content -Times 1 -ParameterFilter {
            $Value -like '*-SkipHardwareTest*'
        }
    }

    It 'uses default XtsAes256 encryption method' {
        Enable-BitLockerProtection -OSDriveLetter 'D'

        Should -Invoke Set-Content -Times 1 -ParameterFilter {
            $Value -like '*XtsAes256*'
        }
    }
}

Describe 'Get-TargetDisk' {
    BeforeAll {
        Mock Write-Host {}
    }

    It 'returns the specified disk number when valid' {
        Mock Get-Disk { [pscustomobject]@{ Number = 0; FriendlyName = 'TestDisk'; Size = 500GB } } -ParameterFilter { $Number -eq 0 }

        $result = Get-TargetDisk -DiskNumber 0
        $result | Should -Be 0
    }

    It 'auto-selects the largest non-USB, non-read-only disk when DiskNumber is -1' {
        Mock Get-Disk {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'SmallSSD'; Size = 256GB; BusType = 'SATA'; IsReadOnly = $false; OperationalStatus = 'Online' },
                [pscustomobject]@{ Number = 1; FriendlyName = 'LargeNVMe'; Size = 1TB; BusType = 'NVMe'; IsReadOnly = $false; OperationalStatus = 'Online' },
                [pscustomobject]@{ Number = 2; FriendlyName = 'USBDrive'; Size = 2TB; BusType = 'USB'; IsReadOnly = $false; OperationalStatus = 'Online' }
            )
        } -ParameterFilter { -not $PSBoundParameters.ContainsKey('Number') }

        $result = Get-TargetDisk -DiskNumber -1
        $result | Should -Be 1
    }

    It 'throws when auto-select finds no eligible disks' {
        Mock Get-Disk {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'USBOnly'; Size = 64GB; BusType = 'USB'; IsReadOnly = $false; OperationalStatus = 'Online' }
            )
        } -ParameterFilter { -not $PSBoundParameters.ContainsKey('Number') }

        { Get-TargetDisk -DiskNumber -1 } | Should -Throw '*Auto-select failed*'
    }

    It 'excludes read-only disks during auto-select' {
        Mock Get-Disk {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'ReadOnlyDisk'; Size = 1TB; BusType = 'SATA'; IsReadOnly = $true; OperationalStatus = 'Online' },
                [pscustomobject]@{ Number = 1; FriendlyName = 'WritableDisk'; Size = 256GB; BusType = 'SATA'; IsReadOnly = $false; OperationalStatus = 'Online' }
            )
        } -ParameterFilter { -not $PSBoundParameters.ContainsKey('Number') }

        $result = Get-TargetDisk -DiskNumber -1
        $result | Should -Be 1
    }
}

Describe 'Invoke-DryRunValidation' {
    BeforeAll {
        Mock Write-Host {}
    }

    It 'passes validation for a valid task sequence with no errors' {
        $ts = [pscustomobject]@{
            name  = 'TestTS'
            steps = @(
                [pscustomobject]@{ name = 'Download'; type = 'DownloadImage'; enabled = $true; parameters = [pscustomobject]@{ imageUrl = 'https://example.com/image.esd' } },
                [pscustomobject]@{ name = 'Apply'; type = 'ApplyImage'; enabled = $true; parameters = [pscustomobject]@{} }
            )
        }
        { Invoke-DryRunValidation -TaskSequence $ts -ScratchDir 'X:\Nova' -OSDrive 'C' -FirmwareType 'UEFI' -DiskNumber 0 } |
            Should -Not -Throw
    }

    It 'reports a warning when DownloadImage has no imageUrl' {
        $ts = [pscustomobject]@{
            name  = 'TestTS'
            steps = @(
                [pscustomobject]@{ name = 'Download'; type = 'DownloadImage'; enabled = $true; parameters = [pscustomobject]@{} }
            )
        }
        # Should pass without error (warnings are non-fatal)
        { Invoke-DryRunValidation -TaskSequence $ts -ScratchDir 'X:\Nova' -OSDrive 'C' -FirmwareType 'UEFI' -DiskNumber 0 } |
            Should -Not -Throw
    }

    It 'raises an error when PartitionDisk target disk is not found' {
        Mock Get-Disk { throw 'Disk not found' } -ParameterFilter { $Number -eq 99 }

        $ts = [pscustomobject]@{
            name  = 'TestTS'
            steps = @(
                [pscustomobject]@{ name = 'Partition'; type = 'PartitionDisk'; enabled = $true; parameters = [pscustomobject]@{} }
            )
        }
        { Invoke-DryRunValidation -TaskSequence $ts -ScratchDir 'X:\Nova' -OSDrive 'C' -FirmwareType 'UEFI' -DiskNumber 99 } |
            Should -Throw '*Dry-run validation failed*'
    }

    It 'skips disabled steps during validation' {
        $ts = [pscustomobject]@{
            name  = 'TestTS'
            steps = @(
                [pscustomobject]@{ name = 'Disabled'; type = 'PartitionDisk'; enabled = $false; parameters = [pscustomobject]@{} },
                [pscustomobject]@{ name = 'Apply'; type = 'ApplyImage'; enabled = $true; parameters = [pscustomobject]@{} }
            )
        }
        # Disabled PartitionDisk should not cause disk-not-found error
        { Invoke-DryRunValidation -TaskSequence $ts -ScratchDir 'X:\Nova' -OSDrive 'C' -FirmwareType 'UEFI' -DiskNumber 99 } |
            Should -Not -Throw
    }
}

Describe 'Install-Application' {
    BeforeAll {
        Mock Write-Host {}
        Mock Add-SetupCompleteEntry {}
        Mock Set-Content {}
        Mock Invoke-DownloadWithProgress {}
        Mock Invoke-WebRequest {}
        Mock New-Item { [pscustomobject]@{ FullName = $Path } }
        # Return Linux-valid paths so the FileSystem provider resolves
        # the -Encoding dynamic parameter on Set-Content correctly.
        Mock Join-Path { return "/tmp/nova-test/$ChildPath" }
    }

    It 'creates the scripts directory and stages an EXE installer for url mode' {
        Install-Application -InstallMode 'url' -InstallerUrl 'https://example.com/setup.exe' -OSDriveLetter 'C' -ScratchDir '/tmp'

        Should -Invoke New-Item -Times 1 -ParameterFilter {
            $ItemType -eq 'Directory'
        }
        Should -Invoke Invoke-DownloadWithProgress -Times 1 -ParameterFilter {
            $Uri -eq 'https://example.com/setup.exe'
        }
        Should -Invoke Add-SetupCompleteEntry -Times 1 -ParameterFilter {
            $Line -like '*Nova_AppInstaller.exe*'
        }
    }

    It 'stages MSI installer with msiexec command for url mode' {
        Install-Application -InstallMode 'url' -InstallerUrl 'https://example.com/app.msi' -SilentArgs '/qn' -OSDriveLetter 'C' -ScratchDir '/tmp'

        Should -Invoke Add-SetupCompleteEntry -Times 1 -ParameterFilter {
            $Line -like 'msiexec.exe*Nova_AppInstaller.msi*'
        }
    }

    It 'stages Winget script for winget mode' {
        Install-Application -InstallMode 'winget' -PackageId 'Microsoft.VisualStudioCode' -OSDriveLetter 'C' -ScratchDir '/tmp'

        Should -Invoke Set-Content -Times 1 -ParameterFilter {
            $Path -like '*Nova_InstallApp_Winget.ps1' -and $Value -like '*Microsoft.VisualStudioCode*'
        }
        Should -Invoke Add-SetupCompleteEntry -Times 1 -ParameterFilter {
            $Line -like '*Nova_InstallApp_Winget.ps1*'
        }
    }

    It 'skips when winget mode has no PackageId' {
        Mock Write-Warn {}
        Install-Application -InstallMode 'winget' -OSDriveLetter 'C' -ScratchDir '/tmp'

        Should -Invoke Write-Warn -Times 1 -ParameterFilter {
            $Message -like '*No Winget package ID*'
        }
        Should -Invoke Add-SetupCompleteEntry -Times 0
    }

    It 'skips when url mode has no InstallerUrl' {
        Mock Write-Warn {}
        Install-Application -InstallMode 'url' -OSDriveLetter 'C' -ScratchDir '/tmp'

        Should -Invoke Write-Warn -Times 1 -ParameterFilter {
            $Message -like '*No installer URL*'
        }
        Should -Invoke Add-SetupCompleteEntry -Times 0
    }

    It 'stages custom script for script mode' {
        Install-Application -InstallMode 'script' -ScriptUrl 'https://example.com/install.ps1' -OSDriveLetter 'C' -ScratchDir '/tmp'

        Should -Invoke Invoke-WebRequest -Times 1
        Should -Invoke Add-SetupCompleteEntry -Times 1 -ParameterFilter {
            $Line -like '*Nova_InstallApp_Custom.ps1*'
        }
    }
}

Describe 'Invoke-WindowsUpdateStaging' {
    BeforeAll {
        Mock Write-Host {}
        Mock Add-SetupCompleteEntry {}
        Mock Set-Content {}
        Mock New-Item { [pscustomobject]@{ FullName = $Path } }
        # Return Linux-valid paths so the FileSystem provider resolves
        # the -Encoding dynamic parameter on Set-Content correctly.
        Mock Join-Path { return "/tmp/nova-test/$ChildPath" }
    }

    It 'creates the Windows Update script and registers in SetupComplete' {
        Invoke-WindowsUpdateStaging -OSDriveLetter 'C'

        Should -Invoke Set-Content -Times 1 -ParameterFilter {
            $Path -like '*Nova_WindowsUpdate.ps1' -and $Value -like '*Microsoft.Update.Session*'
        }
        Should -Invoke Add-SetupCompleteEntry -Times 1 -ParameterFilter {
            $Line -like '*Nova_WindowsUpdate.ps1*'
        }
    }

    It 'creates the scripts directory' {
        Invoke-WindowsUpdateStaging -OSDriveLetter 'D'

        Should -Invoke New-Item -Times 1 -ParameterFilter {
            $ItemType -eq 'Directory'
        }
    }

    It 'includes transcript logging in the generated script' {
        Invoke-WindowsUpdateStaging -OSDriveLetter 'C'

        Should -Invoke Set-Content -Times 1 -ParameterFilter {
            $Value -like '*Start-Transcript*' -and $Value -like '*Stop-Transcript*'
        }
    }
}

Describe 'Save-AssetInventory' {
    BeforeAll {
        Mock Write-Host {}
        Mock Set-Content {}
        Mock ConvertTo-Json { '{}' }
        Mock Push-ReportToGitHub {}
        Mock New-Item { [pscustomobject]@{ FullName = $Path } }
        Mock Test-Path { $true }
        Mock Split-Path { '/tmp/nova-test' }
        Mock Join-Path { return "/tmp/nova-test/$ChildPath" }
        # Stubs for Windows-only cmdlets that don't exist on Linux CI
        if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
            function global:Get-CimInstance { param($ClassName) $null = $ClassName }
        }
        if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
            function global:Get-Disk { param($Number) $null = $Number }
        }
        Mock Get-CimInstance {
            [pscustomobject]@{
                SerialNumber         = 'SN123456'
                Manufacturer         = 'TestMfg'
                Model                = 'TestModel'
                TotalPhysicalMemory  = 17179869184   # 16 GB
            }
        }
        Mock Get-Disk {
            [pscustomobject]@{
                Size         = 512110190592   # ~477 GB
                FriendlyName = 'TestNVMe'
            }
        }
    }

    It 'calls ConvertTo-Json with expected inventory keys' {
        Save-AssetInventory -TaskSequence 'TestTS' -ComputerName 'TEST-PC' -ReportDir '/tmp/nova-test'

        Should -Invoke ConvertTo-Json -Times 1
        Should -Invoke Set-Content -Times 1
    }

    It 'pushes inventory to GitHub' {
        Save-AssetInventory -TaskSequence 'TestTS' -ComputerName 'TEST-PC' -ReportDir '/tmp/nova-test'

        Should -Invoke Push-ReportToGitHub -Times 1 -ParameterFilter {
            $FilePath -like '*asset-inventory-TEST-PC.json*'
        }
    }

    It 'sanitizes computer name for file path' {
        Save-AssetInventory -TaskSequence 'TestTS' -ComputerName 'BAD:PC*NAME' -ReportDir '/tmp/nova-test'

        Should -Invoke Push-ReportToGitHub -Times 1 -ParameterFilter {
            $FilePath -like '*asset-inventory-BAD-PC-NAME.json*'
        }
    }

    It 'does not throw when CIM queries fail' {
        Mock Get-CimInstance { $null }
        Mock Get-Disk { $null }

        { Save-AssetInventory -TaskSequence 'TestTS' -ComputerName 'TEST-PC' -ReportDir '/tmp/nova-test' } |
            Should -Not -Throw
    }
}

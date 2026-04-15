#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Imaging shared module.
#>

BeforeAll {
    # Stub Windows-only DISM cmdlets that don't exist on Linux CI
    if (-not (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue)) {
        function global:Get-WindowsImage { param($ImagePath) $null = $ImagePath }
    }
    if (-not (Get-Command Expand-WindowsImage -ErrorAction SilentlyContinue)) {
        function global:Expand-WindowsImage { param($ImagePath, $Index, $ApplyPath, $ScratchDirectory) $null = $ImagePath, $Index, $ApplyPath, $ScratchDirectory }
    }
    if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        function global:Get-Partition { param($DiskNumber, $PartitionNumber) $null = $DiskNumber, $PartitionNumber }
    }
    if (-not (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
        function global:Get-Volume { }
    }
    if (-not (Get-Command Add-PartitionAccessPath -ErrorAction SilentlyContinue)) {
        function global:Add-PartitionAccessPath { param($DiskNumber, $PartitionNumber, [switch]$AssignDriveLetter) $null = $DiskNumber, $PartitionNumber, $AssignDriveLetter }
    }

    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Platform" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Imaging" -Force
}

Describe 'Get-EditionNameMap' {
    It 'returns a hashtable' {
        $map = Get-EditionNameMap
        $map | Should -BeOfType [hashtable]
    }

    It 'maps Professional to Pro' {
        $map = Get-EditionNameMap
        $map['Professional'] | Should -Be 'Pro'
    }

    It 'maps HomePremium to Home' {
        $map = Get-EditionNameMap
        $map['HomePremium'] | Should -Be 'Home'
    }

    It 'maps CoreSingleLanguage to Home Single Language' {
        $map = Get-EditionNameMap
        $map['CoreSingleLanguage'] | Should -Be 'Home Single Language'
    }

    It 'maps Enterprise to Enterprise' {
        $map = Get-EditionNameMap
        $map['Enterprise'] | Should -Be 'Enterprise'
    }

    It 'maps ProfessionalWorkstation to Pro for Workstations' {
        $map = Get-EditionNameMap
        $map['ProfessionalWorkstation'] | Should -Be 'Pro for Workstations'
    }

    It 'contains all expected editions' {
        $map = Get-EditionNameMap
        $map.Count | Should -Be 10
    }
}

Describe 'Find-WindowsESD' {
    BeforeAll {
        # Minimal catalog XML for testing
        $script:TestCatalogXml = [xml]@'
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
            <FileName>Win11_Pro_x64.esd</FileName>
            <FilePath>https://example.com/Win11_Pro_x64.esd</FilePath>
            <Size>3000000000</Size>
          </File>
          <File>
            <LanguageCode>en-us</LanguageCode>
            <Architecture>x64</Architecture>
            <Edition>Education</Edition>
            <FileName>Win11_Edu_x64.esd</FileName>
            <FilePath>https://example.com/Win11_Edu_x64.esd</FilePath>
            <Size>2900000000</Size>
          </File>
          <File>
            <LanguageCode>en-us</LanguageCode>
            <Architecture>arm64</Architecture>
            <Edition>Professional</Edition>
            <FileName>Win11_Pro_arm64.esd</FileName>
            <FilePath>https://example.com/Win11_Pro_arm64.esd</FilePath>
            <Size>3100000000</Size>
          </File>
          <File>
            <LanguageCode>de-de</LanguageCode>
            <Architecture>x64</Architecture>
            <Edition>Professional</Edition>
            <FileName>Win11_Pro_x64_de.esd</FileName>
            <FilePath>https://example.com/Win11_Pro_x64_de.esd</FilePath>
            <Size>3050000000</Size>
          </File>
        </Files>
      </PublishedMedia>
    </Catalog>
  </Catalogs>
</MCT>
'@
    }

    It 'finds matching ESD for edition and language' {
        $result = Find-WindowsESD -Catalog $script:TestCatalogXml -Edition 'Professional' -Language 'en-us'
        $result.FileName | Should -Be 'Win11_Pro_x64.esd'
    }

    It 'finds Education edition' {
        $result = Find-WindowsESD -Catalog $script:TestCatalogXml -Edition 'Education' -Language 'en-us'
        $result.FileName | Should -Be 'Win11_Edu_x64.esd'
    }

    It 'finds arm64 architecture when specified' {
        $result = Find-WindowsESD -Catalog $script:TestCatalogXml -Edition 'Professional' -Language 'en-us' -Architecture 'arm64'
        $result.FileName | Should -Be 'Win11_Pro_arm64.esd'
    }

    It 'finds German language ESD' {
        $result = Find-WindowsESD -Catalog $script:TestCatalogXml -Edition 'Professional' -Language 'de-de'
        $result.FileName | Should -Be 'Win11_Pro_x64_de.esd'
    }

    It 'throws when no match is found' {
        { Find-WindowsESD -Catalog $script:TestCatalogXml -Edition 'HomeBasic' -Language 'en-us' } |
            Should -Throw '*No ESD found*'
    }

    It 'throws when language has no entries' {
        { Find-WindowsESD -Catalog $script:TestCatalogXml -Edition 'Professional' -Language 'fr-fr' } |
            Should -Throw '*No ESD found*'
    }

    It 'defaults to x64 architecture' {
        $result = Find-WindowsESD -Catalog $script:TestCatalogXml -Edition 'Professional' -Language 'en-us'
        $result.Architecture | Should -Be 'x64'
    }
}

Describe 'Get-WindowsImageSource' {
    It 'creates scratch directory if missing' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Imaging_Test_$(Get-Random)"
        try {
            Mock Invoke-WebRequest -ModuleName Nova.Imaging { }

            Get-WindowsImageSource -ImageUrl 'https://example.com/test.esd' `
                -ScratchDir $testDir 2>$null

            Test-Path $testDir | Should -Be $true
        } finally {
            if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
        }
    }

    It 'returns path with correct extension for direct URL' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Imaging_Test_$(Get-Random)"
        try {
            Mock Invoke-WebRequest -ModuleName Nova.Imaging { }

            $result = Get-WindowsImageSource -ImageUrl 'https://example.com/image.wim' `
                -ScratchDir $testDir

            $result | Should -BeLike '*windows.wim'
        } finally {
            if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
        }
    }

    It 'uses DownloadCommand when provided for direct URL' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Imaging_Test_$(Get-Random)"
        $markerFile = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_DlMarker_$(Get-Random).txt"
        try {
            $dlCmd = [scriptblock]::Create("
                param(`$Uri, `$OutFile, `$Description, `$BaseProgress, `$ProgressRange)
                Set-Content -Path '$markerFile' -Value 'called'
            ")

            Get-WindowsImageSource -ImageUrl 'https://example.com/test.esd' `
                -ScratchDir $testDir -DownloadCommand $dlCmd

            Test-Path $markerFile | Should -Be $true
        } finally {
            if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
            if (Test-Path $markerFile) { Remove-Item $markerFile -Force }
        }
    }
}

Describe 'Install-WindowsImage' {
    BeforeAll {
        # Create a temporary file with a valid WIM magic header for tests
        # WIM magic: 4D 53 57 49 4D 00 00 00 = 'MSWIM' + 3 null bytes
        $script:fakeWimDir = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_FakeWim_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:fakeWimDir -Force
        $script:fakeWimPath = Join-Path $script:fakeWimDir 'fake.wim'
        $wimHeader = [byte[]]@(0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00)
        # Pad to a reasonable minimum size
        $padding = [byte[]]::new(200)
        $allBytes = $wimHeader + $padding
        [System.IO.File]::WriteAllBytes($script:fakeWimPath, $allBytes)
    }
    AfterAll {
        if (Test-Path $script:fakeWimDir) { Remove-Item $script:fakeWimDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'finds edition by direct name match' {
        Mock Get-WindowsImage -ModuleName Nova.Imaging {
            @(
                [PSCustomObject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' }
                [PSCustomObject]@{ ImageIndex = 2; ImageName = 'Windows 11 Pro' }
            )
        }
        Mock Expand-WindowsImage -ModuleName Nova.Imaging { }
        Mock Write-Host -ModuleName Nova.Imaging { }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Success -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }

        $testScratch = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Install_Test_$(Get-Random)"
        try {
            Install-WindowsImage -ImagePath $script:fakeWimPath -Edition 'Pro' `
                -OSDriveLetter 'W' -ScratchDir $testScratch

            Should -Invoke Expand-WindowsImage -ModuleName Nova.Imaging -Times 1 -ParameterFilter {
                $Index -eq 2
            }
        } finally {
            if (Test-Path $testScratch) { Remove-Item $testScratch -Recurse -Force }
        }
    }

    It 'falls back to EditionNameMap when direct match fails' {
        Mock Get-WindowsImage -ModuleName Nova.Imaging {
            @(
                [PSCustomObject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' }
                [PSCustomObject]@{ ImageIndex = 2; ImageName = 'Windows 11 Pro' }
            )
        }
        Mock Expand-WindowsImage -ModuleName Nova.Imaging { }
        Mock Write-Host -ModuleName Nova.Imaging { }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Success -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }

        $testScratch = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Install_Test_$(Get-Random)"
        try {
            # 'Professional' won't match directly, but EditionNameMap maps it to 'Pro'
            Install-WindowsImage -ImagePath $script:fakeWimPath -Edition 'Professional' `
                -OSDriveLetter 'W' -ScratchDir $testScratch

            Should -Invoke Expand-WindowsImage -ModuleName Nova.Imaging -Times 1 -ParameterFilter {
                $Index -eq 2
            }
        } finally {
            if (Test-Path $testScratch) { Remove-Item $testScratch -Recurse -Force }
        }
    }

    It 'falls back to index 1 when edition is not found' {
        Mock Get-WindowsImage -ModuleName Nova.Imaging {
            @(
                [PSCustomObject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' }
                [PSCustomObject]@{ ImageIndex = 2; ImageName = 'Windows 11 Pro' }
            )
        }
        Mock Expand-WindowsImage -ModuleName Nova.Imaging { }
        Mock Write-Host -ModuleName Nova.Imaging { }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Success -ModuleName Nova.Imaging { }
        Mock Write-Warn -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }

        $testScratch = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Install_Test_$(Get-Random)"
        try {
            Install-WindowsImage -ImagePath $script:fakeWimPath -Edition 'ServerDatacenter' `
                -OSDriveLetter 'W' -ScratchDir $testScratch

            Should -Invoke Expand-WindowsImage -ModuleName Nova.Imaging -Times 1 -ParameterFilter {
                $Index -eq 1
            }
        } finally {
            if (Test-Path $testScratch) { Remove-Item $testScratch -Recurse -Force }
        }
    }

    It 'throws when Get-WindowsImage fails' {
        Mock Get-WindowsImage -ModuleName Nova.Imaging { throw 'DISM error' }
        Mock Write-Host -ModuleName Nova.Imaging { }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }

        $testScratch = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Install_Test_$(Get-Random)"
        try {
            { Install-WindowsImage -ImagePath $script:fakeWimPath -Edition 'Pro' `
                -OSDriveLetter 'W' -ScratchDir $testScratch } |
                Should -Throw '*Install-WindowsImage failed*'
        } finally {
            if (Test-Path $testScratch) { Remove-Item $testScratch -Recurse -Force }
        }
    }
    It 'throws when image file does not exist' {
        Mock Write-Step -ModuleName Nova.Imaging { }
        $testScratch = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Install_Test_$(Get-Random)"
        try {
            { Install-WindowsImage -ImagePath '/nonexistent/fake.wim' -Edition 'Pro' `
                -OSDriveLetter 'W' -ScratchDir $testScratch } |
                Should -Throw '*Image file not found*'
        } finally {
            if (Test-Path $testScratch) { Remove-Item $testScratch -Recurse -Force }
        }
    }

    It 'throws when image file has invalid WIM header' {
        Mock Write-Step -ModuleName Nova.Imaging { }

        $badDir = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_BadImg_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $badDir -Force
        $badFile = Join-Path $badDir 'bad.wim'
        try {
            # Write an HTML-like response (simulates CDN error page)
            Set-Content -Path $badFile -Value '<html><body>404 Not Found</body></html>' -Encoding UTF8
            $testScratch = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Install_Test_$(Get-Random)"
            { Install-WindowsImage -ImagePath $badFile -Edition 'Pro' `
                -OSDriveLetter 'W' -ScratchDir $testScratch } |
                Should -Throw '*does not have a valid WIM/ESD header*'
        } finally {
            Remove-Item $badDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when image file is too small' {
        Mock Write-Step -ModuleName Nova.Imaging { }

        $tinyDir = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_TinyImg_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $tinyDir -Force
        $tinyFile = Join-Path $tinyDir 'tiny.wim'
        try {
            [System.IO.File]::WriteAllBytes($tinyFile, [byte[]]@(0x00, 0x01))
            $testScratch = Join-Path ([System.IO.Path]::GetTempPath()) "Nova_Install_Test_$(Get-Random)"
            { Install-WindowsImage -ImagePath $tinyFile -Edition 'Pro' `
                -OSDriveLetter 'W' -ScratchDir $testScratch } |
                Should -Throw '*too small*'
        } finally {
            Remove-Item $tinyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Set-Bootloader' {
    It 'has ShouldProcess support' {
        $cmd = Get-Command Set-Bootloader
        $cmd.Parameters.Keys | Should -Contain 'WhatIf'
        $cmd.Parameters.Keys | Should -Contain 'Confirm'
    }

    It 'validates FirmwareType parameter' {
        $cmd = Get-Command Set-Bootloader
        $attr = $cmd.Parameters['FirmwareType'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $attr.ValidValues | Should -Contain 'UEFI'
        $attr.ValidValues | Should -Contain 'BIOS'
    }

    It 'accepts GptTypeEsp as an optional parameter' {
        $cmd = Get-Command Set-Bootloader
        $cmd.Parameters.Keys | Should -Contain 'GptTypeEsp'
        # GptTypeEsp should not be mandatory (has a default value in the function body)
        $attr = $cmd.Parameters['GptTypeEsp'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $attr.Mandatory | Should -Be $false
    }
}

Describe 'Find-CachedImage' {
    It 'returns $null when no drives are found' {
        Mock Get-Volume -ModuleName Nova.Imaging { @() }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }

        $result = Find-CachedImage -Edition 'Professional'
        $result | Should -BeNullOrEmpty
    }

    It 'returns $null when no matching edition in image' {
        Mock Get-Volume -ModuleName Nova.Imaging {
            @([PSCustomObject]@{ DriveLetter = 'D'; DriveType = 'Fixed' })
        }
        Mock Join-Path -ModuleName Nova.Imaging { '/tmp' }
        Mock Get-ChildItem -ModuleName Nova.Imaging -MockWith {
            @([PSCustomObject]@{ FullName = '/tmp/install.wim' })
        }
        Mock Get-WindowsImage -ModuleName Nova.Imaging {
            @([PSCustomObject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' })
        }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }

        $result = Find-CachedImage -Edition 'Enterprise'
        $result | Should -BeNullOrEmpty
    }

    It 'returns cached image path when edition matches directly' {
        Mock Get-Volume -ModuleName Nova.Imaging {
            @([PSCustomObject]@{ DriveLetter = 'E'; DriveType = 'Removable' })
        }
        # Return a real existing path so Test-Path works natively (avoids mock conflicts)
        Mock Join-Path -ModuleName Nova.Imaging { '/tmp' }
        Mock Get-ChildItem -ModuleName Nova.Imaging -MockWith {
            @([PSCustomObject]@{ FullName = '/tmp/install.wim' })
        }
        Mock Get-WindowsImage -ModuleName Nova.Imaging {
            @([PSCustomObject]@{ ImageIndex = 1; ImageName = 'Windows 11 Enterprise' })
        }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }
        Mock Write-Success -ModuleName Nova.Imaging { }

        $result = Find-CachedImage -Edition 'Enterprise'
        $result | Should -Be '/tmp/install.wim'
    }

    It 'returns cached image path when edition matches via EditionNameMap' {
        Mock Get-Volume -ModuleName Nova.Imaging {
            @([PSCustomObject]@{ DriveLetter = 'E'; DriveType = 'Removable' })
        }
        Mock Join-Path -ModuleName Nova.Imaging { '/tmp' }
        Mock Get-ChildItem -ModuleName Nova.Imaging -MockWith {
            @([PSCustomObject]@{ FullName = '/tmp/win11.wim' })
        }
        Mock Get-WindowsImage -ModuleName Nova.Imaging {
            @([PSCustomObject]@{ ImageIndex = 2; ImageName = 'Windows 11 Pro' })
        }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }
        Mock Write-Success -ModuleName Nova.Imaging { }

        # 'Professional' maps to 'Pro' via EditionNameMap
        $result = Find-CachedImage -Edition 'Professional'
        $result | Should -Be '/tmp/win11.wim'
    }

    It 'excludes drives listed in ExcludeDrives' {
        Mock Get-Volume -ModuleName Nova.Imaging {
            @(
                [PSCustomObject]@{ DriveLetter = 'X'; DriveType = 'Fixed' }
                [PSCustomObject]@{ DriveLetter = 'C'; DriveType = 'Fixed' }
            )
        }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }

        $result = Find-CachedImage -Edition 'Professional' -ExcludeDrives @('X', 'C')
        $result | Should -BeNullOrEmpty
    }

    It 'falls back to filesystem scan when Get-Volume throws' {
        Mock Get-Volume -ModuleName Nova.Imaging { throw 'Not available' }
        Mock Test-Path -ModuleName Nova.Imaging { $false }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }

        $result = Find-CachedImage -Edition 'Professional'
        $result | Should -BeNullOrEmpty
    }

    It 'skips unreadable image files gracefully' {
        Mock Get-Volume -ModuleName Nova.Imaging {
            @([PSCustomObject]@{ DriveLetter = 'F'; DriveType = 'Removable' })
        }
        Mock Join-Path -ModuleName Nova.Imaging { '/tmp' }
        Mock Get-ChildItem -ModuleName Nova.Imaging -MockWith {
            @([PSCustomObject]@{ FullName = '/tmp/install.esd' })
        }
        Mock Get-WindowsImage -ModuleName Nova.Imaging { throw 'Corrupted image' }
        Mock Write-Step -ModuleName Nova.Imaging { }
        Mock Write-Detail -ModuleName Nova.Imaging { }

        $result = Find-CachedImage -Edition 'Professional'
        $result | Should -BeNullOrEmpty
    }

    It 'has correct parameter defaults' {
        $cmd = Get-Command Find-CachedImage
        $cmd.Parameters['Edition'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            ForEach-Object { $_.Mandatory } | Should -Be $false
        $cmd.Parameters['Architecture'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            ForEach-Object { $_.Mandatory } | Should -Be $false
    }
}

Describe 'Module exports' {
    It 'exports exactly the expected functions' {
        $mod = Get-Module Nova.Imaging
        $expectedFunctions = @(
            'Find-WindowsESD'
            'Get-WindowsImageSource'
            'Install-WindowsImage'
            'Set-Bootloader'
            'Get-EditionNameMap'
            'Find-CachedImage'
        )
        $mod.ExportedFunctions.Keys | Sort-Object | Should -Be ($expectedFunctions | Sort-Object)
    }

    It 'exports no cmdlets' {
        $mod = Get-Module Nova.Imaging
        $mod.ExportedCmdlets.Count | Should -Be 0
    }

    It 'exports no variables' {
        $mod = Get-Module Nova.Imaging
        $mod.ExportedVariables.Count | Should -Be 0
    }

    It 'exports no aliases' {
        $mod = Get-Module Nova.Imaging
        $mod.ExportedAliases.Count | Should -Be 0
    }
}

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
    Import-Module "$PSScriptRoot/../Modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../Modules/Nova.Platform" -Force
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force
    Import-ScriptFunctions -Path "$PSScriptRoot/../Nova.ps1"
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

#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for Nova.ps1 utility / pure functions.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/TestHelper.psm1" -Force
    Import-ScriptFunctions -Path "$PSScriptRoot/../Nova.ps1"
}

Describe 'Get-FileSizeReadable' {
    It 'formats gigabytes' {
        Get-FileSizeReadable -Bytes 1073741824 | Should -Be '1.00 GB'
    }

    It 'formats fractional gigabytes' {
        Get-FileSizeReadable -Bytes 1610612736 | Should -Be '1.50 GB'
    }

    It 'formats megabytes' {
        Get-FileSizeReadable -Bytes 1048576 | Should -Be '1.00 MB'
    }

    It 'formats kilobytes' {
        Get-FileSizeReadable -Bytes 1024 | Should -Be '1.00 KB'
    }

    It 'formats bytes' {
        Get-FileSizeReadable -Bytes 42 | Should -Be '42 B'
    }

    It 'handles zero' {
        Get-FileSizeReadable -Bytes 0 | Should -Be '0 B'
    }
}

Describe 'Write-Step' {
    It 'writes cyan message with [Nova] prefix' {
        Mock Write-Host {}
        Write-Step 'Installing drivers'
        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -eq "`n[Nova] Installing drivers" -and $ForegroundColor -eq 'Cyan'
        }
    }
}

Describe 'Write-Success' {
    It 'writes green message with [OK] prefix' {
        Mock Write-Host {}
        Write-Success 'Done'
        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -eq '[OK] Done' -and $ForegroundColor -eq 'Green'
        }
    }
}

Describe 'Write-Warn' {
    It 'writes yellow message with [WARN] prefix' {
        Mock Write-Host {}
        Write-Warn 'Slow network'
        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -eq '[WARN] Slow network' -and $ForegroundColor -eq 'Yellow'
        }
    }
}

Describe 'Write-Fail' {
    It 'writes red message with [FAIL] prefix' {
        Mock Write-Host {}
        Write-Fail 'Disk error'
        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -eq '[FAIL] Disk error' -and $ForegroundColor -eq 'Red'
        }
    }
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

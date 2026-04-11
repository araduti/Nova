#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Logging shared module.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
}

# ── Timestamp format regex (used across multiple test blocks) ──────────────
# Matches [YYYY-MM-DD HH:MM:SS]
$script:TsPattern = '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'

Describe 'Write-Step' {
    It 'writes cyan message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Step 'Installing drivers'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[>\] Installing drivers' -and $ForegroundColor -eq 'Cyan'
        }
    }

    It 'includes a timestamp in the output' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Step 'Timestamp test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }
    }
}

Describe 'Write-Success' {
    It 'writes green message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Success 'Done'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[\+\] Done' -and $ForegroundColor -eq 'Green'
        }
    }

    It 'includes a timestamp in the output' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Success 'Timestamp test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }
    }
}

Describe 'Write-Warn' {
    It 'writes yellow message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Warn 'Low disk'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[!\] Low disk' -and $ForegroundColor -eq 'Yellow'
        }
    }

    It 'includes a timestamp in the output' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Warn 'Timestamp test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }
    }
}

Describe 'Write-Fail' {
    It 'writes red message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Fail 'Crash'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[X\] Crash' -and $ForegroundColor -eq 'Red'
        }
    }

    It 'includes a timestamp in the output' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Fail 'Timestamp test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }
    }
}

Describe 'Write-Info' {
    It 'writes white informational message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Info 'Downloading file'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[i\] Downloading file' -and $ForegroundColor -eq 'White'
        }
    }

    It 'includes a timestamp in the output' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Info 'Test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }
    }
}

Describe 'Write-Detail' {
    It 'writes DarkGray verbose message with default prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Detail 'Buffer size: 64KB'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[\.\] Buffer size: 64KB' -and $ForegroundColor -eq 'DarkGray'
        }
    }
}

Describe 'Write-Section' {
    It 'writes a magenta section header with separator lines' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Section 'Disk Partitioning'
        # Section writes: empty line + separator + title + separator = 4 calls
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 3 -ParameterFilter {
            $ForegroundColor -eq 'Magenta'
        }
    }

    It 'includes the title text' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Section 'Driver Injection'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match 'Driver Injection' -and $ForegroundColor -eq 'Magenta'
        }
    }
}

Describe 'Write-Data' {
    It 'writes labelled key-value pairs in gray' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Data -Label 'Disk' -Data @{ Size = '500GB'; Type = 'NVMe' }
        # Label line + 2 key-value lines = 3 calls
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 3 -ParameterFilter {
            $ForegroundColor -eq 'Gray'
        }
    }

    It 'includes the label in output' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Write-Data -Label 'Network' -Data @{ IP = '192.168.1.1' }
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match 'Network'
        }
    }
}

Describe 'Set-NovaLogPrefix' {
    BeforeEach {
        # Reset to defaults
        Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    }

    It 'overrides the Write-Step prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Step '[Nova]'
        Write-Step 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[Nova\] test'
        }
    }

    It 'overrides the Write-Success prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Success '[OK]'
        Write-Success 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[OK\] test'
        }
    }

    It 'overrides the Write-Warn prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Warn '[WARN]'
        Write-Warn 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[WARN\] test'
        }
    }

    It 'overrides the Write-Fail prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Fail '[FAIL]'
        Write-Fail 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[FAIL\] test'
        }
    }

    It 'overrides the Write-Info prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Info '[INFO]'
        Write-Info 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[INFO\] test'
        }
    }

    It 'overrides the Write-Detail prefix' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Set-NovaLogPrefix -Detail '[DBG]'
        Write-Detail 'test'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match '\[DBG\] test'
        }
    }
}

Describe 'Start-NovaLog / Stop-NovaLog / Get-NovaLogPath' {
    BeforeEach {
        Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
        $script:TestLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "NovaLogTest-$(Get-Random)"
        $script:TestLogFile = Join-Path $script:TestLogDir 'test.log'
    }

    AfterEach {
        Stop-NovaLog
        if (Test-Path $script:TestLogDir) {
            Remove-Item $script:TestLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Get-NovaLogPath returns empty string before Start-NovaLog' {
        Get-NovaLogPath | Should -Be ''
    }

    It 'Start-NovaLog creates the log file and directory' {
        Start-NovaLog -Path $script:TestLogFile
        Test-Path $script:TestLogFile | Should -Be $true
    }

    It 'Get-NovaLogPath returns the active log path' {
        Start-NovaLog -Path $script:TestLogFile
        Get-NovaLogPath | Should -Be $script:TestLogFile
    }

    It 'Stop-NovaLog writes a closing entry and deactivates logging' {
        Start-NovaLog -Path $script:TestLogFile
        Stop-NovaLog
        Get-NovaLogPath | Should -Be ''
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'Nova log ended'
    }

    It 'Write-Step appends to the log file when active' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Start-NovaLog -Path $script:TestLogFile
        Write-Step 'File log test'
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'STEP.*File log test'
    }

    It 'Write-Success appends to the log file when active' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Start-NovaLog -Path $script:TestLogFile
        Write-Success 'Success file test'
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'OK.*Success file test'
    }

    It 'Write-Warn appends to the log file when active' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Start-NovaLog -Path $script:TestLogFile
        Write-Warn 'Warn file test'
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'WARN.*Warn file test'
    }

    It 'Write-Fail appends to the log file when active' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Start-NovaLog -Path $script:TestLogFile
        Write-Fail 'Fail file test'
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'FAIL.*Fail file test'
    }

    It 'Write-Info appends to the log file when active' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Start-NovaLog -Path $script:TestLogFile
        Write-Info 'Info file test'
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'INFO.*Info file test'
    }

    It 'Write-Detail appends to the log file when active' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Start-NovaLog -Path $script:TestLogFile
        Write-Detail 'Detail file test'
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'DETAIL.*Detail file test'
    }

    It 'Log file header includes environment info' {
        Start-NovaLog -Path $script:TestLogFile
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'Nova log started'
        $content | Should -Match 'PS Version'
    }

    It 'Write-Data appends structured data to the log file' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Start-NovaLog -Path $script:TestLogFile
        Write-Data -Label 'Config' -Data @{ Mode = 'Test' }
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'Config'
        $content | Should -Match 'Mode = Test'
    }

    It 'Write-Section appends section header to the log file' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Start-NovaLog -Path $script:TestLogFile
        Write-Section 'Build Phase'
        $content = Get-Content $script:TestLogFile -Raw
        $content | Should -Match 'Build Phase'
        $content | Should -Match '===='
    }
}

Describe 'Show-NovaLogViewer' {
    It 'warns when log file does not exist' {
        Mock -ModuleName Nova.Logging Write-Host {}
        Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
        Mock -ModuleName Nova.Logging Write-Host {}
        Show-NovaLogViewer -Path '/nonexistent/path/log.txt'
        Should -Invoke -ModuleName Nova.Logging Write-Host -Times 1 -ParameterFilter {
            $Object -match 'Log file not found' -and $ForegroundColor -eq 'Yellow'
        }
    }
}

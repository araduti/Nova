#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Reporting module.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Reporting" -Force

    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance { param($ClassName) }
    }
    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        function global:Get-Disk { param($Number) }
    }
}

Describe 'Module Exports' {
    It 'exports expected functions' {
        $mod = Get-Module Nova.Reporting
        $expected = @(
            'Save-DeploymentReport', 'Save-AssetInventory', 'Update-ActiveDeploymentReport',
            'Send-DeploymentAlert', 'Get-GitHubTokenViaEntra', 'Push-ReportToGitHub', 'Export-DeploymentLogs'
        )
        foreach ($fn in $expected) {
            $mod.ExportedFunctions.Keys | Should -Contain $fn
        }
    }
}

Describe 'Save-DeploymentReport' {
    It 'creates a JSON report file' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova-report-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        try {
            Mock -ModuleName Nova.Reporting Write-Success {}
            Mock -ModuleName Nova.Reporting Push-ReportToGitHub {}
            $reportPath = Join-Path $testDir 'test-report.json'
            Save-DeploymentReport -Status 'success' -DeviceName 'TEST-PC' -ReportPath $reportPath -ScratchDir $testDir
            $reportPath | Should -Exist
            $json = Get-Content $reportPath -Raw | ConvertFrom-Json
            $json.status | Should -Be 'success'
            $json.deviceName | Should -Be 'TEST-PC'
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'includes error info for failed deployments' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova-report2-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        try {
            Mock -ModuleName Nova.Reporting Write-Success {}
            Mock -ModuleName Nova.Reporting Push-ReportToGitHub {}
            $reportPath = Join-Path $testDir 'test-report.json'
            Save-DeploymentReport -Status 'failed' -DeviceName 'FAIL-PC' -ErrorMessage 'Disk error' -FailedStep 'PartitionDisk' -ReportPath $reportPath -ScratchDir $testDir
            $json = Get-Content $reportPath -Raw | ConvertFrom-Json
            $json.status | Should -Be 'failed'
            $json.error | Should -Be 'Disk error'
            $json.failedStep | Should -Be 'PartitionDisk'
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-GitHubTokenViaEntra' {
    It 'returns null when no Entra token is set' {
        $origToken = $env:NOVA_GRAPH_TOKEN
        $env:NOVA_GRAPH_TOKEN = ''
        try {
            $result = Get-GitHubTokenViaEntra -GitHubUser 'test' -GitHubRepo 'test' -GitHubBranch 'main'
            $result | Should -BeNullOrEmpty
        } finally {
            $env:NOVA_GRAPH_TOKEN = $origToken
        }
    }
}

Describe 'Push-ReportToGitHub' {
    It 'silently returns when no token available' {
        $origToken = $env:GITHUB_TOKEN
        $origGraph = $env:NOVA_GRAPH_TOKEN
        $env:GITHUB_TOKEN = ''
        $env:NOVA_GRAPH_TOKEN = ''
        try {
            $params = @{
                FilePath = 'test.json'
                Content = @{ test = 1 }
                GitHubUser = 'u'
                GitHubRepo = 'r'
                GitHubBranch = 'b'
            }
            { Push-ReportToGitHub @params } | Should -Not -Throw
        } finally {
            $env:GITHUB_TOKEN = $origToken
            $env:NOVA_GRAPH_TOKEN = $origGraph
        }
    }
}

Describe 'Send-DeploymentAlert' {
    It 'silently skips when alert config is not available' {
        Mock -ModuleName Nova.Reporting Invoke-RestMethod { throw 'not found' }
        $params = @{
            Status = 'success'
            DeviceName = 'TEST'
            GitHubUser = 'x'
            GitHubRepo = 'y'
            GitHubBranch = 'z'
        }
        { Send-DeploymentAlert @params } | Should -Not -Throw
    }
}

Describe 'Export-DeploymentLogs' {
    It 'does not throw when no log files exist' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova-logs-$(New-Guid)"
        try {
            Mock -ModuleName Nova.Reporting Write-Success {}
            Mock -ModuleName Nova.Reporting Write-Warn {}
            { Export-DeploymentLogs -OSDriveLetter $testDir } | Should -Not -Throw
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Update-ActiveDeploymentReport' {
    It 'creates active deployment JSON' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova-active-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        try {
            Mock -ModuleName Nova.Reporting Push-ReportToGitHub {}
            $reportPath = Join-Path $testDir 'active.json'
            Update-ActiveDeploymentReport -DeviceName 'TEST' -Progress 50 -CurrentStep 'Installing' -ReportPath $reportPath -ScratchDir $testDir
            $reportPath | Should -Exist
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'clears active deployment file' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova-active2-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $reportPath = Join-Path $testDir 'active.json'
        '{}' | Set-Content $reportPath
        try {
            Mock -ModuleName Nova.Reporting Push-ReportToGitHub {}
            Update-ActiveDeploymentReport -DeviceName 'TEST' -Clear -ReportPath $reportPath -ScratchDir $testDir
            $reportPath | Should -Not -Exist
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Save-AssetInventory' {
    It 'creates asset inventory JSON' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "nova-asset-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        try {
            Mock -ModuleName Nova.Reporting Get-CimInstance { $null }
            Mock -ModuleName Nova.Reporting Get-Disk { $null }
            Mock -ModuleName Nova.Reporting Write-Success {}
            Mock -ModuleName Nova.Reporting Push-ReportToGitHub {}
            Save-AssetInventory -ComputerName 'TEST-PC' -ReportDir $testDir -ScratchDir $testDir
            $files = Get-ChildItem $testDir -Filter 'asset-inventory-*.json'
            $files.Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
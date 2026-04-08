#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
.SYNOPSIS
    Pester v5 tests for the Nova.Disk module.
.DESCRIPTION
    Tests disk partitioning functions.
    Windows-only cmdlets are stubbed for cross-platform CI.
#>

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Logging" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Platform" -Force
    Import-Module "$PSScriptRoot/../../src/modules/Nova.Disk" -Force

    # Stubs for Windows-only cmdlets
    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        function global:Get-Disk { param($Number) }
    }
    if (-not (Get-Command Clear-Disk -ErrorAction SilentlyContinue)) {
        function global:Clear-Disk { param($Number, [switch]$RemoveData, [switch]$RemoveOEM, [switch]$ConfirmAction) }
    }
    if (-not (Get-Command Initialize-Disk -ErrorAction SilentlyContinue)) {
        function global:Initialize-Disk { param($Number, $PartitionStyle) }
    }
    if (-not (Get-Command New-Partition -ErrorAction SilentlyContinue)) {
        function global:New-Partition { param($DiskNumber, $Size, $GptType, [switch]$UseMaximumSize, [switch]$IsActive, $MbrType) }
    }
    if (-not (Get-Command Format-Volume -ErrorAction SilentlyContinue)) {
        function global:Format-Volume { param($Partition, $FileSystem, $NewFileSystemLabel, [switch]$ConfirmAction) }
    }
    if (-not (Get-Command Add-PartitionAccessPath -ErrorAction SilentlyContinue)) {
        function global:Add-PartitionAccessPath { param($DiskNumber, $PartitionNumber, [switch]$AssignDriveLetter) }
    }
    if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        function global:Get-Partition { param($DiskNumber, $PartitionNumber) }
    }
    if (-not (Get-Command Set-Partition -ErrorAction SilentlyContinue)) {
        function global:Set-Partition { param($DiskNumber, $PartitionNumber, $NewDriveLetter, $GptType) }
    }
    if (-not (Get-Command Remove-PartitionAccessPath -ErrorAction SilentlyContinue)) {
        function global:Remove-PartitionAccessPath { param($DiskNumber, $PartitionNumber, $AccessPath) }
    }
    if (-not (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) {
        function global:Confirm-SecureBootUEFI { }
    }
}

Describe 'Module Exports' {
    It 'exports expected functions' {
        $mod = Get-Module Nova.Disk
        $expected = @('Get-TargetDisk', 'Initialize-TargetDisk', 'Get-PartitionGuid')
        foreach ($fn in $expected) {
            $mod.ExportedFunctions.Keys | Should -Contain $fn
        }
    }
}

Describe 'Get-PartitionGuid' {
    It 'returns hashtable with expected keys' {
        $guids = Get-PartitionGuid
        $guids.Keys | Should -Contain 'Esp'
        $guids.Keys | Should -Contain 'Msr'
        $guids.Keys | Should -Contain 'BasicData'
        $guids.Keys | Should -Contain 'Recovery'
    }

    It 'returns valid GUID strings' {
        $guids = Get-PartitionGuid
        $guids.Esp | Should -Match '^\{[0-9a-fA-F-]+\}$'
        $guids.Msr | Should -Match '^\{[0-9a-fA-F-]+\}$'
    }
}

Describe 'Get-TargetDisk' {
    It 'returns specified disk number when valid' {
        Mock -ModuleName Nova.Disk Get-Disk { [pscustomobject]@{ Number = 0; FriendlyName = 'TestDisk'; Size = 500GB } }
        $result = Get-TargetDisk -DiskNumber 0
        $result | Should -Be 0
    }

    It 'auto-selects largest eligible disk' {
        Mock -ModuleName Nova.Disk Write-Step {}
        Mock -ModuleName Nova.Disk Get-Disk {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'Small'; Size = 100GB; BusType = 'SATA'; IsReadOnly = $false; OperationalStatus = 'Online' },
                [pscustomobject]@{ Number = 1; FriendlyName = 'Big'; Size = 500GB; BusType = 'NVMe'; IsReadOnly = $false; OperationalStatus = 'Online' }
            )
        }
        Mock -ModuleName Nova.Disk Get-FileSizeReadable { '500 GB' }
        $result = Get-TargetDisk -DiskNumber -1
        $result | Should -Be 1
    }

    It 'throws when no eligible disks found for auto-select' {
        Mock -ModuleName Nova.Disk Get-Disk { @() }
        { Get-TargetDisk -DiskNumber -1 } | Should -Throw '*Auto-select failed*'
    }
}
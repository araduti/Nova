# Nova Module Architecture

Nova's deployment engine is built from **17 PowerShell modules** in `src/modules/`, consumed by three main scripts. This document describes each module, the import patterns, and the conventions that keep everything working across PowerShell 5.1 (production/WinPE) and PowerShell 7 (CI).

---

## Module Inventory

### Core Infrastructure (no module dependencies)

| Module | Purpose | Exported Functions |
|--------|---------|-------------------|
| **Nova.Logging** | Colour-coded console logging with configurable prefixes | `Set-NovaLogPrefix`, `Write-Step`, `Write-Success`, `Write-Warn`, `Write-Fail` |
| **Nova.Platform** | Firmware type detection, CPU architecture mapping, file-size formatting | `Get-FirmwareType`, `Get-WinPEArchitecture`, `Get-FileSizeReadable` |
| **Nova.Network** | TCP tuning, IP validation, internet connectivity probing, WiFi management | `Invoke-NetworkTuning`, `Test-HasValidIP`, `Test-InternetConnectivity`, `Start-WlanService`, `Get-WiFiNetwork`, `Get-SignalBar`, `Connect-WiFiNetwork` |
| **Nova.Proxy** | Corporate HTTP/HTTPS proxy configuration for .NET and environment variables | `Set-NovaProxy`, `Get-NovaProxy`, `Clear-NovaProxy` |

### Build-Phase Modules (used by Trigger.ps1)

| Module | Purpose | Exported Functions |
|--------|---------|-------------------|
| **Nova.Integrity** | SHA256 hash verification against `config/hashes.json` | `Confirm-FileIntegrity` |
| **Nova.WinRE** | WinRE discovery from System32 or recovery partition, recovery-package removal | `Get-WinREPath`, `Get-WinREPathFromWindowsISO`, `Remove-WinRERecoveryPackage` |
| **Nova.ADK** | Windows ADK registry detection, installation validation, WinPE file copy | `Get-ADKRoot`, `Assert-ADKInstalled`, `Copy-WinPEFile` |
| **Nova.BuildConfig** | Interactive build configuration UI, language/package selection, config persistence | `Get-BuildConfigPath`, `Save-BuildConfiguration`, `Read-SavedBuildConfiguration`, `Resolve-WinPEPackagePath`, `Show-BuildConfiguration`, `Get-DefaultLanguage`, `Get-AvailableWinPEPackages` |
| **Nova.Auth** | M365/Entra ID OAuth2 authentication (WebView2 + kiosk Edge flows) | `Install-WebView2SDK`, `Show-WebView2AuthPopup`, `Invoke-M365DeviceCodeAuth`, `Update-M365Token`, `Invoke-KioskM365Auth` |
| **Nova.BCD** | Boot Configuration Data management for WinPE boot entries | `Invoke-Bcdedit`, `New-BcdEntry`, `New-BCDRamdiskEntry` |
| **Nova.CloudImage** | Cloud boot image management via GitHub Releases | `Get-CloudBootImage`, `Publish-BootImage` |

### Deployment-Phase Modules (used by Bootstrap.ps1 and Nova.ps1 inside WinPE)

| Module | Purpose | Exported Functions |
|--------|---------|-------------------|
| **Nova.Disk** | Disk partitioning for UEFI (GPT) and BIOS (MBR) layouts | `Get-TargetDisk`, `Initialize-TargetDisk`, `Get-PartitionGuid` |
| **Nova.Imaging** | Windows image source resolution, ESD/WIM download, image application, bootloader setup | `Find-WindowsESD`, `Get-WindowsImageSource`, `Install-WindowsImage`, `Set-Bootloader`, `Get-EditionNameMap` |
| **Nova.Drivers** | OEM driver injection for Dell, HP, Lenovo, Microsoft Surface | `Add-Driver`, `Initialize-NuGetProvider`, `Install-OemModule`, `Get-SystemManufacturer`, `Add-DellDriver`, `Add-HpDriver`, `Add-LenovoDriver`, `Add-SurfaceDriver`, `Invoke-OemDriverInjection` |
| **Nova.Provisioning** | First-boot provisioning: Autopilot, ConfigMgr, OOBE, BitLocker, apps, Windows Update | `Add-SetupCompleteEntry`, `Set-AutopilotConfig`, `Invoke-AutopilotImport`, `Install-CCMSetup`, `Set-OOBECustomization`, `Enable-BitLockerProtection`, `Invoke-PostScript`, `Install-Application`, `Invoke-WindowsUpdateStaging` |
| **Nova.TaskSequence** | Task sequence JSON parsing, condition evaluation, dry-run validation | `Read-TaskSequence`, `Test-StepCondition`, `Invoke-DryRunValidation`, `Update-TaskSequenceFromConfig` |
| **Nova.Reporting** | Deployment reports, asset inventory, GitHub status push, log export | `Save-DeploymentReport`, `Save-AssetInventory`, `Update-ActiveDeploymentReport`, `Send-DeploymentAlert`, `Get-GitHubTokenViaEntra`, `Push-ReportToGitHub`, `Export-DeploymentLogs` |

---

## Script-to-Module Import Map

| Script | Runs In | Modules Imported |
|--------|---------|-----------------|
| **Trigger.ps1** | Full Windows (admin PowerShell) | Logging, Platform, Integrity, WinRE, ADK, BuildConfig, Auth, BCD, CloudImage |
| **Bootstrap.ps1** | WinPE/WinRE | Network, TaskSequence, Auth, Proxy (optional) |
| **Nova.ps1** | WinPE/WinRE | Logging, Platform, Reporting, Disk, Imaging, Drivers, Provisioning, TaskSequence |

---

## Module Resolution

Scripts resolve the module root directory using this priority:

1. **Local repo**: `$PSScriptRoot\..\modules` -- used during development and when running from a cloned repo.
2. **WinPE staging**: `X:\Windows\System32\Modules` -- used when modules are staged into the WinPE image by Trigger.ps1.
3. **iex download**: When `$PSScriptRoot` is empty (running via `iex (irm ...)`), modules are downloaded from GitHub to a temp directory.

### iex Download Blocks

Trigger.ps1 contains two separate download blocks for the `iex (irm ...)` scenario:

- **Trigger.ps1's own modules** (~line 106): Downloads 9 build-phase modules.
- **WinPE module staging** (~line 600): Downloads 11 deployment-phase modules (including Nova.Proxy) to embed into the WinPE image.

---

## Dependency Graph

```
No dependencies:          Nova.Logging, Nova.Network, Nova.Platform, Nova.Proxy
Depends on Logging:       Nova.ADK, Nova.Auth, Nova.BuildConfig, Nova.CloudImage,
                          Nova.Drivers, Nova.Integrity, Nova.Provisioning,
                          Nova.Reporting, Nova.WinRE
Depends on Logging+more:  Nova.BCD (Logging, Platform)
                          Nova.Disk (Logging, Platform)
                          Nova.Imaging (Logging, Platform)
                          Nova.TaskSequence (Logging)
```

---

## Conventions

### File Structure

Each module lives in `src/modules/<ModuleName>/` with exactly two files:

```
src/modules/Nova.Example/
    Nova.Example.psm1    # Module code
    Nova.Example.psd1    # Module manifest
```

### Encoding

- All `.psm1` and `.psd1` files **must** have a UTF-8 BOM (`EF BB BF`). PowerShell 5.1 defaults to Windows-1252 without it.
- `Trigger.ps1` must **not** have a BOM -- the BOM character prevents `iex` from parsing the first line.
- Never use em dashes (U+2014) or en dashes (U+2013) in string literals. Use `--` instead. Their UTF-8 bytes contain `0x93`/`0x94` which map to smart quotes in Windows-1252.

### Export Pattern

Every module must use **both** export mechanisms:

```powershell
# In .psm1 -- explicit export
Export-ModuleMember -Function Get-Example, Set-Example

# In .psd1 -- manifest declaration
FunctionsToExport = @('Get-Example', 'Set-Example')
```

### Function Design

- All public functions use `[CmdletBinding()]`.
- State-changing functions (disk ops, driver injection) use `[CmdletBinding(SupportsShouldProcess)]`.
- Accessor functions for module-scoped constants use `[CmdletBinding()] param()`.
- Strict parameter typing and validation attributes.

### Manifest Requirements

- Unique `GUID` per module (CI checks for duplicates).
- `RequiredModules` declares dependencies.
- `Author = 'Nova Contributors'`, `CompanyName = 'Ampliosoft'`.
- `PowerShellVersion = '5.1'`.
- `PSData.Tags` for discoverability.

---

## Testing

Tests live in `tests/powershell/` with one file per module:

```
tests/powershell/Nova.Example.Tests.ps1
```

### Conventions

- Import modules via `$PSScriptRoot/../../src/modules/Nova.Example`.
- Use `Mock -ModuleName Nova.Example` for proper mock scoping.
- Stub Windows-only cmdlets (e.g. `Get-WindowsPackage`) for cross-platform CI.
- Run with: `pwsh -c "Invoke-Pester ./tests/powershell"`.

### Current Coverage

- **216+ tests** across 20 files (17 module tests + 2 script tests + 1 test helper).
- All tests pass on both Ubuntu (CI) and Windows.

---

## CI Guardrails

The `validate-modules` job in `.github/workflows/ci.yml` enforces:

1. **Manifest validation** -- `Test-ModuleManifest` on all 17 `.psd1` files.
2. **GUID uniqueness** -- no two modules share a GUID.
3. **UTF-8 BOM** -- all `.psm1`/`.psd1` files have the BOM.
4. **No en/em dashes** -- scans module source for problematic Unicode characters.

---

## Adding a New Module

1. Create `src/modules/Nova.NewModule/Nova.NewModule.psm1` and `.psd1` with UTF-8 BOM.
2. Generate a unique GUID for the manifest.
3. Add `Export-ModuleMember` in `.psm1` and matching `FunctionsToExport` in `.psd1`.
4. Add `Import-Module` to the relevant script(s) (Trigger.ps1, Bootstrap.ps1, or Nova.ps1).
5. Add to the appropriate iex download block if needed.
6. Create `tests/powershell/Nova.NewModule.Tests.ps1`.
7. CI will auto-regenerate `config/hashes.json` on push.

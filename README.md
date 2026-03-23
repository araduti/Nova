# AmpCloud

> **GitHub-native OSDCloud replacement.** No USB, no ISO, no local media.  
> Stages a tiny WinPE on the C: drive, boots it via BCD ramdisk, then streams the full OSD engine directly from raw GitHub URLs.

---

## Quick Start

Run this single command on any Windows PC (as Administrator):

```powershell
irm https://raw.githubusercontent.com/araduti/AmpCloud/main/Trigger.ps1 | iex
```

That's it. AmpCloud handles everything else automatically.

---

## How It Works

```
User runs one-liner
       │
       ▼
┌──────────────┐
│  Trigger.ps1 │  ← Runs on existing Windows
│  (GitHub raw)│
└──────┬───────┘
       │  1. Installs ADK + WinPE add-on (if missing)
       │  2. Builds custom WinPE (with PowerShell, WMI, DISM)
       │  3. Embeds Bootstrap.ps1 + winpeshl.ini
       │  4. Creates BCD ramdisk entry
       │  5. Reboots into WinPE
       ▼
┌────────────────┐
│ Bootstrap.ps1  │  ← Runs inside WinPE on reboot
│ (in WinPE)     │
└──────┬─────────┘
       │  1. Detects internet connectivity (waits up to 10 min)
       │  2. Fetches AmpCloud.ps1 from GitHub raw URL
       │  3. Executes AmpCloud.ps1 in memory
       ▼
┌──────────────────┐
│  AmpCloud.ps1    │  ← Full imaging engine (streamed from GitHub)
│  (GitHub raw)    │
└──────────────────┘
       │  1. Partitions disk (UEFI GPT or BIOS MBR)
       │  2. Downloads Windows WIM/ESD (Microsoft or custom URL)
       │  3. Applies image with DISM
       │  4. Configures bootloader (bcdboot)
       │  5. Injects drivers
       │  6. Applies Autopilot/Intune JSON
       │  7. Stages ConfigMgr CCMSetup
       │  8. Applies OOBE customization (unattend.xml)
       │  9. Stages post-provisioning scripts
       │ 10. Reboots into fresh Windows
       ▼
   Windows OOBE
```

---

## Core Architecture

### `Trigger.ps1` — Entry Point

Runs on any existing Windows installation (bare-metal or VM).

**What it does:**
- Auto-detects and installs the latest **Windows ADK** and **WinPE add-on** if missing
- Builds a custom WinPE with PowerShell, WMI, StorageWMI, and DISM cmdlets
- Fetches `Bootstrap.ps1` from GitHub and embeds it in the WinPE image
- Creates a `winpeshl.ini` to auto-launch `Bootstrap.ps1` on WinPE boot
- Creates a **BCD ramdisk entry** pointing to the WinPE WIM at `C:\AmpCloud\boot.wim`
- Reboots into WinPE (10-second countdown, can be cancelled)

**Parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `GitHubUser` | `araduti` | GitHub username |
| `GitHubRepo` | `AmpCloud` | Repository name |
| `GitHubBranch` | `main` | Branch to fetch scripts from |
| `WinPEWorkDir` | `C:\AmpCloud\WinPE` | Working directory for WinPE build |
| `RamdiskVHD` | `C:\AmpCloud\boot.vhd` | Path for BCD ramdisk files |
| `ADKInstallPath` | `C:\Program Files (x86)\Windows Kits\10` | ADK installation path |
| `NoReboot` | `$false` | Skip automatic reboot |

---

### `Bootstrap.ps1` — WinPE Network Waiter

Embedded in WinPE. Runs automatically on WinPE boot via `winpeshl.ini`.

**What it does:**
- Enables DHCP on all network adapters
- Polls for internet connectivity (tests against GitHub raw, Microsoft, Google)
- Waits up to 10 minutes, retrying every 5 seconds
- Once connected, fetches `AmpCloud.ps1` via `irm` and executes it in memory
- On failure, drops to an interactive `cmd.exe` shell for troubleshooting

**Parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `GitHubUser` | `araduti` | GitHub username |
| `GitHubRepo` | `AmpCloud` | Repository name |
| `GitHubBranch` | `main` | Branch to fetch from |
| `MaxWaitSeconds` | `600` | Maximum seconds to wait for internet |
| `RetryInterval` | `5` | Seconds between connectivity checks |

---

### `AmpCloud.ps1` — Full Imaging Engine

Streamed from GitHub at runtime. Never needs to be rebuilt or redeployed.

**What it does:**
1. **Disk Partitioning** — Initializes target disk with GPT (UEFI) or MBR (BIOS) layout
2. **Windows Image Download** — Fetches Windows WIM/ESD from Microsoft's ESD catalog or a custom URL
3. **Image Application** — Applies the image using DISM (`Expand-WindowsImage`)
4. **Bootloader Configuration** — Runs `bcdboot` to make the installation bootable
5. **Driver Injection** — Recursively adds drivers from a specified path
6. **Autopilot/Intune** — Places `AutopilotConfigurationFile.json` in the correct location
7. **ConfigMgr** — Stages `ccmsetup.exe` for first-boot execution via `SetupComplete.cmd`
8. **OOBE Customization** — Applies custom or default `unattend.xml`
9. **Post-Provisioning Scripts** — Stages PowerShell scripts for first-boot execution
10. **Reboot** — Restarts into the freshly imaged Windows (15-second countdown)

**Parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `TargetDiskNumber` | `0` | Disk to image (disk index) |
| `FirmwareType` | `UEFI` | `UEFI` or `BIOS` |
| `WindowsImageUrl` | _(empty)_ | Direct URL to `.wim` or `.esd`; leave empty to use Microsoft ESD catalog |
| `WindowsEdition` | `Windows 11 Pro` | Edition name to apply |
| `WindowsLanguage` | `en-us` | Language for ESD catalog lookup |
| `DriverPath` | _(empty)_ | Path to folder containing driver `.inf` files |
| `AutopilotJsonUrl` | _(empty)_ | URL to `AutopilotConfigurationFile.json` |
| `AutopilotJsonPath` | _(empty)_ | Local WinPE path to Autopilot JSON |
| `CCMSetupUrl` | _(empty)_ | URL to `ccmsetup.exe` |
| `UnattendUrl` | _(empty)_ | URL to `unattend.xml` |
| `UnattendPath` | _(empty)_ | Local WinPE path to `unattend.xml` |
| `PostScriptUrls` | `@()` | Array of URLs to PowerShell scripts for first-boot |
| `OSDrive` | `W` | Drive letter to assign to the OS partition |

---

## Customization Examples

### Custom Windows image + Autopilot

```powershell
# Pass parameters by modifying AmpCloud.ps1 defaults, or call directly:
$params = @{
    WindowsImageUrl   = 'https://mycdn.example.com/custom-win11.wim'
    WindowsEdition    = 'Windows 11 Enterprise'
    AutopilotJsonUrl  = 'https://mycdn.example.com/autopilot.json'
    UnattendUrl       = 'https://mycdn.example.com/unattend.xml'
    PostScriptUrls    = @(
        'https://mycdn.example.com/Install-Apps.ps1',
        'https://mycdn.example.com/Set-Branding.ps1'
    )
}
# These are set as defaults in AmpCloud.ps1 for zero-touch deployments
```

### Fork and customize

1. Fork this repository
2. Edit `AmpCloud.ps1` to set your defaults (image URL, Autopilot JSON, etc.)
3. Run the trigger with your fork:

```powershell
irm https://raw.githubusercontent.com/YOURUSER/AmpCloud/main/Trigger.ps1 | iex
```

Updates to `AmpCloud.ps1` take effect **immediately** — no rebuilds, no redistribution.

---

## Requirements

### On the source machine (where Trigger.ps1 runs)
- Windows 10/11 or Windows Server 2016+
- Administrator privileges
- Internet access
- ~4 GB free on C: drive (for ADK + WinPE workspace)

### On the target machine (where imaging happens)
- x64 architecture
- Network adapter with DHCP
- Internet access from WinPE
- Disk with sufficient space for Windows installation (minimum ~30 GB recommended)

---

## Key Features

| Feature | Details |
|---------|---------|
| 🚫 Zero media required | No USB, ISO, or PXE server needed |
| ⚡ Instant updates | Edit `AmpCloud.ps1` on GitHub — active immediately |
| 🖥️ Bare-metal or in-place | Works on fresh hardware or existing Windows |
| 🔁 BCD-based reboot | No external boot media |
| 🛡️ Full error handling | No forced reboot until imaging succeeds |
| ☁️ Cloud-native | All scripts streamed from GitHub at runtime |
| 🔧 Autopilot ready | Drop-in Autopilot JSON support |
| 🏢 Intune/ConfigMgr | First-boot CCMSetup staging built in |

---

## Security Considerations

- Always host scripts in a **private** repository if they contain sensitive configuration
- Use GitHub **Releases** or **branch protection** to prevent unauthorized script modification
- Scripts are fetched over HTTPS from GitHub; verify your repository is not compromised
- Consider code-signing scripts and validating signatures in `Bootstrap.ps1` for high-security environments

---

## License

MIT License — see [LICENSE](LICENSE) for details.
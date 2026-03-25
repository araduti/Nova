# AmpCloud

> **GitHub-native OSDCloud replacement.** No USB, no ISO, no local media.  
> Stages a tiny WinRE/WinPE image on the C: drive, boots it via BCD ramdisk, then streams the full OSD engine directly from raw GitHub URLs.
>
> **WiFi support:** AmpCloud uses the machine's existing **WinRE** (Windows Recovery Environment) image as its base, which ships with built-in WiFi hardware drivers (Intel, Realtek, MediaTek, Qualcomm) delivered by Microsoft via Windows Update. This means WiFi works on most laptops without manually injecting device-specific drivers. Recovery tools are stripped and the WIM is re-exported with maximum compression to keep the image small.

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
       │  2. Locates WinRE.wim (built-in WiFi drivers); falls back to ADK winpe.wim
       │  3. Slims WinRE: removes recovery tools, re-exports with max compression
       │  4. Adds PowerShell, WMI, StorageWMI, DISM cmdlets from ADK
       │  5. Embeds Bootstrap.ps1 + winpeshl.ini
       │  6. Creates BCD ramdisk entry
       │  7. Reboots into WinRE/WinPE
       ▼
┌────────────────┐
│ Bootstrap.ps1  │  ← Runs inside WinRE/WinPE on reboot
│ (in WinRE)     │
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
- **Prefers WinRE** (Windows Recovery Environment) as the base boot image because WinRE ships with real WiFi hardware drivers (Intel, Realtek, MediaTek, Qualcomm) that Microsoft delivers via Windows Update — enabling wireless connectivity on most laptops without any manual driver injection. Falls back to the ADK `winpe.wim` if WinRE is not accessible on the source machine.
- Strips WinRE-specific recovery packages (startup repair, boot recovery tools) that are not needed for deployment
- Re-exports the WIM with maximum compression to keep the ramdisk image small
- Adds PowerShell, WMI, StorageWMI, and DISM cmdlets from the ADK (skips packages already present in WinRE)
- Fetches `Bootstrap.ps1` from GitHub and embeds it in the boot image
- Creates a `winpeshl.ini` to auto-launch `Bootstrap.ps1` on boot
- Creates a **BCD ramdisk entry** pointing to the WIM at `C:\AmpCloud\boot.wim`
- Reboots into the cloud boot environment (10-second countdown, can be cancelled)

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

### `Bootstrap.ps1` — WinRE/WinPE Network Waiter

Embedded in the boot image. Runs automatically on boot via `winpeshl.ini`.

**What it does:**
- Enables DHCP on all network adapters
- If no wired internet: presents a graphical WiFi selector (WiFi works out-of-the-box when booted from WinRE due to built-in hardware drivers)
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
| `UnattendContent` | _(empty)_ | Inline XML content for `unattend.xml` (from the editor) |
| `PostScriptUrls` | `@()` | Array of URLs to PowerShell scripts for first-boot |
| `OSDrive` | `C` | Drive letter to assign to the OS partition |

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
- Network adapter with DHCP (wired) **or** WiFi (Intel/Realtek/MediaTek/Qualcomm — supported natively by WinRE)
- Internet access from the boot environment
- Disk with sufficient space for Windows installation (minimum ~30 GB recommended)

---

## Key Features

| Feature | Details |
|---------|---------|
| 🚫 Zero media required | No USB, ISO, or PXE server needed |
| 📡 WiFi out-of-the-box | WinRE base image includes Intel, Realtek, MediaTek & Qualcomm drivers |
| ⚡ Instant updates | Edit `AmpCloud.ps1` on GitHub — active immediately |
| 🖥️ Bare-metal or in-place | Works on fresh hardware or existing Windows |
| 🔁 BCD-based reboot | No external boot media |
| 🛡️ Full error handling | No forced reboot until imaging succeeds |
| ☁️ Cloud-native | All scripts streamed from GitHub at runtime |
| 🔧 Autopilot ready | Drop-in Autopilot JSON support |
| 🏢 Intune/ConfigMgr | First-boot CCMSetup staging built in |

---

## Task Sequence Editor

AmpCloud includes a browser-based Task Sequence Editor for visually creating and editing deployment task sequences.

**Live editor:** [https://araduti.github.io/AmpCloud/Editor/](https://araduti.github.io/AmpCloud/Editor/)

- Create, reorder, and configure deployment steps in a drag-and-drop interface
- Open existing `default.json` task sequences or start from scratch
- Export edited sequences as JSON for use with the `-TaskSequencePath` parameter

The editor is a static web app (HTML/CSS/JS) hosted on GitHub Pages and requires no installation.

---

## Security Considerations

- Always host scripts in a **private** repository if they contain sensitive configuration
- Use GitHub **Releases** or **branch protection** to prevent unauthorized script modification
- Scripts are fetched over HTTPS from GitHub; verify your repository is not compromised
- Consider code-signing scripts and validating signatures in `Bootstrap.ps1` for high-security environments

### Microsoft 365 Authentication (Entra ID)

AmpCloud supports an optional **M365 authentication gate** that blocks unauthorised users from deploying images and editing task sequences. When enabled, operators must sign in with a Microsoft 365 account from an Entra ID tenant that is explicitly allowed in the app registration.

Tenant restrictions are managed directly in the **Entra ID app registration** under **Authentication → Supported accounts → Allow only certain tenants**. There is no client-side tenant allow-list — Azure AD rejects sign-in attempts from tenants that are not permitted.

**What is protected:**

- **Deployment engine** (Bootstrap.ps1) — after network connectivity, operators sign in via a **standalone Edge browser** (Authorization Code Flow with PKCE) launched directly inside WinPE. Falls back to Device Code Flow if the Edge browser is unavailable.
- **Task Sequence Editor** (web UI) — a login overlay blocks the editor until the user signs in via MSAL popup

**How it works:**

1. Both the engine and editor fetch [`Config/auth.json`](Config/auth.json) to check if authentication is required.
2. If `requireAuth` is `true`, sign-in is enforced.
3. In WinPE, the engine launches **Microsoft Edge** with GPU-disabled flags, navigating to the Azure AD login page. The operator signs in directly in the Edge browser window — no codes to copy or external devices needed. A localhost HTTP listener captures the redirect. If Edge is unavailable, it transparently falls back to **Device Code Flow** with a one-time code and `https://microsoft.com/devicelogin`.
4. In the browser (editor), MSAL.js shows a popup sign-in window.
5. Azure AD enforces tenant restrictions at the app registration level — only allowed tenants can complete sign-in.

**Setup:**

1. **Register an Azure AD application:**
   - Go to [Azure Portal → App registrations → New registration](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
   - Name: e.g. `AmpCloud`
   - Supported account types: **Accounts in any organizational directory** (multi-tenant)
   - Under **Authentication → Supported accounts**, select **Allow only certain tenants** and add the tenant IDs you want to allow
   - Under **Authentication → Advanced settings**, enable **Allow public client flows** (required for Device Code Flow fallback in WinPE)
   - Under **Authentication → Platform configurations → Single-page application**, add your GitHub Pages URL as a redirect URI (e.g. `https://yourusername.github.io/AmpCloud/Editor/`)
   - Under **Authentication → Platform configurations → Mobile and desktop applications**, add `http://localhost` as a redirect URI (required for the Edge browser sign-in in WinPE)
   - Note the **Application (client) ID**

2. **Configure `Config/auth.json`:**

   ```json
   {
       "requireAuth": true,
       "clientId": "YOUR-APPLICATION-CLIENT-ID",
       "redirectUri": "https://yourusername.github.io/AmpCloud/Editor/"
   }
   ```

   | Field | Description |
   |-------|-------------|
   | `requireAuth` | Set to `true` to enforce authentication. When `false` (default), auth is skipped. |
   | `clientId` | The Application (client) ID from your Azure AD app registration. |
   | `redirectUri` | The redirect URI registered in your app registration under **Single-page application** platform. Must match exactly. |

---

## License

MIT License — see [LICENSE](LICENSE) for details.
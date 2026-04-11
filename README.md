<div align="center">

<img src="grok-image-7cdbf1dc-7de8-4200-865e-3785d9bc2187.png" alt="Nova Logo" width="200" />

# **Nova** — Cloud-Native Windows OS Deployment Platform

### Cloud-Native Windows OS Deployment Platform

*An [Ampliosoft](https://ampliosoft.com) open-source project*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/araduti/Nova/actions/workflows/ci.yml/badge.svg)](https://github.com/araduti/Nova/actions/workflows/ci.yml)
[![CodeQL](https://github.com/araduti/Nova/actions/workflows/codeql.yml/badge.svg)](https://github.com/araduti/Nova/actions/workflows/codeql.yml)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue?logo=powershell&logoColor=white)](https://docs.microsoft.com/en-us/powershell/)
[![Windows](https://img.shields.io/badge/Windows-10%2F11%2FServer-0078D6?logo=windows&logoColor=white)](https://www.microsoft.com/windows)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.8-blue?logo=typescript&logoColor=white)](https://www.typescriptlang.org/)

**Zero-media, cloud-native Windows imaging — no USB, no ISO, no PXE.**
Stream the entire deployment engine from GitHub, reimage any PC over WiFi or Ethernet.

[Quick Start](#quick-start) · [How It Works](#how-it-works) · [Task Sequence Editor](#task-sequence-editor) · [Security](#security) · [Contributing](docs/CONTRIBUTING.md) · [Changelog](docs/CHANGELOG.md)

</div>

---

## What Is Nova?

Nova is a **cloud-native Windows OS deployment platform** that replaces traditional OSDCloud, WinPE USB sticks, and PXE infrastructure. Run a single PowerShell command on any Windows PC, and Nova handles everything: building a minimal boot environment, rebooting, connecting to the network (WiFi included), and streaming the full imaging engine directly from GitHub.

**Key differentiators:**

- **No USB, ISO, or PXE** — everything streams from a GitHub repository.
- **WiFi out-of-the-box** — uses the machine's own WinRE, which ships with Microsoft-signed WiFi drivers (Intel, Realtek, MediaTek, Qualcomm).
- **Instant updates** — edit your deployment defaults on GitHub and they take effect immediately. No rebuilds, no redistribution.
- **Enterprise-ready** — optional Microsoft 365 (Entra ID) authentication gate, Autopilot registration, ConfigMgr staging, and OOBE customization.
- **Visual task sequence editor** — browser-based, drag-and-drop UI hosted on GitHub Pages.

---

## Quick Start

Run this command on any Windows PC as **Administrator**:

```powershell
irm https://nova.raduti.com/Trigger.ps1 | iex
```

Or use the raw GitHub URL:

```powershell
irm https://raw.githubusercontent.com/araduti/Nova/main/src/scripts/Trigger.ps1 | iex
```

Nova installs the required tools, builds a compact boot image, reboots, connects to the network, and deploys Windows — all automatically.

> **Tip:** Fork the repository and point the command at your fork to use your own defaults:
> ```powershell
> irm https://raw.githubusercontent.com/YOURUSER/Nova/main/src/scripts/Trigger.ps1 | iex
> ```

---

## How It Works

Nova operates in three stages. Each stage hands off to the next automatically.

```
  ┌──────────────────────────────────────────────────────────────┐
  │  STAGE 1 — Trigger (runs on existing Windows)               │
  │                                                              │
  │  • Installs ADK + WinPE add-on (if missing)                 │
  │  • Extracts WinRE.wim (built-in WiFi drivers)               │
  │  • Strips recovery tools, re-exports with max compression   │
  │  • Injects PowerShell, WMI, DISM cmdlets                    │
  │  • Embeds Bootstrap.ps1 + auto-launcher                     │
  │  • Creates BCD ramdisk entry and reboots                    │
  └──────────────────────┬───────────────────────────────────────┘
                         │ reboot
  ┌──────────────────────▼───────────────────────────────────────┐
  │  STAGE 2 — Bootstrap (runs inside WinRE/WinPE)              │
  │                                                              │
  │  • Initializes network (DHCP + WiFi selector if needed)      │
  │  • Launches real-time HTML progress UI (Edge kiosk mode)     │
  │  • Optional M365 sign-in gate (PKCE or Device Code)         │
  │  • Downloads Nova.ps1 from GitHub                            │
  └──────────────────────┬───────────────────────────────────────┘
                         │
  ┌──────────────────────▼───────────────────────────────────────┐
  │  STAGE 3 — Imaging Engine (runs in WinPE)                   │
  │                                                              │
  │  1. Partition disk (GPT/UEFI or MBR/BIOS)                   │
  │  2. Download Windows ESD/WIM from Microsoft or custom CDN   │
  │  3. Apply image with DISM                                   │
  │  4. Configure bootloader (bcdboot)                          │
  │  5. Inject drivers (manual or OEM auto-detect)              │
  │  6. Embed Autopilot/Intune configuration                    │
  │  7. Stage ConfigMgr ccmsetup                                │
  │  8. Apply OOBE customization (unattend.xml)                 │
  │  9. Stage post-provisioning PowerShell scripts              │
  │ 10. Reboot into Windows                                     │
  └──────────────────────────────────────────────────────────────┘
                         │
                    Windows OOBE → Autopilot → Production
```

---

## Features

| | Feature | Details |
|---|---------|---------|
| 🚫 | **Zero media** | No USB, ISO, or PXE server needed |
| 📡 | **WiFi out-of-the-box** | WinRE ships with Intel, Realtek, MediaTek & Qualcomm drivers |
| ⚡ | **Instant updates** | Edit defaults on GitHub — active immediately |
| 🔐 | **M365 auth gate** | Optional Entra ID sign-in (Auth Code + PKCE primary, Device Code fallback); tenant restrictions server-side |
| 🔧 | **Autopilot ready** | Registers devices and embeds provisioning JSON |
| 🏢 | **Intune / ConfigMgr** | First-boot ccmsetup staging built in |
| 🖥️ | **Bare-metal or in-place** | Works on new hardware or existing Windows |
| 🌐 | **Multi-language** | Localized UI strings (English, Spanish, French, German, Japanese, Portuguese, Chinese) |
| 📋 | **Task sequence editor** | Browser-based drag-and-drop step builder |
| 📊 | **Real-time progress UI** | HTML dashboard in Edge kiosk mode during imaging |

---

## Repository Layout

```
Nova/
├── src/scripts/Trigger.ps1   # Stage 1 — entry point, WinPE builder
├── src/scripts/Bootstrap.ps1 # Stage 2 — network, auth, engine launcher
├── src/scripts/Nova.ps1      # Stage 3 — task-sequence-driven imaging engine
├── src/modules/              # 17 shared PowerShell modules (Nova.*)
├── src/web/nova-ui/          # Real-time progress UI (HTML/CSS/JS, WinPE embedded)
├── src/web/editor/           # Task sequence editor (GitHub Pages SPA)
│   ├── index.html
│   ├── js/app.js
│   ├── css/style.css
│   └── lib/                 # MSAL.js (vendored)
├── src/web/monitoring/       # Live deployment monitoring dashboard
│   └── index.html
├── src/web/dashboard/        # Root dashboard UI (CSS/JS)
├── src/web/progress/         # Pre-boot progress UI (WinPE embedded)
├── config/
│   ├── auth.json            # OAuth / M365 configuration
│   ├── alerts.json          # Notification settings (Teams, Slack, email)
│   ├── hashes.json          # SHA-256 integrity manifest (CI-generated)
│   └── locale/              # UI localization (de, en, es, fr, ja, pt, zh)
├── resources/task-sequence/
│   └── default.json         # Default deployment task sequence
├── resources/autopilot/      # Autopilot device import utilities
├── resources/unattend/       # Default unattend.xml template
├── resources/products.xml    # Microsoft Windows ESD catalog
├── oauth-proxy/             # Cloudflare Worker — GitHub OAuth CORS proxy
│   ├── src/                 # TypeScript source (modular)
│   │   ├── index.ts         # Worker entry point
│   │   ├── cors.ts          # CORS header builder
│   │   ├── crypto.ts        # PKCS key handling, JWT creation
│   │   ├── rate-limit.ts    # Rate limiting
│   │   ├── types.ts         # TypeScript interfaces
│   │   └── handlers/        # Route handlers
│   │       ├── device-flow.ts
│   │       └── token-exchange.ts
│   ├── test/                # Vitest unit tests
│   ├── package.json
│   ├── tsconfig.json
│   └── wrangler.toml
├── vite.config.js           # Vite build config (Editor, Monitoring, Dashboard)
├── package.json             # Root project (Vite build system)
├── deployments/             # Active + historical deployment data
├── docs/                    # Documentation (CONTRIBUTING, SECURITY, CHANGELOG, etc.)
└── index.html               # Root dashboard landing page
```

---

## Requirements

### Source machine (where Trigger.ps1 runs)

- Windows 10 / 11 or Windows Server 2016+
- Administrator privileges
- Internet access
- ~4 GB free on the C: drive (for ADK + WinPE workspace)

### Target machine (where imaging happens)

- x64 architecture (amd64 or arm64 with appropriate WinPE)
- Network adapter with DHCP — wired Ethernet **or** WiFi (Intel, Realtek, MediaTek, Qualcomm supported natively by WinRE)
- Internet access from the boot environment
- ≥ 30 GB disk space for Windows installation

---

## Configuration

### Script Parameters

<details>
<summary><strong>Trigger.ps1</strong> — Entry Point</summary>

| Parameter | Default | Description |
|-----------|---------|-------------|
| `GitHubUser` | `araduti` | GitHub username or organization |
| `GitHubRepo` | `Nova` | Repository name |
| `GitHubBranch` | `main` | Branch to fetch scripts from |
| `WorkDir` | `C:\Nova` | Root working directory for all artefacts |
| `WindowsISOUrl` | _(empty)_ | Path or URL to a Windows ISO (used when WinRE arch/version mismatch requires fresh extraction) |
| `NoReboot` | `$false` | Skip automatic reboot (useful for testing) |
| `AcceptDefaults` | `$false` | Skip all interactive menus and use defaults (for CI/scripted use) |

</details>

<details>
<summary><strong>Bootstrap.ps1</strong> — Network & Auth</summary>

| Parameter | Default | Description |
|-----------|---------|-------------|
| `GitHubUser` | `araduti` | GitHub username |
| `GitHubRepo` | `Nova` | Repository name |
| `GitHubBranch` | `main` | Branch to fetch from |
| `MaxWaitSeconds` | `300` | Maximum seconds to wait for internet |

</details>

<details>
<summary><strong>Nova.ps1</strong> — Imaging Engine</summary>

Nova.ps1 is task-sequence-driven. Individual imaging options (Windows image URL, drivers, Autopilot, unattend, etc.) are configured as steps in the task sequence JSON, not as script parameters.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `GitHubUser` | `araduti` | GitHub username |
| `GitHubRepo` | `Nova` | Repository name |
| `GitHubBranch` | `main` | Branch to fetch from |
| `TargetDiskNumber` | `0` | Disk to image (disk index) |
| `FirmwareType` | `UEFI` | `UEFI` or `BIOS` |
| `ScratchDir` | `X:\Nova` | Scratch / temp directory inside WinPE |
| `OSDrive` | `C` | Drive letter to assign to the OS partition |
| `StatusFile` | _(empty)_ | IPC status file for Bootstrap.ps1 progress UI |
| `TaskSequencePath` | _(required)_ | Path to the task sequence JSON file |
| `DryRun` | `$false` | Validate task sequence without destructive operations |

</details>

### Authentication (`config/auth.json`)

Nova supports an optional **Microsoft 365 authentication gate** using Entra ID. When enabled, operators must sign in before deployment begins.

<details>
<summary><strong>auth.json fields</strong></summary>

| Field | Description |
|-------|-------------|
| `requireAuth` | `true` to enforce sign-in; `false` (default) to skip |
| `clientId` | Azure AD Application (client) ID |
| `redirectUri` | Redirect URI registered under **Single-page application** |
| `autopilotImport` | `true` to import the device into Autopilot during deployment |
| `graphScopes` | Microsoft Graph delegated permissions (e.g. `DeviceManagementServiceConfig.ReadWrite.All`) |
| `githubOwner` | GitHub user/org that owns the repository |
| `githubRepo` | Repository name |
| `githubClientId` | GitHub OAuth App client ID (enables Device Flow for saving task sequences) |
| `githubOAuthProxy` | URL of the Cloudflare Worker CORS proxy for GitHub OAuth |

</details>

<details>
<summary><strong>Setting up M365 authentication</strong></summary>

1. **Register an Azure AD application:**
   - [Azure Portal → App registrations → New registration](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
   - Name: e.g. `Nova`
   - Supported account types: **Accounts in any organizational directory** (multi-tenant)
   - Under **Authentication → Supported accounts**, select **Allow only certain tenants** and add permitted tenant IDs
   - Enable **Allow public client flows** (required for Device Code fallback)
   - Add a **Single-page application** redirect URI pointing to your GitHub Pages editor URL
   - Add a **Mobile and desktop** redirect URI for `http://localhost` (WinPE Edge sign-in)
   - *(Optional)* Add **Microsoft Graph → DeviceManagementServiceConfig.ReadWrite.All** and grant admin consent (for Autopilot import)

2. **Register a GitHub OAuth App** *(optional — for saving task sequences):*
   - [GitHub → Settings → Developer settings → OAuth Apps](https://github.com/settings/developers)
   - Enable **Device Flow**

3. **Deploy the OAuth CORS proxy** *(optional):*
   - See [`oauth-proxy/README.md`](oauth-proxy/README.md) for Cloudflare Worker deployment instructions

4. **Update `config/auth.json`** with your application and client IDs.

</details>

---

## Task Sequence Editor

Nova includes a browser-based **Task Sequence Editor** for visually creating deployment workflows — similar to SCCM/MECM task sequences.

**Live editor:** [https://nova.raduti.com/src/web/editor/](https://nova.raduti.com/src/web/editor/)

- Drag-and-drop step reordering
- Configure each step with dedicated form fields
- Inline unattend.xml editing
- Import and export task sequences as JSON
- Save directly to GitHub via OAuth Device Flow
- Optional M365 login gate

---

## Customization

### Fork-and-own

1. **Fork** this repository
2. Edit `resources/task-sequence/default.json` to configure your deployment steps (image URL, Autopilot, drivers, etc.) or use the [Task Sequence Editor](#task-sequence-editor) to create your own
3. Update `config/auth.json` with your own app registrations
4. Run the trigger pointing at your fork:

```powershell
irm https://raw.githubusercontent.com/YOURUSER/Nova/main/src/scripts/Trigger.ps1 | iex
```

Changes to scripts fetched at runtime (Nova.ps1, task sequences, config) take effect **immediately** — no rebuild cycle. Note that Bootstrap.ps1 is embedded in the boot image, so changes to it require a rebuild.

---

## Development

### Prerequisites

- [Node.js](https://nodejs.org/) 22+ (for build system and oauth-proxy development)
- [PowerShell](https://docs.microsoft.com/en-us/powershell/) 5.1+ (ships with Windows)

### Web UI development

```bash
npm install        # install Vite
npm run dev        # start local dev server with hot reload
npm run build      # production build → dist/
npm run preview    # preview production build locally
```

The Vite build processes the **Editor**, **Monitoring**, and root **Dashboard** pages. Nova-UI and Progress are embedded into WinPE by Trigger.ps1 and run offline — they are not part of the web build.

### OAuth proxy development

```bash
cd oauth-proxy
npm install        # install dependencies (wrangler, TypeScript, vitest)
npm run typecheck  # TypeScript type checking
npm test           # run unit tests
npm run dev        # local Cloudflare Worker dev server
npm run deploy     # deploy to Cloudflare Workers
```

### CI/CD

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | Push/PR to `main` | TypeScript lint, unit tests, PSScriptAnalyzer, web build, hash regeneration, code signing |
| `codeql.yml` | Push/PR to `main` + weekly | CodeQL security scanning (JavaScript/TypeScript) |
| `pages.yml` | Push to `main` (web files) | Build and deploy web UIs to GitHub Pages |
| `release.yml` | Published release | Code signing, hash regeneration, release artifacts |
| `sign.yml` | Manual dispatch | On-demand code signing for all scripts |

---

## Security

Nova follows modern security best practices for public-client OAuth 2.0 applications.

| Area | Approach |
|------|----------|
| **Script delivery** | All scripts fetched over HTTPS from GitHub |
| **TLS** | TLS 1.2 explicitly enforced in WinPE scripts |
| **M365 authentication** | Authorization Code Flow with PKCE; Device Code fallback |
| **Tenant restriction** | Enforced server-side by Entra ID app registration |
| **Token handling** | Ephemeral — tokens are not persisted to disk |
| **Web editor tokens** | Stored in `sessionStorage` (cleared on tab close) |
| **No secrets in code** | Public client IDs only; no client secrets committed |
| **GitHub PAT** | Collected via `SecureString`; memory zeroed after use |

For a detailed analysis of all authentication flows and security findings, see [**SECURITY_ANALYSIS.md**](docs/SECURITY_ANALYSIS.md).

For a comprehensive review of the codebase covering architecture, performance, and improvement opportunities, see [**CODEBASE_ANALYSIS.md**](docs/CODEBASE_ANALYSIS.md).

### Responsible disclosure

If you discover a security vulnerability, please report it privately. See [**SECURITY.md**](docs/SECURITY.md) for our full security policy.

---

## Contributing

Contributions are welcome! Please read [**CONTRIBUTING.md**](docs/CONTRIBUTING.md) before submitting a pull request.

---

## License

This project is licensed under the **MIT License** — see [LICENSE](LICENSE) for details.

---

<div align="center">

*Built with ❤️ by [Ampliosoft](https://ampliosoft.com)*

</div>

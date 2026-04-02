# Changelog

All notable changes to Nova will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Playwright E2E test suite for the Task Sequence Editor (24 tests covering page load, step CRUD, properties editing, validation, file operations, search, undo/redo, and dialog tabs)
- `.gitattributes` with Git LFS tracking rules for driver binaries (`.sys`, `.exe`, `.dll`, `.cat`, `.inf`) and build artefacts
- Playwright CI job in GitHub Actions workflow with artifact upload for test reports
- `test:e2e` npm script for running Playwright tests locally
- Shared PowerShell modules (`Modules/Nova.Logging`, `Modules/Nova.Platform`, `Modules/Nova.Network`) extracted from monolithic scripts
- `Nova.Logging` module: configurable prefix logging (`Write-Step`, `Write-Success`, `Write-Warn`, `Write-Fail`, `Set-NovaLogPrefix`)
- `Nova.Platform` module: firmware detection (`Get-FirmwareType`), architecture mapping (`Get-WinPEArchitecture`), file utilities (`Get-FileSizeReadable`)
- `Nova.Network` module: TCP tuning, connectivity probing, WiFi scanning and connection
- Module-specific Pester tests (`Nova.Logging.Tests.ps1`, `Nova.Platform.Tests.ps1`, `Nova.Network.Tests.ps1`)

### Changed
- Refactored Nova.ps1 to import Nova.Logging and Nova.Platform modules instead of defining duplicate functions inline
- Refactored Trigger.ps1 to import Nova.Logging and Nova.Platform modules, removing duplicate `Write-Step`/`Write-Success`/`Write-Warn`/`Write-Fail` and `Get-FirmwareType` definitions
- Refactored Bootstrap.ps1 to import Nova.Network module, removing inline network utility functions
- Updated Trigger.ps1 `Build-WinPE` to stage `Modules/` directory into WinPE image
- Updated REPORT.md roadmap: marked PowerShell modularization and alerts integration as complete in Phase 4
- Updated existing Pester tests to import shared modules before script functions

## [1.0.0] - 2026-04-01

### Changed
- Rebranded product from "AmpCloud" to "Nova" across all documentation
- Extracted inline CSS/JS from `index.html` into `css/dashboard.css` and `js/dashboard.js`
- Extracted inline CSS/JS from `Monitoring/index.html` into `Monitoring/css/style.css` and `Monitoring/js/app.js`
- Extracted inline CSS/JS from `Editor/index.html` into `Editor/css/login.css`, `Editor/css/style.css`, and `Editor/js/app.js`
- Replaced all inline event handlers (`onclick`, `onchange`, `oninput`) with `addEventListener`
- Tightened CSP headers: removed `'unsafe-inline'` from `script-src` and `style-src` on all pages
- Upgraded MSAL.js from v2.39.0 to v4.30.0 for Editor authentication

### Added
- Dev Container configuration (`.devcontainer/devcontainer.json`) for GitHub Codespaces and VS Code
- OAuth proxy API reference documentation (`docs/oauth-proxy-api.md`)
- PSScriptAnalyzer linting job in CI workflow
- CodeQL security scanning workflow (JavaScript/TypeScript)
- Pester v5 test suite for PowerShell scripts (Nova, Bootstrap, Trigger)
- SHA256 hash validation CI job (`Config/hashes.json`)
- Handler-level tests for OAuth proxy (device-flow, token-exchange, origin enforcement — 19 new tests)
- IP-based rate limiting for OAuth proxy (60 req/min sliding window)
- Vitest tests for Editor utility functions (31 tests)
- Dependabot configuration for automated dependency updates
- GitHub Actions release workflow for automated releases
- Three-stage cloud-native deployment: Trigger → Bootstrap → Imaging Engine
- WiFi support out-of-the-box via WinRE (Intel, Realtek, MediaTek, Qualcomm)
- Browser-based Task Sequence Editor with drag-and-drop step builder
- Real-time HTML progress UI in Edge kiosk mode
- Optional Microsoft 365 (Entra ID) authentication gate with PKCE
- Device Code Flow fallback for constrained environments
- Autopilot device registration and provisioning JSON embedding
- ConfigMgr (`ccmsetup`) first-boot staging
- OOBE customization via `unattend.xml`
- Post-provisioning PowerShell script staging
- OEM driver auto-detection (Dell, HP, Lenovo)
- Multi-language UI support (English, Spanish, French)
- Deployment monitoring dashboard on GitHub Pages
- Active deployment status reporting to GitHub repository
- Cloudflare Worker OAuth proxy for GitHub CORS
- MIT License
- Contributing guidelines, Code of Conduct, and Security Policy

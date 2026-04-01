# Changelog

All notable changes to Nova will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Rebranded product from "AmpCloud" to "Nova" across all documentation
- Extracted inline CSS/JS from `index.html` into `css/dashboard.css` and `js/dashboard.js`
- Extracted inline CSS/JS from `Monitoring/index.html` into `Monitoring/css/style.css` and `Monitoring/js/app.js`
- Replaced all inline event handlers (`onclick`, `onchange`, `oninput`) with `addEventListener`
- Tightened CSP headers: removed `'unsafe-inline'` from `script-src` and `style-src` on `index.html` and `Monitoring/index.html`

### Added
- Dev Container configuration (`.devcontainer/devcontainer.json`) for GitHub Codespaces and VS Code
- OAuth proxy API reference documentation (`docs/oauth-proxy-api.md`)
- PSScriptAnalyzer linting job in CI workflow
- CodeQL security scanning workflow (JavaScript/TypeScript)
- Handler-level tests for OAuth proxy (device-flow, token-exchange, origin enforcement — 19 new tests)
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

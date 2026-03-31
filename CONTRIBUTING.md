# Contributing to Nova

Thank you for your interest in contributing to Nova! This document provides guidelines and information for contributors.

---

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold its standards.

---

## How to Contribute

### Reporting Bugs

1. **Search existing issues** to avoid duplicates
2. Open a new issue with:
   - A clear, descriptive title
   - Steps to reproduce the problem
   - Expected vs. actual behaviour
   - Environment details (Windows version, architecture, network type)
   - Relevant log files (`X:\Nova-Bootstrap.log`, `X:\Nova-Engine.log`)

### Requesting Features

Open an issue describing:
- The use case or problem you're trying to solve
- Your proposed solution (if any)
- Whether you'd be willing to implement it

### Submitting Pull Requests

1. **Fork** the repository
2. Create a feature branch from `main` (`git checkout -b feature/my-change`)
3. Make your changes (see [Development Guidelines](#development-guidelines) below)
4. Test your changes (see [Testing](#testing))
5. Commit with a clear, concise message
6. Push to your fork and open a pull request against `main`
7. Describe what your PR does and why

---

## Development Guidelines

### PowerShell (Trigger.ps1, Bootstrap.ps1, Nova.ps1)

- Target **PowerShell 5.1** (the version available in WinPE)
- Use `#region` / `#endregion` blocks for logical sections
- Follow the existing naming convention: `Verb-Noun` for functions (e.g. `Build-WinPE`, `Update-HtmlUi`)
- Use `[CmdletBinding()]` and `param()` blocks for function parameters
- Include `try/catch/finally` for operations that can fail
- Use `Write-Host` for user-facing messages; `Write-Verbose` for debug output
- Enforce TLS 1.2: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`
- Test in both WinPE and full Windows environments when possible

### JavaScript (Editor, Nova-UI)

- Use vanilla JavaScript (ES6+) — no build tools or bundlers
- Keep dependencies minimal and vendored (no CDN links)
- Follow the existing code style (camelCase variables, single quotes for strings)
- Ensure the editor works offline after initial page load

### HTML / CSS

- Use semantic HTML5
- Support responsive layouts for varying screen resolutions (WinPE runs at native resolution)
- Keep CSS inline or in dedicated `.css` files (no preprocessors)
- Dark theme is the default for WinPE UI components

---

## Testing

### Manual testing (PowerShell scripts)

Since the core scripts interact with hardware (disk partitioning, DISM, BCD), manual testing is essential:

1. **Trigger.ps1:** Test on a Windows 10/11 VM with ADK not yet installed
2. **Bootstrap.ps1:** Test inside a WinPE VM (Hyper-V with virtual switch)
3. **Nova.ps1:** Test with the `-NoReboot` flag (if available) or in a sacrificial VM

> **Warning:** `Nova.ps1` partitions and formats disks. Never test on a machine with data you want to keep.

### Manual testing (Web editor)

1. Open `Editor/index.html` in a browser
2. Test drag-and-drop step reordering
3. Test JSON export / import round-trip
4. Test with `requireAuth: true` and `requireAuth: false` in `Config/auth.json`

---

## Security

### Reporting Vulnerabilities

Please see [**SECURITY.md**](SECURITY.md) for our full security policy and how to report vulnerabilities privately.

### Security-Sensitive Areas

When contributing, be especially careful with:

- **Token handling** — never persist OAuth tokens to disk
- **Script downloads** — always use HTTPS; validate sources
- **User input** — sanitise any input used in `Invoke-Expression` or HTML rendering
- **WiFi passwords** — minimise plaintext exposure duration
- **Status JSON** — do not add sensitive data to `Nova-Status.json`

---

## Localization

To add a new language:

1. Copy `Config/locale/en.json` to `Config/locale/<lang-code>.json`
2. Translate all string values (keep the JSON keys unchanged)
3. Test the UI with your new locale
4. Submit a PR with the new locale file

---

## License

By contributing to Nova, you agree that your contributions will be licensed under the [MIT License](LICENSE).

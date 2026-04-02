# Nova — Codebase Analysis

> **Date:** 2026-03-27
> **Scope:** Full codebase review covering architecture, performance, design, and security
> **Constraint:** This document is analysis-only — no code changes were made

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Branding & Naming](#branding--naming)
4. [Security Findings](#security-findings)
5. [Performance Findings](#performance-findings)
6. [Design & Architecture Findings](#design--architecture-findings)
7. [Code Quality Observations](#code-quality-observations)
8. [Open-Source Readiness](#open-source-readiness)
9. [Recommended Roadmap](#recommended-roadmap)

---

## Executive Summary

Nova is a well-architected, cloud-native Windows OS deployment platform. The three-stage design (Trigger → Bootstrap → Imaging Engine) is clean and effective. Authentication follows modern OAuth 2.0 best practices (PKCE, minimal scopes, ephemeral tokens). The codebase is functional, well-documented internally, and ready for open-source release with the documentation improvements delivered alongside this analysis.

**Overall assessment:** The project is in strong shape for open-sourcing. The findings below are categorized as improvements, not blockers. No critical vulnerabilities were found.

### By the numbers

| Metric | Value |
|--------|-------|
| PowerShell code | ~5,100 lines across 3 core scripts + 2 utilities |
| JavaScript/HTML/CSS | ~8,200 lines (editor + two UI frontends) |
| Total files | ~240 (including bundled drivers) |
| External dependencies | MSAL.js v2.39.0, moment.js (both vendored) |
| Languages supported | English, Spanish, French |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Nova Architecture                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  STAGE 1: Trigger.ps1 (2,245 lines)                                │
│  ─────────────────────────────────                                  │
│  Runs on existing Windows (admin). Installs ADK, builds WinPE      │
│  from WinRE.wim, embeds Bootstrap.ps1, creates BCD ramdisk entry,  │
│  reboots into cloud boot environment.                               │
│                                                                     │
│  STAGE 2: Bootstrap.ps1 (1,390 lines)                              │
│  ──────────────────────────────────                                  │
│  Runs inside WinRE/WinPE. Initialises network (DHCP + WiFi),       │
│  launches HTML progress UI in Edge kiosk mode, handles optional     │
│  M365 auth gate (PKCE or Device Code), downloads and launches       │
│  the imaging engine.                                                 │
│                                                                     │
│  STAGE 3: Nova.ps1 (1,443 lines)                                   │
│  ─────────────────────────────────                                   │
│  Full imaging engine streamed from GitHub. Partitions disk,         │
│  downloads Windows image, applies with DISM, injects drivers,       │
│  configures Autopilot/Intune/ConfigMgr, applies OOBE               │
│  customization, reboots into Windows.                               │
│                                                                     │
│  PARALLEL WEB COMPONENTS:                                           │
│  ─────────────────────────                                           │
│  • Editor (GitHub Pages SPA) — visual task sequence builder         │
│  • Nova-UI — real-time progress dashboard in Edge kiosk             │
│  • OAuth Proxy (Cloudflare Worker) — CORS bridge for GitHub OAuth   │
│                                                                     │
│  IPC:                                                               │
│  ────                                                               │
│  Bootstrap.ps1 ↔ Nova.ps1 via X:\Nova-Status.json                  │
│  Bootstrap.ps1 ↔ HTML UI via JSON polling (650ms) + HTTP API       │
│  (localhost:8080)                                                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Strengths of the architecture:**

- Clean separation of concerns between stages
- Each script can be tested and updated independently
- The IPC mechanism (JSON + localhost HTTP) is simple and reliable for WinPE
- Using WinRE as the boot base is clever — it inherits WiFi drivers without extra work
- The "stream from GitHub" model eliminates build/distribute cycles

---

## Branding & Naming

### Current state

The name **Nova** is short, memorable, and well-suited for this specific product. The rebrand from the original working name "AmpCloud" was completed to better distinguish this deployment platform from other Ampliosoft products and to establish a clearer identity.

### Branding

The **Nova** name is paired with a clear product descriptor in all branding contexts:

| Context | Value |
|---------|-------|
| Full brand name | **Nova** — Cloud-Native Windows OS Deployment |
| Short tagline | **"Zero-media Windows deployment from GitHub"** |
| Company attribution | **An Ampliosoft open-source project** |
| Locale UI header | `N O V A` |

This approach:
- Provides a distinct, memorable name for the deployment platform
- Clearly separates Nova from any future Ampliosoft products
- Positions Ampliosoft as the parent company brand

The rebrand from "AmpCloud" to "Nova" included updates to file names (`Nova.ps1`, `Nova-UI/`, `Nova-Status.json`), status file paths, locale strings, and documentation. Alternative names that were considered included **AmpDeploy**, **AmpImage**, and **AmpBoot**.

---

## Security Findings

> For authentication-specific analysis, see [SECURITY_ANALYSIS.md](SECURITY_ANALYSIS.md).

### S-01: Remote code execution via `irm | iex` (Informational)

**Component:** Entry point pattern (`irm ... | iex`)
**Severity:** Informational — inherent to the deployment model
**Description:** The primary entry point downloads and executes PowerShell directly from GitHub. If the repository or the HTTPS transport were compromised, arbitrary code would execute with administrator privileges.
**Mitigations already in place:**
- HTTPS-only transport (GitHub enforces TLS)
- Repository integrity managed by the owner
- Private fork option for enterprise customers
**Recommendations:**
- Document this trust model prominently for open-source users
- Consider offering optional SHA-256 checksum verification against GitHub Releases
- Consider optional PowerShell script signing with `Set-AuthenticodeSignature`
- Recommend branch protection rules (require PR reviews) in the contribution guide

### S-02: OAuth client IDs in public repository (Low)

**Component:** `config/auth.json`
**Severity:** Low
**Description:** The Azure AD Application ID and GitHub OAuth Client ID are committed to the repository. These are public identifiers by design (RFC 6749 §2.1), not secrets.
**Recommendation:** Add a note in `auth.json` or documentation clarifying that these are intentionally public and that forkers should replace them with their own app registrations.

### S-03: WiFi password briefly held in plaintext (Low)

**Component:** `Bootstrap.ps1` — WiFi connection logic
**Severity:** Low
**Description:** When connecting to a WiFi network, the password is captured as `SecureString` but must be converted to plaintext to construct the XML profile for `netsh wlan add profile`. The plaintext exists briefly in a PowerShell variable.
**Mitigations:** WinPE runs entirely in RAM; the session is ephemeral. The password is used once and not persisted.
**Recommendation:** No practical alternative exists for `netsh wlan` (it requires plaintext XML). Document this behaviour for security-conscious environments that may prefer wired-only deployment.

### S-04: No script integrity verification (Medium)

**Component:** `Bootstrap.ps1` → downloading `Nova.ps1`
**Severity:** Medium
**Description:** `Nova.ps1` is downloaded from GitHub and executed without verifying a checksum or digital signature. This relies entirely on HTTPS transport security.
**Recommendation:**
- Publish SHA-256 checksums alongside releases
- Add an optional `-VerifyChecksum` parameter to Bootstrap.ps1
- For enterprise environments, document how to use PowerShell code signing with `Get-AuthenticodeSignature`

### S-05: Status file has no ACL restriction (Low)

**Component:** `X:\Nova-Status.json`
**Severity:** Low
**Description:** The JSON status file used for IPC between Bootstrap.ps1 and the HTML UI is written to the WinPE RAM drive without explicit ACLs.
**Mitigations:** WinPE is a single-user, single-session environment. No sensitive data (passwords, tokens) flows through the status file.
**Recommendation:** No change needed for current use. If sensitive data is ever added to the status file, apply NTFS ACLs.

### S-06: Graph API scope is broad (Low)

**Component:** `config/auth.json` — `graphScopes`
**Severity:** Low
**Description:** The scope `DeviceManagementServiceConfig.ReadWrite.All` grants broad device management permissions. This is the minimum scope required for Autopilot device import via the Microsoft Graph API.
**Recommendation:** Document the scope and its purpose. Consider using a more granular scope if Microsoft releases one.

### S-07: TLS 1.2 not enforced in Trigger.ps1 (Low)

**Component:** `Trigger.ps1`
**Severity:** Low
**Description:** Both `Bootstrap.ps1` and `Nova.ps1` explicitly set `[Net.ServicePointManager]::SecurityProtocol = Tls12`. `Trigger.ps1` does not, relying on the OS default. On older PowerShell 5.1 installations, the default may include SSL3/TLS 1.0.
**Recommendation:** Add the TLS 1.2 enforcement line near the top of `Trigger.ps1` for consistency.

### S-08: products.xml uses SHA-1 hashes (Low)

**Component:** `products.xml`
**Severity:** Low
**Description:** The Windows ESD catalog uses SHA-1 for file integrity. SHA-1 is cryptographically deprecated but still used by Microsoft's own catalog infrastructure.
**Recommendation:** No change needed until Microsoft updates their catalog format. When they do, update to SHA-256.

---

## Performance Findings

### P-01: No HTTP resume for large downloads (Medium)

**Component:** `Nova.ps1` — Windows image download
**Impact:** Medium
**Description:** Windows ESD/WIM files are 4–5 GB. `Invoke-WebRequest` downloads the entire file in one pass. If the connection drops, the download starts over.
**Recommendation:** Implement HTTP Range header support for resumable downloads. PowerShell's `Start-BitsTransfer` supports resume natively but may not be available in WinPE.

### P-02: DHCP retry timing could be optimized (Low)

**Component:** `Bootstrap.ps1` — state machine
**Impact:** Low
**Description:** The DHCP acquisition loop runs up to 5 `ipconfig /renew` attempts with fixed 30-second timeouts. On networks with slow DHCP servers, this can take 2–3 minutes.
**Recommendation:** Consider exponential backoff (5s → 10s → 20s → 40s) and make the retry count configurable.

### P-03: JSON status polling interval is fixed (Low)

**Component:** `Bootstrap.ps1` + `src/web/nova-ui/index.html`
**Impact:** Low
**Description:** The HTML UI polls `Nova-Status.json` every 650ms. In WinPE (RAM disk), this is negligible overhead. However, for future scalability (e.g. remote status monitoring), a push-based mechanism (WebSocket or Server-Sent Events) would be more efficient.
**Recommendation:** No change needed for current use. The polling interval is appropriate for local IPC in WinPE.

### P-04: WIM not cached between runs (Low)

**Component:** `Trigger.ps1` — `Build-WinPE`
**Impact:** Low
**Description:** The WinRE.wim is rebuilt from scratch on every Trigger.ps1 invocation. While this ensures a clean image, it adds ~5 minutes to repeated runs during testing.
**Recommendation:** Add an optional `--UseCache` / `-SkipRebuild` flag that reuses the previously built WIM if it exists.

### P-05: ADK download on first run (Informational)

**Component:** `Trigger.ps1` — `Assert-ADKInstalled`
**Impact:** Informational
**Description:** The Windows ADK installer is ~1 GB and can take 15–30 minutes to download and install on first run. This is expected behaviour but may surprise new users.
**Recommendation:** Document the first-run time prominently in the README. Consider adding a progress indicator during ADK installation.

---

## Design & Architecture Findings

### D-01: Task sequence schema has no version field (Medium)

**Component:** `resources/task-sequence/default.json`
**Impact:** Medium
**Description:** The task sequence JSON format has no `version` or `schema` field. If the format evolves (e.g. new step types, renamed properties), old task sequences saved by users could break silently.
**Recommendation:** Add a `"schemaVersion": "1.0"` field to task sequence files. Validate the version on load and provide migration guidance for breaking changes.

### D-02: No dry-run mode (Medium)

**Component:** `Nova.ps1`
**Impact:** Medium
**Description:** There is no way to validate a deployment configuration without actually partitioning the disk. A dry-run mode would be valuable for testing task sequences and catching configuration errors.
**Recommendation:** Add a `-DryRun` / `-WhatIf` parameter that validates all configuration, resolves download URLs, and logs the planned steps without executing destructive operations (partitioning, image application).

### D-03: Single point of dependency on GitHub (Low)

**Component:** All scripts
**Impact:** Low
**Description:** All runtime code is fetched from GitHub. If GitHub is unreachable from the WinPE environment (e.g. corporate proxy, regional outage), deployment cannot proceed.
**Mitigations:** The `GitHubUser`/`GitHubRepo`/`GitHubBranch` parameters allow pointing to a mirror. Boot images could be pre-cached.
**Recommendation:** Document alternative hosting scenarios (Azure Blob Storage, internal web server) and provide guidance for air-gapped deployments.

### D-04: Unattend.xml precedence is implicit (Low)

**Component:** `Nova.ps1`
**Impact:** Low
**Description:** The imaging engine accepts `UnattendPath`, `UnattendContent`, and `UnattendUrl` — three ways to provide an unattend.xml. The precedence order is not documented.
**Recommendation:** Document the precedence explicitly: `UnattendPath` > `UnattendContent` > `UnattendUrl` > built-in default.

### D-05: OEM driver auto-detection coverage (Low)

**Component:** `Nova.ps1` — `InjectOemDrivers` step
**Impact:** Low
**Description:** OEM driver auto-detection supports Dell, HP, and Lenovo. Other manufacturers (Acer, ASUS, Microsoft Surface) are not covered.
**Recommendation:** Document supported manufacturers. Consider adding Surface driver catalog support given its prevalence in enterprise environments.

### D-06: Multi-language support is partial (Low)

**Component:** `config/locale/`
**Impact:** Low
**Description:** Localization files exist for English, Spanish, and French. For enterprise adoption, additional languages (German, Chinese, Japanese, Portuguese) would be valuable.
**Recommendation:** Add a contribution guide for locale translations. Consider using a standard i18n format (ICU Message Format) for future-proofing.

### D-07: Editor lacks syntax highlighting for XML (Low)

**Component:** `src/web/editor/js/app.js` — unattend.xml editor
**Impact:** Low
**Description:** The inline unattend.xml editor uses a plain `<textarea>`. Syntax highlighting would improve usability.
**Recommendation:** Consider integrating a lightweight code editor (CodeMirror or Monaco) for XML editing.

---

## Code Quality Observations

### Strengths

- **Consistent style:** PowerShell scripts follow a uniform style with `#region` blocks, consistent parameter declarations, and well-named functions.
- **Error handling:** All three core scripts use `try/catch/finally` blocks with meaningful error messages. Failed deployments do not force a reboot.
- **Logging:** Transcript logging (`Start-Transcript`) is used in all three stages, producing detailed logs at `X:\Nova-*.log`.
- **State machine pattern:** Bootstrap.ps1's DHCP/connectivity flow uses a clean state machine (`INIT → WPEINIT → SETTLE → DHCP → CHECK`) that is easy to follow and extend.
- **Separation of concerns:** Each script has a single responsibility. The IPC mechanism (JSON + HTTP) keeps them decoupled.
- **Vendored dependencies:** MSAL.js and moment.js are self-hosted rather than loaded from CDNs, which is correct for WinPE and air-gapped scenarios.

### Areas for improvement

- **Function length:** Some functions (e.g. `Build-WinPE` in Trigger.ps1) are 200+ lines. Breaking them into smaller helpers would improve readability and testability.
- **Magic numbers:** Some timeout and retry values are hardcoded (e.g. `120` ticks, `60` ticks). Extracting these as named constants or parameters would improve configurability.
- **Duplicate URL construction:** The pattern `"https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/..."` appears in multiple scripts. A shared function or variable would reduce duplication.
- **No unit tests:** There are no PowerShell (Pester) or JavaScript tests. While the deployment scripts are difficult to unit test (they interact with hardware), the utility functions, URL construction, and JSON parsing could be tested.
- **No linting configuration:** No PSScriptAnalyzer or ESLint configuration files exist. Adding these would catch common issues automatically.

---

## Open-Source Readiness

### What was added as part of this analysis

| File | Purpose |
|------|---------|
| `README.md` | Rewritten for open-source audiences with clear branding, architecture overview, and setup instructions |
| `CODEBASE_ANALYSIS.md` | This document — comprehensive analysis of the entire codebase |
| `CONTRIBUTING.md` | Contribution guidelines, code of conduct, and development setup |
| `LICENSE` | MIT License (as referenced in the previous README) |

### Remaining items for open-source release

| Item | Priority | Notes |
|------|----------|-------|
| Replace `config/auth.json` with a template | High | Ship `auth.json.example` with placeholder values; add `auth.json` to `.gitignore` so forkers don't accidentally commit their real credentials |
| Add `.gitignore` | High | Exclude build artifacts, ADK output, WIM files |
| Add PSScriptAnalyzer config | Medium | Enforce consistent PowerShell style |
| Add GitHub issue templates | Medium | Bug report, feature request, security vulnerability |
| Add a `CHANGELOG.md` | Medium | Track releases and breaking changes |
| Set up GitHub Releases | Medium | Tag versions, publish checksums for boot images |
| Add Pester tests for utility functions | Low | Test URL construction, JSON parsing, parameter validation |
| Add ESLint config for Editor JS | Low | Enforce consistent JavaScript style |

---

## Recommended Roadmap

### Phase 1: Open-source launch (current)

- [x] Rewrite README with professional branding
- [x] Add CONTRIBUTING.md with contributor guidelines
- [x] Add MIT LICENSE file
- [x] Create comprehensive codebase analysis (this document)
- [ ] Replace `auth.json` with `auth.json.example`
- [ ] Add `.gitignore` for build artifacts
- [ ] Enable GitHub Discussions for community Q&A
- [ ] Configure branch protection rules on `main`

### Phase 2: Hardening

- [ ] Add TLS 1.2 enforcement to Trigger.ps1 (Finding S-07)
- [ ] Add OAuth `state` parameter to Trigger.ps1 auth flow (SECURITY_ANALYSIS.md F-01)
- [ ] Add `schemaVersion` to task sequence format (Finding D-01)
- [ ] Add `-DryRun` mode to Nova.ps1 (Finding D-02)
- [ ] Add resumable downloads for large images (Finding P-01)
- [ ] Publish SHA-256 checksums with GitHub Releases (Finding S-04)

### Phase 3: Community growth

- [ ] Add Pester tests for utility functions
- [ ] Add ESLint + PSScriptAnalyzer CI checks
- [ ] Expand locale support (German, Chinese, Japanese)
- [ ] Add syntax highlighting to unattend.xml editor (Finding D-07)
- [ ] Document air-gapped and alternative hosting scenarios (Finding D-03)
- [ ] Expand OEM driver support (Surface, ASUS, Acer) (Finding D-05)

---

*This analysis was prepared for the open-source release of Nova. It is intended as a living document — update it as findings are addressed.*

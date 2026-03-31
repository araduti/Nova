# Nova — Complete Codebase Review & Next-Gen Roadmap

> **Date:** 2026-03-31  
> **Scope:** Full audit of codebase, package versions, folder structures, security, performance  
> **Constraint:** Analysis only — no code changes made  

---

## Table of Contents

1. [Executive Summary](#executive-summary)  
2. [Repository At-a-Glance](#repository-at-a-glance)  
3. [Folder Structure Assessment](#folder-structure-assessment)  
4. [Package Versions & Dependencies](#package-versions--dependencies)  
5. [PowerShell Core Scripts](#powershell-core-scripts)  
6. [JavaScript & Web UI](#javascript--web-ui)  
7. [OAuth Proxy (Cloudflare Worker)](#oauth-proxy-cloudflare-worker)  
8. [Authentication Architecture](#authentication-architecture)  
9. [Security Assessment](#security-assessment)  
10. [Performance Assessment](#performance-assessment)  
11. [Open-Source Readiness](#open-source-readiness)  
12. [Preserving `irm | iex` After Modularization](#preserving-irm--iex-after-modularization)  
13. [GitHub Pages Compatibility with a Build System](#github-pages-compatibility-with-a-build-system)  
14. [Next-Gen Recommendations](#next-gen-recommendations)  
15. [Priority Roadmap](#priority-roadmap)  

---

## Executive Summary

Nova is a cloud-native Windows OS deployment platform built around a 3-stage pipeline (Trigger → Bootstrap → Imaging Engine). The codebase is **functional, well-documented, and security-conscious** with modern OAuth 2.0 flows (PKCE, Device Code, Entra token exchange). However, it currently operates as a **monolithic set of scripts and single-file web apps** without a package manager, build pipeline, test suite, or modular architecture.

### Current State: Solid Foundation

| Area | Grade | Summary |
|------|-------|---------|
| **Functionality** | A | Complete end-to-end Windows deployment with rich feature set |
| **Security** | B+ | Modern auth flows, TLS 1.2, no secrets in code; some gaps in input validation and rate limiting |
| **Performance** | B | Adequate for current scale; monolithic HTML files and no CDN optimization |
| **Code Quality** | B- | Strict mode, good error handling; but monolithic files (2,000+ line scripts), no tests |
| **Open-Source Readiness** | B | MIT license, good docs, contributing guide; missing CI testing, semantic versioning |
| **Maintainability** | C+ | No package manager, no build system, no tests, inline styles/scripts |

### What Would Make It Truly Next-Gen

1. **Modularize** — Break monolithic scripts into importable modules with a proper build system
2. **Test** — Add automated testing (Pester for PowerShell, Vitest for JS)
3. **Harden** — Rate limiting, script integrity verification, CSP headers
4. **Modernize** — TypeScript for the worker, component-based UI, proper npm project structure
5. **Automate** — CI/CD for testing, linting, security scanning, and releases

---

## Repository At-a-Glance

| Metric | Value |
|--------|-------|
| **Total repository size** | ~387 MB (338 MB are bundled drivers) |
| **Total files** | ~257 |
| **License** | MIT (Copyright © 2026 Ampliosoft) |
| **Primary language** | PowerShell (6,155 lines across 5 scripts) |
| **Secondary languages** | JavaScript (3,183 lines), HTML/CSS (~4,007 lines) |
| **Total hand-written code** | ~13,345 lines across key files |
| **External dependencies** | 2 (MSAL.js v2.39.0, Cloudflare Workers runtime) |
| **Package manager** | None |
| **Test suite** | None |
| **CI/CD** | GitHub Pages deployment only |
| **Supported locales** | 3 (English, Spanish, French) |

### Key Files by Size

| File | Lines | Size | Role |
|------|-------|------|------|
| `Trigger.ps1` | 2,248 | 108 KB | Stage 1 — WinPE builder |
| `Nova.ps1` | 2,077 | 92 KB | Stage 3 — Imaging engine |
| `Bootstrap.ps1` | 1,830 | 88 KB | Stage 2 — Network & auth |
| `Editor/js/app.js` | 2,800 | ~95 KB | Task sequence editor SPA |
| `Monitoring/index.html` | 2,181 | 96 KB | Deployment monitoring dashboard |
| `Nova-UI/index.html` | 1,174 | 56 KB | Real-time progress UI |
| `index.html` (root) | 652 | 28 KB | Landing page / dashboard |
| `oauth-proxy/worker.js` | 383 | ~15 KB | Cloudflare Worker OAuth proxy |
| `products.xml` | 1,626 | 84 KB | Windows ESD catalog (30 entries) |

---

## Folder Structure Assessment

### Current Structure (As-Is)

```
Nova/
├── .github/workflows/pages.yml   # CI: GitHub Pages deploy only
├── Nova-UI/index.html         # Monolithic SPA (56 KB)
├── Nova.ps1                   # Monolithic script (92 KB)
├── Autopilot/                     # Utility scripts + binaries
│   ├── Invoke-ImportAutopilot.ps1
│   ├── Utils.ps1
│   ├── oa3tool.exe, PCPKsp.dll    # Vendored binaries
│   └── OA3.cfg
├── Bootstrap.ps1                  # Monolithic script (88 KB)
├── Config/
│   ├── auth.json                  # OAuth config (public client IDs)
│   ├── alerts.json                # Notification config (all disabled)
│   └── locale/{en,es,fr}.json     # UI translations
├── Deployments/
│   ├── active/.gitkeep
│   └── reports/.gitkeep + sample
├── Drivers/NetKVM/                # 338 MB of vendored virtio drivers
├── Editor/                        # Task sequence editor SPA
│   ├── index.html
│   ├── js/app.js                  # 2,800-line single file
│   ├── css/style.css
│   └── lib/msal-browser.min.js    # Vendored MSAL (368 KB)
├── Monitoring/index.html          # Monolithic dashboard (96 KB)
├── Progress/index.html            # Legacy progress UI
├── TaskSequence/default.json      # Default deployment template
├── Trigger.ps1                    # Monolithic script (108 KB)
├── Unattend/unattend.xml          # OOBE template
├── docs/                          # Improvement proposals
├── index.html                     # Root landing page
├── oauth-proxy/
│   ├── worker.js                  # Cloudflare Worker (no package.json)
│   └── wrangler.toml
└── products.xml                   # Windows ESD catalog
```

### Issues Identified

| Issue | Impact | Severity |
|-------|--------|----------|
| **No `src/` organization** — PowerShell scripts at repo root | Cluttered root, hard to navigate | Medium |
| **Monolithic files** — 2,000+ line single-file scripts | Hard to maintain, review, and test | High |
| **338 MB of bundled drivers** — Drivers checked into git | Bloated repo, slow clones | High |
| **Vendored libraries** — MSAL.js checked in, no version management | Stale versions, no update path | Medium |
| **No package manager** — No package.json anywhere | No dependency management or auditing | High |
| **Mixed concerns in root** — Scripts, XML, HTML, docs all at top level | Poor discoverability | Medium |
| **Legacy `Progress/` directory** — Appears superseded by `Nova-UI/` | Confusing for contributors | Low |

### Recommended Structure (Next-Gen)

```
Nova/
├── .github/
│   ├── workflows/
│   │   ├── pages.yml              # Pages deployment
│   │   ├── test.yml               # Pester + Vitest CI
│   │   ├── lint.yml               # PSScriptAnalyzer + ESLint
│   │   └── security.yml           # CodeQL + dependency scanning
│   └── ISSUE_TEMPLATE/
├── src/
│   ├── engine/                    # PowerShell modules
│   │   ├── Nova.psm1          # Main imaging module
│   │   ├── Bootstrap.psm1         # Network & auth module
│   │   ├── Trigger.psm1           # WinPE builder module
│   │   └── Private/               # Internal helper functions
│   │       ├── Auth.ps1
│   │       ├── Deployment.ps1
│   │       ├── Imaging.ps1
│   │       └── Network.ps1
│   ├── autopilot/                 # Autopilot module
│   │   ├── Invoke-ImportAutopilot.ps1
│   │   └── Utils.ps1
│   └── oauth-proxy/               # Cloudflare Worker
│       ├── src/index.ts           # TypeScript entry point
│       ├── src/handlers/
│       ├── package.json
│       ├── tsconfig.json
│       ├── vitest.config.ts
│       └── wrangler.toml
├── web/
│   ├── editor/                    # Task sequence editor
│   │   ├── src/                   # Component-based JS/TS
│   │   ├── index.html
│   │   └── package.json
│   ├── monitoring/                # Deployment dashboard
│   │   ├── src/
│   │   └── index.html
│   ├── ui/                        # Imaging progress UI
│   │   └── index.html
│   └── shared/                    # Shared CSS/utils
├── config/
│   ├── auth.json
│   ├── alerts.json
│   └── locale/
├── task-sequences/
│   └── default.json
├── tests/
│   ├── engine/                    # Pester tests
│   │   ├── Nova.Tests.ps1
│   │   ├── Bootstrap.Tests.ps1
│   │   └── Trigger.Tests.ps1
│   └── oauth-proxy/               # Vitest tests
│       └── worker.test.ts
├── docs/
│   ├── architecture.md
│   ├── security.md
│   └── contributing.md
├── unattend/
│   └── unattend.xml
├── products.xml
├── CHANGELOG.md
├── README.md
└── LICENSE
```

**Key changes:** Move drivers to Git LFS or external artifact storage, modularize PowerShell into `.psm1` modules, add `package.json` for web projects, organize by concern.

---

## Package Versions & Dependencies

### Current Dependencies (As-Is)

| Dependency | Version | Location | Latest Stable | Status |
|-----------|---------|----------|---------------|--------|
| **MSAL.js** (`@azure/msal-browser`) | 2.39.0 (2024-06-06) | `Editor/lib/msal-browser.min.js` (vendored) | 4.x+ | ⚠️ **Major version behind** — MSAL v2 is in maintenance mode; v3/v4 are current |
| **Cloudflare Workers Runtime** | `compatibility_date: 2024-01-01` | `oauth-proxy/wrangler.toml` | 2026-03-01+ | ⚠️ **15+ months behind** — missing newer runtime features and security patches |
| **PowerShell** | Requires 5.1 | All `.ps1` files | 7.4+ | ℹ️ 5.1 is correct for WinPE (ships with Windows); PS 7 not available in WinPE |
| **GitHub Actions: checkout** | v4 | `.github/workflows/pages.yml` | v4 | ✅ Current |
| **GitHub Actions: configure-pages** | v5 | `.github/workflows/pages.yml` | v5 | ✅ Current |
| **GitHub Actions: upload-pages-artifact** | v3 | `.github/workflows/pages.yml` | v4 | ⚠️ **One version behind** |
| **GitHub Actions: deploy-pages** | v4 | `.github/workflows/pages.yml` | v4 | ✅ Current |

### Missing Dependencies (Should Add)

| Category | Tool | Purpose |
|----------|------|---------|
| **PS Linting** | PSScriptAnalyzer | PowerShell static analysis |
| **PS Testing** | Pester v5 | PowerShell unit/integration testing |
| **JS Linting** | ESLint | JavaScript static analysis |
| **JS Formatting** | Prettier | Code formatting |
| **JS Testing** | Vitest | Fast unit testing for Workers |
| **JS Bundling** | esbuild/Rollup | Bundle and minify web assets |
| **Security** | CodeQL | Automated vulnerability scanning |
| **Security** | Dependabot | Dependency update alerts |
| **Type Safety** | TypeScript | Static type checking for JS |

### Version Upgrade Recommendations

| Component | Current | Target | Why |
|-----------|---------|--------|-----|
| MSAL.js | 2.39.0 | 4.x | v2 is maintenance-only; v4 has smaller bundle, tree-shaking, improved token caching |
| Wrangler compat_date | 2024-01-01 | 2026-03-01 | Access to latest Workers APIs, security fixes |
| upload-pages-artifact | v3 | v4 | Bug fixes and improvements |

---

## PowerShell Core Scripts

### Architecture (As-Is)

```
STAGE 1: Trigger.ps1 (2,248 lines)
├── Validates admin rights (#Requires -RunAsAdministrator)
├── Installs Windows ADK if missing
├── Builds WinPE/WinRE ISO with drivers
├── Injects Bootstrap.ps1 as startup script
└── Boots target machine into WinPE

STAGE 2: Bootstrap.ps1 (1,830 lines)
├── Initializes network (Ethernet → Wi-Fi fallback)
├── Launches Edge kiosk UI
├── Handles M365 authentication (PKCE + Device Code)
├── Downloads Nova.ps1 from GitHub
└── Hands off to imaging engine

STAGE 3: Nova.ps1 (2,077 lines)
├── Reads task sequence JSON
├── Executes each step sequentially
├── Reports progress to UI and GitHub
├── Handles rollback on failure
└── Updates deployment status
```

### Strengths

- ✅ **Strict mode everywhere** — `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`
- ✅ **Comprehensive try/catch** — All critical paths wrapped with structured error handling
- ✅ **TLS 1.2 enforced** — `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`
- ✅ **Timeout on every HTTP call** — All `Invoke-RestMethod`/`Invoke-WebRequest` have `-TimeoutSec`
- ✅ **Token isolation** — Tokens in `$script:` scope, never persisted to disk
- ✅ **Retry with exponential backoff** — `Push-ReportToGitHub` retries 3× (2s, 4s, 6s)
- ✅ **Property access guards** — `PSObject.Properties['prop']` checks under strict mode
- ✅ **Negative caching** — 5-min cooldown on Entra exchange failures
- ✅ **One-shot warning flag** — Prevents log flooding from repeated token failures

### Issues

| Issue | File(s) | Severity | Detail |
|-------|---------|----------|--------|
| **Monolithic files** | All 3 scripts | High | 2,000+ lines each with no module separation; impossible to unit test individual functions |
| **No test coverage** | — | High | Zero Pester tests; no automated validation of any logic |
| **`irm \| iex` entry point** | Trigger.ps1 (line 49) | Critical | Downloads and executes script from GitHub without hash/signature verification |
| **Input validation gaps** | Autopilot/Utils.ps1:43 | Medium | Serial number sanitization removes basic chars but doesn't validate length or prevent injection |
| **Error info disclosure** | Bootstrap.ps1:1342 | Medium | Full exception messages logged to auth log; may leak endpoint URLs or response data |
| **Hardcoded paths** | Multiple | Low | `X:\Nova-Status.json`, `X:\Nova-Auth.log` — fine for WinPE but not configurable |
| **No PSScriptAnalyzer** | — | Medium | No static analysis in CI; potential for anti-patterns |
| **Global state via `$script:`** | All scripts | Medium | Heavy use of script-scoped variables; makes reasoning about state difficult |

### Recommendations

1. **Convert to PowerShell modules** (`.psm1`) with `Export-ModuleMember` for public functions
2. **Add Pester v5 tests** for all exported functions, especially auth flows and task sequence execution
3. **Add PSScriptAnalyzer** to CI with custom rules matching project conventions
4. **Implement script integrity verification** — SHA256 hash check before `iex`
5. **Parameterize all paths** — Accept configuration via parameters, not hardcoded paths

---

## JavaScript & Web UI

### Architecture (As-Is)

| Component | File | Lines | Role |
|-----------|------|-------|------|
| Task Sequence Editor | `Editor/js/app.js` | 2,800 | Full SPA — drag-and-drop step builder, GitHub save/load, M365 auth |
| Monitoring Dashboard | `Monitoring/index.html` | 2,181 | Inline JS/CSS — deployment cards, staleness detection, diagnostics |
| Imaging Progress UI | `Nova-UI/index.html` | 1,174 | Inline JS/CSS — real-time step progress, spinner, status updates |
| Landing Page | `index.html` | 652 | Inline JS/CSS — navigation hub |
| OAuth Proxy | `oauth-proxy/worker.js` | 383 | Cloudflare Worker — GitHub OAuth proxy, Entra token exchange |

### Strengths

- ✅ **Consistent XSS prevention** — `escapeHtml()` used at 40+ insertion points via DOM-based escaping
- ✅ **sessionStorage for tokens** — Not persisted across browser sessions
- ✅ **HTTPS-only URL validation** — Device code `verification_uri` enforced to HTTPS
- ✅ **Modern JS practices** — async/await, Fetch API, const/let, template literals, arrow functions
- ✅ **Proper UTF-8 base64 encoding** — Custom `toBase64()` handles multi-byte characters correctly
- ✅ **Comprehensive diagnostics panel** — 7-check connectivity test in Monitoring UI
- ✅ **Staleness detection** — 4-hour stale threshold, 24-hour auto-purge for deployment cards

### Issues

| Issue | File(s) | Severity | Detail |
|-------|---------|----------|--------|
| **Monolithic single files** | All HTML files | High | Monitoring = 2,181 lines inline JS+CSS+HTML; untestable, unreviewable |
| **No build system** | — | High | No minification, no bundling, no tree-shaking; full MSAL.js (368 KB) shipped |
| **No TypeScript** | All JS files | Medium | No type safety; refactoring is error-prone |
| **No ESLint/Prettier** | — | Medium | No automated code style enforcement |
| **No test coverage** | — | High | Zero tests for any JavaScript code |
| **MSAL.js v2 (EOL path)** | Editor/lib/ | Medium | v2 in maintenance; missing v4 features (smaller bundle, improved caching) |
| **No CSP headers** | All HTML files | Medium | No Content Security Policy; relies on GitHub Pages defaults |
| **Vendored library** | Editor/lib/msal-browser.min.js | Medium | No version management; no SRI hash; manual updates only |
| **No lazy loading** | All UIs | Low | All content loaded eagerly; no code splitting |
| **Legacy Progress/ dir** | Progress/index.html | Low | Appears superseded by Nova-UI/; may confuse contributors |

### Recommendations

1. **Extract inline JS/CSS** from monolithic HTML files into separate modules
2. **Add a build step** — Use Vite or esbuild to bundle, minify, and add SRI hashes
3. **Migrate to TypeScript** — Start with oauth-proxy (smallest surface), then Editor
4. **Upgrade MSAL.js to v4** — Smaller bundle, active development, better token management
5. **Add ESLint + Prettier** with shared config
6. **Add Vitest** for unit testing JavaScript logic
7. **Implement CSP headers** via `<meta>` tags for pages served from GitHub Pages

---

## OAuth Proxy (Cloudflare Worker)

### Architecture (As-Is)

```
oauth-proxy/worker.js (383 lines)
├── POST /login/device/code      → Proxy to GitHub Device Flow
├── POST /login/oauth/access_token → Proxy to GitHub token endpoint
├── POST /api/token-exchange      → Entra token → GitHub App token
└── OPTIONS *                     → CORS preflight handling
```

### Strengths

- ✅ **No npm dependencies** — Pure Cloudflare Workers runtime; zero supply chain risk
- ✅ **CORS origin validation** — Optional `ALLOWED_ORIGIN` restriction
- ✅ **Endpoint whitelist** — Only 3 defined routes; all others return 404
- ✅ **PKCS#1/PKCS#8 key support** — Handles both GitHub key formats
- ✅ **Clock skew resilience** — 60-second `iat` buffer on JWT
- ✅ **Safe error messages** — Generic errors; no internal details leaked
- ✅ **Observability enabled** — Cloudflare logging configured in wrangler.toml

### Issues

| Issue | Severity | Detail |
|-------|----------|--------|
| **No rate limiting** | High | Token exchange endpoint can be abused; no per-IP or per-token limits |
| **No package.json** | Medium | Can't run `npm audit`, no dev dependencies for testing/linting |
| **Plain JavaScript** | Medium | No TypeScript; complex crypto/JWT code would benefit from type safety |
| **No tests** | High | Zero test coverage for auth-critical code |
| **Hardcoded account_id** | Low | `deb57b55201f0395f39a3f5ea1df09e3` in wrangler.toml (non-sensitive but should be environment-specific) |
| **CORS reflection** | Medium | Without `ALLOWED_ORIGIN`, reflects any requesting origin |
| **No CSRF protection** | Low | POST endpoints accept requests without CSRF tokens (mitigated by CORS + token requirement) |

### Recommendations

1. **Add `package.json`** with wrangler, vitest, and TypeScript as dev dependencies
2. **Migrate to TypeScript** — `src/index.ts` with proper type definitions
3. **Add Vitest tests** — Test JWT creation, PKCS key import, token validation, CORS logic
4. **Implement rate limiting** — Use Cloudflare KV or Durable Objects for per-IP rate limits
5. **Set `ALLOWED_ORIGIN`** in production to prevent CORS reflection
6. **Move `account_id`** to environment variable or CI secret

---

## Authentication Architecture

### Current Flows (As-Is)

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Nova Authentication Flows                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  FLOW 1: Kiosk PKCE (Bootstrap.ps1)                                 │
│  ┌─────────┐     ┌──────────┐     ┌───────────┐                    │
│  │ WinPE   │────→│ Edge     │────→│ Entra ID  │                    │
│  │ Script  │     │ Kiosk    │     │ /authorize│                    │
│  └─────────┘     └──────────┘     └───────────┘                    │
│       ↑               │                 │                            │
│       └───────────────┘ auth code       │                            │
│       │                                 │                            │
│       └── POST /token (code + verifier) │                            │
│       └── access_token (memory only)    │                            │
│                                                                      │
│  FLOW 2: Device Code (Bootstrap.ps1 fallback)                       │
│  ┌─────────┐     ┌──────────────┐     ┌───────────┐                │
│  │ WinPE   │────→│ Display code │────→│ Entra ID  │                │
│  │ Script  │     │ on screen    │     │ /devicecode│               │
│  └─────────┘     └──────────────┘     └───────────┘                │
│       ↑                                      │                      │
│       └── Poll /token until authorized       │                      │
│       └── access_token (memory only)         │                      │
│                                                                      │
│  FLOW 3: MSAL.js Popup (Editor web UI)                              │
│  ┌─────────┐     ┌──────────┐     ┌───────────┐                    │
│  │ Browser │────→│ MSAL.js  │────→│ Entra ID  │                    │
│  │ SPA     │     │ Popup    │     │ /authorize│                    │
│  └─────────┘     └──────────┘     └───────────┘                    │
│       ↑               │                                              │
│       └── token (sessionStorage)                                     │
│                                                                      │
│  FLOW 4: GitHub Device Flow (Editor → oauth-proxy)                  │
│  ┌─────────┐     ┌────────────┐     ┌────────┐                     │
│  │ Editor  │────→│ CF Worker  │────→│ GitHub  │                     │
│  │ SPA     │     │ CORS Proxy │     │ OAuth   │                     │
│  └─────────┘     └────────────┘     └────────┘                     │
│       ↑               │                                              │
│       └── PAT (sessionStorage)                                       │
│                                                                      │
│  FLOW 5: Entra → GitHub Exchange (oauth-proxy)                      │
│  ┌─────────┐     ┌────────────┐     ┌────────┐                     │
│  │ Client  │────→│ CF Worker  │────→│ Graph   │                     │
│  │ (Entra  │     │ Validate   │     │ /me     │                     │
│  │  token) │     │ + JWT sign │     └────────┘                     │
│  └─────────┘     └────────────┘                                     │
│       ↑               │                                              │
│       │               ├── Create GitHub App JWT (RS256)              │
│       │               └── Get installation token                     │
│       └── GitHub installation token (scoped, short-lived)           │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Security Assessment

| Component | Status | Notes |
|-----------|--------|-------|
| PKCE implementation | ✅ Secure | RFC 7636, 32-byte verifier, S256 challenge |
| Token storage (WinPE) | ✅ Secure | Memory only, `$script:` scope, never written to disk |
| Token storage (Browser) | ⚠️ Adequate | sessionStorage (cleared on tab close), but visible in DevTools |
| Device Code Flow | ✅ Secure | Standard OAuth 2.0 device authorization grant |
| GitHub App JWT | ✅ Secure | RS256, 10-min expiry, 60s clock skew buffer |
| Token scope | ✅ Minimal | `User.Read` + device management; installation token scoped to `contents:write` |
| Entra validation | ✅ Secure | Validated via Graph /me call; optional tenant restriction |
| Token caching | ✅ Smart | 55-min cache for Entra GitHub tokens; 5-min negative cache on failures |
| Client secrets | ✅ None | No client secrets in codebase; all public client flows |

### Recommendations

1. **Enforce `ENTRA_TENANT_ID`** — Currently optional; should be required in production
2. **Add rate limiting** on token exchange endpoint
3. **Token rotation** — Implement proactive token refresh before expiry
4. **Audit logging** — Log all token exchange attempts (success/failure) with IP and user principal

---

## Security Assessment

### Vulnerability Summary

| # | Finding | Severity | Component | Status |
|---|---------|----------|-----------|--------|
| 1 | `irm \| iex` without integrity check | 🔴 Critical | Trigger.ps1 | Open |
| 2 | No rate limiting on OAuth proxy | 🟠 High | oauth-proxy/worker.js | Open |
| 3 | Serial number injection potential | 🟠 High | Autopilot/Utils.ps1 | Open |
| 4 | CORS origin reflection (no ALLOWED_ORIGIN) | 🟡 Medium | oauth-proxy/worker.js | Open |
| 5 | Error messages may leak endpoint URLs | 🟡 Medium | Bootstrap.ps1 | Open |
| 6 | GitHub token visible in sessionStorage | 🟡 Medium | Editor/js/app.js | Open |
| 7 | No Content Security Policy headers | 🟡 Medium | All HTML files | Open |
| 8 | MSAL.js v2 in maintenance mode | 🟡 Medium | Editor/lib/ | Open |
| 9 | No automated security scanning in CI | 🟡 Medium | .github/workflows/ | Open |
| 10 | Vendored binaries without checksum | 🟢 Low | Autopilot/ | Open |

### Detailed Finding: `irm | iex` Without Verification (Critical)

**File:** Trigger.ps1, line 49 (README one-liner entry point)  
**Pattern:** `irm https://raw.githubusercontent.com/.../Trigger.ps1 | iex`  
**Risk:** Script is downloaded over HTTPS and executed without hash or signature verification. If the GitHub account is compromised, DNS is hijacked, or a MITM attack succeeds against TLS, arbitrary code runs with admin privileges.  
**Recommendation:** Implement SHA256 hash verification or Authenticode signing:

```powershell
# Download-then-verify pattern
$script = irm https://raw.githubusercontent.com/.../Trigger.ps1
$hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new(
    [Text.Encoding]::UTF8.GetBytes($script))) -Algorithm SHA256).Hash
if ($hash -ne $EXPECTED_HASH) { throw "Integrity check failed" }
iex $script
```

### Detailed Finding: No Rate Limiting (High)

**File:** oauth-proxy/worker.js, `/api/token-exchange` endpoint  
**Risk:** Any valid Entra ID token (potentially from any tenant if `ENTRA_TENANT_ID` is not set) can request a GitHub installation token. Without rate limiting, this enables:
- Token farming (bulk GitHub API access)
- Denial of service against GitHub App rate limits
- Abuse of installation token scope

**Recommendation:** Implement Cloudflare Workers rate limiting:

```javascript
// Use Cloudflare Rate Limiting binding
const { success } = await env.RATE_LIMITER.limit({ key: clientIP });
if (!success) return new Response('Rate limited', { status: 429 });
```

---

## Performance Assessment

### Current Performance Profile

| Area | Status | Detail |
|------|--------|--------|
| **Page load (Editor)** | ⚠️ Slow | MSAL.js alone is 368 KB minified; no gzip, no code splitting |
| **Page load (Monitoring)** | ⚠️ Slow | 96 KB monolithic HTML with inline JS/CSS; no caching headers |
| **Script download (WinPE)** | ✅ OK | ~100 KB scripts over HTTPS; GitHub CDN provides good latency |
| **Image download** | ✅ OK | Direct Microsoft CDN URLs; resume/retry not implemented |
| **OAuth proxy latency** | ✅ OK | Cloudflare edge deployment; <50ms for CORS proxy |
| **Token exchange** | ✅ OK | 2 sequential API calls (Graph /me + GitHub); typically <500ms |
| **Deployment reporting** | ✅ OK | 15-second timeouts; exponential backoff on failures |
| **Driver injection** | ⚠️ Concern | 338 MB of drivers bundled; most are unused on any given deployment |

### Recommendations

| Area | Improvement | Impact |
|------|-------------|--------|
| **Bundle size** | Add build step (Vite/esbuild) for tree-shaking + minification | -60-80% JS size |
| **MSAL upgrade** | Migrate to MSAL.js v4 (smaller, tree-shakeable) | -50% auth library size |
| **Asset caching** | Add `Cache-Control` and SRI hashes to static assets | Faster repeat loads |
| **Code splitting** | Lazy-load auth, diagnostics, editor panels | Faster initial paint |
| **Driver optimization** | Use Git LFS or download drivers on-demand from known URL | -338 MB repo size |
| **Gzip/Brotli** | GitHub Pages serves gzip automatically; verify Brotli support | -70% transfer size |
| **Image download** | Add resume support (HTTP Range headers) for large ESD files | Resilience on slow networks |

---

## Open-Source Readiness

### Current State

| Criterion | Status | Detail |
|-----------|--------|--------|
| **License** | ✅ MIT | Clear, permissive, well-understood |
| **README** | ✅ Comprehensive | Architecture, quick start, parameters, customization |
| **Contributing guide** | ✅ Present | Standards, PR process, code style |
| **Code of Conduct** | ✅ Present | Contributor Covenant |
| **Security policy** | ✅ Present | Reporting process, supported versions |
| **Issue templates** | ✅ Present | Bug report + feature request with structured fields |
| **PR template** | ✅ Present | Type, components, testing checklist |
| **Changelog** | ⚠️ Minimal | Only "Unreleased" section; no version history |
| **Semantic versioning** | ❌ Missing | No version tags, no releases |
| **CI testing** | ❌ Missing | Only Pages deployment; no test, lint, or security CI |
| **API documentation** | ❌ Missing | No documented API for the OAuth proxy |
| **Architecture docs** | ✅ Present | CODEBASE_ANALYSIS.md and SECURITY_ANALYSIS.md exist |

### What's Missing for a Truly Professional Open-Source Project

1. **Semantic versioning** with tagged releases and a populated CHANGELOG
2. **CI/CD pipeline** with testing, linting, security scanning
3. **API documentation** for the OAuth proxy endpoints
4. **Developer setup guide** — How to run locally, debug, contribute
5. **Example configurations** — Sample auth.json for different scenarios
6. **Automated dependency updates** — Dependabot or Renovate
7. **Badge ecosystem** — CI status, version, license, coverage badges in README
8. **Published npm package** for the OAuth proxy worker

---

## Preserving `irm | iex` After Modularization

> **TL;DR — Yes, absolutely.** The one-liner stays identical. Modularization happens *behind* the launcher, not instead of it. The user types the same command; the launcher just downloads and assembles the modules instead of running a 2,000-line monolith.

### The Question

Nova's entry point is a beloved one-liner:

```powershell
irm osd.raduti.com | iex
#  or
irm https://raw.githubusercontent.com/araduti/AmpCloud/main/Trigger.ps1 | iex
```

If the monolithic `Trigger.ps1` (2,248 lines) is broken into modules, does the one-liner still work? **Yes** — and it actually gets *better*.

### Why It Works Today

When a user runs `irm <url> | iex`, PowerShell:

1. Downloads the full text of `Trigger.ps1` into memory
2. Passes it to `Invoke-Expression`, which executes it as if typed at the console
3. `$PSScriptRoot` is **empty** (there's no script file on disk)

Trigger.ps1 already handles this — it checks `$PSScriptRoot` and, when it's empty, downloads all dependent files individually from GitHub:

```
Trigger.ps1 (line 1106-1131):
├── if ($PSScriptRoot) → copy Autopilot/ from local clone
└── else               → download each file from GitHub raw URLs

Trigger.ps1 (line 1187-1199):
├── if ($PSScriptRoot) → copy Progress/ from local clone
└── else               → download from GitHub raw URL
```

This means **the download-and-assemble pattern already exists**. Modularization simply extends it.

### The Launcher Pattern

After modularization, the one-liner **stays the same**. What changes is that `Trigger.ps1` becomes a thin launcher (~100-150 lines) instead of a 2,248-line monolith:

```
BEFORE (Today):                          AFTER (Modularized):
────────────────                          ────────────────────

irm osd.raduti.com | iex                 irm osd.raduti.com | iex
         │                                        │
         ▼                                        ▼
┌─────────────────────┐               ┌─────────────────────────┐
│  Trigger.ps1        │               │  Trigger.ps1 (launcher) │
│  2,248 lines        │               │  ~150 lines             │
│  ALL code inline    │               │                         │
│                     │               │  1. Parse params        │
│  • Logging          │               │  2. Download modules    │
│  • ADK install      │               │  3. Dot-source them    │
│  • ISO handling     │               │  4. Call main function  │
│  • WinPE build      │               └─────────────────────────┘
│  • Driver inject    │                        │
│  • File embedding   │                        ▼  downloads & dot-sources
│  • Auth config      │               ┌─────────────────────────┐
│  • Cleanup          │               │  Private/               │
│  • ...everything    │               │  ├── Logging.ps1        │
└─────────────────────┘               │  ├── ADK.ps1            │
                                      │  ├── ISO.ps1            │
                                      │  ├── WinPE.ps1          │
                                      │  ├── Drivers.ps1        │
                                      │  ├── Embed.ps1          │
                                      │  └── Auth.ps1           │
                                      └─────────────────────────┘
```

### Concrete Implementation

Here's exactly how the modularized `Trigger.ps1` launcher would work:

```powershell
#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Nova one-liner entry point.
.EXAMPLE
    irm osd.raduti.com | iex
#>
[CmdletBinding()]
param(
    [string] $GitHubUser   = 'araduti',
    [string] $GitHubRepo   = 'AmpCloud',
    [string] $GitHubBranch = 'main',
    [string] $WorkDir      = 'C:\Nova',
    [string] $WindowsISOUrl = '',
    [switch] $NoReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Module list ────────────────────────────────────────────────────
$modules = @(
    'src/engine/Private/Logging.ps1',
    'src/engine/Private/ADK.ps1',
    'src/engine/Private/ISO.ps1',
    'src/engine/Private/WinPE.ps1',
    'src/engine/Private/Drivers.ps1',
    'src/engine/Private/Embed.ps1',
    'src/engine/Private/Auth.ps1',
    'src/engine/Trigger.psm1'
)

$baseUrl = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch"
$tmpDir  = Join-Path $WorkDir 'modules'
$null    = New-Item -Path $tmpDir -ItemType Directory -Force

# ── Download and dot-source each module ────────────────────────────
foreach ($mod in $modules) {
    $localPath = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot $mod   # Local clone — use files on disk
    } else {
        $dest = Join-Path $tmpDir (Split-Path $mod -Leaf)
        Invoke-WebRequest -Uri "$baseUrl/$mod" -OutFile $dest -UseBasicParsing
        $dest                          # irm | iex — download from GitHub
    }
    . $localPath   # Dot-source into current scope
}

# ── Run ────────────────────────────────────────────────────────────
Invoke-NovaTrigger @PSBoundParameters
```

### Key Design Decisions

| Decision | Why |
|----------|-----|
| **Dot-source (`. file.ps1`), not `Import-Module`** | Dot-sourcing loads functions into the current scope, which is what `iex` creates. `Import-Module` would also work but adds overhead for simple function libraries. |
| **`$PSScriptRoot` check preserved** | Same pattern already used in current Trigger.ps1 (line 1106). If running from a local clone, use files on disk. If running via `irm \| iex`, download from GitHub. |
| **Download to `$WorkDir/modules/`** | Provides a cached local copy for the rest of the session, and makes the downloaded modules inspectable. |
| **Module list is explicit** | No glob/directory-listing needed. The launcher knows exactly which files to fetch. Deterministic, auditable, and cacheable. |
| **Single entry function `Invoke-NovaTrigger`** | All parameters forwarded via splatting. Clean separation between launcher and logic. |

### What This Enables

| Benefit | Detail |
|---------|--------|
| **Same one-liner** | `irm osd.raduti.com \| iex` — identical user experience |
| **Unit testable** | Each module can be tested independently with Pester |
| **Reviewable** | 200-line files instead of 2,248-line monolith |
| **Integrity checking** | Launcher can verify SHA256 hashes of each module before dot-sourcing |
| **Parallel downloads** | Launcher can download all modules concurrently via `Start-Job` or runspaces |
| **Caching** | Downloaded modules persist in `$WorkDir/modules/` for the session |
| **Selective updates** | Fix a bug in `Drivers.ps1` without touching `ADK.ps1` |
| **Custom URL shortener** | `osd.raduti.com` still points to the same `Trigger.ps1` — now it's just smaller and faster to download |

### Adding Integrity Verification

The launcher pattern naturally supports the SHA256 hash verification recommended in the Security Assessment (Finding #1). A `modules.json` manifest can be added:

```json
{
    "version": "1.0.0",
    "modules": {
        "src/engine/Private/Logging.ps1":  "a1b2c3d4e5f6...",
        "src/engine/Private/ADK.ps1":      "f6e5d4c3b2a1...",
        "src/engine/Trigger.psm1":         "1a2b3c4d5e6f..."
    }
}
```

```powershell
# In launcher — verify each module after download
$manifest = irm "$baseUrl/modules.json"
foreach ($mod in $modules) {
    $hash = (Get-FileHash -Path $localPath -Algorithm SHA256).Hash
    $expected = $manifest.modules.$mod
    if ($hash -ne $expected) {
        throw "Integrity check failed for $mod (expected $expected, got $hash)"
    }
    . $localPath
}
```

This gives you **signed module loading** — something that was impossible with the monolithic `irm | iex` pattern.

### Same Pattern for All Three Stages

The launcher pattern applies to all three stages:

```
Stage 1: Trigger.ps1 (launcher) → downloads Private/*.ps1 → runs Invoke-NovaTrigger
          ↓ embeds into WinPE:
Stage 2: Bootstrap.ps1 (launcher) → dot-sources Private/*.ps1 → runs Invoke-NovaBootstrap
          ↓ invokes:
Stage 3: Nova.ps1 (launcher) → dot-sources Private/*.ps1 → runs Invoke-NovaImaging
```

Since Trigger.ps1 already pre-stages Bootstrap.ps1 and Nova.ps1 into the WinPE image (lines 1139-1151), it would simply also stage their module files alongside them. Bootstrap.ps1 and Nova.ps1 launchers would dot-source from the local WinPE filesystem — no internet required at boot time, exactly as today.

### FAQ

**Q: Does `irm | iex` work with `Import-Module`?**  
A: Yes — you can `Import-Module` a `.psm1` file from a downloaded path. Dot-sourcing is simpler but both work.

**Q: What about `#Requires -RunAsAdministrator`?**  
A: Stays in the launcher. `#Requires` directives are evaluated before execution, so they work identically whether the script is run from file or via `iex`.

**Q: Does the module download add significant time?**  
A: No. Downloading 7 small files (~5-15 KB each) takes <1 second on any modern connection. The current monolithic Trigger.ps1 (108 KB) takes the same time as 7 files totaling ~108 KB. You can even parallelize with `Start-Job`.

**Q: Can I still fork-and-own?**  
A: Yes. The `$GitHubUser`/`$GitHubRepo`/`$GitHubBranch` parameters still control where modules download from:
```powershell
irm https://raw.githubusercontent.com/YOURUSER/AmpCloud/main/Trigger.ps1 | iex
```

**Q: What if the user is offline?**  
A: Same as today — the `irm` call fails and PowerShell shows an error. The scripts that run *inside* WinPE (Bootstrap.ps1, Nova.ps1) are pre-staged into the image by Trigger.ps1, so they work offline.

---

## GitHub Pages Compatibility with a Build System

> **TL;DR — Yes, fully supported.** GitHub Pages serves static files. A build system (Vite/esbuild) simply *produces* those static files. The build runs in GitHub Actions CI, outputs to a `dist/` folder, and Pages deploys that folder. This is the standard pattern used by thousands of Vite, React, Vue, and Angular projects hosted on GitHub Pages.

### The Concern

The REPORT.md recommends adding a Vite/esbuild build system (Recommendation #3, Phase 3). Since Nova's web UIs are hosted on GitHub Pages, does this even work? **Yes** — and the current `pages.yml` workflow already has the exact structure needed. Only one small change is required.

### How GitHub Pages Works

GitHub Pages is a **static file server**. It doesn't run any server-side code — it simply serves files from a directory. There are two deployment models:

| Model | How It Works | Use Case |
|-------|-------------|----------|
| **Static (current)** | Deploy raw files directly from the repo | Simple sites with no build step |
| **Build + Deploy** | CI builds assets → outputs to `dist/` → Pages serves `dist/` | Projects using Vite, esbuild, Webpack, etc. |

Nova currently uses the "static" model. The proposed build system uses the "build + deploy" model. Both deploy the same thing: **static HTML, CSS, and JS files**. The only difference is *where those files come from*.

### Current vs. Proposed Workflow

```
TODAY (no build step):                    AFTER (with Vite build):
──────────────────────                    ────────────────────────

  Source files in repo                      Source files in repo
  (raw HTML/CSS/JS)                         (src/*.ts, *.css, *.vue)
         │                                           │
         ▼                                           ▼
┌────────────────────┐                    ┌────────────────────┐
│ pages.yml workflow │                    │ pages.yml workflow │
│                    │                    │                    │
│ 1. Checkout repo   │                    │ 1. Checkout repo   │
│ 2. Upload . (root) │ ← entire repo     │ 2. npm ci          │ ← NEW
│ 3. Deploy to Pages │                    │ 3. npm run build   │ ← NEW
│                    │                    │ 4. Upload dist/    │ ← changed
└────────────────────┘                    │ 5. Deploy to Pages │
                                          └────────────────────┘
         │                                           │
         ▼                                           ▼
┌────────────────────┐                    ┌────────────────────┐
│ GitHub Pages       │                    │ GitHub Pages       │
│ serves raw files   │                    │ serves built files │
│ (unminified)       │                    │ (minified, hashed) │
└────────────────────┘                    └────────────────────┘
```

### Current Workflow (What You Have)

```yaml
# .github/workflows/pages.yml (current — 45 lines)
name: Deploy Web UI to GitHub Pages
on:
  push:
    branches: ["main"]
    paths:
      - "Editor/**"
      - "Monitoring/**"
      - "TaskSequence/**"
      - "Config/**"
      - "index.html"

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/configure-pages@v5
      - uses: actions/upload-pages-artifact@v3
        with:
          path: .              # ← uploads ENTIRE repo (387 MB!)
      - uses: actions/deploy-pages@v4
```

**Problems with the current approach:**
- Uploads the **entire repo** (387 MB including drivers) as a Pages artifact
- Serves raw, unminified HTML/CSS/JS
- No minification, no tree-shaking, no hashing
- No SRI (Subresource Integrity) hashes

### Proposed Workflow (With Build Step)

```yaml
# .github/workflows/pages.yml (proposed — with build step)
name: Deploy Web UI to GitHub Pages

on:
  push:
    branches: ["main"]
    paths:
      - "Editor/**"
      - "Monitoring/**"
      - "Nova-UI/**"
      - "Progress/**"
      - "TaskSequence/**"
      - "Config/**"
      - "index.html"
      - "package.json"
      - ".github/workflows/pages.yml"
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: "pages"
  cancel-in-progress: false

jobs:
  build-and-deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Build web assets
        run: npm run build          # Vite builds to dist/

      - name: Setup Pages
        uses: actions/configure-pages@v5

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: dist                # ← only built assets (~500 KB)

      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

### What Changes for the Developer

| Aspect | Today | With Build System |
|--------|-------|-------------------|
| **Edit a UI file** | Edit `Editor/index.html`, push to `main` | Edit `src/editor/App.ts`, push to `main` |
| **Local development** | Open `index.html` in browser | `npm run dev` (Vite dev server with HMR) |
| **Deploy** | Automatic on push | Automatic on push (build step added) |
| **Pages URL** | Same | Same — `https://araduti.github.io/AmpCloud/` |
| **Build time** | 0s (no build) | ~5-10s (Vite is extremely fast) |
| **Deployed size** | 387 MB (entire repo) | ~500 KB (only web assets) |

### What Does NOT Change

- **GitHub Pages URL** — stays `https://araduti.github.io/AmpCloud/`
- **User experience** — same pages, same URLs, same functionality
- **Deployment trigger** — still automatic on push to `main`
- **Free tier** — GitHub Pages free tier has no restrictions on build systems
- **Custom domain** — `osd.raduti.com` (if configured) continues to work

### Why Vite Is the Right Choice

| Feature | Why It Matters for Nova |
|---------|---------------------------|
| **Zero-config** | Detects HTML entry points automatically — your existing `index.html` files work as-is |
| **Multi-page mode** | Native support for Editor, Monitoring, Nova-UI, Progress as separate pages |
| **CSS extraction** | Pulls inline `<style>` blocks into optimized, hashed `.css` files |
| **JS minification** | Minifies and tree-shakes JavaScript — reduces 92 KB Monitoring page significantly |
| **SRI hashes** | Generates integrity hashes for all assets (security improvement) |
| **Dev server** | `npm run dev` with hot module replacement for instant feedback |
| **GitHub Pages plugin** | [`vite-plugin-github-pages`](https://github.com/nicolo-ribaudo/vite-plugin-github-pages) handles base path automatically |

### Minimal Vite Config for Nova

```javascript
// vite.config.js
import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  base: '/AmpCloud/',    // GitHub Pages serves from /AmpCloud/
  build: {
    outDir: 'dist',
    rollupOptions: {
      input: {
        main:       resolve(__dirname, 'index.html'),
        editor:     resolve(__dirname, 'Editor/index.html'),
        monitoring: resolve(__dirname, 'Monitoring/index.html'),
      },
    },
  },
});
```

> **Note:** Nova-UI and Progress are embedded in WinPE by Trigger.ps1, not served via GitHub Pages. They stay as single-file HTML pages since they run offline inside WinPE — no build system needed for those.

### Incremental Adoption Path

You don't have to convert everything at once. This is a safe, incremental path:

```
Step 1: Add package.json + vite.config.js (no code changes)
        Vite can build existing HTML files as-is
        ↓
Step 2: Update pages.yml to add build step
        Pages now serves optimized output — same files, smaller
        ↓
Step 3: Extract inline CSS/JS from monolithic HTML files
        Move <style> and <script> blocks to separate .css/.js files
        Vite bundles them back together, but now they're editable
        ↓
Step 4: (Optional) Migrate to TypeScript, add components
        Full modern development experience
```

**Step 1 is risk-free** — Vite treats plain HTML files as valid entry points and copies them to `dist/` with no changes. You can add the build step and verify that Pages still works identically before making any code changes.

### FAQ

**Q: Does GitHub Pages run Node.js or any server-side code?**  
A: No. GitHub Pages is a pure static file server. The build step runs in **GitHub Actions CI** (the workflow), not on Pages itself. Pages only serves the output.

**Q: Will my Pages URL change?**  
A: No. The URL stays `https://araduti.github.io/AmpCloud/`. The `base: '/AmpCloud/'` in `vite.config.js` ensures all asset paths are correct.

**Q: What about the TaskSequence JSON files and Config directory?**  
A: Vite's `public/` directory copies files as-is to `dist/`. Move `TaskSequence/` and `Config/` into `public/` (or configure Vite to include them) and they'll be served at the same URLs.

**Q: Does this affect the PowerShell scripts (Trigger.ps1, Bootstrap.ps1, Nova.ps1)?**  
A: No. The PowerShell scripts are downloaded via `raw.githubusercontent.com` URLs (GitHub raw content), not via GitHub Pages. The build system only affects the web UIs served via Pages.

**Q: What about the WinPE-embedded UIs (Nova-UI, Progress)?**  
A: These are downloaded by Trigger.ps1 and embedded directly into the WinPE image (lines 1187-1217). They run offline from `X:\` and are **not** served via GitHub Pages. They should stay as single-file HTML — no build system needed.

**Q: Is there a cost increase?**  
A: No. GitHub Actions minutes for public repos are free. The build step adds ~30 seconds to deployment. GitHub Pages has no additional cost regardless of whether files are built or raw.

---

## Next-Gen Recommendations

### 1. Modularize PowerShell into Modules

**Why:** 2,000+ line monolithic scripts are impossible to unit test, hard to review, and error-prone to maintain.

**How:** Use the **launcher pattern** described in [Preserving `irm | iex` After Modularization](#preserving-irm--iex-after-modularization):
- Keep `Trigger.ps1` as a thin launcher (~150 lines) that downloads and dot-sources module files
- Extract functions into focused modules (`Logging.ps1`, `ADK.ps1`, `WinPE.ps1`, etc.)
- Each function becomes independently testable with Pester
- The `irm osd.raduti.com | iex` one-liner works identically — the launcher handles everything
- Add a `modules.json` manifest for SHA256 integrity verification of each module

### 2. Add Comprehensive Testing

**Why:** Zero automated tests means every change risks regression. Critical for open-source trust.

**How:**
- **Pester v5** for PowerShell: Mock `Invoke-RestMethod`, test task sequence execution, verify error handling
- **Vitest** for JavaScript: Test `escapeHtml()`, token management, API calls, UI logic
- **Vitest + Miniflare** for Cloudflare Worker: Test JWT creation, CORS, rate limiting
- **Playwright/Cypress** for Editor E2E: Test drag-and-drop, save/load, auth flows
- **Target:** 80% code coverage on critical paths

### 3. Implement a Build System

**Why:** Shipping raw, unminified, monolithic files is not performant or maintainable.

**How:** Use **Vite** with the GitHub Pages deployment pattern described in [GitHub Pages Compatibility with a Build System](#github-pages-compatibility-with-a-build-system):
- **Vite** for web UIs: Build Editor, Monitoring, and UI pages with HMR for development
- **esbuild** for OAuth proxy: TypeScript compilation and bundling
- **Asset pipeline:** CSS extraction, minification, SRI hash generation
- **Dev server:** `npm run dev` for local development with hot reload
- GitHub Pages fully supports this — the build runs in CI, Pages serves the output

### 4. Migrate OAuth Proxy to TypeScript

**Why:** The worker handles security-critical crypto operations (JWT signing, key import, token validation). TypeScript provides type safety, better tooling, and catches errors at compile time.

**How:**
```typescript
// src/index.ts
interface Env {
  GITHUB_APP_ID: string;
  GITHUB_APP_PRIVATE_KEY: string;
  GITHUB_APP_INSTALLATION_ID: string;
  ENTRA_TENANT_ID?: string;
  ALLOWED_ORIGIN?: string;
  RATE_LIMITER: RateLimit;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    // Typed handlers with proper error types
  }
};
```

### 5. Add Security Hardening

| Improvement | Detail |
|-------------|--------|
| **Script integrity** | SHA256 hash verification before `iex` execution |
| **Rate limiting** | Cloudflare Workers rate limiting on all proxy endpoints |
| **CSP headers** | `<meta http-equiv="Content-Security-Policy">` on all pages |
| **SRI hashes** | Subresource integrity on all vendored scripts |
| **CodeQL scanning** | Automated security analysis in CI |
| **Dependabot** | Automated dependency vulnerability alerts |
| **Tenant enforcement** | Require `ENTRA_TENANT_ID` in production deployments |
| **Input validation** | Comprehensive length/format checks on all user inputs |

### 6. Optimize Repository Size

**Why:** 387 MB repository (338 MB drivers) makes cloning slow and hosting expensive.

**How:**
- **Git LFS** for driver binaries (`.sys`, `.exe`, `.dll`, `.pdb`)
- **Or external download:** Download drivers on-demand during Trigger.ps1 from a known URL
- **Remove debug symbols** (`.pdb` files) — saves ~250 MB+
- **Remove legacy OS drivers** (XP, Vista, Server 2003) unless actively needed

### 7. Add CI/CD Pipeline

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  lint-powershell:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - run: Install-Module PSScriptAnalyzer -Force
      - run: Invoke-ScriptAnalyzer -Path *.ps1 -Recurse -EnableExit

  test-powershell:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - run: Install-Module Pester -Force -MinimumVersion 5.0
      - run: Invoke-Pester -Path tests/ -CI

  lint-javascript:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: npx eslint .

  test-worker:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cd oauth-proxy && npm ci && npm test

  security:
    runs-on: ubuntu-latest
    steps:
      - uses: github/codeql-action/init@v3
      - uses: github/codeql-action/analyze@v3
```

### 8. Implement Component-Based UI Architecture

**Why:** 2,000+ line monolithic HTML files with inline JS/CSS are unmaintainable and untestable.

**How:** For GitHub Pages compatibility (no server-side rendering), use a lightweight approach:

- **Lit** or **Preact** for componentization (small footprint, no build required for basics)
- Or simply extract JavaScript into ES modules with `<script type="module">`
- Extract shared CSS into a design system
- Use CSS custom properties for theming
- Implement web components for reusable elements (deployment cards, diagnostic panels)

### 9. Implement Semantic Versioning and Releases

**How:**
- Tag releases with semver (`v1.0.0`, `v1.1.0`, etc.)
- Use GitHub Releases with auto-generated release notes
- Maintain CHANGELOG.md with [Keep a Changelog](https://keepachangelog.com/) format
- Consider automated release workflow with `release-please` or `semantic-release`

### 10. Enhance Monitoring and Observability

| Current | Next-Gen |
|---------|----------|
| JSON files in GitHub repo | Structured logging to centralized service |
| Manual staleness checks | Automated alerting (Teams/Slack webhooks are configured but disabled) |
| Basic deployment cards | Time-series charts with deployment trends |
| No error aggregation | Error categorization and root cause analysis |

---

## Priority Roadmap

### Phase 1: Foundation (Weeks 1-2)
- [ ] Add `package.json` to oauth-proxy with wrangler, vitest, typescript dev dependencies
- [ ] Add PSScriptAnalyzer to CI workflow
- [ ] Add CodeQL security scanning to CI workflow
- [ ] Set `ALLOWED_ORIGIN` in production Cloudflare Worker
- [ ] Enforce `ENTRA_TENANT_ID` in production
- [ ] Update `upload-pages-artifact` to v4
- [ ] Update wrangler `compatibility_date` to current date

### Phase 2: Testing (Weeks 3-4)
- [ ] Add Pester v5 tests for core PowerShell functions (auth, imaging, task sequence)
- [ ] Add Vitest tests for oauth-proxy (JWT, CORS, token validation)
- [ ] Add Vitest tests for Editor app.js (escapeHtml, toBase64, API handlers)
- [ ] Create CI workflow that runs tests on every PR

### Phase 3: Modernization (Weeks 5-8)
- [ ] Migrate oauth-proxy to TypeScript
- [ ] Upgrade MSAL.js from v2.39.0 to v4.x
- [ ] Add rate limiting to OAuth proxy (Cloudflare KV or Workers Rate Limiting)
- [ ] Implement script integrity verification (SHA256 hash check)
- [ ] Extract inline JS/CSS from monolithic HTML files
- [ ] Add build step (Vite/esbuild) for web assets

### Phase 4: Scale (Weeks 9-12)
- [ ] Move drivers to Git LFS or external storage
- [ ] Modularize PowerShell scripts into `.psm1` modules
- [ ] Add E2E tests for Editor (Playwright)
- [ ] Implement CSP headers on all pages
- [ ] Create first semantic version release (v1.0.0)
- [ ] Set up Dependabot for automated dependency updates
- [ ] Enable and configure alerts (Teams/Slack webhook integration)

### Phase 5: Next-Gen (Ongoing)
- [ ] Component-based UI with web components or Lit
- [ ] Structured observability and deployment analytics
- [ ] Plugin architecture for custom task sequence steps
- [ ] Multi-language expansion (community-contributed locales)
- [ ] API documentation (OpenAPI spec for OAuth proxy)
- [ ] Contributor developer experience (dev containers, codespaces config)

---

## Conclusion

Nova is a **solid, functional platform** with thoughtful security practices and comprehensive documentation. The core deployment pipeline works well and follows modern OAuth 2.0 best practices. However, to become a **truly performant, secure, and next-gen open-source project**, it needs investment in three key areas:

1. **Engineering infrastructure** — Testing, linting, CI/CD, package management
2. **Architecture modernization** — Modularization, TypeScript, build system, component-based UI
3. **Security hardening** — Rate limiting, integrity verification, CSP, input validation

The good news is that the foundation is strong. The authentication architecture is well-designed, error handling is comprehensive, and the codebase is well-documented. The recommendations above build on this foundation rather than requiring a rewrite.

**Bottom line:** With the Phase 1-3 improvements (~8 weeks of work), Nova would be competitive with commercial Windows deployment tools while offering the transparency and customizability of open source.

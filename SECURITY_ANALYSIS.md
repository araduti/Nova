# AmpCloud Authentication Security Analysis

> **Date:** 2026-03-25
> **Scope:** All authentication and authorization pathways in the AmpCloud repository

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Authentication Architecture Overview](#authentication-architecture-overview)
3. [Component Analysis](#component-analysis)
   - [Config/auth.json](#configauthjson)
   - [Trigger.ps1 — Authorization Code Flow with PKCE](#triggerps1--authorization-code-flow-with-pkce)
   - [Bootstrap.ps1 — WebView2 Browser (Auth Code + PKCE) with Device Code Fallback](#bootstrapps1--webview2-browser-auth-code--pkce-with-device-code-fallback)
   - [Editor (Web UI) — MSAL.js Popup Flow](#editor-web-ui--msaljs-popup-flow)
   - [GitHub API — Personal Access Token](#github-api--personal-access-token)
4. [Findings and Recommendations](#findings-and-recommendations)
   - [Strengths](#strengths)
   - [Findings](#findings)
5. [Threat Model](#threat-model)
6. [Conclusion](#conclusion)

---

## Executive Summary

AmpCloud implements **three distinct OAuth 2.0 authentication flows** to protect both the deployment engine and the web-based Task Sequence Editor. All flows use Microsoft Entra ID (Azure AD) as the identity provider with the `/organizations` (multi-tenant) authority, and tenant restrictions are enforced server-side at the app registration level.

**Overall assessment:** The authentication implementation follows modern security best practices for public client applications. The use of PKCE, minimal scopes, ephemeral token handling, and `sessionStorage` caching demonstrates a security-conscious design. The findings below are low-to-informational severity and represent defense-in-depth improvements rather than exploitable vulnerabilities.

---

## Authentication Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Config/auth.json                                │
│  { requireAuth: true, clientId: "...", redirectUri: "..." }           │
│  ↓ fetched by all three entry points                                  │
├───────────────┬────────────────────────┬──────────────────────────────┤
│  Trigger.ps1  │     Bootstrap.ps1      │    Editor (Web UI)           │
│  Auth Code +  │     Auth Code + PKCE   │    MSAL.js Popup Flow        │
│  PKCE (local  │     (WinPE WebView2    │    (browser, sessionStorage) │
│  browser)     │      Chromium browser, │                              │
│               │      Device Code       │                              │
│               │      fallback)         │                              │
├───────────────┼────────────────────────┼──────────────────────────────┤
│  Opens browser│  Embedded WebView2     │  MSAL loginPopup()           │
│  → localhost  │  control in WinForms   │  → Azure AD popup            │
│  listener     │  → intercepts redirect │  → redirect callback         │
│  captures code│  → token exchange      │  → sessionStorage cache      │
│  → token      │  Falls back to Device  │                              │
│  exchange     │  Code Flow if needed   │                              │
└───────────────┴────────────────────────┴──────────────────────────────┘
```

All three flows request only `openid profile` scopes — they function as a **pure identity gate** (verifying the user belongs to an allowed Entra ID tenant) without requesting API permissions or access tokens for downstream services.

---

## Component Analysis

### Config/auth.json

**Location:** `Config/auth.json`

```json
{
    "requireAuth": true,
    "clientId": "040045aa-2c28-42b5-9a10-3fce7778a454",
    "redirectUri": "https://araduti.github.io/AmpCloud/Editor/"
}
```

| Field | Purpose | Security Notes |
|-------|---------|----------------|
| `requireAuth` | Gates authentication enforcement | When `false` or absent, all auth is bypassed. |
| `clientId` | Azure AD application (client) ID | Public value — safe to expose in client apps. Not a secret. |
| `redirectUri` | OAuth redirect URI for the web editor | Must exactly match the URI registered in the Azure AD app. |

**Assessment:** ✅ No secrets stored. The `clientId` is a public application identifier per OAuth 2.0 public client design (RFC 6749 §2.1). The `redirectUri` is enforced server-side by Azure AD and cannot be exploited by modifying the client config alone.

---

### Trigger.ps1 — Authorization Code Flow with PKCE

**Function:** `Invoke-M365DeviceCodeAuth` (lines 1511–1677)
**OAuth Flow:** Authorization Code with PKCE (RFC 7636)
**Environment:** Full Windows (admin PowerShell console with browser access)

#### Flow Steps

1. **Config fetch** (line 1534): Downloads `auth.json` from the GitHub repository over HTTPS
2. **PKCE generation** (lines 1560–1567): Generates 32 random bytes → base64url code verifier; SHA-256 hash → code challenge
3. **Localhost listener** (lines 1570–1586): Binds to a random ephemeral port (49152–65535) on `http://localhost`
4. **Browser launch** (lines 1591–1605): Opens default browser to Azure AD `/authorize` with PKCE challenge
5. **Code capture** (lines 1607–1626): Waits up to 2 minutes for the redirect; parses the authorization code from the query string
6. **Token exchange** (lines 1654–1676): POSTs code + code_verifier to the `/token` endpoint; validates `id_token` presence
7. **Main gate** (lines 1697–1701): If auth fails, script exits with code 1

#### Security Assessment

| Aspect | Status | Details |
|--------|--------|---------|
| PKCE (code_challenge/verifier) | ✅ Implemented | 32-byte random verifier with S256 challenge method. Prevents authorization code interception. |
| Token storage | ✅ Ephemeral | `id_token` is validated for presence but not stored. Code verifier exists only in function scope. |
| Listener binding | ✅ Localhost only | HTTP listener binds to `http://localhost:<random-port>`, not externally accessible. |
| Timeout | ✅ 2 minutes | Prevents indefinite listener exposure. |
| Listener cleanup | ✅ `try/finally` | Listener is always stopped and closed, even on errors. |
| OAuth `state` parameter | ⚠️ Not used | See Finding F-01. |
| `prompt=select_account` | ✅ Good | Forces account picker, preventing silent sign-in with the wrong account. |

---

### Bootstrap.ps1 — WebView2 Browser (Auth Code + PKCE) with Device Code Fallback

**Primary function:** `Invoke-M365WebView2Auth` (embedded WebView2/Chromium control with PKCE)
**Fallback function:** `Invoke-M365DeviceCodeAuth` (Device Code Flow)
**Orchestrator:** `Invoke-M365Auth` (tries WebView2 first, falls back to device code)
**OAuth Flow:** Authorization Code with PKCE (primary) / Device Code (fallback)
**Environment:** Windows PE (WinForms WebView2 control with Chromium + SwiftShader rendering)

#### Flow Steps (Primary — WebView2 Browser)

1. **Config fetch** (`Invoke-M365Auth`): Downloads `auth.json` from GitHub over HTTPS
2. **WebView2 prerequisite check** (`Invoke-M365WebView2Auth`): Verifies managed DLLs exist at `X:\WebView2`; loads assemblies
3. **PKCE generation** (`Invoke-M365WebView2Auth`): Generates 32 random bytes → base64url code verifier; SHA-256 hash → code challenge
4. **WebView2 environment** (`Invoke-M365WebView2Auth`): Creates Chromium environment with WinPE-safe flags (`--disable-gpu`, `--use-angle=swiftshader`, `--in-process-gpu`, etc.)
5. **WinForms dialog with WebView2** (`Invoke-M365WebView2Auth`): Opens a dialog containing an embedded WebView2 control navigated to Azure AD `/authorize` with PKCE challenge
6. **Redirect interception** (`Invoke-M365WebView2Auth`): The `NavigationStarting` event handler intercepts the localhost redirect and captures the authorization code from the query string
7. **Token exchange** (`Invoke-M365WebView2Auth`): POSTs code + code_verifier to the `/token` endpoint; validates `id_token` presence
8. **Fallback** (`Invoke-M365Auth`): If WebView2 is unavailable or fails, transparently falls back to Device Code Flow

#### Flow Steps (Fallback — Device Code)

1. **Device code request** (`Invoke-M365DeviceCodeAuth`): POSTs to the `/devicecode` endpoint to obtain `user_code` and `device_code`
2. **WinForms dialog** (`Invoke-M365DeviceCodeAuth`): Displays the `user_code` in a styled dialog with the verification URL
3. **Token polling** (`Invoke-M365DeviceCodeAuth`): Timer-based polling every `interval` seconds; handles `authorization_pending` and `slow_down` responses

#### Security Assessment

| Aspect | Status | Details |
|--------|--------|---------|
| PKCE (primary flow) | ✅ Implemented | 32-byte random verifier with S256 challenge method. Prevents authorization code interception. |
| WebView2 rendering | ✅ Chromium-based | Uses Edge WebView2 runtime with SwiftShader software rendering for WinPE compatibility. |
| Redirect interception | ✅ Client-side | WebView2 `NavigationStarting` event captures the redirect before any HTTP request is made to localhost. |
| Graceful fallback | ✅ Transparent | If WebView2 runtime is missing or fails, Device Code Flow is used automatically. |
| Token storage | ✅ Ephemeral | Tokens are validated for presence but not stored. Code verifier exists only in function scope. |
| `prompt=select_account` | ✅ Good | Forces account picker, preventing silent sign-in with the wrong account. |
| WinPE GPU flags | ✅ Applied | `--disable-gpu --use-angle=swiftshader --enable-unsafe-swiftshader` ensures rendering without GPU hardware. |
| Device Code Flow (fallback) | ✅ Preserved | Full Device Code Flow with timer polling is kept as fallback. |
| Phishing risk | ✅ Reduced | Primary flow uses an embedded browser — no codes to copy, no external device needed. Fallback Device Code Flow still has inherent phishing risk (see Finding F-02). |

---

### Editor (Web UI) — MSAL.js Popup Flow

**Library:** MSAL Browser v2.39.0 (self-hosted at `Editor/lib/msal-browser.min.js`)
**Function:** Anonymous IIFE `initAuth()` in `Editor/js/app.js` (lines 515–624)
**Environment:** Browser (GitHub Pages)

#### Flow Steps

1. **Config fetch** (line 546): Fetches `auth.json` relative to the editor URL
2. **MSAL initialization** (lines 565–573): Creates `PublicClientApplication` with `sessionStorage` cache
3. **Session check** (lines 576–593): Checks for redirect callback response, then for cached accounts
4. **Login** (lines 597–608): `loginPopup()` with `openid profile` scopes
5. **Logout** (lines 611–618): `logoutPopup()` + page reload

#### Security Assessment

| Aspect | Status | Details |
|--------|--------|---------|
| MSAL library | ✅ v2.39.0 | Latest v2.x release. Handles PKCE, token management, and session hygiene internally. |
| Cache location | ✅ `sessionStorage` | Tokens are cleared when the tab closes. Not shared across tabs. Protected by same-origin policy. |
| Scopes | ✅ Minimal | Only `openid profile` — no API permissions, minimizing attack surface. |
| Login method | ✅ `loginPopup()` | Pop-up avoids full-page redirect, keeping editor state intact. |
| UI gating | ✅ Secure by default | Toolbar and main layout are hidden (`display:none`) until `showEditor()` is called after successful auth. Login overlay is visible by default. |
| Login button visibility | ✅ Progressive | Button is hidden until MSAL init completes and confirms no session exists. |
| Error display | ✅ User-friendly | Auth errors are shown in a designated `<p>` element; no stack traces or token data exposed. |
| Config fetch failure | ⚠️ Fails open | See Finding F-03. |
| Authority | ✅ `/organizations` | Multi-tenant endpoint; tenant restrictions are enforced by Azure AD server-side. |

---

### GitHub API — Personal Access Token

**Function:** `Publish-BootImage` in `Trigger.ps1` (lines 1374–1505), called from the Main region (lines 1789–1811)
**Auth method:** GitHub Personal Access Token (PAT) with `repo` scope

#### Flow Steps

1. **Token prompt** (Main region, line 1793): `Read-Host -AsSecureString` — masked console input
2. **Conversion** (Main region, lines 1794–1796): `SecureString` → `BSTR` → plain text (scoped to `try` block)
3. **Usage** (`Publish-BootImage`, lines 1391–1393, 1459): `Authorization: token <PAT>` header on GitHub API calls
4. **Cleanup** (Main region, lines 1808–1809): Plain text set to `$null`; BSTR zeroed via `ZeroFreeBSTR()`

#### Security Assessment

| Aspect | Status | Details |
|--------|--------|---------|
| Input method | ✅ SecureString | Token is never displayed on screen during input. |
| Memory cleanup | ✅ Explicit | BSTR is zeroed after use; plain text variable is nulled. |
| Scope | ✅ User-controlled | User provides their own PAT; no hardcoded tokens. |
| Transport | ✅ HTTPS only | All GitHub API calls use `https://api.github.com`. |
| Storage | ✅ Not persisted | Token is never written to disk or environment variables. |

---

## Findings and Recommendations

### Strengths

The following security best practices are already implemented:

- **S-01: PKCE on Authorization Code Flow** — Trigger.ps1 uses RFC 7636 PKCE with S256 challenge method, protecting against authorization code interception attacks.
- **S-02: Minimal OAuth scopes** — All three flows request only `openid profile`, which is the minimum needed for identity verification. No API tokens are issued.
- **S-03: Ephemeral token handling** — Tokens are validated for presence but not stored long-term. PowerShell scripts discard tokens after the identity gate.
- **S-04: sessionStorage over localStorage** — The web editor uses `sessionStorage`, which clears when the tab closes and is not shared across tabs.
- **S-05: TLS 1.2 enforcement** — Both `Bootstrap.ps1` and `AmpCloud.ps1` explicitly set `[Net.ServicePointManager]::SecurityProtocol = Tls12` to prevent downgrade attacks in WinPE.
- **S-06: Server-side tenant restrictions** — Tenant access control is enforced by Azure AD at the app registration level, not client-side where it could be bypassed.
- **S-07: No hardcoded secrets** — No tokens, passwords, or client secrets are committed to the repository.
- **S-08: GitHub PAT memory cleanup** — The PAT used for image upload is explicitly zeroed from memory after use.
- **S-09: Secure-by-default UI** — The editor's toolbar and main content are hidden by default (`display:none`) and only revealed after authentication succeeds.

### Findings

#### F-01: Missing OAuth `state` Parameter in Trigger.ps1 (Low)

**Component:** `Trigger.ps1`, `Invoke-M365DeviceCodeAuth`, line 1591
**Severity:** Low
**Description:** The Authorization Code Flow in Trigger.ps1 does not include a `state` parameter in the authorize request. The `state` parameter protects against CSRF attacks where an attacker tricks the victim's browser into using the attacker's authorization code.
**Mitigation factors:** The localhost HTTP listener binds to a random ephemeral port and runs for at most 2 minutes, which limits the window of opportunity. Additionally, PKCE provides strong protection against code injection. However, the `state` parameter is still recommended by RFC 6749 §10.12 as a defense-in-depth measure.
**Recommendation:** Generate a random `state` value before the authorize request, include it in the URL, and validate it when parsing the callback response. This is a defense-in-depth measure on top of the existing PKCE protection.

#### F-02: Device Code Flow Phishing Risk — Mitigated (Informational)

**Component:** `Bootstrap.ps1`, `Invoke-M365DeviceCodeAuth` (fallback path)
**Severity:** Informational
**Description:** The Device Code Flow inherently requires users to visit a URL and enter a code. An attacker who initiates a device code flow on their own could display a code to an unsuspecting user and trick them into authenticating on the attacker's behalf. This is a known limitation of the Device Code Flow (RFC 8628 §5.4) and is not a vulnerability in AmpCloud's implementation.
**Mitigation:** Bootstrap.ps1 now uses an embedded WebView2 (Chromium) browser with Auth Code + PKCE as the primary authentication method. The Device Code Flow is only used as a fallback when the WebView2 runtime is not present in the WinPE image. This significantly reduces the phishing surface since most deployments will use the browser-based flow.
**Recommendation:** No further code change required. For maximum security, ensure WinPE images are built using Trigger.ps1's Build-WinPE function, which embeds the WebView2 runtime (step 4e).

#### F-03: Editor Fails Open When Config is Unavailable (Low)

**Component:** `Editor/js/app.js`, line 620–623
**Severity:** Low
**Description:** When the `auth.json` config file cannot be fetched (network error, 404, etc.), the editor catches the error and calls `showEditor(null)`, displaying the editor without authentication. This means a network failure or misconfiguration could expose the editor without auth.
**Mitigation factors:** The editor is a client-side tool hosted on GitHub Pages — the task sequence JSON files it edits are stored in the same public repository. An attacker who can modify files in the repo already has greater access than the editor provides. The editor does not have write access to the repository; changes must be committed through Git.
**Recommendation:** Consider failing closed instead of open. When `auth.json` is unreachable and `requireAuth` was previously known to be `true`, show an error message rather than bypassing authentication. This could be implemented by checking a cached config or defaulting to auth-required behavior.

#### F-04: Trigger.ps1 Missing TLS 1.2 Enforcement (Low)

**Component:** `Trigger.ps1` (entire file)
**Severity:** Low
**Description:** Both `Bootstrap.ps1` (line 59) and `AmpCloud.ps1` (line 93) explicitly set `[Net.ServicePointManager]::SecurityProtocol = Tls12` to prevent TLS downgrade attacks. However, `Trigger.ps1` does not set this. While Trigger.ps1 runs on a full Windows installation (which likely already defaults to TLS 1.2), older PowerShell 5.1 environments may default to SSL3/TLS 1.0.
**Mitigation factors:** Trigger.ps1 is designed to run on full Windows (not WinPE), where modern .NET and OS versions default to TLS 1.2+. The risk is limited to older Windows installations.
**Recommendation:** Add `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12` near the top of Trigger.ps1 for consistency and defense in depth.

#### F-05: Localhost Listener Uses HTTP (Not HTTPS) (Informational)

**Component:** `Trigger.ps1`, line 1574
**Severity:** Informational
**Description:** The temporary localhost listener in Trigger.ps1 uses `http://localhost:<port>/`. While HTTPS would be ideal, setting up a self-signed certificate for a 2-minute ephemeral listener is impractical and unnecessary.
**Mitigation factors:** Traffic on `localhost` never leaves the machine and cannot be intercepted over the network. The listener is only active for up to 2 minutes. This is the standard approach recommended by RFC 8252 (OAuth 2.0 for Native Apps) §7.3 — native apps should use `http://localhost` loopback redirects.
**Recommendation:** No change required. The use of `http://localhost` for native OAuth redirects is explicitly endorsed by RFC 8252.

#### F-06: No Token Signature Validation (Informational)

**Component:** All three auth flows
**Severity:** Informational
**Description:** The PowerShell scripts (Trigger.ps1, Bootstrap.ps1) check for the presence of `id_token` in the response but do not validate the JWT signature, issuer, or audience claims. The web editor delegates this entirely to MSAL.js.
**Mitigation factors:** The token response comes directly from Microsoft's token endpoint over HTTPS (TLS-protected channel). Since the scripts communicate directly with `login.microsoftonline.com` and do not accept tokens from untrusted sources, the TLS channel provides the authenticity guarantee. This approach is acceptable when the token is received from the token endpoint rather than via a front-channel redirect. MSAL.js handles validation internally for the editor.
**Recommendation:** No change required for the current use case. If the project later uses access tokens to call APIs, full JWT validation (signature, issuer, audience, expiry) should be implemented.

---

## Threat Model

| Threat | Vector | Mitigations | Residual Risk |
|--------|--------|-------------|---------------|
| **Auth bypass via config tampering** | Modify `auth.json` to set `requireAuth: false` | Config hosted in the Git repository; protected by branch protection and repo access controls | Low — requires repo write access |
| **Authorization code interception** | Intercept the auth code from the redirect | PKCE (S256) prevents code replay; localhost listener is not network-accessible | Very Low |
| **Token theft (web)** | XSS or browser extension steals tokens from sessionStorage | Same-origin policy; no `eval()` or dynamic script injection in editor code; tokens cleared on tab close | Low |
| **Token theft (PowerShell)** | Memory dump or process inspection | Tokens are ephemeral (not stored); GitHub PAT is zeroed after use | Low |
| **Script tampering** | Man-in-the-middle modifying downloaded scripts | All downloads use HTTPS (TLS 1.2); GitHub SSL certificates provide server authentication | Low |
| **Device Code phishing** | Attacker displays their own code to an operator | Primary flow uses embedded WebView2 browser (no codes); Device Code is fallback only; Azure AD consent screen shows app name | Very Low (mitigated by WebView2 browser) |
| **MSAL library supply chain** | Compromised MSAL library | Self-hosted (not CDN); version pinned at v2.39.0; integrity can be verified against the npm package | Very Low |
| **Replay attacks** | Reuse of captured authorization codes | PKCE code verifier is single-use; authorization codes expire quickly (typically 10 minutes) | Very Low |
| **TLS downgrade** | Downgrade to SSL3/TLS 1.0 | Explicit `Tls12` enforcement in Bootstrap.ps1 and AmpCloud.ps1; recommended for Trigger.ps1 (F-04) | Low |

---

## Conclusion

AmpCloud's authentication implementation is well-designed and follows current industry best practices for public client OAuth 2.0 applications. The use of PKCE, minimal scopes, ephemeral token handling, server-side tenant restrictions, and `sessionStorage`-based caching demonstrates a mature security posture.

The findings identified are **low or informational severity** and represent opportunities for defense-in-depth hardening rather than exploitable vulnerabilities. The two most actionable improvements are:

1. **F-04 (TLS 1.2 in Trigger.ps1):** A one-line addition for consistency with the other scripts.
2. **F-01 (OAuth state parameter):** A defense-in-depth addition alongside the existing PKCE protection.

No critical or high-severity vulnerabilities were found. The authentication system cannot be bypassed through the application itself — the only path to bypass is modifying the configuration in the Git repository, which requires repository write access.

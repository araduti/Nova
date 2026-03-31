# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Nova, **please do not open a public issue.**

Instead, report it privately:

1. **GitHub Private Vulnerability Reporting** — use the [**Security → Report a vulnerability**](../../security/advisories/new) tab on this repository.
2. **Email** — contact the maintainers at the email address listed in the repository.

Please include:

- A description of the vulnerability
- Steps to reproduce (or a proof-of-concept)
- The affected component(s) (e.g. `Trigger.ps1`, `Bootstrap.ps1`, `Nova.ps1`, `Editor`, `oauth-proxy`)
- Any potential impact or severity assessment

We will acknowledge your report within **3 business days** and aim to release a fix within **30 days** of confirmation.

## Supported Versions

| Version | Supported |
|---------|-----------|
| `main` branch (latest) | ✅ |
| Older releases | Best-effort |

## Security-Sensitive Areas

The following areas deserve extra scrutiny when contributing:

| Area | Risk | Mitigation |
|------|------|------------|
| Script delivery (`irm \| iex`) | Remote code execution | Scripts fetched over HTTPS from GitHub only |
| OAuth token handling | Token leakage | Ephemeral tokens; never persisted to disk |
| WiFi passwords | Plaintext in RAM | WinPE environment is ephemeral; cleared on reboot |
| Disk partitioning | Data loss | Explicit disk index parameter; confirmation in UI |
| `unattend.xml` injection | Privilege escalation | Content validated before embedding |
| Status JSON (`Nova-Status.json`) | Information disclosure | No secrets or credentials written to status file |

## Security Design

For a comprehensive analysis of authentication flows, threat model, and security findings, see [**SECURITY_ANALYSIS.md**](SECURITY_ANALYSIS.md).

Key design decisions:

- **TLS 1.2** explicitly enforced in all WinPE scripts
- **OAuth 2.0 PKCE** for browser-based authentication (no client secrets)
- **Device Code Flow** fallback for constrained environments
- **Ephemeral tokens** — never written to disk
- **No secrets in source** — only public client IDs are committed

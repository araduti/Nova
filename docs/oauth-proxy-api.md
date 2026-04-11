# Nova OAuth Proxy — API Reference

> **Runtime:** Cloudflare Worker  
> **Source:** `oauth-proxy/src/`  
> **Deployment:** `cd oauth-proxy && npm run deploy`

---

## Overview

The Nova GitHub OAuth CORS Proxy provides three endpoints:

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/login/device/code` | Initiate GitHub Device Flow |
| POST | `/login/oauth/access_token` | Poll for Device Flow token |
| POST | `/api/token-exchange` | Exchange Entra ID token → GitHub installation token |
| OPTIONS | `*` | CORS preflight |

All other methods/paths return `404 Not Found` or `405 Method Not Allowed`.

---

## Endpoints

### POST /login/device/code

Proxies to GitHub's Device Flow initiation endpoint. No authentication required.

**Request:**

```http
POST /login/device/code
Content-Type: application/x-www-form-urlencoded

client_id=YOUR_GITHUB_APP_CLIENT_ID
```

**Success Response (200):**

```json
{
  "device_code": "3584d83530557fdd4b95...",
  "user_code": "WDJB-MJHT",
  "verification_uri": "https://github.com/login/device",
  "expires_in": 900,
  "interval": 5
}
```

---

### POST /login/oauth/access_token

Polls GitHub to exchange a device code for an access token. No authentication required.

**Request:**

```http
POST /login/oauth/access_token
Content-Type: application/x-www-form-urlencoded

client_id=YOUR_GITHUB_APP_CLIENT_ID&device_code=3584d83530557fdd4b95&grant_type=urn:ietf:params:oauth:grant-type:device_code
```

**Success Response (200) — token granted:**

```json
{
  "access_token": "ghu_16C7e42F292c6912E7...",
  "expires_in": 28800,
  "refresh_token": "ghr_1B4a2e77838347a7E420...",
  "refresh_token_expires_in": 15811200,
  "token_type": "bearer",
  "scope": "repo"
}
```

**Pending Response (200) — user hasn't authorized yet:**

```json
{
  "error": "authorization_pending",
  "error_description": "User has not yet authorized the request"
}
```

---

### POST /api/token-exchange

Exchanges a Microsoft Entra ID access token for a scoped GitHub App installation token. Requires a valid Entra ID Bearer token.

**Request:**

```http
POST /api/token-exchange
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGc...
```

**Success Response (200):**

```json
{
  "token": "ghs_16C7e42F292c6912E7...",
  "expires_at": "2026-01-15T23:59:59Z",
  "user": "John Doe"
}
```

**Error Responses:**

| Status | Error Code | Condition |
|--------|-----------|-----------|
| 401 | `missing_token` | No `Authorization: Bearer` header |
| 401 | `invalid_token` | Entra token rejected by Microsoft Graph `/me` |
| 403 | `tenant_mismatch` | Token tenant doesn't match `ENTRA_TENANT_ID` |
| 500 | `jwt_error` | Failed to create GitHub App JWT |
| 501 | `proxy_not_configured` | Missing required env vars (`GITHUB_APP_ID`, etc.) |
| 502 | `github_app_error` | GitHub rejected the installation token request |

**Internal Flow:**

1. Extract Entra ID token from `Authorization: Bearer` header
2. Validate via Microsoft Graph API `GET /me`
3. (Optional) Check token tenant claim (`tid`) against `ENTRA_TENANT_ID`
4. Create GitHub App JWT (RS256, 10-min expiry, 60-second clock skew buffer)
5. Request installation access token with `contents:write` permission
6. Return scoped token to caller

---

## CORS

All responses include CORS headers:

```
Access-Control-Allow-Origin: {origin}
Access-Control-Allow-Methods: POST, OPTIONS
Access-Control-Allow-Headers: Content-Type, Accept, Authorization
Access-Control-Max-Age: 86400
Vary: Origin
```

| Configuration | Behavior |
|---------------|----------|
| `ALLOWED_ORIGIN` not set | Reflects the request `Origin` header (or `*` if absent) |
| `ALLOWED_ORIGIN` set | Returns the configured origin; mismatched origins get a `403` |

Preflight `OPTIONS` requests return `204 No Content` with CORS headers.

---

## Rate Limiting

All non-preflight requests are subject to IP-based rate limiting using a
sliding-window algorithm.

| Parameter | Value |
|-----------|-------|
| **Limit** | 60 requests per IP |
| **Window** | 60 seconds (sliding) |
| **Scope** | Per Worker isolate (not globally shared) |

**Response Headers** (included on every response):

```
RateLimit-Limit: 60
RateLimit-Remaining: 42
RateLimit-Reset: 60
```

**When the limit is exceeded (429):**

```json
{
  "error": "rate_limit_exceeded",
  "error_description": "Too many requests. Please try again later."
}
```

The `Retry-After` header indicates how many seconds to wait before retrying.

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ALLOWED_ORIGIN` | No | Lock proxy to a single browser origin (e.g. `https://nova.raduti.com`). If unset, origins are reflected. |
| `GITHUB_APP_ID` | For `/api/token-exchange` | GitHub App numeric ID. |
| `GITHUB_APP_PRIVATE_KEY` | For `/api/token-exchange` | PEM private key (PKCS#1 or PKCS#8). Literal `\n` is normalized. |
| `GITHUB_APP_INSTALLATION_ID` | For `/api/token-exchange` | Installation ID for the target repository. |
| `ENTRA_TENANT_ID` | No | Restrict accepted Entra tokens to a specific Azure AD tenant. |

---

## Usage Examples

### Device Flow (browser)

```js
// 1. Request device code
const resp = await fetch('https://nova-proxy.workers.dev/login/device/code', {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: 'client_id=Iv1.abc123',
});
const { device_code, user_code, verification_uri } = await resp.json();
// Show user_code and verification_uri to the user

// 2. Poll for token
const poll = setInterval(async () => {
  const r = await fetch('https://nova-proxy.workers.dev/login/oauth/access_token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `client_id=Iv1.abc123&device_code=${device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code`,
  });
  const data = await r.json();
  if (data.access_token) { clearInterval(poll); /* use token */ }
}, 5000);
```

### Token Exchange (Entra ID → GitHub)

```js
const resp = await fetch('https://nova-proxy.workers.dev/api/token-exchange', {
  method: 'POST',
  headers: { Authorization: `Bearer ${entraToken}` },
});
const { token, expires_at, user } = await resp.json();
```

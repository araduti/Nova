# AmpCloud GitHub OAuth CORS Proxy

GitHub's OAuth Device Flow endpoints (`/login/device/code`,
`/login/oauth/access_token`) do **not** return CORS headers, so browsers
block direct calls from the AmpCloud Editor.

This directory contains a lightweight **Cloudflare Worker** that:

1. Proxies the Device Flow endpoints with CORS headers (no secrets stored).
2. Provides an **Entra ID → GitHub token exchange** endpoint so the
   AmpCloud engine and Monitoring dashboard can reuse the Entra ID token
   from sign-in instead of requiring a separate GitHub PAT.

---

## Deploy to Cloudflare Workers (free tier)

### 1. Install Wrangler (Cloudflare CLI)

```bash
npm install -g wrangler
wrangler login          # opens browser to authenticate
```

### 2. Create the Worker

```bash
cd oauth-proxy
wrangler init ampcloud-oauth-proxy
```

Copy `worker.js` into the generated `src/` folder (or point `wrangler.toml`
at it).

### 3. Configure environment variables

In the Cloudflare dashboard → your Worker → **Settings → Variables &
Secrets**:

| Variable                       | Required | Description                                     |
| ------------------------------ | -------- | ----------------------------------------------- |
| `ALLOWED_ORIGIN`               | No       | Lock proxy to a single origin (e.g. `https://<you>.github.io`) |
| `GITHUB_APP_ID`                | For token exchange | Your GitHub App's numeric App ID       |
| `GITHUB_APP_PRIVATE_KEY`       | For token exchange | The App's PEM private key (PKCS#8)     |
| `GITHUB_APP_INSTALLATION_ID`   | For token exchange | Installation ID for your repo          |
| `ENTRA_TENANT_ID`              | No       | Restrict accepted Entra tokens to one tenant    |

The `ALLOWED_ORIGIN` variable is optional.  When set, only requests from
that origin are allowed.

The `GITHUB_APP_*` variables are required for the `/api/token-exchange`
endpoint.  If not configured, the endpoint returns `501 Not Configured`
and the Device Flow / PAT fallbacks continue to work.

### 4. Deploy

```bash
wrangler deploy
```

Wrangler prints the Worker URL, for example:

```
https://ampcloud-oauth-proxy.<you>.workers.dev
```

### 5. Configure AmpCloud

Add the Worker URL to `Config/auth.json`:

```json
{
    "githubOAuthProxy": "https://ampcloud-oauth-proxy.<you>.workers.dev"
}
```

---

## Endpoints

### `POST /login/device/code`

Proxies GitHub Device Flow code request (CORS headers added).

### `POST /login/oauth/access_token`

Proxies GitHub Device Flow token poll (CORS headers added).

### `POST /api/token-exchange`

Exchanges an Entra ID access token for a scoped GitHub installation token.

**Request:**

```
POST /api/token-exchange
Authorization: Bearer <entra-access-token>
Content-Type: application/json
```

**Response (200):**

```json
{
    "token": "ghs_...",
    "expires_at": "2026-03-28T07:00:00Z",
    "user": "John Doe"
}
```

**How it works:**

```
AmpCloud Engine / Dashboard               Cloudflare Worker                GitHub
       │                                         │                          │
       │  POST /api/token-exchange               │                          │
       │  Authorization: Bearer <entra-token>     │                          │
       │ ────────────────────────────────────────>│                          │
       │                                         │                          │
       │                 1. Validate Entra token  │                          │
       │                    GET /v1.0/me ─────────┼──> Microsoft Graph       │
       │                    <── 200 OK ───────────┼──  (token is valid)      │
       │                                         │                          │
       │                 2. Create GitHub App JWT │                          │
       │                    (signed with          │                          │
       │                     GITHUB_APP_PRIVATE_KEY)                         │
       │                                         │                          │
       │                 3. Request installation  │                          │
       │                    access token ─────────┼──> GitHub API            │
       │                    <── { token } ────────┼──  (contents:write)      │
       │                                         │                          │
       │  { token, expires_at, user }            │                          │
       │<────────────────────────────────────────│                          │
```

No client secrets travel from the engine/browser to the proxy.  The
GitHub App private key is stored only in Cloudflare Worker secrets.

---

## Device Flow (existing)

```
Browser (Editor)                    Cloudflare Worker               GitHub
       │                                   │                          │
       │  POST /login/device/code          │                          │
       │ ─────────────────────────────────>│                          │
       │                                   │  POST /login/device/code │
       │                                   │ ────────────────────────>│
       │                                   │  { user_code, ... }      │
       │  { user_code, ... } + CORS hdrs   │<─────────────────────── │
       │<──────────────────────────────────│                          │
       │                                                              │
       │  (user opens github.com/login/device, enters code)           │
       │                                                              │
       │  POST /login/oauth/access_token   │                          │
       │ ─────────────────────────────────>│                          │
       │                                   │  POST .../access_token   │
       │                                   │ ────────────────────────>│
       │                                   │  { access_token }        │
       │  { access_token } + CORS hdrs     │<─────────────────────── │
       │<──────────────────────────────────│                          │
```

No client secret is involved at any step.  The proxy only adds CORS headers
and only forwards to allowlisted GitHub URLs.

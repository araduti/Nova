# AmpCloud GitHub OAuth CORS Proxy

GitHub's OAuth Device Flow endpoints (`/login/device/code`,
`/login/oauth/access_token`) do **not** return CORS headers, so browsers
block direct calls from the AmpCloud Editor.

This directory contains a lightweight **Cloudflare Worker** that proxies
those two endpoints and adds the required CORS headers.  Device Flow does
**not** require a `client_secret` — only the public `client_id` and the
`device_code` pass through the proxy, so **no secrets are stored**.

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

### 3. (Optional) Lock down the allowed origin

In the Cloudflare dashboard → your Worker → **Settings → Variables &
Secrets**, you can add:

| Variable         | Value                            |
| ---------------- | -------------------------------- |
| `ALLOWED_ORIGIN` | `https://<you>.github.io`        |

This variable is **optional**.  When set, only requests from that exact
origin are allowed.  When omitted, the proxy reflects the request's
`Origin` header back, which is safe because Device Flow carries no
secrets (only the public `client_id` and temporary `device_code`).

### 4. Deploy

```bash
wrangler deploy
```

Wrangler prints the Worker URL, for example:

```
https://ampcloud-oauth-proxy.<you>.workers.dev
```

### 5. Configure the Editor

Add the Worker URL to `Config/auth.json`:

```json
{
    "githubOAuthProxy": "https://ampcloud-oauth-proxy.<you>.workers.dev"
}
```

Push the change; the Editor will pick it up on next page load and use the
GitHub OAuth Device Flow (consent screen) instead of prompting for a PAT.

---

## How it works

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
       │  (user opens github.com/login/device, enters code, clicks Authorize)
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
and only forwards to two allowlisted GitHub URLs.

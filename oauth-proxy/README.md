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

### 1. Install dependencies

```bash
cd oauth-proxy
npm install
```

### 2. Deploy the Worker

The repository includes a ready-to-use `wrangler.toml`.  If you are
deploying to your own Cloudflare account, update the `account_id` field
in `wrangler.toml` with your own Account ID (visible in `wrangler whoami`
or in the Cloudflare dashboard).

```bash
npx wrangler login      # opens browser to authenticate
npm run deploy
```

Wrangler prints the Worker URL, for example:

```
https://ampcloud-oauth-proxy.<you>.workers.dev
```

### 3. Configure environment variables

The worker reads several environment variables at runtime.
**Wrangler does not create these automatically** — you must set them
yourself using one of the methods described below.

| Variable                       | Required | Description                                     |
| ------------------------------ | -------- | ----------------------------------------------- |
| `ALLOWED_ORIGIN`               | No       | Lock proxy to a single origin (e.g. `https://<you>.github.io`) |
| `GITHUB_APP_ID`                | For token exchange | Your GitHub App's numeric App ID       |
| `GITHUB_APP_PRIVATE_KEY`       | For token exchange | The App's PEM private key (PKCS#1 or PKCS#8) |
| `GITHUB_APP_INSTALLATION_ID`   | For token exchange | Installation ID for your repo          |
| `ENTRA_TENANT_ID`              | No       | Restrict accepted Entra tokens to one tenant    |

`ALLOWED_ORIGIN` is optional.  When set, only requests whose `Origin`
header matches this value are processed; all others receive a `403
Forbidden` response.  Leave it unset to allow any origin (safe because the
proxy only forwards public Device Flow data).

The `GITHUB_APP_*` variables are required **only** for the
`/api/token-exchange` endpoint (Entra ID → GitHub token exchange).  If not
configured, that endpoint returns `501 Not Configured` and the Device Flow
/ PAT fallbacks continue to work normally.

#### Setting secrets via Wrangler CLI

Sensitive values (private keys, app IDs) should be stored as **secrets** so
they are encrypted at rest and never appear in plain text in the dashboard
or in `wrangler.toml`:

```bash
wrangler secret put GITHUB_APP_ID
# paste your App ID and press Enter

wrangler secret put GITHUB_APP_PRIVATE_KEY
# paste the full PEM key (including -----BEGIN/END----- lines) and press Enter

wrangler secret put GITHUB_APP_INSTALLATION_ID
# paste the Installation ID and press Enter
```

Optional variables can be set the same way:

```bash
wrangler secret put ENTRA_TENANT_ID        # optional tenant lock
wrangler secret put ALLOWED_ORIGIN         # optional origin lock
```

> **Tip:** You can also set these in the Cloudflare dashboard under your
> Worker → **Settings → Variables & Secrets**.

### 4. Create a GitHub App (for token exchange)

> Skip this section if you only need the Device Flow proxy (steps 1–3 above
> are sufficient).

The `/api/token-exchange` endpoint requires a **GitHub App** so the worker
can mint short-lived installation access tokens.

1. Go to **[GitHub → Settings → Developer settings → GitHub Apps → New
   GitHub App](https://github.com/settings/apps/new)**.

2. Fill in the required fields:

   | Field | Value |
   |-------|-------|
   | **GitHub App name** | e.g. `AmpCloud Deploy` |
   | **Homepage URL** | Your GitHub Pages URL or repository URL |
   | **Webhook** | Uncheck **Active** (no webhook needed) |

3. Under **Repository permissions**, grant:

   | Permission | Access |
   |------------|--------|
   | **Contents** | Read & write |

   No other permissions are needed.

4. Click **Create GitHub App**.

5. On the app's settings page, note the **App ID** (a numeric value shown
   at the top of the General tab).

6. Scroll to **Private keys** and click **Generate a private key**.  Your
   browser downloads a `.pem` file.

   The downloaded key can be used directly — the worker accepts both
   PKCS#1 (`BEGIN RSA PRIVATE KEY`, GitHub's default) and PKCS#8
   (`BEGIN PRIVATE KEY`) formats.

7. Install the app on your repository:

   - Go to the app's settings → **Install App** (left sidebar).
   - Select your account and choose **Only select repositories** → pick
     your AmpCloud fork.
   - After installation, the URL will contain the **Installation ID**
     (the number at the end of the URL, e.g.
     `https://github.com/settings/installations/12345678` → `12345678`).

8. Set the three values as Worker secrets (see step 3 above):

   ```bash
   wrangler secret put GITHUB_APP_ID               # e.g. 123456
   wrangler secret put GITHUB_APP_PRIVATE_KEY       # paste contents of .pem file (PKCS#1 or PKCS#8)
   wrangler secret put GITHUB_APP_INSTALLATION_ID   # e.g. 12345678
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

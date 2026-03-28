/**
 * AmpCloud GitHub OAuth CORS Proxy — Cloudflare Worker
 *
 * This worker proxies GitHub's OAuth Device Flow endpoints and adds CORS
 * headers so the browser-hosted AmpCloud Editor can use them.
 *
 * It also provides an Entra ID → GitHub token exchange endpoint so that
 * the AmpCloud engine and Monitoring dashboard can reuse the Entra ID
 * token obtained during sign-in instead of requiring a separate GitHub
 * Personal Access Token.
 *
 * Allowed endpoints (everything else returns 404):
 *   POST /login/device/code          → GitHub Device Flow (public, no secret)
 *   POST /login/oauth/access_token   → GitHub Device Flow token poll
 *   POST /api/token-exchange          → Entra ID → GitHub installation token
 *
 * Environment variables (Cloudflare dashboard → Settings → Variables):
 *   ALLOWED_ORIGIN              – (optional) Lock to a single origin.
 *   GITHUB_APP_ID               – (required for /api/token-exchange)
 *   GITHUB_APP_PRIVATE_KEY      – (required for /api/token-exchange) PEM key
 *                                  (PKCS#1 or PKCS#8).
 *   GITHUB_APP_INSTALLATION_ID  – (required for /api/token-exchange)
 *   ENTRA_TENANT_ID             – (optional) Restrict accepted Entra tokens
 *                                  to a specific tenant.
 */

const ROUTE_MAP = {
    '/login/device/code': 'https://github.com/login/device/code',
    '/login/oauth/access_token': 'https://github.com/login/oauth/access_token'
};

/**
 * Build CORS headers for the response.
 *
 * If ALLOWED_ORIGIN is configured the request origin must match it exactly;
 * otherwise the request Origin header is reflected back.  Reflecting the
 * origin is safe here because the proxy only forwards public Device Flow
 * data (client_id + device_code) — no secrets are involved.
 */
function corsHeaders(request, env) {
    const requestOrigin = (request && request.headers && request.headers.get('Origin')) || '';
    const allowedOrigin = (env && env.ALLOWED_ORIGIN) || '';

    /* When ALLOWED_ORIGIN is configured, validate the request origin.
       If it doesn't match, still return the configured origin so the
       browser receives a clear CORS rejection instead of a missing header. */
    let origin;
    if (allowedOrigin) {
        origin = allowedOrigin;
    } else if (requestOrigin) {
        origin = requestOrigin;
    } else {
        origin = '*';
    }

    return {
        'Access-Control-Allow-Origin': origin,
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Accept, Authorization',
        'Access-Control-Max-Age': '86400',
        'Vary': 'Origin'
    };
}

/* ── Entra ID → GitHub token exchange ────────────────────────────────
 *
 * 1. Caller sends their Entra ID access token in the Authorization header.
 * 2. We validate it by calling Microsoft Graph /me (if it returns 200 the
 *    token is genuine and the caller is authenticated).
 * 3. If ENTRA_TENANT_ID is set we also verify the token's tid claim.
 * 4. We create a short-lived GitHub App installation access token scoped
 *    to contents:write — sufficient for pushing deployment reports.
 * 5. Return the installation token to the caller.
 *
 * This lets the AmpCloud engine and dashboard reuse the Entra ID token
 * they already have from sign-in, eliminating the need for a separate
 * GitHub Personal Access Token ($env:GITHUB_TOKEN).
 * ──────────────────────────────────────────────────────────────────── */

/**
 * Wrap a PKCS#1 (RSA PRIVATE KEY) DER buffer in a PKCS#8 envelope so
 * it can be imported via crypto.subtle.importKey('pkcs8', …).
 *
 * PKCS#8 structure:
 *   SEQUENCE {
 *     INTEGER 0,                                    -- version
 *     SEQUENCE { OID 1.2.840.113549.1.1.1, NULL },  -- rsaEncryption
 *     OCTET STRING { <pkcs1 bytes> }
 *   }
 */
function wrapPkcs1InPkcs8(pkcs1Buf) {
    const pkcs1 = new Uint8Array(pkcs1Buf);
    const pkcs1Len = pkcs1.length;
    /* Fixed parts: version (3) + AlgorithmIdentifier (15) + OCTET STRING tag+len (4) */
    const innerLen = 22 + pkcs1Len;
    if (innerLen > 0xFFFF) {
        throw new Error('Private key too large for PKCS#8 wrapping');
    }
    const pkcs8 = new Uint8Array(4 + innerLen);
    let o = 0;
    /* outer SEQUENCE */
    pkcs8[o++] = 0x30; pkcs8[o++] = 0x82;
    pkcs8[o++] = (innerLen >> 8) & 0xFF; pkcs8[o++] = innerLen & 0xFF;
    /* version INTEGER 0 */
    pkcs8[o++] = 0x02; pkcs8[o++] = 0x01; pkcs8[o++] = 0x00;
    /* AlgorithmIdentifier SEQUENCE */
    pkcs8[o++] = 0x30; pkcs8[o++] = 0x0D;
    pkcs8[o++] = 0x06; pkcs8[o++] = 0x09;
    /* OID 1.2.840.113549.1.1.1 (rsaEncryption) */
    pkcs8[o++] = 0x2A; pkcs8[o++] = 0x86; pkcs8[o++] = 0x48; pkcs8[o++] = 0x86;
    pkcs8[o++] = 0xF7; pkcs8[o++] = 0x0D; pkcs8[o++] = 0x01; pkcs8[o++] = 0x01;
    pkcs8[o++] = 0x01;
    pkcs8[o++] = 0x05; pkcs8[o++] = 0x00; /* NULL */
    /* OCTET STRING containing PKCS#1 key */
    pkcs8[o++] = 0x04; pkcs8[o++] = 0x82;
    pkcs8[o++] = (pkcs1Len >> 8) & 0xFF; pkcs8[o++] = pkcs1Len & 0xFF;
    pkcs8.set(pkcs1, o);
    return pkcs8.buffer;
}

/**
 * Import a PEM-encoded RSA private key for signing JWTs.
 *
 * Accepts both PKCS#8 (BEGIN PRIVATE KEY) and PKCS#1
 * (BEGIN RSA PRIVATE KEY) formats.  GitHub generates PKCS#1 keys by
 * default, so we auto-wrap them in a PKCS#8 envelope for Web Crypto.
 *
 * Also normalises literal "\n" sequences that are common when PEM keys
 * are pasted into secret-manager UIs or environment variables.
 */
async function importPrivateKey(pem) {
    /* Normalise literal \n that secret managers sometimes introduce */
    const normalised = pem.replace(/\\n/g, '\n');
    const isPkcs1 = normalised.includes('BEGIN RSA PRIVATE KEY');

    const pemContents = normalised
        .replace(/-----BEGIN RSA PRIVATE KEY-----/, '')
        .replace(/-----END RSA PRIVATE KEY-----/, '')
        .replace(/-----BEGIN PRIVATE KEY-----/, '')
        .replace(/-----END PRIVATE KEY-----/, '')
        .replace(/\s/g, '');
    const binaryDer = Uint8Array.from(atob(pemContents), c => c.charCodeAt(0));

    if (isPkcs1) {
        /* GitHub-generated PKCS#1 key — wrap in PKCS#8 for Web Crypto */
        return await crypto.subtle.importKey(
            'pkcs8', wrapPkcs1InPkcs8(binaryDer.buffer),
            { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
            false, ['sign']
        );
    }

    /* PKCS#8 key — import directly */
    return await crypto.subtle.importKey(
        'pkcs8', binaryDer.buffer,
        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
        false, ['sign']
    );
}

/**
 * Create a GitHub App JWT (valid for up to 10 minutes).
 */
async function createGitHubAppJwt(appId, privateKeyPem) {
    const now = Math.floor(Date.now() / 1000);
    const header = { alg: 'RS256', typ: 'JWT' };
    const payload = { iat: now - 60, exp: now + (10 * 60), iss: appId }; /* iat backdated 60 s for clock skew per GitHub docs */

    const enc = new TextEncoder();
    const b64url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    const strB64 = (obj) => btoa(JSON.stringify(obj))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

    const signingInput = strB64(header) + '.' + strB64(payload);
    const key = await importPrivateKey(privateKeyPem);
    const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, enc.encode(signingInput));

    return signingInput + '.' + b64url(sig);
}

/**
 * Exchange an Entra ID token for a scoped GitHub installation access token.
 */
async function handleTokenExchange(request, env, cors) {
    /* ── Verify required secrets are configured ────────────────────── */
    if (!env.GITHUB_APP_ID || !env.GITHUB_APP_PRIVATE_KEY || !env.GITHUB_APP_INSTALLATION_ID) {
        return new Response(JSON.stringify({
            error: 'proxy_not_configured',
            error_description: 'Token exchange is not configured. Set GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, and GITHUB_APP_INSTALLATION_ID.'
        }), { status: 501, headers: { ...cors, 'Content-Type': 'application/json' } });
    }

    /* ── Extract Entra token from Authorization header ─────────────── */
    const authHeader = request.headers.get('Authorization') || '';
    const entraToken = authHeader.replace(/^Bearer\s+/i, '').trim();
    if (!entraToken) {
        return new Response(JSON.stringify({
            error: 'missing_token',
            error_description: 'Provide an Entra ID access token in the Authorization header.'
        }), { status: 401, headers: { ...cors, 'Content-Type': 'application/json' } });
    }

    /* ── Validate the Entra token by calling Microsoft Graph /me ──── */
    let graphUser;
    try {
        const graphResp = await fetch('https://graph.microsoft.com/v1.0/me', {
            headers: { 'Authorization': 'Bearer ' + entraToken }
        });
        if (!graphResp.ok) {
            let graphErr = '';
            try { graphErr = await graphResp.text(); } catch { /* response body unavailable */ }
            return new Response(JSON.stringify({
                error: 'invalid_token',
                error_description: 'Entra ID token validation failed (Graph /me returned HTTP ' +
                    graphResp.status + '). Ensure the token has User.Read scope and is not expired.',
                graph_status: graphResp.status,
                graph_error: graphErr.substring(0, 500)
            }), { status: 401, headers: { ...cors, 'Content-Type': 'application/json' } });
        }
        graphUser = await graphResp.json();
    } catch (e) {
        return new Response(JSON.stringify({
            error: 'token_validation_error',
            error_description: 'Failed to validate Entra token against Microsoft Graph.'
        }), { status: 502, headers: { ...cors, 'Content-Type': 'application/json' } });
    }

    /* ── Optional tenant restriction ──────────────────────────────── */
    if (env.ENTRA_TENANT_ID) {
        /* Decode JWT payload to check tid claim (no signature check needed
           since Graph already validated the token by returning 200). */
        try {
            const parts = entraToken.split('.');
            if (parts.length === 3) {
                const payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')));
                if (payload.tid && payload.tid !== env.ENTRA_TENANT_ID) {
                    return new Response(JSON.stringify({
                        error: 'tenant_mismatch',
                        error_description: 'Entra token tenant does not match the configured tenant.'
                    }), { status: 403, headers: { ...cors, 'Content-Type': 'application/json' } });
                }
            }
        } catch {
            /* JWT structure invalid — Graph already validated the token so
               this is a non-standard token format.  Log and skip tenant check. */
            console.warn('[AmpCloud-OAuth-Proxy] Could not decode Entra JWT for tenant check');
        }
    }

    /* ── Create a GitHub App JWT ──────────────────────────────────── */
    let appJwt;
    try {
        appJwt = await createGitHubAppJwt(env.GITHUB_APP_ID, env.GITHUB_APP_PRIVATE_KEY);
    } catch (e) {
        return new Response(JSON.stringify({
            error: 'jwt_error',
            error_description: 'Failed to create GitHub App JWT: ' + e.message
        }), { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } });
    }

    /* ── Create a scoped installation access token ───────────────── */
    try {
        const installUrl = `https://api.github.com/app/installations/${env.GITHUB_APP_INSTALLATION_ID}/access_tokens`;
        const installResp = await fetch(installUrl, {
            method: 'POST',
            headers: {
                'Authorization': 'Bearer ' + appJwt,
                'Accept': 'application/vnd.github.v3+json',
                'User-Agent': 'AmpCloud-OAuth-Proxy'
            },
            body: JSON.stringify({
                permissions: { contents: 'write' }
            })
        });

        if (!installResp.ok) {
            const errText = await installResp.text();
            return new Response(JSON.stringify({
                error: 'github_app_error',
                error_description: 'GitHub App installation token request failed: ' + errText
            }), { status: installResp.status, headers: { ...cors, 'Content-Type': 'application/json' } });
        }

        const installData = await installResp.json();
        return new Response(JSON.stringify({
            token: installData.token,
            expires_at: installData.expires_at,
            user: graphUser.displayName || graphUser.userPrincipalName || 'unknown'
        }), {
            status: 200,
            headers: { ...cors, 'Content-Type': 'application/json' }
        });
    } catch (e) {
        return new Response(JSON.stringify({
            error: 'exchange_error',
            error_description: 'Token exchange failed: ' + e.message
        }), { status: 502, headers: { ...cors, 'Content-Type': 'application/json' } });
    }
}

export default {
    async fetch(request, env) {
        /* Build CORS headers early — every response path must include them. */
        let cors;
        try {
            cors = corsHeaders(request, env);
        } catch (e) {
            /* Absolute last resort — if corsHeaders itself throws, build
               minimal CORS headers so the browser still gets a response. */
            console.error('[AmpCloud-OAuth-Proxy] corsHeaders error:', e);
            cors = {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'POST, OPTIONS',
                'Access-Control-Allow-Headers': 'Content-Type, Accept'
            };
        }

        try {
            /* CORS preflight */
            if (request.method === 'OPTIONS') {
                return new Response(null, { status: 204, headers: cors });
            }

            /* ── Server-side origin enforcement ──────────────────────── */
            const allowedOrigin = (env && env.ALLOWED_ORIGIN) || '';
            if (allowedOrigin) {
                const requestOrigin = (request.headers && request.headers.get('Origin')) || '';
                if (requestOrigin !== allowedOrigin) {
                    return new Response(JSON.stringify({
                        error: 'origin_not_allowed',
                        error_description: 'Request origin is not allowed.'
                    }), { status: 403, headers: { ...cors, 'Content-Type': 'application/json' } });
                }
            }

            /* Only POST is accepted */
            if (request.method !== 'POST') {
                return new Response('Method Not Allowed', { status: 405, headers: cors });
            }

            /* Map the request path to a GitHub endpoint */
            const url = new URL(request.url);

            /* ── Token exchange endpoint ─────────────────────────────── */
            if (url.pathname === '/api/token-exchange') {
                return handleTokenExchange(request, env, cors);
            }

            const target = ROUTE_MAP[url.pathname];
            if (!target) {
                return new Response('Not Found', { status: 404, headers: cors });
            }

            /* Forward the request to GitHub */
            const body = await request.text();
            const ghResponse = await fetch(target, {
                method: 'POST',
                headers: {
                    'Accept': 'application/json',
                    'Content-Type': 'application/x-www-form-urlencoded',
                    'User-Agent': 'AmpCloud-OAuth-Proxy'
                },
                body: body
            });

            /* Return GitHub's response with CORS headers */
            const data = await ghResponse.text();
            return new Response(data, {
                status: ghResponse.status,
                headers: {
                    ...cors,
                    'Content-Type': 'application/json'
                }
            });
        } catch (err) {
            return new Response(JSON.stringify({ error: 'proxy_error', error_description: 'Failed to reach GitHub. Please try again.' }), {
                status: 502,
                headers: { ...cors, 'Content-Type': 'application/json' }
            });
        }
    }
};

/**
 * AmpCloud GitHub OAuth CORS Proxy — Cloudflare Worker
 *
 * This worker proxies GitHub's OAuth Device Flow endpoints and adds CORS
 * headers so the browser-hosted AmpCloud Editor can use them.
 *
 * Device Flow does NOT require a client_secret — only the public client_id
 * and device_code travel through the proxy.  No secrets are stored here.
 *
 * Allowed endpoints (everything else returns 404):
 *   POST /login/device/code          → https://github.com/login/device/code
 *   POST /login/oauth/access_token   → https://github.com/login/oauth/access_token
 *
 * Environment variable (set in Cloudflare dashboard → Settings → Variables):
 *   ALLOWED_ORIGIN  – (optional) Lock the proxy to a single origin,
 *                     e.g. "https://araduti.github.io".
 *                     When set, only that origin is allowed.
 *                     When omitted, the request's Origin header is reflected
 *                     back (safe because Device Flow carries no secrets).
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
        'Access-Control-Allow-Headers': 'Content-Type, Accept',
        'Access-Control-Max-Age': '86400',
        'Vary': 'Origin'
    };
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

            /* Only POST is accepted */
            if (request.method !== 'POST') {
                return new Response('Method Not Allowed', { status: 405, headers: cors });
            }

            /* Map the request path to a GitHub endpoint */
            const url = new URL(request.url);
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

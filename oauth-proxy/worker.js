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
 *   ALLOWED_ORIGIN  – (required) The origin of your GitHub Pages site,
 *                     e.g. "https://araduti.github.io"
 */

const ROUTE_MAP = {
    '/login/device/code': 'https://github.com/login/device/code',
    '/login/oauth/access_token': 'https://github.com/login/oauth/access_token'
};

export default {
    async fetch(request, env) {
        const origin = env.ALLOWED_ORIGIN;
        if (!origin) {
            return new Response('ALLOWED_ORIGIN environment variable is not configured.', { status: 500 });
        }
        const corsHeaders = {
            'Access-Control-Allow-Origin': origin,
            'Access-Control-Allow-Methods': 'POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, Accept'
        };

        /* CORS preflight */
        if (request.method === 'OPTIONS') {
            return new Response(null, { status: 204, headers: corsHeaders });
        }

        /* Only POST is accepted */
        if (request.method !== 'POST') {
            return new Response('Method Not Allowed', { status: 405, headers: corsHeaders });
        }

        /* Map the request path to a GitHub endpoint */
        const url = new URL(request.url);
        const target = ROUTE_MAP[url.pathname];
        if (!target) {
            return new Response('Not Found', { status: 404, headers: corsHeaders });
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
                ...corsHeaders,
                'Content-Type': 'application/json'
            }
        });
    }
};

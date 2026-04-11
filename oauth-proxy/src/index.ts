/**
 * Nova GitHub OAuth CORS Proxy — Cloudflare Worker
 *
 * This worker proxies GitHub's OAuth Device Flow endpoints and adds CORS
 * headers so the browser-hosted Nova Editor can use them.
 *
 * It also provides an Entra ID → GitHub token exchange endpoint so that
 * the Nova engine and Monitoring dashboard can reuse the Entra ID
 * token obtained during sign-in instead of requiring a separate GitHub
 * Personal Access Token.
 *
 * Allowed endpoints (everything else returns 404):
 *   POST /login/device/code          → GitHub Device Flow (public, no secret)
 *   POST /login/oauth/access_token   → GitHub Device Flow token poll
 *   POST /api/token-exchange          → Entra ID → GitHub installation token
 *   GET  /api/config/:key            → Read config from KV (Entra-authenticated)
 *   PUT  /api/config/:key            → Write config to KV (Entra-authenticated)
 *
 * Security:
 *   - IP-based rate limiting (60 req/min per IP, sliding window)
 *   - Optional origin locking via ALLOWED_ORIGIN
 *   - CORS preflight handling
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

import { corsHeaders, FALLBACK_CORS } from './cors';
import { handleConfigStore } from './handlers/config-store';
import { handleDeviceFlow } from './handlers/device-flow';
import { handleTokenExchange } from './handlers/token-exchange';
import { RateLimiter, DEFAULT_RATE_LIMIT, rateLimitHeaders } from './rate-limit';
import type { Env } from './types';

/** Single rate-limiter instance shared across requests in this isolate. */
const limiter = new RateLimiter();

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    /* Build CORS headers early — every response path must include them. */
    let cors: Record<string, string>;
    try {
      cors = corsHeaders(request, env);
    } catch (e) {
      /* Absolute last resort — if corsHeaders itself throws, build
         minimal CORS headers so the browser still gets a response. */
      console.error('[Nova-OAuth-Proxy] corsHeaders error:', e);
      cors = FALLBACK_CORS;
    }

    try {
      /* CORS preflight — exempt from rate limiting */
      if (request.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: cors });
      }

      /* ── IP-based rate limiting ──────────────────────────────── */
      const clientIp = request.headers.get('CF-Connecting-IP') ?? 'unknown';
      const rl = limiter.check(clientIp);
      const rlHeaders = rateLimitHeaders(rl.remaining, DEFAULT_RATE_LIMIT, rl.retryAfter);

      if (!rl.allowed) {
        return new Response(
          JSON.stringify({
            error: 'rate_limit_exceeded',
            error_description: 'Too many requests. Please try again later.',
          }),
          { status: 429, headers: { ...cors, ...rlHeaders, 'Content-Type': 'application/json' } },
        );
      }

      /* ── Server-side origin enforcement ──────────────────────── */
      const allowedOrigin = env.ALLOWED_ORIGIN ?? '';
      if (allowedOrigin) {
        const requestOrigin = request.headers.get('Origin') ?? '';
        if (requestOrigin !== allowedOrigin) {
          return new Response(
            JSON.stringify({
              error: 'origin_not_allowed',
              error_description: 'Request origin is not allowed.',
            }),
            { status: 403, headers: { ...cors, ...rlHeaders, 'Content-Type': 'application/json' } },
          );
        }
      }

      /* ── Config store endpoints (GET/PUT) ────────────────────── */
      const url = new URL(request.url);
      if (url.pathname.startsWith('/api/config/')) {
        if (request.method !== 'GET' && request.method !== 'PUT') {
          return new Response('Method Not Allowed', { status: 405, headers: { ...cors, ...rlHeaders } });
        }
        const configResponse = await handleConfigStore(request, env, { ...cors, ...rlHeaders });
        if (configResponse) return configResponse;
      }

      /* Only POST is accepted for remaining endpoints */
      if (request.method !== 'POST') {
        return new Response('Method Not Allowed', { status: 405, headers: { ...cors, ...rlHeaders } });
      }

      /* ── Token exchange endpoint ─────────────────────────────── */
      if (url.pathname === '/api/token-exchange') {
        return handleTokenExchange(request, env, { ...cors, ...rlHeaders });
      }

      /* ── Device Flow proxy endpoints ─────────────────────────── */
      const deviceFlowResponse = await handleDeviceFlow(request, { ...cors, ...rlHeaders });
      if (deviceFlowResponse) return deviceFlowResponse;

      /* No matching route */
      return new Response('Not Found', { status: 404, headers: { ...cors, ...rlHeaders } });
    } catch {
      return new Response(
        JSON.stringify({
          error: 'proxy_error',
          error_description: 'Failed to reach GitHub. Please try again.',
        }),
        { status: 502, headers: { ...cors, 'Content-Type': 'application/json' } },
      );
    }
  },
} satisfies ExportedHandler<Env>;

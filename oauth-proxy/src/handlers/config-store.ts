import type { CorsHeaders, Env } from '../types';

/**
 * Allowed config keys that can be stored in KV.
 *
 * This whitelist prevents callers from writing arbitrary keys.
 */
const ALLOWED_KEYS = new Set(['assignments', 'alerts']);

/** Maximum config value size in bytes (64 KB). */
const MAX_VALUE_SIZE = 65_536;

/** JSON response helper. */
function jsonResponse(
  body: Record<string, unknown>,
  status: number,
  cors: CorsHeaders,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

/**
 * Validate an Entra ID access token by calling Microsoft Graph /me.
 *
 * Returns the user display name on success, or null on failure.
 */
async function validateEntraToken(
  token: string,
  env: Env,
): Promise<string | null> {
  try {
    const resp = await fetch('https://graph.microsoft.com/v1.0/me', {
      headers: { Authorization: 'Bearer ' + token },
    });
    if (!resp.ok) return null;

    const user = (await resp.json()) as { displayName?: string; userPrincipalName?: string };

    /* Optional tenant restriction */
    if (env.ENTRA_TENANT_ID) {
      const parts = token.split('.');
      if (parts.length === 3) {
        const payloadB64 = parts[1]!.replace(/-/g, '+').replace(/_/g, '/');
        try {
          const payload = JSON.parse(atob(payloadB64)) as { tid?: string };
          if (payload.tid && payload.tid !== env.ENTRA_TENANT_ID) {
            return null;
          }
        } catch {
          /* Cannot decode — Graph validated the token, skip tenant check. */
        }
      }
    }

    return user.displayName ?? user.userPrincipalName ?? 'authenticated';
  } catch {
    return null;
  }
}

/**
 * Handle GET/PUT requests to /api/config/:key.
 *
 * GET  /api/config/:key — Read a config value (requires valid Entra token).
 * PUT  /api/config/:key — Write a config value (requires valid Entra token).
 *
 * Both methods require an Entra ID bearer token in the Authorization header.
 * The token is validated against Microsoft Graph /me.
 */
export async function handleConfigStore(
  request: Request,
  env: Env,
  cors: CorsHeaders,
): Promise<Response | null> {
  const url = new URL(request.url);
  const match = url.pathname.match(/^\/api\/config\/([a-z]+)$/);
  if (!match) return null;

  const key = match[1]!;

  if (!ALLOWED_KEYS.has(key)) {
    return jsonResponse(
      { error: 'invalid_key', error_description: `Config key '${key}' is not allowed.` },
      400,
      cors,
    );
  }

  /* ── Verify KV namespace is configured ───────────────────────── */
  if (!env.NOVA_CONFIG) {
    return jsonResponse(
      {
        error: 'kv_not_configured',
        error_description: 'NOVA_CONFIG KV namespace is not bound. See wrangler.toml.',
      },
      501,
      cors,
    );
  }

  /* ── Authenticate via Entra token ────────────────────────────── */
  const authHeader = request.headers.get('Authorization') ?? '';
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!token) {
    return jsonResponse(
      { error: 'missing_token', error_description: 'Provide an Entra ID token in the Authorization header.' },
      401,
      cors,
    );
  }

  const user = await validateEntraToken(token, env);
  if (!user) {
    return jsonResponse(
      { error: 'invalid_token', error_description: 'Entra ID token validation failed.' },
      401,
      cors,
    );
  }

  /* ── GET — read config value ─────────────────────────────────── */
  if (request.method === 'GET') {
    const value = await env.NOVA_CONFIG.get(key, 'text');
    if (value === null) {
      return jsonResponse({ key, value: null }, 200, cors);
    }
    try {
      return jsonResponse({ key, value: JSON.parse(value) }, 200, cors);
    } catch {
      return jsonResponse({ key, value }, 200, cors);
    }
  }

  /* ── PUT — write config value ────────────────────────────────── */
  if (request.method === 'PUT') {
    let body: string;
    try {
      body = await request.text();
    } catch {
      return jsonResponse(
        { error: 'invalid_body', error_description: 'Could not read request body.' },
        400,
        cors,
      );
    }

    if (body.length > MAX_VALUE_SIZE) {
      return jsonResponse(
        { error: 'payload_too_large', error_description: `Config value exceeds ${MAX_VALUE_SIZE} bytes.` },
        413,
        cors,
      );
    }

    /* Validate JSON */
    try {
      JSON.parse(body);
    } catch {
      return jsonResponse(
        { error: 'invalid_json', error_description: 'Request body must be valid JSON.' },
        400,
        cors,
      );
    }

    await env.NOVA_CONFIG.put(key, body);
    return jsonResponse({ key, saved: true, user }, 200, cors);
  }

  return jsonResponse(
    { error: 'method_not_allowed', error_description: 'Use GET or PUT.' },
    405,
    cors,
  );
}

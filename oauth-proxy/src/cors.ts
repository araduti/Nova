import type { CorsHeaders, Env } from './types';

/**
 * Build CORS headers for the response.
 *
 * If `ALLOWED_ORIGIN` is configured the request origin must match it
 * exactly; otherwise the request Origin header is reflected back.
 * Reflecting the origin is safe here because the proxy only forwards
 * public Device Flow data (client_id + device_code) — no secrets
 * are involved.
 */
export function corsHeaders(request: Request, env: Env): CorsHeaders {
  const requestOrigin = request.headers.get('Origin') ?? '';
  const allowedOrigin = env.ALLOWED_ORIGIN ?? '';

  /* When ALLOWED_ORIGIN is configured, validate the request origin.
     If it doesn't match, still return the configured origin so the
     browser receives a clear CORS rejection instead of a missing header. */
  let origin: string;
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
    Vary: 'Origin',
  };
}

/** Minimal fallback CORS headers if `corsHeaders()` itself throws. */
export const FALLBACK_CORS: CorsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept',
};

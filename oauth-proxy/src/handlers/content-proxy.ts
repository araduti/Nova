/**
 * Content proxy handler for serving private GitHub repo content.
 *
 * Endpoint: GET /api/repo/{path}
 *
 * Authenticates the caller via an Entra ID bearer token, then fetches
 * the requested file from the private GitHub repository using a
 * server-side GitHub App installation token (contents:read).
 *
 * Security:
 *   - Entra ID authentication required (validated via Microsoft Graph)
 *   - Path whitelist: only allowed prefixes and file extensions
 *   - SSRF protection: constructed URL hostname verified
 *   - Response size limit: 5 MB (boot images use GitHub Releases)
 *   - Branch hardcoded to configured value (default: main)
 *   - Response streamed (not buffered) for memory efficiency
 */

import { validateEntraToken } from '../auth';
import { getInstallationToken } from '../github-token';
import type { CorsHeaders, Env } from '../types';

/** Maximum response size in bytes (5 MB). */
const MAX_RESPONSE_BYTES = 5 * 1024 * 1024;

/**
 * Allowed file extensions -- whitelist based on actual repo contents.
 * Binary executables intentionally excluded; serve via GitHub Releases.
 */
const ALLOWED_EXTENSIONS = new Set([
  '.ps1',
  '.psm1',
  '.psd1',
  '.json',
  '.xml',
  '.html',
  '.css',
  '.js',
  '.png',
  '.cfg',
]);

/**
 * Allowed path prefixes -- every proxied path must start with one.
 * Derived from the Nova repository structure.
 */
const ALLOWED_PREFIXES = [
  'src/scripts/',
  'src/modules/',
  'src/web/',
  'config/',
  'resources/',
];

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

/** Content-Type mapping by extension. */
const CONTENT_TYPES: Record<string, string> = {
  '.ps1': 'text/plain; charset=utf-8',
  '.psm1': 'text/plain; charset=utf-8',
  '.psd1': 'text/plain; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.png': 'image/png',
  '.cfg': 'text/plain; charset=utf-8',
};

/**
 * Validate and normalize a repo-relative path.
 *
 * Returns the normalized path or null if the path is invalid,
 * contains traversal sequences, or is not in the whitelist.
 */
export function validateRepoPath(rawPath: string): string | null {
  // 1. URL-decode to prevent double-encoding bypasses
  let path: string;
  try {
    path = decodeURIComponent(rawPath);
  } catch {
    return null;
  }

  // 2. Reject null bytes, newlines, carriage returns, backslashes
  if (/[\x00\r\n\\]/.test(path)) return null;

  // 3. Split on / and reject traversal segments or empty segments
  const segments = path.split('/');
  if (segments.some((s) => s === '..' || s === '.' || s === '')) return null;

  // 4. Reconstruct normalized path
  const normalized = segments.join('/');

  // 5. Check prefix whitelist
  const prefixOk = ALLOWED_PREFIXES.some((p) => normalized.startsWith(p));
  if (!prefixOk) return null;

  // 6. Check extension whitelist
  const lastDot = normalized.lastIndexOf('.');
  if (lastDot === -1) return null;
  const ext = normalized.substring(lastDot).toLowerCase();
  if (!ALLOWED_EXTENSIONS.has(ext)) return null;

  return normalized;
}

/**
 * Build the upstream GitHub raw content URL and verify the hostname.
 *
 * @throws If the constructed URL has an unexpected hostname (SSRF guard).
 */
function buildUpstreamUrl(owner: string, repo: string, branch: string, path: string): string {
  const url = `https://raw.githubusercontent.com/${owner}/${repo}/${branch}/${path}`;
  const parsed = new URL(url);
  if (parsed.hostname !== 'raw.githubusercontent.com') {
    throw new Error('SSRF: constructed URL escapes allowed host');
  }
  return parsed.toString();
}

/**
 * Handle GET /api/repo/{path}.
 *
 * Authenticates the caller via Entra ID, then streams the requested
 * file from the private GitHub repo.
 *
 * @returns Response with the file content, or an error response.
 *          Returns null if the URL path does not match /api/repo/.
 */
export async function handleContentProxy(
  request: Request,
  env: Env,
  cors: CorsHeaders,
): Promise<Response | null> {
  const url = new URL(request.url);

  /* ── Route matching ──────────────────────────────────────────── */
  const prefix = '/api/repo/';
  if (!url.pathname.startsWith(prefix)) return null;

  const rawPath = url.pathname.substring(prefix.length);
  if (!rawPath) {
    return jsonResponse(
      { error: 'missing_path', error_description: 'Provide a file path after /api/repo/.' },
      400,
      cors,
    );
  }

  /* ── Path validation ─────────────────────────────────────────── */
  const validPath = validateRepoPath(rawPath);
  if (!validPath) {
    return jsonResponse(
      { error: 'invalid_path', error_description: 'The requested path is not allowed.' },
      400,
      cors,
    );
  }

  /* ── Entra authentication ────────────────────────────────────── */
  const authHeader = request.headers.get('Authorization') ?? '';
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!token) {
    return jsonResponse(
      { error: 'missing_token', error_description: 'Provide an Entra ID token in the Authorization header.' },
      401,
      cors,
    );
  }

  const validation = await validateEntraToken(token, env);
  if (!validation.valid) {
    return jsonResponse(
      { error: 'invalid_token', error_description: 'Entra ID token validation failed.' },
      401,
      cors,
    );
  }

  /* ── GitHub App secrets check ────────────────────────────────── */
  if (!env.GITHUB_APP_ID || !env.GITHUB_APP_PRIVATE_KEY || !env.GITHUB_APP_INSTALLATION_ID) {
    return jsonResponse(
      {
        error: 'proxy_not_configured',
        error_description:
          'Content proxy is not configured. Set GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, and GITHUB_APP_INSTALLATION_ID.',
      },
      501,
      cors,
    );
  }

  /* ── Resolve repo coordinates from env ───────────────────────── */
  const owner = env.GITHUB_OWNER ?? 'araduti';
  const repo = env.GITHUB_REPO ?? 'Nova';
  const branch = env.GITHUB_BRANCH ?? 'main';

  /* ── Build upstream URL (with SSRF guard) ────────────────────── */
  let upstreamUrl: string;
  try {
    upstreamUrl = buildUpstreamUrl(owner, repo, branch, validPath);
  } catch {
    return jsonResponse(
      { error: 'internal_error', error_description: 'Failed to construct upstream URL.' },
      500,
      cors,
    );
  }

  /* ── Fetch from GitHub using server-side installation token ──── */
  let ghToken: string;
  try {
    ghToken = await getInstallationToken(env);
  } catch (e) {
    return jsonResponse(
      { error: 'token_error', error_description: 'Failed to obtain GitHub token: ' + (e as Error).message },
      502,
      cors,
    );
  }

  let upstream: Response;
  try {
    upstream = await fetch(upstreamUrl, {
      headers: {
        Authorization: 'token ' + ghToken,
        'User-Agent': 'Nova-Content-Proxy',
      },
    });
  } catch {
    return jsonResponse(
      { error: 'upstream_error', error_description: 'Failed to fetch content from GitHub.' },
      502,
      cors,
    );
  }

  if (!upstream.ok) {
    return jsonResponse(
      { error: 'not_found', error_description: `File not found or inaccessible (HTTP ${upstream.status}).` },
      upstream.status === 404 ? 404 : 502,
      cors,
    );
  }

  /* ── Response size guard ─────────────────────────────────────── */
  const contentLength = upstream.headers.get('Content-Length');
  if (contentLength && parseInt(contentLength, 10) > MAX_RESPONSE_BYTES) {
    return jsonResponse(
      {
        error: 'response_too_large',
        error_description: 'Requested file exceeds the 5 MB proxy limit. Use GitHub Releases for large assets.',
      },
      413,
      cors,
    );
  }

  /* ── Determine Content-Type ──────────────────────────────────── */
  const lastDot = validPath.lastIndexOf('.');
  const ext = lastDot >= 0 ? validPath.substring(lastDot).toLowerCase() : '';
  const contentType = CONTENT_TYPES[ext] ?? 'application/octet-stream';

  /* ── Stream the response back (no buffering) ─────────────────── */
  const responseHeaders: Record<string, string> = {
    ...cors,
    'Content-Type': contentType,
    'X-Content-Type-Options': 'nosniff',
    'Cache-Control': 'no-store',
  };

  if (contentLength) {
    responseHeaders['Content-Length'] = contentLength;
  }

  return new Response(upstream.body, {
    status: 200,
    headers: responseHeaders,
  });
}

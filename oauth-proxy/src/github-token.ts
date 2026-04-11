/**
 * Server-side GitHub App installation token management.
 *
 * Caches a read-only (`contents:read`) installation token in memory
 * with a 55-minute TTL (GitHub tokens expire after 1 hour).  This
 * avoids creating a new token per proxied request and keeps the
 * GitHub App rate budget healthy.
 *
 * The token stays server-side -- it is never returned to clients.
 * Clients of the content proxy authenticate via Entra ID; the Worker
 * uses this cached token to fetch from the private GitHub repo on
 * their behalf.
 */

import { createGitHubAppJwt } from './crypto';
import type { Env, InstallationToken } from './types';

/** In-memory cache entry. */
interface CachedToken {
  token: string;
  expiresAt: number; // Unix ms
}

/** Module-scoped cache (persists for the Worker isolate lifetime). */
let cached: CachedToken | null = null;

/** Safety margin: refresh 5 minutes before expiry. */
const SAFETY_MARGIN_MS = 5 * 60 * 1000;

/**
 * Get a read-only GitHub installation token, creating one if the
 * cache is empty or the cached token is about to expire.
 *
 * @throws If the GitHub App secrets are not configured or the API call fails.
 */
export async function getInstallationToken(env: Env): Promise<string> {
  const now = Date.now();

  if (cached && cached.expiresAt - now > SAFETY_MARGIN_MS) {
    return cached.token;
  }

  if (!env.GITHUB_APP_ID || !env.GITHUB_APP_PRIVATE_KEY || !env.GITHUB_APP_INSTALLATION_ID) {
    throw new Error(
      'GitHub App secrets (GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, GITHUB_APP_INSTALLATION_ID) are not configured.',
    );
  }

  const appJwt = await createGitHubAppJwt(env.GITHUB_APP_ID, env.GITHUB_APP_PRIVATE_KEY);

  const installUrl = `https://api.github.com/app/installations/${env.GITHUB_APP_INSTALLATION_ID}/access_tokens`;
  const resp = await fetch(installUrl, {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + appJwt,
      Accept: 'application/vnd.github.v3+json',
      'User-Agent': 'Nova-OAuth-Proxy',
    },
    body: JSON.stringify({
      permissions: { contents: 'read' },
    }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`GitHub installation token creation failed (HTTP ${resp.status}): ${errText}`);
  }

  const data = (await resp.json()) as InstallationToken;

  cached = {
    token: data.token,
    expiresAt: new Date(data.expires_at).getTime(),
  };

  return data.token;
}

/**
 * Clear the cached token (for testing).
 * @internal
 */
export function _clearTokenCache(): void {
  cached = null;
}

import { validateEntraToken } from '../auth';
import { createGitHubAppJwt } from '../crypto';
import type {
  CorsHeaders,
  Env,
  InstallationToken,
  ProxyError,
  TokenExchangeResult,
} from '../types';

/** JSON response helper. */
function jsonResponse(
  body: ProxyError | TokenExchangeResult,
  status: number,
  cors: CorsHeaders,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

/**
 * Exchange an Entra ID token for a scoped GitHub installation access token.
 *
 * 1. Caller sends their Entra ID access token in the Authorization header.
 * 2. We validate it by calling Microsoft Graph /me (if it returns 200 the
 *    token is genuine and the caller is authenticated).
 * 3. If ENTRA_TENANT_ID is set we also verify the token's `tid` claim.
 * 4. We create a short-lived GitHub App installation access token scoped
 *    to `contents:write` — sufficient for pushing deployment reports.
 * 5. Return the installation token to the caller.
 */
export async function handleTokenExchange(
  request: Request,
  env: Env,
  cors: CorsHeaders,
): Promise<Response> {
  /* ── Verify required secrets are configured ────────────────────── */
  if (!env.GITHUB_APP_ID || !env.GITHUB_APP_PRIVATE_KEY || !env.GITHUB_APP_INSTALLATION_ID) {
    return jsonResponse(
      {
        error: 'proxy_not_configured',
        error_description:
          'Token exchange is not configured. Set GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, and GITHUB_APP_INSTALLATION_ID.',
      },
      501,
      cors,
    );
  }

  /* ── Extract Entra token from Authorization header ─────────────── */
  const authHeader = request.headers.get('Authorization') ?? '';
  const entraToken = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!entraToken) {
    return jsonResponse(
      {
        error: 'missing_token',
        error_description: 'Provide an Entra ID access token in the Authorization header.',
      },
      401,
      cors,
    );
  }

  /* ── Validate the Entra token via shared auth module ──────────── */
  const validation = await validateEntraToken(entraToken, env);
  if (!validation.valid) {
    if (validation.tenantMismatch) {
      return jsonResponse(
        {
          error: 'tenant_mismatch',
          error_description: 'Entra token tenant does not match the configured tenant.',
        },
        403,
        cors,
      );
    }
    if (validation.graphStatus) {
      return jsonResponse(
        {
          error: 'invalid_token',
          error_description:
            'Entra ID token validation failed (Graph /me returned HTTP ' +
            validation.graphStatus +
            '). Ensure the token has User.Read scope and is not expired.',
          graph_status: validation.graphStatus,
          graph_error: validation.graphError,
        },
        401,
        cors,
      );
    }
    return jsonResponse(
      {
        error: 'token_validation_error',
        error_description: 'Failed to validate Entra token against Microsoft Graph.',
      },
      502,
      cors,
    );
  }

  /* ── Create a GitHub App JWT ──────────────────────────────────── */
  let appJwt: string;
  try {
    appJwt = await createGitHubAppJwt(env.GITHUB_APP_ID, env.GITHUB_APP_PRIVATE_KEY);
  } catch (e) {
    return jsonResponse(
      {
        error: 'jwt_error',
        error_description: 'Failed to create GitHub App JWT: ' + (e as Error).message,
      },
      500,
      cors,
    );
  }

  /* ── Create a scoped installation access token ───────────────── */
  try {
    const installUrl = `https://api.github.com/app/installations/${env.GITHUB_APP_INSTALLATION_ID}/access_tokens`;
    const installResp = await fetch(installUrl, {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + appJwt,
        Accept: 'application/vnd.github.v3+json',
        'User-Agent': 'Nova-OAuth-Proxy',
      },
      body: JSON.stringify({
        permissions: { contents: 'write' },
      }),
    });

    if (!installResp.ok) {
      const errText = await installResp.text();
      return jsonResponse(
        {
          error: 'github_app_error',
          error_description: 'GitHub App installation token request failed: ' + errText,
        },
        installResp.status,
        cors,
      );
    }

    const installData = (await installResp.json()) as InstallationToken;
    return jsonResponse(
      {
        token: installData.token,
        expires_at: installData.expires_at,
        user: validation.user ?? 'unknown',
      },
      200,
      cors,
    );
  } catch (e) {
    return jsonResponse(
      {
        error: 'exchange_error',
        error_description: 'Token exchange failed: ' + (e as Error).message,
      },
      502,
      cors,
    );
  }
}

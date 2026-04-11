/**
 * Shared Entra ID token validation.
 *
 * Validates an Entra access token by calling Microsoft Graph /me.
 * Optionally restricts accepted tokens to a specific Azure AD tenant.
 *
 * Used by config-store, token-exchange, and content-proxy handlers.
 */

import type { Env } from './types';

/** Result of validating an Entra ID token. */
export interface EntraValidation {
  /** Whether the token is valid. */
  valid: boolean;
  /** Display name of the authenticated user (if valid). */
  user: string | null;
  /** HTTP status from Graph /me (if validation failed). */
  graphStatus?: number;
  /** Error body from Graph /me (if validation failed, truncated to 500 chars). */
  graphError?: string;
  /** True when the token was valid but the tenant did not match. */
  tenantMismatch?: boolean;
}

/**
 * Validate an Entra ID access token by calling Microsoft Graph /me.
 *
 * If `env.ENTRA_TENANT_ID` is set, also checks the JWT `tid` claim
 * to ensure the token belongs to the expected tenant.
 *
 * @returns Validation result with user display name on success.
 */
export async function validateEntraToken(
  token: string,
  env: Env,
): Promise<EntraValidation> {
  try {
    const resp = await fetch('https://graph.microsoft.com/v1.0/me', {
      headers: { Authorization: 'Bearer ' + token },
    });

    if (!resp.ok) {
      let graphErr = '';
      try {
        graphErr = await resp.text();
      } catch {
        /* response body unavailable */
      }
      return {
        valid: false,
        user: null,
        graphStatus: resp.status,
        graphError: graphErr.substring(0, 500),
      };
    }

    const user = (await resp.json()) as { displayName?: string; userPrincipalName?: string };

    /* Optional tenant restriction */
    if (env.ENTRA_TENANT_ID) {
      const parts = token.split('.');
      if (parts.length === 3) {
        const payloadB64 = parts[1]!.replace(/-/g, '+').replace(/_/g, '/');
        try {
          const payload = JSON.parse(atob(payloadB64)) as { tid?: string };
          if (payload.tid && payload.tid !== env.ENTRA_TENANT_ID) {
            return { valid: false, user: null, tenantMismatch: true };
          }
        } catch {
          /* Cannot decode — Graph validated the token, skip tenant check. */
        }
      }
    }

    const displayName = user.displayName ?? user.userPrincipalName ?? 'authenticated';
    return { valid: true, user: displayName };
  } catch {
    return { valid: false, user: null };
  }
}

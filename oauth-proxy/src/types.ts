/**
 * Environment bindings for the Cloudflare Worker.
 */
export interface Env {
  /** Lock proxy to a single browser origin (optional). */
  ALLOWED_ORIGIN?: string;
  /** GitHub App numeric App ID (required for /api/token-exchange). */
  GITHUB_APP_ID?: string;
  /** GitHub App PEM private key — PKCS#1 or PKCS#8 (required for /api/token-exchange). */
  GITHUB_APP_PRIVATE_KEY?: string;
  /** GitHub App installation ID (required for /api/token-exchange). */
  GITHUB_APP_INSTALLATION_ID?: string;
  /** Restrict accepted Entra tokens to a specific tenant (optional). */
  ENTRA_TENANT_ID?: string;
  /** KV namespace for storing configuration (assignments, alerts, etc.). */
  NOVA_CONFIG?: KVNamespace;
}

/** JSON error body returned by the proxy. */
export interface ProxyError {
  error: string;
  error_description: string;
  graph_status?: number;
  graph_error?: string;
}

/** Successful token-exchange response. */
export interface TokenExchangeResult {
  token: string;
  expires_at: string;
  user: string;
}

/** Microsoft Graph /me response (subset of fields we use). */
export interface GraphUser {
  displayName?: string;
  userPrincipalName?: string;
}

/** GitHub installation access-token response (subset). */
export interface InstallationToken {
  token: string;
  expires_at: string;
}

/** CORS header record. */
export type CorsHeaders = Record<string, string>;

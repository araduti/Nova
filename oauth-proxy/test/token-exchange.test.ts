import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { handleTokenExchange } from '../src/handlers/token-exchange';
import type { CorsHeaders, Env } from '../src/types';

const CORS: CorsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept, Authorization',
};

function fakeRequest(token?: string): Request {
  const headers = new Headers();
  if (token) headers.set('Authorization', `Bearer ${token}`);
  return new Request('https://proxy.example.com/api/token-exchange', {
    method: 'POST',
    headers,
  });
}

describe('handleTokenExchange', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalThis.fetch = vi.fn();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('returns 501 when GitHub App secrets are missing', async () => {
    const env: Env = {};
    const resp = await handleTokenExchange(fakeRequest('some-token'), env, CORS);

    expect(resp.status).toBe(501);
    const body = await resp.json();
    expect(body.error).toBe('proxy_not_configured');
  });

  it('returns 401 when Authorization header is missing', async () => {
    const env: Env = {
      GITHUB_APP_ID: '12345',
      GITHUB_APP_PRIVATE_KEY: 'fake-key',
      GITHUB_APP_INSTALLATION_ID: '67890',
    };
    const resp = await handleTokenExchange(fakeRequest(), env, CORS);

    expect(resp.status).toBe(401);
    const body = await resp.json();
    expect(body.error).toBe('missing_token');
  });

  it('returns 401 when Graph /me rejects the token', async () => {
    const env: Env = {
      GITHUB_APP_ID: '12345',
      GITHUB_APP_PRIVATE_KEY: 'fake-key',
      GITHUB_APP_INSTALLATION_ID: '67890',
    };

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response('{"error":"InvalidAuthenticationToken"}', { status: 401 }),
    );

    const resp = await handleTokenExchange(fakeRequest('bad-token'), env, CORS);

    expect(resp.status).toBe(401);
    const body = await resp.json();
    expect(body.error).toBe('invalid_token');
    expect(body.graph_status).toBe(401);
  });

  it('returns 403 when tenant ID does not match', async () => {
    const env: Env = {
      GITHUB_APP_ID: '12345',
      GITHUB_APP_PRIVATE_KEY: 'fake-key',
      GITHUB_APP_INSTALLATION_ID: '67890',
      ENTRA_TENANT_ID: 'expected-tenant-id',
    };

    /* Build a fake JWT with a different tid */
    const header = btoa(JSON.stringify({ alg: 'none' }));
    const payload = btoa(JSON.stringify({ tid: 'wrong-tenant-id' }));
    const fakeJwt = `${header}.${payload}.sig`;

    /* Graph /me succeeds */
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const resp = await handleTokenExchange(fakeRequest(fakeJwt), env, CORS);

    expect(resp.status).toBe(403);
    const body = await resp.json();
    expect(body.error).toBe('tenant_mismatch');
  });

  it('passes tenant check when tid matches', async () => {
    const env: Env = {
      GITHUB_APP_ID: '12345',
      GITHUB_APP_PRIVATE_KEY: 'fake-key',
      GITHUB_APP_INSTALLATION_ID: '67890',
      ENTRA_TENANT_ID: 'correct-tenant-id',
    };

    /* Build a fake JWT with the correct tid */
    const header = btoa(JSON.stringify({ alg: 'none' }));
    const payload = btoa(JSON.stringify({ tid: 'correct-tenant-id' }));
    const fakeJwt = `${header}.${payload}.sig`;

    /* Graph /me succeeds */
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    /* createGitHubAppJwt will fail because the key is fake — that's fine,
       we just want to verify the tenant check passed (no 403). */
    const resp = await handleTokenExchange(fakeRequest(fakeJwt), env, CORS);

    /* Should NOT be 403 (tenant_mismatch) — it'll be 500 (jwt_error)
       because the fake key can't be imported. */
    expect(resp.status).not.toBe(403);
    const body = await resp.json();
    expect(body.error).not.toBe('tenant_mismatch');
  });

  it('returns 502 when Graph /me fetch throws', async () => {
    const env: Env = {
      GITHUB_APP_ID: '12345',
      GITHUB_APP_PRIVATE_KEY: 'fake-key',
      GITHUB_APP_INSTALLATION_ID: '67890',
    };

    vi.mocked(globalThis.fetch).mockRejectedValueOnce(new Error('network down'));

    const resp = await handleTokenExchange(fakeRequest('some-token'), env, CORS);

    expect(resp.status).toBe(502);
    const body = await resp.json();
    expect(body.error).toBe('token_validation_error');
  });

  it('includes CORS headers in all responses', async () => {
    const env: Env = {};
    const resp = await handleTokenExchange(fakeRequest('some-token'), env, CORS);

    expect(resp.headers.get('Access-Control-Allow-Origin')).toBe('*');
    expect(resp.headers.get('Content-Type')).toBe('application/json');
  });
});

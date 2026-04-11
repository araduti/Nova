import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { validateEntraToken } from '../src/auth';
import type { Env } from '../src/types';

describe('validateEntraToken (shared)', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalThis.fetch = vi.fn();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('returns valid with user name on successful Graph /me', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const result = await validateEntraToken('valid-token', {});
    expect(result.valid).toBe(true);
    expect(result.user).toBe('Test User');
  });

  it('falls back to userPrincipalName when displayName is absent', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ userPrincipalName: 'user@example.com' }), { status: 200 }),
    );

    const result = await validateEntraToken('valid-token', {});
    expect(result.valid).toBe(true);
    expect(result.user).toBe('user@example.com');
  });

  it('returns "authenticated" when both names are absent', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({}), { status: 200 }),
    );

    const result = await validateEntraToken('valid-token', {});
    expect(result.valid).toBe(true);
    expect(result.user).toBe('authenticated');
  });

  it('returns invalid with graphStatus on Graph /me rejection', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response('{"error":"InvalidAuthenticationToken"}', { status: 401 }),
    );

    const result = await validateEntraToken('bad-token', {});
    expect(result.valid).toBe(false);
    expect(result.graphStatus).toBe(401);
    expect(result.graphError).toContain('InvalidAuthenticationToken');
  });

  it('returns invalid on network error', async () => {
    vi.mocked(globalThis.fetch).mockRejectedValueOnce(new Error('network down'));

    const result = await validateEntraToken('any-token', {});
    expect(result.valid).toBe(false);
    expect(result.user).toBeNull();
  });

  it('enforces tenant restriction when ENTRA_TENANT_ID is set', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const header = btoa(JSON.stringify({ alg: 'none' }));
    const payload = btoa(JSON.stringify({ tid: 'wrong-tenant' }));
    const fakeJwt = `${header}.${payload}.sig`;

    const env: Env = { ENTRA_TENANT_ID: 'expected-tenant' };
    const result = await validateEntraToken(fakeJwt, env);
    expect(result.valid).toBe(false);
    expect(result.tenantMismatch).toBe(true);
  });

  it('passes tenant check when tid matches', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const header = btoa(JSON.stringify({ alg: 'none' }));
    const payload = btoa(JSON.stringify({ tid: 'correct-tenant' }));
    const fakeJwt = `${header}.${payload}.sig`;

    const env: Env = { ENTRA_TENANT_ID: 'correct-tenant' };
    const result = await validateEntraToken(fakeJwt, env);
    expect(result.valid).toBe(true);
    expect(result.user).toBe('Test User');
  });

  it('truncates Graph error body to 500 chars', async () => {
    const longError = 'x'.repeat(1000);
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(longError, { status: 500 }),
    );

    const result = await validateEntraToken('any-token', {});
    expect(result.valid).toBe(false);
    expect(result.graphError!.length).toBe(500);
  });
});

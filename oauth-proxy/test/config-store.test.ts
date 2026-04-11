import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { handleConfigStore } from '../src/handlers/config-store';
import type { CorsHeaders, Env } from '../src/types';

const CORS: CorsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept, Authorization',
};

/** Minimal KV mock. */
function mockKV(store: Record<string, string> = {}): KVNamespace {
  return {
    get: vi.fn(async (key: string) => store[key] ?? null),
    put: vi.fn(async (key: string, value: string) => {
      store[key] = value;
    }),
    delete: vi.fn(),
    list: vi.fn(),
    getWithMetadata: vi.fn(),
  } as unknown as KVNamespace;
}

function fakeRequest(
  path: string,
  opts: { method?: string; token?: string; body?: string } = {},
): Request {
  const headers = new Headers();
  if (opts.token) headers.set('Authorization', `Bearer ${opts.token}`);
  if (opts.body) headers.set('Content-Type', 'application/json');
  const init: RequestInit = {
    method: opts.method ?? 'GET',
    headers,
  };
  if (opts.body) init.body = opts.body;
  return new Request(`https://proxy.example.com${path}`, init);
}

/** Build a fake Entra JWT token. */
function fakeEntraToken(tid?: string): string {
  const header = btoa(JSON.stringify({ alg: 'none' }));
  const payload = btoa(JSON.stringify({ tid: tid ?? 'test-tenant' }));
  return `${header}.${payload}.sig`;
}

describe('handleConfigStore', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalThis.fetch = vi.fn();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('returns null for non-matching paths', async () => {
    const env: Env = { NOVA_CONFIG: mockKV() };
    const resp = await handleConfigStore(
      fakeRequest('/api/other-path', { token: 'tok' }),
      env,
      CORS,
    );
    expect(resp).toBeNull();
  });

  it('returns 400 for disallowed keys', async () => {
    const env: Env = { NOVA_CONFIG: mockKV() };

    /* Mock Graph /me to succeed */
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const resp = await handleConfigStore(
      fakeRequest('/api/config/secrets', { token: fakeEntraToken() }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(400);
    const body = await resp!.json();
    expect(body.error).toBe('invalid_key');
  });

  it('returns 501 when KV is not configured', async () => {
    const env: Env = {};

    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments', { token: fakeEntraToken() }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(501);
    const body = await resp!.json();
    expect(body.error).toBe('kv_not_configured');
  });

  it('returns 401 when no Authorization header', async () => {
    const env: Env = { NOVA_CONFIG: mockKV() };
    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments'),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(401);
    const body = await resp!.json();
    expect(body.error).toBe('missing_token');
  });

  it('returns 401 when Entra token is invalid', async () => {
    const env: Env = { NOVA_CONFIG: mockKV() };

    /* Graph /me rejects the token */
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response('Unauthorized', { status: 401 }),
    );

    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments', { token: 'bad-token' }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(401);
    const body = await resp!.json();
    expect(body.error).toBe('invalid_token');
  });

  it('GET returns null value for missing key', async () => {
    const env: Env = { NOVA_CONFIG: mockKV() };

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments', { token: fakeEntraToken() }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(200);
    const body = await resp!.json();
    expect(body.key).toBe('assignments');
    expect(body.value).toBeNull();
  });

  it('GET returns stored JSON value', async () => {
    const stored = JSON.stringify({ schemaVersion: '1.0', assignments: [{ target: 'abc-123', taskSequence: 'default.json' }] });
    const env: Env = { NOVA_CONFIG: mockKV({ assignments: stored }) };

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments', { token: fakeEntraToken() }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(200);
    const body = await resp!.json();
    expect(body.key).toBe('assignments');
    expect(body.value.assignments).toHaveLength(1);
    expect(body.value.assignments[0].target).toBe('abc-123');
  });

  it('PUT saves valid JSON and returns success', async () => {
    const kv = mockKV();
    const env: Env = { NOVA_CONFIG: kv };

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const payload = JSON.stringify({ schemaVersion: '1.0', assignments: [] });
    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments', { method: 'PUT', token: fakeEntraToken(), body: payload }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(200);
    const body = await resp!.json();
    expect(body.saved).toBe(true);
    expect(body.user).toBe('Test User');
    expect(kv.put).toHaveBeenCalledWith('assignments', payload);
  });

  it('PUT rejects invalid JSON', async () => {
    const env: Env = { NOVA_CONFIG: mockKV() };

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments', { method: 'PUT', token: fakeEntraToken(), body: 'not-json{' }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(400);
    const body = await resp!.json();
    expect(body.error).toBe('invalid_json');
  });

  it('PUT rejects oversized payloads', async () => {
    const env: Env = { NOVA_CONFIG: mockKV() };

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const bigPayload = JSON.stringify({ data: 'x'.repeat(70_000) });
    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments', { method: 'PUT', token: fakeEntraToken(), body: bigPayload }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(413);
    const body = await resp!.json();
    expect(body.error).toBe('payload_too_large');
  });

  it('includes CORS headers in all responses', async () => {
    const env: Env = { NOVA_CONFIG: mockKV() };

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments', { token: fakeEntraToken() }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.headers.get('Access-Control-Allow-Origin')).toBe('*');
  });

  it('enforces tenant restriction', async () => {
    const env: Env = {
      NOVA_CONFIG: mockKV(),
      ENTRA_TENANT_ID: 'expected-tenant',
    };

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const resp = await handleConfigStore(
      fakeRequest('/api/config/assignments', { token: fakeEntraToken('wrong-tenant') }),
      env,
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(401);
  });
});

import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import worker from '../src/index';
import type { Env } from '../src/types';

/** Build a Request with optional origin and method. */
function fakeRequest(
  path: string,
  opts: { method?: string; origin?: string; body?: string } = {},
): Request {
  const headers = new Headers();
  if (opts.origin) headers.set('Origin', opts.origin);
  const init: RequestInit = {
    method: opts.method ?? 'POST',
    headers,
  };
  if (opts.body) init.body = opts.body;
  return new Request(`https://proxy.example.com${path}`, init);
}

describe('worker fetch handler', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalThis.fetch = vi.fn();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('returns 204 for OPTIONS preflight', async () => {
    const resp = await worker.fetch(
      fakeRequest('/', { method: 'OPTIONS', origin: 'https://test.example.com' }),
      {} as Env,
      {} as ExecutionContext,
    );
    expect(resp.status).toBe(204);
    expect(resp.headers.get('Access-Control-Allow-Origin')).toBe('https://test.example.com');
  });

  it('returns 405 for GET requests', async () => {
    const resp = await worker.fetch(
      fakeRequest('/', { method: 'GET' }),
      {} as Env,
      {} as ExecutionContext,
    );
    expect(resp.status).toBe(405);
  });

  it('returns 404 for unknown POST paths', async () => {
    const resp = await worker.fetch(
      fakeRequest('/unknown/path'),
      {} as Env,
      {} as ExecutionContext,
    );
    expect(resp.status).toBe(404);
  });

  it('blocks requests when ALLOWED_ORIGIN is set and origin does not match', async () => {
    const env: Env = { ALLOWED_ORIGIN: 'https://good.example.com' };
    const resp = await worker.fetch(
      fakeRequest('/login/device/code', { origin: 'https://evil.example.com' }),
      env,
      {} as ExecutionContext,
    );

    expect(resp.status).toBe(403);
    const body = await resp.json();
    expect(body.error).toBe('origin_not_allowed');
  });

  it('allows requests when ALLOWED_ORIGIN matches', async () => {
    const env: Env = { ALLOWED_ORIGIN: 'https://good.example.com' };

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response('{"device_code":"abc"}', { status: 200 }),
    );

    const resp = await worker.fetch(
      fakeRequest('/login/device/code', {
        origin: 'https://good.example.com',
        body: 'client_id=test',
      }),
      env,
      {} as ExecutionContext,
    );

    expect(resp.status).toBe(200);
  });

  it('allows requests when no ALLOWED_ORIGIN is configured', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response('{"device_code":"abc"}', { status: 200 }),
    );

    const resp = await worker.fetch(
      fakeRequest('/login/device/code', {
        origin: 'https://any-origin.example.com',
        body: 'client_id=test',
      }),
      {} as Env,
      {} as ExecutionContext,
    );

    expect(resp.status).toBe(200);
  });

  it('returns 502 when upstream fetch fails', async () => {
    vi.mocked(globalThis.fetch).mockRejectedValueOnce(new Error('network error'));

    const resp = await worker.fetch(
      fakeRequest('/login/device/code', { body: 'client_id=test' }),
      {} as Env,
      {} as ExecutionContext,
    );

    expect(resp.status).toBe(502);
    const body = await resp.json();
    expect(body.error).toBe('proxy_error');
  });

  it('includes CORS headers in error responses', async () => {
    const resp = await worker.fetch(
      fakeRequest('/unknown', { origin: 'https://test.example.com' }),
      {} as Env,
      {} as ExecutionContext,
    );

    expect(resp.headers.get('Access-Control-Allow-Origin')).toBe('https://test.example.com');
  });
});

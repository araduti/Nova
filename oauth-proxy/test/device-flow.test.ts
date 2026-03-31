import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { handleDeviceFlow } from '../src/handlers/device-flow';
import type { CorsHeaders } from '../src/types';

const CORS: CorsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept, Authorization',
};

/** Build a minimal POST Request for a given path. */
function fakePost(path: string, body = ''): Request {
  return new Request(`https://proxy.example.com${path}`, {
    method: 'POST',
    body,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  });
}

describe('handleDeviceFlow', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalThis.fetch = vi.fn();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('returns null for unrecognised paths', async () => {
    const result = await handleDeviceFlow(fakePost('/unknown'), CORS);
    expect(result).toBeNull();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it('proxies /login/device/code to GitHub', async () => {
    const ghBody = JSON.stringify({ device_code: 'abc', user_code: '1234-5678' });
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(ghBody, { status: 200 }),
    );

    const resp = await handleDeviceFlow(
      fakePost('/login/device/code', 'client_id=Iv1.test'),
      CORS,
    );

    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(200);
    expect(resp!.headers.get('Access-Control-Allow-Origin')).toBe('*');

    const data = await resp!.json();
    expect(data.device_code).toBe('abc');

    expect(globalThis.fetch).toHaveBeenCalledWith(
      'https://github.com/login/device/code',
      expect.objectContaining({ method: 'POST' }),
    );
  });

  it('proxies /login/oauth/access_token to GitHub', async () => {
    const ghBody = JSON.stringify({ access_token: 'ghu_test123' });
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(ghBody, { status: 200 }),
    );

    const resp = await handleDeviceFlow(
      fakePost('/login/oauth/access_token', 'device_code=abc&grant_type=urn:ietf:params:oauth:grant-type:device_code'),
      CORS,
    );

    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(200);

    const data = await resp!.json();
    expect(data.access_token).toBe('ghu_test123');
  });

  it('forwards GitHub error status codes', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response('{"error":"slow_down"}', { status: 200 }),
    );

    const resp = await handleDeviceFlow(
      fakePost('/login/device/code', 'client_id=Iv1.test'),
      CORS,
    );

    expect(resp).not.toBeNull();
    const data = await resp!.json();
    expect(data.error).toBe('slow_down');
  });
});

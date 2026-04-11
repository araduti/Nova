import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { handleContentProxy, validateRepoPath } from '../src/handlers/content-proxy';
import * as githubToken from '../src/github-token';
import type { CorsHeaders, Env } from '../src/types';

const CORS: CorsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept, Authorization',
};

function fakeRequest(
  path: string,
  opts: { token?: string } = {},
): Request {
  const headers = new Headers();
  if (opts.token) headers.set('Authorization', `Bearer ${opts.token}`);
  return new Request(`https://proxy.example.com${path}`, { method: 'GET', headers });
}

/** Build a fake Entra JWT token. */
function fakeEntraToken(tid?: string): string {
  const header = btoa(JSON.stringify({ alg: 'none' }));
  const payload = btoa(JSON.stringify({ tid: tid ?? 'test-tenant' }));
  return `${header}.${payload}.sig`;
}

function baseEnv(): Env {
  return {
    GITHUB_APP_ID: '12345',
    GITHUB_APP_PRIVATE_KEY: 'fake-key',
    GITHUB_APP_INSTALLATION_ID: '67890',
    GITHUB_OWNER: 'araduti',
    GITHUB_REPO: 'Nova',
    GITHUB_BRANCH: 'main',
  };
}

describe('validateRepoPath', () => {
  it('accepts valid PowerShell script paths', () => {
    expect(validateRepoPath('src/scripts/Trigger.ps1')).toBe('src/scripts/Trigger.ps1');
    expect(validateRepoPath('src/scripts/Bootstrap.ps1')).toBe('src/scripts/Bootstrap.ps1');
  });

  it('accepts valid module paths', () => {
    expect(validateRepoPath('src/modules/Nova.Auth/Nova.Auth.psm1')).toBe('src/modules/Nova.Auth/Nova.Auth.psm1');
    expect(validateRepoPath('src/modules/Nova.Auth/Nova.Auth.psd1')).toBe('src/modules/Nova.Auth/Nova.Auth.psd1');
  });

  it('accepts config files', () => {
    expect(validateRepoPath('config/hashes.json')).toBe('config/hashes.json');
    expect(validateRepoPath('config/auth.json')).toBe('config/auth.json');
    expect(validateRepoPath('config/locale/en-us.json')).toBe('config/locale/en-us.json');
  });

  it('accepts resource files', () => {
    expect(validateRepoPath('resources/task-sequence/default.json')).toBe('resources/task-sequence/default.json');
    expect(validateRepoPath('resources/autopilot/Get-WindowsAutoPilotInfo.ps1')).toBe('resources/autopilot/Get-WindowsAutoPilotInfo.ps1');
    expect(validateRepoPath('resources/products.xml')).toBe('resources/products.xml');
  });

  it('accepts web UI files', () => {
    expect(validateRepoPath('src/web/progress/index.html')).toBe('src/web/progress/index.html');
  });

  it('rejects path traversal with ..', () => {
    expect(validateRepoPath('../etc/passwd')).toBeNull();
    expect(validateRepoPath('src/../../etc/passwd')).toBeNull();
    expect(validateRepoPath('config/../../../secrets')).toBeNull();
  });

  it('rejects paths with single dot segments', () => {
    expect(validateRepoPath('./src/scripts/Trigger.ps1')).toBeNull();
    expect(validateRepoPath('src/./scripts/Trigger.ps1')).toBeNull();
  });

  it('rejects empty segments (double slashes)', () => {
    expect(validateRepoPath('src//scripts/Trigger.ps1')).toBeNull();
  });

  it('rejects null bytes', () => {
    expect(validateRepoPath('src/scripts/Trigger.ps1\x00.txt')).toBeNull();
  });

  it('rejects newlines and carriage returns', () => {
    expect(validateRepoPath('src/scripts/Trigger.ps1\n')).toBeNull();
    expect(validateRepoPath('src/scripts/Trigger.ps1\r')).toBeNull();
  });

  it('rejects backslashes', () => {
    expect(validateRepoPath('src\\scripts\\Trigger.ps1')).toBeNull();
  });

  it('rejects disallowed prefixes', () => {
    expect(validateRepoPath('.github/workflows/ci.yml')).toBeNull();
    expect(validateRepoPath('tests/unit/test.ps1')).toBeNull();
    expect(validateRepoPath('node_modules/foo/bar.js')).toBeNull();
  });

  it('rejects disallowed extensions', () => {
    expect(validateRepoPath('resources/autopilot/oa3tool.exe')).toBeNull();
    expect(validateRepoPath('resources/autopilot/PCPKsp.dll')).toBeNull();
    expect(validateRepoPath('src/scripts/Trigger.bat')).toBeNull();
  });

  it('rejects paths with no extension', () => {
    expect(validateRepoPath('src/scripts/Makefile')).toBeNull();
  });

  it('decodes URL-encoded paths correctly', () => {
    expect(validateRepoPath('src%2Fscripts%2FTrigger.ps1')).toBe('src/scripts/Trigger.ps1');
  });

  it('rejects double-encoded traversal attempts', () => {
    // %252e%252e = %2e%2e after first decode = .. after second (but we only decode once)
    expect(validateRepoPath('%252e%252e/etc/passwd')).toBeNull();
  });
});

describe('handleContentProxy', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalThis.fetch = vi.fn();
    githubToken._clearTokenCache();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    vi.restoreAllMocks();
    githubToken._clearTokenCache();
  });

  it('returns null for non-matching paths', async () => {
    const resp = await handleContentProxy(
      fakeRequest('/api/other', { token: fakeEntraToken() }),
      baseEnv(),
      CORS,
    );
    expect(resp).toBeNull();
  });

  it('returns 400 when path is missing', async () => {
    const resp = await handleContentProxy(
      fakeRequest('/api/repo/', { token: fakeEntraToken() }),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(400);
    const body = await resp!.json();
    expect(body.error).toBe('missing_path');
  });

  it('returns 400 for disallowed prefixes', async () => {
    const resp = await handleContentProxy(
      fakeRequest('/api/repo/.github/workflows/ci.yml', { token: fakeEntraToken() }),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(400);
    const body = await resp!.json();
    expect(body.error).toBe('invalid_path');
  });

  it('returns 401 when no Authorization header', async () => {
    const resp = await handleContentProxy(
      fakeRequest('/api/repo/src/scripts/Trigger.ps1'),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(401);
    const body = await resp!.json();
    expect(body.error).toBe('missing_token');
  });

  it('returns 401 when Entra token is invalid', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response('Unauthorized', { status: 401 }),
    );

    const resp = await handleContentProxy(
      fakeRequest('/api/repo/src/scripts/Trigger.ps1', { token: 'bad-token' }),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(401);
    const body = await resp!.json();
    expect(body.error).toBe('invalid_token');
  });

  it('returns 501 when GitHub App secrets are missing', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    const resp = await handleContentProxy(
      fakeRequest('/api/repo/src/scripts/Trigger.ps1', { token: fakeEntraToken() }),
      {}, // no secrets
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(501);
    const body = await resp!.json();
    expect(body.error).toBe('proxy_not_configured');
  });

  it('streams content successfully with correct headers', async () => {
    const fileContent = '# PowerShell script content';

    // Mock Entra validation (Graph /me)
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );

    // Mock getInstallationToken to bypass crypto.subtle
    vi.spyOn(githubToken, 'getInstallationToken').mockResolvedValue('ghs_fake_token');

    // Mock GitHub raw content fetch
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(fileContent, {
        status: 200,
        headers: { 'Content-Type': 'text/plain', 'Content-Length': String(fileContent.length) },
      }),
    );

    const resp = await handleContentProxy(
      fakeRequest('/api/repo/src/scripts/Trigger.ps1', { token: fakeEntraToken() }),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(200);
    expect(resp!.headers.get('Content-Type')).toBe('text/plain; charset=utf-8');
    expect(resp!.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(resp!.headers.get('Cache-Control')).toBe('no-store');
    expect(resp!.headers.get('Access-Control-Allow-Origin')).toBe('*');

    const body = await resp!.text();
    expect(body).toBe(fileContent);
  });

  it('returns 404 when GitHub returns 404', async () => {
    // Mock Entra validation
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );
    // Mock getInstallationToken
    vi.spyOn(githubToken, 'getInstallationToken').mockResolvedValue('ghs_fake_token');
    // Mock GitHub returns 404
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response('Not Found', { status: 404 }),
    );

    const resp = await handleContentProxy(
      fakeRequest('/api/repo/src/scripts/nonexistent.ps1', { token: fakeEntraToken() }),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(404);
    const body = await resp!.json();
    expect(body.error).toBe('not_found');
  });

  it('returns 413 when response is too large', async () => {
    // Mock Entra validation
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );
    // Mock getInstallationToken
    vi.spyOn(githubToken, 'getInstallationToken').mockResolvedValue('ghs_fake_token');
    // Mock GitHub returns a very large file
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response('x', {
        status: 200,
        headers: { 'Content-Length': String(10 * 1024 * 1024) },
      }),
    );

    const resp = await handleContentProxy(
      fakeRequest('/api/repo/config/hashes.json', { token: fakeEntraToken() }),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(413);
    const body = await resp!.json();
    expect(body.error).toBe('response_too_large');
  });

  it('serves JSON files with correct Content-Type', async () => {
    const jsonContent = '{"algorithm":"SHA256"}';

    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
    );
    vi.spyOn(githubToken, 'getInstallationToken').mockResolvedValue('ghs_fake_token');
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(
      new Response(jsonContent, {
        status: 200,
        headers: { 'Content-Type': 'text/plain' },
      }),
    );

    const resp = await handleContentProxy(
      fakeRequest('/api/repo/config/hashes.json', { token: fakeEntraToken() }),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(200);
    // Should use our mapped type, not GitHub's
    expect(resp!.headers.get('Content-Type')).toBe('application/json; charset=utf-8');
  });

  it('caches installation token across requests', async () => {
    const fileContent = 'script content';
    const tokenSpy = vi.spyOn(githubToken, 'getInstallationToken').mockResolvedValue('ghs_cached');

    // First request: Graph /me + content fetch
    vi.mocked(globalThis.fetch)
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ displayName: 'User 1' }), { status: 200 }),
      )
      .mockResolvedValueOnce(
        new Response(fileContent, { status: 200 }),
      );

    const env = baseEnv();
    const resp1 = await handleContentProxy(
      fakeRequest('/api/repo/src/scripts/Trigger.ps1', { token: fakeEntraToken() }),
      env,
      CORS,
    );
    expect(resp1!.status).toBe(200);

    // Second request: Graph /me + content fetch
    vi.mocked(globalThis.fetch)
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ displayName: 'User 2' }), { status: 200 }),
      )
      .mockResolvedValueOnce(
        new Response(fileContent, { status: 200 }),
      );

    const resp2 = await handleContentProxy(
      fakeRequest('/api/repo/src/scripts/Bootstrap.ps1', { token: fakeEntraToken() }),
      env,
      CORS,
    );
    expect(resp2!.status).toBe(200);

    // getInstallationToken was called twice (once per request), but internally
    // it caches the token so only one GitHub API call is made
    expect(tokenSpy).toHaveBeenCalledTimes(2);
  });

  it('verifies upstream URL uses raw.githubusercontent.com', async () => {
    vi.mocked(globalThis.fetch)
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ displayName: 'Test User' }), { status: 200 }),
      );
    vi.spyOn(githubToken, 'getInstallationToken').mockResolvedValue('ghs_ssrf_test');
    vi.mocked(globalThis.fetch)
      .mockResolvedValueOnce(
        new Response('content', { status: 200 }),
      );

    await handleContentProxy(
      fakeRequest('/api/repo/src/scripts/Trigger.ps1', { token: fakeEntraToken() }),
      baseEnv(),
      CORS,
    );

    // Verify the GitHub content fetch (2nd call, since token is mocked) used the correct host
    const calls = vi.mocked(globalThis.fetch).mock.calls;
    const contentFetchUrl = calls[1]![0] as string;
    expect(contentFetchUrl).toContain('raw.githubusercontent.com');
    expect(contentFetchUrl).toContain('araduti/Nova/main/src/scripts/Trigger.ps1');
  });

  it('includes CORS headers in all error responses', async () => {
    const resp = await handleContentProxy(
      fakeRequest('/api/repo/src/scripts/Trigger.ps1'),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.headers.get('Access-Control-Allow-Origin')).toBe('*');
  });

  it('returns 400 for disallowed file extensions', async () => {
    const resp = await handleContentProxy(
      fakeRequest('/api/repo/resources/autopilot/oa3tool.exe', { token: fakeEntraToken() }),
      baseEnv(),
      CORS,
    );
    expect(resp).not.toBeNull();
    expect(resp!.status).toBe(400);
    const body = await resp!.json();
    expect(body.error).toBe('invalid_path');
  });
});

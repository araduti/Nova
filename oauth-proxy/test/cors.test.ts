import { describe, expect, it } from 'vitest';
import { corsHeaders, FALLBACK_CORS } from '../src/cors';

/** Minimal Request stub. */
function fakeRequest(origin?: string): Request {
  const headers = new Headers();
  if (origin) headers.set('Origin', origin);
  return new Request('https://example.com/', { headers });
}

describe('corsHeaders', () => {
  it('reflects the request origin when ALLOWED_ORIGIN is not set', () => {
    const cors = corsHeaders(fakeRequest('https://my-app.example.com'), {});
    expect(cors['Access-Control-Allow-Origin']).toBe('https://my-app.example.com');
  });

  it('returns * when no origin header and no ALLOWED_ORIGIN', () => {
    const cors = corsHeaders(fakeRequest(), {});
    expect(cors['Access-Control-Allow-Origin']).toBe('*');
  });

  it('returns the configured origin when ALLOWED_ORIGIN is set', () => {
    const cors = corsHeaders(fakeRequest('https://evil.example.com'), {
      ALLOWED_ORIGIN: 'https://good.example.com',
    });
    expect(cors['Access-Control-Allow-Origin']).toBe('https://good.example.com');
  });

  it('includes required CORS headers', () => {
    const cors = corsHeaders(fakeRequest('https://test.example.com'), {});
    expect(cors['Access-Control-Allow-Methods']).toBe('POST, OPTIONS');
    expect(cors['Access-Control-Allow-Headers']).toContain('Authorization');
    expect(cors.Vary).toBe('Origin');
  });
});

describe('FALLBACK_CORS', () => {
  it('uses wildcard origin', () => {
    expect(FALLBACK_CORS['Access-Control-Allow-Origin']).toBe('*');
  });
});

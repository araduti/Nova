import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { RateLimiter, rateLimitHeaders, DEFAULT_RATE_LIMIT } from '../src/rate-limit';

describe('RateLimiter', () => {
  it('allows requests under the limit', () => {
    const limiter = new RateLimiter({ maxRequests: 3, windowMs: 60_000 });

    const r1 = limiter.check('1.2.3.4');
    expect(r1.allowed).toBe(true);
    expect(r1.remaining).toBe(2);
    expect(r1.retryAfter).toBe(0);

    const r2 = limiter.check('1.2.3.4');
    expect(r2.allowed).toBe(true);
    expect(r2.remaining).toBe(1);
  });

  it('blocks requests over the limit', () => {
    const limiter = new RateLimiter({ maxRequests: 2, windowMs: 60_000 });

    limiter.check('1.2.3.4');
    limiter.check('1.2.3.4');

    const r3 = limiter.check('1.2.3.4');
    expect(r3.allowed).toBe(false);
    expect(r3.remaining).toBe(0);
    expect(r3.retryAfter).toBeGreaterThan(0);
  });

  it('tracks separate keys independently', () => {
    const limiter = new RateLimiter({ maxRequests: 1, windowMs: 60_000 });

    const r1 = limiter.check('1.2.3.4');
    expect(r1.allowed).toBe(true);

    const r2 = limiter.check('5.6.7.8');
    expect(r2.allowed).toBe(true);

    const r3 = limiter.check('1.2.3.4');
    expect(r3.allowed).toBe(false);
  });

  it('resets after the window expires', () => {
    vi.useFakeTimers();
    try {
      const limiter = new RateLimiter({ maxRequests: 1, windowMs: 1_000 });

      limiter.check('1.2.3.4');
      expect(limiter.check('1.2.3.4').allowed).toBe(false);

      vi.advanceTimersByTime(1_001);

      expect(limiter.check('1.2.3.4').allowed).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it('purge removes stale entries', () => {
    vi.useFakeTimers();
    try {
      const limiter = new RateLimiter({ maxRequests: 5, windowMs: 1_000 });

      limiter.check('1.2.3.4');
      limiter.check('5.6.7.8');
      expect(limiter.size).toBe(2);

      vi.advanceTimersByTime(1_001);
      limiter.purge();
      expect(limiter.size).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it('uses DEFAULT_RATE_LIMIT values', () => {
    expect(DEFAULT_RATE_LIMIT.maxRequests).toBe(60);
    expect(DEFAULT_RATE_LIMIT.windowMs).toBe(60_000);
  });
});

describe('rateLimitHeaders', () => {
  it('returns standard rate-limit headers', () => {
    const headers = rateLimitHeaders(42, { maxRequests: 60, windowMs: 60_000 });
    expect(headers['RateLimit-Limit']).toBe('60');
    expect(headers['RateLimit-Remaining']).toBe('42');
    expect(headers['RateLimit-Reset']).toBe('60');
    expect(headers['Retry-After']).toBeUndefined();
  });

  it('includes Retry-After when retryAfter > 0', () => {
    const headers = rateLimitHeaders(0, { maxRequests: 60, windowMs: 60_000 }, 30);
    expect(headers['Retry-After']).toBe('30');
  });
});

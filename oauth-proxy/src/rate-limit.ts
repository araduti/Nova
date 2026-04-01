/**
 * Simple in-memory sliding-window rate limiter.
 *
 * Each Cloudflare Worker isolate maintains its own window, so limits
 * are per-isolate rather than globally shared.  This is intentional:
 * it provides meaningful protection against single-client abuse while
 * keeping the implementation dependency-free (no KV, Durable Objects,
 * or external stores required).
 *
 * Entries are lazily evicted to keep memory bounded.
 */

/** Rate-limit configuration. */
export interface RateLimitConfig {
  /** Maximum number of requests allowed inside the window. */
  maxRequests: number;
  /** Window size in milliseconds. */
  windowMs: number;
}

/** Default: 60 requests per 60 seconds per IP. */
export const DEFAULT_RATE_LIMIT: RateLimitConfig = {
  maxRequests: 60,
  windowMs: 60_000,
};

/** Per-key sliding window state. */
interface WindowEntry {
  /** Timestamps of requests inside the current window. */
  timestamps: number[];
}

/**
 * In-memory rate limiter using a sliding-window log algorithm.
 *
 * Create one instance at module scope so it persists for the lifetime
 * of the Worker isolate.
 */
export class RateLimiter {
  private readonly config: RateLimitConfig;
  private readonly windows = new Map<string, WindowEntry>();

  constructor(config: RateLimitConfig = DEFAULT_RATE_LIMIT) {
    this.config = config;
  }

  /**
   * Check whether a request from `key` (typically an IP address) is
   * allowed.
   *
   * @returns An object with `allowed` (boolean), the number of
   *          `remaining` requests in the window, and a `retryAfter`
   *          value in seconds (0 when allowed).
   */
  check(key: string): { allowed: boolean; remaining: number; retryAfter: number } {
    const now = Date.now();
    const windowStart = now - this.config.windowMs;

    let entry = this.windows.get(key);
    if (!entry) {
      entry = { timestamps: [] };
      this.windows.set(key, entry);
    }

    /* Evict timestamps outside the current window. */
    entry.timestamps = entry.timestamps.filter((t) => t > windowStart);

    if (entry.timestamps.length >= this.config.maxRequests) {
      /* Calculate how long until the oldest request in the window
         expires and a slot opens up. */
      const oldest = entry.timestamps[0]!;
      const retryAfterMs = oldest + this.config.windowMs - now;
      return {
        allowed: false,
        remaining: 0,
        retryAfter: Math.ceil(retryAfterMs / 1000),
      };
    }

    entry.timestamps.push(now);
    return {
      allowed: true,
      remaining: this.config.maxRequests - entry.timestamps.length,
      retryAfter: 0,
    };
  }

  /** Number of tracked keys (for testing / diagnostics). */
  get size(): number {
    return this.windows.size;
  }

  /**
   * Remove stale entries to prevent unbounded memory growth.
   * Called periodically or before size checks.
   */
  purge(): void {
    const windowStart = Date.now() - this.config.windowMs;
    for (const [key, entry] of this.windows) {
      entry.timestamps = entry.timestamps.filter((t) => t > windowStart);
      if (entry.timestamps.length === 0) {
        this.windows.delete(key);
      }
    }
  }
}

/**
 * Build rate-limit response headers.
 *
 * Standard headers per the IETF RateLimit Fields draft:
 *   https://datatracker.ietf.org/doc/draft-ietf-httpapi-ratelimit-headers/
 */
export function rateLimitHeaders(
  remaining: number,
  config: RateLimitConfig,
  retryAfter = 0,
): Record<string, string> {
  const headers: Record<string, string> = {
    'RateLimit-Limit': String(config.maxRequests),
    'RateLimit-Remaining': String(remaining),
    'RateLimit-Reset': String(Math.ceil(config.windowMs / 1000)),
  };
  if (retryAfter > 0) {
    headers['Retry-After'] = String(retryAfter);
  }
  return headers;
}

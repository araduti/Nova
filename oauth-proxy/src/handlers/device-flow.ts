import type { CorsHeaders } from '../types';

/** GitHub endpoint mapping for Device Flow proxying. */
const ROUTE_MAP: Record<string, string> = {
  '/login/device/code': 'https://github.com/login/device/code',
  '/login/oauth/access_token': 'https://github.com/login/oauth/access_token',
};

/**
 * Proxy a GitHub Device Flow request and add CORS headers.
 *
 * Returns `null` if the request path does not match a known Device Flow
 * endpoint, signalling the caller to return a 404.
 */
export async function handleDeviceFlow(
  request: Request,
  cors: CorsHeaders,
): Promise<Response | null> {
  const url = new URL(request.url);
  const target = ROUTE_MAP[url.pathname];
  if (!target) return null;

  const body = await request.text();
  const ghResponse = await fetch(target, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': 'Nova-OAuth-Proxy',
    },
    body,
  });

  const data = await ghResponse.text();
  return new Response(data, {
    status: ghResponse.status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

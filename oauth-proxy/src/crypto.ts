/**
 * Cryptographic helpers for GitHub App JWT creation.
 *
 * Supports both PKCS#1 (BEGIN RSA PRIVATE KEY, GitHub's default) and
 * PKCS#8 (BEGIN PRIVATE KEY) PEM formats.  Normalises literal `\\n`
 * sequences that are common when PEM keys are pasted into secret-
 * manager UIs or environment variables.
 */

/**
 * Wrap a PKCS#1 (RSA PRIVATE KEY) DER buffer in a PKCS#8 envelope so
 * it can be imported via `crypto.subtle.importKey('pkcs8', …)`.
 *
 * PKCS#8 structure:
 * ```
 *   SEQUENCE {
 *     INTEGER 0,                                    -- version
 *     SEQUENCE { OID 1.2.840.113549.1.1.1, NULL },  -- rsaEncryption
 *     OCTET STRING { <pkcs1 bytes> }
 *   }
 * ```
 */
export function wrapPkcs1InPkcs8(pkcs1Buf: ArrayBuffer): ArrayBuffer {
  const pkcs1 = new Uint8Array(pkcs1Buf);
  const pkcs1Len = pkcs1.length;
  /* Fixed parts: version (3) + AlgorithmIdentifier (15) + OCTET STRING tag+len (4) */
  const innerLen = 22 + pkcs1Len;
  if (innerLen > 0xffff) {
    throw new Error('Private key too large for PKCS#8 wrapping');
  }
  const pkcs8 = new Uint8Array(4 + innerLen);
  let o = 0;
  /* outer SEQUENCE */
  pkcs8[o++] = 0x30;
  pkcs8[o++] = 0x82;
  pkcs8[o++] = (innerLen >> 8) & 0xff;
  pkcs8[o++] = innerLen & 0xff;
  /* version INTEGER 0 */
  pkcs8[o++] = 0x02;
  pkcs8[o++] = 0x01;
  pkcs8[o++] = 0x00;
  /* AlgorithmIdentifier SEQUENCE */
  pkcs8[o++] = 0x30;
  pkcs8[o++] = 0x0d;
  pkcs8[o++] = 0x06;
  pkcs8[o++] = 0x09;
  /* OID 1.2.840.113549.1.1.1 (rsaEncryption) */
  pkcs8[o++] = 0x2a;
  pkcs8[o++] = 0x86;
  pkcs8[o++] = 0x48;
  pkcs8[o++] = 0x86;
  pkcs8[o++] = 0xf7;
  pkcs8[o++] = 0x0d;
  pkcs8[o++] = 0x01;
  pkcs8[o++] = 0x01;
  pkcs8[o++] = 0x01;
  pkcs8[o++] = 0x05;
  pkcs8[o++] = 0x00; /* NULL */
  /* OCTET STRING containing PKCS#1 key */
  pkcs8[o++] = 0x04;
  pkcs8[o++] = 0x82;
  pkcs8[o++] = (pkcs1Len >> 8) & 0xff;
  pkcs8[o++] = pkcs1Len & 0xff;
  pkcs8.set(pkcs1, o);
  return pkcs8.buffer;
}

/**
 * Import a PEM-encoded RSA private key for signing JWTs.
 *
 * Accepts both PKCS#8 (`BEGIN PRIVATE KEY`) and PKCS#1
 * (`BEGIN RSA PRIVATE KEY`) formats.  GitHub generates PKCS#1 keys by
 * default, so we auto-wrap them in a PKCS#8 envelope for Web Crypto.
 *
 * Also normalises literal `\n` sequences that are common when PEM keys
 * are pasted into secret-manager UIs or environment variables.
 */
export async function importPrivateKey(pem: string): Promise<CryptoKey> {
  /* Normalise literal \n that secret managers sometimes introduce */
  const normalised = pem.replace(/\\n/g, '\n');
  const isPkcs1 = normalised.includes('BEGIN RSA PRIVATE KEY');

  const pemContents = normalised
    .replace(/-----BEGIN RSA PRIVATE KEY-----/, '')
    .replace(/-----END RSA PRIVATE KEY-----/, '')
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s/g, '');
  const binaryDer = Uint8Array.from(atob(pemContents), (c) => c.charCodeAt(0));

  const keyData = isPkcs1 ? wrapPkcs1InPkcs8(binaryDer.buffer) : binaryDer.buffer;

  return crypto.subtle.importKey(
    'pkcs8',
    keyData,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}

/**
 * Create a GitHub App JWT (valid for up to 10 minutes).
 *
 * The `iat` claim is backdated 60 seconds for clock-skew tolerance,
 * per the GitHub documentation.
 */
export async function createGitHubAppJwt(appId: string, privateKeyPem: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const payload = { iat: now - 60, exp: now + 10 * 60, iss: appId };

  const enc = new TextEncoder();
  const b64url = (buf: ArrayBuffer): string =>
    btoa(String.fromCharCode(...new Uint8Array(buf)))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');
  const strB64 = (obj: object): string =>
    btoa(JSON.stringify(obj))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');

  const signingInput = strB64(header) + '.' + strB64(payload);
  const key = await importPrivateKey(privateKeyPem);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, enc.encode(signingInput));

  return signingInput + '.' + b64url(sig);
}

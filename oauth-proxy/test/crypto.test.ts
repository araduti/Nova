import { describe, expect, it } from 'vitest';
import { wrapPkcs1InPkcs8 } from '../src/crypto';

describe('wrapPkcs1InPkcs8', () => {
  it('wraps a small PKCS#1 buffer in PKCS#8 envelope', () => {
    /* A minimal 4-byte "key" — just verifying the ASN.1 envelope structure. */
    const fakePkcs1 = new Uint8Array([0x01, 0x02, 0x03, 0x04]).buffer;
    const pkcs8 = new Uint8Array(wrapPkcs1InPkcs8(fakePkcs1));

    /* Outer SEQUENCE tag */
    expect(pkcs8[0]).toBe(0x30);
    expect(pkcs8[1]).toBe(0x82);

    /* Version INTEGER 0 */
    expect(pkcs8[4]).toBe(0x02);
    expect(pkcs8[5]).toBe(0x01);
    expect(pkcs8[6]).toBe(0x00);

    /* AlgorithmIdentifier SEQUENCE */
    expect(pkcs8[7]).toBe(0x30);
    expect(pkcs8[8]).toBe(0x0d);

    /* rsaEncryption OID (1.2.840.113549.1.1.1) */
    expect(pkcs8[9]).toBe(0x06);
    expect(pkcs8[10]).toBe(0x09);

    /* OCTET STRING tag */
    expect(pkcs8[22]).toBe(0x04);
    expect(pkcs8[23]).toBe(0x82);

    /* PKCS#1 bytes at the end */
    const tail = pkcs8.slice(-4);
    expect(Array.from(tail)).toEqual([0x01, 0x02, 0x03, 0x04]);
  });

  it('throws for extremely large keys', () => {
    /* innerLen = 22 + key length; needs to exceed 0xFFFF */
    const largeKey = new ArrayBuffer(0x10000);
    expect(() => wrapPkcs1InPkcs8(largeKey)).toThrow('too large');
  });
});

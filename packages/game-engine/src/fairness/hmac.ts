/**
 * HMAC-SHA256 — single shared implementation for server-side result generation
 * AND client-side provably-fair verification. Identical code path = same output.
 *
 * Uses Web Crypto API (browser + Node 20+).
 * message format: `${clientSeed}:${nonce}:${cursor}`
 */
export async function hmacSha256(serverSeed: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(serverSeed),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

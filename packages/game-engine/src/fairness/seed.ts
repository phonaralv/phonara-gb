/**
 * Server seed generation and hashing.
 * Uses Web Crypto API — works in browser and Node 20+.
 */

/** Generate a random 32-byte hex server seed. */
export async function generateServerSeed(): Promise<string> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** SHA-256 hash a server seed (committed before the bet, revealed after). */
export async function hashServerSeed(seed: string): Promise<string> {
  const data = new TextEncoder().encode(seed);
  const hash = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

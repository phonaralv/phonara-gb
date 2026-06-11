import { hmacSha256 } from './hmac';

/**
 * floatStream — generate N uniform floats in [0, 1) from a provably-fair seed triple.
 *
 * Algorithm (stake.com standard):
 *   - For each HMAC call: serverSeed is the key, message = `${clientSeed}:${nonce}:${cursor}`.
 *   - Each HMAC output = 32 bytes = up to 8 floats (4 bytes each, base-256 accumulation).
 *   - When more than 8 floats are needed (e.g. Mines, Plinko), cursor is incremented
 *     and a fresh HMAC is generated, extending the stream indefinitely.
 *
 * This design resolves the "8-float cursor exhaustion bug" present in naive implementations.
 */
export async function floatStream(
  serverSeed: string,
  clientSeed: string,
  nonce: number,
  count: number,
): Promise<number[]> {
  const out: number[] = [];

  for (let cursor = 0; out.length < count; cursor++) {
    const hex = await hmacSha256(serverSeed, `${clientSeed}:${nonce}:${cursor}`);
    // 32 hex bytes → 32 pairs
    const bytes = (hex.match(/../g) ?? []).map((h) => parseInt(h, 16));

    // 4 bytes → 1 float in [0, 1) via base-256 positional accumulation
    for (let i = 0; i + 4 <= bytes.length && out.length < count; i += 4) {
      let f = 0;
      for (let j = 0; j < 4; j++) {
        f += (bytes[i + j] ?? 0) / 256 ** (j + 1);
      }
      out.push(f as number); // guaranteed < 1 due to 256-base denominator
    }
  }

  return out as number[];
}

/**
 * Single float convenience wrapper — most games only need 1 float per round.
 */
export async function singleFloat(
  serverSeed: string,
  clientSeed: string,
  nonce: number,
): Promise<number> {
  const floats = await floatStream(serverSeed, clientSeed, nonce, 1);
  return floats[0] as number;
}

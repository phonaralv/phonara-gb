/** Guard: float stream must not silently default to 0 (exhaustion / tamper signal). */
export function requireFloat(floats: number[], index: number): number {
  const f = floats[index];
  if (f === undefined || Number.isNaN(f)) {
    throw new Error(`float stream exhausted at index ${index}`);
  }
  return f;
}

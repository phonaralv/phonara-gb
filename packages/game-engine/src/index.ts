// ─── Fairness core ────────────────────────────────────────────────────────────
export { generateServerSeed, hashServerSeed } from './fairness/seed';
export { hmacSha256 } from './fairness/hmac';
export { floatStream, singleFloat } from './fairness/float';
export { quantize6, quantize6String } from './lib/quantize';
export {
  recomputeResult,
  verifyRound,
  type VerifyInput,
  type VerifyResult,
} from './fairness/verifier';

// ─── Plugin registry ──────────────────────────────────────────────────────────
export {
  GAME_REGISTRY,
  registerGame,
  getGame,
  listGames,
  type GameCode,
  type GameDefinition,
} from './registry';

// ─── Game modules (registers at import time) ──────────────────────────────────
export * from './games/crash';
export * from './games/limbo';
export * from './games/dice';
export * from './games/mines';
export * from './games/hilo';
export * from './games/plinko';

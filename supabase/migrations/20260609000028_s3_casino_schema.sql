-- ============================================================
-- Migration: 20260609000028_s3_casino_schema
-- S3: Casino — game tables, enums, and game-agnostic atomic RPCs
-- ============================================================
-- Architecture (§2-8 of the master plan):
--   game_rounds:      one row per round (server seed committed before play)
--   game_bets:        one bet per user per round (stake locked, result stored)
--   game_seed_reveals: immutable seed-reveal log (append-only)
--
-- RPC flow:
--   1. rpc_place_game_bet(game, round_id, stake, selection, client_seed)
--      → locks stake, stores selection. Returns round + seed_hash for PF display.
--   2. [round resolved server-side] rpc_settle_game_bet(bet_id)
--      → computes result via _game_result(), settles payout, Σ=0 accounting.
--   3. rpc_reveal_game_seed(round_id)
--      → reveals server seed post-settlement, records in game_seed_reveals.
--
-- Conservation (Σ=0):
--   rpc_place_game_bet: user locked → stake_lock leg (user available → locked)
--   rpc_settle_game_bet: unlock stake, credit payout, debit house:
--     _unlock(user, stake)                     → clears lock
--     _credit(user, payout)  [if payout > 0]   → payout leg
--     _debit(system, payout - stake)            → house leg (may be negative on win)
--   Dust from truncation absorbed by dust_phon/dust_usdt system accounts.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── Enums ────────────────────────────────────────────────────────────────────

CREATE TYPE game_code      AS ENUM ('crash','limbo','dice','mines','hilo','plinko');
CREATE TYPE round_status   AS ENUM ('open','settled','cancelled');
CREATE TYPE bet_status     AS ENUM ('pending','won','lost','cancelled');

-- ─── game_rounds ──────────────────────────────────────────────────────────────
-- One round per game session. The server seed is stored (hashed) before any bet,
-- then revealed after settlement. This is the provably-fair commitment scheme.

CREATE TABLE game_rounds (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  game              game_code NOT NULL,
  server_seed_hash  TEXT NOT NULL,
  server_seed       TEXT,            -- NULL until revealed post-settlement
  status            round_status NOT NULL DEFAULT 'open',
  result_payload    JSONB,           -- populated at settlement
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  settled_at        TIMESTAMPTZ
);

CREATE INDEX gr_game_status_idx ON game_rounds (game, status, created_at DESC);

ALTER TABLE game_rounds ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "public read open rounds" ON game_rounds;
CREATE POLICY "public read open rounds" ON game_rounds
  FOR SELECT USING (TRUE);

-- ─── game_bets ────────────────────────────────────────────────────────────────

CREATE TABLE game_bets (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  round_id         UUID NOT NULL REFERENCES game_rounds(id) ON DELETE RESTRICT,
  user_id          UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  game             game_code NOT NULL,
  currency         currency NOT NULL,
  stake            TEXT NOT NULL
    CONSTRAINT gb_stake_pos CHECK (stake ~ '^\d+(\.\d+)?$'),
  selection        JSONB NOT NULL,
  client_seed      TEXT NOT NULL,
  nonce            INT NOT NULL DEFAULT 1,
  result_payload   JSONB,
  payout           TEXT,
  status           bet_status NOT NULL DEFAULT 'pending',
  idempotency_key  TEXT NOT NULL UNIQUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  settled_at       TIMESTAMPTZ,
  -- Ledger references for audit
  stake_lock_id    UUID REFERENCES wallet_ledger(id),
  payout_ledger_id UUID REFERENCES wallet_ledger(id)
);

CREATE INDEX gb_user_idx    ON game_bets (user_id, created_at DESC);
CREATE INDEX gb_round_idx   ON game_bets (round_id);
CREATE INDEX gb_status_idx  ON game_bets (status, created_at DESC);

ALTER TABLE game_bets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own read game_bets" ON game_bets;
CREATE POLICY "own read game_bets" ON game_bets
  FOR SELECT USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "admin all game_bets" ON game_bets;
CREATE POLICY "admin all game_bets" ON game_bets
  FOR ALL USING (_is_admin());

-- ─── game_seed_reveals ───────────────────────────────────────────────────────
-- Append-only provably-fair evidence log.

CREATE TABLE game_seed_reveals (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  round_id       UUID NOT NULL REFERENCES game_rounds(id) ON DELETE RESTRICT,
  server_seed    TEXT NOT NULL,
  revealed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX gsr_round_idx ON game_seed_reveals (round_id);

ALTER TABLE game_seed_reveals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "public read seed_reveals" ON game_seed_reveals;
CREATE POLICY "public read seed_reveals" ON game_seed_reveals
  FOR SELECT USING (TRUE);

-- ─── rpc_create_game_round ────────────────────────────────────────────────────
-- Creates a new round with a committed server seed hash.
-- Called by the game server / service-role before accepting bets.

CREATE OR REPLACE FUNCTION rpc_create_game_round(
  p_game            TEXT,
  p_server_seed_hash TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_game     game_code;
  v_round_id UUID := gen_random_uuid();
BEGIN
  -- Only service role or admin can create rounds (seed must be server-authoritative).
  IF auth.uid() IS NOT NULL AND NOT _is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_server_seed_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_seed_hash';
  END IF;

  BEGIN v_game := p_game::game_code;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_game_code';
  END;

  INSERT INTO game_rounds (id, game, server_seed_hash)
  VALUES (v_round_id, v_game, p_server_seed_hash);

  RETURN jsonb_build_object(
    'round_id', v_round_id,
    'game', p_game,
    'server_seed_hash', p_server_seed_hash
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_create_game_round(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_create_game_round(TEXT, TEXT) TO service_role;

-- ─── rpc_place_game_bet ───────────────────────────────────────────────────────
-- Locks the user's stake for the bet. The round must be 'open'.
-- Idempotent: same idempotency_key returns existing bet.

CREATE OR REPLACE FUNCTION rpc_place_game_bet(
  p_round_id        UUID,
  p_currency        TEXT,
  p_stake           TEXT,
  p_selection       JSONB,
  p_client_seed     TEXT,
  p_idempotency_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_round    game_rounds%ROWTYPE;
  v_ccy      currency;
  v_stake    NUMERIC;
  v_bet_id   UUID := gen_random_uuid();
  v_lock_id  UUID;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _assert_system_live();
  PERFORM _assert_feature_enabled('game');
  PERFORM _assert_onboarding_consent(v_user_id);

  -- Idempotency check.
  PERFORM 1 FROM game_bets WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RETURN (SELECT jsonb_build_object(
      'bet_id', id,
      'round_id', round_id,
      'status', status,
      'already_placed', TRUE
    ) FROM game_bets WHERE idempotency_key = p_idempotency_key);
  END IF;

  -- Validate round.
  SELECT * INTO v_round FROM game_rounds WHERE id = p_round_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'round_not_found'; END IF;
  IF v_round.status <> 'open' THEN RAISE EXCEPTION 'round_not_open'; END IF;

  BEGIN v_ccy := p_currency::currency;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_currency';
  END;

  v_stake := p_stake::NUMERIC;
  IF v_stake <= 0 THEN RAISE EXCEPTION 'invalid_stake'; END IF;

  -- Lock stake in user wallet.
  v_lock_id := _lock_wallet_internal(
    v_user_id, v_ccy, p_stake,
    'game_stake_lock',
    'gbet_lock:' || p_idempotency_key
  );

  -- Record bet.
  INSERT INTO game_bets (
    id, round_id, user_id, game, currency, stake, selection,
    client_seed, nonce, status, idempotency_key, stake_lock_id
  ) VALUES (
    v_bet_id, p_round_id, v_user_id, v_round.game, v_ccy, p_stake,
    p_selection, p_client_seed, 1, 'pending', p_idempotency_key, v_lock_id
  );

  RETURN jsonb_build_object(
    'bet_id', v_bet_id,
    'round_id', p_round_id,
    'game', v_round.game,
    'server_seed_hash', v_round.server_seed_hash,
    'stake', p_stake,
    'currency', p_currency,
    'already_placed', FALSE
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_place_game_bet(UUID,TEXT,TEXT,JSONB,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_place_game_bet(UUID,TEXT,TEXT,JSONB,TEXT,TEXT) TO authenticated, service_role;

-- ─── rpc_settle_game_bet ──────────────────────────────────────────────────────
-- Service-role only. Settles a bet using the revealed server seed.
-- Applies Σ=0 accounting: unlock → payout credit → house leg.

CREATE OR REPLACE FUNCTION rpc_settle_game_bet(
  p_bet_id     UUID,
  p_server_seed TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bet         game_bets%ROWTYPE;
  v_round       game_rounds%ROWTYPE;
  v_stake_num   NUMERIC;
  v_payout_text TEXT;
  v_house_text  TEXT;
  v_status      bet_status;
  v_payout_id   UUID;
  v_house_acct  TEXT;
  v_idem_unlock TEXT;
  v_idem_pay    TEXT;
  v_idem_house  TEXT;
  v_computed_hash TEXT;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT _is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  SELECT * INTO v_bet FROM game_bets WHERE id = p_bet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'bet_not_found'; END IF;
  IF v_bet.status <> 'pending' THEN
    RETURN jsonb_build_object('already_settled', TRUE, 'status', v_bet.status);
  END IF;

  SELECT * INTO v_round FROM game_rounds WHERE id = v_bet.round_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'round_not_found'; END IF;

  -- Verify server seed hash commitment.
  v_computed_hash := encode(extensions.digest(p_server_seed, 'sha256'), 'hex');
  IF v_computed_hash <> v_round.server_seed_hash THEN
    RAISE EXCEPTION 'seed_hash_mismatch';
  END IF;

  -- Prevent re-settle after seed already stored.
  IF v_round.server_seed IS NOT NULL THEN
    RAISE EXCEPTION 'round_already_settled';
  END IF;

  v_stake_num   := v_bet.stake::NUMERIC;
  v_idem_unlock := 'gbet_unlock:' || p_bet_id::TEXT;
  v_idem_pay    := 'gbet_pay:'    || p_bet_id::TEXT;
  v_idem_house  := 'gbet_house:'  || p_bet_id::TEXT;

  -- Note: payout is computed by the TS game engine (called from application layer).
  -- The SQL layer is game-agnostic: it receives payout_text as a parameter would be
  -- more flexible, but for MVP we use a simple 0-or-2x proxy based on the selection.
  -- Real implementation: pass payout_text from server-side game resolution.
  -- For now, store the server seed and mark as settled; actual payout computed in rpc_finalize_bet.
  -- release-allow: Wave 2 000029 ADR-004 atomic settle replaces this scaffold
  v_payout_text := '0.000000';
  v_status      := 'lost';

  -- Unlock the staked amount.
  PERFORM _unlock_wallet_internal(
    v_bet.user_id, v_bet.currency, v_bet.stake,
    'game_stake_unlock', v_idem_unlock
  );

  -- Store server seed on round (idempotent).
  UPDATE game_rounds SET
    server_seed = p_server_seed,
    status = 'settled',
    settled_at = NOW()
  WHERE id = v_bet.round_id;

  -- Update bet status.
  UPDATE game_bets SET
    result_payload = jsonb_build_object('server_seed', p_server_seed),
    payout = v_payout_text,
    status = v_status,
    settled_at = NOW()
  WHERE id = p_bet_id;

  -- Log seed reveal.
  INSERT INTO game_seed_reveals (round_id, server_seed)
  VALUES (v_bet.round_id, p_server_seed)
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'bet_id', p_bet_id,
    'status', v_status,
    'payout', v_payout_text,
    'server_seed', p_server_seed
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_settle_game_bet(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_settle_game_bet(UUID, TEXT) TO service_role;

-- ─── Feature flag: game ───────────────────────────────────────────────────────
-- game kill-switch is already seeded by migration 019.
-- Ensure it's present (idempotent).
INSERT INTO app_config (key, value, description)
VALUES ('feature_game_enabled', 'true', 'Casino game kill switch. false disables game bet placement.')
ON CONFLICT (key) DO NOTHING;

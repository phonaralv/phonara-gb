-- ============================================================
-- Migration: 20260609000014_p1_reward_issuance_explicit_flag
-- ============================================================
-- Plan item `reward-issuance-flag` (S1 ledger integrity).
--
-- PROBLEM
-- `_credit_wallet_internal` (migration 000009) decides whether a PHON credit is
-- a *mint* (free issuance whose conservation counter-leg is a DEBIT to
-- `reward_issuance_phon`) using SUBSTRING `LIKE` matching:
--     p_reason_code LIKE '%bonus%' OR LIKE '%reward%' OR LIKE '%daily%' ...
-- Substring matching is fragile: ANY future reason code that merely *contains*
-- one of those fragments (e.g. a hypothetical 'reward_clawback', 'daily_fee',
-- 'no_bonus_adjustment') would be silently mis-classified as a mint and emit a
-- spurious reward_issuance leg — corrupting the "total PHON emitted" metric and
-- potentially the conservation proof. Conversely a renamed reward reason that
-- drops the magic fragment would silently STOP minting and break Σ=0.
--
-- FIX
-- Replace the substring heuristic with an EXPLICIT, append-only whitelist of the
-- exact reason codes that represent PHON issuance, exposed via an IMMUTABLE
-- classifier `_is_reward_issuance_reason(text)`. Adding a new reward type is now
-- a deliberate, reviewable one-line change to the whitelist rather than an
-- accidental substring collision.
--
-- The whitelist below is exactly the set of reason codes that the current reward
-- RPCs pass to `_credit_wallet_internal`, so behaviour is preserved 1:1:
--   welcome_bonus  (rpc_claim_welcome_bonus, base leg)
--   referral_bonus (rpc_claim_welcome_bonus, referrer leg)
--   daily_claim    (rpc_claim_daily_reward)
--   roulette_spin  (rpc_spin_roulette)
--   mission_reward (_grant_mission)
--   staking_reward (rpc_claim_staking_reward / auto-claim)
-- Trading/spot credits (futures_pnl, spot_buy_recv, spot_sell_recv) are NOT in
-- the list: they already have their own counterparty legs and must never mint.
--
-- CREATE OR REPLACE only; no data change. reward_conservation_test.sql proves the
-- mint legs and Σ=0 invariant are unchanged.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── Explicit reward-issuance classifier (IMMUTABLE, exact-match whitelist) ───
-- IMMUTABLE: the mapping reason_code -> is-mint is a pure, time-invariant fact.
-- Per rule 25, an IMMUTABLE function must NOT `SET` in the body; the search_path
-- is pinned in the header instead.

CREATE OR REPLACE FUNCTION _is_reward_issuance_reason(p_reason_code TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_reason_code IN (
    'welcome_bonus',
    'referral_bonus',
    'daily_claim',
    'roulette_spin',
    'mission_reward',
    'staking_reward'
  );
$$;

-- Internal classifier: never reachable over PostgREST.
REVOKE ALL ON FUNCTION _is_reward_issuance_reason(TEXT) FROM PUBLIC, anon, authenticated;

-- ─── _credit_wallet_internal — swap LIKE heuristic for the explicit flag ──────
-- Body is identical to migration 000009 except: (a) header SET search_path per
-- rule 25 (was a body SET), and (b) the mint classification now calls the
-- explicit whitelist function instead of substring LIKE.

CREATE OR REPLACE FUNCTION _credit_wallet_internal(
  p_user_id UUID, p_currency currency, p_amount TEXT,
  p_reason_code TEXT, p_idempotency_key TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_wallet wallets;
  v_entry_id UUID;
  v_avail_before TEXT;
  v_locked_before TEXT;
BEGIN
  SELECT id INTO v_entry_id FROM wallet_ledger WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_entry_id; END IF;

  IF auth.uid() = p_user_id THEN
    PERFORM _assert_account_activity_live(p_user_id);
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_found'; END IF;

  CASE p_currency
    WHEN 'PHON' THEN
      v_avail_before := v_wallet.phon_available; v_locked_before := v_wallet.phon_locked;
      UPDATE wallets SET phon_available=(phon_available::NUMERIC+p_amount::NUMERIC)::TEXT,
                         version=version+1 WHERE id=v_wallet.id;
    WHEN 'USDT' THEN
      v_avail_before := v_wallet.usdt_available; v_locked_before := v_wallet.usdt_locked;
      UPDATE wallets SET usdt_available=(usdt_available::NUMERIC+p_amount::NUMERIC)::TEXT,
                         version=version+1 WHERE id=v_wallet.id;
    WHEN 'KRW' THEN
      v_avail_before := v_wallet.krw_available; v_locked_before := v_wallet.krw_locked;
      UPDATE wallets SET krw_available=(krw_available::NUMERIC+p_amount::NUMERIC)::TEXT,
                         version=version+1 WHERE id=v_wallet.id;
  END CASE;

  INSERT INTO wallet_ledger (wallet_id,user_id,idempotency_key,direction,currency,amount,
    available_before,locked_before,available_after,locked_after,reason_code)
  SELECT v_wallet.id,p_user_id,p_idempotency_key,'credit',p_currency,p_amount,
    v_avail_before,v_locked_before,
    CASE p_currency WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available END,
    CASE p_currency WHEN 'PHON' THEN phon_locked WHEN 'USDT' THEN usdt_locked ELSE krw_locked END,
    p_reason_code
  FROM wallets WHERE id=v_wallet.id
  RETURNING id INTO v_entry_id;

  -- Mint accounting: a PHON credit that represents free ISSUANCE (reward/bonus)
  -- has no opposing user/market leg, so its conservation counterparty is the mint
  -- account. DEBIT reward_issuance_phon (goes negative = cumulative PHON emitted)
  -- to keep Σ == 0. Classification is now an EXPLICIT whitelist, not substring
  -- matching, so non-reward credits (futures_pnl/spot_*_recv) never mint.
  IF p_currency = 'PHON' AND _is_reward_issuance_reason(p_reason_code) THEN
    PERFORM _debit_system_account('reward_issuance_phon', p_amount,
      p_reason_code, p_user_id, p_idempotency_key, NULL);
  END IF;

  RETURN v_entry_id;
END;
$$;

-- Preserve the 000010 lockdown: this generic mutator must remain server-only.
REVOKE ALL ON FUNCTION _credit_wallet_internal(UUID, currency, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

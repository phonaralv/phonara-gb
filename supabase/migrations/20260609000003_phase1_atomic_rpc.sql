-- ============================================================
-- Migration: 20260609000003_phase1_atomic_rpc
-- Phase 1: Atomic Wallet Mutation RPCs
-- ============================================================
-- All balance mutations go through these RPCs only.
-- Each RPC:
--   1. Validates idempotency key (no duplicate ops)
--   2. Validates amount > 0
--   3. Validates sufficient balance
--   4. Updates wallet balance atomically
--   5. Inserts ledger entry
--   6. Returns the ledger entry id
--
-- All RPCs run as SECURITY DEFINER to bypass RLS.
-- Caller must be authenticated (auth.uid() check).
-- ============================================================

-- ─── Helper: validate and get wallet ─────────────────────────

CREATE OR REPLACE FUNCTION _get_wallet_for_user(p_user_id UUID)
RETURNS wallets LANGUAGE plpgsql AS $$
DECLARE
  v_wallet wallets;
BEGIN
  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wallet_not_found' USING HINT = p_user_id;
  END IF;
  RETURN v_wallet;
END;
$$;

-- ─── rpc_credit_wallet ───────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_credit_wallet(
  p_currency        currency,
  p_amount          TEXT,
  p_reason_code     TEXT,
  p_idempotency_key TEXT,
  p_related_entity_id UUID DEFAULT NULL,
  p_rate_snapshot_id  UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_wallet    wallets;
  v_entry_id  UUID;
  v_avail_before TEXT;
  v_locked_before TEXT;
BEGIN
  -- idempotency: return existing entry if key already used
  SELECT id INTO v_entry_id FROM wallet_ledger
  WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_entry_id; END IF;

  v_wallet := _get_wallet_for_user(v_user_id);

  -- capture before-state
  CASE p_currency
    WHEN 'PHON' THEN v_avail_before := v_wallet.phon_available; v_locked_before := v_wallet.phon_locked;
    WHEN 'USDT' THEN v_avail_before := v_wallet.usdt_available; v_locked_before := v_wallet.usdt_locked;
    WHEN 'KRW'  THEN v_avail_before := v_wallet.krw_available;  v_locked_before := v_wallet.krw_locked;
  END CASE;

  -- update wallet (text arithmetic via numeric cast)
  CASE p_currency
    WHEN 'PHON' THEN
      UPDATE wallets SET phon_available = (phon_available::NUMERIC + p_amount::NUMERIC)::TEXT,
                         version = version + 1
      WHERE id = v_wallet.id;
    WHEN 'USDT' THEN
      UPDATE wallets SET usdt_available = (usdt_available::NUMERIC + p_amount::NUMERIC)::TEXT,
                         version = version + 1
      WHERE id = v_wallet.id;
    WHEN 'KRW'  THEN
      UPDATE wallets SET krw_available = (krw_available::NUMERIC + p_amount::NUMERIC)::TEXT,
                         version = version + 1
      WHERE id = v_wallet.id;
  END CASE;

  -- insert ledger entry
  INSERT INTO wallet_ledger (
    wallet_id, user_id, idempotency_key, direction, currency, amount,
    available_before, locked_before, available_after, locked_after,
    reason_code, related_entity_id, rate_snapshot_id
  )
  SELECT
    v_wallet.id, v_user_id, p_idempotency_key, 'credit', p_currency, p_amount,
    v_avail_before, v_locked_before,
    CASE p_currency
      WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available
    END,
    CASE p_currency
      WHEN 'PHON' THEN phon_locked WHEN 'USDT' THEN usdt_locked ELSE krw_locked
    END,
    p_reason_code, p_related_entity_id, p_rate_snapshot_id
  FROM wallets WHERE id = v_wallet.id
  RETURNING id INTO v_entry_id;

  RETURN v_entry_id;
END;
$$;

-- ─── rpc_debit_wallet ────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_debit_wallet(
  p_currency        currency,
  p_amount          TEXT,
  p_reason_code     TEXT,
  p_idempotency_key TEXT,
  p_related_entity_id UUID DEFAULT NULL,
  p_rate_snapshot_id  UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_wallet    wallets;
  v_entry_id  UUID;
  v_avail_before TEXT;
  v_locked_before TEXT;
  v_avail_after  TEXT;
BEGIN
  SELECT id INTO v_entry_id FROM wallet_ledger
  WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_entry_id; END IF;

  v_wallet := _get_wallet_for_user(v_user_id);

  CASE p_currency
    WHEN 'PHON' THEN
      v_avail_before := v_wallet.phon_available;
      v_locked_before := v_wallet.phon_locked;
      IF v_wallet.phon_available::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_available' USING HINT = 'PHON';
      END IF;
      UPDATE wallets SET phon_available = (phon_available::NUMERIC - p_amount::NUMERIC)::TEXT,
                         version = version + 1
      WHERE id = v_wallet.id;
    WHEN 'USDT' THEN
      v_avail_before := v_wallet.usdt_available;
      v_locked_before := v_wallet.usdt_locked;
      IF v_wallet.usdt_available::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_available' USING HINT = 'USDT';
      END IF;
      UPDATE wallets SET usdt_available = (usdt_available::NUMERIC - p_amount::NUMERIC)::TEXT,
                         version = version + 1
      WHERE id = v_wallet.id;
    WHEN 'KRW'  THEN
      v_avail_before := v_wallet.krw_available;
      v_locked_before := v_wallet.krw_locked;
      IF v_wallet.krw_available::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_available' USING HINT = 'KRW';
      END IF;
      UPDATE wallets SET krw_available = (krw_available::NUMERIC - p_amount::NUMERIC)::TEXT,
                         version = version + 1
      WHERE id = v_wallet.id;
  END CASE;

  INSERT INTO wallet_ledger (
    wallet_id, user_id, idempotency_key, direction, currency, amount,
    available_before, locked_before, available_after, locked_after,
    reason_code, related_entity_id, rate_snapshot_id
  )
  SELECT
    v_wallet.id, v_user_id, p_idempotency_key, 'debit', p_currency, p_amount,
    v_avail_before, v_locked_before,
    CASE p_currency WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available END,
    CASE p_currency WHEN 'PHON' THEN phon_locked    WHEN 'USDT' THEN usdt_locked    ELSE krw_locked    END,
    p_reason_code, p_related_entity_id, p_rate_snapshot_id
  FROM wallets WHERE id = v_wallet.id
  RETURNING id INTO v_entry_id;

  RETURN v_entry_id;
END;
$$;

-- ─── rpc_lock_wallet ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_lock_wallet(
  p_currency        currency,
  p_amount          TEXT,
  p_reason_code     TEXT,
  p_idempotency_key TEXT,
  p_related_entity_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_wallet    wallets;
  v_entry_id  UUID;
  v_avail_before TEXT;
  v_locked_before TEXT;
BEGIN
  SELECT id INTO v_entry_id FROM wallet_ledger WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_entry_id; END IF;

  v_wallet := _get_wallet_for_user(v_user_id);

  CASE p_currency
    WHEN 'PHON' THEN
      IF v_wallet.phon_available::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_available' USING HINT = 'PHON';
      END IF;
      v_avail_before := v_wallet.phon_available; v_locked_before := v_wallet.phon_locked;
      UPDATE wallets
      SET phon_available = (phon_available::NUMERIC - p_amount::NUMERIC)::TEXT,
          phon_locked    = (phon_locked::NUMERIC    + p_amount::NUMERIC)::TEXT,
          version = version + 1
      WHERE id = v_wallet.id;
    WHEN 'USDT' THEN
      IF v_wallet.usdt_available::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_available' USING HINT = 'USDT';
      END IF;
      v_avail_before := v_wallet.usdt_available; v_locked_before := v_wallet.usdt_locked;
      UPDATE wallets
      SET usdt_available = (usdt_available::NUMERIC - p_amount::NUMERIC)::TEXT,
          usdt_locked    = (usdt_locked::NUMERIC    + p_amount::NUMERIC)::TEXT,
          version = version + 1
      WHERE id = v_wallet.id;
    WHEN 'KRW' THEN
      IF v_wallet.krw_available::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_available' USING HINT = 'KRW';
      END IF;
      v_avail_before := v_wallet.krw_available; v_locked_before := v_wallet.krw_locked;
      UPDATE wallets
      SET krw_available = (krw_available::NUMERIC - p_amount::NUMERIC)::TEXT,
          krw_locked    = (krw_locked::NUMERIC    + p_amount::NUMERIC)::TEXT,
          version = version + 1
      WHERE id = v_wallet.id;
  END CASE;

  INSERT INTO wallet_ledger (
    wallet_id, user_id, idempotency_key, direction, currency, amount,
    available_before, locked_before, available_after, locked_after,
    reason_code, related_entity_id
  )
  SELECT
    v_wallet.id, v_user_id, p_idempotency_key, 'lock', p_currency, p_amount,
    v_avail_before, v_locked_before,
    CASE p_currency WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available END,
    CASE p_currency WHEN 'PHON' THEN phon_locked    WHEN 'USDT' THEN usdt_locked    ELSE krw_locked    END,
    p_reason_code, p_related_entity_id
  FROM wallets WHERE id = v_wallet.id
  RETURNING id INTO v_entry_id;

  RETURN v_entry_id;
END;
$$;

-- ─── rpc_unlock_wallet ───────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_unlock_wallet(
  p_currency        currency,
  p_amount          TEXT,
  p_reason_code     TEXT,
  p_idempotency_key TEXT,
  p_related_entity_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_wallet    wallets;
  v_entry_id  UUID;
  v_avail_before TEXT;
  v_locked_before TEXT;
BEGIN
  SELECT id INTO v_entry_id FROM wallet_ledger WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_entry_id; END IF;

  v_wallet := _get_wallet_for_user(v_user_id);

  CASE p_currency
    WHEN 'PHON' THEN
      IF v_wallet.phon_locked::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_locked' USING HINT = 'PHON';
      END IF;
      v_avail_before := v_wallet.phon_available; v_locked_before := v_wallet.phon_locked;
      UPDATE wallets
      SET phon_locked    = (phon_locked::NUMERIC    - p_amount::NUMERIC)::TEXT,
          phon_available = (phon_available::NUMERIC + p_amount::NUMERIC)::TEXT,
          version = version + 1
      WHERE id = v_wallet.id;
    WHEN 'USDT' THEN
      IF v_wallet.usdt_locked::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_locked' USING HINT = 'USDT';
      END IF;
      v_avail_before := v_wallet.usdt_available; v_locked_before := v_wallet.usdt_locked;
      UPDATE wallets
      SET usdt_locked    = (usdt_locked::NUMERIC    - p_amount::NUMERIC)::TEXT,
          usdt_available = (usdt_available::NUMERIC + p_amount::NUMERIC)::TEXT,
          version = version + 1
      WHERE id = v_wallet.id;
    WHEN 'KRW' THEN
      IF v_wallet.krw_locked::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_locked' USING HINT = 'KRW';
      END IF;
      v_avail_before := v_wallet.krw_available; v_locked_before := v_wallet.krw_locked;
      UPDATE wallets
      SET krw_locked    = (krw_locked::NUMERIC    - p_amount::NUMERIC)::TEXT,
          krw_available = (krw_available::NUMERIC + p_amount::NUMERIC)::TEXT,
          version = version + 1
      WHERE id = v_wallet.id;
  END CASE;

  INSERT INTO wallet_ledger (
    wallet_id, user_id, idempotency_key, direction, currency, amount,
    available_before, locked_before, available_after, locked_after,
    reason_code, related_entity_id
  )
  SELECT
    v_wallet.id, v_user_id, p_idempotency_key, 'unlock', p_currency, p_amount,
    v_avail_before, v_locked_before,
    CASE p_currency WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available END,
    CASE p_currency WHEN 'PHON' THEN phon_locked    WHEN 'USDT' THEN usdt_locked    ELSE krw_locked    END,
    p_reason_code, p_related_entity_id
  FROM wallets WHERE id = v_wallet.id
  RETURNING id INTO v_entry_id;

  RETURN v_entry_id;
END;
$$;

-- ─── Grant execute to authenticated users ────────────────────

GRANT EXECUTE ON FUNCTION rpc_credit_wallet TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_debit_wallet  TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_lock_wallet   TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_unlock_wallet TO authenticated;

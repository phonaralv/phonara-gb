-- ============================================================
-- P1 (high-risk): Wallet-ledger hash-chain payload hardening (v2)
-- ============================================================
-- Why: the v1 chain hashed only (prev_hash | id | direction | currency |
-- amount | seq). That leaves the balance snapshots (available_after /
-- locked_after), the owning user_id, and the reason_code OUTSIDE the signed
-- payload. An attacker (or a buggy migration) able to UPDATE the ledger could
-- rewrite a row's balance snapshot or reason_code, or reassign a row to another
-- user_id, WITHOUT breaking verify_ledger_hash_chain().
--
-- v2 binds all of those into the SHA-256 payload:
--   prev_hash | id | user_id | direction | currency | amount |
--   available_after | locked_after | reason_code | seq
--
-- Implementation notes:
--  * A single IMMUTABLE helper `_wl_row_hash(...)` is the ONLY place the payload
--    is constructed, so the INSERT trigger, the verifier, and the one-time
--    backfill can never drift apart again.
--  * The helper is REVOKEd from PUBLIC/anon/authenticated (it is an internal
--    primitive; the SECURITY DEFINER trigger/verifier call it as owner).
--  * All existing rows are deterministically re-hashed under v2 so the verifier
--    is clean from this migration forward.
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Single source of truth for the row payload → SHA-256 hex digest
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _wl_row_hash(
  p_prev_hash       TEXT,
  p_id              UUID,
  p_user_id         UUID,
  p_direction       TEXT,
  p_currency        TEXT,
  p_amount          TEXT,
  p_available_after TEXT,
  p_locked_after    TEXT,
  p_reason_code     TEXT,
  p_seq             BIGINT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT encode(
    extensions.digest(
      coalesce(p_prev_hash, 'GENESIS')
        || '|' || p_id::TEXT
        || '|' || p_user_id::TEXT
        || '|' || p_direction
        || '|' || p_currency
        || '|' || p_amount
        || '|' || p_available_after
        || '|' || p_locked_after
        || '|' || p_reason_code
        || '|' || p_seq::TEXT,
      'sha256'
    ),
    'hex'
  );
$$;

REVOKE ALL ON FUNCTION
  _wl_row_hash(TEXT, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BIGINT)
  FROM PUBLIC, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. INSERT trigger now signs the v2 payload via the shared helper
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _wl_compute_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_prev_hash TEXT;
BEGIN
  SELECT row_hash INTO v_prev_hash
  FROM wallet_ledger
  WHERE user_id = NEW.user_id
    AND seq < NEW.seq
  ORDER BY seq DESC
  LIMIT 1;

  NEW.prev_hash := v_prev_hash;   -- NULL if first row for this user
  NEW.row_hash  := _wl_row_hash(
    v_prev_hash,
    NEW.id,
    NEW.user_id,
    NEW.direction::TEXT,
    NEW.currency::TEXT,
    NEW.amount,
    NEW.available_after,
    NEW.locked_after,
    NEW.reason_code,
    NEW.seq
  );
  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Verifier recomputes the v2 payload (same helper) and reports broken rows
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION verify_ledger_hash_chain(p_user_id UUID DEFAULT NULL)
RETURNS TABLE (
  broken_user_id UUID,
  entry_id       UUID,
  entry_seq      BIGINT,
  expected       TEXT,
  actual         TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r           wallet_ledger%ROWTYPE;
  v_last_user UUID := NULL;
  v_prev_hash TEXT := NULL;
  v_expected  TEXT;
BEGIN
  FOR r IN
    SELECT * FROM wallet_ledger
    WHERE (p_user_id IS NULL OR wallet_ledger.user_id = p_user_id)
    ORDER BY wallet_ledger.user_id, wallet_ledger.seq
  LOOP
    -- Reset chain when we cross into a new user's first row
    IF v_last_user IS NULL OR r.user_id <> v_last_user THEN
      v_prev_hash := NULL;
      v_last_user := r.user_id;
    END IF;

    v_expected := _wl_row_hash(
      v_prev_hash,
      r.id,
      r.user_id,
      r.direction::TEXT,
      r.currency::TEXT,
      r.amount,
      r.available_after,
      r.locked_after,
      r.reason_code,
      r.seq
    );

    -- Detect both tampered fields (hash mismatch) and a broken prev_hash link
    IF v_expected <> coalesce(r.row_hash, '')
       OR coalesce(r.prev_hash, '') <> coalesce(v_prev_hash, '') THEN
      broken_user_id := r.user_id;
      entry_id       := r.id;
      entry_seq      := r.seq;
      expected       := v_expected;
      actual         := r.row_hash;
      RETURN NEXT;
    END IF;

    v_prev_hash := r.row_hash;
  END LOOP;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. One-time deterministic re-hash of all existing rows under v2
-- ─────────────────────────────────────────────────────────────────────────────
-- The append-only RULE must be disabled for this controlled rewrite, then
-- re-enabled. The BEFORE-INSERT trigger does not fire on UPDATE, so the chain
-- is rebuilt purely from the helper below.
ALTER TABLE wallet_ledger DISABLE RULE wallet_ledger_no_update;
DO $$
DECLARE
  r           wallet_ledger%ROWTYPE;
  v_last_user UUID := NULL;
  v_prev_hash TEXT := NULL;
  v_hash      TEXT;
BEGIN
  FOR r IN SELECT * FROM wallet_ledger ORDER BY user_id, seq LOOP
    IF v_last_user IS NULL OR r.user_id <> v_last_user THEN
      v_prev_hash := NULL;
      v_last_user := r.user_id;
    END IF;

    v_hash := _wl_row_hash(
      v_prev_hash,
      r.id,
      r.user_id,
      r.direction::TEXT,
      r.currency::TEXT,
      r.amount,
      r.available_after,
      r.locked_after,
      r.reason_code,
      r.seq
    );

    UPDATE wallet_ledger SET prev_hash = v_prev_hash, row_hash = v_hash WHERE id = r.id;

    v_prev_hash := v_hash;
  END LOOP;
END;
$$;
ALTER TABLE wallet_ledger ENABLE RULE wallet_ledger_no_update;

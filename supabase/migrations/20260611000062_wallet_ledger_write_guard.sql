-- ============================================================
-- Wallet / wallet_ledger privileged write guard
-- ============================================================
-- Closes two privileged-write gaps:
--   1. service_role / privileged SQL could UPDATE wallet balances without a
--      matching wallet_ledger row;
--   2. privileged direct wallet_ledger INSERTs could bypass the wallet FOR UPDATE
--      serialization that the RPC path relies on, allowing hash-chain branches.
--
-- Authorized ledger writers must set a transaction-local GUC immediately before
-- mutating wallets / wallet_ledger:
--   PERFORM set_config('phonara.ledger_write', 'allowed', true);
-- The final `true` is mandatory: the allowance is LOCAL to the transaction.
-- ============================================================

SET search_path = public, pg_temp;

-- ── Stop immediately if a wallet hash-chain branch already exists ────────────
DO $$
DECLARE
  r RECORD;
BEGIN
  SELECT user_id, prev_hash, count(*) AS duplicate_count
    INTO r
    FROM wallet_ledger
   WHERE prev_hash IS NOT NULL
   GROUP BY user_id, prev_hash
  HAVING count(*) > 1
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'wallet_ledger_hash_branch_exists'
      USING DETAIL = format('user_id=%s prev_hash=%s count=%s', r.user_id, r.prev_hash, r.duplicate_count);
  END IF;

  SELECT user_id, count(*) AS duplicate_count
    INTO r
    FROM wallet_ledger
   WHERE prev_hash IS NULL
   GROUP BY user_id
  HAVING count(*) > 1
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'wallet_ledger_genesis_branch_exists'
      USING DETAIL = format('user_id=%s genesis_count=%s', r.user_id, r.duplicate_count);
  END IF;
END;
$$;

-- Non-genesis rows: one child per (user_id, prev_hash).
CREATE UNIQUE INDEX IF NOT EXISTS wallet_ledger_user_prev_hash_uidx
  ON wallet_ledger (user_id, prev_hash)
  WHERE prev_hash IS NOT NULL;

-- Genesis rows use prev_hash NULL, so regular UNIQUE would not protect them.
CREATE UNIQUE INDEX IF NOT EXISTS wallet_ledger_user_genesis_uidx
  ON wallet_ledger (user_id)
  WHERE prev_hash IS NULL;

-- ── Shared guard primitive ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _require_ledger_write_allowed()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_setting('phonara.ledger_write', true) IS DISTINCT FROM 'allowed' THEN
    RAISE EXCEPTION 'ledger_write_not_allowed';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _require_ledger_write_allowed() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _guard_wallet_balance_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.phon_available IS DISTINCT FROM NEW.phon_available
     OR OLD.phon_locked IS DISTINCT FROM NEW.phon_locked
     OR OLD.usdt_available IS DISTINCT FROM NEW.usdt_available
     OR OLD.usdt_locked IS DISTINCT FROM NEW.usdt_locked
     OR OLD.krw_available IS DISTINCT FROM NEW.krw_available
     OR OLD.krw_locked IS DISTINCT FROM NEW.krw_locked THEN
    PERFORM _require_ledger_write_allowed();
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION _guard_wallet_balance_update() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_00_wallets_balance_write_guard ON wallets;
CREATE TRIGGER trg_00_wallets_balance_write_guard
BEFORE UPDATE ON wallets
FOR EACH ROW
EXECUTE FUNCTION _guard_wallet_balance_update();

CREATE OR REPLACE FUNCTION _guard_wallet_ledger_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM _require_ledger_write_allowed();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION _guard_wallet_ledger_insert() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_00_wallet_ledger_insert_guard ON wallet_ledger;
CREATE TRIGGER trg_00_wallet_ledger_insert_guard
BEFORE INSERT ON wallet_ledger
FOR EACH ROW
EXECUTE FUNCTION _guard_wallet_ledger_insert();

-- ── Patch all wallet_ledger writers to set the LOCAL write allowance ─────────
DO $$
DECLARE
  v_sig TEXT;
  v_def TEXT;
  v_new TEXT;
  v_sigs TEXT[] := ARRAY[
    'public._credit_wallet_internal(uuid,currency,text,text,text)',
    'public._debit_wallet_internal(uuid,currency,text,text,text)',
    'public._lock_wallet_internal(uuid,currency,text,text,text)',
    'public._unlock_wallet_internal(uuid,currency,text,text,text)',
    'public._debit_locked_wallet_internal(uuid,currency,text,text,text,uuid,uuid)',
    'public.rpc_lock_wallet(currency,text,text,text,uuid)',
    'public.rpc_unlock_wallet(currency,text,text,text,uuid)'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_sigs LOOP
    IF to_regprocedure(v_sig) IS NULL THEN
      RAISE EXCEPTION 'ledger writer function missing: %', v_sig;
    END IF;

    v_def := pg_get_functiondef(v_sig::regprocedure);
    IF position('phonara.ledger_write' IN v_def) > 0 THEN
      CONTINUE;
    END IF;

    v_new := regexp_replace(
      v_def,
      '\mBEGIN\M',
      E'BEGIN\n  PERFORM set_config(''phonara.ledger_write'', ''allowed'', true);',
      ''
    );

    IF v_new = v_def THEN
      RAISE EXCEPTION 'could not inject ledger_write guard into %', v_sig;
    END IF;

    EXECUTE v_new;
  END LOOP;
END;
$$;

-- Preserve the existing lockdown posture after CREATE OR REPLACE.
REVOKE ALL ON FUNCTION _credit_wallet_internal(UUID, currency, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _debit_wallet_internal(UUID, currency, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _lock_wallet_internal(UUID, currency, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _unlock_wallet_internal(UUID, currency, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _debit_locked_wallet_internal(UUID, currency, TEXT, TEXT, TEXT, UUID, UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION rpc_lock_wallet(currency, TEXT, TEXT, TEXT, UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION rpc_unlock_wallet(currency, TEXT, TEXT, TEXT, UUID)
  FROM PUBLIC, anon, authenticated;

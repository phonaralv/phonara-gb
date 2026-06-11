-- ============================================================
-- Wallet / system internal helper positive amount guards
-- ============================================================
-- Internal balance mutators are not client-facing, but they are still privileged
-- money movement primitives. Reject non-canonical, zero, and negative amounts at
-- the helper boundary before any wallet/system arithmetic or idempotency return.
-- ============================================================

SET search_path = public, pg_temp;

DO $$
DECLARE
  v_sig TEXT;
  v_def TEXT;
  v_new TEXT;
  v_guard TEXT := E'BEGIN\n  IF p_amount IS NULL OR p_amount !~ ''^\\d+(\\.\\d+)?$'' OR p_amount::NUMERIC <= 0 THEN\n    RAISE EXCEPTION ''invalid_amount'';\n  END IF;';
  v_sigs TEXT[] := ARRAY[
    'public._debit_wallet_internal(uuid,currency,text,text,text)',
    'public._credit_wallet_internal(uuid,currency,text,text,text)',
    'public._lock_wallet_internal(uuid,currency,text,text,text)',
    'public._unlock_wallet_internal(uuid,currency,text,text,text)',
    'public._debit_locked_wallet_internal(uuid,currency,text,text,text,uuid,uuid)',
    'public._credit_system_account(text,text,text,uuid,text,uuid)',
    'public._debit_system_account(text,text,text,uuid,text,uuid)'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_sigs LOOP
    IF to_regprocedure(v_sig) IS NULL THEN
      RAISE EXCEPTION 'internal amount helper missing: %', v_sig;
    END IF;

    v_def := pg_get_functiondef(v_sig::regprocedure);
    IF position('p_amount::NUMERIC <= 0' IN v_def) > 0 THEN
      CONTINUE;
    END IF;

    v_new := regexp_replace(v_def, '\mBEGIN\M', v_guard, '');

    IF v_new = v_def THEN
      RAISE EXCEPTION 'could not inject amount guard into %', v_sig;
    END IF;

    EXECUTE v_new;
  END LOOP;
END
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
REVOKE ALL ON FUNCTION _credit_system_account(TEXT, TEXT, TEXT, UUID, TEXT, UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _debit_system_account(TEXT, TEXT, TEXT, UUID, TEXT, UUID)
  FROM PUBLIC, anon, authenticated;

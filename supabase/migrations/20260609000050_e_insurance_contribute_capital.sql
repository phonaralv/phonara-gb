-- ============================================================
-- Group E E1-a — operator capital contribution to insurance fund
-- ============================================================
-- Local-only until Wave 12. No remote apply in this change.
--
-- Adds:
--   * operator_contributed_capital_{phon,usdt} system accounts
--   * rpc_contribute_insurance_capital(...)
--
-- The RPC moves value system-account to system-account only:
--   operator_contributed_capital_<ccy> debit
--   insurance_fund_<ccy> credit
-- Same amount, same transfer_id, same currency => Σ=0.
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Operator contribution source accounts (PHON/USDT only)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO system_accounts (code, currency, description) VALUES
  ('operator_contributed_capital_phon', 'PHON',
   'Operator capital injection source for insurance (may go negative)'),
  ('operator_contributed_capital_usdt', 'USDT',
   'Operator capital injection source for insurance (may go negative)')
ON CONFLICT (code) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Admin RPC: contribute operator capital into insurance
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_contribute_insurance_capital(
  p_currency              TEXT,
  p_amount                TEXT,
  p_reason                TEXT,
  p_idempotency_key       TEXT,
  p_confirm_large_change  BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_ccy currency;
  v_ccy_text TEXT;
  v_amount TEXT;
  v_amount_num NUMERIC;
  v_ins_account TEXT;
  v_operator_account TEXT;
  v_ins_balance_num NUMERIC;
  v_ins_balance TEXT;
  v_operator_balance TEXT;
  v_alert_pct NUMERIC;
  v_delta_pct NUMERIC;
  v_transfer_id UUID;
  v_existing_amount TEXT;
BEGIN
  IF NOT _is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) < 8 THEN
    RAISE EXCEPTION 'invalid_idempotency_key';
  END IF;

  BEGIN
    v_ccy := upper(p_currency)::currency;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_currency';
  END;

  IF v_ccy IS NULL OR v_ccy NOT IN ('PHON'::currency, 'USDT'::currency) THEN
    RAISE EXCEPTION 'invalid_currency';
  END IF;

  IF p_amount IS NULL OR p_amount !~ '^\d+(\.\d+)?$' THEN
    RAISE EXCEPTION 'invalid_amount';
  END IF;

  v_amount_num := p_amount::NUMERIC;
  v_amount := _fmt6(v_amount_num);

  IF v_amount_num <= 0 OR v_amount::NUMERIC <= 0 THEN
    RAISE EXCEPTION 'invalid_amount';
  END IF;

  v_ccy_text := lower(v_ccy::TEXT);
  v_ins_account := 'insurance_fund_' || v_ccy_text;
  v_operator_account := 'operator_contributed_capital_' || v_ccy_text;

  -- Idempotency is anchored on the insurance credit leg; each successful
  -- contribution creates exactly one such row for the caller-provided key.
  SELECT transfer_id, amount
    INTO v_transfer_id, v_existing_amount
    FROM system_account_ledger
   WHERE account_code = v_ins_account
     AND direction = 'credit'
     AND reason_code = 'insurance_capital_contribution'
     AND related_tx_id = p_idempotency_key
   ORDER BY seq DESC
   LIMIT 1;

  IF FOUND THEN
    SELECT balance INTO v_ins_balance
      FROM system_accounts
     WHERE code = v_ins_account;
    SELECT balance INTO v_operator_balance
      FROM system_accounts
     WHERE code = v_operator_account;

    RETURN jsonb_build_object(
      'ok', TRUE,
      'idempotent', TRUE,
      'currency', v_ccy::TEXT,
      'amount', v_existing_amount,
      'transfer_id', v_transfer_id,
      'insurance_balance', v_ins_balance,
      'operator_contributed_balance', v_operator_balance
    );
  END IF;

  -- Mirror treasury's large-change guard: only compute a percentage when the
  -- current balance is positive. Insurance accounts may legitimately be <= 0.
  SELECT balance::NUMERIC
    INTO v_ins_balance_num
    FROM system_accounts
   WHERE code = v_ins_account
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'system_account_not_found' USING HINT = v_ins_account;
  END IF;

  SELECT COALESCE((SELECT value::NUMERIC FROM app_config WHERE key = 'attested_change_alert_pct'), 10)
    INTO v_alert_pct;

  IF v_ins_balance_num > 0 THEN
    v_delta_pct := v_amount::NUMERIC / v_ins_balance_num * 100.0;
    IF v_delta_pct > v_alert_pct AND NOT p_confirm_large_change THEN
      RAISE EXCEPTION 'attested_change_requires_confirm'
        USING DETAIL = 'delta_pct=' || round(v_delta_pct, 2)::TEXT
          || ' threshold=' || round(v_alert_pct, 2)::TEXT;
    END IF;
  END IF;

  v_transfer_id := gen_random_uuid();

  PERFORM _debit_system_account(
    v_operator_account,
    v_amount,
    'insurance_capital_contribution',
    v_actor,
    p_idempotency_key,
    v_transfer_id
  );

  PERFORM _credit_system_account(
    v_ins_account,
    v_amount,
    'insurance_capital_contribution',
    v_actor,
    p_idempotency_key,
    v_transfer_id
  );

  SELECT balance INTO v_ins_balance
    FROM system_accounts
   WHERE code = v_ins_account;
  SELECT balance INTO v_operator_balance
    FROM system_accounts
   WHERE code = v_operator_account;

  INSERT INTO audit_logs (actor_id, action, entity_type, payload)
  VALUES (
    v_actor,
    'insurance_capital_contribution',
    'system_accounts',
    jsonb_build_object(
      'currency', v_ccy::TEXT,
      'amount', v_amount,
      'reason', p_reason,
      'idempotency_key', p_idempotency_key,
      'transfer_id', v_transfer_id,
      'confirm_large_change', p_confirm_large_change,
      'insurance_account', v_ins_account,
      'operator_account', v_operator_account
    )
  );

  RETURN jsonb_build_object(
    'ok', TRUE,
    'idempotent', FALSE,
    'currency', v_ccy::TEXT,
    'amount', v_amount,
    'transfer_id', v_transfer_id,
    'insurance_balance', v_ins_balance,
    'operator_contributed_balance', v_operator_balance
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_contribute_insurance_capital(TEXT, TEXT, TEXT, TEXT, BOOLEAN)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_contribute_insurance_capital(TEXT, TEXT, TEXT, TEXT, BOOLEAN)
  TO authenticated, service_role;

-- ============================================================
-- PART B — KRW deposit must have an active PHON/KRW rate
-- ============================================================
-- Local-only until Wave 12. No remote apply in this change.
--
-- Fixes the 0 PHON credit gap:
--   old path: no active PHON/KRW rate -> expected_phon NULL -> credit path
--             COALESCE(expected_phon, '0.000000') -> user receives 0 PHON.
--   new path: no active positive PHON/KRW rate -> request is rejected before any
--             krw_deposit_requests row is created.
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_create_krw_deposit_request(
  p_amount_krw TEXT,
  p_client_request_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_wallet  wallets%ROWTYPE;
  v_ref     TEXT;
  v_rate_id UUID;
  v_phon    TEXT;
  v_dep_id  UUID;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;

  PERFORM _assert_system_live();
  PERFORM _assert_feature_enabled('deposit');
  PERFORM _assert_account_activity_live(v_user_id);
  PERFORM _assert_onboarding_consent(v_user_id);

  IF p_amount_krw !~ '^\d+(\.\d+)?$' OR p_amount_krw::NUMERIC <= 0 THEN
    RAISE EXCEPTION 'invalid_amount';
  END IF;

  IF p_client_request_id IS NOT NULL AND length(btrim(p_client_request_id)) > 0 THEN
    INSERT INTO rpc_request_idem (user_id, client_request_id, rpc_name)
    VALUES (v_user_id, p_client_request_id, 'rpc_create_krw_deposit_request')
    ON CONFLICT (user_id, client_request_id) DO NOTHING;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'duplicate_request';
    END IF;
  END IF;

  SELECT id INTO v_wallet FROM wallets WHERE user_id = v_user_id;

  SELECT id, _fmt6((p_amount_krw::NUMERIC / rate::NUMERIC))
    INTO v_rate_id, v_phon
    FROM exchange_rate_snapshots
   WHERE base_currency = 'PHON'
     AND quote_currency = 'KRW'
     AND is_active = TRUE
     AND rate::NUMERIC > 0
   ORDER BY captured_at DESC
   LIMIT 1;

  IF v_rate_id IS NULL OR v_phon IS NULL OR v_phon::NUMERIC <= 0 THEN
    RAISE EXCEPTION 'phon_krw_rate_unavailable';
  END IF;

  v_ref := upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 10));

  INSERT INTO krw_deposit_requests (
    user_id, wallet_id, reference_code, amount_krw, expected_phon, rate_snapshot_id
  ) VALUES (
    v_user_id, v_wallet.id, v_ref, p_amount_krw, v_phon, v_rate_id
  ) RETURNING id INTO v_dep_id;

  RETURN jsonb_build_object(
    'ok', TRUE,
    'deposit_id', v_dep_id,
    'reference_code', v_ref,
    'expected_phon', v_phon,
    'sla_hours', (SELECT value FROM app_config WHERE key = 'deposit_exception_sla_hours')
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_create_krw_deposit_request(TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_create_krw_deposit_request(TEXT, TEXT)
  TO authenticated;

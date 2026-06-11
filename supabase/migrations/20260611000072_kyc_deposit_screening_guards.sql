-- ============================================================
-- KYC/deposit sanctions screening guards
-- ============================================================
-- KYC submission must not fail-closed for brand-new users without a screening
-- row. Instead it queues a pending screening. Deposit requests require an
-- already-clear screening, matching the withdrawal gate.
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION _ensure_kyc_sanctions_screening_pending(
  p_user_id UUID,
  p_trigger TEXT DEFAULT 'kyc_submission'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_screening sanctions_screenings%ROWTYPE;
  v_sla_hours INT;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  SELECT * INTO v_screening
    FROM sanctions_screenings
   WHERE user_id = p_user_id
   ORDER BY screened_at DESC
   LIMIT 1;

  IF FOUND AND v_screening.status = 'hit' THEN
    RAISE EXCEPTION 'sanctions_blocked';
  END IF;

  IF FOUND AND v_screening.status = 'clear' THEN
    RETURN;
  END IF;

  IF NOT FOUND THEN
    INSERT INTO sanctions_screenings (user_id, status, screened_at, source, details)
    VALUES (
      p_user_id,
      'pending',
      NOW(),
      p_trigger,
      jsonb_build_object('trigger', p_trigger)
    )
    RETURNING * INTO v_screening;
  END IF;

  SELECT COALESCE(value::INT, 24) INTO v_sla_hours
    FROM app_config WHERE key = 'deposit_exception_sla_hours';

  INSERT INTO admin_review_queue (
    queue_type,
    entity_type,
    entity_id,
    user_id,
    reason,
    sla_due_at,
    payload
  )
  SELECT
    'sanctions_screening',
    'sanctions_screening',
    v_screening.id,
    p_user_id,
    p_trigger,
    NOW() + (v_sla_hours || ' hours')::INTERVAL,
    jsonb_build_object('trigger', p_trigger, 'screening_status', v_screening.status)
  WHERE NOT EXISTS (
    SELECT 1
      FROM admin_review_queue
     WHERE queue_type = 'sanctions_screening'
       AND entity_type = 'sanctions_screening'
       AND entity_id = v_screening.id
       AND status IN ('pending', 'in_review')
  );
END;
$$;

REVOKE ALL ON FUNCTION _ensure_kyc_sanctions_screening_pending(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION rpc_submit_kyc(
  p_payload JSONB,
  p_idempotency_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_submission kyc_submissions%ROWTYPE;
  v_legal_name TEXT := btrim(COALESCE(p_payload->>'legal_name', ''));
  v_document_type TEXT := btrim(COALESCE(p_payload->>'document_type', ''));
  v_document_last4 TEXT := upper(btrim(COALESCE(p_payload->>'document_last4', '')));
  v_country TEXT := upper(btrim(COALESCE(p_payload->>'country', '')));
  v_sla_hours NUMERIC := _app_config_numeric('kyc_review_sla_hours', 24);
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) < 8 THEN
    RAISE EXCEPTION 'invalid_idempotency_key';
  END IF;
  IF length(v_legal_name) < 2 THEN RAISE EXCEPTION 'invalid_kyc_legal_name'; END IF;
  IF v_document_type NOT IN ('id_card', 'passport', 'driver_license') THEN
    RAISE EXCEPTION 'invalid_kyc_document_type';
  END IF;
  IF v_document_last4 !~ '^[A-Z0-9]{4}$' THEN RAISE EXCEPTION 'invalid_kyc_document_last4'; END IF;
  IF v_country !~ '^[A-Z]{2}$' THEN RAISE EXCEPTION 'invalid_kyc_country'; END IF;

  PERFORM _ensure_kyc_sanctions_screening_pending(v_uid, 'kyc_submission');

  SELECT * INTO v_submission
    FROM kyc_submissions
   WHERE user_id = v_uid
     AND status IN ('submitted', 'reviewing', 'approved')
   ORDER BY created_at DESC
   LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', TRUE,
      'submission_id', v_submission.id,
      'status', v_submission.status,
      'idempotent', TRUE
    );
  END IF;

  INSERT INTO kyc_submissions (
    user_id, legal_name, document_type, document_last4, country, idempotency_key
  )
  VALUES (
    v_uid, v_legal_name, v_document_type, v_document_last4, v_country, btrim(p_idempotency_key)
  )
  RETURNING * INTO v_submission;

  INSERT INTO admin_review_queue (
    queue_type, entity_type, entity_id, user_id, reason, sla_due_at, payload
  )
  VALUES (
    'kyc_review',
    'kyc_submission',
    v_submission.id,
    v_uid,
    'kyc_submitted',
    NOW() + make_interval(hours => v_sla_hours::INT),
    jsonb_build_object(
      'legal_name_masked', _mask_kyc_name(v_legal_name),
      'document_type', v_document_type,
      'document_last4_masked', '****',
      'country', v_country
    )
  );

  RETURN jsonb_build_object('ok', TRUE, 'submission_id', v_submission.id, 'status', v_submission.status);
END;
$$;

REVOKE ALL ON FUNCTION rpc_submit_kyc(JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_submit_kyc(JSONB, TEXT) TO authenticated;

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
  PERFORM _assert_sanctions_screening(v_user_id);

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

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;

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

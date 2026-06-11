-- ============================================================
-- Migration: 20260609000037_s1_kyc_submission_flow
-- W9-R3: KYC submission queue + admin state machine.
-- ============================================================

SET search_path = public, pg_temp;

INSERT INTO app_config (key, value, description) VALUES
  ('kyc_review_sla_hours', '24', 'SLA hours for first KYC submission review.')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS kyc_submissions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status            TEXT NOT NULL DEFAULT 'submitted'
    CONSTRAINT kyc_submissions_status_chk CHECK (status IN ('submitted', 'reviewing', 'approved', 'rejected')),
  legal_name        TEXT NOT NULL,
  document_type     TEXT NOT NULL
    CONSTRAINT kyc_submissions_doc_type_chk CHECK (document_type IN ('id_card', 'passport', 'driver_license')),
  document_last4    TEXT NOT NULL
    CONSTRAINT kyc_submissions_last4_chk CHECK (document_last4 ~ '^[A-Za-z0-9]{4}$'),
  country           TEXT NOT NULL
    CONSTRAINT kyc_submissions_country_chk CHECK (country ~ '^[A-Z]{2}$'),
  idempotency_key   TEXT NOT NULL,
  submitted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at       TIMESTAMPTZ,
  reviewed_by       UUID REFERENCES profiles(id),
  rejection_reason  TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT kyc_submissions_user_idem UNIQUE (user_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS kyc_submissions_user_status_idx
  ON kyc_submissions (user_id, status, created_at DESC);

ALTER TABLE kyc_submissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own read kyc_submissions" ON kyc_submissions;
CREATE POLICY "own read kyc_submissions" ON kyc_submissions
  FOR SELECT USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "admin rw kyc_submissions" ON kyc_submissions;
CREATE POLICY "admin rw kyc_submissions" ON kyc_submissions
  FOR ALL USING (_is_admin());

DROP TRIGGER IF EXISTS kyc_submissions_updated_at ON kyc_submissions;
CREATE TRIGGER kyc_submissions_updated_at
  BEFORE UPDATE ON kyc_submissions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE FUNCTION _mask_kyc_name(p_name TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN length(btrim(COALESCE(p_name, ''))) <= 1 THEN '*'
    ELSE left(btrim(p_name), 1) || repeat('*', greatest(length(btrim(p_name)) - 1, 1))
  END;
$$;

REVOKE ALL ON FUNCTION _mask_kyc_name(TEXT) FROM PUBLIC, anon, authenticated;

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

CREATE OR REPLACE FUNCTION rpc_review_kyc_submission(
  p_submission_id UUID,
  p_status TEXT,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_submission kyc_submissions%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN RAISE EXCEPTION 'reason_required'; END IF;
  IF p_status NOT IN ('reviewing', 'approved', 'rejected') THEN RAISE EXCEPTION 'invalid_kyc_status'; END IF;

  SELECT * INTO v_submission FROM kyc_submissions WHERE id = p_submission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'kyc_submission_not_found'; END IF;

  IF v_submission.status IN ('approved', 'rejected') THEN
    RETURN jsonb_build_object('ok', TRUE, 'submission_id', p_submission_id, 'status', v_submission.status, 'idempotent', TRUE);
  END IF;

  UPDATE kyc_submissions
     SET status = p_status,
         reviewed_at = CASE WHEN p_status IN ('approved', 'rejected') THEN NOW() ELSE reviewed_at END,
         reviewed_by = CASE WHEN p_status IN ('approved', 'rejected') THEN v_actor ELSE reviewed_by END,
         rejection_reason = CASE WHEN p_status = 'rejected' THEN btrim(p_reason) ELSE NULL END
   WHERE id = p_submission_id
   RETURNING * INTO v_submission;

  IF p_status = 'approved' THEN
    UPDATE profiles
       SET kyc_tier = 'id_verified',
           legal_name = v_submission.legal_name
     WHERE id = v_submission.user_id;
  END IF;

  UPDATE admin_review_queue
     SET status = CASE WHEN p_status = 'reviewing' THEN 'in_review' ELSE 'resolved' END,
         resolved_at = CASE WHEN p_status = 'reviewing' THEN resolved_at ELSE NOW() END,
         resolved_by = CASE WHEN p_status = 'reviewing' THEN resolved_by ELSE v_actor END
   WHERE entity_type = 'kyc_submission'
     AND entity_id = p_submission_id
     AND status IN ('pending', 'in_review');

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    v_actor,
    'kyc_submission_' || p_status,
    'kyc_submission',
    p_submission_id,
    jsonb_build_object(
      'reason', p_reason,
      'user_id', v_submission.user_id,
      'status', p_status
    )
  );

  RETURN jsonb_build_object('ok', TRUE, 'submission_id', p_submission_id, 'status', p_status);
END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_submit_kyc(JSONB, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION rpc_review_kyc_submission(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_submit_kyc(JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_review_kyc_submission(UUID, TEXT, TEXT) TO authenticated;

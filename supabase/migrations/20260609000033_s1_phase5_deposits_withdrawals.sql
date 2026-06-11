-- ============================================================
-- Migration: 20260609000033_s1_phase5_deposits_withdrawals
-- Wave 9.1: KYC/sanctions/solvency gates, KRW reconciliation, withdrawal RPC
-- ============================================================
-- RED-first: gate neg tests in phase5_gates_test.sql must GREEN before GRANT.
-- GRANT on user-facing RPCs is at the END of this file.
-- ============================================================

SET search_path = public, pg_temp;

-- Conservation counterparty for KRW→PHON deposit credits (Σ=0 per PHON leg).
INSERT INTO system_accounts (code, currency, description) VALUES
  ('deposit_conversion_phon', 'PHON',
   'Counterparty for KRW deposit PHON credits. Negative balance = PHON issued against fiat deposits.')
ON CONFLICT (code) DO NOTHING;

-- ─── Config keys (Phase 5 screening + SLA) ─────────────────────────────────────
INSERT INTO app_config (key, value, description) VALUES
  ('screening_withdrawal_max_age_hours', '24',
   'Max age of last clear sanctions screening for withdrawal.'),
  ('screening_deposit_single_krw_threshold', '5000000',
   'Single KRW deposit amount triggering enhanced screening (KRW won).'),
  ('screening_deposit_rolling_krw_threshold', '10000000',
   'Rolling cumulative KRW deposit threshold (anti-structuring).'),
  ('screening_deposit_rolling_days', '7', 'Rolling window days for deposit screening.'),
  ('screening_deposit_count_threshold', '5',
   'Deposit count in rolling window triggering screening.'),
  ('attested_change_alert_pct', '10',
   'Treasury attested balance change pct requiring dual confirm.'),
  ('deposit_exception_sla_hours', '24',
   'SLA hours for admin exception queue items (user-facing estimate).'),
  ('str_withdrawal_krw_threshold', '5000000', 'STR auto-open threshold for withdrawals (KRW).')
ON CONFLICT (key) DO NOTHING;

-- ─── Profile extensions ───────────────────────────────────────────────────────
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS legal_name TEXT,
  ADD COLUMN IF NOT EXISTS activity_frozen BOOLEAN NOT NULL DEFAULT FALSE;

-- ─── Enums / deposit status extensions ───────────────────────────────────────
ALTER TYPE deposit_status ADD VALUE IF NOT EXISTS 'unmatched';
ALTER TYPE deposit_status ADD VALUE IF NOT EXISTS 'disputed';
ALTER TYPE deposit_status ADD VALUE IF NOT EXISTS 'admin_rejected';

-- ─── sanctions_screenings ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sanctions_screenings (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status       TEXT NOT NULL DEFAULT 'pending'
    CONSTRAINT ss_status_chk CHECK (status IN ('pending', 'clear', 'hit')),
  screened_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  source       TEXT NOT NULL DEFAULT 'internal',
  details      JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ss_user_screened_idx
  ON sanctions_screenings (user_id, screened_at DESC);

ALTER TABLE sanctions_screenings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own read sanctions_screenings" ON sanctions_screenings;
CREATE POLICY "own read sanctions_screenings" ON sanctions_screenings
  FOR SELECT USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "admin rw sanctions_screenings" ON sanctions_screenings;
CREATE POLICY "admin rw sanctions_screenings" ON sanctions_screenings
  FOR ALL USING (_is_admin());

-- ─── risk_flags ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS risk_flags (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  flag_type   TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'active'
    CONSTRAINT rf_status_chk CHECK (status IN ('active', 'cleared')),
  details     JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  cleared_at  TIMESTAMPTZ,
  cleared_by  UUID REFERENCES profiles(id)
);

CREATE INDEX IF NOT EXISTS risk_flags_user_active_idx
  ON risk_flags (user_id) WHERE status = 'active';

ALTER TABLE risk_flags ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin rw risk_flags" ON risk_flags;
CREATE POLICY "admin rw risk_flags" ON risk_flags
  FOR ALL USING (_is_admin());

-- ─── str_cases ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS str_cases (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID REFERENCES profiles(id),
  case_type    TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'open'
    CONSTRAINT str_status_chk CHECK (status IN ('open', 'reviewing', 'filed', 'dismissed')),
  trigger_ref  TEXT,
  details      JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE str_cases ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin rw str_cases" ON str_cases;
CREATE POLICY "admin rw str_cases" ON str_cases
  FOR ALL USING (_is_admin());

-- ─── admin_review_queue ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_review_queue (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  queue_type    TEXT NOT NULL,
  entity_type   TEXT NOT NULL,
  entity_id     UUID NOT NULL,
  user_id       UUID REFERENCES profiles(id),
  status        TEXT NOT NULL DEFAULT 'pending'
    CONSTRAINT arq_status_chk CHECK (status IN ('pending', 'in_review', 'resolved')),
  reason        TEXT,
  sla_due_at    TIMESTAMPTZ NOT NULL,
  resolved_at   TIMESTAMPTZ,
  resolved_by   UUID REFERENCES profiles(id),
  payload       JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS arq_pending_sla_idx
  ON admin_review_queue (status, sla_due_at) WHERE status = 'pending';

ALTER TABLE admin_review_queue ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin rw admin_review_queue" ON admin_review_queue;
CREATE POLICY "admin rw admin_review_queue" ON admin_review_queue
  FOR ALL USING (_is_admin());

-- ─── bank_incoming_transfers (transfer_id UNIQUE = idempotency layer 1) ───────
CREATE TABLE IF NOT EXISTS bank_incoming_transfers (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id         TEXT NOT NULL UNIQUE,
  amount_krw          TEXT NOT NULL
    CONSTRAINT bit_amt_fmt CHECK (amount_krw ~ '^\d+(\.\d+)?$'),
  depositor_name      TEXT NOT NULL,
  reference_code      TEXT,
  received_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  matched_deposit_id  UUID REFERENCES krw_deposit_requests(id),
  reconciliation_job_id UUID,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS bit_reference_idx ON bank_incoming_transfers (reference_code);
CREATE INDEX IF NOT EXISTS bit_matched_deposit_idx ON bank_incoming_transfers (matched_deposit_id);

ALTER TABLE bank_incoming_transfers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin rw bank_incoming_transfers" ON bank_incoming_transfers;
CREATE POLICY "admin rw bank_incoming_transfers" ON bank_incoming_transfers
  FOR ALL USING (_is_admin());

-- ─── deposit_reconciliation_jobs ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS deposit_reconciliation_jobs (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source           TEXT NOT NULL DEFAULT 'manual_entry',
  status           TEXT NOT NULL DEFAULT 'completed',
  matched_count    INT NOT NULL DEFAULT 0,
  exception_count  INT NOT NULL DEFAULT 0,
  run_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  operator_id      UUID REFERENCES profiles(id),
  payload          JSONB
);

ALTER TABLE deposit_reconciliation_jobs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin rw deposit_reconciliation_jobs" ON deposit_reconciliation_jobs;
CREATE POLICY "admin rw deposit_reconciliation_jobs" ON deposit_reconciliation_jobs
  FOR ALL USING (_is_admin());

-- ─── withdrawal_requests ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS withdrawal_requests (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  wallet_id           UUID NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  currency            currency NOT NULL,
  amount              TEXT NOT NULL
    CONSTRAINT wr_amt_fmt CHECK (amount ~ '^\d+(\.\d+)?$'),
  destination         JSONB NOT NULL DEFAULT '{}',
  status              withdrawal_status NOT NULL DEFAULT 'pending',
  idempotency_key     TEXT NOT NULL,
  client_request_id   TEXT,
  ledger_debit_id     UUID REFERENCES wallet_ledger(id),
  admin_note          TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT wr_user_idem UNIQUE (user_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS wr_user_status_idx ON withdrawal_requests (user_id, status);

ALTER TABLE withdrawal_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own read withdrawal_requests" ON withdrawal_requests;
CREATE POLICY "own read withdrawal_requests" ON withdrawal_requests
  FOR SELECT USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "admin rw withdrawal_requests" ON withdrawal_requests;
CREATE POLICY "admin rw withdrawal_requests" ON withdrawal_requests
  FOR ALL USING (_is_admin());

CREATE TRIGGER withdrawal_requests_updated_at
  BEFORE UPDATE ON withdrawal_requests
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── Helpers ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _normalize_person_name(p_name TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(regexp_replace(btrim(COALESCE(p_name, '')), '\s+', '', 'g'));
$$;

REVOKE ALL ON FUNCTION _normalize_person_name(TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _has_active_risk_flag(p_user_id UUID, p_flag_type TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM risk_flags
     WHERE user_id = p_user_id AND flag_type = p_flag_type AND status = 'active'
  );
$$;

REVOKE ALL ON FUNCTION _has_active_risk_flag(UUID, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _enqueue_admin_review(
  p_queue_type TEXT,
  p_entity_type TEXT,
  p_entity_id UUID,
  p_user_id UUID,
  p_reason TEXT,
  p_payload JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id UUID;
  v_sla_hours INT;
BEGIN
  SELECT COALESCE(value::INT, 24) INTO v_sla_hours
    FROM app_config WHERE key = 'deposit_exception_sla_hours';

  INSERT INTO admin_review_queue (
    queue_type, entity_type, entity_id, user_id, reason, sla_due_at, payload
  ) VALUES (
    p_queue_type, p_entity_type, p_entity_id, p_user_id, p_reason,
    NOW() + (v_sla_hours || ' hours')::INTERVAL,
    p_payload
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION _enqueue_admin_review(TEXT,TEXT,UUID,UUID,TEXT,JSONB)
  FROM PUBLIC, anon, authenticated;

-- Activity freeze: sanctions hit blocks all balance-moving user ops.
CREATE OR REPLACE FUNCTION _assert_account_activity_live(p_user_id UUID DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid UUID := COALESCE(p_user_id, auth.uid());
  v_frozen BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  SELECT activity_frozen INTO v_frozen FROM profiles WHERE id = v_uid;
  IF COALESCE(v_frozen, FALSE) THEN
    RAISE EXCEPTION 'account_activity_frozen';
  END IF;

  IF _has_active_risk_flag(v_uid, 'sanctions_pending') THEN
    RAISE EXCEPTION 'sanctions_pending';
  END IF;

  IF _has_active_risk_flag(v_uid, 'sanctions_hit')
     OR _has_active_risk_flag(v_uid, 'account_activity_frozen') THEN
    RAISE EXCEPTION 'account_activity_frozen';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_account_activity_live(UUID) FROM PUBLIC, anon, authenticated;

-- Apply sanctions hit side effects (internal).
CREATE OR REPLACE FUNCTION _apply_sanctions_hit(p_user_id UUID, p_details JSONB DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE profiles SET activity_frozen = TRUE WHERE id = p_user_id;

  INSERT INTO risk_flags (user_id, flag_type, details)
  SELECT p_user_id, 'sanctions_hit', p_details
   WHERE NOT EXISTS (
     SELECT 1 FROM risk_flags
      WHERE user_id = p_user_id AND flag_type = 'sanctions_hit' AND status = 'active'
   );

  INSERT INTO risk_flags (user_id, flag_type, details)
  SELECT p_user_id, 'account_activity_frozen', p_details
   WHERE NOT EXISTS (
     SELECT 1 FROM risk_flags
      WHERE user_id = p_user_id AND flag_type = 'account_activity_frozen' AND status = 'active'
   );

  IF NOT EXISTS (
    SELECT 1 FROM str_cases
     WHERE user_id = p_user_id AND case_type = 'sanctions_hit' AND status IN ('open', 'reviewing')
  ) THEN
    INSERT INTO str_cases (user_id, case_type, trigger_ref, details)
    VALUES (p_user_id, 'sanctions_hit', 'sanctions_screening', p_details);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _apply_sanctions_hit(UUID, JSONB) FROM PUBLIC, anon, authenticated;

-- ─── Gate 1: KYC withdrawal ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _assert_kyc_withdrawal_gate(p_user_id UUID DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  UUID := COALESCE(p_user_id, auth.uid());
  v_tier kyc_tier;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;

  SELECT kyc_tier INTO v_tier FROM profiles WHERE id = v_uid;
  IF v_tier IS DISTINCT FROM 'id_verified'::kyc_tier THEN
    RAISE EXCEPTION 'kyc_insufficient';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_kyc_withdrawal_gate(UUID) FROM PUBLIC, anon, authenticated;

-- ─── Gate 2: Sanctions screening ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _assert_sanctions_screening(p_user_id UUID DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid       UUID := COALESCE(p_user_id, auth.uid());
  v_status    TEXT;
  v_screened  TIMESTAMPTZ;
  v_max_hours INT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;

  PERFORM _assert_account_activity_live(v_uid);

  SELECT status, screened_at INTO v_status, v_screened
    FROM sanctions_screenings
   WHERE user_id = v_uid
   ORDER BY screened_at DESC
   LIMIT 1;

  IF v_status = 'hit' THEN
    RAISE EXCEPTION 'sanctions_blocked';
  END IF;

  IF v_status = 'pending' THEN
    RAISE EXCEPTION 'sanctions_pending';
  END IF;

  SELECT COALESCE(value::INT, 24) INTO v_max_hours
    FROM app_config WHERE key = 'screening_withdrawal_max_age_hours';

  IF v_status IS DISTINCT FROM 'clear'
     OR v_screened IS NULL
     OR v_screened < NOW() - (v_max_hours || ' hours')::INTERVAL THEN
    RAISE EXCEPTION 'sanctions_stale';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_sanctions_screening(UUID) FROM PUBLIC, anon, authenticated;

-- ─── Gate 3: Solvency withdrawal (ADR-005 wrapper) ────────────────────────────
CREATE OR REPLACE FUNCTION _assert_solvency_withdrawal_gate(p_currency currency)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tr           treasury_reserves%ROWTYPE;
  v_user_total   NUMERIC;
  v_real         NUMERIC;
  v_max_oblig    NUMERIC;
  v_fresh_recon  BOOLEAN;
BEGIN
  PERFORM _assert_system_live();
  PERFORM _assert_feature_enabled('withdrawal');

  SELECT * INTO v_tr FROM treasury_reserves WHERE currency = p_currency;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'withdrawal_solvency_hold' USING HINT = 'no_treasury_row';
  END IF;

  v_real := v_tr.real_balance::NUMERIC;
  IF v_real <= 0 THEN
    RAISE EXCEPTION 'withdrawal_solvency_hold' USING HINT = 'treasury_unconfigured';
  END IF;

  -- Fresh reconciliation within 24h with is_match=true for this currency.
  SELECT EXISTS (
    SELECT 1 FROM reconciliation_log
     WHERE currency = p_currency
       AND is_match = TRUE
       AND run_at >= NOW() - INTERVAL '24 hours'
  ) INTO v_fresh_recon;

  IF NOT v_fresh_recon THEN
    RAISE EXCEPTION 'withdrawal_solvency_hold' USING HINT = 'stale_reconciliation';
  END IF;

  v_user_total := CASE p_currency
    WHEN 'PHON' THEN COALESCE((SELECT SUM(phon_available::NUMERIC + phon_locked::NUMERIC) FROM wallets), 0)
    WHEN 'USDT' THEN COALESCE((SELECT SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC) FROM wallets), 0)
    WHEN 'KRW'  THEN COALESCE((SELECT SUM(krw_available::NUMERIC  + krw_locked::NUMERIC)  FROM wallets), 0)
    ELSE 0
  END;

  -- Σ withdrawable ≤ attested × (1 − buffer_pct)
  v_max_oblig := v_real * (1.0 - v_tr.buffer_pct / 100.0);

  IF v_user_total > v_max_oblig THEN
    RAISE EXCEPTION 'withdrawal_solvency_hold'
      USING HINT = 'obligations_exceed_attested',
            DETAIL = format('user_total=%s max=%s currency=%s',
                            _fmt6(v_user_total), _fmt6(v_max_oblig), p_currency);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_solvency_withdrawal_gate(currency) FROM PUBLIC, anon, authenticated;

-- ─── Treasury update with audit + large-delta guard ───────────────────────────
DROP FUNCTION IF EXISTS rpc_update_treasury_reserve(TEXT, TEXT, NUMERIC, NUMERIC, TEXT);

CREATE OR REPLACE FUNCTION rpc_update_treasury_reserve(
  p_currency              TEXT,
  p_balance               TEXT,
  p_buffer_pct            NUMERIC DEFAULT NULL,
  p_cap_pct               NUMERIC DEFAULT NULL,
  p_notes                 TEXT    DEFAULT NULL,
  p_confirm_large_change  BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_ccy       currency;
  v_old       TEXT;
  v_old_num   NUMERIC;
  v_new_num   NUMERIC;
  v_pct       NUMERIC;
  v_alert_pct NUMERIC;
  v_delta_pct NUMERIC;
BEGIN
  IF NOT _is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  BEGIN v_ccy := p_currency::currency;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_currency';
  END;

  IF p_balance !~ '^\d+(\.\d+)?$' THEN
    RAISE EXCEPTION 'invalid_amount';
  END IF;

  SELECT real_balance INTO v_old FROM treasury_reserves WHERE currency = v_ccy;
  IF NOT FOUND THEN RAISE EXCEPTION 'currency_not_found'; END IF;

  v_old_num := v_old::NUMERIC;
  v_new_num := p_balance::NUMERIC;

  SELECT COALESCE(value::NUMERIC, 10) INTO v_alert_pct
    FROM app_config WHERE key = 'attested_change_alert_pct';

  IF v_old_num > 0 THEN
    v_delta_pct := ABS(v_new_num - v_old_num) / v_old_num * 100.0;
    IF v_delta_pct > v_alert_pct AND NOT p_confirm_large_change THEN
      RAISE EXCEPTION 'attested_change_requires_confirm'
        USING DETAIL = 'delta_pct=' || round(v_delta_pct, 2)::TEXT
          || ' threshold=' || round(v_alert_pct, 2)::TEXT;
    END IF;
  END IF;

  UPDATE treasury_reserves SET
    real_balance   = p_balance,
    buffer_pct     = COALESCE(p_buffer_pct, buffer_pct),
    payout_cap_pct = COALESCE(p_cap_pct, payout_cap_pct),
    updated_at     = NOW(),
    updated_by     = v_user_id,
    notes          = COALESCE(p_notes, notes)
  WHERE currency = v_ccy;

  INSERT INTO audit_logs (actor_id, action, entity_type, payload)
  VALUES (v_user_id, 'treasury_reserve_update', 'treasury_reserves',
    jsonb_build_object(
      'currency', p_currency,
      'old_balance', v_old,
      'new_balance', p_balance,
      'confirm_large_change', p_confirm_large_change,
      'notes', p_notes
    ));

  RETURN jsonb_build_object(
    'ok', TRUE,
    'currency', p_currency,
    'real_balance', p_balance
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_update_treasury_reserve(TEXT,TEXT,NUMERIC,NUMERIC,TEXT,BOOLEAN)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_update_treasury_reserve(TEXT,TEXT,NUMERIC,NUMERIC,TEXT,BOOLEAN)
  TO service_role;

-- ─── Name match: conservative — exact normalized only ─────────────────────────
CREATE OR REPLACE FUNCTION _depositor_name_matches(p_depositor TEXT, p_legal_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT _normalize_person_name(p_depositor) = _normalize_person_name(p_legal_name)
     AND length(_normalize_person_name(p_legal_name)) > 0;
$$;

REVOKE ALL ON FUNCTION _depositor_name_matches(TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- ─── Internal: credit KRW deposit → PHON (idempotent on transfer_id) ───────────
CREATE OR REPLACE FUNCTION _credit_krw_deposit_internal(
  p_deposit_id UUID,
  p_transfer_id TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dep       krw_deposit_requests%ROWTYPE;
  v_ledger_id UUID;
  v_idem      TEXT;
  v_phon      TEXT;
  v_rate_id   UUID;
BEGIN
  SELECT * INTO v_dep FROM krw_deposit_requests WHERE id = p_deposit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'deposit_not_found'; END IF;

  IF v_dep.status = 'credited' THEN
    SELECT id INTO v_ledger_id FROM wallet_ledger
     WHERE related_entity_id = p_deposit_id AND reason_code = 'krw_deposit_credit'
     LIMIT 1;
    RETURN v_ledger_id;
  END IF;

  PERFORM _assert_account_activity_live(v_dep.user_id);

  v_idem := 'krw_dep:' || p_transfer_id;

  SELECT id INTO v_ledger_id FROM wallet_ledger WHERE idempotency_key = v_idem;
  IF FOUND THEN
    UPDATE krw_deposit_requests
       SET status = 'credited', credited_at = COALESCE(credited_at, NOW()), matched_at = COALESCE(matched_at, NOW())
     WHERE id = p_deposit_id;
    RETURN v_ledger_id;
  END IF;

  v_phon := COALESCE(v_dep.expected_phon, '0.000000');
  v_rate_id := v_dep.rate_snapshot_id;

  v_ledger_id := _credit_wallet_internal(
    v_dep.user_id, 'PHON', v_phon, 'krw_deposit_credit', v_idem
  );

  PERFORM _debit_system_account(
    'deposit_conversion_phon', v_phon, 'krw_deposit_credit',
    v_dep.user_id, p_transfer_id, v_ledger_id
  );

  UPDATE krw_deposit_requests
     SET status = 'credited', credited_at = NOW(), matched_at = COALESCE(matched_at, NOW())
   WHERE id = p_deposit_id;

  RETURN v_ledger_id;
END;
$$;

REVOKE ALL ON FUNCTION _credit_krw_deposit_internal(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- ─── Match incoming transfer to deposit request ───────────────────────────────
CREATE OR REPLACE FUNCTION _try_match_krw_deposit(
  p_transfer_id TEXT,
  p_amount_krw TEXT,
  p_depositor_name TEXT,
  p_reference_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dep_id    UUID;
  v_dep       krw_deposit_requests%ROWTYPE;
  v_legal     TEXT;
  v_bit_id    UUID;
  v_job_id    UUID;
  v_ledger    UUID;
BEGIN
  -- Layer 1 idempotency: transfer_id UNIQUE prevents double processing.
  INSERT INTO bank_incoming_transfers (transfer_id, amount_krw, depositor_name, reference_code)
  VALUES (p_transfer_id, p_amount_krw, p_depositor_name, p_reference_code)
  RETURNING id INTO v_bit_id;

  SELECT id INTO v_dep_id
    FROM krw_deposit_requests
   WHERE reference_code = p_reference_code
     AND status = 'pending'
     AND expires_at > NOW()
   ORDER BY created_at ASC
   LIMIT 1;

  IF v_dep_id IS NULL THEN
    PERFORM _enqueue_admin_review(
      'deposit_exception', 'bank_incoming_transfers', v_bit_id, NULL,
      'reference_not_found',
      jsonb_build_object('transfer_id', p_transfer_id, 'reference_code', p_reference_code)
    );
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'reference_not_found', 'exception', TRUE);
  END IF;

  SELECT * INTO v_dep FROM krw_deposit_requests WHERE id = v_dep_id;

  IF v_dep.amount_krw IS DISTINCT FROM p_amount_krw THEN
    PERFORM _enqueue_admin_review(
      'deposit_exception', 'krw_deposit_requests', v_dep_id, v_dep.user_id,
      'amount_mismatch',
      jsonb_build_object('expected', v_dep.amount_krw, 'received', p_amount_krw, 'transfer_id', p_transfer_id)
    );
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'amount_mismatch', 'exception', TRUE);
  END IF;

  SELECT legal_name INTO v_legal FROM profiles WHERE id = v_dep.user_id;

  IF v_legal IS NULL OR NOT _depositor_name_matches(p_depositor_name, v_legal) THEN
    PERFORM _enqueue_admin_review(
      'deposit_exception', 'krw_deposit_requests', v_dep_id, v_dep.user_id,
      'depositor_name_mismatch',
      jsonb_build_object('depositor', p_depositor_name, 'legal_name', v_legal, 'transfer_id', p_transfer_id)
    );
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'depositor_name_mismatch', 'exception', TRUE);
  END IF;

  IF EXISTS (
    SELECT 1 FROM risk_flags
     WHERE user_id = v_dep.user_id AND status = 'active'
       AND flag_type IN ('sanctions_hit', 'sanctions_pending')
  ) OR EXISTS (SELECT 1 FROM profiles WHERE id = v_dep.user_id AND activity_frozen) THEN
    PERFORM _enqueue_admin_review(
      'deposit_exception', 'krw_deposit_requests', v_dep_id, v_dep.user_id,
      'sanctions_or_freeze',
      jsonb_build_object('transfer_id', p_transfer_id)
    );
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'sanctions_or_freeze', 'exception', TRUE);
  END IF;

  UPDATE bank_incoming_transfers SET matched_deposit_id = v_dep_id WHERE id = v_bit_id;
  UPDATE krw_deposit_requests SET status = 'matched', matched_at = NOW() WHERE id = v_dep_id;

  v_ledger := _credit_krw_deposit_internal(v_dep_id, p_transfer_id);

  INSERT INTO deposit_reconciliation_jobs (source, matched_count, exception_count, payload)
  VALUES ('manual_entry', 1, 0,
    jsonb_build_object('transfer_id', p_transfer_id, 'deposit_id', v_dep_id))
  RETURNING id INTO v_job_id;

  UPDATE bank_incoming_transfers SET reconciliation_job_id = v_job_id WHERE id = v_bit_id;

  RETURN jsonb_build_object(
    'ok', TRUE, 'deposit_id', v_dep_id, 'ledger_id', v_ledger, 'auto_matched', TRUE
  );

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'duplicate_transfer_id' USING HINT = p_transfer_id;
END;
$$;

REVOKE ALL ON FUNCTION _try_match_krw_deposit(TEXT,TEXT,TEXT,TEXT)
  FROM PUBLIC, anon, authenticated;

-- Service-role entry for reconciliation runner.
CREATE OR REPLACE FUNCTION rpc_process_bank_transfer(
  p_transfer_id TEXT,
  p_amount_krw TEXT,
  p_depositor_name TEXT,
  p_reference_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM _assert_feature_enabled('deposit');
  RETURN _try_match_krw_deposit(p_transfer_id, p_amount_krw, p_depositor_name, p_reference_code);
END;
$$;

REVOKE ALL ON FUNCTION rpc_process_bank_transfer(TEXT,TEXT,TEXT,TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_process_bank_transfer(TEXT,TEXT,TEXT,TEXT) TO service_role;

-- ─── User: create KRW deposit request ─────────────────────────────────────────
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

  v_ref := upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 10));

  SELECT id INTO v_rate_id
    FROM exchange_rate_snapshots
   WHERE base_currency = 'PHON' AND quote_currency = 'KRW' AND is_active = TRUE
   ORDER BY captured_at DESC LIMIT 1;

  IF v_rate_id IS NOT NULL THEN
    SELECT _fmt6((p_amount_krw::NUMERIC / NULLIF(rate::NUMERIC, 0))) INTO v_phon
      FROM exchange_rate_snapshots WHERE id = v_rate_id;
  END IF;

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

-- ─── User: request withdrawal ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_request_withdrawal(
  p_currency          TEXT,
  p_amount            TEXT,
  p_destination       JSONB,
  p_idempotency_key   TEXT,
  p_client_request_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ccy     currency;
  v_wallet  wallets%ROWTYPE;
  v_wr_id   UUID;
  v_ledger  UUID;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;

  PERFORM _assert_system_live();
  PERFORM _assert_feature_enabled('withdrawal');
  PERFORM _assert_account_activity_live(v_user_id);
  PERFORM _assert_onboarding_consent(v_user_id);

  BEGIN v_ccy := p_currency::currency;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_currency';
  END;

  PERFORM _assert_amount_text(p_amount);

  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) < 8 THEN
    RAISE EXCEPTION 'invalid_idempotency_key';
  END IF;

  -- Three withdrawal gates (RED-first tested).
  PERFORM _assert_kyc_withdrawal_gate(v_user_id);
  PERFORM _assert_sanctions_screening(v_user_id);
  PERFORM _assert_solvency_withdrawal_gate(v_ccy);

  SELECT id INTO v_wr_id FROM withdrawal_requests
   WHERE user_id = v_user_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', TRUE, 'withdrawal_id', v_wr_id, 'idempotent', TRUE);
  END IF;

  IF p_client_request_id IS NOT NULL AND length(btrim(p_client_request_id)) > 0 THEN
    INSERT INTO rpc_request_idem (user_id, client_request_id, rpc_name)
    VALUES (v_user_id, p_client_request_id, 'rpc_request_withdrawal')
    ON CONFLICT (user_id, client_request_id) DO NOTHING;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'duplicate_request';
    END IF;
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id FOR UPDATE;

  v_ledger := rpc_debit_wallet(
    v_ccy, p_amount, 'withdrawal_request',
    'wd_req:' || v_user_id::TEXT || ':' || p_idempotency_key,
    NULL, NULL
  );

  INSERT INTO withdrawal_requests (
    user_id, wallet_id, currency, amount, destination, status,
    idempotency_key, client_request_id, ledger_debit_id
  ) VALUES (
    v_user_id, v_wallet.id, v_ccy, p_amount, COALESCE(p_destination, '{}'::JSONB),
    'pending', p_idempotency_key, p_client_request_id, v_ledger
  ) RETURNING id INTO v_wr_id;

  RETURN jsonb_build_object('ok', TRUE, 'withdrawal_id', v_wr_id);
END;
$$;

-- ─── GRANT (last — after gate tests GREEN) ────────────────────────────────────
GRANT EXECUTE ON FUNCTION rpc_create_krw_deposit_request(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_request_withdrawal(TEXT, TEXT, JSONB, TEXT, TEXT) TO authenticated;

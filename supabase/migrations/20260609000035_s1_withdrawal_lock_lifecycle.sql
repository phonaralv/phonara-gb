-- ============================================================
-- Migration: 20260609000035_s1_withdrawal_lock_lifecycle
-- P0: withdrawal request lock model + admin approve/reject lifecycle.
-- ============================================================
-- Request no longer debits user available balance immediately. It locks funds
-- in the user's wallet. Reject unlocks them. Approve consumes locked funds and
-- records the system payout counter-leg so wallet+system conservation remains 0.
-- The global withdrawal kill switch remains OFF for operator re-enable only.
-- ============================================================

SET search_path = public, pg_temp;

ALTER TYPE withdrawal_status ADD VALUE IF NOT EXISTS 'sent';

INSERT INTO system_accounts (code, currency, description) VALUES
  ('withdrawal_payout_phon', 'PHON', 'Counterparty for approved PHON withdrawals. Positive balance tracks approved external payouts.'),
  ('withdrawal_payout_usdt', 'USDT', 'Counterparty for approved USDT withdrawals. Positive balance tracks approved external payouts.'),
  ('withdrawal_payout_krw',  'KRW',  'Counterparty for approved KRW withdrawals. Positive balance tracks approved external payouts.')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE withdrawal_requests
  ADD COLUMN IF NOT EXISTS ledger_lock_id UUID REFERENCES wallet_ledger(id),
  ADD COLUMN IF NOT EXISTS ledger_approve_debit_id UUID REFERENCES wallet_ledger(id),
  ADD COLUMN IF NOT EXISTS ledger_reject_unlock_id UUID REFERENCES wallet_ledger(id),
  ADD COLUMN IF NOT EXISTS system_payout_transfer_id UUID,
  ADD COLUMN IF NOT EXISTS approved_by UUID REFERENCES profiles(id),
  ADD COLUMN IF NOT EXISTS rejected_by UUID REFERENCES profiles(id),
  ADD COLUMN IF NOT EXISTS sent_by UUID REFERENCES profiles(id),
  ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS rejected_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS sent_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS wr_pending_idx
  ON withdrawal_requests (status, created_at)
  WHERE status = 'pending';

-- Internal helper: consume already-locked user funds without routing through
-- available balance. This is only used by guarded admin withdrawal approval.
CREATE OR REPLACE FUNCTION _debit_locked_wallet_internal(
  p_user_id UUID,
  p_currency currency,
  p_amount TEXT,
  p_reason_code TEXT,
  p_idempotency_key TEXT,
  p_related_entity_id UUID DEFAULT NULL,
  p_transfer_id UUID DEFAULT NULL
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

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_found'; END IF;

  CASE p_currency
    WHEN 'PHON' THEN
      IF v_wallet.phon_locked::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_locked' USING HINT = 'PHON';
      END IF;
      v_avail_before := v_wallet.phon_available;
      v_locked_before := v_wallet.phon_locked;
      UPDATE wallets
         SET phon_locked = (phon_locked::NUMERIC - p_amount::NUMERIC)::TEXT,
             version = version + 1
       WHERE id = v_wallet.id;
    WHEN 'USDT' THEN
      IF v_wallet.usdt_locked::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_locked' USING HINT = 'USDT';
      END IF;
      v_avail_before := v_wallet.usdt_available;
      v_locked_before := v_wallet.usdt_locked;
      UPDATE wallets
         SET usdt_locked = (usdt_locked::NUMERIC - p_amount::NUMERIC)::TEXT,
             version = version + 1
       WHERE id = v_wallet.id;
    WHEN 'KRW' THEN
      IF v_wallet.krw_locked::NUMERIC < p_amount::NUMERIC THEN
        RAISE EXCEPTION 'insufficient_locked' USING HINT = 'KRW';
      END IF;
      v_avail_before := v_wallet.krw_available;
      v_locked_before := v_wallet.krw_locked;
      UPDATE wallets
         SET krw_locked = (krw_locked::NUMERIC - p_amount::NUMERIC)::TEXT,
             version = version + 1
       WHERE id = v_wallet.id;
  END CASE;

  INSERT INTO wallet_ledger (
    wallet_id, user_id, idempotency_key, direction, currency, amount,
    available_before, locked_before, available_after, locked_after,
    reason_code, related_entity_id, transfer_id
  )
  SELECT
    v_wallet.id, p_user_id, p_idempotency_key, 'debit', p_currency, p_amount,
    v_avail_before, v_locked_before,
    CASE p_currency
      WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available
    END,
    CASE p_currency
      WHEN 'PHON' THEN phon_locked WHEN 'USDT' THEN usdt_locked ELSE krw_locked
    END,
    p_reason_code, p_related_entity_id, p_transfer_id
  FROM wallets WHERE id = v_wallet.id
  RETURNING id INTO v_entry_id;

  RETURN v_entry_id;
END;
$$;

REVOKE ALL ON FUNCTION _debit_locked_wallet_internal(UUID, currency, TEXT, TEXT, TEXT, UUID, UUID)
  FROM PUBLIC, anon, authenticated;

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
  v_lock_id UUID;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;

  PERFORM _assert_system_live();
  PERFORM _assert_feature_enabled('withdrawal');
  PERFORM _assert_account_activity_live(v_user_id);
  PERFORM _assert_onboarding_consent(v_user_id);

  BEGIN
    v_ccy := p_currency::currency;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_currency';
  END;

  PERFORM _assert_amount_text(p_amount);

  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) < 8 THEN
    RAISE EXCEPTION 'invalid_idempotency_key';
  END IF;

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

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_found'; END IF;

  v_wr_id := gen_random_uuid();
  v_lock_id := rpc_lock_wallet(
    v_ccy, p_amount, 'withdrawal_request_lock',
    'wd_lock:' || v_user_id::TEXT || ':' || p_idempotency_key,
    v_wr_id
  );

  INSERT INTO withdrawal_requests (
    id, user_id, wallet_id, currency, amount, destination, status,
    idempotency_key, client_request_id, ledger_lock_id
  ) VALUES (
    v_wr_id, v_user_id, v_wallet.id, v_ccy, p_amount, COALESCE(p_destination, '{}'::JSONB),
    'pending', p_idempotency_key, p_client_request_id, v_lock_id
  );

  RETURN jsonb_build_object('ok', TRUE, 'withdrawal_id', v_wr_id);
END;
$$;

CREATE OR REPLACE FUNCTION rpc_reject_withdrawal(
  p_withdrawal_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_req withdrawal_requests%ROWTYPE;
  v_ledger_id UUID;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'withdrawal_not_found'; END IF;

  IF v_req.status = 'rejected' THEN
    RETURN jsonb_build_object('ok', TRUE, 'withdrawal_id', p_withdrawal_id, 'idempotent', TRUE);
  END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'invalid_withdrawal_status';
  END IF;

  v_ledger_id := _unlock_wallet_internal(
    v_req.user_id, v_req.currency, v_req.amount,
    'withdrawal_reject_unlock', 'wd_reject_unlock:' || p_withdrawal_id::TEXT
  );

  UPDATE withdrawal_requests
     SET status = 'rejected',
         admin_note = p_reason,
         rejected_by = v_actor,
         rejected_at = NOW(),
         ledger_reject_unlock_id = v_ledger_id
   WHERE id = p_withdrawal_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    v_actor, 'withdrawal_rejected', 'withdrawal_request', p_withdrawal_id,
    jsonb_build_object('reason', p_reason, 'user_id', v_req.user_id, 'amount', v_req.amount, 'currency', v_req.currency)
  );

  RETURN jsonb_build_object('ok', TRUE, 'withdrawal_id', p_withdrawal_id, 'status', 'rejected');
END;
$$;

CREATE OR REPLACE FUNCTION rpc_approve_withdrawal(
  p_withdrawal_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_req withdrawal_requests%ROWTYPE;
  v_ledger_id UUID;
  v_transfer_id UUID := gen_random_uuid();
  v_payout_account TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'withdrawal_not_found'; END IF;

  IF v_req.status IN ('approved', 'sent') THEN
    RETURN jsonb_build_object('ok', TRUE, 'withdrawal_id', p_withdrawal_id, 'idempotent', TRUE);
  END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'invalid_withdrawal_status';
  END IF;

  v_payout_account := 'withdrawal_payout_' || lower(v_req.currency::TEXT);
  v_ledger_id := _debit_locked_wallet_internal(
    v_req.user_id, v_req.currency, v_req.amount,
    'withdrawal_approve_debit', 'wd_approve_debit:' || p_withdrawal_id::TEXT,
    p_withdrawal_id, v_transfer_id
  );

  PERFORM _credit_system_account(
    v_payout_account, v_req.amount, 'withdrawal_payout',
    v_req.user_id, p_withdrawal_id::TEXT, v_transfer_id
  );

  UPDATE withdrawal_requests
     SET status = 'approved',
         admin_note = p_reason,
         approved_by = v_actor,
         approved_at = NOW(),
         ledger_approve_debit_id = v_ledger_id,
         system_payout_transfer_id = v_transfer_id
   WHERE id = p_withdrawal_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    v_actor, 'withdrawal_approved', 'withdrawal_request', p_withdrawal_id,
    jsonb_build_object('reason', p_reason, 'user_id', v_req.user_id, 'amount', v_req.amount, 'currency', v_req.currency)
  );

  RETURN jsonb_build_object('ok', TRUE, 'withdrawal_id', p_withdrawal_id, 'status', 'approved');
END;
$$;

CREATE OR REPLACE FUNCTION rpc_mark_withdrawal_sent(
  p_withdrawal_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_req withdrawal_requests%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'withdrawal_not_found'; END IF;

  IF v_req.status = 'sent' THEN
    RETURN jsonb_build_object('ok', TRUE, 'withdrawal_id', p_withdrawal_id, 'idempotent', TRUE);
  END IF;
  IF v_req.status <> 'approved' THEN
    RAISE EXCEPTION 'invalid_withdrawal_status';
  END IF;

  UPDATE withdrawal_requests
     SET status = 'sent',
         sent_by = v_actor,
         sent_at = NOW()
   WHERE id = p_withdrawal_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    v_actor, 'withdrawal_sent', 'withdrawal_request', p_withdrawal_id,
    jsonb_build_object('reason', p_reason, 'user_id', v_req.user_id, 'amount', v_req.amount, 'currency', v_req.currency)
  );

  RETURN jsonb_build_object('ok', TRUE, 'withdrawal_id', p_withdrawal_id, 'status', 'sent');
END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_request_withdrawal(TEXT, TEXT, JSONB, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_request_withdrawal(TEXT, TEXT, JSONB, TEXT, TEXT) TO authenticated;

REVOKE EXECUTE ON FUNCTION rpc_reject_withdrawal(UUID, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION rpc_approve_withdrawal(UUID, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION rpc_mark_withdrawal_sent(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_reject_withdrawal(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_approve_withdrawal(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_mark_withdrawal_sent(UUID, TEXT) TO authenticated;

-- Keep the emergency seal until the operator explicitly re-enables withdrawals.
UPDATE app_config
   SET value = 'false',
       updated_at = NOW()
 WHERE key = 'feature_withdrawal_enabled';

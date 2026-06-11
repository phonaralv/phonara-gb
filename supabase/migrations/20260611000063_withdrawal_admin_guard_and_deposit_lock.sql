-- ============================================================
-- Withdrawal admin guard + deposit match lock
-- ============================================================
-- Scope:
--   1. Prevent admins from approving / marking sent for their own withdrawals.
--      Reject remains allowed because it only unlocks funds back to the user.
--   2. Honor feature_withdrawal_enabled=false for approve / mark-sent. Reject
--      remains live during incidents so operators can refund locked funds.
--   3. Lock the pending KRW deposit request selected for bank-transfer matching,
--      preventing two concurrent transfers from racing against the same pending row.
-- ============================================================

SET search_path = public, pg_temp;

-- ── Patch rpc_approve_withdrawal ─────────────────────────────────────────────
DO $$
DECLARE
  v_def TEXT;
  v_new TEXT;
BEGIN
  v_def := pg_get_functiondef('public.rpc_approve_withdrawal(uuid,text)'::regprocedure);
  v_new := v_def;

  IF position('_assert_feature_enabled(''withdrawal'')' IN v_new) = 0 THEN
    v_new := replace(
      v_new,
      'SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;',
      'PERFORM _assert_feature_enabled(''withdrawal'');

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;'
    );
  END IF;

  IF position('_assert_feature_enabled(''withdrawal'')' IN v_new) = 0 THEN
    RAISE EXCEPTION 'rpc_approve_withdrawal feature guard anchor not found';
  END IF;

  IF position('self_approval_forbidden' IN v_new) = 0 THEN
    v_new := replace(
      v_new,
      'IF NOT FOUND THEN RAISE EXCEPTION ''withdrawal_not_found''; END IF;',
      'IF NOT FOUND THEN RAISE EXCEPTION ''withdrawal_not_found''; END IF;
  IF v_req.user_id = v_actor THEN
    RAISE EXCEPTION ''self_approval_forbidden'';
  END IF;'
    );
  END IF;

  IF v_new = v_def THEN
    RAISE EXCEPTION 'rpc_approve_withdrawal patch anchors not found';
  END IF;

  EXECUTE v_new;
END;
$$;

-- ── Patch rpc_mark_withdrawal_sent ───────────────────────────────────────────
DO $$
DECLARE
  v_def TEXT;
  v_new TEXT;
BEGIN
  v_def := pg_get_functiondef('public.rpc_mark_withdrawal_sent(uuid,text)'::regprocedure);
  v_new := v_def;

  IF position('_assert_feature_enabled(''withdrawal'')' IN v_new) = 0 THEN
    v_new := replace(
      v_new,
      'SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;',
      'PERFORM _assert_feature_enabled(''withdrawal'');

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;'
    );
  END IF;

  IF position('_assert_feature_enabled(''withdrawal'')' IN v_new) = 0 THEN
    RAISE EXCEPTION 'rpc_mark_withdrawal_sent feature guard anchor not found';
  END IF;

  IF position('self_approval_forbidden' IN v_new) = 0 THEN
    v_new := replace(
      v_new,
      'IF NOT FOUND THEN RAISE EXCEPTION ''withdrawal_not_found''; END IF;',
      'IF NOT FOUND THEN RAISE EXCEPTION ''withdrawal_not_found''; END IF;
  IF v_req.user_id = v_actor THEN
    RAISE EXCEPTION ''self_approval_forbidden'';
  END IF;'
    );
  END IF;

  IF v_new = v_def THEN
    RAISE EXCEPTION 'rpc_mark_withdrawal_sent patch anchors not found';
  END IF;

  EXECUTE v_new;
END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_approve_withdrawal(UUID, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION rpc_mark_withdrawal_sent(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_approve_withdrawal(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_mark_withdrawal_sent(UUID, TEXT) TO authenticated;

-- ── Patch _try_match_krw_deposit pending row selection ───────────────────────
-- Lock order remains deposit request first, then _credit_krw_deposit_internal
-- locks the same deposit row again and then the wallet row. No existing path
-- locks the wallet first and then the same deposit row, so this does not invert
-- the established deposit-credit lock order.
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
   LIMIT 1
   FOR UPDATE;

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
  UPDATE krw_deposit_requests
     SET status = 'matched', matched_at = NOW()
   WHERE id = v_dep_id
     AND status = 'pending';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'deposit_request_not_pending';
  END IF;

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

REVOKE ALL ON FUNCTION _try_match_krw_deposit(TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

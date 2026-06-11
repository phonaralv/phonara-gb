-- ============================================================
-- Migration: 20260609000036_s1_admin_exception_queue_actions
-- W9-R1: admin exception queue resolution RPCs.
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION rpc_resolve_admin_review_queue(
  p_queue_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row admin_review_queue%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  SELECT * INTO v_row FROM admin_review_queue WHERE id = p_queue_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'queue_item_not_found'; END IF;

  IF v_row.status = 'resolved' THEN
    RETURN jsonb_build_object('ok', TRUE, 'queue_id', p_queue_id, 'idempotent', TRUE);
  END IF;

  UPDATE admin_review_queue
     SET status = 'resolved',
         resolved_at = NOW(),
         resolved_by = v_actor
   WHERE id = p_queue_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    v_actor, 'admin_queue_resolved', 'admin_review_queue', p_queue_id,
    jsonb_build_object(
      'reason', p_reason,
      'queue_type', v_row.queue_type,
      'entity_type', v_row.entity_type,
      'entity_id', v_row.entity_id,
      'user_id', v_row.user_id
    )
  );

  RETURN jsonb_build_object('ok', TRUE, 'queue_id', p_queue_id, 'status', 'resolved');
END;
$$;

CREATE OR REPLACE FUNCTION rpc_clear_risk_flag(
  p_flag_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row risk_flags%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  SELECT * INTO v_row FROM risk_flags WHERE id = p_flag_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'risk_flag_not_found'; END IF;

  IF v_row.status = 'cleared' THEN
    RETURN jsonb_build_object('ok', TRUE, 'flag_id', p_flag_id, 'idempotent', TRUE);
  END IF;

  UPDATE risk_flags
     SET status = 'cleared',
         cleared_at = NOW(),
         cleared_by = v_actor
   WHERE id = p_flag_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    v_actor, 'risk_flag_cleared', 'risk_flag', p_flag_id,
    jsonb_build_object(
      'reason', p_reason,
      'flag_type', v_row.flag_type,
      'user_id', v_row.user_id,
      'details', v_row.details
    )
  );

  RETURN jsonb_build_object('ok', TRUE, 'flag_id', p_flag_id, 'status', 'cleared');
END;
$$;

CREATE OR REPLACE FUNCTION rpc_update_str_case_status(
  p_case_id UUID,
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
  v_row str_cases%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;
  IF p_status NOT IN ('reviewing', 'filed', 'dismissed') THEN
    RAISE EXCEPTION 'invalid_str_status';
  END IF;

  SELECT * INTO v_row FROM str_cases WHERE id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'str_case_not_found'; END IF;

  IF v_row.status = p_status THEN
    RETURN jsonb_build_object('ok', TRUE, 'case_id', p_case_id, 'idempotent', TRUE);
  END IF;

  UPDATE str_cases
     SET status = p_status,
         updated_at = NOW()
   WHERE id = p_case_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    v_actor, 'str_case_status_updated', 'str_case', p_case_id,
    jsonb_build_object(
      'reason', p_reason,
      'from_status', v_row.status,
      'to_status', p_status,
      'case_type', v_row.case_type,
      'user_id', v_row.user_id
    )
  );

  RETURN jsonb_build_object('ok', TRUE, 'case_id', p_case_id, 'status', p_status);
END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_resolve_admin_review_queue(UUID, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION rpc_clear_risk_flag(UUID, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION rpc_update_str_case_status(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_resolve_admin_review_queue(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_clear_risk_flag(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_update_str_case_status(UUID, TEXT, TEXT) TO authenticated;

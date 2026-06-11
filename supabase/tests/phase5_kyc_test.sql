-- ============================================================
-- Phase 5 — KYC submission flow tests (W9-R3)
-- ============================================================

BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_admin UUID := gen_random_uuid();
  v_submission UUID;
  v_queue_count INT;
  v_audit_count INT;
  v_msg TEXT;
  v_blocked BOOLEAN := FALSE;
  v_res JSONB;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_uid, 'authenticated', 'authenticated', 'kyc_user_' || v_uid::TEXT || '@test.local', NOW(), NOW()),
    (v_admin, 'authenticated', 'authenticated', 'kyc_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'email_verified' WHERE id = v_uid;
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);

  BEGIN
    PERFORM _assert_kyc_withdrawal_gate(v_uid);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'kyc_insufficient' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, format('withdrawal gate must block before KYC approval, got %s', v_msg);

  v_res := rpc_submit_kyc(
    jsonb_build_object(
      'legal_name', 'Kim Minsoo',
      'document_type', 'id_card',
      'document_last4', 'A123',
      'country', 'KR'
    ),
    'kyc-test-idem-' || v_uid::TEXT
  );
  v_submission := (v_res->>'submission_id')::UUID;

  SELECT COUNT(*) INTO v_queue_count
    FROM admin_review_queue
   WHERE entity_type = 'kyc_submission'
     AND entity_id = v_submission
     AND queue_type = 'kyc_review'
     AND status = 'pending'
     AND payload->>'legal_name_masked' = 'K*********'
     AND payload->>'document_last4_masked' = '****';
  ASSERT v_queue_count = 1, 'KYC submission did not create masked admin queue item';

  SELECT COUNT(*) INTO v_queue_count
    FROM sanctions_screenings
   WHERE user_id = v_uid
     AND status = 'pending'
     AND source = 'kyc_submission';
  ASSERT v_queue_count = 1, 'KYC submit should create one pending sanctions screening for a new user';

  SELECT COUNT(*) INTO v_queue_count
    FROM admin_review_queue
   WHERE user_id = v_uid
     AND entity_type = 'sanctions_screening'
     AND queue_type = 'sanctions_screening'
     AND status = 'pending'
     AND payload->>'trigger' = 'kyc_submission';
  ASSERT v_queue_count = 1, 'KYC submit should enqueue sanctions screening review without blocking onboarding';

  v_res := rpc_submit_kyc(
    jsonb_build_object(
      'legal_name', 'Kim Minsoo',
      'document_type', 'id_card',
      'document_last4', 'A123',
      'country', 'KR'
    ),
    'kyc-test-idem-' || v_uid::TEXT
  );
  ASSERT (v_res->>'submission_id')::UUID = v_submission, 'KYC submit idempotency returned different submission';

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  BEGIN
    PERFORM rpc_review_kyc_submission(v_submission, 'approved', 'user cannot approve own KYC');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
  END;
  ASSERT v_msg = 'forbidden', format('non-admin KYC review must be forbidden, got %s', v_msg);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  v_res := rpc_review_kyc_submission(v_submission, 'approved', 'documents verified');
  ASSERT v_res->>'status' = 'approved', 'admin KYC approval did not return approved';

  PERFORM _assert_kyc_withdrawal_gate(v_uid);

  SELECT COUNT(*) INTO v_queue_count
    FROM admin_review_queue
   WHERE entity_type = 'kyc_submission'
     AND entity_id = v_submission
     AND status = 'resolved'
     AND resolved_by = v_admin;
  ASSERT v_queue_count = 1, 'KYC queue item not resolved after approval';

  SELECT COUNT(*) INTO v_audit_count
    FROM audit_logs
   WHERE actor_id = v_admin
     AND action = 'kyc_submission_approved'
     AND entity_type = 'kyc_submission'
     AND entity_id = v_submission;
  ASSERT v_audit_count = 1, 'KYC approval audit log missing';

  RAISE NOTICE 'KYC SUBMISSION APPROVAL OK — queue masked, screening queued, admin approved, withdrawal gate unlocked';
END;
$$;
ROLLBACK;

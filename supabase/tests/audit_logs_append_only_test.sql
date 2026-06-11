-- ============================================================
-- audit_logs / price_change_audit append-only trigger coverage
-- ============================================================
-- Proves UPDATE/DELETE raise append_only_violation (not silent no-op).
-- Runs in one transaction and ROLLS BACK — no residue.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_id UUID;
  v_caught BOOLEAN := FALSE;
BEGIN
  INSERT INTO audit_logs (action, entity_type, payload)
  VALUES ('append_only_pilot', 'test', '{"probe":true}'::JSONB)
  RETURNING id INTO v_id;

  BEGIN
    UPDATE audit_logs SET action = action || '_tampered' WHERE id = v_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append_only_violation%' THEN
      RAISE;
    END IF;
    v_caught := TRUE;
  END;

  ASSERT v_caught, 'UPDATE on audit_logs must raise append_only_violation';

  v_caught := FALSE;
  BEGIN
    DELETE FROM audit_logs WHERE id = v_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append_only_violation%' THEN
      RAISE;
    END IF;
    v_caught := TRUE;
  END;

  ASSERT v_caught, 'DELETE on audit_logs must raise append_only_violation';

  RAISE NOTICE 'AUDIT LOGS APPEND-ONLY OK — trigger blocks UPDATE/DELETE with append_only_violation';
END;
$$;

ROLLBACK;

BEGIN;

DO $$
DECLARE
  v_id UUID;
  v_caught BOOLEAN := FALSE;
BEGIN
  INSERT INTO price_change_audit (
    symbol, price_before, price_after, change_pct, source, actor_id, reason, circuit_breaker_triggered
  ) VALUES (
    'APPEND_ONLY_TEST', '1.000000', '1.010000', 1, 'admin', NULL, 'append-only coverage', FALSE
  )
  RETURNING id INTO v_id;

  BEGIN
    UPDATE price_change_audit SET reason = reason || '_tampered' WHERE id = v_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append_only_violation%' THEN
      RAISE;
    END IF;
    v_caught := TRUE;
  END;

  ASSERT v_caught, 'UPDATE on price_change_audit must raise append_only_violation';

  v_caught := FALSE;
  BEGIN
    DELETE FROM price_change_audit WHERE id = v_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append_only_violation%' THEN
      RAISE;
    END IF;
    v_caught := TRUE;
  END;

  ASSERT v_caught, 'DELETE on price_change_audit must raise append_only_violation';

  RAISE NOTICE 'PRICE CHANGE AUDIT APPEND-ONLY OK — trigger blocks UPDATE/DELETE with append_only_violation';
END;
$$;

ROLLBACK;

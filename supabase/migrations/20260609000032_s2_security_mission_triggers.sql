-- ============================================================
-- S2 security mission triggers
-- ============================================================
-- Completes the remaining mission paths without reopening rpc_complete_mission.

CREATE OR REPLACE FUNCTION _on_deposit_credited_mission()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status IN ('matched', 'credited')
     AND NEW.credited_at IS NOT NULL
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status OR OLD.credited_at IS DISTINCT FROM NEW.credited_at) THEN
    BEGIN
      PERFORM _grant_mission(NEW.user_id, 'first_deposit');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS deposits_first_deposit_mission ON krw_deposit_requests;
CREATE TRIGGER deposits_first_deposit_mission
  AFTER INSERT OR UPDATE OF status, credited_at ON krw_deposit_requests
  FOR EACH ROW EXECUTE FUNCTION _on_deposit_credited_mission();

CREATE OR REPLACE FUNCTION _on_profile_kyc_verified_mission()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.kyc_tier = 'id_verified'
     AND (TG_OP = 'INSERT' OR OLD.kyc_tier IS DISTINCT FROM NEW.kyc_tier) THEN
    BEGIN
      PERFORM _grant_mission(NEW.id, 'kyc_verified');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_kyc_verified_mission ON profiles;
CREATE TRIGGER profiles_kyc_verified_mission
  AFTER INSERT OR UPDATE OF kyc_tier ON profiles
  FOR EACH ROW EXECUTE FUNCTION _on_profile_kyc_verified_mission();

REVOKE ALL ON FUNCTION _on_deposit_credited_mission() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _on_profile_kyc_verified_mission() FROM PUBLIC, anon, authenticated;

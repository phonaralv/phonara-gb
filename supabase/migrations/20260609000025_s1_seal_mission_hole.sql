-- ============================================================
-- Migration: 20260609000025_s1_seal_mission_hole
-- S1 Critical: Seal rpc_complete_mission unauthenticated self-claim hole
-- ============================================================
-- VULNERABILITY (005 lines 412–431, re-granted by 013):
--   rpc_complete_mission(p_mission TEXT) is GRANT'ed to authenticated
--   and calls _grant_mission() with NO server-side condition validation.
--   Any signed-in user can self-claim kyc_verified(3000 PHON),
--   invite_3_friends(1500), streak_30_days(5000), etc. — up to ~11,700
--   PHON per account with only idempotency (1x) as a safeguard.
--
-- FIX:
--   1. REVOKE authenticated EXECUTE on rpc_complete_mission.
--      It remains callable by service_role (admin tooling / server-side).
--   2. Add server-side auto-triggers so legitimate completions still fire:
--      a. first_trade      → AFTER INSERT on spot_trades + futures_positions
--      b. invite_3_friends → AFTER UPDATE on referrals (rewarded_at set;
--                            referrer now has >= 3 rewarded referrals)
--      c. complete_profile → AFTER UPDATE on profiles (username first set)
--      d. first_deposit / kyc_verified / first_game → wired in S4/S3 when
--         those RPCs are built (no public entry yet → no current exposure).
--
-- Trigger functions are SECURITY DEFINER so they can call _grant_mission.
-- They are fully fault-tolerant: any exception is silently caught so a
-- mission grant failure can never block the underlying domain operation.
-- All three helpers are REVOKE'd from PUBLIC/anon/authenticated (internal).
-- ============================================================

SET search_path = public, pg_temp;

-- ─── 1. Seal the public entry point ──────────────────────────────────────────
-- After this, only service_role (SECURITY DEFINER owner context) may call
-- rpc_complete_mission. Authenticated clients can no longer self-claim.
REVOKE ALL ON FUNCTION rpc_complete_mission(TEXT) FROM PUBLIC, anon, authenticated;

-- ─── 2a. first_trade — AFTER INSERT trigger on spot_trades ───────────────────

CREATE OR REPLACE FUNCTION _on_spot_trade_inserted()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  BEGIN
    PERFORM _grant_mission(NEW.user_id, 'first_trade');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION _on_spot_trade_inserted()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS spot_trades_first_trade_mission ON spot_trades;
CREATE TRIGGER spot_trades_first_trade_mission
  AFTER INSERT ON spot_trades
  FOR EACH ROW EXECUTE FUNCTION _on_spot_trade_inserted();

-- ─── 2b. first_trade — AFTER INSERT trigger on futures_positions ──────────────

CREATE OR REPLACE FUNCTION _on_futures_position_opened()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  BEGIN
    PERFORM _grant_mission(NEW.user_id, 'first_trade');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION _on_futures_position_opened()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS futures_position_first_trade_mission ON futures_positions;
CREATE TRIGGER futures_position_first_trade_mission
  AFTER INSERT ON futures_positions
  FOR EACH ROW EXECUTE FUNCTION _on_futures_position_opened();

-- ─── 2c. invite_3_friends — AFTER UPDATE on referrals ────────────────────────
-- Fires when a referred user's welcome bonus is claimed (rewarded_at set).
-- Checks whether the referrer now has >= 3 fully-rewarded referrals.

CREATE OR REPLACE FUNCTION _on_referral_rewarded()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count INT;
BEGIN
  IF OLD.rewarded_at IS NULL AND NEW.rewarded_at IS NOT NULL THEN
    SELECT COUNT(*) INTO v_count
      FROM referrals
     WHERE referrer_id = NEW.referrer_id
       AND rewarded_at IS NOT NULL;

    IF v_count >= 3 THEN
      BEGIN
        PERFORM _grant_mission(NEW.referrer_id, 'invite_3_friends');
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION _on_referral_rewarded()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS referrals_invite_mission ON referrals;
CREATE TRIGGER referrals_invite_mission
  AFTER UPDATE ON referrals
  FOR EACH ROW EXECUTE FUNCTION _on_referral_rewarded();

-- ─── 2d. complete_profile — AFTER UPDATE on profiles ─────────────────────────
-- Fires when a user sets their username for the first time (NULL → non-NULL).

CREATE OR REPLACE FUNCTION _on_profile_username_set()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.username IS NULL AND NEW.username IS NOT NULL THEN
    BEGIN
      PERFORM _grant_mission(NEW.id, 'complete_profile');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION _on_profile_username_set()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS profiles_complete_profile_mission ON profiles;
CREATE TRIGGER profiles_complete_profile_mission
  AFTER UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION _on_profile_username_set();

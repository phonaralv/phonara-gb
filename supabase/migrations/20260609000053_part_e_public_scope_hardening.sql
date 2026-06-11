-- ============================================================
-- PART E: public read-scope hardening for app_config/audit/source tables
-- ============================================================
-- Local-only until the PART E gates are green.
--
-- Classification:
--   * Direct web client read required today:
--       - feature_withdrawal_enabled (wallet withdrawal availability UI)
--   * Internal/admin-only:
--       - AML/sanctions/STR thresholds, treasury alert thresholds, oracle/risk
--         parameters, casino stake/payout/exposure caps, system mode flags, and
--         market source/provider mappings.
--
-- SECURITY DEFINER RPCs continue reading app_config as table owner. Admin users
-- keep direct read/write through _is_admin() RLS. Regular clients only read
-- rows explicitly marked is_public.
-- ============================================================

SET search_path = public, pg_temp;

ALTER TABLE app_config
  ADD COLUMN IF NOT EXISTS is_public BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE app_config
   SET is_public = (key IN ('feature_withdrawal_enabled')),
       updated_at = NOW();

DROP POLICY IF EXISTS "public read app_config" ON app_config;
DROP POLICY IF EXISTS "app_config: public read flagged" ON app_config;
CREATE POLICY "app_config: public read flagged" ON app_config
  FOR SELECT
  USING (is_public = TRUE);

DROP POLICY IF EXISTS "app_config: admin rw" ON app_config;
CREATE POLICY "app_config: admin rw" ON app_config
  FOR ALL
  USING (_is_admin())
  WITH CHECK (_is_admin());

DROP POLICY IF EXISTS "public read price_change_audit" ON price_change_audit;
DROP POLICY IF EXISTS "price_change_audit: admin read" ON price_change_audit;
CREATE POLICY "price_change_audit: admin read" ON price_change_audit
  FOR SELECT
  USING (_is_admin());

DROP POLICY IF EXISTS "market_sources: authenticated read" ON market_sources;
DROP POLICY IF EXISTS "market_sources: admin read" ON market_sources;
CREATE POLICY "market_sources: admin read" ON market_sources
  FOR SELECT
  USING (_is_admin());

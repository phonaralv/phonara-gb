-- ============================================================
-- Migration: 20260609000015_p0_liquidation_cron_runner
-- ============================================================
-- Plan item `liquidation-runner` (S0 stabilization, Critical).
--
-- PROBLEM
-- The auto-liquidation engine `rpc_run_liquidations()` (migration 000009) exists
-- and is correct, but NOTHING calls it on a schedule in the database. Production
-- had no pg_cron job and no deployed Edge Function, so an underwater position
-- would never be force-closed by the server — a solvency hole.
--
-- FIX
-- Schedule `rpc_run_liquidations()` every minute via pg_cron, entirely inside the
-- database (no Edge Function deploy, no pg_net, no external secret required).
-- pg_cron is already in `shared_preload_libraries` on every Supabase project
-- (verified locally + matches Supabase cloud defaults), so `CREATE EXTENSION` is
-- safe to apply both locally (`supabase db reset`) and remotely.
--
-- The cron job runs as the job owner (postgres / superuser). Inside the sweep,
-- `auth.uid()` reads `request.jwt.claims`, which is unset in the cron session, so
-- `auth.uid()` returns NULL → the function's service-path guard
-- (`IF auth.uid() IS NOT NULL AND NOT _is_admin() THEN RAISE 'forbidden'`) passes.
--
-- OBSERVABILITY
-- A thin wrapper `_run_liquidations_logged()` records only MEANINGFUL sweeps
-- (>=1 liquidation or >=1 error) into `liquidation_run_log`, so the table does
-- not bloat with ~1,440 empty rows/day. pg_cron's own `cron.job_run_details`
-- already records every invocation for liveness, so the custom log is reserved
-- for actionable events.
--
-- The Edge Function `supabase/functions/liquidation-worker` remains as an
-- OPTIONAL redundant runner; it is no longer required for the runner to be live.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── pg_cron extension (preloaded on all Supabase projects) ───────────────────
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ─── Append-only log of meaningful liquidation sweeps ─────────────────────────
CREATE TABLE IF NOT EXISTS liquidation_run_log (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ran_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  liquidated  INT NOT NULL,
  skipped     INT NOT NULL,
  errors      INT NOT NULL,
  duration_ms INT NOT NULL,
  detail      JSONB NOT NULL DEFAULT '[]'::JSONB
);

CREATE INDEX IF NOT EXISTS lrl_ran_at_idx ON liquidation_run_log (ran_at DESC);

ALTER TABLE liquidation_run_log ENABLE ROW LEVEL SECURITY;

-- Admins read the actionable liquidation history; writes happen via SECURITY
-- DEFINER only. No anon/authenticated read of internal engine internals.
DROP POLICY IF EXISTS "admin read liquidation_run_log" ON liquidation_run_log;
CREATE POLICY "admin read liquidation_run_log" ON liquidation_run_log
  FOR SELECT USING (_is_admin());

-- ─── Logging wrapper invoked by pg_cron ───────────────────────────────────────
-- Runs the sweep and persists only actionable outcomes. SECURITY DEFINER, owned
-- by postgres; revoked from all client roles (cron runs as superuser, bypassing
-- GRANTs, so no client ever needs EXECUTE).
CREATE OR REPLACE FUNCTION _run_liquidations_logged()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_start TIMESTAMPTZ := clock_timestamp();
  v_res   JSONB;
  v_liq   INT;
  v_skip  INT;
  v_err   INT;
BEGIN
  v_res  := rpc_run_liquidations();
  v_liq  := COALESCE((v_res->>'liquidated')::INT, 0);
  v_skip := COALESCE((v_res->>'skipped')::INT, 0);
  v_err  := COALESCE((v_res->>'errors')::INT, 0);

  -- Only persist actionable sweeps; cron.job_run_details covers liveness.
  IF v_liq > 0 OR v_err > 0 THEN
    INSERT INTO liquidation_run_log (liquidated, skipped, errors, duration_ms, detail)
    VALUES (
      v_liq, v_skip, v_err,
      EXTRACT(MILLISECONDS FROM (clock_timestamp() - v_start))::INT,
      COALESCE(v_res->'detail', '[]'::JSONB)
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _run_liquidations_logged() FROM PUBLIC, anon, authenticated;

-- ─── Schedule: every minute ───────────────────────────────────────────────────
-- cron.schedule(name, schedule, command) upserts by job name, so re-applying this
-- migration (or applying after a manual unschedule) is idempotent.
SELECT cron.schedule(
  'phonara_auto_liquidations',
  '* * * * *',
  $cron$SELECT public._run_liquidations_logged();$cron$
);

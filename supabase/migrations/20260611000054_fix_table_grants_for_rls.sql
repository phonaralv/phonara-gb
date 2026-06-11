-- ============================================================
-- Migration: 20260611000054_fix_table_grants_for_rls
-- Fix missing table grants for RLS policy evaluation
-- ============================================================
-- RLS policies only work after the role has base table access via GRANT.
-- These grants are required for:
-- - candles_volume_test.sql: authenticated role reading spot_trades
-- - public_scope_hardening_test.sql: anon role reading app_config
-- ============================================================

SET search_path = public, pg_temp;

-- Grant SELECT on spot_trades to authenticated users
-- RLS policy restricts to own rows only
GRANT SELECT ON public.spot_trades TO authenticated;

-- Grant SELECT on app_config to anon users
-- RLS policy restricts to is_public = TRUE rows only
GRANT SELECT ON public.app_config TO anon;

-- Grant SELECT on app_config to authenticated users
-- RLS policy restricts to is_public = TRUE or _is_admin() = TRUE
GRANT SELECT ON public.app_config TO authenticated;

-- Grant SELECT on price_change_audit to authenticated users
-- RLS policy restricts to _is_admin() = TRUE only
GRANT SELECT ON public.price_change_audit TO authenticated;

-- Grant SELECT on market_sources to authenticated users
-- RLS policy restricts to _is_admin() = TRUE only
GRANT SELECT ON public.market_sources TO authenticated;

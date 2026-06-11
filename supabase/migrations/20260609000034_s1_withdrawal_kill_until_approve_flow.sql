-- ============================================================
-- Migration: 20260609000034_s1_withdrawal_kill_until_approve_flow
-- Wave 9.1 hotfix: block user withdrawal requests until approve/reject
-- RPCs exist (escrow/reversal path not shipped).
-- ============================================================
-- rpc_request_withdrawal GRANTs to authenticated but only debits the user
-- wallet (no withdrawal_escrow system leg, no rpc_reject_withdrawal). Leaving
-- feature_withdrawal_enabled=true would accept requests with no way to return
-- funds. Kill switch OFF until approve/reject flow lands.
-- ============================================================

SET search_path = public, pg_temp;

UPDATE app_config
   SET value = 'false',
       updated_at = NOW()
 WHERE key = 'feature_withdrawal_enabled';

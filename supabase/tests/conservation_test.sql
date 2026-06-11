-- ============================================================
-- A1 Conservation — SQL integration test (DB-level, real RPCs)
-- ============================================================
-- Complements the property-based spec in
--   packages/trading-engine/src/conservation.test.ts
-- by executing the ACTUAL Supabase RPCs and asserting the global money
-- invariant directly on the database:
--
--   GRAND TOTAL per currency =
--       Σ(wallets.available + wallets.locked)      -- all users
--     + Σ(system_accounts.balance)                 -- house/insurance/liquidity/dust/mint
--
--   This grand total MUST be invariant across every trading / settlement RPC.
--   (Deposits/withdrawals change it on purpose; reward issuance does NOT, because
--    the user credit is balanced by a negative reward_issuance mint leg.)
--
-- HOW TO RUN (requires Postgres with all migrations applied):
--   Local:  supabase start && supabase db reset
--           psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/conservation_test.sql
--   Remote: run via the Supabase MCP execute_sql (it is fully wrapped in a
--           transaction and ROLLBACKs at the end — it never persists data).
--
-- The whole script runs inside one transaction and ROLLS BACK, so it leaves no
-- residue (satisfies the testing rule on test residue cleanup).
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_uid        UUID := gen_random_uuid();
  v_phon_total_before NUMERIC;
  v_usdt_total_before NUMERIC;
  v_phon_total_after  NUMERIC;
  v_usdt_total_after  NUMERIC;
  v_pos        JSONB;
  v_pos_id     UUID;
BEGIN
  -- ── Arrange: throwaway auth user (triggers auto-create profile + wallet) ────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'conservation_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  -- Fund the auto-created wallet (on_auth_user_created inserts it with zero balances)
  UPDATE wallets SET phon_available = '1000000.000000', usdt_available = '1000000.000000'
  WHERE user_id = v_uid;

  -- Make auth.uid() resolve to our test user for SECURITY DEFINER RPCs.
  -- We intentionally stay on the superuser role (bypasses RLS) so the harness can
  -- seed oracle prices directly; the RPCs are SECURITY DEFINER and read auth.uid()
  -- from request.jwt.claims regardless of the connection role.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  -- Ensure fresh, non-stale oracle prices for both the spot (PHON_USDT) and the
  -- futures (PHONUSDT-PERP) markets used below.
  INSERT INTO oracle_prices (symbol, price, updated_at) VALUES
    ('PHON_USDT',     '0.010000', NOW()),
    ('PHONUSDT-PERP', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = EXCLUDED.price, updated_at = NOW();

  -- ── Snapshot grand totals BEFORE ────────────────────────────────────────────
  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC),0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='PHON'),
    (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC),0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='USDT')
  INTO v_phon_total_before, v_usdt_total_before;

  -- ── Act: a sequence of money RPCs ──────────────────────────────────────────
  PERFORM rpc_spot_market_buy('5000.000000');     -- USDT -> PHON
  PERFORM rpc_spot_market_sell('100000.000000');  -- PHON -> USDT

  v_pos := rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '1000.000000', '10');
  v_pos_id := (v_pos->>'position_id')::UUID;
  -- Move price within circuit-breaker limits (+5% < 10% max_tick), then close
  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHONUSDT-PERP', '0.010500', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010500', updated_at = NOW();
  PERFORM rpc_close_futures_position(v_pos_id);

  -- ── Snapshot grand totals AFTER ─────────────────────────────────────────────
  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC),0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='PHON'),
    (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC),0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='USDT')
  INTO v_phon_total_after, v_usdt_total_after;

  -- ── Assert: conservation (grand total per currency unchanged) ───────────────
  ASSERT v_phon_total_after = v_phon_total_before,
    format('PHON not conserved: before=%s after=%s (delta=%s)',
           v_phon_total_before, v_phon_total_after, v_phon_total_after - v_phon_total_before);
  ASSERT v_usdt_total_after = v_usdt_total_before,
    format('USDT not conserved: before=%s after=%s (delta=%s)',
           v_usdt_total_before, v_usdt_total_after, v_usdt_total_after - v_usdt_total_before);

  -- ── Assert: hash chain is intact for this user ──────────────────────────────
  ASSERT NOT EXISTS (SELECT 1 FROM verify_ledger_hash_chain(v_uid)),
    'wallet_ledger hash chain broken for test user';

  RAISE NOTICE 'CONSERVATION OK — PHON total=% USDT total=% (chain intact)',
    v_phon_total_after, v_usdt_total_after;
END;
$$;

ROLLBACK;

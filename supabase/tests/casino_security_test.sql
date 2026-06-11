-- ============================================================
-- Casino security — RPC/RLS negative paths
-- ============================================================

-- ── 1. Admin void requires admin and writes audit ─────────────────────────────
BEGIN;
DO $$
DECLARE
  v_admin UUID := gen_random_uuid();
  v_user UUID := gen_random_uuid();
  v_round_id UUID;
  v_bet_id UUID := gen_random_uuid();
  v_lock_id UUID;
  v_result JSONB;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_admin, 'authenticated', 'authenticated', 'casino_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW()),
    (v_user, 'authenticated', 'authenticated', 'casino_void_' || v_user::TEXT || '@test.local', NOW(), NOW());
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;
  UPDATE wallets SET phon_available = '1000.000000' WHERE user_id = v_user;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_round_id := (rpc_create_game_round('dice', 'void_seed_value_for_validation')->>'round_id')::UUID;
  v_lock_id := _lock_wallet_internal(v_user, 'PHON', '25.000000', 'game_void_lock', 'void_lock:' || v_bet_id::TEXT);

  INSERT INTO game_bets (
    id, round_id, user_id, game, currency, stake, selection, client_seed, nonce,
    status, idempotency_key, stake_lock_id
  ) VALUES (
    v_bet_id, v_round_id, v_user, 'dice', 'PHON', '25.000000',
    '{"target":"50.00","direction":"over"}'::JSONB, 'cs', 1,
    'pending', 'void_idem_' || v_user::TEXT, v_lock_id
  );

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  v_result := rpc_admin_void_game_bet(v_bet_id, 'risk review reversal');

  ASSERT v_result->>'status' = 'cancelled', 'admin void must cancel pending bet';
  ASSERT EXISTS (
    SELECT 1 FROM audit_logs
    WHERE actor_id = v_admin AND action = 'admin_void_game_bet' AND entity_id = v_bet_id
  ), 'admin void audit row missing';

  RAISE NOTICE 'CASINO ADMIN VOID OK — reasoned audit row written';
END;
$$;
ROLLBACK;

-- ── 2. Authenticated users cannot call service settlement path ────────────────
BEGIN;
DO $$
BEGIN
  ASSERT NOT has_function_privilege(
    'authenticated', 'public.rpc_settle_game_bet(uuid,text)', 'EXECUTE'),
    'authenticated role must not execute rpc_settle_game_bet';
  RAISE NOTICE 'CASINO SETTLE PRIVILEGE OK — authenticated caller rejected';
END;
$$;
ROLLBACK;

-- ── 3. Authenticated users cannot tamper stored payout directly ───────────────
BEGIN;
DO $$
BEGIN
  ASSERT NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'game_bets'
      AND cmd IN ('UPDATE', 'ALL')
      AND roles::TEXT LIKE '%authenticated%'
  ), 'authenticated role must not have an UPDATE RLS path for game_bets payout';
  RAISE NOTICE 'CASINO PAYOUT TAMPER OK — direct update rejected';
END;
$$;
ROLLBACK;

-- ── 4. Authenticated users cannot directly SELECT protected server_seed ───────
BEGIN;
DO $$
BEGIN
  ASSERT NOT has_table_privilege('authenticated', 'public.game_rounds', 'SELECT'),
    'authenticated role must not directly select game_rounds';
  ASSERT NOT has_column_privilege('authenticated', 'public.game_rounds', 'server_seed', 'SELECT'),
    'authenticated role must not directly select game_rounds.server_seed';
  RAISE NOTICE 'CASINO SERVER SEED PROTECTION OK — direct table SELECT rejected';
END;
$$;
ROLLBACK;

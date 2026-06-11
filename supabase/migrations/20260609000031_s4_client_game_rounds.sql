-- ============================================================
-- S4 client game rounds
-- ============================================================
-- Browser clients need a committed seed hash before placing a bet, but must
-- never provide or see the server seed before reveal. This RPC creates the
-- round inside Postgres and returns only the commitment.

CREATE OR REPLACE FUNCTION rpc_open_game_round(p_game TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_game game_code;
  v_seed TEXT;
  v_hash TEXT;
  v_round_id UUID := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _assert_system_live();
  PERFORM _assert_feature_enabled('game');

  BEGIN
    v_game := p_game::game_code;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_game_code';
  END;

  PERFORM _assert_game_feature_enabled(v_game);

  v_seed := encode(extensions.gen_random_bytes(32), 'hex');
  v_hash := encode(extensions.digest(v_seed, 'sha256'), 'hex');

  INSERT INTO game_rounds (id, game, server_seed_hash, server_seed)
  VALUES (v_round_id, v_game, v_hash, v_seed);

  RETURN jsonb_build_object(
    'round_id', v_round_id,
    'game', v_game,
    'server_seed_hash', v_hash
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_open_game_round(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_open_game_round(TEXT) TO authenticated, service_role;

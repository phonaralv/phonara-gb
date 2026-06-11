-- ============================================================
-- P0 (high-risk): Request-level idempotency for entry RPCs
-- ============================================================
-- Plan item `request-idem`.
--
-- PROBLEM
-- The wallet ledger is idempotent per generated entity id, but a fresh entity id
-- is minted on every call, so a double-click (two near-simultaneous submits)
-- creates TWO positions / TWO trades / TWO stakes and locks margin twice.
--
-- FIX
-- A per-user dedup table keyed by a client-supplied request id. Each entry RPC
-- accepts an optional `p_client_request_id`; when present it INSERTs the key with
-- ON CONFLICT DO NOTHING and raises `duplicate_request` if the key already
-- existed. The UNIQUE (user_id, client_request_id) index also serializes two
-- in-flight duplicates: the second blocks on the first's row lock, then sees the
-- conflict. Because the insert lives inside the same transaction, a FAILED entry
-- RPC rolls the key back too, so the user can safely retry with the same id.
--
-- The param is added by transforming the live pg_get_functiondef text (preserves
-- every previously-injected guard) then DROP + CREATE with the new signature and
-- re-applied grants. Idempotent + fails loudly if an anchor is missing.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── Dedup table ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rpc_request_idem (
  user_id           UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  client_request_id TEXT NOT NULL,
  rpc_name          TEXT NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, client_request_id)
);
CREATE INDEX IF NOT EXISTS rpc_request_idem_created_idx ON rpc_request_idem (created_at);

ALTER TABLE rpc_request_idem ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own read rpc_request_idem" ON rpc_request_idem;
CREATE POLICY "own read rpc_request_idem" ON rpc_request_idem
  FOR SELECT USING (auth.uid() = user_id);

-- No INSERT/UPDATE/DELETE policies: RLS denies all client writes. Rows are
-- written only by the SECURITY DEFINER entry RPCs (which run as owner and bypass
-- RLS). Rules are intentionally NOT used here because an ON UPDATE rule is
-- incompatible with the ON CONFLICT clause the RPCs rely on. Belt-and-suspenders:
-- revoke write grants from client roles.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON rpc_request_idem FROM anon, authenticated;

-- ─── Transform the 4 entry RPCs: add param + dedup gate ───────────────────────
DO $mig$
DECLARE
  v_sig    TEXT;
  v_rpc    TEXT;
  v_newsig TEXT;
  v_def    TEXT;
  v_new    TEXT;
  i        INT;
  v_sigs    TEXT[] := ARRAY[
    'public.rpc_open_futures_position(text,text,text,text,text,text,text)',
    'public.rpc_spot_market_buy(text)',
    'public.rpc_spot_market_sell(text)',
    'public.rpc_stake_phon(text,text)'
  ];
  v_rpcs    TEXT[] := ARRAY[
    'rpc_open_futures_position', 'rpc_spot_market_buy', 'rpc_spot_market_sell', 'rpc_stake_phon'
  ];
  v_newsigs TEXT[] := ARRAY[
    'public.rpc_open_futures_position(text,text,text,text,text,text,text,text)',
    'public.rpc_spot_market_buy(text,text)',
    'public.rpc_spot_market_sell(text,text)',
    'public.rpc_stake_phon(text,text,text)'
  ];
BEGIN
  FOR i IN 1..array_length(v_sigs, 1) LOOP
    v_sig    := v_sigs[i];
    v_rpc    := v_rpcs[i];
    v_newsig := v_newsigs[i];
    v_def    := pg_get_functiondef(v_sig::regprocedure);

    -- Idempotent: already transformed
    IF position('p_client_request_id' IN v_def) > 0 THEN
      CONTINUE;
    END IF;

    -- (1) Append the optional param just before "RETURNS jsonb"
    v_new := regexp_replace(
      v_def,
      '\)(\s+RETURNS jsonb)',
      ', p_client_request_id text DEFAULT NULL::text)\1',
      ''
    );
    IF v_new = v_def THEN
      RAISE EXCEPTION 'request-idem param anchor not found in %', v_sig;
    END IF;

    -- (2) Inject the dedup gate immediately after the system-live guard
    v_def := v_new;
    v_new := replace(
      v_def,
      'PERFORM _assert_system_live();',
      'PERFORM _assert_system_live();'
        || E'\n  IF p_client_request_id IS NOT NULL AND v_user_id IS NOT NULL THEN'
        || E'\n    INSERT INTO rpc_request_idem (user_id, client_request_id, rpc_name)'
        || E'\n    VALUES (v_user_id, p_client_request_id, ''' || v_rpc || ''')'
        || E'\n    ON CONFLICT (user_id, client_request_id) DO NOTHING;'
        || E'\n    IF NOT FOUND THEN RAISE EXCEPTION ''duplicate_request''; END IF;'
        || E'\n  END IF;'
    );
    IF v_new = v_def THEN
      RAISE EXCEPTION 'request-idem dedup anchor (_assert_system_live) not found in %', v_sig;
    END IF;

    -- (3) Replace the function (new signature → must drop old first) and re-grant
    EXECUTE 'DROP FUNCTION ' || v_sig;
    EXECUTE v_new;
    EXECUTE 'REVOKE ALL ON FUNCTION ' || v_newsig || ' FROM PUBLIC, anon';
    EXECUTE 'GRANT EXECUTE ON FUNCTION ' || v_newsig || ' TO authenticated, service_role';
  END LOOP;
END
$mig$;

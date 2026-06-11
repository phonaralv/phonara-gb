-- ============================================================
-- Stage 2: Market/source mapping registry
-- ============================================================
-- Prepares the DB-side registry that the later external feed worker will read.
-- This migration does not fetch external APIs and does not change oracle logic.
-- ============================================================

SET search_path = public, pg_temp;

CREATE TABLE IF NOT EXISTS market_sources (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  internal_symbol TEXT NOT NULL,
  provider        TEXT NOT NULL,
  provider_symbol TEXT NOT NULL,
  weight          TEXT NOT NULL DEFAULT '1'
    CONSTRAINT ms_weight_fmt CHECK (weight ~ '^\d+(\.\d+)?$'),
  enabled         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (internal_symbol, provider)
);

CREATE INDEX IF NOT EXISTS ms_internal_enabled_idx ON market_sources (internal_symbol, enabled);

DROP TRIGGER IF EXISTS ms_updated_at ON market_sources;
CREATE TRIGGER ms_updated_at
  BEFORE UPDATE ON market_sources
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE market_sources ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "market_sources: authenticated read" ON market_sources;
CREATE POLICY "market_sources: authenticated read" ON market_sources
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "market_sources: admin write" ON market_sources;
CREATE POLICY "market_sources: admin write" ON market_sources
  FOR ALL USING (_is_admin()) WITH CHECK (_is_admin());

CREATE OR REPLACE FUNCTION rpc_set_market_source(
  p_internal_symbol TEXT,
  p_provider        TEXT,
  p_provider_symbol TEXT,
  p_weight          TEXT,
  p_enabled         BOOLEAN,
  p_reason          TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_id    UUID;
BEGIN
  IF NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;
  IF p_internal_symbol IS NULL OR length(btrim(p_internal_symbol)) = 0 THEN
    RAISE EXCEPTION 'invalid_input' USING HINT = 'internal_symbol';
  END IF;
  IF p_provider IS NULL OR length(btrim(p_provider)) = 0 THEN
    RAISE EXCEPTION 'invalid_input' USING HINT = 'provider';
  END IF;
  IF p_provider_symbol IS NULL OR length(btrim(p_provider_symbol)) = 0 THEN
    RAISE EXCEPTION 'invalid_input' USING HINT = 'provider_symbol';
  END IF;
  IF p_weight IS NULL OR p_weight !~ '^\d+(\.\d+)?$' OR p_weight::NUMERIC <= 0 THEN
    RAISE EXCEPTION 'invalid_input' USING HINT = 'weight';
  END IF;

  INSERT INTO market_sources (internal_symbol, provider, provider_symbol, weight, enabled)
  VALUES (p_internal_symbol, lower(p_provider), p_provider_symbol, p_weight, COALESCE(p_enabled, TRUE))
  ON CONFLICT (internal_symbol, provider) DO UPDATE
    SET provider_symbol = EXCLUDED.provider_symbol,
        weight = EXCLUDED.weight,
        enabled = EXCLUDED.enabled,
        updated_at = NOW()
  RETURNING id INTO v_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (v_actor, 'market_source_set', 'market_sources', v_id,
    jsonb_build_object(
      'internal_symbol', p_internal_symbol,
      'provider', lower(p_provider),
      'provider_symbol', p_provider_symbol,
      'weight', p_weight,
      'enabled', COALESCE(p_enabled, TRUE),
      'reason', p_reason
    ));

  RETURN jsonb_build_object('id', v_id, 'internal_symbol', p_internal_symbol, 'provider', lower(p_provider));
END;
$$;

CREATE OR REPLACE FUNCTION rpc_disable_market_source(
  p_internal_symbol TEXT,
  p_provider        TEXT,
  p_reason          TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_id    UUID;
BEGIN
  IF NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  UPDATE market_sources
     SET enabled = FALSE,
         updated_at = NOW()
   WHERE internal_symbol = p_internal_symbol
     AND provider = lower(p_provider)
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'market_source_not_found';
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (v_actor, 'market_source_disabled', 'market_sources', v_id,
    jsonb_build_object(
      'internal_symbol', p_internal_symbol,
      'provider', lower(p_provider),
      'reason', p_reason
    ));

  RETURN jsonb_build_object('id', v_id, 'enabled', FALSE);
END;
$$;

REVOKE ALL ON FUNCTION rpc_set_market_source(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION rpc_disable_market_source(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_set_market_source(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION rpc_disable_market_source(TEXT, TEXT, TEXT) TO authenticated, service_role;

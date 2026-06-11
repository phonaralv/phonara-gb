-- ============================================================
-- Migration: 20260609000016_p1_entry_rpc_numeric_input_guard
-- ============================================================
-- Plan item `ts-input-guard` (S3, security parity TS<->SQL).
--
-- PROBLEM
-- The entry money RPCs validate amounts with `p_x::NUMERIC` + `IF v <= 0`. But
-- `'NaN'::numeric` and `'Infinity'::numeric` are VALID numeric values, and
-- `'NaN' <= 0` is FALSE, so the non-positive guard lets them through. A caller
-- could pass 'NaN'/'Infinity' as margin/leverage/amount and poison downstream
-- arithmetic. The TypeScript engine already rejects these via regex+isFinite;
-- the SQL side was asymmetric.
--
-- FIX
-- Add an IMMUTABLE text guard `_assert_amount_text(text)` that requires the
-- canonical decimal shape `^\d+(\.\d+)?$` (rejects NaN, Infinity, scientific
-- notation, signs, and garbage) and call it on every scalar money/leverage
-- parameter BEFORE the value is used. For spot/stake the `::NUMERIC` cast lived
-- in the DECLARE block (so 'NaN' was cast before any body guard could run); the
-- cast is moved into the body, after the guard, so 'NaN' is rejected cleanly
-- with the stable `invalid_amount` code instead of bypassing the check.
--
-- The four function bodies below are reproduced verbatim from the live
-- definitions (pg_get_functiondef) with ONLY the guard + cast-relocation added,
-- so trading math / conservation is unchanged.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── Canonical decimal-shape guard (rejects NaN/Infinity/sci-notation/signs) ──
CREATE OR REPLACE FUNCTION _assert_amount_text(p_value TEXT)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_value IS NULL OR p_value !~ '^\d+(\.\d+)?$' THEN
    RAISE EXCEPTION 'invalid_amount' USING HINT = COALESCE(p_value, 'null');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_amount_text(TEXT) FROM PUBLIC, anon, authenticated;
-- Internal helper still callable inside SECURITY DEFINER RPCs (owner context);
-- not exposed to clients.

-- ─── rpc_open_futures_position (guard p_margin_amount + p_leverage) ───────────
CREATE OR REPLACE FUNCTION public.rpc_open_futures_position(
  p_market text, p_side text, p_margin_currency text, p_margin_amount text,
  p_leverage text, p_stop_loss text DEFAULT NULL::text, p_take_profit text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id    UUID := auth.uid();
  v_mkt        futures_markets%ROWTYPE;
  v_ccy        currency;
  v_side       position_side;
  v_margin     NUMERIC;
  v_lev        NUMERIC;
  v_mmr        NUMERIC;
  v_entry      NUMERIC;
  v_notional   NUMERIC;
  v_qty        NUMERIC;
  v_open_fee   NUMERIC;
  v_inv_lev    NUMERIC;
  v_liq        NUMERIC;
  v_pos_id     UUID := gen_random_uuid();
  v_tid        UUID := gen_random_uuid();
BEGIN
  SET search_path = public, pg_temp;

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_open_futures_position');
  PERFORM _assert_onboarding_consent(v_user_id);

  -- Input shape guard (blocks NaN/Infinity/sci-notation/signs) before any cast.
  PERFORM _assert_amount_text(p_margin_amount);
  PERFORM _assert_amount_text(p_leverage);

  SELECT * INTO v_mkt FROM futures_markets WHERE symbol = p_market AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'market_not_found'; END IF;

  IF p_side NOT IN ('long','short') THEN RAISE EXCEPTION 'invalid_side'; END IF;
  IF p_margin_currency NOT IN ('PHON','USDT') THEN RAISE EXCEPTION 'invalid_margin_currency'; END IF;
  v_side := p_side::position_side;
  v_ccy  := p_margin_currency::currency;

  v_margin := p_margin_amount::NUMERIC;
  v_lev    := p_leverage::NUMERIC;
  v_mmr    := v_mkt.maintenance_margin_rate::NUMERIC;

  IF v_margin <= 0 THEN RAISE EXCEPTION 'invalid_margin'; END IF;
  IF v_lev < 1    THEN RAISE EXCEPTION 'invalid_leverage'; END IF;
  IF v_lev > v_mkt.max_leverage::NUMERIC THEN RAISE EXCEPTION 'leverage_too_high'; END IF;

  v_entry := _assert_price_fresh(p_market);

  v_notional := v_margin * v_lev;
  v_qty      := v_notional / v_entry;
  v_open_fee := v_notional * v_mkt.open_fee_rate::NUMERIC;
  v_inv_lev  := 1 / v_lev;
  IF v_side = 'long' THEN
    v_liq := v_entry * (1 - v_inv_lev + v_mmr);
  ELSE
    v_liq := v_entry * (1 + v_inv_lev - v_mmr);
  END IF;
  IF v_liq < 0 THEN v_liq := 0; END IF;

  PERFORM _lock_wallet_internal(v_user_id, v_ccy, _fmt6(v_margin),
    'futures_margin_lock', 'fut_margin:' || v_pos_id::TEXT);

  IF trunc(v_open_fee, 6) > 0 THEN
    PERFORM _debit_wallet_internal(v_user_id, v_ccy, _fmt6(v_open_fee),
      'futures_open_fee', 'fut_openfee:' || v_pos_id::TEXT);
    PERFORM _credit_system_account(
      'house_fee_' || lower(v_ccy::TEXT), _fmt6(v_open_fee),
      'futures_open_fee', v_user_id, v_pos_id::TEXT, v_tid);
  END IF;

  INSERT INTO futures_positions (
    id, user_id, market, side, margin_currency, margin_amount, leverage,
    entry_price, quantity, notional, open_fee, liquidation_price, stop_loss, take_profit
  ) VALUES (
    v_pos_id, v_user_id, p_market, v_side, v_ccy, _fmt6(v_margin), v_lev::TEXT,
    _fmt6(v_entry), _fmt6(v_qty), _fmt6(v_notional), _fmt6(v_open_fee), _fmt6(v_liq),
    p_stop_loss, p_take_profit
  );

  INSERT INTO position_ledger (position_id, user_id, event, price, fee, payload)
  VALUES (v_pos_id, v_user_id, 'open', _fmt6(v_entry), _fmt6(v_open_fee),
    jsonb_build_object('side', p_side, 'leverage', v_lev, 'notional', _fmt6(v_notional)));

  RETURN jsonb_build_object(
    'position_id',       v_pos_id,
    'market',            p_market,
    'side',              p_side,
    'entry_price',       _fmt6(v_entry),
    'quantity',          _fmt6(v_qty),
    'notional',          _fmt6(v_notional),
    'open_fee',          _fmt6(v_open_fee),
    'liquidation_price', _fmt6(v_liq)
  );
END;
$function$;

-- ─── rpc_spot_market_buy (guard p_usdt_spent; cast moved into body) ───────────
CREATE OR REPLACE FUNCTION public.rpc_spot_market_buy(p_usdt_spent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id  UUID := auth.uid();
  v_mkt      spot_markets%ROWTYPE;
  v_price    NUMERIC;
  v_usdt     NUMERIC;
  v_fee_rate NUMERIC;
  v_gross    NUMERIC;
  v_fee      NUMERIC;
  v_net      NUMERIC;
  v_usdt6    NUMERIC;
  v_net6     NUMERIC;
  v_fee6     NUMERIC;
  v_trade_id UUID := gen_random_uuid();
  v_tid      UUID := gen_random_uuid();
BEGIN
  SET search_path = public, pg_temp;

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_spot_market_buy');
  PERFORM _assert_onboarding_consent(v_user_id);
  PERFORM _assert_amount_text(p_usdt_spent);
  v_usdt := p_usdt_spent::NUMERIC;
  IF v_usdt <= 0 THEN RAISE EXCEPTION 'invalid_amount'; END IF;

  SELECT * INTO v_mkt FROM spot_markets WHERE symbol = 'PHON_USDT' AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'market_not_found'; END IF;

  v_price    := _assert_price_fresh('PHON_USDT');
  v_fee_rate := v_mkt.fee_rate::NUMERIC;
  v_gross    := v_usdt / v_price;
  v_fee      := v_gross * v_fee_rate;
  v_net      := v_gross - v_fee;

  v_usdt6 := trunc(v_usdt, 6);
  v_net6  := trunc(v_net, 6);
  v_fee6  := trunc(v_fee, 6);

  PERFORM _debit_wallet_internal(v_user_id, 'USDT', _fmt6(v_usdt6),
    'spot_buy_pay', 'spot_pay:' || v_trade_id::TEXT);
  PERFORM _credit_system_account('house_liquidity_usdt', _fmt6(v_usdt6),
    'spot_buy_liquidity', v_user_id, v_trade_id::TEXT, v_tid);

  PERFORM _credit_wallet_internal(v_user_id, 'PHON', _fmt6(v_net6),
    'spot_buy_recv', 'spot_recv:' || v_trade_id::TEXT);
  IF v_fee6 > 0 THEN
    PERFORM _credit_system_account('house_fee_phon', _fmt6(v_fee6),
      'spot_buy_fee', v_user_id, v_trade_id::TEXT, v_tid);
  END IF;
  PERFORM _debit_system_account('house_liquidity_phon', _fmt6(v_net6 + v_fee6),
    'spot_buy_liquidity', v_user_id, v_trade_id::TEXT, v_tid);

  INSERT INTO spot_trades (id, user_id, market, side, price, phon_amount, usdt_amount, fee_currency, fee_amount)
  VALUES (v_trade_id, v_user_id, 'PHON_USDT', 'buy', _fmt6(v_price), _fmt6(v_net6), _fmt6(v_usdt6), 'PHON', _fmt6(v_fee6));

  RETURN jsonb_build_object('trade_id', v_trade_id, 'side', 'buy', 'price', _fmt6(v_price),
    'usdt_spent', _fmt6(v_usdt6), 'phon_received', _fmt6(v_net6), 'fee_phon', _fmt6(v_fee6));
END;
$function$;

-- ─── rpc_spot_market_sell (guard p_phon_sold; cast moved into body) ───────────
CREATE OR REPLACE FUNCTION public.rpc_spot_market_sell(p_phon_sold text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id  UUID := auth.uid();
  v_mkt      spot_markets%ROWTYPE;
  v_price    NUMERIC;
  v_phon     NUMERIC;
  v_fee_rate NUMERIC;
  v_gross    NUMERIC;
  v_fee      NUMERIC;
  v_net      NUMERIC;
  v_phon6    NUMERIC;
  v_net6     NUMERIC;
  v_fee6     NUMERIC;
  v_trade_id UUID := gen_random_uuid();
  v_tid      UUID := gen_random_uuid();
BEGIN
  SET search_path = public, pg_temp;

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_spot_market_sell');
  PERFORM _assert_onboarding_consent(v_user_id);
  PERFORM _assert_amount_text(p_phon_sold);
  v_phon := p_phon_sold::NUMERIC;
  IF v_phon <= 0 THEN RAISE EXCEPTION 'invalid_amount'; END IF;

  SELECT * INTO v_mkt FROM spot_markets WHERE symbol = 'PHON_USDT' AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'market_not_found'; END IF;

  v_price    := _assert_price_fresh('PHON_USDT');
  v_fee_rate := v_mkt.fee_rate::NUMERIC;
  v_gross    := v_phon * v_price;
  v_fee      := v_gross * v_fee_rate;
  v_net      := v_gross - v_fee;

  v_phon6 := trunc(v_phon, 6);
  v_net6  := trunc(v_net, 6);
  v_fee6  := trunc(v_fee, 6);

  PERFORM _debit_wallet_internal(v_user_id, 'PHON', _fmt6(v_phon6),
    'spot_sell_pay', 'spot_pay:' || v_trade_id::TEXT);
  PERFORM _credit_system_account('house_liquidity_phon', _fmt6(v_phon6),
    'spot_sell_liquidity', v_user_id, v_trade_id::TEXT, v_tid);

  PERFORM _credit_wallet_internal(v_user_id, 'USDT', _fmt6(v_net6),
    'spot_sell_recv', 'spot_recv:' || v_trade_id::TEXT);
  IF v_fee6 > 0 THEN
    PERFORM _credit_system_account('house_fee_usdt', _fmt6(v_fee6),
      'spot_sell_fee', v_user_id, v_trade_id::TEXT, v_tid);
  END IF;
  PERFORM _debit_system_account('house_liquidity_usdt', _fmt6(v_net6 + v_fee6),
    'spot_sell_liquidity', v_user_id, v_trade_id::TEXT, v_tid);

  INSERT INTO spot_trades (id, user_id, market, side, price, phon_amount, usdt_amount, fee_currency, fee_amount)
  VALUES (v_trade_id, v_user_id, 'PHON_USDT', 'sell', _fmt6(v_price), _fmt6(v_phon6), _fmt6(v_net6), 'USDT', _fmt6(v_fee6));

  RETURN jsonb_build_object('trade_id', v_trade_id, 'side', 'sell', 'price', _fmt6(v_price),
    'phon_sold', _fmt6(v_phon6), 'usdt_received', _fmt6(v_net6), 'fee_usdt', _fmt6(v_fee6));
END;
$function$;

-- ─── rpc_stake_phon (guard p_amount; cast moved into body) ────────────────────
CREATE OR REPLACE FUNCTION public.rpc_stake_phon(p_term text, p_amount text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id  UUID := auth.uid();
  v_pool     staking_pools%ROWTYPE;
  v_amount   NUMERIC;
  v_pos_id   UUID := gen_random_uuid();
  v_unlock   TIMESTAMPTZ;
BEGIN
  SET search_path = public, pg_temp;

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_stake_phon');
  PERFORM _assert_onboarding_consent(v_user_id);
  PERFORM _assert_amount_text(p_amount);
  v_amount := p_amount::NUMERIC;
  IF v_amount <= 0 THEN RAISE EXCEPTION 'invalid_amount'; END IF;

  SELECT * INTO v_pool FROM staking_pools WHERE term = p_term::staking_term AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'pool_not_found'; END IF;

  PERFORM _lock_wallet_internal(v_user_id, 'PHON', _fmt6(v_amount),
    'staking_lock', 'stake_lock:' || v_pos_id::TEXT);

  IF v_pool.lock_days > 0 THEN
    v_unlock := NOW() + (v_pool.lock_days || ' days')::INTERVAL;
  END IF;

  INSERT INTO staking_positions (id, user_id, pool_id, term, principal, apr_snapshot, lock_days, unlock_at)
  VALUES (v_pos_id, v_user_id, v_pool.id, v_pool.term, _fmt6(v_amount), v_pool.estimated_apr, v_pool.lock_days, v_unlock);

  RETURN jsonb_build_object('position_id', v_pos_id, 'term', p_term,
    'principal', _fmt6(v_amount), 'apr', v_pool.estimated_apr, 'unlock_at', v_unlock);
END;
$function$;

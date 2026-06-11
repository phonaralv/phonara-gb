-- ============================================================
-- Migration: 20260609000007_phase3_trading_rpcs
-- Phase 3 Atomic RPCs: Futures, Spot, Staking
-- ============================================================
-- All settlement mirrors @phonara/trading-engine exactly.
-- All wallet mutations go through internal helpers (by user_id) so the
-- same code path serves self-close, admin and cron liquidation.
-- Amounts written to wallet_ledger are always positive (constraint).
-- ============================================================

-- ─── Formatting helper: truncate to 6 dp (matches engine toFixed) ────────────

CREATE OR REPLACE FUNCTION _fmt6(v NUMERIC)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT to_char(trunc(v, 6), 'FM999999999990.000000');
$$;

-- ─── Internal wallet helpers (by explicit user_id) ───────────────────────────

CREATE OR REPLACE FUNCTION _lock_wallet_internal(
  p_user_id UUID, p_currency currency, p_amount TEXT,
  p_reason_code TEXT, p_idempotency_key TEXT
)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_wallet wallets; v_entry_id UUID; v_avail_before TEXT; v_locked_before TEXT;
BEGIN
  SELECT id INTO v_entry_id FROM wallet_ledger WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_entry_id; END IF;

  IF auth.uid() = p_user_id THEN
    PERFORM _assert_account_activity_live(p_user_id);
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_found'; END IF;

  CASE p_currency
    WHEN 'PHON' THEN
      IF v_wallet.phon_available::NUMERIC < p_amount::NUMERIC THEN RAISE EXCEPTION 'insufficient_available' USING HINT='PHON'; END IF;
      v_avail_before := v_wallet.phon_available; v_locked_before := v_wallet.phon_locked;
      UPDATE wallets SET phon_available=(phon_available::NUMERIC-p_amount::NUMERIC)::TEXT,
                         phon_locked=(phon_locked::NUMERIC+p_amount::NUMERIC)::TEXT, version=version+1 WHERE id=v_wallet.id;
    WHEN 'USDT' THEN
      IF v_wallet.usdt_available::NUMERIC < p_amount::NUMERIC THEN RAISE EXCEPTION 'insufficient_available' USING HINT='USDT'; END IF;
      v_avail_before := v_wallet.usdt_available; v_locked_before := v_wallet.usdt_locked;
      UPDATE wallets SET usdt_available=(usdt_available::NUMERIC-p_amount::NUMERIC)::TEXT,
                         usdt_locked=(usdt_locked::NUMERIC+p_amount::NUMERIC)::TEXT, version=version+1 WHERE id=v_wallet.id;
    WHEN 'KRW' THEN
      IF v_wallet.krw_available::NUMERIC < p_amount::NUMERIC THEN RAISE EXCEPTION 'insufficient_available' USING HINT='KRW'; END IF;
      v_avail_before := v_wallet.krw_available; v_locked_before := v_wallet.krw_locked;
      UPDATE wallets SET krw_available=(krw_available::NUMERIC-p_amount::NUMERIC)::TEXT,
                         krw_locked=(krw_locked::NUMERIC+p_amount::NUMERIC)::TEXT, version=version+1 WHERE id=v_wallet.id;
  END CASE;

  INSERT INTO wallet_ledger (wallet_id,user_id,idempotency_key,direction,currency,amount,
    available_before,locked_before,available_after,locked_after,reason_code)
  SELECT v_wallet.id,p_user_id,p_idempotency_key,'lock',p_currency,p_amount,
    v_avail_before,v_locked_before,
    CASE p_currency WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available END,
    CASE p_currency WHEN 'PHON' THEN phon_locked WHEN 'USDT' THEN usdt_locked ELSE krw_locked END,
    p_reason_code
  FROM wallets WHERE id=v_wallet.id
  RETURNING id INTO v_entry_id;
  RETURN v_entry_id;
END;
$$;

CREATE OR REPLACE FUNCTION _unlock_wallet_internal(
  p_user_id UUID, p_currency currency, p_amount TEXT,
  p_reason_code TEXT, p_idempotency_key TEXT
)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_wallet wallets; v_entry_id UUID; v_avail_before TEXT; v_locked_before TEXT;
BEGIN
  SELECT id INTO v_entry_id FROM wallet_ledger WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_entry_id; END IF;

  IF auth.uid() = p_user_id THEN
    PERFORM _assert_account_activity_live(p_user_id);
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_found'; END IF;

  CASE p_currency
    WHEN 'PHON' THEN
      IF v_wallet.phon_locked::NUMERIC < p_amount::NUMERIC THEN RAISE EXCEPTION 'insufficient_locked' USING HINT='PHON'; END IF;
      v_avail_before := v_wallet.phon_available; v_locked_before := v_wallet.phon_locked;
      UPDATE wallets SET phon_locked=(phon_locked::NUMERIC-p_amount::NUMERIC)::TEXT,
                         phon_available=(phon_available::NUMERIC+p_amount::NUMERIC)::TEXT, version=version+1 WHERE id=v_wallet.id;
    WHEN 'USDT' THEN
      IF v_wallet.usdt_locked::NUMERIC < p_amount::NUMERIC THEN RAISE EXCEPTION 'insufficient_locked' USING HINT='USDT'; END IF;
      v_avail_before := v_wallet.usdt_available; v_locked_before := v_wallet.usdt_locked;
      UPDATE wallets SET usdt_locked=(usdt_locked::NUMERIC-p_amount::NUMERIC)::TEXT,
                         usdt_available=(usdt_available::NUMERIC+p_amount::NUMERIC)::TEXT, version=version+1 WHERE id=v_wallet.id;
    WHEN 'KRW' THEN
      IF v_wallet.krw_locked::NUMERIC < p_amount::NUMERIC THEN RAISE EXCEPTION 'insufficient_locked' USING HINT='KRW'; END IF;
      v_avail_before := v_wallet.krw_available; v_locked_before := v_wallet.krw_locked;
      UPDATE wallets SET krw_locked=(krw_locked::NUMERIC-p_amount::NUMERIC)::TEXT,
                         krw_available=(krw_available::NUMERIC+p_amount::NUMERIC)::TEXT, version=version+1 WHERE id=v_wallet.id;
  END CASE;

  INSERT INTO wallet_ledger (wallet_id,user_id,idempotency_key,direction,currency,amount,
    available_before,locked_before,available_after,locked_after,reason_code)
  SELECT v_wallet.id,p_user_id,p_idempotency_key,'unlock',p_currency,p_amount,
    v_avail_before,v_locked_before,
    CASE p_currency WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available END,
    CASE p_currency WHEN 'PHON' THEN phon_locked WHEN 'USDT' THEN usdt_locked ELSE krw_locked END,
    p_reason_code
  FROM wallets WHERE id=v_wallet.id
  RETURNING id INTO v_entry_id;
  RETURN v_entry_id;
END;
$$;

CREATE OR REPLACE FUNCTION _debit_wallet_internal(
  p_user_id UUID, p_currency currency, p_amount TEXT,
  p_reason_code TEXT, p_idempotency_key TEXT
)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_wallet wallets; v_entry_id UUID; v_avail_before TEXT; v_locked_before TEXT;
BEGIN
  SELECT id INTO v_entry_id FROM wallet_ledger WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_entry_id; END IF;

  IF auth.uid() = p_user_id THEN
    PERFORM _assert_account_activity_live(p_user_id);
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_found'; END IF;

  CASE p_currency
    WHEN 'PHON' THEN
      IF v_wallet.phon_available::NUMERIC < p_amount::NUMERIC THEN RAISE EXCEPTION 'insufficient_available' USING HINT='PHON'; END IF;
      v_avail_before := v_wallet.phon_available; v_locked_before := v_wallet.phon_locked;
      UPDATE wallets SET phon_available=(phon_available::NUMERIC-p_amount::NUMERIC)::TEXT, version=version+1 WHERE id=v_wallet.id;
    WHEN 'USDT' THEN
      IF v_wallet.usdt_available::NUMERIC < p_amount::NUMERIC THEN RAISE EXCEPTION 'insufficient_available' USING HINT='USDT'; END IF;
      v_avail_before := v_wallet.usdt_available; v_locked_before := v_wallet.usdt_locked;
      UPDATE wallets SET usdt_available=(usdt_available::NUMERIC-p_amount::NUMERIC)::TEXT, version=version+1 WHERE id=v_wallet.id;
    WHEN 'KRW' THEN
      IF v_wallet.krw_available::NUMERIC < p_amount::NUMERIC THEN RAISE EXCEPTION 'insufficient_available' USING HINT='KRW'; END IF;
      v_avail_before := v_wallet.krw_available; v_locked_before := v_wallet.krw_locked;
      UPDATE wallets SET krw_available=(krw_available::NUMERIC-p_amount::NUMERIC)::TEXT, version=version+1 WHERE id=v_wallet.id;
  END CASE;

  INSERT INTO wallet_ledger (wallet_id,user_id,idempotency_key,direction,currency,amount,
    available_before,locked_before,available_after,locked_after,reason_code)
  SELECT v_wallet.id,p_user_id,p_idempotency_key,'debit',p_currency,p_amount,
    v_avail_before,v_locked_before,
    CASE p_currency WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available END,
    CASE p_currency WHEN 'PHON' THEN phon_locked WHEN 'USDT' THEN usdt_locked ELSE krw_locked END,
    p_reason_code
  FROM wallets WHERE id=v_wallet.id
  RETURNING id INTO v_entry_id;
  RETURN v_entry_id;
END;
$$;

CREATE OR REPLACE FUNCTION _is_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin');
$$;

-- ─── rpc_open_futures_position ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_open_futures_position(
  p_market          TEXT,
  p_side            TEXT,
  p_margin_currency TEXT,
  p_margin_amount   TEXT,
  p_leverage        TEXT,
  p_stop_loss       TEXT DEFAULT NULL,
  p_take_profit     TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id    UUID := auth.uid();
  v_mkt        futures_markets%ROWTYPE;
  v_ccy        currency;
  v_side       position_side;
  v_margin     NUMERIC;
  v_lev        NUMERIC;
  v_entry      NUMERIC;
  v_mmr        NUMERIC;
  v_notional   NUMERIC;
  v_qty        NUMERIC;
  v_open_fee   NUMERIC;
  v_inv_lev    NUMERIC;
  v_liq        NUMERIC;
  v_pos_id     UUID := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

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
  IF v_lev < 1 THEN RAISE EXCEPTION 'invalid_leverage'; END IF;
  IF v_lev > v_mkt.max_leverage::NUMERIC THEN RAISE EXCEPTION 'leverage_too_high'; END IF;

  SELECT price::NUMERIC INTO v_entry FROM oracle_prices WHERE symbol = p_market;
  IF v_entry IS NULL OR v_entry <= 0 THEN RAISE EXCEPTION 'no_price'; END IF;

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

  -- Lock margin, then charge open fee from available.
  PERFORM _lock_wallet_internal(v_user_id, v_ccy, _fmt6(v_margin),
    'futures_margin_lock', 'fut_margin:' || v_pos_id::TEXT);

  IF trunc(v_open_fee, 6) > 0 THEN
    PERFORM _debit_wallet_internal(v_user_id, v_ccy, _fmt6(v_open_fee),
      'futures_open_fee', 'fut_openfee:' || v_pos_id::TEXT);
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
    'position_id', v_pos_id,
    'market', p_market,
    'side', p_side,
    'entry_price', _fmt6(v_entry),
    'quantity', _fmt6(v_qty),
    'notional', _fmt6(v_notional),
    'open_fee', _fmt6(v_open_fee),
    'liquidation_price', _fmt6(v_liq)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_open_futures_position(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO authenticated;

-- ─── Internal settlement (shared by close + liquidate) ───────────────────────

CREATE OR REPLACE FUNCTION _settle_futures_position(
  p_pos_id   UUID,
  p_exit     NUMERIC,
  p_status   position_status,
  p_event    TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_pos        futures_positions%ROWTYPE;
  v_qty        NUMERIC;
  v_entry      NUMERIC;
  v_margin     NUMERIC;
  v_pnl        NUMERIC;
  v_close_fee  NUMERIC;
  v_equity     NUMERIC;
  v_adjust     NUMERIC;
  v_close_rate NUMERIC;
BEGIN
  SELECT * INTO v_pos FROM futures_positions WHERE id = p_pos_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_pos.status <> 'open' THEN RAISE EXCEPTION 'position_not_open'; END IF;

  SELECT close_fee_rate::NUMERIC INTO v_close_rate FROM futures_markets WHERE symbol = v_pos.market;

  v_qty    := v_pos.quantity::NUMERIC;
  v_entry  := v_pos.entry_price::NUMERIC;
  v_margin := v_pos.margin_amount::NUMERIC;

  IF v_pos.side = 'long' THEN
    v_pnl := v_qty * (p_exit - v_entry);
  ELSE
    v_pnl := v_qty * (v_entry - p_exit);
  END IF;

  v_close_fee := (v_qty * p_exit) * v_close_rate;
  v_equity := v_margin + v_pnl - v_close_fee;
  IF v_equity < 0 THEN v_equity := 0; END IF;

  -- Return the locked margin to available, then apply net adjustment.
  PERFORM _unlock_wallet_internal(v_pos.user_id, v_pos.margin_currency, _fmt6(v_margin),
    'futures_margin_unlock', 'fut_unlock:' || p_pos_id::TEXT);

  v_adjust := v_equity - v_margin;
  IF trunc(v_adjust, 6) > 0 THEN
    PERFORM _credit_wallet_internal(v_pos.user_id, v_pos.margin_currency, _fmt6(v_adjust),
      'futures_pnl', 'fut_pnl:' || p_pos_id::TEXT);
  ELSIF trunc(v_adjust, 6) < 0 THEN
    PERFORM _debit_wallet_internal(v_pos.user_id, v_pos.margin_currency, _fmt6(abs(v_adjust)),
      'futures_pnl', 'fut_pnl:' || p_pos_id::TEXT);
  END IF;

  UPDATE futures_positions SET
    status          = p_status,
    exit_price      = _fmt6(p_exit),
    realized_pnl    = _fmt6(v_pnl),
    close_fee       = _fmt6(v_close_fee),
    equity_returned = _fmt6(v_equity),
    closed_at       = NOW()
  WHERE id = p_pos_id;

  INSERT INTO position_ledger (position_id, user_id, event, price, realized_pnl, fee)
  VALUES (p_pos_id, v_pos.user_id, p_event, _fmt6(p_exit), _fmt6(v_pnl), _fmt6(v_close_fee));

  RETURN jsonb_build_object(
    'position_id', p_pos_id,
    'status', p_status,
    'exit_price', _fmt6(p_exit),
    'realized_pnl', _fmt6(v_pnl),
    'close_fee', _fmt6(v_close_fee),
    'equity_returned', _fmt6(v_equity)
  );
END;
$$;

-- ─── rpc_close_futures_position ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_close_futures_position(p_position_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_pos     futures_positions%ROWTYPE;
  v_exit    NUMERIC;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  SELECT * INTO v_pos FROM futures_positions WHERE id = p_position_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_pos.user_id <> v_user_id THEN RAISE EXCEPTION 'forbidden'; END IF;

  SELECT price::NUMERIC INTO v_exit FROM oracle_prices WHERE symbol = v_pos.market;
  IF v_exit IS NULL OR v_exit <= 0 THEN RAISE EXCEPTION 'no_price'; END IF;

  RETURN _settle_futures_position(p_position_id, v_exit, 'closed', 'close');
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_close_futures_position(UUID) TO authenticated;

-- ─── rpc_liquidate_position (owner or admin) ─────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_liquidate_position(p_position_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_pos     futures_positions%ROWTYPE;
  v_mark    NUMERIC;
  v_liq     NUMERIC;
  v_hit     BOOLEAN;
BEGIN
  SELECT * INTO v_pos FROM futures_positions WHERE id = p_position_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_user_id IS NOT NULL AND v_pos.user_id <> v_user_id AND NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT price::NUMERIC INTO v_mark FROM oracle_prices WHERE symbol = v_pos.market;
  IF v_mark IS NULL OR v_mark <= 0 THEN RAISE EXCEPTION 'no_price'; END IF;

  v_liq := v_pos.liquidation_price::NUMERIC;
  IF v_pos.side = 'long' THEN
    v_hit := v_mark <= v_liq;
  ELSE
    v_hit := v_mark >= v_liq;
  END IF;
  IF NOT v_hit THEN RAISE EXCEPTION 'not_liquidatable'; END IF;

  RETURN _settle_futures_position(p_position_id, v_mark, 'liquidated', 'liquidate');
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_liquidate_position(UUID) TO authenticated;

-- ─── rpc_spot_market_buy / sell ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_spot_market_buy(p_usdt_spent TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_mkt      spot_markets%ROWTYPE;
  v_price    NUMERIC;
  v_usdt     NUMERIC := p_usdt_spent::NUMERIC;
  v_fee_rate NUMERIC;
  v_gross    NUMERIC;
  v_fee      NUMERIC;
  v_net      NUMERIC;
  v_trade_id UUID := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF v_usdt <= 0 THEN RAISE EXCEPTION 'invalid_amount'; END IF;

  SELECT * INTO v_mkt FROM spot_markets WHERE symbol = 'PHON_USDT' AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'market_not_found'; END IF;
  SELECT price::NUMERIC INTO v_price FROM oracle_prices WHERE symbol = 'PHON_USDT';
  IF v_price IS NULL OR v_price <= 0 THEN RAISE EXCEPTION 'no_price'; END IF;

  v_fee_rate := v_mkt.fee_rate::NUMERIC;
  v_gross := v_usdt / v_price;
  v_fee   := v_gross * v_fee_rate;
  v_net   := v_gross - v_fee;

  -- Pay USDT, receive PHON
  PERFORM _debit_wallet_internal(v_user_id, 'USDT', _fmt6(v_usdt),
    'spot_buy_pay', 'spot_pay:' || v_trade_id::TEXT);
  PERFORM _credit_wallet_internal(v_user_id, 'PHON', _fmt6(v_net),
    'spot_buy_recv', 'spot_recv:' || v_trade_id::TEXT);

  INSERT INTO spot_trades (id, user_id, market, side, price, phon_amount, usdt_amount, fee_currency, fee_amount)
  VALUES (v_trade_id, v_user_id, 'PHON_USDT', 'buy', _fmt6(v_price), _fmt6(v_net), _fmt6(v_usdt), 'PHON', _fmt6(v_fee));

  RETURN jsonb_build_object('trade_id', v_trade_id, 'side', 'buy', 'price', _fmt6(v_price),
    'usdt_spent', _fmt6(v_usdt), 'phon_received', _fmt6(v_net), 'fee_phon', _fmt6(v_fee));
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_spot_market_buy(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_spot_market_sell(p_phon_sold TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_mkt      spot_markets%ROWTYPE;
  v_price    NUMERIC;
  v_phon     NUMERIC := p_phon_sold::NUMERIC;
  v_fee_rate NUMERIC;
  v_gross    NUMERIC;
  v_fee      NUMERIC;
  v_net      NUMERIC;
  v_trade_id UUID := gen_random_uuid();
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF v_phon <= 0 THEN RAISE EXCEPTION 'invalid_amount'; END IF;

  SELECT * INTO v_mkt FROM spot_markets WHERE symbol = 'PHON_USDT' AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'market_not_found'; END IF;
  SELECT price::NUMERIC INTO v_price FROM oracle_prices WHERE symbol = 'PHON_USDT';
  IF v_price IS NULL OR v_price <= 0 THEN RAISE EXCEPTION 'no_price'; END IF;

  v_fee_rate := v_mkt.fee_rate::NUMERIC;
  v_gross := v_phon * v_price;
  v_fee   := v_gross * v_fee_rate;
  v_net   := v_gross - v_fee;

  -- Pay PHON, receive USDT
  PERFORM _debit_wallet_internal(v_user_id, 'PHON', _fmt6(v_phon),
    'spot_sell_pay', 'spot_pay:' || v_trade_id::TEXT);
  PERFORM _credit_wallet_internal(v_user_id, 'USDT', _fmt6(v_net),
    'spot_sell_recv', 'spot_recv:' || v_trade_id::TEXT);

  INSERT INTO spot_trades (id, user_id, market, side, price, phon_amount, usdt_amount, fee_currency, fee_amount)
  VALUES (v_trade_id, v_user_id, 'PHON_USDT', 'sell', _fmt6(v_price), _fmt6(v_phon), _fmt6(v_net), 'USDT', _fmt6(v_fee));

  RETURN jsonb_build_object('trade_id', v_trade_id, 'side', 'sell', 'price', _fmt6(v_price),
    'phon_sold', _fmt6(v_phon), 'usdt_received', _fmt6(v_net), 'fee_usdt', _fmt6(v_fee));
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_spot_market_sell(TEXT) TO authenticated;

-- ─── rpc_stake_phon ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_stake_phon(p_term TEXT, p_amount TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_pool     staking_pools%ROWTYPE;
  v_amount   NUMERIC := p_amount::NUMERIC;
  v_pos_id   UUID := gen_random_uuid();
  v_unlock   TIMESTAMPTZ;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
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
$$;

GRANT EXECUTE ON FUNCTION rpc_stake_phon(TEXT,TEXT) TO authenticated;

-- ─── rpc_claim_staking_reward ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_claim_staking_reward(p_position_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_pos      staking_positions%ROWTYPE;
  v_accrued  NUMERIC;
  v_claimed  NUMERIC;
  v_payable  NUMERIC;
  v_elapsed_days NUMERIC;
  v_reward_id UUID := gen_random_uuid();
  v_ledger_id UUID;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  SELECT * INTO v_pos FROM staking_positions WHERE id = p_position_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_pos.user_id <> v_user_id THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF v_pos.status <> 'active' THEN RAISE EXCEPTION 'not_active'; END IF;

  v_elapsed_days := EXTRACT(EPOCH FROM (NOW() - v_pos.staked_at)) / 86400.0;
  v_accrued := v_pos.principal::NUMERIC * v_pos.apr_snapshot::NUMERIC * (v_elapsed_days / 365.0);
  v_claimed := v_pos.reward_claimed::NUMERIC;
  v_payable := v_accrued - v_claimed;

  IF trunc(v_payable, 6) <= 0 THEN
    RETURN jsonb_build_object('claimed', FALSE, 'reason', 'nothing_to_claim', 'reward', '0.000000');
  END IF;

  v_ledger_id := _credit_wallet_internal(v_user_id, 'PHON', _fmt6(v_payable),
    'staking_reward', 'stake_reward:' || v_reward_id::TEXT);

  INSERT INTO staking_rewards (id, staking_position_id, user_id, reward_amount, ledger_entry_id)
  VALUES (v_reward_id, p_position_id, v_user_id, _fmt6(v_payable), v_ledger_id);

  UPDATE staking_positions SET reward_claimed = _fmt6(v_claimed + v_payable) WHERE id = p_position_id;

  RETURN jsonb_build_object('claimed', TRUE, 'reward', _fmt6(v_payable),
    'total_claimed', _fmt6(v_claimed + v_payable));
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_claim_staking_reward(UUID) TO authenticated;

-- ─── rpc_unstake_phon (unlock principal + auto-claim remaining reward) ────────

CREATE OR REPLACE FUNCTION rpc_unstake_phon(p_position_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_pos      staking_positions%ROWTYPE;
  v_accrued  NUMERIC;
  v_claimed  NUMERIC;
  v_payable  NUMERIC;
  v_elapsed_days NUMERIC;
  v_reward_id UUID := gen_random_uuid();
  v_ledger_id UUID;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  SELECT * INTO v_pos FROM staking_positions WHERE id = p_position_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_pos.user_id <> v_user_id THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF v_pos.status <> 'active' THEN RAISE EXCEPTION 'not_active'; END IF;

  IF v_pos.lock_days > 0 AND v_pos.unlock_at IS NOT NULL AND NOW() < v_pos.unlock_at THEN
    RAISE EXCEPTION 'still_locked';
  END IF;

  -- settle remaining reward
  v_elapsed_days := EXTRACT(EPOCH FROM (NOW() - v_pos.staked_at)) / 86400.0;
  v_accrued := v_pos.principal::NUMERIC * v_pos.apr_snapshot::NUMERIC * (v_elapsed_days / 365.0);
  v_claimed := v_pos.reward_claimed::NUMERIC;
  v_payable := v_accrued - v_claimed;

  IF trunc(v_payable, 6) > 0 THEN
    v_ledger_id := _credit_wallet_internal(v_user_id, 'PHON', _fmt6(v_payable),
      'staking_reward', 'stake_reward:' || v_reward_id::TEXT);
    INSERT INTO staking_rewards (id, staking_position_id, user_id, reward_amount, ledger_entry_id)
    VALUES (v_reward_id, p_position_id, v_user_id, _fmt6(v_payable), v_ledger_id);
  ELSE
    v_payable := 0;
  END IF;

  -- unlock principal
  PERFORM _unlock_wallet_internal(v_user_id, 'PHON', v_pos.principal,
    'staking_unlock', 'stake_unlock:' || p_position_id::TEXT);

  UPDATE staking_positions SET
    status = 'unstaked',
    reward_claimed = _fmt6(v_claimed + v_payable),
    unstaked_at = NOW()
  WHERE id = p_position_id;

  RETURN jsonb_build_object('unstaked', TRUE, 'principal_returned', v_pos.principal,
    'final_reward', _fmt6(v_payable));
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_unstake_phon(UUID) TO authenticated;

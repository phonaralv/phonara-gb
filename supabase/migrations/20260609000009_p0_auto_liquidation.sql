-- ============================================================
-- Migration: 20260609000009_p0_auto_liquidation
-- A2: Auto-liquidation engine
-- ─ Uses _settle_futures_position (existing, Phase 3)
-- ─ Adds: insurance fund absorption for bad debt
-- ─ Adds: _credit_system_account / _debit_system_account helpers
-- ─ Adds: rpc_run_liquidations (called by Edge Function / pg_cron)
-- ─ Patches: rpc_open/close to use _assert_price_fresh + rate limits
-- ─ Patches: _settle_futures_position to route fees → house account
-- ============================================================
-- NOTE: _settle_futures_position is replaced (CREATE OR REPLACE).
--       All existing behaviour is preserved; fee routing and insurance
--       fund are the only net additions.
-- ============================================================

SET search_path = public, pg_temp;

-- ─────────────────────────────────────────────────────────────────────────────
-- System account helpers (internal, SECURITY DEFINER)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _credit_system_account(
  p_code        TEXT,
  p_amount      TEXT,
  p_reason_code TEXT,
  p_related_user_id UUID DEFAULT NULL,
  p_related_tx_id   TEXT DEFAULT NULL,
  p_transfer_id     UUID DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_before TEXT;
  v_after  TEXT;
BEGIN
  SET search_path = public, pg_temp;

  SELECT balance INTO v_before FROM system_accounts WHERE code = p_code FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'system_account_not_found' USING HINT = p_code; END IF;

  v_after := (v_before::NUMERIC + p_amount::NUMERIC)::TEXT;

  UPDATE system_accounts SET balance = v_after, updated_at = NOW() WHERE code = p_code;

  INSERT INTO system_account_ledger
    (account_code, direction, currency, amount, balance_before, balance_after,
     reason_code, related_user_id, related_tx_id, transfer_id)
  SELECT p_code, 'credit',
    (SELECT currency FROM system_accounts WHERE code = p_code),
    p_amount, v_before, v_after,
    p_reason_code, p_related_user_id, p_related_tx_id, p_transfer_id;
END;
$$;

CREATE OR REPLACE FUNCTION _debit_system_account(
  p_code        TEXT,
  p_amount      TEXT,
  p_reason_code TEXT,
  p_related_user_id UUID DEFAULT NULL,
  p_related_tx_id   TEXT DEFAULT NULL,
  p_transfer_id     UUID DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_before TEXT;
  v_after  TEXT;
BEGIN
  SET search_path = public, pg_temp;

  SELECT balance INTO v_before FROM system_accounts WHERE code = p_code FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'system_account_not_found' USING HINT = p_code; END IF;

  -- Internal system accounts MAY go negative (they are the house side: counterparty,
  -- liquidity, mint). A negative balance is a house liability, never an error. This
  -- is what guarantees liveness: settling a winning user / bad-debt liquidation can
  -- never be blocked by an "insufficient" house balance.
  v_after := (v_before::NUMERIC - p_amount::NUMERIC)::TEXT;

  UPDATE system_accounts SET balance = v_after, updated_at = NOW() WHERE code = p_code;

  INSERT INTO system_account_ledger
    (account_code, direction, currency, amount, balance_before, balance_after,
     reason_code, related_user_id, related_tx_id, transfer_id)
  SELECT p_code, 'debit',
    (SELECT currency FROM system_accounts WHERE code = p_code),
    p_amount, v_before, v_after,
    p_reason_code, p_related_user_id, p_related_tx_id, p_transfer_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: _settle_futures_position
-- Adds:
--   1. Fee routing to house_fee_<currency> system account
--   2. Insurance fund absorption when equity would go negative (bad debt)
--   3. transfer_id pairing for wallet_ledger ↔ system_account_ledger
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _settle_futures_position(
  p_pos_id   UUID,
  p_exit     NUMERIC,
  p_status   position_status,
  p_event    TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_pos          futures_positions%ROWTYPE;
  v_qty          NUMERIC;
  v_entry        NUMERIC;
  v_margin       NUMERIC;
  v_pnl          NUMERIC;
  v_close_fee    NUMERIC;
  v_gross_equity NUMERIC;
  v_equity       NUMERIC;
  v_adjust       NUMERIC;
  v_close_rate   NUMERIC;
  v_bad_debt     NUMERIC := 0;
  v_fee_account  TEXT;
  v_ins_account  TEXT;
  v_tid          UUID := gen_random_uuid();  -- transfer_id pairing
  -- 6dp-quantized legs (these are the exact amounts written to ledgers)
  v_u6           NUMERIC;   -- user delta (signed)
  v_h6           NUMERIC;   -- house fee  (>= 0)
  v_ins6         NUMERIC;   -- insurance counterparty delta (signed)
  v_dust6        NUMERIC;   -- residual so that u + h + ins + dust = 0 exactly
BEGIN
  SET search_path = public, pg_temp;

  SELECT * INTO v_pos FROM futures_positions WHERE id = p_pos_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_pos.status <> 'open' THEN RAISE EXCEPTION 'position_not_open'; END IF;

  v_fee_account := 'house_fee_'      || lower(v_pos.margin_currency::TEXT);
  v_ins_account := 'insurance_fund_' || lower(v_pos.margin_currency::TEXT);

  SELECT close_fee_rate::NUMERIC INTO v_close_rate FROM futures_markets WHERE symbol = v_pos.market;

  v_qty    := v_pos.quantity::NUMERIC;
  v_entry  := v_pos.entry_price::NUMERIC;
  v_margin := v_pos.margin_amount::NUMERIC;

  IF v_pos.side = 'long' THEN
    v_pnl := v_qty * (p_exit - v_entry);
  ELSE
    v_pnl := v_qty * (v_entry - p_exit);
  END IF;

  v_close_fee    := (v_qty * p_exit) * v_close_rate;
  v_gross_equity := v_margin + v_pnl - v_close_fee;

  -- Equity the user keeps is floored at 0. Any shortfall below 0 is "bad debt":
  -- the loss the user could not cover. In a house-as-counterparty model this is
  -- simply uncollectible upside for the house — it never created money, so it is
  -- recorded as a METRIC only (no balance movement, hence no liveness trap).
  IF v_gross_equity < 0 THEN
    v_bad_debt := -v_gross_equity;
    v_equity   := 0;
  ELSE
    v_equity   := v_gross_equity;
  END IF;

  -- ── Conservation decomposition (raw) ──────────────────────────────────────
  --   user_delta = equity - margin                       (what the user nets)
  --   house      = close_fee                             (platform revenue)
  --   insurance  = (margin - equity) - close_fee         (residual counterparty)
  --   => user + house + insurance == 0  (raw, before rounding)
  --   Normal:    insurance = -pnl
  --   Bad debt:  insurance = margin - close_fee  (the collectible amount only)
  --
  -- Quantize to 6dp. The user leg MUST equal the verified engine's payout, which is
  -- t6(equity) - margin (the engine truncates *equity* first, then returns it). So we
  -- truncate equity before subtracting margin (margin is already 6dp → result is exact
  -- 6dp). Insurance uses t6 of the RAW residual so it equals -pnl economically; dust
  -- absorbs the tiny truncation difference so the ledger nets to EXACTLY zero at 6dp.
  v_adjust := trunc(v_equity, 6) - v_margin;
  v_u6   := trunc(v_adjust, 6);
  v_h6   := trunc(v_close_fee, 6);
  v_ins6 := trunc((v_margin - v_equity) - v_close_fee, 6);
  v_dust6 := -(v_u6 + v_h6 + v_ins6);

  -- 1. Unlock margin → available (within-wallet move, net user total unchanged)
  PERFORM _unlock_wallet_internal(v_pos.user_id, v_pos.margin_currency, _fmt6(v_margin),
    'futures_margin_unlock', 'fut_unlock:' || p_pos_id::TEXT);

  -- 2. User PnL adjustment (exactly v_u6)
  IF v_u6 > 0 THEN
    PERFORM _credit_wallet_internal(v_pos.user_id, v_pos.margin_currency, _fmt6(v_u6),
      'futures_pnl', 'fut_pnl:' || p_pos_id::TEXT);
  ELSIF v_u6 < 0 THEN
    PERFORM _debit_wallet_internal(v_pos.user_id, v_pos.margin_currency, _fmt6(abs(v_u6)),
      'futures_pnl', 'fut_pnl:' || p_pos_id::TEXT);
  END IF;

  -- 3. House fee leg
  IF v_h6 > 0 THEN
    PERFORM _credit_system_account(v_fee_account, _fmt6(v_h6),
      'futures_close_fee', v_pos.user_id, p_pos_id::TEXT, v_tid);
  END IF;

  -- 4. Insurance counterparty leg (may go negative when the user profits)
  IF v_ins6 > 0 THEN
    PERFORM _credit_system_account(v_ins_account, _fmt6(v_ins6),
      'futures_counterparty', v_pos.user_id, p_pos_id::TEXT, v_tid);
  ELSIF v_ins6 < 0 THEN
    PERFORM _debit_system_account(v_ins_account, _fmt6(abs(v_ins6)),
      'futures_counterparty', v_pos.user_id, p_pos_id::TEXT, v_tid);
  END IF;

  -- 5. Dust leg — captures 6dp truncation residue; keeps Σ exactly 0
  IF v_dust6 > 0 THEN
    PERFORM _credit_system_account('dust_' || lower(v_pos.margin_currency::TEXT), _fmt6(v_dust6),
      'rounding_dust', v_pos.user_id, p_pos_id::TEXT, v_tid);
  ELSIF v_dust6 < 0 THEN
    PERFORM _debit_system_account('dust_' || lower(v_pos.margin_currency::TEXT), _fmt6(abs(v_dust6)),
      'rounding_dust', v_pos.user_id, p_pos_id::TEXT, v_tid);
  END IF;

  -- 6. Update position record
  UPDATE futures_positions SET
    status          = p_status,
    exit_price      = _fmt6(p_exit),
    realized_pnl    = _fmt6(v_pnl),
    close_fee       = _fmt6(v_close_fee),
    equity_returned = _fmt6(v_equity),
    closed_at       = NOW()
  WHERE id = p_pos_id;

  INSERT INTO position_ledger (position_id, user_id, event, price, realized_pnl, fee, payload)
  VALUES (p_pos_id, v_pos.user_id, p_event, _fmt6(p_exit), _fmt6(v_pnl), _fmt6(v_close_fee),
    jsonb_build_object('bad_debt', _fmt6(v_bad_debt), 'transfer_id', v_tid));

  RETURN jsonb_build_object(
    'position_id',    p_pos_id,
    'status',         p_status,
    'exit_price',     _fmt6(p_exit),
    'realized_pnl',   _fmt6(v_pnl),
    'close_fee',      _fmt6(v_close_fee),
    'equity_returned',_fmt6(v_equity),
    'bad_debt',       _fmt6(v_bad_debt)
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2: rpc_run_liquidations
-- ─────────────────────────────────────────────────────────────────────────────
-- Called by pg_cron every minute OR by the Edge Function liquidation-worker.
-- Scans all open positions for each active market and liquidates those that
-- have crossed their liquidation_price at the current mark price.
-- Returns a summary JSONB of how many positions were liquidated / errored.
--
-- Design: runs inside a single transaction. Each position is settled inside a
-- BEGIN/EXCEPTION block (implicit savepoint) so one failure does not abort the rest.

CREATE OR REPLACE FUNCTION rpc_run_liquidations()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_symbol      TEXT;
  v_mark        NUMERIC;
  v_pos         futures_positions%ROWTYPE;
  v_liq         NUMERIC;
  v_should_liq  BOOLEAN;
  v_liquidated  INT := 0;
  v_skipped     INT := 0;
  v_errors      INT := 0;
  v_detail      JSONB := '[]'::JSONB;
  v_result      JSONB;
  v_err_msg     TEXT;
BEGIN
  SET search_path = public, pg_temp;

  -- Authorization: only the service role (auth.uid() IS NULL, used by the Edge
  -- Function / pg_cron) or an admin may run the liquidation sweep. This prevents
  -- ordinary authenticated users from triggering expensive full-table scans.
  IF auth.uid() IS NOT NULL AND NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  -- Iterate each active, non-halted futures market
  FOR v_symbol IN
    SELECT fm.symbol
    FROM futures_markets fm
    JOIN market_circuit_breakers mcb ON mcb.symbol = fm.symbol
    WHERE fm.is_active AND NOT mcb.is_halted
  LOOP
    -- Get fresh mark price (skip if stale / missing)
    BEGIN
      v_mark := _assert_price_fresh(v_symbol);
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END;

    -- Scan open positions for this market
    FOR v_pos IN
      SELECT * FROM futures_positions
      WHERE market = v_symbol AND status = 'open'
      FOR UPDATE SKIP LOCKED
    LOOP
      v_liq := v_pos.liquidation_price::NUMERIC;

      v_should_liq :=
        (v_pos.side = 'long'  AND v_mark <= v_liq) OR
        (v_pos.side = 'short' AND v_mark >= v_liq);

      IF NOT v_should_liq THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      -- Attempt settlement inside a BEGIN/EXCEPTION block. In PL/pgSQL this block
      -- automatically establishes an internal savepoint and rolls back to it if any
      -- exception is raised, so one bad position cannot abort the whole batch.
      -- (Explicit SAVEPOINT / ROLLBACK TO SAVEPOINT are NOT allowed inside functions.)
      BEGIN
        PERFORM _settle_futures_position(v_pos.id, v_mark, 'liquidated', 'auto_liquidate');
        v_liquidated := v_liquidated + 1;
        v_detail     := v_detail || jsonb_build_object(
          'position_id', v_pos.id, 'user_id', v_pos.user_id,
          'market', v_symbol, 'side', v_pos.side, 'mark', _fmt6(v_mark)
        );
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
        v_errors := v_errors + 1;
        v_detail := v_detail || jsonb_build_object(
          'position_id', v_pos.id, 'error', v_err_msg
        );
      END;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'liquidated', v_liquidated,
    'skipped',    v_skipped,
    'errors',     v_errors,
    'detail',     v_detail,
    'ran_at',     NOW()
  );
END;
$$;

-- Least privilege: do NOT grant to authenticated. The Edge Function / pg_cron
-- call this with the service role (which bypasses GRANTs). Admins can still call
-- it because the in-body guard allows _is_admin(), but we avoid a blanket grant.
REVOKE ALL ON FUNCTION rpc_run_liquidations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_run_liquidations() TO service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: rpc_open_futures_position — add staleness guard + rate limit
-- ─────────────────────────────────────────────────────────────────────────────

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

  -- Staleness + circuit breaker guard (replaces bare oracle_prices lookup)
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
    -- Route open fee to house account
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
$$;

GRANT EXECUTE ON FUNCTION rpc_open_futures_position(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: rpc_close_futures_position — add staleness guard + rate limit
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_close_futures_position(p_position_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_pos     futures_positions%ROWTYPE;
  v_exit    NUMERIC;
BEGIN
  SET search_path = public, pg_temp;

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_close_futures_position');

  SELECT * INTO v_pos FROM futures_positions WHERE id = p_position_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_pos.user_id <> v_user_id THEN RAISE EXCEPTION 'forbidden'; END IF;

  v_exit := _assert_price_fresh(v_pos.market);

  RETURN _settle_futures_position(p_position_id, v_exit, 'closed', 'close');
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_close_futures_position(UUID) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: rpc_spot_market_buy — add staleness guard + fee routing + rate limit
-- ─────────────────────────────────────────────────────────────────────────────

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
  IF v_usdt <= 0 THEN RAISE EXCEPTION 'invalid_amount'; END IF;

  SELECT * INTO v_mkt FROM spot_markets WHERE symbol = 'PHON_USDT' AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'market_not_found'; END IF;

  v_price    := _assert_price_fresh('PHON_USDT');
  v_fee_rate := v_mkt.fee_rate::NUMERIC;
  v_gross    := v_usdt / v_price;
  v_fee      := v_gross * v_fee_rate;
  v_net      := v_gross - v_fee;

  -- 6dp-quantized legs (exact amounts written)
  v_usdt6 := trunc(v_usdt, 6);
  v_net6  := trunc(v_net, 6);
  v_fee6  := trunc(v_fee, 6);

  -- USDT side: user pays usdt6, house liquidity receives usdt6 (Σ_USDT = 0 exactly)
  PERFORM _debit_wallet_internal(v_user_id, 'USDT', _fmt6(v_usdt6),
    'spot_buy_pay', 'spot_pay:' || v_trade_id::TEXT);
  PERFORM _credit_system_account('house_liquidity_usdt', _fmt6(v_usdt6),
    'spot_buy_liquidity', v_user_id, v_trade_id::TEXT, v_tid);

  -- PHON side: user receives net6; house_fee gets fee6; liquidity pays out (net6+fee6)
  --            (Σ_PHON = net6 + fee6 - (net6+fee6) = 0 exactly)
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
$$;

GRANT EXECUTE ON FUNCTION rpc_spot_market_buy(TEXT) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: rpc_spot_market_sell — add staleness guard + fee routing + rate limit
-- ─────────────────────────────────────────────────────────────────────────────

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

  -- PHON side: user pays phon6, house liquidity receives phon6 (Σ_PHON = 0 exactly)
  PERFORM _debit_wallet_internal(v_user_id, 'PHON', _fmt6(v_phon6),
    'spot_sell_pay', 'spot_pay:' || v_trade_id::TEXT);
  PERFORM _credit_system_account('house_liquidity_phon', _fmt6(v_phon6),
    'spot_sell_liquidity', v_user_id, v_trade_id::TEXT, v_tid);

  -- USDT side: user receives net6; house_fee gets fee6; liquidity pays out (net6+fee6)
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
$$;

GRANT EXECUTE ON FUNCTION rpc_spot_market_sell(TEXT) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: _credit_wallet_internal — track reward issuance in system account
-- ─────────────────────────────────────────────────────────────────────────────
-- When reason_code starts with 'staking_reward' or 'bonus' or 'reward',
-- mirror the credit to reward_issuance_phon so dilution is tracked.
-- We add a minimal wrapper that calls the existing function.
-- (reward_issuance_phon tracks total PHON emitted, not a withdrawal.)

CREATE OR REPLACE FUNCTION _credit_wallet_internal(
  p_user_id UUID, p_currency currency, p_amount TEXT,
  p_reason_code TEXT, p_idempotency_key TEXT
)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_wallet wallets;
  v_entry_id UUID;
  v_avail_before TEXT;
  v_locked_before TEXT;
BEGIN
  SET search_path = public, pg_temp;

  SELECT id INTO v_entry_id FROM wallet_ledger WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_entry_id; END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_found'; END IF;

  CASE p_currency
    WHEN 'PHON' THEN
      v_avail_before := v_wallet.phon_available; v_locked_before := v_wallet.phon_locked;
      UPDATE wallets SET phon_available=(phon_available::NUMERIC+p_amount::NUMERIC)::TEXT,
                         version=version+1 WHERE id=v_wallet.id;
    WHEN 'USDT' THEN
      v_avail_before := v_wallet.usdt_available; v_locked_before := v_wallet.usdt_locked;
      UPDATE wallets SET usdt_available=(usdt_available::NUMERIC+p_amount::NUMERIC)::TEXT,
                         version=version+1 WHERE id=v_wallet.id;
    WHEN 'KRW' THEN
      v_avail_before := v_wallet.krw_available; v_locked_before := v_wallet.krw_locked;
      UPDATE wallets SET krw_available=(krw_available::NUMERIC+p_amount::NUMERIC)::TEXT,
                         version=version+1 WHERE id=v_wallet.id;
  END CASE;

  INSERT INTO wallet_ledger (wallet_id,user_id,idempotency_key,direction,currency,amount,
    available_before,locked_before,available_after,locked_after,reason_code)
  SELECT v_wallet.id,p_user_id,p_idempotency_key,'credit',p_currency,p_amount,
    v_avail_before,v_locked_before,
    CASE p_currency WHEN 'PHON' THEN phon_available WHEN 'USDT' THEN usdt_available ELSE krw_available END,
    CASE p_currency WHEN 'PHON' THEN phon_locked WHEN 'USDT' THEN usdt_locked ELSE krw_locked END,
    p_reason_code
  FROM wallets WHERE id=v_wallet.id
  RETURNING id INTO v_entry_id;

  -- Mint accounting: when PHON is ISSUED to a user as a reward/bonus (no opposing
  -- user or market leg), the counterparty is the mint account. To keep Σ == 0 we
  -- DEBIT reward_issuance_phon (it goes negative = cumulative PHON emitted). This
  -- is the conservation counter-entry for free issuance. Trading/spot credits do
  -- NOT match this filter (they have their own counterparty legs).
  IF p_currency = 'PHON' AND (
    p_reason_code LIKE 'staking_reward%' OR
    p_reason_code LIKE '%bonus%' OR
    p_reason_code LIKE '%reward%' OR
    p_reason_code LIKE '%roulette%' OR
    p_reason_code LIKE '%daily%' OR
    p_reason_code LIKE '%referral%' OR
    p_reason_code LIKE '%mission%'
  ) THEN
    PERFORM _debit_system_account('reward_issuance_phon', p_amount,
      p_reason_code, p_user_id, p_idempotency_key, NULL);
  END IF;

  RETURN v_entry_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: rpc_liquidate_position — add staleness/halt guard + rate limit
-- ─────────────────────────────────────────────────────────────────────────────
-- Manual (owner/admin) liquidation. The auto path is rpc_run_liquidations.

CREATE OR REPLACE FUNCTION rpc_liquidate_position(p_position_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_pos     futures_positions%ROWTYPE;
  v_mark    NUMERIC;
  v_liq     NUMERIC;
  v_hit     BOOLEAN;
BEGIN
  SET search_path = public, pg_temp;

  SELECT * INTO v_pos FROM futures_positions WHERE id = p_position_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_user_id IS NOT NULL AND v_pos.user_id <> v_user_id AND NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF v_user_id IS NOT NULL THEN
    PERFORM _enforce_rate_limit(v_user_id, 'rpc_liquidate_position');
  END IF;

  -- Staleness + circuit-breaker guard
  v_mark := _assert_price_fresh(v_pos.market);

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

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: rpc_stake_phon — add rate limit + consent gate
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_stake_phon(p_term TEXT, p_amount TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_pool     staking_pools%ROWTYPE;
  v_amount   NUMERIC := p_amount::NUMERIC;
  v_pos_id   UUID := gen_random_uuid();
  v_unlock   TIMESTAMPTZ;
BEGIN
  SET search_path = public, pg_temp;

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_stake_phon');
  PERFORM _assert_onboarding_consent(v_user_id);
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: rpc_claim_staking_reward — add rate limit
-- ─────────────────────────────────────────────────────────────────────────────

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
  SET search_path = public, pg_temp;

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_claim_staking_reward');

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

-- ─────────────────────────────────────────────────────────────────────────────
-- Patch: rpc_unstake_phon — add rate limit
-- ─────────────────────────────────────────────────────────────────────────────

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
  SET search_path = public, pg_temp;

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_unstake_phon');

  SELECT * INTO v_pos FROM staking_positions WHERE id = p_position_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_pos.user_id <> v_user_id THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF v_pos.status <> 'active' THEN RAISE EXCEPTION 'not_active'; END IF;

  IF v_pos.lock_days > 0 AND v_pos.unlock_at IS NOT NULL AND NOW() < v_pos.unlock_at THEN
    RAISE EXCEPTION 'still_locked';
  END IF;

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

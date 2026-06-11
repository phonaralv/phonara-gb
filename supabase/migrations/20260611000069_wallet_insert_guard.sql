-- ============================================================
-- Wallet INSERT guard
-- ============================================================
-- Zero-balance wallet rows are allowed so signup/profile automation can create
-- the derived balance row. Any non-zero initial balance must come from an
-- authorized ledger writer that has set phonara.ledger_write locally.
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION _guard_wallet_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.phon_available::NUMERIC <> 0
     OR NEW.phon_locked::NUMERIC <> 0
     OR NEW.usdt_available::NUMERIC <> 0
     OR NEW.usdt_locked::NUMERIC <> 0
     OR NEW.krw_available::NUMERIC <> 0
     OR NEW.krw_locked::NUMERIC <> 0 THEN
    PERFORM _require_ledger_write_allowed();
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION _guard_wallet_insert() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_00_wallets_insert_guard ON wallets;
CREATE TRIGGER trg_00_wallets_insert_guard
BEFORE INSERT ON wallets
FOR EACH ROW
EXECUTE FUNCTION _guard_wallet_insert();

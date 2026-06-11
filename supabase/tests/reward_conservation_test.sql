-- ============================================================
-- Reward conservation — SQL integration test (DB-level, real RPCs)
-- ============================================================
-- Guards migration 000011 (p1_reward_conservation_fix). Proves that the reward
-- RPCs (welcome / daily / roulette / referral) now:
--   1. EXECUTE at runtime (the old rpc_credit_wallet(uuid, ...) call signature
--      did not resolve -> every claim threw "function ... does not exist"), and
--   2. preserve the global PHON invariant: each user credit is balanced by an
--      equal-and-opposite debit to the reward_issuance_phon mint account, so the
--      grand total (Σ wallets + Σ system_accounts) is unchanged, and
--   3. credit the REFERRER's own wallet (not the caller's) on referral reward.
--
-- Runs in one transaction and ROLLS BACK — no residue.
-- ============================================================

BEGIN;

-- ── Test 1: single user — welcome + daily + roulette conserve PHON ───────────
DO $$
DECLARE
  v_uid          UUID := gen_random_uuid();
  v_grand_before NUMERIC;
  v_grand_after  NUMERIC;
  v_wallet_before NUMERIC;
  v_wallet_after  NUMERIC;
  v_issuance_before NUMERIC;
  v_issuance_after  NUMERIC;
  v_welcome JSONB;
  v_daily   JSONB;
  v_spin    JSONB;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'reward_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'v1', TRUE
  FROM unnest(ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']) AS doc_type
  ON CONFLICT DO NOTHING;

  SELECT balance::NUMERIC INTO v_issuance_before FROM system_accounts WHERE code = 'reward_issuance_phon';
  SELECT phon_available::NUMERIC + phon_locked::NUMERIC INTO v_wallet_before FROM wallets WHERE user_id = v_uid;
  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC),0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='PHON')
  INTO v_grand_before;

  -- Act: these threw "function rpc_credit_wallet(uuid,...) does not exist" before 000011.
  v_welcome := rpc_claim_welcome_bonus();
  v_daily   := rpc_claim_daily_reward();
  v_spin    := rpc_spin_roulette();

  SELECT balance::NUMERIC INTO v_issuance_after FROM system_accounts WHERE code = 'reward_issuance_phon';
  SELECT phon_available::NUMERIC + phon_locked::NUMERIC INTO v_wallet_after FROM wallets WHERE user_id = v_uid;
  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC),0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='PHON')
  INTO v_grand_after;

  -- The claims must have actually awarded PHON (welcome 5000 + daily 50 + spin >=10).
  ASSERT (v_welcome->>'already_claimed')::BOOLEAN = FALSE, 'welcome bonus did not award';
  ASSERT v_wallet_after > v_wallet_before, 'user PHON wallet did not increase';

  -- Conservation: the user gain is exactly matched by the reward_issuance mint debit.
  ASSERT (v_wallet_after - v_wallet_before) = (v_issuance_before - v_issuance_after),
    format('reward mint leg mismatch: wallet_gain=%s issuance_drop=%s',
           v_wallet_after - v_wallet_before, v_issuance_before - v_issuance_after);
  ASSERT v_issuance_after < v_issuance_before, 'reward_issuance_phon was not debited';
  ASSERT v_grand_after = v_grand_before,
    format('PHON not conserved across rewards: before=%s after=%s', v_grand_before, v_grand_after);

  ASSERT NOT EXISTS (SELECT 1 FROM verify_ledger_hash_chain(v_uid)),
    'wallet_ledger hash chain broken after rewards';

  RAISE NOTICE 'REWARD CONSERVATION OK — user_gain=% issuance_debit=% (grand total intact, chain intact)',
    v_wallet_after - v_wallet_before, v_issuance_before - v_issuance_after;
END;
$$;

-- ── Test 2: referral reward credits the REFERRER, not the caller ─────────────
DO $$
DECLARE
  v_referrer UUID := gen_random_uuid();
  v_referred UUID := gen_random_uuid();
  v_referrer_phon NUMERIC;
  v_referred_phon NUMERIC;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at) VALUES
    (v_referrer, 'authenticated', 'authenticated', 'ref_a_' || v_referrer::TEXT || '@test.local', NOW(), NOW()),
    (v_referred, 'authenticated', 'authenticated', 'ref_b_' || v_referred::TEXT || '@test.local', NOW(), NOW());

  -- referred was invited by referrer (rewarded_at NULL -> eligible).
  INSERT INTO referrals (referrer_id, referred_id) VALUES (v_referrer, v_referred);

  -- The REFERRED user claims their welcome bonus.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_referred::TEXT)::TEXT, true);
  PERFORM rpc_claim_welcome_bonus();

  SELECT phon_available::NUMERIC INTO v_referrer_phon FROM wallets WHERE user_id = v_referrer;
  SELECT phon_available::NUMERIC INTO v_referred_phon FROM wallets WHERE user_id = v_referred;

  -- Referrer must receive exactly 2,000 PHON; referred receives 5,000 + 1,000 = 6,000.
  ASSERT v_referrer_phon = 2000, format('referrer should get 2000 PHON, got %s', v_referrer_phon);
  ASSERT v_referred_phon = 6000, format('referred should get 6000 PHON, got %s', v_referred_phon);

  RAISE NOTICE 'REFERRAL REWARD OK — referrer=+% referred=+% (credited to correct wallets)',
    v_referrer_phon, v_referred_phon;
END;
$$;

-- ── Test 3: explicit reward-issuance classifier (migration 000014) ───────────
-- The mint classification must be an EXACT whitelist: every reward reason mints,
-- and NO trading/spot/settlement reason mints (substring collisions are gone).
DO $$
DECLARE
  v_reason TEXT;
BEGIN
  -- Every reward reason code currently passed to _credit_wallet_internal mints.
  FOREACH v_reason IN ARRAY ARRAY[
    'welcome_bonus','referral_bonus','daily_claim',
    'roulette_spin','mission_reward','staking_reward'
  ] LOOP
    ASSERT _is_reward_issuance_reason(v_reason),
      format('reward reason %s must be classified as mint', v_reason);
  END LOOP;

  -- Trading/spot/settlement credits must NEVER mint (these have real counterparty
  -- legs). Includes near-miss strings that the old substring LIKE would have
  -- wrongly matched (e.g. anything merely containing reward/bonus/daily).
  FOREACH v_reason IN ARRAY ARRAY[
    'futures_pnl','spot_buy_recv','spot_sell_recv','futures_margin_unlock',
    'reward_clawback','daily_fee','no_bonus_adjustment','referral_reversal'
  ] LOOP
    ASSERT NOT _is_reward_issuance_reason(v_reason),
      format('non-reward reason %s must NOT be classified as mint', v_reason);
  END LOOP;

  RAISE NOTICE 'REWARD ISSUANCE CLASSIFIER OK — exact whitelist, no substring collisions';
END;
$$;

ROLLBACK;

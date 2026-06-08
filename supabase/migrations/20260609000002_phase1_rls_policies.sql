-- ============================================================
-- Migration: 20260609000002_phase1_rls_policies
-- Phase 1: Row Level Security for wallet, ledger, deposits
-- ============================================================
-- Principle: default DENY ALL, explicit ALLOW.
-- Users can only see and affect their own data.
-- Admin access goes through service_role or admin RPCs only.
-- ============================================================

-- ─── Enable RLS on all tables ─────────────────────────────────

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE exchange_rate_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE krw_deposit_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- ─── profiles ─────────────────────────────────────────────────

-- Users can read their own profile
CREATE POLICY "profiles: own read"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

-- Users can update their own non-sensitive profile fields
CREATE POLICY "profiles: own update"
  ON profiles FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    -- Prevent self-elevation: role must stay the same
    AND role = (SELECT role FROM profiles WHERE id = auth.uid())
    AND kyc_tier = (SELECT kyc_tier FROM profiles WHERE id = auth.uid())
    AND is_banned = (SELECT is_banned FROM profiles WHERE id = auth.uid())
  );

-- No direct INSERT or DELETE — handled by trigger (handle_new_user)

-- ─── wallets ─────────────────────────────────────────────────

-- Users can read their own wallet
CREATE POLICY "wallets: own read"
  ON wallets FOR SELECT
  USING (auth.uid() = user_id);

-- No direct UPDATE — balance changes must go through RPC only
-- No INSERT — handled by auto_create_wallet trigger

-- ─── wallet_ledger ───────────────────────────────────────────

-- Users can read their own ledger entries
CREATE POLICY "wallet_ledger: own read"
  ON wallet_ledger FOR SELECT
  USING (auth.uid() = user_id);

-- No INSERT/UPDATE/DELETE from client — only via service_role RPC

-- ─── exchange_rate_snapshots ─────────────────────────────────

-- All authenticated users can read active rates (public market data)
CREATE POLICY "rates: authenticated read"
  ON exchange_rate_snapshots FOR SELECT
  TO authenticated
  USING (is_active = TRUE);

-- No write from client — managed by admin RPC / service_role only

-- ─── krw_deposit_requests ────────────────────────────────────

-- Users can read their own deposits
CREATE POLICY "deposits: own read"
  ON krw_deposit_requests FOR SELECT
  USING (auth.uid() = user_id);

-- Users can INSERT their own deposit request
CREATE POLICY "deposits: own insert"
  ON krw_deposit_requests FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- No UPDATE from client — status transitions via admin/service_role RPC

-- ─── audit_logs ──────────────────────────────────────────────

-- Users cannot read audit logs (admin-only)
-- No policies for regular users → default deny applies
-- Admins access via service_role only

-- ─── Negative policy tests (documented here, tested in test suite) ──────
-- These policies must be validated:
-- 1. User A cannot read User B's wallet          → tested
-- 2. User A cannot INSERT to wallet_ledger       → tested
-- 3. User A cannot UPDATE their own balance      → tested
-- 4. User A cannot read audit_logs               → tested
-- 5. User A cannot change their own role         → tested
-- 6. User A cannot mark their own deposit as credited → tested

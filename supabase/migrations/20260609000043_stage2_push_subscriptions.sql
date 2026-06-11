-- ============================================================
-- Stage 2: Deferred web-push subscription scaffold
-- ============================================================
-- Stores browser Push API subscriptions for the later external worker.
-- This migration does not send push messages and does not introduce pg_net.
-- ============================================================

SET search_path = public, pg_temp;

CREATE TABLE IF NOT EXISTS push_subscriptions (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  endpoint   TEXT NOT NULL,
  p256dh     TEXT NOT NULL,
  auth       TEXT NOT NULL,
  ua         TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, endpoint)
);

CREATE INDEX IF NOT EXISTS ps_user_idx ON push_subscriptions (user_id, updated_at DESC);

DROP TRIGGER IF EXISTS ps_updated_at ON push_subscriptions;
CREATE TRIGGER ps_updated_at
  BEFORE UPDATE ON push_subscriptions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "push_subscriptions: own read" ON push_subscriptions;
CREATE POLICY "push_subscriptions: own read" ON push_subscriptions
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "push_subscriptions: own insert" ON push_subscriptions;
CREATE POLICY "push_subscriptions: own insert" ON push_subscriptions
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "push_subscriptions: own update" ON push_subscriptions;
CREATE POLICY "push_subscriptions: own update" ON push_subscriptions
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "push_subscriptions: own delete" ON push_subscriptions;
CREATE POLICY "push_subscriptions: own delete" ON push_subscriptions
  FOR DELETE USING (auth.uid() = user_id);

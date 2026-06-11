-- ============================================================
-- Casino seed reveal idempotency
-- ============================================================
-- A round has exactly one public seed reveal evidence row. The reveal RPC may
-- be called repeatedly after settlement, but repeat calls must not duplicate
-- the append-only evidence for the same round.

SET search_path = public, pg_temp;

DO $$
DECLARE
  r RECORD;
BEGIN
  SELECT round_id, count(*) AS reveal_count
    INTO r
    FROM game_seed_reveals
   GROUP BY round_id
  HAVING count(*) > 1
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'duplicate_game_seed_reveals'
      USING DETAIL = format('round_id=%s count=%s', r.round_id, r.reveal_count);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conrelid = 'public.game_seed_reveals'::regclass
       AND conname = 'game_seed_reveals_round_id_key'
  ) THEN
    ALTER TABLE game_seed_reveals
      ADD CONSTRAINT game_seed_reveals_round_id_key UNIQUE (round_id);
  END IF;
END;
$$;

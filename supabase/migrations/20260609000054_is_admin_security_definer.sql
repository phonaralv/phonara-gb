-- ============================================================
-- PART E follow-up: make _is_admin safe inside RLS policies
-- ============================================================
-- _is_admin() is used by admin-only RLS policies that may be evaluated for anon
-- reads (for example app_config public flags). It must not depend on anon having
-- direct SELECT on profiles. Keep profiles closed and let the definer function
-- perform the self-admin check.
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION _is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.profiles
     WHERE id = auth.uid()
       AND role = 'admin'
  );
$$;

REVOKE ALL ON FUNCTION _is_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _is_admin() TO anon, authenticated, service_role;

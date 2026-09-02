-- Let people turn marketing email off again.
--
-- The signup checkbox is now PRE-TICKED (opt-out rather than opt-in), which
-- makes a working off switch necessary rather than optional. Consent that
-- cannot be withdrawn isn't consent, and in practice the alternative to an off
-- switch is people marking the mail as spam — which costs the sending domain's
-- reputation far more than the unsubscribe would have.
--
-- Why an RPC and not a column grant: profiles' client-writable GRANT is
-- deliberately `full_name` only, so that nobody can flip marketing_opt_in for
-- themselves OR anyone else by a plain PATCH. Widening the grant to include
-- marketing_opt_in would also expose it on every other row the update policy
-- can reach. A security definer function keyed on auth.uid() gives exactly one
-- capability — "change my own answer" — and nothing else.
--
-- Additive: one new function. No table, column, policy or grant changes, and
-- no existing row is rewritten. Safe to run twice. Mirrored into schema.sql.
--
-- Run BEFORE pushing the new app.html, which offers the toggle in Account.
-- Until it exists the toggle 404s as PGRST202.

-- ---------------------------------------------------------------------------
-- set_marketing_opt_in(p_opt_in boolean) -> boolean (the value now stored)
--
-- Self-only: auth.uid() is the row, and it is not a parameter, so there is no
-- version of this call that touches somebody else's profile.
--
-- On the timestamp: marketing_opt_in_at answers "when did they agree", so it is
-- stamped when turning ON and CLEARED when turning off. Leaving a stale "agreed
-- at" date on someone who has since opted out would be worse than useless — it
-- is exactly the field you would reach for to justify having emailed them.
-- ---------------------------------------------------------------------------
create or replace function public.set_marketing_opt_in(p_opt_in boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_opt_in boolean := coalesce(p_opt_in, false);
begin
  if auth.uid() is null then
    raise exception 'Not signed in.';
  end if;

  update public.profiles
     set marketing_opt_in = v_opt_in,
         marketing_opt_in_at = case when v_opt_in then now() else null end
   where id = auth.uid();

  -- An UPDATE matching zero rows is a success in Postgres. A user really can
  -- have no profiles row (handle_new_user() only fires at signup, so anyone
  -- whose account predates it has none), and silently reporting success would
  -- leave the toggle showing a preference that was never stored.
  if not found then
    raise exception 'Your profile record is missing — log out and back in, then try again.';
  end if;

  return v_opt_in;
end $$;

grant execute on function public.set_marketing_opt_in(boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- as a signed-in user, from the app or with their JWT:
--   select public.set_marketing_opt_in(false);   -- => false
--   select marketing_opt_in, marketing_opt_in_at from public.profiles
--    where id = auth.uid();
--   -- expect: false | null      (the date is cleared, not left stale)
--
--   select public.set_marketing_opt_in(true);    -- => true
--   -- expect: true | <now>
--
--   -- and the column is still NOT writable directly — this must fail:
--   --   PATCH /rest/v1/profiles?id=eq.<self>  {"marketing_opt_in": true}
--   -- expect: 42501 permission denied for column marketing_opt_in
-- ---------------------------------------------------------------------------

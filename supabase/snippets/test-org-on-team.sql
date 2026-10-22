-- ADMIN ONLY — run by hand in the Supabase SQL editor. Never from the app.
--
-- Puts a DISPOSABLE test organisation on the Team plan without Stripe, so the
-- team flows can be tested end to end without a real card:
--   * join code + daily code (join_organisation() requires plan_tier 'multi')
--   * Account/Admin -> Add team member (add_team_member() requires the same)
--   * staff counting at the same time (claim_seat() draws on concurrent_seats)
--
-- Why SQL and not a "test mode" in the app or webhook: a code path that grants
-- Team without paying ships to every customer and only needs one bug to be
-- used. This needs the database owner's hands on it.
--
-- Safety rails, all enforced below:
--   * matched by the OWNER's email, not a name or id typed from memory;
--   * refused if the org has any Stripe subscription — never on a paying org;
--   * refused unless the org name contains "test" (case-insensitive).
--
-- What it can't do: set-seat-count (changing seats from the admin console)
-- still says "billing isn't fully set up" — it needs a real Stripe item. Set
-- the seats here instead (v_seats).
--
-- The webhook never touches this org (no subscription, no customer), so it
-- stays on Team until reverted with the block at the bottom.

do $$
declare
  v_owner_email text := 'james.admiraal+palsorg2210@gmail.com';   -- the disposable org's OWNER
  v_seats int := 2;                                               -- extra people counting at once
  v_org public.organisations%rowtype;
begin
  select o.* into v_org
  from public.organisations o
  join public.memberships m on m.org_id = o.id and m.role = 'owner'
  join auth.users u on u.id = m.user_id
  where lower(u.email) = lower(v_owner_email);

  if v_org.id is null then
    raise exception 'No organisation owned by % — check the email.', v_owner_email;
  end if;
  if v_org.stripe_subscription_id is not null or v_org.stripe_customer_id is not null then
    raise exception '"%" has Stripe billing attached — this is for disposable test orgs only.', v_org.name;
  end if;
  if v_org.name !~* 'test' then
    raise exception '"%" is not named as a test org (needs "test" in the name) — refusing.', v_org.name;
  end if;

  update public.organisations
     set plan_tier = 'multi', concurrent_seats = v_seats
   where id = v_org.id;

  raise notice 'Put "%" (%) on Team with % extra people counting at once. Join code: %',
    v_org.name, v_org.id, v_seats, v_org.join_code;
end $$;

-- Check:
--   select o.name, o.plan_tier, o.concurrent_seats, o.join_code, o.stripe_subscription_id
--   from public.organisations o
--   join public.memberships m on m.org_id = o.id and m.role = 'owner'
--   join auth.users u on u.id = m.user_id
--   where lower(u.email) = lower('james.admiraal+palsorg2210@gmail.com');
--
-- Revert (back to the trial; the seat trigger zeroes concurrent_seats when an
-- org leaves Team). Same rails:
--
--   update public.organisations o set plan_tier = 'trial'
--   from public.memberships m, auth.users u
--   where m.org_id = o.id and m.role = 'owner' and u.id = m.user_id
--     and lower(u.email) = lower('james.admiraal+palsorg2210@gmail.com')
--     and o.stripe_subscription_id is null and o.stripe_customer_id is null
--     and o.name ~* 'test';

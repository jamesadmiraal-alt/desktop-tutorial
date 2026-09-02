-- Reword the Multi-venue upgrade sentence in Postgres.
--
-- Copy only. No behaviour, no permission, no price changes — the same callers
-- are refused in the same conditions; only what they are told changes.
--
-- Why it needs a migration at all: the sentence lives in add_team_member(), so
-- it is stored in the database rather than shipped with the page. Three places
-- have to say the same thing (the RPC here, create-team-member's 403, and the
-- Team view in app.html) and schema.sql says so explicitly above this function.
-- Leaving the database on the old wording is what makes that comment a lie.
--
-- What changed and why: "Extra concurrent seats on Multi are $29/mo each"
-- described the billing row rather than the decision. It conflated two things a
-- publican has no reason to separate on their own — how many PEOPLE you set up
-- (unlimited, free) and how many can be COUNTING AT THE SAME TIME (what is
-- billed). The new sentence names both.
--
-- Idempotent (create or replace). Safe against the deployed page: it only ever
-- displays this string. Mirrored into schema.sql.
--
-- Run BEFORE (or with) the create-team-member redeploy, so the two sentences
-- never disagree in the wild.

create or replace function public.add_team_member(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_id uuid := public.my_org_id();
  target_label text;
begin
  -- `is distinct from` rather than `!=`: my_role() is NULL for a caller with no
  -- membership, and `NULL != 'owner'` is NULL, which plpgsql treats as false.
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can add team members.';
  end if;

  -- Plan boundary, not a permission one, so the message names the price and the
  -- way out. Deliberately AFTER the owner check: a staff member who reached
  -- here should be told they are not the owner, not handed an upgrade pitch
  -- they cannot act on. adopt_existing_team_member() delegates here and
  -- inherits this gate.
  if (select plan_tier from public.organisations where id = org_id) is distinct from 'multi' then
    raise exception 'Single-venue is just you — the owner. Multi-venue ($59/mo) lets you set up as many people as you like, and costs $29/mo for each extra person counting at the same time.';
  end if;

  if p_role not in ('manager', 'staff') then
    raise exception 'Invalid role.';
  end if;

  insert into public.memberships (org_id, user_id, role) values (org_id, p_user_id, p_role);

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select coalesce(u.email, 'Unknown user') into target_label
    from auth.users u where u.id = p_user_id;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
  values (org_id, (select name from public.organisations where id = org_id), actor, actor_label,
          'membership.added_by_owner', 'membership', p_user_id, target_label, jsonb_build_object('role', p_role));
end $$;

grant execute on function public.add_team_member(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- the wording is live, and still only for non-multi orgs:
--   select prosrc like '%counting at the same time%' as reworded
--     from pg_proc where proname = 'add_team_member';
--   -- expect: true
--
--   -- Colac (multi) is unaffected — adding a member there still works, and
--   -- a single-venue owner still gets refused, with the new sentence.
-- ---------------------------------------------------------------------------

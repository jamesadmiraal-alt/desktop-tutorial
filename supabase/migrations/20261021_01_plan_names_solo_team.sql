-- Plan names in user-facing text: Single-venue -> Solo, Multi-venue -> Team.
--
-- COPY ONLY. Two functions raise a message that names the plans, so the new
-- names need these re-created. Nothing else changes: plan_tier values stay
-- 'single' / 'multi', every condition, permission and grant is identical, and
-- no row is touched. Bodies are copied from schema.sql, whose code was checked
-- identical (comments aside) to the live versions from 20260831_04
-- (join_organisation) and 20260901_02 (add_team_member) before rewording.
--
-- add_team_member()'s sentence lives in THREE places — this exception,
-- create-team-member's 403 body, and the Team view in app.html. All three were
-- reworded together; deploy create-team-member with this.
--
-- Order: run this, deploy create-team-member, push app.html. In any other
-- order the old and new names show side by side for a few minutes; nothing
-- breaks. create or replace with the same signatures — safe to run twice and
-- mid-count.

create or replace function public.join_organisation(p_join_code text, p_daily_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  target_org public.organisations%rowtype;
begin
  if exists (select 1 from public.memberships where user_id = auth.uid()) then
    raise exception 'You already belong to an organisation.';
  end if;

  select * into target_org from public.organisations where join_code = p_join_code;
  if target_org.id is null then
    raise exception 'Invalid organisation code.';
  end if;
  if target_org.daily_code is null
     or target_org.daily_code_date is distinct from current_date
     or target_org.daily_code is distinct from p_daily_code then
    raise exception 'Invalid or expired daily code.';
  end if;

  -- Single-venue is ONE user: the owner. A valid pair of codes is still not a
  -- way onto that plan.
  --
  -- Checked after the codes, deliberately. Refusing before them would tell an
  -- unauthenticated guesser which join codes are real, and the plan a stranger's
  -- org is on is not their business.
  --
  -- `is distinct from` rather than `<>`: plan_tier is not null today, but a null
  -- here would make `<>` evaluate to NULL, which plpgsql treats as false — the
  -- exact null-comparison bypass this file has already been bitten by.
  if target_org.plan_tier is distinct from 'multi' then
    raise exception 'This organisation is on the Solo plan (owner only). Ask the owner to upgrade to Team.';
  end if;

  insert into public.memberships (org_id, user_id, role) values (target_org.id, auth.uid(), 'staff');

  return target_org.id;
end $$;

create or replace function public.add_team_member(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_id uuid := public.my_org_id();
  target_label text;
begin
  -- `is distinct from` rather than `!=`: my_role() is NULL for a caller with no
  -- membership, and `NULL != 'owner'` is NULL, which plpgsql treats as false —
  -- so `!=` would wave through precisely the callers who belong to no org. They
  -- fail later on memberships.org_id's not-null constraint rather than
  -- succeeding, but relying on that is defence by accident, and the error the
  -- caller gets is a constraint violation instead of "you're not the owner".
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can add team members.';
  end if;

  -- Single-venue is ONE user: the owner. A team is what the Multi-venue plan is
  -- for, so this is a plan boundary rather than a permission one — hence the
  -- message names the price and the way out instead of just refusing.
  --
  -- Deliberately AFTER the owner check: a staff member who somehow reached here
  -- should be told they are not the owner, which is true and actionable, rather
  -- than being handed an upgrade pitch they cannot act on.
  --
  -- adopt_existing_team_member() delegates here, so it inherits this gate. The
  -- same sentence is returned by create-team-member (403) and shown on the Team
  -- view; keep the three in step if it is ever reworded.
  if (select plan_tier from public.organisations where id = org_id) is distinct from 'multi' then
    raise exception 'Solo ($29/mo) is just you — the owner. Team ($59/mo) lets you set up as many people as you like, and costs $29/mo for each extra person counting at the same time.';
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

-- Verify (both true):
--   select prosrc like '%Solo plan (owner only)%' from pg_proc where proname = 'join_organisation';
--   select prosrc like '%Solo ($29/mo) is just you%' from pg_proc where proname = 'add_team_member';

-- Team plan: $79/month (A$; $790/year), up to 10 people logged in at the same
-- time, the owner included. Replaces "base + $29/month per extra person
-- counting at the same time" (decided with James, 2 Nov 2026).
--
-- * plan_people_at_once(): the limit comes from the plan, not a purchased
--   number. Team = 10. organisations.concurrent_seats, seats_increased_at and
--   the minimum-term trigger stay in place but nothing reads them any more.
-- * claim_seat(): a non-owner is refused once 10 are logged in (everyone
--   counted, the owner too). The owner is never refused. Solo and trial are
--   owner-only, unchanged. The 'no_seats_purchased' reason can't happen now.
-- * record_seat_denial(): the same limit; also returns people_at_once.
--   seats_purchased is still returned (= the limit) for the deployed
--   notify-seat-denied until it is redeployed.
-- * add_team_member(): the Solo/Team sentence, reworded with the new price.
--   It lives in THREE places (CLAUDE.md): here, create-team-member's 403 body
--   and app.html's Team view. All three change together.
--
-- Safe to run twice and mid-count: three create or replace with unchanged
-- signatures and one new function. For every Team organisation the limit goes
-- UP to 10 (no Team org had bought more than a handful of seats; nobody was
-- paying yet, as of 2 Nov 2026). It can run before or after the pages are
-- pushed. Retire set-seat-count FIRST (see STRIPE-SETUP.md), so nothing can
-- change a flat $79 subscription's quantity. Mirrored into schema.sql.

-- How many people a plan allows logged in at the same time. Team ('multi')
-- is 10, the owner included (2 Nov 2026). Anything else is owner-only, which
-- claim_seat() enforces separately, so NULL here. A Corporate tier, if one is
-- ever a plan_tier rather than an arrangement, slots in here.
create or replace function public.plan_people_at_once(p_tier text)
returns integer language sql immutable as $$
  select case coalesce(p_tier, '') when 'multi' then 10 end
$$;
grant execute on function public.plan_people_at_once(text) to authenticated;

create or replace function public.claim_seat(p_device_id text, p_takeover boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.my_org_id();
  v_role text := public.my_role();
  v_plan text;
  v_seats integer;
  v_interval_secs integer;
  v_occupied integer;
  v_org_name text;
  v_existing_device text;
  v_existing_seen timestamptz;
  v_has_row boolean;
  v_stale_before timestamptz;
  actor_label text;
begin
  if v_org_id is null then
    return jsonb_build_object('granted', false, 'reason', 'no_organisation');
  end if;

  select plan_tier, concurrent_seats, heartbeat_interval_seconds, name
    into v_plan, v_seats, v_interval_secs, v_org_name
    from public.organisations where id = v_org_id;

  v_stale_before := now() - make_interval(secs => v_interval_secs * 2.5);

  select device_id, last_seen_at, true
    into v_existing_device, v_existing_seen, v_has_row
    from public.active_sessions where user_id = auth.uid();

  -- ---- Rule 1: one device per login ----
  if coalesce(v_has_row, false) then
    -- Same device, or a row old enough that whatever held it is gone. The stale
    -- case is deliberately silent: prompting "another device is using this login"
    -- about a phone that crashed an hour ago would be both wrong and impossible
    -- for the operator to act on, and it's what stops a crash locking someone out
    -- until the timeout expires.
    if v_existing_device is null
       or v_existing_device = p_device_id
       or v_existing_seen <= v_stale_before then
      update public.active_sessions
         set last_seen_at = now(), device_id = p_device_id
       where user_id = auth.uid();
      return jsonb_build_object('granted', true);
    end if;

    -- Live on a different device.
    if not p_takeover then
      return jsonb_build_object('granted', false, 'reason', 'other_device');
    end if;

    update public.active_sessions
       set last_seen_at = now(), device_id = p_device_id
     where user_id = auth.uid();

    -- Logged because a run of these on one account is the signature of a shared
    -- login being passed around — the only signal an owner (or support) would
    -- otherwise have. One legitimate takeover when someone swaps phone for tablet
    -- looks nothing like fifteen a shift.
    select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
      from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
    values (v_org_id, v_org_name, auth.uid(), actor_label, 'session.taken_over', 'membership',
            auth.uid(), actor_label, jsonb_build_object('signed_out_previous_device', true));

    return jsonb_build_object('granted', true, 'took_over', true);
  end if;

  -- ---- Rule 1b: single-venue is one user, the owner ----
  --
  -- Rule 2 below only engages for multi, so a single-venue non-owner used to fall
  -- straight through to the insert and get a session. That is why extra logins
  -- worked on the $29 plan: nothing server-side stopped them.
  --
  -- Placed after Rule 1 so a returning owner still refreshes their own row, and
  -- before the insert so no active_sessions row is created for someone who is
  -- about to be refused.
  --
  -- 'pending' orgs are covered too — the owner is let through (they need to reach
  -- checkout), anyone else is not.
  --
  -- No notifySeatDenied() for this reason, and record_seat_denied() already
  -- treats non-multi as "not subject to the seat limit", so nothing emails the
  -- owner about it. This is a plan boundary, not a full pool.
  if v_plan is distinct from 'multi' and v_role is distinct from 'owner' then
    return jsonb_build_object('granted', false, 'reason', 'single_venue_owner_only');
  end if;

  -- ---- Rule 2: the Team limit (non-owner) ----
  -- Team includes plan_people_at_once('multi') = 10 people logged in at the
  -- same time, the owner counted among them (2 Nov 2026; it used to be a
  -- purchased number of extra seats, concurrent_seats, now unused). The owner
  -- is never refused, so with 10 others already in, the owner still gets in
  -- and can sign someone out from Admin.
  if v_plan = 'multi' and v_role is distinct from 'owner' then
    select count(*) into v_occupied from public.active_sessions
     where org_id = v_org_id and last_seen_at > v_stale_before;

    if v_occupied >= public.plan_people_at_once(v_plan) then
      return jsonb_build_object('granted', false, 'reason', 'seats_full',
                                'limit', public.plan_people_at_once(v_plan));
    end if;
  end if;

  insert into public.active_sessions (user_id, org_id, device_id, last_seen_at)
    values (auth.uid(), v_org_id, p_device_id, now());
  return jsonb_build_object('granted', true);
end $$;

grant execute on function public.claim_seat(text, boolean) to authenticated;

create or replace function public.record_seat_denial()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.my_org_id();
  v_role text := public.my_role();
  v_plan text;
  v_seats integer;
  v_interval_secs integer;
  v_occupied integer;
  v_org_name text;
  v_notified_at timestamptz;
  v_owner_id uuid;
  v_actor_label text;
  v_should_notify boolean := false;
  -- One email per org per 30 minutes. A venue hitting the limit does so
  -- repeatedly — every staff member arriving for the same shift — and the owner
  -- needs to know once, not eleven times. The seat.denied audit rows are NOT
  -- throttled, so the full picture is still recoverable from the log.
  v_throttle interval := interval '30 minutes';
begin
  if v_org_id is null then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'no organisation');
  end if;

  select plan_tier, concurrent_seats, heartbeat_interval_seconds, name, seats_full_notified_at
    into v_plan, v_seats, v_interval_secs, v_org_name, v_notified_at
    from public.organisations where id = v_org_id;

  -- The owner is exempt from the pool and single-venue has no pool, so neither
  -- can genuinely be denied — mirrors claim_seat()'s first branch exactly.
  if v_plan != 'multi' or v_role = 'owner' then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'not subject to the seat limit');
  end if;

  -- Holding a seat already means they weren't denied.
  if exists (select 1 from public.active_sessions where user_id = auth.uid()) then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'caller holds a seat');
  end if;

  select count(*) into v_occupied from public.active_sessions
   where org_id = v_org_id
     and last_seen_at > now() - make_interval(secs => v_interval_secs * 2.5);

  if v_occupied < public.plan_people_at_once(v_plan) then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'a seat is available');
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into v_actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();

  -- Unthrottled: every denial is logged even when no email goes out, so an owner
  -- reviewing the activity log later can see how often people were locked out.
  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
  values (v_org_id, v_org_name, auth.uid(), v_actor_label, 'seat.denied', 'membership', auth.uid(), v_actor_label,
          jsonb_build_object('people_at_once', public.plan_people_at_once(v_plan), 'seats_occupied', v_occupied));

  if v_notified_at is null or v_notified_at < now() - v_throttle then
    v_should_notify := true;
    update public.organisations set seats_full_notified_at = now() where id = v_org_id;
  end if;

  select m.user_id into v_owner_id
    from public.memberships m where m.org_id = v_org_id and m.role = 'owner' limit 1;

  return jsonb_build_object(
    'denied', true,
    'notify', v_should_notify,
    'org_name', v_org_name,
    'owner_user_id', v_owner_id,
    'blocked_person', v_actor_label,
    -- seats_purchased kept for an older deployed notify-seat-denied; it reads
    -- the limit now, never a purchased number.
    'seats_purchased', public.plan_people_at_once(v_plan),
    'people_at_once', public.plan_people_at_once(v_plan),
    'seats_occupied', v_occupied
  );
end $$;

grant execute on function public.record_seat_denial() to authenticated;

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
    raise exception 'Solo ($29/mo) is just you, the owner. Team ($79/mo) lets you set up as many people as you like, with up to 10 logged in at the same time.';
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

-- Verify:
--   select public.plan_people_at_once('multi'), public.plan_people_at_once('single');   -- 10, null
--   select prosrc like '%plan_people_at_once%' from pg_proc where proname = 'claim_seat';  -- true
--   select prosrc like '%$79/mo%' from pg_proc where proname = 'add_team_member';        -- true

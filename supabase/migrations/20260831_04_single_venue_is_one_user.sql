-- Single-venue is ONE user: the owner.
--
-- Adding a team member, joining an org, or logging in as a second person is a
-- Multi-venue feature. The UI already treated Team as single-venue-capable and
-- nothing server-side stopped a second user, so extra logins worked on the $29
-- plan. Three security-definer functions are the whole write path into
-- memberships and active_sessions, so closing them closes the gate:
--
--   join_organisation()   — refuses a join into a non-multi org
--   add_team_member()     — refuses provisioning on a non-multi org
--                           (adopt_existing_team_member() delegates here and
--                            inherits it)
--   claim_seat()          — refuses a non-owner session on a non-multi org
--
-- set-seat-count already 400s when plan_tier is not 'multi' and is untouched.
-- No Stripe product, price, key or webhook is involved: prices are display and
-- copy only, and Single stays $29 / Multi $59 / extra Multi seats $29.
--
-- INCREMENTAL ONLY. Three CREATE OR REPLACE statements, nothing else. No table
-- is created or dropped, no constraint or policy changes, no data is written or
-- backfilled — stocktakes and stocktake_items are not referenced at all, so
-- Belles and Colac cannot be affected. Safe to run twice. Mirrored into
-- schema.sql.
--
-- EXISTING EXTRA MEMBERS ARE NOT REMOVED. A leftover non-owner on a
-- single-venue org keeps their memberships row and is locked out at login by
-- claim_seat instead. Deleting people's memberships to enforce a pricing change
-- would be destructive and unrecoverable; refusing a session is reversible the
-- moment the owner upgrades.
--
-- Run BEFORE pushing the new app.html/index.html: the client shows copy that
-- promises this behaviour, and until these exist a single-venue org could still
-- add a second user.

-- ---------------------------------------------------------------------------
-- 1. join_organisation — a valid code pair is not a way onto the $29 plan.
-- ---------------------------------------------------------------------------
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

  -- Checked AFTER the codes, deliberately. Refusing before them would tell an
  -- unauthenticated guesser which join codes are real, and the plan a stranger's
  -- org is on is not their business.
  --
  -- `is distinct from` rather than `<>`: a null plan_tier would make `<>`
  -- evaluate to NULL, which plpgsql treats as false — the exact
  -- null-comparison bypass this schema has already been bitten by.
  if target_org.plan_tier is distinct from 'multi' then
    raise exception 'This organisation is on the Single-venue plan (owner only). Ask the owner to upgrade to Multi-venue.';
  end if;

  insert into public.memberships (org_id, user_id, role) values (target_org.id, auth.uid(), 'staff');

  return target_org.id;
end $$;

-- ---------------------------------------------------------------------------
-- 2. add_team_member — no provisioning a second user on Single-venue.
--
-- The message names the price and the way out, because this is a plan boundary
-- rather than a permission problem. The identical sentence is returned by
-- create-team-member as a 403 and shown on the Team view; keep all three in step
-- if it is ever reworded.
-- ---------------------------------------------------------------------------
create or replace function public.add_team_member(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_id uuid := public.my_org_id();
  target_label text;
begin
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can add team members.';
  end if;

  -- AFTER the owner check on purpose: a staff member who reaches here should be
  -- told they are not the owner — true and actionable — rather than handed an
  -- upgrade pitch they cannot act on.
  if (select plan_tier from public.organisations where id = org_id) is distinct from 'multi' then
    raise exception 'Single-venue is just you — the owner. Upgrade to Multi-venue ($59/mo) to add team members. Extra concurrent seats on Multi are $29/mo each.';
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

-- ---------------------------------------------------------------------------
-- 3. claim_seat — a non-owner cannot hold a session on a non-multi org.
--
-- This is the one that actually closes the hole. Rule 2 (the seat pool) only
-- engages for multi, so a single-venue non-owner fell straight through to the
-- insert and got a session. New Rule 1b sits after Rule 1 (so a returning owner
-- still refreshes their own row) and before the insert (so no active_sessions
-- row is created for someone about to be refused).
--
-- The rest of the function is unchanged — reproduced verbatim because
-- CREATE OR REPLACE replaces the whole body.
-- ---------------------------------------------------------------------------
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
  -- 'pending' orgs are covered too — the owner is let through (they need to reach
  -- checkout), anyone else is not.
  --
  -- record_seat_denial() already treats non-multi as "not subject to the seat
  -- limit", so nothing emails the owner about this, and the client must not call
  -- notifySeatDenied() for it either. It is a plan boundary, not a full pool.
  if v_plan is distinct from 'multi' and v_role is distinct from 'owner' then
    return jsonb_build_object('granted', false, 'reason', 'single_venue_owner_only');
  end if;

  -- ---- Rule 2: the seat pool (multi-venue, non-owner) ----
  if v_plan = 'multi' and v_role is distinct from 'owner' then
    select count(*) into v_occupied from public.active_sessions
     where org_id = v_org_id and last_seen_at > v_stale_before;

    if v_occupied >= v_seats then
      -- Distinguish "nobody's purchased any staff seats yet" (v_seats = 0,
      -- true even with v_occupied = 0 — this is the very first non-owner
      -- login on a fresh org) from a pool that's genuinely full right now.
      -- The client shows different, non-misleading copy for each: telling
      -- someone to "ask a teammate to log out" when there IS no teammate
      -- logged in is actively wrong, not just unhelpful.
      if v_seats = 0 then
        return jsonb_build_object('granted', false, 'reason', 'no_seats_purchased');
      end if;
      return jsonb_build_object('granted', false, 'reason', 'seats_full');
    end if;
  end if;

  insert into public.active_sessions (user_id, org_id, device_id, last_seen_at)
    values (auth.uid(), v_org_id, p_device_id, now());
  return jsonb_build_object('granted', true);
end $$;

-- Grants are unchanged (CREATE OR REPLACE keeps them), restated so a fresh
-- project reaches the same state.
grant execute on function public.join_organisation(text, text) to authenticated;
grant execute on function public.add_team_member(uuid, text) to authenticated;
grant execute on function public.claim_seat(text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify. Use a DISPOSABLE single-venue org — do NOT test against Colac
-- (multi-venue) or anything holding the Belles/Colac stocktakes.
--
--   -- which orgs are affected, and who would be locked out (read-only):
--   select o.name, o.plan_tier, count(m.*) as members
--     from public.organisations o
--     left join public.memberships m on m.org_id = o.id
--    group by o.id, o.name, o.plan_tier order by o.plan_tier, o.name;
--
--   select o.name, m.role, u.email
--     from public.memberships m
--     join public.organisations o on o.id = m.org_id
--     join auth.users u on u.id = m.user_id
--    where o.plan_tier is distinct from 'multi' and m.role <> 'owner';
--   -- ^ these logins will hit the new lockout. Nothing deletes them.
--
--   -- 2. as the owner of a single-venue org:
--   select public.add_team_member('<some uuid>', 'staff');
--   -- ERROR: Single-venue is just you — the owner. Upgrade to Multi-venue ...
--
--   -- 3. joining a single-venue org with valid codes:
--   select public.join_organisation('<single venue join_code>', '<today''s code>');
--   -- ERROR: This organisation is on the Single-venue plan (owner only) ...
--   -- and memberships for that org is still just the owner.
--
--   -- 5. Colac (multi) must be unaffected: add_team_member, join_organisation
--   --    and claim_seat all behave exactly as before.

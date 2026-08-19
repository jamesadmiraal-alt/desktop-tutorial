-- One device per login.
--
-- The problem: one Gantry login used on ten devices consumed ONE seat, because
-- active_sessions has one row per person and claim_seat() simply refreshed
-- whatever row it found ("Already holding a seat (e.g. a second device) — refresh
-- it, don't count it twice"). A venue could put one account on every phone and
-- never buy a second seat.
--
-- The worse consequence was the audit trail: every entry attributes to a user, so
-- "Sam Lee deleted stocktake X — 247 items" is only evidence if exactly one person
-- can be Sam at a time. That is why the device rule below applies to EVERY role
-- and BOTH tiers, even though owners and single-venue orgs leak no revenue.
--
-- Seat accounting is untouched — still one seat per person — so nothing about
-- billing changes.
--
-- Additive and safe against a live project. Mirrored into schema.sql.
-- Run BEFORE pushing the new app.html; the compatibility shims at the bottom keep
-- already-open pages working until they reload.

alter table public.active_sessions add column if not exists device_id text;

-- ---------------------------------------------------------------------------
-- claim_seat: device rule for everyone, seat pool for multi-venue non-owners.
-- Returns jsonb so one call distinguishes "in" from the two different refusals.
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

  if coalesce(v_has_row, false) then
    -- Same device, a pre-existing row with no device recorded, or a row stale
    -- enough that whatever held it is gone. The stale case is silent on purpose:
    -- prompting about a phone that crashed an hour ago is both wrong and
    -- unactionable, and this is what stops a crash locking someone out.
    if v_existing_device is null
       or v_existing_device = p_device_id
       or v_existing_seen <= v_stale_before then
      update public.active_sessions
         set last_seen_at = now(), device_id = p_device_id
       where user_id = auth.uid();
      return jsonb_build_object('granted', true);
    end if;

    if not p_takeover then
      return jsonb_build_object('granted', false, 'reason', 'other_device');
    end if;

    update public.active_sessions
       set last_seen_at = now(), device_id = p_device_id
     where user_id = auth.uid();

    -- Logged: a run of takeovers on one account is the signature of a shared
    -- login, and it's the only signal an owner would otherwise have.
    select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
      from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
    values (v_org_id, v_org_name, auth.uid(), actor_label, 'session.taken_over', 'membership',
            auth.uid(), actor_label, jsonb_build_object('signed_out_previous_device', true));

    return jsonb_build_object('granted', true, 'took_over', true);
  end if;

  if v_plan = 'multi' and v_role is distinct from 'owner' then
    select count(*) into v_occupied from public.active_sessions
     where org_id = v_org_id and last_seen_at > v_stale_before;

    if v_occupied >= v_seats then
      return jsonb_build_object('granted', false, 'reason', 'seats_full');
    end if;
  end if;

  insert into public.active_sessions (user_id, org_id, device_id, last_seen_at)
    values (auth.uid(), v_org_id, p_device_id, now());
  return jsonb_build_object('granted', true);
end $$;

grant execute on function public.claim_seat(text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- heartbeat: the device id in the WHERE clause is how a displaced device learns
-- it has been displaced — the update matches nothing, returns false, and the
-- client logs itself out. Same mechanism that already makes kick_user() stick.
create or replace function public.heartbeat(p_device_id text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.active_sessions set last_seen_at = now()
   where user_id = auth.uid()
     and (p_device_id is null or device_id is not distinct from p_device_id
          or device_id is null);
  return found;
end $$;

grant execute on function public.heartbeat(text) to authenticated;

-- ---------------------------------------------------------------------------
-- COMPATIBILITY SHIMS — delete these once the deploy has settled.
--
-- Clients served the previous app.html call claim_seat()/heartbeat() with no
-- arguments and expect a boolean. A null device id lands in the "adopt the row"
-- branch, so an already-open page keeps working until it reloads. Leaving these
-- in place permanently would leave a null-device path wide enough to drive the
-- shared-login bypass straight back through.
create or replace function public.claim_seat()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  return coalesce((public.claim_seat(null::text, false) ->> 'granted')::boolean, false);
end $$;

grant execute on function public.claim_seat() to authenticated;

create or replace function public.heartbeat()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  return public.heartbeat(null::text);
end $$;

grant execute on function public.heartbeat() to authenticated;

-- DONE 2026-08-19: both shims were dropped once every client had reloaded, and
-- removed from schema.sql so a rebuild can't recreate them. Kept here only as the
-- record of what this migration originally created:
--   drop function if exists public.claim_seat();
--   drop function if exists public.heartbeat();
-- Do not re-run the two `create or replace ... ()` blocks above against a live
-- project — a null device id matches any row, so anything calling them is immune
-- to displacement, which is the bypass this migration exists to close.

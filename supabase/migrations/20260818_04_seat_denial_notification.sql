-- Record when someone is turned away by the concurrent-seat limit, and decide
-- (atomically, and at most once per 30 minutes) whether to email the owner.
--
-- Today claim_seat() returning false writes nothing anywhere: the blocked staff
-- member sees a screen, and the one person who can fix it — the owner — has no
-- idea it happened. This adds the record and the throttle; the actual email is
-- sent by the notify-seat-denied Edge Function.
--
-- Why this is a Postgres function rather than logic in that Edge Function:
--   * It re-derives the denial instead of trusting the caller, using the same
--     seat pool and staleness cutoff claim_seat() uses. Otherwise any staff
--     member could call the notify endpoint in a loop and mail their owner at
--     will.
--   * Staff cannot read active_sessions at all (owner/manager RLS), so counting
--     occupied seats needs a security-definer function regardless.
--   * Reading and writing the throttle stamp must be atomic with the decision,
--     or two devices denied in the same second both send an email.
--
-- Additive and safe against a live project. Mirrored into schema.sql.
-- Run BEFORE deploying notify-seat-denied.

alter table public.organisations
  add column if not exists seats_full_notified_at timestamptz;

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
  -- One email per org per 30 minutes. A venue at its limit denies people
  -- repeatedly — every staff member arriving for the same shift — and the owner
  -- needs telling once. The audit rows below are NOT throttled.
  v_throttle interval := interval '30 minutes';
begin
  if v_org_id is null then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'no organisation');
  end if;

  select plan_tier, concurrent_seats, heartbeat_interval_seconds, name, seats_full_notified_at
    into v_plan, v_seats, v_interval_secs, v_org_name, v_notified_at
    from public.organisations where id = v_org_id;

  -- Mirrors claim_seat()'s first branch: the owner is exempt from the pool and
  -- single-venue has no pool, so neither can genuinely be denied.
  if v_plan != 'multi' or v_role = 'owner' then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'not subject to the seat limit');
  end if;

  if exists (select 1 from public.active_sessions where user_id = auth.uid()) then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'caller holds a seat');
  end if;

  select count(*) into v_occupied from public.active_sessions
   where org_id = v_org_id
     and last_seen_at > now() - make_interval(secs => v_interval_secs * 2.5);

  if v_occupied < v_seats then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'a seat is available');
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into v_actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
  values (v_org_id, v_org_name, auth.uid(), v_actor_label, 'seat.denied', 'membership', auth.uid(), v_actor_label,
          jsonb_build_object('seats_purchased', v_seats, 'seats_occupied', v_occupied));

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
    'seats_purchased', v_seats,
    'seats_occupied', v_occupied
  );
end $$;

grant execute on function public.record_seat_denial() to authenticated;

-- ---------------------------------------------------------------------------
-- Note the update to organisations here happens under a service-role-free path
-- (security definer, function owner), so on_org_seat_change /
-- enforce_seat_minimum_term also fires — harmless, since concurrent_seats and
-- plan_tier are both unchanged and the trigger falls straight through to
-- `return new`.

-- Fix a NULL-role bypass present in every plpgsql owner/manager guard, and an
-- ambiguous column reference that made kick_user() unusable.
--
-- This is the SQL half of commit b8b16a8, which changed schema.sql but was never
-- applied to the live project — so until this runs, the database still has the
-- broken guards. Numbered 00 because it predates the stocktake-audit work and is
-- independent of it; run it any time, before or after 01.
--
-- The bug: `my_role()` returns NULL for a caller with no membership row at all.
-- `NULL != 'owner'` and `NULL not in ('owner','manager')` both evaluate to NULL,
-- and plpgsql treats a NULL IF condition as false — so every one of these
-- guards silently waved through exactly the callers who belong to no
-- organisation. They could not ultimately create a membership (my_org_id() is
-- NULL and memberships.org_id is not-null), but they reached the code past the
-- guard, and in adopt_existing_team_member()'s case that means an email
-- enumeration oracle: "No existing account uses that email" versus "already
-- belongs to an organisation" distinguishes registered addresses from
-- unregistered ones. Fixed with `is distinct from` / `coalesce(..., '')`.
--
-- Separately, kick_user() declared a variable named `org_id`, shadowing the
-- identically-named column in its own predicates. `org_id = org_id` is
-- ambiguous, and Postgres's default plpgsql.variable_conflict = error raises
-- 'column reference "org_id" is ambiguous' at runtime — for every caller,
-- including a legitimate owner. That function could never have worked. It has no
-- client call site today (the kick-user Edge Function replaced it) but remains
-- granted to `authenticated`, so it stays reachable over /rest/v1/rpc.
--
-- All additive `create or replace`. Safe against a live project.

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
create or replace function public.adopt_existing_team_member(p_email text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid;
begin
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can add team members.';
  end if;

  select u.id into v_user_id
    from auth.users u
   where lower(u.email) = lower(trim(p_email));

  if v_user_id is null then
    raise exception 'No existing account uses that email.';
  end if;

  if exists (select 1 from public.memberships where user_id = v_user_id) then
    raise exception 'That person already belongs to an organisation.';
  end if;

  perform public.add_team_member(v_user_id, p_role);
end $$;

-- ---------------------------------------------------------------------------
create or replace function public.get_daily_code()
returns text language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.my_org_id();
  v_code text;
  v_date date;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'Only owners and managers can view the daily code.';
  end if;

  select daily_code, daily_code_date into v_code, v_date
    from public.organisations where id = v_org_id;

  if v_date is distinct from current_date then
    v_code := substr(md5(random()::text || clock_timestamp()::text), 1, 6);
    update public.organisations
       set daily_code = v_code, daily_code_date = current_date
     where id = v_org_id;
  end if;

  return v_code;
end $$;

-- ---------------------------------------------------------------------------
create or replace function public.list_org_members()
returns table (user_id uuid, email text, full_name text, role text, joined_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'Only owners and managers can view the roster.';
  end if;

  return query
    select m.user_id, u.email::text, p.full_name, m.role, m.created_at
      from public.memberships m
      join auth.users u on u.id = m.user_id
      left join public.profiles p on p.id = m.user_id
     where m.org_id = public.my_org_id()
     order by m.created_at asc;
end $$;

-- ---------------------------------------------------------------------------
-- v_org_id, not org_id — see the header note on the ambiguity.
create or replace function public.kick_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  v_org_id uuid := public.my_org_id();
  target_label text;
begin
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can log out a team member.';
  end if;
  if not exists (select 1 from public.memberships m where m.user_id = p_user_id and m.org_id = v_org_id) then
    raise exception 'That person is not a member of your organisation.';
  end if;

  delete from public.active_sessions s where s.user_id = p_user_id and s.org_id = v_org_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select coalesce(p.full_name, u.email, 'Unknown user') into target_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user_id;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label)
  values (v_org_id, (select name from public.organisations where id = v_org_id), actor, actor_label,
          'membership.force_logged_out_by_owner', 'membership', p_user_id, target_label);
end $$;

-- ---------------------------------------------------------------------------
create or replace function public.list_active_sessions()
returns table (user_id uuid, email text, full_name text, last_seen_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.my_org_id();
  v_interval_secs integer;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'Only owners and managers can view active sessions.';
  end if;

  select heartbeat_interval_seconds into v_interval_secs
    from public.organisations where id = v_org_id;

  return query
    select s.user_id, u.email::text, p.full_name, s.last_seen_at
      from public.active_sessions s
      join auth.users u on u.id = s.user_id
      left join public.profiles p on p.id = s.user_id
     where s.org_id = v_org_id
       and s.last_seen_at > now() - make_interval(secs => v_interval_secs * 2.5)
     order by s.last_seen_at desc;
end $$;

-- Note: clear_stocktake_items() has the same coalesce fix, but it is replaced
-- wholesale by migration 01 (which also adds its owner/manager guard), so it is
-- deliberately not repeated here.

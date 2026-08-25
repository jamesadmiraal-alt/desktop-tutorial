-- Archive venues and locations instead of deleting them.
--
-- Why: an operator sold a venue and could not remove it. That looked like a
-- permissions problem but wasn't — RLS already lets owner/manager DELETE both
-- tables. The blocker is referential integrity:
--
--   stocktakes.location_id ... on delete restrict
--   locations.venue_id     ... on delete cascade  (from venues)
--
-- so any location that has ever been counted cannot be deleted, and a venue
-- containing one inherits that. The FK is doing its job: refusing to shred
-- count records. Archiving retires a venue while keeping its history, and is
-- reversible. Plain DELETE still works for a never-counted venue/location.
--
-- Run BEFORE pushing the new app.html/admin.html — the console calls
-- set_venue_archived / set_location_archived, and the app filters on columns
-- that don't exist yet.
--
-- Safe to run twice. Additive: two nullable columns, two new functions, and
-- policy replacements that only ever narrow inserts. No existing row changes,
-- and nothing is deleted. Mirrored into schema.sql.

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.venues    add column if not exists archived_at timestamptz;
alter table public.locations add column if not exists archived_at timestamptz;

-- ---------------------------------------------------------------------------
-- 2. Lock the columns down
--
-- archived_at must move ONLY through the RPCs below, which are owner-only and
-- always write an audit row. The update policies on these tables admit
-- managers, and RLS cannot restrict columns — so the column GRANT is the only
-- place this can be enforced. Same pattern as profiles.full_name.
--
-- `name` (and locations.venue_id, for the existing 'location.moved' flow) stay
-- writable, so renaming from the console keeps working — including from the
-- currently deployed page, which means this block is safe to run before the
-- push.
-- ---------------------------------------------------------------------------
revoke update on public.venues from authenticated, anon;
grant  update (name) on public.venues to authenticated;

revoke update on public.locations from authenticated, anon;
grant  update (name, venue_id) on public.locations to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Archived rows must stop counting against the single-venue cap
--
-- Without this, an operator on the single-venue plan who sells their only venue
-- and archives it can NEVER create the replacement: the cap of one is
-- permanently consumed by a venue they no longer own, and the only way out
-- would be deleting the history archiving exists to preserve.
-- ---------------------------------------------------------------------------
drop policy if exists "owner manager insert venues" on public.venues;
create policy "owner manager insert venues" on public.venues
  for insert with check (
    org_id = public.my_org_id()
    and public.my_role() in ('owner', 'manager')
    and (
      (select plan_tier from public.organisations where id = venues.org_id) = 'multi'
      or (
        (select plan_tier from public.organisations where id = venues.org_id) = 'single'
        and (select count(*) from public.venues
              where org_id = venues.org_id and archived_at is null) = 0
      )
    )
  );

-- No new locations inside an archived venue. An archived venue stays readable
-- (that is what makes Restore possible), so without this a stale client could
-- keep filling it.
drop policy if exists "owner manager insert locations" on public.locations;
create policy "owner manager insert locations" on public.locations
  for insert with check (
    org_id = public.my_org_id()
    and public.my_role() in ('owner', 'manager')
    and exists (
      select 1 from public.venues v
       where v.id = locations.venue_id and v.org_id = locations.org_id
         and v.archived_at is null
    )
  );

-- No starting a count at an archived location, or at one whose venue is
-- archived. Enforced here and not just in the app because a phone can hold a
-- location list loaded before the venue was retired.
drop policy if exists "org members insert stocktakes" on public.stocktakes;
create policy "org members insert stocktakes" on public.stocktakes
  for insert with check (
    org_id = public.my_org_id()
    and exists (
      select 1 from public.locations l
        join public.venues v on v.id = l.venue_id
       where l.id = stocktakes.location_id and l.org_id = stocktakes.org_id
         and l.archived_at is null and v.archived_at is null
    )
  );

-- ---------------------------------------------------------------------------
-- 4. The RPCs
--
-- Archiving a venue deliberately does NOT stamp its locations. A location is
-- *effectively* archived when its own archived_at is set OR its venue's is, and
-- every read filters on both. If archiving a venue stamped its children,
-- restoring it could not tell "archived because its venue was" from "already
-- archived on its own beforehand", and would wrongly revive the second kind.
--
-- Archiving the org's last active venue is allowed on purpose: that is the
-- middle of the "sold one, buying another" transition, and §3 above is what
-- lets the replacement be created.
-- ---------------------------------------------------------------------------
create or replace function public.set_venue_archived(
  p_venue_id uuid,
  p_archived boolean
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_venue_org uuid;
  v_venue_name text;
  v_was_archived timestamptz;
  v_locations integer;
  v_stocktakes integer;
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  -- coalesce, not `<>`: my_role() is NULL for a caller with no membership, and
  -- `NULL <> 'owner'` is NULL, which plpgsql treats as false — the null-role
  -- bypass this codebase has already been bitten by once.
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Only the owner can archive or restore a venue.';
  end if;

  select v.org_id, v.name, v.archived_at
    into v_venue_org, v_venue_name, v_was_archived
    from public.venues v where v.id = p_venue_id;

  -- security definer bypasses RLS, so re-implement org scoping. Same message
  -- either way, so this can't be used to probe for UUIDs.
  if v_venue_org is null or v_venue_org is distinct from v_org then
    raise exception 'Venue not found.';
  end if;

  -- No-op, not an error: two admin tabs can race the same button, and writing
  -- nothing avoids a misleading "archived an already-archived venue" log row.
  if (v_was_archived is not null) = p_archived then
    return;
  end if;

  update public.venues
     set archived_at = case when p_archived then now() else null end
   where id = p_venue_id;

  -- For the log, not for a decision: "archived Old Tavern" alone doesn't convey
  -- that 31 counts just left every screen.
  select count(*) into v_locations
    from public.locations l where l.venue_id = p_venue_id;
  select count(*) into v_stocktakes
    from public.stocktakes s
    join public.locations l on l.id = s.location_id
   where l.venue_id = p_venue_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
  values (v_org, org_label, actor, actor_label,
          case when p_archived then 'venue.archived' else 'venue.restored' end,
          'venue', p_venue_id, v_venue_name,
          jsonb_build_object('archived_at', v_was_archived),
          jsonb_build_object(
            'archived', p_archived,
            'locations_affected', v_locations,
            'stocktakes_affected', v_stocktakes));
end $$;

grant execute on function public.set_venue_archived(uuid, boolean) to authenticated;

create or replace function public.set_location_archived(
  p_location_id uuid,
  p_archived boolean
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_loc_org uuid;
  v_loc_name text;
  v_was_archived timestamptz;
  v_stocktakes integer;
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Only the owner can archive or restore a location.';
  end if;

  select l.org_id, l.name, l.archived_at
    into v_loc_org, v_loc_name, v_was_archived
    from public.locations l where l.id = p_location_id;

  if v_loc_org is null or v_loc_org is distinct from v_org then
    raise exception 'Location not found.';
  end if;

  if (v_was_archived is not null) = p_archived then
    return;
  end if;

  update public.locations
     set archived_at = case when p_archived then now() else null end
   where id = p_location_id;

  select count(*) into v_stocktakes
    from public.stocktakes s where s.location_id = p_location_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
  values (v_org, org_label, actor, actor_label,
          case when p_archived then 'location.archived' else 'location.restored' end,
          'location', p_location_id, v_loc_name,
          jsonb_build_object('archived_at', v_was_archived),
          jsonb_build_object('archived', p_archived, 'stocktakes_affected', v_stocktakes));
end $$;

grant execute on function public.set_location_archived(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- NOTE: the existing log_venues_change()/log_locations_change() triggers are
-- untouched and do NOT double-log this. Both only fire their UPDATE branch on a
-- name change (and locations also on venue_id), so an archived_at-only update
-- matches no branch and writes nothing. The RPCs above log explicitly instead.
--
-- ---------------------------------------------------------------------------
-- Verify (as the owner, from the SQL editor's auth context or the app):
--   select id, name, archived_at from public.venues order by name;
--
--   -- direct write must be refused even for the owner:
--   update public.venues set archived_at = now() where id = '<venue>';
--   -- ERROR: permission denied for table venues
--
--   -- the RPC is the way in, and logs:
--   select public.set_venue_archived('<venue>', true);
--   select actor_label, action, target_label,
--          after->>'stocktakes_affected' as stocktakes
--     from public.audit_log
--    where action in ('venue.archived','venue.restored',
--                     'location.archived','location.restored')
--    order by created_at desc limit 5;
--
--   -- and a single-venue org can now replace an archived venue:
--   --   archive the only venue, then insert a new one — must succeed.

-- "Staff only see stocktakes they started" — an owner-controlled visibility
-- boundary on stocktakes.
--
-- OFF (the default, and what every existing organisation gets): unchanged.
-- Every member sees every stocktake in their org, exactly as today.
--
-- ON: a `staff` member sees only the stocktakes they started themselves.
-- `owner` and `manager` always see all of them, whatever the flag says.
--
-- ---------------------------------------------------------------------------
-- READ THIS BEFORE TURNING THE FLAG ON — it changes counting, not just listing
-- ---------------------------------------------------------------------------
-- Today any staff member can open any in-progress take and scan into it, which
-- is how two people count one cellar together. With the flag ON they cannot:
-- if you can't SELECT the take, you can't open it, and the triggers below stop
-- you writing items into it even if you still know its id. Shared counting
-- between staff becomes owner/manager-only territory.
--
-- That is the feature working as specified, not a side effect — but it is the
-- part that will generate a support call, so it is stated here rather than
-- discovered on a Friday night.
--
-- Second consequence: stocktakes.created_by is `on delete set null`, and its
-- column comment in schema.sql said "audit only, not a security predicate".
-- This migration makes it one. A take whose creator's account has since been
-- deleted has created_by = NULL and, with the flag ON, is visible to
-- owner/manager only. Check for those before switching a venue over:
--
--   select count(*) from public.stocktakes where created_by is null;
--
-- ---------------------------------------------------------------------------
-- Safety: with the flag OFF every predicate below short-circuits to the
-- current behaviour, so running this migration changes nothing observable
-- until an owner turns it on. It is safe to run while people are counting.
--
-- Additive except for four policy swaps, each dropped and recreated in place.
-- Safe to run twice. Mirrored into schema.sql.
--
-- Run BEFORE pushing the new admin.html, which offers the toggle.

-- ---------------------------------------------------------------------------
-- 1. The flag
--
-- On the client-writable GRANT rather than behind an RPC, unlike
-- set_scan_prefs(): that one existed because managers needed it and the
-- "owner update org" policy is owner-only. Here owner-only is exactly the
-- requirement, so the existing policy is already the right boundary and a
-- function would add nothing but indirection.
-- ---------------------------------------------------------------------------
alter table public.organisations
  add column if not exists staff_see_own_stocktakes_only boolean not null default false;

revoke update on public.organisations from authenticated;
grant update (name, logo_url, export_format, join_code, country, roster_last_viewed_at,
              heartbeat_interval_seconds, staff_see_own_stocktakes_only)
  on public.organisations to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Two helpers, so the rule exists in ONE place
--
-- Four policies and two triggers depend on this predicate. Written out six
-- times it would drift, and a visibility rule that drifts is a leak.
--
-- Both are `stable` (evaluated once per statement, not once per row) and
-- `security definer` (they read organisations/stocktakes, which the caller may
-- not be able to read for themselves — and can_see_stocktake() is called from
-- the stocktakes policy itself, so without definer it would recurse).
-- ---------------------------------------------------------------------------
create or replace function public.staff_sees_own_only()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select o.staff_see_own_stocktakes_only
       from public.organisations o
      where o.id = public.my_org_id()),
    false);
$$;

grant execute on function public.staff_sees_own_only() to authenticated;

-- Used by the triggers below, which run inside security-definer RPCs where RLS
-- is not in play at all. Deliberately the whole rule, not just the flag.
create or replace function public.can_see_stocktake(p_stocktake_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.stocktakes s
     where s.id = p_stocktake_id
       and s.org_id = public.my_org_id()
       and (
         -- coalesce, not `in` on a possibly-NULL role: my_role() is NULL for a
         -- caller with no membership, and `NULL in (...)` is NULL, which reads
         -- as false in some contexts and has bitten this file before.
         coalesce(public.my_role(), '') in ('owner', 'manager')
         or not public.staff_sees_own_only()
         or s.created_by = auth.uid()
       )
  );
$$;

grant execute on function public.can_see_stocktake(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The stocktakes SELECT policy
--
-- Inlined rather than calling can_see_stocktake(), which would re-query
-- stocktakes once per row to answer a question about the row already in hand.
-- ---------------------------------------------------------------------------
drop policy if exists "read org stocktakes" on public.stocktakes;
create policy "read org stocktakes" on public.stocktakes
  for select using (
    org_id = public.my_org_id()
    and (
      coalesce(public.my_role(), '') in ('owner', 'manager')
      or not public.staff_sees_own_only()
      or created_by = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 4. stocktake_items must not become the back door
--
-- This is the part that matters most. Before this, item SELECT was
-- `org_id = my_org_id()` — so a staff member who could no longer see a
-- stocktake could still read every barcode and quantity in it, AND harvest its
-- id from stocktake_id to feed the RPCs below. Hiding the take while leaving
-- its contents readable would have been theatre.
--
-- Expressed as "the parent is visible to me" rather than by repeating the
-- predicate: the subquery is itself subject to the stocktakes policy above, so
-- there is exactly one definition of visible.
--
-- The INSERT policy already contains an `exists` against stocktakes and so
-- tightens automatically with the policy above — it is left alone on purpose.
-- ---------------------------------------------------------------------------
drop policy if exists "read org items" on public.stocktake_items;
create policy "read org items" on public.stocktake_items
  for select using (
    org_id = public.my_org_id()
    and exists (
      select 1 from public.stocktakes s where s.id = stocktake_items.stocktake_id
    )
  );

drop policy if exists "org members update items" on public.stocktake_items;
create policy "org members update items" on public.stocktake_items
  for update using (
    org_id = public.my_org_id()
    and exists (
      select 1 from public.stocktakes s where s.id = stocktake_items.stocktake_id
    )
  )
  with check (
    org_id = public.my_org_id()
    and exists (
      select 1 from public.stocktakes s where s.id = stocktake_items.stocktake_id
    )
  );

-- ---------------------------------------------------------------------------
-- 5. The RPCs bypass RLS, so policies alone are not enough
--
-- add_stocktake_item(), set_stocktake_item_qty(), delete_stocktake_items() and
-- set_stocktake_status() are all `security definer`. They check the caller's
-- ORG and stop there, which was right when every org member could see every
-- take and is not any more: knowing a uuid would be enough to scan into, edit,
-- or mark ready a count you cannot open.
--
-- A trigger rather than rewriting those four functions, which is the pattern
-- this schema already uses for exactly this reason — see
-- enforce_stocktake_not_completed(), a trigger "because the item RPCs are
-- security definer and bypass policies". It also covers any future writer
-- without anyone having to remember this rule.
--
-- auth.uid() IS NULL means service_role, the SQL editor, or an edge function —
-- none of which have a membership and all of which are trusted here. Same
-- guard as log_organisations_change().
-- ---------------------------------------------------------------------------
create or replace function public.enforce_stocktake_visible()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_take uuid := coalesce(new.stocktake_id, old.stocktake_id);
  v_parent_exists boolean;
begin
  if auth.uid() is null then
    return coalesce(new, old);
  end if;
  -- Does the parent still exist AT ALL, visibility aside? Deleting a stocktake
  -- cascades to its items, and by the time those row deletions run the parent
  -- is already gone — so a check that failed closed here would make deleting a
  -- stocktake impossible. enforce_stocktake_not_completed() passes in the same
  -- situation for the same reason (its `v_status = 'completed'` is NULL, hence
  -- false, when the lookup finds nothing).
  --
  -- Not a hole: stocktake_items.stocktake_id is a foreign key, so an INSERT
  -- naming a stocktake that doesn't exist is refused by the FK anyway.
  select exists (select 1 from public.stocktakes s where s.id = v_take)
    into v_parent_exists;
  if not v_parent_exists then
    return coalesce(new, old);
  end if;

  if not public.can_see_stocktake(v_take) then
    -- Same message the RPCs use for a take in another org, so this can't be
    -- used to tell "hidden from me" from "doesn't exist".
    raise exception 'Stocktake not found.';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists stocktake_items_visible on public.stocktake_items;
create trigger stocktake_items_visible
  before insert or update or delete on public.stocktake_items
  for each row execute function public.enforce_stocktake_visible();

-- The same hole on the parent row: client UPDATE on stocktakes is revoked, so
-- set_stocktake_status() is the only writer — and it is security definer too.
create or replace function public.enforce_stocktake_row_visible()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    return new;
  end if;
  if not public.can_see_stocktake(new.id) then
    raise exception 'Stocktake not found.';
  end if;
  return new;
end $$;

drop trigger if exists stocktakes_visible_on_update on public.stocktakes;
create trigger stocktakes_visible_on_update
  before update on public.stocktakes
  for each row execute function public.enforce_stocktake_row_visible();

-- ---------------------------------------------------------------------------
-- 6. Audit the flag itself
--
-- It is a permission boundary — it decides what a whole role can and cannot
-- see — so who moved it and when belongs in the same trail as role changes.
--
-- This is a `create or replace` of the WHOLE function, so every existing
-- branch below is reproduced verbatim from schema.sql and only the
-- staff_visibility one is new. Check that list against schema.sql before
-- running if this file has been sitting around: dropping a branch here would
-- silently stop auditing that column, and nothing would fail loudly.
-- ---------------------------------------------------------------------------
create or replace function public.log_organisations_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
begin
  if actor is null then
    return new;
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;

  if old.name is distinct from new.name then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.name_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if old.logo_url is distinct from new.logo_url then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.logo_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if old.export_format is distinct from new.export_format then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.export_format_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if old.country is distinct from new.country then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.country_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if old.join_code is distinct from new.join_code then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.join_code_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if old.heartbeat_interval_seconds is distinct from new.heartbeat_interval_seconds then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.heartbeat_interval_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  -- The new one.
  if old.staff_see_own_stocktakes_only is distinct from new.staff_see_own_stocktakes_only then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.staff_visibility_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;

  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Verify
--
-- The SQL editor runs as a superuser, which ignores RLS — so these tests
-- impersonate real users. Everything is inside begin/rollback and writes
-- nothing.
--
--   -- 0. who is who (pick two staff and a manager in one org):
--   select m.user_id, m.role, u.email, m.org_id
--     from public.memberships m join auth.users u on u.id = m.user_id
--    order by m.org_id, m.role;
--
--   -- 1. flag OFF (current state) — a staff member still sees everything:
--   begin;
--     set local role authenticated;
--     set local request.jwt.claims = '{"sub":"<STAFF_A_UUID>","role":"authenticated"}';
--     select count(*) as takes_visible from public.stocktakes;
--     select count(*) as items_visible from public.stocktake_items;
--   rollback;
--
--   -- 2. same staff member with the flag ON — own takes only.
--   --    (the update is rolled back, so nothing is actually switched on)
--   begin;
--     update public.organisations set staff_see_own_stocktakes_only = true
--      where id = '<ORG_UUID>';
--     set local role authenticated;
--     set local request.jwt.claims = '{"sub":"<STAFF_A_UUID>","role":"authenticated"}';
--     select count(*) filter (where created_by = '<STAFF_A_UUID>') as own,
--            count(*) filter (where created_by is distinct from '<STAFF_A_UUID>') as others
--       from public.stocktakes;
--     -- expect: others = 0
--     -- and the items back door is shut too:
--     select count(*) as items_visible from public.stocktake_items;
--     -- expect: only items belonging to STAFF_A's own takes
--   rollback;
--
--   -- 3. a manager with the flag ON still sees all:
--   begin;
--     update public.organisations set staff_see_own_stocktakes_only = true
--      where id = '<ORG_UUID>';
--     set local role authenticated;
--     set local request.jwt.claims = '{"sub":"<MANAGER_UUID>","role":"authenticated"}';
--     select count(*) as takes_visible from public.stocktakes;
--     -- expect: the org's full count, same as step 1
--   rollback;
--
--   -- 4. the RPC back door is shut — staff A scanning into staff B's take:
--   begin;
--     update public.organisations set staff_see_own_stocktakes_only = true
--      where id = '<ORG_UUID>';
--     set local role authenticated;
--     set local request.jwt.claims = '{"sub":"<STAFF_A_UUID>","role":"authenticated"}';
--     select public.add_stocktake_item('<STAFF_B_TAKE_UUID>', '9310072012345', 1);
--     -- expect: ERROR: Stocktake not found.
--   rollback;
--
--   -- 5. and staff A can still scan into their OWN take:
--   begin;
--     update public.organisations set staff_see_own_stocktakes_only = true
--      where id = '<ORG_UUID>';
--     set local role authenticated;
--     set local request.jwt.claims = '{"sub":"<STAFF_A_UUID>","role":"authenticated"}';
--     select public.add_stocktake_item('<STAFF_A_TAKE_UUID>', '9310072012345', 1);
--     -- expect: a stocktake_items row back
--   rollback;
--
--   -- 6. owner-only at the API. As a MANAGER this must fail:
--   --   PATCH /rest/v1/organisations?id=eq.<org>
--   --        {"staff_see_own_stocktakes_only": true}
--   -- expect: 0 rows updated (the owner-only policy filters it out)
--
--   -- 7. REGRESSION: deleting a stocktake still works with the flag ON.
--   --    Its items cascade, and by then the parent row is gone — a
--   --    visibility check that failed closed there would abort the delete.
--   --    Rolled back, so the take survives.
--   begin;
--     update public.organisations set staff_see_own_stocktakes_only = true
--      where id = '<ORG_UUID>';
--     set local role authenticated;
--     set local request.jwt.claims = '{"sub":"<OWNER_UUID>","role":"authenticated"}';
--     delete from public.stocktakes where id = '<ANY_TAKE_UUID_WITH_ITEMS>';
--     -- expect: DELETE 1, no exception
--   rollback;
-- ---------------------------------------------------------------------------

-- Close the unlogged-destruction holes in stocktake data.
--
-- Motivation: a venue can delete work mid-count and then claim Gantry lost it.
-- `stocktake.deleted` was already logged, but (a) it recorded no item count, so
-- it proved nothing about scale, (b) per-item deletes wrote nothing at all, and
-- (c) quantity edits wrote nothing at all. After this, every way an operator can
-- destroy scanned data leaves an attributable row in audit_log.
--
-- Safe to run against a live project: additive, no drops of tables or data.
-- Mirrored into schema.sql. Run this BEFORE deploying the new app.html; the
-- companion revoke migration (02) runs AFTER.

-- ---------------------------------------------------------------------------
-- 1. stocktake.deleted, now with counts, and moved to BEFORE DELETE.
--
-- BEFORE is load-bearing: `on delete cascade` is an internal AFTER ROW trigger
-- on the parent named RI_ConstraintTrigger_a_<oid>, and AFTER row triggers on
-- the same event fire in strcmp(tgname) order — 'R' (0x52) before 'l' (0x6C) —
-- so the cascade removing this stocktake's items runs before an AFTER
-- log_stocktakes_audit would. Counting items from AFTER returns 0, silently.
-- ---------------------------------------------------------------------------
create or replace function public.log_stocktakes_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  item_count integer;
  unit_total bigint;
begin
  if actor is null then
    return old;
  end if;

  select count(*), coalesce(sum(i.qty), 0)
    into item_count, unit_total
    from public.stocktake_items i
   where i.stocktake_id = old.id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = old.org_id;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
  values (old.org_id, org_label, actor, actor_label, 'stocktake.deleted', 'stocktake', old.id, old.name,
          to_jsonb(old) || jsonb_build_object('items_deleted', item_count, 'units_deleted', unit_total));
  return old;
end $$;

drop trigger if exists log_stocktakes_audit on public.stocktakes;
create trigger log_stocktakes_audit
  before delete on public.stocktakes
  for each row execute function public.log_stocktakes_change();

-- ---------------------------------------------------------------------------
-- 2. The logged replacement for the client's direct per-item DELETE.
-- Staff may call it: correcting a mis-scan must not need a manager.
-- ---------------------------------------------------------------------------
create or replace function public.delete_stocktake_items(p_item_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_ids uuid[];
  v_take_id uuid;
  v_take_name text;
  v_distinct_takes integer;
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  removed jsonb;
  removed_count integer;
  unit_total bigint;
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;

  select array_agg(distinct x) into v_ids
    from unnest(coalesce(p_item_ids, '{}'::uuid[])) as x;
  if v_ids is null then
    raise exception 'No items given to remove.';
  end if;
  if array_length(v_ids, 1) > 500 then
    raise exception 'Too many items in one request (max 500). Use Clear items instead.';
  end if;

  select count(*), count(distinct i.stocktake_id), min(i.stocktake_id), coalesce(sum(i.qty), 0)
    into removed_count, v_distinct_takes, v_take_id, unit_total
    from public.stocktake_items i
   where i.id = any(v_ids) and i.org_id = v_org;

  if removed_count <> array_length(v_ids, 1) or v_distinct_takes <> 1 then
    raise exception 'Those items could not all be found in one of your stocktakes.';
  end if;

  select jsonb_agg(jsonb_build_object('barcode', i.barcode, 'qty', i.qty, 'scanned_by', i.scanned_by)
                   order by i.barcode)
    into removed
    from public.stocktake_items i where i.id = any(v_ids);

  select s.name into v_take_name from public.stocktakes s where s.id = v_take_id;
  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  delete from public.stocktake_items i where i.id = any(v_ids);

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
  values (v_org, org_label, actor, actor_label, 'stocktake_items.deleted', 'stocktake', v_take_id, v_take_name,
          jsonb_build_object('items_deleted', removed_count, 'units_deleted', unit_total, 'items', removed));
  return removed_count;
end $$;

grant execute on function public.delete_stocktake_items(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. clear_stocktake_items: owner/manager only, plus a unit total.
-- Wiping every item destroys as much as deleting the stocktake, which is
-- already owner/manager — the previous staff-allowed behaviour was the exact
-- action this audit trail exists to make undeniable.
-- ---------------------------------------------------------------------------
create or replace function public.clear_stocktake_items(p_stocktake_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  take_name text;
  take_org uuid;
  cleared_count integer;
  cleared_units bigint;
begin
  select s.org_id, s.name into take_org, take_name
    from public.stocktakes s where s.id = p_stocktake_id;

  if take_org is null or take_org != public.my_org_id() then
    raise exception 'Stocktake not found.';
  end if;

  -- coalesce, not `!=`: my_role() is NULL for a caller with no membership and
  -- `NULL not in (...)` is NULL, which plpgsql treats as false.
  if coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'Only owners and managers can clear a whole stocktake. Remove items individually, or ask a manager.';
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = take_org;

  select coalesce(sum(i.qty), 0) into cleared_units
    from public.stocktake_items i where i.stocktake_id = p_stocktake_id;

  delete from public.stocktake_items where stocktake_id = p_stocktake_id;
  get diagnostics cleared_count = row_count;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
  values (take_org, org_label, actor, actor_label, 'stocktake_items.cleared', 'stocktake', p_stocktake_id, take_name,
          jsonb_build_object('items_cleared', cleared_count, 'units_cleared', cleared_units));
end $$;

grant execute on function public.clear_stocktake_items(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Quantity reductions. `update stocktake_items set qty = 1` empties a count
-- without deleting anything, and left no trace whatsoever before this.
-- Statement-level with a transition table: one row per UPDATE statement however
-- many items it touched. Increases are ordinary scanning and are not logged.
-- ---------------------------------------------------------------------------
create or replace function public.log_item_qty_reduced()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  r record;
begin
  if actor is null then
    return null;
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;

  for r in
    select o.stocktake_id,
           o.org_id,
           count(*)                        as lines,
           coalesce(sum(o.qty - n.qty), 0) as units_removed
      from old_items o join new_items n on n.id = o.id
     where n.qty < o.qty
     group by o.stocktake_id, o.org_id
  loop
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
    select r.org_id, org.name, actor, actor_label, 'stocktake_items.qty_reduced', 'stocktake', r.stocktake_id, s.name,
           jsonb_build_object('lines_reduced', r.lines, 'units_removed', r.units_removed)
      from public.stocktakes s join public.organisations org on org.id = r.org_id
     where s.id = r.stocktake_id;
  end loop;
  return null;
end $$;

drop trigger if exists log_item_qty_reduced_audit on public.stocktake_items;
create trigger log_item_qty_reduced_audit
  after update on public.stocktake_items
  referencing old table as old_items new table as new_items
  for each statement execute function public.log_item_qty_reduced();

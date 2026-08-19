-- Decimal quantities, and zero as a valid count.
--
-- Bars count part bottles: spirits and wine sold by the glass are routinely half
-- or a quarter full. qty was `integer not null check (qty >= 1)`, so an operator
-- eyeballing 0.4 of a bottle had to round to 1 (wrong) or 0 (rejected outright).
--
-- Two changes:
--   * numeric(12,2) — 0.25 / 0.5 / 0.1 / 0.05 all representable
--   * check (qty >= 0) — "I checked and there are none" is real stocktake
--     information, and different from "never scanned it"
--
-- Safe against a live project. Widening integer -> numeric is lossless, and the
-- check loosens rather than tightens, so no existing row can be made invalid.
-- Mirrored into schema.sql.
--
-- Run BEFORE pushing the new app.html — the new client can send 0 and 0.4, which
-- the old constraint would reject. The reverse is harmless: the OLD client keeps
-- working against numeric, since it only ever sent whole numbers.
--
-- Note on the lock: `alter column ... type` rewrites the table and takes an ACCESS
-- EXCLUSIVE lock. On a stocktake_items of this size that's milliseconds, but it
-- does mean scans will error rather than queue if anyone is mid-count. Run it when
-- nobody's counting.

alter table public.stocktake_items drop constraint if exists stocktake_items_qty_check;

alter table public.stocktake_items
  alter column qty type numeric(12,2) using qty::numeric(12,2);

alter table public.stocktake_items
  add constraint stocktake_items_qty_check check (qty >= 0);

-- ---------------------------------------------------------------------------
-- The functions that SUM qty all declared bigint accumulators, which would
-- truncate a part-bottle total — "1032 units" when the real figure is 1032.75
-- makes the audit log's own evidence wrong. Only the declarations change; the
-- logic is untouched.
--
-- Rather than repeat all four bodies here, this migration only re-creates the
-- declaration lines that matter. Each is a full `create or replace` because
-- plpgsql has no way to alter a single declaration.
-- ---------------------------------------------------------------------------

-- log_stocktakes_change: unit_total bigint -> numeric
create or replace function public.log_stocktakes_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  item_count integer;
  unit_total numeric;
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

-- delete_stocktake_items: unit_total bigint -> numeric
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
  unit_total numeric;
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

-- clear_stocktake_items: cleared_units bigint -> numeric
create or replace function public.clear_stocktake_items(p_stocktake_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  take_name text;
  take_org uuid;
  cleared_count integer;
  cleared_units numeric;
begin
  select s.org_id, s.name into take_org, take_name
    from public.stocktakes s where s.id = p_stocktake_id;

  if take_org is null or take_org != public.my_org_id() then
    raise exception 'Stocktake not found.';
  end if;

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

-- log_item_qty_reduced needs no change: its sum is inferred from the transition
-- tables rather than declared, so it becomes numeric automatically. Included here
-- only so the next reader doesn't go looking for a fifth edit.

-- ---------------------------------------------------------------------------
-- Verify:
--   select qty, pg_typeof(qty) from public.stocktake_items limit 1;   -- numeric
--   -- 0 now allowed, negatives still not:
--   update public.stocktake_items set qty = 0 where id = '<id>';       -- succeeds
--   update public.stocktake_items set qty = -1 where id = '<id>';      -- rejected
--   update public.stocktake_items set qty = 0.25 where id = '<id>';    -- succeeds
--
-- AND, most importantly, check how it reaches the browser — a numeric arriving as
-- a JSON string would turn the client's `0 + qty` totals into string
-- concatenation, silently. See the app.html comment on qtyNum().

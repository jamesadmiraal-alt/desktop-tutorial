-- Fix: removing a scanned line failed with `function min(uuid) does not exist`.
--
-- delete_stocktake_items() resolved "which stocktake are these items in" with
-- min(i.stocktake_id). Postgres has no min() for uuid, so the call raised every
-- single time — plpgsql only plans a statement on first EXECUTION, which is why
-- the function was created without complaint and then failed at run time.
--
-- Scope of the breakage: the ✕ on a stocktake line has been dead for EVERY
-- role, not just staff, since 20260818_01_stocktake_audit.sql introduced the
-- line on 2026-08-18. clear_stocktake_items() was never affected (it takes the
-- stocktake id as an argument and needs no aggregate).
--
-- The fix is (array_agg(i.stocktake_id))[1], and taking the first element is
-- exact rather than arbitrary: the very next statement rejects the call unless
-- count(distinct i.stocktake_id) = 1, so every row carries the same value.
--
-- The two historical files that contain the bad line
-- (20260818_01_stocktake_audit.sql, 20260820_01_decimal_qty.sql) are
-- deliberately NOT edited — rule 2 in the README. This supersedes them.
--
-- `create or replace`, same signature, no data touched. Safe to run twice, and
-- safe to run while people are counting. Mirrored into schema.sql.
--
-- Run any time — the deployed app.html already calls this and currently gets an
-- error toast, so the sooner it runs the sooner ✕ works.
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
  unit_total numeric; -- numeric, not bigint — see log_stocktakes_change above
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

  -- Authorise and resolve in one pass: every id must exist, belong to the
  -- CALLER's org, and sit in ONE stocktake so the single audit row below has an
  -- unambiguous subject. Any mismatch is reported identically, so this can't be
  -- used to probe which item UUIDs exist in other organisations.
  -- (array_agg(...))[1] rather than min(): Postgres has no min(uuid), and this
  -- line raised `function min(uuid) does not exist` on EVERY call from the day
  -- it shipped — plpgsql only plans the statement on first execution, so it
  -- was created without complaint and failed at run time. Line delete was
  -- broken for everyone, not just staff, until 2026-09-09.
  --
  -- Taking the first element is exact, not a guess: v_distinct_takes is checked
  -- to be 1 immediately below, so every row carries the same stocktake_id.
  select count(*), count(distinct i.stocktake_id), (array_agg(i.stocktake_id))[1], coalesce(sum(i.qty), 0)
    into removed_count, v_distinct_takes, v_take_id, unit_total
    from public.stocktake_items i
   where i.id = any(v_ids) and i.org_id = v_org;

  if removed_count <> array_length(v_ids, 1) or v_distinct_takes <> 1 then
    raise exception 'Those items could not all be found in one of your stocktakes.';
  end if;

  -- Snapshot barcode + qty BEFORE deleting. This is what turns the log from
  -- "someone removed 3 items" into "someone removed 9312345678907 x14" — from
  -- an accusation into evidence. Affordable at per-action scale; the bulk paths
  -- keep counts only, since loadAuditLog() does select('*') and would otherwise
  -- download the whole payload on every page load.
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
-- Verify:
--
--   -- 1. the aggregate resolves at all (this is the exact expression that
--   --    used to fail; it should return NULL, not an error):
--   select (array_agg(id))[1] from public.stocktake_items where false;
--
--   -- 2. end to end, as a real staff member, rolled back:
--   begin;
--     set local role authenticated;
--     set local request.jwt.claims = '{"sub":"<STAFF_UUID>","role":"authenticated"}';
--     select public.delete_stocktake_items(array['<AN_ITEM_UUID_OF_THEIRS>']::uuid[]);
--     -- expect: 1   (and NOT: function min(uuid) does not exist)
--     select action, target_label, before->>'items_deleted'
--       from public.audit_log order by created_at desc limit 1;
--     -- expect: stocktake_items.deleted, with the snapshotted barcode + qty
--   rollback;
--
--   -- 3. the one-stocktake guard still holds — ids from two takes must fail:
--   begin;
--     set local role authenticated;
--     set local request.jwt.claims = '{"sub":"<STAFF_UUID>","role":"authenticated"}';
--     select public.delete_stocktake_items(array['<ITEM_IN_TAKE_A>','<ITEM_IN_TAKE_B>']::uuid[]);
--     -- expect: ERROR: Those items could not all be found in one of your stocktakes.
--   rollback;
-- ---------------------------------------------------------------------------
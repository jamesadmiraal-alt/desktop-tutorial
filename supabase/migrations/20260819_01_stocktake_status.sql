-- Three-state stocktake workflow: in_progress -> ready_for_export -> completed.
--
-- The problem: head office can't tell a count that's still being done from one
-- that's finished and waiting to be exported — both show as In Progress. The
-- existing transition is automatic and inverted (exporting is what marks a
-- stocktake complete), so "finished" has never been expressible.
--
-- Additive and safe against a live project: existing rows hold only
-- 'in_progress' or 'completed', both of which satisfy the new constraint, so no
-- backfill. Mirrored into schema.sql.
--
-- Run this BEFORE deploying the new app.html — it calls set_stocktake_status().
-- The companion revoke (migration 02) runs AFTER.

-- ---------------------------------------------------------------------------
-- 1. Constrain the column. It has been free text until now on the reasoning
-- that the app was its only writer; once a workflow depends on the value that
-- stops being an acceptable trade.
--
-- Uses a named constraint + drop-if-exists so re-running this file is safe.
alter table public.stocktakes drop constraint if exists stocktakes_status_check;
alter table public.stocktakes add constraint stocktakes_status_check
  check (status in ('in_progress', 'ready_for_export', 'completed'));

-- ---------------------------------------------------------------------------
-- 2. The single write path for status.
--
-- p_reason only distinguishes a deliberate move from the automatic one the
-- export makes, so the activity log can say "marked ready" versus "exported".
-- It deliberately does NOT affect permissions — otherwise a client could choose
-- its own privileges by lying about the reason.
--
-- Leaving 'completed' is owner/manager only: head office has already exported by
-- then, so reopening invites a second export with different numbers. Same
-- reasoning that already restricts deleting a stocktake.
create or replace function public.set_stocktake_status(
  p_stocktake_id uuid,
  p_status text,
  p_reason text default 'manual'
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_take_org uuid;
  v_take_name text;
  v_old_status text;
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  if p_status not in ('in_progress', 'ready_for_export', 'completed') then
    raise exception 'Unknown stocktake status.';
  end if;
  if coalesce(p_reason, '') not in ('manual', 'export') then
    raise exception 'Unknown reason for the status change.';
  end if;

  select s.org_id, s.name, s.status into v_take_org, v_take_name, v_old_status
    from public.stocktakes s where s.id = p_stocktake_id;

  -- security definer bypasses RLS, so re-implement org scoping. Identical
  -- message either way, so this can't be used to probe for UUIDs.
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  -- No-op, not an error: the export path calls this unconditionally and two
  -- devices can race the same button. Avoids a "completed -> completed" log row.
  if v_old_status = p_status then
    return;
  end if;

  -- coalesce, not `!=` — my_role() is NULL for a caller with no membership and
  -- `NULL not in (...)` is NULL, which plpgsql treats as false.
  if v_old_status = 'completed'
     and coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'This stocktake has already been exported — ask a manager to reopen it.';
  end if;

  update public.stocktakes set status = p_status where id = p_stocktake_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
  values (v_org, org_label, actor, actor_label, 'stocktake.status_changed', 'stocktake',
          p_stocktake_id, v_take_name,
          jsonb_build_object('status', v_old_status),
          jsonb_build_object('status', p_status, 'reason', coalesce(p_reason, 'manual')));
end $$;

grant execute on function public.set_stocktake_status(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify:
--   -- as staff, on an in_progress stocktake: succeeds
--   select public.set_stocktake_status('<id>', 'ready_for_export');
--   -- as staff, on a completed one: raises "ask a manager to reopen it"
--   select public.set_stocktake_status('<completed id>', 'in_progress');
--   -- rejected by the constraint:
--   update public.stocktakes set status = 'nonsense' where id = '<id>';
--   -- and the transitions are in the log:
--   select actor_label, before->>'status', after->>'status', after->>'reason'
--     from public.audit_log where action = 'stocktake.status_changed'
--    order by created_at desc limit 5;

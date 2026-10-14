-- Counts lock the moment a stocktake leaves In Progress, not only once it is
-- completed.
--
-- Stress test, 14 Oct 2026: a take was marked Ready for export, and a line on
-- it still went 46 -> 48 afterwards. "Ready for export" is head office's cue
-- that the numbers are final; a count that can still move underneath that cue
-- means the file can differ from what the venue said was finished.
--
-- enforce_stocktake_not_completed() — the BEFORE INSERT/UPDATE/DELETE trigger on
-- stocktake_items — refused writes only into 'completed'. It now refuses any
-- status other than 'in_progress'. Being a trigger, it covers every writer at
-- once: add_stocktake_item, set_stocktake_item_qty, delete_stocktake_items,
-- clear_stocktake_items, and any future RPC — all security definer, all of
-- which would bypass an RLS policy.
--
-- The message names the way out. The app shows it verbatim when a stale screen
-- (another phone's Mark ready) tries to write, so it is written for a bartender:
-- what happened, and what to do.
--
-- Deleting a STOCKTAKE still works whatever its status: its items are removed
-- by the foreign-key cascade AFTER the parent row is gone, the status lookup
-- finds nothing, and NULL is not treated as locked (the explicit `is not null`
-- below — the same reasoning enforce_stocktake_visible() documents).
--
-- "Back to in progress" (set_stocktake_status, owner/manager from completed)
-- reopens counting with no further change: the trigger reads the live status.
--
-- create or replace only; the trigger itself is unchanged. Safe to run twice,
-- safe mid-count (an In Progress take is unaffected). Mirrored into schema.sql.

create or replace function public.enforce_stocktake_not_completed()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_status text;
begin
  select s.status into v_status
    from public.stocktakes s
   where s.id = coalesce(new.stocktake_id, old.stocktake_id);

  if v_status = 'completed' then
    raise exception 'This stocktake is completed — ask a manager to reopen it before changing counts.'
      using errcode = 'check_violation';
  end if;
  if v_status is not null and v_status <> 'in_progress' then
    raise exception 'This count is marked ready. Move it back to In Progress to keep counting.'
      using errcode = 'check_violation';
  end if;

  return coalesce(new, old);
end $$;

-- ---------------------------------------------------------------------------
-- Verify (a DISPOSABLE stocktake — not Belles, not Colac):
--
--   select public.set_stocktake_status('<take>', 'ready_for_export', 'manual');
--   select public.add_stocktake_item('<take>', 'TEST-LOCK', 1);
--   -- ERROR: This count is marked ready. Move it back to In Progress to keep counting.
--   select public.set_stocktake_status('<take>', 'in_progress', 'manual');
--   select public.add_stocktake_item('<take>', 'TEST-LOCK', 1);   -- works again
-- ---------------------------------------------------------------------------

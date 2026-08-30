-- A completed stocktake stops accepting counts.
--
-- Why: exporting is the end of the workflow — head office has the file and is
-- acting on those numbers. But a phone still sitting in the stocktake could keep
-- scanning into it afterwards, because the item policies never looked at
-- stocktakes.status. During the 30 Aug stress test the scan header drifted
-- 36 / 35 / 33 / 36 after an export: the CSV in head office's hands and the live
-- count were two different things, and nothing on either screen said so.
--
-- A TRIGGER rather than an RLS predicate, for two reasons:
--   1. add_stocktake_item() and set_stocktake_item_qty() are security definer
--      and bypass RLS, so a policy would not stop the app's own write path —
--      the one people actually use.
--   2. An RLS refusal surfaces as "new row violates row-level security policy",
--      which tells a bartender nothing. A trigger can say what happened and what
--      to do, and that message reaches the app's toast unchanged.
--
-- DELETE is included so "completed" means immutable rather than merely
-- append-blocked. Deleting the whole stocktake still works: `on delete cascade`
-- runs as an AFTER trigger on the parent, so by the time the child delete
-- reaches this function the parent row is already gone and the status lookup
-- finds nothing.
--
-- Reopening is unchanged: set_stocktake_status() writes to `stocktakes`, which
-- this trigger does not touch, and stays owner/manager for leaving 'completed'.
--
-- SAFE TO RUN BEFORE THE PUSH, and worth running early — it closes the hole for
-- the currently deployed page too. The only behaviour change is that writes into
-- an already-completed stocktake now fail loudly instead of silently diverging
-- from the exported file. Nothing else can hit it: the live app only writes to
-- takes someone has open, and a completed take should not be accepting writes.
--
-- Additive: one function, one trigger. No table, column, constraint, policy or
-- row is altered. Safe to run twice. Mirrored into schema.sql.

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

  return coalesce(new, old);
end $$;

drop trigger if exists stocktake_items_block_when_completed on public.stocktake_items;
create trigger stocktake_items_block_when_completed
  before insert or update or delete on public.stocktake_items
  for each row execute function public.enforce_stocktake_not_completed();

-- ---------------------------------------------------------------------------
-- Verify (disposable stocktake, NOT Belles or Colac):
--
--   -- with the take in_progress or ready_for_export, this succeeds:
--   select public.add_stocktake_item('<take>', '9348230001611', 1);
--
--   -- mark it completed, then the same call must fail:
--   select public.set_stocktake_status('<take>', 'completed', 'manual');
--   select public.add_stocktake_item('<take>', '9348230001611', 1);
--   -- ERROR: This stocktake is completed — ask a manager to reopen it ...
--
--   update public.stocktake_items set qty = 99
--    where stocktake_id = '<take>';            -- same error
--   delete from public.stocktake_items
--    where stocktake_id = '<take>';            -- same error
--
--   -- reopening restores writes:
--   select public.set_stocktake_status('<take>', 'ready_for_export', 'manual');
--   select public.add_stocktake_item('<take>', '9348230001611', 1);   -- succeeds
--
--   -- and deleting a COMPLETED stocktake outright still cascades cleanly:
--   --   delete from public.stocktakes where id = '<a throwaway completed take>';

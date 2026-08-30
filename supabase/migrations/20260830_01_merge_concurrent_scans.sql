-- Merge concurrent scans of the same barcode instead of colliding.
--
-- Why: two staff counting one stocktake, both scanning 9309000134045. app.html
-- decided INSERT-vs-UPDATE from its own in-memory `items` array; the other
-- device's row is not in that array, so both took the INSERT branch and the
-- second got
--
--   duplicate key value violates unique constraint
--   "stocktake_items_stocktake_id_barcode_key"
--
-- Save greyed out and stayed that way, and the second scanner had no way to see
-- the barcode was already counted — so the natural next move was to retype the
-- number, overwriting a colleague's count.
--
-- The merge has to happen in Postgres, where both writers serialise on the same
-- row. `unique (stocktake_id, barcode)` is untouched and stays untouched: it is
-- what makes the merge correct, not an obstacle to it.
--
-- Additive: two new functions plus their grants. No table, column, constraint,
-- policy or row is altered, and nothing here writes to existing data. Safe to
-- run twice (create or replace). Mirrored into schema.sql.
--
-- Run BEFORE deploying the new app.html — the page calls both functions, and
-- until they exist every save fails with PGRST202. Running it early is harmless:
-- the currently deployed page never calls them.

-- ---------------------------------------------------------------------------
-- Scan / ADD path
--
-- A loop rather than `insert ... on conflict do update` on purpose:
-- stocktake_items carries log_item_qty_reduced_audit, an
-- `after update ... for each statement` trigger using `referencing old table /
-- new table`. Whether ON CONFLICT DO UPDATE composes safely with transition
-- tables could not be verified against this project's database before shipping,
-- and a wrong guess there fails at call time — mid-count — rather than at
-- deploy. This is the documented concurrency-safe upsert, behaves identically,
-- and keeps the unique_violation retry inside the transaction where a dropped
-- connection cannot lose it.
--
-- No audit row is written here, matching log_item_qty_reduced()'s existing
-- rule that increases are ordinary scanning and logging them would bury the
-- deletions and status changes the log exists to evidence.
-- ---------------------------------------------------------------------------
create or replace function public.add_stocktake_item(
  p_stocktake_id uuid,
  p_barcode text,
  p_qty numeric
)
returns public.stocktake_items
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_take_org uuid;
  v_code text := btrim(coalesce(p_barcode, ''));
  v_qty numeric;
  v_row public.stocktake_items;
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  if v_code = '' then
    raise exception 'A barcode is required.';
  end if;
  if p_qty is null then
    raise exception 'A quantity is required.';
  end if;
  -- numeric accepts 'NaN', and `'NaN' >= 0` is true, so neither the check below
  -- nor the column's own `check (qty >= 0)` would stop it — the line's total
  -- would just become NaN permanently.
  if p_qty = 'NaN'::numeric then
    raise exception 'Quantity must be a number.';
  end if;
  v_qty := round(p_qty, 2);   -- matches numeric(12,2) and QTY_DP in app.html
  if v_qty < 0 then
    raise exception 'Quantity must be 0 or more.';
  end if;

  -- security definer bypasses RLS, so re-implement the scoping the insert policy
  -- would have applied. Same message whether the stocktake is missing or belongs
  -- to another org, so this cannot be used to probe for UUIDs.
  select s.org_id into v_take_org from public.stocktakes s where s.id = p_stocktake_id;
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  loop
    -- Postgres evaluates `qty + v_qty` against the committed row under a row
    -- lock, so two devices adding at once serialise and both counts land.
    -- Computing the total client-side is what made this last-writer-wins.
    update public.stocktake_items
       set qty = qty + v_qty,
           last_scanned = now(),
           last_scanned_by = auth.uid()
     where stocktake_id = p_stocktake_id
       and barcode = v_code
    returning * into v_row;
    if found then
      return v_row;
    end if;

    begin
      insert into public.stocktake_items (stocktake_id, org_id, barcode, qty)
      values (p_stocktake_id, v_org, v_code, v_qty)
      returning * into v_row;
      return v_row;
    exception when unique_violation then
      -- Another device inserted this barcode between our UPDATE finding nothing
      -- and our INSERT. Round again; the UPDATE now finds their row and adds to
      -- it. This is precisely the race the old client-side branch lost.
      null;
    end;
  end loop;
end $$;

grant execute on function public.add_stocktake_item(uuid, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Absolute set, for the keypad's Edit mode and the −/+ steppers.
--
-- Keyed on (stocktake_id, barcode), not the row id the client is holding: that
-- id can be stale if the line was removed and rescanned elsewhere, and an UPDATE
-- by a stale id affects nothing while reporting success.
--
-- This one can lower a quantity, so log_item_qty_reduced_audit fires and the
-- reduction is recorded — intended, since an edit walking a 247-unit line down
-- to 1 is exactly what that trigger exists to catch.
-- ---------------------------------------------------------------------------
create or replace function public.set_stocktake_item_qty(
  p_stocktake_id uuid,
  p_barcode text,
  p_qty numeric
)
returns public.stocktake_items
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_take_org uuid;
  v_code text := btrim(coalesce(p_barcode, ''));
  v_qty numeric;
  v_row public.stocktake_items;
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  if v_code = '' then
    raise exception 'A barcode is required.';
  end if;
  if p_qty is null then
    raise exception 'A quantity is required.';
  end if;
  if p_qty = 'NaN'::numeric then
    raise exception 'Quantity must be a number.';
  end if;
  v_qty := round(p_qty, 2);
  if v_qty < 0 then
    raise exception 'Quantity must be 0 or more.';
  end if;

  select s.org_id into v_take_org from public.stocktakes s where s.id = p_stocktake_id;
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  update public.stocktake_items
     set qty = v_qty,
         last_scanned = now(),
         last_scanned_by = auth.uid()
   where stocktake_id = p_stocktake_id
     and barcode = v_code
  returning * into v_row;
  if found then
    return v_row;
  end if;

  -- Line isn't there — removed on another device while this one still showed it.
  -- Recreate it at the requested quantity rather than failing: the operator
  -- asked for this barcode to read this number.
  begin
    insert into public.stocktake_items (stocktake_id, org_id, barcode, qty)
    values (p_stocktake_id, v_org, v_code, v_qty)
    returning * into v_row;
    return v_row;
  exception when unique_violation then
    update public.stocktake_items
       set qty = v_qty,
           last_scanned = now(),
           last_scanned_by = auth.uid()
     where stocktake_id = p_stocktake_id
       and barcode = v_code
    returning * into v_row;
    return v_row;
  end;
end $$;

grant execute on function public.set_stocktake_item_qty(uuid, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- NOT DONE HERE: revoking client INSERT/UPDATE on stocktake_items.
--
-- Revoking would make the merge impossible to bypass, the way DELETE was locked
-- to delete_stocktake_items(). It is deliberately left for its own change,
-- because revoking now would break the CURRENTLY DEPLOYED page the moment this
-- runs — this migration is meant to be safe to apply before the new app.html
-- ships, and to leave a working rollback if it has to be reverted.
--
-- ---------------------------------------------------------------------------
-- Verify (use a disposable stocktake, NOT Belles or Colac):
--
--   select public.add_stocktake_item('<take>', '9309000134045', 2);
--   select public.add_stocktake_item('<take>', '9309000134045', 3);
--   -- one row, qty 5:
--   select barcode, qty from public.stocktake_items
--    where stocktake_id = '<take>' and barcode = '9309000134045';
--
--   select public.set_stocktake_item_qty('<take>', '9309000134045', 1);
--   -- qty 1, and the reduction appears in the log:
--   select action, before->>'units_removed' from public.audit_log
--    where action = 'stocktake_items.qty_reduced' order by created_at desc limit 1;
--
--   -- scoping: another org's stocktake must not be reachable
--   select public.add_stocktake_item('<some other org take>', 'x', 1);
--   -- ERROR: Stocktake not found.

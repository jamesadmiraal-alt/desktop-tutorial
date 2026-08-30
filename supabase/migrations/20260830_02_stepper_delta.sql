-- Let add_stocktake_item() take a NEGATIVE delta, and clamp the result at 0.
--
-- Why: the −/+ steppers in the item list still computed `current ± 1` in the
-- browser and wrote it as an absolute quantity. That is last-writer-wins — two
-- devices both showing 10 both tap +, both compute 11, and the line ends at 11
-- instead of 12. One tap is silently lost and neither operator sees anything
-- wrong. During the 30 Aug stress test this showed up as the scan-view header
-- jumping 6/32 then 6/29, and a line reading 19 on screen exporting as 18.
--
-- The scan/ADD path was already fixed (20260830_01) by sending the typed amount
-- as a delta and letting Postgres do `qty = qty + delta` under a row lock. The
-- steppers now do the same, sending -1 or +1 — which this function has to
-- accept, since it previously raised on anything below zero.
--
-- The RESULT is floored at 0 rather than rejected. The column's
-- `check (qty >= 0)` would otherwise turn a decrement race — two devices each
-- stepping the last unit down — into a raw constraint error mid-count, and
-- "can't go below zero" is a clamp, not something worth interrupting a count
-- for.
--
-- Same signature as before, so this is a plain `create or replace`: no drop, no
-- grant change, nothing else to update. Additive and safe to run twice.
--
-- SAFE TO RUN BEFORE THE PUSH. The deployed page only ever sends a non-negative
-- p_qty, and for those this behaves exactly as it does today: greatest(x, 0)
-- with x >= 0 is x. Nothing changes until the new app.html starts sending -1.
-- Mirrored into schema.sql.

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
  -- numeric accepts 'NaN', and `'NaN' >= 0` is true, so neither a range check
  -- nor the column's own `check (qty >= 0)` would stop it — the line's total
  -- would just become NaN permanently.
  if p_qty = 'NaN'::numeric then
    raise exception 'Quantity must be a number.';
  end if;
  -- No lower bound on the DELTA — negatives are how the − stepper works. The
  -- RESULT is clamped at 0 below.
  v_qty := round(p_qty, 2);   -- matches numeric(12,2) and QTY_DP in app.html

  -- security definer bypasses RLS, so re-implement the scoping the insert policy
  -- would have applied. Same message whether the stocktake is missing or belongs
  -- to another org, so this cannot be used to probe for UUIDs.
  select s.org_id into v_take_org from public.stocktakes s where s.id = p_stocktake_id;
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  loop
    -- Postgres evaluates `qty + v_qty` against the committed row under a row
    -- lock, so two devices stepping at once serialise and both taps land.
    update public.stocktake_items
       set qty = greatest(qty + v_qty, 0),
           last_scanned = now(),
           last_scanned_by = auth.uid()
     where stocktake_id = p_stocktake_id
       and barcode = v_code
    returning * into v_row;
    if found then
      return v_row;
    end if;

    begin
      -- A negative delta against a line that doesn't exist yet lands at 0, not a
      -- constraint error. Reachable when the last unit is stepped off on one
      -- device while another removes the line entirely.
      insert into public.stocktake_items (stocktake_id, org_id, barcode, qty)
      values (p_stocktake_id, v_org, v_code, greatest(v_qty, 0))
      returning * into v_row;
      return v_row;
    exception when unique_violation then
      -- Another device inserted this barcode between our UPDATE finding nothing
      -- and our INSERT. Round again; the UPDATE now finds their row.
      null;
    end;
  end loop;
end $$;

grant execute on function public.add_stocktake_item(uuid, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify (disposable stocktake, NOT Belles or Colac):
--
--   select public.add_stocktake_item('<take>', '9309000134045', 10);   -- 10
--   select public.add_stocktake_item('<take>', '9309000134045', 1);    -- 11
--   select public.add_stocktake_item('<take>', '9309000134045', -1);   -- 10
--   select public.add_stocktake_item('<take>', '9309000134045', -999); -- 0, not an error
--
--   select barcode, qty from public.stocktake_items
--    where stocktake_id = '<take>' and barcode = '9309000134045';
--
-- The concurrency itself is easiest to see with two psql sessions:
--   both: begin;  select public.add_stocktake_item('<take>','X',1);
--   then: commit; commit;   -- X ends at 2, never 1

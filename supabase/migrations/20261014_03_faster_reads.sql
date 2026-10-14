-- Faster reads: Home and the open take stop paying per-row for every line.
--
-- Stress test, 14 Oct 2026: Home showed "Loading…" for 20–60s, reopening a take
-- once hung for over two minutes. Part of that evening overlapped network drops
-- on the test computer, but a baseline round trip to this project measures
-- ~0.35s (2026-10-14, anon key, from Adelaide), so the database itself is not
-- slow at rest. Two things in the read path are:
--
-- 1. RLS helpers evaluated per ROW. my_org_id(), my_role() and
--    staff_sees_own_only() are `stable security definer` SQL functions —
--    security definer is never inlined, so in a plain WHERE clause Postgres may
--    call them once per row. "read org items" called my_org_id() per item AND
--    ran a correlated exists into stocktakes whose own policy called all three
--    again: around five membership lookups per item row. Supabase's documented
--    fix is to wrap each call in a scalar sub-select — `(select
--    public.my_org_id())` — which the planner evaluates ONCE per statement as
--    an InitPlan. The value is the same either way (it can't change within a
--    statement), so the policies below are logically identical to the ones
--    they replace; only how often the lookups run changes.
--
-- 2. Home over-fetched. Its query embedded stocktake_items(qty) — every line of
--    every stocktake the org has ever done, Completed history included — only
--    to show "N items · M total qty" on each card. At ~600 lines a count that
--    is tens of thousands of rows, each paying the per-row cost above.
--    stocktake_totals() returns one row per stocktake instead. It runs as the
--    CALLER (security invoker), so the same RLS decides which lines are
--    counted: staff under staff_see_own_stocktakes_only still only see totals
--    for their own takes.
--
-- Plus the index the review asked to check: stocktakes (org_id, status) was
-- missing. (stocktake_items (stocktake_id) and (stocktake_id, barcode) exist —
-- items_stocktake_idx and the unique constraint.)
--
-- Policies are dropped and re-created in place; for that instant RLS's default
-- is DENY, so a read during the swap returns nothing rather than too much.
-- Safe to run twice. Mirrored into schema.sql. Order-independent of the other
-- 20261014 migrations. app.html falls back to the old Home query if
-- stocktake_totals() doesn't exist yet.

create index if not exists stocktakes_org_status_idx on public.stocktakes (org_id, status);

-- ---------------------------------------------------------------------------
-- 1. The two read policies, with their helper calls evaluated once.
--    Same logic as "read org stocktakes" / "read org items" in schema.sql
--    (20260909_01 for the staff-visibility half).
-- ---------------------------------------------------------------------------
drop policy if exists "read org stocktakes" on public.stocktakes;
create policy "read org stocktakes" on public.stocktakes
  for select using (
    org_id = (select public.my_org_id())
    and (
      (select coalesce(public.my_role(), '')) in ('owner', 'manager')
      or not (select public.staff_sees_own_only())
      or created_by = (select auth.uid())
    )
  );

drop policy if exists "read org items" on public.stocktake_items;
create policy "read org items" on public.stocktake_items
  for select using (
    org_id = (select public.my_org_id())
    and exists (
      select 1 from public.stocktakes s where s.id = stocktake_items.stocktake_id
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Home's totals, one row per stocktake.
-- ---------------------------------------------------------------------------
create or replace function public.stocktake_totals()
returns table (stocktake_id uuid, line_count bigint, total_qty numeric)
language sql stable security invoker set search_path = public as $$
  select i.stocktake_id, count(*), coalesce(sum(i.qty), 0)
    from public.stocktake_items i
   group by i.stocktake_id
$$;

grant execute on function public.stocktake_totals() to authenticated;

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- 1. same answers as before, as a real user (Home's numbers unchanged):
--   select stocktake_id, line_count, total_qty from public.stocktake_totals();
--
--   -- 2. the policies use InitPlans now — look for "InitPlan" and the absence
--   --    of per-row my_org_id() in:
--   explain analyze select qty from public.stocktake_items;   -- as an org user
--
--   -- 3. staff under staff_see_own_stocktakes_only still see only their own
--   --    takes' totals (run as a staff login with the flag on).
-- ---------------------------------------------------------------------------

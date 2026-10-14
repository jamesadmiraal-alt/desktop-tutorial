-- Idempotent item writes: a retried save can never count twice.
--
-- Stress test, 14 Oct 2026. A save's reply was lost (a network drop, a slow
-- gateway), the app said "That save did not come back. Nothing was recorded" or
-- "<barcode> was NOT saved. TypeError: Failed to fetch" — and the write had in
-- fact landed. The operator did the obvious thing and saved again, and
-- 9300675010119 went 2 -> 4. The app's claim was a guess: a lost reply says
-- nothing about whether the request arrived.
--
-- The fix makes the guess unnecessary. Each user action now carries a client
-- request id (crypto.randomUUID()), reused on any retry of that same action:
--
--   * add_stocktake_item() / set_stocktake_item_qty() record the id in
--     stocktake_item_requests IN THE SAME TRANSACTION as the write. Seeing an id
--     again means "this exact action already happened" — the line is returned
--     as it stands and nothing is applied a second time. If the write fails (a
--     trial cap, a closed count), the transaction rolls back and the id goes
--     with it, so a genuine retry still applies.
--   * stocktake_item_request_applied() lets the app ASK whether a request it
--     lost the reply to landed — so "saved" and "couldn't confirm" are both
--     statements of fact rather than assumptions.
--
-- p_request_id defaults to NULL, so a client that doesn't send one behaves
-- exactly as before. The old three-argument functions are DROPPED rather than
-- left beside the new ones: two versions make a three-argument call ambiguous
-- to PostgREST (PGRST203) — and that is exactly the call the currently deployed
-- app.html makes on every save. With them gone, that call lands on the new
-- function with p_request_id NULL. (Same reasoning, and same move, as
-- record_stocktake_export() in 20261011_01.)
--
-- Additive otherwise: one new table, one new function, two functions
-- re-created with identical behaviour plus the request check. No existing row
-- is touched. Safe to run twice. Safe mid-count: there is a moment between the
-- drop and the create where a save would 404 — run it when nobody is counting,
-- as with 20260820_01. Mirrored into schema.sql.
--
-- Independent of 20261011_01 (still unapplied as of 2026-10-14); either order.

-- ---------------------------------------------------------------------------
-- 1. The record of which actions have already been applied.
--
-- No client access at all — not even SELECT. Only the two save functions
-- (security definer) write it, and stocktake_item_request_applied() reads it
-- scoped to the caller's org. RLS on with no policies, plus the revoke, so a
-- default-privileges grant can't open it.
--
-- Rows are cheap and only matter for minutes (a retry), so the save functions
-- prune anything older than 7 days on roughly 1 call in 100, and deleting a
-- stocktake takes its rows with it.
-- ---------------------------------------------------------------------------
create table if not exists public.stocktake_item_requests (
  request_id uuid primary key,
  stocktake_id uuid not null references public.stocktakes(id) on delete cascade,
  barcode text not null,
  created_at timestamptz not null default now()
);
create index if not exists stocktake_item_requests_created_idx
  on public.stocktake_item_requests (created_at);

alter table public.stocktake_item_requests enable row level security;
revoke all on public.stocktake_item_requests from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The two save functions, now idempotent on p_request_id.
--
-- Everything below the request check is byte-identical to the previous
-- versions (schema.sql / 20260830_02): same validation, same org scoping, same
-- update-then-insert loop under a row lock, same clamp at 0. Read their
-- comments there for why each part is the way it is.
-- ---------------------------------------------------------------------------
drop function if exists public.add_stocktake_item(uuid, text, numeric);
drop function if exists public.set_stocktake_item_qty(uuid, text, numeric);

create or replace function public.add_stocktake_item(
  p_stocktake_id uuid,
  p_barcode text,
  p_qty numeric,
  p_request_id uuid default null
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
  v_qty := round(p_qty, 2);   -- matches numeric(12,2) and QTY_DP in app.html

  select s.org_id into v_take_org from public.stocktakes s where s.id = p_stocktake_id;
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  -- The retry guard. First caller with this id records it and carries on; any
  -- later caller (the same action, retried because its reply was lost) finds it
  -- taken and gets the line as it stands — nothing added twice. Two copies
  -- arriving at once serialise on the primary key: the second waits for the
  -- first to commit, then sees the conflict.
  if p_request_id is not null then
    insert into public.stocktake_item_requests (request_id, stocktake_id, barcode)
    values (p_request_id, p_stocktake_id, v_code)
    on conflict (request_id) do nothing;
    if not found then
      select * into v_row from public.stocktake_items
       where stocktake_id = p_stocktake_id and barcode = v_code;
      return v_row;
    end if;
    if random() < 0.01 then
      delete from public.stocktake_item_requests where created_at < now() - interval '7 days';
    end if;
  end if;

  loop
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
      insert into public.stocktake_items (stocktake_id, org_id, barcode, qty)
      values (p_stocktake_id, v_org, v_code, greatest(v_qty, 0))
      returning * into v_row;
      return v_row;
    exception when unique_violation then
      null;
    end;
  end loop;
end $$;

grant execute on function public.add_stocktake_item(uuid, text, numeric, uuid) to authenticated;

create or replace function public.set_stocktake_item_qty(
  p_stocktake_id uuid,
  p_barcode text,
  p_qty numeric,
  p_request_id uuid default null
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

  -- Same guard as add_stocktake_item(). An absolute set looks naturally
  -- idempotent, but it isn't once there are two devices: a retried "set to 6"
  -- arriving after a colleague's +1 would quietly undo their tap.
  if p_request_id is not null then
    insert into public.stocktake_item_requests (request_id, stocktake_id, barcode)
    values (p_request_id, p_stocktake_id, v_code)
    on conflict (request_id) do nothing;
    if not found then
      select * into v_row from public.stocktake_items
       where stocktake_id = p_stocktake_id and barcode = v_code;
      return v_row;
    end if;
    if random() < 0.01 then
      delete from public.stocktake_item_requests where created_at < now() - interval '7 days';
    end if;
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

grant execute on function public.set_stocktake_item_qty(uuid, text, numeric, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. "Did that save land?"
--
-- The question the app asks after a lost reply, before it says anything. Only
-- answers for the caller's own org: an id from another org reads as "no", the
-- same as one that never arrived, so this can't be used to probe.
--
-- A "no" is not proof the write will never land — the original request can
-- still be in flight. The app therefore says "couldn't confirm", never
-- "nothing was recorded", and re-checks the pending id before any retry.
-- ---------------------------------------------------------------------------
create or replace function public.stocktake_item_request_applied(p_request_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.stocktake_item_requests r
      join public.stocktakes s on s.id = r.stocktake_id
     where r.request_id = p_request_id
       and s.org_id = public.my_org_id()
  )
$$;

grant execute on function public.stocktake_item_request_applied(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify (a DISPOSABLE stocktake — not Belles, not Colac):
--
--   -- 1. one version of each, four arguments:
--   select proname, pg_get_function_identity_arguments(oid) from pg_proc
--    where proname in ('add_stocktake_item', 'set_stocktake_item_qty');
--
--   -- 2. the same request id applies once; different ids apply twice:
--   select qty from public.add_stocktake_item('<take>', 'TEST-IDEM', 2, '11111111-1111-1111-1111-111111111111');  -- 2
--   select qty from public.add_stocktake_item('<take>', 'TEST-IDEM', 2, '11111111-1111-1111-1111-111111111111');  -- 2 (not 4)
--   select qty from public.add_stocktake_item('<take>', 'TEST-IDEM', 2, '22222222-2222-2222-2222-222222222222');  -- 4
--   select public.stocktake_item_request_applied('11111111-1111-1111-1111-111111111111');  -- true
--   select public.stocktake_item_request_applied('33333333-3333-3333-3333-333333333333');  -- false
--
--   -- 3. no id: exactly the old behaviour (adds every time):
--   select qty from public.add_stocktake_item('<take>', 'TEST-IDEM', 1);  -- 5
--   select qty from public.add_stocktake_item('<take>', 'TEST-IDEM', 1);  -- 6
--
--   -- 4. clients can't read or write the table directly:
--   --   GET /rest/v1/stocktake_item_requests  -> 401/403 or empty
-- ---------------------------------------------------------------------------

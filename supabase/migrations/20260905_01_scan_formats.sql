-- Which code types the camera is allowed to read, per organisation.
--
-- Why this exists: a tester scanned a wine bottle and the camera kept locking
-- onto the marketing QR on the back label instead of the retail barcode. Both
-- are in frame, both decode, and the QR usually wins because it is bigger and
-- higher contrast. The operator has no way to tell the camera "not that one".
--
-- Defaults are deliberately NOT both on:
--   scan_barcodes  true   — retail barcodes are what a stocktake counts
--   scan_qr        false  — a bottle QR is almost never the thing being counted
--
-- Existing organisations get exactly those defaults, because the columns are
-- NOT NULL DEFAULT. A missing preference must never be read as "both on" —
-- that is the state that caused the problem.
--
-- Org-wide rather than per-device on purpose: a venue's bottles are the same
-- bottles whoever is holding the phone, and a setting that has to be found and
-- flipped on each device is a setting that will be wrong on one of them.
--
-- Additive: two new defaulted columns and one new function. No table, policy or
-- grant changes, and no existing row is rewritten. Safe to run twice. Mirrored
-- into schema.sql.
--
-- Run BEFORE pushing the new app.html, which reads both columns and offers the
-- toggles in Account.

alter table public.organisations
  add column if not exists scan_barcodes boolean not null default true;
alter table public.organisations
  add column if not exists scan_qr boolean not null default false;

-- ---------------------------------------------------------------------------
-- set_scan_prefs(p_barcodes boolean, p_qr boolean)
--
-- An RPC rather than two more columns on the client-writable GRANT, and the
-- reason is a permission boundary rather than tidiness.
--
-- The "owner update org" policy is OWNER-ONLY, but a venue manager is exactly
-- the person who should be able to say "stop reading the QR on these bottles".
-- Widening that policy to managers would also hand them `country` — which sets
-- the billing currency — plus `join_code` and `export_format`. So instead this
-- function grants one narrow capability to owner AND manager, and the columns
-- stay off the GRANT entirely, meaning nothing else can write them.
--
-- Returns the stored pair, so the client renders what the server holds rather
-- than what was tapped.
-- ---------------------------------------------------------------------------
create or replace function public.set_scan_prefs(p_barcodes boolean, p_qr boolean)
returns table (scan_barcodes boolean, scan_qr boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_role text := public.my_role();
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  -- `not in` rather than `<>`: my_role() is NULL for a caller with no
  -- membership, and NULL comparisons evaluate to NULL, which plpgsql treats as
  -- false — the null-comparison bypass this file has been bitten by before.
  if v_role is null or v_role not in ('owner', 'manager') then
    raise exception 'Only an owner or manager can change scanning settings.';
  end if;

  -- Both off would leave a camera that cannot read anything, and the app would
  -- have to explain a state the operator did not intend. Refuse it here so the
  -- database never holds it, whatever the client does.
  if coalesce(p_barcodes, false) = false and coalesce(p_qr, false) = false then
    raise exception 'Leave at least one of barcode or QR scanning on.';
  end if;

  update public.organisations
     set scan_barcodes = coalesce(p_barcodes, true),
         scan_qr = coalesce(p_qr, false)
   where id = v_org;

  return query
    select o.scan_barcodes, o.scan_qr from public.organisations o where o.id = v_org;
end $$;

grant execute on function public.set_scan_prefs(boolean, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- 1. existing orgs got the safe defaults, not "both on":
--   select name, scan_barcodes, scan_qr from public.organisations order by name;
--   -- expect every row: true | false
--
--   -- 2. as an owner or manager:
--   select * from public.set_scan_prefs(true, true);    -- => true | true
--   select * from public.set_scan_prefs(true, false);   -- => true | false
--
--   -- 3. both off is refused:
--   select * from public.set_scan_prefs(false, false);
--   -- ERROR: Leave at least one of barcode or QR scanning on.
--
--   -- 4. staff are refused:
--   --   ERROR: Only an owner or manager can change scanning settings.
--
--   -- 5. and the columns are still not writable directly — this must fail:
--   --   PATCH /rest/v1/organisations?id=eq.<org>  {"scan_qr": true}
--   -- expect: 42501 permission denied for column scan_qr
-- ---------------------------------------------------------------------------

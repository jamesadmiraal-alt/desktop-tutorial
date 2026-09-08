-- Tap-to-capture scanning + the org barcode directory.
--
-- ALREADY APPLIED to the live project on 2026-09-08, before app.html was
-- pushed. This file is written after the fact so the migrations log is a
-- truthful record of how the live database got its current shape — the SQL was
-- run from an extract of schema.sql rather than from a file here, which is the
-- convention this directory exists to prevent. Re-running it is harmless
-- (every statement is guarded) but unnecessary.
--
-- Two things, both from live venue use:
--
--   1. Walking the phone along a shelf, the camera decodes whatever passes
--      through the frame, so a neighbouring product lands in the count with
--      nobody choosing it. scan_mode = 'tap' keeps the preview live but only
--      accepts the decode at the moment the operator taps Capture.
--   2. When the venue's own stock system rejects a line as "barcode not
--      found", Gantry only had the raw digits. org_barcodes is the human name.
--
-- Defaults keep every existing organisation exactly as it was: scan_mode
-- 'continuous', and an empty directory. Mirrored into schema.sql.

-- ---- A. Scan mode -------------------------------------------------------
alter table public.organisations
  add column if not exists scan_mode text not null default 'continuous';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'organisations_scan_mode_check'
       and conrelid = 'public.organisations'::regclass
  ) then
    alter table public.organisations
      add constraint organisations_scan_mode_check
      check (scan_mode in ('continuous', 'tap'));
  end if;
end $$;

-- A new function rather than more parameters on set_scan_prefs(): `create or
-- replace` with a different signature creates an OVERLOAD rather than
-- replacing, and GitHub Pages serves a cached app.html for a while after a
-- deploy, so an old client calling the 2-arg form must keep working.
create or replace function public.set_scan_mode(p_mode text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_role text := public.my_role();
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  if v_role is null or v_role not in ('owner', 'manager') then
    raise exception 'Only an owner or manager can change scanning settings.';
  end if;
  if p_mode is null or p_mode not in ('continuous', 'tap') then
    raise exception 'Unknown scanning mode.';
  end if;

  update public.organisations set scan_mode = p_mode where id = v_org;
  return p_mode;
end $$;

grant execute on function public.set_scan_mode(text) to authenticated;

-- ---- B. Org barcode directory -------------------------------------------
-- Deliberately not a product catalogue: no price, no pack size, no supplier.
-- The name never reaches the CSV — export shape is set by export_format and is
-- read by someone else's importer.
create table if not exists public.org_barcodes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  barcode text not null check (btrim(barcode) <> ''),
  name text not null check (btrim(name) <> ''),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, barcode)
);

alter table public.org_barcodes enable row level security;

-- Read is the whole org, staff included: they hold the phone, and a name they
-- can't see while counting does nothing for the problem this solves.
drop policy if exists "read org barcodes" on public.org_barcodes;
create policy "read org barcodes" on public.org_barcodes
  for select using (org_id = public.my_org_id());

drop policy if exists "owner manager insert org barcodes" on public.org_barcodes;
create policy "owner manager insert org barcodes" on public.org_barcodes
  for insert with check (
    org_id = public.my_org_id()
    and public.my_role() in ('owner', 'manager')
  );

drop policy if exists "owner manager update org barcodes" on public.org_barcodes;
create policy "owner manager update org barcodes" on public.org_barcodes
  for update using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'))
  with check (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

drop policy if exists "owner manager delete org barcodes" on public.org_barcodes;
create policy "owner manager delete org barcodes" on public.org_barcodes
  for delete using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

alter table public.org_barcodes
  alter column org_id set default public.my_org_id();
alter table public.org_barcodes
  alter column created_by set default auth.uid();

-- Supabase's default privileges re-grant UPDATE on every newly created table,
-- so this narrowing has to live in the file or a rebuild silently reopens it.
revoke update on public.org_barcodes from authenticated, anon;
grant update (barcode, name) on public.org_barcodes to authenticated;

create or replace function public.touch_org_barcode()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists touch_org_barcodes on public.org_barcodes;
create trigger touch_org_barcodes
  before update on public.org_barcodes
  for each row execute function public.touch_org_barcode();

-- ---------------------------------------------------------------------------
-- Verify (all confirmed on 2026-09-08 via the REST API):
--
--   select scan_mode from public.organisations limit 5;   -- all 'continuous'
--   select count(*) from public.org_barcodes;             -- 0
--   select public.set_scan_mode('continuous');            -- 'continuous'
--
--   -- and the column is not directly writable — this must fail:
--   --   PATCH /rest/v1/organisations?id=eq.<org>  {"scan_mode": "tap"}
--   -- expect: 42501 permission denied for column scan_mode
-- ---------------------------------------------------------------------------

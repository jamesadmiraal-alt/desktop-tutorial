-- Receiving invoices (coming soon) — Phase 1: the feature flag and the
-- product master.
--
-- Receiving is being built behind a wall. Nothing here changes stocktakes,
-- exports, or any existing table's behaviour:
--
--   * organisations.receiving_enabled (default false) is the wall. It is NOT in
--     the client-writable column GRANT, so it can only be turned on by hand in
--     the SQL editor — the same footing as plan_tier. app.html's Account card
--     and receiving.html both read it separately and treat a failed read as
--     "off", so pushing the pages before this runs only ever shows "coming soon".
--   * products / product_barcodes are the POS product list (H&L, Bepoz…):
--     product code, description, pack size, and any number of barcodes per
--     product — unit, inner and carton. export-engine.js's ctx.products has
--     been waiting for this since the template work; nothing is wired to the
--     exports here, so every export is byte-for-byte unchanged.
--   * product_imports records every import: who, when, which file, which
--     column mapping, and what changed.
--
-- Barcodes are STORED as imported and MATCHED on barcode_key(): an all-digit
-- code is right-aligned to 14 digits (the GTIN-14 form), so the UPC-A, EAN-13
-- and GTIN-14 renderings of one bottle are one key — the phones' decoders
-- disagree about which they report (see CLAUDE.md, Colac). Anything else is
-- trimmed and upper-cased. product-import.js has the same function and
-- scripts/test-product-import.js checks the two agree.
--
-- Writes go through the three functions below only (owner/manager, flag on);
-- the tables have no client insert/update/delete. Reads are the whole org,
-- staff included: the people receiving a delivery are the ones scanning.
--
-- Additive: one defaulted column, three tables, four functions. Safe to run
-- twice and mid-count. Mirrored into schema.sql.
--
-- To open the wall for one organisation (and close it again):
--   update public.organisations set receiving_enabled = true  where name = '…';
--   update public.organisations set receiving_enabled = false where name = '…';

-- ---------------------------------------------------------------------------
-- 1. The wall.
-- ---------------------------------------------------------------------------
alter table public.organisations
  add column if not exists receiving_enabled boolean not null default false;

-- Is the receiving feature open to the caller's organisation?
create or replace function public.receiving_enabled_for_me()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select o.receiving_enabled from public.organisations o
                    where o.id = public.my_org_id()), false)
$$;
grant execute on function public.receiving_enabled_for_me() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Barcode key — see the header. Must match barcodeKey() in
--    product-import.js exactly.
-- ---------------------------------------------------------------------------
create or replace function public.barcode_key(p text)
returns text language sql immutable as $$
  select case
    when btrim(coalesce(p, '')) ~ '^[0-9]{1,14}$' then lpad(btrim(p), 14, '0')
    else upper(btrim(coalesce(p, '')))
  end
$$;

-- ---------------------------------------------------------------------------
-- 3. Tables.
-- ---------------------------------------------------------------------------
create table if not exists public.product_imports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  pos_system text not null check (public.is_known_pos(pos_system)),
  file_name text,
  -- Which file column fed which field, by HEADER NAME, so the next import of
  -- the same export can be mapped for the operator automatically.
  mapping jsonb not null default '{}'::jsonb,
  status text not null default 'running' check (status in ('running', 'done')),
  rows_total integer not null default 0,
  products_created integer not null default 0,
  products_updated integer not null default 0,
  products_deactivated integer not null default 0,
  barcodes_saved integer not null default 0,
  barcodes_moved integer not null default 0,
  imported_by uuid references auth.users(id) on delete set null,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists product_imports_org_recent on public.product_imports (org_id, started_at desc);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  pos_system text not null check (public.is_known_pos(pos_system)),
  pos_code text not null check (btrim(pos_code) <> ''),
  description text not null default '',
  -- Units in one carton. NULL when the POS export doesn't say; a carton
  -- barcode can't be converted to units without it.
  pack_size integer check (pack_size is null or pack_size >= 1),
  -- A re-import never deletes: deliveries will reference products, and a
  -- product dropped from the POS export is marked inactive instead.
  active boolean not null default true,
  last_import_id uuid references public.product_imports(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, pos_system, pos_code)
);

create table if not exists public.product_barcodes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  barcode text not null check (btrim(barcode) <> ''),   -- as imported
  barcode_key text not null,                            -- barcode_key(barcode)
  kind text not null default 'unit' check (kind in ('unit', 'inner', 'carton')),
  -- How many units one scan of this barcode is: 1 for a unit barcode, the pack
  -- size for a carton.
  units integer not null default 1 check (units >= 1),
  created_at timestamptz not null default now(),
  -- One product per barcode per org: a scan must resolve to one thing.
  unique (org_id, barcode_key)
);
create index if not exists product_barcodes_product on public.product_barcodes (product_id);

-- ---------------------------------------------------------------------------
-- 4. RLS. Read: the whole org. Write: only through the functions below.
--    (select …) wrapping per 20261014_03 — evaluated once per statement.
-- ---------------------------------------------------------------------------
alter table public.products enable row level security;
alter table public.product_barcodes enable row level security;
alter table public.product_imports enable row level security;

drop policy if exists "read org products" on public.products;
create policy "read org products" on public.products
  for select using (org_id = (select public.my_org_id()));

drop policy if exists "read org product barcodes" on public.product_barcodes;
create policy "read org product barcodes" on public.product_barcodes
  for select using (org_id = (select public.my_org_id()));

drop policy if exists "owner manager read product imports" on public.product_imports;
create policy "owner manager read product imports" on public.product_imports
  for select using (org_id = (select public.my_org_id())
                    and (select public.my_role()) in ('owner', 'manager'));

revoke insert, update, delete on public.products, public.product_barcodes, public.product_imports
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Import, in three calls: start -> batches -> finish.
--    The file is parsed and validated in the browser (product-import.js), then
--    sent ~500 products at a time, so a 20,000-line POS export is ~40 short
--    calls rather than one request big enough to time out.
-- ---------------------------------------------------------------------------
create or replace function public.start_product_import(p_pos_system text, p_file_name text, p_mapping jsonb)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_role text := public.my_role();
  v_id uuid;
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  if v_role is null or v_role not in ('owner', 'manager') then
    raise exception 'Only an owner or manager can import products.';
  end if;
  if not public.receiving_enabled_for_me() then
    raise exception 'Receiving invoices is not available for this organisation yet.';
  end if;
  if not public.is_known_pos(p_pos_system) then
    raise exception 'Unknown POS system.';
  end if;
  insert into public.product_imports (org_id, pos_system, file_name, mapping, imported_by)
  values (v_org, p_pos_system, left(p_file_name, 200), coalesce(p_mapping, '{}'::jsonb), auth.uid())
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.start_product_import(text, text, jsonb) to authenticated;

-- p_rows: [{ "pos_code": "…", "description": "…", "pack_size": 24 | null,
--            "barcodes": [{ "barcode": "…", "kind": "unit"|"inner"|"carton", "units": 1 }] }]
-- Each product's barcode set is REPLACED by the file's: a barcode the POS no
-- longer lists for that product is removed; one that has moved to another
-- product follows it (counted as moved).
create or replace function public.import_products_batch(p_import_id uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_role text := public.my_role();
  imp public.product_imports%rowtype;
  r jsonb;
  b jsonb;
  v_code text;
  v_pid uuid;
  v_inserted boolean;
  v_key text;
  v_old_pid uuid;
  v_keys text[];
  n_created int := 0; n_updated int := 0; n_barcodes int := 0; n_moved int := 0;
begin
  if v_org is null or v_role is null or v_role not in ('owner', 'manager') then
    raise exception 'Only an owner or manager can import products.';
  end if;
  select * into imp from public.product_imports where id = p_import_id and org_id = v_org;
  if not found then
    raise exception 'Import not found.';
  end if;
  if imp.status <> 'running' then
    raise exception 'That import has already finished.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 1000 then
    raise exception 'Send products as an array of at most 1000.';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_code := btrim(coalesce(r->>'pos_code', ''));
    continue when v_code = '';

    insert into public.products (org_id, pos_system, pos_code, description, pack_size, active, last_import_id)
    values (v_org, imp.pos_system, v_code, left(coalesce(r->>'description', ''), 300),
            nullif(r->>'pack_size', '')::int, true, p_import_id)
    on conflict (org_id, pos_system, pos_code) do update
      set description = excluded.description,
          pack_size = excluded.pack_size,
          active = true,
          last_import_id = excluded.last_import_id,
          updated_at = now()
    returning id, (xmax = 0) into v_pid, v_inserted;
    if v_inserted then n_created := n_created + 1; else n_updated := n_updated + 1; end if;

    v_keys := '{}';
    for b in select * from jsonb_array_elements(coalesce(r->'barcodes', '[]'::jsonb)) loop
      continue when btrim(coalesce(b->>'barcode', '')) = '';
      v_key := public.barcode_key(b->>'barcode');
      v_keys := v_keys || v_key;
      select product_id into v_old_pid from public.product_barcodes
       where org_id = v_org and barcode_key = v_key;
      if found and v_old_pid is distinct from v_pid then n_moved := n_moved + 1; end if;
      insert into public.product_barcodes (org_id, product_id, barcode, barcode_key, kind, units)
      values (v_org, v_pid, btrim(b->>'barcode'), v_key,
              coalesce(nullif(b->>'kind', ''), 'unit'),
              greatest(coalesce(nullif(b->>'units', '')::int, 1), 1))
      on conflict (org_id, barcode_key) do update
        set product_id = excluded.product_id, barcode = excluded.barcode,
            kind = excluded.kind, units = excluded.units;
      n_barcodes := n_barcodes + 1;
    end loop;
    -- This product's barcodes are exactly the file's now.
    delete from public.product_barcodes
     where product_id = v_pid and not (barcode_key = any (v_keys));
  end loop;

  update public.product_imports
     set rows_total = rows_total + jsonb_array_length(p_rows),
         products_created = products_created + n_created,
         products_updated = products_updated + n_updated,
         barcodes_saved = barcodes_saved + n_barcodes,
         barcodes_moved = barcodes_moved + n_moved
   where id = p_import_id;

  return jsonb_build_object('created', n_created, 'updated', n_updated,
                            'barcodes', n_barcodes, 'moved', n_moved);
end $$;
grant execute on function public.import_products_batch(uuid, jsonb) to authenticated;

-- p_deactivate_missing: the file was the POS's FULL product list, so anything
-- of this POS not in it is no longer stocked. Off for a partial file.
create or replace function public.finish_product_import(p_import_id uuid, p_deactivate_missing boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_role text := public.my_role();
  imp public.product_imports%rowtype;
  n_off int := 0;
  v_actor text;
begin
  if v_org is null or v_role is null or v_role not in ('owner', 'manager') then
    raise exception 'Only an owner or manager can import products.';
  end if;
  select * into imp from public.product_imports where id = p_import_id and org_id = v_org;
  if not found then
    raise exception 'Import not found.';
  end if;
  if imp.status <> 'running' then
    raise exception 'That import has already finished.';
  end if;

  if coalesce(p_deactivate_missing, false) then
    update public.products
       set active = false, updated_at = now()
     where org_id = v_org and pos_system = imp.pos_system and active
       and last_import_id is distinct from p_import_id;
    get diagnostics n_off = row_count;
  end if;

  update public.product_imports
     set status = 'done', finished_at = now(), products_deactivated = n_off
   where id = p_import_id
  returning * into imp;

  select coalesce(p.full_name, u.email, 'Unknown user') into v_actor
    from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();
  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
  values (v_org, (select name from public.organisations where id = v_org), auth.uid(), coalesce(v_actor, 'Unknown user'),
          'products.imported', 'product_import', imp.id, imp.file_name,
          jsonb_build_object('pos_system', imp.pos_system, 'rows', imp.rows_total,
                             'created', imp.products_created, 'updated', imp.products_updated,
                             'deactivated', imp.products_deactivated, 'barcodes', imp.barcodes_saved,
                             'moved', imp.barcodes_moved));

  return to_jsonb(imp);
end $$;
grant execute on function public.finish_product_import(uuid, boolean) to authenticated;

-- Verify:
--   select column_name from information_schema.columns
--    where table_name = 'organisations' and column_name = 'receiving_enabled';      -- 1 row
--   select public.barcode_key('012345678905'), public.barcode_key('0012345678905');  -- equal
--   select has_table_privilege('authenticated', 'public.products', 'insert');        -- false
--   select name, receiving_enabled from public.organisations order by name;          -- all false

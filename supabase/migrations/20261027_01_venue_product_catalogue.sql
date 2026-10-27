-- Venue product catalogue: a venue's POS product list, so a scan shows what
-- the product is ("Altr Chill · 4pk") instead of a bare barcode.
--
-- Gantry's ONE product list. It supersedes the receiving migrations
-- 20261024_01 / 20261025_01, which were never applied to production; receiving
-- will build on this later.
--
-- Nothing here changes stocktakes, exports or any existing behaviour:
--
--   * organisations.products_enabled (default false) is the switch. It is NOT
--     in the client-writable column GRANT; the owner turns it on and off with
--     set_products_enabled(), which writes the audit log. Off: the app makes
--     one small read at sign-in (my_products_access) and nothing else changes.
--   * The plan gate is server-side: plan_has_products() (Team, and trials,
--     treated as Team until they end). Solo can't turn it on, can't import,
--     and can't read the list. A downgrade keeps the rows but hides them, and
--     an upgrade brings them back. Corporate joins plan_has_products() with
--     the pricing-v2 tiers.
--   * venue_products / venue_product_barcodes are per VENUE: one product, any
--     number of barcodes, each with the POS's size name ("Bottle", "4pk",
--     "Carton") and how many units one scan of it is, where that is known.
--     A 4pk scan is still counted as one 4pk barcode; the POS converts it on
--     import, so export files are byte-for-byte what they were.
--   * catalogue_imports records every import: who, when, which venue and file,
--     merge or replace, and what changed.
--
-- Barcodes are STORED as imported and MATCHED on barcode_key(): an all-digit
-- code is right-aligned to 14 digits (GTIN-14), so the UPC-A, EAN-13 and
-- GTIN-14 renderings of one bottle are one key; anything else is trimmed and
-- upper-cased. product-import.js has the same function, and
-- scripts/test-product-import.js checks the two agree.
--
-- Writes go through the functions below only (security definer, with the
-- role, switch and plan checked inside); the tables have no client insert,
-- update or delete. Reads: everyone in the organisation while the list is on
-- and the plan allows it. Staff are the ones scanning.
--
-- Additive: one defaulted column, three tables, eight functions. Safe to run
-- twice and mid-count. Mirrored into schema.sql.

-- ---------------------------------------------------------------------------
-- 1. The switch and the plan gate.
-- ---------------------------------------------------------------------------
alter table public.organisations
  add column if not exists products_enabled boolean not null default false;

-- Which plans include the product list. 'multi' is Team; 'trial' is treated as
-- Team until it ends. Solo ('single'), a lapsed plan ('pending') and anything
-- unknown do not.
create or replace function public.plan_has_products(p_tier text)
returns boolean language sql immutable as $$
  select coalesce(p_tier, '') in ('multi', 'trial')
$$;

-- Is the product list on, and allowed, for the caller's organisation?
create or replace function public.products_on_for_me()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select o.products_enabled and public.plan_has_products(o.plan_tier)
                     from public.organisations o where o.id = public.my_org_id()), false)
$$;
grant execute on function public.products_on_for_me() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Barcode key. Must match barcodeKey() in product-import.js exactly.
--    (Also defined by the never-applied 20261024_01, identically.)
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
create table if not exists public.catalogue_imports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  pos_system text not null check (public.is_known_pos(pos_system)),
  file_name text,
  -- merge: add and update, keep the rest. replace: the file is the venue's
  -- whole list, so products not in it are deleted when the import finishes
  -- (and only then: a failed import never leaves a venue half empty).
  mode text not null check (mode in ('merge', 'replace')),
  status text not null default 'running' check (status in ('running', 'done')),
  rows_sent integer not null default 0,
  products_created integer not null default 0,
  products_updated integer not null default 0,
  products_removed integer not null default 0,
  barcodes_saved integer not null default 0,
  barcodes_moved integer not null default 0,
  -- Problems the browser found and reported before sending (counts only).
  warnings integer not null default 0,
  skipped integer not null default 0,
  imported_by uuid references auth.users(id) on delete set null,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists catalogue_imports_org_recent on public.catalogue_imports (org_id, started_at desc);

create table if not exists public.venue_products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  name text not null check (btrim(name) <> ''),
  -- The POS's own code (PLU, stock code) when the file has one. Bepoz's
  -- product list doesn't; then a product is recognised by its barcodes.
  item_code text check (item_code is null or btrim(item_code) <> ''),
  -- The POS's grouping ("Parent Name" in Bepoz: "Whisky", "Cider").
  group_name text,
  last_import_id uuid references public.catalogue_imports(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, item_code)
);
create index if not exists venue_products_venue on public.venue_products (venue_id);

create table if not exists public.venue_product_barcodes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  product_id uuid not null references public.venue_products(id) on delete cascade,
  barcode text not null check (btrim(barcode) <> ''),   -- as imported
  barcode_key text not null,                            -- barcode_key(barcode)
  -- What the POS calls this barcode's size: "Bottle", "4pk", "Carton".
  size_name text,
  kind text not null default 'unit' check (kind in ('unit', 'pack', 'carton')),
  -- Units in one scan of it: 1, 4, 24. NULL when not known (a POS "Case").
  units integer check (units is null or units >= 1),
  -- Why this code looked unusual at import (short in-store code, failed check
  -- digit), or NULL. It was imported anyway; the venue chose to keep it.
  warning text,
  created_at timestamptz not null default now(),
  -- One product per barcode per venue: a scan must resolve to one thing.
  unique (venue_id, barcode_key)
);
create index if not exists venue_product_barcodes_org on public.venue_product_barcodes (org_id);
create index if not exists venue_product_barcodes_product on public.venue_product_barcodes (product_id);

-- ---------------------------------------------------------------------------
-- 4. RLS. Read: the organisation, while the list is on and the plan allows.
--    Write: only through the functions below.
--    (select …) wrapping per 20261014_03: evaluated once per statement.
-- ---------------------------------------------------------------------------
alter table public.catalogue_imports enable row level security;
alter table public.venue_products enable row level security;
alter table public.venue_product_barcodes enable row level security;

drop policy if exists "read org catalogue products" on public.venue_products;
create policy "read org catalogue products" on public.venue_products
  for select using (org_id = (select public.my_org_id()) and (select public.products_on_for_me()));

drop policy if exists "read org catalogue barcodes" on public.venue_product_barcodes;
create policy "read org catalogue barcodes" on public.venue_product_barcodes
  for select using (org_id = (select public.my_org_id()) and (select public.products_on_for_me()));

drop policy if exists "owner manager read catalogue imports" on public.catalogue_imports;
create policy "owner manager read catalogue imports" on public.catalogue_imports
  for select using (org_id = (select public.my_org_id())
                    and (select public.my_role()) in ('owner', 'manager'));

-- Reads are granted explicitly rather than left to Supabase's default
-- privileges; the policies above decide which rows.
grant select on public.catalogue_imports, public.venue_products, public.venue_product_barcodes to authenticated;
revoke insert, update, delete on public.catalogue_imports, public.venue_products, public.venue_product_barcodes
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. What the app reads: the switch, the plan, and a "has anything changed?"
--    value. One small call at sign-in; while the list is on, once a minute.
--    The version moves when an import finishes, when the number of catalogue
--    barcodes changes, and when a manual barcode name is added, edited or
--    deleted, so a phone mid-count picks up names without reloading.
-- ---------------------------------------------------------------------------
create or replace function public.my_products_access()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'enabled', coalesce(o.products_enabled, false),
    'allowed', public.plan_has_products(o.plan_tier),
    'role', public.my_role(),
    'version',
      coalesce((select max(i.finished_at)::text from public.catalogue_imports i
                 where i.org_id = o.id and i.status = 'done'), '-')
      || '|' || (select count(*) from public.venue_product_barcodes b where b.org_id = o.id)
      || '|' || coalesce((select max(n.updated_at)::text from public.org_barcodes n where n.org_id = o.id), '-')
      || '|' || (select count(*) from public.org_barcodes n where n.org_id = o.id))
  from public.organisations o
  where o.id = public.my_org_id()
$$;
grant execute on function public.my_products_access() to authenticated;

-- Owner only. Turning it on needs a plan that includes it; turning it off is
-- always allowed. Writes who, before and after to the audit log.
create or replace function public.set_products_enabled(p_on boolean)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_was boolean;
  v_tier text;
  v_name text;
  v_actor text;
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can turn the product list on or off.';
  end if;
  select products_enabled, plan_tier, name into v_was, v_tier, v_name
    from public.organisations where id = v_org for update;
  if coalesce(p_on, false) and not public.plan_has_products(v_tier) then
    raise exception 'Product lists are part of the Team plan.';
  end if;
  if v_was is not distinct from coalesce(p_on, false) then
    return v_was;
  end if;
  update public.organisations set products_enabled = coalesce(p_on, false) where id = v_org;
  select coalesce(p.full_name, u.email, 'Unknown user') into v_actor
    from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();
  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id,
                                target_label, before, after)
  values (v_org, v_name, auth.uid(), coalesce(v_actor, 'Unknown user'),
          case when p_on then 'catalogue.enabled' else 'catalogue.disabled' end,
          'organisation', v_org, v_name,
          jsonb_build_object('products_enabled', v_was), jsonb_build_object('products_enabled', coalesce(p_on, false)));
  return coalesce(p_on, false);
end $$;
grant execute on function public.set_products_enabled(boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Import, in three calls: start -> batches -> finish.
--    The file is read and checked in the browser (product-import.js), then
--    sent 500 products at a time, so a 20,000-line POS export is ~40 short
--    calls rather than one request big enough to time out.
-- ---------------------------------------------------------------------------
create or replace function public.catalogue_writer_check()
returns uuid
language plpgsql stable security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  if public.my_role() is null or public.my_role() not in ('owner', 'manager') then
    raise exception 'Only an owner or manager can import a product list.';
  end if;
  if not public.products_on_for_me() then
    raise exception 'The product list is off for this organisation, or not part of its plan.';
  end if;
  return v_org;
end $$;
revoke execute on function public.catalogue_writer_check() from public, anon, authenticated;

create or replace function public.start_catalogue_import(p_venue_id uuid, p_pos_system text, p_file_name text,
                                                         p_mode text, p_warnings integer default 0,
                                                         p_skipped integer default 0)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.catalogue_writer_check();
  v_id uuid;
begin
  if not exists (select 1 from public.venues v where v.id = p_venue_id and v.org_id = v_org and v.archived_at is null) then
    raise exception 'Venue not found.';
  end if;
  if not public.is_known_pos(p_pos_system) then
    raise exception 'Unknown POS system.';
  end if;
  if p_mode is null or p_mode not in ('merge', 'replace') then
    raise exception 'Choose merge or replace.';
  end if;
  insert into public.catalogue_imports (org_id, venue_id, pos_system, file_name, mode, warnings, skipped, imported_by)
  values (v_org, p_venue_id, p_pos_system, left(p_file_name, 200), p_mode,
          greatest(coalesce(p_warnings, 0), 0), greatest(coalesce(p_skipped, 0), 0), auth.uid())
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.start_catalogue_import(uuid, text, text, text, integer, integer) to authenticated;

-- p_products: [{ "name": "…", "item_code": "…" | null, "group_name": "…" | null,
--                "barcodes": [{ "barcode": "…", "size_name": "4pk", "kind": "unit"|"pack"|"carton",
--                               "units": 4 | null, "warning": "…" | null }] }]
--
-- Which existing product a row is: the same item code in this venue; with no
-- item code, the product that already owns one of its barcodes (unless an
-- earlier row of THIS import already claimed that product); otherwise a new
-- one. Its barcode set is then exactly the file's: a barcode the POS no longer
-- lists for it is removed, and one that belonged to another product moves
-- (counted as moved).
create or replace function public.import_catalogue_batch(p_import_id uuid, p_products jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.catalogue_writer_check();
  imp public.catalogue_imports%rowtype;
  r jsonb;
  b jsonb;
  v_name text;
  v_code text;
  v_pid uuid;
  v_key text;
  v_old uuid;
  v_keys text[];
  n_created int := 0; n_updated int := 0; n_barcodes int := 0; n_moved int := 0;
begin
  select * into imp from public.catalogue_imports where id = p_import_id and org_id = v_org for update;
  if not found then
    raise exception 'Import not found.';
  end if;
  if imp.status <> 'running' then
    raise exception 'That import has already finished.';
  end if;
  if jsonb_typeof(p_products) <> 'array' or jsonb_array_length(p_products) > 1000 then
    raise exception 'Send products as an array of at most 1000.';
  end if;

  for r in select * from jsonb_array_elements(p_products) loop
    v_name := left(btrim(coalesce(r->>'name', '')), 300);
    continue when v_name = '';
    v_code := nullif(left(btrim(coalesce(r->>'item_code', '')), 100), '');
    v_pid := null;

    if v_code is not null then
      select id into v_pid from public.venue_products where venue_id = imp.venue_id and item_code = v_code;
    else
      select p.id into v_pid
        from jsonb_array_elements(coalesce(r->'barcodes', '[]'::jsonb)) x
        join public.venue_product_barcodes vb
          on vb.venue_id = imp.venue_id and vb.barcode_key = public.barcode_key(x->>'barcode')
        join public.venue_products p on p.id = vb.product_id
       where p.last_import_id is distinct from p_import_id and p.item_code is null
       limit 1;
    end if;

    if v_pid is null then
      insert into public.venue_products (org_id, venue_id, name, item_code, group_name, last_import_id)
      values (v_org, imp.venue_id, v_name, v_code, nullif(left(btrim(coalesce(r->>'group_name', '')), 200), ''), p_import_id)
      returning id into v_pid;
      n_created := n_created + 1;
    else
      update public.venue_products
         set name = v_name, group_name = nullif(left(btrim(coalesce(r->>'group_name', '')), 200), ''),
             last_import_id = p_import_id, updated_at = now()
       where id = v_pid;
      n_updated := n_updated + 1;
    end if;

    v_keys := '{}';
    for b in select * from jsonb_array_elements(coalesce(r->'barcodes', '[]'::jsonb)) loop
      continue when btrim(coalesce(b->>'barcode', '')) = '';
      v_key := public.barcode_key(b->>'barcode');
      continue when v_key = any (v_keys);   -- the same code twice on one product
      v_keys := v_keys || v_key;
      select product_id into v_old from public.venue_product_barcodes
       where venue_id = imp.venue_id and barcode_key = v_key;
      if found and v_old is distinct from v_pid then n_moved := n_moved + 1; end if;
      insert into public.venue_product_barcodes (org_id, venue_id, product_id, barcode, barcode_key,
                                                 size_name, kind, units, warning)
      values (v_org, imp.venue_id, v_pid, left(btrim(b->>'barcode'), 48), v_key,
              nullif(left(btrim(coalesce(b->>'size_name', '')), 60), ''),
              case when b->>'kind' in ('unit', 'pack', 'carton') then b->>'kind' else 'unit' end,
              case when (b->>'units') ~ '^[0-9]{1,5}$' and (b->>'units')::int >= 1 then (b->>'units')::int end,
              nullif(left(coalesce(b->>'warning', ''), 200), ''))
      on conflict (venue_id, barcode_key) do update
        set product_id = excluded.product_id, barcode = excluded.barcode, size_name = excluded.size_name,
            kind = excluded.kind, units = excluded.units, warning = excluded.warning;
      n_barcodes := n_barcodes + 1;
    end loop;
    -- This product's barcodes are exactly the file's now.
    delete from public.venue_product_barcodes
     where product_id = v_pid and not (barcode_key = any (v_keys));
  end loop;

  update public.catalogue_imports
     set rows_sent = rows_sent + jsonb_array_length(p_products),
         products_created = products_created + n_created,
         products_updated = products_updated + n_updated,
         barcodes_saved = barcodes_saved + n_barcodes,
         barcodes_moved = barcodes_moved + n_moved
   where id = p_import_id;

  return jsonb_build_object('created', n_created, 'updated', n_updated, 'barcodes', n_barcodes, 'moved', n_moved);
end $$;
grant execute on function public.import_catalogue_batch(uuid, jsonb) to authenticated;

-- Called once every batch has succeeded. Replace: products of this venue that
-- the file didn't include are deleted, with their barcodes. Either mode: a
-- product left with no barcodes (every one moved to another product) is
-- deleted too, since nothing can find it any more.
create or replace function public.finish_catalogue_import(p_import_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.catalogue_writer_check();
  imp public.catalogue_imports%rowtype;
  n_removed int := 0;
  n_empty int := 0;
  v_actor text;
  v_venue text;
begin
  select * into imp from public.catalogue_imports where id = p_import_id and org_id = v_org for update;
  if not found then
    raise exception 'Import not found.';
  end if;
  if imp.status <> 'running' then
    raise exception 'That import has already finished.';
  end if;

  if imp.mode = 'replace' then
    delete from public.venue_products
     where venue_id = imp.venue_id and last_import_id is distinct from p_import_id;
    get diagnostics n_removed = row_count;
  end if;
  delete from public.venue_products p
   where p.venue_id = imp.venue_id
     and not exists (select 1 from public.venue_product_barcodes b where b.product_id = p.id);
  get diagnostics n_empty = row_count;

  update public.catalogue_imports
     set status = 'done', finished_at = now(), products_removed = n_removed + n_empty
   where id = p_import_id
  returning * into imp;

  select name into v_venue from public.venues where id = imp.venue_id;
  select coalesce(p.full_name, u.email, 'Unknown user') into v_actor
    from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();
  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
  values (v_org, (select name from public.organisations where id = v_org), auth.uid(), coalesce(v_actor, 'Unknown user'),
          'catalogue.imported', 'venue', imp.venue_id, v_venue,
          jsonb_build_object('import_id', imp.id, 'file_name', imp.file_name, 'pos_system', imp.pos_system,
                             'mode', imp.mode, 'rows', imp.rows_sent,
                             'created', imp.products_created, 'updated', imp.products_updated,
                             'removed', imp.products_removed, 'barcodes', imp.barcodes_saved,
                             'moved', imp.barcodes_moved, 'warnings', imp.warnings, 'skipped', imp.skipped));

  return to_jsonb(imp);
end $$;
grant execute on function public.finish_catalogue_import(uuid) to authenticated;

-- Verify:
--   select column_name from information_schema.columns
--    where table_name = 'organisations' and column_name = 'products_enabled';          -- 1 row
--   select public.barcode_key('012345678905'), public.barcode_key('0012345678905');     -- equal
--   select has_table_privilege('authenticated', 'public.venue_products', 'insert');     -- false
--   select name, plan_tier, products_enabled from public.organisations order by name;   -- all false

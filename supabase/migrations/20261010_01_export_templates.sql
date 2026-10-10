-- Export templates, Phase 1: the table, its RLS, the three verified system
-- templates, and the org default that replaces export_format.
--
-- Why: Gantry's export was two hand-written builders in app.html — the
-- "standard" barcode,count file Bepoz was verified against on 2026-08-20, and
-- the five-column Gantry CSV. Every new POS meant another builder, and every
-- builder was a place to get a byte wrong. The Colac trial (2026-09-29) added a
-- third axis, the leading zero, as an org toggle. This makes all of it data: a
-- template row says which identifier, which barcode rules, which columns in
-- which order, header or not, delimiter, extension, BOM, filename — and one
-- engine (export-engine.js) produces the file from it.
--
-- Phase 1 changes NO export. The three seeded templates reproduce the two old
-- builders byte for byte (scripts/test-export-engine.js holds the old code as
-- the oracle and proves it), and every existing org is pointed at the template
-- that matches what it exports today:
--
--   export_format 'standard'/'bepoz', strip_leading_zero false -> 'standard'
--   export_format 'standard'/'bepoz', strip_leading_zero true  -> 'bepoz'
--   anything else ('full', legacy 'myob'/'lightspeed')         -> 'full'
--
-- (the last line matches app.html's old exportFormat() fallback exactly).
-- As of 2026-10-10 that is all 6 orgs -> 'standard', including Colac, whose
-- strip toggle was never ticked. Colac needs 'Bepoz' chosen in admin.html.
--
-- Not in Phase 1, on purpose:
--   * MYOB EXO, Lightspeed R/K, Shopfront, Tower — researched, not verified. They
--     are seeded in Phase 2 with verified = false, alongside the POS product
--     list that the SKU/stock-code ones need to produce anything at all.
--   * Fill mode (mode = 'fill') — the column exists so the shape is final, but
--     set_export_template() refuses it and the engine refuses to build it.
--
-- Additive: one new table, one new column on organisations (populated for every
-- existing row, as above), two new functions, one trigger function replaced.
-- No existing column is changed or dropped — export_format and
-- strip_leading_zero stay, mirrored from the chosen template, so an app.html
-- cached from before this release keeps exporting the same file. Safe to run
-- twice. Safe mid-count: no export changes shape. Mirrored into schema.sql.
--
-- Run BEFORE pushing the new app.html/admin.html.

-- ---------------------------------------------------------------------------
-- 1. The table.
--
-- org_id NULL  <=> is_system. A system template belongs to nobody and is read by
-- everybody; an org template belongs to exactly one org. The check makes the
-- two states the only states.
--
-- `code` is the stable key for system templates ('standard', 'bepoz', 'full'),
-- so the seed below can be re-run as an upsert and the legacy mapping has
-- something that isn't a display name to match on. Org templates have none.
--
-- `verified` is server-only (not in the client GRANT): it is Gantry's claim
-- that a template has been checked against a real import, and an org cannot
-- grant that to itself. admin.html labels anything unverified.
--
-- `bom` is not in the brief's field list and is required: the Gantry CSV has
-- always carried a UTF-8 BOM (Excel needs it for accented venue names), and a
-- headerless POS file must never carry one (it corrupts the first barcode).
-- Byte-identity with the old builders is impossible without it.
--
-- `import_behaviour` is NULL for "not known" rather than defaulting to a guess.
-- Whether Bepoz's stocktake import adds to or replaces existing counts has not
-- been confirmed, and a confident wrong answer here would drive a confident
-- wrong warning in the app.
-- ---------------------------------------------------------------------------
create table if not exists public.export_templates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organisations(id) on delete cascade default public.my_org_id(),
  is_system boolean not null default false,
  code text,
  name text not null check (btrim(name) <> ''),
  description text,
  verified boolean not null default false,
  identifier_type text not null default 'barcode'
    check (identifier_type in ('barcode', 'sku', 'stockcode', 'system_id')),
  identifier_fallback text
    check (identifier_fallback is null
           or identifier_fallback in ('barcode', 'sku', 'stockcode', 'system_id')),
  barcode_rules jsonb not null default '{"leading_zero": "keep", "trim": true}'::jsonb
    check (jsonb_typeof(barcode_rules) = 'object'
           and coalesce(barcode_rules->>'leading_zero', 'keep')
               in ('keep', 'strip_one', 'strip_all', 'pad')),
  include_header boolean not null default false,
  columns jsonb not null
    check (jsonb_typeof(columns) = 'array' and jsonb_array_length(columns) > 0),
  delimiter text not null default ',' check (delimiter in (',', E'\t')),
  file_extension text not null default 'csv' check (file_extension in ('csv', 'txt')),
  file_name_pattern text,
  bom boolean not null default false,
  import_behaviour text check (import_behaviour is null or import_behaviour in ('add', 'replace')),
  mode text not null default 'generate' check (mode in ('generate', 'fill')),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint export_templates_system_has_no_org check (is_system = (org_id is null))
);

create unique index if not exists export_templates_system_code
  on public.export_templates (code) where is_system;
-- Two org templates called "Bepoz" and "bepoz " would be one entry in a picker
-- that can't tell them apart.
create unique index if not exists export_templates_org_name
  on public.export_templates (org_id, lower(btrim(name))) where not is_system;

-- ---------------------------------------------------------------------------
-- 2. RLS. Orgs see the system templates plus their own; nobody sees another
-- org's; only owner/manager write, and only their own org's non-system rows.
--
-- `to authenticated` on every policy: the anon key is in config.js, and while
-- the system templates are not secret, nothing about this table is for a
-- signed-out visitor.
-- ---------------------------------------------------------------------------
alter table public.export_templates enable row level security;

drop policy if exists "read system and own export templates" on public.export_templates;
create policy "read system and own export templates" on public.export_templates
  for select to authenticated
  using (is_system or org_id = public.my_org_id());

drop policy if exists "owner manager insert export templates" on public.export_templates;
create policy "owner manager insert export templates" on public.export_templates
  for insert to authenticated
  with check (not is_system and org_id = public.my_org_id()
              and public.my_role() in ('owner', 'manager'));

drop policy if exists "owner manager update export templates" on public.export_templates;
create policy "owner manager update export templates" on public.export_templates
  for update to authenticated
  using (not is_system and org_id = public.my_org_id()
         and public.my_role() in ('owner', 'manager'))
  with check (not is_system and org_id = public.my_org_id()
              and public.my_role() in ('owner', 'manager'));

drop policy if exists "owner manager delete export templates" on public.export_templates;
create policy "owner manager delete export templates" on public.export_templates
  for delete to authenticated
  using (not is_system and org_id = public.my_org_id()
         and public.my_role() in ('owner', 'manager'));

-- Column GRANTs — both halves, same reason as every other table here: Supabase's
-- default privileges grant ALL on a new table to anon and authenticated, so the
-- revoke has to be explicit, and RLS alone can't stop a client writing a column
-- it shouldn't (is_system, verified, code). The policies decide which ROWS; this
-- decides which COLUMNS.
--
-- org_id IS in both lists, deliberately — the lesson of 20260929_02. An upsert
-- that sends org_id puts it in its DO UPDATE SET list, and without UPDATE on
-- org_id every such write fails with 42501 before RLS is even consulted. The
-- policies pin org_id to my_org_id() on both sides, so it can't move a row.
revoke insert, update, delete on public.export_templates from anon;
revoke insert, update on public.export_templates from authenticated;
grant insert (org_id, name, description, identifier_type, identifier_fallback,
              barcode_rules, include_header, columns, delimiter, file_extension,
              file_name_pattern, bom, import_behaviour, mode)
  on public.export_templates to authenticated;
grant update (org_id, name, description, identifier_type, identifier_fallback,
              barcode_rules, include_header, columns, delimiter, file_extension,
              file_name_pattern, bom, import_behaviour, mode)
  on public.export_templates to authenticated;

create or replace function public.touch_export_template()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists touch_export_templates on public.export_templates;
create trigger touch_export_templates
  before update on public.export_templates
  for each row execute function public.touch_export_template();

-- ---------------------------------------------------------------------------
-- 3. The system templates.
--
-- The JSON between the $seed$ markers is ALSO read by
-- scripts/test-export-engine.js, which builds a file from each of these and
-- compares it byte for byte against the old builders. That is the only reason
-- it is one JSON literal rather than three INSERTs: the test and the database
-- read the same text, so they cannot drift. Edit it here, re-run the test.
--
-- Upsert on code, so re-running this file updates the definitions rather than
-- duplicating them — and an org pointing at a system template follows the edit.
-- That is the point of system templates, and also why editing one is a
-- production change to every org using it.
-- ---------------------------------------------------------------------------
insert into public.export_templates
  (is_system, org_id, code, name, description, verified, identifier_type,
   identifier_fallback, barcode_rules, include_header, columns, delimiter,
   file_extension, file_name_pattern, bom, import_behaviour, mode, created_by)
select true, null, s.code, s.name, s.description, s.verified, s.identifier_type,
       s.identifier_fallback, s.barcode_rules, s.include_header, s.columns,
       s.delimiter, s.file_extension, s.file_name_pattern, s.bom,
       s.import_behaviour, s.mode, null
  from jsonb_to_recordset($seed$[
    {
      "code": "standard",
      "name": "Standard (barcode, count)",
      "description": "Barcode and count, no header row. The shape most POS stocktake imports accept. Barcodes exactly as scanned.",
      "verified": true,
      "identifier_type": "barcode",
      "identifier_fallback": null,
      "barcode_rules": {"leading_zero": "keep", "trim": true},
      "include_header": false,
      "columns": [
        {"header": "barcode", "source": "identifier"},
        {"header": "count", "source": "quantity"}
      ],
      "delimiter": ",",
      "file_extension": "csv",
      "file_name_pattern": "gantry-{location}-{stocktake}-{date}-standard",
      "bom": false,
      "import_behaviour": null,
      "mode": "generate"
    },
    {
      "code": "bepoz",
      "name": "Bepoz",
      "description": "Barcode and count, no header row, with one leading zero removed from 13- and 14-digit barcodes — the form Bepoz stores them in. Checked against a real Bepoz import.",
      "verified": true,
      "identifier_type": "barcode",
      "identifier_fallback": null,
      "barcode_rules": {"leading_zero": "strip_one", "trim": true},
      "include_header": false,
      "columns": [
        {"header": "barcode", "source": "identifier"},
        {"header": "count", "source": "quantity"}
      ],
      "delimiter": ",",
      "file_extension": "csv",
      "file_name_pattern": "gantry-{location}-{stocktake}-{date}-bepoz",
      "bom": false,
      "import_behaviour": null,
      "mode": "generate"
    },
    {
      "code": "full",
      "name": "Gantry CSV (full)",
      "description": "Stocktake, barcode, quantity and scan times, with a header row. For spreadsheets and records, not for POS import.",
      "verified": true,
      "identifier_type": "barcode",
      "identifier_fallback": null,
      "barcode_rules": {"leading_zero": "keep", "trim": true},
      "include_header": true,
      "columns": [
        {"header": "stocktake", "source": "stocktake_name"},
        {"header": "barcode", "source": "identifier"},
        {"header": "qty", "source": "quantity"},
        {"header": "first_scanned", "source": "first_scanned"},
        {"header": "last_scanned", "source": "last_scanned"}
      ],
      "delimiter": ",",
      "file_extension": "csv",
      "file_name_pattern": null,
      "bom": true,
      "import_behaviour": null,
      "mode": "generate"
    }
  ]$seed$::jsonb) as s(
    code text, name text, description text, verified boolean,
    identifier_type text, identifier_fallback text, barcode_rules jsonb,
    include_header boolean, columns jsonb, delimiter text, file_extension text,
    file_name_pattern text, bom boolean, import_behaviour text, mode text)
on conflict (code) where is_system do update set
  name = excluded.name,
  description = excluded.description,
  verified = excluded.verified,
  identifier_type = excluded.identifier_type,
  identifier_fallback = excluded.identifier_fallback,
  barcode_rules = excluded.barcode_rules,
  include_header = excluded.include_header,
  columns = excluded.columns,
  delimiter = excluded.delimiter,
  file_extension = excluded.file_extension,
  file_name_pattern = excluded.file_name_pattern,
  bom = excluded.bom,
  import_behaviour = excluded.import_behaviour,
  mode = excluded.mode;

-- ---------------------------------------------------------------------------
-- 4. The org default.
--
-- `on delete set null`: deleting an org's own template must not delete the org.
-- A NULL here is handled by app.html, which falls back to the system template
-- matching export_format/strip_leading_zero — the same mapping as below — so a
-- deleted default degrades to the file the org got before templates existed.
--
-- Off the client GRANT: set_export_template() is the only writer.
-- ---------------------------------------------------------------------------
alter table public.organisations
  add column if not exists export_template_id uuid
    references public.export_templates(id) on delete set null;

-- Point every org at the template that reproduces its current export. Run from
-- the SQL editor, auth.uid() is NULL, so log_organisations_change() writes no
-- audit rows for this — correct, nobody chose it.
update public.organisations o
   set export_template_id = t.id
  from public.export_templates t
 where o.export_template_id is null
   and t.is_system
   and t.code = case
                  when o.export_format in ('standard', 'bepoz')
                    then case when o.strip_leading_zero then 'bepoz' else 'standard' end
                  else 'full'
                end;

-- ---------------------------------------------------------------------------
-- set_export_template(p_template_id uuid) — the org default.
--
-- Owner AND manager, an RPC for the same reason as set_scan_prefs() and
-- set_strip_leading_zero(): "owner update org" is owner-only, and widening it
-- would also hand managers `country`, `join_code` and the rest. The person who
-- fixes a failed POS import is usually the venue manager.
--
-- Mirrors the two legacy columns from the chosen template, so an app.html cached
-- from before this release (GitHub Pages serves stale pages for a while after a
-- deploy) produces the same file the new one does:
--   export_format      'full' for the full system template, else 'standard'
--   strip_leading_zero true iff the template strips exactly one zero
-- A custom template has no legacy equivalent; 'standard' is the nearest shape.
--
-- Refuses fill-mode templates: a fill template needs the venue's own POS file
-- uploaded at export time, so it cannot be what one tap on Export produces.
-- ---------------------------------------------------------------------------
create or replace function public.set_export_template(p_template_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_role text := public.my_role();
  t public.export_templates%rowtype;
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  -- Explicit null test, not `<>`: my_role() is NULL for a caller with no
  -- membership and a NULL comparison is NULL, which plpgsql treats as false.
  if v_role is null or v_role not in ('owner', 'manager') then
    raise exception 'Only an owner or manager can change the export template.';
  end if;

  -- security definer bypasses RLS, so the visibility rule is re-stated here.
  -- Same message whether it doesn't exist or belongs to another org.
  select * into t from public.export_templates
   where id = p_template_id and (is_system or org_id = v_org);
  if not found then
    raise exception 'Export template not found.';
  end if;
  if t.mode <> 'generate' then
    raise exception 'That template fills in a file exported from your POS, so it cannot be the default export.';
  end if;

  update public.organisations
     set export_template_id = t.id,
         export_format = case when t.is_system and t.code = 'full' then 'full' else 'standard' end,
         strip_leading_zero = coalesce(t.barcode_rules->>'leading_zero', 'keep') = 'strip_one'
   where id = v_org;

  return t.id;
end $$;

grant execute on function public.set_export_template(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Audit. One row per decision.
--
-- set_export_template() changes up to three columns at once (the template and
-- its two mirrors). Logging all three would put "changed the export format",
-- "turned off removing the leading zero" and "changed the export template" in
-- the log for one tap, two of them describing side effects nobody chose. So
-- when export_template_id changes, only the template is logged, with both names
-- resolved (the log is read by people, and a UUID is not evidence). The two
-- legacy branches still fire on their own — that is the cached-page path.
--
-- Whole function replaced; everything other than the template branch and the
-- `if not v_template_changed` guards is byte-identical to schema.sql.
-- ---------------------------------------------------------------------------
create or replace function public.log_organisations_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  v_template_changed boolean := old.export_template_id is distinct from new.export_template_id;
begin
  if actor is null then
    return new;
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;

  if old.name is distinct from new.name then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.name_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if old.logo_url is distinct from new.logo_url then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.logo_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if v_template_changed then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.export_template_changed', 'organisation', new.id, new.name,
            to_jsonb(old) || jsonb_build_object('export_template_name',
              (select name from public.export_templates where id = old.export_template_id)),
            to_jsonb(new) || jsonb_build_object('export_template_name',
              (select name from public.export_templates where id = new.export_template_id)));
  end if;
  if not v_template_changed and old.export_format is distinct from new.export_format then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.export_format_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if old.country is distinct from new.country then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.country_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if old.join_code is distinct from new.join_code then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.join_code_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  if old.heartbeat_interval_seconds is distinct from new.heartbeat_interval_seconds then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.heartbeat_interval_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  -- A permission boundary, so who moved it and when belongs in the same trail
  -- as role changes — it decides what a whole role can and cannot see.
  if old.staff_see_own_stocktakes_only is distinct from new.staff_see_own_stocktakes_only then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.staff_visibility_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  -- Changes the bytes a POS importer reads, same as export_format above.
  if not v_template_changed and old.strip_leading_zero is distinct from new.strip_leading_zero then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.strip_leading_zero_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- 1. three system templates, all verified, none owned by an org:
--   select code, name, verified, org_id is null as system_row
--     from public.export_templates where is_system order by code;
--   -- expect: bepoz, full, standard — all true, true
--
--   -- 2. every org has a template, and it matches what it exported before:
--   select o.name, o.export_format, o.strip_leading_zero, t.code
--     from public.organisations o
--     left join public.export_templates t on t.id = o.export_template_id
--    order by o.name;
--   -- expect: no NULL code; 'standard'+false -> standard, 'standard'+true ->
--   -- bepoz, 'full' -> full. As of 2026-10-10: every row -> standard.
--
--   -- 3. as an owner or manager (Colac):
--   select public.set_export_template(
--     (select id from public.export_templates where is_system and code = 'bepoz'));
--   select export_format, strip_leading_zero from public.organisations
--    where id = public.my_org_id();             -- => standard | true
--   select action, after->>'export_template_name' from public.audit_log
--    where action like 'organisation.export_%' order by created_at desc limit 3;
--   -- => exactly ONE new row: organisation.export_template_changed | Bepoz
--
--   -- 4. staff are refused:
--   --   ERROR: Only an owner or manager can change the export template.
--
--   -- 5. system templates cannot be edited or minted by a client — both fail:
--   --   PATCH /rest/v1/export_templates?code=eq.bepoz  {"name": "x"}   -> 0 rows (RLS)
--   --   POST  /rest/v1/export_templates  {"is_system": true, ...}       -> 42501 (GRANT)
--
--   -- 6. the column is not writable directly:
--   --   PATCH /rest/v1/organisations?id=eq.<org>  {"export_template_id": "<uuid>"}
--   --   -> 42501 permission denied
-- ---------------------------------------------------------------------------

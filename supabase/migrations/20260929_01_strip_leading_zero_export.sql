-- Export-time leading-zero normalisation: the org setting, and the record of
-- which way each export went.
--
-- Why this exists: Colac Port Adelaide's first live count (2026-09-29, ~600
-- lines) imported into Bepoz with ~50 lines unmatched. Most were products Bepoz
-- didn't have set up. The rest were a leading zero — the same product captured
-- as "0797776409853" on one phone and "797776409853" on another (Bepoz holds the
-- 12-digit form), and Tyrrell's Semillon captured with "00" where Bepoz holds a
-- single "0". In both cases removing exactly ONE leading zero produces the POS
-- barcode.
--
-- The cause is not in Gantry. Nothing here has ever padded a barcode: the scan
-- path is String(rawValue).trim() and every column is `text`. The same printed
-- symbol is legitimately reported as UPC-A (12), EAN-13 (the same digits padded
-- to 13) or GTIN-14 depending on the decoder, and Gantry runs two — the
-- platform's native BarcodeDetector on Android Chrome, the vendored zxing-wasm
-- ponyfill everywhere else. A venue counting with a mix of phones gets a mix of
-- paddings for one bottle.
--
-- So this is a per-org EXPORT setting, and the normalisation happens in
-- barcode-export.js while the file is built. Scanned data is never rewritten:
--
--   * what was scanned is evidence — a count is a claim about a shelf at a point
--     in time, and rewriting digits on the way in destroys the only record of
--     what the camera read;
--   * the right answer is per-POS. Bepoz wants the zero gone; the next importer
--     may insist on the padded form. A setting can be changed; a rewritten row
--     cannot;
--   * it must be reversible — off, and the next export is byte for byte what it
--     would have been before any of this existed.
--
-- Additive: one defaulted column on organisations, three on stocktakes, two new
-- functions, one trigger function replaced. No existing row is rewritten, no
-- policy changes, safe to run twice. Mirrored into schema.sql.
--
-- Run BEFORE pushing the new app.html/admin.html: admin.html calls
-- set_strip_leading_zero() (PGRST202 until it exists) and app.html calls
-- record_stocktake_export(). Note app.html treats a missing
-- record_stocktake_export() as non-fatal on purpose — a failed stamp must never
-- withhold a file the operator is entitled to — so exports keep working either
-- way, just untraceable until this runs.

-- ---------------------------------------------------------------------------
-- 1. The setting.
--
-- Default FALSE, and that matters: this changes the bytes a POS importer reads,
-- so no existing org may have its export shape altered by a migration. Colac
-- turns it on deliberately, in admin.html, and can turn it off again.
-- ---------------------------------------------------------------------------
alter table public.organisations
  add column if not exists strip_leading_zero boolean not null default false;

-- ---------------------------------------------------------------------------
-- set_strip_leading_zero(p_on boolean)
--
-- An RPC rather than another column on the client-writable GRANT, same shape and
-- same reason as set_scan_prefs() and set_scan_mode(): the "owner update org"
-- policy is OWNER-ONLY, but a venue manager is exactly the person who deals with
-- the POS import and finds out the zero is wrong. Widening that policy would
-- also hand managers `country` (the billing currency), `join_code` and
-- `export_format`. This grants one narrow capability to owner AND manager, and
-- the column stays off the GRANT so nothing else can write it.
--
-- Returns the stored value, so the client renders what the server holds rather
-- than what was tapped.
-- ---------------------------------------------------------------------------
create or replace function public.set_strip_leading_zero(p_on boolean)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_role text := public.my_role();
  v_on boolean := coalesce(p_on, false);
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  -- Explicit null test, not `<>`: my_role() is NULL for a caller with no
  -- membership and a NULL comparison is NULL, which plpgsql treats as false —
  -- the bypass this codebase has already been bitten by once.
  if v_role is null or v_role not in ('owner', 'manager') then
    raise exception 'Only an owner or manager can change export settings.';
  end if;

  update public.organisations set strip_leading_zero = v_on where id = v_org;
  return v_on;
end $$;

grant execute on function public.set_strip_leading_zero(boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The setting is an export-shape decision, so it belongs in the audit trail
-- beside export_format — "who changed the file we send the POS, and when" is the
-- first question asked when an import goes wrong.
--
-- Whole function replaced (create or replace), with one new branch added at the
-- end. Everything else is byte-identical to schema.sql.
-- ---------------------------------------------------------------------------
create or replace function public.log_organisations_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
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
  if old.export_format is distinct from new.export_format then
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
  if old.strip_leading_zero is distinct from new.strip_leading_zero then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.id, new.name, actor, actor_label, 'organisation.strip_leading_zero_changed', 'organisation', new.id, new.name, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 3. What each export actually sent.
--
-- Without this, a re-export is indistinguishable from the original and nobody
-- can answer "was the file we imported the stripped one?" weeks later — which is
-- the same question org_barcodes exists to answer about product names, and the
-- reason this whole trial produced a bug report at all.
--
-- Columns rather than only an audit row because the answer belongs ON the
-- stocktake, where whoever is arguing about it is already looking. The audit row
-- goes in too (below), so the sequence of re-exports survives.
--
-- Deliberately NOT added to any GRANT: client UPDATE on stocktakes is revoked
-- wholesale (see the stocktakes policies in schema.sql), so
-- record_stocktake_export() is the only writer.
-- ---------------------------------------------------------------------------
alter table public.stocktakes
  add column if not exists last_exported_at timestamptz;
alter table public.stocktakes
  add column if not exists last_export_format text;
alter table public.stocktakes
  add column if not exists last_export_strip_leading_zero boolean;

-- ---------------------------------------------------------------------------
-- record_stocktake_export(p_stocktake_id uuid, p_format text, p_strip boolean)
--
-- Any org member who can see the stocktake, because any of them can export it —
-- this records what happened, it does not authorise it. set_stocktake_status()
-- remains the thing that gates the workflow.
--
-- security definer because client UPDATE on stocktakes is revoked; the org
-- scoping the dropped update policy used to provide is re-implemented here, and
-- the row-visibility trigger (enforce_stocktake_row_visible) still applies on
-- top, so a staff member under staff_see_own_stocktakes_only cannot stamp a take
-- they cannot see.
--
-- Unlike set_stocktake_status() this does NOT no-op on a repeat: re-exporting an
-- already-completed take changes no status, so the status log says nothing about
-- it. This row is the only trace that the second file ever left the building.
-- ---------------------------------------------------------------------------
create or replace function public.record_stocktake_export(
  p_stocktake_id uuid,
  p_format text,
  p_strip_leading_zero boolean
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_take_org uuid;
  v_take_name text;
  v_format text := left(coalesce(btrim(p_format), 'unknown'), 40);
  v_strip boolean := coalesce(p_strip_leading_zero, false);
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  select s.org_id, s.name into v_take_org, v_take_name
    from public.stocktakes s where s.id = p_stocktake_id;

  -- Same message whether the stocktake is missing or belongs to another org, so
  -- this can't be used to probe for UUIDs. Same wording as
  -- set_stocktake_status().
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  update public.stocktakes
     set last_exported_at = now(),
         last_export_format = v_format,
         last_export_strip_leading_zero = v_strip
   where id = p_stocktake_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
  values (v_org, org_label, actor, actor_label, 'stocktake.exported', 'stocktake',
          p_stocktake_id, v_take_name,
          jsonb_build_object('format', v_format, 'strip_leading_zero', v_strip));
end $$;

grant execute on function public.record_stocktake_export(uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- 1. every existing org is OFF — no export shape changed by this migration:
--   select name, export_format, strip_leading_zero from public.organisations order by name;
--   -- expect strip_leading_zero = false on every row
--
--   -- 2. as an owner or manager:
--   select public.set_strip_leading_zero(true);   -- => true
--   select public.set_strip_leading_zero(false);  -- => false
--
--   -- 3. as staff:
--   --   ERROR: Only an owner or manager can change export settings.
--
--   -- 4. the column is not writable directly — this must fail:
--   --   PATCH /rest/v1/organisations?id=eq.<org>  {"strip_leading_zero": true}
--   -- expect: 42501 permission denied for column strip_leading_zero
--
--   -- 5. the change is audited beside export_format:
--   select action, after->>'strip_leading_zero' from public.audit_log
--    where action = 'organisation.strip_leading_zero_changed' order by created_at desc limit 5;
--
--   -- 6. the export stamp, run twice against a disposable stocktake (NOT Belles
--   --    or Colac) to prove a re-export is still traceable:
--   select public.record_stocktake_export('<take uuid>', 'Standard', true);
--   select last_exported_at, last_export_format, last_export_strip_leading_zero
--     from public.stocktakes where id = '<take uuid>';
--   select count(*) from public.audit_log
--    where action = 'stocktake.exported' and entity_id = '<take uuid>';  -- => 2
--
--   -- 7. another org's stocktake is not stampable:
--   --   ERROR: Stocktake not found.
-- ---------------------------------------------------------------------------

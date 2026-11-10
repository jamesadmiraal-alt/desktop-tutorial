-- ===========================================================================
-- APPLY THIS IN SUPABASE BEFORE PUSHING app.html.
--
-- The new app.html asks for export_templates.trailing_newline in every
-- template read (TEMPLATE_COLUMNS). Pushed first, against a database without
-- the column, every one of those reads is a 400: Account -> Exports says
-- "Could not load templates" and Export says "Could not load the export
-- template", for EVERY venue. Applied first, nothing breaks: the live app.html
-- names its columns, so it never sees the new one.
--
-- Between applying this and the new app.html going live, the OLD page already
-- lists the four trials below. Trials A and B would download as .csv with no
-- final line break, and C and D are refused ("Delimiter must be a comma or a
-- tab."). No existing template changes. Push straight after applying.
--
-- Never drop trailing_newline while the new app.html is live, for the same
-- reason. When three of the four trials are retired, keep the column: the
-- winner uses it.
-- ===========================================================================
--
-- Four TRIAL system export templates, to find out which file layout H&L Stock
-- accepts when a stocktake count is imported with PDE Type = BHT. H&L's own
-- Denso scanners save counts as Pack1.dat, but H&L doesn't publish the layout.
-- A venue exports one stocktake four ways and imports each file into a TEST
-- stocktake in H&L. The four are the same test files already sent to the H&L
-- venue (Parafield Airport Liquor) to import by hand, so Gantry's output
-- must match them byte for byte; scripts/test-export-engine.js proves it.
--
--   hl_test_a  barcode,count
--   hl_test_b  barcode<TAB>count
--   hl_test_c  barcode left-aligned in 13, count right-aligned in 6, spaces
--   hl_test_d  barcode left-aligned in 13, count right-aligned in 6, zeros
--
-- All four: CRLF, a CRLF after the last line too, no header, no BOM, barcodes
-- exactly as scanned, .dat, unverified, import_behaviour 'add' (H&L's help
-- says imported counts are ADDED to the stocktake, so importing the same file
-- twice doubles them).
--
-- What the engine needed that it couldn't do before:
--   * file_extension 'dat'
--   * delimiter '' = fixed width, each column carrying width/align/pad in the
--     existing `columns` jsonb (export-engine.js, fixedField())
--   * trailing_newline: a final CRLF. standard/bepoz/full stay false, their
--     bytes never had one
--
-- 'dat' and '' are allowed on SYSTEM templates only. The custom template
-- builder in app.html offers csv/txt and comma/tab, and the client GRANT lets
-- an org write file_extension, delimiter and columns directly, so without that
-- an org could save a template the builder would show (and re-save) as
-- csv/comma. trailing_newline is off the client GRANT for the same reason,
-- like `verified`.
--
-- TO RETIRE THE THREE LOSERS later: one DELETE by code. Orgs pointing at a
-- deleted template fall back to their legacy mapping (export_template_id is
-- ON DELETE SET NULL), and stocktakes.last_export_template_id and
-- export_template_submissions.template_id go NULL the same way. Remove them
-- from the $hl_seed$ block here AND in schema.sql, or a re-run of either
-- brings them back.
--
-- Additive: one column, two check constraints widened, four rows upserted. The
-- $seed$ block in 20261010_01 (standard, bepoz, full) is NOT touched; the test
-- still proves those byte-identical to the old builders. Safe to run twice.
-- Mirrored into schema.sql, including an identical copy of $hl_seed$.

-- ---------------------------------------------------------------------------
-- 1. The column.
-- ---------------------------------------------------------------------------
alter table public.export_templates
  add column if not exists trailing_newline boolean not null default false;

-- ---------------------------------------------------------------------------
-- 2. The two check constraints, widened for system templates only. The old
-- ones are the column checks from 20261010_01, under Postgres's default names.
-- ---------------------------------------------------------------------------
alter table public.export_templates drop constraint if exists export_templates_delimiter_check;
alter table public.export_templates add constraint export_templates_delimiter_check
  check (delimiter in (',', E'\t') or (is_system and delimiter = ''));
alter table public.export_templates drop constraint if exists export_templates_file_extension_check;
alter table public.export_templates add constraint export_templates_file_extension_check
  check (file_extension in ('csv', 'txt') or (is_system and file_extension = 'dat'));

-- ---------------------------------------------------------------------------
-- 3. The four trials.
--
-- The JSON between the $hl_seed$ markers is ALSO read by
-- scripts/test-export-engine.js, which builds a file from each and compares it
-- with the bytes the venue was sent, and requires the same block, unchanged,
-- in schema.sql. Same pattern as $seed$ in 20261010_01, kept as its own block
-- so that one stays untouched. Upsert on code, so re-running updates rather
-- than duplicates.
--
-- System template text is read by every org: no customer or venue names here.
-- ---------------------------------------------------------------------------
insert into public.export_templates
  (is_system, org_id, code, name, description, verified, identifier_type,
   identifier_fallback, barcode_rules, include_header, columns, delimiter,
   file_extension, file_name_pattern, bom, trailing_newline, import_behaviour,
   mode, created_by)
select true, null, s.code, s.name, s.description, s.verified, s.identifier_type,
       s.identifier_fallback, s.barcode_rules, s.include_header, s.columns,
       s.delimiter, s.file_extension, s.file_name_pattern, s.bom,
       s.trailing_newline, s.import_behaviour, s.mode, null
  from jsonb_to_recordset($hl_seed$[
    {
      "code": "hl_test_a",
      "name": "H&L trial A: comma",
      "description": "A trial file for working out which layout H&L Stock accepts for a BHT import: barcode, a comma, then the count, one line per product. Import it into a test stocktake in H&L and discard that stocktake afterwards. H&L adds imported counts to the stocktake, so never import the same file twice.",
      "verified": false,
      "identifier_type": "barcode",
      "identifier_fallback": null,
      "barcode_rules": {"leading_zero": "keep", "trim": true},
      "include_header": false,
      "columns": [
        {"header": "barcode", "source": "identifier"},
        {"header": "count", "source": "quantity"}
      ],
      "delimiter": ",",
      "file_extension": "dat",
      "file_name_pattern": "gantry-{location}-{stocktake}-{date}-hl-a",
      "bom": false,
      "trailing_newline": true,
      "import_behaviour": "add",
      "mode": "generate"
    },
    {
      "code": "hl_test_b",
      "name": "H&L trial B: tab",
      "description": "A trial file for working out which layout H&L Stock accepts for a BHT import: barcode, a tab, then the count, one line per product. Import it into a test stocktake in H&L and discard that stocktake afterwards. H&L adds imported counts to the stocktake, so never import the same file twice.",
      "verified": false,
      "identifier_type": "barcode",
      "identifier_fallback": null,
      "barcode_rules": {"leading_zero": "keep", "trim": true},
      "include_header": false,
      "columns": [
        {"header": "barcode", "source": "identifier"},
        {"header": "count", "source": "quantity"}
      ],
      "delimiter": "\t",
      "file_extension": "dat",
      "file_name_pattern": "gantry-{location}-{stocktake}-{date}-hl-b",
      "bom": false,
      "trailing_newline": true,
      "import_behaviour": "add",
      "mode": "generate"
    },
    {
      "code": "hl_test_c",
      "name": "H&L trial C: fixed width, spaces",
      "description": "A trial file for working out which layout H&L Stock accepts for a BHT import: the barcode in 13 characters, then the count right-aligned in 6, padded with spaces, one line per product. Import it into a test stocktake in H&L and discard that stocktake afterwards. H&L adds imported counts to the stocktake, so never import the same file twice.",
      "verified": false,
      "identifier_type": "barcode",
      "identifier_fallback": null,
      "barcode_rules": {"leading_zero": "keep", "trim": true},
      "include_header": false,
      "columns": [
        {"header": "barcode", "source": "identifier", "width": 13, "align": "left", "pad": " "},
        {"header": "count", "source": "quantity", "width": 6, "align": "right", "pad": " "}
      ],
      "delimiter": "",
      "file_extension": "dat",
      "file_name_pattern": "gantry-{location}-{stocktake}-{date}-hl-c",
      "bom": false,
      "trailing_newline": true,
      "import_behaviour": "add",
      "mode": "generate"
    },
    {
      "code": "hl_test_d",
      "name": "H&L trial D: fixed width, zeros",
      "description": "A trial file for working out which layout H&L Stock accepts for a BHT import: the barcode in 13 characters, then the count right-aligned in 6, padded with zeros, one line per product. Import it into a test stocktake in H&L and discard that stocktake afterwards. H&L adds imported counts to the stocktake, so never import the same file twice.",
      "verified": false,
      "identifier_type": "barcode",
      "identifier_fallback": null,
      "barcode_rules": {"leading_zero": "keep", "trim": true},
      "include_header": false,
      "columns": [
        {"header": "barcode", "source": "identifier", "width": 13, "align": "left", "pad": " "},
        {"header": "count", "source": "quantity", "width": 6, "align": "right", "pad": "0"}
      ],
      "delimiter": "",
      "file_extension": "dat",
      "file_name_pattern": "gantry-{location}-{stocktake}-{date}-hl-d",
      "bom": false,
      "trailing_newline": true,
      "import_behaviour": "add",
      "mode": "generate"
    }
  ]$hl_seed$::jsonb) as s(
    code text, name text, description text, verified boolean,
    identifier_type text, identifier_fallback text, barcode_rules jsonb,
    include_header boolean, columns jsonb, delimiter text, file_extension text,
    file_name_pattern text, bom boolean, trailing_newline boolean,
    import_behaviour text, mode text)
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
  trailing_newline = excluded.trailing_newline,
  import_behaviour = excluded.import_behaviour,
  mode = excluded.mode;

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- 1. the column, false everywhere except the four trials:
--   select code, file_extension, delimiter = '' as fixed_width, trailing_newline, verified
--     from public.export_templates where is_system order by code;
--   -- expect: bepoz/full/standard  csv  false  false  true
--   --         hl_test_a  dat  false  true  false
--   --         hl_test_b  dat  false  true  false
--   --         hl_test_c  dat  true   true  false
--   --         hl_test_d  dat  true   true  false
--
--   -- 2. the widened checks still refuse an org template (run as an owner;
--   --    both must fail with a check violation, 23514):
--   --   POST /rest/v1/export_templates {"name":"x","pos_system":"hl","columns":[...],"file_extension":"dat"}
--   --   POST /rest/v1/export_templates {"name":"y","pos_system":"hl","columns":[...],"delimiter":""}
--
--   -- 3. trailing_newline is not client-writable:
--   --   PATCH /rest/v1/export_templates?id=eq.<own template> {"trailing_newline": true}
--   --   -> 42501 permission denied
-- ---------------------------------------------------------------------------

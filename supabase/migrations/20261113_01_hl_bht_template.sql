-- ===========================================================================
-- The H&L Stock export, and the end of the four H&L trials.
--
-- Data only: one system template upserted, any org on a trial moved onto it,
-- the four trials deleted. No column, constraint or function changes, and no
-- app.html change goes with it (the engine already writes .dat and fixed
-- width since 20261111_01), so it can be applied at any time. Safe to run
-- twice. Mirrored into schema.sql, including an identical copy of $hl_seed$.
-- ===========================================================================
--
-- What H&L Stock's PDE import (PDE Type = BHT) reads, worked out from its own
-- PDE logs over two evenings of test imports on a venue's live H&L server
-- (Eddie, 11 and 12 Nov 2026; the files and logs are in James's email):
--
--   * The barcode is characters 1-16 of the line, spaces trimmed. Trial D's
--     line "2000000000015000041" logged barcode "2000000000015000" (16) and
--     count "041"; trials A and B logged the whole line as the barcode.
--   * The count is characters 17-22, spaces trimmed, either side. A count
--     right-aligned in 8 came back empty (all 6 characters it read were
--     spaces); "1234567.75" came back "123456". Everything past 22 is ignored.
--   * Decimals are accepted: 12.5 against a real product logged Count: 12.50.
--   * H&L converts pack sizes itself: 31 of a carton barcode logged 744 (CTN,
--     24), so a carton counted in Gantry as 1 is right.
--
-- Trial C (barcode in 13, count right-aligned in 6) imported correctly, but
-- only because its counts were short: its count sits at characters 14-19, so a
-- count of 4 or more characters (12.5, 1000, 10.25) on a 13-digit barcode ran
-- into the barcode field and the line was lost. Never bring it back.
--
-- So: hl_bht. Barcode left-aligned in 16, count right-aligned in 6, both
-- padded with spaces; CRLF with a final CRLF, no header, no BOM, barcodes as
-- scanned. Every line is exactly 22 characters.
--
-- A value too long for its field is never cut (export-engine.js fixedField
-- sends it whole and reports it in `overflow`, which the download toast names).
-- For this template that means a barcode over 16 characters, or a count over 6
-- (1000.25, 12345.5). H&L would misread that line, so the toast is the warning.
--
-- verified stays false until a real Gantry count, exported with this template,
-- has imported cleanly into a test stocktake in H&L. Then:
--   update public.export_templates set verified = true where is_system and code = 'hl_bht';
-- (verified is server-only, and is not in the seed's upsert path for that
-- reason: re-running this file must not un-verify it. See section 1.)
--
-- Orgs that picked a trial are moved onto hl_bht rather than left to fall back
-- to their legacy mapping (export_template_id is ON DELETE SET NULL), because
-- an org that chose an H&L file wants the H&L file. The legacy columns are
-- mirrored exactly as set_export_template() would for this template.
-- stocktakes.last_export_template_id and export_template_submissions.template_id
-- that point at a trial go NULL on the delete; the submissions keep their
-- template_snapshot.
--
-- 20261111_01 still inserts the four trials if it is re-run on its own. Don't.

-- ---------------------------------------------------------------------------
-- 1. The H&L template.
--
-- The JSON between the $hl_seed$ markers is ALSO read by
-- scripts/test-export-engine.js, which checks the file it builds against what
-- H&L's import logs showed it reading, and requires the same block, unchanged, in
-- schema.sql. Upsert on code. `verified` is set on insert only.
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
      "code": "hl_bht",
      "name": "H&L Stock (BHT)",
      "description": "For H&L Stock's PDE import with PDE Type set to BHT: the barcode in the first 16 characters, then the count in the next 6, one line per product. Count cartons and packs as their own barcode; H&L converts them. H&L adds imported counts to the stocktake, so never import the same file twice. A count longer than 6 characters, such as 1000.25, does not fit and is flagged when you export.",
      "verified": false,
      "identifier_type": "barcode",
      "identifier_fallback": null,
      "barcode_rules": {"leading_zero": "keep", "trim": true},
      "include_header": false,
      "columns": [
        {"header": "barcode", "source": "identifier", "width": 16, "align": "left", "pad": " "},
        {"header": "count", "source": "quantity", "width": 6, "align": "right", "pad": " "}
      ],
      "delimiter": "",
      "file_extension": "dat",
      "file_name_pattern": "gantry-{location}-{stocktake}-{date}-hl",
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
-- 2. Orgs on a trial move to hl_bht. Same mirror as set_export_template():
-- not 'full', so 'standard'; leading_zero 'keep', so no strip.
-- ---------------------------------------------------------------------------
update public.organisations o
   set export_template_id = h.id,
       export_format = 'standard',
       strip_leading_zero = false
  from public.export_templates h
 where h.is_system and h.code = 'hl_bht'
   and o.export_template_id in (
     select id from public.export_templates
      where is_system and code in ('hl_test_a', 'hl_test_b', 'hl_test_c', 'hl_test_d'));

-- ---------------------------------------------------------------------------
-- 3. The four trials go.
-- ---------------------------------------------------------------------------
delete from public.export_templates
 where is_system and code in ('hl_test_a', 'hl_test_b', 'hl_test_c', 'hl_test_d');

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- 1. four system templates, the trials gone:
--   select code, file_extension, delimiter = '' as fixed_width, trailing_newline, verified
--     from public.export_templates where is_system order by code;
--   -- expect: bepoz     csv  false  false  true
--   --         full      csv  false  false  true
--   --         hl_bht    dat  true   true   false
--   --         standard  csv  false  false  true
--
--   -- 2. its layout:
--   select columns from public.export_templates where is_system and code = 'hl_bht';
--   -- expect widths 16 and 6, align left and right, pad " " both
--
--   -- 3. who is on it (anyone who had picked a trial, moved here):
--   select o.name, o.export_format, o.strip_leading_zero
--     from public.organisations o
--     join public.export_templates t on t.id = o.export_template_id
--    where t.code = 'hl_bht';
--   -- expect export_format 'standard', strip_leading_zero false on every row
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- The H&L export is called just "H&L", and is verified.
--
-- Name: it was "H&L Stock (BHT)" (20261113_01). Now the picker shows "H&L",
-- the button "Export DAT (H&L)" and the download message "H&L export
-- downloaded". The description still says which H&L import it is for. The code
-- stays hl_bht, so nothing that looks a template up changes.
-- stocktakes.last_export_format keeps the old name on takes already exported;
-- that column is a record of what was used.
--
-- Verified (James, 19 Nov 2026): on 18 Nov two counts exported straight from
-- Gantry with this template were imported into H&L, and H&L read every line
-- exactly, barcode and count, an 8-digit barcode and part bottles included.
-- Real products had already matched in the same layout (12 Nov). Verified
-- drops "unverified" from the pickers, the note under Export, and the
-- first-import question after an export.
--
-- Data only, one row. No app.html change. Safe to run twice, and at any time.
-- 20261113_01 and schema.sql carry the new name and verified = true in their
-- $hl_seed$ block too, so a re-run or a rebuild matches.
-- ===========================================================================

update public.export_templates
   set name = 'H&L',
       verified = true
 where is_system and code = 'hl_bht';

-- ---------------------------------------------------------------------------
-- Verify:
--
--   select code, name, verified from public.export_templates where is_system order by code;
--   -- expect hl_bht  H&L  true (bepoz, full, standard unchanged, all true)
--
--   -- any venue's own template also called H&L would sit beside it in that
--   -- venue's picker with the same label; expect no rows:
--   select org_id, name from public.export_templates
--    where not is_system and lower(btrim(name)) = 'h&l';
-- ---------------------------------------------------------------------------

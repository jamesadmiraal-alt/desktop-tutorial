-- Allow 'bepoz' as an organisation's export format.
--
-- Why: the first on-site trial (Colac Port Adl, Cellars, 20 Aug 2026) exported a
-- Gantry CSV into Bepoz and every line came back "## No Product Match ##". The
-- cause was column alignment, not bad data — Bepoz reads
--
--   CSV column 1 -> Barcode
--   CSV column 2 -> Count
--
-- takes the store from its own import profile, and treats a header row as data.
-- Gantry's export is `stocktake, barcode, qty, first_scanned, last_scanned`, so
-- Bepoz was comparing the stocktake NAME against its product barcodes, and
-- reading the real barcode as a quantity. Nothing could ever have matched.
--
-- The fix is a two-column, header-less export: barcode,qty. That is stored as an
-- org preference rather than asked on every export, because a venue uses the same
-- POS every time.
--
-- Additive and safe against a live project: the constraint only widens, so no
-- existing row can be made invalid. Mirrored into schema.sql.
--
-- Run BEFORE pushing the new app.html/admin.html — the console will offer 'bepoz'
-- as a choice, and the old constraint would reject it.

alter table public.organisations drop constraint if exists organisations_export_format_check;

-- 'myob'/'lightspeed' remain legal only so any existing row stays valid. Nothing
-- writes them and no UI offers them; both were unverified guesses, removed on
-- 2026-08-20. If either POS is ever confirmed, add a real builder instead of
-- reviving the value.
alter table public.organisations
  add constraint organisations_export_format_check
  check (export_format in ('full', 'bepoz', 'myob', 'lightspeed'));

-- ---------------------------------------------------------------------------
-- No GRANT change needed: export_format is already in the client-writable column
-- grant on organisations, and "owner update org" RLS already restricts writes to
-- the owner. log_organisations_change() already has an export_format branch, so
-- changes start appearing in the activity log with no trigger edit — that branch
-- has simply never fired before, because nothing ever set this column.
--
-- Verify:
--   update public.organisations set export_format = 'bepoz' where id = '<org>';
--   -- succeeds; and appears in the log:
--   select actor_label, before->>'export_format', after->>'export_format'
--     from public.audit_log where action = 'organisation.export_format_changed'
--    order by created_at desc limit 3;
--   update public.organisations set export_format = 'nonsense' where id = '<org>';
--   -- rejected by the check constraint

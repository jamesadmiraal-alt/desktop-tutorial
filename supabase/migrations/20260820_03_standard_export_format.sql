-- Rename the Bepoz export format to 'standard', and make it the first choice in
-- the admin console.
--
-- Why: the format was built for Bepoz and verified against Bepoz, but
-- `barcode,count` with no header is the shape stock importers generally want.
-- Naming it after one vendor would make the next customer on a different POS
-- assume it doesn't apply to them. The Bepoz evidence stays in the comments;
-- only the name changes.
--
-- SUPERSEDES 20260820_02_bepoz_export_format.sql, and is written so it does not
-- matter whether that one was ever run:
--   * it drops the constraint by name with `if exists`, so a missing one is fine;
--   * the new constraint lists every value either version allowed;
--   * the UPDATE is a no-op when no row holds 'bepoz'.
-- Safe to run twice. Additive to the constraint — the value set only ever grows
-- here, so no existing row can be invalidated. Mirrored into schema.sql.
--
-- Run BEFORE deploying the new app.html/admin.html: the console will PATCH
-- export_format = 'standard', and neither the original constraint nor the 02
-- version permits that value.

alter table public.organisations drop constraint if exists organisations_export_format_check;

alter table public.organisations
  add constraint organisations_export_format_check
  check (export_format in ('full', 'standard', 'bepoz', 'myob', 'lightspeed'));

-- Move any org already switched to Bepoz onto the new name. No behaviour change:
-- both values produce byte-identical files, because app.html aliases 'bepoz' to
-- the same builder.
update public.organisations
   set export_format = 'standard'
 where export_format = 'bepoz';

-- ---------------------------------------------------------------------------
-- NOTE ON 'bepoz' STAYING LEGAL
--
-- The UPDATE above clears it out today, so it is tempting to drop it from the
-- constraint. Don't, yet. app.html deliberately aliases 'bepoz' to the standard
-- builder, and that alias is the only thing standing between a restored-from-
-- backup row and a silent regression: without it the org falls back to 'full',
-- gets the 5-column file, and every line comes back "## No Product Match ##" —
-- the original bug, with nothing on screen to explain it. Remove the value and
-- the alias together, or neither.
--
-- ---------------------------------------------------------------------------
-- Verify:
--   select export_format, count(*) from public.organisations group by 1;
--   -- expect 'standard' and/or 'full'; no 'bepoz' left
--
--   update public.organisations set export_format = 'standard' where id = '<org>';
--   -- succeeds
--   update public.organisations set export_format = 'nonsense' where id = '<org>';
--   -- rejected by the check constraint
--
--   -- and the change is logged, via the existing log_organisations_change branch:
--   select actor_label, before->>'export_format', after->>'export_format'
--     from public.audit_log where action = 'organisation.export_format_changed'
--    order by created_at desc limit 3;

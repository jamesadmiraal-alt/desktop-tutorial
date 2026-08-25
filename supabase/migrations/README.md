# Migrations

`schema.sql` at the repo root is a **full rebuild** — it drops every app table and
is guarded to refuse to run against a project that already has an organisation.
It is the description of a finished database, not a way to change a live one.

These files are how a live project actually changes. Each is additive and safe to
run once against `vfixdchbkmqryfhirphx` (the project named **BarScan** in the
Supabase dashboard — that is Gantry; `zythshvfgphkwwfborvb`/BarberBook is a
different product, don't paste into it).

## Rules

1. **Every statement here must also be mirrored into `schema.sql`** at the
   matching place, so a deliberate rebuild produces the same database. This is
   the step that gets forgotten, and it silently reverts things — the
   `revoke delete on stocktake_items` especially, since Supabase's default
   privileges re-grant DELETE on every freshly created table.
2. Run them in filename order. Never re-order or edit a file that has already
   been run — add a new one.
3. Run in the Supabase SQL editor (Dashboard → SQL Editor → New query → Run), or
   `supabase db execute`. Check the project switcher reads **BarScan** first.
4. Deploy order per change: **SQL → Edge Functions → HTML.** A function or page
   that calls something not yet in the database fails for real users.

## Log

| File | What | Notes |
|---|---|---|
| `20260818_00_role_guard_fixes.sql` | NULL-role bypass in every plpgsql owner/manager guard; ambiguous `org_id` in `kick_user()` | Independent of 01/02, run any time. This is the un-applied SQL half of commit `b8b16a8` |
| `20260818_01_stocktake_audit.sql` | Enriched delete logging, `delete_stocktake_items()`, owner/manager guard on `clear_stocktake_items()`, `qty_reduced` trigger | Run **before** deploying the new `app.html` |
| `20260818_02_revoke_item_delete.sql` | Revokes client DELETE on `stocktake_items` | Run **only after** the new `app.html` is live — it removes the path the old page uses |
| `20260818_03_seat_minimum_term.sql` | `organisations.seats_increased_at` + `enforce_seat_minimum_term()` trigger | Run **before** deploying `set-seat-count` — the function selects the new column |
| `20260818_04_seat_denial_notification.sql` | `organisations.seats_full_notified_at` + `record_seat_denial()` | Run **before** deploying `notify-seat-denied` |
| `20260819_01_stocktake_status.sql` | `status` check constraint + `set_stocktake_status()` | Run **before** pushing the new `app.html` |
| `20260819_02_revoke_stocktake_update.sql` | Revokes client UPDATE on `stocktakes` | Run **only after** the new `app.html` is live — the old page flips status directly on export |
| `20260819_03_one_device_per_login.sql` | `active_sessions.device_id`, device-aware `claim_seat`/`heartbeat` | Shims it created were dropped 2026-08-19; don't re-run those blocks |
| `20260820_01_decimal_qty.sql` | `qty` → `numeric(12,2)`, `check (qty >= 0)`, numeric accumulators | Run **before** pushing the new `app.html`. Rewrites the table, so run it when nobody is mid-count |
| `20260820_02_bepoz_export_format.sql` | Allowed `export_format = 'bepoz'` | **Superseded by 03** — skip it and run 03 instead, which covers both. Harmless if it was already run |
| `20260820_03_standard_export_format.sql` | Renames that format to `'standard'` and migrates any `'bepoz'` row | Run **before** pushing the new `app.html`/`admin.html`. Safe whether or not 02 ran, and safe to run twice |
| `20260820_04_default_standard_export.sql` | `export_format` column default `'full'` → `'standard'` | Order doesn't matter — no page reads the default. Metadata-only, touches no existing row |
| `20260824_01_archive_venues_locations.sql` | `archived_at` on venues/locations, `set_venue_archived()`/`set_location_archived()`, column GRANTs, three insert policies narrowed | Run **before** pushing the new `app.html`/`admin.html`. Safe against the deployed page — renaming still works, since the GRANT keeps `name` writable |

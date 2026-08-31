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
| `20260830_01_merge_concurrent_scans.sql` | `add_stocktake_item()` + `set_stocktake_item_qty()` — two people scanning one barcode now merge instead of hitting the unique constraint | Run **before** pushing the new `app.html` (it calls both; until they exist every save 404s as PGRST202). Purely additive, and the deployed page never calls them, so it can be run early |
| `20260830_02_stepper_delta.sql` | `add_stocktake_item()` accepts a **negative** delta and clamps the result at 0, so the −/+ steppers can send ±1 instead of an absolute qty | Run **before** pushing. `create or replace`, same signature. Safe against the deployed page, which only ever sends a non-negative delta and is unaffected by the clamp |
| `20260831_01_completed_is_immutable.sql` | `enforce_stocktake_not_completed()` trigger — no insert/update/delete on `stocktake_items` once the parent stocktake is `completed` | Order doesn't matter, and running it **early** is better: it closes the hole for the deployed page too. A trigger, not RLS, because the item RPCs are security definer and bypass policies |
| `20260831_02_unique_open_stocktake_name.sql` | One **open** stocktake per name per org — trigger with an advisory lock, plus a partial unique index attempted where the data allows | Run **before** pushing. Renames/merges nothing: the existing duplicate "Stress test 2" rows are grandfathered and stay usable, and the index step self-skips with a NOTICE while they exist |
| `20260831_03_pos_interest.sql` | `pos_interest` table for the landing-page POS form — insert-only for `anon`, no select policy | Independent of the app. Not mirrored into `schema.sql` on purpose: a rebuild would drop real submissions |
| `20260831_04_single_venue_is_one_user.sql` | Single-venue = the owner alone. Plan gates in `join_organisation()`, `add_team_member()` and `claim_seat()` | Run **before** pushing the new `app.html`/`index.html`. Three `create or replace` only — no table, policy or data changes, and **no memberships are deleted**: a leftover extra member is locked out at login, not removed |
| `20260831_05_trial_tier.sql` | The trial: `'trial'` plan tier, new orgs start there **with a venue and a `Main` location**, `enforce_trial_scan_limit()` capping 5 products per stocktake, plus `profiles.marketing_opt_in` captured at signup | Run **before** pushing the new `app.html`/`index.html`, which offer the consent checkbox and the trial wall. Additive — one widened check, two new columns, three `create or replace`, one trigger. **Existing `'pending'` orgs are deliberately NOT converted** (they have no venue, so they'd get a trial with nowhere to scan) — the SQL shape is in the file if you want to |

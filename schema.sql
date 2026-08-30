-- Gantry schema for Supabase — organisation-based multi-tenant model
-- Run this once in your Supabase project: Dashboard -> SQL Editor -> New query -> paste -> Run
--
-- *** DO NOT RUN THIS WHOLE FILE AGAINST THE LIVE PROJECT. ***
--
-- It was written as a CLEAN REPLACEMENT of the earlier per-user schema, not an
-- additive migration: the `drop table ... cascade` run immediately below the
-- safety guard drops and recreates every app table.
-- That was safe when there was no production data to preserve. That is NO
-- LONGER TRUE — vfixdchbkmqryfhirphx now has a real organisation, memberships
-- and user accounts. Re-running this as-is deletes all of it.
--
-- A guard at the top now enforces this rather than relying on you reading it:
-- the DO block below the header aborts the script if public.organisations has
-- any rows, so a stray paste fails immediately and explains itself instead of
-- silently wiping the project. Comment that block out to rebuild deliberately.
--
-- The other trap, which the guard does NOT undo — worth knowing if a wipe ever
-- does happen:
--   * auth.users is NOT dropped here, but public.profiles IS. So a re-run
--     leaves every existing login intact while wiping its profile row, and
--     handle_new_user() only fires for NEW signups — the rows never come back
--     on their own. Symptom: operators with no display name, and existing
--     accounts landing on the "Set up your organisation" screen.
--     Backfill with:
--       insert into public.profiles (id, full_name)
--       select u.id, u.raw_user_meta_data->>'full_name' from auth.users u
--       where not exists (select 1 from public.profiles p where p.id = u.id);
--
-- To change the schema from here on: write a real migration (e.g.
-- add-column-with-backfill, or a single CREATE POLICY) and run only that.

-- ==========================================================================
-- SAFETY GUARD — deliberately the first executable statement in this file.
--
-- Aborts the whole script if this project already has a real organisation,
-- rather than trusting whoever pasted it to have read the warning above. The
-- SQL editor batches a script into one implicit transaction, so raising here
-- rolls back everything: none of the drops below run.
--
-- This replaces a safety net that used to exist by accident — a re-run died
-- partway on a foreign-key violation, and the same implicit-transaction
-- rollback undid the drops. The orphan sweeps further down (audit_log /
-- active_sessions) fixed that violation, which also removed the accident. This
-- guard is the intentional version, and it fails EARLY and says why, instead of
-- failing late with a 23503 that reads like an unrelated validation error.
--
-- to_regclass() rather than a bare EXISTS: on a genuinely fresh project the
-- table doesn't exist yet, and querying a missing table would raise the wrong
-- error and block the legitimate first run.
--
-- TO INTENTIONALLY WIPE AND REBUILD: comment out this whole DO block. That is
-- meant to be a conscious act with a backup taken first (Dashboard -> Database
-- -> Backups), not something you can do by pasting the file out of habit.
-- ==========================================================================
do $$
begin
  if to_regclass('public.organisations') is not null
     and exists (select 1 from public.organisations) then
    raise exception using
      errcode = 'raise_exception',
      message = 'schema.sql refused to run: public.organisations already has data.',
      detail  = 'This file DROPS every app table (profiles, organisations, venues, '
                || 'locations, memberships, stocktakes, stocktake_items) and would '
                || 'delete that organisation, its team and all of its stocktakes.',
      hint    = 'To change the live schema, run only the specific statements you '
                || 'need (a CREATE POLICY, an ALTER TABLE ... ADD COLUMN with a '
                || 'backfill). To intentionally rebuild from scratch, take a '
                || 'backup and comment out the DO block at the top of this file.';
  end if;
end $$;

-- ---- Profiles: one row per user, personal identity only ----
-- No billing/plan fields here any more — those are now on `organisations`,
-- since billing is org-scoped, not user-scoped. See `organisations` below.
drop table if exists public.stocktake_items cascade;
drop table if exists public.stocktakes cascade;
drop table if exists public.memberships cascade;
drop table if exists public.locations cascade;
drop table if exists public.venues cascade;
drop table if exists public.organisations cascade;
drop table if exists public.profiles cascade;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,   -- set at signup, for audit/history reference (who did a stocktake)
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
-- The actual "read own or org profile" policy is created further down,
-- after public.memberships exists — it references that table in a
-- subquery, and CREATE POLICY validates its SQL immediately, so it can't
-- be declared before the table it depends on exists yet.
-- No insert policy for clients: the row is only ever created by the
-- handle_new_user() trigger below. Updates ARE allowed, but only to your own
-- row and only to full_name — see the "update own profile" policy and its
-- column-scoped GRANT further down (same place as the read policy, and for
-- the same reason: it has to come after public.memberships exists).

-- ---- Organisations: the billing/tenant entity. Every stocktake and every
-- location belongs to one of these, not to a user. ----
create table public.organisations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  logo_url text,
  -- Which CSV shape this org's exports produce. In use again as of 2026-08-20,
  -- and this column's history is worth knowing before changing it: it sat unread
  -- for weeks (the format was picked per-export from a dialog instead), the
  -- dialog's MYOB/Lightspeed presets were deleted as unverified guesses, and then
  -- an on-site trial at a real venue produced the actual requirement.
  --
  -- Bepoz reads CSV column 1 as Barcode and column 2 as Count, takes the store
  -- from its own import profile, and treats a header row as data. Gantry's own
  -- 5-column export therefore matched nothing at all — it was feeding the
  -- stocktake NAME in as a barcode. See buildStandardCsv() in app.html.
  --
  -- An org preference rather than a per-export choice because a venue uses the
  -- same POS every time; making them pick on every export would be friction with
  -- one right answer. Owner-settable (this column IS in the client-writable GRANT
  -- below) and changes are logged by log_organisations_change().
  --
  -- Values, and why there are five for two formats:
  --   'standard'   barcode,count with no header — the two-column shape above.
  --   'bepoz'      the SAME format under its original name. Kept legal, and
  --                aliased in app.html's EXPORT_FORMATS, so a row written before
  --                the 2026-08-20 rename (or restored from a backup taken then)
  --                still produces the right file. Drop this only after confirming
  --                no row holds it — otherwise such an org silently falls back to
  --                'full' and its imports start matching nothing again.
  --   'full'       Gantry's own 5-column CSV, for Excel and for humans.
  --   'myob',
  --   'lightspeed' legal ONLY so any pre-existing row stays valid. Nothing
  --                produces them, no UI offers them, and both were unverified
  --                guesses. If either POS is ever properly verified, add a real
  --                builder rather than reviving the value.
  --
  -- Default is 'standard' (changed from 'full' on 2026-08-20). A new venue is
  -- signing up to get counts into its POS, and the format that does that should
  -- not be something they have to know to go and switch on — the first trial
  -- failed precisely because the shape was wrong and nothing said so. An org that
  -- wants the 5-column file for Excel can pick it.
  --
  -- This affects only NEWLY created orgs. create_organisation() doesn't name the
  -- column (see below), so the default is what it gets. Note this is NOT the same
  -- as the unknown-value fallback in app.html's exportFormat(), which stays 'full'
  -- on purpose: that path exists for legacy 'myob'/'lightspeed' rows, and pointing
  -- it at 'standard' would silently change the export shape for an org that never
  -- asked for it.
  export_format text not null default 'standard'
    check (export_format in ('full', 'standard', 'bepoz', 'myob', 'lightspeed')),
  -- No free tier — a brand-new org starts 'pending' (created, but blocked
  -- from doing anything real: no locations exist yet, so no stocktakes can
  -- exist either — see the locations insert policy below) until the owner
  -- completes checkout for 'single' or 'multi'. stripe-webhook flips this
  -- and creates the org's first location together, on checkout.session.completed.
  plan_tier text not null default 'pending'
    check (plan_tier in ('pending', 'single', 'multi')),

  -- Billing country, moved here from profiles.country — it's what currency
  -- checkout uses, and checkout is now an org-level action. Same 30-day
  -- change cooldown as before, just re-pointed (see enforce_country_cooldown
  -- below); only meaningful once the org actually has billing to protect.
  country text,
  country_changed_at timestamptz,

  -- Written only by the stripe-webhook edge function / by hand in the
  -- dashboard — never client-writable (see the column-scoped GRANT below).
  stripe_customer_id text,
  stripe_subscription_id text,
  -- The subscription item whose `quantity` tracks this org's location
  -- count for the multi-venue tier (first location included in the base
  -- price, each additional one billed via Stripe's graduated pricing).
  -- Irrelevant/null for free and single-venue orgs.
  stripe_subscription_item_id text,

  -- Durable, owner-rotatable — one half of the two-factor join code.
  join_code text not null unique,
  -- The other half: changes daily, only ever shown live in admin.html.
  -- Lazily regenerated by get_daily_code() below rather than a cron job —
  -- null/stale until the first time someone with owner/manager role opens
  -- the roster screen on a given day.
  daily_code text,
  daily_code_date date,

  -- Bumped whenever the owner opens the roster screen; lets admin.html
  -- highlight memberships created after that (new-member notification,
  -- with no email/push infrastructure needed).
  roster_last_viewed_at timestamptz,

  -- Multi-venue billing: venues/locations are unlimited and free — the
  -- billable unit is concurrent seats instead (see active_sessions,
  -- claim_seat() below). Extra seats purchased beyond the owner (who's
  -- always free — see claim_seat()); single-venue orgs ignore this
  -- entirely (unlimited staff, no seat pool). Deliberately NOT in the
  -- client-writable column GRANT below — same protected treatment as
  -- plan_tier/stripe_customer_id, since it's a billing number tied to a
  -- real Stripe charge, not a preference. Only set-seat-count (Edge
  -- Function, service role, after the matching Stripe PATCH succeeds)
  -- may write it.
  concurrent_seats integer not null default 0,
  -- When the current seat level was last INCREASED. Structurally the same idea
  -- as country_changed_at above, for the same kind of reason: a purchased seat
  -- is billed for a minimum of one month, so an owner must not be able to add
  -- seats for a busy weekend and drop them on the Monday. Stamped by
  -- enforce_seat_minimum_term() below, never by a client — and unlike
  -- country_changed_at it isn't even reachable from one, since concurrent_seats
  -- itself is outside the column GRANT and only set-seat-count (service role)
  -- writes it. Triggers still fire for service-role writes even though RLS
  -- doesn't apply, and that asymmetry is the whole enforcement mechanism.
  --
  -- NULL means "no commitment on record" — a brand-new org, or one whose seats
  -- were set by hand before this column existed. Decreases are free in that case.
  seats_increased_at timestamptz,
  -- When the owner was last emailed that someone hit the seat limit. Throttles
  -- that email to once per window — a venue at its limit denies people
  -- repeatedly (every staff member arriving for the same shift), and the owner
  -- needs telling once, not once per attempt. Read and written inside
  -- record_seat_denial() so the decision and the stamp are atomic; two devices
  -- denied in the same second must not both trigger a send. The seat.denied
  -- audit rows are deliberately NOT throttled.
  seats_full_notified_at timestamptz,
  -- How often (seconds) a logged-in client checks in via heartbeat() —
  -- governs both how quickly a stale/crashed session frees its seat and
  -- how quickly an owner's kick_user() call actually takes effect on the
  -- kicked device (2.5x this value — see claim_seat()/heartbeat()).
  -- Owner-adjustable trade-off (faster response vs. request volume), so
  -- unlike concurrent_seats above, this IS a preference — plain
  -- client-writable column (see the GRANT below) with audit coverage
  -- via log_organisations_change().
  heartbeat_interval_seconds integer not null default 60
    check (heartbeat_interval_seconds >= 10),

  created_at timestamptz not null default now()
);

-- ---- Venues: the plan-tier boundary lives here now — single-venue orgs
-- get exactly one of these, ever; multi-venue is unlimited. Locations
-- underneath a venue carry no billing consequence on any tier any more
-- (unlimited, free — see the locations insert policy below, where the old
-- per-tier location cap used to live before this layer existed).
-- Concretely: single-tier goes from "1 location, period" to "1 venue,
-- unlimited locations within it". ----
create table public.venues (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  name text not null,
  -- Retire a venue without destroying its count history — the "we sold the
  -- pub" case. Null means active.
  --
  -- Deleting such a venue is impossible by design, and that is not an
  -- oversight to route around: stocktakes.location_id is `on delete restrict`
  -- (see below) and locations.venue_id cascades from here, so a venue with any
  -- counted location cannot be deleted without shredding the count records.
  -- Archiving is the answer to "remove it" for anything that has been used;
  -- plain DELETE still works, and is still the right call, for a venue created
  -- by mistake and never counted against.
  --
  -- Only set_venue_archived() writes this — UPDATE is granted per-column below
  -- and this column is NOT in that grant, so the RPC's owner-only check and its
  -- audit row cannot be bypassed by a plain PATCH.
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  unique (org_id, name)
);

-- ---- Locations: pre-created spots within a venue that staff scan against.
-- Staff can only start stocktakes at locations that already exist here
-- (enforced in the stocktakes insert policy below), not invent their own on
-- the fly. ----
create table public.locations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  name text not null,
  -- Same idea as venues.archived_at, and the two compose rather than cascade.
  --
  -- Archiving a VENUE deliberately does NOT stamp its locations. A location is
  -- *effectively* archived when
  --   locations.archived_at is not null OR venues.archived_at is not null
  -- and every read filters on both. If archiving a venue stamped its children,
  -- restoring that venue could no longer tell "archived because its venue was"
  -- from "already archived on its own beforehand", and would wrongly revive the
  -- second kind. One stamp per decision keeps restore exact.
  --
  -- Only set_location_archived() writes this — see the column GRANT below.
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  unique (venue_id, name)
);

-- ---- Memberships: who belongs to which org, and with what role.
-- unique(user_id) enforces one org per user (deliberate simplification —
-- no active-org switcher needed; see the planning doc for the tradeoff). ----
create table public.memberships (
  org_id uuid not null references public.organisations(id) on delete cascade,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  role text not null default 'staff'
    check (role in ('owner', 'manager', 'staff')),
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);

-- Own profile, plus any teammate's — needed so "started by X" can show a
-- name on a shared stocktake, and the org roster can show who's who. Not
-- sensitive: display names are the kind of thing already visible to
-- teammates in any team tool. Declared here (not up with the rest of
-- profiles' setup above) because it references this table, and CREATE
-- POLICY validates its SQL immediately — it can't be declared before the
-- table it depends on exists.
create policy "read own or org profile" on public.profiles
  for select using (
    auth.uid() = id
    or exists (
      select 1 from public.memberships mine
        join public.memberships theirs on theirs.org_id = mine.org_id
       where mine.user_id = auth.uid() and theirs.user_id = profiles.id
    )
  );

-- Set your OWN display name (👤 Account → Your name in app.html). Editing
-- anyone ELSE's name stays owner-only and goes through the
-- update-team-member Edge Function instead, which is also why this is scoped
-- to auth.uid() = id on both sides: without the `with check` half, a client
-- could satisfy `using` on their own row and then reassign it to someone
-- else's id. The column GRANT below is what keeps this to full_name only, so
-- created_at/id aren't client-writable even on your own row.
create policy "update own profile" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

revoke update on public.profiles from authenticated;
grant update (full_name) on public.profiles to authenticated;

-- ---- Helper functions used throughout RLS below ----
-- security definer (like the existing enforce_country_cooldown/
-- handle_new_user pattern) specifically to avoid RLS recursion: a policy on
-- `memberships` that queried `memberships` directly to know who's asking
-- would otherwise need to evaluate its own RLS to answer that query.
create or replace function public.my_org_id()
returns uuid language sql stable security definer set search_path = public as $$
  select org_id from public.memberships where user_id = auth.uid();
$$;

create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.memberships where user_id = auth.uid();
$$;

-- ---- Stocktakes ----
create table public.stocktakes (
  id uuid primary key default gen_random_uuid(),
  -- Denormalized alongside location_id (rather than only derivable via a
  -- join) so every RLS policy below is a flat equality check, not a join —
  -- standard multi-tenant RLS practice. Defaults via my_org_id() the same
  -- way the old schema defaulted user_id via auth.uid() — the client never
  -- needs to pass this explicitly.
  org_id uuid not null default public.my_org_id() references public.organisations(id) on delete cascade,
  -- Must be one of the org's pre-created locations (checked in the insert
  -- policy below, since a plain FK can't also verify same-org). No default:
  -- the operator has to actively choose a location.
  location_id uuid not null references public.locations(id) on delete restrict,
  -- Audit only, not a security predicate — `on delete set null` so a staff
  -- member's account deletion doesn't take the org's stocktake with it.
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  name text not null,
  -- The workflow head office watches. 'ready_for_export' is the load-bearing
  -- one: before it existed, a finished-but-unexported count was indistinguishable
  -- from one still being counted, so the only way to know a venue had finished
  -- was to ask them.
  --
  --   in_progress      being counted (default for a new stocktake)
  --   ready_for_export the venue says counting is done — head office's cue
  --   completed        an export has happened
  --
  -- Now constrained, unlike the original schema which left this free text on the
  -- reasoning that the app was the only writer. Once a workflow depends on the
  -- value, an unconstrained column is a real bug rather than a latent one.
  -- Written only by set_stocktake_status() — client UPDATE on this table is
  -- revoked (see below the policies).
  status text not null default 'in_progress'
    check (status in ('in_progress', 'ready_for_export', 'completed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.stocktake_items (
  id uuid primary key default gen_random_uuid(),
  stocktake_id uuid not null references public.stocktakes(id) on delete cascade,
  org_id uuid not null default public.my_org_id() references public.organisations(id) on delete cascade,
  -- Who scanned this barcode in, and who last touched its qty — genuinely
  -- meaningful attribution now that any org member can write into any of
  -- the org's stocktakes (unlike the old user_id, which was always
  -- identical to the stocktake's own owner and so wasn't really usable as
  -- "who scanned this"). Neither is a security predicate; both `on delete
  -- set null` so departing staff don't take data with them.
  scanned_by uuid references auth.users(id) on delete set null default auth.uid(),
  last_scanned_by uuid references auth.users(id) on delete set null default auth.uid(),
  barcode text not null,
  -- numeric, not integer: bars count PART bottles. Spirits and wine sold by the
  -- glass are routinely half or a quarter full, and an operator eyeballing 0.4 of
  -- a bottle previously had to round to 1 (wrong) or 0 (which the old
  -- `check (qty >= 1)` rejected outright). 2 decimal places covers quarters,
  -- tenths and twentieths without implying precision an eyeball estimate doesn't
  -- have.
  --
  -- `>= 0`, not `>= 1`: zero is a real and useful count — "I checked this line and
  -- there are none" is different information from "never scanned it", and the old
  -- constraint made it unrecordable. Still not negative, which is never a count.
  --
  -- Anything reading this in JS must coerce with Number(): a numeric column can
  -- arrive as a string depending on serialisation, and `0 + "0.40"` is `"00.40"`,
  -- which would corrupt every total silently rather than throwing.
  qty numeric(12,2) not null check (qty >= 0),
  first_scanned timestamptz not null default now(),
  last_scanned timestamptz not null default now(),
  unique (stocktake_id, barcode)
);

create index stocktakes_org_idx on public.stocktakes (org_id, updated_at desc);
create index stocktakes_location_idx on public.stocktakes (location_id);
create index items_stocktake_idx on public.stocktake_items (stocktake_id);
create index items_org_idx on public.stocktake_items (org_id);

-- Keep the parent stocktake's updated_at fresh whenever its items change
create or replace function public.touch_stocktake()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.stocktakes
     set updated_at = now()
   where id = coalesce(new.stocktake_id, old.stocktake_id);
  return coalesce(new, old);
end $$;

create trigger touch_stocktake_on_items
  after insert or update or delete on public.stocktake_items
  for each row execute function public.touch_stocktake();

-- ---- Bootstrapping: profile row + org country-change cooldown ----
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data->>'full_name')
  on conflict do nothing;
  return new;
end $$;

-- auth.users itself is never dropped (Supabase-managed), so unlike every
-- other trigger in this file its old version survives a re-run and has to
-- be dropped explicitly — including the very first time this runs against
-- your current live project, which already has the old schema's copy.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Enforces the 30-day billing-country-change cooldown server-side (an
-- owner shouldn't be able to hop the org to a cheap-currency country right
-- before upgrading, then hop back) — re-pointed from profiles to
-- organisations, otherwise identical to the original. security definer
-- because the client is only granted UPDATE on the `country` column (see
-- the GRANT below), not `country_changed_at` — the trigger stamps that
-- regardless.
create or replace function public.enforce_country_cooldown()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.country is distinct from old.country then
    if old.country_changed_at is not null
       and old.country_changed_at > now() - interval '30 days' then
      raise exception 'Country can only be changed once every 30 days.';
    end if;
    new.country_changed_at := now();
  end if;
  return new;
end $$;

create trigger on_org_country_change
  before update on public.organisations
  for each row execute function public.enforce_country_cooldown();

-- Enforces the one-month minimum term on purchased concurrent seats, and it has
-- to live in Postgres for a reason RLS can't help with: the only writer of
-- concurrent_seats is set-seat-count using the SERVICE ROLE, which bypasses RLS
-- entirely. Triggers still fire for service-role writes, so this is the only
-- layer that can actually hold the line — a check in the Edge Function alone
-- would be bypassable by anything else holding that key.
--
-- One column is enough because the window restarts on every increase: after any
-- increase no decrease is permitted while the window is open, so the CURRENT
-- level is always exactly the committed floor. A separate "floor" column would
-- only be needed to allow partial decreases (8 down to 5), which would need
-- per-seat term accounting that Stripe's proration would also have to match.
--
-- Fires alongside enforce_country_cooldown on the same table and event; they
-- touch disjoint columns, so relative order is irrelevant.
create or replace function public.enforce_seat_minimum_term()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  eligible_at timestamptz := old.seats_increased_at + interval '30 days';
begin
  -- Leaving the multi-venue tier ends the commitment outright: the subscription
  -- item the seats were billed on is cancelled or swapped for the single-venue
  -- price, so there's nothing left to hold them to and Stripe has already
  -- settled the current period. Zeroing here also closes a pre-existing leak —
  -- stripe-webhook only ever PATCHes plan_tier, so a cancelled org previously
  -- kept concurrent_seats = N, and a later re-subscription billed Stripe
  -- quantity 1 while the database went on granting N seats.
  if old.plan_tier = 'multi' and new.plan_tier is distinct from 'multi' then
    new.concurrent_seats := 0;
    new.seats_increased_at := null;
    return new;
  end if;

  if new.concurrent_seats is distinct from old.concurrent_seats then
    if new.concurrent_seats > old.concurrent_seats then
      -- Re-stamp on every increase, including one inside an already-open window.
      -- Stricter than strict per-seat accounting (5 seats committed to day 30
      -- plus 3 more on day 10 becomes "8 until day 40"), but those extra seats
      -- genuinely are committed to day 40, seats aren't individually identified,
      -- and "you can't go below the level you last bought up to, for 30 days
      -- from that purchase" is the only rule that is both explainable to an
      -- owner and impossible to game. Matches enforce_country_cooldown's
      -- any-change-re-stamps behaviour.
      new.seats_increased_at := now();
    elsif old.seats_increased_at is not null
          and old.seats_increased_at > now() - interval '30 days' then
      -- NULL seats_increased_at is the first-ever-increase case, and any org
      -- whose seats predate this column: no commitment on record, decrease away.
      --
      -- `detail` carries the machine-readable date so set-seat-count can surface
      -- it without parsing the prose; PostgREST returns `details` alongside
      -- `message`.
      raise exception
        'Added seats are billed for a minimum of one month. You can reduce below % seat(s) from % onwards.',
        old.concurrent_seats,
        to_char(eligible_at::date, 'FMDD Mon YYYY')
        using hint = 'The minimum term restarts each time seats are added.',
              detail = 'eligible_at=' || eligible_at::text;
    end if;
  end if;
  return new;
end $$;

create trigger on_org_seat_change
  before update on public.organisations
  for each row execute function public.enforce_seat_minimum_term();

-- ---- Signup RPCs ----
-- Deliberately NOT done inside handle_new_user(): if org-creation or a bad
-- invite code failed inside that trigger, the whole auth.users insert would
-- roll back and signUp() would fail with an opaque Postgres error. Calling
-- these as an explicit second step after signUp() succeeds means a failure
-- here is recoverable — the account already exists, the user just retries
-- this step with a clear error.
--
-- Neither of these needs to touch Stripe: billing scales with location
-- count, not staff count, so joining an org (at any tier) has no billing
-- side effect. That's also why both can be plain security-definer SQL
-- functions rather than Edge Functions — see create_location/remove_location
-- (not in this file; Edge Functions, Phase D) for where the Stripe-calling
-- logic actually lives.

create or replace function public.create_organisation(org_name text, org_country text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  new_org_id uuid;
begin
  if exists (select 1 from public.memberships where user_id = auth.uid()) then
    raise exception 'You already belong to an organisation.';
  end if;
  if org_name is null or length(trim(org_name)) = 0 then
    raise exception 'Organisation name is required.';
  end if;

  insert into public.organisations (name, country, join_code)
  values (trim(org_name), org_country, substr(md5(random()::text || clock_timestamp()::text), 1, 8))
  returning id into new_org_id;

  -- No location created here — the org starts 'pending' (see the column
  -- comment above) and has no usable location until checkout completes;
  -- stripe-webhook creates the first one alongside flipping plan_tier.

  insert into public.memberships (org_id, user_id, role) values (new_org_id, auth.uid(), 'owner');

  return new_org_id;
end $$;

create or replace function public.join_organisation(p_join_code text, p_daily_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  target_org public.organisations%rowtype;
begin
  if exists (select 1 from public.memberships where user_id = auth.uid()) then
    raise exception 'You already belong to an organisation.';
  end if;

  select * into target_org from public.organisations where join_code = p_join_code;
  if target_org.id is null then
    raise exception 'Invalid organisation code.';
  end if;
  if target_org.daily_code is null
     or target_org.daily_code_date is distinct from current_date
     or target_org.daily_code is distinct from p_daily_code then
    raise exception 'Invalid or expired daily code.';
  end if;

  insert into public.memberships (org_id, user_id, role) values (target_org.id, auth.uid(), 'staff');

  return target_org.id;
end $$;

-- Owner-provisioned team member: the create-team-member Edge Function
-- creates the auth.users row itself (via the Admin API — something
-- Postgres can't do), then calls this, forwarding the OWNER's own JWT
-- rather than the service role, so auth.uid() below resolves to the
-- owner for both the role check and the audit log entry. Unlike
-- join_organisation() (self-service, unlogged — see log_memberships_change()'s
-- comment), this path is logged explicitly: an owner directly
-- provisioning someone's account is a distinct, audit-worthy action, not
-- a routine join.
create or replace function public.add_team_member(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_id uuid := public.my_org_id();
  target_label text;
begin
  -- `is distinct from` rather than `!=`: my_role() is NULL for a caller with no
  -- membership, and `NULL != 'owner'` is NULL, which plpgsql treats as false —
  -- so `!=` would wave through precisely the callers who belong to no org. They
  -- fail later on memberships.org_id's not-null constraint rather than
  -- succeeding, but relying on that is defence by accident, and the error the
  -- caller gets is a constraint violation instead of "you're not the owner".
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can add team members.';
  end if;
  if p_role not in ('manager', 'staff') then
    raise exception 'Invalid role.';
  end if;

  insert into public.memberships (org_id, user_id, role) values (org_id, p_user_id, p_role);

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select coalesce(u.email, 'Unknown user') into target_label
    from auth.users u where u.id = p_user_id;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
  values (org_id, (select name from public.organisations where id = org_id), actor, actor_label,
          'membership.added_by_owner', 'membership', p_user_id, target_label, jsonb_build_object('role', p_role));
end $$;

grant execute on function public.add_team_member(uuid, text) to authenticated;

-- Adopts an account that ALREADY exists in auth.users but belongs to no
-- organisation, instead of leaving it stranded. Without this, an email that
-- once started a signup and stopped is a permanent dead end: create-team-member
-- can't create it (the Admin API rejects the duplicate) and the person can't
-- join either, so that address becomes un-hireable. Real staff do abandon
-- signups, so the owner needs a way through.
--
-- The owner check comes FIRST and deliberately so: this function resolves an
-- arbitrary email against auth.users, which is an enumeration oracle if anyone
-- can call it. Non-owners are rejected before the lookup happens, so a staff
-- account can't use it to probe which addresses have signed up. It also refuses
-- anyone who already has a membership rather than silently moving them between
-- organisations — the caller gets told, and stealing a rival org's member is
-- not something an owner should be able to do by typing an email.
--
-- Note it does NOT touch the existing account's password: they already have
-- credentials, so create-team-member returns no temp password on this path and
-- the UI says to use their existing one. Membership creation and the audit
-- entry are delegated to add_team_member() above so there's exactly one place
-- that writes a membership.
create or replace function public.adopt_existing_team_member(p_email text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid;
begin
  -- `is distinct from`, NOT `!=`. my_role() returns NULL for a caller with no
  -- membership at all, and `NULL != 'owner'` is NULL, which plpgsql treats as
  -- false — so a plain `!=` lets exactly the callers with no org straight past
  -- the guard. They can't ultimately create a membership (my_org_id() is NULL
  -- and memberships.org_id is not-null), but they DO reach the email lookup
  -- below, and its two distinct error messages ("No existing account uses that
  -- email" vs "already belongs to an organisation") then leak whether any given
  -- address has a Gantry account. That enumeration oracle is the whole thing
  -- this check exists to prevent.
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can add team members.';
  end if;

  select u.id into v_user_id
    from auth.users u
   where lower(u.email) = lower(trim(p_email));

  if v_user_id is null then
    raise exception 'No existing account uses that email.';
  end if;

  if exists (select 1 from public.memberships where user_id = v_user_id) then
    raise exception 'That person already belongs to an organisation.';
  end if;

  perform public.add_team_member(v_user_id, p_role);
end $$;

grant execute on function public.adopt_existing_team_member(text, text) to authenticated;

-- Lazy daily-code rotation — called by admin.html whenever the roster/join
-- screen is opened, rather than a pg_cron job (avoids depending on an
-- extension just to rotate a code once a day). Owner/manager only.
create or replace function public.get_daily_code()
returns text language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.my_org_id();
  v_code text;
  v_date date;
begin
  -- coalesce, because my_role() is NULL for a caller with no membership and
  -- `NULL not in (...)` is NULL — which plpgsql treats as false, letting them
  -- past. See add_team_member() for the full explanation.
  if coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'Only owners and managers can view the daily code.';
  end if;

  select daily_code, daily_code_date into v_code, v_date
    from public.organisations where id = v_org_id;

  if v_date is distinct from current_date then
    v_code := substr(md5(random()::text || clock_timestamp()::text), 1, 6);
    update public.organisations
       set daily_code = v_code, daily_code_date = current_date
     where id = v_org_id;
  end if;

  return v_code;
end $$;

-- Roster for admin.html — owner/manager only. auth.users isn't exposed to
-- the client via PostgREST at all (not just RLS-restricted), so this is the
-- only way to show a member's email alongside their role; security definer
-- lets it read auth.users safely without exposing the whole table.
create or replace function public.list_org_members()
returns table (user_id uuid, email text, full_name text, role text, joined_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  -- coalesce — see the daily-code function above; a NULL role would otherwise
  -- slip past this check.
  if coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'Only owners and managers can view the roster.';
  end if;

  return query
    select m.user_id, u.email::text, p.full_name, m.role, m.created_at
      from public.memberships m
      join auth.users u on u.id = m.user_id
      left join public.profiles p on p.id = m.user_id
     where m.org_id = public.my_org_id()
     order by m.created_at asc;
end $$;

-- Postgres grants EXECUTE on new functions to PUBLIC by default, so these
-- are likely redundant — but this repo has never called an RPC function
-- before now (nothing in app.html today uses `.rpc()`), so making it
-- explicit rather than relying on an unverified default.
grant execute on function public.create_organisation(text, text) to authenticated;
grant execute on function public.join_organisation(text, text) to authenticated;
grant execute on function public.get_daily_code() to authenticated;
grant execute on function public.list_org_members() to authenticated;

-- ---- Row Level Security ----

alter table public.organisations enable row level security;
alter table public.venues enable row level security;
alter table public.locations enable row level security;
alter table public.memberships enable row level security;
alter table public.stocktakes enable row level security;
alter table public.stocktake_items enable row level security;

-- organisations: read/update own org only; plan_tier/stripe_* stay
-- service-role/webhook-only, same pattern as is_pro was untouchable by
-- clients in the old schema.
create policy "read own org" on public.organisations
  for select using (id = public.my_org_id());

create policy "owner update org" on public.organisations
  for update using (id = public.my_org_id() and public.my_role() = 'owner')
  with check (id = public.my_org_id() and public.my_role() = 'owner');

revoke update on public.organisations from authenticated;
grant update (name, logo_url, export_format, join_code, country, roster_last_viewed_at, heartbeat_interval_seconds)
  on public.organisations to authenticated;
-- No insert policy: organisations are only ever created via
-- create_organisation() above (security definer, bypasses RLS).

-- venues: any org member reads; owner/manager manage. There's no plain
-- client insert path for a 'pending' org's very first venue — that's
-- created by stripe-webhook (service role, bypasses RLS) once checkout
-- completes (ensureFirstVenue()), which is exactly what makes 'pending' a
-- hard paywall: no venue exists yet, so no location or stocktake can exist
-- either. The one remaining plain-RLS insert case is a 'single'-tier org's
-- first venue (their only one, ever) — 'multi' is unlimited.
create policy "read org venues" on public.venues
  for select using (org_id = public.my_org_id());

create policy "owner manager update venues" on public.venues
  for update using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'))
  with check (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

create policy "owner manager insert venues" on public.venues
  for insert with check (
    org_id = public.my_org_id()
    and public.my_role() in ('owner', 'manager')
    and (
      (select plan_tier from public.organisations where id = venues.org_id) = 'multi'
      or (
        (select plan_tier from public.organisations where id = venues.org_id) = 'single'
        -- Archived venues must NOT count against the single-tier cap of one.
        -- Otherwise an operator who sells their only venue and archives it can
        -- never create its replacement — the cap would be permanently consumed
        -- by a venue they no longer own, with no way back except deleting the
        -- history that archiving exists to preserve. That is exactly the
        -- scenario archiving was added for.
        and (select count(*) from public.venues
              where org_id = venues.org_id and archived_at is null) = 0
      )
    )
  );

create policy "owner manager delete venues" on public.venues
  for delete using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

-- Only `name` is client-writable. archived_at is excluded so the ONLY way to
-- archive or restore is set_venue_archived() below, which is owner-only and
-- always writes an audit row — a plain PATCH would bypass both (the update
-- policy above admits managers too). Same pattern, and same reasoning, as the
-- column grants on profiles and organisations.
--
-- Supabase grants UPDATE on every newly created table, so this revoke MUST
-- live in this file: a rebuild without it silently reopens the direct path.
revoke update on public.venues from authenticated, anon;
grant update (name) on public.venues to authenticated;

-- locations: any org member reads; owner/manager manage. No plan-tier cap
-- of its own any more — that boundary moved up to venues (see above), so
-- every tier gets unlimited locations within whatever venue(s) it has. The
-- insert check instead verifies venue_id actually belongs to a venue in the
-- SAME org as the location's own org_id — mirrors the exact pattern the
-- stocktakes insert policy below already uses for location_id; without it,
-- a client could satisfy org_id = my_org_id() while pointing venue_id at a
-- different org's venue.
create policy "read org locations" on public.locations
  for select using (org_id = public.my_org_id());

create policy "owner manager update locations" on public.locations
  for update using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'))
  with check (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

create policy "owner manager insert locations" on public.locations
  for insert with check (
    org_id = public.my_org_id()
    and public.my_role() in ('owner', 'manager')
    and exists (
      -- `archived_at is null` so a new location can't be added to a venue
      -- that's been retired. Nothing in the UI offers it, but an archived
      -- venue is still readable (that's what makes Restore possible), so
      -- without this a stale or hand-rolled client could keep filling it.
      select 1 from public.venues v
       where v.id = locations.venue_id and v.org_id = locations.org_id
         and v.archived_at is null
    )
  );

create policy "owner manager delete locations" on public.locations
  for delete using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

-- `name` and `venue_id` stay client-writable (rename, and the existing
-- 'location.moved' flow); archived_at does not, for the same reason as venues
-- above — set_location_archived() is the only writer.
revoke update on public.locations from authenticated, anon;
grant update (name, venue_id) on public.locations to authenticated;

-- memberships: any org member can see the roster; only the owner changes
-- roles or removes staff. No insert policy — only create_organisation()/
-- join_organisation() insert rows here (both security definer).
create policy "read org memberships" on public.memberships
  for select using (org_id = public.my_org_id());

create policy "owner update memberships" on public.memberships
  for update using (org_id = public.my_org_id() and public.my_role() = 'owner')
  with check (org_id = public.my_org_id() and public.my_role() = 'owner');

create policy "owner delete memberships" on public.memberships
  for delete using (org_id = public.my_org_id() and public.my_role() = 'owner');

-- stocktakes: any org member reads/creates; only owner/manager can
-- delete one outright. This is a deliberate tightening from the
-- old single-user model, where the sole owner could always delete their
-- own stocktake — once other people's work can be sitting inside it,
-- letting any staff member delete the whole thing is a real footgun.
-- UPDATE is not granted to clients at all — see the revoke below.
create policy "read org stocktakes" on public.stocktakes
  for select using (org_id = public.my_org_id());

create policy "org members insert stocktakes" on public.stocktakes
  for insert with check (
    org_id = public.my_org_id()
    and exists (
      -- Both archived_at checks matter, and they're checked here rather than
      -- only in the app because a phone can be holding a location list loaded
      -- before the venue was retired. The join to venues is what enforces
      -- "effectively archived" (see locations.archived_at) — a location can be
      -- active in its own right while its venue is not.
      select 1 from public.locations l
        join public.venues v on v.id = l.venue_id
       where l.id = stocktakes.location_id and l.org_id = stocktakes.org_id
         and l.archived_at is null and v.archived_at is null
    )
  );

-- No update policy, and UPDATE revoked outright. `status` is the only column a
-- client ever changed here, and it now goes through set_stocktake_status()
-- (further down), which logs the transition and enforces who may make it.
--
-- Revoking the whole table's UPDATE rather than just gating status is
-- deliberate, and RLS is the reason: a policy can restrict WHICH ROWS you may
-- update but not WHICH COLUMNS, and it cannot express "this transition is
-- allowed but that one isn't". The old policy therefore let any org member —
-- staff included — rename anyone's stocktake or set status to arbitrary text,
-- with nothing written down. A column-scoped GRANT could have narrowed the
-- columns (as on profiles/organisations) but still couldn't express the
-- per-transition role rule, so the function is the only place that can hold all
-- of it in one readable piece.
--
-- touch_stocktake() is unaffected: it's security definer
-- (see above), so it runs as the function owner and updates updated_at
-- regardless of what the caller may do. Same reasoning as the
-- stocktake_items cascade surviving its own DELETE revoke.
--
-- Must live in this file: Supabase's default privileges re-grant UPDATE on every
-- newly created table, so a rebuild without this silently reopens it.
drop policy if exists "org members update stocktakes" on public.stocktakes;
revoke update on public.stocktakes from authenticated, anon;

create policy "owner manager delete stocktakes" on public.stocktakes
  for delete using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

-- stocktake_items: any org member can read/insert/update within their org's
-- stocktakes. DELETE is deliberately NOT granted to clients at all — see the
-- revoke below. The insert check verifies stocktake_id actually
-- belongs to a stocktake in the SAME org as the item's own org_id —
-- without this, a client could satisfy `org_id = my_org_id()` while
-- pointing stocktake_id at a different org's stocktake, writing items into
-- someone else's tenant. No item-count cap any more — that was the old
-- free-plan limit (3 distinct products per stocktake); there's no free
-- plan now, every org that can reach this point has already paid.
create policy "read org items" on public.stocktake_items
  for select using (org_id = public.my_org_id());

create policy "org members insert items" on public.stocktake_items
  for insert with check (
    org_id = public.my_org_id()
    and exists (
      select 1 from public.stocktakes s
       where s.id = stocktake_items.stocktake_id and s.org_id = stocktake_items.org_id
    )
  );

create policy "org members update items" on public.stocktake_items
  for update using (org_id = public.my_org_id())
  with check (org_id = public.my_org_id());

-- No delete policy, and DELETE revoked outright. Removing scanned items goes
-- through delete_stocktake_items() / clear_stocktake_items() (both further
-- down), which log what was removed before removing it. A policy alone wasn't
-- enough: the old `"org members delete items"` policy let any org member — staff
-- included — issue `DELETE /rest/v1/stocktake_items?stocktake_id=eq.<uuid>` and
-- wipe an entire count with nothing written down, which is precisely the
-- "Gantry lost our stocktake" scenario we have to be able to disprove.
--
-- Both halves on purpose. Dropping the policy alone leaves a table-level GRANT
-- that a later `create policy` would silently re-enable; revoking alone leaves a
-- policy that reads as if staff can still delete. Note Supabase's
-- `alter default privileges ... grant all on tables to anon, authenticated`
-- re-grants DELETE on every newly created table, so this revoke MUST live in
-- this file — a rebuild without it reopens the hole invisibly. Same
-- belt-and-braces shape as the `revoke update on public.profiles` above.
--
-- This does not affect `delete from stocktakes`: its cascade to
-- stocktake_items runs as the table owner with RLS forced off, not as the
-- caller, so it is unaffected by client privileges.
drop policy if exists "org members delete items" on public.stocktake_items;
revoke delete on public.stocktake_items from authenticated, anon;

-- ==========================================================================
-- Operator activity log — "who did what". Deliberately NOT dropped and
-- recreated on every run like every table above: it's the historical
-- record itself, and this file now gets re-run against a live org routinely
-- (every time a feature needs a schema change), not just once at the start.
-- `create table if not exists` + explicit `if exists` guards below keep
-- reruns safe without wiping existing log rows. Every other app table above
-- still gets `drop table ... cascade`'d on each run, which would silently
-- destroy this table's FK constraints (the cascade drops dependent
-- constraint objects) without the unconditional drop/re-add below.
-- ==========================================================================
create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,
  org_label text not null,
  actor_id uuid,
  actor_label text not null,
  action text not null,           -- dot-namespaced, e.g. 'location.renamed'
  entity_type text not null,      -- 'venue' | 'location' | 'membership' | 'organisation' | 'stocktake'
  entity_id uuid,                 -- NOT a FK — the referenced row may be long gone
  target_label text,              -- human label for what was affected
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now()
);

-- on delete set null (not cascade): if an org is ever dissolved (e.g. a
-- sole member deleting their account), its log history shouldn't vanish in
-- the same transaction as the event it exists to explain. org_label/
-- actor_label are snapshotted at write time for the same reason — profiles
-- cascade-deletes with auth.users, so a join-at-read-time approach would go
-- blank exactly when a departed operator's history matters most.
-- Orphan sweep before re-adding the FK. This table deliberately survives the
-- `drop table organisations cascade` at the top of the file, so on a re-run its
-- rows still point at org ids that no longer exist and ADD CONSTRAINT would
-- fail validation with a 23503 — after the drops have already happened. Doing
-- exactly what the constraint's own `on delete set null` would have done keeps
-- the history (org_label is snapshotted at write time precisely so a null
-- org_id stays readable) instead of losing it.
update public.audit_log a set org_id = null
 where a.org_id is not null
   and not exists (select 1 from public.organisations o where o.id = a.org_id);

alter table public.audit_log drop constraint if exists audit_log_org_id_fkey;
alter table public.audit_log add constraint audit_log_org_id_fkey
  foreign key (org_id) references public.organisations(id) on delete set null;

alter table public.audit_log drop constraint if exists audit_log_actor_id_fkey;
alter table public.audit_log add constraint audit_log_actor_id_fkey
  foreign key (actor_id) references auth.users(id) on delete set null;

create index if not exists audit_log_org_created_idx
  on public.audit_log (org_id, created_at desc);

alter table public.audit_log enable row level security;

-- No insert/update/delete policy for `authenticated` at all — RLS defaults
-- to deny for any command with zero matching policies. Writes only happen
-- from inside `security definer` trigger functions below (which execute as
-- the function owner and bypass RLS, same mechanism that already lets
-- create_organisation()/join_organisation() insert into
-- organisations/memberships with no direct insert policy on those tables
-- either) — nobody, not even an org owner, can fabricate or edit a log
-- entry through the client.
drop policy if exists "owner manager read audit log" on public.audit_log;
create policy "owner manager read audit log" on public.audit_log
  for select using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

-- A trigger only writes a log row when auth.uid() is non-null — i.e. a real
-- end-user's own RLS-governed session made the change. Writes made via a
-- service-role key (some Edge Functions, e.g. stripe-webhook's
-- ensureFirstLocation()) have no end-user JWT, so auth.uid() is null there
-- and the trigger silently no-ops — deliberate, not a bug: those are
-- system-driven writes with no human actor to attribute.
create or replace function public.log_locations_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  if actor is null then
    return coalesce(new, old);
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o
    where o.id = coalesce(new.org_id, old.org_id);

  if TG_OP = 'INSERT' then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
    values (new.org_id, org_label, actor, actor_label, 'location.created', 'location', new.id, new.name, to_jsonb(new));
  elsif TG_OP = 'UPDATE' and old.name is distinct from new.name then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.org_id, org_label, actor, actor_label, 'location.renamed', 'location', new.id, new.name, to_jsonb(old), to_jsonb(new));
  elsif TG_OP = 'UPDATE' and old.venue_id is distinct from new.venue_id then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.org_id, org_label, actor, actor_label, 'location.moved', 'location', new.id, new.name, to_jsonb(old), to_jsonb(new));
  elsif TG_OP = 'DELETE' then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
    values (old.org_id, org_label, actor, actor_label, 'location.removed', 'location', old.id, old.name, to_jsonb(old));
  end if;
  return coalesce(new, old);
end $$;

create trigger log_locations_audit
  after insert or update or delete on public.locations
  for each row execute function public.log_locations_change();

-- venues: same null-actor guard, same watched-column-only-on-name-change
-- shape as locations above. The org's very first venue (created by
-- stripe-webhook's ensureFirstVenue(), service role, no end-user JWT) is
-- deliberately NOT logged here — that no-ops via the null-actor guard, same
-- as ensureFirstLocation() always has; stripe-webhook logs that one
-- explicitly instead, since it's the only place that knows there's no real
-- human actor to attribute it to ('Stripe checkout').
create or replace function public.log_venues_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  if actor is null then
    return coalesce(new, old);
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o
    where o.id = coalesce(new.org_id, old.org_id);

  if TG_OP = 'INSERT' then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
    values (new.org_id, org_label, actor, actor_label, 'venue.created', 'venue', new.id, new.name, to_jsonb(new));
  elsif TG_OP = 'UPDATE' and old.name is distinct from new.name then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.org_id, org_label, actor, actor_label, 'venue.renamed', 'venue', new.id, new.name, to_jsonb(old), to_jsonb(new));
  elsif TG_OP = 'DELETE' then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
    values (old.org_id, org_label, actor, actor_label, 'venue.removed', 'venue', old.id, old.name, to_jsonb(old));
  end if;
  return coalesce(new, old);
end $$;

create trigger log_venues_audit
  after insert or update or delete on public.venues
  for each row execute function public.log_venues_change();

-- membership INSERT is deliberately not logged — join_organisation() already
-- durably records who joined and when via the row itself (created_at).
create or replace function public.log_memberships_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  target_label text;
begin
  if actor is null then
    return coalesce(new, old);
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o
    where o.id = coalesce(new.org_id, old.org_id);
  select coalesce(p.full_name, u.email, 'Unknown user') into target_label
    from auth.users u left join public.profiles p on p.id = u.id
   where u.id = coalesce(new.user_id, old.user_id);

  if TG_OP = 'UPDATE' and old.role is distinct from new.role then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
    values (new.org_id, org_label, actor, actor_label, 'membership.role_changed', 'membership', new.user_id, target_label, to_jsonb(old), to_jsonb(new));
  elsif TG_OP = 'DELETE' then
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
    values (old.org_id, org_label, actor, actor_label, 'membership.removed', 'membership', old.user_id, target_label, to_jsonb(old));
  end if;
  return coalesce(new, old);
end $$;

create trigger log_memberships_audit
  after update or delete on public.memberships
  for each row execute function public.log_memberships_change();

-- Watches every owner-writable organisations column (the same set the
-- column-scoped GRANT above already lets owners write) except the passive
-- roster_last_viewed_at read-tracking touch, which isn't an operator action.
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
  return new;
end $$;

create trigger log_organisations_audit
  after update on public.organisations
  for each row execute function public.log_organisations_change();

-- stocktakes: delete only, as a TRIGGER. Creation is already durably attributed
-- via created_by, and status changes are logged explicitly by
-- set_stocktake_status() instead — that used to be an automatic export side
-- effect rather than an operator decision, but it isn't any more: marking a count
-- ready for export is a deliberate act head office relies on, so it needs its own
-- entry with who and which direction.
--
-- BEFORE delete, not AFTER, and that is load-bearing. `on delete cascade` is
-- implemented as an internal AFTER ROW trigger on the PARENT table, named
-- RI_ConstraintTrigger_a_<oid>, and AFTER row triggers on the same table and
-- event fire in strcmp(tgname) order — 'R' (0x52) sorts before 'l' (0x6C), so
-- the cascade that deletes this stocktake's items runs BEFORE
-- log_stocktakes_audit would. Counting items from an AFTER trigger therefore
-- returns 0, silently and permanently. In a BEFORE DELETE trigger the parent
-- row is still present and no AFTER queue has drained, so every item is still
-- there to count — and that stays true however trigger names or FK OIDs shuffle
-- later, which a rename-to-sort-first hack would not.
--
-- The counts are the point: "deleted stocktake Friday Bar Count" is an
-- assertion, "deleted Friday Bar Count — 247 items, 1032 units" is evidence.
--
-- MUST return old: returning null from a BEFORE DELETE trigger silently
-- cancels the delete.
--
-- One accepted trade-off of BEFORE: under READ COMMITTED, if the delete hits a
-- concurrent update (plausible here — touch_stocktake() UPDATEs the parent on
-- every scan) EvalPlanQual re-runs the row and this can fire twice, or fire for
-- a row the re-check then skips. The failure mode is a duplicate or phantom
-- audit row, never a missing one, which is the right direction for a trail
-- whose job is to make destruction undeniable. A delete blocked by RLS never
-- reaches here at all — `using` quals are scan quals.
create or replace function public.log_stocktakes_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  item_count integer;
  -- numeric, not bigint: qty is numeric(12,2) now, and a bigint accumulator would
  -- silently truncate a part-bottle total — "247 items, 1032 units" turning into
  -- 1032 when the real figure is 1032.75 makes the log's own evidence wrong.
  unit_total numeric;
begin
  if actor is null then
    return old;
  end if;

  select count(*), coalesce(sum(i.qty), 0)
    into item_count, unit_total
    from public.stocktake_items i
   where i.stocktake_id = old.id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = old.org_id;

  -- to_jsonb(old) || ... keeps the existing `before` shape, so rows written
  -- before this change simply lack the two new keys and admin.html's sentence
  -- falls back (see AUDIT_SENTENCES there).
  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
  values (old.org_id, org_label, actor, actor_label, 'stocktake.deleted', 'stocktake', old.id, old.name,
          to_jsonb(old) || jsonb_build_object('items_deleted', item_count, 'units_deleted', unit_total));
  return old;
end $$;

drop trigger if exists log_stocktakes_audit on public.stocktakes;
create trigger log_stocktakes_audit
  before delete on public.stocktakes
  for each row execute function public.log_stocktakes_change();

-- ---- Deleting scanned items: both paths go through an RPC ----
--
-- Client DELETE on stocktake_items is REVOKED (see the revoke beside the
-- stocktake_items policies above), so these two functions are the only ways an
-- operator can remove scanned items, and both log. That closes the hole this
-- product's whole dispute story depends on: previously app.html's per-item ✕
-- issued a plain `delete from stocktake_items where id = ...`, permitted with no
-- role check and no log entry, so a count could be emptied one item at a time
-- and a hand-rolled `DELETE /rest/v1/stocktake_items?stocktake_id=eq.<uuid>`
-- wiped it in one request — either way leaving nothing to point at afterwards.
--
-- An earlier comment here claimed a row-level trigger could not tell a cascade
-- from a deliberate bulk clear, and that per-row logging would be too noisy.
-- Both are wrong, and worth correcting because they shaped the old design:
--   1. It CAN tell. `on delete cascade` is an internal AFTER ROW trigger on the
--      PARENT, so by the time a cascaded child delete runs the parent row is
--      already gone: `exists (select 1 from stocktakes where id =
--      old.stocktake_id)` is false during a cascade and true during a
--      deliberate item delete.
--   2. The noise objection is dissolved by `for each statement` +
--      `referencing old table`, which fires once per DELETE statement whether
--      it removed 1 row or 5,000 (see log_item_qty_reduced below for that shape).
-- We still prefer revoke-plus-RPC over detection: no grant means no path,
-- rather than a heuristic whose reliability rests on OID-ordered internal
-- trigger names.
--
-- Both are security definer, which bypasses RLS, so each re-implements its own
-- org scoping — without it these would be cross-org deletes callable by any
-- authenticated user who guesses a UUID.

-- Removes specific scanned items. Array-shaped rather than single-id so one
-- user action is one audit row: a future multi-select "remove selected" needs no
-- second function and produces no burst of rows. app.html passes one id today.
--
-- Deliberately available to STAFF as well. Rescanning is inherently corrective
-- — wrong barcode, double scan — and needing a manager for every mis-scan makes
-- the scanner unusable, which is how you end up with staff working around the
-- tool instead of with it. It is safe precisely because it is now attributable:
-- the barcode and quantity are snapshotted into the log before the row goes.
-- Bulk clear is the asymmetry (see clear_stocktake_items below).
create or replace function public.delete_stocktake_items(p_item_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_ids uuid[];
  v_take_id uuid;
  v_take_name text;
  v_distinct_takes integer;
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  removed jsonb;
  removed_count integer;
  unit_total numeric; -- numeric, not bigint — see log_stocktakes_change above
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;

  select array_agg(distinct x) into v_ids
    from unnest(coalesce(p_item_ids, '{}'::uuid[])) as x;
  if v_ids is null then
    raise exception 'No items given to remove.';
  end if;
  if array_length(v_ids, 1) > 500 then
    raise exception 'Too many items in one request (max 500). Use Clear items instead.';
  end if;

  -- Authorise and resolve in one pass: every id must exist, belong to the
  -- CALLER's org, and sit in ONE stocktake so the single audit row below has an
  -- unambiguous subject. Any mismatch is reported identically, so this can't be
  -- used to probe which item UUIDs exist in other organisations.
  select count(*), count(distinct i.stocktake_id), min(i.stocktake_id), coalesce(sum(i.qty), 0)
    into removed_count, v_distinct_takes, v_take_id, unit_total
    from public.stocktake_items i
   where i.id = any(v_ids) and i.org_id = v_org;

  if removed_count <> array_length(v_ids, 1) or v_distinct_takes <> 1 then
    raise exception 'Those items could not all be found in one of your stocktakes.';
  end if;

  -- Snapshot barcode + qty BEFORE deleting. This is what turns the log from
  -- "someone removed 3 items" into "someone removed 9312345678907 x14" — from
  -- an accusation into evidence. Affordable at per-action scale; the bulk paths
  -- keep counts only, since loadAuditLog() does select('*') and would otherwise
  -- download the whole payload on every page load.
  select jsonb_agg(jsonb_build_object('barcode', i.barcode, 'qty', i.qty, 'scanned_by', i.scanned_by)
                   order by i.barcode)
    into removed
    from public.stocktake_items i where i.id = any(v_ids);

  select s.name into v_take_name from public.stocktakes s where s.id = v_take_id;
  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  delete from public.stocktake_items i where i.id = any(v_ids);

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
  values (v_org, org_label, actor, actor_label, 'stocktake_items.deleted', 'stocktake', v_take_id, v_take_name,
          jsonb_build_object('items_deleted', removed_count, 'units_deleted', unit_total, 'items', removed));
  return removed_count;
end $$;

grant execute on function public.delete_stocktake_items(uuid[]) to authenticated;

-- "Clear items" — one function, one summary log row.
create or replace function public.clear_stocktake_items(p_stocktake_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  take_name text;
  take_org uuid;
  cleared_count integer;
  cleared_units numeric; -- numeric, not bigint — see log_stocktakes_change above
begin
  select s.org_id, s.name into take_org, take_name
    from public.stocktakes s where s.id = p_stocktake_id;

  if take_org is null or take_org != public.my_org_id() then
    raise exception 'Stocktake not found.';
  end if;

  -- Owner/manager only. This reverses the note on the stocktakes delete policy
  -- above, which said "staff can still clear its items" as though that were the
  -- safe half of the split — it isn't. Wiping every item is not a correction,
  -- it destroys exactly as much as deleting the stocktake outright, and it IS
  -- the "deleted the work mid-count" scenario this trail exists to make
  -- undeniable. Per-item removal stays open to staff; this does not.
  -- coalesce, not `!=`: my_role() is NULL for a caller with no membership and
  -- `NULL not in (...)` is NULL, which plpgsql treats as false, letting exactly
  -- those callers through (same idiom as list_active_sessions above).
  if coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'Only owners and managers can clear a whole stocktake. Remove items individually, or ask a manager.';
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = take_org;

  -- Units captured before the delete; the count comes from row_count after.
  select coalesce(sum(i.qty), 0) into cleared_units
    from public.stocktake_items i where i.stocktake_id = p_stocktake_id;

  delete from public.stocktake_items where stocktake_id = p_stocktake_id;
  get diagnostics cleared_count = row_count;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
  values (take_org, org_label, actor, actor_label, 'stocktake_items.cleared', 'stocktake', p_stocktake_id, take_name,
          jsonb_build_object('items_cleared', cleared_count, 'units_cleared', cleared_units));
end $$;

grant execute on function public.clear_stocktake_items(uuid) to authenticated;

-- ==========================================================================
-- Writing a scanned quantity. Both of these exist because two people counting
-- the SAME stocktake is normal, and the client cannot see the other device's
-- rows.
--
-- What went wrong without them: app.html decided INSERT-vs-UPDATE from its own
-- in-memory `items` array. The other scanner's row isn't in that array, so both
-- devices took the INSERT branch and the second hit
-- `stocktake_items_stocktake_id_barcode_key`. The operator got a raw Postgres
-- error, Save stayed greyed out, and — worse — the second scanner had no way to
-- know the barcode was already counted, so the natural response was to retype
-- the number and lose the first person's count.
--
-- The merge therefore has to happen in Postgres, where both writers are
-- serialised on the same row, not in a client array that is stale by
-- definition. `unique (stocktake_id, barcode)` stays exactly as it was: it is
-- what makes the merge correct rather than something to design around.
--
-- WHY A LOOP RATHER THAN `insert ... on conflict do update`:
-- this table carries log_item_qty_reduced_audit, an `after update ... for each
-- statement` trigger using `referencing old table / new table`. Whether
-- ON CONFLICT DO UPDATE composes safely with transition tables is not something
-- that could be verified against this project's database before shipping, and a
-- wrong guess fails at call time in the middle of a count rather than at deploy.
-- The update-then-insert loop below is the documented concurrency-safe upsert,
-- behaves identically, and additionally keeps the unique_violation retry INSIDE
-- the transaction, where it cannot be lost to a dropped connection the way a
-- client-side retry can.
--
-- NO AUDIT ROW HERE, deliberately. log_item_qty_reduced() above logs quantity
-- DECREASES only, on the stated grounds that "increases are ordinary scanning,
-- and logging them would bury the interesting rows". A scan is the most common
-- write in the product; logging each one would push the deletions and status
-- changes the log exists to evidence off the first page. The decrease trigger
-- still fires for set_stocktake_item_qty() below when an edit lowers a line,
-- which is the direction that destroys a count.
-- ==========================================================================

-- Scan / ADD path. Adds p_qty to whatever is already there, creating the line if
-- this is its first scan. Returns the resulting row so the caller can show the
-- merged total — which is how the second scanner finds out someone else had
-- already counted this barcode.
--
-- p_qty is a DELTA and may be NEGATIVE — the −/+ steppers in the item list send
-- -1 and +1 through here. They used to compute `current ± 1` in the browser and
-- write it as an absolute qty, which is last-writer-wins: two devices both
-- showing 10 both tap +, both compute 11, and the line ends at 11 instead of 12.
-- One of the two taps is silently lost, and neither operator sees anything
-- wrong. Sending the delta and letting Postgres add it under a row lock is the
-- only way both land.
--
-- Result is floored at 0 rather than rejected: the column's `check (qty >= 0)`
-- would otherwise turn a decrement race (two devices each stepping the last unit
-- down) into a raw constraint error in the middle of a count, and "you can't go
-- below zero" is a clamp, not an error worth interrupting someone for.
create or replace function public.add_stocktake_item(
  p_stocktake_id uuid,
  p_barcode text,
  p_qty numeric
)
returns public.stocktake_items
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_take_org uuid;
  v_code text := btrim(coalesce(p_barcode, ''));
  v_qty numeric;
  v_row public.stocktake_items;
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  if v_code = '' then
    raise exception 'A barcode is required.';
  end if;
  if p_qty is null then
    raise exception 'A quantity is required.';
  end if;
  -- numeric accepts 'NaN', and `'NaN' >= 0` is true, so neither the range check
  -- below nor the column's own `check (qty >= 0)` would stop it — it would just
  -- turn the line's total into NaN permanently.
  if p_qty = 'NaN'::numeric then
    raise exception 'Quantity must be a number.';
  end if;
  -- No lower bound on the DELTA — negatives are how the − stepper works. The
  -- RESULT is clamped at 0 below.
  v_qty := round(p_qty, 2);   -- matches numeric(12,2) and QTY_DP in app.html

  -- security definer bypasses RLS, so re-implement the scoping the insert policy
  -- would have done. Same message whether the stocktake is missing or belongs to
  -- another org, so this cannot be used to probe for UUIDs.
  select s.org_id into v_take_org from public.stocktakes s where s.id = p_stocktake_id;
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  loop
    -- `qty + v_qty` is evaluated by Postgres against the committed row under a
    -- row lock, so two devices adding at once serialise and both counts land.
    -- Computing the total in the client is what made this last-writer-wins.
    update public.stocktake_items
       set qty = greatest(qty + v_qty, 0),
           last_scanned = now(),
           last_scanned_by = auth.uid()
     where stocktake_id = p_stocktake_id
       and barcode = v_code
    returning * into v_row;
    if found then
      return v_row;
    end if;

    begin
      -- A negative delta against a line that doesn't exist yet lands at 0, not a
      -- constraint error. Reachable when the last unit is stepped off on one
      -- device while another removes the line entirely.
      insert into public.stocktake_items (stocktake_id, org_id, barcode, qty)
      values (p_stocktake_id, v_org, v_code, greatest(v_qty, 0))
      returning * into v_row;
      return v_row;
    exception when unique_violation then
      -- Another device inserted this exact barcode between our UPDATE finding
      -- nothing and our INSERT. Go round again; the UPDATE will now find their
      -- row and add to it. This is the race the old client-side branch lost.
      null;
    end;
  end loop;
end $$;

grant execute on function public.add_stocktake_item(uuid, text, numeric) to authenticated;

-- Absolute set, for the keypad's Edit mode and the −/+ steppers. Keyed on
-- (stocktake_id, barcode) rather than the row id the client happens to be
-- holding: that id can be stale — the line may have been removed and rescanned
-- on another device — and an UPDATE by a stale id silently affects nothing while
-- reporting success.
--
-- This one CAN lower a quantity, so log_item_qty_reduced_audit fires for it and
-- the reduction is recorded. That is intended: an edit walking a 247-unit line
-- down to 1 is exactly what that trigger exists to catch.
create or replace function public.set_stocktake_item_qty(
  p_stocktake_id uuid,
  p_barcode text,
  p_qty numeric
)
returns public.stocktake_items
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_take_org uuid;
  v_code text := btrim(coalesce(p_barcode, ''));
  v_qty numeric;
  v_row public.stocktake_items;
begin
  if v_org is null then
    raise exception 'You do not belong to an organisation.';
  end if;
  if v_code = '' then
    raise exception 'A barcode is required.';
  end if;
  if p_qty is null then
    raise exception 'A quantity is required.';
  end if;
  if p_qty = 'NaN'::numeric then
    raise exception 'Quantity must be a number.';
  end if;
  v_qty := round(p_qty, 2);
  if v_qty < 0 then
    raise exception 'Quantity must be 0 or more.';
  end if;

  select s.org_id into v_take_org from public.stocktakes s where s.id = p_stocktake_id;
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  update public.stocktake_items
     set qty = v_qty,
         last_scanned = now(),
         last_scanned_by = auth.uid()
   where stocktake_id = p_stocktake_id
     and barcode = v_code
  returning * into v_row;
  if found then
    return v_row;
  end if;

  -- Line isn't there — removed on another device while this one still showed it.
  -- Recreate it at the requested quantity rather than failing: the operator
  -- asked for this barcode to read this number.
  begin
    insert into public.stocktake_items (stocktake_id, org_id, barcode, qty)
    values (p_stocktake_id, v_org, v_code, v_qty)
    returning * into v_row;
    return v_row;
  exception when unique_violation then
    update public.stocktake_items
       set qty = v_qty,
           last_scanned = now(),
           last_scanned_by = auth.uid()
     where stocktake_id = p_stocktake_id
       and barcode = v_code
    returning * into v_row;
    return v_row;
  end;
end $$;

grant execute on function public.set_stocktake_item_qty(uuid, text, numeric) to authenticated;

-- ==========================================================================
-- A completed stocktake stops accepting counts.
--
-- Exporting is the end of the workflow: head office has the file and is acting
-- on those numbers. Until this existed, a phone still sitting in the stocktake
-- could keep scanning into it afterwards — during the 30 Aug stress test the
-- header drifted 36 / 35 / 33 / 36 after an export, so the CSV in head office's
-- hands and the count in the app were two different things and nothing said so.
--
-- A TRIGGER rather than an RLS predicate, for two reasons:
--   1. add_stocktake_item() and set_stocktake_item_qty() are security definer
--      and bypass RLS entirely, so a policy would not stop the app's own write
--      path — the one people actually use.
--   2. An RLS refusal surfaces as "new row violates row-level security policy",
--      which tells a bartender nothing. A trigger can say what happened and what
--      to do about it, and that message reaches the toast unchanged.
--
-- DELETE is included so "completed" means immutable rather than
-- append-blocked — otherwise a line could still be removed from a finished
-- count. Deleting the whole stocktake still works: `on delete cascade` runs as
-- an AFTER trigger on the parent, so by the time the child delete reaches here
-- the parent row is already gone and the status lookup finds nothing. Same
-- parent-already-gone property log_stocktakes_change() relies on.
-- ==========================================================================
create or replace function public.enforce_stocktake_not_completed()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_status text;
begin
  select s.status into v_status
    from public.stocktakes s
   where s.id = coalesce(new.stocktake_id, old.stocktake_id);

  if v_status = 'completed' then
    raise exception 'This stocktake is completed — ask a manager to reopen it before changing counts.'
      using errcode = 'check_violation';
  end if;

  return coalesce(new, old);
end $$;

drop trigger if exists stocktake_items_block_when_completed on public.stocktake_items;
create trigger stocktake_items_block_when_completed
  before insert or update or delete on public.stocktake_items
  for each row execute function public.enforce_stocktake_not_completed();

-- The only way a stocktake's status changes. Client UPDATE on stocktakes is
-- revoked (see the policies above), so this is the whole write path — which is
-- what makes the log entry unskippable and lets the per-transition role rule
-- exist at all. RLS could not express either: it gates rows, not columns, and has
-- no notion of "this transition, from this state, by this role".
--
-- The workflow this drives:
--   in_progress       being counted
--   ready_for_export  the venue says counting is done — head office's cue
--   completed         an export has happened
--
-- p_reason distinguishes a deliberate move from the automatic one that
-- the export path makes, purely so the activity log can read "marked ready"
-- versus "exported". It does NOT affect permissions — an export by a staff
-- member is still a staff action, and pretending otherwise would let the client
-- pick its own privileges by lying about the reason.
--
-- Leaving 'completed' is owner/manager only. By then head office has already
-- exported, so reopening invites a second export with different numbers — the
-- same reasoning that already restricts deleting a stocktake, and unlike
-- marking a count ready, which is the counter's own call.
create or replace function public.set_stocktake_status(
  p_stocktake_id uuid,
  p_status text,
  p_reason text default 'manual'
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_take_org uuid;
  v_take_name text;
  v_old_status text;
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  if p_status not in ('in_progress', 'ready_for_export', 'completed') then
    raise exception 'Unknown stocktake status.';
  end if;
  if coalesce(p_reason, '') not in ('manual', 'export') then
    raise exception 'Unknown reason for the status change.';
  end if;

  select s.org_id, s.name, s.status into v_take_org, v_take_name, v_old_status
    from public.stocktakes s where s.id = p_stocktake_id;

  -- security definer bypasses RLS, so re-implement the org scoping the dropped
  -- update policy used to provide. Same message whether the stocktake is missing
  -- or belongs to another org, so this can't be used to probe for UUIDs.
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  -- No-op rather than an error: the export path calls this without checking, and
  -- two devices can race the same button. Writing nothing means no misleading
  -- "changed from completed to completed" row in the log.
  if v_old_status = p_status then
    return;
  end if;

  -- coalesce, not `!=`: my_role() is NULL for a caller with no membership and
  -- `NULL not in (...)` is NULL, which plpgsql treats as false — the bypass this
  -- codebase has already been bitten by once.
  if v_old_status = 'completed'
     and coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'This stocktake has already been exported — ask a manager to reopen it.';
  end if;

  update public.stocktakes set status = p_status where id = p_stocktake_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
  values (v_org, org_label, actor, actor_label, 'stocktake.status_changed', 'stocktake',
          p_stocktake_id, v_take_name,
          jsonb_build_object('status', v_old_status),
          jsonb_build_object('status', p_status, 'reason', coalesce(p_reason, 'manual')));
end $$;

grant execute on function public.set_stocktake_status(uuid, text, text) to authenticated;

-- ==========================================================================
-- Archiving venues and locations.
--
-- Why an RPC rather than a plain UPDATE: archiving hides a venue's entire
-- counting history from every screen, so it has to be owner-only and it has to
-- be logged. RLS can restrict which ROWS you may update but not which COLUMNS,
-- and the update policies on these tables admit managers — so the only way to
-- get "owner-only, always logged" is to revoke the column and funnel writes
-- through here. Exactly the shape of set_stocktake_status() above.
--
-- Archiving is the answer to "remove this venue" for anything that has been
-- counted, because deleting it is impossible by design: stocktakes.location_id
-- is `on delete restrict` and locations.venue_id cascades from venues, so a
-- DELETE would have to shred the count records first. Plain DELETE still works
-- for a venue or location that was never used, and is still the right tool
-- there.
--
-- Archiving the org's LAST active venue is deliberately allowed. It's the real
-- middle of the "sold one, buying another" transition, and the venues insert
-- policy above ignores archived rows precisely so the replacement can be
-- created. The org simply can't start counts until it has an active venue.
-- ==========================================================================
create or replace function public.set_venue_archived(
  p_venue_id uuid,
  p_archived boolean
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_venue_org uuid;
  v_venue_name text;
  v_was_archived timestamptz;
  v_locations integer;
  v_stocktakes integer;
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  -- coalesce, not `!=`: my_role() is NULL for a caller with no membership, and
  -- `NULL <> 'owner'` is NULL, which plpgsql treats as false — the exact
  -- null-role bypass this codebase has already been bitten by once.
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Only the owner can archive or restore a venue.';
  end if;

  select v.org_id, v.name, v.archived_at
    into v_venue_org, v_venue_name, v_was_archived
    from public.venues v where v.id = p_venue_id;

  -- security definer bypasses RLS, so re-implement the org scoping here. Same
  -- message whether the venue is missing or belongs to another org, so this
  -- can't be used to probe for UUIDs.
  if v_venue_org is null or v_venue_org is distinct from v_org then
    raise exception 'Venue not found.';
  end if;

  -- No-op rather than an error — two admin tabs can race the same button, and
  -- writing nothing avoids a misleading "archived an already-archived venue"
  -- row in the log.
  if (v_was_archived is not null) = p_archived then
    return;
  end if;

  update public.venues
     set archived_at = case when p_archived then now() else null end
   where id = p_venue_id;

  -- Counted for the log, not for a decision: "archived Old Tavern" alone
  -- doesn't convey that 31 counts just left every screen. Same reasoning as
  -- the items_deleted/units_deleted enrichment on stocktake deletion.
  select count(*) into v_locations
    from public.locations l where l.venue_id = p_venue_id;
  select count(*) into v_stocktakes
    from public.stocktakes s
    join public.locations l on l.id = s.location_id
   where l.venue_id = p_venue_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
  values (v_org, org_label, actor, actor_label,
          case when p_archived then 'venue.archived' else 'venue.restored' end,
          'venue', p_venue_id, v_venue_name,
          jsonb_build_object('archived_at', v_was_archived),
          jsonb_build_object(
            'archived', p_archived,
            'locations_affected', v_locations,
            'stocktakes_affected', v_stocktakes));
end $$;

grant execute on function public.set_venue_archived(uuid, boolean) to authenticated;

-- Same contract for a single location. Note this is independent of its venue's
-- state by design (see locations.archived_at): restoring a venue does not
-- un-archive a location that was retired on its own beforehand.
create or replace function public.set_location_archived(
  p_location_id uuid,
  p_archived boolean
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_loc_org uuid;
  v_loc_name text;
  v_was_archived timestamptz;
  v_stocktakes integer;
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Only the owner can archive or restore a location.';
  end if;

  select l.org_id, l.name, l.archived_at
    into v_loc_org, v_loc_name, v_was_archived
    from public.locations l where l.id = p_location_id;

  if v_loc_org is null or v_loc_org is distinct from v_org then
    raise exception 'Location not found.';
  end if;

  if (v_was_archived is not null) = p_archived then
    return;
  end if;

  update public.locations
     set archived_at = case when p_archived then now() else null end
   where id = p_location_id;

  select count(*) into v_stocktakes
    from public.stocktakes s where s.location_id = p_location_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before, after)
  values (v_org, org_label, actor, actor_label,
          case when p_archived then 'location.archived' else 'location.restored' end,
          'location', p_location_id, v_loc_name,
          jsonb_build_object('archived_at', v_was_archived),
          jsonb_build_object('archived', p_archived, 'stocktakes_affected', v_stocktakes));
end $$;

grant execute on function public.set_location_archived(uuid, boolean) to authenticated;

-- Quantity edits are the other way to destroy a count without deleting
-- anything: `update stocktake_items set qty = 1` walks a 247-unit line down to
-- nothing, and until this trigger existed the only trigger on this table was
-- touch_stocktake_on_items (which just bumps updated_at), so it left no trace
-- at all. The check constraint is no defence — 247 units becoming 1, or now 0,
-- is functionally "the system lost our count". Zero being a legal quantity makes
-- this trigger more important than it was, not less: walking a line to 0 is now a
-- single edit rather than something the constraint blocked.
--
-- Statement-level with a transition table: one audit row per UPDATE statement
-- regardless of how many rows it touched, which is what makes logging this
-- affordable. Only DECREASES are logged — increases are ordinary scanning, and
-- logging them would bury the interesting rows.
create or replace function public.log_item_qty_reduced()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  r record;
begin
  if actor is null then
    return null;
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;

  for r in
    select o.stocktake_id,
           o.org_id,
           count(*)                        as lines,
           coalesce(sum(o.qty - n.qty), 0) as units_removed
      from old_items o join new_items n on n.id = o.id
     where n.qty < o.qty
     group by o.stocktake_id, o.org_id
  loop
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
    select r.org_id, org.name, actor, actor_label, 'stocktake_items.qty_reduced', 'stocktake', r.stocktake_id, s.name,
           jsonb_build_object('lines_reduced', r.lines, 'units_removed', r.units_removed)
      from public.stocktakes s join public.organisations org on org.id = r.org_id
     where s.id = r.stocktake_id;
  end loop;
  return null;
end $$;

drop trigger if exists log_item_qty_reduced_audit on public.stocktake_items;
create trigger log_item_qty_reduced_audit
  after update on public.stocktake_items
  referencing old table as old_items new table as new_items
  for each statement execute function public.log_item_qty_reduced();

-- ==========================================================================
-- Multi-venue concurrent-seat billing. Venues/locations carry no billing
-- consequence any more (unlimited, free) — the multi-venue tier's paid
-- unit is how many people can be actively logged in at once. One row per
-- person (not per device/session — see claim_seat()), upserted on every
-- claim/heartbeat. No client insert/update/delete policy at all: writes
-- only happen via the security-definer RPCs below, same "RLS blocks it,
-- security definer bypasses it" pattern as audit_log.
-- ==========================================================================
-- Not dropped/recreated like every table above (same reason as audit_log:
-- it must survive this file being re-run against a live org) — so it needs
-- the same `if not exists` + unconditional FK drop/re-add treatment
-- audit_log already uses, since a plain inline `references
-- organisations(id)` would otherwise silently vanish the next time this
-- file's `drop table organisations cascade` runs (the cascade drops the FK
-- constraint pointing at it, not this table itself).
create table if not exists public.active_sessions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  org_id uuid not null,
  -- Which device currently holds this login. Still ONE row per person — seats are
  -- billed per person and that hasn't changed — but the row now records WHICH
  -- device, so a second device can be told the login is in use rather than
  -- silently sharing the seat.
  --
  -- That sharing was the bypass: ten staff on one login used to consume one seat,
  -- because this function just refreshed whatever row it found. Worse, it made the
  -- audit trail unreliable — "Sam Lee deleted stocktake X" means nothing if ten
  -- people are Sam. See claim_seat() below for the takeover rules.
  --
  -- Client-generated (localStorage, see app.html) and never trusted for anything
  -- but equality: it's an opaque tag for "same browser as last time", not a
  -- credential. Nullable so rows predating this column are simply treated as
  -- takeable rather than locking anyone out on deploy.
  device_id text,
  last_seen_at timestamptz not null default now()
);

-- For orgs upgraded in place rather than rebuilt from this file.
alter table public.active_sessions add column if not exists device_id text;

-- Orphan sweep before re-adding the FK — same hazard as audit_log above, and
-- this is the one that actually bit: re-running this file with anyone logged in
-- failed here with
--   23503 ... "active_sessions_org_id_fkey" ... Key (org_id)=(...) is not
--   present in table "organisations"
-- which reads like a harmless validation error but only happens *after* the
-- drops at the top have run. Unlike audit_log, these rows are ephemeral seat
-- claims with nothing worth preserving, and the constraint is `on delete
-- cascade` — so deleting them is precisely what the FK itself would do. The
-- affected devices just re-claim a seat on their next heartbeat.
delete from public.active_sessions s
 where not exists (select 1 from public.organisations o where o.id = s.org_id);

alter table public.active_sessions drop constraint if exists active_sessions_org_id_fkey;
alter table public.active_sessions add constraint active_sessions_org_id_fkey
  foreign key (org_id) references public.organisations(id) on delete cascade;

alter table public.active_sessions enable row level security;

drop policy if exists "owner manager read active sessions" on public.active_sessions;
create policy "owner manager read active sessions" on public.active_sessions
  for select using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

-- Called once at login (refreshOrgStatus() in app.html) — NOT the repeating call,
-- see heartbeat() below.
--
-- Enforces TWO separate rules, and keeping them separate matters:
--
--  1. ONE DEVICE PER LOGIN — applies to everyone, every role, both tiers.
--     A login already live on another device is refused (or taken over on
--     request). This is what makes account-sharing unworkable rather than merely
--     uneconomic: ten staff on one login can't be logged in at once, so they need
--     ten logins, which is the paywall doing its job. It also restores the audit
--     trail's meaning — "Sam Lee deleted stocktake X" is only evidence if exactly
--     one person can be Sam at a time. That second reason is why this rule covers
--     owners and single-venue orgs too, even though neither leaks revenue.
--
--  2. THE SEAT POOL — multi-venue, non-owner only, unchanged. The owner is
--     always free (the base price covers them) and single-venue has no pool.
--
-- Returns jsonb rather than boolean so one round trip can distinguish "you're in"
-- from the two quite different refusals: a full pool is the org's problem (buy a
-- seat), another device is the operator's (take over or go away). The old boolean
-- form is kept below as a wrapper so clients mid-deploy don't break.
create or replace function public.claim_seat(p_device_id text, p_takeover boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.my_org_id();
  v_role text := public.my_role();
  v_plan text;
  v_seats integer;
  v_interval_secs integer;
  v_occupied integer;
  v_org_name text;
  v_existing_device text;
  v_existing_seen timestamptz;
  v_has_row boolean;
  v_stale_before timestamptz;
  actor_label text;
begin
  if v_org_id is null then
    return jsonb_build_object('granted', false, 'reason', 'no_organisation');
  end if;

  select plan_tier, concurrent_seats, heartbeat_interval_seconds, name
    into v_plan, v_seats, v_interval_secs, v_org_name
    from public.organisations where id = v_org_id;

  v_stale_before := now() - make_interval(secs => v_interval_secs * 2.5);

  select device_id, last_seen_at, true
    into v_existing_device, v_existing_seen, v_has_row
    from public.active_sessions where user_id = auth.uid();

  -- ---- Rule 1: one device per login ----
  if coalesce(v_has_row, false) then
    -- Same device, or a row old enough that whatever held it is gone. The stale
    -- case is deliberately silent: prompting "another device is using this login"
    -- about a phone that crashed an hour ago would be both wrong and impossible
    -- for the operator to act on, and it's what stops a crash locking someone out
    -- until the timeout expires.
    if v_existing_device is null
       or v_existing_device = p_device_id
       or v_existing_seen <= v_stale_before then
      update public.active_sessions
         set last_seen_at = now(), device_id = p_device_id
       where user_id = auth.uid();
      return jsonb_build_object('granted', true);
    end if;

    -- Live on a different device.
    if not p_takeover then
      return jsonb_build_object('granted', false, 'reason', 'other_device');
    end if;

    update public.active_sessions
       set last_seen_at = now(), device_id = p_device_id
     where user_id = auth.uid();

    -- Logged because a run of these on one account is the signature of a shared
    -- login being passed around — the only signal an owner (or support) would
    -- otherwise have. One legitimate takeover when someone swaps phone for tablet
    -- looks nothing like fifteen a shift.
    select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
      from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();
    insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
    values (v_org_id, v_org_name, auth.uid(), actor_label, 'session.taken_over', 'membership',
            auth.uid(), actor_label, jsonb_build_object('signed_out_previous_device', true));

    return jsonb_build_object('granted', true, 'took_over', true);
  end if;

  -- ---- Rule 2: the seat pool (multi-venue, non-owner) ----
  if v_plan = 'multi' and v_role is distinct from 'owner' then
    select count(*) into v_occupied from public.active_sessions
     where org_id = v_org_id and last_seen_at > v_stale_before;

    if v_occupied >= v_seats then
      -- Distinguish "nobody's purchased any staff seats yet" (v_seats = 0,
      -- true even with v_occupied = 0 — this is the very first non-owner
      -- login on a fresh org) from a pool that's genuinely full right now.
      -- The client shows different, non-misleading copy for each: telling
      -- someone to "ask a teammate to log out" when there IS no teammate
      -- logged in is actively wrong, not just unhelpful.
      if v_seats = 0 then
        return jsonb_build_object('granted', false, 'reason', 'no_seats_purchased');
      end if;
      return jsonb_build_object('granted', false, 'reason', 'seats_full');
    end if;
  end if;

  insert into public.active_sessions (user_id, org_id, device_id, last_seen_at)
    values (auth.uid(), v_org_id, p_device_id, now());
  return jsonb_build_object('granted', true);
end $$;

grant execute on function public.claim_seat(text, boolean) to authenticated;

-- There is deliberately NO zero-argument claim_seat(). One existed briefly as a
-- compatibility shim while the one-device-per-login deploy rolled out, so pages
-- loaded before the change kept working until they reloaded. It was dropped on
-- 2026-08-19 and must not come back: it passed a null device id, which the device
-- check treats as "adopt whatever row you find", so anything calling it was immune
-- to being displaced — precisely the shared-login bypass this feature closed.
-- If a client ever needs to call claim_seat, it passes a device id.

-- Records that someone was turned away by the seat limit, and decides whether
-- the owner should be emailed about it. Called by the notify-seat-denied Edge
-- Function immediately after claim_seat() returns false.
--
-- Why this lives in Postgres rather than in the Edge Function:
--   * It has to RE-DERIVE the denial rather than trust the caller. Otherwise any
--     authenticated staff member could hit the notify endpoint in a loop and mail
--     their owner as often as they liked. The verification has to see the same
--     seat pool and the same staleness cutoff claim_seat() uses, and the only way
--     to guarantee that is to compute it right here beside it.
--   * A staff member cannot read active_sessions at all (owner/manager RLS), so
--     the count has to come from a security-definer function regardless.
--   * The throttle stamp has to be read and written atomically with the decision,
--     or two devices denied in the same second both send an email.
--
-- Returns jsonb rather than a scalar because the caller needs several facts and
-- a second round trip for each would reintroduce the race this avoids.
-- `notify` is true at most once per throttle window; `denied` false means the
-- caller was NOT actually blocked (a seat freed up between claim_seat and this
-- call, or they're the owner) and nothing was recorded.
create or replace function public.record_seat_denial()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.my_org_id();
  v_role text := public.my_role();
  v_plan text;
  v_seats integer;
  v_interval_secs integer;
  v_occupied integer;
  v_org_name text;
  v_notified_at timestamptz;
  v_owner_id uuid;
  v_actor_label text;
  v_should_notify boolean := false;
  -- One email per org per 30 minutes. A venue hitting the limit does so
  -- repeatedly — every staff member arriving for the same shift — and the owner
  -- needs to know once, not eleven times. The seat.denied audit rows are NOT
  -- throttled, so the full picture is still recoverable from the log.
  v_throttle interval := interval '30 minutes';
begin
  if v_org_id is null then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'no organisation');
  end if;

  select plan_tier, concurrent_seats, heartbeat_interval_seconds, name, seats_full_notified_at
    into v_plan, v_seats, v_interval_secs, v_org_name, v_notified_at
    from public.organisations where id = v_org_id;

  -- The owner is exempt from the pool and single-venue has no pool, so neither
  -- can genuinely be denied — mirrors claim_seat()'s first branch exactly.
  if v_plan != 'multi' or v_role = 'owner' then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'not subject to the seat limit');
  end if;

  -- Holding a seat already means they weren't denied.
  if exists (select 1 from public.active_sessions where user_id = auth.uid()) then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'caller holds a seat');
  end if;

  select count(*) into v_occupied from public.active_sessions
   where org_id = v_org_id
     and last_seen_at > now() - make_interval(secs => v_interval_secs * 2.5);

  if v_occupied < v_seats then
    return jsonb_build_object('denied', false, 'notify', false, 'reason', 'a seat is available');
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into v_actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();

  -- Unthrottled: every denial is logged even when no email goes out, so an owner
  -- reviewing the activity log later can see how often people were locked out.
  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
  values (v_org_id, v_org_name, auth.uid(), v_actor_label, 'seat.denied', 'membership', auth.uid(), v_actor_label,
          jsonb_build_object('seats_purchased', v_seats, 'seats_occupied', v_occupied));

  if v_notified_at is null or v_notified_at < now() - v_throttle then
    v_should_notify := true;
    update public.organisations set seats_full_notified_at = now() where id = v_org_id;
  end if;

  select m.user_id into v_owner_id
    from public.memberships m where m.org_id = v_org_id and m.role = 'owner' limit 1;

  return jsonb_build_object(
    'denied', true,
    'notify', v_should_notify,
    'org_name', v_org_name,
    'owner_user_id', v_owner_id,
    'blocked_person', v_actor_label,
    'seats_purchased', v_seats,
    'seats_occupied', v_occupied
  );
end $$;

grant execute on function public.record_seat_denial() to authenticated;

-- The repeating call (every heartbeat_interval_seconds while the app is
-- open, multi-tier only). Deliberately does NOT insert a row if one
-- doesn't exist — that's what makes kick_user() actually stick instead
-- of being silently undone by the next heartbeat: a kicked client's next
-- heartbeat finds nothing to update, gets `false` back, and logs itself
-- out client-side.
-- The device id in the WHERE clause is how a displaced device finds out. When
-- another device takes the login over, claim_seat() overwrites device_id — so this
-- update matches nothing, returns false, and the client logs itself out. Exactly
-- the mechanism that already makes kick_user() stick, reused: no new plumbing, and
-- no way for a displaced client to quietly keep working.
--
-- The bound on that is one heartbeat_interval_seconds (default 60). Pushing to the
-- old device instantly would need Realtime; this is the same deliberate soft-kick
-- trade already documented above, and it costs the operator nothing because every
-- scan is written to the server as it happens — there is no local buffer to lose.
create or replace function public.heartbeat(p_device_id text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.active_sessions set last_seen_at = now()
   where user_id = auth.uid()
     -- `is not distinct from` so a null device_id (a row from before this column,
     -- or an old client) still matches its own null rather than failing forever.
     and (p_device_id is null or device_id is not distinct from p_device_id
          or device_id is null);
  return found;
end $$;

grant execute on function public.heartbeat(text) to authenticated;

-- No zero-argument heartbeat() either — dropped 2026-08-19 alongside
-- claim_seat()'s shim, and for the same reason: a null device id matches any row,
-- so a client calling it could never be displaced.

-- Best-effort, called on explicit logout so the common case frees the
-- seat immediately instead of waiting out the staleness timeout.
create or replace function public.release_seat()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.active_sessions where user_id = auth.uid();
end $$;

grant execute on function public.release_seat() to authenticated;

-- Owner force-logs-out anyone holding a seat, from admin.html. Soft kick,
-- not an instant server-side kill — see heartbeat()'s comment for why
-- that's a deliberate, stated trade-off rather than an oversight.
create or replace function public.kick_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  -- v_org_id, NOT org_id: named `org_id` it shadowed the identically-named
  -- COLUMN in the memberships/active_sessions predicates below, so
  -- `org_id = org_id` was ambiguous. Postgres's default
  -- plpgsql.variable_conflict = error means that raised
  -- 'column reference "org_id" is ambiguous' at runtime for every caller,
  -- including a legitimate owner — this function could never have worked.
  -- (It has no client call site today: the kick-user Edge Function replaced it
  -- and does its own deletes. But it's still granted to `authenticated`, so it
  -- stays reachable over /rest/v1/rpc and worth being correct.)
  v_org_id uuid := public.my_org_id();
  target_label text;
begin
  -- `is distinct from` rather than `!=` — see add_team_member() for why a NULL
  -- role would otherwise slip past.
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can log out a team member.';
  end if;
  if not exists (select 1 from public.memberships m where m.user_id = p_user_id and m.org_id = v_org_id) then
    raise exception 'That person is not a member of your organisation.';
  end if;

  delete from public.active_sessions s where s.user_id = p_user_id and s.org_id = v_org_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select coalesce(p.full_name, u.email, 'Unknown user') into target_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user_id;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label)
  values (v_org_id, (select name from public.organisations where id = v_org_id), actor, actor_label,
          'membership.force_logged_out_by_owner', 'membership', p_user_id, target_label);
end $$;

grant execute on function public.kick_user(uuid) to authenticated;

-- Roster for the new "Concurrent seats" admin.html card — owner/manager
-- only, same auth.users-join-from-security-definer shape as
-- list_org_members(). Filtered to the same staleness cutoff claim_seat()
-- uses, so the owner sees who's ACTUALLY active, not stale rows waiting
-- to time out.
create or replace function public.list_active_sessions()
returns table (user_id uuid, email text, full_name text, last_seen_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.my_org_id();
  v_interval_secs integer;
begin
  -- coalesce — see the daily-code function above; a NULL role would otherwise
  -- slip past this check.
  if coalesce(public.my_role(), '') not in ('owner', 'manager') then
    raise exception 'Only owners and managers can view active sessions.';
  end if;

  select heartbeat_interval_seconds into v_interval_secs
    from public.organisations where id = v_org_id;

  return query
    select s.user_id, u.email::text, p.full_name, s.last_seen_at
      from public.active_sessions s
      join auth.users u on u.id = s.user_id
      left join public.profiles p on p.id = s.user_id
     where s.org_id = v_org_id
       and s.last_seen_at > now() - make_interval(secs => v_interval_secs * 2.5)
     order by s.last_seen_at desc;
end $$;

grant execute on function public.list_active_sessions() to authenticated;

-- ---- Upgrading an org's plan manually (e.g. before Stripe is fully wired
-- up, or to fix a payment that landed without a matching webhook event) ----
--   update public.organisations set plan_tier = 'single'
--    where id = (select org_id from public.memberships m
--                  join auth.users u on u.id = m.user_id
--                 where u.email = 'person@example.com');
-- A 'pending' org has no venue or location yet (see the plan_tier column
-- comment above) — stripe-webhook normally creates both alongside the tier
-- flip (ensureFirstVenue()/ensureFirstLocation()), so doing this manually
-- also needs:
--   with v as (
--     insert into public.venues (org_id, name)
--     values ((select org_id from public.memberships m
--                join auth.users u on u.id = m.user_id
--               where u.email = 'person@example.com'), 'Main')
--     returning id, org_id
--   )
--   insert into public.locations (org_id, venue_id, name)
--   select org_id, id, 'Main' from v;

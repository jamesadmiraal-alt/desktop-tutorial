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
  export_format text not null default 'full'
    check (export_format in ('full', 'myob', 'lightspeed')),
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
  -- 'in_progress' | 'completed' — deliberately unconstrained (unlike
  -- plan_tier/role above) matching the original schema's lighter-weight
  -- approach here: the app is the only writer, flips it to 'completed' on
  -- first successful export.
  status text not null default 'in_progress',
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
  qty integer not null check (qty >= 1),
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
        and (select count(*) from public.venues where org_id = venues.org_id) = 0
      )
    )
  );

create policy "owner manager delete venues" on public.venues
  for delete using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

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
      select 1 from public.venues v where v.id = locations.venue_id and v.org_id = locations.org_id
    )
  );

create policy "owner manager delete locations" on public.locations
  for delete using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

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

-- stocktakes: any org member reads/creates/updates; only owner/manager can
-- delete one outright (staff can still clear its items — see
-- stocktake_items delete below). This is a deliberate tightening from the
-- old single-user model, where the sole owner could always delete their
-- own stocktake — once other people's work can be sitting inside it,
-- letting any staff member delete the whole thing is a real footgun.
create policy "read org stocktakes" on public.stocktakes
  for select using (org_id = public.my_org_id());

create policy "org members insert stocktakes" on public.stocktakes
  for insert with check (
    org_id = public.my_org_id()
    and exists (
      select 1 from public.locations l
       where l.id = stocktakes.location_id and l.org_id = stocktakes.org_id
    )
  );

create policy "org members update stocktakes" on public.stocktakes
  for update using (org_id = public.my_org_id())
  with check (org_id = public.my_org_id());

create policy "owner manager delete stocktakes" on public.stocktakes
  for delete using (org_id = public.my_org_id() and public.my_role() in ('owner', 'manager'));

-- stocktake_items: any org member can read/insert/update/delete within
-- their org's stocktakes. The insert check verifies stocktake_id actually
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

create policy "org members delete items" on public.stocktake_items
  for delete using (org_id = public.my_org_id());

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

-- stocktakes: delete only. Creation is already durably attributed via
-- created_by; the only update that happens today is an automatic
-- status->'completed' side effect of exporting, not an operator decision.
create or replace function public.log_stocktakes_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  if actor is null then
    return old;
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = old.org_id;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
  values (old.org_id, org_label, actor, actor_label, 'stocktake.deleted', 'stocktake', old.id, old.name, to_jsonb(old));
  return old;
end $$;

create trigger log_stocktakes_audit
  after delete on public.stocktakes
  for each row execute function public.log_stocktakes_change();

-- "Clear items" goes through this RPC instead of a stocktake_items trigger:
-- every stocktake deletion already cascades to delete all of that
-- stocktake's items, which would fire a blanket per-row trigger once per
-- scanned item on every single stocktake delete — noisy, and redundant with
-- the one clean row log_stocktakes_change() already writes for that same
-- delete. There's no cheap, reliable way for a row-level trigger to tell
-- "this delete is part of a cascade" from "this is the deliberate bulk
-- clear", so the RPC sidesteps it: one function, one summary log row, no
-- per-row trigger. security definer bypasses RLS the same way the trigger
-- functions above do, so it re-implements the org-scoping check itself —
-- without it this would be a cross-org delete callable by any authenticated
-- user who knows or guesses a stocktake UUID.
create or replace function public.clear_stocktake_items(p_stocktake_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
  take_name text;
  take_org uuid;
  cleared_count integer;
begin
  select s.org_id, s.name into take_org, take_name
    from public.stocktakes s where s.id = p_stocktake_id;

  if take_org is null or take_org != public.my_org_id() then
    raise exception 'Stocktake not found.';
  end if;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = take_org;

  delete from public.stocktake_items where stocktake_id = p_stocktake_id;
  get diagnostics cleared_count = row_count;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, before)
  values (take_org, org_label, actor, actor_label, 'stocktake_items.cleared', 'stocktake', p_stocktake_id, take_name, jsonb_build_object('items_cleared', cleared_count));
end $$;

grant execute on function public.clear_stocktake_items(uuid) to authenticated;

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
  last_seen_at timestamptz not null default now()
);

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

-- Called once at login (refreshOrgStatus() in app.html) — NOT the
-- repeating call, see heartbeat() below. Owner is always exempt from the
-- pool (the $59 base always covers them, regardless of purchased seats),
-- and single-venue orgs never enforce a limit at all (unlimited staff,
-- unchanged from before this feature).
create or replace function public.claim_seat()
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.my_org_id();
  v_role text := public.my_role();
  v_plan text;
  v_seats integer;
  v_interval_secs integer;
  v_occupied integer;
begin
  select plan_tier, concurrent_seats, heartbeat_interval_seconds
    into v_plan, v_seats, v_interval_secs
    from public.organisations where id = v_org_id;

  if v_plan != 'multi' or v_role = 'owner' then
    insert into public.active_sessions (user_id, org_id, last_seen_at)
      values (auth.uid(), v_org_id, now())
      on conflict (user_id) do update set last_seen_at = now();
    return true;
  end if;

  -- Already holding a seat (e.g. a second device, or re-entering after
  -- being on the seats-full screen) — refresh it, don't count it twice.
  if exists (select 1 from public.active_sessions where user_id = auth.uid()) then
    update public.active_sessions set last_seen_at = now() where user_id = auth.uid();
    return true;
  end if;

  select count(*) into v_occupied from public.active_sessions
   where org_id = v_org_id
     and last_seen_at > now() - make_interval(secs => v_interval_secs * 2.5);

  if v_occupied >= v_seats then
    return false;
  end if;

  insert into public.active_sessions (user_id, org_id, last_seen_at)
    values (auth.uid(), v_org_id, now());
  return true;
end $$;

grant execute on function public.claim_seat() to authenticated;

-- The repeating call (every heartbeat_interval_seconds while the app is
-- open, multi-tier only). Deliberately does NOT insert a row if one
-- doesn't exist — that's what makes kick_user() actually stick instead
-- of being silently undone by the next heartbeat: a kicked client's next
-- heartbeat finds nothing to update, gets `false` back, and logs itself
-- out client-side.
create or replace function public.heartbeat()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.active_sessions set last_seen_at = now() where user_id = auth.uid();
  return found;
end $$;

grant execute on function public.heartbeat() to authenticated;

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

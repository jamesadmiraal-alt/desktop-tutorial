-- Reinstate a trial: five products per stocktake, exports uncapped.
--
-- New signups land on a WORKING tier instead of a paywall. 'pending' had no
-- venue and no location, which is what made it a hard stop — there was nowhere
-- to put a stocktake, so there was nothing to do. A trial has to be the
-- opposite: scanning within seconds of signing up.
--
-- Shape, as decided: five LINES per stocktake, unlimited stocktakes, exports
-- never capped. Enough to prove the workflow, not enough to count a cellar.
--
-- Five LINES, not five scan events: scanning one barcode six times builds one
-- line, and that must cost one of the five, not six. Editing a quantity,
-- stepping with +/- and re-exporting all stay open — the cap is on how much of
-- a count you can build, not on fixing what you have built.
--
-- Also captures marketing consent at signup, as evidence rather than as an
-- assumption. See profiles.marketing_opt_in below.
--
-- Additive: one widened check constraint, two new nullable/defaulted columns,
-- three function replacements, one new trigger. No table is dropped, no policy
-- changes, and NO existing row is rewritten — see the note on 'pending' orgs at
-- the bottom. Safe to run twice. Mirrored into schema.sql.
--
-- Run BEFORE pushing the new app.html: the page offers a marketing checkbox and
-- shows a trial upgrade wall, both of which need this.

-- ---------------------------------------------------------------------------
-- 1. 'trial' becomes a legal tier.
--
-- Widening only: every existing value stays valid, so no row can be
-- invalidated by this.
-- ---------------------------------------------------------------------------
alter table public.organisations drop constraint if exists organisations_plan_tier_check;
alter table public.organisations
  add constraint organisations_plan_tier_check
  check (plan_tier in ('pending', 'trial', 'single', 'multi'));

-- ---------------------------------------------------------------------------
-- 2. Marketing consent, recorded at signup.
--
-- Default false, and false is a real answer meaning "do not email". An absent
-- or unparseable value means the same — never "assume yes". The timestamp
-- records when they said yes, so it answers "when did they agree" rather than
-- "when did we ask".
--
-- Deliberately NOT added to the client-writable column grant on profiles (which
-- stays full_name only), so nobody can flip their own or anyone else's after the
-- fact. A future opt-out needs its own deliberate path.
--
-- Under the Australian Spam Act a commercial message needs consent; the value of
-- this column is that it is evidence of what a specific person agreed to.
-- Transactional mail about someone's own account is separate and unaffected.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists marketing_opt_in boolean not null default false;
alter table public.profiles add column if not exists marketing_opt_in_at timestamptz;

-- ---------------------------------------------------------------------------
-- 3. handle_new_user captures the consent in the same transaction as the
--    account, so there is never a window where someone exists with no recorded
--    answer, and the client cannot set it for anybody else.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, marketing_opt_in, marketing_opt_in_at)
  values (
    new.id,
    new.raw_user_meta_data->>'full_name',
    coalesce((new.raw_user_meta_data->>'marketing_opt_in')::boolean, false),
    case when coalesce((new.raw_user_meta_data->>'marketing_opt_in')::boolean, false)
         then now() end
  )
  on conflict do nothing;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 4. A new org starts on 'trial' with somewhere to scan.
--
-- The venue and first location are created here rather than waiting for
-- stripe-webhook's ensureFirstVenue() on checkout. That webhook still runs on
-- upgrade and is idempotent about this, so an org that trials and then pays does
-- not end up with two venues.
-- ---------------------------------------------------------------------------
create or replace function public.create_organisation(org_name text, org_country text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  new_org_id uuid;
  new_venue_id uuid;
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

  update public.organisations set plan_tier = 'trial' where id = new_org_id;

  insert into public.venues (org_id, name) values (new_org_id, trim(org_name))
  returning id into new_venue_id;
  insert into public.locations (org_id, venue_id, name)
  values (new_org_id, new_venue_id, 'Main');

  insert into public.memberships (org_id, user_id, role) values (new_org_id, auth.uid(), 'owner');

  return new_org_id;
end $$;

-- ---------------------------------------------------------------------------
-- 5. The cap itself.
--
-- A trigger rather than the insert POLICY (where the old free plan's 3-product
-- cap used to live) because add_stocktake_item() is security definer and
-- bypasses RLS — a policy would miss the app's own scan path entirely.
--
-- The message is prefixed 'Trial limit reached' and app.html matches on that to
-- raise the upgrade dialog. Keep the prefix stable if the wording changes.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_trial_scan_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_plan text;
  v_lines integer;
begin
  select o.plan_tier into v_plan
    from public.stocktakes s
    join public.organisations o on o.id = s.org_id
   where s.id = new.stocktake_id;

  if v_plan is distinct from 'trial' then
    return new;
  end if;

  select count(*) into v_lines
    from public.stocktake_items i where i.stocktake_id = new.stocktake_id;

  if v_lines >= 5 then
    raise exception 'Trial limit reached — the trial covers 5 products per stocktake. Choose a plan to keep counting.'
      using errcode = 'check_violation';
  end if;

  return new;
end $$;

drop trigger if exists stocktake_items_trial_limit on public.stocktake_items;
create trigger stocktake_items_trial_limit
  before insert on public.stocktake_items
  for each row execute function public.enforce_trial_scan_limit();

grant execute on function public.create_organisation(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- EXISTING 'pending' ORGS ARE NOT CONVERTED.
--
-- Anyone who signed up before this and never checked out is still on 'pending',
-- still looking at the paywall, and still has no venue — so simply flipping
-- their tier would give them a trial with nowhere to scan. Converting them is a
-- deliberate commercial decision, not a migration side effect, so it is left to
-- you. If you do want it, this is the shape (review the SELECT first):
--
--   select id, name, created_at from public.organisations
--    where plan_tier = 'pending';
--
--   -- then, per org, they need a venue and location as well as the tier:
--   --   update public.organisations set plan_tier = 'trial' where id = '<org>';
--   --   insert into public.venues (org_id, name) values ('<org>', '<org name>');
--   --   insert into public.locations (org_id, venue_id, name)
--   --     values ('<org>', '<the venue id>', 'Main');
--
-- ---------------------------------------------------------------------------
-- Verify (a fresh disposable signup — do NOT use Belles or Colac):
--
--   -- 1. a new org lands on trial WITH somewhere to scan:
--   select o.plan_tier, v.name as venue, l.name as location
--     from public.organisations o
--     join public.venues v on v.org_id = o.id
--     join public.locations l on l.venue_id = v.id
--    where o.id = '<new org>';
--   -- expect: trial | <org name> | Main
--
--   -- 2. five lines go in, the sixth is refused:
--   select public.add_stocktake_item('<take>', '111', 1);   -- 1
--   select public.add_stocktake_item('<take>', '222', 1);   -- 2
--   select public.add_stocktake_item('<take>', '333', 1);   -- 3
--   select public.add_stocktake_item('<take>', '444', 1);   -- 4
--   select public.add_stocktake_item('<take>', '555', 1);   -- 5
--   select public.add_stocktake_item('<take>', '666', 1);
--   -- ERROR: Trial limit reached — the trial covers 5 products per stocktake...
--
--   -- 3. but topping up an EXISTING line still works, and so does export:
--   select public.add_stocktake_item('<take>', '111', 4);   -- fine, still 5 lines
--
--   -- 4. a second trial stocktake gets its own five:
--   --    (create one, then repeat step 2 — the first five succeed again)
--
--   -- 5. consent is recorded as evidence:
--   select id, marketing_opt_in, marketing_opt_in_at from public.profiles
--    order by created_at desc limit 5;
--
--   -- 6. paid tiers are uncapped — Colac (multi) must take a sixth line fine.

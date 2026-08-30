-- One OPEN stocktake per name per organisation.
--
-- Why: two staff starting a count at the same location on the same day both get
-- the same suggested name and both tap Create. The 30 Aug stress test ended up
-- with two "Stress test 2 — 30/8/2026" cards on Home, and from there the title
-- cannot tell them apart — a mis-tap opens the wrong count with nothing on
-- screen to reveal it.
--
-- Scoped to OPEN takes (in_progress, ready_for_export). Completed counts are
-- history and must not reserve a name forever: "Main Bar – 30/8/2026" has to be
-- reusable next week.
--
-- ---------------------------------------------------------------------------
-- READ THIS BEFORE RUNNING — it is why this is a trigger and not just an index.
--
-- A partial unique index is the better boundary, and §3 below tries to create
-- one. But an index cannot be created while duplicates already exist, and this
-- project HAS them: the two "Stress test 2 — 30/8/2026" rows. Those are real
-- counts and must not be renamed or merged to make room for an index.
--
-- So the trigger in §1 does the enforcing. It applies to everything written from
-- now on and leaves the existing rows exactly as they are — still open, still
-- named what they are named, still usable. §3 then attempts the index and, if
-- the duplicates block it, prints a NOTICE and moves on rather than failing the
-- migration. Once those two counts are completed, re-running this file installs
-- the index as well.
--
-- Nothing here renames, merges or deletes any stocktake. Additive and safe to
-- run twice. Mirrored into schema.sql.
--
-- Run BEFORE pushing the new app.html, which relies on this refusing the
-- duplicate rather than only warning about it client-side.
-- ---------------------------------------------------------------------------

-- §1. The rule.
--
-- The advisory lock is what makes this race-safe, and it is the whole point: a
-- bare "select then insert" check is precisely the pattern that loses this race
-- — two devices both look, both find nothing, both insert. Locking on the
-- normalised name serialises them so the second sees the first.
create or replace function public.enforce_unique_open_stocktake_name()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_key text := lower(btrim(new.name));
  v_open text[] := array['in_progress', 'ready_for_export'];
  v_clash text;
begin
  if new.status is null or not (new.status = any(v_open)) then
    return new;   -- creating or moving into history: nothing to reserve
  end if;

  perform pg_advisory_xact_lock(hashtext(new.org_id::text || '|' || v_key));

  select s.name into v_clash
    from public.stocktakes s
   where s.org_id = new.org_id
     and s.id is distinct from new.id
     and s.status = any(v_open)
     and lower(btrim(s.name)) = v_key
   limit 1;

  if v_clash is not null then
    raise exception 'A stocktake named "%" is already in progress.', btrim(new.name)
      using errcode = 'unique_violation';
  end if;

  return new;
end $$;

-- §2. Where it fires.
--
-- INSERT, plus the one UPDATE that genuinely adds to the open set (reopening a
-- completed take, which can collide with a count started in the meantime).
--
-- Deliberately NOT every UPDATE: the existing duplicate rows would then be
-- unable to move to ready_for_export, because each collides with its twin.
-- Grandfathering has to mean they stay usable, not merely present. There is no
-- rename path to miss — client UPDATE on stocktakes is revoked, and
-- set_stocktake_status() only writes status.
drop trigger if exists stocktakes_unique_open_name on public.stocktakes;
create trigger stocktakes_unique_open_name
  before insert on public.stocktakes
  for each row execute function public.enforce_unique_open_stocktake_name();

drop trigger if exists stocktakes_unique_open_name_on_reopen on public.stocktakes;
create trigger stocktakes_unique_open_name_on_reopen
  before update of status on public.stocktakes
  for each row
  when (old.status = 'completed' and new.status <> 'completed')
  execute function public.enforce_unique_open_stocktake_name();

-- §3. The stronger boundary, when the data allows it.
do $$
begin
  create unique index if not exists stocktakes_one_open_name_per_org
    on public.stocktakes (org_id, lower(btrim(name)))
    where status in ('in_progress', 'ready_for_export');
  raise notice 'stocktakes_one_open_name_per_org is in place.';
exception when unique_violation then
  raise notice 'Skipped stocktakes_one_open_name_per_org: duplicate open names already exist. The trigger still enforces this for every new stocktake; re-run this file once those counts are completed and the index will be created.';
end $$;

-- ---------------------------------------------------------------------------
-- See which open names are currently duplicated (read-only — run it first if
-- you want to know whether §3 will succeed):
--
--   select org_id, lower(btrim(name)) as name_key, count(*), array_agg(id)
--     from public.stocktakes
--    where status in ('in_progress', 'ready_for_export')
--    group by 1, 2 having count(*) > 1;
--
-- Verify (disposable names — do NOT use Belles or Colac):
--
--   -- 1. duplicate open name is refused
--   insert into public.stocktakes (name, location_id) values ('Prompt7 dup test', '<loc>');
--   insert into public.stocktakes (name, location_id) values ('prompt7 DUP test  ', '<loc>');
--   -- ERROR: A stocktake named "prompt7 DUP test" is already in progress.
--   --        (case-insensitive and trim-aware)
--
--   -- 2. still refused once the first is ready_for_export
--   select public.set_stocktake_status('<first>', 'ready_for_export', 'manual');
--   insert into public.stocktakes (name, location_id) values ('Prompt7 dup test', '<loc>');
--   -- ERROR, same message
--
--   -- 3. history does not block
--   select public.set_stocktake_status('<first>', 'completed', 'manual');
--   insert into public.stocktakes (name, location_id) values ('Prompt7 dup test', '<loc>');
--   -- succeeds
--
--   -- 4. the grandfathered rows still work: marking one of the existing
--   --    duplicate "Stress test 2" counts ready must NOT error
--   select public.set_stocktake_status('<one stress test 2 id>', 'ready_for_export', 'manual');

-- Enforce a one-month minimum term on purchased concurrent seats, so an owner
-- can't add seats for a busy weekend and drop them on the Monday.
--
-- Enforced in Postgres, not in set-seat-count, because RLS is no help here: the
-- only writer of concurrent_seats is that Edge Function using the SERVICE ROLE,
-- which bypasses RLS entirely. Triggers DO fire for service-role writes, and
-- that asymmetry is the whole mechanism.
--
-- Also fixes a pre-existing billing leak as a side effect — see the tier-change
-- branch below.
--
-- Additive and safe against a live project. Mirrored into schema.sql.
-- Run this BEFORE deploying the updated set-seat-count function.

-- ---------------------------------------------------------------------------
-- No GRANT change needed: the client-writable column grant on organisations is
-- an allowlist, so a new column is non-client-writable by construction.
alter table public.organisations
  add column if not exists seats_increased_at timestamptz;

-- ---------------------------------------------------------------------------
create or replace function public.enforce_seat_minimum_term()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  eligible_at timestamptz := old.seats_increased_at + interval '30 days';
begin
  -- Leaving multi-venue ends the commitment: the subscription item the seats
  -- were billed on is gone, and Stripe has settled the current period. Zeroing
  -- here also closes a pre-existing leak — stripe-webhook only PATCHes
  -- plan_tier, so a cancelled org kept concurrent_seats = N and a later
  -- re-subscription billed quantity 1 while the DB still granted N seats.
  if old.plan_tier = 'multi' and new.plan_tier is distinct from 'multi' then
    new.concurrent_seats := 0;
    new.seats_increased_at := null;
    return new;
  end if;

  if new.concurrent_seats is distinct from old.concurrent_seats then
    if new.concurrent_seats > old.concurrent_seats then
      -- Re-stamp on every increase, including inside an open window.
      new.seats_increased_at := now();
    elsif old.seats_increased_at is not null
          and old.seats_increased_at > now() - interval '30 days' then
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

drop trigger if exists on_org_seat_change on public.organisations;
create trigger on_org_seat_change
  before update on public.organisations
  for each row execute function public.enforce_seat_minimum_term();

-- ---------------------------------------------------------------------------
-- Verify (on a scratch project, or accept that the first statement below
-- actually changes your seat count):
--
--   update public.organisations set concurrent_seats = 5 where id = '<org>';
--   -- stamps seats_increased_at = now()
--   update public.organisations set concurrent_seats = 2 where id = '<org>';
--   -- ERROR: Added seats are billed for a minimum of one month. ...
--   update public.organisations set seats_increased_at = now() - interval '31 days'
--    where id = '<org>';
--   update public.organisations set concurrent_seats = 2 where id = '<org>';
--   -- succeeds
--
-- Note the third statement works because seats_increased_at is only *stamped* by
-- the trigger, not protected from direct service-role writes — that's the same
-- posture as country_changed_at, and fine, since no client can reach either.

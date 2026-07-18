-- Barscan schema for Supabase
-- Run this once in your Supabase project: Dashboard -> SQL Editor -> New query -> paste -> Run
-- (Safe to re-run: statements are idempotent.)

-- ---- Profiles: one row per user, holds the Pro subscription flag ----
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  is_pro boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles
  for select using (auth.uid() = id);
-- No insert/update policies for clients: profiles are created by the trigger
-- below, and is_pro is flipped only by you (dashboard/service role/Stripe webhook).

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill profiles for any users that signed up before this table existed
insert into public.profiles (id) select id from auth.users on conflict do nothing;

-- ---- Stocktakes ----
create table if not exists public.stocktakes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.stocktake_items (
  id uuid primary key default gen_random_uuid(),
  stocktake_id uuid not null references public.stocktakes(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  barcode text not null,
  qty integer not null check (qty >= 1),
  first_scanned timestamptz not null default now(),
  last_scanned timestamptz not null default now(),
  unique (stocktake_id, barcode)
);

create index if not exists stocktakes_user_idx on public.stocktakes (user_id, updated_at desc);
create index if not exists items_stocktake_idx on public.stocktake_items (stocktake_id);

-- Keep the parent stocktake's updated_at fresh whenever its items change
create or replace function public.touch_stocktake()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.stocktakes
     set updated_at = now()
   where id = coalesce(new.stocktake_id, old.stocktake_id);
  return coalesce(new, old);
end $$;

drop trigger if exists touch_stocktake_on_items on public.stocktake_items;
create trigger touch_stocktake_on_items
  after insert or update or delete on public.stocktake_items
  for each row execute function public.touch_stocktake();

-- ---- Row Level Security ----
alter table public.stocktakes enable row level security;
alter table public.stocktake_items enable row level security;

drop policy if exists "own stocktakes" on public.stocktakes;
create policy "own stocktakes" on public.stocktakes
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Items: read/update/delete own rows freely; INSERT enforces the free-plan
-- limit server-side — free users can hold at most 3 distinct products per
-- stocktake, Pro users (profiles.is_pro) are unlimited.
drop policy if exists "own items" on public.stocktake_items;
drop policy if exists "select own items" on public.stocktake_items;
drop policy if exists "update own items" on public.stocktake_items;
drop policy if exists "delete own items" on public.stocktake_items;
drop policy if exists "insert own items" on public.stocktake_items;

create policy "select own items" on public.stocktake_items
  for select using (auth.uid() = user_id);
create policy "update own items" on public.stocktake_items
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "delete own items" on public.stocktake_items
  for delete using (auth.uid() = user_id);
create policy "insert own items" on public.stocktake_items
  for insert with check (
    auth.uid() = user_id
    and (
      coalesce((select p.is_pro from public.profiles p where p.id = auth.uid()), false)
      or (select count(*) from public.stocktake_items i
            where i.stocktake_id = stocktake_items.stocktake_id) < 3
    )
  );

-- ---- Upgrading a user to Pro ----
-- Until payments are automated (e.g. a Stripe webhook), flip the flag manually:
--   update public.profiles set is_pro = true
--    where id = (select id from auth.users where email = 'person@example.com');
